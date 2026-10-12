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
    const out = { t, v: col(p => p.v), thr: col(p => p.thr), brk: col(p => p.brk), offline: interp(ref.S, sk, keep.map(i => off[i])) };
    if (lap[0].gear !== null && lap[0].gear !== undefined) {
      // nearest sample rather than an interpolation: half way between third and
      // fourth is not a gear
      const g = new Float64Array(N), r = new Float64Array(N);
      let j = 0;
      for (let i = 0; i < N; i++) {
        while (j < sk.length - 2 && sk[j + 1] < ref.S[i]) j++;
        const k = keep[(j + 1 < sk.length && Math.abs(sk[j + 1] - ref.S[i]) < Math.abs(sk[j] - ref.S[i])) ? j + 1 : j];
        g[i] = lap[k].gear; r[i] = lap[k].rpm === null ? 0 : lap[k].rpm;
      }
      out.gear = g; out.rpm = r;
    }
    return out;
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
  // How the car is actually being driven through a corner, beyond the pedals:
  // how hard it is stopped, whether the brake trace is steady or hunting,
  // whether it is accelerating once past the apex, and what the gearbox is
  // doing. These are the measurements the technique rules are built on.
  function dynamics(ref, corners, p, i, bp) {
    const c = corners[i], DS = ref.DS, ap = at(ref, c.apex_s);
    const W = k => ((k % N) + N) % N;
    const back = Math.round(Math.min(500, 260) / DS), fwd = Math.round(220 / DS);

    // peak deceleration through the braking zone, in g. Speed is in mph on a
    // distance grid, so dv/dt comes from v dv/ds.
    let peakG = null, entryV = null;
    if (bp.touch !== null && bp.off !== null) {
      const j0 = Math.round((c.apex_s - bp.touch) / DS), j1 = Math.round((c.apex_s - bp.off) / DS);
      entryV = p.v[W(j0)];
      // over a baseline of about fifteen metres, not point to point: the grid
      // is under a metre, and dividing the noise in an interpolated speed
      // trace by that returns three g for a car that can pull two
      const h = Math.max(2, Math.round(7.5 / DS));
      let worst = 0;
      for (let j = j0; j <= j1; j++) {
        const a = p.v[W(j - h)] * 0.44704, b = p.v[W(j + h)] * 0.44704;   // m/s
        const mid = p.v[W(j)] * 0.44704;
        const g = -(mid * (b - a) / (2 * h * DS)) / 9.81;
        if (g > worst) worst = g;
      }
      peakG = worst;
    }

    // how many times the brake pressure changes direction while it is applied:
    // a steady squeeze and release reverses once or twice, pumping reverses
    // many times, and it is the clearest sign of a driver guessing
    let reversals = 0;
    if (bp.touch !== null) {
      const j0 = Math.round((c.apex_s - bp.touch) / DS), j1 = Math.round((c.apex_s - (bp.off === null ? 0 : bp.off)) / DS);
      let dir = 0, last = p.brk[W(j0)];
      const stepN = Math.max(1, Math.round(6 / DS));                      // ignore wobble under ~6 m
      for (let j = j0; j <= j1; j += stepN) {
        const nowv = p.brk[W(j)], d = nowv - last;
        if (Math.abs(d) < 4) continue;                                    // and under 4% of pedal
        const nd = d > 0 ? 1 : -1;
        if (dir !== 0 && nd !== dir) reversals++;
        dir = nd; last = nowv;
      }
    }

    // metres past the apex before the car is genuinely accelerating again. A
    // long stall is the signature of an apex taken too early: the exit has been
    // spent on steering, so the throttle cannot be used.
    let stall = null;
    {
      const vmn = p.v[ap];
      let j = 0;
      for (; j <= fwd; j++) if (p.v[W(ap + j)] > vmn * 1.05) break;
      stall = j > fwd ? null : j * DS;
    }

    // gearbox, when the source carries it
    let upshiftAfterApex = null, limiter = 0;
    if (p.gear) {
      const lim = Math.round(60 / DS);
      for (let j = 1; j <= lim; j++) {
        const a = p.gear[W(ap + j - 1)], b = p.gear[W(ap + j)];
        if (b > a && upshiftAfterApex === null && p.thr[W(ap + j)] < 95) upshiftAfterApex = j * DS;
      }
      if (p.rpm) {
        let top = 0; for (let k = 0; k < N; k++) if (p.rpm[k] > top) top = p.rpm[k];
        for (let j = -back; j <= fwd; j++) {
          const k = W(ap + j);
          if (p.thr[k] >= 95 && p.rpm[k] > top * 0.985) limiter += DS;
        }
      }
    }
    return { peakG, entryV, reversals, stall, upshiftAfterApex, limiter };
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
      const dy = P.map((p, k) => dynamics(ref, corners, p, i, bp[k]));
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
        dyn: dy, dynBest: dy[bi],
        peakG: med(dy.map(d => d.peakG)), entryV: med(dy.map(d => d.entryV)),
        reversalsMed: med(dy.map(d => d.reversals)), stallMed: med(dy.map(d => d.stall)),
        upshifts: dy.filter(d => d.upshiftAfterApex !== null).length,
        limiterMed: med(dy.map(d => d.limiter)),
        lineDev: (() => { const o = P.map(p => p.offline[at(ref, c.apex_s)]); return Math.max.apply(null, o) - Math.min.apply(null, o); })(),
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
    // ---------- a reference lap, if one was supplied ----------
    // Everything above measures the driver against themselves. This measures
    // them against somebody quicker, by putting that lap on the same reference
    // line and comparing at every point on the track rather than at every
    // instant in time, so the two laps stay in step all the way round.
    if (opts.reference && opts.reference.samples && opts.reference.samples.length > 300) {
      result.ref = compareTo(ref, corners, bounds, B, P[bi], opts.reference, result);
    }
    result.advice = advise(result, opts);
    return result;
  }

  // ---------- comparison against a reference lap ----------
  function compareTo(ref, corners, bounds, B, bestP, reference, result) {
    // the reference almost always comes from a replay, where the pedals arrive
    // late, and it is corrected on its own: the driver's own laps are usually
    // live and in step, so a shared correction would be wrong for both
    let samples = reference.samples;
    const lag = pedalLag(samples);
    let lagFix = null;
    if (lag.r > 0.5 && lag.lag >= 6) { samples = applyLag(samples, lag.lag); lagFix = { samples: lag.lag, seconds: lag.lag / 60 }; }

    // is this even the same track? the projection will happily return nonsense
    // for a lap from somewhere else, so refuse instead of inventing a comparison
    const xs = Float64Array.from(samples, q => q.x), zs = Float64Array.from(samples, q => q.z);
    const own = cumdist(xs, zs); const ownLap = own[own.length - 1];
    if (Math.abs(ownLap - ref.LAP) / ref.LAP > 0.05) {
      return { ok: false, why: `That lap is ${Math.round(ownLap)} m round and yours is ${Math.round(ref.LAP)} m, so it is from a different track.` };
    }
    const p = profile(ref, samples);
    let offSum = 0; for (let i = 0; i < N; i++) offSum += p.offline[i];
    const meanOff = offSum / N;
    if (meanOff > 12) {
      return { ok: false, why: `That lap does not follow the same piece of road as yours (about ${Math.round(meanOff)} m away from your line on average), so it is from a different track or a different layout.` };
    }

    const time = samples[samples.length - 1].t - samples[0].t;
    // the delta: how far ahead or behind you are at each point on the track,
    // both laps zeroed at the line. Rising means you are losing time.
    const delta = new Array(N);
    for (let i = 0; i < N; i++) delta[i] = B.t[i] - p.t[i];

    const rows = corners.map((c, i) => {
      const bp = brakeProfile(ref, corners, p, i);
      const dy = dynamics(ref, corners, p, i, bp);
      const k = at(ref, c.apex_s + 120);
      return {
        name: c.name,
        vmin: vmin(ref, corners, p, i), brake: bp, dyn: dy,
        sect: sectionTime(ref, p, bounds[i][0], bounds[i][1]),
        exit: p.v[k],
      };
    });
    // time lost per corner, against the same section bounds
    const lost = corners.map((c, i) => result.corners[i].sectBest - rows[i].sect);

    let topR = -Infinity; for (let i = 0; i < N; i++) if (p.v[i] > topR) topR = p.v[i];
    let flatR = 0; for (let i = 0; i < N; i++) if (p.thr[i] >= 95) flatR++;
    return {
      ok: true, name: reference.name || "Reference", time, lagFix,
      gap: result.bestTime - time, delta,
      speed: Array.from(p.v), brake: Array.from(p.brk), throttle: Array.from(p.thr), t: Array.from(p.t),
      path: { x: Array.from(interp(ref.S, own, xs)), y: Array.from(interp(ref.S, own, Float64Array.from(samples, q => q.y || 0))), z: Array.from(interp(ref.S, own, zs)) },
      corners: rows, lost, top: topR, flatShare: 100 * flatR / N, meanOff,
    };
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
    const slow = braking.filter(r => r.kind === "slow");
    const spread = Math.max.apply(null, R.times) - Math.min.apply(null, R.times);
    const onTable = R.bestTime - R.theoretical;
    const nm = r => r.name + (r.name === R.longestRun.opensFrom ? " (the corner onto the long straight)" : "");
    const list = rs => rs.map(r => r.name).join(", ");
    const add = o => { out.push(o); return o; };

    // ---------- the whole lap ----------
    if (R.times.length >= 3) {
      if (spread < 0.8) add({ kind: "good", score: 1, head: "You are consistent", body:
        `Your ${R.times.length} laps sit within ${fmt(spread, 2)} seconds of each other, and a lap built from your best version of every section would be only ${fmt(onTable, 2)} quicker than your best. Tidying up will not find much. The time is in changing something, and the cards below say what.` });
      else add({ kind: "consistency", score: onTable * 2, head: "Consistency is the cheapest time on the table", body:
        `Your laps spread by ${fmt(spread, 2)} seconds, and a lap built from your best version of every section would be ${fmt(onTable, 2)} quicker than your best. Before changing technique, find the corners that vary, which are marked below, and do your best version of each one every lap.`,
        why: `A fast lap is not one heroic effort, it is the same lap repeated. Chasing a personal best on every lap is the most common way to get slower: you arrive at each corner with a different entry speed, so you never learn what the car does, and you spend the session reacting instead of building a reference. Drive at about ninety five percent until a corner comes out the same three times in a row, then push that corner and leave the rest alone. Repeatability is also what makes everything else in this report measurable, because a habit only shows up once the noise is gone.` });
    }

    // ---------- the brake ----------
    const withZone = braking.filter(r => r.brakeBest.touch !== null && r.brakeBest.off !== null && r.brakeBest.touch - r.brakeBest.off > 15);
    const dumped = withZone.filter(r => r.trailMed !== null && r.trailMed < 0.35);
    const dumpedFires = dumped.length >= Math.max(1, Math.ceil(withZone.length / 3));
    const WHY_TRAIL = `Braking throws the car's weight onto the front tyres, and a tyre with weight on it can grip harder. That is why the front of the car turns best while the brake is still doing something. If the pedal is gone before you turn in, the nose goes light at the exact moment you ask it to change direction, so the car pushes straight on and you have to wait for it to settle before you can use the throttle. Easing the last of the pressure off as you turn keeps that weight where you need it and lets you carry more speed into the corner for the same speed at the apex. It is the single technique that separates quick drivers from the rest, and it is worth more than any braking point.`;
    if (dumpedFires) {
      add({ kind: "pedal", score: 3 + 0.4 * dumped.length, head: "You come off the brake too quickly", body:
        `At ${dumped.length} of your ${withZone.length} braking corners (${list(dumped)}) the pressure comes off in a short, sharp movement rather than being eased away. Keep your braking point and the first hard part of the stop exactly as they are. Change only the last part: bleed the pedal away slowly as you turn in, so there is still a little pressure on at the apex.`,
        why: WHY_TRAIL, corners: dumped.map(r => r.name) });
    }
    const slowOn = braking.filter(r => r.brakeBest.touch !== null && r.brakeBest.full !== null && r.brakeBest.touch - r.brakeBest.full > 28 && r.kind !== "fast");
    if (slowOn.length) {
      const r = slowOn[0];
      add({ kind: "pedal", score: 2 + 0.3 * slowOn.length, head: `You feed the brake in slowly at ${r.name}`, body:
        `Into ${nm(r)} it takes about ${Math.round(r.brakeBest.touch - r.brakeBest.full)} metres from first touch to full pressure${slowOn.length > 1 ? `, and the same at ${list(slowOn.slice(1, 4))}` : ""}. Build to full in the first couple of car lengths, then ease it off as you turn.`,
        why: `A tyre can only do so much at once, and braking and cornering both spend the same budget. At the start of a braking zone the car is upright and pointing straight, so almost all of that budget is available for stopping, and that is where the hardest braking belongs. By the time you are turning, most of the budget has gone to cornering and there is little left for the brake. A long squeeze at the start wastes the one part of the corner where the car could have been stopping hardest, which forces you to begin braking earlier than you needed to.`,
        corners: slowOn.map(r => r.name) });
    }
    const never = braking.filter(r => r.brakeBest.full === null && r.kind === "slow" && r.coastMed !== null && r.coastMed > 15);
    if (never.length) {
      const r = never[0];
      add({ kind: "pedal", score: 1.8, head: `The brake never reaches full pressure at ${r.name}`, body:
        `Into ${nm(r)} the pedal never gets to full, and there are about ${Math.round(r.coastMed)} metres afterwards where neither pedal is doing anything. Brake later and harder into the same apex speed and that empty stretch disappears.`,
        why: `Those two findings are the same fault seen from both ends. A stop that is too gentle has to start early, and because it started early it also finishes early, which leaves the car rolling to the apex with nothing loading the tyres. Drivers usually get here by moving the braking point earlier after a scare, then never moving it back. The fix is not to brake harder at the same place, which only means arriving at the apex too slowly: it is to brake later and harder, and arrive at the same apex speed having spent less road doing it.`,
        corners: never.map(r => r.name) });
    }
    // peak deceleration against what this driver demonstrably gets from this car
    const stoppers = braking.filter(r => r.peakMed !== null && r.peakMed >= 70 && r.peakG !== null && r.entryV !== null);
    if (stoppers.length >= 2) {
      const weak = stoppers.map(r => {
        // compare only against corners entered at the same speed or slower, where
        // there is no more downforce to help, so the comparison is conservative
        const peers = stoppers.filter(q => q !== r && q.entryV <= r.entryV + 10);
        if (!peers.length) return null;
        const best = Math.max.apply(null, peers.map(q => q.peakG));
        return r.peakG < best * 0.85 ? { r, best, gap: best - r.peakG } : null;
      }).filter(Boolean).sort((a, b) => b.gap - a.gap);
      if (weak.length) {
        const w = weak[0];
        add({ kind: "pedal", score: 1.6 + w.gap, head: `There is more braking available at ${w.r.name}`, body:
          `Into ${nm(w.r)} you reach about ${w.r.peakG.toFixed(1)}g of deceleration, but elsewhere on this lap, from the same speed or slower, you stop the same car at ${w.best.toFixed(1)}g. The grip is clearly there. Either the braking point is early enough that you never need all of it, or you are not loading the pedal as hard here as you do elsewhere.`,
          why: `Peak deceleration is the one braking number you can judge without a reference lap, because the car is the comparison. If the same car stops harder somewhere else on the same lap at a similar speed, then the difference is you rather than the machinery. The usual cause is a corner that feels intimidating, so the pedal goes on earlier and softer and the stop is spread over more road than it needs. Move the braking point later in small steps and let the pedal pressure come up to match what you already achieve elsewhere.`,
          corners: [w.r.name] });
      }
    }
    const hunting = braking.filter(r => r.reversalsMed !== null && r.reversalsMed >= 3);
    if (hunting.length) {
      const r = hunting[0];
      add({ kind: "pedal", score: 1.4 + 0.2 * hunting.length, head: `The brake pressure hunts at ${r.name}`, body:
        `Through the braking zone into ${nm(r)} the pedal pressure changes direction about ${r.reversalsMed} times${hunting.length > 1 ? `, and the same happens at ${list(hunting.slice(1, 3))}` : ""}. A settled stop goes on, holds, and comes off. Pressure that goes up and down is you adjusting to what the car is doing instead of knowing what it will do.`,
        why: `Every change of brake pressure moves weight around the car, and a car whose weight keeps moving never settles enough to be driven precisely. Hunting on the pedal almost always means the braking point was a guess, so the first pressure was wrong and everything after it is a correction. The cure is a fixed visual reference rather than better reactions: pick something at the side of the track, a marker board, a change in the kerb, a shadow, and brake at it every lap. Once the start of the zone is the same every time, the pressure can be a plan instead of a reaction.`,
        corners: hunting.map(r => r.name) });
    }
    const wanders = braking.filter(r => r.touchMin !== null && r.touchMax - r.touchMin > 20).sort((a, b) => (b.touchMax - b.touchMin) - (a.touchMax - a.touchMin));
    if (wanders.length) {
      const r = wanders[0];
      add({ kind: "corner", score: 1.5 + 0.02 * (r.touchMax - r.touchMin), head: `Your braking point at ${r.name} moves ${Math.round(r.touchMax - r.touchMin)} metres`, body:
        `Between your laps the first touch of the brake into ${nm(r)} moves by about ${Math.round(r.touchMax - r.touchMin)} metres${wanders.length > 1 ? `, and there is similar movement at ${list(wanders.slice(1, 3))}` : ""}. That is most of a car length and a half of difference in where the corner starts, which is enough to change everything that follows it.`,
        why: `A braking point is not a feeling, it is a place. Drivers who are quick are not reacting faster, they are arriving at the same spot every lap and so the rest of the corner is the same too. Pick a fixed object at the side of the track rather than a distance, because distance is impossible to judge at speed and an object is not. If you cannot find one, count the marker boards. Once the point stops moving you will find you can move it later deliberately, which is the only safe way to find the real limit.`,
        corners: wanders.map(r => r.name) });
    }

    // ---------- the middle of the corner ----------
    const coastSecs = r => r.coastMed === null ? 0 : r.coastMed / Math.max(8, r.vminBest * 0.44704);
    const coasters = braking.filter(r => coastSecs(r) > 0.3 && r.coastMed > 12).sort((a, b) => coastSecs(b) - coastSecs(a));
    if (coasters.length) {
      const r = coasters[0];
      add({ kind: "coast", score: 1.5 + 2.5 * coastSecs(r), head: `${r.name}: ${Math.round(r.coastMed)} metres of coasting, about ${coastSecs(r).toFixed(1)}s`, body:
        `Into ${nm(r)} there is a stretch of about ${Math.round(r.coastMed)} metres where neither pedal is doing anything${coasters.length > 1 ? `, and the same happens at ${list(coasters.slice(1, 4))}` : ""}. At the speed you go through there that is roughly ${coastSecs(r).toFixed(1)} seconds with nothing being asked of the car. Carry the brake deeper, release it as you turn, and pick the throttle up as the release finishes.`,
        why: `A car that is neither braking nor driving is not doing anything useful: it is losing speed to drag and tyre scrub without that loss buying you any cornering. The slowest point of a corner should be an instant, not a stretch. Coasting is usually a symptom rather than a habit of its own, and the cause is at one end or the other: either the brake came off too early, or the throttle went on too late because the car was not pointed where you wanted it. Fix whichever end the corner cards say is yours, and the gap closes from that side.`,
        corners: coasters.map(r => r.name) });
    }
    const lifters = braking.filter(r => r.liftGapMed !== null && r.liftGapMed > 20).sort((a, b) => b.liftGapMed - a.liftGapMed);
    if (lifters.length) {
      const r = lifters[0];
      add({ kind: "lift", score: 1 + 0.03 * r.liftGapMed, head: `Lifting ${Math.round(r.liftGapMed)} metres before you brake into ${r.name}`, body:
        `You come off the throttle about ${Math.round(r.liftGapMed)} metres before the brake touches into ${nm(r)}${lifters.length > 1 ? ` (also ${list(lifters.slice(1, 4))})` : ""}. At the speed you arrive there that is roughly ${fmt(r.liftGapMed / Math.max(8, r.exitBest * 0.44704 * 1.4), 2)} seconds a lap. Stay flat until your braking point and move your foot across in one motion.`,
        why: `The gap between lifting and braking is road you are travelling at less than full speed for no reason. It usually appears because the braking point is not certain, so the lift is an insurance policy that buys thinking time. That makes it a symptom of the same problem as a wandering braking point, and the same fix works: a fixed reference to brake at, so there is nothing to decide on the way in. If the braking point then feels early once you stay flat to it, that is useful information rather than a problem, and it is the next thing to move.`,
        corners: lifters.map(r => r.name) });
    }
    const overl = braking.filter(r => r.overlapMed !== null && r.overlapMed > 25).sort((a, b) => b.overlapMed - a.overlapMed);
    if (overl.length) {
      const r = overl[0];
      add({ kind: "overlap", score: 0.9 + 0.02 * r.overlapMed, head: `Brake and throttle together for ${Math.round(r.overlapMed)} metres at ${r.name}`, body:
        `Into ${nm(r)} the brake and the throttle are both pressed for about ${Math.round(r.overlapMed)} metres. A brief overlap as one hands over to the other is normal and fine. This is longer than that, and over that distance the two are working against each other.`,
        why: `A short crossover between the pedals is deliberate in a lot of fast driving, and on a rear wheel drive car a touch of throttle against the brake can even help settle the back. What costs time is a long overlap, because the engine is pushing while the brakes are holding: the car gets neither the full stop nor the full drive, and the tyres do the arguing. If you brake with your left foot this is the habit to watch, since there is nothing forcing one foot off before the other arrives.`,
        corners: overl.map(r => r.name) });
    }
    const vmins = braking.filter(r => r.vminMax - r.vminMin > 5).sort((a, b) => (b.vminMax - b.vminMin) - (a.vminMax - a.vminMin));
    if (vmins.length && !wanders.length) {
      const r = vmins[0];
      add({ kind: "corner", score: 1.2, head: `Your apex speed at ${r.name} varies by ${Math.round(r.vminMax - r.vminMin)} mph`, body:
        `Your braking points are fairly settled, but the slowest point of ${nm(r)} ranges from ${Math.round(r.vminMin)} to ${Math.round(r.vminMax)} mph across your laps. When the braking point is consistent and the apex speed is not, the variation is coming from how you release the pedal rather than where you press it.`,
        why: `Entry speed is set by the shape of the release, not the start of the stop. Two laps that begin braking in the same place can arrive at the apex several miles an hour apart if one bled the pressure away faster than the other. That makes apex speed a good test of whether your trail braking is repeatable: if the number moves around, the release is still being improvised. Try holding a deliberate, slow, even release for a few laps, even if it feels slow, and watch the apex speed settle before you try to raise it.`,
        corners: [r.name] });
    }

    // ---------- the exit ----------
    const stalled = slow.filter(r => r.stallMed !== null && r.stallMed > 30).sort((a, b) => b.stallMed - a.stallMed);
    if (stalled.length) {
      const r = stalled[0];
      add({ kind: "exit", score: 1.7 + 0.01 * r.stallMed, head: `${r.name}: the car cannot accelerate for ${Math.round(r.stallMed)} metres past the apex`, body:
        `Out of ${nm(r)} it takes about ${Math.round(r.stallMed)} metres past the slowest point before the car is genuinely gaining speed${stalled.length > 1 ? `, and the same at ${list(stalled.slice(1, 3))}` : ""}. That is the signature of an apex taken too early: the car reaches the inside of the corner while it is still pointed across the track, so the exit has to be spent steering instead of accelerating.`,
        why: `An early apex feels good and is slow. Turning in early puts the car on the inside kerb quickly, but it leaves the car aimed at the outside of the exit, so you have to hold steering lock on just when you want to be straightening and feeding in power. A late apex does the opposite: you give up a little entry speed, the car is pointed down the road sooner, and you can be on the throttle earlier and harder. Because the exit of a corner feeds a straight, and the straight is long, a late apex wins every time a corner leads onto one. Work backwards from where you want the car at the exit, and let that decide the turn-in.`,
        corners: stalled.map(r => r.name) });
    }
    const tent = braking.filter(r => r.pickMed !== null && r.tfullMed !== null && (r.tfullMed - r.pickMed) > (r.kind === "slow" ? 120 : 80)).sort((a, b) => (b.tfullMed - b.pickMed) - (a.tfullMed - a.pickMed));
    if (tent.length) {
      const r = tent[0];
      add({ kind: "exit", score: 1.2 + 0.005 * (r.tfullMed - r.pickMed), head: `Slow to full throttle out of ${r.name}`, body:
        `Out of ${nm(r)} it takes about ${Math.round(r.tfullMed - r.pickMed)} metres to get from first throttle to full. Progressive is right, but that is a long squeeze.`,
        why: `A long throttle squeeze is almost never a throttle problem. If the car is pointed down the road you can take the power quickly; if it is not, you cannot, and no amount of bravery with your right foot changes that. So the cause is usually upstream, at the turn-in or the apex, and the fix is to arrive at the exit with the car straighter rather than to force more throttle into the same corner. Try turning in a car length later so the car is pointed where you want it sooner, and the squeeze will shorten on its own.`,
        corners: tent.map(r => r.name) });
    }
    const relift = braking.filter(r => r.midLifts >= Math.max(2, Math.ceil(R.times.length / 3)));
    if (relift.length) {
      const r = relift.sort((a, b) => b.midLifts - a.midLifts)[0];
      add({ kind: "exit", score: 1.3, head: `You lift again on the way out of ${r.name}`, body:
        `On ${r.midLifts} of your ${R.times.length} laps the throttle comes back off part way through the exit of ${nm(r)} after you had already picked it up. That is the car running out of road or running out of grip, and either way the lap has already lost the time by then.`,
        why: `Having to lift on an exit means the throttle went on before the car could take it. Occasionally that is simple greed, but far more often it is an apex that was too early, which leaves the car heading for the outside of the track with steering still applied, so adding power pushes it wide and you have to back out. Treat a second lift as a message about the entry rather than the exit. If it only happens on some laps, it is also telling you which entry was different, which is worth more than the lap time it cost.`,
        corners: relift.map(r => r.name) });
    }
    const gearLow = braking.filter(r => r.upshifts >= Math.max(2, Math.ceil(R.times.length / 2)));
    if (gearLow.length) {
      const r = gearLow.sort((a, b) => b.upshifts - a.upshifts)[0];
      add({ kind: "exit", score: 1.1, head: `You change up mid-exit at ${r.name}`, body:
        `On ${r.upshifts} of your ${R.times.length} laps you take an upshift within sixty metres of the apex of ${nm(r)}, while the throttle is still only part open${gearLow.length > 1 ? `, and the same at ${list(gearLow.slice(1, 3))}` : ""}. That usually means the corner is being taken a gear lower than it wants.`,
        why: `A gear that is too low runs out of revs just as you need to be feeding power in, so the shift lands in the middle of the part of the corner where the car is least settled. Each shift interrupts the drive and sends a small shock through the car at the exact moment the rear tyres are working hardest. A gear higher often feels lazy for the first few metres and is quicker by the end of the following straight, because the power arrives smoothly and stays. Try the corner one gear up and compare the speed at the end of the next straight rather than how it feels at the apex.`,
        corners: gearLow.map(r => r.name) });
    }
    const revd = rows.filter(r => r.limiterMed !== null && r.limiterMed > 60);
    if (revd.length) {
      const r = revd.sort((a, b) => b.limiterMed - a.limiterMed)[0];
      add({ kind: "exit", score: 0.8, head: `You are sitting on the rev limiter near ${r.name}`, body:
        `For about ${Math.round(r.limiterMed)} metres around ${nm(r)} the engine is at its limit with the throttle wide open. Once the needle is against the stop, more road is not making you any faster.`,
        why: `Bouncing off the limiter is dead road: the engine cannot make more speed, so every metre spent there is a metre you could have covered faster in the next gear. It usually means the shift is going in late out of habit, or that the corner before it was taken a gear low and the whole sequence is one gear out. Change up as the needle reaches the limit rather than after it, and if that leaves the engine below its best power, the corner before probably wants a higher gear too.`,
        corners: [r.name] });
    }

    // ---------- where to spend the practice ----------
    const byVar = braking.slice().sort((a, b) => (b.sectMax - b.sectMin) - (a.sectMax - a.sectMin));
    if (byVar.length) {
      const r = byVar[0]; const comp = rows.find(x => x.name === R.longestRun.opensFrom);
      let body = `${r.name}, apex about ${Math.round(r.apex)} m from the line and taken at ${Math.round(r.vminBest)} mph on your best lap, varies most between your laps: ${fmt(r.sectMax - r.sectMin, 2)} seconds between your best and worst, with the slowest point ranging from ${Math.round(r.vminMin)} to ${Math.round(r.vminMax)} mph.`;
      if (comp && comp.name === r.name) body += ` It also opens onto the longest flat-out stretch on the lap (${Math.round(R.longestRun.metres)} m), so whatever speed you carry out of it stays with you a long way down the road. Nail this corner every lap before you touch anything else.`;
      else if (comp) body += ` Separately, ${comp.name} opens onto the longest flat-out stretch on the lap (${Math.round(R.longestRun.metres)} m), so the same gain in exit speed is worth more there than anywhere else.`;
      add({ kind: "corner", score: 2 + 2 * (r.sectMax - r.sectMin), head: `Priority corner: ${r.name}`, body,
        why: `Not every corner is worth the same, and practising them equally is how sessions get used up without the lap time moving. Two things make a corner worth more than its neighbours. The first is how much it varies, because a corner you already do the same way every lap has little left in it, while one that swings by half a second is giving time away on most laps. The second is what follows it: a corner that opens onto a long straight carries its exit speed all the way down that straight, so a mile an hour gained there is worth several times the same gain into a corner that leads to another corner. When those two point at the same corner, as they sometimes do, that is the one to spend the whole session on.`,
        corners: [r.name] });
    }
    const liney = braking.filter(r => r.lineDev !== null && r.lineDev > 1.5).sort((a, b) => b.lineDev - a.lineDev);
    if (liney.length && R.times.length >= 4) {
      const r = liney[0];
      add({ kind: "corner", score: 0.9, head: `Your line through ${r.name} moves about ${r.lineDev.toFixed(1)} m`, body:
        `Across your laps the car passes the apex of ${nm(r)} up to ${r.lineDev.toFixed(1)} metres apart from one lap to the next${liney.length > 1 ? `, and there is similar spread at ${list(liney.slice(1, 3))}` : ""}. That is roughly half a car width of difference in where you put it.`,
        why: `The line is the frame that everything else hangs on. If the car is in a different place at the apex each lap then the braking point, the entry speed and the exit all have to be different too, and none of them can be practised properly. It is also the cheapest thing to make repeatable, because unlike a braking point it does not require any bravery: pick the piece of kerb you want to touch and touch it every lap at whatever speed you like, then build the speed back up once the line stops moving.`,
        corners: liney.map(r => r.name) });
    }
    const brushed = braking.filter(r => r.brakeBest.touch !== null && r.brakeBest.full === null && r.brakeBest.off !== null && r.brakeBest.off > 50 && !never.some(n => n.name === r.name));
    if (brushed.length) {
      const r = brushed[0];
      add({ kind: "brush", score: 0.9, head: `${r.name}: a brush, not a brake`, body:
        `Into ${nm(r)} you touch the brake ${Math.round(r.brakeBest.touch)} metres out, never reach full pressure, and are off it ${Math.round(r.brakeBest.off)} metres before the apex. A corner like this is usually either flat with a lift, or a short firm brake much later.`,
        why: `A long gentle brush of the pedal is often a habit left over from the first few laps at a track, when the corner was unknown and a dab felt safer than nothing. It is the worst of both: it is not enough to meaningfully slow the car, but it is enough to unsettle it and to cost you the speed you would have carried by staying flat. Try the corner both ways in a practice session, flat with a lift and then a late firm brake, and let the minimum speed and the section time on the next report tell you which the corner actually wants.`,
        corners: [r.name] });
    }

    // ---------- what is already right ----------
    const good = withZone.filter(r => r.trailMed !== null && r.trailMed >= 0.55);
    if (good.length >= Math.ceil(withZone.length * 0.6) && !dumpedFires) {
      add({ kind: "good", score: 0.4, head: "Your braking shape is already right", body:
        `At ${good.length} of your ${withZone.length} braking corners you load the pedal quickly and then ease it away over most of the zone, which is what trail braking looks like and is the hardest part of this to learn.${good.length < withZone.length ? ` The exception${withZone.length - good.length > 1 ? "s are" : " is"} ${list(withZone.filter(r => good.indexOf(r) < 0))}, where the pedal comes away faster.` : ""} Nothing above is about how you use the pedal; it is about where you use it and what happens on the way out.` });
    }
    if (R.flatShare && R.flatShare[bi] > 55) {
      add({ kind: "good", score: 0.3, head: `You are flat out for ${Math.round(R.flatShare[bi])}% of the lap`, body:
        `On your best lap the throttle is wide open for ${Math.round(R.flatShare[bi])}% of the distance, with the longest unbroken run ${Math.round(R.longestRun.metres)} metres out of ${R.longestRun.opensFrom}. That is a high number and it means the corners, not the straights, are where the rest of your time is.` });
    }

    // Faults get ranked and trimmed; things that are already right are not
    // faults and do not belong in a list headed "smaller things to work on".
    const faults = out.filter(a => a.kind !== "good").sort((a, b) => b.score - a.score);
    const working = out.filter(a => a.kind === "good").sort((a, b) => b.score - a.score);
    // a ranked list only helps if it is short enough to act on in one session
    const KEEP = 6;
    const shown = faults.slice(0, KEEP), rest = faults.slice(KEEP);
    if (rest.length) shown.push({ kind: "more", score: -0.4, head: `${rest.length} smaller thing${rest.length > 1 ? "s" : ""} further down the list`, body:
      `Also measured, in order: ${rest.map(a => a.head.charAt(0).toLowerCase() + a.head.slice(1)).join("; ")}. These are worth less than the ones above, so they are listed rather than explained. They will move up on their own once the bigger ones are fixed.` });
    shown.push.apply(shown, working);
    // a reference comparison answers the question the driver actually asked, so
    // it leads, and the self-measured findings follow it as context
    if (R.ref && R.ref.ok) {
      const cmp = compareAdvice(R).sort((a, b) => b.score - a.score);
      shown.unshift.apply(shown, cmp);
    }
    shown.push({ kind: "caveat", score: -1, head: "What this can and cannot say", body:
      `${R.times.length} laps on your own show what you do and how much it varies. They cannot show where you are slow against a faster driver: that needs a reference lap in the same car on the same track, which is the next thing this tool will do. Everything above is measured from your own telemetry; nothing is guessed.` });
    return shown;
  }

  // ---------- advice against a reference lap ----------
  // Measured against somebody quicker, the useful question is not "what do you
  // do" but "what do they do differently, and where does it actually cost you".
  // Ranked by time, because a corner where they are a tenth up matters more
  // than one where their technique differs and the clock does not notice.
  function compareAdvice(R) {
    const F = R.ref, out = [];
    if (!F || !F.ok) return out;
    const n = R.corners.length;
    const ranked = R.corners.map((c, i) => ({ c, i, lost: F.lost[i], them: F.corners[i] }))
      .filter(x => x.lost > 0.08).sort((a, b) => b.lost - a.lost);
    const nm = c => c.name + (c.name === R.longestRun.opensFrom ? " (the corner onto the long straight)" : "");

    out.push({ kind: "refhead", score: 100, head: `${F.gap > 0 ? "You are " + fmt(F.gap, 3) + " seconds behind" : "You are " + fmt(-F.gap, 3) + " seconds ahead of"} ${F.name}`, body:
      ranked.length
        ? `Against your best lap, the difference is concentrated at ${ranked.slice(0, 3).map(x => `${x.c.name} (${fmt(x.lost, 2)}s)`).join(", ")}${ranked.length > 3 ? `, with the rest spread thinly` : ""}. Everywhere else you are within a few hundredths, which is worth knowing before you change anything: most of your lap is already their pace.`
        : `The difference is spread evenly round the lap rather than sitting in one or two corners, which usually means a small, consistent difference in how the car is being driven rather than a specific mistake.`,
      why: `Both laps are laid over the same piece of road rather than lined up by time, so at every point on the track you are being compared with what they were doing in the same place. That is what makes the corner by corner numbers meaningful: without it, one earlier braking point shifts everything after it and the rest of the lap looks different when it is not. The gap you see is the real one, and the corner differences below add up to it.` });

    ranked.slice(0, 3).forEach(x => {
      const b = x.c.brakeBest, t = x.them.brake;
      const dBrake = (t.touch !== null && b.touch !== null) ? t.touch - b.touch : null;   // positive: they brake earlier
      const dApex = x.them.vmin - x.c.vminBest;
      const dExit = x.them.exit - x.c.exitBest;
      const dPick = (t.pick !== null && b.pick !== null) ? b.pick - t.pick : null;        // positive: they pick up earlier
      const bits = [];
      if (dBrake !== null && dBrake < -8) bits.push(`they brake about ${Math.round(-dBrake)} metres later than you`);
      else if (dBrake !== null && dBrake > 8) bits.push(`they actually brake ${Math.round(dBrake)} metres earlier than you`);
      else if (dBrake !== null) bits.push(`you both brake within a few metres of the same place`);
      if (dApex > 1.5) bits.push(`they carry ${fmt(dApex, 1)} mph more through the slowest part`);
      else if (dApex < -1.5) bits.push(`you are actually ${fmt(-dApex, 1)} mph quicker at the apex`);
      if (dPick !== null && dPick > 8) bits.push(`they are back on the throttle about ${Math.round(dPick)} metres earlier`);
      if (dExit > 1.5) bits.push(`and they are ${fmt(dExit, 1)} mph up by the time the corner has finished`);

      let read = "";
      if (dBrake !== null && dBrake > -8 && dApex > 1.5) read = `The braking point is not the difference here: you are both getting on the brake in the same place. They are simply carrying more speed through the middle, which comes from how the pedal is released rather than when it is pressed.`;
      else if (dBrake !== null && dBrake < -8 && dApex > 1.5) read = `They brake later and still arrive quicker, which means the braking itself is harder and shorter rather than just later. Moving your braking point without also loading the pedal harder will only get you to the apex too fast.`;
      else if (dBrake !== null && dBrake < -8) read = `They brake later and arrive at the same speed you do, so the whole stop is being done in less road. That is a harder initial press, not a braver entry.`;
      else if (dExit > 1.5 || (dPick !== null && dPick > 8)) read = `The entry is close to theirs. The difference is on the way out, which usually points at where the car is pointed at the apex rather than at anything you are doing with your feet.`;
      else read = `No single input stands out, so the difference here is small and spread through the corner.`;

      out.push({ kind: "ref", score: 10 + x.lost, head: `${x.c.name}: you lose ${fmt(x.lost, 2)}s here`, body:
        `Through ${nm(x.c)} you lose ${fmt(x.lost, 2)} seconds. ${bits.length ? (bits.length > 1 ? bits.slice(0, -1).join(", ") + " and " + bits[bits.length - 1] : bits[0]).replace(/^./, m => m.toUpperCase()) + ". " : ""}${read}`,
        corners: [x.c.name] });
    });

    // a difference that is the same everywhere is a different kind of message
    const brakeDiffs = R.corners.map((c, i) => {
      const t = F.corners[i].brake, b = c.brakeBest;
      return (t.touch !== null && b.touch !== null) ? b.touch - t.touch : null;
    }).filter(d => d !== null);
    if (brakeDiffs.length >= 3) {
      const later = brakeDiffs.filter(d => d > 8).length;
      if (later >= Math.ceil(brakeDiffs.length * 0.6)) {
        const med = brakeDiffs.slice().sort((a, b) => a - b)[Math.floor(brakeDiffs.length / 2)];
        out.push({ kind: "ref", score: 9, head: `They brake later nearly everywhere, by about ${Math.round(med)} metres`, body:
          `At ${later} of the ${brakeDiffs.length} corners measured, they get on the brake later than you, with a typical difference of about ${Math.round(med)} metres. A difference that shows up at nearly every corner is not about any one corner: it is a standing margin you are leaving yourself everywhere.`,
          why: `A consistent margin like this is almost never courage, it is certainty. A driver who knows exactly what the car will do from a given speed does not need insurance, so their braking point sits where the car's limit is rather than a safe distance in front of it. The number to take from this is not the metres, it is that the same gap appears everywhere: fixing it is one habit rather than five corners. Move your braking point later in small steps at one corner until the car tells you where the limit actually is, and the rest will follow once you believe it.` });
      } else if (brakeDiffs.filter(d => Math.abs(d) <= 8).length >= Math.ceil(brakeDiffs.length * 0.6)) {
        out.push({ kind: "ref", score: 8, head: "You brake in the same places they do", body:
          `At most corners your braking point is within a few metres of theirs. Wherever the gap is coming from, it is not that they are braver on the way in, and chasing a later braking point is likely to cost you more than it finds.`,
          why: `This is a more useful finding than it looks, because the braking point is the first thing most drivers try to change and it is usually already right. When the braking points match and the lap times do not, the difference is in the shape of what happens next: how hard the pedal goes on, how slowly it comes off, and how early the car can take power on the way out. Those are harder to feel and they are where the time actually is.` });
      }
    }
    // the corner onto the longest straight, where exit speed is worth the most
    const comp = R.corners.findIndex(c => c.name === R.longestRun.opensFrom);
    if (comp >= 0 && F.corners[comp]) {
      const dExit = F.corners[comp].exit - R.corners[comp].exitBest;
      if (dExit > 1) out.push({ kind: "ref", score: 7 + dExit * 0.2, head: `They leave ${R.corners[comp].name} ${fmt(dExit, 1)} mph quicker, onto the longest straight`, body:
        `Out of ${R.corners[comp].name} they are ${fmt(dExit, 1)} mph up on you by the time the corner has finished, and that corner opens onto the longest flat-out stretch on the lap (${Math.round(R.longestRun.metres)} m). A speed advantage at the start of a run that long is still being paid out at the end of it.`,
        why: `Exit speed from the corner before a long straight is the single most valuable thing on a lap, because you carry the difference for every metre of the straight rather than for the length of the corner. It is also why the corner before a straight is worth practising far more than one that leads into another corner. If you only have time to change one thing, change this one, and be willing to give up a little entry speed to get the car pointed down the road sooner.`,
        corners: [R.corners[comp].name] });
    }
    return out;
  }

  // ---------- CSV from the SparksTheory logger ----------
  function parseLoggerCSV(text, name) {
    const lines = text.trim().split(/\r?\n/); const head = lines[0].split(",");
    const ix = Object.fromEntries(head.map((h, i) => [h.trim(), i]));
    const samples = [];
    for (let i = 1; i < lines.length; i++) {
      const c = lines[i].split(","); if (c.length < head.length) continue;
      samples.push({ t: +c[ix.t_s], x: +c[ix.x], y: ix.y !== undefined ? +c[ix.y] : 0, z: +c[ix.z],
        v: ix.speed_mph !== undefined ? +c[ix.speed_mph] : +c[ix.speed_kph] * 0.621371,
        thr: +c[ix.throttle_pct], brk: +c[ix.brake_pct],
        gear: ix.gear !== undefined ? +c[ix.gear] : null, rpm: ix.rpm !== undefined ? +c[ix.rpm] : null,
        lap: ix.lap !== undefined ? +c[ix.lap] : null });
    }
    return { name: name || "lap", samples, multi: ix.lap !== undefined };
  }

  // The replay logger writes one file holding a whole replay, with a lap column,
  // while the lap logger writes one file per lap. So a file with a lap column in
  // it is somebody's replay, which is how a driver captures a reference lap: they
  // watch a top ten replay from the leaderboard and log it. Take the quickest
  // complete lap out of it.
  function bestLapFromReplay(parsed, name) {
    if (!parsed.multi) return null;
    const by = new Map();
    for (const s of parsed.samples) {
      if (s.lap === null) continue;
      if (!by.has(s.lap)) by.set(s.lap, []);
      by.get(s.lap).push(s);
    }
    let best = null;
    for (const [n, ss] of by) {
      if (ss.length < 600) continue;                       // a part lap, or the pit exit
      const dur = ss[ss.length - 1].t - ss[0].t;
      // a complete lap starts and finishes at the line, so the first and last
      // samples should be close together on track
      const gap = Math.hypot(ss[0].x - ss[ss.length - 1].x, ss[0].z - ss[ss.length - 1].z);
      if (gap > 120) continue;
      if (!best || dur < best.dur) best = { n, ss, dur };
    }
    if (!best) return null;
    const t0 = best.ss[0].t;
    return { name: name || ("replay lap " + best.n), samples: best.ss.map(s => {
      const q = {}; for (const k in s) q[k] = s[k]; q.t = s.t - t0; return q;
    }) };
  }

  const api = { analyse, parseLoggerCSV, bestLapFromReplay, findCorners, buildReference, profile, pedalLag };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.LapCoach = api;
})(typeof window !== "undefined" ? window : globalThis);
