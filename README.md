# relay_tracking: sending relay tracking for Roundcube

Roundcube plugin (1.6+, Elastic skin or derived) for people who send their mail through a **transactional SMTP relay**
(Brevo, ...):

- **Delivery tracking** in a sent mail: per recipient, delivered / opened / clicks / bounce / spam complaint /
  unsubscribe, with the bounce reason and the clicked links. Temporary failures that were followed by a delivery show
  as retries, and automatic opens (image proxies of Apple, Proton, ...) are kept apart from real ones;
- **Blocked contacts** (Settings): the addresses the relay now refuses (unsubscribe, hard bounce, spam complaint...),
  with an **Unblock** button;
- **Compose**: warning when a recipient is blocked by the relay of the selected sender;
- **Alert** in the mail list when a new contact gets blocked.

Translations: English, French.

**Roundcube holds no relay key.** A *collector* (a server script, with the key) queries the relay's API and writes JSON
files into a shared folder; Roundcube reads them and drops unblock requests that the collector carries out. One relay =
one subfolder = one collector.

## Installation

1. Install the plugin:
   - with Composer, from Roundcube's folder: `composer require p6g9yhk6/relay_tracking` (adds it to the plugin list
     when asked), or
   - by hand: copy this folder to `plugins/relay_tracking` and add `relay_tracking` to `$config['plugins']`.
2. Mount the relays folder in the Roundcube container (read-write: Roundcube writes in `requests/`), e.g.
   `/var/roundcube/relays`, and declare it: `$config['relay_tracking_dir'] = '/var/roundcube/relays';`
   (the other options are in [`config.inc.php.dist`](config.inc.php.dist)).
3. Install the relay's collector on the server. **Brevo**: [`collectors/brevo/brevo-collector.sh`](collectors/brevo/brevo-collector.sh)
   (standalone: bash, curl, jq, flock). Copy `brevo-collector.conf.example` to `brevo-collector.conf` (chmod 600), set
   the relay folder, the sender domains and the path of the API key file, try a dry run
   (`DRY_RUN=1 ./brevo-collector.sh`), then run it **every minute** (cron: `* * * * * /path/brevo-collector.sh`).
   The collector creates `requests/` for Roundcube's web user (`WEB_UID`, 33 = www-data in the official image). The
   `collectors/` folder does not need to be reachable by Roundcube.

The plugin only shows up for a user who has an **identity on a domain** declared by a relay.

### Options

| Option | Default | Meaning |
|---|---|---|
| `relay_tracking_dir` | `/var/roundcube/relays` | folder the collectors write to |
| `relay_tracking_untracked_after` | `86400` | seconds without any event after which a mail is labelled "no tracking" (before that: "pending", relays publish late) |
| `relay_tracking_show_all_blocked` | `false` | `true`: every user of a relay's domains sees and can unblock all its blocked contacts, not only those blocked for their own identities |

## Privacy

Open and click tracking is done by the relay (a tracking pixel and rewritten links), not by this plugin; turn it off
at the relay if you do not want it. Opens are a weak signal: many providers load images on receipt, so only clicks
prove a read. The common format never carries IP addresses or user agents, only date, type, clicked link and reason.

## Common format v1 (contract between collector and plugin)

Folder `<relay_tracking_dir>/<id>/` (`id`: `[a-z0-9_-]{1,32}`). Files written by the collector **atomically**
(temporary file, then rename), readable by Roundcube, never changed by it.

| File | Content |
|---|---|
| `relay.json` | `{"format": 1, "id", "name", "domains": [..], "capabilities": [..], "lag": "free text", "events_days": n}` |
| `events.json` | `{"generated": epoch, "days": n, "since"?: epoch, "messages": {"<Message-ID>": {"recipient": [[ISO 8601 date, type, extra?], ...]}}}` |
| `blocked.json` | `{"generated": epoch, "contacts": [{"email", "reason", "detail"?, "at": ISO 8601 date, "sender"?, "removable"?}]}` |
| `unblock.json` | `{"requests": [{"id", "email", "user", "status", "at": epoch}, ...]}` (newest first, 50 max) |
| `requests/` | **written by Roundcube**: one request = `<epoch>-<random>.json` `{"email", "user", "ts"}` (at most 2 KB) |

- **Capabilities** (`capabilities`): `events` (per mail tracking), `opens`, `clicks`, `blocked` (blocked list),
  `unblock` (unblocking). A missing capability hides the matching feature.
- **`<Message-ID>` key**: the `Message-ID` header of the mail as Roundcube sent it, angle brackets included. The
  collector must find that identifier at the relay (Brevo keeps it: `messageId` field of its events).
- **`"*"` recipient** in `events.json`: events without a specific recipient (relays that do not give one per event,
  e.g. Lettermint); they apply to every recipient of the mail.
