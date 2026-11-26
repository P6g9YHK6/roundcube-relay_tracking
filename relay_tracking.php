<?php

/**
 * relay_tracking
 *
 * Per recipient delivery tracking of sent mail (sent, delivered, opened, clicks, bounces, spam complaint,
 * unsubscribe) for mail that goes out through a transactional SMTP relay (Brevo, ...).
 *
 * Roundcube never holds a relay API key. One collector per relay (a server-side script, see README.md) writes into
 * a shared folder, in the COMMON FORMAT v1:
 *
 *   <relay_tracking_dir>/<relay>/relay.json    description: name, domains served, capabilities, publication delay
 *   <relay_tracking_dir>/<relay>/events.json   events by Message-ID, then by recipient (normalised types)
 *   <relay_tracking_dir>/<relay>/archive/      events older than events.json's window, one file per Message-ID hash
 *
 * When viewing a SENT mail from an identity on a relay's domain, a "Delivery tracking" box shows each recipient's
 * events, with the IP address on hover when the collector includes it (off by default).
 *
 * SELF TRACKING (relay_tracking_self, off by default): when sending, the plugin itself adds an open pixel and
 * rewrites the links of the HTML part to Roundcube (?_task=relay_tracking), which records the hits in its database
 * (SQL/) and shows them in the same box, alone or next to a relay's events.
 *
 * @author P6g9YHK6
 * @license GNU GPLv3+
 *
 * Copyright (C) P6g9YHK6
 *
 * This program is a Roundcube (https://roundcube.net) plugin.
 * For more information see README.md.
 * For configuration see config.inc.php.dist.
 *
 * This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any
 * later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with this program. If not, see
 * https://www.gnu.org/licenses/.
 */
class relay_tracking extends rcube_plugin
{
    // login, relay_tracking: open pixel and tracked links (recipients have no session, so the task is "login")
    public $task = 'mail|settings|login|relay_tracking';

    private const FORMAT = 1;

    // self tracking: hits kept per mail at most (a pixel URL can be requested by anyone)
    private const SELF_MAX_HITS = 500;

    // self tracking: an open this soon after sending, or by a client giving no detail at all (Apple Mail Privacy
    // Protection), is the recipient's provider loading images on receipt, not a reader
    private const SELF_AUTO_OPEN = 20;
    private const SELF_AUTO_UA = '/^(Mozilla\/5\.0)?$/';

    // 1x1 transparent GIF
    private const PIXEL = 'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

    private $rc;
    private $relays = null;   // id => relay.json (only the user's relays)

    public static function info()
    {
        return [
            'name' => 'relay_tracking',
            'vendor' => 'p6g9yhk6',
            'version' => '2.7.0',
            'license' => 'GPL-3.0-or-later',
            'uri' => 'https://github.com/P6g9YHK6/roundcube-relay_tracking',
        ];
    }

    public function init()
    {
        $this->rc = rcmail::get_instance();

        // self tracking: open pixel and tracked links, answered before Roundcube asks for a login
        if (rcube_utils::get_input_string('_task', rcube_utils::INPUT_GET) === 'relay_tracking') {
            $this->add_hook('startup', [$this, 'self_hit']);
            return;
        }
        if ($this->rc->task == 'login') {
            return;
        }

        // Settings > Preferences: what the tracking box shows of the IP addresses (Displaying Messages), self
        // tracking by default (Composing Messages)
        if ($this->rc->task == 'settings') {
            $this->add_hook('preferences_list', [$this, 'preferences_list']);
            $this->add_hook('preferences_save', [$this, 'preferences_save']);
            return;
        }

        // sending: headers some relays need to report the mail's Message-ID (relay.json "headers"), self tracking
        if ($this->rc->action == 'send') {
            $this->load_config();
            $this->add_hook('message_before_send', [$this, 'add_headers']);
            $this->add_hook('message_before_send', [$this, 'self_track']);
            return;
        }

        // compose: "Track opens and clicks" in the options
        if ($this->rc->action == 'compose') {
            $this->load_config();
            $this->compose_option();
            return;
        }

        if ($this->rc->output->type != 'html' || !in_array($this->rc->action, ['show', 'preview'], true)) {
            return;
        }
        $this->load_config();
        if (!$this->relays() && !$this->self_enabled()) {
            return;
        }
        $this->include_stylesheet($this->local_skin_path() . '/relay_tracking.css');
        $this->include_script('relay_tracking.js');
        $this->add_hook('message_load', [$this, 'message_env']);
    }

