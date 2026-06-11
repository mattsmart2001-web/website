/* GTEC Elo tier badges — shared across drivers / standings / stats / profile.
   Loaded with `defer` so it runs after each page's main script. Exposes:
       window.eloTier(rating)       → { name, short, key, min, max }
       window.eloTierBadge(rating)  → small HTML span ready to inject
       window.eloTierFull(rating)   → full-width name + Elo HTML span
   Also injects the badge styles once on first load. */
(function () {
    'use strict';

    // Highest threshold first so .find() picks the right tier on the first hit.
    const TIERS = [
        { min: 2700, max: 3000, name: 'Legend',     short: 'LEG', key: 'legend'   },
        { min: 2400, max: 2699, name: 'Master',     short: 'M',   key: 'master'   },
        { min: 2200, max: 2399, name: 'Diamond',    short: 'D',   key: 'diamond'  },
        { min: 2000, max: 2199, name: 'Sapphire',   short: 'S',   key: 'sapphire' },
        { min: 1800, max: 1999, name: 'Platinum',   short: 'P',   key: 'platinum' },
        { min: 1600, max: 1799, name: 'Gold',       short: 'G',   key: 'gold'     },
        { min: 1400, max: 1599, name: 'Silver',     short: 'S',   key: 'silver'   },
        { min: 1200, max: 1399, name: 'Bronze I',   short: 'B1',  key: 'bronze1'  },
        { min: 1000, max: 1199, name: 'Bronze II',  short: 'B2',  key: 'bronze2'  },
        { min:    0, max:  999, name: 'Bronze III', short: 'B3',  key: 'bronze3'  },
    ];

    function tierFor(rating) {
        const r = Number(rating);
        if (!Number.isFinite(r)) return null;
        return TIERS.find(t => r >= t.min) || TIERS[TIERS.length - 1];
    }

    function badge(rating) {
        const t = tierFor(rating);
        if (!t) return '';
        return `<span class="elo-tier elo-tier-${t.key}" title="${t.name} · ${t.min}–${t.max} Elo">${t.name}</span>`;
    }

    function fullChip(rating) {
        const t = tierFor(rating);
        if (!t) return '';
        return `<span class="elo-tier-chip elo-tier-${t.key}"><span class="elo-tier-name">${t.name}</span><span class="elo-tier-elo">${Math.round(rating)}</span></span>`;
    }

    window.eloTier      = tierFor;
    window.eloTierBadge = badge;
    window.eloTierFull  = fullChip;

    // Inject the shared CSS once. Tier colours roughly track the metals /
    // gemstones in the names, with white text where the background is dark
    // and dark text where the background is light.
    if (!document.getElementById('elo-tier-styles')) {
        const style = document.createElement('style');
        style.id = 'elo-tier-styles';
        style.textContent = `
            /* Parent containers (e.g. .stat-value.gold) often set their own
               text colour and text-shadow that would bleed into the badge.
               !important on the visual props keeps every tier readable
               regardless of where the badge is injected. */
            .elo-tier {
                display: inline-block;
                padding: 0.18rem 0.6rem;
                margin-left: 0.5rem;
                border-radius: 999px;
                font-family: 'Orbitron', sans-serif !important;
                font-size: 0.62rem !important;
                font-weight: 800 !important;
                letter-spacing: 0.14em !important;
                text-transform: uppercase;
                vertical-align: middle;
                line-height: 1.2;
                border: 1px solid rgba(0,0,0,0.45);
                text-shadow: none !important;
                white-space: nowrap;
            }
            .elo-tier-chip {
                display: inline-flex;
                align-items: center;
                gap: 0.5rem;
                padding: 0.25rem 0.65rem;
                border-radius: 999px;
                font-family: 'Orbitron', sans-serif !important;
                font-weight: 700;
                letter-spacing: 0.1em;
                font-size: 0.78rem;
                border: 1px solid rgba(0,0,0,0.45);
                text-shadow: none !important;
            }
            .elo-tier-chip .elo-tier-name { text-transform: uppercase; font-size: 0.65rem; }
            .elo-tier-chip .elo-tier-elo  { font-family: 'Anton', sans-serif; font-size: 1rem; letter-spacing: 0.04em; }

            .elo-tier-bronze3,  .elo-tier-chip.elo-tier-bronze3  { background: #6b4226 !important; color: #ffd9b3 !important; }
            .elo-tier-bronze2,  .elo-tier-chip.elo-tier-bronze2  { background: #8a5a2b !important; color: #ffe0b3 !important; }
            .elo-tier-bronze1,  .elo-tier-chip.elo-tier-bronze1  { background: #cd7f32 !important; color: #2a1300 !important; }
            .elo-tier-silver,   .elo-tier-chip.elo-tier-silver   { background: linear-gradient(135deg, #c0c0c0, #e6e6e6) !important; color: #1a1a1a !important; }
            .elo-tier-gold,     .elo-tier-chip.elo-tier-gold     { background: linear-gradient(135deg, #ffd700, #ffb700) !important; color: #2a1a00 !important; }
            .elo-tier-platinum, .elo-tier-chip.elo-tier-platinum { background: linear-gradient(135deg, #e5e4e2, #b0c4de) !important; color: #1a1a1a !important; }
            .elo-tier-sapphire, .elo-tier-chip.elo-tier-sapphire { background: linear-gradient(135deg, #0f52ba, #1e90ff) !important; color: #fff !important; }
            .elo-tier-diamond,  .elo-tier-chip.elo-tier-diamond  { background: linear-gradient(135deg, #b9f2ff, #5dd3ff) !important; color: #062436 !important; }
            .elo-tier-master,   .elo-tier-chip.elo-tier-master   { background: linear-gradient(135deg, #ff4500, #ff6f00) !important; color: #fff !important; }
            .elo-tier-legend,   .elo-tier-chip.elo-tier-legend   { background: linear-gradient(135deg, #ff0080, #8b00ff) !important; color: #fff !important; box-shadow: 0 0 12px rgba(255,0,128,0.4); }
        `;
        document.head.appendChild(style);
    }
})();
