<?php
// relay_tracking tests: PHP built-in server answering ?_task=relay_tracking like Roundcube does before its login check.
// RT_DB = database, cookie "as_user" = the logged-in user (none: a recipient).
require __DIR__ . '/stubs.php';
$GLOBALS['DB'] = getenv('RT_DB');
$rc = rcmail::get_instance();
$rc->config->c = ['relay_tracking_self' => true, 'relay_tracking_self_ip' => true];
$rc->user = new rt_user(isset($_COOKIE['as_user']) ? (int) $_COOKIE['as_user'] : null);
$p = new relay_tracking();
$p->init();
foreach ($p->hooks['startup'] ?? [] as $cb) {
    call_user_func($cb, ['task' => 'login', 'action' => $_GET['_action'] ?? '']);
}
echo "not handled\n";
