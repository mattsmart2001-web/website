/* GT7 Lap Coach: the analysis.
 *
 * Takes a set of laps (arrays of samples {t, x, z, v, thr, brk}, t in seconds,
 * x/z in metres, v in mph, thr/brk in percent) and returns everything the
 * report draws: the best lap's line as the reference, every lap projected onto
 * it by position, the corners found from the best lap's speed trace, per-corner
 * braking point, minimum speed, throttle-flat point and pedal shape for every
 * lap, section times, the theoretical best, and the advice.
 *
 * Pure functions, no DOM, so it runs in the page and in Node for testing.
 */
(function (root) {
  "use strict";

  const N = 2000;                 // samples along the reference line

  // ---------- helpers ----------
  function cumdist(xs, zs) {
    const rs = new Float64Array(xs.length); rs[0] = 0;
    for (let i = 1; i < xs.length; i++) rs[i] = rs[i - 1] + Math.hypot(xs[i] - xs[i - 1], zs[i] - zs[i - 1]);
    return rs;
  }
  function interp(xq, xp, fp) {
    // xp ascending; linear interpolation, clamped at the ends
    const out = new Float64Array(xq.length);
    let j = 0;
    for (let i = 0; i < xq.length; i++) {
      const x = xq[i];
      while (j < xp.length - 2 && xp[j + 1] < x) j++;
      if (x <= xp[0]) { out[i] = fp[0]; continue; }
      if (x >= xp[xp.length - 1]) { out[i] = fp[fp.length - 1]; continue; }
      const u = (x - xp[j]) / (xp[j + 1] - xp[j] || 1e-9);
      out[i] = fp[j] + (fp[j + 1] - fp[j]) * u;
    }
    return out;
  }
  function smooth(a, w) {
    const out = new Float64Array(a.length); const h = Math.floor(w / 2);
    for (let i = 0; i < a.length; i++) {
      let s = 0, n = 0;
      for (let k = -h; k <= h; k++) { const j = i + k; if (j >= 0 && j < a.length) { s += a[j]; n++; } }
      out[i] = s / n;
    }
    return out;
  }
  // nearest point on the reference line, with a coarse grid so it is quick
  function makeIndex(xs, zs, cell) {
    const g = new Map();
    const key = (cx, cz) => cx + "," + cz;
    for (let i = 0; i < xs.length; i++) {
      const k = key(Math.floor(xs[i] / cell), Math.floor(zs[i] / cell));
      if (!g.has(k)) g.set(k, []);
      g.get(k).push(i);
    }
    return function nearest(x, z) {
      const cx = Math.floor(x / cell), cz = Math.floor(z / cell);
      let best = -1, bd = Infinity;
      for (let r = 0; r <= 3 && best < 0; r++) {
        for (let dx = -r; dx <= r; dx++) for (let dz = -r; dz <= r; dz++) {
          if (Math.max(Math.abs(dx), Math.abs(dz)) !== r) continue;
          const b = g.get(key(cx + dx, cz + dz)); if (!b) continue;
          for (const i of b) { const d = (xs[i] - x) ** 2 + (zs[i] - z) ** 2; if (d < bd) { bd = d; best = i; } }
        }
        if (best >= 0 && r >= 1) break;      // one ring past the first hit is enough
      }
      if (best < 0) { for (let i = 0; i < xs.length; i++) { const d = (xs[i] - x) ** 2 + (zs[i] - z) ** 2; if (d < bd) { bd = d; best = i; } } }
      return [best, Math.sqrt(bd)];
    };
  }

  // ---------- projection ----------
  function buildReference(lap) {
    const xs = Float64Array.from(lap, s => s.x), zs = Float64Array.from(lap, s => s.z);
    const rs = cumdist(xs, zs); const LAP = rs[rs.length - 1];
    const S = new Float64Array(N); for (let i = 0; i < N; i++) S[i] = LAP * i / (N - 1);
    return { xs, zs, rs, LAP, S, DS: LAP / (N - 1), nearest: makeIndex(xs, zs, 25) };
  }
  function profile(ref, lap) {
    const n = lap.length; const raw = new Float64Array(n); const off = new Float64Array(n);
    for (let i = 0; i < n; i++) { const [j, d] = ref.nearest(lap[i].x, lap[i].z); raw[i] = ref.rs[j]; off[i] = d; }
    for (let i = 0; i < Math.min(300, n); i++) if (raw[i] > 0.9 * ref.LAP) raw[i] -= ref.LAP;   // starts before the line
    const s = new Float64Array(n); s[0] = raw[0];
    for (let i = 1; i < n; i++) s[i] = Math.max(s[i - 1], raw[i]);
    const keep = []; for (let i = 0; i < n; i++) if ((i === 0 || s[i] - s[i - 1] > 1e-9) && s[i] >= 0) keep.push(i);
    const sk = keep.map(i => s[i]);
    const col = f => interp(ref.S, sk, keep.map(i => f(lap[i])));
    const t = col(p => p.t); const t0 = t[0]; for (let i = 0; i < N; i++) t[i] -= t0;
    return { t, v: col(p => p.v), thr: col(p => p.thr), brk: col(p => p.brk), offline: interp(ref.S, sk, keep.map(i => off[i])) };
  }

  // ---------- corners ----------
  function findCorners(ref, B) {
    const DS = ref.DS, v = smooth(B.v, 9); const order = Math.round(60 / DS);
    const corners = [];
    for (let i = 0; i < N; i++) {
      if (ref.S[i] < 80 || ref.S[i] > ref.LAP - 80) continue;
      let isMin = true;
      for (let k = Math.max(0, i - order); k <= Math.min(N - 1, i + order); k++) if (v[k] < v[i]) { isMin = false; break; }
      if (!isMin) continue;
      const lo = Math.max(0, i - Math.round(200 / DS)), hi = Math.min(N - 1, i + Math.round(200 / DS));
      let pkL = -Infinity, pkR = -Infinity;
      for (let k = lo; k <= i; k++) pkL = Math.max(pkL, v[k]);
      for (let k = i; k <= hi; k++) pkR = Math.max(pkR, v[k]);
      if (Math.max(pkL, pkR) - v[i] < 8) continue;
      const c = { apex_s: ref.S[i], vmin: v[i], i };
      if (corners.length && c.apex_s - corners[corners.length - 1].apex_s < 120) {
        if (c.vmin < corners[corners.length - 1].vmin) corners[corners.length - 1] = c;
        continue;
      }
      corners.push(c);
    }
    corners.forEach((c, n) => {
      c.name = "T" + (n + 1);
      const prev = n ? corners[n - 1].apex_s : corners[corners.length - 1].apex_s - ref.LAP;
      const back = Math.round(Math.min(400, (c.apex_s - prev) * 0.85) / DS);
      let mx = 0; for (let j = 0; j <= back; j++) mx = Math.max(mx, B.brk[(c.i - j + N) % N]);
      c.braking = mx > 10;
    });
    return corners;
  }

  // ---------- per corner measures ----------
  const at = (ref, s) => Math.min(N - 1, Math.max(0, Math.round(((s % ref.LAP) + ref.LAP) % ref.LAP / ref.DS)));
  function brakeProfile(ref, corners, p, i) {
    const c = corners[i], DS = ref.DS;
    const prev = i ? corners[i - 1].apex_s : corners[corners.length - 1].apex_s - ref.LAP;
    const ap = at(ref, c.apex_s), back = Math.round(Math.min(500, (c.apex_s - prev) * 0.85) / DS);
    const ks = []; for (let j = back; j >= 0; j--) ks.push((ap - j + N) % N);
    let pk = 0; for (let j = 1; j < ks.length; j++) if (p.v[ks[j]] > p.v[ks[pk]]) pk = j;
    let touch = null, full = null;
    for (let j = pk; j < ks.length; j++) {
      const b = p.brk[ks[j]];
      if (touch === null && b > 10) touch = (ks.length - 1 - j) * DS;
      if (full === null && b >= 90) full = (ks.length - 1 - j) * DS;
    }
    let off = null, peak = 0;
    if (touch !== null) {
      for (let j = ks.length - 1 - Math.round(touch / DS); j < ks.length + Math.round(150 / DS); j++) {
        const k = (ap - (ks.length - 1 - j) + 4 * N) % N; peak = Math.max(peak, p.brk[k]);
        if (p.brk[k] < 30 && (ks.length - 1 - j) * DS < touch - 10) { off = (ks.length - 1 - j) * DS; break; }
      }
    }
    return { touch, full, off, peak };
  }
  function vmin(ref, corners, p, i) {
    const ap = at(ref, corners[i].apex_s), w = Math.round(100 / ref.DS); let m = Infinity;
    for (let j = -w; j < w; j++) m = Math.min(m, p.v[(ap + j + N) % N]);
    return m;
  }
  function flatPoint(ref, corners, p, i) {
    const ap = at(ref, corners[i].apex_s), hold = Math.round(30 / ref.DS), w = Math.round(100 / ref.DS);
    let start = -w, mv = Infinity;
    for (let j = -w; j < w; j++) { const vv = p.v[(ap + j + N) % N]; if (vv < mv) { mv = vv; start = j; } }
    for (let j = start; j < Math.round(600 / ref.DS); j++) {
      let ok = true; for (let m = 0; m < hold; m++) if (p.thr[(ap + j + m + N) % N] < 95) { ok = false; break; }
      if (ok) return j * ref.DS;
    }
    return null;
  }
  function sectionTime(ref, p, lo, hi) {
    const tt = s => s < 0 ? p.t[at(ref, s)] - p.t[N - 1] : s >= ref.LAP ? p.t[at(ref, s)] + p.t[N - 1] : p.t[at(ref, s)];
    return tt(hi) - tt(lo);
  }

  // ---------- the whole analysis ----------
  function analyse(laps, opts) {
    opts = opts || {};
    const names = laps.map((l, i) => l.name || ("Lap " + (i + 1)));
    const times = laps.map(l => l.samples[l.samples.length - 1].t - l.samples[0].t);
    const bi = times.indexOf(Math.min(...times));
    const ref = buildReference(laps[bi].samples);
    const P = laps.map(l => profile(ref, l.samples));
    const B = P[bi];
    const corners = findCorners(ref, B);
    const apex = corners.map(c => c.apex_s);
    const bounds = apex.map((a, i) => {
      const a0 = i ? apex[i - 1] : apex[apex.length - 1] - ref.LAP;
      const a1 = i + 1 < apex.length ? apex[i + 1] : apex[0] + ref.LAP;
      return [(a0 + a) / 2, (a + a1) / 2];
    });
    let theo = 0;
    const rows = corners.map((c, i) => {
      const vs = P.map(p => vmin(ref, corners, p, i));
      const fs = P.map(p => flatPoint(ref, corners, p, i));
      const bp = P.map(p => brakeProfile(ref, corners, p, i));
      const st = P.map(p => sectionTime(ref, p, bounds[i][0], bounds[i][1]));
      theo += Math.min(...st);
      const k = at(ref, c.apex_s + 120);
      const exits = P.map(p => p.v[k]);
      const touches = bp.map(b => b.touch).filter(x => x !== null);
      return {
        name: c.name, apex: c.apex_s, braking: c.braking, idx: c.i,
        vmin: vs, vminBest: vs[bi], vminMin: Math.min(...vs), vminMax: Math.max(...vs),
        brake: bp, brakeBest: bp[bi], touchMin: touches.length ? Math.min(...touches) : null, touchMax: touches.length ? Math.max(...touches) : null,
        flat: fs, flatBest: fs[bi],
        sect: st, sectBest: st[bi], sectMin: Math.min(...st), sectMax: Math.max(...st),
        exit: exits, exitBest: exits[bi], exitMin: Math.min(...exits), exitMax: Math.max(...exits),
      };
    });
    // the longest flat-out stretch on the best lap, allowed to wrap across the line
    const flatF = Array.from({ length: N }, (_, i) => B.thr[i] >= 95 && B.brk[i] < 5);
    let runStart = -1, bestRun = [0, 0];
    for (let i = 0; i < 2 * N; i++) {
      const f = flatF[i % N];
      if (f && runStart < 0) runStart = i;
      if ((!f || i === 2 * N - 1) && runStart >= 0) { if (Math.min(i, runStart + N) - runStart > bestRun[1] - bestRun[0]) bestRun = [runStart, Math.min(i, runStart + N)]; runStart = -1; }
    }
    const runFrom = ref.S[bestRun[0] % N], runTo = ref.S[bestRun[0] % N] + (bestRun[1] - bestRun[0]) * ref.DS;
    let compounding = null, bestD = Infinity;
    rows.forEach(r => { let d = runFrom - r.apex; if (d < -50) d += ref.LAP; if (d >= -50 && d < bestD) { bestD = d; compounding = r.name; } });
    if (!compounding && rows.length) compounding = rows[rows.length - 1].name;

    const flatShare = P.map(p => { let n = 0; for (let i = 0; i < N; i++) if (p.thr[i] >= 95) n++; return 100 * n / N; });
    const top = P.map(p => Math.max(...p.v));
    const result = {
      names, times, best: bi, lapLength: ref.LAP, S: Array.from(ref.S),
      map: Array.from({ length: Math.ceil(ref.xs.length / 5) }, (_, i) => [ref.xs[i * 5], ref.zs[i * 5]]),
      mapS: Array.from({ length: Math.ceil(ref.rs.length / 5) }, (_, i) => ref.rs[i * 5]),
      corners: rows, theoretical: theo, bestTime: times[bi],
      longestRun: { from: runFrom, to: runTo, metres: runTo - runFrom, opensFrom: compounding },
      flatShare, top,
      speed: P.map(p => Array.from(p.v)), brake: P.map(p => Array.from(p.brk)), throttle: P.map(p => Array.from(p.thr)),
      t: P.map(p => Array.from(p.t)),
      offline: P.map(p => Math.max(...p.offline)),
    };
    result.advice = advise(result, opts);
    return result;
  }

  // ---------- advice ----------
  function fmt(x, d) { return x.toFixed(d === undefined ? 1 : d); }
  function advise(R, opts) {
    const out = []; const rows = R.corners; const bi = R.best;
    const spread = Math.max(...R.times) - Math.min(...R.times);
    const onTable = R.bestTime - R.theoretical;
    // 1. consistency
    if (R.times.length >= 3) {
      if (spread < 0.8) out.push({ kind: "consistency", head: "You are consistent", body:
        `Your ${R.times.length} laps sit within ${fmt(spread, 2)} seconds of each other, and a lap built from your best version of every section would be only ${fmt(onTable, 2)} quicker than your best. Tidying up will not find much. The time is in changing something.` });
      else out.push({ kind: "consistency", head: "Consistency first", body:
        `Your laps spread by ${fmt(spread, 2)} seconds, and a lap built from your best version of every section would be ${fmt(onTable, 2)} quicker than your best. Before changing technique, that is the cheapest time on the table: find which corners vary and do your best version every lap.` });
    }
    // 2. pedal shape: stamping and early release
    const braking = rows.filter(r => r.braking);
    const stamp = braking.filter(r => r.brakeBest.touch !== null && r.brakeBest.full !== null && r.brakeBest.touch - r.brakeBest.full <= 6);
    const early = braking.filter(r => r.brakeBest.off !== null && r.brakeBest.off > 15);
    if (braking.length && (stamp.length >= Math.ceil(braking.length / 2) || early.length >= Math.ceil(braking.length / 2))) {
      let body = "";
      if (stamp.length) body += `At ${stamp.length} of your ${braking.length} braking corners you go from first touch to full pressure within a few metres: the pedal as a switch. `;
      if (early.length) body += `At ${early.length} of them you are fully off the brake ${Math.round(Math.min(...early.map(r => r.brakeBest.off)))} to ${Math.round(Math.max(...early.map(r => r.brakeBest.off)))} metres before the apex, then rolling in with nothing on the pedal. `;
      body += "Keep the same braking points. Squeeze the first few car lengths at half pressure instead of stamping, build to full, and keep a little pressure on all the way to the turn-in. Same start, same apex speed, more speed in between, which is where the fast drivers find most of their time.";
      out.push({ kind: "pedal", head: "The pedal is a switch. Make it a dial", body, corners: stamp.map(r => r.name) });
    }
    // 3. the corner that compounds: biggest spread, or the one onto the longest straight
    const byVar = [...braking].sort((a, b) => (b.sectMax - b.sectMin) - (a.sectMax - a.sectMin));
    if (byVar.length) {
      const r = byVar[0]; const comp = rows.find(x => x.name === R.longestRun.opensFrom);
      let body = `${r.name}, apex about ${Math.round(r.apex)} m from the line, taken at ${Math.round(r.vminBest)} mph on your best lap, varies most between laps: ${fmt(r.sectMax - r.sectMin, 2)} seconds between your best and worst, and your minimum speed there wanders from ${Math.round(r.vminMin)} to ${Math.round(r.vminMax)} mph.`;
      if (comp && comp.name === r.name) body += ` It also opens onto the longest flat-out stretch on the lap (${Math.round(R.longestRun.metres)} m), so whatever speed you carry out of it is still with you a long way down the road. Nail this corner every lap before you touch anything else.`;
      else if (comp) body += ` Separately, ${comp.name} opens onto the longest flat-out stretch on the lap (${Math.round(R.longestRun.metres)} m): a small gain in exit speed there is worth more than the same gain anywhere else.`;
      out.push({ kind: "corner", head: `Priority corner: ${r.name}`, body, corners: [r.name] });
    }
    // 4. inconsistent exits
    const exits = braking.filter(r => r.flat.filter(x => x !== null).length >= 3).map(r => { const f = r.flat.filter(x => x !== null); return [r, Math.max(...f) - Math.min(...f)]; }).sort((a, b) => b[1] - a[1]);
    if (exits.length && exits[0][1] > 30) {
      const [r, d] = exits[0];
      out.push({ kind: "exit", head: `Exit of ${r.name} wanders`, body:
        `Where you get back to full throttle after ${r.name} moves by ${Math.round(d)} metres between laps, from ${Math.round(Math.min(...r.flat.filter(x => x !== null)))} to ${Math.round(Math.max(...r.flat.filter(x => x !== null)))} metres past the apex. An inconsistent exit usually means an inconsistent entry: trailing the brake to the apex settles the car and makes the throttle point repeatable.`, corners: [r.name] });
    }
    // 5. brushed corners: braking that never reaches full and releases very early
    const brushed = braking.filter(r => r.brakeBest.touch !== null && r.brakeBest.full === null && r.brakeBest.off !== null && r.brakeBest.off > 50);
    if (brushed.length) {
      const r = brushed[0];
      out.push({ kind: "brush", head: `${r.name}: a brush, not a brake`, body:
        `Into ${r.name} you touch the brake ${Math.round(r.brakeBest.touch)} metres out, never reach full pressure, and are off it ${Math.round(r.brakeBest.off)} metres before the apex. That reads like a habit rather than a decision. Try braking later and firmer, or less at all, and see what the car says.`, corners: [r.name] });
    }
    // 6. honest caveat
    out.push({ kind: "caveat", head: "What this can and cannot say", body:
      `${R.times.length} laps on your own show what you do and how much it varies. They cannot show where you are slow against a faster driver: that needs a reference lap in the same car on the same track, which is the next thing this tool will do.` });
    return out;
  }

  // ---------- CSV from the SparksTheory logger ----------
  function parseLoggerCSV(text, name) {
    const lines = text.trim().split(/\r?\n/); const head = lines[0].split(",");
    const ix = Object.fromEntries(head.map((h, i) => [h.trim(), i]));
    const samples = [];
    for (let i = 1; i < lines.length; i++) {
      const c = lines[i].split(","); if (c.length < head.length) continue;
      samples.push({ t: +c[ix.t_s], x: +c[ix.x], z: +c[ix.z], v: ix.speed_mph !== undefined ? +c[ix.speed_mph] : +c[ix.speed_kph] * 0.621371, thr: +c[ix.throttle_pct], brk: +c[ix.brake_pct] });
    }
    return { name: name || "lap", samples };
  }

  const api = { analyse, parseLoggerCSV, findCorners, buildReference, profile };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.LapCoach = api;
})(typeof window !== "undefined" ? window : globalThis);
