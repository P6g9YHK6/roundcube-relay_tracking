#!/usr/bin/env bash
# =====================================================================================================================
#  relay_tracking: STANDALONE Brevo collector (common format v1 of the plugin, see ../../README.md)
# =====================================================================================================================
#  The only program that talks to the Brevo API: Roundcube holds no key. Run it EVERY MINUTE (cron, systemd timer...)
#  as root or as an account that can write RELAY_DIR and read the keys.
#
#  Every minute    : blocked contacts list > blocked.json; unblock requests dropped by Roundcube in requests/ >
#                    DELETE at Brevo if the address really is blocked > unblock.json.
#  Every 5 minutes : events of the last EVENT_DAYS days (/smtp/statistics/events), grouped by Message-ID then by
#                    recipient > events.json. Never IP addresses (not read).
#  Every run       : relay.json (name, domains, capabilities), which is what enables the plugin for those domains.
#
#  Only mail sent from DOMAINS is kept (events and blocked contacts), so a Brevo account shared with other senders
#  does not leak into Roundcube.
#
#  Settings: file given as argument (default: brevo-collector.conf next to the script), see brevo-collector.conf.example.
#  It is sourced as shell, so it must belong to the user running the collector and not be writable by anyone else.
#  Keys: 600 files outside any repository; they never go on a command line (headers in 600 temporary files, removed
#  on exit).
#  Dry run: DRY_RUN=1 ./brevo-collector.sh > nothing is written outside a temporary folder, no DELETE; output shown
#  with masked addresses.
#  Dependencies: bash 4+, curl, jq, flock (util-linux), GNU date.
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
: "${API_KEY_FILE:?API_KEY_FILE missing}"    # Brevo key (read statistics and blocked contacts)
UNBLOCK_KEY_FILE="${UNBLOCK_KEY_FILE:-$API_KEY_FILE}"   # key allowed to unblock (may be the same)
WEB_UID="${WEB_UID:-33}"                      # Roundcube web server user (www-data = 33 in the official image)
STATE_DIR="${STATE_DIR:-/var/lib/relay-tracking-brevo}"   # lock, unblock log
EVENT_DAYS="${EVENT_DAYS:-90}"                # Brevo API maximum
[ -n "${LAG:-}" ] || LAG="up to 1-2 h"        # statistics publication delay (shown in Roundcube)
MAX_UNBLOCK=20
RETRY_FOR=1800                                # an unblock that fails on 429/5xx/network is retried this long (s)
EV_PAGE=2500
EV_MAX=25000                                  # events fetched at most per run; "since" tells the plugin where it stopped
API="https://api.brevo.com/v3"
DRY="${DRY_RUN:-0}"

install -d -m 0700 "$STATE_DIR" || exit 1
exec 9>"$STATE_DIR/.lock"
flock -n 9 || exit 0
WORK=$(mktemp -d "$STATE_DIR/.work.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

OUT="$RELAY_DIR"; REQ="$RELAY_DIR/requests"; LOG="$STATE_DIR/unblock.log"
if [ "$DRY" = "1" ]; then
  OUT="$WORK/out"; LOG="$WORK/out/unblock.log"; install -d -m 0700 "$OUT"
  [ -d "$RELAY_DIR/requests" ] && REQ="$RELAY_DIR/requests" || REQ="$WORK/out/requests"
else
  install -d -m 0755 "$OUT" || exit 1
  [ -d "$REQ" ] || install -d -m 0770 -o "$WEB_UID" -g "$WEB_UID" "$REQ"
fi
NOW=$(date +%s)
log(){ echo "[brevo-collector] $*"; }

hdr(){ [ -s "$1" ] || return 1; printf 'api-key: %s\nAccept: application/json\n' "$(tr -d '\r\n ' < "$1")" > "$2"; }
HS="$WORK/h-stats"; HU="$WORK/h-unblock"
hdr "$API_KEY_FILE" "$HS" || { log "key not readable: $API_KEY_FILE"; exit 1; }
hdr "$UNBLOCK_KEY_FILE" "$HU" || HU=""
api(){ curl -s -m 30 -H @"$1" -o "$3" -w '%{http_code}' "$API$2" 2>/dev/null; }

# Atomic write, readable by Roundcube, only when the content changes
publish(){ if [ -f "$2" ] && cmp -s "$1" "$2"; then return 0; fi; cp "$1" "$2.tmp" && chmod 644 "$2.tmp" && mv -f "$2.tmp" "$2"; }

# Sender domains as a jq array, to keep only our own mail
DOMAINS_JSON=$(jq -cn --arg d "$DOMAINS" '$d | ascii_downcase | split(" ") | map(select(. != ""))')
OURS='(ascii_downcase | split("@") | .[-1]) as $dom | $doms | index([$dom]) != null'

# Common vocabulary (plugin README)
REASON_MAP='if test("^unsubscribed") then "unsubscribed" elif . == "hardBounce" then "hard_bounce"
  elif . == "contactFlaggedAsSpam" then "spam" elif . == "adminBlocked" then "manual" else "other" end'
EVENT_MAP='({"requests":"sent","delivered":"delivered","deferred":"deferred","softBounces":"soft_bounce",
  "hardBounces":"hard_bounce","bounces":"hard_bounce","blocked":"blocked","invalid":"invalid","error":"error",
  "opened":"opened","loadedByProxy":"proxy_open","clicks":"clicked","spam":"spam","unsubscribed":"unsubscribed"}[.] // "other")'

