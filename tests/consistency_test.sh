#!/usr/bin/env bash
# relay_tracking tests: things that drift apart silently. Same labels in every language, every label the code uses
# exists, versions agree, every relay has a driver and a README row, no em dash anywhere.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
check(){ if [ -z "$2" ]; then echo "ok   $1"; else echo "FAIL $1"; printf '     %s\n' $2; fail=$((fail + 1)); fi; }
keys(){ grep -oP "^\\\$labels\['\K\w+" "$1" | sort; }

for f in localization/*.inc; do
  check "same labels in $f as in en_US" "$(diff <(keys localization/en_US.inc) <(keys "$f") | grep '^[<>]' | tr -d '<> ')"
done
# literal labels, preferences, and one ev_ label per event type the box shows (proxy_open is shown as opened)
types=$(sed -n '/^- Event types:/,/others are ignored/p' README.md | tr '\n' ' ' | sed 's/; others.*//' \
  | grep -oP '`\K[a-z_]+(?=`)' | grep -vx proxy_open)
check 'event types found in the README' "$( [ "$(echo "$types" | wc -l)" -ge 10 ] || echo "only: $types")"
used=$( { grep -oP "label\('\K\w+(?='\))" relay_tracking.js
          grep -oP "gettext\('\K\w+(?='\))" relay_tracking.php
          echo "$types" | sed 's/^/ev_/'
          grep -oP "relay_tracking_\K(show_\w+|self_track)(?=')" relay_tracking.php | sed 's/^/pref_/'; } | sort -u)
check 'every label used exists' "$(comm -23 <(echo "$used") <(keys localization/en_US.inc))"

v=$(grep -oP "'version' => '\K[0-9.]+" relay_tracking.php)
check "CHANGELOG starts with $v" "$(head -5 CHANGELOG.md | grep -q "^## $v " || echo "top entry is not $v")"

drivers=$(cd collectors/relays && ls *.sh | sed 's/\.sh$//' | sort)
listed=$(grep -oP '^\| `RELAY` +\| required +\| relay: \K.*?(?= *\|$)' README.md | grep -oP '`\K[a-z0-9_-]+' | sort)
check 'README lists every driver' "$(diff <(echo "$drivers") <(echo "$listed") | grep '^[<>]' | tr -d '<> ')"

check 'no em dash' "$(git ls-files | grep -vE '\.(png|gz|xz)$' | xargs grep -l $'\xe2\x80\x94' 2>/dev/null)"
check 'composer.json is valid JSON' "$(python3 -c 'import json; json.load(open("composer.json"))' 2>&1)"

[ "$fail" = 0 ] && echo "all passed" || echo "$fail failed"
exit $(( fail > 0 ))
