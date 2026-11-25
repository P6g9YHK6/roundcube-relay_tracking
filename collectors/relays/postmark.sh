# relay_tracking driver: Postmark (sourced by relay-collector.sh, see the driver contract there)
#
# Postmark replaces the Message-ID over SMTP, so the plugin adds the mail's Message-ID as metadata (X-PM-Metadata-rt-mid,
# removed by Postmark before delivery). Each run searches the outbound messages of the window, keeps those carrying
# that metadata, and reads the events of each one (delivery, bounce, open, click, unsubscribe), again every run the
# first day, hourly the first week and daily after. With INCLUDE_IP=1 the IP of the first open and of the clicks.
# Key: Server API token of the server the mail goes through (API_KEY_FILE).
# Setting: POSTMARK_STREAM (default "outbound"), the message stream used for SMTP.
#
# API documentation:
#   Authentication          https://postmarkapp.com/developer/api/overview#authentication
#   Outbound message search https://postmarkapp.com/developer/api/messages-api#outbound-message-search
#   Message details         https://postmarkapp.com/developer/api/messages-api#outbound-message-details
#   Opens / clicks          https://postmarkapp.com/developer/api/messages-api#opens-for-message
#                           https://postmarkapp.com/developer/api/messages-api#clicks-for-message
#   Bounce types            https://postmarkapp.com/developer/api/bounce-api#bounce-types
#   SMTP metadata headers   https://postmarkapp.com/developer/user-guide/send-email-with-smtp
#                           https://postmarkapp.com/support/article/1125-custom-metadata-faq

R_NAME="Postmark"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=45                      # default retention (7 to 365 days on request: raise EVENT_DAYS with it)
[ -n "${EVENT_DAYS:-}" ] && [ "$EVENT_DAYS" -gt 45 ] 2>/dev/null && R_DAYS=$EVENT_DAYS
R_LAG="a few minutes"
R_HEADERS='{"X-PM-Metadata-rt-mid": "{message_id}"}'
API="https://api.postmarkapp.com"
PM_MAX=10000                   # search limit (count + offset)

r_auth(){ cfg_header "X-Postmark-Server-Token: $KEY"; }

