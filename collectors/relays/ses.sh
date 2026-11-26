# relay_tracking driver: Amazon SES (sourced by relay-collector.sh, see the driver contract there)
#
# SES has no event history to poll (outside the paid VDM): it publishes each event, here through an SNS topic to an
# SQS queue that this driver empties, so the events are accumulated in STATE_DIR for the window. Each event carries
# the original headers of the mail, Message-ID included, so no header is needed.
# Set up once in AWS: an SQS queue, an SNS topic subscribed to it, and a configuration set with an event destination
# to that topic for Send, Delivery, Bounce, Complaint, Reject, DeliveryDelay, Open, Click and Subscription; make it the
# default configuration set of the sending identities (or have the mail server add X-SES-CONFIGURATION-SET).
# Key: "ACCESS_KEY_ID:SECRET_ACCESS_KEY" in API_KEY_FILE, of an IAM user allowed sqs:ReceiveMessage and
# sqs:DeleteMessage on the queue only.
# Settings: SES_QUEUE_URL (required, https://sqs.<region>.amazonaws.com/<account>/<queue>); SES_REGION (default:
# taken from the queue URL). Needs curl 7.75+ (AWS signature).
#
# API documentation:
#   Event publishing setup     https://docs.aws.amazon.com/ses/latest/dg/monitor-using-event-publishing.html
#   Event contents             https://docs.aws.amazon.com/ses/latest/dg/event-publishing-retrieving-sns-contents.html
#   SNS to SQS                 https://docs.aws.amazon.com/sns/latest/dg/sns-sqs-as-subscriber.html
#   SQS JSON requests          https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-making-api-requests-json.html
#   ReceiveMessage             https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_ReceiveMessage.html
#   DeleteMessageBatch         https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_DeleteMessageBatch.html

R_NAME="Amazon SES"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=90                      # kept by the collector, not by SES: any window works
[ -n "${EVENT_DAYS:-}" ] && [ "$EVENT_DAYS" -gt 90 ] 2>/dev/null && R_DAYS=$EVENT_DAYS
R_LAG="a few minutes"
SES_BATCHES=200                # receive calls per run at most (10 events each)

r_auth(){
  : "${SES_QUEUE_URL:?SES_QUEUE_URL missing}"
  SES_REGION="${SES_REGION:-$(sed -E 's#^https://sqs\.([a-z0-9-]+)\..*#\1#' <<< "$SES_QUEUE_URL")}"
  API="https://sqs.$SES_REGION.amazonaws.com/"
  cfg_user "$KEY"
  cfg_line aws-sigv4 "aws:amz:$SES_REGION:sqs"
}

# sqs ACTION BODY_FILE OUT: prints the HTTP status
sqs(){
  curl -s -m 60 -K "$CFG" -H "X-Amz-Target: AmazonSQS.$1" -H 'Content-Type: application/x-amz-json-1.0' \
    --data-binary @"$2" -o "$3" -w '%{http_code}' "$API" 2>/dev/null
}

