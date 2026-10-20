// ============================================================
// Lap Coach track shape library
//
// Takes the shape of a circuit someone has driven, so the next person who
// drives it gets it recognised by name instead of "Unrecognised track".
//
// What arrives here is 256 numbers describing how hard the car is turning at
// equally spaced points around the lap, plus the name the driver typed and the
// measured length. That is a property of the circuit, not of the driver: there
// is no lap time in it, no speed, no braking, no inputs, and nothing that
// identifies anyone. It cannot be turned back into how fast or how well they
// drove. Nothing is sent unless the driver presses the button.
//
// Submissions land unapproved. They are reviewed before anything is merged into
// the library that ships in lap-coach.js, so a joke name or a scruffy lap
// cannot rename a circuit for everybody.
//
// Env vars required:
//   GTEC_SUPABASE_URL       (falls back to SUPABASE_URL if unset)
//   GTEC_SUPABASE_ANON_KEY  (falls back to SUPABASE_ANON_KEY if unset)
//
// Table: lap_coach_track_shapes
//   id          bigint identity primary key
//   name        text not null          -- what the driver typed
//   length_m    integer not null       -- measured lap length
//   sig         jsonb not null         -- 256 numbers
//   corners     integer                -- how many the analyser found
//   approved    boolean default false
//   created_at  timestamptz default now()
// ============================================================

const fetch = require('node-fetch');

const SUPABASE_URL      = process.env.GTEC_SUPABASE_URL      || process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.GTEC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;

const SIG_N     = 256;
const MAX_NAME  = 60;
const MIN_LEN   = 300;      // metres. Shorter than any real circuit.
const MAX_LEN   = 30000;    // longer than the Nordschleife with room to spare

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json',
  };
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers, body: '' };
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers, body: JSON.stringify({ error: 'POST only' }) };
  }
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: 'Storage not configured' }) };
  }

  let body;
  try { body = JSON.parse(event.body || '{}'); }
  catch (_) { return { statusCode: 400, headers, body: JSON.stringify({ error: 'Bad JSON' }) }; }

  // Validate hard. This endpoint is public, so assume everything arriving is
  // junk until it proves otherwise, and never store something malformed that
  // would then have to be cleaned out of the library by hand.
  const name = String(body.name || '').trim().slice(0, MAX_NAME);
  if (name.length < 2) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: 'Track name too short' }) };
  }
  const length = Math.round(Number(body.length));
  if (!isFinite(length) || length < MIN_LEN || length > MAX_LEN) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: 'Lap length out of range' }) };
  }
  const sig = body.sig;
  if (!Array.isArray(sig) || sig.length !== SIG_N || !sig.every(v => typeof v === 'number' && isFinite(v))) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: `sig must be ${SIG_N} finite numbers` }) };
  }
  // A real lap turns through roughly a full circle or two. A flat signature is
  // a straight line or a bug, not a circuit.
  const spread = Math.max.apply(null, sig) - Math.min.apply(null, sig);
  if (spread < 1) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: 'That does not look like a closed circuit' }) };
  }
  const corners = Number.isFinite(Number(body.corners)) ? Math.round(Number(body.corners)) : null;

  const row = {
    name,
    length_m: length,
    sig: sig.map(v => +v.toFixed(3)),
    corners,
    approved: false,
  };

  try {
    const resp = await fetch(`${SUPABASE_URL}/rest/v1/lap_coach_track_shapes`, {
      method: 'POST',
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
        'Content-Type': 'application/json',
        Prefer: 'return=minimal',
      },
      body: JSON.stringify(row),
    });
    if (!resp.ok) {
      const detail = await resp.text();
      return { statusCode: 502, headers, body: JSON.stringify({ error: 'Could not save', detail: detail.slice(0, 300) }) };
    }
    return { statusCode: 200, headers, body: JSON.stringify({ ok: true, name }) };
  } catch (e) {
    return { statusCode: 502, headers, body: JSON.stringify({ error: 'Could not save', detail: String(e).slice(0, 300) }) };
  }
};
