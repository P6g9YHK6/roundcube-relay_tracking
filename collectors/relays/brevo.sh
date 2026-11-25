# relay_tracking driver: Brevo (sourced by relay-collector.sh, see the driver contract there)
#
# Global feed of the transactional events, newest first; Brevo keeps the Message-ID of the mail as sent, so no header
# is needed. Opens by image proxies (Apple, ...) come as "loadedByProxy".
# Key: API key allowed to read transactional statistics (API_KEY_FILE).
#
# API documentation:
#   Authentication              https://developers.brevo.com/docs/authentication-schemes
#   Transactional email events  https://developers.brevo.com/reference/get-email-event-report

R_NAME="Brevo"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=90                      # API maximum
R_LAG="up to 1-2 h"            # statistics publication delay
API="https://api.brevo.com/v3"
EV_PAGE=2500
EV_MAX=25000                   # events fetched at most per run; "since" tells the plugin where it stopped

r_auth(){ cfg_header "api-key: $KEY"; }

r_fetch(){
  local map='({"requests":"sent","delivered":"delivered","deferred":"deferred","softBounces":"soft_bounce",
    "hardBounces":"hard_bounce","bounces":"hard_bounce","blocked":"blocked","invalid":"invalid","error":"error",
    "opened":"opened","loadedByProxy":"proxy_open","clicks":"clicked","spam":"spam","unsubscribed":"unsubscribed"}[.] // "other")'
  local off=0 n
  while :; do
    api_ok "/smtp/statistics/events?days=$EVENT_DAYS&limit=$EV_PAGE&offset=$off&sort=desc" "$WORK/page" || return 1
    # pseudonymous addresses (Brevo anonymous tracking) have no @ and are dropped later
    jq -c "$JQ_DEFS"'(.events // [])[] | {m: (.messageId | mid), f: (.from // ""), e: (.email // ""), d: .date,
        t: (.event | '"$map"'), l: (if .event == "clicks" then (.link // "") else "" end), r: (.reason // ""),
        i: (.ip // "")}' "$WORK/page" >> "$EV"
    n=$(jq '(.events // []) | length' "$WORK/page")
    [ "$n" -lt "$EV_PAGE" ] && break
    off=$(( off + EV_PAGE ))
    if [ "$off" -ge "$EV_MAX" ]; then
      # window not fully read (newest first): tell the plugin where coverage starts, older mails show as expired
      SINCE=$(date -d "$(tail -n 1 "$EV" | jq -r '.d')" +%s 2>/dev/null || echo 0)
      log "events: stopped after $EV_MAX, covering since $(date -d "@$SINCE" -Is 2>/dev/null)"
      break
    fi
  done
}
