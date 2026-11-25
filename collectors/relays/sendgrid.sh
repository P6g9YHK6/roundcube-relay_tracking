# relay_tracking driver: Twilio SendGrid (sourced by relay-collector.sh, see the driver contract there)
#
# Email Activity API (paid "additional email activity history" add-on). The plugin adds the mail's Message-ID as a
# unique argument (X-SMTPAPI header, removed by SendGrid before delivery). Each run lists the messages with an event
# since the last run, and reads the events of each one of ours whose last event changed.
# Key: API key with Email Activity access (API_KEY_FILE).
#
# API documentation:
#   Getting started, query syntax  https://www.twilio.com/docs/sendgrid/for-developers/sending-email/getting-started-email-activity-api
#   Filter all messages            https://www.twilio.com/docs/sendgrid/api-reference/email-activity/filter-all-messages
#   Message by id (events)         https://www.twilio.com/docs/sendgrid/api-reference/email-activity/filter-messages-by-message-id
#   X-SMTPAPI unique_args          https://www.twilio.com/docs/sendgrid/for-developers/sending-email/building-an-x-smtpapi-header

R_NAME="SendGrid"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=30                      # activity history of the add-on
R_LAG="a few minutes"
R_HEADERS='{"X-SMTPAPI": "{\"unique_args\": {\"rt_mid\": \"{message_id}\"}}"}'
API="https://api.sendgrid.com/v3"
SG_LIMIT=1000                  # API maximum per query, without paging: a full answer splits the period in two

r_auth(){ cfg_header "Authorization: Bearer $KEY"; }

# messages with an event between $1 and $2 (epoch) >> $WORK/sg.list
sg_list(){
  local a="$1" b="$2" q n mid
  q="last_event_time BETWEEN TIMESTAMP \"$(date -u -d "@$a" +%Y-%m-%dT%H:%M:%S.000Z)\" AND TIMESTAMP \"$(date -u -d "@$b" +%Y-%m-%dT%H:%M:%S.000Z)\""
  api_ok "/messages?limit=$SG_LIMIT&query=$(uri "$q")" "$WORK/page" || return 1
  n=$(jq '.messages | length' "$WORK/page")
  if [ "$n" -ge "$SG_LIMIT" ] && [ $(( b - a )) -gt 60 ]; then
    mid=$(( (a + b) / 2 ))
    sg_list "$a" "$mid" && sg_list "$mid" "$b"; return
  fi
  jq -c --argjson doms "$DOMAINS_JSON" '.messages[] | select(.from_email | '"$OURS"') | {id: .msg_id, st: (.last_event_time + " " + .status)}' \
    "$WORK/page" >> "$WORK/sg.list"
}

r_fetch(){
  local id st
  : > "$WORK/sg.list"
  sg_list "$FROM" "$NOW" || return 1
  while IFS=$'\t' read -r id st; do
    mc_fresh "$id" "$st" && continue
    api_ok "/messages/$(uri "$id")" "$WORK/sg.d" || continue
    # unique_args comes as a string holding a JSON-like hash (single quotes in the documentation's example)
    jq -c "$JQ_DEFS"'((.unique_args // "") | tostring | (capture("rt_mid[\"'"'"']\\s*:\\s*[\"'"'"'](?<v>[^\"'"'"']+)").v // "") | mid) as $m
      | select($m != "") | .from_email as $f | .to_email as $e
      | .events[]? | {m: $m, f: $f, e: $e, d: .processed,
          t: ({"processed": "sent", "delivered": "delivered", "deferred": "deferred", "dropped": "blocked",
               "opened": "opened", "clicked": "clicked", "spam_report": "spam", "unsubscribe": "unsubscribed",
               "group_unsubscribe": "unsubscribed"}[.event_name]
              // (if .event_name == "bounced" then (if .bounce_type == "soft" then "soft_bounce" else "hard_bounce" end) else "other" end)),
          l: (if .event_name == "clicked" then (.url // "") else "" end), r: (.reason // "")}' "$WORK/sg.d" \
      | mc_put "$id" "$st"
  done < <(jq -r '[.id, .st] | @tsv' "$WORK/sg.list" | sort -u)
  mc_all >> "$EV"
}
