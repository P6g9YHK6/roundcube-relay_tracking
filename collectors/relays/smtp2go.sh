# relay_tracking driver: SMTP2GO (sourced by relay-collector.sh, see the driver contract there)
#
# Activity search: events of the account since the last run, accumulated in STATE_DIR for the window, with the
# mail's Message-ID header read from the stored headers (custom_headers), so no header is needed.
# Key: API key with access to Activity search (API_KEY_FILE).
# Setting: SMTP2GO_API, regional endpoint (default https://api.smtp2go.com/v3; us-api, eu-api, au-api also exist).
#
# API documentation:
#   Authentication, endpoints  https://developers.smtp2go.com/docs/getting-started
#   Activity search            https://developers.smtp2go.com/reference/search-activity
#   Rate limits                https://developers.smtp2go.com/docs/rate-limiting

R_NAME="SMTP2GO"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=30                      # reporting window (5 days on the free plan without extended reporting)
R_LAG="a few minutes"
API="${SMTP2GO_API:-https://api.smtp2go.com/v3}"

r_auth(){ cfg_header "X-Smtp2go-Api-Key: $KEY"; }

r_fetch(){
  local token="" pages=0
  while :; do
    jq -n --arg s "$(iso "$FROM")" --arg e "$(iso "$NOW")" --arg tok "$token" \
      '{start_date: $s, end_date: $e, limit: 1000, custom_headers: ["Message-ID"],
        event_types: ["processed", "delivered", "soft-bounced", "hard-bounced", "rejected", "spam", "unsubscribed", "opened", "clicked"]}
       + (if $tok != "" then {continue_token: $tok} else {} end)' > "$WORK/s2.req"
    api_ok "/activity/search" "$WORK/page" "$WORK/s2.req" || return 1
    jq -c "$JQ_DEFS"'.data.events[]? | (.custom_headers // {} | to_entries | map(select(.key | ascii_downcase == "message-id")) | .[0].value
          | if type == "array" then .[0] else . end) as $h
      | {m: ($h | mid), f: (.sender // .from // "" | (capture("<(?<a>[^>]+)>").a // .)), e: (.recipient // ""), d: .date,
         t: ({"processed": "sent", "delivered": "delivered", "soft-bounced": "soft_bounce", "hard-bounced": "hard_bounce",
              "rejected": "blocked", "spam": "spam", "unsubscribed": "unsubscribed", "opened": "opened", "clicked": "clicked"}[.event]
             // "other"),
         l: (if .event == "clicked" then (.metadata.url // .metadata.link // .url // "") else "" end),
         r: (if (.event | IN("soft-bounced", "hard-bounced", "rejected")) then (.reason // .smtp_response // .error // "") else "" end),
         i: (if (.event | IN("opened", "clicked")) then (.host // "") else "" end)}' "$WORK/page" >> "$EV"
    token=$(jq -r '.data.continue_token // ""' "$WORK/page")
    pages=$(( pages + 1 ))
    [ -z "$token" ] && break
    if [ "$pages" -ge 50 ]; then
      # order not documented: the next run reads the same period again
      CURSOR=$(( FROM + ${R_OVERLAP:-7200} ))
      log "activity: stopped after $pages pages"; break
    fi
    sleep 1                    # 60 requests per minute
  done
}
