const fetch = require('node-fetch');

const DISCORD_API = 'https://discord.com/api/v10';
const FORM_NAME   = 'nordschleife-24h-signup';

/**
 * Netlify auto-invokes this function whenever a form submission is verified.
 * We use it to look up the new signup's Discord username in your server and
 * assign them the configured "Driver" role, which in turn grants channel
 * access via Discord's role-permission system.
 *
 * Required env vars on the Netlify site:
 *   DISCORD_BOT_TOKEN       — the bot's token
 *   DISCORD_GUILD_ID        — your server's ID
 *   DISCORD_DRIVER_ROLE_ID  — the role to assign to verified drivers
 */
exports.handler = async (event) => {
  const BOT_TOKEN = process.env.DISCORD_BOT_TOKEN;
  const GUILD_ID  = process.env.DISCORD_GUILD_ID;
  const ROLE_ID   = process.env.DISCORD_DRIVER_ROLE_ID;

  // Always return 200 — we don't want Netlify to mark the submission as
  // failed just because Discord is down or misconfigured.
  const ok = { statusCode: 200, body: '' };

  if (!BOT_TOKEN || !GUILD_ID || !ROLE_ID) {
    console.error('[discord] Missing one of DISCORD_BOT_TOKEN / DISCORD_GUILD_ID / DISCORD_DRIVER_ROLE_ID');
    return ok;
  }

  let payload;
  try {
    payload = JSON.parse(event.body || '{}');
  } catch (e) {
    console.error('[discord] Could not parse submission body:', e.message);
    return ok;
  }

  // Netlify wraps the form data inside payload.payload.
  const sub  = payload && payload.payload;
  const data = sub && sub.data;
  if (!sub || !data) return ok;
  if (sub.form_name !== FORM_NAME) return ok;

  const rawHandle = (data.discord_username || '').toString().trim();
  if (!rawHandle) {
    console.log('[discord] No discord_username on submission — skipping.');
    return ok;
  }

  // Normalise the handle: strip leading "@" and any old-style "#1234"
  // discriminator suffix, lowercase.
  const wanted = rawHandle.replace(/^@+/, '').split('#')[0].trim().toLowerCase();
  if (!wanted) return ok;

  try {
    // Search the guild for members whose username/nickname matches.
    const searchUrl =
      `${DISCORD_API}/guilds/${GUILD_ID}/members/search` +
      `?query=${encodeURIComponent(wanted)}&limit=10`;
    const searchResp = await fetch(searchUrl, {
      headers: { Authorization: `Bot ${BOT_TOKEN}` },
    });
    if (!searchResp.ok) {
      const body = await searchResp.text();
      console.error(`[discord] Member search ${searchResp.status}: ${body}`);
      return ok;
    }
    const members = await searchResp.json();
    if (!Array.isArray(members) || !members.length) {
      console.log(`[discord] No server members found matching "${rawHandle}". Driver may need to join the server.`);
      return ok;
    }

    // Prefer exact match on the unique username; fall back to global_name
    // or nickname; otherwise take the first hit.
    const match = members.find((m) => {
      const u  = m.user && (m.user.username  || '').toLowerCase();
      const gn = m.user && (m.user.global_name || '').toLowerCase();
      const nick = (m.nick || '').toLowerCase();
      return u === wanted || gn === wanted || nick === wanted;
    }) || members[0];

    const userId = match.user && match.user.id;
    if (!userId) {
      console.error('[discord] Matched member had no user id');
      return ok;
    }

    // Already has the role? Skip the PUT.
    if (Array.isArray(match.roles) && match.roles.includes(ROLE_ID)) {
      console.log(`[discord] ${match.user.username} (PSN: ${data.psn_id}) already has the driver role.`);
      return ok;
    }

    const roleUrl = `${DISCORD_API}/guilds/${GUILD_ID}/members/${userId}/roles/${ROLE_ID}`;
    const roleResp = await fetch(roleUrl, {
      method: 'PUT',
      headers: { Authorization: `Bot ${BOT_TOKEN}` },
    });
    if (!roleResp.ok) {
      const body = await roleResp.text();
      console.error(`[discord] Role assign ${roleResp.status}: ${body}`);
      return ok;
    }
    console.log(`[discord] Assigned driver role to ${match.user.username} (PSN: ${data.psn_id || '—'}).`);
  } catch (err) {
    console.error('[discord] Unhandled error:', err && err.message);
  }
  return ok;
};