    private function dir()
    {
        return rtrim((string) $this->rc->config->get('relay_tracking_dir', '/var/roundcube/relays'), '/');
    }

    private static function domain_of($email)
    {
        $pos = strrpos((string) $email, '@');
        return $pos === false ? '' : strtolower(substr($email, $pos + 1));
    }

    /** Message-ID with its angle brackets, as the collectors key it ('' when none). */
    private static function message_id($mid)
    {
        $mid = trim((string) $mid);
        return $mid !== '' && $mid[0] !== '<' ? '<' . $mid . '>' : $mid;
    }

    /** Addresses of the user's identities (lower case). */
    private function my_emails()
    {
        return array_map(function ($i) { return strtolower((string) ($i['email'] ?? '')); },
            (array) $this->rc->user->list_emails());
    }

    /**
     * Relays relevant to the user: relay.json in a known format, with the "events" capability and a domain matching
     * one of the user's identities. id => description; empty when none (the plugin then shows nothing).
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
            if (!preg_match('/^[a-z0-9_-]{1,32}$/', $id) || !is_array($data) || (int) ($data['format'] ?? 0) !== self::FORMAT
                || !in_array('events', (array) ($data['capabilities'] ?? []), true)) {
                continue;
            }
            $domains = array_values(array_filter(array_map('strtolower', (array) ($data['domains'] ?? []))));
            if (array_intersect($domains, $mine)) {
                // headers to add when sending: X- names only, one line values
                $headers = [];
                foreach ((array) ($data['headers'] ?? []) as $name => $value) {
                    if (is_string($value) && preg_match('/^X-[A-Za-z0-9_-]{1,64}$/', (string) $name)
                        && strlen($value) <= 500 && !preg_match('/[\x00-\x1f]/', $value)) {
                        $headers[$name] = $value;
                    }
                }
                $this->relays[$id] = [
                    'name' => (string) ($data['name'] ?? $id),
                    'domains' => $domains,
                    'lag' => (string) ($data['lag'] ?? ''),
                    'headers' => $headers,
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

    /**
     * message_before_send hook: for relays that do not report the Message-ID, the headers their collector asks for
     * (relay.json "headers"), "{message_id}" replaced by the mail's Message-ID. The relays remove them before delivery.
     */
    public function add_headers($args)
    {
        $message = $args['message'] ?? null;
        if (!is_object($message) || !method_exists($message, 'headers')) {
            return $args;
        }
        $headers = (array) $message->headers();
        $mid = self::message_id($headers['Message-ID'] ?? '');
        $from = (string) ($args['from'] ?? '');
        if ($from === '') {
            $list = rcube_mime::decode_address_list((string) ($headers['From'] ?? ''), 1, true, null, true);
            $from = (string) (reset($list) ?: '');
        }
        $relay = $this->relay_for_domain(self::domain_of($from));
        if ($mid === '' || !$relay || empty($this->relays()[$relay]['headers'])) {
            return $args;
        }
        // safe inside the JSON some relays expect (Mailgun, SendGrid)
        $mid = preg_replace('/[\x00-\x1f"\\\\]/', '', $mid);
        $add = [];
        foreach ($this->relays()[$relay]['headers'] as $name => $value) {
            $add[$name] = str_replace('{message_id}', $mid, $value);
        }
        $message->headers($add, true);
        $args['message'] = $message;
        return $args;
    }

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
        if (!in_array($from, $this->my_emails(), true)) {
            return $p;   // not a mail we sent
        }
        $relay = $this->relay_for_domain(self::domain_of($from));
        $mid = self::message_id($h->messageID);
        $self = $this->self_events($mid);
        if (!$relay && $self === null) {
            return $p;   // neither sent through a tracked relay nor tracked by Roundcube
        }

