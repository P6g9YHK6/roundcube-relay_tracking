<?php
// relay_tracking tests: self tracking when sending, the tracking box data, preferences and cleanup.
//   php tests/php/plugin_test.php      (needs the sqlite3 command line tool)
require __DIR__ . '/stubs.php';

$failed = 0;
function check($name, $ok, $detail = '')
{
    global $failed;
    echo ($ok ? 'ok   ' : 'FAIL ') . $name . ($ok || $detail === '' ? '' : "\n     " . $detail) . "\n";
    $failed += $ok ? 0 : 1;
}

// fresh database: Roundcube's users table + the plugin's schema
$GLOBALS['DB'] = tempnam(sys_get_temp_dir(), 'rt') . '.db';
$schema = "CREATE TABLE users (user_id integer NOT NULL PRIMARY KEY); INSERT INTO users VALUES (1);\n"
    . file_get_contents(RT_PLUGIN . '/SQL/sqlite.initial.sql');
exec('sqlite3 ' . escapeshellarg($GLOBALS['DB']) . ' ' . escapeshellarg($schema), $out, $rc);
check('sqlite schema loads', $rc === 0);

$rc = rcmail::get_instance();
$rc->user = new rt_user(1);
$rc->task = 'mail';

function plugin($action, $config)
{
    $rc = rcmail::get_instance();
    $rc->action = $action;
    $rc->config->c = $config + ['relay_tracking_dir' => '/nonexistent'];
    $rc->output = new rt_output();
    $p = new relay_tracking();
    $p->init();
    return $p;
}

function send($p, $html, $mid)
{
    $args = ['message' => new Mail_mime($html, ['Message-ID' => $mid]), 'from' => 'me@example.org'];
    foreach ($p->hooks['message_before_send'] ?? [] as $cb) {
        $args = call_user_func($cb, $args);
    }
    return $args['message']->getHTMLBody();
}

function rows($sql)
{
    return iterator_to_array(rcmail::get_instance()->db->query($sql));
}

$html = '<html><body><p><a href="https://example.com/a?x=1&amp;y=2">a</a> <a href=\'http://b.test/\'>b</a> '
    . '<a href="mailto:x@y.z">m</a> <a href="#top">t</a> <a href="https://bad.test/a b">s</a></p></body></html>';

// ---------------------------------------------------------------- sending
$_POST = ['_relay_tracking_self' => '1'];
$out = send(plugin('send', []), $html, '<off@example.org>');
check('self tracking off by default: mail unchanged', $out === $html);

$out = send(plugin('send', ['relay_tracking_self' => true]), $html, 'abc@example.org');
$mail = rows('SELECT * FROM relay_tracking_mail');
check('tracked mail stored', count($mail) === 1 && $mail[0]['message_id'] === '<abc@example.org>'
    && (int) $mail[0]['user_id'] === 1, json_encode($mail));
$token = $mail[0]['token'] ?? '';
check('token is 32 hex', (bool) preg_match('/^[0-9a-f]{32}$/', $token));
check('links stored decoded', ($mail[0]['links'] ?? '') === '["https://example.com/a?x=1&y=2","http://b.test/"]', $mail[0]['links'] ?? '');
check('http(s) links rewritten', substr_count($out, '_action=click&amp;_t=' . $token) === 2, $out);
check('mailto, anchors and unsafe links kept', strpos($out, 'mailto:x@y.z') && strpos($out, '#top')
    && strpos($out, 'https://bad.test/a b'));
check('pixel before </body>', (bool) preg_match('#<img src="[^"]*_action=open&amp;_t=' . $token . '"[^>]*></body>#', $out), $out);

$_POST = ['_relay_tracking_self' => ''];
$out = send(plugin('send', ['relay_tracking_self' => true]), $html, '<unticked@example.org>');
check('unticked in compose: mail unchanged', $out === $html && count(rows('SELECT token FROM relay_tracking_mail')) === 1);

$_POST = [];
$out = send(plugin('send', ['relay_tracking_self' => true, 'dont_override' => ['relay_tracking_self_track']]),
    '<p>x</p>', '<locked@example.org>');
check('locked preference applies without the checkbox', strpos($out, '_action=open') !== false && substr($out, 0, 8) === '<p>x</p>');

$out = send(plugin('send', ['relay_tracking_self' => true, 'dont_override' => ['relay_tracking_self_track'],
    'relay_tracking_self_track' => false]), '<p>x</p>', '<lockedoff@example.org>');
check('locked off: mail unchanged', $out === '<p>x</p>');

// ---------------------------------------------------------------- hits, then the box
$rc->db->query("INSERT INTO relay_tracking_hit (token, created, type, extra, ip) VALUES (?, '2026-01-01 10:05:00', 'opened', NULL, '192.0.2.1')", $token);
$rc->db->query("INSERT INTO relay_tracking_hit (token, created, type, extra, ip) VALUES (?, '2026-01-01 10:01:00', 'clicked', ?, NULL)", $token, 'https://example.com/a?x=1&y=2');
$rc->db->query("UPDATE relay_tracking_mail SET created = '2026-01-01 10:00:00' WHERE token = ?", $token);

