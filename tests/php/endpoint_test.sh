#!/usr/bin/env bash
# relay_tracking tests: the open pixel and tracked links over HTTP (PHP built-in server), as a recipient and as the
# sender. Needs php, curl, sqlite3.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
T=$(mktemp -d); trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
export RT_DB="$T/rc.db"
sqlite3 "$RT_DB" "CREATE TABLE users (user_id integer NOT NULL PRIMARY KEY); INSERT INTO users VALUES (1);" \
  && sqlite3 "$RT_DB" < ../../SQL/sqlite.initial.sql || exit 1
TOKEN=0123456789abcdef0123456789abcdef
sqlite3 "$RT_DB" "INSERT INTO relay_tracking_mail VALUES ('$TOKEN', 1, '<m@example.org>',
  '[\"https://example.com/a?x=1&y=2\",\"http://b.test/\"]', datetime('now'))"

PORT=$(( 20000 + RANDOM % 20000 ))
php -S 127.0.0.1:$PORT router.php > "$T/server.log" 2>&1 & SRV=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
U="http://127.0.0.1:$PORT/?_task=relay_tracking"

fail=0
check(){   # name, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     expected: $2"; echo "     got:      $3"; fail=$((fail + 1)); fi
}
req(){ curl -s -o /dev/null -w '%{http_code} %{content_type} %{redirect_url}' "$@"; }
redirect(){ curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$@"; }
hits(){ sqlite3 "$RT_DB" "SELECT group_concat(type || '|' || ifnull(extra, ''), ' ') FROM (SELECT * FROM relay_tracking_hit ORDER BY hit_id)"; }

check 'open right after sending: pixel, automatic' '200 image/gif ' "$(req -A 'Thunderbird/140' "$U&_action=open&_t=$TOKEN")"
sqlite3 "$RT_DB" "UPDATE relay_tracking_mail SET created = datetime('now', '-1 hour')"
check 'later open: pixel' '200 image/gif ' "$(req -A 'Mozilla/5.0 (X11; Linux) Firefox/140' "$U&_action=open&_t=$TOKEN")"
check 'Apple Mail Privacy Protection' '200 image/gif ' "$(req -A 'Mozilla/5.0' "$U&_action=open&_t=$TOKEN")"
check 'click: redirect to the stored link' '302 https://example.com/a?x=1&y=2' "$(redirect "$U&_action=click&_t=$TOKEN&_l=0")"
check 'unknown link number: 404' '404 text/plain; charset=UTF-8 ' "$(req "$U&_action=click&_t=$TOKEN&_l=7")"
check 'link number not a number: 404' '404 text/plain; charset=UTF-8 ' "$(req "$U&_action=click&_t=$TOKEN&_l=0x")"
check 'unknown token click: 404' '404 text/plain; charset=UTF-8 ' "$(req "$U&_action=click&_t=ffffffffffffffffffffffffffffffff&_l=0")"
check 'unknown token open: pixel anyway' '200 image/gif ' "$(req "$U&_action=open&_t=nope")"
check 'pixel is a 1x1 GIF' 'GIF89a' "$(curl -s "$U&_action=open&_t=nope" | head -c 6)"
check 'no cache' 'no-store' "$(curl -s -D - -o /dev/null "$U&_action=open&_t=nope" | tr -d '\r' | sed -n 's/^cache-control: \([^,]*\).*/\1/Ip')"
check 'sender viewing their copy: redirect' '302 http://b.test/' "$(redirect -b as_user=1 "$U&_action=click&_t=$TOKEN&_l=1")"
req -b as_user=1 "$U&_action=open&_t=$TOKEN" > /dev/null
check 'hits recorded (none for the sender)' 'proxy_open| opened| proxy_open| clicked|https://example.com/a?x=1&y=2' "$(hits)"
check 'IP kept with relay_tracking_self_ip' '127.0.0.1' "$(sqlite3 "$RT_DB" 'SELECT DISTINCT ip FROM relay_tracking_hit')"

sqlite3 "$RT_DB" "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600)
  INSERT INTO relay_tracking_hit (token, created, type) SELECT '$TOKEN', datetime('now'), 'opened' FROM n"
before=$(sqlite3 "$RT_DB" 'SELECT COUNT(*) FROM relay_tracking_hit')
req "$U&_action=open&_t=$TOKEN" > /dev/null
check 'no more hits past the limit' "$before" "$(sqlite3 "$RT_DB" 'SELECT COUNT(*) FROM relay_tracking_hit')"

if grep -E 'PHP (Warning|Notice|Deprecated|Fatal)' "$T/server.log"; then echo "FAIL PHP messages in the server log"; fail=$((fail + 1)); fi
[ "$fail" = 0 ] && echo "all passed" || echo "$fail failed"
exit $(( fail > 0 ))
