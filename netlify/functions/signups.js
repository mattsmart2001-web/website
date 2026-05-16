const fetch = require('node-fetch');

const FORM_NAME = 'nordschleife-24h-signup';

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Content-Type': 'application/json',
    'Cache-Control': 'public, max-age=30',
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
    // 1. Find the form ID by name.
    const formsResp = await fetch(
      `https://api.netlify.com/api/v1/sites/${SITE_ID}/forms`,
      { headers: { Authorization: `Bearer ${AUTH}` } }
    );
    if (!formsResp.ok) {
      throw new Error(`Forms list failed: ${formsResp.status}`);
    }
    const forms = await formsResp.json();
    const form = forms.find((f) => f.name === FORM_NAME);
    if (!form) {
      return {
        statusCode: 200,
        headers,
        body: JSON.stringify({ count: 0, drivers: [] }),
      };
    }

    // 2. Pull verified submissions (Netlify hides spam from this endpoint).
    const subsResp = await fetch(
      `https://api.netlify.com/api/v1/forms/${form.id}/submissions?per_page=200`,
      { headers: { Authorization: `Bearer ${AUTH}` } }
    );
    if (!subsResp.ok) {
      throw new Error(`Submissions fetch failed: ${subsResp.status}`);
    }
    const subs = await subsResp.json();

    // 3. Strip to public-safe fields only: PSN ID + chosen car.
    const all = subs
      .map((s) => ({
        psn_id: ((s.data && s.data.psn_id) || '').toString().trim(),
        preferred_car: ((s.data && s.data.preferred_car) || '').toString().trim(),
        submitted_at: s.created_at,
      }))
      .filter((d) => d.psn_id)
      // Newest first
      .sort((a, b) => new Date(b.submitted_at) - new Date(a.submitted_at));

    // 4. De-duplicate by PSN ID (case-insensitive), keeping the most recent
    //    entry per driver. Lets drivers re-submit the form to change their
    //    car or correct a typo without admin intervention.
    const seen = new Set();
    const drivers = [];
    for (const d of all) {
      const key = d.psn_id.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      drivers.push(d);
    }

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ count: drivers.length, drivers }),
    };
  } catch (err) {
    console.error('signups function error:', err);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({ error: err.message || 'Unknown error' }),
    };
  }
};
