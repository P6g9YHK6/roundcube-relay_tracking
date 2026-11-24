#!/usr/bin/env bash
# =====================================================================================================================
#  relay_tracking: STANDALONE Brevo collector (common format v1 of the plugin, see ../../README.md)
# =====================================================================================================================
#  The only program that talks to the Brevo API: Roundcube holds no key. Run it EVERY 5 MINUTES (cron, systemd
#  timer...) as root or as an account that can write RELAY_DIR and read the key.
#
#  Each run: relay.json (name, domains, capabilities), which is what enables the plugin for those domains, and the
#  events of the last EVENT_DAYS days (/smtp/statistics/events), grouped by Message-ID then by recipient >
#  events.json. IP addresses only with INCLUDE_IP=1 (personal data of the recipients: off by default); with IP_LOOKUP=1
#  each IP's reverse DNS name, and with IP_ASN=1 also its network owner (Team Cymru lookup), cached 30 days.
#
#  Only mail sent from DOMAINS is kept, so a Brevo account shared with other senders does not leak into Roundcube.
#
#  Settings: file given as argument (default: brevo-collector.conf next to the script), see brevo-collector.conf.example.
#  It is sourced as shell, so it must belong to the user running the collector and not be writable by anyone else.
#  Key: 600 file outside any repository; it never goes on a command line (header in a 600 temporary file, removed
#  on exit).
#  Dry run: DRY_RUN=1 ./brevo-collector.sh > nothing is written outside a temporary folder; output shown with masked
#  addresses.
#  Dependencies: bash 4+, curl, jq, flock (util-linux), GNU date; dig (bind tools) for IP_LOOKUP.
#  License: GPL-3.0-or-later.
# =====================================================================================================================
set -uo pipefail
umask 077

CONF="${1:-$(dirname "$0")/brevo-collector.conf}"
[ -r "$CONF" ] || { echo "settings not found: $CONF" >&2; exit 1; }
# sourced as shell: refuse a file someone else could have written
if [ "$(stat -Lc %u "$CONF")" != "$(id -u)" ] || [ $(( 0$(stat -Lc %a "$CONF") & 022 )) -ne 0 ]; then
  echo "settings must belong to $(id -un) and not be group/world writable: $CONF" >&2; exit 1
fi
# shellcheck source=/dev/null
. "$CONF"

: "${RELAY_DIR:?RELAY_DIR missing}"          # e.g. /srv/roundcube/relays/brevo (mounted in Roundcube)
: "${DOMAINS:?DOMAINS missing}"              # e.g. "example.org other.org" (sender domains that go through Brevo)
: "${API_KEY_FILE:?API_KEY_FILE missing}"    # Brevo key (read transactional statistics)
STATE_DIR="${STATE_DIR:-/var/lib/relay-tracking-brevo}"   # lock
EVENT_DAYS="${EVENT_DAYS:-90}"                # Brevo API maximum
INCLUDE_IP="${INCLUDE_IP:-0}"                 # 1 = keep the IP of each event (shown in the Roundcube timeline)
IP_LOOKUP="${IP_LOOKUP:-0}"                   # 1 = identify each IP: reverse DNS name (needs INCLUDE_IP=1 and dig)
IP_ASN="${IP_ASN:-0}"                         # 1 = also look up each IP's network owner at Team Cymru (third party)
IP_LOOKUPS=200                                # new IP lookups per run at most (cached 30 days)
[ -n "${LAG:-}" ] || LAG="up to 1-2 h"        # statistics publication delay (shown in Roundcube)
EV_PAGE=2500
EV_MAX=25000                                  # events fetched at most per run; "since" tells the plugin where it stopped
API="https://api.brevo.com/v3"
DRY="${DRY_RUN:-0}"

