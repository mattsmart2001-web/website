/* GTEC career + victory badges — shared helper used on the public
   driver profile and the My Profile portal. Categories are defined
   below; both renderers take a single { starts, wins } stats object
   and the helper figures out who's earned what. */
(function () {
    'use strict';

    // Tier ladders. Highest threshold first so earnedFor() can pick
    // the top-most badge a driver has unlocked within a category.
    const CATEGORIES = [
        {
            key: 'career',
            title: 'Career',
            stat: 'starts',
            statLabel: 'races',
            badges: [
                { key: 'living_legend',  name: 'Living Legend',         icon: '👑', threshold: 100, blurb: 'Complete 100 races' },
                { key: 'ironman',        name: 'Ironman',               icon: '🛡️', threshold:  50, blurb: 'Complete 50 races'  },
                { key: 'endurance_spec', name: 'Endurance Specialist',  icon: '⏱️', threshold:  20, blurb: 'Complete 20 races'  },
                { key: 'veteran',        name: 'Veteran',               icon: '🪖', threshold:  10, blurb: 'Complete 10 races'  },
                { key: 'regular',        name: 'Regular',               icon: '🎫', threshold:   5, blurb: 'Complete 5 races'   },
                { key: 'debut',          name: 'Debut',                 icon: '🏁', threshold:   1, blurb: 'Complete first race'},
            ],
        },
        {
            key: 'victories',
            title: 'Victories',
            stat: 'wins',
            statLabel: 'wins',
            badges: [
                { key: 'legend_of_gtec', name: 'Legend of GTEC', icon: '🌟', threshold: 50, blurb: 'Win 50 races' },
                { key: 'dominator',      name: 'Dominator',      icon: '🔥', threshold: 25, blurb: 'Win 25 races' },
                { key: 'elite_winner',   name: 'Elite Winner',   icon: '💎', threshold: 10, blurb: 'Win 10 races' },
                { key: 'proven_winner',  name: 'Proven Winner',  icon: '🏆', threshold:  5, blurb: 'Win 5 races'  },
                { key: 'race_winner',    name: 'Race Winner',    icon: '🥇', threshold:  3, blurb: 'Win 3 races'  },
                { key: 'first_victory',  name: 'First Victory',  icon: '🎉', threshold:  1, blurb: 'Win your first race' },
            ],
        },
    ];

    function earnedFor(cat, value) {
        const n = Number(value) || 0;
        return cat.badges
            .filter(b => n >= b.threshold)
            .slice()
            .reverse(); // ascending difficulty for display
    }

    function nextFor(cat, value) {
        const n = Number(value) || 0;
        const remaining = cat.badges
            .filter(b => n < b.threshold)
            .sort((a, b) => a.threshold - b.threshold);
        return remaining[0] || null;
    }

    function badgeIcon(b, opts = {}) {
        const locked   = !!opts.locked;
        const progress = opts.progress;
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

    // Public-style strip — every earned badge across every category,
    // grouped by category for readability. Nothing rendered for drivers
    // with no earned badges in any category.
    function renderBadgeStrip(stats) {
        stats = stats || {};
        const sections = CATEGORIES.map(cat => {
            const earned = earnedFor(cat, stats[cat.stat]);
            if (!earned.length) return '';
            return earned.map(b => badgeIcon(b)).join('');
        }).filter(Boolean);
        if (!sections.length) return '';
        return `<div class="gtec-badge-strip">${sections.join('')}</div>`;
    }

    // Portal-style full grid — every category, every badge, with locked
    // ones desaturated + a conic progress ring filling 0 → 100% as the
    // driver approaches the threshold. Each category gets its own
    // sub-heading and a "X / Y to NEXT" footer line.
    function renderBadgeGrid(stats) {
        stats = stats || {};
        return CATEGORIES.map(cat => {
            const n = Number(stats[cat.stat]) || 0;
            const ordered = cat.badges.slice().reverse(); // Debut → Legend, easiest first
            const cards = ordered.map(b => {
                const locked = n < b.threshold;
                if (!locked) return badgeIcon(b);
                const prev = b.threshold === ordered[0].threshold ? 0
                    : cat.badges.find(x => x.threshold < b.threshold).threshold;
                const range = b.threshold - prev;
                const intoRange = Math.max(0, n - prev);
                const progress = Math.max(0, Math.min(1, intoRange / range));
                return badgeIcon(b, { locked: true, progress });
            }).join('');

            const next = nextFor(cat, n);
            const footer = next
                ? `<div class="gtec-badge-next">🏁 <strong>${n} / ${next.threshold}</strong> ${cat.statLabel} to <strong>${next.name}</strong></div>`
                : `<div class="gtec-badge-next">Every ${cat.title.toLowerCase()} badge earned.</div>`;

            return `
                <div class="gtec-badge-section">
                    <div class="gtec-badge-section-title">${cat.title}</div>
                    <div class="gtec-badge-grid">${cards}</div>
                    ${footer}
                </div>`;
        }).join('');
    }

    // Inject CSS once.
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
            .gtec-badge-section + .gtec-badge-section { margin-top: 1.5rem; }
            .gtec-badge-section-title {
                font-family: 'Orbitron', sans-serif;
                font-size: 0.62rem;
                font-weight: 700;
                letter-spacing: 0.3em;
                text-transform: uppercase;
                color: var(--gold, #ffd166);
                margin-bottom: 0.5rem;
            }
            .gtec-badge-grid {
                display: grid;
                grid-template-columns: repeat(auto-fill, minmax(110px, 1fr));
                gap: 0.85rem 0.65rem;
                margin: 0.25rem 0 0.4rem;
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

    window.BADGE_CATEGORIES = CATEGORIES;
    window.renderBadgeStrip = renderBadgeStrip;
    window.renderBadgeGrid  = renderBadgeGrid;
})();
