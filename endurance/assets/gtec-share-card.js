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
            const numCx = photoCx + photoR + 8;
            const numCy = photoCy - photoR + 28;
            ctx.fillStyle = '#ffd166';
            ctx.beginPath();
            ctx.arc(numCx, numCy, 44, 0, Math.PI * 2);
            ctx.fill();
            ctx.fillStyle = '#1a1300';
            ctx.font = '900 38px "Anton", Impact, sans-serif';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillText('#' + driver.career_number, numCx, numCy + 2);
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

        grid.forEach((cell, i) => {
            const cx = 80 + colW * i + colW / 2;
            // Divider line (skip on first cell).
            if (i > 0) {
                ctx.strokeStyle = 'rgba(255,209,102,0.18)';
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.moveTo(80 + colW * i, gridY + 30);
                ctx.lineTo(80 + colW * i, gridY + gridH - 30);
                ctx.stroke();
            }
            // Value
            ctx.fillStyle = '#ffd166';
            ctx.font = '900 84px "Anton", Impact, sans-serif';
            ctx.textAlign = 'center';
            ctx.fillText(cell.v, cx, gridY + 110);
            // Label
            ctx.fillStyle = 'rgba(148,163,184,0.85)';
            ctx.font = '800 20px "Orbitron", system-ui, sans-serif';
            ctx.fillText(cell.k, cx, gridY + 150);
            // Optional sub-line (tier under Elo)
            if (cell.sub) {
                ctx.fillStyle = 'rgba(255,209,102,0.85)';
                ctx.font = '700 18px "Orbitron", system-ui, sans-serif';
                ctx.fillText(cell.sub.toUpperCase(), cx, gridY + 178);
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
            const file  = new File([blob], fname, { type: 'image/png' });

            // Prefer Web Share so the system sheet lets the user pick the
            // target app (Discord, X, Insta, WhatsApp etc.) with the image
            // already attached.
            if (navigator.canShare && navigator.canShare({ files: [file] })) {
                setBtn('Sharing…');
                try {
                    await navigator.share({
                        title: `${driver.display_name} — GTEC`,
                        text:  `Check out my GTEC driver profile.`,
                        files: [file],
                        url:   url,
                    });
                    setBtn('Shared');
                    setTimeout(resetBtn, 1800);
                    return;
                } catch (err) {
                    // User cancelled — silently restore.
                    if (err && err.name === 'AbortError') { resetBtn(); return; }
                    // Any other error → fall through to the download path.
                }
            }

            // Fallback: download the card and copy the public URL.
            const a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = fname;
            document.body.appendChild(a);
            a.click();
            a.remove();
            setTimeout(() => URL.revokeObjectURL(a.href), 5000);
            try { await navigator.clipboard?.writeText(url); } catch (_) {/* ignore */}
            setBtn('Saved · URL copied');
            setTimeout(resetBtn, 2400);
        } catch (err) {
            console.error(err);
            setBtn('Share failed');
            setTimeout(resetBtn, 2000);
        }
    }

    window.gtecShareCard = gtecShareCard;
})();
