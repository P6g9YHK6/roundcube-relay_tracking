<?php
// relay_tracking tests: the parts of Roundcube the plugin uses, just enough to run it outside Roundcube.
// Database: the sqlite3 command line tool on $GLOBALS['DB'] (real SQL, no PDO extension needed).
define('RT_PLUGIN', dirname(__DIR__, 2));
class rcube_config { public $c = []; function get($k, $d = null) { return array_key_exists($k, $this->c) ? $this->c[$k] : $d; } }
class rt_db {
    public $err = false;
    function table_name($n, $q = false) { return $n; }
    function is_error() { return $this->err; }
    function query($sql, ...$args) {
        $i = 0;
        $sql = preg_replace_callback('/\?/', function () use (&$i, $args) {
            if (!array_key_exists($i, $args)) throw new Exception("missing parameter $i in: $sql");
            $v = $args[$i++];
            return $v === null ? 'NULL' : "'" . str_replace("'", "''", (string) $v) . "'";
        }, $sql);
        $out = []; $rc = 0;
        exec('sqlite3 -json ' . escapeshellarg($GLOBALS['DB']) . ' ' . escapeshellarg('PRAGMA foreign_keys=ON; ' . $sql) . ' 2>&1', $out, $rc);
        $this->err = $rc != 0;
        if ($rc) fwrite(STDERR, "SQL ERROR: " . implode("\n", $out) . "\n");
        $rows = json_decode(implode("\n", $out) ?: '[]', true) ?: [];
        return new ArrayIterator($rows);
    }
    function fetch_assoc($res) { if (!$res || !$res->valid()) return false; $r = $res->current(); $res->next(); return $r; }
}
class rt_user { public $ID; function __construct($id) { $this->ID = $id; } function list_emails() { return [['email' => 'me@example.org']]; } }
class rt_output { public $type = 'html'; public $env = []; function set_env($k, $v) { $this->env[$k] = $v; } }
class rcmail {
    static $i; public $config, $user, $task, $action, $output, $db;
    static function get_instance() { return self::$i ?: self::$i = new rcmail(); }
    function __construct() { $this->config = new rcube_config(); $this->output = new rt_output(); $this->db = new rt_db(); $this->user = new rt_user(null); }
    function get_dbh() { return $this->db; }
    function get_user_id() { return $this->user->ID; }
    function url($p, $abs, $full) { return 'https://rc.test/?' . http_build_query($p); }
    function format_date($d) { return $d->format('d.m.Y H:i'); }
}
class rt_api { public $content = []; function add_content($h, $c) { $this->content[$c][] = $h; } }
class rcube_plugin {
    public $api; public $hooks = [];
    function __construct() { $this->api = new rt_api(); }
    function add_hook($n, $cb) { $this->hooks[$n][] = $cb; }
    function load_config() {}
    function add_texts($d, $js = false) { $labels = []; include RT_PLUGIN . '/localization/en_US.inc'; $this->labels = $labels; }
    function gettext($k) { return $this->labels[$k] ?? $k; }
    function include_stylesheet($f) {} function include_script($f) {} function local_skin_path() { return 'skins/elastic'; }
}
class rcube { static function Q($s) { return htmlspecialchars($s); } }
class rcube_utils {
    const INPUT_GET = 1, INPUT_POST = 2;
    static function get_input_string($n, $s) { $a = $s == 1 ? $_GET : $_POST; return isset($a[$n]) ? (string) $a[$n] : ''; }
    static function get_input_value($n, $s) { return self::get_input_string($n, $s); }
    static function check_email($e, $dns) { return (bool) filter_var($e, FILTER_VALIDATE_EMAIL); }
    static function remote_addr() { return $_SERVER['REMOTE_ADDR'] ?? '127.0.0.1'; }
}
class rcube_mime { static function decode_address_list($s, $max = null, $dec = true, $cs = null, $addronly = false) {
    preg_match_all('/[^\s<>,]+@[^\s<>,]+/', (string) $s, $m); $r = []; $i = 1; foreach ($m[0] as $a) $r[$i++] = $a; return $r; } }
class html { static function div($c, $h) { return "<div class=\"$c\">$h</div>"; } static function label($a, $h) { return '<label>' . $h . '</label>'; } }
class html_checkbox { public $a; function __construct($a) { $this->a = $a; } function show($v) { return '<input type="checkbox" name="' . $this->a['name'] . '"' . ($v ? ' checked' : '') . '>'; } }
class Mail_mime { public $html, $h; function __construct($html, $h) { $this->html = $html; $this->h = $h; }
    function getHTMLBody() { return $this->html; } function setHTMLBody($b) { $this->html = $b; }
    function headers($add = null, $overwrite = false) { if ($add) $this->h = array_merge($this->h, $add); return $this->h; } }
require RT_PLUGIN . '/relay_tracking.php';
