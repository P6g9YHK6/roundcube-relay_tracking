<?php

/**
 * relay_tracking: delivery tracking for mail sent through a transactional SMTP relay (Brevo, ...) and management of
 * the contacts that relay blocks, for Roundcube (Elastic and derived skins).
 *
 * Roundcube never holds a relay API key. One collector per relay (a server-side script, see README.md) writes into
 * a shared folder, in the COMMON FORMAT v1:
 *
 *   <relay_tracking_dir>/<relay>/relay.json    description: name, domains served, capabilities, publication delay
 *   <relay_tracking_dir>/<relay>/events.json   events by Message-ID, then by recipient (normalised types)
 *   <relay_tracking_dir>/<relay>/blocked.json  blocked contacts (normalised reason)
 *   <relay_tracking_dir>/<relay>/unblock.json  unblock results
 *   <relay_tracking_dir>/<relay>/requests/     unblock requests dropped HERE by Roundcube (its only write)
 *
 * Features (for a user with an identity on a domain served by a relay):
 *   - viewing a SENT mail: "Delivery tracking" box per recipient (delivered, opened, clicks, bounce...) and blocked
 *     recipients flagged, with "Unblock";
 *   - Settings > "Blocked contacts": one section per relay, reason, date, "Unblock", recent unblocks;
 *   - compose: warning when a recipient is blocked by the relay of the selected sender;
 *   - mail list: alert when a new contact gets blocked (seen = "Blocked contacts" page opened).
 *
 * Options: see config.inc.php.dist. No IP address exists in the format (collectors never read them).
 */
class relay_tracking extends rcube_plugin
{
    public $task = 'mail|settings';

    private const FORMAT = 1;

    /** Normalised block reasons (blocked.json > reason) */
    private const REASONS = ['unsubscribed', 'hard_bounce', 'spam', 'manual', 'invalid', 'other'];

    /** Known unblock results (unblock.json > status) */
    private const RESULTS = ['unblocked', 'not_blocked', 'invalid', 'dry_run'];

    private $rc;
    private $relays = null;   // id => relay.json (only the user's relays)
    private $json = [];

    public static function info()
    {
        return [
            'name' => 'relay_tracking',
            'vendor' => 'p6g9yhk6',
            'version' => '1.0.0',
            'license' => 'GPL-3.0-or-later',
            'uri' => 'https://github.com/P6g9YHK6/roundcube-relay_tracking',
        ];
    }

    public function init()
    {
        $this->rc = rcmail::get_instance();
        $this->load_config();

        if (in_array($this->rc->task, ['mail', 'settings'], true)) {
            $this->register_action('plugin.relay_tracking_unblock', [$this, 'unblock']);
            $this->register_action('plugin.relay_tracking_status', [$this, 'status']);
        }
        if ($this->rc->task == 'settings') {
            $this->add_texts('localization/');   // label of the Settings menu entry
            $this->add_hook('settings_actions', [$this, 'settings_actions']);
            $this->register_action('plugin.relay_tracking', [$this, 'settings_page']);
            if ($this->rc->output->type == 'html' && $this->relays()) {
                $this->include_stylesheet('relay_tracking.css');   // menu icon
            }
            return;
        }

        if ($this->rc->output->type != 'html' || !$this->relays()) {
            return;
        }
        $this->include_stylesheet('relay_tracking.css');
        $this->include_script('relay_tracking.js');

        if (in_array($this->rc->action, ['show', 'preview'], true)) {
            $this->add_hook('message_load', [$this, 'message_env']);
        }
        elseif ($this->rc->action == 'compose') {
            $this->compose_env();
        }
        elseif ($this->rc->action == '' || $this->rc->action == 'list') {
            $this->alert_env();
        }
    }

    // ------------------------------------------------------------------ relays and cache

    private function dir()
    {
        return rtrim((string) $this->rc->config->get('relay_tracking_dir', '/var/roundcube/relays'), '/');
    }

    private static function domain_of($email)
    {
        $pos = strrpos((string) $email, '@');
        return $pos === false ? '' : strtolower(substr($email, $pos + 1));
    }

    /** Addresses of the user's identities (lower case). */
    private function my_emails()
    {
        return array_map(function ($i) { return strtolower((string) ($i['email'] ?? '')); },
            (array) $this->rc->user->list_emails());
    }