r_fetch(){
  # the API reads dates in US Eastern time
  local from; from=$(TZ=America/New_York date -d "@$WINDOW_START" +%Y-%m-%dT%H:%M:%S)
  local stream; stream=$(uri "${POSTMARK_STREAM:-outbound}")
  local off=0 total id mid rcvd stamp
  : > "$WORK/pm.list"
  while :; do
    api_ok "/messages/outbound?count=500&offset=$off&fromdate=$(uri "$from")&messagestream=$stream" "$WORK/page" || return 1
    # ours: carries the plugin's metadata and comes from DOMAINS
    jq -c --argjson doms "$DOMAINS_JSON" '.Messages[] | select((.Metadata["rt-mid"] // "") != "")
      | select(.From | (capture("<(?<a>[^>]+)>").a // .) | '"$OURS"')
      | {id: .MessageID, mid: .Metadata["rt-mid"], at: .ReceivedAt, from: .From, to: .Recipients}' "$WORK/page" >> "$WORK/pm.list"
    total=$(jq '.TotalCount // 0' "$WORK/page")
    off=$(( off + 500 ))
    [ "$off" -ge "$total" ] && break
    if [ "$off" -ge "$PM_MAX" ]; then
      SINCE=$(jq -rs 'map(.at) | min // empty' "$WORK/pm.list" | xargs -r -I{} date -d {} +%s)
      log "messages: stopped after $PM_MAX of $total"
      break
    fi
  done

  while IFS=$'\t' read -r id rcvd; do
    stamp=$(mc_age_stamp "$(date -d "$rcvd" +%s)")
    if mc_fresh "$id" "$stamp"; then continue; fi
    pm_message "$id" || continue
    mc_put "$id" "$stamp" < "$WORK/pm.ev"
  done < <(jq -r '[.id, .at] | @tsv' "$WORK/pm.list")
  mc_all >> "$EV"
}

# events of one message > $WORK/pm.ev
pm_message(){
  local id="$1" b
  api_ok "/messages/outbound/$id/details" "$WORK/pm.d" || return 1
  # bounce types (hard, soft, spam complaint...) are only in the Bounce API
  echo '{}' > "$WORK/pm.bt"
  for b in $(jq -r '.MessageEvents[] | select(.Type == "Bounced") | .Details.BounceID // empty' "$WORK/pm.d" | tr -cd '0-9\n'); do
    api_ok "/bounces/$b" "$WORK/pm.b" && jq --arg b "$b" --slurpfile x "$WORK/pm.b" '. + {($b): $x[0].Type}' "$WORK/pm.bt" > "$WORK/pm.bt2" \
      && mv "$WORK/pm.bt2" "$WORK/pm.bt"
  done
  # IPs: the first open and every click, matched to the details by recipient and date
  echo '{"Opens": [], "Clicks": []}' > "$WORK/pm.o"; cp "$WORK/pm.o" "$WORK/pm.c"
  if [ "$INCLUDE_IP" = "1" ]; then
    api_ok "/messages/outbound/opens/$id?count=500&offset=0" "$WORK/pm.o" || echo '{"Opens": []}' > "$WORK/pm.o"
    api_ok "/messages/outbound/clicks/$id?count=500&offset=0" "$WORK/pm.c" || echo '{"Clicks": []}' > "$WORK/pm.c"
  fi
  jq -c --slurpfile bt "$WORK/pm.bt" --slurpfile o "$WORK/pm.o" --slurpfile c "$WORK/pm.c" "$JQ_DEFS"'
    ([$o[0].Opens[]?, $c[0].Clicks[]?] | map({key: ((.Recipient // "" | ascii_downcase) + " " + .ReceivedAt), value: (.Geo.IP // "")})
      | from_entries) as $ips
    | . as $msg | (.Metadata["rt-mid"] | mid) as $m | (.From | (capture("<(?<a>[^>]+)>").a // .)) as $f
    | ( (.Recipients[]? | {m: $m, f: $f, e: ., d: $msg.ReceivedAt, t: "sent"}),
        (.MessageEvents[] | (.Details // {}) as $x
          | {m: $m, f: $f, e: .Recipient, d: .ReceivedAt,
             i: ($ips[(.Recipient // "" | ascii_downcase) + " " + .ReceivedAt] // ""),
             t: (if .Type == "Delivered" then "delivered"
                 elif .Type == "Transient" then "deferred"
                 elif .Type == "Bounced" then ({"HardBounce": "hard_bounce", "SoftBounce": "soft_bounce",
                     "Transient": "deferred", "DnsError": "soft_bounce", "SpamComplaint": "spam", "SpamNotification": "spam",
                     "Blocked": "blocked", "BadEmailAddress": "invalid", "ManuallyDeactivated": "blocked",
                     "Unsubscribe": "unsubscribed", "AddressChange": "hard_bounce", "ChallengeVerification": "soft_bounce",
                     "AutoResponder": "other", "Unknown": "hard_bounce"}[$bt[0][$x.BounceID // ""] // "Unknown"] // "hard_bounce")
                 elif .Type == "Opened" then (if ($x.Summary // "" | test("proxy"; "i")) then "proxy_open" else "opened" end)
                 elif .Type == "LinkClicked" then "clicked"
                 elif .Type == "SubscriptionChanged" and $x.Origin == "Recipient" and $x.SuppressSending == "True" then "unsubscribed"
                 else "other" end),
             l: (if .Type == "LinkClicked" then ($x.Link // "") else "" end),
             r: (if .Type == "Bounced" or .Type == "Transient" then ($x.Summary // $x.DeliveryMessage // "") else "" end)}) )' \
    "$WORK/pm.d" > "$WORK/pm.ev"
}
