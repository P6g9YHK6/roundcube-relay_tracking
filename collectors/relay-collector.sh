#!/usr/bin/env bash
# =====================================================================================================================
#  relay_tracking: relay collector (common format v1 of the plugin, see ../README.md)
# =====================================================================================================================
#  The only program that talks to the relay API: Roundcube holds no key. Run it EVERY 5 MINUTES (cron, systemd
#  timer...) as root or as an account that can write RELAY_DIR and read the key. One settings file per relay:
#
#    relay-collector.sh /srv/relay-tracking/collector/brevo.conf
#
#  The settings file names the relay (RELAY=brevo, postmark, mailgun...), whose driver in relays/<RELAY>.sh fetches
#  the events and maps them to the common vocabulary. This script does the rest, the same for every relay:
#  relay.json (name, domains, capabilities, headers to add when sending), which is what enables the plugin for those
#  domains, and events.json, the events of the last EVENT_DAYS days grouped by Message-ID then by recipient. IP
#  addresses only with INCLUDE_IP=1 (personal data of the recipients: off by default); with IP_LOOKUP=1 each IP's
#  reverse DNS name, and with IP_ASN=1 also its network owner (Team Cymru lookup), cached 30 days; with IP_GEO=1 its
#  location from DB-IP Lite data, searched locally.
#
#  Only mail sent from DOMAINS is kept, so a relay account shared with other senders does not leak into Roundcube.
#
#  Settings: see relay-collector.conf.example. The file is sourced as shell, so it must belong to the user running the
#  collector and not be writable by anyone else.
#  Key: 600 file outside any repository; it never goes on a command line (curl reads it from a 600 temporary config
#  file, removed on exit).
#  Dry run: DRY_RUN=1 ./relay-collector.sh x.conf > nothing is written outside a temporary folder (the relay's queue,
#  for Amazon SES, is not emptied); output shown with masked addresses.
#  Dependencies: bash 4+, curl (7.75+ for Amazon SES), jq 1.6+, flock (util-linux), GNU date; dig (bind tools) for
#  IP_LOOKUP, xz for IP_GEO; the relay drivers may need more (see their header).
#  License: GPL-3.0-or-later.
#
#  Driver contract (relays/<id>.sh, sourced after the settings):
#    R_NAME     display name                         R_CAPS     capabilities, JSON array ("events" required)
#    R_DAYS     longest window the relay keeps       R_LAG      publication delay shown while a mail is pending
#    R_HEADERS  JSON object of headers the plugin adds to each mail sent through the relay, "{message_id}" replaced
#               by its Message-ID (for relays that do not return the Message-ID); {} when none
#    R_KEEP     1 = events are accumulated in STATE_DIR between runs (relays that only give what changed lately);
#               r_fetch then only needs the events since $FROM, and may set CURSOR (epoch) when it stopped before now
#    r_auth     writes the curl settings (key) with cfg_header / cfg_user / cfg_line
#    r_fetch    appends the events to $EV, one JSON object per line:
#                 {m: Message-ID with <>, f: sender (or ""), e: recipient (or "*" for all), d: date (ISO 8601 or
#                  epoch seconds), t: common type, l: clicked link, r: reason, i: IP}
#               returns non-zero when the relay could not be read (nothing is published then); may set SINCE (epoch)
#               when it could not read the whole window
# =====================================================================================================================
set -uo pipefail
umask 077

CONF="${1:-}"
[ -n "$CONF" ] && [ -r "$CONF" ] || { echo "usage: $0 <settings file>" >&2; exit 1; }
# sourced as shell: refuse a file someone else could have written
if [ "$(stat -Lc %u "$CONF")" != "$(id -u)" ] || [ $(( 0$(stat -Lc %a "$CONF") & 022 )) -ne 0 ]; then
  echo "settings must belong to $(id -un) and not be group/world writable: $CONF" >&2; exit 1
fi
# shellcheck source=/dev/null
. "$CONF"

RELAY="${RELAY:-}"
[[ "$RELAY" =~ ^[a-z0-9_-]{1,32}$ ]] || { echo "RELAY missing or invalid in $CONF" >&2; exit 1; }
DRIVER="$(dirname "$(readlink -f "$0")")/relays/$RELAY.sh"
[ -r "$DRIVER" ] || { echo "no driver for relay $RELAY: $DRIVER" >&2; exit 1; }