    /**
     * Relays relevant to the user: relay.json in a known format, with a domain matching one of the user's identities.
     * id => description; empty when none (the plugin then shows nothing).
     */
    private function relays()
    {
        if ($this->relays !== null) {
            return $this->relays;
        }
        $this->relays = [];
        if (empty($this->rc->user->ID) || !is_dir($this->dir())) {
            return $this->relays;
        }
        $mine = array_unique(array_map([__CLASS__, 'domain_of'], $this->my_emails()));
        foreach ((array) glob($this->dir() . '/*/relay.json') as $file) {
            $id = basename(dirname($file));
            $data = json_decode((string) @file_get_contents($file), true);
            if (!preg_match('/^[a-z0-9_-]{1,32}$/', $id) || !is_array($data) || (int) ($data['format'] ?? 0) !== self::FORMAT) {
                continue;
            }
            $domains = array_values(array_filter(array_map('strtolower', (array) ($data['domains'] ?? []))));
            if (array_intersect($domains, $mine)) {
                $this->relays[$id] = [
                    'id' => $id,
                    'name' => (string) ($data['name'] ?? $id),
                    'domains' => $domains,
                    'capabilities' => array_values(array_map('strval', (array) ($data['capabilities'] ?? []))),
                    'lag' => (string) ($data['lag'] ?? ''),
                ];
            }
        }
        ksort($this->relays);
        return $this->relays;
    }

    /** Relay serving a domain (or null). */
    private function relay_for_domain($domain)
    {
        foreach ($this->relays() as $id => $r) {
            if (in_array($domain, $r['domains'], true)) {
                return $id;
            }
        }
        return null;
    }

    private function can($relay, $capability)
    {
        return in_array($capability, $this->relays()[$relay]['capabilities'] ?? [], true);
    }

    /** JSON file of a relay (read once per request). */
    private function cache($relay, $name)
    {
        $key = $relay . '/' . $name;
        if (!array_key_exists($key, $this->json)) {
            $file = $this->dir() . '/' . $relay . '/' . $name . '.json';
            $data = is_readable($file) ? json_decode((string) file_get_contents($file), true) : null;
            $this->json[$key] = is_array($data) ? $data : null;
        }
        return $this->json[$key];
    }

    private function reason_label($reason)
    {
        return $this->gettext('reason_' . (in_array($reason, self::REASONS, true) ? $reason : 'other'));
    }

    /**
     * Contacts blocked by a relay: email => {reason, label, detail, at, removable, own}.
     * removable false: block the relay API cannot lift (e.g. spam complaint at Postmark or Lettermint).
     * own: blocked while sending from one of the user's identities, or the relay does not say who sent (no "sender"),
     * or relay_tracking_show_all_blocked is on. Only own contacts are listed, alerted on and unblockable by the user;
     * the compose warning covers every contact, since the relay blocks them for every sender.
     */
    private function blocked($relay)
    {
        $all = (bool) $this->rc->config->get('relay_tracking_show_all_blocked', false);
        $mine = $this->my_emails();
        $out = [];
        foreach ((array) ($this->cache($relay, 'blocked')['contacts'] ?? []) as $c) {
            $email = strtolower((string) ($c['email'] ?? ''));
            if ($email !== '') {
                $reason = (string) ($c['reason'] ?? 'other');
                $sender = strtolower((string) ($c['sender'] ?? ''));
                $out[$email] = [
                    'reason' => $reason,
                    'label' => $this->reason_label($reason),
                    'detail' => (string) ($c['detail'] ?? ''),
                    'at' => strtotime((string) ($c['at'] ?? '')) ?: 0,
                    'removable' => ($c['removable'] ?? true) !== false,
                    'own' => $all || $sender === '' || in_array($sender, $mine, true),
                ];
            }
        }
        return $out;
    }

    /** Blocked contacts the user may see and unblock (see blocked()). */
    private function own_blocked($relay)
    {
        return array_filter($this->blocked($relay), function ($b) { return $b['own']; });
    }

    /** Pending requests (files the collector has not processed yet): email => timestamp */
    private function pending($relay)
    {
        $out = [];
        foreach ((array) glob($this->dir() . '/' . $relay . '/requests/*.json') as $file) {
            if (is_file($file) && !is_link($file) && filesize($file) <= 2048) {
                $data = json_decode((string) file_get_contents($file), true);
                if (!empty($data['email'])) {
                    $out[strtolower($data['email'])] = (int) ($data['ts'] ?? filemtime($file));
                }
            }
        }
        return $out;
    }

    /** Latest known unblock result per address: email => {status, at} */
    private function results($relay)
    {
        $out = [];
        foreach ((array) ($this->cache($relay, 'unblock')['requests'] ?? []) as $r) {
            $email = strtolower((string) ($r['email'] ?? ''));
            if ($email !== '' && !isset($out[$email])) {   // newest first
                $out[$email] = ['status' => (string) ($r['status'] ?? ''), 'at' => (int) ($r['at'] ?? 0)];
            }
        }
        return $out;
    }

