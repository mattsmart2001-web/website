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
    let off = null, peak = 0, offJ = null;
    if (touch !== null) {
      const tj = back - Math.round(touch / DS);
      for (let j = tj; j < K.length; j++) { peak = Math.max(peak, brk[j]); if (brk[j] < 30 && m(j) < touch - 10) { off = m(j); offJ = j; break; } }
    }
    // throttle after the slowest point: pick-up (>5%), full (>=95% held 30 m), any lift back below 60% of its peak before full
    let slow = back; for (let j = Math.max(0, back - Math.round(100 / DS)); j < Math.min(K.length, back + Math.round(100 / DS)); j++) if (v[j] < v[slow]) slow = j;
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
    return { lift, touch, full, off, peak, pick, tfull, midLift, coast, overlap, liftGap };
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
      const med = a => { const f = a.filter(x => x !== null).sort((x, y) => x - y); return f.length ? f[Math.floor(f.length / 2)] : null; };
      const kind = vs[bi] < 70 ? "slow" : vs[bi] < 105 ? "medium" : "fast";
      return {
        kind, coastMed: med(bp.map(b => b.coast)), liftGapMed: med(bp.map(b => b.liftGap)), overlapMed: med(bp.map(b => b.overlap)),
        pickMed: med(bp.map(b => b.pick)), tfullMed: med(bp.map(b => b.tfull)), midLifts: bp.filter(b => b.midLift).length,
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
      names, times, best: bi, lapLength: ref.LAP, S: Array.from(ref.S),
      map: Array.from({ length: Math.ceil(ref.xs.length / 5) }, (_, i) => [ref.xs[i * 5], ref.zs[i * 5]]),
      mapS: Array.from({ length: Math.ceil(ref.rs.length / 5) }, (_, i) => ref.rs[i * 5]),
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
    // the pedal as a switch, and early release (no trail braking)
    const stamp = braking.filter(r => r.brakeBest.touch !== null && r.brakeBest.full !== null && r.brakeBest.touch - r.brakeBest.full <= 6);
    const early = braking.filter(r => r.brakeBest.off !== null && r.brakeBest.off > 15);
    if (braking.length && (stamp.length >= Math.ceil(braking.length / 2) || early.length >= Math.ceil(braking.length / 2))) {
      let body = "";
      if (stamp.length) body += `At ${stamp.length} of your ${braking.length} braking corners (${stamp.map(r => r.name).join(", ")}) you go from first touch to full pressure within a few metres: the pedal as a switch. The car takes a big lump of speed off in the first few car lengths, then you are rolling. `;
      if (early.length) body += `At ${early.length} of them you are fully off the brake ${Math.round(Math.min(...early.map(r => r.brakeBest.off)))} to ${Math.round(Math.max(...early.map(r => r.brakeBest.off)))} metres before the apex, so the front tyres are unloaded exactly when you ask them to turn. `;
      body += "Keep the same braking points. Squeeze the first few car lengths at half pressure instead of stamping, build to full, then bleed it off slowly so a little pressure is still on at the turn-in. Trail braking keeps weight on the nose, which is what makes the car turn, and it keeps your speed higher through the whole zone with the same apex speed at the end of it. On most tracks this is where the biggest gap to the front of the leaderboard lives.";
      out.push({ kind: "pedal", score: 3 + 0.4 * stamp.length + 0.3 * early.length, head: "The pedal is a switch. Make it a dial", body, corners: stamp.map(r => r.name) });
    }
    // coasting: the car doing nothing between brake and throttle
    const coasters = braking.filter(r => r.coastMed !== null && r.coastMed > 20).sort((a, b) => b.coastMed - a.coastMed);
    if (coasters.length) {
      const r = coasters[0];
      out.push({ kind: "coast", score: 1.5 + 0.02 * r.coastMed, head: `${r.name}: ${Math.round(r.coastMed)} metres of coasting`, body:
        `Into ${nm(r)} there is a stretch of about ${Math.round(r.coastMed)} metres where neither pedal is doing anything: you are off the brake and not yet on the throttle${coasters.length > 1 ? `, and the same happens at ${coasters.slice(1, 4).map(x => x.name).join(", ")}` : ""}. A car that is coasting is only losing speed. The fix is to make the two ends meet: carry the brake deeper, release it as you turn, and pick the throttle up the moment the release is finished. The slowest point of the corner should be a moment, not a stretch.`, corners: coasters.map(r => r.name) });
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
    const brushed = braking.filter(r => r.brakeBest.touch !== null && r.brakeBest.full === null && r.brakeBest.off !== null && r.brakeBest.off > 50);
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
      samples.push({ t: +c[ix.t_s], x: +c[ix.x], z: +c[ix.z], v: ix.speed_mph !== undefined ? +c[ix.speed_mph] : +c[ix.speed_kph] * 0.621371, thr: +c[ix.throttle_pct], brk: +c[ix.brake_pct] });
    }
    return { name: name || "lap", samples };
  }

  const api = { analyse, parseLoggerCSV, findCorners, buildReference, profile };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.LapCoach = api;
})(typeof window !== "undefined" ? window : globalThis);
