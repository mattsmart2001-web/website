/* ============================================================
 * SparksTheory — "live on YouTube" badge
 *
 * Drop <script defer src="/live-banner.js"></script> on any page.
 * It polls the youtube-live Netlify function and, when the channel
 * is broadcasting, shows a small dismissible pill linking to the
 * stream. Self-contained: injects its own styles, no dependencies,
 * works the same on the GTEC pages and the main site.
 *
 * The Netlify function is same-origin (/.netlify/functions/...), so
 * it satisfies the GTEC pages' connect-src 'self' CSP.
 * ============================================================ */
(function () {
  'use strict';
  if (window.__stLiveBanner) return;      // guard against double-injection
  window.__stLiveBanner = true;

  var ENDPOINT = '/.netlify/functions/youtube-live';
  var POLL_MS = 90 * 1000;                 // check every 90s
  var DISMISS_KEY = 'st-live-dismissed';   // stores the dismissed videoId

  function injectCSS() {
    if (document.getElementById('st-live-css')) return;
    var css = ''
      + '.st-live{position:fixed;left:18px;bottom:18px;z-index:2147483000;'
      + 'display:flex;align-items:center;gap:10px;max-width:min(340px,calc(100vw - 36px));'
      + 'padding:10px 12px 10px 13px;border-radius:12px;'
      + 'background:rgba(17,19,24,0.92);border:1px solid rgba(225,6,0,0.55);'
      + 'box-shadow:0 8px 30px rgba(0,0,0,0.45),0 0 0 1px rgba(0,0,0,0.3);'
      + 'backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);'
      + 'font-family:"Barlow Condensed","Arial Narrow",system-ui,sans-serif;'
      + 'transform:translateY(140%);opacity:0;transition:transform .45s cubic-bezier(.2,.8,.2,1),opacity .45s;}'
      + '.st-live.st-show{transform:translateY(0);opacity:1;}'
      + '.st-live a.st-live-main{display:flex;align-items:center;gap:10px;text-decoration:none;color:#fff;min-width:0;}'
      + '.st-live-dot{position:relative;flex:0 0 auto;width:11px;height:11px;border-radius:50%;background:#e10600;}'
      + '.st-live-dot::after{content:"";position:absolute;inset:0;border-radius:50%;background:#e10600;animation:st-live-pulse 1.6s ease-out infinite;}'
      + '@keyframes st-live-pulse{0%{transform:scale(1);opacity:.7}100%{transform:scale(3.2);opacity:0}}'
      + '.st-live-txt{min-width:0;line-height:1.05;}'
      + '.st-live-txt b{display:block;font-weight:700;letter-spacing:.14em;text-transform:uppercase;font-size:12.5px;color:#fff;}'
      + '.st-live-txt span{display:block;font-family:"Barlow",system-ui,sans-serif;font-weight:500;font-size:12px;'
      + 'letter-spacing:.01em;color:#c9ccd2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:220px;}'
      + '.st-live-x{flex:0 0 auto;appearance:none;background:transparent;border:0;cursor:pointer;'
      + 'color:#868d98;font-size:17px;line-height:1;padding:2px 4px;border-radius:6px;}'
      + '.st-live-x:hover{color:#fff;background:rgba(255,255,255,0.08);}'
      + '@media (prefers-reduced-motion:reduce){.st-live{transition:opacity .3s}.st-live-dot::after{animation:none}}';
    var s = document.createElement('style');
    s.id = 'st-live-css';
    s.textContent = css;
    document.head.appendChild(s);
  }

  var el = null;

  function remove() {
    if (el) { el.classList.remove('st-show'); var n = el; setTimeout(function () { if (n && n.parentNode) n.parentNode.removeChild(n); }, 500); el = null; }
  }

  function show(info) {
    // Respect a dismissal, but only for that exact stream — a new
    // broadcast (new videoId) brings the pill back.
    try { if (localStorage.getItem(DISMISS_KEY) === info.videoId) return; } catch (e) {}
    if (el) return;                        // already showing
    injectCSS();

    el = document.createElement('div');
    el.className = 'st-live';
    el.setAttribute('role', 'status');

    var a = document.createElement('a');
    a.className = 'st-live-main';
    a.href = info.url;
    a.target = '_blank';
    a.rel = 'noopener';
    a.setAttribute('aria-label', 'Watch the live stream on YouTube');

    var dot = document.createElement('span');
    dot.className = 'st-live-dot';

    var txt = document.createElement('span');
    txt.className = 'st-live-txt';
    var b = document.createElement('b');
    b.textContent = 'Live on YouTube';
    var sub = document.createElement('span');
    sub.textContent = info.title ? info.title : 'Watch now';
    txt.appendChild(b);
    txt.appendChild(sub);

    a.appendChild(dot);
    a.appendChild(txt);

    var x = document.createElement('button');
    x.className = 'st-live-x';
    x.type = 'button';
    x.setAttribute('aria-label', 'Dismiss');
    x.innerHTML = '&times;';
    x.addEventListener('click', function () {
      try { localStorage.setItem(DISMISS_KEY, info.videoId || '1'); } catch (e) {}
      remove();
    });

    el.appendChild(a);
    el.appendChild(x);
    document.body.appendChild(el);
    // next frame -> slide in
    requestAnimationFrame(function () { requestAnimationFrame(function () { if (el) el.classList.add('st-show'); }); });
  }

  function check() {
    fetch(ENDPOINT, { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) {
        if (d && d.live && d.url) show(d);
        else remove();                      // stream ended -> pull the pill
      })
      .catch(function () { /* offline / blocked -> just try again later */ });
  }

  function start() {
    check();
    setInterval(check, POLL_MS);
    // Re-check when the tab regains focus, so it feels responsive.
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible') check();
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
