# relay_tracking driver: Resend (sourced by relay-collector.sh, see the driver contract there)
#
# Resend's API only gives each email's latest event (last_event), no history: each run lists the emails of the window
# and records every new last_event with the time it was first seen, so the timeline is only as precise as the
# collector's schedule, and an event replaced between two runs (e.g. opened, then clicked) is missed. The date of the
# sending is exact. Correlation by the email's message_id: check with a real send that it is the mail's Message-ID.
# Key: API key with full access (sending-only keys cannot read emails) in API_KEY_FILE.
#
# API documentation:
#   Authentication, pagination  https://resend.com/docs/api-reference/introduction
#                               https://resend.com/docs/api-reference/pagination
#   List emails                 https://resend.com/docs/api-reference/emails/list-emails
#   Retrieve email              https://resend.com/docs/api-reference/emails/retrieve-email
#   Email events                https://resend.com/docs/dashboard/emails/manage-emails
#   SMTP                        https://resend.com/docs/send-with-smtp

R_NAME="Resend"
R_CAPS='["events", "opens", "clicks"]'
R_DAYS=30
R_LAG="up to the collector's schedule"
API="https://api.resend.com"

r_auth(){ cfg_header "Authorization: Bearer $KEY"; }

r_fetch(){
  local after="" n=0 state="$DATA/resend.state"
  [ -f "$state" ] || : > "$state"
  : > "$WORK/rs.list"
  while :; do
    api_ok "/emails?limit=100${after:+&after=$(uri "$after")}" "$WORK/page" || return 1
    jq -c --argjson doms "$DOMAINS_JSON" "$EPOCH"'.data[]? | select(((.created_at | epoch) // 0) >= '"$WINDOW_START"')
      | select(.from | (capture("<(?<a>[^>]+)>").a // .) | '"$OURS"')' "$WORK/page" >> "$WORK/rs.list"
    after=$(jq -r '.data[-1].id // ""' "$WORK/page")
    n=$(( n + 1 ))
    # newest first: stop at the window start
    [ "$(jq -r '.has_more // false' "$WORK/page")" = "true" ] && [ -n "$after" ] \
      && [ "$(jq "$EPOCH"'(.data[-1].created_at | epoch) // 0' "$WORK/page")" -ge "$WINDOW_START" ] && [ "$n" -lt 1000 ] || break
  done
  # state: id <tab> event <tab> first seen (epoch), kept for the emails of the window
  jq -r '[.id, (.last_event // "")] | @tsv' "$WORK/rs.list" | awk -F'\t' -v now="$NOW" '
    FILENAME == ARGV[1] { seen[$1 "\t" $2] = $3; next }
    { keep[$1] = 1; if ($2 != "" && !(($1 "\t" $2) in seen)) seen[$1 "\t" $2] = now }
    END { for (k in seen) { split(k, p, "\t"); if (p[1] in keep) print k "\t" seen[k] } }' "$state" - > "$state.tmp" \
    && mv -f "$state.tmp" "$state"
  jq -c --rawfile st "$state" "$JQ_DEFS"'
    ($st | split("\n") | map(select(. != "") | split("\t")) | group_by(.[0]) | map({key: .[0][0], value: map({e: .[1], at: (.[2] | tonumber)})})
      | from_entries) as $S
    | . as $x | (.message_id | mid) as $m | (.from | (capture("<(?<a>[^>]+)>").a // .)) as $f | (.to // []) as $to
    | (if ($to | length) == 1 then $to[0] else "*" end) as $one
    | ($to[] | {m: $m, f: $f, e: ., d: $x.created_at, t: "sent"}),
      ($S[$x.id][]? | select(.e | IN("sent", "queued", "scheduled") | not) | {m: $m, f: $f, e: $one, d: .at,
        t: ({"delivered": "delivered", "delivery_delayed": "deferred", "bounced": "hard_bounce", "complained": "spam",
             "opened": "opened", "clicked": "clicked", "failed": "error", "suppressed": "blocked", "canceled": "error"}[.e] // "other")})' \
    "$WORK/rs.list" >> "$EV"
}