function box($config)
{
    $p = plugin('show', $config);
    $h = (object) ['from' => 'me@example.org', 'to' => 'a@x.test, b@x.test', 'cc' => '', 'bcc' => '',
        'charset' => 'UTF-8', 'messageID' => 'abc@example.org', 'timestamp' => strtotime('2026-01-01 10:00:00 UTC')];
    foreach ($p->hooks['message_load'] ?? [] as $cb) {
        call_user_func($cb, ['object' => (object) ['headers' => $h, 'folder' => 'Sent']]);
    }
    return rcmail::get_instance()->output->env['relay_tracking_msg'] ?? null;
}

$env = box(['relay_tracking_self' => true]);
check('box without relay: Roundcube, one row for all', $env && $env['name'] === 'Roundcube' && $env['self_only']
    && count($env['recipients']) === 1 && $env['recipients'][0]['email'] === 'a@x.test, b@x.test' && $env['known'],
    json_encode($env));
$types = array_map(function ($ev) { return $ev[1]; }, $env['recipients'][0]['events'] ?? []);
check('events in date order', $types === ['sent', 'clicked', 'opened'], json_encode($types));
check('IP kept when shown', ($env['recipients'][0]['events'][2][3] ?? '') === '192.0.2.1');
$env = box(['relay_tracking_self' => true, 'relay_tracking_show_ip' => false]);
check('IP removed when hidden', !isset($env['recipients'][0]['events'][2][3]));
check('no box with self tracking off', box([]) === null);

// with a relay: the relay's events + Roundcube's hits, per recipient
$dir = sys_get_temp_dir() . '/rt-relays-' . getmypid();
@mkdir($dir . '/brevo', 0755, true);
file_put_contents($dir . '/brevo/relay.json', json_encode(['format' => 1, 'name' => 'Brevo', 'domains' => ['example.org'],
    'capabilities' => ['events', 'opens'], 'lag' => '1 h']));
file_put_contents($dir . '/brevo/events.json', json_encode(['generated' => time(), 'days' => 30, 'messages' => [
    '<abc@example.org>' => ['a@x.test' => [['2026-01-01T10:00:02Z', 'sent'], ['2026-01-01T10:00:09Z', 'delivered']]]]]));
$env = box(['relay_tracking_self' => true, 'relay_tracking_dir' => $dir]);
$a = $env['recipients'][0] ?? [];
check('box with relay: per recipient, relay name', $env && $env['name'] === 'Brevo' && !$env['self_only']
    && count($env['recipients']) === 2, json_encode($env));
check('relay and own events merged in order without a second "sent"',
    array_map(function ($ev) { return $ev[1]; }, $a['events'] ?? []) === ['sent', 'delivered', 'clicked', 'opened'],
    json_encode($a));
$env = box(['relay_tracking_dir' => $dir]);
check('relay only: own hits ignored when self tracking is off',
    count($env['recipients'][0]['events'] ?? []) === 2 && $env['recipients'][1]['events'] === []);

// ---------------------------------------------------------------- compose and preferences
$p = plugin('compose', ['relay_tracking_self' => true]);
check('compose checkbox, ticked by default', strpos(implode('', $p->api->content['composeoptions'] ?? []), 'name="_relay_tracking_self" checked') !== false);
$p = plugin('compose', ['relay_tracking_self' => true, 'relay_tracking_self_track' => false]);
check('compose checkbox follows the preference', strpos(implode('', $p->api->content['composeoptions'] ?? []), 'checked') === false);
$p = plugin('compose', ['relay_tracking_self' => true, 'dont_override' => ['relay_tracking_self_track']]);
check('no compose checkbox when locked', empty($p->api->content));
$p = plugin('compose', []);
check('no compose checkbox when self tracking is off', empty($p->api->content));

$rc->task = 'settings';
$p = plugin('', ['relay_tracking_self' => true]);
$list = call_user_func($p->hooks['preferences_list'][0], ['section' => 'compose', 'blocks' => []]);
check('compose preference listed', isset($list['blocks']['relay_tracking']['options']['relay_tracking_self_track']));
$_POST = [];
$save = call_user_func($p->hooks['preferences_save'][0], ['section' => 'compose', 'prefs' => []]);
check('compose preference saved', ($save['prefs'] ?? null) === ['relay_tracking_self_track' => false]);
$p = plugin('', []);
$list = call_user_func($p->hooks['preferences_list'][0], ['section' => 'compose', 'blocks' => []]);
$save = call_user_func($p->hooks['preferences_save'][0], ['section' => 'compose', 'prefs' => []]);
check('no compose preference when self tracking is off', empty($list['blocks']) && empty($save['prefs']));
$rc->task = 'mail';

// ---------------------------------------------------------------- cleanup when sending
$rc->db->query('UPDATE relay_tracking_mail SET created = ?', gmdate('Y-m-d H:i:s', time() - 100 * 86400));
$_POST = ['_relay_tracking_self' => '1'];
send(plugin('send', ['relay_tracking_self' => true]), '<p>new</p>', '<new@example.org>');
$left = rows('SELECT (SELECT COUNT(*) FROM relay_tracking_mail) AS m, (SELECT COUNT(*) FROM relay_tracking_hit) AS h');
check('mails older than relay_tracking_self_days removed with their hits', $left === [['m' => 1, 'h' => 0]], json_encode($left));

@unlink($GLOBALS['DB']);
array_map('unlink', glob($dir . '/brevo/*'));
@rmdir($dir . '/brevo');
@rmdir($dir);
echo $failed ? "$failed failed\n" : "all passed\n";
exit($failed ? 1 : 0);