        $events = [];
        if ($relay) {
            $file = $this->dir() . '/' . $relay . '/events.json';
            $events = is_readable($file) ? json_decode((string) file_get_contents($file), true) : null;
            $events = is_array($events) ? $events : [];
        }
        $per = (array) ($events['messages'][$mid] ?? []);
        // events the relay no longer has, kept by the collector: before the window's, and their IPs' hosts
        if ($relay && !empty($events['archive'])) {
            $old_hosts = [];
            foreach ($this->archived($relay, $mid, $old_hosts) as $addr => $list) {
                $per[$addr] = array_merge($list, (array) ($per[$addr] ?? []));
            }
            $events['hosts'] = (array) ($events['hosts'] ?? []) + $old_hosts;
        }

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
        // Roundcube's own pixel and links: one body for all recipients, so the hits belong to none in particular
        if ($self !== null) {
            // the relay has its own "sent"
            $all = array_merge($all, $relay ? array_values(array_filter($self, function ($ev) {
                return $ev[1] !== 'sent';
            })) : $self);
        }
        $rcpts = array_values(array_filter(array_keys($rcpts), function ($addr) {
            return rcube_utils::check_email($addr, false);
        }));
        // without a relay, all the events are Roundcube's: one row for all the recipients
        $rows = [];
        if ($relay) {
            foreach ($rcpts as $addr) {
                $rows[$addr] = array_merge($all, (array) ($per[$addr] ?? []));
            }
        }
        else if ($rcpts) {
            $rows[implode(', ', $rcpts)] = $all;
        }

        // user preferences: IP addresses, who they belong to, where they are
        $show_ip = (bool) $this->rc->config->get('relay_tracking_show_ip', true);
        $show_owner = $show_ip && (bool) $this->rc->config->get('relay_tracking_show_owner', true);
        $show_location = $show_ip && (bool) $this->rc->config->get('relay_tracking_show_location', true);

        $out = [];
        $hosts = [];   // reverse DNS / provider of the IPs this mail's events carry (only those)
        foreach ($rows as $addr => $list) {
            $list = array_values($list);
            // events without a recipient (and Roundcube's hits) among the recipient's own: back in date order
            usort($list, function ($a, $b) {
                return strtotime((string) ($a[0] ?? '')) <=> strtotime((string) ($b[0] ?? ''));
            });
            if (!$show_ip) {
                $list = array_map(function ($ev) { return array_slice((array) $ev, 0, 3); }, $list);
            }
            foreach ($list as $ev) {
                $ip = (string) ($ev[3] ?? '');
                if ($ip === '' || !isset($events['hosts'][$ip]) || !is_array($events['hosts'][$ip])) {
                    continue;
                }
                $host = $events['hosts'][$ip];
                $hosts[$ip] = [];
                if ($show_owner) {
                    $hosts[$ip]['rdns'] = (string) ($host['rdns'] ?? '');
                    $hosts[$ip]['provider'] = (string) ($host['provider'] ?? '');
                }
                if ($show_location) {
                    // "City, Region, CC" without the empty or repeated parts (Zurich, Zurich, CH > Zurich, CH)
                    $parts = array_values(array_unique(array_filter([(string) ($host['city'] ?? ''),
                        (string) ($host['region'] ?? ''), (string) ($host['country'] ?? '')], 'strlen')));
                    $hosts[$ip]['location'] = implode(', ', $parts);
                }
            }
            $out[] = ['email' => (string) $addr, 'events' => $list];
        }