    // ------------------------------------------------------------------ viewing a sent mail

    /** message_load hook: "relay_tracking_msg" env for the tracking box. */
    public function message_env($p)
    {
        $msg = $p['object'] ?? null;
        if (!$msg || empty($msg->headers)) {
            return $p;
        }
        // draft: not sent yet
        if ((string) $msg->folder === (string) $this->rc->config->get('drafts_mbox')) {
            return $p;
        }

        $h = $msg->headers;
        $from = rcube_mime::decode_address_list((string) $h->from, 1, true, $h->charset, true);
        $from = strtolower((string) (reset($from) ?: ''));   // list indexed from 1 (rcube_mime)
        $relay = $this->relay_for_domain(self::domain_of($from));
        if (!$relay || !in_array($from, $this->my_emails(), true) || !$this->can($relay, 'events')) {
            return $p;   // not a mail we sent through a tracked relay
        }

        $mid = trim((string) $h->messageID);
        if ($mid !== '' && $mid[0] !== '<') {
            $mid = '<' . $mid . '>';
        }
        $events = $this->cache($relay, 'events');
        $per = (array) ($events['messages'][$mid] ?? []);

        // recipients of the message (To, Cc, Bcc) + those that appear in the events
        $rcpts = [];
        foreach (['to', 'cc', 'bcc'] as $field) {
            foreach (rcube_mime::decode_address_list((string) $h->$field, null, true, $h->charset, true) as $addr) {
                $rcpts[strtolower((string) $addr)] = true;
            }
        }
        // "*" = events without a specific recipient (relays that do not provide one): they apply to everyone
        $all = (array) ($per['*'] ?? []);
        unset($per['*']);
        foreach (array_keys($per) as $addr) {
            $rcpts[strtolower($addr)] = true;
        }

        $blocked = $this->can($relay, 'blocked') ? $this->blocked($relay) : [];
        $pending = $this->pending($relay);
        $results = $this->results($relay);
        $out = [];
        foreach (array_keys($rcpts) as $addr) {
            if (rcube_utils::check_email($addr, false)) {
                $b = $blocked[$addr] ?? null;
                $out[] = [
                    'email' => $addr,
                    'events' => array_values(array_merge($all, (array) ($per[$addr] ?? []))),
                    'blocked' => $b ? ['label' => $b['label'], 'detail' => $b['detail'], 'at' => $b['at'],
                        'unblockable' => $b['removable'] && $b['own']] : null,
                    'pending' => isset($pending[$addr]),
                    // unblocked since (and no longer blocked): earlier problems are shown as resolved
                    'unblocked_at' => !$b && ($results[$addr]['status'] ?? '') === 'unblocked'
                        ? $results[$addr]['at'] : 0,
                ];
            }
        }

        $days = (int) ($events['days'] ?? 30);
        $generated = (int) ($events['generated'] ?? 0);
        // start of the window the collector covers: "since" when it had to stop paging before the end of the
        // window (too many events), otherwise the full "days" window
        $since = max((int) ($events['since'] ?? 0), $generated - $days * 86400);
        $wait = (int) $this->rc->config->get('relay_tracking_untracked_after', 86400);
        $none = empty($per) && empty($all);
        $expired = $none && $h->timestamp && $h->timestamp < $since;
        $this->rc->output->set_env('relay_tracking_msg', [
            'relay' => $relay,
            'name' => $this->relays()[$relay]['name'],
            'lag' => $this->relays()[$relay]['lag'],
            'unblock' => $this->can($relay, 'unblock'),
            'recipients' => $out,
            'known' => !$none,
            'expired' => $expired,
            // unknown to the relay long after sending: sent before the relay was in use or through another relay.
            // Before that delay: "pending" (Brevo publishes events up to ~1 h 20 after sending, blocks are immediate)
            'untracked' => $none && !$expired && $h->timestamp && $generated > $h->timestamp + $wait,
            'days' => $since && $generated ? max(1, (int) floor(($generated - $since) / 86400)) : $days,
        ]);
        $this->add_texts('localization/', true);

        return $p;
    }

    // ------------------------------------------------------------------ compose + alert

    /** Compose: blocked contacts by sender domain (domain => email => {label, at, unblockable}). */
    private function compose_env()
    {
        $list = [];
        foreach ($this->relays() as $id => $r) {
            if (!$this->can($id, 'blocked')) {
                continue;
            }
            $blocked = [];
            foreach ($this->blocked($id) as $email => $b) {
                $blocked[$email] = ['label' => $b['label'], 'at' => $b['at'], 'unblockable' => $b['removable'] && $b['own']];
            }
            foreach ($r['domains'] as $domain) {
                $list[$domain] = ['relay' => $id, 'name' => $r['name'], 'unblock' => $this->can($id, 'unblock'),
                    'contacts' => (object) $blocked];
            }
        }
        $this->rc->output->set_env('relay_tracking_blocked', (object) $list);
        $this->add_texts('localization/', true);
    }

