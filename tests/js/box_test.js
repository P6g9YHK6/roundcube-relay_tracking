// relay_tracking tests: the tracking box as relay_tracking.js draws it, in jsdom.
//   npm install --no-save jsdom@24.1.3 && node tests/js/box_test.js
'use strict';
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const root = path.join(__dirname, '..', '..');
const script = fs.readFileSync(path.join(root, 'relay_tracking.js'), 'utf8');

// labels as Roundcube hands them to the page (localization/en_US.inc)
const labels = {};
fs.readFileSync(path.join(root, 'localization', 'en_US.inc'), 'utf8').replace(
    /\$labels\['(\w+)'\] = '((?:[^'\\]|\\.)*)';/g,
    (m, k, v) => {
        labels['relay_tracking.' + k] = v.replace(/\\'/g, "'");
    },
);

let failed = 0;
function check(name, ok, detail) {
    console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok || !detail ? '' : '\n     ' + detail));
    if (!ok) failed++;
}

function render(msg) {
    const dom = new JSDOM('<!doctype html><div id="message-header"></div>', { runScripts: 'outside-only' });
    const w = dom.window,
        listeners = [];
    w.rcmail = {
        env: { task: 'mail', action: 'show', locale: 'en_US', relay_tracking_msg: msg },
        get_label: (k) => labels[k] || k,
        addEventListener: (ev, fn) => {
            if (ev === 'init') listeners.push(fn);
        },
    };
    w.eval(script);
    listeners.forEach((fn) => fn());
    return w.document;
}

const text = (doc, sel) => Array.from(doc.querySelectorAll(sel)).map((e) => e.textContent.trim());

// relay: one delivered and opened, one hard bounce (box opens by itself)
let doc = render({
    name: 'Brevo',
    lag: '1 h',
    known: true,
    days: 30,
    hosts: {
        '192.0.2.1': { location: 'Zurich, CH', provider: 'Swisscom (Schweiz) AG', rdns: 'x.swisscom.ch' },
    },
    dates: {},
    recipients: [
        {
            email: 'a@x.test',
            events: [
                ['2026-01-01T10:00:00Z', 'sent'],
                ['2026-01-01T10:00:05Z', 'delivered'],
                ['2026-01-01T12:00:00Z', 'opened', '', '192.0.2.1'],
                ['2026-01-01T12:01:00Z', 'clicked', 'https://e.test/', '192.0.2.1'],
            ],
        },
        {
            email: 'b@x.test',
            events: [
                ['2026-01-01T10:00:00Z', 'sent'],
                ['2026-01-01T10:00:06Z', 'hard_bounce', 'no such user'],
            ],
        },
    ],
});
check('box drawn under the header', !!doc.querySelector('#message-header + #rt-track'));
check('title', text(doc, '.rt-title')[0] === 'Delivery tracking · Brevo', text(doc, '.rt-title')[0]);
check(
    'summary',
    text(doc, '.rt-summary')[0] === 'Delivered 1/2 · opened by 1 · 1 click · 1 issue(s)',
    text(doc, '.rt-summary')[0],
);
check(
    'opened on a problem',
    doc.querySelector('#rt-track').classList.contains('rt-alert') && !doc.querySelector('.rt-body').hidden,
);
check(
    'stepper of the delivered one',
    text(doc, '.rt-rcpt')[0] &&
        text(doc, '.rt-rcpt:first-child .rt-st-label').join('>') === 'Sent>Delivered>Opened>Clicked',
    text(doc, '.rt-rcpt:first-child .rt-st-label').join('>'),
);
check(
    'bounce in red, with its reason',
    doc.querySelector('.rt-rcpt:nth-child(2) .rt-st-bad') !== null &&
        doc.querySelector('.rt-rcpt:nth-child(2) .rt-st-bad').title === 'no such user',
);
check(
    'IP owner and location in the timeline',
    text(doc, '.rt-ip-owner')[0] === 'Swisscom (Schweiz) AG' && text(doc, '.rt-ip-geo')[0] === 'Zurich, CH',
);
check(
    'public IP links to the lookup',
    (doc.querySelector('a.rt-ip-addr') || {}).href === 'https://www.iplocation.net/ip-lookup?query=192.0.2.1',
);
check(
    'DB-IP credit',
    text(doc, '.rt-credit')[0] === 'IP locations and owners: IP Geolocation by DB-IP',
    text(doc, '.rt-credit')[0],
);

// relay, nothing published yet
doc = render({
    name: 'Brevo',
    lag: '1 h',
    known: false,
    days: 30,
    hosts: {},
    dates: {},
    recipients: [{ email: 'a@x.test', events: [] }],
});
check(
    'pending',
    text(doc, '.rt-summary')[0] ===
        'Tracking pending: Brevo has not published anything for this mail yet. (usual delay: 1 h)',
    text(doc, '.rt-summary')[0],
);
check('pending box cannot open', doc.querySelector('.rt-head').disabled);

// Roundcube's own tracking only
doc = render({
    name: 'Roundcube',
    lag: '',
    self_only: true,
    known: true,
    days: 30,
    hosts: {},
    dates: {},
    recipients: [
        {
            email: 'a@x.test, b@x.test',
            events: [
                ['2026-01-01T10:00:00Z', 'sent'],
                ['2026-01-01T10:00:03Z', 'proxy_open', ''],
                ['2026-01-01T12:00:00Z', 'opened', ''],
                ['2026-01-01T13:00:00Z', 'opened', ''],
                ['2026-01-01T13:01:00Z', 'clicked', 'https://e.test/'],
            ],
        },
    ],
});
check('self tracking title', text(doc, '.rt-title')[0] === 'Delivery tracking · Roundcube');
check(
    'self tracking summary counts opens',
    text(doc, '.rt-summary')[0] === 'Opened 2 time(s) · 1 click',
    text(doc, '.rt-summary')[0],
);
check(
    'no Delivered step',
    text(doc, '.rt-st-label').join('>') === 'Sent>Opened>Clicked',
    text(doc, '.rt-st-label').join('>'),
);
check('one row for all the recipients', text(doc, '.rt-email').join('|') === 'a@x.test, b@x.test');
check('automatic open marked', text(doc, '.rt-row-auto .rt-ev')[0] === 'Opened *');
check(
    'self tracking note',
    text(doc, '.rt-note').some((t) => t.startsWith('Tracked by Roundcube')),
);

doc = render({
    name: 'Roundcube',
    lag: '',
    self_only: true,
    known: true,
    days: 30,
    hosts: {},
    dates: {},
    recipients: [{ email: 'a@x.test', events: [['2026-01-01T10:00:00Z', 'sent']] }],
});
check('self tracking, nothing yet', text(doc, '.rt-summary')[0] === 'Not opened yet', text(doc, '.rt-summary')[0]);

// not on a message view: nothing drawn
const dom = new JSDOM('<!doctype html><div id="message-header"></div>', { runScripts: 'outside-only' });
const ls = [];
dom.window.rcmail = {
    env: { task: 'mail', action: 'compose' },
    get_label: (k) => k,
    addEventListener: (e, f) => ls.push(f),
};
dom.window.eval(script);
ls.forEach((f) => f());
check('nothing outside the message view', !dom.window.document.getElementById('rt-track'));

console.log(failed ? failed + ' failed' : 'all passed');
process.exit(failed ? 1 : 0);
