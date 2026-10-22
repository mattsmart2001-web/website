/* GTEC team crests - generative, deterministic from the team name. Same
   name always produces the exact same crest, forever; rename the team and
   it changes for good. No stored images, no admin step: every team gets
   one automatically, including one created five minutes ago.

       const canvas = window.gtecRenderCrest('Northgate Racing', 96);
       el.appendChild(canvas);

   Returns a fresh <canvas> sized size×size with the crest drawn on it -
   append it into the DOM directly, or draw it onto another canvas with
   ctx.drawImage(canvas, x, y, w, h) (used by the trading-card renderer). */
(function () {
    'use strict';

    /* ---------- deterministic hash + PRNG ---------- */
    function hashStr(s) {
        let h = 5381;
        for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
        return h >>> 0;
    }
    function mulberry32(seed) {
        return function () {
            seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
            let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
            t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
    }
    function pick(rand, arr) { return arr[Math.floor(rand() * arr.length)]; }

    const PALETTE = [
        ['#b91c1c', '#450a0a'], ['#1e3a5f', '#0c1e33'], ['#3f6212', '#1a2e05'],
        ['#854d0e', '#422006'], ['#4c1d95', '#1e0a3c'], ['#0f766e', '#042f2e'],
        ['#7c2d12', '#431407'], ['#334155', '#0f172a'],
    ];

    function shade(hex, pct) {
        const n = parseInt(hex.slice(1), 16);
        let r = (n >> 16) + Math.round(255 * pct);
        let g = ((n >> 8) & 0xff) + Math.round(255 * pct);
        let b = (n & 0xff) + Math.round(255 * pct);
        r = Math.max(0, Math.min(255, r)); g = Math.max(0, Math.min(255, g)); b = Math.max(0, Math.min(255, b));
        return '#' + ((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1);
    }

    function initialsFor(name) {
        const words = name.trim().split(/\s+/).filter(Boolean);
        if (!words.length) return 'GT';
        if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
        return (words[0][0] + words[1][0]).toUpperCase();
    }

    function crestParams(name) {
        const clean = (name || 'GTEC').trim() || 'GTEC';
        const seed = hashStr(clean.toLowerCase());
        const rand = mulberry32(seed);
        const [c1, c2] = pick(rand, PALETTE);
        return {
            seed, clean,
            shield: pick(rand, ['heater', 'rounded', 'swiss', 'chevron', 'roundel']),
            division: pick(rand, ['solid', 'pale', 'fess', 'bend', 'bendSin', 'quarterly']),
            topDevice: pick(rand, ['chiefMullets', 'chiefMullets', 'checkerCanton', 'none']),
            chiefMarks: 3 + Math.floor(rand() * 4),
            stripes: rand() > 0.6,
            stripeW: 0.05 + rand() * 0.035,
            stripeGap: 0.03 + rand() * 0.05,
            bordure: rand() > 0.28,
            bordureDash: pick(rand, [[2, 3], [1, 2], [3, 2], [1, 1]]),
            charge: pick(rand, ['star', 'diamond', 'ring', 'bolt', 'bar', 'cog', 'laurel', 'wing', 'wheel', 'flags', 'speed', 'numberBadge']),
            satellites: Math.floor(rand() * 4),
            satCharge: pick(rand, ['star', 'diamond', 'ring']),
            c1, c2,
            c3: shade(c1, rand() > 0.5 ? 0.3 : -0.24),
            flip: rand() > 0.5,
            initials: initialsFor(clean),
        };
    }

    function shieldPath(ctx, kind, w, h) {
        const x0 = w * 0.5, top = h * 0.06, midY = h * 0.55, botY = h * 0.94;
        ctx.beginPath();
        if (kind === 'heater') {
            ctx.moveTo(w * 0.08, top);
            ctx.lineTo(w * 0.92, top);
            ctx.lineTo(w * 0.92, midY);
            ctx.quadraticCurveTo(w * 0.92, h * 0.8, x0, botY);
            ctx.quadraticCurveTo(w * 0.08, h * 0.8, w * 0.08, midY);
            ctx.closePath();
        } else if (kind === 'rounded') {
            ctx.moveTo(w * 0.1, top + h * 0.04);
            ctx.quadraticCurveTo(x0, top - h * 0.02, w * 0.9, top + h * 0.04);
            ctx.lineTo(w * 0.9, midY);
            ctx.quadraticCurveTo(x0, botY, w * 0.1, midY);
            ctx.closePath();
        } else if (kind === 'swiss') {
            ctx.moveTo(w * 0.1, top);
            ctx.lineTo(w * 0.9, top);
            ctx.lineTo(w * 0.9, h * 0.86);
            ctx.lineTo(x0, botY);
            ctx.lineTo(w * 0.1, h * 0.86);
            ctx.closePath();
        } else if (kind === 'roundel') {
            ctx.arc(x0, h * 0.5, Math.min(w, h) * 0.44, 0, Math.PI * 2);
            ctx.closePath();
        } else { /* chevron */
            ctx.moveTo(w * 0.08, top);
            ctx.lineTo(w * 0.92, top);
            ctx.lineTo(w * 0.92, h * 0.62);
            ctx.lineTo(x0, botY);
            ctx.lineTo(w * 0.08, h * 0.62);
            ctx.closePath();
        }
    }

    /* ---------- field: a two-tone division, heraldry-style ---------- */
    function drawField(ctx, p, w, h) {
        const g1 = p.c1, g2 = p.c2;
        switch (p.division) {
            case 'pale':
                ctx.fillStyle = g1; ctx.fillRect(0, 0, w / 2, h);
                ctx.fillStyle = g2; ctx.fillRect(w / 2, 0, w / 2, h);
                break;
            case 'fess':
                ctx.fillStyle = g1; ctx.fillRect(0, 0, w, h / 2);
                ctx.fillStyle = g2; ctx.fillRect(0, h / 2, w, h / 2);
                break;
            case 'bend':
                ctx.fillStyle = g1; ctx.fillRect(0, 0, w, h);
                ctx.fillStyle = g2;
                ctx.beginPath(); ctx.moveTo(w, 0); ctx.lineTo(w, h); ctx.lineTo(0, h); ctx.closePath(); ctx.fill();
                break;
            case 'bendSin':
                ctx.fillStyle = g1; ctx.fillRect(0, 0, w, h);
                ctx.fillStyle = g2;
                ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(w, 0); ctx.lineTo(0, h); ctx.closePath(); ctx.fill();
                break;
            case 'quarterly':
                ctx.fillStyle = g1; ctx.fillRect(0, 0, w, h);
                ctx.fillStyle = g2;
                ctx.fillRect(0, 0, w / 2, h / 2); ctx.fillRect(w / 2, h / 2, w / 2, h / 2);
                break;
            default: {
                const g = ctx.createLinearGradient(0, 0, p.flip ? w : 0, p.flip ? 0 : h);
                g.addColorStop(0, g1); g.addColorStop(1, g2);
                ctx.fillStyle = g; ctx.fillRect(0, 0, w, h);
            }
        }
    }

    /* ---------- racing livery stripes down the middle, Gulf/Martini-style ---------- */
    function drawStripes(ctx, p, w, h) {
        if (!p.stripes) return;
        const cx = w * 0.5, stripeW = w * p.stripeW, gap = w * p.stripeGap;
        ctx.fillStyle = 'rgba(255,209,102,0.94)';
        ctx.fillRect(cx - gap / 2 - stripeW, 0, stripeW, h);
        ctx.fillRect(cx + gap / 2, 0, stripeW, h);
        ctx.fillStyle = 'rgba(5,6,8,0.55)';
        ctx.fillRect(cx - gap / 2 - stripeW * 1.7, 0, stripeW * 0.4, h);
        ctx.fillRect(cx + gap / 2 + stripeW * 1.3, 0, stripeW * 0.4, h);
    }

    function drawChecker(ctx, x, y, w, h, cells, c1, c2) {
        const cw = w / cells, ch = h / cells;
        for (let iy = 0; iy < cells; iy++) {
            for (let ix = 0; ix < cells; ix++) {
                ctx.fillStyle = (ix + iy) % 2 === 0 ? c1 : c2;
                ctx.fillRect(x + ix * cw, y + iy * ch, cw + 0.5, ch + 0.5);
            }
        }
    }

    /* ---------- top-left device: a chief band of stars, or a literal
       black/white chequered-flag canton - the one unmistakably "racing" mark
       regardless of the team's own colours ---------- */
    function drawTopDevice(ctx, p, w, h) {
        if (p.topDevice === 'chiefMullets') {
            const bandH = h * 0.22;
            ctx.fillStyle = p.c3;
            ctx.fillRect(0, 0, w, bandH);
            ctx.strokeStyle = 'rgba(0,0,0,0.28)'; ctx.lineWidth = w * 0.008;
            ctx.beginPath(); ctx.moveTo(0, bandH); ctx.lineTo(w, bandH); ctx.stroke();
            const n = p.chiefMarks, pad = w * 0.16;
            for (let i = 0; i < n; i++) {
                const t = n === 1 ? 0.5 : i / (n - 1);
                drawMullet(ctx, pad + (w - pad * 2) * t, bandH * 0.52, bandH * 0.24, 'rgba(255,209,102,0.92)');
            }
        } else if (p.topDevice === 'checkerCanton') {
            const cw = w * 0.4, ch = h * 0.32;
            drawChecker(ctx, 0, 0, cw, ch, 5, '#f1f5f9', '#0b0e14');
            ctx.strokeStyle = 'rgba(255,209,102,0.85)'; ctx.lineWidth = w * 0.014;
            ctx.strokeRect(0, 0, cw, ch);
        }
    }

    /* ---------- a dashed inset ring, on a fraction of the crests ---------- */
    function drawBordure(ctx, p, kind, w, h) {
        if (!p.bordure) return;
        ctx.save();
        const scale = 0.9, ox = w * (1 - scale) / 2, oy = h * (1 - scale) / 2;
        ctx.translate(ox, oy); ctx.scale(scale, scale);
        shieldPath(ctx, kind, w, h);
        ctx.restore();
        ctx.setLineDash(p.bordureDash.map(v => v * (w / 38)));
        ctx.lineWidth = w * 0.014;
        ctx.strokeStyle = 'rgba(255,209,102,0.75)';
        ctx.stroke();
        ctx.setLineDash([]);
    }

    function drawMullet(ctx, cx, cy, r, color) {
        ctx.fillStyle = color;
        ctx.beginPath();
        for (let i = 0; i < 5; i++) {
            const a = -Math.PI / 2 + i * (Math.PI * 2 / 5);
            const a2 = a + Math.PI / 5;
            ctx.lineTo(cx + Math.cos(a) * r, cy + Math.sin(a) * r);
            ctx.lineTo(cx + Math.cos(a2) * r * 0.42, cy + Math.sin(a2) * r * 0.42);
        }
        ctx.closePath(); ctx.fill();
    }

    function drawLaurelSide(ctx, cx, cy, r, dir, color) {
        ctx.strokeStyle = color; ctx.fillStyle = color; ctx.lineWidth = r * 0.1;
        ctx.beginPath();
        ctx.moveTo(cx, cy + r * 0.9);
        ctx.quadraticCurveTo(cx + dir * r * 0.9, cy + r * 0.6, cx + dir * r * 0.55, cy - r * 0.8);
        ctx.stroke();
        for (let i = 0; i < 5; i++) {
            const t = 0.15 + i * 0.17;
            const lx = cx + dir * r * (0.2 + t * 0.75), ly = cy + r * 0.85 - t * r * 1.6;
            ctx.beginPath();
            ctx.ellipse(lx, ly, r * 0.16, r * 0.08, dir * (-0.6 + t * 0.3), 0, Math.PI * 2);
            ctx.fill();
        }
    }

    function drawCharge(ctx, kind, cx, cy, r, color, opts) {
        opts = opts || {};
        ctx.fillStyle = color; ctx.strokeStyle = color; ctx.lineWidth = r * 0.22;
        if (kind === 'star') {
            drawMullet(ctx, cx, cy, r, color);
        } else if (kind === 'diamond') {
            ctx.beginPath();
            ctx.moveTo(cx, cy - r); ctx.lineTo(cx + r * 0.72, cy); ctx.lineTo(cx, cy + r); ctx.lineTo(cx - r * 0.72, cy);
            ctx.closePath(); ctx.fill();
        } else if (kind === 'ring') {
            ctx.lineWidth = r * 0.26;
            ctx.beginPath(); ctx.arc(cx, cy, r * 0.62, 0, Math.PI * 2); ctx.stroke();
        } else if (kind === 'bolt') {
            ctx.beginPath();
            ctx.moveTo(cx + r * 0.15, cy - r); ctx.lineTo(cx - r * 0.45, cy + r * 0.1); ctx.lineTo(cx - r * 0.05, cy + r * 0.1);
            ctx.lineTo(cx - r * 0.15, cy + r); ctx.lineTo(cx + r * 0.45, cy - r * 0.1); ctx.lineTo(cx + r * 0.05, cy - r * 0.1);
            ctx.closePath(); ctx.fill();
        } else if (kind === 'bar') {
            ctx.fillRect(cx - r * 0.75, cy - r * 0.22, r * 1.5, r * 0.44);
        } else if (kind === 'cog') {
            const teeth = 8, inner = r * 0.55, outer = r;
            ctx.beginPath();
            for (let i = 0; i < teeth * 2; i++) {
                const a = (Math.PI * 2 / (teeth * 2)) * i;
                const rr = i % 2 === 0 ? outer : inner * 1.12;
                ctx.lineTo(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr);
            }
            ctx.closePath(); ctx.fill();
            ctx.save(); ctx.globalCompositeOperation = 'destination-out';
            ctx.beginPath(); ctx.arc(cx, cy, inner * 0.5, 0, Math.PI * 2); ctx.fill();
            ctx.restore();
        } else if (kind === 'laurel') {
            drawLaurelSide(ctx, cx, cy, r, -1, color);
            drawLaurelSide(ctx, cx, cy, r, 1, color);
        } else if (kind === 'wing') { /* a rear aero wing, not a bird */
            const wingW = r * 2.0, wingH = r * 0.3;
            ctx.fillRect(cx - wingW / 2, cy - wingH / 2, wingW, wingH);
            ctx.fillRect(cx - wingW / 2 - r * 0.07, cy - r * 0.55, r * 0.14, r * 1.0);
            ctx.fillRect(cx + wingW / 2 - r * 0.07, cy - r * 0.55, r * 0.14, r * 1.0);
            ctx.fillRect(cx - r * 0.09, cy + wingH / 2, r * 0.18, r * 0.55);
        } else if (kind === 'wheel') {
            ctx.lineWidth = r * 0.22; ctx.strokeStyle = color;
            ctx.beginPath(); ctx.arc(cx, cy, r * 0.88, 0, Math.PI * 2); ctx.stroke();
            ctx.lineWidth = r * 0.12;
            ctx.beginPath(); ctx.arc(cx, cy, r * 0.46, 0, Math.PI * 2); ctx.stroke();
            for (let i = 0; i < 5; i++) {
                const a = i * (Math.PI * 2 / 5) - Math.PI / 2;
                ctx.lineWidth = r * 0.09;
                ctx.beginPath();
                ctx.moveTo(cx + Math.cos(a) * r * 0.12, cy + Math.sin(a) * r * 0.12);
                ctx.lineTo(cx + Math.cos(a) * r * 0.45, cy + Math.sin(a) * r * 0.45);
                ctx.stroke();
            }
            ctx.fillStyle = color;
            ctx.beginPath(); ctx.arc(cx, cy, r * 0.11, 0, Math.PI * 2); ctx.fill();
        } else if (kind === 'flags') {
            drawMiniFlag(ctx, cx, cy, r, -0.4);
            drawMiniFlag(ctx, cx, cy, r, 0.4);
        } else if (kind === 'speed') {
            ctx.beginPath();
            ctx.moveTo(cx + r * 0.95, cy);
            ctx.lineTo(cx - r * 0.05, cy - r * 0.7);
            ctx.lineTo(cx - r * 0.42, cy - r * 0.7);
            ctx.lineTo(cx + r * 0.38, cy);
            ctx.lineTo(cx - r * 0.42, cy + r * 0.7);
            ctx.lineTo(cx - r * 0.05, cy + r * 0.7);
            ctx.closePath(); ctx.fill();
            ctx.strokeStyle = color; ctx.lineWidth = r * 0.1;
            [-0.42, 0, 0.42].forEach(off => {
                ctx.beginPath();
                ctx.moveTo(cx - r * 0.6, cy + off * r * 0.62);
                ctx.lineTo(cx - r * 1.15, cy + off * r * 0.62);
                ctx.stroke();
            });
        } else if (kind === 'numberBadge') {
            ctx.fillStyle = '#0b0e14';
            ctx.beginPath(); ctx.arc(cx, cy, r * 0.98, 0, Math.PI * 2); ctx.fill();
            ctx.lineWidth = r * 0.16; ctx.strokeStyle = color;
            ctx.beginPath(); ctx.arc(cx, cy, r * 0.98, 0, Math.PI * 2); ctx.stroke();
            ctx.fillStyle = color;
            ctx.font = `900 ${Math.round(r * 1.05)}px Anton, Impact, sans-serif`;
            ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
            ctx.fillText(opts.initials || 'GT', cx, cy + r * 0.08);
        }
    }

    function drawMiniFlag(ctx, cx, cy, r, tilt) {
        ctx.save();
        ctx.translate(cx, cy);
        ctx.rotate(tilt);
        drawChecker(ctx, -r * 0.14, -r * 0.95, r * 0.8, r * 0.52, 4, '#f1f5f9', '#0b0e14');
        ctx.fillStyle = '#e2e8f0'; ctx.fillRect(-r * 0.17, -r * 0.95, r * 0.06, r * 1.5);
        ctx.restore();
    }

    function drawSatellites(ctx, p, w, cy) {
        if (!p.satellites) return;
        const spread = w * 0.24, n = p.satellites;
        for (let i = 0; i < n; i++) {
            const t = n === 1 ? 0.5 : i / (n - 1);
            const sx = w * 0.5 - spread + spread * 2 * t;
            drawCharge(ctx, p.satCharge, sx, cy, w * 0.05, 'rgba(255,209,102,0.85)', { initials: p.initials });
        }
    }

    function drawSheen(ctx, w, h) {
        const g = ctx.createLinearGradient(0, 0, w, h);
        g.addColorStop(0, 'rgba(255,255,255,0.16)');
        g.addColorStop(0.35, 'rgba(255,255,255,0)');
        g.addColorStop(0.7, 'rgba(255,255,255,0)');
        g.addColorStop(1, 'rgba(0,0,0,0.22)');
        ctx.fillStyle = g; ctx.fillRect(0, 0, w, h);
    }

    function paintCrest(ctx, name, w, h) {
        const p = crestParams(name);
        ctx.clearRect(0, 0, w, h);

        ctx.save();
        shieldPath(ctx, p.shield, w, h);
        ctx.clip();

        drawField(ctx, p, w, h);
        drawStripes(ctx, p, w, h);
        drawTopDevice(ctx, p, w, h);

        const chiefBottom = p.topDevice === 'chiefMullets' ? h * 0.24 : h * 0.04;
        drawSatellites(ctx, p, w, chiefBottom + h * 0.14);
        drawCharge(ctx, p.charge, w * 0.5, chiefBottom + h * 0.36, w * 0.175, '#ffd166', { initials: p.initials });
        drawSheen(ctx, w, h);

        ctx.restore();

        drawBordure(ctx, p, p.shield, w, h);

        ctx.save();
        shieldPath(ctx, p.shield, w, h);
        ctx.lineWidth = w * 0.026;
        ctx.strokeStyle = 'rgba(255,209,102,0.9)';
        ctx.stroke();
        ctx.restore();

        return p.seed;
    }

    /* ---------- public API ---------- */
    function gtecRenderCrest(name, size) {
        size = size || 96;
        const canvas = document.createElement('canvas');
        canvas.width = size; canvas.height = size;
        canvas.setAttribute('aria-label', (name || 'GTEC') + ' team crest');
        canvas.setAttribute('role', 'img');
        paintCrest(canvas.getContext('2d'), name, size, size);
        return canvas;
    }

    window.gtecRenderCrest = gtecRenderCrest;
})();