    /** Mail list: contacts blocked since the last visit to "Blocked contacts". */
    private function alert_env()
    {
        $seen = (array) $this->rc->config->get('relay_tracking_seen', []);
        $count = 0;
        $emails = [];
        foreach ($this->relays() as $id => $r) {
            foreach ($this->can($id, 'blocked') ? $this->own_blocked($id) : [] as $email => $b) {
                if ($b['at'] > (int) ($seen[$id] ?? 0)) {
                    $count++;
                    $emails[] = $email;
                }
            }
        }
        if ($count) {
            $this->rc->output->set_env('relay_tracking_alert', ['count' => $count, 'emails' => array_slice($emails, 0, 3)]);
            $this->add_texts('localization/', true);
        }
    }

    // ------------------------------------------------------------------ Settings > Blocked contacts

    public function settings_actions($args)
    {
        if ($this->relays()) {
            $args['actions'][] = [
                'action' => 'plugin.relay_tracking',
                'class' => 'relay-tracking',
                'label' => 'blocked',
                'title' => 'blocked_title',
                'domain' => 'relay_tracking',
            ];
        }
        return $args;
    }

    public function settings_page()
    {
        $this->add_texts('localization/', true);
        if ($this->relays()) {
            $this->include_stylesheet('relay_tracking.css');
            $this->include_script('relay_tracking.js');
            $this->rc->output->set_pagetitle($this->gettext('blocked'));

            // seen: the "new blocked contact" alert goes away
            $seen = (array) $this->rc->config->get('relay_tracking_seen', []);
            $changed = false;
            foreach (array_keys($this->relays()) as $id) {
                $at = array_column($this->own_blocked($id), 'at');
                if ($at && max($at) > (int) ($seen[$id] ?? 0)) {
                    $seen[$id] = max($at);
                    $changed = true;
                }
            }
            if ($changed) {
                $this->rc->user->save_prefs(['relay_tracking_seen' => $seen]);
            }
            $this->rc->output->add_handlers(['plugin.body' => [$this, 'settings_body']]);
        }
        $this->rc->output->send('plugin');
    }

    public function settings_body()
    {
        $fmt = function ($ts) { return $ts ? $this->rc->format_date($ts) : ''; };
        $html = html::tag('h2', 'rt-title', rcube::Q($this->gettext('blocked_title')));

        foreach ($this->relays() as $id => $r) {
            $domains = implode(', ', $r['domains']);
            $html .= html::tag('h3', 'rt-relay', rcube::Q($r['name'] . ' · ' . $domains));

            if (!$this->can($id, 'blocked')) {
                $html .= html::p('rt-hint', rcube::Q($this->gettext(['name' => 'no_blocked_list', 'vars' => ['relay' => $r['name']]])));
                continue;
            }
            $html .= html::p('rt-hint', rcube::Q($this->gettext(['name' => 'blocked_hint',
                'vars' => ['relay' => $r['name'], 'domains' => $domains]])));

            $blocked = $this->own_blocked($id);
            $pending = $this->pending($id);
            $unblock = $this->can($id, 'unblock');
            if (!$blocked) {
                $html .= html::p('rt-empty', rcube::Q($this->gettext('blocked_none')));
            }
            else {
                $table = new html_table(['class' => 'rt-table', 'cols' => 4]);
                $table->add_header(null, rcube::Q($this->gettext('col_email')));
                $table->add_header(null, rcube::Q($this->gettext('col_reason')));
                $table->add_header(null, rcube::Q($this->gettext('col_since')));
                $table->add_header(null, '');
                foreach ($blocked as $email => $b) {
                    $table->add_row(['data-email' => $email]);
                    $table->add('rt-email', rcube::Q($email));
                    $table->add(['class' => 'rt-reason', 'title' => $b['detail']], rcube::Q($b['label']));
                    $table->add('rt-date', rcube::Q($fmt($b['at'])));
                    $table->add('rt-action', !$unblock || !$b['removable'] ? '' : (isset($pending[$email])
                        ? html::span(['class' => 'rt-pending', 'data-relay' => $id, 'data-email' => $email],
                            rcube::Q($this->gettext('pending')))
                        : html::tag('button', ['type' => 'button', 'class' => 'btn btn-secondary rt-unblock',
                            'data-relay' => $id, 'data-email' => $email], rcube::Q($this->gettext('unblock')))));
                }
                $html .= $table->show();
            }

            $results = array_intersect_key($this->results($id), $this->visible_results($id));
            if ($results) {
                $list = '';
                foreach (array_slice($results, 0, 10, true) as $email => $res) {
                    $status = in_array($res['status'], self::RESULTS, true) ? $res['status'] : 'error';
                    $list .= html::tag('li', null, html::span('rt-email', rcube::Q($email)) . ': '
                        . rcube::Q($this->gettext('st_' . $status)) . html::span('rt-date', ' · ' . rcube::Q($fmt($res['at']))));
                }
                $html .= html::tag('h4', 'rt-sub', rcube::Q($this->gettext('history'))) . html::tag('ul', 'rt-history', $list);
            }
            $gen = (int) ($this->cache($id, 'blocked')['generated'] ?? 0);
            $html .= html::p('rt-foot', rcube::Q($this->gettext(['name' => 'updated', 'vars' => ['date' => $fmt($gen) ?: '-']])));
        }

        return html::div(['id' => 'relay-tracking', 'class' => 'formcontent scroller'], $html);
    }

