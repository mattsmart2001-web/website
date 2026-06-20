/* GTEC service worker — PWA shell + offline cache.
   Lives at /endurance/sw.js so its scope is exactly /endurance/*. */
'use strict';

// Bump this string to force every client to refetch their shell.
const CACHE_NAME = 'gtec-shell-v18';

// Assets to pre-cache on install. Keep this short — fonts and Supabase
// data are intentionally omitted so they always come fresh. The list is
// "what we need to render an offline-friendly shell."
const PRECACHE = [
    '/endurance/',
    '/endurance/calendar/',
    '/endurance/standings/',
    '/endurance/results/',
    '/endurance/drivers/',
    '/endurance/teams/',
    '/endurance/stats/',
    '/endurance/news/',
    '/endurance/media/',
    '/endurance/rules/',
    '/endurance/apply/',
    '/endurance/assets/gtec-config.js',
    '/endurance/assets/gtec-nav.css',
    '/endurance/assets/gtec-nav.js',
    '/endurance/assets/gtec-stars.js',
    '/endurance/assets/gtec-sponsors.js',
    '/endurance/assets/gtec-footer.js',
    '/endurance/assets/elo-tiers.js?v=3',
    '/endurance/assets/gtec-badges.js?v=11',
    '/endurance/assets/gtec-share-card.js?v=5',
    '/endurance/assets/countries.js',
    '/endurance/assets/gtec-logo.png',
    '/endurance/assets/gtec-icon.svg',
    '/endurance/assets/gtec-icon-maskable.svg',
    '/endurance/assets/icon-192.png',
    '/endurance/assets/icon-512.png',
    '/endurance/assets/apple-touch-icon.png',
    '/endurance/assets/og-card.png',
    '/sparks_logo.jpg',
    '/simlab.png',
    '/logo_tm_simracing.png',
    '/yfood_logo_black-960x264.png',
];

self.addEventListener('install', (event) => {
    event.waitUntil((async () => {
        const cache = await caches.open(CACHE_NAME);
        // addAll fails the whole batch on a single 4xx/5xx, which would
        // bork the install. We add one at a time and swallow misses so a
        // page that hasn't shipped yet doesn't take down the install.
        await Promise.all(PRECACHE.map((url) =>
            cache.add(new Request(url, { cache: 'reload' })).catch(() => null)
        ));
        await self.skipWaiting();
    })());
});

self.addEventListener('activate', (event) => {
    event.waitUntil((async () => {
        const keys = await caches.keys();
        await Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)));
        await self.clients.claim();
    })());
});

self.addEventListener('fetch', (event) => {
    const req = event.request;
    if (req.method !== 'GET') return;

    const url = new URL(req.url);

    // Don't intercept anything outside the GTEC scope. Lets the main
    // /sparkstheory.co.uk/ site work normally if the SW is somehow
    // controlling it.
    if (url.origin === location.origin && !url.pathname.startsWith('/endurance/')) {
        return;
    }

    // Supabase / 3rd party data must always go to the network — caching
    // would break realtime + auth tokens.
    if (url.hostname.includes('supabase.co') || url.hostname.includes('supabase.in')) return;
    if (url.hostname.endsWith('jsdelivr.net'))   return; // supabase-js cdn
    if (url.hostname.endsWith('gstatic.com'))    return; // google fonts
    if (url.hostname.endsWith('googleapis.com')) return; // google fonts
    if (url.hostname.endsWith('img.youtube.com')) return; // media thumbs

    // For app navigations (full HTML loads) go network-first so users
    // always see the freshest page; fall back to the cached copy when
    // offline.
    const accept = req.headers.get('accept') || '';
    const isHTML = req.mode === 'navigate' || accept.includes('text/html');

    if (isHTML) {
        event.respondWith((async () => {
            try {
                const fresh = await fetch(req);
                const cache = await caches.open(CACHE_NAME);
                cache.put(req, fresh.clone()).catch(() => null);
                return fresh;
            } catch (err) {
                const cached = await caches.match(req);
                if (cached) return cached;
                // Last-ditch: serve the landing shell so we never hit
                // browser's default offline error page.
                const fallback = await caches.match('/endurance/');
                return fallback || new Response('Offline', { status: 503 });
            }
        })());
        return;
    }

    // Same-origin static assets: cache-first, then network.
    if (url.origin === location.origin) {
        event.respondWith((async () => {
            const cached = await caches.match(req);
            if (cached) return cached;
            try {
                const fresh = await fetch(req);
                if (fresh && fresh.status === 200) {
                    const cache = await caches.open(CACHE_NAME);
                    cache.put(req, fresh.clone()).catch(() => null);
                }
                return fresh;
            } catch (err) {
                return cached || new Response('', { status: 503 });
            }
        })());
    }
});
