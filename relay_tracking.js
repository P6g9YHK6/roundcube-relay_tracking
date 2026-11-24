/**
 * relay_tracking
 *
 * Tracking box of a sent mail. No key and no call to the relay here: the data comes from the cache written by the
 * server's collector (see relay_tracking.php).
 *
 * Event types = common format v1 vocabulary (README.md): sent, delivered, deferred, soft_bounce, hard_bounce, blocked,
 * invalid, error, opened, proxy_open, clicked, spam, unsubscribed.
 *
 * @author P6g9YHK6
 * @licstart  The following is the entire license notice for the JavaScript code in this file.
 *
 * Copyright (C) P6g9YHK6
 *
 * The JavaScript code in this page is free software: you can redistribute it and/or modify it under the terms of the
 * GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at
 * your option) any later version.
 *
 * @licend  The above is the entire license notice for the JavaScript code in this file.
 */
(function () {
    'use strict';

    var rc = window.rcmail;
    if (!rc) {
        return;
    }

    function label(name) {
        return rc.get_label('relay_tracking.' + name);
    }

    function el(tag, cls, text) {
        var e = document.createElement(tag);
        if (cls) {
            e.className = cls;
        }
        if (text !== undefined && text !== null) {
            e.textContent = text;
        }
        return e;
    }

    // Date as Roundcube formats it for this user (date/time format, pretty dates, timezone: env "dates", filled
    // by the PHP side); the browser's short format only if a date is missing there
    function fmt(iso) {
        var dates = (rc.env.relay_tracking_msg || {}).dates || {}, d = new Date(iso);
        if (dates[iso]) {
            return dates[iso];
        }
        if (isNaN(d.getTime())) {
            return String(iso);
        }
        var lang = rc.env.locale ? String(rc.env.locale).replace('_', '-') : undefined;
        try {
            return d.toLocaleString(lang, { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
        } catch (e) {
            return d.toLocaleString();
        }
    }

    function time(iso) {
        var t = new Date(iso).getTime();
        return isNaN(t) ? 0 : t;
    }

    function fill(text, vars) {
        Object.keys(vars).forEach(function (k) {
            text = text.split('$' + k).join(vars[k]);
        });
        return text;
    }

    var PROBLEMS = ['deferred', 'soft_bounce', 'hard_bounce', 'blocked', 'invalid', 'error', 'spam', 'unsubscribed'];

    // Temporary failures: once the mail is delivered afterwards they are only retries (greylisting, full mailbox...)
    var TRANSIENT = ['deferred', 'soft_bounce'];

    // Clicking a public IP in the timeline opens this lookup page
    var IP_LOOKUP_URL = 'https://www.iplocation.net/ip-lookup?query=';
    var PRIVATE_IP = /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|169\.254\.|::1$|f[cd]|fe80:)/i;

    // An open this close to delivery is almost certainly the provider's image proxy (Proton, Apple...), not a reader
    var AUTO_OPEN_MS = 20000;

    // Every event becomes one timeline row, in date order (events come sorted from the collector). ev[2] is the link
    // (click) or reason (bounce), ev[3] the IP when the collector includes it (INCLUDE_IP=1).
    // Row kinds: ok, auto (automatic open, not a read), retried (temporary failure before a delivery), bad (problem).
    function analyse(events) {
        var a = { opens: 0, auto_opens: 0, clicks: 0, problems: [], rows: [] }, delivered_t = 0;

        events.forEach(function (ev) {
            if (String(ev[1]) === 'delivered' && !a.delivered) {
                a.delivered = ev[0];
                delivered_t = time(ev[0]);
            }
        });

        events.forEach(function (ev) {
            var t = String(ev[1] || ''), d = ev[0], row = { d: d, k: t, detail: ev[2] || '', ip: ev[3] || '', kind: 'ok' };
            if (t === 'sent') {
                a.sent = a.sent || d;
            }
            else if (t === 'delivered') {
                // first one is a.delivered
            }
            else if (t === 'opened' || t === 'proxy_open') {
                row.k = 'opened';
                if (t === 'proxy_open' || (delivered_t && Math.abs(time(d) - delivered_t) < AUTO_OPEN_MS)) {
                    row.kind = 'auto';
                    a.auto_opens++;
                }
                else {
                    a.opens++;
                    a.first_open = a.first_open || d;
                    a.last_open = d;
                }
            }
            else if (t === 'clicked') {
                a.clicks++;
                a.first_click = a.first_click || d;
                a.last_click = d;
            }
            else if (PROBLEMS.indexOf(t) >= 0) {
                if (delivered_t && TRANSIENT.indexOf(t) >= 0 && time(d) <= delivered_t) {
                    row.kind = 'retried';
                }
                else {
                    row.kind = 'bad';
                    a.problems.push(row);
                }
            }
            else {
                return;   // unknown type: ignored (common format)
            }
            a.rows.push(row);
        });
        return a;
    }

    // Progress of one recipient: Sent > Delivered > Opened > Clicked. A problem before delivery takes the Delivered
    // step (red); a later one (spam complaint, unsubscribe...) is added as a red step at the end.
    function stepper(a) {
        var ol = el('ol', 'rt-stepper'), stop = false, early = !a.delivered && a.problems.length ? a.problems[0] : null;

        function step(state, name, meta, title) {
            var li = el('li', 'rt-st rt-st-' + state);
            li.appendChild(el('span', 'rt-dot'));
            li.appendChild(el('span', 'rt-st-label', name));
            if (meta) li.appendChild(el('span', 'rt-st-meta', meta));
            if (title) li.title = title;
            ol.appendChild(li);
        }

        function count(n, last) {
            return (n > 1 ? '×' + n + ' · ' : '') + fill(label(n > 1 ? 'last' : 'on'), { date: fmt(last) });
        }

        step(a.sent || a.delivered ? 'done' : 'todo', label('ev_sent'), a.sent ? fmt(a.sent) : '');
        if (early) {
            step('bad', label('ev_' + early.k), fmt(early.d), early.detail || null);
            stop = true;
        }
        else {
            step(a.delivered ? 'done' : 'todo', label('ev_delivered'), a.delivered ? fmt(a.delivered) : '');
        }
        if (a.opens) step(stop ? 'todo' : 'done', label('ev_opened'), count(a.opens, a.last_open));
        else if (a.auto_opens) step('auto', label('ev_opened') + ' *', label('auto_only'), label('auto_open'));
        else step('todo', label('ev_opened'), '');
        step(a.clicks && !stop ? 'done' : 'todo', label('ev_clicked'), a.clicks ? count(a.clicks, a.last_click) : '');
        a.problems.forEach(function (p) {
            if (p !== early) step('bad', label('ev_' + p.k), fmt(p.d), p.detail || null);
        });
        return ol;
    }

    function timeline(a, hosts) {
        var with_detail = a.rows.some(function (x) { return x.detail; }),
            with_ip = a.rows.some(function (x) { return x.ip; }),
            table = el('table', 'rt-timeline' + (with_detail ? ' rt-has-detail' : '')), thead = el('thead'), hr = el('tr'),
            tbody = el('tbody');

        [['col_time', true], ['col_event', true], ['col_detail', with_detail], ['col_ip', with_ip]].forEach(function (c) {
            if (c[1]) hr.appendChild(el('th', null, label(c[0])));
        });
        thead.appendChild(hr);
        table.appendChild(thead);

        a.rows.forEach(function (x) {
            var tr = el('tr', 'rt-row-' + x.kind), ev = el('td', 'rt-ev', label('ev_' + x.k) + (x.kind === 'auto' ? ' *' : ''));
            if (x.kind === 'auto') ev.title = label('auto_open');
            tr.appendChild(el('td', 'rt-time', fmt(x.d)));
            tr.appendChild(ev);
            if (with_detail) tr.appendChild(el('td', 'rt-detail', x.detail));
            if (with_ip) {
                // IP (a link for public ones), then where it is and who it belongs to; reverse DNS name on hover of the owner
                var td = el('td', 'rt-ip'), h = hosts[x.ip] || {}, addr, owner;
                if (x.ip && !PRIVATE_IP.test(x.ip)) {
                    // public IP: opens a lookup page (the IP then goes to that site, only when clicked)
                    addr = el('a', 'rt-ip-addr', x.ip);
                    addr.href = IP_LOOKUP_URL + encodeURIComponent(x.ip);
                    addr.target = '_blank';
                    addr.rel = 'noopener noreferrer';
                    addr.title = label('ip_more');
                }
                else {
                    addr = el('span', 'rt-ip-addr', x.ip);
                }
                td.appendChild(addr);
                if (h.location) td.appendChild(el('span', 'rt-ip-geo', h.location));
                if (h.provider) {
                    owner = td.appendChild(el('span', 'rt-ip-owner', h.provider));
                    if (h.rdns) owner.title = h.rdns;
                }
                tr.appendChild(td);
            }
            tbody.appendChild(tr);
        });
        table.appendChild(tbody);

        // the wrapper scrolls (a table with display: block would no longer stretch to the full width)
        var wrap = el('div', 'rt-tl');
        wrap.appendChild(table);
        return wrap;
    }

    function render_track() {
        var data = rc.env.relay_tracking_msg, header = document.getElementById('message-header');
        if (!data || !header || document.getElementById('rt-track')) {
            return;
        }

        var rcpts = data.recipients || [], n = rcpts.length, delivered = 0, opened = 0, clicks = 0, issues = 0, auto = false;
        var box = el('section', 'rt-box'), head = el('button', 'rt-head'), body = el('div', 'rt-body');
        box.id = 'rt-track';
        box.setAttribute('aria-label', fill(label('track'), { relay: data.name }));
        head.type = 'button';
        head.setAttribute('aria-expanded', 'false');

        rcpts.forEach(function (r) {
            var a = analyse(r.events || []), row = el('div', 'rt-rcpt');
            if (a.delivered) delivered++;
            if (a.opens) opened++;
            if (a.auto_opens) auto = true;
            clicks += a.clicks;
            if (a.problems.length) issues++;

            var top = el('div', 'rt-rhead');
            top.appendChild(el('span', 'rt-email', r.email));
            row.appendChild(top);

            if (!a.rows.length) {
                row.appendChild(el('div', 'rt-none', label('ev_none')));
                body.appendChild(row);
                return;
            }

            row.appendChild(stepper(a));

            // full timeline, folded unless something went wrong
            var toggle = el('button', 'rt-toggle', label('timeline') + ' (' + a.rows.length + ')'), table = timeline(a, data.hosts || {});
            toggle.type = 'button';
            table.hidden = !a.problems.length;
            toggle.setAttribute('aria-expanded', table.hidden ? 'false' : 'true');
            toggle.addEventListener('click', function () {
                table.hidden = !table.hidden;
                toggle.setAttribute('aria-expanded', table.hidden ? 'false' : 'true');
            });
            top.appendChild(toggle);
            row.appendChild(table);
            body.appendChild(row);
        });

        var summary;
        if (!data.known) {
            summary = data.expired ? fill(label('expired'), { days: data.days })
                : data.untracked ? fill(label('untracked'), { relay: data.name })
                : fill(label('waiting'), { relay: data.name }) + (data.lag ? ' ' + fill(label('waiting_lag'), { lag: data.lag }) : '');
        }
        else {
            summary = fill(label('sum_delivered'), { n: delivered, t: n })
                + (opened ? ' · ' + fill(label('sum_opened'), { n: opened }) : '')
                + (clicks ? ' · ' + clicks + ' ' + label(clicks > 1 ? 'ev_clicks' : 'ev_click') : '')
                + (issues ? ' · ' + fill(label('sum_issues'), { n: issues }) : '');
        }

        head.appendChild(el('span', 'rt-title', fill(label('track'), { relay: data.name })));
        head.appendChild(el('span', 'rt-summary', summary));
        box.appendChild(head);

        if (data.known) {
            if (auto) {
                body.appendChild(el('p', 'rt-note', '* ' + label('auto_open')));
            }
            // DB-IP Lite data is CC BY 4.0: credit it wherever a location is shown
            if (Object.keys(data.hosts || {}).some(function (ip) { return data.hosts[ip].location; })) {
                var credit = el('p', 'rt-note rt-credit', label('geo_credit') + ' '), a = el('a', null, 'DB-IP');
                a.href = 'https://db-ip.com';
                a.target = '_blank';
                a.rel = 'noopener noreferrer';
                credit.appendChild(a);
                body.appendChild(credit);
            }
            body.hidden = true;
            box.appendChild(body);
            head.addEventListener('click', function () {
                body.hidden = !body.hidden;
                head.setAttribute('aria-expanded', body.hidden ? 'false' : 'true');
                box.classList.toggle('rt-open', !body.hidden);
            });
            if (issues) {
                box.classList.add('rt-alert');
                head.click();                  // problem: open by default
            }
        }
        else {
            head.disabled = true;
        }

        header.parentNode.insertBefore(box, header.nextSibling);
    }

    rc.addEventListener('init', function () {
        try {
            if (rc.env.task === 'mail' && (rc.env.action === 'show' || rc.env.action === 'preview')) render_track();
        }
        catch (e) {
            // never break the page initialisation
            if (window.console) console.error('relay_tracking', e);
        }
    });
})();
