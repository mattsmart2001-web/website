const fetch = require('node-fetch');

const DISCORD_API = 'https://discord.com/api/v10';
const FORM_NAME   = 'nordschleife-24h-signup';

/**
 * One-shot backfill: pulls every existing nordschleife-24h-signup submission
 * via the Netlify Forms API and runs the same Discord role-assignment that
 * submission-created.js does for new signups.
 *
 * Trigger by visiting:
 *   /.netlify/functions/backfill-discord?token=<BACKFILL_TOKEN>
 *
 * Idempotent — drivers already holding the role are silently skipped.
 *
 * Required env vars (same as the live signups + submission-created flows):
 *   NETLIFY_SITE_ID
 *   NETLIFY_AUTH_TOKEN
 *   DISCORD_BOT_TOKEN
 *   DISCORD_GUILD_ID
 *   DISCORD_DRIVER_ROLE_ID
 *   BACKFILL_TOKEN          shared secret protecting this endpoint
 */
exports.handler = async (event) => {
  const BACKFILL = process.env.BACKFILL_TOKEN;
  const provided = (event.queryStringParameters || {}).token;
  if (!BACKFILL || provided !== BACKFILL) {
    return {
      statusCode: 401,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: 'Missing or invalid token' }),
    };
  }

  const SITE_ID      = process.env.NETLIFY_SITE_ID;
  const NETLIFY_AUTH = process.env.NETLIFY_AUTH_TOKEN;
  const BOT_TOKEN    = process.env.DISCORD_BOT_TOKEN;
  const GUILD_ID     = process.env.DISCORD_GUILD_ID;
  const ROLE_ID      = process.env.DISCORD_DRIVER_ROLE_ID;
  if (!SITE_ID || !NETLIFY_AUTH || !BOT_TOKEN || !GUILD_ID || !ROLE_ID) {
    return {
      statusCode: 500,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: 'Missing one or more required env vars' }),
    };
  }

  try {
    // 1. Find the form ID.
    const formsResp = await fetch(
      `https://api.netlify.com/api/v1/sites/${SITE_ID}/forms`,
      { headers: { Authorization: `Bearer ${NETLIFY_AUTH}` } }
    );
    if (!formsResp.ok) throw new Error(`Forms list failed: ${formsResp.status}`);
    const forms = await formsResp.json();
    const form = forms.find((f) => f.name === FORM_NAME);
    if (!form) {
      return {
        statusCode: 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ processed: 0, results: [], note: 'Form not found' }),
      };
    }

    // 2. Pull verified submissions.
    const subsResp = await fetch(
      `https://api.netlify.com/api/v1/forms/${form.id}/submissions?per_page=200`,
      { headers: { Authorization: `Bearer ${NETLIFY_AUTH}` } }
    );
    if (!subsResp.ok) throw new Error(`Submissions fetch failed: ${subsResp.status}`);
    const subs = await subsResp.json();

    // 3. Walk through submissions and run role-assignment for each one.
    const results = [];
    for (const sub of subs) {
      const data = (sub && sub.data) || {};
      const psn  = (data.psn_id || '').toString().trim();
      const raw  = (data.discord_username || '').toString().trim();
      if (!raw) {
        results.push({ psn, status: 'no_discord_handle' });
        continue;
      }
      const wanted = raw.replace(/^@+/, '').split('#')[0].trim().toLowerCase();
      if (!wanted) {
        results.push({ psn, status: 'no_discord_handle' });
        continue;
      }

      // Tiny delay to be polite to the Discord rate limiter.
      await new Promise((r) => setTimeout(r, 250));

      try {
        const searchUrl =
          `${DISCORD_API}/guilds/${GUILD_ID}/members/search` +
          `?query=${encodeURIComponent(wanted)}&limit=10`;
        const searchResp = await fetch(searchUrl, {
          headers: { Authorization: `Bot ${BOT_TOKEN}` },
        });
        if (!searchResp.ok) {
          results.push({ psn, discord: raw, status: `search_${searchResp.status}` });
          continue;
        }
        const members = await searchResp.json();
        if (!Array.isArray(members) || !members.length) {
          results.push({ psn, discord: raw, status: 'not_in_server' });
          continue;
        }

        const match = members.find((m) => {
          const u  = m.user && (m.user.username   || '').toLowerCase();
          const gn = m.user && (m.user.global_name || '').toLowerCase();
          const nk = (m.nick || '').toLowerCase();
          return u === wanted || gn === wanted || nk === wanted;
        }) || members[0];

        const userId = match.user && match.user.id;
        if (!userId) {
          results.push({ psn, discord: raw, status: 'no_user_id' });
          continue;
        }

        if (Array.isArray(match.roles) && match.roles.includes(ROLE_ID)) {
          results.push({ psn, discord: match.user.username, status: 'already_has_role' });
          continue;
        }

        const roleResp = await fetch(
          `${DISCORD_API}/guilds/${GUILD_ID}/members/${userId}/roles/${ROLE_ID}`,
          { method: 'PUT', headers: { Authorization: `Bot ${BOT_TOKEN}` } }
        );
        if (!roleResp.ok) {
          results.push({ psn, discord: match.user.username, status: `role_${roleResp.status}` });
          continue;
        }
        results.push({ psn, discord: match.user.username, status: 'role_assigned' });
      } catch (err) {
        results.push({ psn, discord: raw, status: `error: ${err.message}` });
      }
    }

    // Summarise for quick visual scanning at the top of the response.
    const summary = results.reduce((acc, r) => {
      acc[r.status] = (acc[r.status] || 0) + 1;
      return acc;
    }, {});

    return {
      statusCode: 200,
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
      },
      body: JSON.stringify({ processed: results.length, summary, results }, null, 2),
    };
  } catch (err) {
    return {
      statusCode: 500,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: err.message || 'Unknown error' }),
    };
  }
};
