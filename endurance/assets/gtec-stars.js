/* GTEC shared starfield — drifting golden specks behind every public page.
   Self-contained: appends its own <canvas>, injects the styles it needs,
   and starts animating on first load. Pages just include this script.

   The element is positioned fixed/inset:0 with z-index:0 and pointer-events:
   none so it never interferes with normal content layout or clicks. */
(function () {
    'use strict';

    // Some pages (notably /endurance/) already render their own starfield
    // inline — don't double up.
    if (document.getElementById('gtec-stars')) return;

    // Inject CSS once.
    if (!document.getElementById('gtec-stars-style')) {
        const style = document.createElement('style');
        style.id = 'gtec-stars-style';
        style.textContent = `
            #gtec-stars {
                position: fixed;
                inset: 0;
                /* -1 keeps the canvas behind body content on pages that
                   don't already set z-index on their own containers
                   (the homepage does and uses z-index:0 there). */
                z-index: -1;
                pointer-events: none;
            }
        `;
        document.head.appendChild(style);
    }

    const canvas = document.createElement('canvas');
    canvas.id = 'gtec-stars';
    // Prepend so it sits behind everything in the body without rewriting
    // page-specific layouts.
    document.body.insertBefore(canvas, document.body.firstChild);

    const ctx = canvas.getContext('2d');
    let stars = [];

    function resize() {
        canvas.width  = window.innerWidth;
        canvas.height = window.innerHeight;
    }

    function init() {
        resize();
        stars = Array.from({ length: 180 }, () => ({
            x: Math.random() * canvas.width,
            y: Math.random() * canvas.height,
            r: Math.random() * 1.2 + 0.2,
            a: Math.random() * 0.55 + 0.1,
            speed: Math.random() * 0.3 + 0.05,
            drift: (Math.random() - 0.5) * 0.08,
        }));
    }

    function draw() {
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        for (const s of stars) {
            ctx.beginPath();
            ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
            ctx.fillStyle = `rgba(255,220,120,${s.a})`;
            ctx.fill();
            s.y += s.speed;
            s.x += s.drift;
            if (s.y > canvas.height) { s.y = 0; s.x = Math.random() * canvas.width; }
            if (s.x < 0 || s.x > canvas.width) { s.x = Math.random() * canvas.width; }
        }
        requestAnimationFrame(draw);
    }

    window.addEventListener('resize', resize);
    init();
    draw();
})();
