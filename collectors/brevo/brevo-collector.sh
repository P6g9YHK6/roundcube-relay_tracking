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
#  each IP's reverse DNS name, and with IP_ASN=1 also its network owner (Team Cymru lookup), cached 30 days; with
#  IP_GEO=1 its location from DB-IP Lite data, searched locally.
#
#  Only mail sent from DOMAINS is kept, so a Brevo account shared with other senders does not leak into Roundcube.
#
#  Settings: file given as argument (default: brevo-collector.conf next to the script), see brevo-collector.conf.example.
#  It is sourced as shell, so it must belong to the user running the collector and not be writable by anyone else.
#  Key: 600 file outside any repository; it never goes on a command line (header in a 600 temporary file, removed
#  on exit).
#  Dry run: DRY_RUN=1 ./brevo-collector.sh > nothing is written outside a temporary folder; output shown with masked
#  addresses.
#  Dependencies: bash 4+, curl, jq, flock (util-linux), GNU date; dig (bind tools) for IP_LOOKUP, xz for IP_GEO.
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
IP_GEO="${IP_GEO:-0}"                         # 1 = location of each IP from DB-IP Lite data (needs INCLUDE_IP=1, xz)
GEO_URL="${GEO_URL:-https://raw.githubusercontent.com/P6g9YHK6/roundcube-relay_tracking/geoip}"
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

# ------------------------------------------------------------------ IP identification
# "hosts" in events.json: IP > {rdns, provider, country, region, city}. Needs INCLUDE_IP=1, then each part has its
# own switch:
#  IP_LOOKUP=1  reverse DNS name (dig), + network owner from Team Cymru's DNS service with IP_ASN=1; cached 30 days
#  IP_GEO=1     location from the DB-IP Lite data on the plugin's geoip branch (GEO_URL), downloaded when its VERSION
#               changes (checked once a day) and searched locally: the IPs never leave this server
ip_key_awk='
function pad(h) { return substr("0000" h, length(h) + 1) }
function ipkey(ip,   p, n, i, l, r, L, R, out, cut) {
  if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { split(ip, p, "."); return sprintf("4%02x%02x%02x%02x", p[1], p[2], p[3], p[4]) }
  ip = tolower(ip); cut = index(ip, "::")
  if (cut) { l = (cut > 1) ? split(substr(ip, 1, cut - 1), L, ":") : 0; r = (substr(ip, cut + 2) != "") ? split(substr(ip, cut + 2), R, ":") : 0 }
  else { l = split(ip, L, ":"); r = 0 }
  out = "6"
  for (i = 1; i <= l; i++) out = out pad(L[i])
  for (i = 0; i < 8 - l - r; i++) out = out "0000"
  for (i = 1; i <= r; i++) out = out pad(R[i])
  return out
}'

geo_update(){   # keeps $STATE_DIR/geo on the latest geoip branch VERSION; prints that version
  local g="$STATE_DIR/geo" remote
  install -d -m 0700 "$g"
  if [ ! -s "$g/VERSION" ] || [ -z "$(find "$g/.checked" -mmin -1440 2>/dev/null)" ]; then
    remote=$(curl -sf -m 20 "$GEO_URL/VERSION" | head -n 1 | tr -cd 'A-Za-z0-9 :,+-')
    if [ -n "$remote" ] && [ "$remote" != "$(cat "$g/VERSION" 2>/dev/null)" ]; then
      if curl -sf -m 600 -o "$WORK/ranges.tsv.xz" "$GEO_URL/ranges.tsv.xz" \
         && curl -sf -m 120 -o "$WORK/locations.tsv.xz" "$GEO_URL/locations.tsv.xz" \
         && xz -t "$WORK/ranges.tsv.xz" && xz -t "$WORK/locations.tsv.xz"; then
        mv -f "$WORK/ranges.tsv.xz" "$WORK/locations.tsv.xz" "$g/" && echo "$remote" > "$g/VERSION"
        log "geo: data $remote" >&2
      else
        log "geo: download of $remote failed, keeping $(cat "$g/VERSION" 2>/dev/null || echo none)" >&2
      fi
    fi
    touch "$g/.checked"
  fi
  cat "$g/VERSION" 2>/dev/null
}

