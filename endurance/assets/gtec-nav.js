/* GTEC shared nav — hamburger toggle.
   Loaded with `defer` so it runs after parsing. */
(function () {
    'use strict';

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
})();