: "${RELAY_DIR:?RELAY_DIR missing}"          # e.g. /srv/relay-tracking/data/brevo (mounted in Roundcube)
: "${DOMAINS:?DOMAINS missing}"              # e.g. "example.org other.org" (sender domains that go through the relay)
: "${API_KEY_FILE:?API_KEY_FILE missing}"    # relay key, alone in its file
STATE_DIR="${STATE_DIR:-/var/lib/relay-tracking-$RELAY}"   # lock, caches, accumulated events
INCLUDE_IP="${INCLUDE_IP:-0}"                 # 1 = keep the IP of each event (shown in the Roundcube timeline)
IP_LOOKUP="${IP_LOOKUP:-0}"                   # 1 = identify each IP: reverse DNS name (needs INCLUDE_IP=1 and dig)
IP_ASN="${IP_ASN:-0}"                         # 1 = also look up each IP's network owner at Team Cymru (third party)
IP_LOOKUPS=200                                # new IP lookups per run at most (cached 30 days)
IP_GEO="${IP_GEO:-0}"                         # 1 = location of each IP from DB-IP Lite data (needs INCLUDE_IP=1, xz)
GEO_URL="${GEO_URL:-https://raw.githubusercontent.com/P6g9YHK6/roundcube-relay_tracking/geoip}"
DRY="${DRY_RUN:-0}"

R_HEADERS='{}'; R_KEEP=0; R_LAG="a few minutes"
# shellcheck source=/dev/null
. "$DRIVER"
EVENT_DAYS="${EVENT_DAYS:-$R_DAYS}"
[ "$EVENT_DAYS" -gt "$R_DAYS" ] 2>/dev/null && EVENT_DAYS=$R_DAYS
[ -n "${LAG:-}" ] || LAG="$R_LAG"

