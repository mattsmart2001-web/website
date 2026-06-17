/* GTEC shared nav — hamburger toggle + unread-message badge.
   Loaded with `defer` so it runs after parsing and after the page's own
   supabase + gtec-config <script> tags have executed. */
(function () {
    'use strict';

    /* -----------------------------------------------------------------
       PWA service worker registration. Scope is /endurance/ so the
       worker only ever controls GTEC routes — never the main site.
       Soft-fails on unsupported browsers / dev environments without
       making any noise.
    ------------------------------------------------------------------ */
    if ('serviceWorker' in navigator && location.protocol === 'https:') {
        window.addEventListener('load', () => {
            navigator.serviceWorker.register('/endurance/sw.js', { scope: '/endurance/' })
                .catch(() => {/* ignore */});
        });
    }

    document.addEventListener('click', function (e) {
        // Toggle drawer
        if (e.target.closest('.gtec-nav-toggle')) {
            document.body.classList.toggle('nav-open');
            return;
        }
        // Close drawer when tapping a nav link
        if (e.target.closest('nav.gtec-nav .nav-links a, nav.gtec-nav .nav-links button')) {
            document.body.classList.remove('nav-open');
            return;
        }
        // Close when tapping outside the nav (covers the rest of the page)
        if (document.body.classList.contains('nav-open') && !e.target.closest('nav.gtec-nav')) {
            document.body.classList.remove('nav-open');
        }
    });

    // Close on Esc
    document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') document.body.classList.remove('nav-open');
    });

    // Close on resize back to desktop
    window.addEventListener('resize', function () {
        if (window.innerWidth > 720) document.body.classList.remove('nav-open');
    });

    /* -----------------------------------------------------------------
       Unread-inbox badge next to "My Profile".
       Counts driver_contact_messages rows where the driver has a fresh
       admin reply or broadcast they haven't opened yet, then subscribes
       to realtime so the badge updates without a page refresh.
    ------------------------------------------------------------------ */
    const badge  = document.getElementById('nav-portal-badge');
    if (!badge) return;
    if (!window.supabase || !window.GTEC_CONFIG) return;

    const sb = window.supabase.createClient(window.GTEC_CONFIG.supabaseUrl, window.GTEC_CONFIG.supabaseAnonKey);

    const setBadge = (n) => {
        if (n > 0) { badge.textContent = n > 99 ? '99+' : String(n); badge.classList.add('show'); }
        else       { badge.classList.remove('show'); badge.textContent = ''; }
    };

    const recount = async (driverId) => {
        // Unread = admin sent something AND the driver hasn't opened it yet.
        // Matches the profile inbox's own "unread" rule so the badge clears
        // the next time the user opens the inbox card.
        const { data } = await sb.from('driver_contact_messages')
            .select('id, is_broadcast, is_direct, admin_reply, driver_read_reply_at')
            .eq('driver_id', driverId)
            .is('driver_read_reply_at', null);
        const n = (data || []).filter(m => m.is_broadcast || m.is_direct || m.admin_reply).length;
        setBadge(n);
    };

    (async () => {
        const { data: { session } } = await sb.auth.getSession();
        if (!session) return;

        const { data: driver } = await sb.from('drivers')
            .select('id').eq('user_id', session.user.id).maybeSingle();
        if (!driver) return;

        await recount(driver.id);

        // Realtime: any insert / update on this driver's messages re-counts.
        // Driver opening the inbox flips driver_read_reply_at and triggers
        // an UPDATE event, so the badge clears without refresh either.
        sb.channel('nav-badge-' + driver.id)
            .on('postgres_changes', {
                event: '*', schema: 'public', table: 'driver_contact_messages',
                filter: `driver_id=eq.${driver.id}`,
            }, () => recount(driver.id))
            .subscribe();
    })();
})();
