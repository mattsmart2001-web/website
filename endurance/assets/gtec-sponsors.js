/* GTEC shared sponsor / affiliate rail.
   Self-contained: injects a fixed strip of sponsor badges down the
   right edge of every public page. Pages just include this script and
   the rail appears — no per-page markup.

   On viewports under 720px the rail collapses to a single horizontal
   row pinned to the bottom so it never crowds the mobile nav or
   content. */
(function () {
    'use strict';

    if (document.getElementById('gtec-sponsors')) return;

    const SPONSORS = [
        {
            name: 'Sim-Lab',
            href: 'https://sim-lab.eu/?ref=SPARKSTHEORY',
            img:  '/simlab.png',
            className: '',
        },
        {
            name: 'Thrustmaster',
            href: 'https://shop.thrustmaster.com/goToHomePage/?creator=SPARKSTHEORY',
            img:  '/logo_tm_simracing.png',
            className: '',
        },
        {
            name: 'YFood',
            href: 'https://bit.ly/Sparkstheory_yfood_Tasterpacks',
            img:  '/yfood_logo_black-960x264.png',
            className: 'gtec-sponsor-yfood',
        },
    ];

    // Inject CSS once.
    if (!document.getElementById('gtec-sponsors-style')) {
        const style = document.createElement('style');
        style.id = 'gtec-sponsors-style';
        style.textContent = `
            #gtec-sponsors {
                position: fixed;
                right: 1rem;
                top: 50%;
                transform: translateY(-50%);
                display: flex;
                flex-direction: column;
                gap: 0.75rem;
                z-index: 50;
                pointer-events: none;
            }
            #gtec-sponsors .gtec-sponsor {
                pointer-events: auto;
                position: relative;
                width: 56px;
                height: 56px;
                padding: 0.55rem;
                background: rgba(10, 14, 18, 0.85);
                border: 1px solid rgba(255, 209, 102, 0.28);
                border-radius: 8px;
                display: flex;
                align-items: center;
                justify-content: center;
                text-decoration: none;
                overflow: hidden;
                backdrop-filter: blur(8px);
                box-shadow: 0 4px 12px rgba(0,0,0,0.4),
                            inset 0 0 12px rgba(255,209,102,0.04);
                transition: transform 0.25s cubic-bezier(0.4,0,0.2,1),
                            border-color 0.25s ease,
                            box-shadow 0.25s ease;
            }
            #gtec-sponsors .gtec-sponsor img {
                width: 100%;
                height: 100%;
                object-fit: contain;
                filter: brightness(0.9);
                transition: filter 0.2s ease;
            }
            #gtec-sponsors .gtec-sponsor:hover {
                border-color: rgba(255,209,102,0.6);
                box-shadow: 0 0 18px rgba(255,209,102,0.25),
                            0 4px 16px rgba(0,0,0,0.5);
                transform: translateX(-4px) scale(1.06);
            }
            #gtec-sponsors .gtec-sponsor:hover img {
                filter: brightness(1.15) drop-shadow(0 0 6px rgba(255,209,102,0.35));
            }
            /* YFood logo is dark on a transparent background — invert so it
               reads against the dark badge fill. */
            #gtec-sponsors .gtec-sponsor-yfood img { filter: invert(1) brightness(0.9); }
            #gtec-sponsors .gtec-sponsor-yfood:hover img {
                filter: invert(1) brightness(1.15) drop-shadow(0 0 6px rgba(255,209,102,0.35));
            }
            /* Small "SPONSORS" eyebrow tag at the top of the rail. */
            #gtec-sponsors .gtec-sponsor-eyebrow {
                font-family: 'Orbitron', sans-serif;
                font-size: 0.5rem;
                font-weight: 700;
                letter-spacing: 0.3em;
                text-transform: uppercase;
                color: rgba(255, 209, 102, 0.6);
                writing-mode: vertical-rl;
                transform: rotate(180deg);
                margin: 0 auto 0.25rem;
                padding-right: 0.1rem;
            }

            /* On mobile pin the rail to the bottom as a slim horizontal
               strip so it never argues with the hamburger nav or the
               content. */
            @media (max-width: 720px) {
                #gtec-sponsors {
                    top: auto;
                    bottom: 0.5rem;
                    right: 50%;
                    transform: translateX(50%);
                    flex-direction: row;
                    gap: 0.5rem;
                }
                #gtec-sponsors .gtec-sponsor { width: 44px; height: 44px; padding: 0.4rem; }
                #gtec-sponsors .gtec-sponsor:hover { transform: scale(1.05); }
                #gtec-sponsors .gtec-sponsor-eyebrow { display: none; }
            }
        `;
        document.head.appendChild(style);
    }

    const rail = document.createElement('div');
    rail.id = 'gtec-sponsors';
    rail.setAttribute('aria-label', 'Sponsors');
    rail.innerHTML = `
        <div class="gtec-sponsor-eyebrow">Sponsors</div>
        ${SPONSORS.map(s => `
            <a class="gtec-sponsor ${s.className}" href="${s.href}" target="_blank" rel="noopener sponsored" title="${s.name}">
                <img src="${s.img}" alt="${s.name}" loading="lazy">
            </a>`).join('')}
    `;
    document.body.appendChild(rail);
})();
