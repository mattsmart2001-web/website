// ============================================================
// Lap Coach track shape review
//
// Submitted shapes never reach anybody. They sit unapproved until a row is
// pasted by hand into TRACKS in lap-coach.js, which is the only place the
// coach reads from. This endpoint is the review step: it groups what has come
// in by the shape of the circuit rather than by the name typed, so a cluster of
// forty people who all drove the same track appears as one entry with the name
// most of them agreed on, and the one person who typed something rude appears
// as a minority name next to it.
//
// That is the real defence against silly names. Agreement between strangers who
// have never met, about a shape none of them chose, is hard to fake and easy to
// read. The shape decides which group a submission belongs to; the humans only
// vote on what it is called.
//
// GET /.netlify/functions/track-shapes-review?token=...
//   returns the clusters, newest first, each with a ready-to-paste library row
//
// Env vars:
//   LAPCOACH_REVIEW_TOKEN   required, any long random string
//   GTEC_SUPABASE_URL / GTEC_SUPABASE_ANON_KEY (or the SUPABASE_ equivalents)
// ============================================================

const fetch = require('node-fetch');

const SUPABASE_URL      = process.env.GTEC_SUPABASE_URL      || process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.GTEC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
const TOKEN             = process.env.LAPCOACH_REVIEW_TOKEN;

const SAME_TRACK = 0.85;   // the threshold the coach itself uses

function match(a, b, maxShift) {
  maxShift = maxShift === undefined ? 12 : maxShift;
  const mean = v => v.reduce((x, y) => x + y, 0) / v.length;
  const ma = mean(a), mb = mean(b);
  let best = -1;
  for (let s = -maxShift; s <= maxShift; s++) {
    let num = 0, da = 0, db = 0;
    for (let i = 0; i < a.length; i++) {
      const x = a[i] - ma, y = b[(i + s + b.length) % b.length] - mb;
      num += x * y; da += x * x; db += y * y;
    }
    const r = da > 0 && db > 0 ? num / Math.sqrt(da * db) : -1;
    if (r > best) best = r;
  }
  return best;
}

exports.handler = async (event) => {
  const headers = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
  if (!TOKEN || (event.queryStringParameters || {}).token !== TOKEN) {
    return { statusCode: 404, headers, body: JSON.stringify({ error: 'Not found' }) };
  }
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: 'Storage not configured' }) };
  }

  let rows;
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/lap_coach_track_shapes?approved=eq.false&order=created_at.desc&limit=500`,
      { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` } });
    if (!r.ok) throw new Error(await r.text());
    rows = await r.json();
  } catch (e) {
    return { statusCode: 502, headers, body: JSON.stringify({ error: 'Could not read', detail: String(e).slice(0, 300) }) };
  }

  // group by shape, not by name
  const clusters = [];
  for (const row of rows) {
    if (!Array.isArray(row.sig) || !row.sig.length) continue;
    let home = null;
    for (const c of clusters) if (match(row.sig, c.members[0].sig) >= SAME_TRACK) { home = c; break; }
    if (home) home.members.push(row); else clusters.push({ members: [row] });
  }

  // "Interlagos", "interlagos" and "Interlagos " are the same vote. Count on a
  // flattened key so capitalisation does not split a majority, but show the
  // spelling most people actually typed.
  const key = s => String(s).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

  const out = clusters.map(c => {
    const votes = {}, spellings = {};
    for (const m of c.members) {
      const k = key(m.name);
      if (!k) continue;
      votes[k] = (votes[k] || 0) + 1;
      spellings[k] = spellings[k] || {};
      const raw = String(m.name).trim();
      spellings[k][raw] = (spellings[k][raw] || 0) + 1;
    }
    const best = k => Object.entries(spellings[k]).sort((a, b) => b[1] - a[1])[0][0];
    const ranked = Object.entries(votes).sort((a, b) => b[1] - a[1])
      .map(([k, count]) => [best(k), count]);
    const n = c.members.length;
    // average the signatures, which also smooths out one scruffy lap
    const len = c.members[0].sig.length;
    const avg = Array.from({ length: len }, (_, i) =>
      +(c.members.reduce((s, m) => s + (m.sig[i] || 0), 0) / n).toFixed(3));
    const lengths = c.members.map(m => m.length_m).sort((a, b) => a - b);
    const medianLen = lengths[Math.floor(lengths.length / 2)];
    const agreement = ranked[0][1] / n;
    return {
      submissions: n,
      agreedName: ranked[0][0],
      agreement: +agreement.toFixed(2),
      allNames: ranked.map(([name, count]) => ({ name, count })),
      medianLength: medianLen,
      confident: n >= 3 && agreement >= 0.6,
      libraryRow: `{ name: ${JSON.stringify(ranked[0][0])}, length: ${medianLen}, sig: [${avg.join(',')}] },`,
    };
  }).sort((a, b) => b.submissions - a.submissions);

  return { statusCode: 200, headers, body: JSON.stringify({
    submissionsRead: rows.length, distinctTracks: out.length, clusters: out }, null, 1) };
};
