#!/usr/bin/env bash
# relay_tracking tests: tools/dbip-convert.py on small DB-IP samples, then a full collector run with a fixture relay
# and those files as the geoip branch (GEO_URL=file://), checking relay.json and events.json.
# Needs bash 4+, python3, jq, curl, xz, flock, GNU date.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fail=0
check(){   # name, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     expected: $2"; echo "     got:      $3"; fail=$((fail + 1)); fi
}

# ------------------------------------------------------------------ converter
gzip -c "$HERE/dbip-city.csv" > "$T/city.csv.gz"; gzip -c "$HERE/dbip-asn.csv" > "$T/asn.csv.gz"
python3 -I "$ROOT/tools/dbip-convert.py" city "$T/city.csv.gz" "$T/branch" \
  && python3 -I "$ROOT/tools/dbip-convert.py" asn "$T/asn.csv.gz" "$T/branch" || { echo "FAIL converter"; exit 1; }
check 'city ranges (gaps get id 0, reserved range unknown)' \
  "$(printf '401000000\t1\n401000100\t2\n401000400\t0\n40a000000\t0\n40b000000\t0\n62a001450000000000000000000000000\t3\n62a001451000000000000000000000000\t0')" \
  "$(cat "$T/branch/ranges.tsv")"
check 'city locations' "$(printf '0\t\t\t\n1\tAU\tQueensland\tSouth Brisbane\n2\tCN\tFujian\tWenquan\n3\tGB\tEngland\tLondon')" \
  "$(cat "$T/branch/locations.tsv")"
check 'asn ranges' "$(printf '401000000\t13335\n401000100\t0\n401000400\t38803\n401000800\t0\n62a001450000000000000000000000000\t15169\n62a001451000000000000000000000000\t0')" \
  "$(cat "$T/branch/asn-ranges.tsv")"
check 'asn names' "$(printf '0\t\n13335\tCloudflare, Inc.\n15169\tGoogle LLC\n38803\tGtelecom Pty Ltd')" "$(cat "$T/branch/asn-names.tsv")"
check 'usage error' '1' "$(python3 -I "$ROOT/tools/dbip-convert.py" country x y 2>/dev/null; echo $?)"
xz -T0 "$T"/branch/*.tsv && echo "2026-01 test" > "$T/branch/VERSION"

# ------------------------------------------------------------------ collector
C="$T/collector"; mkdir -p "$C"
cp "$ROOT/collectors/relay-collector.sh" "$C/" && cp -r "$ROOT/collectors/relays" "$C/" && cp "$HERE/fixture-driver.sh" "$C/relays/fixture.sh"
echo 'secret-key' > "$T/key"; chmod 600 "$T/key"
conf(){   # extra settings...
  { echo "RELAY=fixture"; echo "RELAY_DIR=$T/data/fixture"; echo 'DOMAINS="example.org"'; echo "API_KEY_FILE=$T/key"
    echo "STATE_DIR=$T/state"; echo "GEO_URL=file://$T/branch"; echo "FIXTURE_EVENTS=$HERE/events.jsonl"
    printf '%s\n' "$@"; } > "$T/c.conf"
  chmod 600 "$T/c.conf"
}
run(){ bash "$C/relay-collector.sh" "$T/c.conf" 2> "$T/log"; }
E="$T/data/fixture/events.json"

conf 'INCLUDE_IP=0'
run; check 'run without IPs' '0' "$?"
check 'relay.json' '{"format":1,"id":"fixture","name":"Fixture relay","domains":["example.org"],"capabilities":["events","opens","clicks"],"lag":"a minute","headers":{"X-Fixture-Mid":"{message_id}"}}' \
  "$(jq -c '{format, id, name, domains, capabilities, lag, headers}' "$T/data/fixture/relay.json")"
check 'only our domains, events without sender kept' '["<one@example.org>","<two@example.org>"]' "$(jq -c '.messages | keys' "$E")"
check 'events outside the window dropped' 'false' "$(jq '.messages | has("<old@example.org>")' "$E")"
check 'events per recipient, in date order' '["sent","delivered","opened","clicked"]' "$(jq -c '[.messages["<one@example.org>"]["a@x.test"][][1]]' "$E")"
check 'bounce reason' '"no such user"' "$(jq -c '.messages["<one@example.org>"]["b@x.test"][0][2]' "$E")"
check 'no IPs without INCLUDE_IP' '[]' "$(jq -c '[.messages[][][] | select(length == 4)]' "$E")"
check 'no hosts without INCLUDE_IP' 'null' "$(jq -c '.hosts' "$E")"
check 'output readable by Roundcube' '644 755' "$(stat -c %a "$E") $(stat -c %a "$T/data/fixture")"

conf 'INCLUDE_IP=1' 'IP_GEO=1'
run; check 'run with owners (default) and locations' '0' "$?"
check 'IP kept' '["", "1.0.0.7"]' "$(jq -c '.messages["<one@example.org>"]["a@x.test"][2][2:]' "$E" | sed 's/,/, /')"
check 'owner and location from the local data' '{"rdns":"","provider":"Cloudflare, Inc.","country":"AU","region":"Queensland","city":"South Brisbane"}' \
  "$(jq -c '.hosts["1.0.0.7"]' "$E")"
check 'IPv6' '{"rdns":"","provider":"Google LLC","country":"GB","region":"England","city":"London"}' "$(jq -c '.hosts["2a00:1450::5"]' "$E")"
check 'private network' '{"rdns":"","provider":"private network","country":"","region":"","city":""}' "$(jq -c '.hosts["10.1.2.3"]' "$E")"
check 'unknown IP left out' 'null' "$(jq -c '.hosts["9.9.9.9"]' "$E")"
check 'geo data downloaded' "$(printf 'VERSION\nasn-names.tsv.xz\nasn-ranges.tsv.xz\nlocations.tsv.xz\nranges.tsv.xz')" "$(cd "$T/state/geo" && LC_ALL=C ls)"
check 'lookups cached' '4 4' "$(wc -l < "$T/state/ipasn.tsv") $(wc -l < "$T/state/ipgeo.tsv")"

conf 'INCLUDE_IP=1' 'IP_ASN=0'
rm -rf "$T/state/geo"
run; check 'owners off' 'null' "$(jq -c '.hosts["1.0.0.7"]' "$E")"
check 'nothing downloaded when off' '' "$(find "$T/state" -name '*.xz')"

conf 'INCLUDE_IP=1'
DRY_RUN=1 bash "$C/relay-collector.sh" "$T/c.conf" > "$T/dry" 2>&1
check 'dry run writes nothing' 'null' "$(jq -c '.hosts["1.0.0.7"]' "$E")"
check 'dry run shows masked output' 'true' "$(grep -qF '"a***@x.test"' "$T/dry" && echo true || echo false)"

chmod 666 "$T/c.conf"
check 'refuses a settings file others can write' '1' "$(bash "$C/relay-collector.sh" "$T/c.conf" 2>/dev/null; echo $?)"

[ "$fail" = 0 ] && echo "all passed" || { echo "$fail failed"; echo "--- collector log"; cat "$T/log"; }
exit $(( fail > 0 ))
