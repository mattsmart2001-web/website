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

  // Samples along the reference line. Every distance the report prints is
  // quantised to LAP/N metres, so this is the floor on brake-point accuracy:
  // at 4000 a 5.7 km track resolves to 1.4 m, which is finer than the 1.2 m a
  // car covers between two 60 Hz samples on a straight.
  const N = 4000;

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
    // the lap is a loop, so the window wraps: without this the trace either
    // side of the start line is smoothed against half a window and corners
    // near the line are found in the wrong place
    const out = new Float64Array(a.length); const h = Math.floor(w / 2), L = a.length;
    for (let i = 0; i < L; i++) {
      let s = 0;
      for (let k = -h; k <= h; k++) s += a[((i + k) % L + L) % L];
      out[i] = s / (2 * h + 1);
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

  // ---------- replay pedal lag ----------
  // A lap logged while driving has the pedals and the physics in step. A lap
  // logged by playing back a saved replay does not: GT7 sends the pedal
  // channels about three tenths of a second late, so the car appears to start
  // slowing before the brake is touched and every braking point reads roughly
  // twenty five metres early. Cross-correlating deceleration against brake
  // pressure recovers the offset. Reference laps taken from other drivers'
  // replays all carry it, so correcting here is what keeps a comparison
  // against a faster driver honest.
  function pedalLag(samples, maxLag) {
    maxLag = maxLag || 30;
    const n = samples.length;
    if (n < 4 * maxLag + 20) return { lag: 0, r: 0 };
    const dec = new Float64Array(n);
    for (let i = 1; i < n - 1; i++) { const d = samples[i - 1].v - samples[i + 1].v; dec[i] = d > 0 ? d : 0; }
    let md = 0, mb = 0;
    for (let i = 0; i < n; i++) { md += dec[i]; mb += samples[i].brk; }
    md /= n; mb /= n;
    if (mb < 0.5) return { lag: 0, r: 0 };            // nothing that counts as braking
    let best = 0, bestR = -Infinity;
    for (let L = -maxLag; L <= maxLag; L++) {
      let num = 0, d2 = 0, b2 = 0;
      for (let i = maxLag; i < n - maxLag; i++) {
        const a = dec[i] - md, b = samples[i + L].brk - mb;
        num += a * b; d2 += a * a; b2 += b * b;
      }
      const r = num / Math.sqrt(d2 * b2);
      if (r > bestR) { bestR = r; best = L; }
    }
    return { lag: best, r: bestR };
  }
  function applyLag(samples, L) {
    // move the pedal channels back onto the physics
    const n = samples.length;
    return samples.map((s, i) => {
      const j = Math.min(n - 1, Math.max(0, i + L));
      return { t: s.t, x: s.x, y: s.y, z: s.z, v: s.v, thr: samples[j].thr, brk: samples[j].brk };
    });
  }

  // ---------- projection ----------
  function buildReference(lap) {
    const xs = Float64Array.from(lap, s => s.x), zs = Float64Array.from(lap, s => s.z), ys = Float64Array.from(lap, s => s.y || 0);
    const rs = cumdist(xs, zs); const LAP = rs[rs.length - 1];
    const S = new Float64Array(N); for (let i = 0; i < N; i++) S[i] = LAP * i / (N - 1);
    return { xs, ys, zs, rs, LAP, S, DS: LAP / (N - 1), nearest: makeIndex(xs, zs, 25) };
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
    // Detect on a well smoothed trace so noise cannot invent a corner, but
    // locate the apex on a lightly smoothed one. A heavy window pulls the
    // minimum towards the gentler side of the corner, which on a long coast
    // into a sharp pick-up moved the apex most of a car length, and every
    // distance in the report is measured from it.
    const DS = ref.DS, v = smooth(B.v, Math.max(5, Math.round(16 / DS) | 1)); const order = Math.round(60 / DS);
    const vf = smooth(B.v, Math.max(3, Math.round(5 / DS) | 1));
    const W = i => ((i % N) + N) % N;                 // the lap is a loop
    const corners = [];
    for (let i = 0; i < N; i++) {
      let isMin = true;
      for (let k = -order; k <= order; k++) if (v[W(i + k)] < v[i]) { isMin = false; break; }
      if (!isMin) continue;
      let pkL = -Infinity, pkR = -Infinity; const span = Math.round(200 / DS);
      for (let k = 0; k <= span; k++) { pkL = Math.max(pkL, v[W(i - k)]); pkR = Math.max(pkR, v[W(i + k)]); }
      if (Math.max(pkL, pkR) - v[i] < 8) continue;
      // A slow corner holds minimum speed for a stretch rather than hitting a
      // point, and the test above fires on the first index of that plateau.
      // Taking the first index put every apex up to half a plateau early, and
      // with it every brake point, lift and throttle distance. Use the middle.
      const eps = 0.25;                               // mph: still "at minimum speed"
      let a = 0, b = 0;
      while (a < order && v[W(i - a - 1)] <= v[i] + eps) a++;
      while (b < order && v[W(i + b + 1)] <= v[i] + eps) b++;
      let mid = W(i + Math.round((b - a) / 2));
      // refine against the lightly smoothed trace, within the heavy window
      const fine = Math.max(2, Math.round(14 / DS));
      let lo = mid; for (let k = -fine; k <= fine; k++) if (vf[W(mid + k)] < vf[lo]) lo = W(mid + k);
      let a2 = 0, b2 = 0;
      while (a2 < fine && vf[W(lo - a2 - 1)] <= vf[lo] + eps) a2++;
      while (b2 < fine && vf[W(lo + b2 + 1)] <= vf[lo] + eps) b2++;
      mid = W(lo + Math.round((b2 - a2) / 2));
      const c = { apex_s: ref.S[mid], vmin: vf[mid], i: mid };
      const last = corners.length ? corners[corners.length - 1] : null;
      if (last && merges(ref, vf, last, c)) {
        if (c.vmin < last.vmin) corners[corners.length - 1] = c;
        continue;
      }
      corners.push(c);
    }
    // a corner found at each end of the line is one corner, not two
    if (corners.length > 1) {
      const f = corners[0], l = corners[corners.length - 1];
      if (merges(ref, vf, l, f)) { if (l.vmin < f.vmin) corners[0] = l; corners.pop(); }
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

  // Two speed minima close together are one corner only if the car stays slow
  // between them. A chicane is one corner because you brake once and never get
  // back on the power; two corners a hundred metres apart with a squirt of
  // throttle between them are two, and merging those would hide one of them
  // from the report entirely.
  function merges(ref, v, a, b) {
    let gap = b.apex_s - a.apex_s; if (gap < 0) gap += ref.LAP;
    if (gap >= 150) return false;
    if (gap < 40) return true;
    const W = i => ((i % N) + N) % N;
    let mx = -Infinity;
    for (let i = a.i; i !== b.i; i = W(i + 1)) if (v[i] > mx) mx = v[i];
    return mx < Math.min(a.vmin, b.vmin) + 8;
  }

  // ---------- per corner measures ----------
  const at = (ref, s) => Math.min(N - 1, Math.max(0, Math.round(((s % ref.LAP) + ref.LAP) % ref.LAP / ref.DS)));
  function brakeProfile(ref, corners, p, i) {
    // everything that happens on the pedals from the end of the previous corner
    // to well past this apex, in metres relative to the apex (positive = before)
    const c = corners[i], DS = ref.DS;
    const prev = i ? corners[i - 1].apex_s : corners[corners.length - 1].apex_s - ref.LAP;
    const ap = at(ref, c.apex_s), back = Math.round(Math.min(500, (c.apex_s - prev) * 0.85) / DS);
    const fwd = Math.round(250 / DS);
    const m = j => (back - j) * DS;                              // index in the window -> metres before apex
    const K = []; for (let j = 0; j <= back + fwd; j++) K.push((ap - back + j + 4 * N) % N);
    const brk = K.map(k => p.brk[k]), thr = K.map(k => p.thr[k]), v = K.map(k => p.v[k]);
    let pk = 0; for (let j = 1; j <= back; j++) if (v[j] > v[pk]) pk = j;
    let lift = null, touch = null, full = null;
    for (let j = pk; j <= back; j++) {
      if (lift === null && thr[j] < 95) lift = m(j);
      if (touch === null && brk[j] > 10) touch = m(j);
      if (full === null && brk[j] >= 90) full = m(j);
    }
    // the slowest point, used both as the end of the braking search and as the
    // start of the throttle search
    let slow = back; for (let j = Math.max(0, back - Math.round(100 / DS)); j < Math.min(K.length, back + Math.round(100 / DS)); j++) if (v[j] < v[slow]) slow = j;
    // Where the brake is genuinely released. This used to be the first moment
    // pressure fell below 30%, which called a driver "off the brake" while a
    // third of the pedal was still on: it under-credited trail braking and
    // counted the trail as coasting. It is now the last point with real
    // pressure, searched to a little past the slowest point, so a release that
    // runs to the apex reads as trail braking and a release past the apex
    // reports as a negative number rather than being missed.
    let off = null, peak = 0, offJ = null, trail = null;
    if (touch !== null) {
      const tj = back - Math.round(touch / DS);
      const lim = Math.min(K.length - 1, slow + Math.round(60 / DS));
      for (let j = tj; j <= lim; j++) peak = Math.max(peak, brk[j]);
      for (let j = lim; j >= tj; j--) if (brk[j] > 3) { off = m(j); offJ = j; break; }
      // how much of the braking zone is spent easing the pedal off: the
      // distance from peak pressure to release, as a share of the whole zone
      if (off !== null && peak > 0) {
        // measure from the LAST moment at peak pressure, not the first: a
        // driver who holds the pedal flat and then stamps off it has a long
        // zone and a violent release, and measuring from the first peak would
        // score that as gradual and tell them their technique is fine
        let pj = tj; for (let j = lim; j >= tj; j--) if (brk[j] >= peak - 1) { pj = j; break; }
        const zone = touch - off;
        trail = zone > 1 ? Math.max(0, Math.min(1, (m(pj) - off) / zone)) : null;
      }
    }
    let pick = null, tfull = null, midLift = false, pickJ = null;
    const hold = Math.round(30 / DS);
    for (let j = (offJ !== null ? Math.min(offJ, slow) : slow); j < K.length; j++) {
      if (pick === null && thr[j] > 5) { pick = -m(j); pickJ = j; }
      if (pick !== null && tfull === null) {
        let ok = j + hold <= K.length - 1; for (let q = 0; ok && q < hold; q++) if (thr[j + q] < 95) ok = false;
        if (ok) { tfull = -m(j); break; }
      }
    }
    if (pickJ !== null) { let mx = 0; for (let j = pickJ; j < K.length && (tfull === null || -m(j) < tfull); j++) { mx = Math.max(mx, thr[j]); if (mx > 50 && thr[j] < mx * 0.6) { midLift = true; break; } } }
    const coast = (off !== null && pick !== null) ? Math.max(0, pick + off) : null;    // metres with neither pedal, brake-off to throttle-on
    let overlap = 0; for (let j = 0; j < K.length; j++) if (brk[j] > 10 && thr[j] > 10) overlap += DS;
    const liftGap = (lift !== null && touch !== null) ? Math.max(0, lift - touch) : null; // metres between throttle lift and brake touch
    return { lift, touch, full, off, peak, trail, pick, tfull, midLift, coast, overlap, liftGap };
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
    // correct replay pedal lag before anything is measured off the pedals
    let lagFix = null;
    if (opts.lag !== false) {
      const found = laps.map(l => pedalLag(l.samples));
      const good = found.filter(f => f.r > 0.5).map(f => f.lag).sort((a, b) => a - b);
      const med = good.length ? good[Math.floor(good.length / 2)] : 0;
      if (med >= 6) {
        laps = laps.map(l => ({ name: l.name, samples: applyLag(l.samples, med) }));
        lagFix = { samples: med, seconds: med / 60 };
      }
    }
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
      const med = a => { const f = a.filter(x => x !== null).sort((x, y) => x - y); return f.length ? f[Math.floor(f.length / 2)] : null; };
      const kind = vs[bi] < 70 ? "slow" : vs[bi] < 105 ? "medium" : "fast";
      return {
        kind, coastMed: med(bp.map(b => b.coast)), liftGapMed: med(bp.map(b => b.liftGap)), overlapMed: med(bp.map(b => b.overlap)),
        pickMed: med(bp.map(b => b.pick)), tfullMed: med(bp.map(b => b.tfull)), midLifts: bp.filter(b => b.midLift).length,
        offMed: med(bp.map(b => b.off)), trailMed: med(bp.map(b => b.trail)), peakMed: med(bp.map(b => b.peak)),
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
    const top = P.map(p => p.v.reduce((a, b) => b > a ? b : a, -Infinity));
    const result = {
      names, times, best: bi, lapLength: ref.LAP, S: Array.from(ref.S), lagFix,
      map: Array.from({ length: Math.ceil(ref.xs.length / 5) }, (_, i) => [ref.xs[i * 5], ref.zs[i * 5]]),
      mapS: Array.from({ length: Math.ceil(ref.rs.length / 5) }, (_, i) => ref.rs[i * 5]),
      // the best lap's line on the S grid, with elevation, for the 3D map
      path: { x: Array.from(interp(ref.S, ref.rs, ref.xs)), y: Array.from(interp(ref.S, ref.rs, ref.ys)), z: Array.from(interp(ref.S, ref.rs, ref.zs)) },
      corners: rows, theoretical: theo, bestTime: times[bi],
      longestRun: { from: runFrom, to: runTo, metres: runTo - runFrom, opensFrom: compounding },
      flatShare, top,
      speed: P.map(p => Array.from(p.v)), brake: P.map(p => Array.from(p.brk)), throttle: P.map(p => Array.from(p.thr)),
      t: P.map(p => Array.from(p.t)),
      offline: P.map(p => p.offline.reduce((a, b) => b > a ? b : a, -Infinity)),
    };
    result.advice = advise(result, opts);
    return result;
  }

  // ---------- advice ----------
  // Rules written from the technique canon (trail braking, minimal coasting,
  // progressive throttle, no pedal overlap, repeatable references, and the
  // corner before the long straight mattering most), each scored by how much
  // time it is likely worth so the biggest things come first.
  function fmt(x, d) { return x.toFixed(d === undefined ? 1 : d); }
  function advise(R, opts) {
    const out = []; const rows = R.corners; const bi = R.best;
    const braking = rows.filter(r => r.braking);
    const spread = Math.max(...R.times) - Math.min(...R.times);
    const onTable = R.bestTime - R.theoretical;
    const nm = r => r.name + (r.name === R.longestRun.opensFrom ? " (the corner onto the long straight)" : "");

    // consistency
    if (R.times.length >= 3) {
      if (spread < 0.8) out.push({ kind: "consistency", score: 1, head: "You are consistent", body:
        `Your ${R.times.length} laps sit within ${fmt(spread, 2)} seconds of each other, and a lap built from your best version of every section would be only ${fmt(onTable, 2)} quicker than your best. Tidying up will not find much. The time is in changing something, and the cards below say what.` });
      else out.push({ kind: "consistency", score: onTable * 2, head: "Consistency is the cheapest time on the table", body:
        `Your laps spread by ${fmt(spread, 2)} seconds, and a lap built from your best version of every section would be ${fmt(onTable, 2)} quicker than your best. Before changing technique, find the corners that vary (they are marked below) and do your best version of each every lap. Fast drivers are not fast because of one heroic lap; they are fast because every lap is nearly the same.` });
    }
    // How the brake is used. Reaching peak pressure quickly is correct, not a
    // fault: the tyre has most grip when the car is upright and straight, so
    // the hard part of the stop belongs at the start of the zone. What costs
    // time is dumping the pedal at turn-in, never loading it properly, or
    // feeding it in so slowly that the first stretch of the zone does nothing.
    const withZone = braking.filter(r => r.brakeBest.touch !== null && r.brakeBest.off !== null && r.brakeBest.touch - r.brakeBest.off > 15);
    const dumped = withZone.filter(r => r.trailMed !== null && r.trailMed < 0.35);
    const dumpedFires = dumped.length >= Math.max(1, Math.ceil(withZone.length / 3));
    if (dumpedFires) {
      out.push({ kind: "pedal", score: 3 + 0.4 * dumped.length, head: "You come off the brake too quickly", body:
        `At ${dumped.length} of your ${withZone.length} braking corners (${dumped.map(r => r.name).join(", ")}) the pressure comes off in a short, sharp movement rather than being eased away. The moment the brake is gone the weight comes off the front tyres, and that is the exact moment you are asking them to turn, so the car runs wide and you have to wait for it. Keep your braking point and the first hard part of the stop exactly as they are. Change only the last part: bleed the pedal away slowly as you turn in, so there is still a little pressure on at the apex. That is trail braking, and it is where most of the gap to the front of a leaderboard lives.`,
        corners: dumped.map(r => r.name) });
    }
    const slowOn = braking.filter(r => r.brakeBest.touch !== null && r.brakeBest.full !== null && r.brakeBest.touch - r.brakeBest.full > 28 && r.kind !== "fast");
    if (slowOn.length) {
      const r = slowOn[0];
      out.push({ kind: "pedal", score: 2 + 0.3 * slowOn.length, head: `You feed the brake in slowly at ${r.name}`, body:
        `Into ${nm(r)} it takes about ${Math.round(r.brakeBest.touch - r.brakeBest.full)} metres from first touch to full pressure${slowOn.length > 1 ? `, and the same at ${slowOn.slice(1, 4).map(x => x.name).join(", ")}` : ""}. The car is upright and straight at the start of a braking zone, which is when the tyres can take the most, so that is where the pressure should already be. A squeeze that long wastes the strongest part of the stop and means you had to start it earlier than you needed to. Build to full in the first couple of car lengths, then ease it off as you turn.`,
        corners: slowOn.map(r => r.name) });
    }
    const never = braking.filter(r => r.brakeBest.full === null && r.kind === "slow" && r.coastMed !== null && r.coastMed > 15);
    if (never.length) {
      const r = never[0];
      out.push({ kind: "pedal", score: 1.8, head: `The brake never gets to full pressure at ${r.name}`, body:
        `Into ${nm(r)} the pedal never reaches full, and there are about ${Math.round(r.coastMed)} metres afterwards where neither pedal is doing anything. Those two go together: a stop that is too gentle has to start early and finish early, which leaves the car rolling to the apex with nothing loading the tyres. Brake later and harder into the same apex speed and that empty stretch disappears.`,
        corners: never.map(r => r.name) });
    }
    // and say so when the shape of it is already right, so the report is a
    // reading of what you do rather than a list of faults
    // one ordinary corner out of six should not cancel the note: it is the
    // overall shape being right that is worth telling someone
    const good = withZone.filter(r => r.trailMed !== null && r.trailMed >= 0.55);
    if (good.length >= Math.ceil(withZone.length * 0.6) && !dumpedFires) {
      out.push({ kind: "good", score: 0.4, head: "Your braking shape is already right", body:
        `At ${good.length} of your ${withZone.length} braking corners you load the pedal quickly and then ease it away over most of the zone, which is what trail braking looks like and is the hardest part of this to learn.${good.length < withZone.length ? ` The exception${withZone.length - good.length > 1 ? 's are' : ' is'} ${withZone.filter(r => !good.includes(r)).map(r => r.name).join(" and ")}, where the pedal comes away faster.` : ""} Nothing below is about how you use the pedal; it is about where you use it and what happens on the way out.` });
    }
    // coasting: the car doing nothing between brake and throttle
    // Coasting costs time, and the same stretch of road costs far more of it in
    // a hairpin than in a fast sweeper, so judge it in seconds rather than
    // metres: twenty metres is a second at 45 mph and a third of that at 135.
    const coastSecs = r => r.coastMed === null ? 0 : r.coastMed / Math.max(8, r.vminBest * 0.44704);
    const coasters = braking.filter(r => coastSecs(r) > 0.3 && r.coastMed > 12).sort((a, b) => coastSecs(b) - coastSecs(a));
    if (coasters.length) {
      const r = coasters[0];
      out.push({ kind: "coast", score: 1.5 + 2.5 * coastSecs(r), head: `${r.name}: ${Math.round(r.coastMed)} metres of coasting, about ${coastSecs(r).toFixed(1)}s`, body:
        `Into ${nm(r)} there is a stretch of about ${Math.round(r.coastMed)} metres where neither pedal is doing anything: you are off the brake and not yet on the throttle${coasters.length > 1 ? `, and the same happens at ${coasters.slice(1, 4).map(x => x.name).join(", ")}` : ""}. At the speed you are going through there that is roughly ${coastSecs(r).toFixed(1)} seconds of the lap with nothing being asked of the car. A car that is coasting is only losing speed. The fix is to make the two ends meet: carry the brake deeper, release it as you turn, and pick the throttle up the moment the release is finished. The slowest point of the corner should be a moment, not a stretch.`, corners: coasters.map(r => r.name) });
    }
    // lifting long before braking
    const lifters = braking.filter(r => r.liftGapMed !== null && r.liftGapMed > 20).sort((a, b) => b.liftGapMed - a.liftGapMed);
    if (lifters.length) {
      const r = lifters[0];
      out.push({ kind: "lift", score: 1 + 0.03 * r.liftGapMed, head: `Lifting ${Math.round(r.liftGapMed)} metres before you brake into ${r.name}`, body:
        `You come off the throttle about ${Math.round(r.liftGapMed)} metres before the brake touches into ${nm(r)}${lifters.length > 1 ? ` (also ${lifters.slice(1, 4).map(x => x.name).join(", ")})` : ""}. Those metres are flat-out road you are giving away: at the speed you arrive there it is roughly ${fmt(r.liftGapMed / (r.exitBest * 0.44704 * 1.4), 2)} seconds a lap. Stay flat until your braking point and move your foot across in one motion. If the braking point then feels early, it is: that is the next thing to move.`, corners: lifters.map(r => r.name) });
    }
    // pedal overlap
    const overl = braking.filter(r => r.overlapMed !== null && r.overlapMed > 12).sort((a, b) => b.overlapMed - a.overlapMed);
    if (overl.length) {
      const r = overl[0];
      out.push({ kind: "overlap", score: 0.8 + 0.02 * r.overlapMed, head: `Brake and throttle together at ${r.name}`, body:
        `For about ${Math.round(r.overlapMed)} metres into ${nm(r)} the brake and the throttle are both pressed. One is fighting the other, and the car gets neither the braking nor the drive. Finish the release before the throttle goes on; if you are left-foot braking, this is the habit to watch.`, corners: overl.map(r => r.name) });
    }
    // tentative exits: a long way from first throttle to full
    const tent = braking.filter(r => r.pickMed !== null && r.tfullMed !== null && (r.tfullMed - r.pickMed) > (r.kind === "slow" ? 120 : 80)).sort((a, b) => (b.tfullMed - b.pickMed) - (a.tfullMed - a.pickMed));
    if (tent.length) {
      const r = tent[0];
      out.push({ kind: "exit", score: 1.2 + 0.005 * (r.tfullMed - r.pickMed), head: `Slow to full throttle out of ${r.name}`, body:
        `Out of ${nm(r)} it takes you about ${Math.round(r.tfullMed - r.pickMed)} metres to get from first throttle to full. Progressive is right, but that is a long squeeze${r.midLifts ? `, and on ${r.midLifts} of your laps the throttle came back off part way, which usually means the car ran wide and you corrected` : ""}. Most often the cause is upstream: an apex that is slightly too early leaves the car pointed at the exit kerb, so you cannot commit. Try turning in a car length later so the car is straighter when you ask for the power.`, corners: tent.map(r => r.name) });
    }
    // the corner that varies most, and the one onto the long straight
    const byVar = [...braking].sort((a, b) => (b.sectMax - b.sectMin) - (a.sectMax - a.sectMin));
    if (byVar.length) {
      const r = byVar[0]; const comp = rows.find(x => x.name === R.longestRun.opensFrom);
      let body = `${r.name}, apex about ${Math.round(r.apex)} m from the line, taken at ${Math.round(r.vminBest)} mph on your best lap, varies most between laps: ${fmt(r.sectMax - r.sectMin, 2)} seconds between your best and worst, and your minimum speed there wanders from ${Math.round(r.vminMin)} to ${Math.round(r.vminMax)} mph.`;
      if (r.touchMin !== null && r.touchMax - r.touchMin > 15) body += ` Your braking point there moves by ${Math.round(r.touchMax - r.touchMin)} metres lap to lap, so pick one fixed reference at the side of the track and brake at it every time.`;
      if (comp && comp.name === r.name) body += ` It also opens onto the longest flat-out stretch on the lap (${Math.round(R.longestRun.metres)} m), so whatever speed you carry out of it is still with you a long way down the road. Nail this corner every lap before you touch anything else.`;
      else if (comp) body += ` Separately, ${comp.name} opens onto the longest flat-out stretch on the lap (${Math.round(R.longestRun.metres)} m): a small gain in exit speed there is worth more than the same gain anywhere else, so it is the corner to spend practice on.`;
      out.push({ kind: "corner", score: 2 + 2 * (r.sectMax - r.sectMin), head: `Priority corner: ${r.name}`, body, corners: [r.name] });
    }
    // brushed corners
    const brushed = braking.filter(r => r.brakeBest.touch !== null && r.brakeBest.full === null && r.brakeBest.off !== null && r.brakeBest.off > 50 && !never.some(n => n.name === r.name));
    if (brushed.length) {
      const r = brushed[0];
      out.push({ kind: "brush", score: 0.9, head: `${r.name}: a brush, not a brake`, body:
        `Into ${nm(r)} you touch the brake ${Math.round(r.brakeBest.touch)} metres out, never reach full pressure, and are off it ${Math.round(r.brakeBest.off)} metres before the apex. That reads like a habit rather than a decision. A corner like this is usually either flat with a lift, or a short, firm brake much later. Try both and let the minimum speed on the next report tell you which.`, corners: [r.name] });
    }
    // caveat always last
    out.sort((a, b) => b.score - a.score);
    out.push({ kind: "caveat", score: -1, head: "What this can and cannot say", body:
      `${R.times.length} laps on your own show what you do and how much it varies. They cannot show where you are slow against a faster driver: that needs a reference lap in the same car on the same track, which is the next thing this tool will do. Everything above is measured from your own telemetry; nothing is guessed.` });
    return out;
  }

  // ---------- CSV from the SparksTheory logger ----------
  function parseLoggerCSV(text, name) {
    const lines = text.trim().split(/\r?\n/); const head = lines[0].split(",");
    const ix = Object.fromEntries(head.map((h, i) => [h.trim(), i]));
    const samples = [];
    for (let i = 1; i < lines.length; i++) {
      const c = lines[i].split(","); if (c.length < head.length) continue;
      samples.push({ t: +c[ix.t_s], x: +c[ix.x], y: ix.y !== undefined ? +c[ix.y] : 0, z: +c[ix.z], v: ix.speed_mph !== undefined ? +c[ix.speed_mph] : +c[ix.speed_kph] * 0.621371, thr: +c[ix.throttle_pct], brk: +c[ix.brake_pct] });
    }
    return { name: name || "lap", samples };
  }

  const api = { analyse, parseLoggerCSV, findCorners, buildReference, profile, pedalLag };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.LapCoach = api;
})(typeof window !== "undefined" ? window : globalThis);
