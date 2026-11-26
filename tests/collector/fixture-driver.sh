# shellcheck shell=bash disable=SC2034,SC2154
# relay_tracking tests: relay driver reading its events from $FIXTURE_EVENTS (see the driver contract in
# relay-collector.sh). Copied next to the real drivers by collector_test.sh, never installed.
R_NAME="Fixture relay"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=30
R_LAG="a minute"
R_HEADERS='{"X-Fixture-Mid": "{message_id}"}'

r_auth(){ cfg_header "x-key: $KEY"; }

r_fetch(){
  [ -r "$FIXTURE_EVENTS" ] || return 1
  # dates relative to the test's start (FIXTURE_NOW), so they stay inside the window and the same in every run:
  # d = seconds ago
  jq -c --argjson now "${FIXTURE_NOW:-$NOW}" '.d = ($now - .d)' "$FIXTURE_EVENTS" >> "$EV"
}