install -d -m 0700 "$STATE_DIR" || exit 1
exec 9>"$STATE_DIR/.lock"
flock -n 9 || exit 0
WORK=$(mktemp -d "$STATE_DIR/.work.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

OUT="$RELAY_DIR"
if [ "$DRY" = "1" ]; then
  OUT="$WORK/out"; install -d -m 0700 "$OUT"
else
  install -d -m 0755 "$OUT" || exit 1
fi
NOW=$(date +%s)
log(){ echo "[brevo-collector] $*"; }

HS="$WORK/h-stats"
[ -s "$API_KEY_FILE" ] || { log "key not readable: $API_KEY_FILE"; exit 1; }
printf 'api-key: %s\nAccept: application/json\n' "$(tr -d '\r\n ' < "$API_KEY_FILE")" > "$HS"
api(){ curl -s -m 30 -H @"$HS" -o "$2" -w '%{http_code}' "$API$1" 2>/dev/null; }

# Atomic write, readable by Roundcube, only when the content changes
publish(){ if [ -f "$2" ] && cmp -s "$1" "$2"; then return 0; fi; cp "$1" "$2.tmp" && chmod 644 "$2.tmp" && mv -f "$2.tmp" "$2"; }

# Sender domains as a jq array, to keep only our own mail
DOMAINS_JSON=$(jq -cn --arg d "$DOMAINS" '$d | ascii_downcase | split(" ") | map(select(. != ""))')
OURS='(ascii_downcase | split("@") | .[-1]) as $dom | $doms | index([$dom]) != null'

# Common vocabulary (plugin README)
EVENT_MAP='({"requests":"sent","delivered":"delivered","deferred":"deferred","softBounces":"soft_bounce",
  "hardBounces":"hard_bounce","bounces":"hard_bounce","blocked":"blocked","invalid":"invalid","error":"error",
  "opened":"opened","loadedByProxy":"proxy_open","clicks":"clicked","spam":"spam","unsubscribed":"unsubscribed"}[.] // "other")'

# ------------------------------------------------------------------ relay description
jq -n --argjson doms "$DOMAINS_JSON" --arg lag "$LAG" --argjson days "$EVENT_DAYS" \
  '{format: 1, id: "brevo", name: "Brevo", domains: $doms, lag: $lag, events_days: $days,
    capabilities: ["events", "opens", "clicks"]}' \
  > "$WORK/relay.json" && publish "$WORK/relay.json" "$OUT/relay.json"

