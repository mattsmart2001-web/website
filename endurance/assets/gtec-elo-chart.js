/* GTEC Elo history chart — shared SVG renderer used on the public
   driver profile and the My Profile portal. Pass an array of
   { rating_after, delta, events: { name, round } } ordered oldest →
   newest. Returns HTML for a small fixed-height chart with:
     · gold area gradient under the line
     · soft 1500 baseline (dashed) if it falls inside the range
     · peak dot picked out in gold, trough in red
     · per-event tooltips on hover
     · current / peak / lowest labels at the top
   Self-injects its CSS once. */
(function () {
    'use strict';

    function renderEloChart(history, opts = {}) {
        history = Array.isArray(history) ? history.filter(h => h && Number.isFinite(Number(h.rating_after))) : [];
        if (history.length === 0) {
            return `<div class="gtec-elo-empty">No race history yet — your Elo journey starts at the first event.</div>`;
        }

        // Vals + min/max with 5% headroom either side so peaks and
        // troughs don't kiss the chart edges.
        const vals    = history.map(h => Number(h.rating_after));
        const realLo  = Math.min(...vals);
        const realHi  = Math.max(...vals);
        const padded  = Math.max(20, Math.round((realHi - realLo) * 0.15));
        const lo      = Math.max(800,  realLo - padded);
        const hi      = Math.min(3000, realHi + padded);
        const range   = Math.max(1, hi - lo);

        const W  = 600;
        const H  = 180;
        const PL = 40;    // padding left (for y-labels)
        const PR = 12;
        const PT = 18;
        const PB = 20;

        const innerW = W - PL - PR;
        const innerH = H - PT - PB;

        const xFn = i => vals.length === 1
            ? PL + innerW / 2
            : PL + (i / (vals.length - 1)) * innerW;
        const yFn = v => PT + (1 - (v - lo) / range) * innerH;

        const cur   = vals[vals.length - 1];
        const first = vals[0];
        const delta = cur - first;
        const peakIdx = vals.indexOf(realHi);
        const lowIdx  = vals.indexOf(realLo);

        // Smooth-ish polyline. For perf + simplicity stick to straight
        // segments — endurance leagues rarely have so many events that a
        // bezier curve is worth the maths.
        const linePts = vals.map((v, i) => `${xFn(i).toFixed(1)},${yFn(v).toFixed(1)}`).join(' ');

        // Area fill polygon: line points + close along the bottom.
        const areaPts = `${linePts} ${xFn(vals.length - 1).toFixed(1)},${(H - PB).toFixed(1)} ${PL.toFixed(1)},${(H - PB).toFixed(1)}`;

        // 1500 baseline if it sits inside the visible band.
        const baseline = (lo < 1500 && hi > 1500)
            ? `<line x1="${PL}" y1="${yFn(1500).toFixed(1)}" x2="${W - PR}" y2="${yFn(1500).toFixed(1)}" stroke="rgba(255,255,255,0.18)" stroke-width="1" stroke-dasharray="5,5"/>
               <text x="${W - PR - 4}" y="${(yFn(1500) - 4).toFixed(1)}" text-anchor="end" fill="rgba(255,255,255,0.4)" font-family="Orbitron,sans-serif" font-size="9" font-weight="700" letter-spacing="0.15em">1500</text>`
            : '';

        // y-axis min / max labels (Orbitron caps, muted)
        const yLabels = `
            <text x="${PL - 6}" y="${(PT + 6).toFixed(1)}" text-anchor="end" fill="rgba(148,163,184,0.7)" font-family="Orbitron,sans-serif" font-size="9" font-weight="700" letter-spacing="0.15em">${Math.round(hi)}</text>
            <text x="${PL - 6}" y="${(H - PB).toFixed(1)}" text-anchor="end" fill="rgba(148,163,184,0.7)" font-family="Orbitron,sans-serif" font-size="9" font-weight="700" letter-spacing="0.15em">${Math.round(lo)}</text>`;

        // Per-point dots. Peak rendered as a slightly larger gold circle
        // with a glow; trough as a small red marker. Tooltips on every
        // point so hovering tells the story.
        const dots = vals.map((v, i) => {
            const cx = xFn(i).toFixed(1);
            const cy = yFn(v).toFixed(1);
            const ev = history[i].events || {};
            const evtName = ev.name ? `${ev.name}` : (ev.round != null ? `Round ${ev.round}` : 'Event');
            const dlt = history[i].delta;
            const dStr = dlt != null ? ` (${dlt >= 0 ? '+' : ''}${dlt})` : '';
            const title = `${escXml(evtName)} — ${v}${dStr}`;
            if (i === peakIdx && vals.length > 1) {
                return `<circle cx="${cx}" cy="${cy}" r="5.5" fill="#ffd166" stroke="var(--bg-1)" stroke-width="2" filter="drop-shadow(0 0 5px rgba(255,209,102,0.6))"><title>${title}</title></circle>`;
            }
            if (i === lowIdx && vals.length > 1 && peakIdx !== lowIdx) {
                return `<circle cx="${cx}" cy="${cy}" r="4" fill="#f87171" stroke="var(--bg-1)" stroke-width="1.5"><title>${title}</title></circle>`;
            }
            return `<circle cx="${cx}" cy="${cy}" r="3" fill="#94a3b8" stroke="var(--bg-1)" stroke-width="1.5"><title>${title}</title></circle>`;
        }).join('');

        const gradId  = 'gtec-elo-grad-' + Math.random().toString(36).slice(2, 8);
        const lineCol = delta > 0 ? '#4ade80' : delta < 0 ? '#f87171' : '#ffd166';

        const meta = vals.length > 1
            ? `<div class="gtec-elo-meta">
                  <span class="gtec-elo-meta-item">
                      <span class="gtec-elo-meta-k">Current</span>
                      <span class="gtec-elo-meta-v">${cur}</span>
                  </span>
                  <span class="gtec-elo-meta-item">
                      <span class="gtec-elo-meta-k">Peak</span>
                      <span class="gtec-elo-meta-v" style="color:#ffd166">${realHi}</span>
                  </span>
                  <span class="gtec-elo-meta-item">
                      <span class="gtec-elo-meta-k">Lowest</span>
                      <span class="gtec-elo-meta-v" style="color:#f87171">${realLo}</span>
                  </span>
                  <span class="gtec-elo-meta-item" style="margin-left:auto">
                      <span class="gtec-elo-meta-k">${vals.length} event${vals.length === 1 ? '' : 's'}</span>
                      <span class="gtec-elo-meta-v" style="color:${delta > 0 ? '#4ade80' : delta < 0 ? '#f87171' : 'var(--muted)'}">${delta > 0 ? '+' : ''}${delta}</span>
                  </span>
               </div>`
            : `<div class="gtec-elo-meta">
                  <span class="gtec-elo-meta-item">
                      <span class="gtec-elo-meta-k">First Rating</span>
                      <span class="gtec-elo-meta-v">${cur}</span>
                  </span>
                  <span class="gtec-elo-meta-item" style="margin-left:auto">
                      <span class="gtec-elo-meta-k">Race a second event</span>
                      <span class="gtec-elo-meta-v" style="font-size:0.78rem">to see your trend</span>
                  </span>
               </div>`;

        return `
            <div class="gtec-elo-chart">
                ${meta}
                <svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="width:100%;height:${H}px;display:block;overflow:visible">
                    <defs>
                        <linearGradient id="${gradId}" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="0%" stop-color="rgba(255,209,102,0.32)"/>
                            <stop offset="100%" stop-color="rgba(255,209,102,0.0)"/>
                        </linearGradient>
                    </defs>
                    ${baseline}
                    ${yLabels}
                    ${vals.length > 1 ? `<polygon points="${areaPts}" fill="url(#${gradId})"/>` : ''}
                    ${vals.length > 1 ? `<polyline points="${linePts}" fill="none" stroke="${lineCol}" stroke-width="2.25" stroke-linejoin="round" stroke-linecap="round" opacity="0.95"/>` : ''}
                    ${dots}
                </svg>
            </div>`;
    }

    function escXml(s) {
        if (s == null) return '';
        return String(s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
    }

    // Inject CSS once.
    if (!document.getElementById('gtec-elo-chart-style')) {
        const style = document.createElement('style');
        style.id = 'gtec-elo-chart-style';
        style.textContent = `
            .gtec-elo-chart {
                background: var(--bg-1, #0a0e15);
                border: 1px solid var(--border, rgba(255,255,255,0.08));
                border-radius: 10px;
                padding: 0.9rem 1rem 0.5rem;
            }
            .gtec-elo-meta {
                display: flex;
                align-items: baseline;
                gap: 1.25rem;
                flex-wrap: wrap;
                padding-bottom: 0.65rem;
                margin-bottom: 0.35rem;
                border-bottom: 1px solid var(--border, rgba(255,255,255,0.06));
            }
            .gtec-elo-meta-item { display: inline-flex; flex-direction: column; gap: 0.1rem; }
            .gtec-elo-meta-k {
                font-family: 'Orbitron', sans-serif;
                font-size: 0.55rem;
                font-weight: 700;
                letter-spacing: 0.22em;
                text-transform: uppercase;
                color: var(--muted, #94a3b8);
            }
            .gtec-elo-meta-v {
                font-family: 'Anton', sans-serif;
                font-size: 1.05rem;
                letter-spacing: 0.02em;
                line-height: 1;
                color: var(--text, #f1f5f9);
            }
            .gtec-elo-empty {
                background: var(--bg-1, #0a0e15);
                border: 1px dashed var(--border, rgba(255,255,255,0.1));
                border-radius: 10px;
                padding: 1rem 1.1rem;
                font-size: 0.85rem;
                color: var(--muted, #94a3b8);
                text-align: center;
            }
        `;
        document.head.appendChild(style);
    }

    window.renderEloChart = renderEloChart;
})();
