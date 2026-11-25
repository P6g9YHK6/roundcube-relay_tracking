# relay_tracking driver: Mailjet (sourced by relay-collector.sh, see the driver contract there)
#
# The plugin tags each mail with its Message-ID as Mailjet custom ID (X-MJ-CustomID). Each run lists the messages of
# the window (one per recipient at Mailjet) and reads the history of each one of ours, again when its status changes
# and otherwise every run the first day, hourly the first week and daily after. Mailjet gives neither the clicked link
# nor the IP of an event.
# Key: "API_KEY:SECRET_KEY" in API_KEY_FILE.
#
# API documentation:
#   Authentication            https://dev.mailjet.com/email/guides/
#   Messages and history      https://dev.mailjet.com/email/reference/messages/
#                             https://dev.mailjet.com/openapi/openapi-mailjet/messages/get_v3_message
#                             https://dev.mailjet.com/openapi/openapi-mailjet/messages/get_v3_messagehistory_id
#   SMTP custom ID header     https://dev.mailjet.com/smtp-relay/custom-headers/

R_NAME="Mailjet"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=30
R_LAG="a few minutes"
R_HEADERS='{"X-MJ-CustomID": "{message_id}"}'
API="https://api.mailjet.com/v3/REST"
MJ_PAGE=1000

r_auth(){ cfg_user "$KEY"; }

r_fetch(){
  local off=0 n id st at
  : > "$WORK/mj.list"
  while :; do
    api_ok "/message?FromTS=$WINDOW_START&FromType=1&ShowCustomID=true&ShowContactAlt=true&Limit=$MJ_PAGE&Offset=$off" "$WORK/page" || return 1
    jq -c '.Data[] | select((.CustomID // "") | startswith("<"))' "$WORK/page" >> "$WORK/mj.list"
    n=$(jq '.Data | length' "$WORK/page")
    [ "$n" -lt "$MJ_PAGE" ] && break
    off=$(( off + MJ_PAGE ))
    [ "$off" -ge 50000 ] && { log "messages: stopped after $off"; break; }
  done
  while IFS=$'\t' read -r id st at; do
    st="$st $(mc_age_stamp "$(date -d "$at" +%s 2>/dev/null || echo "$NOW")")"
    mc_fresh "$id" "$st" && continue
    api_ok "/messagehistory/$id" "$WORK/mj.h" || continue
    jq -c --argjson msg "$(jq -c --arg id "$id" 'select((.ID | tostring) == $id)' "$WORK/mj.list" | head -n 1)" "$JQ_DEFS"'
      ($msg.CustomID | mid) as $m | ($msg.ContactAlt // "") as $e
      | (if ($msg.ArrivedAt // "") != "" then {m: $m, e: $e, d: $msg.ArrivedAt, t: "sent"} else empty end),
        (.Data[] | {m: $m, e: $e, d: .EventAt,
          t: ({"sent": "delivered", "opened": "opened", "clicked": "clicked", "blocked": "blocked", "unsub": "unsubscribed",
               "spam": "spam"}[.EventType]
              // (if .EventType == "bounced" then (if $msg.StatePermanent then "hard_bounce" else "soft_bounce" end) else "other" end)),
          r: ([.State // "", .Comment // ""] | map(select(. != "")) | join(": "))})' "$WORK/mj.h" \
      | mc_put "$id" "$st"
  done < <(jq -r '[(.ID | tostring), (.Status // ""), (.ArrivedAt // "")] | @tsv' "$WORK/mj.list")
  mc_all >> "$EV"
}
