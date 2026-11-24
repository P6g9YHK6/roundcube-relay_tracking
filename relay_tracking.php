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
 *
 * When viewing a SENT mail from an identity on a relay's domain, a "Delivery tracking" box shows each recipient's
 * events, with the IP address on hover when the collector includes it (off by default).
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
    public $task = 'mail|settings';

    private const FORMAT = 1;

    private $rc;
    private $relays = null;   // id => relay.json (only the user's relays)

    public static function info()
    {
        return [
            'name' => 'relay_tracking',
            'vendor' => 'p6g9yhk6',
            'version' => '2.1.0',
            'license' => 'GPL-3.0-or-later',
            'uri' => 'https://github.com/P6g9YHK6/roundcube-relay_tracking',
        ];
    }

    public function init()
    {
        $this->rc = rcmail::get_instance();

        // Settings > Preferences > Displaying Messages: what the tracking box shows of the IP addresses
        if ($this->rc->task == 'settings') {
            $this->add_hook('preferences_list', [$this, 'preferences_list']);
            $this->add_hook('preferences_save', [$this, 'preferences_save']);
            return;
        }

        if ($this->rc->output->type != 'html' || !in_array($this->rc->action, ['show', 'preview'], true)) {
            return;
        }
        $this->load_config();
        if (!$this->relays()) {
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
                $this->relays[$id] = [
                    'name' => (string) ($data['name'] ?? $id),
                    'domains' => $domains,
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
        if (!$relay || !in_array($from, $this->my_emails(), true)) {
            return $p;   // not a mail we sent through a tracked relay
        }

        $mid = trim((string) $h->messageID);
        if ($mid !== '' && $mid[0] !== '<') {
            $mid = '<' . $mid . '>';
        }
        $file = $this->dir() . '/' . $relay . '/events.json';
        $events = is_readable($file) ? json_decode((string) file_get_contents($file), true) : null;
        $events = is_array($events) ? $events : [];
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

        // user preferences: IP addresses, and who they belong to
        $show_ip = (bool) $this->rc->config->get('relay_tracking_show_ip', true);
        $show_owner = $show_ip && (bool) $this->rc->config->get('relay_tracking_show_owner', true);

        $out = [];
        $hosts = [];   // reverse DNS / provider of the IPs this mail's events carry (only those)
        foreach (array_keys($rcpts) as $addr) {
            if (rcube_utils::check_email($addr, false)) {
                $list = array_values(array_merge($all, (array) ($per[$addr] ?? [])));
                if (!$show_ip) {
                    $list = array_map(function ($ev) { return array_slice((array) $ev, 0, 3); }, $list);
                }
                foreach ($list as $ev) {
                    $ip = (string) ($ev[3] ?? '');
                    if ($show_owner && $ip !== '' && isset($events['hosts'][$ip]) && is_array($events['hosts'][$ip])) {
                        $hosts[$ip] = [
                            'rdns' => (string) ($events['hosts'][$ip]['rdns'] ?? ''),
                            'provider' => (string) ($events['hosts'][$ip]['provider'] ?? ''),
                        ];
                    }
                }
                $out[] = ['email' => $addr, 'events' => $list];
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
            'name' => $this->relays()[$relay]['name'],
            'lag' => $this->relays()[$relay]['lag'],
            'recipients' => $out,
            'hosts' => (object) $hosts,
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

    // ------------------------------------------------------------------ preferences

    private const PREFS = ['relay_tracking_show_ip', 'relay_tracking_show_owner'];

    /** preferences_list hook: "Delivery tracking" block in Displaying Messages, for users with a tracked relay */
    public function preferences_list($args)
    {
        if ($args['section'] != 'mailview') {
            return $args;
        }
        $this->load_config();
        if (!$this->relays()) {
            return $args;
        }
        $this->add_texts('localization/');
        $locked = (array) $this->rc->config->get('dont_override', []);
        $options = [];
        foreach (self::PREFS as $pref) {
            if (in_array($pref, $locked, true)) {
                continue;
            }
            $id = 'rcmfd_' . $pref;
            $check = new html_checkbox(['name' => '_' . $pref, 'id' => $id, 'value' => 1]);
            $options[$pref] = [
                'title' => html::label($id, rcube::Q($this->gettext('pref_' . substr($pref, strlen('relay_tracking_'))))),
                'content' => $check->show($this->rc->config->get($pref, true) ? 1 : 0),
            ];
        }
        if ($options) {
            $args['blocks']['relay_tracking'] = ['name' => rcube::Q($this->gettext('pref_block')), 'options' => $options];
        }
        return $args;
    }

    /** preferences_save hook */
    public function preferences_save($args)
    {
        if ($args['section'] != 'mailview') {
            return $args;
        }
        $locked = (array) $this->rc->config->get('dont_override', []);
        foreach (self::PREFS as $pref) {
            if (!in_array($pref, $locked, true)) {
                $args['prefs'][$pref] = !empty(rcube_utils::get_input_value('_' . $pref, rcube_utils::INPUT_POST));
            }
        }
        return $args;
    }
}
