import Foundation

/// The script injected into every page and frame before the page's own code runs. It watches the page's network
/// calls (the API list), looks for attack payloads in what leaves the browser, and checks the page for the
/// signs of web shells, hidden click-hijack layers, miners and risky scripts. Everything it finds goes to the app
/// through the `pfSecurity` message handler; the app decides what to show.
enum PageGuardScript {
    static let handlerName = "pfSecurity"

    static func source(mode: WAFMode, allowedHosts: [String]) -> String {
        let minerPattern = WAFRules.minerHosts.map { $0.replacingOccurrences(of: ".", with: "\\\\.") }.joined(separator: "|")
        return template
            .replacingOccurrences(of: "%MODE%", with: mode.rawValue)
            .replacingOccurrences(of: "%RULES%", with: WAFRules.json)
            .replacingOccurrences(of: "%MINERHOSTS%", with: minerPattern)
            .replacingOccurrences(of: "%ALLOWED%", with: (try? JSONSerialization.data(withJSONObject: allowedHosts)).map { String(decoding: $0, as: UTF8.self) } ?? "[]")
    }

    private static let template = #"""
    (function () {
      if (window.__pfSec) return;
      window.__pfSec = true;
      var MODE = '%MODE%';
      var ALLOWED = %ALLOWED%;
      var topHost = (function () {
        try {
          if (location.ancestorOrigins && location.ancestorOrigins.length) {
            return new URL(location.ancestorOrigins[location.ancestorOrigins.length - 1]).hostname;
          }
        } catch (e) {}
        return location.hostname;
      })();
      // Sites the user chose to trust are not filtered.
      var BYPASS = ALLOWED.indexOf(String(topHost).toLowerCase().replace(/^www\./, '')) !== -1;
      var RULES = %RULES%;
      var isTop = window.top === window;
      var seen = {};
      var seenCount = 0;
      var origin = location.origin;

      function post(o) {
        try { window.webkit.messageHandlers.pfSecurity.postMessage(o); } catch (e) {}
      }
      function emit(kind, sev, title, detail, blocked) {
        var key = kind + '|' + title + '|' + String(detail || '').slice(0, 60);
        if (seen[key] || seenCount > 150) return;
        seen[key] = 1; seenCount++;
        post({ t: 'finding', kind: kind, sev: sev, title: title, detail: String(detail || '').slice(0, 300),
               blocked: !!blocked, frame: location.href.slice(0, 200) });
      }
      function abs(u) { try { return new URL(String(u), location.href).href; } catch (e) { return String(u); } }

      // ---------- user gestures: a click or key press is what makes a pop-up or download legitimate ----------
      var lastGesture = 0, lastSent = 0;
      function gesture(e) {
        if (!e.isTrusted) return;
        lastGesture = Date.now();
        if (lastGesture - lastSent > 250) { lastSent = lastGesture; post({ t: 'gesture' }); }
      }
      ['pointerdown', 'mousedown', 'keydown', 'touchstart'].forEach(function (n) {
        window.addEventListener(n, gesture, true);
      });
      function hasGesture() { return Date.now() - lastGesture < 1500; }

      // ---------- firewall: attack patterns in what the page sends ----------
      var compiled = RULES.map(function (r) {
        try { return { id: r.id, cat: r.cat, name: r.name, sev: r.sev, re: new RegExp(r.re, 'i') }; } catch (e) { return null; }
      }).filter(Boolean);
      function decode(s) {
        s = String(s).replace(/\+/g, ' ');
        for (var i = 0; i < 3; i++) {
          try { var d = decodeURIComponent(s); if (d === s) break; s = d; } catch (e) { break; }
        }
        return s;
      }
      function scan(text) {
        if (!text) return [];
        var d = decode(String(text).slice(0, 20000));
        return compiled.filter(function (r) { return r.re.test(d); });
      }
      function guardText(where, text) {
        if (MODE === 'off' || BYPASS) return false;
        var hits = scan(text);
        if (!hits.length) return false;
        var top = hits.reduce(function (a, b) { return (b.sev === 'high' && a.sev !== 'high') ? b : a; });
        var blocked = MODE === 'block' && top.sev !== 'low';
        var snippet = decode(String(text)).replace(/\s+/g, ' ').slice(0, 120);
        emit('injection', top.sev, top.cat + ': ' + top.name + ' in ' + where, snippet, blocked);
        return blocked;
      }
      function bodyText(b) {
        if (b == null) return '';
        if (typeof b === 'string') return b;
        if (b instanceof URLSearchParams) return b.toString();
        if (typeof FormData !== 'undefined' && b instanceof FormData) {
          var parts = [];
          b.forEach(function (v, k) { if (typeof v === 'string') parts.push(k + '=' + v); });
          return parts.join('&');
        }
        return '';
      }

      // ---------- API monitor ----------
      // Besides the address, each call keeps its headers and body, and the answer's headers and a text preview,
      // so the app can rebuild it as a cURL command. Nothing is stored on disk by the page.
      var perKey = {};
      var MAX_BODY = 8192, MAX_PREVIEW = 4000;
      function pairs(h) {
        var out = [];
        try {
          if (!h) return out;
          if (typeof Headers !== 'undefined' && h instanceof Headers) h.forEach(function (v, k) { out.push([k, String(v)]); });
          else if (Array.isArray(h)) h.forEach(function (p) { out.push([String(p[0]), String(p[1])]); });
          else Object.keys(h).forEach(function (k) { out.push([k, String(h[k])]); });
        } catch (e) {}
        return out.slice(0, 50);
      }
      function describeBody(b) {
        try {
          if (b == null) return null;
          if (typeof b === 'string') return b.length > MAX_BODY ? b.slice(0, MAX_BODY) : b;
          if (typeof URLSearchParams !== 'undefined' && b instanceof URLSearchParams) return b.toString().slice(0, MAX_BODY);
          if (typeof FormData !== 'undefined' && b instanceof FormData) {
            var parts = [];
            b.forEach(function (v, k) { parts.push(k + '=' + (typeof v === 'string' ? v : '[file ' + (v.name || '') + ']')); });
            return '[multipart] ' + parts.join('&').slice(0, MAX_BODY);
          }
          if (typeof Blob !== 'undefined' && b instanceof Blob) return '[binary ' + b.size + ' bytes]';
          if (b.byteLength !== undefined) return '[binary ' + b.byteLength + ' bytes]';
        } catch (e) {}
        return '[body]';
      }
      function parseRawHeaders(raw) {
        var out = [];
        String(raw || '').trim().split(/[\r\n]+/).forEach(function (line) {
          var i = line.indexOf(':');
          if (i > 0) out.push([line.slice(0, i).trim(), line.slice(i + 1).trim()]);
        });
        return out.slice(0, 50);
      }
      function textual(ct) { return /json|text|xml|javascript|x-www-form|graphql/i.test(ct || ''); }

      function apiStart(kind, method, url, req) {
        var full = abs(url);
        var key = kind + ' ' + method + ' ' + full.split('?')[0];
        var n = perKey[key] = (perKey[key] || 0) + 1;
        var report = n <= 5 || n % 25 === 0;
        if (report) {
          var m = { t: 'api', phase: 'start', kind: kind, method: method, url: full.slice(0, 600), n: n, page: location.href.slice(0, 300) };
          if (req) { m.headers = req.headers || []; m.body = req.body === undefined ? null : req.body; }
          post(m);
        }
        var begin = performance.now();
        return {
          report: report, kind: kind, method: method, url: full,
          end: function (status, ctype, failed, blocked) {
            if (!report) return;
            post({ t: 'api', phase: 'end', kind: kind, method: method, url: full.slice(0, 600), status: status || 0,
                   ms: Math.round(performance.now() - begin), ctype: (ctype || '').split(';')[0], failed: !!failed, blocked: !!blocked });
          },
          response: function (status, headerPairs, preview) {
            if (!report) return;
            post({ t: 'api', phase: 'resp', kind: kind, method: method, url: full.slice(0, 600), status: status || 0,
                   rheaders: headerPairs || [], preview: preview == null ? null : String(preview).slice(0, MAX_PREVIEW) });
          }
        };
      }

      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function (input, init) {
          var isReq = typeof Request !== 'undefined' && input instanceof Request;
          var url = typeof input === 'string' ? input : (input && input.url) || String(input);
          var method = ((init && init.method) || (isReq && input.method) || 'GET').toUpperCase();
          var headers = pairs((init && init.headers) || (isReq ? input.headers : null));
          var body = init && init.body !== undefined ? describeBody(init.body) : undefined;
          var tracker = apiStart('fetch', method, url, { headers: headers, body: body });
          if (isReq && body === undefined && method !== 'GET' && method !== 'HEAD' && tracker.report) {
            try {
              input.clone().text().then(function (t) {
                post({ t: 'api', phase: 'body', kind: 'fetch', method: method, url: tracker.url.slice(0, 600), body: t.slice(0, MAX_BODY) });
              }, function () {});
            } catch (e) {}
          }
          var blocked = guardText('request to ' + abs(url).split('?')[0], abs(url).replace(/^[a-z]+:\/\/[^\/]*/i, '') + ' ' + bodyText(init && init.body));
          if (blocked) {
            tracker.end(0, '', true, true);
            return Promise.reject(new TypeError('Blocked by the Pathfinder firewall'));
          }
          return origFetch.apply(this, arguments).then(function (r) {
            try {
              var ct = r.headers.get('content-type');
              tracker.end(r.status, ct, !r.ok && r.status >= 500, false);
              var hp = pairs(r.headers);
              var len = Number(r.headers.get('content-length') || 0);
              if (tracker.report && textual(ct) && (len === 0 || len < 300000)) {
                r.clone().text().then(function (t) { tracker.response(r.status, hp, t); }, function () { tracker.response(r.status, hp, null); });
              } else {
                tracker.response(r.status, hp, null);
              }
            } catch (e) {}
            return r;
          }, function (err) { tracker.end(0, '', true, false); throw err; });
        };
      }

      var xOpen = XMLHttpRequest.prototype.open, xSend = XMLHttpRequest.prototype.send, xSetHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__pf = { method: String(method || 'GET').toUpperCase(), url: url, headers: [] };
        return xOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        try { if (this.__pf && this.__pf.headers.length < 50) this.__pf.headers.push([String(name), String(value)]); } catch (e) {}
        return xSetHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function (body) {
        var info = this.__pf;
        if (info) {
          var tracker = apiStart('XHR', info.method, info.url, { headers: info.headers, body: describeBody(body) });
          var blocked = guardText('request to ' + abs(info.url).split('?')[0], abs(info.url).replace(/^[a-z]+:\/\/[^\/]*/i, '') + ' ' + bodyText(body));
          if (blocked) { tracker.end(0, '', true, true); throw new DOMException('Blocked by the Pathfinder firewall', 'NetworkError'); }
          var xhr = this;
          xhr.addEventListener('loadend', function () {
            try {
              var ct = xhr.getResponseHeader('content-type');
              tracker.end(xhr.status, ct, xhr.status === 0 || xhr.status >= 500, false);
              var preview = null;
              if ((xhr.responseType === '' || xhr.responseType === 'text') && textual(ct)) preview = xhr.responseText;
              tracker.response(xhr.status, parseRawHeaders(xhr.getAllResponseHeaders()), preview);
            } catch (e) {}
          });
        }
        return xSend.apply(this, arguments);
      };

      var origBeacon = navigator.sendBeacon;
      if (origBeacon) {
        navigator.sendBeacon = function (url, data) {
          var tracker = apiStart('Beacon', 'POST', url, { headers: [], body: describeBody(data) });
          tracker.end(204, '', false, false);
          return origBeacon.apply(this, arguments);
        };
      }

      var minerHost = new RegExp('(^|[./])(%MINERHOSTS%)', 'i');
      var stratumLike = /stratum\+|\b(xmr|monero|supportxmr|nanopool|minexmr|hashvault|moneroocean|cryptonight)\b/i;
      var NativeWS = window.WebSocket;
      if (NativeWS) {
        var PatchedWS = function (url, protocols) {
          var full = abs(url);
          if (minerHost.test(full) || stratumLike.test(full)) {
            emit('cryptojacking', 'high', 'Mining pool connection', full, MODE === 'block' && !BYPASS);
            if (MODE === 'block' && !BYPASS) throw new DOMException('Blocked by the Pathfinder firewall', 'SecurityError');
          }
          var ws = protocols === undefined ? new NativeWS(url) : new NativeWS(url, protocols);
          var tracker = apiStart('WebSocket', 'GET', full);
          post({ t: 'api', phase: 'open', kind: 'WebSocket', method: 'GET', url: full.slice(0, 400) });
          var origSend = ws.send;
          ws.send = function (data) {
            if (typeof data === 'string') {
              if (/"(method|type)"\s*:\s*"(login|auth)"/.test(data) && /"(agent|pass|job|algo)"/.test(data)) {
                emit('cryptojacking', 'high', 'Mining protocol over WebSocket', data.slice(0, 120), false);
              }
              guardText('WebSocket message', data);
            }
            return origSend.apply(this, arguments);
          };
          ws.addEventListener('close', function () {
            post({ t: 'api', phase: 'close', kind: 'WebSocket', method: 'GET', url: full.slice(0, 400) });
            tracker.end(101, '', false, false);
          });
          return ws;
        };
        PatchedWS.prototype = NativeWS.prototype;
        ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) { PatchedWS[k] = NativeWS[k]; });
        window.WebSocket = PatchedWS;
      }

      var NativeES = window.EventSource;
      if (NativeES) {
        var PatchedES = function (url, cfg) {
          var full = abs(url);
          var es = new NativeES(url, cfg);
          apiStart('SSE', 'GET', full);
          post({ t: 'api', phase: 'open', kind: 'SSE', method: 'GET', url: full.slice(0, 400) });
          var close = es.close;
          es.close = function () {
            post({ t: 'api', phase: 'close', kind: 'SSE', method: 'GET', url: full.slice(0, 400) });
            return close.apply(this, arguments);
          };
          return es;
        };
        PatchedES.prototype = NativeES.prototype;
        window.EventSource = PatchedES;
      }

      // ---------- forms: payloads typed or injected into fields ----------
      document.addEventListener('submit', function (e) {
        var form = e.target;
        if (!form || !form.elements) return;
        var parts = [];
        for (var i = 0; i < form.elements.length; i++) {
          var el = form.elements[i];
          if (!el.name || el.type === 'password' || el.type === 'file' || typeof el.value !== 'string') continue;
          parts.push(el.name + '=' + el.value);
        }
        if (guardText('form submission', parts.join('&'))) {
          e.preventDefault(); e.stopImmediatePropagation();
        }
        try {
          var action = abs(form.action || location.href);
          if (action.indexOf('http://') === 0 && form.querySelector('input[type=password]')) {
            emit('transport', 'high', 'Password sent over an unencrypted connection', action, false);
          }
        } catch (err) {}
      }, true);

      // ---------- pop-ups and programmatic clicks nobody asked for ----------
      var origOpen = window.open;
      window.open = function (url) {
        if (!hasGesture()) {
          var blocked = MODE === 'block' && !BYPASS;
          emit('malvertising', 'medium', 'Pop-up opened without a click', url ? abs(url) : '(blank)', blocked);
          if (blocked) return null;
        }
        return origOpen.apply(this, arguments);
      };
      var origClick = HTMLElement.prototype.click;
      HTMLElement.prototype.click = function () {
        try {
          if (this instanceof HTMLAnchorElement && !hasGesture()) {
            var href = abs(this.href || '');
            var isDownload = this.hasAttribute('download') || /\.(exe|msi|dmg|pkg|scr|bat|cmd|jar|apk|ps1|vbs|hta|lnk|iso|sh|command)(\?|#|$)/i.test(href);
            if (isDownload) {
              var blocked = MODE === 'block' && !BYPASS;
              emit('driveBy', 'high', 'Script clicked a download link by itself', href, blocked);
              if (blocked) return;
            } else if (this.target === '_blank' || (href && new URL(href).origin !== origin)) {
              var blockedNav = MODE === 'block' && !BYPASS && this.target === '_blank';
              emit('malvertising', 'medium', 'Script clicked a link by itself', href, blockedNav);
              if (blockedNav) return;
            }
          }
        } catch (e) {}
        return origClick.apply(this, arguments);
      };

      // ---------- obfuscated code ----------
      function looksObfuscated(code) {
        var s = String(code);
        if (/eval\(function\(p,a,c,k,e,[dr]\)/.test(s) || /\}\('.{200,}',\d+,\d+,'/.test(s)) return 'packed script (p,a,c,k,e,d)';
        if ((s.match(/_0x[0-9a-f]{4,6}/g) || []).length > 30) return 'obfuscator.io style identifiers';
        if (/(\\x[0-9a-f]{2}){24,}/i.test(s)) return 'long hex-escaped string';
        if (/(\\u[0-9a-f]{4}){24,}/i.test(s)) return 'long unicode-escaped string';
        return null;
      }
      // The page's scripts are read, not hooked: replacing window.eval would turn the page's direct eval calls
      // into indirect ones, which run at global scope and break players that build their stream address with eval.
      var scriptsRead = 0;
      function checkScriptText(code) {
        if (scriptsRead >= 200 || !code) return;
        scriptsRead++;
        var text = String(code).slice(0, 200000);
        var why = looksObfuscated(text);
        if (why) emit('malvertising', 'low', 'Obfuscated code in a page script', why, false);
        if (/coinhive|cryptonight|CryptoLoot|new\s+CoinHive/i.test(text)) emit('cryptojacking', 'high', 'Miner code in a page script', text.slice(0, 100), false);
      }
      function checkInlineScripts() {
        var inline = document.querySelectorAll('script:not([src])');
        for (var i = 0; i < inline.length; i++) {
          if (inline[i].__pfRead) continue;
          inline[i].__pfRead = true;
          checkScriptText(inline[i].textContent);
        }
      }
      try {
        var scriptWatcher = new MutationObserver(function (records) {
          for (var i = 0; i < records.length; i++) {
            var added = records[i].addedNodes;
            for (var j = 0; j < added.length; j++) {
              var n = added[j];
              if (n.tagName === 'SCRIPT' && !n.src && !n.__pfRead) { n.__pfRead = true; checkScriptText(n.textContent); }
            }
          }
          if (scriptsRead >= 200) scriptWatcher.disconnect();
        });
        scriptWatcher.observe(document, { childList: true, subtree: true });
      } catch (e) {}

      // ---------- cryptojacking: workers and miner scripts ----------
      var minerName = /(coin-?hive|crypto-?loot|coinimp|web-?miner|deep-?miner|jsecoin|authedmine|minero|webmr|cryptonight|monero-?miner|xmr-?(stak|rig|miner)|cn-?wasm)/i;
      var NativeWorker = window.Worker;
      if (NativeWorker) {
        var PatchedWorker = function (url, opts) {
          try {
            var full = abs(url);
            if (minerName.test(full) || minerHost.test(full)) {
              var stop = MODE === 'block' && !BYPASS;
              emit('cryptojacking', 'high', 'Mining worker started', full, stop);
              if (stop) throw new DOMException('Blocked by the Pathfinder firewall', 'SecurityError');
            }
          } catch (e) { if (e && e.name === 'SecurityError') throw e; }
          return opts === undefined ? new NativeWorker(url) : new NativeWorker(url, opts);
        };
        PatchedWorker.prototype = NativeWorker.prototype;
        window.Worker = PatchedWorker;
      }

      // ---------- page checks (after the page has had time to build itself) ----------
      var WEBSHELL_NAMES = /(c99|r57|wso|b374k|webshell|web shell|filesman|china chopper|alfa team|alfashell|indoxploit|mini shell|p0wny|weevely|phpspy|php shell|safe0ver|antichat|ani-shell|dhanush|sym403)/i;
      var WEBSHELL_PATH = /(^|\/)(c99|r57|wso|b374k|alfa|indoxploit|filesman|webshell|backdoor|p0wny|phpspy|shell|cmd|mini)[\w.-]*\.(php\d?|phtml|asp|aspx|jsp|jspx|cfm)(\?|$)/i;

      function checkWebShell() {
        if (!isTop) return;
        var score = 0, why = [];
        var title = document.title || '';
        var text = (document.body && document.body.innerText || '').slice(0, 6000);
        if (WEBSHELL_NAMES.test(title)) { score += 3; why.push('title "' + title.slice(0, 40) + '"'); }
        var m = text.match(WEBSHELL_NAMES);
        if (m) { score += 2; why.push('page text mentions "' + m[0] + '"'); }
        if (WEBSHELL_PATH.test(location.pathname)) { score += 1; why.push('file name ' + location.pathname.split('/').pop()); }
        if (/\/wp-content\/(uploads|upgrade)\/.+\.(php|phtml)(\?|$)/i.test(location.pathname)) { score += 2; why.push('PHP file inside wp-content/uploads'); }
        var cmdInput = document.querySelector('input[name=cmd], input[name=command], input[name=exec], textarea[name=cmd], input[name=c], input[name=execute]');
        if (cmdInput) { score += 2; why.push('command input field'); }
        if (/(uname -a|Safe-?mode|Server IP|\buid=\d+\(.+\)\s+gid=\d+|\[ ?Sec\. Info ?\]|Execute command|File ?Manager.*(Upload|Chmod)|Php ?Info.*Sql)/i.test(text)) { score += 2; why.push('shell-style output on the page'); }
        if (document.querySelector('input[type=file]') && cmdInput) { score += 1; why.push('upload form next to a command box'); }
        if (score >= 3) emit('webShell', score >= 5 ? 'high' : 'medium', 'This page looks like a web shell', why.join('; '), false);
      }

      function checkRedirects() {
        if (!isTop) return;
        var metas = document.querySelectorAll('meta[http-equiv]');
        for (var i = 0; i < metas.length; i++) {
          if (String(metas[i].httpEquiv).toLowerCase() !== 'refresh') continue;
          var m = String(metas[i].content).match(/^\s*(\d+(?:\.\d+)?)\s*[;,]\s*(?:url\s*=\s*)?['"]?([^'"]+)/i);
          if (!m) continue;
          var target = abs(m[2]);
          try {
            if (new URL(target).origin !== origin) {
              emit('redirect', parseFloat(m[1]) <= 1 ? 'high' : 'medium', 'Page redirects to another site on its own',
                   'meta refresh after ' + m[1] + ' s to ' + target, false);
            }
          } catch (e) {}
        }
        // A page that is nothing but a frame to another site is a common cloaking / redirect shell.
        var frames = document.querySelectorAll('iframe');
        var text = (document.body && document.body.innerText || '').trim();
        if (frames.length === 1 && text.length < 20) {
          var f = frames[0], r = f.getBoundingClientRect();
          try {
            if (r.width >= innerWidth * 0.9 && r.height >= innerHeight * 0.9 && f.src && new URL(abs(f.src)).origin !== origin) {
              emit('redirect', 'medium', 'Page is only a full-window frame of another site', abs(f.src), false);
            }
          } catch (e) {}
        }
      }

      function checkOverlays() {
        if (!isTop || !document.body) return;
        var w = innerWidth, h = innerHeight;
        var pts = [[w / 2, h / 2], [w * 0.25, h * 0.25], [w * 0.75, h * 0.75]];
        for (var i = 0; i < pts.length; i++) {
          var el = document.elementFromPoint(pts[i][0], pts[i][1]);
          if (!el || el === document.body || el === document.documentElement) continue;
          var cs = getComputedStyle(el), r = el.getBoundingClientRect();
          var covers = r.width >= w * 0.85 && r.height >= h * 0.85;
          var pos = cs.position === 'fixed' || cs.position === 'absolute';
          var invisible = parseFloat(cs.opacity) < 0.05 || cs.backgroundColor === 'rgba(0, 0, 0, 0)' && !el.textContent.trim() && !el.querySelector('img,video,canvas,svg');
          var clickable = el.tagName === 'A' || el.tagName === 'IFRAME' || !!el.onclick || el.getAttribute('onclick') || el.closest('a');
          if (covers && pos && invisible && clickable && parseInt(cs.zIndex || '0', 10) > 100) {
            emit('malvertising', 'high', 'Invisible full-page layer will catch your clicks',
                 el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (el.src ? ' → ' + abs(el.src) : el.href ? ' → ' + abs(el.href) : ''), false);
            return;
          }
        }
      }

      function checkMiners() {
        var scripts = document.querySelectorAll('script[src], iframe[src]');
        for (var i = 0; i < scripts.length; i++) {
          var src = abs(scripts[i].src);
          if (minerName.test(src) || minerHost.test(src)) emit('cryptojacking', 'high', 'Miner script on this page', src, false);
        }
        var globals = ['CoinHive', 'CryptoLoot', 'CoinImp', 'deepMiner', 'JSECoin', 'Client'];
        for (var j = 0; j < globals.length; j++) {
          try {
            var g = window[globals[j]];
            if (g && (g.Anonymous || g.User || g.Token) && typeof g === 'object' && globals[j] !== 'Client') {
              emit('cryptojacking', 'high', 'Miner library loaded', globals[j], false);
            } else if (globals[j] === 'Client' && g && typeof g.Anonymous === 'function') {
              emit('cryptojacking', 'high', 'Miner library loaded', 'Client.Anonymous', false);
            }
          } catch (e) {}
        }
      }

      function checkUrlPayload() {
        if (!isTop) return;
        if (MODE === 'off' || BYPASS) return;
        var query = location.search + location.hash;
        var hits = scan(location.pathname + query).filter(function (r) { return r.cat === 'XSS'; });
        if (!hits.length) return;
        // Reflected: the payload from the address is now part of the page's markup.
        var html = document.documentElement.innerHTML;
        var params = new URLSearchParams(location.search + '&' + location.hash.replace(/^#/, ''));
        params.forEach(function (v) {
          if (v.length < 8) return;
          var dv = decode(v);
          if (scan(dv).some(function (r) { return r.cat === 'XSS'; }) && html.indexOf(dv) !== -1) {
            emit('injection', 'high', 'Reflected XSS: the page echoed a script payload from its address', dv.slice(0, 120), false);
          }
        });
      }

      function run() {
        try { checkInlineScripts(); checkMiners(); checkWebShell(); checkRedirects(); checkUrlPayload(); } catch (e) {}
        setTimeout(function () { try { checkOverlays(); checkMiners(); } catch (e) {} }, 2000);
        setTimeout(function () { try { checkOverlays(); checkMiners(); } catch (e) {} }, 6000);
      }
      if (isTop) {
        try {
          if (!BYPASS && MODE !== 'off') {
            var urlHits = scan(location.pathname + location.search + location.hash);
            if (urlHits.length) {
              var worst = urlHits.reduce(function (a, b) { return (b.sev === 'high' && a.sev !== 'high') ? b : a; });
              emit('injection', worst.sev, worst.cat + ': ' + worst.name + ' in this page\'s address', decode(location.pathname + location.search).slice(0, 120), false);
            }
          }
        } catch (e) {}
      }
      if (document.readyState === 'complete') setTimeout(run, 300);
      else window.addEventListener('load', function () { setTimeout(run, 300); });
    })();
    """#
}