# ------------------------------------------------------------------ 0. relay description
CAPS='["events","opens","clicks","blocked"]'; [ -n "$HU" ] && CAPS='["events","opens","clicks","blocked","unblock"]'
jq -n --argjson doms "$DOMAINS_JSON" --arg lag "$LAG" --argjson days "$EVENT_DAYS" --argjson caps "$CAPS" \
  '{format: 1, id: "brevo", name: "Brevo", domains: $doms, lag: $lag, events_days: $days, capabilities: $caps}' \
  > "$WORK/relay.json" && publish "$WORK/relay.json" "$OUT/relay.json"

# ------------------------------------------------------------------ 1. blocked contacts (every minute)
# Brevo's list is account wide: keep contacts blocked while sending from our domains (or without a known sender)
blocked_json(){ jq -s --argjson gen "$NOW" --argjson doms "$DOMAINS_JSON" '{generated: $gen, contacts: [ .[]
    | select((.senderEmail // "") == "" or (.senderEmail | '"$OURS"'))
    | {email: (.email | ascii_downcase), reason: ((.reason.code // "") | '"$REASON_MAP"'),
       detail: (.reason.message // .reason.code // ""), at: .blockedAt}
      + (if (.senderEmail // "") != "" then {sender: (.senderEmail | ascii_downcase)} else {} end) ]}' "$WORK/bl.all"; }
: > "$WORK/bl.all"
KEY_BL="$HS"; [ -n "$HU" ] && KEY_BL="$HU"
off=0; BL_OK=1
while :; do
  c=$(api "$KEY_BL" "/smtp/blockedContacts?limit=100&offset=$off&sort=desc" "$WORK/bl.page")
  if [ "$c" != "200" ] || ! jq -e '.' "$WORK/bl.page" >/dev/null 2>&1; then BL_OK=0; log "blockedContacts: HTTP $c"; break; fi
  jq -c '(.contacts // [])[]' "$WORK/bl.page" >> "$WORK/bl.all"
  [ "$(jq '(.contacts // []) | length' "$WORK/bl.page")" -lt 100 ] && break
  off=$(( off + 100 )); [ "$off" -ge 5000 ] && break
done
[ "$BL_OK" = "1" ] && blocked_json > "$WORK/blocked.json" && publish "$WORK/blocked.json" "$OUT/blocked.json"

# ------------------------------------------------------------------ 2. unblock requests (every minute)
if [ -n "$HU" ] && [ "$BL_OK" = "1" ] && [ -d "$REQ" ]; then
  mapfile -t FILES < <(find "$REQ" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | head -n "$MAX_UNBLOCK")
  if [ "${#FILES[@]}" -gt 0 ]; then
    [ -f "$OUT/unblock.json" ] && cp "$OUT/unblock.json" "$WORK/unblock.json" || echo '{"requests":[]}' > "$WORK/unblock.json"
    for f in "${FILES[@]}"; do
      id=$(basename "$f" .json); [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || id="invalid"
      email=""; user=""
      if [ "$(stat -c %s "$f" 2>/dev/null || echo 99999)" -le 2048 ] && [ ! -L "$f" ]; then
        email=$(jq -r '.email // empty' "$f" 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -c 254)
        user=$(jq -r '.user // empty' "$f" 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -c 254)
      fi
      [[ "$user" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+$ ]] || user="?"
      if ! [[ "$email" =~ ^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$ ]]; then
        status="invalid"; email=""
      elif ! blocked_json | jq -e --arg e "$email" '.contacts[] | select(.email == $e)' >/dev/null 2>&1; then
        status="not_blocked"                       # not blocked for our domains: no API call
      elif [ "$DRY" = "1" ]; then
        status="dry_run"
      else
        c=$(curl -s -m 30 -X DELETE -H @"$HU" -o /dev/null -w '%{http_code}' \
              "$API/smtp/blockedContacts/$(jq -rn --arg e "$email" '$e | @uri')" 2>/dev/null)
        case "$c" in 204) status="unblocked" ;; 404) status="not_blocked" ;; *) status="error_$c" ;; esac
      fi
      # rate limit, Brevo or network down: keep the request for the next run, up to RETRY_FOR after it was made
      if [[ "$status" =~ ^error_(000|429|5[0-9][0-9])$ ]] && [ $(( NOW - $(stat -c %Y "$f") )) -lt "$RETRY_FOR" ]; then
        log "unblock: HTTP ${status#error_}, retried next run"
        [ "$status" = "error_429" ] && break
        continue
      fi
      printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$user" "${email:-?}" "$status" >> "$LOG"; chmod 600 "$LOG"
      [ "$(wc -l < "$LOG")" -gt 1000 ] && tail -n 1000 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
      jq --arg id "$id" --arg e "$email" --arg u "$user" --arg s "$status" --argjson t "$(date +%s)" \
         '.requests = ([{id: $id, email: $e, user: $u, status: $s, at: $t}] + .requests)[:50]' \
         "$WORK/unblock.json" > "$WORK/unblock.new" && mv -f "$WORK/unblock.new" "$WORK/unblock.json"
      [ "$DRY" = "1" ] || rm -f "$f"
      [ "$status" = "unblocked" ] && jq -c --arg e "$email" 'select(.email | ascii_downcase != $e)' "$WORK/bl.all" \
        > "$WORK/bl.tmp" && mv -f "$WORK/bl.tmp" "$WORK/bl.all"
    done
    publish "$WORK/unblock.json" "$OUT/unblock.json"
    blocked_json > "$WORK/blocked.json" && publish "$WORK/blocked.json" "$OUT/blocked.json"
  fi
fi

# ------------------------------------------------------------------ 3. events (every 5 minutes)
AGE=999999; [ -f "$OUT/events.json" ] && AGE=$(( NOW - $(stat -c %Y "$OUT/events.json") ))
if [ "$DRY" = "1" ] || [ $(( 10#$(date +%M) % 5 )) -eq 0 ] || [ "$AGE" -ge 290 ]; then
  : > "$WORK/ev.all"; off=0; EV_OK=1; SINCE=0
  while :; do
    c=$(api "$HS" "/smtp/statistics/events?days=$EVENT_DAYS&limit=$EV_PAGE&offset=$off&sort=desc" "$WORK/ev.page")
    if [ "$c" != "200" ] || ! jq -e '.' "$WORK/ev.page" >/dev/null 2>&1; then EV_OK=0; log "events: HTTP $c"; break; fi
    jq -c '(.events // [])[] | {m: (.messageId // "" | if . == "" or startswith("<") then . else "<" + . + ">" end),
                                f: (.from // ""), e: ((.email // "") | ascii_downcase), d: .date,
                                t: (.event | '"$EVENT_MAP"'),
                                l: (if .event == "clicks" then (.link // "") else "" end), r: (.reason // "")}' \
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
    # [date, type] + link (click) or reason (bounce); our sender domains only (events without sender are kept);
    # pseudonymous addresses (Brevo anonymous tracking) dropped
    jq -s --argjson gen "$NOW" --argjson days "$EVENT_DAYS" --argjson since "$SINCE" --argjson doms "$DOMAINS_JSON" \
      '{generated: $gen, days: $days} + (if $since > 0 then {since: $since} else {} end) + {
        messages: ( map(select((.m // "") != "" and (.e | test("@")) and (.f == "" or (.f | '"$OURS"'))))
          | group_by(.m) | map({key: .[0].m, value:
              ( group_by(.e) | map({key: .[0].e, value:
                  ( sort_by(.d) | map([.d, .t] + (if .l != "" then [.l] elif .r != "" then [.r] else [] end)) )})
                | from_entries )})
          | from_entries )}' "$WORK/ev.all" > "$WORK/events.json" && publish "$WORK/events.json" "$OUT/events.json"
  fi
fi

if [ "$DRY" = "1" ]; then
  mask(){ sed -E 's/"([^"@ ]{1})[^"@ ]*@/"\1***@/g'; }
  for f in relay blocked events unblock; do
    [ -f "$OUT/$f.json" ] && { echo "===== $f.json"; jq -c . "$OUT/$f.json" | mask | head -c 2000; echo; }
  done
fi
exit 0