    /** Unblock results the user may see: their own requests, or all of them with relay_tracking_show_all_blocked. */
    private function visible_results($relay)
    {
        $all = (bool) $this->rc->config->get('relay_tracking_show_all_blocked', false);
        $me = strtolower((string) $this->rc->get_user_name());
        $out = [];
        foreach ((array) ($this->cache($relay, 'unblock')['requests'] ?? []) as $r) {
            if ($all || strtolower((string) ($r['user'] ?? '')) === $me) {
                $out[strtolower((string) ($r['email'] ?? ''))] = true;
            }
        }
        return $out;
    }

    // ------------------------------------------------------------------ AJAX actions (token checked by Roundcube)

    private function input_relay()
    {
        $relay = (string) rcube_utils::get_input_string('_relay', rcube_utils::INPUT_POST);
        return isset($this->relays()[$relay]) ? $relay : null;
    }

    /** Drops an unblock request for the relay's collector (processed within a minute). */
    public function unblock()
    {
        $relay = $this->input_relay();
        $email = strtolower(trim((string) rcube_utils::get_input_string('_email', rcube_utils::INPUT_POST)));
        $status = 'error';

        if ($relay && $this->can($relay, 'unblock') && rcube_utils::check_email($email, false)) {
            $pending = $this->pending($relay);
            $blocked = $this->blocked($relay);
            if (isset($pending[$email])) {
                $status = 'pending';
            }
            elseif (!isset($blocked[$email])) {
                $status = 'not_blocked';
            }
            elseif (!$blocked[$email]['removable'] || !$blocked[$email]['own']) {
                $status = 'error';   // the relay API cannot lift it, or another sender's contact (no button then)
            }
            elseif (count($pending) < 20) {
                $file = $this->dir() . '/' . $relay . '/requests/' . time() . '-' . bin2hex(random_bytes(4)) . '.json';
                $data = json_encode(['email' => $email, 'user' => (string) $this->rc->get_user_name(), 'ts' => time()]);
                if (@file_put_contents($file . '.tmp', $data) !== false && @rename($file . '.tmp', $file)) {
                    $status = 'pending';
                }
            }
        }

        if ($status == 'error') {
            $this->add_texts('localization/');
            $this->rc->output->show_message('relay_tracking.unblock_failed', 'error');
        }
        $this->rc->output->command('plugin.relay_tracking_state', ['relay' => $relay, 'states' => [$email => $status]]);
        $this->rc->output->send();
    }

    /** State of the requested addresses: pending | blocked | unblocked | not_blocked | error_... */
    public function status()
    {
        $relay = $this->input_relay();
        $emails = array_slice(array_filter(array_map('strtolower', explode(',',
            (string) rcube_utils::get_input_string('_emails', rcube_utils::INPUT_POST)))), 0, 50);
        $states = [];

        if ($relay) {
            $blocked = $this->blocked($relay);
            $pending = $this->pending($relay);
            $results = $this->results($relay);
            foreach ($emails as $email) {
                if (isset($pending[$email])) {
                    $states[$email] = 'pending';
                }
                elseif (isset($blocked[$email])) {
                    $states[$email] = 'blocked';
                }
                else {
                    $states[$email] = $results[$email]['status'] ?? 'not_blocked';
                }
            }
        }

        $this->rc->output->command('plugin.relay_tracking_state', ['relay' => $relay, 'states' => $states]);
        $this->rc->output->send();
    }
}