        $days = (int) ($events['days'] ?? 30);
        $generated = (int) ($events['generated'] ?? 0);
        // start of what the collector covers: with an archive, "since"; otherwise "since" when it had to stop paging
        // before the end of the window (too many events), else the full "days" window
        $since = !empty($events['archive']) ? (int) ($events['since'] ?? 0)
            : max((int) ($events['since'] ?? 0), $generated - $days * 86400);
        $wait = (int) $this->rc->config->get('relay_tracking_untracked_after', 86400);
        $none = empty($per) && empty($all);
        $expired = $none && $h->timestamp && $h->timestamp < $since;
        // every event date formatted by Roundcube itself: the user's date/time format, "pretty dates" and timezone
        $dates = [];
        foreach ($out as $r) {
            foreach ($r['events'] as $ev) {
                $iso = (string) ($ev[0] ?? '');
                if ($iso !== '' && !isset($dates[$iso])) {
                    try {
                        $dates[$iso] = $this->rc->format_date(new DateTime($iso));
                    }
                    catch (Exception $e) {
                        // unreadable date: the browser shows it as it came
                    }
                }
            }
        }

        $this->rc->output->set_env('relay_tracking_msg', [
            'name' => $relay ? $this->relays()[$relay]['name'] : 'Roundcube',
            'lag' => $relay ? $this->relays()[$relay]['lag'] : '',
            // Roundcube's pixel and links only: no delivery information, one row for all the recipients
            'self_only' => !$relay,
            'recipients' => $out,
            'hosts' => (object) $hosts,
            'dates' => (object) $dates,
            'known' => !$none,
            'expired' => $expired,
            // unknown to the relay long after sending: sent before the relay was in use or through another relay.
            // Before that delay: "pending" (Brevo publishes events up to ~1 h 20 after sending)
            'untracked' => $none && !$expired && $h->timestamp && $generated > $h->timestamp + $wait,
            'days' => $since && $generated ? max(1, (int) floor(($generated - $since) / 86400)) : $days,
        ]);
        $this->add_texts('localization/', true);