install -d -m 0700 "$STATE_DIR" || exit 1
exec 9>"$STATE_DIR/.lock"
flock -n 9 || exit 0
WORK=$(mktemp -d "$STATE_DIR/.work.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# Persistent data of the driver (accumulated events, per message cache, cursor) in $DATA; a dry run works on a copy
DATA="$STATE_DIR/data"
install -d -m 0700 "$DATA" || exit 1
OUT="$RELAY_DIR"
if [ "$DRY" = "1" ]; then
  OUT="$WORK/out"; install -d -m 0700 "$OUT"
  cp -a "$DATA" "$WORK/data" && DATA="$WORK/data"
else
  install -d -m 0755 "$OUT" || exit 1
fi
NOW=$(date +%s)
WINDOW_START=$(( NOW - EVENT_DAYS * 86400 ))
log(){ echo "[relay-collector $RELAY] $*" >&2; }

# ------------------------------------------------------------------ helpers for the drivers
# curl settings holding the key: a 600 file read with -K, never the command line
CFG="$WORK/curl.cfg"; : > "$CFG"
cfgq(){ local v="${1//\\/\\\\}"; printf '"%s"' "${v//\"/\\\"}"; }
cfg_line(){ printf '%s = %s\n' "$1" "$(cfgq "$2")" >> "$CFG"; }
cfg_header(){ cfg_line header "$1"; }
cfg_user(){ cfg_line user "$1"; }
[ -s "$API_KEY_FILE" ] || { log "key not readable: $API_KEY_FILE"; exit 1; }
KEY=$(tr -d '\r\n ' < "$API_KEY_FILE")

# api URL OUT [JSON body file]: GET (or POST with a body), prints the HTTP status; a 429 is retried once after the
# delay the relay asks for (60 s at most). URL: full, or a path after $API
api(){
  local url="$1" out="$2" body="${3:-}" c wait
  [[ "$url" == http* ]] || url="$API$url"
  for _ in 1 2; do
    if [ -n "$body" ]; then
      c=$(curl -s -m 60 -K "$CFG" -H 'Accept: application/json' -H 'Content-Type: application/json' \
            --data-binary @"$body" -D "$WORK/resp.h" -o "$out" -w '%{http_code}' "$url" 2>/dev/null)
    else
      c=$(curl -s -m 60 -K "$CFG" -H 'Accept: application/json' -D "$WORK/resp.h" -o "$out" -w '%{http_code}' "$url" 2>/dev/null)
    fi
    [ "$c" = "429" ] || break
    wait=$(grep -i '^retry-after:' "$WORK/resp.h" | tr -cd '0-9'); wait=${wait:-10}
    [ "$wait" -gt 60 ] && wait=60
    sleep "$wait"
  done
  echo "$c"
}
# api call that must answer 200 with JSON
api_ok(){ local c; c=$(api "$@"); [ "$c" = "200" ] && jq -e . "$2" >/dev/null 2>&1 && return 0; log "HTTP $c on ${1%%\?*}"; return 1; }
uri(){ jq -rn --arg v "$1" '$v | @uri'; }
iso(){ date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# jq helpers for the drivers: mid = Message-ID with angle brackets ("" when none)
JQ_DEFS='def mid: if . == null or . == "" then "" else (tostring | gsub("^\\s+|\\s+$"; "")
  | if startswith("<") then . else "<" + . + ">" end) end;'

# Per message cache, for relays read one message at a time: mc_fresh KEY STAMP tells whether KEY was stored with that
# STAMP (whatever changes when the message gets new events), mc_put KEY STAMP < lines stores it, mc_get KEY prints it.
# Every cached message is part of the events; messages not refreshed for EVENT_DAYS + 2 days are dropped.
MC="$DATA/msg"; install -d -m 0700 "$MC"
mc_file(){ printf '%s/%s' "$MC" "$(printf '%s' "$1" | md5sum | cut -c1-32)"; }
mc_fresh(){ local f; f=$(mc_file "$1"); [ -f "$f.stamp" ] && [ "$(cat "$f.stamp")" = "$2" ]; }
mc_put(){ local f; f=$(mc_file "$1"); cat > "$f.ev" && printf '%s' "$2" > "$f.stamp"; }
mc_get(){ local f; f=$(mc_file "$1"); cat "$f.ev" 2>/dev/null; }
mc_touch(){ local f; f=$(mc_file "$1"); [ -f "$f.ev" ] && touch "$f.ev" "$f.stamp"; }
# refresh interval by message age: every run the first day, hourly the first week, daily after
mc_age_stamp(){ local a=$(( NOW - $1 )); if [ "$a" -lt 86400 ]; then echo "$NOW"; elif [ "$a" -lt 604800 ]; then echo "h$(( NOW / 3600 ))"; else echo "d$(( NOW / 86400 ))"; fi; }
mc_all(){ find "$MC" -name '*.ev' -mtime +$(( EVENT_DAYS + 2 )) -delete 2>/dev/null
          find "$MC" -name '*.stamp' -mtime +$(( EVENT_DAYS + 2 )) -delete 2>/dev/null
          find "$MC" -name '*.ev' -exec cat {} + 2>/dev/null; }

# Drivers reading only what changed read from $FROM: the last successful run, with an overlap for late events, or the
# window start
FROM=$WINDOW_START
if [ -s "$DATA/cursor" ]; then
  c=$(( $(cat "$DATA/cursor") - ${R_OVERLAP:-7200} ))
  [ "$c" -gt "$FROM" ] && FROM=$c
fi

# Sender domains as a jq array, to keep only our own mail
DOMAINS_JSON=$(jq -cn --arg d "$DOMAINS" '$d | ascii_downcase | split(" ") | map(select(. != ""))')
OURS='(ascii_downcase | split("@") | .[-1]) as $dom | $doms | index([$dom]) != null'

# Atomic write, readable by Roundcube, only when the content changes
publish(){ if [ -f "$2" ] && cmp -s "$1" "$2"; then return 0; fi; cp "$1" "$2.tmp" && chmod 644 "$2.tmp" && mv -f "$2.tmp" "$2"; }

# ------------------------------------------------------------------ relay description
jq -n --arg id "$RELAY" --arg name "$R_NAME" --argjson doms "$DOMAINS_JSON" --arg lag "$LAG" \
  --argjson days "$EVENT_DAYS" --argjson caps "$R_CAPS" --argjson hdr "$R_HEADERS" \
  '{format: 1, id: $id, name: $name, domains: $doms, lag: $lag, events_days: $days, capabilities: $caps}
   + (if $hdr == {} then {} else {headers: $hdr} end)' \
  > "$WORK/relay.json" && publish "$WORK/relay.json" "$OUT/relay.json"

# ------------------------------------------------------------------ events
# date to epoch: ISO 8601 with a T or a space, optional fraction, Z / +hh:mm / +hhmm / +hh or none (UTC); or a number
EPOCH='def epoch: if type == "number" then (if . > 1e14 then ./1e9 elif . > 1e11 then ./1e3 else . end | floor)
  else (first(capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2})[T ](?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?\\s*(?<z>Z|[+-][0-9]{2}(:?[0-9]{2})?)?$")) // null)
    | if . == null then null else ((.b + "T" + .t + "Z") | fromdateiso8601) - ((.z // "Z") as $z
        | if $z == "Z" then 0 else (($z[1:3] | tonumber) * 3600 + (if ($z | length) > 3 then ($z[-2:] | tonumber) * 60 else 0 end))
          * (if $z[0:1] == "+" then 1 else -1 end) end) end end;'
TYPES='["sent","delivered","deferred","soft_bounce","hard_bounce","blocked","invalid","error","opened","proxy_open",
  "clicked","spam","unsubscribed"]'

r_auth
EV="$WORK/ev.all"; : > "$EV"; SINCE=0; EV_OK=1
r_fetch || EV_OK=0


if [ "$EV_OK" = "1" ]; then
  # one canonical line per event: epoch s, UTC date d, known types only, inside the window
  jq -c --argjson start "$WINDOW_START" --argjson types "$TYPES" "$EPOCH"'
    (.d | epoch) as $s | select((.m // "") != "" and $s != null and $s >= $start and (.t as $t | $types | index([$t]) != null))
    | {m: (.m // ""), f: (.f // "" | ascii_downcase), e: (.e // "" | ascii_downcase), s: $s, d: ($s | todate),
       t, l: (.l // ""), r: (.r // "" | tostring | .[:500]), i: (.i // "")}' "$EV" > "$WORK/ev.norm" || EV_OK=0
fi
if [ "$EV_OK" = "1" ] && [ "$R_KEEP" = "1" ]; then
  # events of the earlier runs, still in the window
  [ -f "$DATA/events.jsonl" ] && jq -c --argjson start "$WINDOW_START" 'select(.s >= $start)' "$DATA/events.jsonl" >> "$WORK/ev.norm"
  sort -u "$WORK/ev.norm" > "$WORK/ev.keep" && cp "$WORK/ev.keep" "$WORK/ev.norm"
fi
if [ "$EV_OK" = "1" ]; then
  # [date, type] + link (click) or reason (bounce), + IP when kept (extra is then "" if none); our sender domains
  # only (events without sender are kept); events without a usable recipient dropped
  jq -s --argjson gen "$NOW" --argjson days "$EVENT_DAYS" --argjson since "$SINCE" --argjson doms "$DOMAINS_JSON" \
     --argjson ip "$( [ "$INCLUDE_IP" = 1 ] && echo true || echo false )" \
    '{generated: $gen, days: $days} + (if $since > 0 then {since: $since} else {} end) + {
      messages: ( unique | map(select(.m != "" and (.e == "*" or (.e | test("@"))) and (.f == "" or (.f | '"$OURS"')))
          | if $ip then . else .i = "" end)
        | group_by(.m) | map({key: .[0].m, value:
            ( group_by(.e) | map({key: .[0].e, value:
                ( sort_by(.s) | map([.d, .t] + (if .i != "" then [(if .l != "" then .l else .r end), .i]
                                  elif .l != "" then [.l] elif .r != "" then [.r] else [] end)) )})
              | from_entries )})
        | from_entries )}' "$WORK/ev.norm" > "$WORK/events.json" || EV_OK=0
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
        log "geo: data $remote"
      else
        log "geo: download of $remote failed, keeping $(cat "$g/VERSION" 2>/dev/null || echo none)"
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
if [ "$EV_OK" = "1" ]; then
  publish "$WORK/events.json" "$OUT/events.json"
  # accumulated events and cursor, for the next run (a dry run only changes its copy)
  if [ "$R_KEEP" = "1" ]; then
    cp "$WORK/ev.norm" "$DATA/events.jsonl.tmp" && mv -f "$DATA/events.jsonl.tmp" "$DATA/events.jsonl"
  fi
  echo "${CURSOR:-$NOW}" > "$DATA/cursor"
  # the driver's commit step (e.g. removing read messages from a queue), only once the events are stored
  if [ "$DRY" != "1" ] && declare -F r_commit >/dev/null; then r_commit; fi
fi

if [ "$DRY" = "1" ]; then
  mask(){ sed -E 's/"([^"@ ]{1})[^"@ ]*@/"\1***@/g'; }
  for f in relay events; do
    [ -f "$OUT/$f.json" ] && { echo "===== $f.json"; jq -c . "$OUT/$f.json" | mask | head -c 2000; echo; }
  done
fi
exit 0
