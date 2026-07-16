/* GTEC head-to-head comparison card — paints a 1080×1400 PNG of two
   drivers facing off and shares it via the Web Share API (or falls back
   to download / copy image / copy link). Self-contained sibling to
   gtec-share-card.js; only API surface is

       window.gtecCompareCard({
           a: { display_name, slug, photo_url, manufacturer_color },
           b: { display_name, slug, photo_url, manufacturer_color },
           rows: [ { label, va, vb, fmt } ],   // fmt optional, formats both
           buttonEl: <button> to show "Preparing…" / "Shared" on,
       });
*/
(function () {
    'use strict';

    const W = 1080;
    const H = 1400;
    const SITE_URL = 'https://sparkstheory.co.uk/endurance/';
    const GOLD = '#ffd166';

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

    function loadImage(url) {
        return new Promise((resolve) => {
            if (!url) return resolve(null);
            const img = new Image();
            img.crossOrigin = 'anonymous';
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

    // Draws one driver's half of the photo band (cover-fit photo, or a
    // large-initials placeholder tinted with their manufacturer colour).
    function drawHalf(ctx, driver, photo, x0, y0, w, h) {
        ctx.save();
        ctx.beginPath();
        ctx.rect(x0, y0, w, h);
        ctx.clip();

        if (photo) {
            const ar = photo.width / photo.height;
            const boxAr = w / h;
            let dw, dh, dx, dy;
            if (ar > boxAr) { dh = h; dw = dh * ar; dx = x0 - (dw - w) / 2; dy = y0; }
            else            { dw = w; dh = dw / ar; dx = x0; dy = y0 - (dh - h) / 2; }
            ctx.drawImage(photo, dx, dy, dw, dh);
        } else {
            ctx.fillStyle = '#0a0e15';
            ctx.fillRect(x0, y0, w, h);
            const ini = (driver.display_name || '?').split(/\s+/).slice(0, 2).map(s => s[0]).join('').toUpperCase();
            ctx.fillStyle = (driver.manufacturer_color || GOLD) + '22';
            ctx.font = '900 220px "Anton", Impact, sans-serif';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillText(ini, x0 + w / 2, y0 + h / 2);
            ctx.textBaseline = 'alphabetic';
        }

        // Bottom fade so the name plate below always reads clean.
        const fade = ctx.createLinearGradient(0, y0 + h * 0.55, 0, y0 + h);
        fade.addColorStop(0, 'rgba(5,6,8,0)');
        fade.addColorStop(1, 'rgba(5,6,8,0.95)');
        ctx.fillStyle = fade;
        ctx.fillRect(x0, y0, w, h);

        // Manufacturer-tinted colour wash, subtle, top of the half.
        if (driver.manufacturer_color) {
            const tint = ctx.createLinearGradient(0, y0, 0, y0 + h * 0.4);
            tint.addColorStop(0, driver.manufacturer_color + '33');
            tint.addColorStop(1, driver.manufacturer_color + '00');
            ctx.fillStyle = tint;
            ctx.fillRect(x0, y0, w, h * 0.4);
        }

        ctx.restore();
    }

    function fitText(ctx, text, maxWidth, startFs, minFs, weight, family) {
        let fs = startFs;
        while (fs > minFs) {
            ctx.font = `${weight} ${fs}px "${family}", Impact, sans-serif`;
            if (ctx.measureText(text).width <= maxWidth) break;
            fs -= 3;
        }
        return fs;
    }

    async function drawCard(a, b, rows) {
        const canvas = document.createElement('canvas');
        canvas.width = W; canvas.height = H;
        const ctx = canvas.getContext('2d');
        const hasLS = ('letterSpacing' in ctx);
        const setLS = (v) => { if (hasLS) ctx.letterSpacing = v; };

        ctx.fillStyle = '#050608';
        ctx.fillRect(0, 0, W, H);

        const [photoA, photoB] = await Promise.all([loadImage(a.photo_url), loadImage(b.photo_url)]);

        const bandY = 96, bandH = 620;
        drawHalf(ctx, a, photoA, 0, bandY, W / 2, bandH);
        drawHalf(ctx, b, photoB, W / 2, bandY, W / 2, bandH);

        // Centre seam
        ctx.fillStyle = 'rgba(5,6,8,0.9)';
        ctx.fillRect(W / 2 - 3, bandY, 6, bandH);

        /* ---------- GTEC wordmark ---------- */
        ctx.fillStyle = 'rgba(255,209,102,0.55)';
        ctx.font = '700 24px "Orbitron", system-ui, sans-serif';
        ctx.textAlign = 'center'; ctx.textBaseline = 'alphabetic';
        setLS('0.4em');
        ctx.fillText('GTEC HEAD-TO-HEAD', W / 2, 56);
        setLS('0px');

        /* ---------- VS medallion, centred on the seam ---------- */
        const vsCy = bandY + bandH / 2, vsR = 76;
        ctx.save();
        ctx.beginPath();
        ctx.arc(W / 2, vsCy, vsR, 0, Math.PI * 2);
        ctx.fillStyle = '#050608';
        ctx.fill();
        ctx.lineWidth = 4;
        ctx.strokeStyle = GOLD;
        ctx.stroke();
        ctx.fillStyle = GOLD;
        ctx.font = '900 56px "Anton", Impact, sans-serif';
        ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.fillText('VS', W / 2, vsCy + 4);
        ctx.textBaseline = 'alphabetic';
        ctx.restore();

        /* ---------- name plates ---------- */
        const plateY = bandY + bandH + 68;
        [{ d: a, cx: W / 4 }, { d: b, cx: (W / 4) * 3 }].forEach(({ d, cx }) => {
            const name = (d.display_name || '').toUpperCase();
            const fs = fitText(ctx, name, W / 2 - 48, 68, 34, 900, 'Anton');
            ctx.font = `900 ${fs}px "Anton", Impact, sans-serif`;
            ctx.fillStyle = '#f1f5f9';
            ctx.textAlign = 'center'; ctx.textBaseline = 'alphabetic';
            ctx.fillText(name, cx, plateY);
            if (d.manufacturer_color) {
                const tw = ctx.measureText(name).width;
                ctx.fillStyle = d.manufacturer_color;
                ctx.fillRect(cx - Math.min(tw, W / 2 - 48) / 2, plateY + 14, Math.min(tw, W / 2 - 48), 4);
            }
        });

        /* ---------- stats rows ---------- */
        let rowY = plateY + 76;
        const rowH = 74;
        const tableX = 48, tableW = W - 96;
        ctx.strokeStyle = 'rgba(255,209,102,0.22)'; ctx.lineWidth = 1;
        roundRect(ctx, tableX, rowY, tableW, rowH * rows.length, 14); ctx.stroke();
        ctx.fillStyle = 'rgba(255,255,255,0.02)';
        roundRect(ctx, tableX, rowY, tableW, rowH * rows.length, 14); ctx.fill();

        rows.forEach((row, i) => {
            const y = rowY + i * rowH;
            if (i > 0) {
                ctx.strokeStyle = 'rgba(255,255,255,0.06)'; ctx.lineWidth = 1;
                ctx.beginPath(); ctx.moveTo(tableX + 20, y); ctx.lineTo(tableX + tableW - 20, y); ctx.stroke();
            }
            const cy = y + rowH / 2;
            const fmt = row.fmt || (v => v);
            const aWin = Number(row.va) > Number(row.vb);
            const bWin = Number(row.vb) > Number(row.va);

            ctx.textBaseline = 'middle';

            // Space the two value columns out based on this row's own label
            // width, not a fixed offset — a wide label ("CURRENT RATING")
            // needs more clearance than a short one ("WINS"), and a fixed
            // offset let 4-digit ratings collide with the label text.
            ctx.font = '700 21px "Orbitron", system-ui, sans-serif';
            const labelText = row.label.toUpperCase();
            const labelHalfWidth = ctx.measureText(labelText).width / 2;
            const valueOffset = Math.max(100, labelHalfWidth + 32);

            ctx.fillStyle = 'rgba(148,163,184,0.85)';
            ctx.textAlign = 'center';
            ctx.fillText(labelText, W / 2, cy);

            ctx.font = '900 40px "Anton", Impact, sans-serif';
            ctx.fillStyle = aWin ? GOLD : '#f1f5f9';
            ctx.textAlign = 'right';
            ctx.fillText(String(fmt(row.va)), W / 2 - valueOffset, cy);

            ctx.fillStyle = bWin ? GOLD : '#f1f5f9';
            ctx.textAlign = 'left';
            ctx.fillText(String(fmt(row.vb)), W / 2 + valueOffset, cy);

            ctx.textBaseline = 'alphabetic';
        });

        /* ---------- footer ---------- */
        ctx.fillStyle = 'rgba(148,163,184,0.5)';
        ctx.font = '700 22px "Orbitron", system-ui, sans-serif';
        ctx.textAlign = 'center';
        setLS('0.15em');
        ctx.fillText('SPARKSTHEORY.CO.UK/ENDURANCE', W / 2, H - 30);
        setLS('0px');

        return canvas;
    }

    function canvasToBlob(canvas) {
        return new Promise((resolve) => canvas.toBlob((b) => resolve(b), 'image/png', 0.95));
    }

    /* ---------- share modal — same shape/behaviour as gtec-share-card.js ---------- */
    function injectModalStyles() {
        if (document.getElementById('gtec-compare-modal-style')) return;
        const style = document.createElement('style');
        style.id = 'gtec-compare-modal-style';
        style.textContent = `
            .gtec-cc-overlay {
                position: fixed; inset: 0;
                background: rgba(0,0,0,0.78);
                backdrop-filter: blur(6px);
                z-index: 9999;
                display: flex; align-items: center; justify-content: center;
                padding: 1.25rem;
                opacity: 0; transition: opacity 0.15s ease;
            }
            .gtec-cc-overlay.open { opacity: 1; }
            .gtec-cc-modal {
                background: var(--bg-1, #0a0e15);
                border: 1px solid rgba(255,209,102,0.35);
                border-radius: 14px;
                max-width: 460px; width: 100%; max-height: 92vh; overflow-y: auto;
                padding: 1.1rem 1.1rem 1.25rem;
                box-shadow: 0 20px 60px rgba(0,0,0,0.65);
                position: relative;
            }
            .gtec-cc-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.85rem; }
            .gtec-cc-title { font-family: 'Orbitron', sans-serif; font-size: 0.62rem; font-weight: 700; letter-spacing: 0.3em; text-transform: uppercase; color: var(--gold, #ffd166); }
            .gtec-cc-close { background: transparent; border: none; color: var(--muted, #94a3b8); font-size: 1.4rem; line-height: 1; cursor: pointer; padding: 0.1rem 0.45rem; transition: color 0.15s ease; }
            .gtec-cc-close:hover { color: var(--text, #f1f5f9); }
            .gtec-cc-preview { width: 100%; aspect-ratio: ${W} / ${H}; border-radius: 10px; overflow: hidden; margin-bottom: 1rem; border: 1px solid rgba(255,255,255,0.08); }
            .gtec-cc-preview img { width: 100%; height: 100%; display: block; }
            .gtec-cc-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
            .gtec-cc-action { display: inline-flex; align-items: center; justify-content: center; gap: 0.4rem; padding: 0.7rem 0.85rem; background: var(--bg-2, #11161f); border: 1px solid rgba(255,255,255,0.1); border-radius: 8px; color: var(--text, #f1f5f9); font-family: 'Orbitron', sans-serif; font-size: 0.58rem; font-weight: 700; letter-spacing: 0.18em; text-transform: uppercase; cursor: pointer; transition: background 0.15s ease, border-color 0.15s ease, transform 0.1s ease; }
            .gtec-cc-action:hover:not(:disabled) { background: rgba(255,209,102,0.08); border-color: rgba(255,209,102,0.45); transform: translateY(-1px); }
            .gtec-cc-action.primary { background: linear-gradient(135deg, rgba(255,209,102,0.25), rgba(255,209,102,0.08)); border-color: rgba(255,209,102,0.55); color: var(--gold, #ffd166); grid-column: 1 / -1; }
            .gtec-cc-action.primary:hover:not(:disabled) { background: linear-gradient(135deg, rgba(255,209,102,0.4), rgba(255,209,102,0.15)); }
            .gtec-cc-action svg { width: 13px; height: 13px; }
            .gtec-cc-action:disabled { opacity: 0.65; cursor: progress; }
            .gtec-cc-hint { font-family: 'Inter', sans-serif; font-size: 0.72rem; color: var(--muted, #94a3b8); text-align: center; margin-top: 0.85rem; line-height: 1.45; }
            @media (max-width: 520px) { .gtec-cc-actions { grid-template-columns: 1fr; } }
        `;
        document.head.appendChild(style);
    }

    function openModal({ blob, fname, url, a, b }) {
        injectModalStyles();
        const previewUrl = URL.createObjectURL(blob);
        const overlay = document.createElement('div');
        overlay.className = 'gtec-cc-overlay';

        const supportsShare = !!(navigator.share && navigator.canShare &&
            navigator.canShare({ files: [new File([blob], fname, { type: 'image/png' })] }));

        const escAttr = (s) => String(s || '').replace(/"/g, '&quot;');

        overlay.innerHTML = `
            <div class="gtec-cc-modal" role="dialog" aria-label="Share comparison card">
                <div class="gtec-cc-head">
                    <div class="gtec-cc-title">Share Comparison</div>
                    <button class="gtec-cc-close" data-act="close" aria-label="Close">✕</button>
                </div>
                <div class="gtec-cc-preview"><img src="${previewUrl}" alt="${escAttr(a.display_name)} vs ${escAttr(b.display_name)} — GTEC"></div>
                <div class="gtec-cc-actions">
                    ${supportsShare ? `<button class="gtec-cc-action primary" data-act="share">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/><polyline points="16 6 12 2 8 6"/><line x1="12" y1="2" x2="12" y2="15"/></svg>
                        Share…
                    </button>` : ''}
                    <button class="gtec-cc-action" data-act="download">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                        Download
                    </button>
                    <button class="gtec-cc-action" data-act="copy-image">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>
                        <span data-label="copy-image">Copy Image</span>
                    </button>
                    <button class="gtec-cc-action" data-act="copy-link" style="${supportsShare ? '' : 'grid-column:1 / -1'}">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.07 0l3-3a5 5 0 0 0-7.07-7.07L11 5"/><path d="M14 11a5 5 0 0 0-7.07 0l-3 3a5 5 0 0 0 7.07 7.07L13 19"/></svg>
                        <span data-label="copy-link">Copy Link</span>
                    </button>
                </div>
                <div class="gtec-cc-hint">Right-click or long-press the image to save it manually, or paste it into Discord / X / WhatsApp after Copy Image.</div>
            </div>
        `;

        document.body.appendChild(overlay);
        requestAnimationFrame(() => overlay.classList.add('open'));

        const close = () => {
            overlay.classList.remove('open');
            setTimeout(() => { overlay.remove(); URL.revokeObjectURL(previewUrl); }, 150);
        };
        overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });

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
                const link = document.createElement('a');
                link.href = previewUrl;
                link.download = fname;
                document.body.appendChild(link);
                link.click();
                link.remove();
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
                        title: `${a.display_name} vs ${b.display_name} — GTEC`,
                        text: `Head-to-head: ${a.display_name} vs ${b.display_name} on GTEC.`,
                        files: [file],
                        url,
                    });
                } catch (err) {
                    if (!err || err.name !== 'AbortError') console.warn('Share failed', err);
                }
                return;
            }
        });

        document.addEventListener('keydown', function onEsc(e) {
            if (e.key === 'Escape') { document.removeEventListener('keydown', onEsc); close(); }
        });
    }

    async function gtecCompareCard({ a, b, rows, buttonEl }) {
        const restore = buttonEl ? buttonEl.innerHTML : null;
        const setBtn = (txt) => { if (buttonEl) { buttonEl.disabled = true; buttonEl.innerHTML = txt; } };
        const resetBtn = () => { if (buttonEl) { buttonEl.disabled = false; buttonEl.innerHTML = restore; } };

        try {
            setBtn('Building card…');
            await ensureFonts();
            const canvas = await drawCard(a, b, rows);
            const blob = await canvasToBlob(canvas);
            if (!blob) throw new Error('Canvas blob failed');

            const url = `${SITE_URL}stats/`;
            const fname = `${(a.slug || 'a')}-vs-${(b.slug || 'b')}-gtec.png`;

            resetBtn();
            openModal({ blob, fname, url, a, b });
        } catch (err) {
            console.error(err);
            setBtn('Share failed');
            setTimeout(resetBtn, 2000);
        }
    }

    window.gtecCompareCard = gtecCompareCard;
})();
