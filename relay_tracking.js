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

    // An open this close to delivery is almost certainly the provider's image proxy (Proton, Apple...), not a reader
    var AUTO_OPEN_MS = 20000;

    // Opens and clicks are kept one by one, in date order (events come sorted from the collector); ev[3] is the IP
    // when the collector includes it (INCLUDE_IP=1)
    function analyse(events) {
        var a = { opens: 0, auto_opens: 0, clicks: 0, activity: [], links: {}, problems: [], retried: [] }, delivered_t = 0;

        events.forEach(function (ev) {
            if (String(ev[1]) === 'delivered' && !a.delivered) {
                a.delivered = ev[0];
                a.delivered_ip = ev[3] || '';
                delivered_t = time(ev[0]);
            }
        });

        events.forEach(function (ev) {
            var t = String(ev[1] || ''), d = ev[0], extra = ev[2] || '', ip = ev[3] || '';
            if (t === 'sent') {
                if (!a.sent) {
                    a.sent = d;
                    a.sent_ip = ip;
                }
            }
            else if (t === 'opened' || t === 'proxy_open') {
                var auto = t === 'proxy_open' || (delivered_t && Math.abs(time(d) - delivered_t) < AUTO_OPEN_MS);
                a.activity.push({ k: 'opened', d: d, ip: ip, auto: !!auto });
                if (auto) a.auto_opens++;
                else a.opens++;
            }
            else if (t === 'clicked') {
                a.clicks++;
                a.activity.push({ k: 'clicked', d: d, ip: ip, link: extra });
                if (extra) a.links[extra] = (a.links[extra] || 0) + 1;
            }
            else if (PROBLEMS.indexOf(t) >= 0) {
                var p = { k: t, d: d, reason: extra, ip: ip };
                if (delivered_t && TRANSIENT.indexOf(t) >= 0 && time(d) <= delivered_t) {
                    a.retried.push(p);
                }
                else {
                    a.problems.push(p);
                }
            }
        });
        return a;
    }

    // Tooltip lines: reason or link, IP, note
    function tip() {
        return Array.prototype.filter.call(arguments, function (x) { return !!x; }).join('\n') || null;
    }

    function ip_line(ip) {
        return ip ? fill(label('ip'), { ip: ip }) : '';
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
            var a = analyse(r.events || []), row = el('div', 'rt-rcpt'), steps = el('ul', 'rt-steps');
            if (a.delivered) delivered++;
            if (a.opens) opened++;
            clicks += a.clicks;
            if (a.problems.length) issues++;

            row.appendChild(el('div', 'rt-email', r.email));

            function step(cls, text, title) {
                var li = el('li', 'rt-step rt-' + cls, text);
                if (title) li.title = title;
                steps.appendChild(li);
            }

            a.retried.forEach(function (p) {
                step('retried', label('ev_' + p.k) + ' · ' + fmt(p.d), tip(p.reason, ip_line(p.ip)));
            });
            if (a.delivered) step('ok', label('ev_delivered') + ' · ' + fmt(a.delivered), tip(ip_line(a.delivered_ip)));
            else if (a.sent && !a.problems.length) step('wait', label('ev_sent') + ' · ' + fmt(a.sent), tip(ip_line(a.sent_ip)));
            a.activity.forEach(function (x) {
                if (x.k === 'clicked') {
                    step('ok', label('ev_clicked') + ' · ' + fmt(x.d), tip(x.link, ip_line(x.ip)));
                }
                else if (x.auto) {
                    // automatic open: shown apart, it does not prove a read
                    auto = true;
                    step('auto', label('ev_opened') + ' · ' + fmt(x.d) + ' *', tip(ip_line(x.ip), label('auto_open')));
                }
                else {
                    step('ok', label('ev_opened') + ' · ' + fmt(x.d), tip(ip_line(x.ip)));
                }
            });
            a.problems.forEach(function (p) {
                step('bad', label('ev_' + p.k) + ' · ' + fmt(p.d), tip(p.reason, ip_line(p.ip)));
            });
            if (!(r.events || []).length) step('none', label('ev_none'));
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
