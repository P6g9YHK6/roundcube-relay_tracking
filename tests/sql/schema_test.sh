#!/usr/bin/env bash
# relay_tracking tests: SQL/<engine>.initial.sql in a real database, with the queries the plugin runs and the cascades
# from Roundcube's users table.
#   schema_test.sh sqlite | mysql | postgres
# mysql: MYSQL_HOST/MYSQL_PWD (root, database rc); postgres: PGHOST/PGUSER/PGPASSWORD (database rc).
set -uo pipefail
ENGINE="${1:?sqlite, mysql or postgres}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

case "$ENGINE" in
  sqlite)   sql(){ sqlite3 -batch -bail "$T/rc.db" "PRAGMA foreign_keys = ON; $1"; }
            USERS="CREATE TABLE users (user_id integer NOT NULL PRIMARY KEY);" ;;
  mysql)    sql(){ mysql -h "${MYSQL_HOST:-127.0.0.1}" -u root -N -B rc -e "$1"; }
            sql "DROP TABLE IF EXISTS relay_tracking_hit, relay_tracking_mail, users"
            USERS="CREATE TABLE users (user_id int(10) UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY) ENGINE=INNODB;" ;;
  postgres) sql(){ psql -X -q -t -A -v ON_ERROR_STOP=1 -d rc -c "$1"; }
            sql "DROP TABLE IF EXISTS relay_tracking_hit, relay_tracking_mail, users; DROP SEQUENCE IF EXISTS relay_tracking_hit_seq"
            USERS="CREATE TABLE users (user_id serial PRIMARY KEY);" ;;
  *) echo "unknown engine $ENGINE" >&2; exit 2 ;;
esac

fail=0
check(){ if [ "$2" = "$3" ]; then echo "ok   $ENGINE: $1"; else echo "FAIL $ENGINE: $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }

sql "$USERS INSERT INTO users (user_id) VALUES (1), (2);" || exit 1
sql "$(cat "$ROOT/SQL/$ENGINE.initial.sql")"; check 'schema loads' 0 "$?"

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
sql "INSERT INTO relay_tracking_mail (token, user_id, message_id, links, created) VALUES
  ('$A', 1, '<a@example.org>', '[\"https://e.test/\"]', '2026-01-01 10:00:00'),
  ('$B', 2, '<b@example.org>', '[]', '2025-01-01 10:00:00')"
check 'insert mails' 0 "$?"
sql "INSERT INTO relay_tracking_hit (token, created, type, extra, ip) VALUES
  ('$A', '2026-01-01 10:05:00', 'opened', NULL, '2001:db8::1'),
  ('$A', '2026-01-01 10:01:00', 'clicked', 'https://e.test/', NULL),
  ('$B', '2025-01-01 11:00:00', 'opened', NULL, NULL)"
check 'insert hits (ids generated)' 0 "$?"
check 'duplicate token refused' 'refused' "$(sql "INSERT INTO relay_tracking_mail (token, user_id, message_id, links, created) VALUES ('$A', 1, 'x', '[]', '2026-01-01 00:00:00')" >/dev/null 2>&1 && echo accepted || echo refused)"
check 'hit for an unknown mail refused' 'refused' "$(sql "INSERT INTO relay_tracking_hit (token, created, type) VALUES ('cccccccccccccccccccccccccccccccc', '2026-01-01 00:00:00', 'opened')" >/dev/null 2>&1 && echo accepted || echo refused)"

# the plugin's queries
check 'mail of a user by Message-ID' "$A" "$(sql "SELECT token FROM relay_tracking_mail WHERE user_id = 1 AND message_id = '<a@example.org>'")"
check 'hits in date order' "$(printf 'clicked\nopened')" "$(sql "SELECT type FROM relay_tracking_hit WHERE token = '$A' ORDER BY created, hit_id")"
check 'hit count' 2 "$(sql "SELECT COUNT(*) AS n FROM relay_tracking_hit WHERE token = '$A'")"
sql "DELETE FROM relay_tracking_hit WHERE token IN (SELECT token FROM relay_tracking_mail WHERE created < '2025-06-01 00:00:00')" \
  && sql "DELETE FROM relay_tracking_mail WHERE created < '2025-06-01 00:00:00'"
check 'cleanup of old mails' "1 2" "$(sql "SELECT COUNT(*) FROM relay_tracking_mail") $(sql "SELECT COUNT(*) FROM relay_tracking_hit")"

# Roundcube deleting a user takes their tracking with it
sql "DELETE FROM users WHERE user_id = 1"
check 'user deletion cascades' "0 0" "$(sql "SELECT COUNT(*) FROM relay_tracking_mail") $(sql "SELECT COUNT(*) FROM relay_tracking_hit")"

[ "$fail" = 0 ] && echo "all passed" || echo "$fail failed"
exit $(( fail > 0 ))
