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
        { min: 2800, max: 3000, name: 'Legend',       short: 'LEG', key: 'legend'      },
        { min: 2600, max: 2799, name: 'Hall of Fame', short: 'HOF', key: 'hall_of_fame'},
        { min: 2400, max: 2599, name: 'Champion',     short: 'C',   key: 'champion'    },
        { min: 2200, max: 2399, name: 'Master',       short: 'M',   key: 'master'      },
        { min: 2000, max: 2199, name: 'Elite',        short: 'E',   key: 'elite'       },
        { min: 1800, max: 1999, name: 'Diamond',      short: 'D',   key: 'diamond'     },
        { min: 1600, max: 1799, name: 'Platinum',     short: 'P',   key: 'platinum'    },
        { min: 1400, max: 1599, name: 'Gold',         short: 'G',   key: 'gold'        },
        { min: 1200, max: 1399, name: 'Silver',       short: 'S',   key: 'silver'      },
        { min:    0, max: 1199, name: 'Bronze',       short: 'B',   key: 'bronze'      },
    ];

    function tierFor(rating) {
        const r = Number(rating);
        if (!Number.isFinite(r)) return null;
        return TIERS.find(t => r >= t.min) || TIERS[TIERS.length - 1];
    }

    // DR / SR seed for drivers who haven't earned an Elo from races yet.
    // Same numbers admin uses for pre-season lobby allocation so the badge
    // on the public site reflects the same skill order.
    const DR_TO_ELO   = { 'E': 800, 'D': 1100, 'C': 1300, 'B': 1500, 'A': 1700, 'A+': 1850, 'S': 2000 };
    const SR_TO_BONUS = { 'E': -75, 'D': -45, 'C': -15, 'B': 15,  'A': 45,  'S': 75 };
    function drSrSeed(dr, sr) {
        if (!dr && !sr) return null;
        return (DR_TO_ELO[dr] ?? 1500) + (SR_TO_BONUS[sr] ?? 0);
    }
    window.eloDrSrSeed = drSrSeed;

    function badge(rating, opts = {}) {
        const t = tierFor(rating);
        if (!t) return '';
        const provisional = !!opts.provisional;
        const title = `${t.name} · ${t.min}–${t.max} ${provisional ? '(provisional — DR / SR seed)' : 'Elo'}`;
        return `<span class="elo-tier elo-tier-${t.key}${provisional ? ' elo-tier-provisional' : ''}" title="${title}">${t.name}${provisional ? ' *' : ''}</span>`;
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

            .elo-tier-bronze,       .elo-tier-chip.elo-tier-bronze       { background: linear-gradient(135deg, #cd7f32, #8a5a2b) !important; color: #2a1300 !important; }
            .elo-tier-silver,       .elo-tier-chip.elo-tier-silver       { background: linear-gradient(135deg, #c0c0c0, #e6e6e6) !important; color: #1a1a1a !important; }
            .elo-tier-gold,         .elo-tier-chip.elo-tier-gold         { background: linear-gradient(135deg, #ffd700, #ffb700) !important; color: #2a1a00 !important; }
            .elo-tier-platinum,     .elo-tier-chip.elo-tier-platinum     { background: linear-gradient(135deg, #e5e4e2, #b0c4de) !important; color: #1a1a1a !important; }
            .elo-tier-diamond,      .elo-tier-chip.elo-tier-diamond      { background: linear-gradient(135deg, #b9f2ff, #5dd3ff) !important; color: #062436 !important; }
            .elo-tier-elite,        .elo-tier-chip.elo-tier-elite        { background: linear-gradient(135deg, #10b981, #047857) !important; color: #fff !important; }
            .elo-tier-master,       .elo-tier-chip.elo-tier-master       { background: linear-gradient(135deg, #ff4500, #ff6f00) !important; color: #fff !important; }
            .elo-tier-champion,     .elo-tier-chip.elo-tier-champion      { background: linear-gradient(135deg, #dc2626, #7f1d1d) !important; color: #fff !important; }
            .elo-tier-hall_of_fame, .elo-tier-chip.elo-tier-hall_of_fame { background: linear-gradient(135deg, #8b5cf6, #4c1d95) !important; color: #fff !important; box-shadow: 0 0 10px rgba(139,92,246,0.35); }
            .elo-tier-legend,       .elo-tier-chip.elo-tier-legend       { background: linear-gradient(135deg, #ff0080, #8b00ff) !important; color: #fff !important; box-shadow: 0 0 12px rgba(255,0,128,0.4); }
            /* Provisional pills (DR/SR seed before any race history) get a
               subtle dashed border so they read as "estimated, not earned". */
            .elo-tier-provisional { border-style: dashed !important; border-color: rgba(255,255,255,0.55) !important; opacity: 0.92; }
        `;
        document.head.appendChild(style);
    }
})();