        return $p;
    }

    /**
     * Archived events of a mail: archive/<first 2 hex digits of md5(Message-ID)>.jsonl, one event per line
     * ({m, e, d, t, l, r, i, h?: host of i}). By recipient in the events.json form ([date, type, extra?, ip?]), the
     * hosts added to $hosts. Repeated lines are skipped.
     */
    private function archived($relay, $mid, &$hosts)
    {
        $per = [];
        $file = $this->dir() . '/' . $relay . '/archive/' . substr(md5($mid), 0, 2) . '.jsonl';
        $fh = $mid !== '' && is_readable($file) ? fopen($file, 'r') : false;
        if (!$fh) {
            return $per;
        }
        // the collector writes "m" first: only lines naming this Message-ID are decoded
        $needle = '{"m":' . json_encode($mid, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . ',';
        $seen = [];
        while (($line = fgets($fh)) !== false) {
            $line = trim($line);
            if (strpos($line, $needle) !== 0 || isset($seen[$line])) {
                continue;
            }
            $seen[$line] = true;
            $ev = json_decode($line, true);
            if (!is_array($ev) || ($ev['m'] ?? '') !== $mid) {
                continue;
            }
            $link = (string) ($ev['l'] ?? '');
            $reason = (string) ($ev['r'] ?? '');
            $ip = (string) ($ev['i'] ?? '');
            $item = [(string) ($ev['d'] ?? ''), (string) ($ev['t'] ?? '')];
            if ($ip !== '') {
                array_push($item, $link !== '' ? $link : $reason, $ip);
                if (is_array($ev['h'] ?? null)) {
                    $hosts[$ip] = $ev['h'];
                }
            }
            else if ($link !== '' || $reason !== '') {
                $item[] = $link !== '' ? $link : $reason;
            }
            $per[strtolower((string) ($ev['e'] ?? ''))][] = $item;
        }
        fclose($fh);
        return $per;
    }

    // ------------------------------------------------------------------ self tracking

    private function self_enabled()
    {
        return (bool) $this->rc->config->get('relay_tracking_self', false);
    }

    private function table($name)
    {
        return $this->rc->get_dbh()->table_name($name, true);
    }

    /** Whether the user can choose per mail (compose checkbox), or the admin decided for everyone. */
    private function self_locked()
    {
        return in_array('relay_tracking_self_track', (array) $this->rc->config->get('dont_override', []), true);
    }

    /** Absolute URL of the open pixel or of a tracked link (relay_tracking_self_url when Roundcube sits behind a proxy). */
    private function self_url($action, $token, $link = null)
    {
        $p = ['_task' => 'relay_tracking', '_action' => $action, '_t' => $token];
        if ($link !== null) {
            $p['_l'] = $link;
        }
        $base = trim((string) $this->rc->config->get('relay_tracking_self_url', ''));
        return $base === '' ? $this->rc->url($p, true, true) : rtrim($base, '/') . '/?' . http_build_query($p);
    }

    /** compose: "Track opens and clicks" checkbox in the options, ticked per the user's preference. */
    private function compose_option()
    {
        if (!$this->self_enabled() || $this->self_locked()) {
            return;
        }
        $this->add_texts('localization/');
        $id = 'compose-relay-tracking';
        $check = new html_checkbox(['name' => '_relay_tracking_self', 'id' => $id, 'value' => 1,
            'class' => 'form-check-input', 'tabindex' => 2]);
        $this->api->add_content(html::div('form-group row form-check',
            html::label(['for' => $id, 'class' => 'col-form-label col-6'], rcube::Q($this->gettext('compose_self')))
            . html::div('col-6 form-check', $check->show($this->rc->config->get('relay_tracking_self_track', true) ? 1 : 0))
        ), 'composeoptions');
    }

    /**
     * message_before_send hook: open pixel at the end of the HTML part and its http(s) links through Roundcube, when
     * tracking is ticked for this mail. Mail without an HTML part is left as it is.
     */
    public function self_track($args)
    {
        $message = $args['message'] ?? null;
        if (!$this->self_enabled() || !is_object($message) || !method_exists($message, 'getHTMLBody')) {
            return $args;
        }
        $on = $this->self_locked() ? $this->rc->config->get('relay_tracking_self_track', true)
            : rcube_utils::get_input_value('_relay_tracking_self', rcube_utils::INPUT_POST);
        $html = (string) $message->getHTMLBody();
        $mid = self::message_id(((array) $message->headers())['Message-ID'] ?? '');
        if (empty($on) || $html === '' || $mid === '' || strlen($mid) > 255 || empty($this->rc->user->ID)) {
            return $args;
        }

        $this->self_cleanup();
        $token = bin2hex(random_bytes(16));
        $links = [];
        $html = preg_replace_callback('/(<a\b[^>]*?\shref\s*=\s*)(["\'])(https?:\/\/[^"\']+)\2/i',
            function ($m) use (&$links, $token) {
                $url = html_entity_decode($m[3], ENT_QUOTES | ENT_HTML5, 'UTF-8');
                // kept as it is: anything that could not be sent back as a Location header
                if (strlen($url) > 2048 || preg_match('/[\x00-\x20\x7f]/', $url)) {
                    return $m[0];
                }
                $links[] = $url;
                return $m[1] . $m[2] . htmlspecialchars($this->self_url('click', $token, count($links) - 1)) . $m[2];
            }, $html);
        $pixel = '<img src="' . htmlspecialchars($this->self_url('open', $token)) . '" width="1" height="1" alt=""'
            . ' style="display:block;width:1px;height:1px;border:0">';
        $end = strripos($html, '</body>');
        $html = $end === false ? $html . $pixel : substr_replace($html, $pixel, $end, 0);

        $db = $this->rc->get_dbh();
        $db->query('INSERT INTO ' . $this->table('relay_tracking_mail')
            . ' (token, user_id, message_id, links, created) VALUES (?, ?, ?, ?, ?)',
            $token, $this->rc->user->ID, $mid, json_encode($links, JSON_UNESCAPED_SLASHES), gmdate('Y-m-d H:i:s'));
        if ($db->is_error()) {
            return $args;   // not recorded: sent untracked rather than with links nobody can follow
        }
        $message->setHTMLBody($html);
        $args['message'] = $message;
        return $args;
    }

    /** Tracking older than relay_tracking_self_days is dropped (done when sending, the only time rows are added). */
    private function self_cleanup()
    {
        $days = (int) $this->rc->config->get('relay_tracking_self_days', 90);
        if ($days <= 0) {
            return;
        }
        $db = $this->rc->get_dbh();
        $before = gmdate('Y-m-d H:i:s', time() - $days * 86400);
        $mail = $this->table('relay_tracking_mail');
        $db->query('DELETE FROM ' . $this->table('relay_tracking_hit')
            . " WHERE token IN (SELECT token FROM $mail WHERE created < ?)", $before);
        $db->query("DELETE FROM $mail WHERE created < ?", $before);
    }

    /**
     * startup hook for ?_task=relay_tracking: records an open (_action=open) or a click (_action=click, _l = link
     * number) and answers with the pixel or a redirect. Only links stored when sending are followed, so it is no open
     * redirect. Requests from the sender's own session (their Sent copy) are not recorded.
     */
    public function self_hit($args)
    {
        $this->load_config();
        $action = (string) rcube_utils::get_input_string('_action', rcube_utils::INPUT_GET);
        $token = (string) rcube_utils::get_input_string('_t', rcube_utils::INPUT_GET);
        $db = $this->rc->get_dbh();

        $row = null;
        if ($this->self_enabled() && preg_match('/^[0-9a-f]{32}$/', $token)) {
            $res = $db->query('SELECT user_id, links, created FROM ' . $this->table('relay_tracking_mail')
                . ' WHERE token = ?', $token);
            $row = $db->fetch_assoc($res) ?: null;
        }
        $url = null;
        if ($row && $action == 'click') {
            $links = json_decode((string) $row['links'], true);
            $l = (string) rcube_utils::get_input_string('_l', rcube_utils::INPUT_GET);
            if (ctype_digit($l) && is_array($links) && is_string($links[(int) $l] ?? null)) {
                $url = $links[(int) $l];
            }
        }

        if ($row && ($action == 'open' || $url !== null) && (int) $row['user_id'] !== (int) $this->rc->get_user_id()) {
            $res = $db->query('SELECT COUNT(*) AS n FROM ' . $this->table('relay_tracking_hit') . ' WHERE token = ?', $token);
            if ((int) (($db->fetch_assoc($res) ?: [])['n'] ?? 0) < self::SELF_MAX_HITS) {
                $type = 'clicked';
                if ($action == 'open') {
                    $age = time() - (int) strtotime($row['created'] . ' UTC');
                    $auto = $age < self::SELF_AUTO_OPEN || preg_match(self::SELF_AUTO_UA, (string) ($_SERVER['HTTP_USER_AGENT'] ?? ''));
                    $type = $auto ? 'proxy_open' : 'opened';
                }
                $db->query('INSERT INTO ' . $this->table('relay_tracking_hit')
                    . ' (token, created, type, extra, ip) VALUES (?, ?, ?, ?, ?)',
                    $token, gmdate('Y-m-d H:i:s'), $type, $url,
                    $this->rc->config->get('relay_tracking_self_ip', false) ? rcube_utils::remote_addr() : null);
            }
        }

        // no session row for each recipient's request
        if (session_status() == PHP_SESSION_ACTIVE) {
            session_abort();
        }
        while (ob_get_level()) {
            ob_end_clean();
        }
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Referrer-Policy: no-referrer');
        if ($action == 'click') {
            if ($url === null) {
                http_response_code(404);
                header('Content-Type: text/plain; charset=UTF-8');
                echo "Not found\n";
            }
            else {
                header('Location: ' . $url, true, 302);
            }
        }
        else {
            header('Content-Type: image/gif');
            echo base64_decode(self::PIXEL);
        }
        exit;
    }

    /**
     * Roundcube's own tracking of a sent mail as common format events (sent, then each hit in date order), or null
     * when it was not tracked.
     */
    private function self_events($mid)
    {
        if (!$this->self_enabled() || $mid === '') {
            return null;
        }
        $db = $this->rc->get_dbh();
        $res = $db->query('SELECT token, created FROM ' . $this->table('relay_tracking_mail')
            . ' WHERE user_id = ? AND message_id = ?', $this->rc->user->ID, $mid);
        $mail = $db->fetch_assoc($res);
        if (!$mail) {
            return null;
        }
        $iso = function ($date) { return gmdate('Y-m-d\TH:i:s\Z', (int) strtotime($date . ' UTC')); };
        $events = [[$iso($mail['created']), 'sent']];
        $res = $db->query('SELECT created, type, extra, ip FROM ' . $this->table('relay_tracking_hit')
            . ' WHERE token = ? ORDER BY created, hit_id', $mail['token']);
        while ($hit = $db->fetch_assoc($res)) {
            $ev = [$iso($hit['created']), (string) $hit['type'], (string) $hit['extra']];
            if ((string) $hit['ip'] !== '') {
                $ev[] = (string) $hit['ip'];
            }
            $events[] = $ev;
        }
        return $events;
    }

    // ------------------------------------------------------------------ preferences

    private const PREFS = [
        'mailview' => ['relay_tracking_show_ip', 'relay_tracking_show_owner', 'relay_tracking_show_location'],
        'compose' => ['relay_tracking_self_track'],
    ];

    /** Preferences of a section the user has a use for: the box's (a tracked relay or self tracking), self tracking's. */
    private function prefs($section)
    {
        $this->load_config();
        if (empty(self::PREFS[$section]) || !($section == 'compose' ? $this->self_enabled()
            : $this->relays() || $this->self_enabled())) {
            return [];
        }
        $locked = (array) $this->rc->config->get('dont_override', []);
        return array_values(array_diff(self::PREFS[$section], $locked));
    }

    /**
     * preferences_list hook: "Delivery tracking" block in Displaying Messages (what the box shows) and in Composing
     * Messages (self tracking ticked by default)
     */
    public function preferences_list($args)
    {
        $prefs = $this->prefs($args['section']);
        if (!$prefs) {
            return $args;
        }
        $this->add_texts('localization/');
        $options = [];
        foreach ($prefs as $pref) {
            $id = 'rcmfd_' . $pref;
            $check = new html_checkbox(['name' => '_' . $pref, 'id' => $id, 'value' => 1]);
            $options[$pref] = [
                'title' => html::label($id, rcube::Q($this->gettext('pref_' . substr($pref, strlen('relay_tracking_'))))),
                'content' => $check->show($this->rc->config->get($pref, true) ? 1 : 0),
            ];
        }
        $args['blocks']['relay_tracking'] = ['name' => rcube::Q($this->gettext('pref_block')), 'options' => $options];
        return $args;
    }

    /** preferences_save hook */
    public function preferences_save($args)
    {
        foreach ($this->prefs($args['section']) as $pref) {
            $args['prefs'][$pref] = !empty(rcube_utils::get_input_value('_' . $pref, rcube_utils::INPUT_POST));
        }
        return $args;
    }
}
