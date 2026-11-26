# relay_tracking driver: Mailgun (sourced by relay-collector.sh, see the driver contract there)
#
# Logs API (the Events API is deprecated): events of the whole account since the last run, accumulated in STATE_DIR
# for the window. The plugin adds the mail's Message-ID as a custom variable (X-Mailgun-Variables, removed by Mailgun
# before delivery); the Message-ID header Mailgun reports is used when the variable is missing.
# Key: API key, read access to the logs (API_KEY_FILE).
# Setting: MAILGUN_REGION ("us", default, or "eu"), where the sending domains live.
#
# API documentation:
#   Base URLs and authentication  https://documentation.mailgun.com/docs/mailgun/api-reference/api-overview
#   Logs API                      https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/logs
#                                 https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/logs/post-v1-analytics-logs
#   Event types                   https://documentation.mailgun.com/docs/mailgun/user-manual/events/

R_NAME="Mailgun"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=30                      # depends on the plan (1 day on the free plan): set EVENT_DAYS to it
R_LAG="a few minutes"
R_HEADERS='{"X-Mailgun-Variables": "{\"rt_mid\": \"{message_id}\"}"}'
case "${MAILGUN_REGION:-us}" in
  eu) API="https://api.eu.mailgun.net" ;;
  *)  API="https://api.mailgun.net" ;;
esac

r_auth(){ cfg_user "api:$KEY"; }

r_fetch(){
  local token="" pages=0 hours=$(( (NOW - FROM) / 3600 + 1 ))
  while :; do
    jq -n --arg start "$(date -u -R -d "@$FROM")" --arg end "$(date -u -R -d "@$NOW")" --arg dur "${hours}h" --arg tok "$token" \
      '{start: $start, end: $end, duration: $dur,
        events: ["accepted", "delivered", "failed", "rejected", "opened", "clicked", "unsubscribed", "complained"],
        pagination: ({sort: "timestamp:asc", limit: 100} + (if $tok != "" then {token: $tok} else {} end))}' > "$WORK/mg.req"
    api_ok "/v1/analytics/logs" "$WORK/page" "$WORK/mg.req" || return 1
    jq -c "$JQ_DEFS"'.items[]? | (.["user-variables"] // {} | if type == "string" then (try fromjson catch {}) else . end) as $v
      | (.message.headers // {}) as $h | (.["delivery-status"] // {}) as $ds
      | {m: ((if ($v | type) == "object" then $v.rt_mid else null end) // $h["message-id"] | mid),
         f: ($h.from // "" | (capture("<(?<a>[^>]+)>").a // .)),
         e: (.recipient // ""), d: (.["@timestamp"] // .timestamp),
         t: (if .event == "accepted" then "sent"
             elif .event == "delivered" then "delivered"
             elif .event == "failed" then (if .severity == "temporary" then "deferred"
                                          elif (.reason // "" | startswith("suppress")) then "blocked" else "hard_bounce" end)
             elif .event == "rejected" then "blocked"
             elif .event == "opened" then "opened"
             elif .event == "clicked" then "clicked"
             elif .event == "unsubscribed" then "unsubscribed"
             elif .event == "complained" then "spam" else "other" end),
         l: (if .event == "clicked" then (.url // "") else "" end),
         r: (if .event == "failed" or .event == "rejected" then ($ds.message // $ds.description // .reason // "") else "" end),
         i: (if (.event | IN("opened", "clicked", "unsubscribed", "complained")) then (.ip // "") else "" end)}' \
      "$WORK/page" >> "$EV"
    token=$(jq -r '.pagination.next // ""' "$WORK/page")
    pages=$(( pages + 1 ))
    [ -z "$token" ] || [ "$(jq '.items | length' "$WORK/page")" -lt 100 ] && break
    if [ "$pages" -ge 300 ]; then
      # the next run goes on from the last event read
      CURSOR=$(tail -n 1 "$EV" | jq -r '.d' | xargs -r -I{} date -d {} +%s); CURSOR=$(( ${CURSOR:-$NOW} + ${R_OVERLAP:-7200} ))
      log "logs: stopped after $pages pages"; break
    fi
  done
}
