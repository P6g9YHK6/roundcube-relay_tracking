# relay_tracking driver: MailerSend (sourced by relay-collector.sh, see the driver contract there)
#
# MailerSend drops custom headers over SMTP and does not return the Message-ID; it answers "250 Message queued as
# <id>", the id its API reports. The mail server's log ties that id to the Message-ID: this driver reads the Postfix
# log (MAIL_LOG), keeps the mapping in STATE_DIR, then reads the activity of the sending domains since the last run,
# accumulated for the window. 10 activity requests per minute: the first run over a long window takes a while.
# Key: API token with activity read access (API_KEY_FILE).
# Settings:
#   MAIL_LOG              Postfix log files, rotated ones too (default "/var/log/mail.log /var/log/mail.log.1"),
#                         compressed or not; or MAIL_LOG_CMD, a command printing it (e.g. "journalctl -u postfix
#                         --since -1d -o short"). The collector must be able to read it.
#   MAILERSEND_DOMAIN_IDS domain ids (default: looked up from DOMAINS)
#
# API documentation:
#   Authentication, rate limits  https://developers.mailersend.com/general
#   Activity                     https://developers.mailersend.com/api/v1/activity.html
#   Emails (message_id)          https://developers.mailersend.com/api/v1/email/emails.html
#   Domains                      https://developers.mailersend.com/api/v1/domains.html
#   SMTP relay, 250 reply        https://developers.mailersend.com/api/v1/email/smtp-relay

R_NAME="MailerSend"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=30                      # depends on the plan's data retention
R_LAG="a few minutes"
API="https://api.mailersend.com/v1"
MS_WAIT=6                      # seconds between activity requests (10 per minute)

r_auth(){ cfg_header "Authorization: Bearer $KEY"; }

# Postfix log > "relay id <tab> Message-ID" for mail relayed by MailerSend, added to $DATA/ms.map
ms_map(){
  local map="$DATA/ms.map"; [ -f "$map" ] || : > "$map"
  {
    if [ -n "${MAIL_LOG_CMD:-}" ]; then bash -c "$MAIL_LOG_CMD"
    else for f in ${MAIL_LOG:-/var/log/mail.log /var/log/mail.log.1}; do [ -r "$f" ] && zcat -f "$f"; done; fi
  } 2>/dev/null | awk '
    / postfix\/cleanup\[/ && match($0, /: [0-9A-Za-z]+: message-id=/) {
      q = substr($0, RSTART + 2, RLENGTH - 15); m = substr($0, RSTART + RLENGTH); sub(/[ \t].*$/, "", m); mid[q] = m; next }
    /status=sent/ && /mailersend/ && match($0, /: [0-9A-Za-z]+: to=/) {
      q = substr($0, RSTART + 2, RLENGTH - 7)
      if (match($0, /queued as [0-9A-Za-z]+/) && (q in mid)) print substr($0, RSTART + 10, RLENGTH - 10) "\t" mid[q] }' \
    > "$WORK/ms.new"
  # the most recent 100000 mails are enough for the window
  cat "$map" "$WORK/ms.new" | awk -F'\t' '!seen[$1]++' | tail -n 100000 > "$map.tmp" && mv -f "$map.tmp" "$map"
  [ -s "$map" ] || log "no MailerSend mail found in the mail log yet"
}

r_fetch(){
  local ids="${MAILERSEND_DOMAIN_IDS:-}" d a b page n
  ms_map
  if [ -z "$ids" ]; then
    api_ok "/domains?limit=100" "$WORK/page" || return 1
    ids=$(jq -r --argjson doms "$DOMAINS_JSON" '.data[] | select(.name | ascii_downcase | IN($doms[])) | .id' "$WORK/page")
    [ -n "$ids" ] || { log "none of DOMAINS is a MailerSend domain"; return 1; }
  fi
  : > "$WORK/ms.items"
  for d in $ids; do
    # periods of 7 days at most
    a=$FROM
    while [ "$a" -lt "$NOW" ]; do
      b=$(( a + 604800 )); [ "$b" -gt "$NOW" ] && b=$NOW
      page=1
      while :; do
        sleep "$MS_WAIT"
        api_ok "/activity/$(uri "$d")?date_from=$a&date_to=$b&limit=100&page=$page" "$WORK/page" || return 1
        jq -c '.data[]?' "$WORK/page" >> "$WORK/ms.items"
        n=$(jq '.data | length' "$WORK/page")
        [ "$n" -lt 100 ] || [ "$(jq -r '.links.next // ""' "$WORK/page")" = "" ] && break
        page=$(( page + 1 ))
        [ "$page" -gt 1000 ] && break
      done
      a=$b
    done
  done

  # MailerSend id of each email: in the activity, or read once per email
  local emap="$DATA/ms.email" id; [ -f "$emap" ] || : > "$emap"
  for id in $(jq -r 'select((.email.message_id // "") == "") | .email.id // empty' "$WORK/ms.items" | sort -u); do
    grep -q "^$id"$'\t' "$emap" && continue
    sleep 1
    api_ok "/email/$(uri "$id")" "$WORK/ms.e" || continue
    printf '%s\t%s\n' "$id" "$(jq -r '.data.message_id // ""' "$WORK/ms.e")" >> "$emap"
  done
  tail -n 100000 "$emap" > "$emap.tmp" && mv -f "$emap.tmp" "$emap"

  jq -c --rawfile map "$DATA/ms.map" --rawfile em "$emap" "$JQ_DEFS"'
    def rows($t): $t | split("\n") | map(select(. != "") | split("\t")) | map({key: .[0], value: (.[1] // "")}) | from_entries;
    rows($map) as $M | rows($em) as $E
    | (.email // {}) as $x | ($x.message_id // $E[$x.id // ""] // "") as $msid
    | {m: ($M[$msid] // "" | mid), f: ($x.from // ""), e: ($x.recipient.email // ""), d: .created_at,
       t: ({"sent": "sent", "delivered": "delivered", "soft_bounced": "soft_bounce", "hard_bounced": "hard_bounce",
            "deferred": "deferred", "opened": "opened", "clicked": "clicked", "unsubscribed": "unsubscribed",
            "spam_complaints": "spam", "suppressed": "blocked"}[.type] // "other"),
       r: (.suppression_reason // "")}' "$WORK/ms.items" >> "$EV"
}
