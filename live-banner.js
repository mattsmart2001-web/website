/* ============================================================
 * SparksTheory "live on YouTube" badge
 *
 * Drop <script defer src="/live-banner.js"></script> on any page.
 * It polls the youtube-live Netlify function and, when the channel
 * is broadcasting, shows a prominent dismissible banner (stream
 * thumbnail, pulsing LIVE NOW, title, Watch button) linking to the
 * stream. Self-contained: injects its own styles, no dependencies,
 * works the same on the GTEC pages and the main site. It floats
 * (position:fixed) so it never disturbs any page's layout.
 *
 * The Netlify function is same-origin (/.netlify/functions/...), so
 * it satisfies the GTEC pages' connect-src 'self' CSP. Thumbnails
 * come from i.ytimg.com over https, allowed by img-src.
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
      + '.st-live{position:fixed;left:50%;bottom:22px;transform:translate(-50%,160%);z-index:2147483000;'
      + 'width:min(430px,calc(100vw - 28px));'
      + 'display:flex;align-items:stretch;gap:0;overflow:hidden;'
      + 'border-radius:16px;background:linear-gradient(135deg,#1a1013 0%,#141317 60%);'
      + 'border:1.5px solid rgba(225,6,0,0.75);'
      + 'box-shadow:0 12px 40px rgba(0,0,0,0.55),0 0 0 1px rgba(0,0,0,0.4);'
      + 'opacity:0;transition:transform .5s cubic-bezier(.2,.9,.2,1),opacity .5s;'
      + 'animation:st-live-glow 2.2s ease-in-out infinite;}'
      + '.st-live.st-show{transform:translate(-50%,0);opacity:1;}'
      + '@keyframes st-live-glow{0%,100%{box-shadow:0 12px 40px rgba(0,0,0,0.55),0 0 0 1px rgba(0,0,0,0.4),0 0 0 0 rgba(225,6,0,0);}'
      + '50%{box-shadow:0 12px 46px rgba(0,0,0,0.55),0 0 0 1px rgba(0,0,0,0.4),0 0 26px 2px rgba(225,6,0,0.45);}}'
      + '.st-live a.st-live-main{display:flex;align-items:stretch;gap:0;text-decoration:none;color:#fff;flex:1;min-width:0;}'
      + '.st-live-thumb{position:relative;flex:0 0 132px;background:#000;overflow:hidden;}'
      + '.st-live-thumb img{width:100%;height:100%;object-fit:cover;display:block;}'
      + '.st-live-thumb::after{content:"";position:absolute;inset:0;background:linear-gradient(90deg,rgba(0,0,0,0) 55%,#141317 100%);}'
      + '.st-live-play{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:34px;height:34px;border-radius:50%;'
      + 'background:rgba(225,6,0,0.92);display:flex;align-items:center;justify-content:center;box-shadow:0 2px 10px rgba(0,0,0,.5);}'
      + '.st-live-play::after{content:"";margin-left:2px;border-style:solid;border-width:7px 0 7px 12px;border-color:transparent transparent transparent #fff;}'
      + '.st-live-body{flex:1;min-width:0;display:flex;flex-direction:column;justify-content:center;gap:5px;padding:13px 14px;}'
      + '.st-live-tag{display:inline-flex;align-items:center;gap:7px;font-family:"Barlow Condensed","Arial Narrow",system-ui,sans-serif;'
      + 'font-weight:700;letter-spacing:.16em;text-transform:uppercase;font-size:13px;color:#ff4d4d;}'
      + '.st-live-dot{position:relative;flex:0 0 auto;width:9px;height:9px;border-radius:50%;background:#e10600;box-shadow:0 0 8px #e10600;}'
      + '.st-live-dot::after{content:"";position:absolute;inset:0;border-radius:50%;background:#e10600;animation:st-live-pulse 1.6s ease-out infinite;}'
      + '@keyframes st-live-pulse{0%{transform:scale(1);opacity:.7}100%{transform:scale(3.4);opacity:0}}'
      + '.st-live-title{font-family:"Barlow",system-ui,sans-serif;font-weight:600;font-size:14px;line-height:1.25;color:#f3f3f5;'
      + 'display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;}'
      + '.st-live-cta{align-self:flex-start;margin-top:2px;font-family:"Barlow Condensed","Arial Narrow",system-ui,sans-serif;'
      + 'font-weight:700;letter-spacing:.1em;text-transform:uppercase;font-size:12px;color:#fff;'
      + 'background:#e10600;border-radius:7px;padding:6px 11px;display:inline-flex;align-items:center;gap:6px;}'
      + '.st-live:hover .st-live-cta{background:#ff2a24;}'
      + '.st-live-cta svg{width:12px;height:12px;fill:#fff;}'
      + '.st-live-x{position:absolute;top:6px;right:6px;z-index:2;appearance:none;background:rgba(0,0,0,0.45);border:0;cursor:pointer;'
      + 'color:#d7d7db;width:22px;height:22px;line-height:1;font-size:16px;border-radius:50%;display:flex;align-items:center;justify-content:center;}'
      + '.st-live-x:hover{color:#fff;background:rgba(0,0,0,0.7);}'
      + '@media (max-width:480px){.st-live{bottom:14px;}.st-live-thumb{flex-basis:104px;}.st-live-title{-webkit-line-clamp:1;}}'
      + '@media (prefers-reduced-motion:reduce){.st-live{transition:opacity .3s;animation:none}.st-live-dot::after{animation:none}}';
    var s = document.createElement('style');
    s.id = 'st-live-css';
    s.textContent = css;
    document.head.appendChild(s);
  }

  var el = null;

  function remove() {
    if (el) { el.classList.remove('st-show'); var n = el; setTimeout(function () { if (n && n.parentNode) n.parentNode.removeChild(n); }, 550); el = null; }
  }

  function show(info) {
    // Respect a dismissal, but only for that exact stream. A new
    // broadcast (new videoId) brings the banner back.
    try { if (localStorage.getItem(DISMISS_KEY) === info.videoId) return; } catch (e) {}
    if (el) return;                        // already showing
    injectCSS();

    el = document.createElement('div');
    el.className = 'st-live';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');

    var a = document.createElement('a');
    a.className = 'st-live-main';
    a.href = info.url;
    a.target = '_blank';
    a.rel = 'noopener';
    a.setAttribute('aria-label', 'Watch the live stream on YouTube: ' + (info.title || ''));

    // Thumbnail (falls back gracefully to just the play button if it 404s).
    var thumb = document.createElement('div');
    thumb.className = 'st-live-thumb';
    if (info.videoId) {
      var img = document.createElement('img');
      img.src = 'https://i.ytimg.com/vi/' + info.videoId + '/mqdefault.jpg';
      img.alt = '';
      img.loading = 'lazy';
      img.addEventListener('error', function () { img.style.display = 'none'; });
      thumb.appendChild(img);
    }
    var play = document.createElement('span');
    play.className = 'st-live-play';
    thumb.appendChild(play);

    var body = document.createElement('div');
    body.className = 'st-live-body';

    var tag = document.createElement('span');
    tag.className = 'st-live-tag';
    var dot = document.createElement('span');
    dot.className = 'st-live-dot';
    tag.appendChild(dot);
    tag.appendChild(document.createTextNode('Live now on YouTube'));

    var title = document.createElement('span');
    title.className = 'st-live-title';
    title.textContent = info.title || 'SparksTheory is streaming';

    var cta = document.createElement('span');
    cta.className = 'st-live-cta';
    cta.innerHTML = '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>Watch now';

    body.appendChild(tag);
    body.appendChild(title);
    body.appendChild(cta);

    a.appendChild(thumb);
    a.appendChild(body);

    var x = document.createElement('button');
    x.className = 'st-live-x';
    x.type = 'button';
    x.setAttribute('aria-label', 'Dismiss');
    x.innerHTML = '&times;';
    x.addEventListener('click', function (e) {
      e.preventDefault(); e.stopPropagation();
      try { localStorage.setItem(DISMISS_KEY, info.videoId || '1'); } catch (err) {}
      remove();
    });

    el.appendChild(a);
    el.appendChild(x);
    document.body.appendChild(el);
    // next frame -> slide up
    requestAnimationFrame(function () { requestAnimationFrame(function () { if (el) el.classList.add('st-show'); }); });
  }

  function check() {
    fetch(ENDPOINT, { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) {
        if (d && d.live && d.url) show(d);
        else remove();                      // stream ended -> pull the banner
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
