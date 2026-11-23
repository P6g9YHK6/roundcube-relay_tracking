# relay_tracking: sending relay tracking for Roundcube
<img width="554" height="307" alt="image" src="https://github.com/user-attachments/assets/b0a19179-ca8c-49d8-9dba-f863e47f21fa" />

Roundcube plugin (1.6+, Elastic skin or derived) for people who send their mail through a **transactional SMTP relay**
(Brevo, ...). In a sent mail, a **Delivery tracking** box shows per recipient: sent, delivered, opened, clicks (with
the clicked links), bounce (with the reason), spam complaint, unsubscribe. Temporary failures that were followed by a
delivery show as retries, automatic opens (image proxies of Apple, Proton, ...) are kept apart from real ones, and every
open and click is listed on its own, with its IP address on hover when the collector provides it.

Translations: English, French.

**Roundcube holds no relay key.** A *collector* (a server script, with the key) queries the relay's API and writes JSON
files into a shared folder that Roundcube only reads. One relay = one subfolder = one collector.

## Installation

1. Install the plugin:
   - with Composer, from Roundcube's folder: `composer require p6g9yhk6/relay_tracking` (adds it to the plugin list
     when asked), or
   - by hand: copy this folder to `plugins/relay_tracking` and add `relay_tracking` to `$config['plugins']`.
2. Mount the relays folder in the Roundcube container (read-only is enough), e.g. `/var/roundcube/relays`, and declare
   it: `$config['relay_tracking_dir'] = '/var/roundcube/relays';` (the other option is in
   [`config.inc.php.dist`](config.inc.php.dist)).
3. Install the relay's collector on the server. **Brevo**: [`collectors/brevo/brevo-collector.sh`](collectors/brevo/brevo-collector.sh)
   (standalone: bash, curl, jq, flock). Copy `brevo-collector.conf.example` to `brevo-collector.conf` (chmod 600), set
   the relay folder, the sender domains and the path of the API key file, try a dry run
   (`DRY_RUN=1 ./brevo-collector.sh`), then run it **every 5 minutes** (cron: `*/5 * * * * /path/brevo-collector.sh`).
   The `collectors/` folder does not need to be reachable by Roundcube.

The plugin only shows up for a user who has an **identity on a domain** declared by a relay.

### Options

| Option | Default | Meaning |
|---|---|---|
| `relay_tracking_dir` | `/var/roundcube/relays` | folder the collectors write to |
| `relay_tracking_untracked_after` | `86400` | seconds without any event after which a mail is labelled "no tracking" (before that: "pending", relays publish late) |

## Privacy

Open and click tracking is done by the relay (a tracking pixel and rewritten links), not by this plugin; turn it off
at the relay if you do not want it. Opens are a weak signal: many providers load images on receipt, so only clicks
prove a read. By default the common format carries no IP address or user agent, only date, type, clicked link and
reason. A collector may add the IP of each event when asked to (`INCLUDE_IP=1` for Brevo); it is the recipient's IP
(or their provider's proxy), so personal data: only turn it on if you have a basis for processing it.

## Common format v1 (contract between collector and plugin)

Folder `<relay_tracking_dir>/<id>/` (`id`: `[a-z0-9_-]{1,32}`). Files written by the collector **atomically**
(temporary file, then rename), readable by Roundcube, never changed by it.

| File | Content |
|---|---|
| `relay.json` | `{"format": 1, "id", "name", "domains": [..], "capabilities": [..], "lag": "free text", "events_days": n}` |
| `events.json` | `{"generated": epoch, "days": n, "since"?: epoch, "messages": {"<Message-ID>": {"recipient": [[ISO 8601 date, type, extra?, ip?], ...]}}}` |

- **Capabilities** (`capabilities`): `events` (required for the plugin to use the relay), `opens`, `clicks`.
- **`<Message-ID>` key**: the `Message-ID` header of the mail as Roundcube sent it, angle brackets included. The
  collector must find that identifier at the relay (Brevo keeps it: `messageId` field of its events).
- **`"*"` recipient** in `events.json`: events without a specific recipient (relays that do not give one per event,
  e.g. Lettermint); they apply to every recipient of the mail.
- **`since`** in `events.json`: when the collector could not read the whole `days` window (too many events), the
  date its data starts from. Older mails without events then show as "history unavailable" rather than "no tracking".
- **Event types**: `sent`, `delivered`, `deferred`, `soft_bounce`, `hard_bounce`, `blocked` (not sent: the relay
  blocks that recipient), `invalid`, `error`, `opened`, `proxy_open` (image loaded by a proxy: Apple, Proton...),
  `clicked`, `spam`, `unsubscribed` (any other type is ignored). `extra` = link for `clicked`, reason for a bounce
  (`""` when there is none but an `ip` follows); `ip` = optional IP address of the event, shown on hover.
- **Permissions**: relay folder `755`, files `644`.

## Writing a collector for another relay

The Brevo collector (`collectors/brevo/`) is the model: key in a `600` file outside any repository, HTTP headers in
a temporary file (never on a command line), atomic writes, a lock, a dry run mode (`DRY_RUN=1`). Producing the files
above is all it takes; the mapping from the relay's vocabulary to the common one is at the top of the script
(`EVENT_MAP`).

**The hard part is correlation**: finding, at the relay, the events of the mail whose `Message-ID` Roundcube knows.
Three ways depending on the relay: (a) the relay keeps our `Message-ID` and returns it in its events (Brevo); (b) a
relay-specific **metadata header**, added when sending (Postfix rule or plugin) with our `Message-ID`, that the API can
filter on, the most portable way; (c) the **relay's identifier in the SMTP "250" reply**, visible in the Postfix log
(`status=sent (250 ...)`), linked to the `Message-ID` by the collector.

### Relays: what their API allows (official documentation, checked on 2026-11-23)

| Relay | Events by polling | Correlation | Opens / clicks |
|---|---|---|---|
| **Brevo** (collector included) | global feed, 90 d | (a) `messageId` | yes |
| Lettermint | per message (N+1 calls), no recipient per event, 28 d | (b) `X-LM-Metadata-*` (`X-LM-Preserve-Message-ID` keeps ours, not filterable) | yes, enabled per route |
| Mailgun | global feed (Logs API); **1 d** on the free plan | (b) `X-Mailgun-Variables` | yes |
| Postmark | search + detail per message, 45 d | (b) `X-PM-Metadata-*` (`X-PM-KeepID`) | yes |
| Amazon SES | only with VDM (paid), otherwise SNS > SQS | (c) 250 reply | yes (configuration set) |
| SendGrid | global feed (paid add-on per the docs); no free plan any more | (b) `X-SMTPAPI` `unique_args` | yes |
| Mailjet | per message, no recipient or link in the history | (b) `X-MJ-CustomID` (64 chars: hash) | yes |
| Scaleway TEM | state per recipient, no feed | `message_id` to be checked | **no** |
| MailerSend | global feed; **1 d** on the free plan | (c) 250 reply (custom headers removed) | yes |
| SMTP2GO | global feed | headers returned, to be checked | yes |
| Resend | latest state only (webhooks needed) | `message_id`, to be checked | yes |
| Infomaniak | no transactional relay API | - | - |

To check with a real send before writing a collector: whether the `Message-ID` is kept (Mailgun, Resend, Scaleway,
SMTP2GO) and what the 250 reply contains (Postmark, Lettermint, Mailgun, Mailjet).

## License

GPL-3.0-or-later (like Roundcube), see [LICENSE](LICENSE).
