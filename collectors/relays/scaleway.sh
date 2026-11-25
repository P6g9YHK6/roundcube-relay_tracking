# relay_tracking driver: Scaleway Transactional Email (TEM) (sourced by relay-collector.sh, see the driver contract
# there)
#
# Scaleway keeps one email per recipient with its state (sending, sent, failed...), the last three delivery attempts
# and flags (hard bounce, mailbox full, spam...); no opens or clicks. Each run reads the emails of the window and turns
# them into events: sent at creation, delivered or deferred per attempt, then the final state.
# Correlation by the email's message_id: check with a real send that it is the mail's Message-ID header.
# Key: secret key of an API key allowed to read TEM (API_KEY_FILE).
# Settings: SCW_PROJECT_ID (required), SCW_REGION (default fr-par).
#
# API documentation:
#   Authentication   https://www.scaleway.com/en/developers/api/#authentication
#   TEM API          https://www.scaleway.com/en/developers/api/transactional-email/
#   Same, as code    https://github.com/scaleway/scaleway-sdk-go/blob/master/api/tem/v1alpha1/tem_sdk.go

R_NAME="Scaleway TEM"
R_CAPS='["events"]'
R_DAYS=30
R_LAG="a few minutes"
API="https://api.scaleway.com/transactional-email/v1alpha1/regions/${SCW_REGION:-fr-par}"

r_auth(){ cfg_header "X-Auth-Token: $KEY"; }

r_fetch(){
  : "${SCW_PROJECT_ID:?SCW_PROJECT_ID missing}"
  local page=1 total
  while :; do
    api_ok "/emails?project_id=$(uri "$SCW_PROJECT_ID")&since=$(uri "$(iso "$WINDOW_START")")&order_by=created_at_asc&page=$page&page_size=100" \
      "$WORK/page" || return 1
    jq -c "$JQ_DEFS"'.emails[]? | (.message_id | mid) as $m | .mail_from as $f | .mail_rcpt as $e | (.flags // []) as $fl
      | {m: $m, f: $f, e: $e, d: .created_at, t: "sent"},
        (.last_tries[]? | {m: $m, f: $f, e: $e, d: .tried_at, r: (.message // ""),
           t: (if .code >= 200 and .code < 300 then "delivered" elif .code >= 500 then "other" else "deferred" end)}),
        (if .status == "failed" then
           {m: $m, f: $f, e: $e, d: .updated_at, r: (.status_details // (.last_tries[-1].message // "")),
            t: (if ($fl | index(["blocklisted"])) or ($fl | index(["spam"])) then "blocked"
                elif ($fl | index(["soft_bounce"])) or ($fl | index(["mailbox_full"])) then "soft_bounce"
                else "hard_bounce" end)}
         elif .status == "canceled" then {m: $m, f: $f, e: $e, d: .updated_at, t: "error", r: (.status_details // "canceled")}
         elif .status == "sent" and ([.last_tries[]? | select(.code >= 200 and .code < 300)] | length) == 0 then
           {m: $m, f: $f, e: $e, d: .updated_at, t: "delivered"}
         else empty end)' "$WORK/page" >> "$EV"
    total=$(jq '.total_count // 0' "$WORK/page")
    [ $(( page * 100 )) -ge "$total" ] && break
    page=$(( page + 1 ))
    [ "$page" -gt 500 ] && { log "emails: stopped after $(( page * 100 ))"; break; }
  done
}
