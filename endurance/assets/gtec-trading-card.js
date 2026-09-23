/* GTEC trading card - paints a 1080x1440 PNG collectible card for a
   driver's career: foil-tier border, team crest, edition number. This is
   a persistent collectible, distinct from the one-off Share Driver Card
   (gtec-share-card.js) - same modal/export pattern, different artwork.
   Self-contained: only API surface is

       window.gtecTradingCard({
           driver:   { display_name, slug, career_number, nationality,
                       photo_url, team_name, manufacturer_name },
           stats:    { elo, tier, points, wins, podiums, races },
           buttonEl: <button> to show "Building…" / restore on,
       });

   Needs gtec-crest.js loaded first (for the team crest badge); renders
   fine without it, just without the crest. */
(function () {
    'use strict';

    const W = 1080;
    const H = 1440;
    const SITE_URL = 'https://sparkstheory.co.uk/endurance/';

    // Mirrors the ten Elo tiers in elo-tiers.js (bronze through legend),
    // same colour families, so the card's foil border always matches the
    // tier badge shown everywhere else on the site. "steel" is the only
    // tier not in elo-tiers.js - the placeholder for a provisional /
    // unrated driver, who has no tier yet.
    const TIERS = {
        bronze:       { label: 'Bronze Tier',       stops: ['#f0c090', '#cd7f32', '#6e3d10'], glow: 'rgba(205,127,50,0.45)' },
        silver:       { label: 'Silver Tier',       stops: ['#ffffff', '#c0c0c0', '#71797e'], glow: 'rgba(192,192,192,0.4)' },
        gold:         { label: 'Gold Tier',         stops: ['#fff3c4', '#ffd700', '#b8860b'], glow: 'rgba(255,215,0,0.5)' },
        platinum:     { label: 'Platinum Tier',     stops: ['#f5f5f0', '#e5e4e2', '#8a9bab'], glow: 'rgba(176,196,222,0.45)' },
        diamond:      { label: 'Diamond Tier',      stops: ['#e8fbff', '#b9f2ff', '#2f9fc4'], glow: 'rgba(93,211,255,0.5)' },
        elite:        { label: 'Elite Tier',        stops: ['#6ee7b7', '#10b981', '#047857'], glow: 'rgba(16,185,129,0.45)' },
        master:       { label: 'Master Tier',       stops: ['#ffb347', '#ff4500', '#c23600'], glow: 'rgba(255,69,0,0.45)' },
        champion:     { label: 'Champion Tier',     stops: ['#f87171', '#dc2626', '#7f1d1d'], glow: 'rgba(220,38,38,0.45)' },
        hall_of_fame: { label: 'Hall of Fame Tier', stops: ['#c4b5fd', '#8b5cf6', '#4c1d95'], glow: 'rgba(139,92,246,0.5)' },
        legend:       { label: 'Legend Tier',       stops: ['#ff9ed8', '#ff0080', '#8b00ff'], glow: 'rgba(255,0,128,0.55)' },
        steel:        { label: 'Rookie',            stops: ['#aab4c2', '#4b5563', '#1f2937'], glow: 'rgba(148,163,184,0.3)' },
    };

    function tierKey(tier) {
        const t = (tier || '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
        return TIERS[t] ? t : 'steel';
    }

    // Same djb2-style hash as gtec-crest.js, kept local so this file has
    // no hard dependency on load order beyond gtecRenderCrest itself.
    function hashStr(s) {
        let h = 5381;
        for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
        return h >>> 0;
    }

    function serialFor(driver) {
        if (driver.career_number != null) return String(driver.career_number).padStart(3, '0');
        const h = hashStr(driver.display_name || driver.slug || 'gtec');
        return String(h % 1000).padStart(3, '0');
    }

    async function ensureFonts() {
        if (!document.fonts || !document.fonts.load) return;
        try {
            await Promise.race([
                Promise.all([
                    document.fonts.load('900 96px "Anton"'),
                    document.fonts.load('800 26px "Orbitron"'),
                    document.fonts.load('600 24px "Inter"'),
                ]),
                new Promise((r) => setTimeout(r, 1500)),
            ]);
        } catch (_) {/* ignore */}
    }

    function loadImage(url, crossOrigin = 'anonymous') {
        return new Promise((resolve) => {
            if (!url) return resolve(null);
            const img = new Image();
            if (crossOrigin) img.crossOrigin = crossOrigin;
            img.onload  = () => resolve(img);
            img.onerror = () => resolve(null);
            img.src = url;
        });
    }

    function roundRect(ctx, x, y, w, h, r) {
        ctx.beginPath();
        ctx.moveTo(x + r, y);
        ctx.lineTo(x + w - r, y);
        ctx.quadraticCurveTo(x + w, y, x + w, y + r);
        ctx.lineTo(x + w, y + h - r);
        ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
        ctx.lineTo(x + r, y + h);
        ctx.quadraticCurveTo(x, y + h, x, y + h - r);
        ctx.lineTo(x, y + r);
        ctx.quadraticCurveTo(x, y, x + r, y);
        ctx.closePath();
    }

    function foilGradient(ctx, x0, y0, x1, y1, stops) {
        const g = ctx.createLinearGradient(x0, y0, x1, y1);
        g.addColorStop(0,    stops[0]);
        g.addColorStop(0.5,  stops[1]);
        g.addColorStop(1,    stops[2]);
        return g;
    }

    async function drawTradingCard(driver, stats, opts) {
        const eyebrow = (opts && opts.eyebrow) || 'CAREER CARD';
        const canvas = document.createElement('canvas');
        canvas.width  = W;
        canvas.height = H;
        const ctx = canvas.getContext('2d');
        const hasLS = ('letterSpacing' in ctx);
        const setLS = (v) => { if (hasLS) ctx.letterSpacing = v; };

        const tk = tierKey(stats.tier);
        const tier = TIERS[tk];
        const margin = 24;

        /* ---------- dark base ---------- */
        ctx.fillStyle = '#050608';
        ctx.fillRect(0, 0, W, H);

        /* ---------- foil border frame ---------- */
        ctx.save();
        ctx.shadowColor = tier.glow;
        ctx.shadowBlur = 40;
        ctx.strokeStyle = foilGradient(ctx, 0, 0, W, H, tier.stops);
        ctx.lineWidth = 10;
        roundRect(ctx, margin, margin, W - margin * 2, H - margin * 2, 28);
        ctx.stroke();
        ctx.restore();
        ctx.strokeStyle = foilGradient(ctx, 0, 0, W, H, tier.stops);
        ctx.globalAlpha = 0.55;
        ctx.lineWidth = 2;
        roundRect(ctx, margin + 16, margin + 16, W - (margin + 16) * 2, H - (margin + 16) * 2, 20);
        ctx.stroke();
        ctx.globalAlpha = 1;

        const innerX = margin + 30, innerY = margin + 30, innerW = W - (margin + 30) * 2;

        /* ---------- photo panel ---------- */
        const photoH = Math.round(H * 0.56);
        roundRect(ctx, innerX, innerY, innerW, photoH, 16);
        ctx.save();
        ctx.clip();
        const photo = driver.photo_url ? await loadImage(driver.photo_url) : null;
        if (photo) {
            const ar = photo.width / photo.height, boxAr = innerW / photoH;
            let dw, dh, dx, dy;
            if (ar > boxAr) { dh = photoH; dw = dh * ar; dx = innerX - (dw - innerW) / 2; dy = innerY; }
            else            { dw = innerW; dh = dw / ar; dx = innerX; dy = innerY - Math.max(0, (dh - photoH) * 0.15); }
            ctx.drawImage(photo, dx, dy, dw, dh);
        } else {
            ctx.fillStyle = '#0a0e15';
            ctx.fillRect(innerX, innerY, innerW, photoH);
            const ini = (driver.display_name || '?').split(/\s+/).slice(0, 2).map(s => s[0]).join('').toUpperCase();
            ctx.fillStyle = 'rgba(255,255,255,0.06)';
            ctx.font = '900 260px "Anton", Impact, sans-serif';
            ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
            ctx.fillText(ini, innerX + innerW / 2, innerY + photoH / 2);
            ctx.textBaseline = 'alphabetic';
        }
        // Bottom fade so the info block below reads cleanly against any photo.
        const fadeG = ctx.createLinearGradient(0, innerY + photoH * 0.7, 0, innerY + photoH);
        fadeG.addColorStop(0, 'rgba(5,6,8,0)');
        fadeG.addColorStop(1, 'rgba(5,6,8,0.85)');
        ctx.fillStyle = fadeG;
        ctx.fillRect(innerX, innerY, innerW, photoH);
        ctx.restore();
        ctx.strokeStyle = 'rgba(255,255,255,0.08)'; ctx.lineWidth = 1;
        roundRect(ctx, innerX, innerY, innerW, photoH, 16); ctx.stroke();

        /* ---------- header: wordmark + rarity tag ---------- */
        ctx.fillStyle = 'rgba(255,255,255,0.85)';
        ctx.font = '700 24px "Orbitron", system-ui, sans-serif';
        ctx.textAlign = 'left'; ctx.textBaseline = 'alphabetic';
        setLS('0.35em');
        ctx.fillText('GTEC', innerX + 20, innerY + 42);
        setLS('0px');
        ctx.fillStyle = 'rgba(255,255,255,0.5)';
        ctx.font = '700 16px "Orbitron", system-ui, sans-serif';
        setLS('0.2em');
        ctx.fillText(eyebrow, innerX + 20, innerY + 64);
        setLS('0px');

        const rarityText = tier.label.toUpperCase();
        ctx.font = '700 18px "Orbitron", system-ui, sans-serif';
        const rw = ctx.measureText(rarityText).width;
        const rpx = 16, rh = 38;
        const rbx = innerX + innerW - 20 - (rw + rpx * 2), rby = innerY + 18;
        ctx.fillStyle = 'rgba(5,6,8,0.6)';
        roundRect(ctx, rbx, rby, rw + rpx * 2, rh, rh / 2); ctx.fill();
        ctx.strokeStyle = foilGradient(ctx, rbx, rby, rbx + rw + rpx * 2, rby, tier.stops);
        ctx.lineWidth = 1.5;
        roundRect(ctx, rbx, rby, rw + rpx * 2, rh, rh / 2); ctx.stroke();
        ctx.fillStyle = tier.stops[1];
        ctx.textBaseline = 'middle';
        ctx.fillText(rarityText, rbx + rpx, rby + rh / 2 + 1);
        ctx.textBaseline = 'alphabetic';

        /* ---------- team crest badge, bottom-right of photo ---------- */
        if (driver.team_name && window.gtecRenderCrest) {
            const crestSize = 108;
            const cx = innerX + innerW - 20 - crestSize, cy = innerY + photoH - 20 - crestSize;
            ctx.save();
            ctx.shadowColor = 'rgba(0,0,0,0.6)';
            ctx.shadowBlur = 16;
            roundRect(ctx, cx - 8, cy - 8, crestSize + 16, crestSize + 16, 14);
            ctx.fillStyle = 'rgba(5,6,8,0.55)';
            ctx.fill();
            ctx.restore();
            const crestCanvas = window.gtecRenderCrest(driver.team_name, crestSize * 2);
            ctx.drawImage(crestCanvas, cx, cy, crestSize, crestSize);
        }

        /* ---------- edition / serial, bottom-left of photo ---------- */
        const serial = serialFor(driver);
        ctx.fillStyle = 'rgba(5,6,8,0.6)';
        ctx.font = '700 20px "Orbitron", system-ui, sans-serif';
        const serialText = `NO. ${serial}`;
        const sw = ctx.measureText(serialText).width;
        const spx = 14, sh = 34;
        roundRect(ctx, innerX + 20, innerY + photoH - 20 - sh, sw + spx * 2, sh, sh / 2); ctx.fill();
        ctx.fillStyle = 'rgba(255,255,255,0.75)';
        ctx.textBaseline = 'middle'; ctx.textAlign = 'left';
        setLS('0.08em');
        ctx.fillText(serialText, innerX + 20 + spx, innerY + photoH - 20 - sh / 2 + 1);
        setLS('0px');
        ctx.textBaseline = 'alphabetic';

        /* ---------- info block below photo ---------- */
        let curY = innerY + photoH + 64;

        // Name font size first, so the career-number advance below can be
        // sized to the name's actual cap height and never overlap it.
        const nameText = (driver.display_name || '').toUpperCase();
        let nameFs = 92;
        while (nameFs > 48) {
            ctx.font = `900 ${nameFs}px "Anton", Impact, sans-serif`;
            if (ctx.measureText(nameText).width < innerW - 8) break;
            nameFs -= 3;
        }

        if (driver.career_number != null) {
            ctx.fillStyle = tier.stops[1];
            ctx.font = '700 30px "Orbitron", system-ui, sans-serif';
            setLS('0.1em');
            ctx.fillText('#' + driver.career_number, innerX + 4, curY);
            setLS('0px');
            curY += Math.round(nameFs * 0.78) + 14;
        }

        ctx.font = `900 ${nameFs}px "Anton", Impact, sans-serif`;
        ctx.fillStyle = '#f1f5f9';
        ctx.fillText(nameText, innerX + 4, curY);
        curY += nameFs * 0.55 + 40;

        const tagParts = [];
        if (driver.nationality)  tagParts.push(driver.nationality);
        if (driver.team_name)    tagParts.push(driver.team_name);
        else if (driver.manufacturer_name) tagParts.push(driver.manufacturer_name);
        if (tagParts.length) {
            ctx.fillStyle = 'rgba(148,163,184,0.88)';
            ctx.font = '400 28px "Inter", system-ui, sans-serif';
            ctx.fillText(tagParts.join('  ·  '), innerX + 4, curY);
            curY += 46;
        }

        /* ---------- stat grid: 2x2 ---------- */
        const statItems = [
            { k: 'ELO',     v: stats.elo != null ? String(stats.elo) : '0' },
            { k: 'POINTS',  v: stats.points != null ? String(stats.points) : '0' },
            { k: 'WINS',    v: stats.wins != null ? String(stats.wins) : '0' },
            { k: 'PODIUMS', v: stats.podiums != null ? String(stats.podiums) : '0' },
        ];
        const gridY = H - margin - 30 - 190;
        const gridH = 190, gridW = innerW, colW = gridW / 2, rowH = gridH / 2;
        ctx.strokeStyle = 'rgba(255,255,255,0.1)'; ctx.lineWidth = 1;
        roundRect(ctx, innerX, gridY, gridW, gridH, 14); ctx.stroke();
        ctx.fillStyle = 'rgba(255,255,255,0.03)';
        roundRect(ctx, innerX, gridY, gridW, gridH, 14); ctx.fill();
        ctx.beginPath();
        ctx.moveTo(innerX + colW, gridY + 18); ctx.lineTo(innerX + colW, gridY + gridH - 18);
        ctx.moveTo(innerX + 18, gridY + rowH); ctx.lineTo(innerX + gridW - 18, gridY + rowH);
        ctx.strokeStyle = 'rgba(255,255,255,0.08)';
        ctx.stroke();

        statItems.forEach((cell, i) => {
            const col = i % 2, row = Math.floor(i / 2);
            const ccx = innerX + colW * col + colW / 2;
            const ccy = gridY + rowH * row + rowH / 2;
            ctx.fillStyle = tier.stops[1];
            ctx.font = '900 54px "Anton", Impact, sans-serif';
            ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
            ctx.fillText(cell.v, ccx, ccy - 14);
            ctx.fillStyle = 'rgba(148,163,184,0.85)';
            ctx.font = '700 16px "Orbitron", system-ui, sans-serif';
            setLS('0.1em');
            ctx.fillText(cell.k, ccx, ccy + 26);
            setLS('0px');
        });

        /* ---------- foil sheen sweep ---------- */
        ctx.save();
        roundRect(ctx, margin, margin, W - margin * 2, H - margin * 2, 28);
        ctx.clip();
        const sheen = ctx.createLinearGradient(0, 0, W, H * 0.6);
        sheen.addColorStop(0,    'rgba(255,255,255,0)');
        sheen.addColorStop(0.42, 'rgba(255,255,255,0)');
        sheen.addColorStop(0.5,  'rgba(255,255,255,0.06)');
        sheen.addColorStop(0.58, 'rgba(255,255,255,0)');
        sheen.addColorStop(1,    'rgba(255,255,255,0)');
        ctx.fillStyle = sheen;
        ctx.fillRect(0, 0, W, H);
        ctx.restore();

        /* ---------- footer ---------- */
        ctx.fillStyle = 'rgba(148,163,184,0.5)';
        ctx.font = '700 18px "Orbitron", system-ui, sans-serif';
        ctx.textAlign = 'center'; ctx.textBaseline = 'alphabetic';
        setLS('0.15em');
        ctx.fillText('SPARKSTHEORY.CO.UK/ENDURANCE', W / 2, H - margin - 18);
        setLS('0px');

        return canvas;
    }

    function canvasToBlob(canvas) {
        return new Promise((resolve) => canvas.toBlob((b) => resolve(b), 'image/png', 0.95));
    }

    function injectModalStyles() {
        if (document.getElementById('gtec-tcard-modal-style')) return;
        const style = document.createElement('style');
        style.id = 'gtec-tcard-modal-style';
        style.textContent = `
            .gtec-tcard-overlay {
                position: fixed; inset: 0;
                background: rgba(0,0,0,0.78);
                backdrop-filter: blur(6px);
                z-index: 9999;
                display: flex; align-items: center; justify-content: center;
                padding: 1.25rem;
                opacity: 0; transition: opacity 0.15s ease;
            }
            .gtec-tcard-overlay.open { opacity: 1; }
            .gtec-tcard-modal {
                background: var(--bg-1, #0a0e15);
                border: 1px solid rgba(255,209,102,0.35);
                border-radius: 14px;
                max-width: 460px;
                width: 100%;
                max-height: 92vh;
                overflow-y: auto;
                padding: 1.1rem 1.1rem 1.25rem;
                box-shadow: 0 20px 60px rgba(0,0,0,0.65);
                position: relative;
            }
            .gtec-tcard-head {
                display: flex; align-items: center; justify-content: space-between;
                margin-bottom: 0.85rem;
            }
            .gtec-tcard-title {
                font-family: 'Orbitron', sans-serif;
                font-size: 0.62rem; font-weight: 700; letter-spacing: 0.35em;
                text-transform: uppercase; color: var(--gold, #ffd166);
            }
            .gtec-tcard-close {
                background: transparent; border: none;
                color: var(--muted, #94a3b8);
                font-size: 1.4rem; line-height: 1;
                cursor: pointer; padding: 0.1rem 0.45rem;
                transition: color 0.15s ease;
            }
            .gtec-tcard-close:hover { color: var(--text, #f1f5f9); }
            .gtec-tcard-preview {
                width: 100%;
                aspect-ratio: 3 / 4;
                border-radius: 10px;
                overflow: hidden;
                margin-bottom: 1rem;
                border: 1px solid rgba(255,255,255,0.08);
            }
            .gtec-tcard-preview img { width: 100%; height: 100%; display: block; }
            .gtec-tcard-actions {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 0.5rem;
            }
            .gtec-tcard-action {
                display: inline-flex; align-items: center; justify-content: center; gap: 0.4rem;
                padding: 0.7rem 0.85rem;
                background: var(--bg-2, #11161f);
                border: 1px solid rgba(255,255,255,0.1);
                border-radius: 8px;
                color: var(--text, #f1f5f9);
                font-family: 'Orbitron', sans-serif;
                font-size: 0.58rem; font-weight: 700; letter-spacing: 0.18em;
                text-transform: uppercase;
                cursor: pointer;
                transition: background 0.15s ease, border-color 0.15s ease, transform 0.1s ease;
            }
            .gtec-tcard-action:hover:not(:disabled) {
                background: rgba(255,209,102,0.08);
                border-color: rgba(255,209,102,0.45);
                transform: translateY(-1px);
            }
            .gtec-tcard-action.primary {
                background: linear-gradient(135deg, rgba(255,209,102,0.25), rgba(255,209,102,0.08));
                border-color: rgba(255,209,102,0.55);
                color: var(--gold, #ffd166);
                grid-column: 1 / -1;
            }
            .gtec-tcard-action.primary:hover:not(:disabled) {
                background: linear-gradient(135deg, rgba(255,209,102,0.4), rgba(255,209,102,0.15));
            }
            .gtec-tcard-action svg { width: 13px; height: 13px; }
            .gtec-tcard-action:disabled { opacity: 0.65; cursor: progress; }
            .gtec-tcard-hint {
                font-family: 'Inter', sans-serif;
                font-size: 0.72rem;
                color: var(--muted, #94a3b8);
                text-align: center;
                margin-top: 0.85rem;
                line-height: 1.45;
            }
            @media (max-width: 520px) {
                .gtec-tcard-actions { grid-template-columns: 1fr; }
            }
        `;
        document.head.appendChild(style);
    }

    function escAttr(s) {
        return String(s || '').replace(/"/g, '&quot;');
    }

    function openModal({ blob, fname, url, driver, title }) {
        injectModalStyles();
        const previewUrl = URL.createObjectURL(blob);
        const overlay = document.createElement('div');
        overlay.className = 'gtec-tcard-overlay';

        const supportsShare = !!(navigator.share && navigator.canShare &&
            navigator.canShare({ files: [new File([blob], fname, { type: 'image/png' })] }));

        overlay.innerHTML = `
            <div class="gtec-tcard-modal" role="dialog" aria-label="Trading card">
                <div class="gtec-tcard-head">
                    <div class="gtec-tcard-title">${escAttr(title || 'Trading Card')}</div>
                    <button class="gtec-tcard-close" data-act="close" aria-label="Close">✕</button>
                </div>
                <div class="gtec-tcard-preview"><img src="${previewUrl}" alt="${escAttr(driver.display_name || 'Driver')} - GTEC career card"></div>
                <div class="gtec-tcard-actions">
                    ${supportsShare ? `<button class="gtec-tcard-action primary" data-act="share">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/><polyline points="16 6 12 2 8 6"/><line x1="12" y1="2" x2="12" y2="15"/></svg>
                        Share…
                    </button>` : ''}
                    <button class="gtec-tcard-action" data-act="download">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                        Download
                    </button>
                    <button class="gtec-tcard-action" data-act="copy-image">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>
                        <span data-label="copy-image">Copy Image</span>
                    </button>
                    <button class="gtec-tcard-action" data-act="copy-link" style="${supportsShare ? '' : 'grid-column:1 / -1'}">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.07 0l3-3a5 5 0 0 0-7.07-7.07L11 5"/><path d="M14 11a5 5 0 0 0-7.07 0l-3 3a5 5 0 0 0 7.07 7.07L13 19"/></svg>
                        <span data-label="copy-link">Copy Link</span>
                    </button>
                </div>
                <div class="gtec-tcard-hint">Right-click or long-press the image to save it manually, or paste it into Discord / X / WhatsApp after Copy Image.</div>
            </div>
        `;

        document.body.appendChild(overlay);
        requestAnimationFrame(() => overlay.classList.add('open'));

        const close = () => {
            overlay.classList.remove('open');
            setTimeout(() => {
                overlay.remove();
                URL.revokeObjectURL(previewUrl);
            }, 150);
        };

        overlay.addEventListener('click', (e) => {
            if (e.target === overlay) close();
        });

        const flash = (sel, txt, restore = 1800) => {
            const el = overlay.querySelector(`[data-label="${sel}"]`);
            if (!el) return;
            const orig = el.textContent;
            el.textContent = txt;
            setTimeout(() => { el.textContent = orig; }, restore);
        };

        overlay.addEventListener('click', async (e) => {
            const target = e.target.closest('[data-act]');
            if (!target) return;
            const act = target.dataset.act;

            if (act === 'close') return close();

            if (act === 'download') {
                const a = document.createElement('a');
                a.href = previewUrl;
                a.download = fname;
                document.body.appendChild(a);
                a.click();
                a.remove();
                return;
            }

            if (act === 'copy-image') {
                try {
                    if (!navigator.clipboard || !window.ClipboardItem) throw new Error('Clipboard API unavailable');
                    await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
                    flash('copy-image', 'Copied!');
                } catch (err) {
                    console.warn('Copy image failed', err);
                    flash('copy-image', 'Use Download');
                }
                return;
            }

            if (act === 'copy-link') {
                try {
                    await navigator.clipboard.writeText(url);
                    flash('copy-link', 'Copied!');
                } catch (err) {
                    flash('copy-link', 'Copy failed');
                }
                return;
            }

            if (act === 'share') {
                try {
                    const file = new File([blob], fname, { type: 'image/png' });
                    await navigator.share({
                        title: `${driver.display_name} - GTEC`,
                        text:  `My GTEC career card.`,
                        files: [file],
                        url:   url,
                    });
                } catch (err) {
                    if (!err || err.name !== 'AbortError') {
                        console.warn('Share failed', err);
                    }
                }
                return;
            }
        });

        document.addEventListener('keydown', function onEsc(e) {
            if (e.key === 'Escape') {
                document.removeEventListener('keydown', onEsc);
                close();
            }
        });
    }

    // eyebrow/title/fnamePart let a locked season card (My Collection)
    // reuse this same painter/modal with different labelling, e.g.
    // eyebrow: "2026 SEASON" instead of the default live "CAREER CARD".
    async function gtecTradingCard({ driver, stats, buttonEl, eyebrow, title, fnamePart }) {
        const restore = buttonEl ? buttonEl.innerHTML : null;
        const setBtn = (txt) => {
            if (!buttonEl) return;
            buttonEl.disabled = true;
            buttonEl.innerHTML = txt;
        };
        const resetBtn = () => {
            if (!buttonEl) return;
            buttonEl.disabled = false;
            buttonEl.innerHTML = restore;
        };

        try {
            setBtn('Building card…');
            await ensureFonts();
            const canvas = await drawTradingCard(driver, stats, { eyebrow });
            const blob   = await canvasToBlob(canvas);
            if (!blob) throw new Error('Canvas blob failed');

            const url   = SITE_URL + (driver.slug ? `drivers/?slug=${encodeURIComponent(driver.slug)}` : '');
            const fname = `${(driver.slug || driver.display_name || 'driver').replace(/[^a-z0-9-]/gi, '-').toLowerCase()}-gtec-card${fnamePart ? '-' + fnamePart : ''}.png`;

            resetBtn();
            openModal({ blob, fname, url, driver, title });
        } catch (err) {
            console.error(err);
            setBtn('Card failed');
            setTimeout(resetBtn, 2000);
        }
    }

    window.gtecTradingCard = gtecTradingCard;
})();
