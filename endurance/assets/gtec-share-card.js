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
    const H = 1080;
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

        /* ---------- background ---------- */
        const bg = ctx.createLinearGradient(0, 0, 0, H);
        bg.addColorStop(0,    '#0a0e15');
        bg.addColorStop(1,    '#050608');
        ctx.fillStyle = bg;
        ctx.fillRect(0, 0, W, H);

        // Subtle starfield speckle for texture.
        ctx.fillStyle = 'rgba(255,209,102,0.18)';
        for (let i = 0; i < 90; i++) {
            const x = Math.random() * W;
            const y = Math.random() * H;
            const r = Math.random() * 1.5 + 0.4;
            ctx.beginPath();
            ctx.arc(x, y, r, 0, Math.PI * 2);
            ctx.fill();
        }

        // Inner gold rim.
        ctx.strokeStyle = 'rgba(255,209,102,0.32)';
        ctx.lineWidth = 2;
        roundRect(ctx, 40, 40, W - 80, H - 80, 36);
        ctx.stroke();

        /* ---------- top bar: GTEC + tagline ---------- */
        const logo = await loadImage('/endurance/assets/gtec-logo.png');
        if (logo) {
            const lw = 360, lh = lw * (logo.height / logo.width);
            ctx.drawImage(logo, (W - lw) / 2, 80, lw, lh);
        }
        ctx.fillStyle = 'rgba(148,163,184,0.7)';
        ctx.font = '800 22px "Orbitron", system-ui, sans-serif';
        ctx.textAlign = 'center';
        ctx.letterSpacing = '0.35em';
        ctx.fillText('A GRAN TURISMO 7 ENDURANCE CHAMPIONSHIP', W / 2, 200);

        /* ---------- driver photo ---------- */
        const photoR  = 150;
        const photoCx = W / 2;
        const photoCy = 380;
        const photo   = driver.photo_url ? await loadImage(driver.photo_url) : null;

        // Gold halo ring.
        ctx.strokeStyle = 'rgba(255,209,102,0.85)';
        ctx.lineWidth = 4;
        ctx.beginPath();
        ctx.arc(photoCx, photoCy, photoR + 8, 0, Math.PI * 2);
        ctx.stroke();

        ctx.save();
        ctx.beginPath();
        ctx.arc(photoCx, photoCy, photoR, 0, Math.PI * 2);
        ctx.closePath();
        ctx.clip();
        if (photo) {
            // Cover-fit
            const ar = photo.width / photo.height;
            let dw, dh;
            if (ar > 1) { dh = photoR * 2; dw = dh * ar; }
            else        { dw = photoR * 2; dh = dw / ar; }
            ctx.drawImage(photo, photoCx - dw / 2, photoCy - dh / 2, dw, dh);
        } else {
            // Initials avatar fallback.
            ctx.fillStyle = '#11161f';
            ctx.fillRect(photoCx - photoR, photoCy - photoR, photoR * 2, photoR * 2);
            ctx.fillStyle = '#ffd166';
            ctx.font = '900 120px "Anton", Impact, sans-serif';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            const initials = (driver.display_name || '?').split(/\s+/).slice(0, 2).map(s => s[0]).join('').toUpperCase();
            ctx.fillText(initials, photoCx, photoCy + 4);
        }
        ctx.restore();
        ctx.textBaseline = 'alphabetic';

        /* ---------- career number badge (top-right of photo) ---------- */
        if (driver.career_number != null) {
            const numText = '#' + driver.career_number;
            // Auto-size the coin so a 3-digit number doesn't blow it out
            // and a 1-digit number doesn't leave a yawning gap.
            let coinR  = 32;
            let coinFs = 26;
            if (numText.length === 4) { coinR = 36; coinFs = 24; }  // e.g. #888
            if (numText.length >= 5)  { coinR = 40; coinFs = 22; }  // 4-digit numbers
            const numCx = photoCx + photoR - coinR + 24;
            const numCy = photoCy - photoR + coinR - 8;
            // Dark inner ring so the coin reads as separate from the halo.
            ctx.fillStyle = '#0a0e15';
            ctx.beginPath();
            ctx.arc(numCx, numCy, coinR + 3, 0, Math.PI * 2);
            ctx.fill();
            ctx.fillStyle = '#ffd166';
            ctx.beginPath();
            ctx.arc(numCx, numCy, coinR, 0, Math.PI * 2);
            ctx.fill();
            ctx.fillStyle = '#1a1300';
            ctx.font = `900 ${coinFs}px "Anton", Impact, sans-serif`;
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillText(numText, numCx, numCy + 1);
            ctx.textBaseline = 'alphabetic';
        }

        /* ---------- driver name + tags ---------- */
        ctx.fillStyle = '#f1f5f9';
        ctx.textAlign = 'center';
        ctx.font = '900 96px "Anton", Impact, sans-serif';
        // Auto-shrink the name to fit if it's too long.
        let nameFs = 96;
        let nameText = (driver.display_name || '').toUpperCase();
        while (nameFs > 48) {
            ctx.font = `900 ${nameFs}px "Anton", Impact, sans-serif`;
            if (ctx.measureText(nameText).width < W - 160) break;
            nameFs -= 4;
        }
        ctx.fillText(nameText, W / 2, photoCy + photoR + 110);

        // Country flag + team / manufacturer line.
        const tagParts = [];
        if (driver.nationality)       tagParts.push(driver.nationality);
        if (driver.team_name)         tagParts.push(driver.team_name);
        if (driver.manufacturer_name) tagParts.push(driver.manufacturer_name);
        const tagLine = tagParts.join('  ·  ');
        ctx.fillStyle = 'rgba(148,163,184,0.95)';
        ctx.font = '600 26px "Inter", system-ui, sans-serif';
        ctx.fillText(tagLine, W / 2, photoCy + photoR + 160);

        /* ---------- stats grid ---------- */
        const grid = [];
        if (stats.elo != null)     grid.push({ k: 'ELO',     v: String(stats.elo),     sub: stats.tier || '' });
        if (stats.points != null)  grid.push({ k: 'POINTS',  v: String(stats.points) });
        if (stats.wins != null)    grid.push({ k: 'WINS',    v: String(stats.wins) });
        if (stats.podiums != null) grid.push({ k: 'PODIUMS', v: String(stats.podiums) });
        if (stats.races != null)   grid.push({ k: 'RACES',   v: String(stats.races) });

        const gridY     = photoCy + photoR + 230;
        const gridH     = 200;
        const colCount  = grid.length || 1;
        const colW      = (W - 160) / colCount;

        // Frame.
        ctx.strokeStyle = 'rgba(255,209,102,0.35)';
        ctx.lineWidth = 1.5;
        roundRect(ctx, 80, gridY, W - 160, gridH, 18);
        ctx.stroke();

        const maxW = colW - 30;
        const eloIdx = grid.findIndex(c => c.k === 'ELO');
        const hasLetterSpacing = ('letterSpacing' in ctx);

        // Helper: measure a value with the right kerning for its column.
        // ELO uses tighter letter-spacing so a 4-digit number fits at
        // roughly the same visual size as the single-digit values.
        const measureVal = (text, fs, tight) => {
            ctx.font = `900 ${fs}px "Anton", Impact, sans-serif`;
            if (hasLetterSpacing) ctx.letterSpacing = tight ? '-2px' : '0px';
            const w = ctx.measureText(text).width;
            if (hasLetterSpacing) ctx.letterSpacing = '0px';
            return w;
        };

        // Pick a single font size that lets *every* value fit, so the
        // ELO doesn't end up much smaller than the WINS / PODIUMS cells
        // because of auto-shrink. Start big, shrink uniformly.
        let valFs = 78;
        while (valFs > 36) {
            const allFit = grid.every((c, idx) => measureVal(c.v, valFs, idx === eloIdx) <= maxW);
            if (allFit) break;
            valFs -= 2;
        }

        grid.forEach((cell, i) => {
            const cx = 80 + colW * i + colW / 2;
            // Divider line (skip on first cell). Made more prominent —
            // the previous 0.18 alpha was so faint it disappeared, so
            // long Elo values flowed visually into the next cell.
            if (i > 0) {
                ctx.strokeStyle = 'rgba(255,209,102,0.32)';
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.moveTo(80 + colW * i, gridY + 30);
                ctx.lineTo(80 + colW * i, gridY + gridH - 30);
                ctx.stroke();
            }
            // Value — uniform font size across every cell, with tighter
            // kerning on the ELO so its 4-digit number reads at the same
            // visual size as the single-digit ones beside it.
            const tight = (i === eloIdx);
            ctx.font = `900 ${valFs}px "Anton", Impact, sans-serif`;
            if (hasLetterSpacing) ctx.letterSpacing = tight ? '-2px' : '0px';
            ctx.fillStyle = '#ffd166';
            ctx.textAlign = 'center';
            ctx.fillText(cell.v, cx, gridY + 108);
            if (hasLetterSpacing) ctx.letterSpacing = '0px';
            // Label
            ctx.fillStyle = 'rgba(148,163,184,0.85)';
            ctx.font = '800 18px "Orbitron", system-ui, sans-serif';
            ctx.fillText(cell.k, cx, gridY + 148);
            // Optional sub-line (tier under Elo) — auto-shrink too.
            if (cell.sub) {
                let subFs = 16;
                ctx.font = `700 ${subFs}px "Orbitron", system-ui, sans-serif`;
                while (ctx.measureText(cell.sub.toUpperCase()).width > maxW && subFs > 10) {
                    subFs -= 1;
                    ctx.font = `700 ${subFs}px "Orbitron", system-ui, sans-serif`;
                }
                ctx.fillStyle = 'rgba(255,209,102,0.85)';
                ctx.fillText(cell.sub.toUpperCase(), cx, gridY + 174);
            }
        });

        /* ---------- footer URL ---------- */
        ctx.fillStyle = 'rgba(148,163,184,0.7)';
        ctx.font = '700 24px "Orbitron", system-ui, sans-serif';
        ctx.textAlign = 'center';
        ctx.fillText('SPARKSTHEORY.CO.UK/ENDURANCE', W / 2, H - 80);

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
                aspect-ratio: 1 / 1;
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
