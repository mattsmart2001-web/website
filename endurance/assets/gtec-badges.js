/* GTEC career / victory / circuit badges — shared helper used on the
   public driver profile and the My Profile portal. Categories are
   defined below; both renderers take a single
       { starts, wins, completedCircuits }
   stats object and the helper figures out who's earned what. */
(function () {
    'use strict';

    // Tier ladders. Highest threshold first so earnedFor() can pick
    // the top-most badge a driver has unlocked within a threshold-style
    // category. Circuit badges use type:'match' instead.
    const CATEGORIES = [
        {
            key: 'career',
            title: 'Career',
            type: 'threshold',
            stat: 'starts',
            statLabel: 'races',
            badges: [
                { key: 'living_legend',  name: 'Living Legend',         icon: '/endurance/assets/badges/living_legend.png',  threshold: 100, blurb: 'Complete 100 races' },
                { key: 'ironman',        name: 'Ironman',               icon: '/endurance/assets/badges/ironman.png',        threshold:  50, blurb: 'Complete 50 races'  },
                { key: 'endurance_spec', name: 'Endurance Specialist',  icon: '/endurance/assets/badges/endurance_spec.png', threshold:  20, blurb: 'Complete 20 races'  },
                { key: 'veteran',        name: 'Veteran',               icon: '/endurance/assets/badges/veteran.png',        threshold:  10, blurb: 'Complete 10 races'  },
                { key: 'regular',        name: 'Regular',               icon: '/endurance/assets/badges/regular.png',        threshold:   5, blurb: 'Complete 5 races'   },
                { key: 'debut',          name: 'Debut',                 icon: '/endurance/assets/badges/debut.png',          threshold:   1, blurb: 'Complete first race'},
            ],
        },
        {
            key: 'victories',
            title: 'Victories',
            type: 'threshold',
            stat: 'wins',
            statLabel: 'wins',
            badges: [
                { key: 'legend_of_gtec', name: 'Legend of GTEC', icon: '/endurance/assets/badges/legend_of_gtec.png', threshold: 50, blurb: 'Win 50 races' },
                { key: 'dominator',      name: 'Dominator',      icon: '/endurance/assets/badges/dominator.png',     threshold: 25, blurb: 'Win 25 races' },
                { key: 'elite_winner',   name: 'Elite Winner',   icon: '/endurance/assets/badges/elite_winner.png',  threshold: 10, blurb: 'Win 10 races' },
                { key: 'proven_winner',  name: 'Proven Winner',  icon: '/endurance/assets/badges/proven_winner.png', threshold:  5, blurb: 'Win 5 races'  },
                { key: 'race_winner',    name: 'Race Winner',    icon: '/endurance/assets/badges/race_winner.png',   threshold:  3, blurb: 'Win 3 races'  },
                { key: 'first_victory',  name: 'First Victory',  icon: '/endurance/assets/badges/first_victory.png', threshold:  1, blurb: 'Win your first race' },
            ],
        },
        {
            key: 'circuits',
            title: 'Circuits',
            type: 'match',
            stat: 'completedCircuits',  // array of lowercased circuit name strings
            // Each matcher is a case-insensitive substring tested against
            // every circuit the driver has classified-finished. First hit
            // unlocks the badge. Easy to extend — add a row, the public
            // strip + portal grid both pick it up automatically.
            badges: [
                { key: 'spa',          name: 'Spa Survivor',         icon: '/endurance/assets/badges/spa.png',         blurb: 'Complete a race at Spa-Francorchamps',         matchers: ['spa', 'francorchamp'] },
                { key: 'monza',        name: 'Temple Visitor',       icon: '/endurance/assets/badges/monza.png',       blurb: 'Complete a race at Monza',                       matchers: ['monza'] },
                { key: 'suzuka',       name: 'Suzuka Graduate',      icon: '/endurance/assets/badges/suzuka.png',      blurb: 'Complete a race at Suzuka',                      matchers: ['suzuka'] },
                { key: 'bathurst',     name: 'Mountain Survivor',    icon: '/endurance/assets/badges/bathurst.png',    blurb: 'Complete a race at Mount Panorama / Bathurst',   matchers: ['bathurst', 'mount panorama', 'panorama'] },
                { key: 'daytona',      name: 'Daytona Survivor',     icon: '/endurance/assets/badges/daytona.png',     blurb: 'Complete a race at Daytona',                     matchers: ['daytona'] },
                { key: 'interlagos',   name: 'Interlagos Survivor',  icon: '/endurance/assets/badges/interlagos.png',  blurb: 'Complete a race at Interlagos',                  matchers: ['interlagos'] },
                { key: 'nurburgring',  name: 'Green Hell Survivor',  icon: '/endurance/assets/badges/nurburgring.png', blurb: 'Complete a race at the Nürburgring Nordschleife', matchers: ['nürburgring', 'nurburgring', 'nordschleife', 'nords'] },
                { key: 'le_mans',      name: 'Le Mans Finisher',     icon: '/endurance/assets/badges/le_mans.png',     blurb: 'Complete a race at Circuit de la Sarthe / Le Mans', matchers: ['le mans', 'sarthe'] },
                // Capstone. Auto-unlocks the moment every other badge in
                // this category is earned, so it doesn't need its own
                // matchers — badgeIsEarned() resolves it dynamically.
                { key: 'grand_tour',   name: 'Grand Tour',           icon: '/endurance/assets/badges/grand_tour.png',  blurb: 'Complete every event on the calendar',           requiresAll: true },
            ],
        },
        {
            key: 'titles',
            title: 'Titles',
            type: 'season',
            // Each badge is earned via its own evalFn — gives us count-
            // based "Win 2 championships" without bolting on yet another
            // category-type. stats.seasonFinishes is an array of finish
            // positions (1..N) across *completed* seasons only.
            badges: [
                { key: 'dynasty',          name: 'Dynasty',                 icon: '/endurance/assets/badges/dynasty.png',         blurb: 'Win 3 championships',
                  evalFn: s => (s.seasonFinishes || []).filter(p => p === 1).length >= 3 },
                { key: 'double_champion',  name: 'Double Champion',         icon: '/endurance/assets/badges/double_champion.png', blurb: 'Win 2 championships',
                  evalFn: s => (s.seasonFinishes || []).filter(p => p === 1).length >= 2 },
                { key: 'season_champion',  name: 'Season Champion',         icon: '/endurance/assets/badges/season_champion.png', blurb: 'Win a championship',
                  evalFn: s => (s.seasonFinishes || []).some(p => p === 1) },
                { key: 'vice_champion',    name: 'Vice Champion',           icon: '/endurance/assets/badges/vice_champion.png',   blurb: 'Finish P2 in a season',
                  evalFn: s => (s.seasonFinishes || []).some(p => p === 2) },
                { key: 'challenger',       name: 'Championship Challenger', icon: '/endurance/assets/badges/challenger.png',      blurb: 'Finish top 5 in a season',
                  evalFn: s => (s.seasonFinishes || []).some(p => p >= 1 && p <= 5) },
                { key: 'contender',        name: 'Championship Contender',  icon: '/endurance/assets/badges/contender.png',       blurb: 'Finish top 10 in a season',
                  evalFn: s => (s.seasonFinishes || []).some(p => p >= 1 && p <= 10) },
            ],
        },
        {
            key: 'secrets',
            title: 'Secrets',
            type: 'secret',
            // Hidden badges — locked tiles render as a "?" with no name
            // / blurb so drivers don't know what's possible until they
            // unlock one. evalFn pulls from stats.secretBadges, populated
            // by the driver_secret_badges RPC (mig 61).
            badges: [
                { key: 'giant_killer',     name: 'Giant Killer',     icon: '/endurance/assets/badges/giant_killer.png',     blurb: 'Beat a driver 300+ Elo above you',
                  evalFn: s => !!(s.secretBadges || {}).giant_killer },
                { key: 'david_vs_goliath', name: 'David vs Goliath', icon: '/endurance/assets/badges/david_vs_goliath.png', blurb: 'Win a race as the lowest-rated driver in your split',
                  evalFn: s => !!(s.secretBadges || {}).david_vs_goliath },
                { key: 'giant_slayer',        name: 'Giant Slayer',        icon: '/endurance/assets/badges/giant_slayer.png',        blurb: 'Beat the championship leader in a race',
                  evalFn: s => !!(s.secretBadges || {}).giant_slayer },
                { key: 'unfinished_business', name: 'Unfinished Business', icon: '/endurance/assets/badges/unfinished_business.png', blurb: 'Beat a driver who finished ahead of you in the previous round',
                  evalFn: s => !!(s.secretBadges || {}).unfinished_business },
                { key: 'phoenix',             name: 'Phoenix',             icon: '/endurance/assets/badges/phoenix.png',             blurb: 'Lose 1000 Elo, then climb all the way back',
                  evalFn: s => !!(s.secretBadges || {}).phoenix },
                { key: 'comeback_king',       name: 'Comeback King',       icon: '/endurance/assets/badges/comeback_king.png',       blurb: 'Gain 10 or more positions in a single race',
                  evalFn: s => !!(s.secretBadges || {}).comeback_king },
                { key: 'last_to_first',       name: 'Last to First',       icon: '/endurance/assets/badges/last_to_first.png',       blurb: 'Start dead last in your split and win the race',
                  evalFn: s => !!(s.secretBadges || {}).last_to_first },
                { key: 'mr_consistent',       name: 'Mr Consistent',       icon: '/endurance/assets/badges/mr_consistent.png',       blurb: 'Finish top 10 in 5 consecutive races',
                  evalFn: s => !!(s.secretBadges || {}).mr_consistent },
                { key: 'ghost',               name: 'Ghost',               icon: '/endurance/assets/badges/ghost.png',               blurb: 'Consistently absent from the grid',
                  evalFn: s => !!(s.secretBadges || {}).ghost },
            ],
        },
        {
            key: 'community',
            title: 'Community',
            type: 'threshold',
            stat: 'hostCount',
            statLabel: 'splits hosted',
            badges: [
                { key: 'host_legend',  name: 'Host Legend',  icon: '🏅', threshold: 15, blurb: 'Hosted 15 splits' },
                { key: 'trusted_host', name: 'Trusted Host', icon: '🎖️', threshold:  5, blurb: 'Hosted 5 splits'  },
                { key: 'lobby_host',   name: 'Lobby Host',   icon: '/endurance/assets/badges/lobby_host.png', threshold: 1, blurb: 'Hosted your first split' },
            ],
        },
    ];

    function badgeIsEarned(cat, badge, stats) {
        // Admin override — manual_badges on the driver row is a text[]
        // of badge keys an organiser has granted by hand to paper over
        // missed results / data-entry mishaps. Trumps every other rule.
        const manual = Array.isArray(stats.manualBadges) ? stats.manualBadges : [];
        if (manual.includes(badge.key)) return true;
        // Generic per-badge evaluator — used by Titles and ready for any
        // future "this is too bespoke for the threshold/match shape" badge.
        if (typeof badge.evalFn === 'function') {
            try { return !!badge.evalFn(stats); } catch (_) { return false; }
        }
        if (cat.type === 'threshold') {
            return (Number(stats[cat.stat]) || 0) >= badge.threshold;
        }
        if (cat.type === 'match') {
            // Capstone: earned when every other badge in the category is
            // earned. Lets us add a "complete-the-set" trophy without
            // hard-wiring which badges count toward it.
            if (badge.requiresAll) {
                return cat.badges
                    .filter(b => b.key !== badge.key)
                    .every(b => badgeIsEarned(cat, b, stats));
            }
            const completed = Array.isArray(stats[cat.stat]) ? stats[cat.stat] : [];
            if (!completed.length) return false;
            return (badge.matchers || []).some(m =>
                completed.some(c => c.toLowerCase().includes(m.toLowerCase()))
            );
        }
        return false;
    }

    // Returns the badges from `cat` that the driver has earned, in
    // ascending difficulty order for threshold ladders and in the
    // declaration order for match-style sets.
    function earnedFor(cat, stats) {
        // Use badgeIsEarned for every category so admin manual_badges
        // unlocks ripple into the public strip too.
        return cat.badges.filter(b => badgeIsEarned(cat, b, stats)).slice().reverse();
    }

    // For threshold ladders, returns the next unlock + how far away.
    // For match-style sets there's no ladder so returns null.
    function nextThreshold(cat, value) {
        if (cat.type !== 'threshold') return null;
        const n = Number(value) || 0;
        const remaining = cat.badges
            .filter(b => n < b.threshold)
            .sort((a, b) => a.threshold - b.threshold);
        return remaining[0] || null;
    }

    // Badge art can be a plain emoji string ("👑") or a path/URL to a PNG —
    // anything containing a "/" is treated as an image so badges can be
    // swapped from emoji to custom artwork one at a time, no data migration.
    function isImageIcon(icon) {
        return !!icon && icon.indexOf('/') !== -1;
    }

    function iconMarkup(icon) {
        return isImageIcon(icon) ? `<img src="${icon}" alt="" loading="lazy">` : icon;
    }

    function badgeIcon(b, opts = {}) {
        const locked   = !!opts.locked;
        const secret   = !!opts.secret;
        const progress = opts.progress;
        // Hidden tile — drivers see "?" with no name, no blurb, no
        // hover hint, until they unlock it.
        if (locked && secret) {
            return `
                <div class="gtec-badge gtec-badge-locked gtec-badge-secret" title="Hidden badge">
                    <span class="gtec-badge-icon" aria-hidden="true">?</span>
                    <span class="gtec-badge-lock">🔒</span>
                    <span class="gtec-badge-label">Hidden</span>
                </div>`;
        }
        // Custom artwork already comes with its own border/shading baked in,
        // so the circular ring + card chrome built for bare emoji would just
        // double up on it — drop both and let the art sit on its own.
        const artwork  = isImageIcon(b.icon);
        const cls      = 'gtec-badge' + (locked ? ' gtec-badge-locked' : '') + (artwork ? ' gtec-badge-artwork' : '');
        const iconCls  = 'gtec-badge-icon' + (artwork ? ' gtec-badge-artwork' : '');
        const title    = locked
            ? `${b.name} — ${b.blurb}${progress != null ? ` · ${Math.round(progress * 100)}%` : ''}`
            : `${b.name} — ${b.blurb}`;
        const ring = locked && progress != null && progress > 0
            ? `<span class="gtec-badge-progress" style="--p:${(progress * 100).toFixed(1)}"></span>`
            : '';
        return `
            <div class="${cls}" title="${title}">
                ${ring}
                <span class="${iconCls}" aria-hidden="true">${iconMarkup(b.icon)}</span>
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
            const earned = earnedFor(cat, stats);
            if (!earned.length) return '';
            return earned.map(b => badgeIcon(b)).join('');
        }).filter(Boolean);
        if (!sections.length) return '';
        return `<div class="gtec-badge-strip">${sections.join('')}</div>`;
    }

    // Role badges — only show when earned; no locked tiles (it's a role, not an aspiration).
    function renderRoleSection(cat, stats) {
        const earned = earnedFor(cat, stats);
        if (!earned.length) return '';
        return `
            <div class="gtec-badge-section">
                <div class="gtec-badge-section-title">${cat.title}</div>
                <div class="gtec-badge-grid">${earned.map(b => badgeIcon(b)).join('')}</div>
            </div>`;
    }

    // Portal-style full grid — every category, every badge, with locked
    // ones desaturated + a conic progress ring (threshold ladders only)
    // filling 0 → 100% as the driver approaches the next unlock. Each
    // category gets its own sub-heading and a footer line.
    function renderBadgeGrid(stats) {
        stats = stats || {};
        return CATEGORIES.map(cat => {
            if (cat.type === 'threshold') return renderThresholdSection(cat, stats);
            if (cat.type === 'match')     return renderMatchSection(cat, stats);
            if (cat.type === 'season')    return renderSeasonSection(cat, stats);
            if (cat.type === 'secret')    return renderSecretSection(cat, stats);
            if (cat.type === 'role')      return renderRoleSection(cat, stats);
            return '';
        }).join('');
    }

    function renderSecretSection(cat, stats) {
        const ordered = cat.badges.slice();
        let earnedCount = 0;
        const cards = ordered.map(b => {
            if (badgeIsEarned(cat, b, stats)) {
                earnedCount++;
                return badgeIcon(b);
            }
            return badgeIcon(b, { locked: true, secret: true });
        }).join('');
        const total  = ordered.length;
        const footer = earnedCount === 0
            ? `<div class="gtec-badge-next">🔍 ${total} hidden badge${total === 1 ? '' : 's'} waiting to be discovered…</div>`
            : earnedCount === total
                ? `<div class="gtec-badge-next">Every secret uncovered. Few have done it.</div>`
                : `<div class="gtec-badge-next">🔍 <strong>${earnedCount} / ${total}</strong> secrets discovered</div>`;
        return `
            <div class="gtec-badge-section">
                <div class="gtec-badge-section-title">${cat.title}</div>
                <div class="gtec-badge-grid">${cards}</div>
                ${footer}
            </div>`;
    }

    function renderThresholdSection(cat, stats) {
        const n = Number(stats[cat.stat]) || 0;
        const ordered = cat.badges.slice().reverse(); // easiest first
        const cards = ordered.map(b => {
            const locked = !badgeIsEarned(cat, b, stats);
            if (!locked) return badgeIcon(b);
            const prev = b.threshold === ordered[0].threshold ? 0
                : cat.badges.find(x => x.threshold < b.threshold).threshold;
            const range = b.threshold - prev;
            const intoRange = Math.max(0, n - prev);
            const progress = Math.max(0, Math.min(1, intoRange / range));
            return badgeIcon(b, { locked: true, progress });
        }).join('');

        const next = nextThreshold(cat, n);
        const footer = next
            ? `<div class="gtec-badge-next">🏁 <strong>${n} / ${next.threshold}</strong> ${cat.statLabel} to <strong>${next.name}</strong></div>`
            : `<div class="gtec-badge-next">Every ${cat.title.toLowerCase()} badge earned.</div>`;

        return `
            <div class="gtec-badge-section">
                <div class="gtec-badge-section-title">${cat.title}</div>
                <div class="gtec-badge-grid">${cards}</div>
                ${footer}
            </div>`;
    }

    function renderMatchSection(cat, stats) {
        // Show declared order (Spa, Monza, Suzuka…) instead of the
        // reverse used for threshold ladders so the list feels like a
        // tour itinerary rather than a podium.
        const ordered = cat.badges.slice();
        let earnedCount = 0;
        const cards = ordered.map(b => {
            if (badgeIsEarned(cat, b, stats)) {
                earnedCount++;
                return badgeIcon(b);
            }
            return badgeIcon(b, { locked: true });
        }).join('');

        const total  = ordered.length;
        const footer = earnedCount === 0
            ? `<div class="gtec-badge-next">No circuit badges yet — finish a race to claim your first.</div>`
            : earnedCount === total
                ? `<div class="gtec-badge-next">Every circuit conquered. Untouchable.</div>`
                : `<div class="gtec-badge-next">🏁 <strong>${earnedCount} / ${total}</strong> circuits visited</div>`;

        return `
            <div class="gtec-badge-section">
                <div class="gtec-badge-section-title">${cat.title}</div>
                <div class="gtec-badge-grid">${cards}</div>
                ${footer}
            </div>`;
    }

    function renderSeasonSection(cat, stats) {
        // Display easiest → hardest (Contender left, Dynasty right) so
        // the row reads as a climb instead of starting at the summit.
        const ordered = cat.badges.slice().reverse();
        let earnedCount = 0;
        const cards = ordered.map(b => {
            if (badgeIsEarned(cat, b, stats)) {
                earnedCount++;
                return badgeIcon(b);
            }
            return badgeIcon(b, { locked: true });
        }).join('');
        const total = ordered.length;
        const seasons = (stats.seasonFinishes || []).length;
        const titles  = (stats.seasonFinishes || []).filter(p => p === 1).length;
        const footer = seasons === 0
            ? `<div class="gtec-badge-next">Title badges unlock once a season has been completed.</div>`
            : earnedCount === total
                ? `<div class="gtec-badge-next">Every title earned. Untouchable.</div>`
                : `<div class="gtec-badge-next">🏁 <strong>${titles}</strong> championship${titles === 1 ? '' : 's'} · <strong>${seasons}</strong> season${seasons === 1 ? '' : 's'} finished</div>`;
        return `
            <div class="gtec-badge-section">
                <div class="gtec-badge-section-title">${cat.title}</div>
                <div class="gtec-badge-grid">${cards}</div>
                ${footer}
            </div>`;
    }

    // Inject CSS once.
    if (!document.getElementById('gtec-badge-styles')) {
        const style = document.createElement('style');
        style.id = 'gtec-badge-styles';
        style.textContent = `
            .gtec-badge-strip {
                display: flex;
                flex-wrap: wrap;
                gap: 0.4rem;
                margin: 0.85rem 0 0.5rem;
            }
            /* Strip tiles are noticeably smaller than the portal grid
               so a profile with a full collection doesn't sprawl down
               the page. The grid keeps its larger sizing for browsing. */
            .gtec-badge-strip .gtec-badge {
                min-width: 64px;
                padding: 0.4rem 0.35rem 0.35rem;
                gap: 0.25rem;
            }
            .gtec-badge-strip .gtec-badge-icon {
                width: 34px; height: 34px;
                font-size: 1.05rem;
                border-width: 1.5px;
            }
            .gtec-badge-strip .gtec-badge-label {
                font-size: 0.48rem;
                letter-spacing: 0.14em;
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
            .gtec-badge.gtec-badge-artwork {
                background: none;
                border: none;
                box-shadow: none;
            }
            .gtec-badge.gtec-badge-artwork:hover { box-shadow: none; }
            .gtec-badge-locked {
                background: linear-gradient(160deg, rgba(255,255,255,0.04), rgba(255,255,255,0.02));
                border-color: rgba(255,255,255,0.1);
                opacity: 0.75;
            }
            .gtec-badge-locked .gtec-badge-label { color: rgba(148,163,184,0.55); }
            .gtec-badge-secret {
                background: linear-gradient(160deg, rgba(255,255,255,0.03), rgba(255,255,255,0.01)) !important;
                border-style: dashed !important;
                border-color: rgba(255,255,255,0.18) !important;
                opacity: 0.6;
            }
            .gtec-badge-secret .gtec-badge-icon {
                background: radial-gradient(circle at 30% 25%, rgba(255,255,255,0.05), rgba(0,0,0,0.5) 75%) !important;
                border-color: rgba(255,255,255,0.18) !important;
                box-shadow: none !important;
                color: rgba(148,163,184,0.6);
                font-family: 'Anton', sans-serif !important;
                font-weight: 900;
                filter: none !important;
            }
            .gtec-badge-secret .gtec-badge-label {
                color: rgba(148,163,184,0.45) !important;
                letter-spacing: 0.3em;
            }
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
                overflow: hidden;
            }
            .gtec-badge-icon img {
                width: 100%; height: 100%;
                object-fit: cover;
                border-radius: 50%;
            }
            .gtec-badge-locked .gtec-badge-icon {
                background: radial-gradient(circle at 30% 25%, rgba(255,255,255,0.05), rgba(0,0,0,0.4) 75%);
                border-color: rgba(255,255,255,0.15);
                box-shadow: none;
                filter: grayscale(1) brightness(0.65);
            }
            .gtec-badge-icon.gtec-badge-artwork {
                background: none;
                border: none;
                box-shadow: none;
                border-radius: 0;
            }
            .gtec-badge-icon.gtec-badge-artwork img {
                border-radius: 0;
                object-fit: contain;
            }
            .gtec-badge-locked .gtec-badge-icon.gtec-badge-artwork {
                background: none;
                border: none;
                box-shadow: none;
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

    window.BADGE_CATEGORIES  = CATEGORIES;
    window.renderBadgeStrip  = renderBadgeStrip;
    window.renderBadgeGrid   = renderBadgeGrid;
    // Shared with other pages that render their own compact badge chips
    // (driver cards, admin's manual-badge picker) so a badge's icon — emoji
    // or custom PNG — never has to be interpreted more than once.
    window.gtecBadgeIsImage     = isImageIcon;
    window.gtecBadgeIconMarkup  = iconMarkup;
})();