if [ "$EV_OK" = "1" ] && [ "$INCLUDE_IP" = "1" ] && { [ "$IP_LOOKUP" = "1" ] || [ "$IP_GEO" = "1" ]; }; then
  jq -r '[.messages[][][] | select(length == 4) | .[3]] | unique | .[] | select(test("^[0-9a-fA-F.:]+$"))' \
    "$WORK/events.json" > "$WORK/ips"
  : > "$WORK/rdns.tsv"; : > "$WORK/geo.tsv"

  # -- reverse DNS / network owner
  if [ "$IP_LOOKUP" = "1" ] && command -v dig >/dev/null; then
    CACHE="$STATE_DIR/ipinfo.tsv"; [ -f "$CACHE" ] || : > "$CACHE"
    declare -A INFO
    while IFS=$'\t' read -r ip ts rd org; do INFO[$ip]="$ts"$'\t'"$rd"$'\t'"$org"; done < "$CACHE"
    n=0
    while read -r ip; do
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
      [ -n "$entry" ] && printf '%s\t%s\n' "$ip" "${entry#*$'\t'}" >> "$WORK/rdns.tsv"
    done < "$WORK/ips"
    # entries not seen for 90 days are dropped
    for ip in "${!INFO[@]}"; do
      [ $(( NOW - ${INFO[$ip]%%$'\t'*} )) -lt 7776000 ] && printf '%s\t%s\n' "$ip" "${INFO[$ip]}"
    done > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
  fi

  # -- location (cache: one line per IP and data version; only new IPs or a new version cost a pass over the data)
  if [ "$IP_GEO" = "1" ] && command -v xz >/dev/null; then
    GEO_VER=$(geo_update)
    GCACHE="$STATE_DIR/ipgeo.tsv"; [ -f "$GCACHE" ] || : > "$GCACHE"
    if [ -n "$GEO_VER" ]; then
      # (FILENAME, not NR == FNR: the cache is empty on the first run)
      awk -F'\t' -v ver="$GEO_VER" 'FILENAME == ARGV[1] { if ($2 == ver) c[$1] = 1; next } !($1 in c)' "$GCACHE" "$WORK/ips" \
        | awk "$ip_key_awk"' { print ipkey($1) "\t" $1 }' | LC_ALL=C sort -t $'\t' -k1,1 > "$WORK/geo.q"
      if [ -s "$WORK/geo.q" ]; then
        # one pass over the sorted ranges: each query takes the location of the last range starting at or before it
        xz -dc "$STATE_DIR/geo/ranges.tsv.xz" | awk -F'\t' -v q="$WORK/geo.q" '
          BEGIN { while ((getline line < q) > 0) { split(line, a, "\t"); n++; K[n] = a[1]; IP[n] = a[2] } i = 1; cur = 0 }
          { while (i <= n && (K[i] "") < ($1 "")) { print IP[i] "\t" cur; i++ } if (i > n) exit; cur = $2 }
          END { while (i <= n) { print IP[i] "\t" cur; i++ } }' > "$WORK/geo.ids"
        xz -dc "$STATE_DIR/geo/locations.tsv.xz" | awk -F'\t' -v ver="$GEO_VER" '
          FILENAME == ARGV[1] { want[$2] = want[$2] " " $1; next }
          ($1 in want) { n = split(want[$1], ips, " "); for (i = 1; i <= n; i++) print ips[i] "\t" ver "\t" $2 "\t" $3 "\t" $4 }' \
          "$WORK/geo.ids" - > "$WORK/geo.new"
      else
        : > "$WORK/geo.new"
      fi
      # cache = this run's IPs: freshly found ones + still valid cached ones
      awk -F'\t' -v ver="$GEO_VER" 'FILENAME == ARGV[1] { ip[$1] = 1; next } FILENAME == ARGV[2] { if ($2 == ver && ($1 in ip)) print; next }
        ($1 in ip) { print }' "$WORK/ips" "$GCACHE" "$WORK/geo.new" | sort -u -t $'\t' -k1,1 > "$GCACHE.tmp" \
        && mv -f "$GCACHE.tmp" "$GCACHE"
      cut -f1,3- "$GCACHE" > "$WORK/geo.tsv"
    fi
  fi

  # -- hosts: provider = private range, else network owner, else the last two labels of the reverse DNS name
  jq -n --rawfile ips "$WORK/ips" --rawfile rd "$WORK/rdns.tsv" --rawfile geo "$WORK/geo.tsv" '
    def rows($t): $t | split("\n") | map(select(. != "") | split("\t"));
    (rows($rd) | map({key: .[0], value: {rdns: (.[1] // ""), org: (.[2] // "")}}) | from_entries) as $R
    | (rows($geo) | map({key: .[0], value: {country: (.[1] // ""), region: (.[2] // ""), city: (.[3] // "")}}) | from_entries) as $G
    | $ips | split("\n") | map(select(. != "")) | map(. as $ip | ($R[$ip] // {}) as $r | {key: $ip, value: (
        {rdns: ($r.rdns // ""), provider: (
          if ($ip | test("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|127\\.|[fF][cdCD])")) then "private network"
          elif ($r.org // "") != "" then $r.org
          elif ($r.rdns // "") != "" then ($r.rdns | split(".") | .[-2:] | join("."))
          else "" end)} + ($G[$ip] // {}))})
    | map(select(.value.rdns != "" or .value.provider != "" or (.value.country // "") != "")) | from_entries' > "$WORK/hosts.json" \
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
