/* GTEC service worker - PWA shell + offline cache.
   Lives at /endurance/sw.js so its scope is exactly /endurance/*. */
'use strict';

// Bump this string to force every client to refetch their shell.
// v33: the asset strategy below changed from cache-first-for-ever to
// stale-while-revalidate, and the bump is also what evicts the terrain file
// that everyone was stuck on. See the fetch handler for the whole story.
const CACHE_NAME = 'gtec-shell-v38';

// Assets to pre-cache on install. Keep this short - fonts and Supabase
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
    '/endurance/assets/gtec-badges.js?v=13',
    '/endurance/assets/gtec-share-card.js?v=5',
    '/endurance/assets/countries.js',
    '/endurance/assets/gtec-logo.png',
    '/endurance/assets/gtec-icon.svg',
    '/endurance/assets/gtec-icon-maskable.svg',
    '/endurance/assets/icon-192.png',
    '/endurance/assets/icon-512.png',
    '/endurance/assets/icon-badge.png',
    '/endurance/assets/apple-touch-icon.png',
    '/endurance/assets/og-card.png',
    '/sparks_logo.jpg',
    '/simlab.png',
    '/logo_tm_simracing.png',
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

    // Supabase / 3rd party data must always go to the network - caching
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

    // Same-origin static assets: the cached copy at once, and a refetch in
    // the background so the next load has the current one.
    //
    // This used to be cache-first and nothing else, which meant an asset
    // replaced at the same path was served from the first version a browser
    // ever saw, for ever, until this file's cache name changed. The pages
    // themselves are network-first and so were always current, which made it
    // look like one specific feature had broken: the live map's terrain file
    // was rebuilt three times, and anyone who had loaded the first one got a
    // map with no shading, on every normal refresh, with a hard refresh
    // putting it right because that bypasses the service worker entirely.
    //
    // Stale-while-revalidate keeps the offline shell instant and heals a
    // changed asset by itself on the load after. Versioned query strings on
    // a few scripts are now belt to this file's braces rather than the only
    // thing standing between a deploy and a stale page.
    if (url.origin === location.origin) {
        event.respondWith((async () => {
            const cached = await caches.match(req);
            const network = fetch(req).then(async (fresh) => {
                if (fresh && fresh.status === 200) {
                    const cache = await caches.open(CACHE_NAME);
                    cache.put(req, fresh.clone()).catch(() => null);
                }
                return fresh;
            }).catch(() => null);

            if (cached) {
                // Keep the worker alive until the refetch finishes, or it
                // can be killed before the new copy is stored and nothing
                // ever updates.
                event.waitUntil(network);
                return cached;
            }
            return (await network) || new Response('', { status: 503 });
        })());
    }
});

/* ---------------------------------------------------------------
   Web push - split assignments, etc. Payload is JSON:
   { title, body, url }. Falls back gracefully if a push ever
   arrives without a JSON body.
------------------------------------------------------------------ */
self.addEventListener('push', (event) => {
    let data = {};
    try { data = event.data ? event.data.json() : {}; }
    catch { data = { title: 'GTEC', body: event.data ? event.data.text() : '' }; }

    const title = data.title || 'GTEC';
    const options = {
        body: data.body || '',
        icon: '/endurance/assets/icon-192.png',
        // The badge is the small monochrome status-bar mark. Android renders
        // it as a pure alpha silhouette, so it MUST be white-on-transparent.
        // Pointing it at the opaque full-colour icon made it a white square.
        badge: '/endurance/assets/icon-badge.png',
        // Show the real send time rather than "now" whenever the sender
        // stamps one.
        timestamp: data.timestamp || Date.now(),
        data: { url: data.url || '/endurance/profile/' },
    };
    // A tag lets a newer push replace an older one of the same kind instead
    // of piling up. renotify makes that replacement still alert the user.
    if (data.tag) {
        options.tag = data.tag;
        options.renotify = true;
    }
    event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
    event.notification.close();
    const url = event.notification.data && event.notification.data.url || '/endurance/profile/';
    event.waitUntil((async () => {
        const allClients = await clients.matchAll({ type: 'window', includeUncontrolled: true });
        for (const client of allClients) {
            if (client.url.includes(url) && 'focus' in client) return client.focus();
        }
        if (clients.openWindow) return clients.openWindow(url);
    })());
});
