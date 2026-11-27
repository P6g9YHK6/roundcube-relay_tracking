# relay_tracking driver: Lettermint (sourced by relay-collector.sh, see the driver contract there)
#
# Lettermint replaces the Message-ID unless asked not to, and its API does not return it, so the plugin adds the
# mail's Message-ID as metadata (X-LM-Metadata-rt_mid, removed by Lettermint before delivery). Each run lists the
# outbound messages of the window sent from DOMAINS, reads the metadata of each new one once, and the events of ours
# again when their status changes, and otherwise every run the first day, hourly the first week and daily after.
# Delivery events carry their recipient; the others apply to every recipient of the mail. Opens and clicks only on
# routes with tracking enabled.
# Key: Team API token (lm_team_...) in API_KEY_FILE.
#
# API documentation:
#   Authentication, base URL   https://lettermint.co/docs/api-reference
#   Messages and their events  https://lettermint.co/docs/api-reference/team/message
#   Event and status names     https://lettermint.co/docs/api-reference/team/~schemas
#   Activity (recipient)       https://lettermint.co/docs/platform/emails/activity
#   Retention                  https://lettermint.co/docs/platform/emails/data-retention
#   SMTP metadata headers      https://lettermint.co/docs/guides/send-email-with-smtp

R_NAME="Lettermint"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=28                      # default message retention
[ -n "${EVENT_DAYS:-}" ] && [ "$EVENT_DAYS" -gt 28 ] 2>/dev/null && R_DAYS=$EVENT_DAYS
R_LAG="a few minutes"
R_HEADERS='{"X-LM-Metadata-rt_mid": "{message_id}"}'
API="https://api.lettermint.co/v1"

r_auth(){ cfg_header "Authorization: Bearer $KEY"; }

# all pages of a list ($1 = path with query) >> $2, items of "data"
lm_pages(){
  local url="$1" out="$2" cur="" n=0 sep
  [[ "$url" == *\?* ]] && sep="&" || sep="?"
  while :; do
    api_ok "$url${cur:+${sep}page%5Bcursor%5D=$(uri "$cur")}" "$WORK/page" || return 1
    jq -c '.data[]?' "$WORK/page" >> "$out"
    cur=$(jq -r '.next_cursor // ""' "$WORK/page")
    n=$(( n + 1 ))
    [ -z "$cur" ] || [ "$n" -ge 500 ] && break
  done
}

r_fetch(){
  local id st at mid meta="$DATA/lm.meta"
  [ -f "$meta" ] || : > "$meta"
  : > "$WORK/lm.list"
  lm_pages "/messages?filter%5Btype%5D=outbound&filter%5Bfrom_date%5D=$(date -u -d "@$WINDOW_START" +%Y-%m-%d)&page%5Bsize%5D=100" \
    "$WORK/lm.list" || return 1
  jq -c --argjson doms "$DOMAINS_JSON" 'select(.from_email | '"$OURS"')' "$WORK/lm.list" > "$WORK/lm.ours"

  # metadata, read once per message: "id <tab> Message-ID" ("" when the mail did not come through the plugin)
  declare -A MID
  while IFS=$'\t' read -r id mid; do MID[$id]="$mid"; done < "$meta"
  while read -r id; do
    [ -n "${MID[$id]+x}" ] && continue
    api_ok "/messages/$(uri "$id")" "$WORK/lm.d" || continue
    MID[$id]=$(jq -r '.metadata.rt_mid // .data.metadata.rt_mid // ""' "$WORK/lm.d" | tr -d '\t\r\n')
  done < <(jq -r '.id' "$WORK/lm.ours")
  # only this window's messages are remembered
  while read -r id; do [ -n "${MID[$id]+x}" ] && printf '%s\t%s\n' "$id" "${MID[$id]}" || :; done \
    < <(jq -r '.id' "$WORK/lm.list") > "$meta.tmp" && mv -f "$meta.tmp" "$meta"

  while IFS=$'\t' read -r id st at; do
    mid="${MID[$id]:-}"
    [ -n "$mid" ] || continue
    st="$st $(mc_age_stamp "$(date -d "$at" +%s 2>/dev/null || echo "$NOW")")"
    mc_fresh "$id" "$st" && continue
    : > "$WORK/lm.ev"
    lm_pages "/messages/$(uri "$id")/events?sort=timestamp&page%5Bsize%5D=100" "$WORK/lm.ev" || continue
    jq -c --arg mid "$mid" --argjson msg "$(jq -c --arg id "$id" 'select(.id == $id)' "$WORK/lm.ours" | head -n 1)" "$JQ_DEFS"'
      (.metadata | if type == "object" then . else {} end) as $x
      | {m: ($mid | mid), f: ($msg.from_email // ""), e: ($x.recipient // "*"), d: .timestamp,
         t: ({"processed": "sent", "delivered": "delivered", "soft_bounced": "soft_bounce", "hard_bounced": "hard_bounce",
              "spam_complaint": "spam", "failed": "error", "blocked": "blocked", "suppressed": "blocked",
              "policy_rejected": "blocked", "unsubscribed": "unsubscribed", "clicked": "clicked"}[.event]
             // (if .event == "opened" then
                   (if ([$x.reason_codes[]?, $x.engagement.reason_codes[]?] | any(. == "privacy_proxy" or . == "image_proxy"))
                    then "proxy_open" else "opened" end)
                 else "other" end)),
         l: (if .event == "clicked" then ($x.url // $x.destination_url // $x.link // "") else "" end),
         r: ($x.reason // (if ($x.response|type) == "object" then $x.response.content else $x.response end) // ""), i: ($x.ip // "")}' "$WORK/lm.ev" \
      | mc_put "$id" "$st"
  done < <(jq -r '[.id, ((.status // "") + " " + (.status_changed_at // "")), .created_at] | @tsv' "$WORK/lm.ours")
  mc_all >> "$EV"
}