r_fetch(){
  local n=0 c
  : > "$WORK/ses.handles"
  jq -n --arg q "$SES_QUEUE_URL" '{QueueUrl: $q, MaxNumberOfMessages: 10, WaitTimeSeconds: 0, VisibilityTimeout: 600}' > "$WORK/ses.req"
  while [ "$n" -lt "$SES_BATCHES" ]; do
    c=$(sqs ReceiveMessage "$WORK/ses.req" "$WORK/page")
    [ "$c" = "200" ] || { log "ReceiveMessage: HTTP $c $(jq -r '.message // .Message // ""' "$WORK/page" 2>/dev/null)"; return 1; }
    [ "$(jq '(.Messages // []) | length' "$WORK/page")" -eq 0 ] && break
    jq -r '.Messages[].ReceiptHandle' "$WORK/page" >> "$WORK/ses.handles"
    # SNS envelope (Message holds the event as a JSON string) or raw delivery (the body is the event)
    jq -c "$JQ_DEFS"'
      def addr: tostring | (capture("<(?<a>[^>]+)>").a // .);
      .Messages[] | (.Body | fromjson? // {}) | ((.Message | fromjson?) // .) as $ev
      | ($ev.mail // {}) as $mail
      | ([$mail.headers[]? | select(.name | ascii_downcase == "message-id") | .value][0] | mid) as $m
      | ($mail.source // "" | addr) as $f | ($mail.destination // [] | map(addr)) as $dest
      | (if ($dest | length) == 1 then $dest[0] else "*" end) as $one
      | ($ev.eventType // $ev.notificationType) as $type
      | if $type == "Send" then ($dest[] | {m: $m, f: $f, e: ., d: $mail.timestamp, t: "sent"})
        elif $type == "Delivery" then ($ev.delivery.recipients[]? | {m: $m, f: $f, e: addr, d: $ev.delivery.timestamp, t: "delivered"})
        elif $type == "Bounce" then ($ev.bounce as $b | $b.bouncedRecipients[]? | {m: $m, f: $f, e: (.emailAddress | addr), d: $b.timestamp,
            r: (.diagnosticCode // $b.bounceSubType // ""),
            t: (if $b.bounceType == "Permanent" then
                  (if ($b.bounceSubType | IN("Suppressed", "OnAccountSuppressionList", "OnTenantSuppressionList")) then "blocked" else "hard_bounce" end)
                else "soft_bounce" end)})
        elif $type == "Complaint" then ($ev.complaint.complainedRecipients[]? | {m: $m, f: $f, e: (.emailAddress | addr), d: $ev.complaint.timestamp, t: "spam"})
        elif $type == "Reject" then ($dest[] | {m: $m, f: $f, e: ., d: $mail.timestamp, t: "blocked", r: ($ev.reject.reason // "")})
        elif $type == "DeliveryDelay" then ($ev.deliveryDelay as $x | $x.delayedRecipients[]? | {m: $m, f: $f, e: (.emailAddress | addr),
            d: $x.timestamp, t: "deferred", r: (.diagnosticCode // $x.delayType // "")})
        elif $type == "Open" then {m: $m, f: $f, e: $one, d: $ev.open.timestamp, i: ($ev.open.ipAddress // ""),
            t: (if $ev.open.isBotEvent == "Likely" then "proxy_open" else "opened" end)}
        elif $type == "Click" then {m: $m, f: $f, e: $one, d: $ev.click.timestamp, i: ($ev.click.ipAddress // ""), t: "clicked",
            l: ($ev.click.link // "")}
        elif $type == "Subscription" then {m: $m, f: $f, e: $one, d: ($ev.subscription.timestamp // $mail.timestamp), t: "unsubscribed"}
        elif $type == "Rendering Failure" then {m: $m, f: $f, e: $one, d: $mail.timestamp, t: "error",
            r: ($ev.failure.errorMessage // "")}
        else empty end' "$WORK/page" >> "$EV"
    n=$(( n + 1 ))
  done
  [ "$n" -ge "$SES_BATCHES" ] && log "queue: $SES_BATCHES receive calls, the rest next run"
  return 0
}

# once the events are stored: remove them from the queue, 10 at a time
r_commit(){
  local c
  [ -s "$WORK/ses.handles" ] || return 0
  split -l 10 "$WORK/ses.handles" "$WORK/ses.del."
  for f in "$WORK"/ses.del.*; do
    jq -Rn --arg q "$SES_QUEUE_URL" '{QueueUrl: $q, Entries: ([inputs] | to_entries | map({Id: "m\(.key)", ReceiptHandle: .value}))}' \
      < "$f" > "$WORK/ses.dreq"
    c=$(sqs DeleteMessageBatch "$WORK/ses.dreq" "$WORK/ses.dres")
    { [ "$c" = "200" ] && [ "$(jq '(.Failed // []) | length' "$WORK/ses.dres")" -eq 0 ]; } \
      || log "DeleteMessageBatch: HTTP $c, those events come again and are merged"
  done
}