- **`since`** in `events.json`: when the collector could not read the whole `days` window (too many events), the
  date its data starts from. Older mails without events then show as "history unavailable" rather than "no tracking".
- **`sender`** in `blocked.json`: address that was sending when the contact got blocked. Users see and unblock only the
  contacts blocked for their own identities (or without `sender`), unless `relay_tracking_show_all_blocked` is on. The
  compose warning covers all contacts, since a relay blocks them for every sender.
- **`removable: false`** in `blocked.json`: a block the relay's API cannot lift (e.g. spam complaint at Postmark or
  Lettermint), so no "Unblock" button.
- **Event types**: `sent`, `delivered`, `deferred`, `soft_bounce`, `hard_bounce`, `blocked`, `invalid`, `error`,
  `opened`, `proxy_open` (image loaded by a proxy: Apple, Proton...), `clicked`, `spam`, `unsubscribed` (any other type
  is ignored). `extra` = link for `clicked`, reason for a bounce.
- **Block reasons** (`reason`): `unsubscribed`, `hard_bounce`, `spam`, `manual`, `invalid`, `other`; `detail` = the
  relay's own reason (optional, shown as a tooltip).
- **Unblocking**: the collector reads `requests/`, validates the address, unblocks only if it **really is blocked**,
  adds the result at the top of `unblock.json` (`unblocked`, `not_blocked`, `invalid`, `error_<code>`) and then removes
  the request (a rate limit or server error is retried for a while first). Roundcube polls the state every 10 s for
  3 min.
- **Permissions**: relay folder `755` (read), `requests/` owned by the web user (`770`).

## Writing a collector for another relay

The Brevo collector (`collectors/brevo/`) is the model: keys in `600` files outside any repository, HTTP headers in
temporary files (never on a command line), atomic writes, a lock, a dry run mode (`DRY_RUN=1`). Producing the files
above is all it takes; the mapping from the relay's vocabulary to the common one is at the top of the script
(`EVENT_MAP`, `REASON_MAP`).

**The hard part is correlation**: finding, at the relay, the events of the mail whose `Message-ID` Roundcube knows.
Three ways depending on the relay: (a) the relay keeps our `Message-ID` and returns it in its events (Brevo); (b) a
relay-specific **metadata header**, added when sending (Postfix rule or plugin) with our `Message-ID`, that the API can
filter on, the most portable way; (c) the **relay's identifier in the SMTP "250" reply**, visible in the Postfix log
(`status=sent (250 ...)`), linked to the `Message-ID` by the collector.

### Relays: what their API allows (official documentation, checked on 2026-11-23)

| Relay | Events by polling | Correlation | Opens / clicks | Blocked list | Unblocking |
|---|---|---|---|---|---|
| **Brevo** (collector included) | global feed, 90 d | (a) `messageId` | yes | yes | yes |
| Lettermint | per message (N+1 calls), no recipient per event, 28 d | (b) `X-LM-Metadata-*` (`X-LM-Preserve-Message-ID` keeps ours, not filterable) | yes, enabled per route | yes | yes, except complaints (reviewed by support) |
| Mailgun | global feed (Logs API); **1 d** on the free plan | (b) `X-Mailgun-Variables` | yes | yes | yes |
| Postmark | search + detail per message, 45 d | (b) `X-PM-Metadata-*` (`X-PM-KeepID`) | yes | yes (per stream) | yes, except complaints |
| Amazon SES | only with VDM (paid), otherwise SNS > SQS | (c) 250 reply | yes (configuration set) | yes | yes |
| SendGrid | global feed (paid add-on per the docs); no free plan any more | (b) `X-SMTPAPI` `unique_args` | yes | yes | yes |
| Mailjet | per message, no recipient or link in the history | (b) `X-MJ-CustomID` (64 chars: hash) | yes | indirect | **no** (support) |
| Scaleway TEM | state per recipient, no feed | `message_id` to be checked | **no** | yes (bounces) | yes, 5 / 24 h |
| MailerSend | global feed; **1 d** on the free plan | (c) 250 reply (custom headers removed) | yes | yes | likely |
| SMTP2GO | global feed | headers returned, to be checked | yes | yes | yes, except complaints |
| Resend | latest state only (webhooks needed) | `message_id`, to be checked | yes | yes | yes |
| Infomaniak | no transactional relay API | - | - | - | - |

To check with a real send before writing a collector: whether the `Message-ID` is kept (Mailgun, Resend, Scaleway,
SMTP2GO) and what the 250 reply contains (Postmark, Lettermint, Mailgun, Mailjet).

## License

GPL-3.0-or-later (like Roundcube), see [LICENSE](LICENSE).
