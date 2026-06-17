/* GTEC career badges — shared helper used on the public driver profile
   and the My Profile portal. Self-contained CSS injection + render
   helpers. No schema changes; everything derives from a driver's
   lifetime race count. */
(function () {
    'use strict';

    // Threshold ladder. Highest threshold first so earnedCareer() can
    // pick the top-most badge a driver has unlocked.
    const CAREER_BADGES = [
        { key: 'living_legend',  name: 'Living Legend',         icon: '👑', threshold: 100, blurb: 'Complete 100 races' },
        { key: 'ironman',        name: 'Ironman',               icon: '🛡️', threshold:  50, blurb: 'Complete 50 races'  },
        { key: 'endurance_spec', name: 'Endurance Specialist',  icon: '⏱️', threshold:  20, blurb: 'Complete 20 races'  },
        { key: 'veteran',        name: 'Veteran',               icon: '🪖', threshold:  10, blurb: 'Complete 10 races'  },
        { key: 'regular',        name: 'Regular',               icon: '🎫', threshold:   5, blurb: 'Complete 5 races'   },
        { key: 'debut',          name: 'Debut',                 icon: '🏁', threshold:   1, blurb: 'Complete first race'},
    ];

    function earnedCareer(starts) {
        const n = Number(starts) || 0;
        // Lowest threshold first for display order (Debut → Living Legend).
        return CAREER_BADGES
            .filter(b => n >= b.threshold)
            .slice()
            .reverse();
    }

    function nextCareer(starts) {
        const n = Number(starts) || 0;
        // Find the lowest threshold the driver hasn't hit yet.
        const remaining = CAREER_BADGES
            .filter(b => n < b.threshold)
            .sort((a, b) => a.threshold - b.threshold);
        return remaining[0] || null;
    }

    function badgeIcon(b, opts = {}) {
        const locked   = !!opts.locked;
        const progress = opts.progress;  // 0..1 ring fill on locked badges
        const cls      = 'gtec-badge' + (locked ? ' gtec-badge-locked' : '');
        const title    = locked
            ? `${b.name} — ${b.blurb}${progress != null ? ` · ${Math.round(progress * 100)}%` : ''}`
            : `${b.name} — ${b.blurb}`;
        const ring = locked && progress != null && progress > 0
            ? `<span class="gtec-badge-progress" style="--p:${(progress * 100).toFixed(1)}"></span>`
            : '';
        return `
            <div class="${cls}" title="${title}">
                ${ring}
                <span class="gtec-badge-icon" aria-hidden="true">${b.icon}</span>
                ${locked ? '<span class="gtec-badge-lock">🔒</span>' : ''}
                <span class="gtec-badge-label">${b.name}</span>
            </div>`;
    }

    // Public-style strip — only earned badges, compact horizontal scroll.
    function renderBadgeStrip(starts) {
        const earned = earnedCareer(starts);
        if (!earned.length) return '';
        return `<div class="gtec-badge-strip">${earned.map(b => badgeIcon(b)).join('')}</div>`;
    }

    // Portal-style grid — every badge with locked ones greyed out + a
    // "next badge" progress hint underneath.
    function renderBadgeGrid(starts) {
        const n = Number(starts) || 0;
        // Show in difficulty order Debut → Living Legend.
        const ordered = CAREER_BADGES.slice().reverse();
        const next = nextCareer(n);
        const cards = ordered.map(b => {
            const locked = n < b.threshold;
            if (!locked) return badgeIcon(b);
            const prev = b.threshold === 1 ? 0
                : CAREER_BADGES.find(x => x.threshold < b.threshold).threshold;
            const range = b.threshold - prev;
            const intoRange = Math.max(0, n - prev);
            const progress = Math.max(0, Math.min(1, intoRange / range));
            return badgeIcon(b, { locked: true, progress });
        }).join('');

        const nextLine = next
            ? `<div class="gtec-badge-next">🏁 <strong>${n} / ${next.threshold}</strong> races to <strong>${next.name}</strong></div>`
            : `<div class="gtec-badge-next">All career badges earned. Living the dream.</div>`;

        return `
            <div class="gtec-badge-grid">${cards}</div>
            ${nextLine}`;
    }

    // Inject CSS once. Tier badges everywhere else already use Orbitron;
    // we match that for monogram + label.
    if (!document.getElementById('gtec-badge-styles')) {
        const style = document.createElement('style');
        style.id = 'gtec-badge-styles';
        style.textContent = `
            .gtec-badge-strip {
                display: flex;
                flex-wrap: wrap;
                gap: 0.55rem;
                margin: 0.85rem 0 0.5rem;
            }
            .gtec-badge-grid {
                display: grid;
                grid-template-columns: repeat(auto-fill, minmax(110px, 1fr));
                gap: 0.85rem 0.65rem;
                margin: 1rem 0 0.4rem;
            }
            .gtec-badge {
                position: relative;
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 0.35rem;
                padding: 0.6rem 0.45rem 0.5rem;
                background: linear-gradient(160deg, rgba(255,209,102,0.14), rgba(255,209,102,0.04));
                border: 1px solid rgba(255,209,102,0.4);
                border-radius: 10px;
                min-width: 84px;
                transition: transform 0.15s ease, box-shadow 0.15s ease;
            }
            .gtec-badge:hover { transform: translateY(-2px); box-shadow: 0 6px 20px rgba(255,209,102,0.18); }
            .gtec-badge-locked {
                background: linear-gradient(160deg, rgba(255,255,255,0.04), rgba(255,255,255,0.02));
                border-color: rgba(255,255,255,0.1);
                opacity: 0.75;
            }
            .gtec-badge-locked .gtec-badge-label { color: rgba(148,163,184,0.55); }
            .gtec-badge-locked:hover { transform: none; box-shadow: none; }

            .gtec-badge-icon {
                font-size: 1.5rem;
                line-height: 1;
                width: 46px; height: 46px;
                display: flex; align-items: center; justify-content: center;
                border-radius: 50%;
                background: radial-gradient(circle at 30% 25%, rgba(255,255,255,0.25), rgba(0,0,0,0.5) 75%);
                border: 2px solid rgba(255,209,102,0.55);
                box-shadow: inset 0 0 12px rgba(255,209,102,0.18);
                /* Stop emoji baseline drift across systems */
                font-family: 'Apple Color Emoji', 'Segoe UI Emoji', 'Noto Color Emoji', sans-serif;
            }
            .gtec-badge-locked .gtec-badge-icon {
                background: radial-gradient(circle at 30% 25%, rgba(255,255,255,0.05), rgba(0,0,0,0.4) 75%);
                border-color: rgba(255,255,255,0.15);
                box-shadow: none;
                filter: grayscale(1) brightness(0.65);
            }
            .gtec-badge-label {
                font-family: 'Orbitron', sans-serif;
                font-size: 0.55rem;
                font-weight: 700;
                letter-spacing: 0.18em;
                text-transform: uppercase;
                color: var(--gold, #ffd166);
                text-align: center;
                line-height: 1.2;
            }
            .gtec-badge-lock {
                position: absolute;
                top: 0.35rem; right: 0.4rem;
                font-size: 0.65rem;
                opacity: 0.6;
            }
            /* Conic progress ring on locked badges showing how close they
               are to unlocking it. --p comes from inline style. */
            .gtec-badge-progress {
                position: absolute;
                top: 0.4rem; left: 50%;
                transform: translateX(-50%);
                width: 50px; height: 50px;
                border-radius: 50%;
                background: conic-gradient(rgba(255,209,102,0.55) calc(var(--p) * 1%), transparent 0);
                mask: radial-gradient(transparent 21px, #000 22px, #000 24px, transparent 25px);
                -webkit-mask: radial-gradient(transparent 21px, #000 22px, #000 24px, transparent 25px);
                pointer-events: none;
            }
            .gtec-badge-next {
                font-family: 'Orbitron', sans-serif;
                font-size: 0.7rem;
                letter-spacing: 0.15em;
                text-transform: uppercase;
                color: rgba(148,163,184,0.75);
                margin-top: 0.85rem;
                text-align: center;
            }
            .gtec-badge-next strong { color: var(--gold, #ffd166); font-weight: 700; }
        `;
        document.head.appendChild(style);
    }

    window.CAREER_BADGES    = CAREER_BADGES;
    window.earnedCareer     = earnedCareer;
    window.nextCareer       = nextCareer;
    window.renderBadgeStrip = renderBadgeStrip;
    window.renderBadgeGrid  = renderBadgeGrid;
})();
