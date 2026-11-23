/**
 * relay_tracking: tracking box of a sent mail, compose warning, "Blocked contacts" page, "new blocked contact"
 * alert. No key and no call to the relay here: the data comes from the cache written by the server's collector,
 * unblocks are requests it processes within a minute (see relay_tracking.php).
 *
 * Event types = common format v1 vocabulary (README.md): sent, delivered, deferred, soft_bounce, hard_bounce, blocked,
 * invalid, error, opened, proxy_open, clicked, spam, unsubscribed.
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

    // Short date in the user's language
    function fmt(iso) {
        var d = new Date(iso);
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

    function fmt_ts(ts) {
        return ts ? fmt(ts * 1000) : '';
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

    /* ---------- unblock: request + state polling (shared by the three screens) ---------- */

    // watched[relay][email] = true while a request is in progress
    var watchers = [], polling = null, poll_left = 0, watched = {};

    rc.addEventListener('plugin.relay_tracking_state', function (p) {
        var relay = p && p.relay, states = (p && p.states) || {}, busy = false;
        if (!relay) {
            return;
        }
        Object.keys(states).forEach(function (email) {
            if (states[email] === 'pending') {
                busy = true;
            }
            else if (watched[relay]) {
                delete watched[relay][email];
            }
        });
        watchers.forEach(function (fn) {
            fn(relay, states);
        });
        if (busy) {
            start_poll();
        }
    });

    function watch(relay, email) {
        (watched[relay] = watched[relay] || {})[email] = true;
    }

    function start_poll() {
        poll_left = 18;                       // ~3 min (the collector runs every minute)
        if (polling) {
            return;
        }
        polling = setInterval(function () {
            var any = false;
            Object.keys(watched).forEach(function (relay) {
                var emails = Object.keys(watched[relay]);
                if (emails.length) {
                    any = true;
                    rc.http_post('plugin.relay_tracking_status', { _relay: relay, _emails: emails.join(',') });
                }
            });
            if (!any || --poll_left < 0) {
                clearInterval(polling);
                polling = null;
            }
        }, 10000);
    }

    function request_unblock(relay, name, email) {
        rc.confirm_dialog(fill(label('unblock_confirm'), { email: email, relay: name }), 'relay_tracking.unblock', function () {
            watch(relay, email);
            rc.http_post('plugin.relay_tracking_unblock', { _relay: relay, _email: email }, rc.set_busy(true, 'loading'));
        });
    }

    function state_text(state) {
        switch (state) {
            case 'pending': return label('pending');
            case 'unblocked': return label('st_unblocked');
            case 'not_blocked': return label('st_not_blocked');
            case 'blocked': return null;      // still blocked: keep the button
            default: return label('st_error');
        }
    }

    // Replaces an "Unblock" button with the state, and brings it back if the address is still blocked
    function bind_button(btn, relay, name, email) {
        btn.addEventListener('click', function () {
            request_unblock(relay, name, email);
        });
        watchers.push(function (r, states) {
            if (r !== relay || !(email in states)) {
                return;
            }
            var txt = state_text(states[email]), span = btn.parentNode && btn.parentNode.querySelector('.rt-state');
            if (!span) {
                span = el('span', 'rt-state');
                btn.parentNode.insertBefore(span, btn);
            }
            span.textContent = txt || '';
            span.className = 'rt-state rt-st-' + states[email];
            btn.hidden = !!txt && states[email] !== 'error';
        });
    }

    function unblock_button(relay, name, email, hidden) {
        var btn = el('button', 'btn btn-secondary rt-unblock', label('unblock'));
        btn.type = 'button';
        btn.hidden = !!hidden;
        bind_button(btn, relay, name, email);
        return btn;
    }

    /* ---------- 1. tracking box in a sent mail ---------- */

    var PROBLEMS = ['deferred', 'soft_bounce', 'hard_bounce', 'blocked', 'invalid', 'error', 'spam', 'unsubscribed'];

    // Temporary failures: once the mail is delivered afterwards they are only retries (greylisting, full mailbox...)
    var TRANSIENT = ['deferred', 'soft_bounce'];

    // Problems lifted by a later unblock (unsubscribe, complaint, bounce > contact unblocked since)
    var CLEARED_BY_UNBLOCK = ['unsubscribed', 'spam', 'hard_bounce', 'blocked'];

    // An open this close to delivery is almost certainly the provider's image proxy (Proton, Apple...), not a reader
    var AUTO_OPEN_MS = 20000;

    function analyse(events, unblocked_at) {
        var a = { opens: 0, auto_opens: 0, clicks: 0, links: {}, problems: [], resolved: [], retried: [] }, delivered_t = 0;

        events.forEach(function (ev) {
            if (String(ev[1]) === 'delivered' && !a.delivered) {
                a.delivered = ev[0];
                delivered_t = time(ev[0]);
            }
        });

        events.forEach(function (ev) {
            var t = String(ev[1] || ''), d = ev[0], extra = ev[2] || '';
            if (t === 'sent') a.sent = a.sent || d;
            else if (t === 'opened' || t === 'proxy_open') {
                if (t === 'proxy_open' || (delivered_t && Math.abs(time(d) - delivered_t) < AUTO_OPEN_MS)) {
                    a.auto_opens++;
                    a.auto_opened = a.auto_opened || d;
                }
                else {
                    a.opens++;
                    a.opened = a.opened || d;
                }
            }
            else if (t === 'clicked') {
                a.clicks++;
                if (extra) a.links[extra] = (a.links[extra] || 0) + 1;
            }
            else if (PROBLEMS.indexOf(t) >= 0) {
                var p = { k: t, d: d, reason: extra };
                if (delivered_t && TRANSIENT.indexOf(t) >= 0 && time(d) <= delivered_t) {
                    a.retried.push(p);
                }
                else if (unblocked_at && CLEARED_BY_UNBLOCK.indexOf(t) >= 0 && time(d) <= unblocked_at * 1000) {
                    a.resolved.push(p);
                }
                else {
                    a.problems.push(p);
                }
            }
        });
        return a;
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
            var a = analyse(r.events || [], r.unblocked_at), row = el('div', 'rt-rcpt'), steps = el('ul', 'rt-steps');
            if (a.delivered) delivered++;
            if (a.opens) opened++;
            clicks += a.clicks;
            if (a.problems.length || r.blocked) issues++;

            row.appendChild(el('div', 'rt-email', r.email));

            function step(cls, text, title) {
                var li = el('li', 'rt-step rt-' + cls, text);
                if (title) li.title = title;
                steps.appendChild(li);
            }

            a.retried.forEach(function (p) {
                step('retried', label('ev_' + p.k) + ' · ' + fmt(p.d), p.reason || null);
            });
            if (a.delivered) step('ok', label('ev_delivered') + ' · ' + fmt(a.delivered));
            else if (a.sent && !a.problems.length) step('wait', label('ev_sent') + ' · ' + fmt(a.sent));
            if (a.opens) {
                step('ok', label('ev_opened') + ' · ' + fmt(a.opened) + (a.opens > 1 ? ' (×' + a.opens + ')' : ''));
            }
            else if (a.auto_opens) {
                // only automatic opens: shown apart, they do not prove a read
                auto = true;
                step('auto', label('ev_opened') + ' · ' + fmt(a.auto_opened) + ' *', label('auto_open'));
            }
            if (a.clicks) step('ok', a.clicks + ' ' + label(a.clicks > 1 ? 'ev_clicks' : 'ev_click'));
            a.problems.forEach(function (p) {
                step('bad', label('ev_' + p.k) + ' · ' + fmt(p.d), p.reason || null);
            });
            a.resolved.forEach(function (p) {
                step('resolved', label('ev_' + p.k) + ' · ' + fmt(p.d) + ' · ' + fill(label('resolved'), { date: fmt_ts(r.unblocked_at) }),
                    p.reason || null);
            });
            if (!(r.events || []).length && !r.blocked) step('none', label('ev_none'));
            row.appendChild(steps);

            var links = Object.keys(a.links);
            if (links.length) {
                var ul = el('ul', 'rt-links');
                links.forEach(function (l) {
                    ul.appendChild(el('li', null, l + (a.links[l] > 1 ? ' (×' + a.links[l] + ')' : '')));
                });
                row.appendChild(ul);
            }
            a.problems.forEach(function (p) {
                if (p.reason) row.appendChild(el('div', 'rt-reason', p.reason));
            });

            if (r.blocked) {
                var warn = el('div', 'rt-blocked');
                warn.appendChild(el('span', 'rt-blocked-text', fill(label('is_blocked'),
                    { relay: data.name, reason: r.blocked.label, date: fmt_ts(r.blocked.at) })));
                if (r.blocked.detail) warn.title = r.blocked.detail;
                if (data.unblock && r.blocked.unblockable) {
                    if (r.pending) {
                        warn.appendChild(el('span', 'rt-state rt-st-pending', label('pending')));
                        watch(data.relay, r.email);
                        start_poll();
                    }
                    warn.appendChild(unblock_button(data.relay, data.name, r.email, r.pending));
                }
                row.appendChild(warn);
            }
            body.appendChild(row);
        });

        var summary;
        if (!data.known && !rcpts.some(function (r) { return r.blocked; })) {
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

        if (data.known || issues) {
            if (auto) {
                body.appendChild(el('p', 'rt-note', '* ' + label('auto_open')));
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

    /* ---------- 2. compose: recipient blocked by the sender's relay ---------- */

    function compose_watch() {
        var by_domain = rc.env.relay_tracking_blocked || {}, anchor = document.getElementById('compose_subject');
        if (!Object.keys(by_domain).length || !document.getElementById('_to') || !anchor) {
            return;
        }

        var box = el('div', 'rt-compose'), last = '';
        box.setAttribute('role', 'alert');
        box.hidden = true;
        anchor.parentNode.insertBefore(box, anchor);

        // Domain of the selected identity: address given by Roundcube (env.identities[id].email), otherwise the
        // option's displayed text ("Name <address>").
        function from_domain() {
            var sel = document.getElementById('_from'), txt = '', ids = rc.env.identities || {};
            if (sel && sel.value && ids[sel.value] && ids[sel.value].email) {
                txt = ids[sel.value].email;
            } else if (sel && sel.options && sel.selectedIndex >= 0) {
                txt = sel.options[sel.selectedIndex].text || '';
            }
            var m = txt.match(/([^\s<>@]+)@([^\s<>@]+)/);
            return m ? m[2].toLowerCase() : '';
        }

        function check() {
            var domain = from_domain(), text = ['_to', '_cc', '_bcc'].map(function (id) {
                var f = document.getElementById(id);
                return f ? f.value : '';
            }).join(',') + '|' + domain;
            if (text === last) {
                return;
            }
            last = text;

            var relay = by_domain[domain], hits = [];
            if (relay && relay.contacts) {
                (text.match(/[^\s<>,;"']+@[^\s<>,;"'|]+/g) || []).forEach(function (e) {
                    e = e.toLowerCase();
                    if (relay.contacts[e] && hits.indexOf(e) < 0) hits.push(e);
                });
            }

            box.textContent = '';
            box.hidden = !hits.length;
            hits.forEach(function (e) {
                var line = el('div', 'rt-compose-line'), b = relay.contacts[e];
                line.appendChild(el('span', 'rt-compose-text', fill(label('compose_blocked'),
                    { email: e, relay: relay.name, reason: b.label, date: fmt_ts(b.at) })));
                if (relay.unblock && b.unblockable) {
                    line.appendChild(unblock_button(relay.relay, relay.name, e));
                }
                box.appendChild(line);
            });
        }

        // the recipient widgets update the hidden fields without events of their own, hence the light polling
        setInterval(check, 1000);
        check();
    }

    /* ---------- 3. Settings > Blocked contacts ---------- */

    function settings_page() {
        var root = document.getElementById('relay-tracking');
        if (!root) {
            return;
        }
        var name_of = function (node) {
            var h = node.closest('table') ? node.closest('table').previousElementSibling : null;
            while (h && !h.classList.contains('rt-relay')) h = h.previousElementSibling;
            return h ? h.textContent.split(' · ')[0] : '';
        };
        Array.prototype.forEach.call(root.querySelectorAll('button.rt-unblock'), function (btn) {
            bind_button(btn, btn.getAttribute('data-relay'), name_of(btn), btn.getAttribute('data-email'));
        });
        // request already pending: state tracked + (hidden) button ready in case the unblock fails
        Array.prototype.forEach.call(root.querySelectorAll('.rt-pending'), function (span) {
            var relay = span.getAttribute('data-relay'), email = span.getAttribute('data-email');
            span.className = 'rt-state rt-st-pending';
            span.parentNode.appendChild(unblock_button(relay, name_of(span), email, true));
            watch(relay, email);
        });
        if (Object.keys(watched).length) {
            start_poll();
        }
    }

    /* ---------- 4. "new blocked contact" alert (mail list) ---------- */

    function alert_new() {
        var a = rc.env.relay_tracking_alert, key = 'relay-tracking-alert';
        if (!a || !a.count) {
            return;
        }
        var sig = a.count + ':' + a.emails.join(',');
        try {
            if (sessionStorage.getItem(key) === sig) return;   // once per browser session
            sessionStorage.setItem(key, sig);
        }
        catch (e) {
            // storage unavailable: show it anyway
        }
        rc.display_message(fill(label('alert'), { n: a.count, emails: a.emails.join(', ') }), 'warning', 15000);
    }

    rc.addEventListener('init', function () {
        try {
            if (rc.env.task === 'mail' && (rc.env.action === 'show' || rc.env.action === 'preview')) render_track();
            else if (rc.env.task === 'mail' && rc.env.action === 'compose') compose_watch();
            else if (rc.env.task === 'settings') settings_page();
            else if (rc.env.task === 'mail' && !rc.env.action) alert_new();
        }
        catch (e) {
            // never break the page initialisation
            if (window.console) console.error('relay_tracking', e);
        }
    });
})();
