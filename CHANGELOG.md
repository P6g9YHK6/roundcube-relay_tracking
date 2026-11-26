# Changelog

## 2.6.0 (2026-11-26)

- Network owner of each IP from DB-IP's free "IP to ASN Lite" data, searched locally like the locations: the IPs no
  longer go to Team Cymru, whose lookup is removed. On by default (`IP_ASN=1`, still needs `INCLUDE_IP=1`), no longer
  tied to `IP_LOOKUP`, which now only adds the reverse DNS name. The geoip branch carries the owner files next to the
  location ones; a collector downloads only the files of what it has turned on.
- `tools/dbip-convert.py` takes the kind of file first: `city` or `asn`.
- The DB-IP credit in the tracking box also shows when only owners are.
- Converter: the space after the last range of IPv4 and of IPv6 is marked unknown, so an IP there no longer takes the
  last range's owner or location. The geoip branch version includes the converter's hash, and a change to the
  converter rebuilds the branch on push.
- CI (`.github/workflows/ci.yml`, tests in `tests/`): PHP lint on 7.3 to 8.4; the plugin run against Roundcube stubs
  (sending, open pixel and links over HTTP, tracking box data, preferences); the box drawn in jsdom; shellcheck; a full
  collector run on a fixture relay and fixture DB-IP files; the SQL schemas in SQLite, MySQL and PostgreSQL; labels,
  versions and docs in step. Daily, the geoip branch is checked against DB-IP's latest release.

## 2.5.0 (2026-11-26)

- Self tracking (`relay_tracking_self`, off by default): when sending, Roundcube adds an open pixel and sends the links
  of the HTML part through its own address (`?_task=relay_tracking`, no login needed), records opens and clicks in two
  new tables (`SQL/`) and shows them in the tracking box. Works without a relay; with one, its opens and clicks are
  added to the relay's events.
- "Track opens and clicks" box in the compose options, ticked per the new preference "Track opens and clicks of the
  mails I send" (Settings > Preferences > Composing Messages, default `relay_tracking_self_track`).
- Settings `relay_tracking_self_url`, `relay_tracking_self_ip` and `relay_tracking_self_days`.
- Events of a mail are sorted by date after merging the ones without a recipient.

## 2.4.0 (2026-11-25)

- Collectors for Postmark, Mailgun, SendGrid, Mailjet, Lettermint, SMTP2GO, Scaleway TEM, MailerSend, Amazon SES and
  Resend, next to Brevo. One script, `collectors/relay-collector.sh`, takes a settings file naming the relay
  (`RELAY=...`); each relay is a driver in `collectors/relays/` with links to the API documentation it follows. The IP
  lookups, locations, dry run and output are shared by all of them.
- Relays that do not report the Message-ID get it from a header the plugin adds when sending (`headers` in
  `relay.json`, e.g. `X-PM-Metadata-rt-mid` for Postmark), removed by the relay before delivery.
- `collectors/brevo/brevo-collector.sh` is replaced by `relay-collector.sh` with `RELAY=brevo`; an installed copy of
  the old script keeps working.

## 2.3.0 (2026-11-24)

- Public IPs in the timeline are links to their iplocation.net lookup page ("Click for more info"); private addresses
  stay plain text. The reverse DNS name moved to the hover of the owner line.

## 2.2.2 (2026-11-24)

- Dates follow the user's Roundcube settings (date and time format, pretty dates, timezone): the server formats them
  with Roundcube's own `format_date()` instead of the browser.

## 2.2.1 (2026-11-24)

- Timeline table spans the full width again (the scrolling moved to a wrapper); time, event and IP take only the room
  they need.
- README screenshots with demo data.

## 2.2.0 (2026-11-24)

- IP location (city, region, country) under each IP in the timeline, from DB-IP's free "IP to City Lite" data: a daily
  GitHub Actions workflow keeps it on the `geoip` branch, the Brevo collector downloads it when it changes and searches
  it locally (`IP_GEO=1`, off by default). Credited "IP Geolocation by DB-IP" as CC BY 4.0 requires.
- New user preference "Show where the IP is" (`relay_tracking_show_location`).

## 2.1.0 (2026-11-24)

- New recipient layout: a progress stepper (Sent > Delivered > Opened > Clicked, with dates and counts, problems in red)
  and a folded timeline table, one row per event with time, event, detail and IP.
- IP identification in the Brevo collector, each behind its own switch: `IP_LOOKUP=1` (reverse DNS, cached 30 days)
  and `IP_ASN=1` (network owner via Team Cymru). The provider is shown under each IP in the timeline.
- Restyled box: card layout, hover and keyboard focus states, scrolling timeline, phone layout.
- User preferences (Settings > Preferences > Displaying Messages > Delivery tracking): show IP addresses, show who the
  IP belongs to. Defaults `relay_tracking_show_ip` and `relay_tracking_show_owner`, lockable with `dont_override`.

## 2.0.0 (2026-11-23)

Delivery tracking only.

- Removed the blocked contacts features (Settings page, Unblock button, compose warning, new block alert), the unblock
  actions and the `relay_tracking_show_all_blocked` option. The common format drops `blocked.json`, `unblock.json` and
  `requests/`; Roundcube now only reads the relays folder.
- Every open and click listed on its own, in date order; automatic opens marked apart from real opens.
- Optional IP address per event, shown on hover (`INCLUDE_IP=1` in the Brevo collector, off by default).
- The Brevo collector only fetches events and is meant to run every 5 minutes; it no longer needs a second key.
- Stylesheet moved to `skins/elastic/`, license headers added, requires `roundcube/plugin-installer` ~0.3.5.

## 1.0.0 (2026-11-23)

First public release, extracted from a private Roundcube setup.

- Tracking box in sent mail: per recipient sent, delivered, opened, clicks (with links), bounces (with reason),
  spam complaint, unsubscribe.
- Settings > Blocked contacts, with an Unblock button handled by the collector.
- Compose warning when a recipient is blocked by the sender's relay; alert in the mail list for new blocks.
- Brevo collector (bash, curl, jq).
- A deferral or soft bounce followed by a delivery shows as a retry, not as a problem.
- Automatic opens (image proxies, opens within 20 s of delivery) are counted apart from real opens.
- `events.json` may carry `since` when the collector could not read the whole window; older mail shows as expired
  instead of untracked.
- The Brevo collector keeps only events and blocked contacts of the configured sender domains, adds `sender` and the
  relay's readable reason to blocked contacts, retries unblocks on rate limits and server errors, normalises
  Message-IDs and refuses a settings file others could write.
- Users only see and unblock contacts blocked for their own identities (`relay_tracking_show_all_blocked` to lift).
