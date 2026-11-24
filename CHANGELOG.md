# Changelog

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
