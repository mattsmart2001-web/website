/* GTEC share card — paints a 1080×1080 PNG of a driver's profile and
   shares it via the Web Share API (or falls back to download + copy
   URL). Self-contained: only API surface is

       window.gtecShareCard({
           driver:   { display_name, slug, career_number, nationality,
                       photo_url, team_name, manufacturer_name },
           stats:    { elo, tier, points, wins, podiums, races },
           buttonEl: <button> to show "Preparing…" / "Shared" on,
       });

   Falls back gracefully when fonts haven't loaded, when the driver
   photo is cross-origin-tainted, or when Web Share is unavailable. */
(function () {
    'use strict';

    const W = 1080;
    const H = 1440;
    const SITE_URL = 'https://sparkstheory.co.uk/endurance/';

    // Wait for the brand fonts so Canvas can use them. document.fonts is
    // available in every browser that matters; older Safari falls back to
    // a 1.5s timeout. Without this the card renders in fallback fonts.
    async function ensureFonts() {
        if (!document.fonts || !document.fonts.load) return;
        try {
            await Promise.race([
                Promise.all([
                    document.fonts.load('700 96px "Anton"'),
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

    async function drawCard(driver, stats) {
        const canvas = document.createElement('canvas');
        canvas.width  = W;
        canvas.height = H;
        const ctx = canvas.getContext('2d');
        const hasLS = ('letterSpacing' in ctx);
        const setLS = (v) => { if (hasLS) ctx.letterSpacing = v; };

        /* ---------- dark background ---------- */
        ctx.fillStyle = '#050608';
        ctx.fillRect(0, 0, W, H);

        /* ---------- driver photo — full bleed, top-anchored ---------- */
        const photo = driver.photo_url ? await loadImage(driver.photo_url) : null;
        if (photo) {
            const ar = photo.width / photo.height;
            const canvasAr = W / H;
            let dw, dh, dx, dy;
            if (ar > canvasAr) {
                dh = H; dw = dh * ar;
                dx = (W - dw) / 2; dy = 0;
            } else {
                dw = W; dh = dw / ar;
                dx = 0; dy = 0;
            }
            ctx.drawImage(photo, dx, dy, dw, dh);
        } else {
            ctx.fillStyle = '#0a0e15';
            ctx.fillRect(0, 0, W, Math.round(H * 0.65));
            const ini = (driver.display_name || '?').split(/\s+/).slice(0, 2).map(s => s[0]).join('').toUpperCase();
            ctx.fillStyle = 'rgba(255,209,102,0.07)';
            ctx.font = '900 300px "Anton", Impact, sans-serif';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillText(ini, W / 2, Math.round(H * 0.32));
            ctx.textBaseline = 'alphabetic';
        }

        /* ---------- ghost race number ---------- */
        if (driver.career_number != null) {
            const numStr = String(driver.career_number);
            const ghostFs = numStr.length <= 2 ? 480 : numStr.length === 3 ? 360 : 280;
            ctx.save();
            ctx.globalAlpha = 0.055;
            ctx.fillStyle = '#ffffff';
            ctx.font = `900 ${ghostFs}px "Orbitron", system-ui, sans-serif`;
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillText(numStr, W / 2, Math.round(H * 0.36));
            ctx.restore();
        }

        /* ---------- gradient overlays ---------- */
        // Top vignette (keeps top badges readable)
        const topG = ctx.createLinearGradient(0, 0, 0, 210);
        topG.addColorStop(0, 'rgba(5,6,8,0.68)');
        topG.addColorStop(1, 'rgba(5,6,8,0)');
        ctx.fillStyle = topG;
        ctx.fillRect(0, 0, W, 210);

        // Bottom gradient fading photo to near-black for the info block
        const botG = ctx.createLinearGradient(0, Math.round(H * 0.38), 0, H);
        botG.addColorStop(0,    'rgba(5,6,8,0)');
        botG.addColorStop(0.4,  'rgba(5,6,8,0.8)');
        botG.addColorStop(1,    'rgba(5,6,8,0.98)');
        ctx.fillStyle = botG;
        ctx.fillRect(0, 0, W, H);

        /* ---------- manufacturer colour strip (left edge) ---------- */
        ctx.fillStyle = driver.manufacturer_color || 'rgba(255,209,102,0.75)';
        ctx.fillRect(0, 0, 10, H);

        /* ---------- ELO badge — glass pill, top-left ---------- */
        if (stats.elo != null) {
            const label = 'ELO', value = String(stats.elo);
            const bh = 60, br = 10, padH = 18, gap = 12;
            ctx.font = '700 20px "Orbitron", system-ui, sans-serif';
            const lw = ctx.measureText(label).width;
            ctx.font = '900 36px "Anton", Impact, sans-serif';
            const vw = ctx.measureText(value).width;
            const bw = padH + lw + gap + vw + padH;
            const bx = 28, by = 28;
            ctx.fillStyle = 'rgba(5,6,8,0.72)';
            roundRect(ctx, bx, by, bw, bh, br); ctx.fill();
            ctx.strokeStyle = 'rgba(255,209,102,0.28)'; ctx.lineWidth = 1.5;
            roundRect(ctx, bx, by, bw, bh, br); ctx.stroke();
            ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
            ctx.fillStyle = 'rgba(148,163,184,0.85)';
            ctx.font = '700 20px "Orbitron", system-ui, sans-serif';
            ctx.fillText(label, bx + padH, by + bh / 2);
            ctx.fillStyle = '#ffd166';
            ctx.font = '900 36px "Anton", Impact, sans-serif';
            ctx.fillText(value, bx + padH + lw + gap, by + bh / 2 + 2);
            ctx.textBaseline = 'alphabetic';
        }

        /* ---------- PTS badge — glass pill, top-right ---------- */
        if (stats.points != null) {
            const label = 'PTS', value = String(stats.points);
            const bh = 60, br = 10, padH = 18, gap = 12;
            ctx.font = '700 20px "Orbitron", system-ui, sans-serif';
            const lw = ctx.measureText(label).width;
            ctx.font = '900 36px "Anton", Impact, sans-serif';
            const vw = ctx.measureText(value).width;
            const bw = padH + lw + gap + vw + padH;
            const bx = W - 28 - bw, by = 28;
            ctx.fillStyle = 'rgba(5,6,8,0.72)';
            roundRect(ctx, bx, by, bw, bh, br); ctx.fill();
            ctx.strokeStyle = 'rgba(255,209,102,0.28)'; ctx.lineWidth = 1.5;
            roundRect(ctx, bx, by, bw, bh, br); ctx.stroke();
            ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
            ctx.fillStyle = 'rgba(148,163,184,0.85)';
            ctx.font = '700 20px "Orbitron", system-ui, sans-serif';
            ctx.fillText(label, bx + padH, by + bh / 2);
            ctx.fillStyle = '#ffd166';
            ctx.font = '900 36px "Anton", Impact, sans-serif';
            ctx.fillText(value, bx + padH + lw + gap, by + bh / 2 + 2);
            ctx.textBaseline = 'alphabetic';
        }

        /* ---------- GTEC wordmark — top centre ---------- */
        ctx.fillStyle = 'rgba(255,209,102,0.5)';
        ctx.font = '700 26px "Orbitron", system-ui, sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'alphabetic';
        setLS('0.4em');
        ctx.fillText('GTEC', W / 2, 76);
        setLS('0px');

        /* ---------- bottom info block ---------- */
        const leftX = 50;
        let curY = Math.round(H * 0.60);  // ~864

        // Pre-compute name font size first so the career-number advance
        // is large enough that the name's tall cap height can't reach up
        // and overlap it.
        const nameText = (driver.display_name || '').toUpperCase();
        let nameFs = 128;
        ctx.textAlign = 'left';
        while (nameFs > 58) {
            ctx.font = `900 ${nameFs}px "Anton", Impact, sans-serif`;
            if (ctx.measureText(nameText).width < W - leftX - 36) break;
            nameFs -= 3;
        }

        // #number line
        if (driver.career_number != null) {
            ctx.fillStyle = '#ffd166';
            ctx.font = '700 34px "Orbitron", system-ui, sans-serif';
            ctx.textAlign = 'left'; ctx.textBaseline = 'alphabetic';
            setLS('0.12em');
            ctx.fillText('#' + driver.career_number, leftX, curY);
            setLS('0px');
            // Advance by ~85% of nameFs so the name cap (75% of font size)
            // stays below the career-number baseline with room to spare.
            curY += Math.round(nameFs * 0.85) + 16;
        } else {
            curY += 18;
        }

        // Driver name
        ctx.font = `900 ${nameFs}px "Anton", Impact, sans-serif`;
        ctx.fillStyle = '#f1f5f9';
        ctx.textAlign = 'left';
        ctx.fillText(nameText, leftX, curY);
        curY += nameFs + 24;

        // Nationality · Team
        const tagParts = [];
        if (driver.nationality) tagParts.push(driver.nationality);
        if (driver.team_name)   tagParts.push(driver.team_name);
        if (tagParts.length) {
            ctx.fillStyle = 'rgba(148,163,184,0.88)';
            ctx.font = '400 34px "Inter", system-ui, sans-serif';
            ctx.fillText(tagParts.join('  ·  '), leftX, curY);
            curY += 54;
        }

        // Tier pill
        if (stats.tier) {
            curY += 14;
            const tierText = stats.tier.toUpperCase();
            ctx.font = '700 20px "Orbitron", system-ui, sans-serif';
            const tw = ctx.measureText(tierText).width;
            const px = 22, pillH = 46, br = 9;
            ctx.fillStyle = 'rgba(255,209,102,0.1)';
            roundRect(ctx, leftX, curY, tw + px * 2, pillH, br); ctx.fill();
            ctx.strokeStyle = 'rgba(255,209,102,0.38)'; ctx.lineWidth = 1;
            roundRect(ctx, leftX, curY, tw + px * 2, pillH, br); ctx.stroke();
            ctx.fillStyle = '#ffd166';
            ctx.textBaseline = 'middle';
            ctx.fillText(tierText, leftX + px, curY + pillH / 2);
            ctx.textBaseline = 'alphabetic';
        }

        /* ---------- stats strip ---------- */
        const statItems = [];
        if (stats.wins    != null) statItems.push({ k: 'WINS',    v: String(stats.wins) });
        if (stats.podiums != null) statItems.push({ k: 'PODIUMS', v: String(stats.podiums) });
        if (stats.races   != null) statItems.push({ k: 'RACES',   v: String(stats.races) });

        if (statItems.length) {
            const stripY = H - 185, stripH = 138;
            const stripX = 28, stripW = W - 56;
            ctx.strokeStyle = 'rgba(255,209,102,0.22)'; ctx.lineWidth = 1;
            roundRect(ctx, stripX, stripY, stripW, stripH, 14); ctx.stroke();
            ctx.fillStyle = 'rgba(5,6,8,0.35)';
            roundRect(ctx, stripX, stripY, stripW, stripH, 14); ctx.fill();

            const colW = stripW / statItems.length;
            statItems.forEach((cell, i) => {
                const cx = stripX + colW * i + colW / 2;
                if (i > 0) {
                    ctx.strokeStyle = 'rgba(255,209,102,0.2)'; ctx.lineWidth = 1;
                    ctx.beginPath();
                    ctx.moveTo(stripX + colW * i, stripY + 24);
                    ctx.lineTo(stripX + colW * i, stripY + stripH - 24);
                    ctx.stroke();
                }
                ctx.fillStyle = '#ffd166';
                ctx.font = '900 62px "Anton", Impact, sans-serif';
                ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
                ctx.fillText(cell.v, cx, stripY + stripH / 2 - 10);
                ctx.fillStyle = 'rgba(148,163,184,0.8)';
                ctx.font = '700 17px "Orbitron", system-ui, sans-serif';
                ctx.textBaseline = 'alphabetic';
                ctx.fillText(cell.k, cx, stripY + stripH - 16);
            });
        }

        /* ---------- footer URL ---------- */
        ctx.fillStyle = 'rgba(148,163,184,0.5)';
        ctx.font = '700 22px "Orbitron", system-ui, sans-serif';
        ctx.textAlign = 'center'; ctx.textBaseline = 'alphabetic';
        setLS('0.15em');
        ctx.fillText('SPARKSTHEORY.CO.UK/ENDURANCE', W / 2, H - 22);
        setLS('0px');

        return canvas;
    }

    function canvasToBlob(canvas) {
        return new Promise((resolve) => canvas.toBlob((b) => resolve(b), 'image/png', 0.95));
    }

    /* ----------------------------------------------------------------
       Preview modal — paints the card into a centred dialog with
       explicit Download / Copy Image / Copy Link buttons (and a Share
       button that opens the native share sheet where it actually works
       properly, i.e. mobile + Android desktop). macOS Safari's share
       sheet only carries the URL not the file, so on desktop we lead
       with the explicit actions and only show Share when canShare is
       confident the file will travel with it.
    ----------------------------------------------------------------- */
    function injectModalStyles() {
        if (document.getElementById('gtec-share-modal-style')) return;
        const style = document.createElement('style');
        style.id = 'gtec-share-modal-style';
        style.textContent = `
            .gtec-share-overlay {
                position: fixed; inset: 0;
                background: rgba(0,0,0,0.78);
                backdrop-filter: blur(6px);
                z-index: 9999;
                display: flex; align-items: center; justify-content: center;
                padding: 1.25rem;
                opacity: 0; transition: opacity 0.15s ease;
            }
            .gtec-share-overlay.open { opacity: 1; }
            .gtec-share-modal {
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
            .gtec-share-head {
                display: flex; align-items: center; justify-content: space-between;
                margin-bottom: 0.85rem;
            }
            .gtec-share-title {
                font-family: 'Orbitron', sans-serif;
                font-size: 0.62rem; font-weight: 700; letter-spacing: 0.35em;
                text-transform: uppercase; color: var(--gold, #ffd166);
            }
            .gtec-share-close {
                background: transparent; border: none;
                color: var(--muted, #94a3b8);
                font-size: 1.4rem; line-height: 1;
                cursor: pointer; padding: 0.1rem 0.45rem;
                transition: color 0.15s ease;
            }
            .gtec-share-close:hover { color: var(--text, #f1f5f9); }
            .gtec-share-preview {
                width: 100%;
                aspect-ratio: 3 / 4;
                border-radius: 10px;
                overflow: hidden;
                margin-bottom: 1rem;
                border: 1px solid rgba(255,255,255,0.08);
            }
            .gtec-share-preview img { width: 100%; height: 100%; display: block; }
            .gtec-share-actions {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 0.5rem;
            }
            .gtec-share-action {
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
            .gtec-share-action:hover:not(:disabled) {
                background: rgba(255,209,102,0.08);
                border-color: rgba(255,209,102,0.45);
                transform: translateY(-1px);
            }
            .gtec-share-action.primary {
                background: linear-gradient(135deg, rgba(255,209,102,0.25), rgba(255,209,102,0.08));
                border-color: rgba(255,209,102,0.55);
                color: var(--gold, #ffd166);
                grid-column: 1 / -1;
            }
            .gtec-share-action.primary:hover:not(:disabled) {
                background: linear-gradient(135deg, rgba(255,209,102,0.4), rgba(255,209,102,0.15));
            }
            .gtec-share-action svg { width: 13px; height: 13px; }
            .gtec-share-action:disabled { opacity: 0.65; cursor: progress; }
            .gtec-share-hint {
                font-family: 'Inter', sans-serif;
                font-size: 0.72rem;
                color: var(--muted, #94a3b8);
                text-align: center;
                margin-top: 0.85rem;
                line-height: 1.45;
            }
            @media (max-width: 520px) {
                .gtec-share-actions { grid-template-columns: 1fr; }
            }
        `;
        document.head.appendChild(style);
    }

    function openModal({ blob, fname, url, driver }) {
        injectModalStyles();
        const previewUrl = URL.createObjectURL(blob);
        const overlay = document.createElement('div');
        overlay.className = 'gtec-share-overlay';

        const supportsShare = !!(navigator.share && navigator.canShare &&
            navigator.canShare({ files: [new File([blob], fname, { type: 'image/png' })] }));

        overlay.innerHTML = `
            <div class="gtec-share-modal" role="dialog" aria-label="Share driver card">
                <div class="gtec-share-head">
                    <div class="gtec-share-title">Share Driver Card</div>
                    <button class="gtec-share-close" data-act="close" aria-label="Close">✕</button>
                </div>
                <div class="gtec-share-preview"><img src="${previewUrl}" alt="${escAttr(driver.display_name || 'Driver')} — GTEC"></div>
                <div class="gtec-share-actions">
                    ${supportsShare ? `<button class="gtec-share-action primary" data-act="share">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/><polyline points="16 6 12 2 8 6"/><line x1="12" y1="2" x2="12" y2="15"/></svg>
                        Share…
                    </button>` : ''}
                    <button class="gtec-share-action" data-act="download">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                        Download
                    </button>
                    <button class="gtec-share-action" data-act="copy-image">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>
                        <span data-label="copy-image">Copy Image</span>
                    </button>
                    <button class="gtec-share-action" data-act="copy-link" style="${supportsShare ? '' : 'grid-column:1 / -1'}">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.07 0l3-3a5 5 0 0 0-7.07-7.07L11 5"/><path d="M14 11a5 5 0 0 0-7.07 0l-3 3a5 5 0 0 0 7.07 7.07L13 19"/></svg>
                        <span data-label="copy-link">Copy Link</span>
                    </button>
                </div>
                <div class="gtec-share-hint">Right-click or long-press the image to save it manually, or paste it into Discord / X / WhatsApp after Copy Image.</div>
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
                        title: `${driver.display_name} — GTEC`,
                        text:  `Check out my GTEC driver profile.`,
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

    function escAttr(s) {
        return String(s || '').replace(/"/g, '&quot;');
    }

    async function gtecShareCard({ driver, stats, buttonEl }) {
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
            const canvas = await drawCard(driver, stats);
            const blob   = await canvasToBlob(canvas);
            if (!blob) throw new Error('Canvas blob failed');

            const url   = SITE_URL + (driver.slug ? `drivers/?slug=${encodeURIComponent(driver.slug)}` : '');
            const fname = `${(driver.slug || driver.display_name || 'driver').replace(/[^a-z0-9-]/gi, '-').toLowerCase()}-gtec.png`;

            resetBtn();
            openModal({ blob, fname, url, driver });
        } catch (err) {
            console.error(err);
            setBtn('Share failed');
            setTimeout(resetBtn, 2000);
        }
    }

    window.gtecShareCard = gtecShareCard;
})();
