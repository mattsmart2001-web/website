const fetch = require('node-fetch');

const FORM_NAME = 'reaction-time-leaderboard';

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Content-Type': 'application/json',
    'Cache-Control': 'public, max-age=15',
  };
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers, body: '' };
  }

  const SITE_ID = process.env.NETLIFY_SITE_ID;
  const AUTH    = process.env.NETLIFY_AUTH_TOKEN;
  if (!SITE_ID || !AUTH) {
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({
        error: 'Missing NETLIFY_SITE_ID or NETLIFY_AUTH_TOKEN env var on the Netlify site.',
      }),
    };
  }

  try {
    // Find form id by name.
    const formsResp = await fetch(
      `https://api.netlify.com/api/v1/sites/${SITE_ID}/forms`,
      { headers: { Authorization: `Bearer ${AUTH}` } }
    );
    if (!formsResp.ok) throw new Error(`Forms list failed: ${formsResp.status}`);
    const forms = await formsResp.json();
    const form = forms.find((f) => f.name === FORM_NAME);
    if (!form) {
      return {
        statusCode: 200,
        headers,
        body: JSON.stringify({ count: 0, scores: [] }),
      };
    }

    const subsResp = await fetch(
      `https://api.netlify.com/api/v1/forms/${form.id}/submissions?per_page=500`,
      { headers: { Authorization: `Bearer ${AUTH}` } }
    );
    if (!subsResp.ok) throw new Error(`Submissions fetch failed: ${subsResp.status}`);
    const subs = await subsResp.json();

    // Parse + sanitise.
    const rows = subs
      .map((s) => {
        const name = ((s.data && s.data.name) || '').toString().trim().slice(0, 24);
        const ms   = parseInt((s.data && s.data.time_ms) || '0', 10);
        return { name, time_ms: ms, created_at: s.created_at };
      })
      .filter((r) => r.name && r.time_ms >= 80 && r.time_ms <= 2000);

    // Keep each name's best time only, so the leaderboard doesn't fill up
    // with one person's repeat attempts.
    const bestByName = new Map();
    for (const r of rows) {
      const key = r.name.toLowerCase();
      const existing = bestByName.get(key);
      if (!existing || r.time_ms < existing.time_ms) {
        bestByName.set(key, r);
      }
    }
    const scores = [...bestByName.values()]
      .sort((a, b) => a.time_ms - b.time_ms || new Date(a.created_at) - new Date(b.created_at))
      .slice(0, 50);

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ count: scores.length, scores }),
    };
  } catch (err) {
    console.error('reaction-scores function error:', err);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({ error: err.message || 'Unknown error' }),
    };
  }
};