# ------------------------------------------------------------------ events
: > "$WORK/ev.all"; off=0; EV_OK=1; SINCE=0
while :; do
  c=$(api "/smtp/statistics/events?days=$EVENT_DAYS&limit=$EV_PAGE&offset=$off&sort=desc" "$WORK/ev.page")
  if [ "$c" != "200" ] || ! jq -e '.' "$WORK/ev.page" >/dev/null 2>&1; then EV_OK=0; log "events: HTTP $c"; break; fi
  jq -c '(.events // [])[] | {m: (.messageId // "" | if . == "" or startswith("<") then . else "<" + . + ">" end),
                              f: (.from // ""), e: ((.email // "") | ascii_downcase), d: .date,
                              t: (.event | '"$EVENT_MAP"'),
                              l: (if .event == "clicks" then (.link // "") else "" end), r: (.reason // ""),
                              i: (if $ip then (.ip // "") else "" end)}' --argjson ip "$( [ "$INCLUDE_IP" = 1 ] && echo true || echo false )" \
     "$WORK/ev.page" >> "$WORK/ev.all"
  [ "$(jq '(.events // []) | length' "$WORK/ev.page")" -lt "$EV_PAGE" ] && break
  off=$(( off + EV_PAGE ))
  if [ "$off" -ge "$EV_MAX" ]; then
    # window not fully read (newest first): tell the plugin where coverage starts, older mails show as expired
    SINCE=$(date -d "$(tail -n 1 "$WORK/ev.all" | jq -r '.d')" +%s 2>/dev/null || echo 0)
    log "events: stopped after $EV_MAX, covering since $(date -d "@$SINCE" -Is 2>/dev/null)"
    break
  fi
done
if [ "$EV_OK" = "1" ]; then
  # [date, type] + link (click) or reason (bounce), + IP when kept (extra is then "" if none); our sender domains
  # only (events without sender are kept);
  # pseudonymous addresses (Brevo anonymous tracking) dropped
  jq -s --argjson gen "$NOW" --argjson days "$EVENT_DAYS" --argjson since "$SINCE" --argjson doms "$DOMAINS_JSON" \
    '{generated: $gen, days: $days} + (if $since > 0 then {since: $since} else {} end) + {
      messages: ( map(select((.m // "") != "" and (.e | test("@")) and (.f == "" or (.f | '"$OURS"'))))
        | group_by(.m) | map({key: .[0].m, value:
            ( group_by(.e) | map({key: .[0].e, value:
                ( sort_by(.d) | map([.d, .t] + (if .i != "" then [(if .l != "" then .l else .r end), .i]
                                  elif .l != "" then [.l] elif .r != "" then [.r] else [] end)) )})
              | from_entries )})
        | from_entries )}' "$WORK/ev.all" > "$WORK/events.json" && EV_OK=1 || EV_OK=0
fi

# ------------------------------------------------------------------ IP identification (INCLUDE_IP=1 + IP_LOOKUP=1)
# "hosts" in events.json: IP > {rdns, provider}. Reverse DNS for every IP; network owner (ASN name) from Team Cymru's
# DNS service when IP_ASN=1. Cached in STATE_DIR for 30 days, IP_LOOKUPS new lookups per run at most.
if [ "$EV_OK" = "1" ] && [ "$INCLUDE_IP" = "1" ] && [ "$IP_LOOKUP" = "1" ] && command -v dig >/dev/null; then
  CACHE="$STATE_DIR/ipinfo.tsv"; [ -f "$CACHE" ] || : > "$CACHE"
  declare -A INFO
  while IFS=$'\t' read -r ip ts rd org; do INFO[$ip]="$ts"$'\t'"$rd"$'\t'"$org"; done < "$CACHE"
  n=0
  : > "$WORK/hosts.tsv"
  while read -r ip; do
    [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]] || continue
    entry="${INFO[$ip]:-}"
    if [ -z "$entry" ] || [ $(( NOW - ${entry%%$'\t'*} )) -gt 2592000 ]; then
      if [ "$n" -lt "$IP_LOOKUPS" ]; then
        n=$(( n + 1 ))
        rd=$(dig +short +time=1 +tries=1 -x "$ip" 2>/dev/null | grep -E '^[A-Za-z0-9.-]+\.$' | head -n 1 | sed 's/\.$//')
        org=""
        if [ "$IP_ASN" = "1" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          rev=$(awk -F. '{print $4"."$3"."$2"."$1}' <<< "$ip")
          asn=$(dig +short +time=1 +tries=1 "$rev.origin.asn.cymru.com" TXT 2>/dev/null | grep '^"' | head -n 1 | tr -d '"' | cut -d'|' -f1 | tr -cd '0-9')
          [ -n "$asn" ] && org=$(dig +short +time=1 +tries=1 "AS$asn.asn.cymru.com" TXT 2>/dev/null | grep '^"' | head -n 1 | tr -d '"' \
            | awk -F'|' '{print $5}' | sed -E 's/^ +//; s/, [A-Z]{2}$//' | tr -cd 'A-Za-z0-9 .,&()-' | head -c 60)
        fi
        INFO[$ip]="$NOW"$'\t'"$rd"$'\t'"$org"
      fi
    fi
    entry="${INFO[$ip]:-}"
    [ -n "$entry" ] && printf '%s\t%s\n' "$ip" "${entry#*$'\t'}" >> "$WORK/hosts.tsv"
  done < <(jq -r '[.messages[][][] | select(length == 4) | .[3]] | unique | .[]' "$WORK/events.json")
  # entries not seen for 90 days are dropped
  for ip in "${!INFO[@]}"; do
    [ $(( NOW - ${INFO[$ip]%%$'\t'*} )) -lt 7776000 ] && printf '%s\t%s\n' "$ip" "${INFO[$ip]}"
  done > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
  # provider: private range, else network owner, else the last two labels of the reverse DNS name
  jq -R -s 'split("\n") | map(select(. != "") | split("\t")) | map({key: .[0], value: (
      (.[1] // "") as $rd | (.[2] // "") as $org | {rdns: $rd, provider: (
        if (.[0] | test("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|127\\.|[fF][cdCD])")) then "private network"
        elif $org != "" then $org
        elif $rd != "" then ($rd | split(".") | .[-2:] | join("."))
        else "" end)})}) | from_entries' "$WORK/hosts.tsv" > "$WORK/hosts.json" \
    && jq --slurpfile h "$WORK/hosts.json" '. + {hosts: $h[0]}' "$WORK/events.json" > "$WORK/events.new" \
    && mv -f "$WORK/events.new" "$WORK/events.json"
fi
[ "$EV_OK" = "1" ] && publish "$WORK/events.json" "$OUT/events.json"

if [ "$DRY" = "1" ]; then
  mask(){ sed -E 's/"([^"@ ]{1})[^"@ ]*@/"\1***@/g'; }
  for f in relay events; do
    [ -f "$OUT/$f.json" ] && { echo "===== $f.json"; jq -c . "$OUT/$f.json" | mask | head -c 2000; echo; }
  done
fi
exit 0
