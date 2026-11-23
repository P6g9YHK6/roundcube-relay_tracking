# Changelog

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
