/* GTEC shared backdrop — a static, photographed-material carbon fibre
   weave behind every public page. Replaces the old drifting starfield:
   this renders ONE canvas tile on load (real 2x2 twill geometry, flat
   matte ribbons, no gloss) and tiles it as a CSS background image, with
   no per-frame animation and no requestAnimationFrame loop.

   Self-contained: appends its own backdrop element, injects the styles
   it needs, and generates the tile on first load. Pages just include
   this script. */
(function () {
    'use strict';

    if (document.getElementById('gtec-backdrop')) return;

    if (!document.getElementById('gtec-backdrop-style')) {
        const style = document.createElement('style');
        style.id = 'gtec-backdrop-style';
        style.textContent = `
            #gtec-backdrop {
                position: fixed;
                inset: 0;
                z-index: -1;
                pointer-events: none;
                background-color: #050608;
            }
            #gtec-backdrop .gtec-backdrop-weave {
                position: absolute;
                inset: 0;
                background-repeat: repeat;
                opacity: 0.5;
            }
            #gtec-backdrop .gtec-backdrop-grain {
                position: absolute;
                inset: 0;
                background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='2' stitchTiles='stitch'/%3E%3CfeColorMatrix type='matrix' values='0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 0.05 0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
                background-size: 120px 120px;
                mix-blend-mode: overlay;
            }
            #gtec-backdrop .gtec-backdrop-vignette {
                position: absolute;
                inset: 0;
                background: radial-gradient(ellipse 90% 80% at 50% 40%, transparent 45%, rgba(0,0,0,0.5) 100%);
            }
        `;
        document.head.appendChild(style);
    }

    const root = document.createElement('div');
    root.id = 'gtec-backdrop';
    root.innerHTML = `
        <div class="gtec-backdrop-weave"></div>
        <div class="gtec-backdrop-grain"></div>
        <div class="gtec-backdrop-vignette"></div>
    `;
    document.body.insertBefore(root, document.body.firstChild);

    // Real 2x2 twill weave geometry, canvas-rendered once at load: warp
    // (vertical) and weft (horizontal) tows, each a flat matte ribbon
    // with fine longitudinal filament striations, interlaced on the
    // standard over-2/under-2 twill step (not a printed crosshatch).
    function makeCarbonTile(cell, cells) {
        const S = cell, N = cells, tile = S * N;
        const dpr = 4; // supersample for crisp filament detail regardless of the viewer's actual DPR
        const canvas = document.createElement('canvas');
        canvas.width = tile * dpr;
        canvas.height = tile * dpr;
        const ctx = canvas.getContext('2d');
        ctx.scale(dpr, dpr);

        // Dark seam colour: what shows through the narrow gap at every
        // tow boundary and at the crossings where one bundle dips under
        // another — the thing that actually reads as "weave", far more
        // than any gloss on the tow itself.
        ctx.fillStyle = '#030303';
        ctx.fillRect(0, 0, tile, tile);

        // A carbon tow is a flat matte ribbon of graphite filaments, not
        // a rounded glossy cord: a narrow, low-contrast centre band,
        // near-flat everywhere else — kept dark so the material recedes
        // rather than announcing itself.
        function towFill(x0, y0, x1, y1) {
            const g = ctx.createLinearGradient(x0, y0, x1, y1);
            g.addColorStop(0.00, '#131315');
            g.addColorStop(0.22, '#17181a');
            g.addColorStop(0.50, '#1c1d20');
            g.addColorStop(0.78, '#17181a');
            g.addColorStop(1.00, '#131315');
            return g;
        }

        // Fine longitudinal filament striations along a tow's run —
        // thin, irregular hairlines, the texture that keeps a flat
        // ribbon from reading as a printed swatch.
        function striate(x0, y0, w, h, vertical) {
            const lines = Math.max(3, Math.round((vertical ? w : h) / 1.6));
            for (let i = 0; i < lines; i++) {
                const t = (i + 0.5) / lines;
                ctx.strokeStyle = (i % 3 === 0) ? 'rgba(10,10,12,0.35)' : 'rgba(255,255,255,0.05)';
                ctx.lineWidth = 0.4;
                ctx.beginPath();
                if (vertical) {
                    const lx = x0 + t * w;
                    ctx.moveTo(lx, y0); ctx.lineTo(lx, y0 + h);
                } else {
                    const ly = y0 + t * h;
                    ctx.moveTo(x0, ly); ctx.lineTo(x0 + w, ly);
                }
                ctx.stroke();
            }
        }

        const seam = Math.max(1, S * 0.09); // gap exposed between adjacent tows

        // Warp: vertical tows, full tile height.
        for (let c = 0; c < N; c++) {
            const x = c * S;
            ctx.fillStyle = towFill(x, 0, x + S, 0);
            ctx.fillRect(x + seam / 2, 0, S - seam, tile);
            ctx.save();
            ctx.beginPath();
            ctx.rect(x + seam / 2, 0, S - seam, tile);
            ctx.clip();
            striate(x, 0, S, tile, true);
            ctx.restore();
        }

        // Weft: horizontal tows, drawn only into the cells where the
        // twill step puts them on top of the warp.
        for (let r = 0; r < N; r++) {
            const y = r * S;
            const overCols = [r % N, (r + 1) % N]; // warp stays visible here
            for (let c2 = 0; c2 < N; c2++) {
                if (overCols.indexOf(c2) !== -1) continue;
                const x2 = c2 * S;
                ctx.save();
                ctx.beginPath();
                ctx.rect(x2, y + seam / 2, S, S - seam);
                ctx.clip();
                ctx.fillStyle = towFill(0, y, 0, y + S);
                ctx.fillRect(x2, y, S, S);
                striate(x2, y, S, S, false);
                ctx.restore();
            }
        }

        // Faint shadow at every tow boundary and crossing — just enough
        // to read as a dip where one bundle passes under another,
        // without hardening into a grid of grout lines.
        ctx.strokeStyle = 'rgba(0,0,0,0.22)';
        ctx.lineWidth = Math.max(0.35, seam * 0.5);
        for (let i = 0; i <= N; i++) {
            ctx.beginPath(); ctx.moveTo(i * S, 0); ctx.lineTo(i * S, tile); ctx.stroke();
            ctx.beginPath(); ctx.moveTo(0, i * S); ctx.lineTo(tile, i * S); ctx.stroke();
        }

        return { url: canvas.toDataURL('image/png'), size: tile };
    }

    const tile = makeCarbonTile(5, 4);
    const weaveEl = root.querySelector('.gtec-backdrop-weave');
    weaveEl.style.backgroundImage = 'url(' + tile.url + ')';
    weaveEl.style.backgroundSize = tile.size + 'px ' + tile.size + 'px';
})();
