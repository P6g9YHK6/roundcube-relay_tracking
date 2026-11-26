#!/usr/bin/env bash
# relay_tracking tests: the geoip branch is on DB-IP's latest monthly City and ASN Lite files, built by the current
# converter, with every file the collectors download. Run daily after the geoip workflow; a failure means that workflow
# did not run or failed.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
check(){ if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }

git fetch -q origin geoip || { echo "FAIL no geoip branch"; exit 1; }
have=$(git show origin/geoip:VERSION)
latest=""
for m in "$(date -u +%Y-%m)" "$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m)"; do
  mod=$(curl -sfI -m 30 "https://download.db-ip.com/free/dbip-city-lite-$m.csv.gz" | tr -d '\r' | sed -n 's/^last-modified: //Ip')
  if [ -n "$mod" ] && curl -sfI -m 30 "https://download.db-ip.com/free/dbip-asn-lite-$m.csv.gz" > /dev/null; then
    latest="$m $mod"; break
  fi
done
[ -n "$latest" ] || { echo "FAIL DB-IP unreachable"; exit 1; }
check 'DB-IP release on the branch' "$latest" "${have% *}"
check 'built by the current converter' "$(sha256sum tools/dbip-convert.py | cut -c1-8)" "${have##* }"
for f in ranges.tsv.xz locations.tsv.xz asn-ranges.tsv.xz asn-names.tsv.xz; do
  size=$(git cat-file -s "origin/geoip:$f" 2>/dev/null || echo 0)
  check "$f present" yes "$( [ "$size" -gt 100000 ] && echo yes || echo "size $size")"
done
[ "$fail" = 0 ] && echo "all passed" || echo "$fail failed"
exit $(( fail > 0 ))
