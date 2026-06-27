// ============================================================
// notify-discord-results
// POST { event_id, event_name, article_slug }
// Auth: Bearer <supabase admin token>
//
// Fetches the top-3 finishers per split for an event and posts
// a summary embed to the #results Discord channel with a link
// to the full race report article.
//
// Env vars required:
//   GTEC_DISCORD_BOT_TOKEN       — Discord bot token
//   DISCORD_RESULTS_CHANNEL_ID   — #results channel ID
//   GTEC_SUPABASE_URL            (falls back to SUPABASE_URL)
//   GTEC_SUPABASE_ANON_KEY       (falls back to SUPABASE_ANON_KEY)
// ============================================================

const fetch = require('node-fetch');

const SUPABASE_URL      = process.env.GTEC_SUPABASE_URL      || process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.GTEC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
const BOT_TOKEN         = process.env.GTEC_DISCORD_BOT_TOKEN;
const RESULTS_CHANNEL   = process.env.DISCORD_RESULTS_CHANNEL_ID;
const SITE_URL          = 'https://sparkstheory.co.uk';

const DISCORD_API = 'https://discord.com/api/v10';

const MEDALS = ['🥇', '🥈', '🥉'];
const SPLIT_COLOURS = [0xffd166, 0x5dd3ff, 0x4ade80, 0xf97316, 0xc084fc];

exports.handler = async (event) => {
    if (event.httpMethod !== 'POST') {
        return { statusCode: 405, body: 'Method not allowed' };
    }

    if (!BOT_TOKEN)        return { statusCode: 500, body: 'GTEC_DISCORD_BOT_TOKEN not configured' };
    if (!RESULTS_CHANNEL)  return { statusCode: 500, body: 'DISCORD_RESULTS_CHANNEL_ID not configured' };
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
        return { statusCode: 500, body: 'Supabase env vars not configured' };
    }

    // Verify admin
    const auth = event.headers.authorization || event.headers.Authorization || '';
    if (!auth.startsWith('Bearer ')) return { statusCode: 401, body: 'Missing bearer token' };
    const userToken = auth.slice(7);

    const meRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
        headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` },
    });
    if (!meRes.ok) return { statusCode: 401, body: 'Invalid token' };
    const me = await meRes.json();

    const roleRes = await fetch(
        `${SUPABASE_URL}/rest/v1/user_roles?select=role&user_id=eq.${me.id}&role=eq.admin`,
        { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` } }
    );
    const roles = await roleRes.json();
    if (!Array.isArray(roles) || roles.length === 0) {
        return { statusCode: 403, body: 'Admin role required' };
    }

    let body;
    try { body = JSON.parse(event.body || '{}'); }
    catch { return { statusCode: 400, body: 'Invalid JSON' }; }

    const { event_id, event_name, article_slug, round } = body;
    if (!event_id) return { statusCode: 400, body: 'event_id required' };

    const headers = { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` };

    // Query results → entries (for lobby_number/split) → result_drivers (for per-driver finish)
    const rRes = await fetch(
        `${SUPABASE_URL}/rest/v1/results` +
        `?select=id,entries(lobby_number),result_drivers(finish_position,status,drivers(display_name))` +
        `&event_id=eq.${event_id}` +
        `&order=entries(lobby_number)`,
        { headers }
    );
    const resultsRaw = await rRes.json();

    if (!Array.isArray(resultsRaw) || resultsRaw.length === 0) {
        return { statusCode: 404, body: 'No results found for this event' };
    }

    // Flatten to one row per driver with the split they ran in
    const rdRows = resultsRaw.flatMap(r =>
        (r.result_drivers || []).map(rd => ({
            finish_position: rd.finish_position,
            status:          rd.status,
            driver_name:     rd.drivers?.display_name || null,
            lobby_number:    r.entries?.lobby_number ?? 1,
        }))
    );

    if (rdRows.length === 0) {
        return { statusCode: 404, body: 'No driver results found for this event' };
    }

    const splitFor = rd => rd.lobby_number ?? 1;

    // Group classified finishers by split
    const splits = {};
    for (const rd of rdRows) {
        const split = splitFor(rd);
        if (!splits[split]) splits[split] = [];
        splits[split].push(rd);
    }

    const sortedSplits = Object.keys(splits).map(Number).sort((a, b) => a - b);

    const label = [
        event_name || 'Race Results',
        round ? `· Round ${round}` : '',
    ].filter(Boolean).join(' ');

    const articleUrl = article_slug
        ? `${SITE_URL}/endurance/news/?article=${article_slug}`
        : `${SITE_URL}/endurance/news/`;

    const splitEmbeds = sortedSplits.map((splitNum, i) => {
        const rows = splits[splitNum]
            .filter(rd => rd.finish_position != null)
            .sort((a, b) => a.finish_position - b.finish_position);

        const lines = rows.map(rd => {
            const pos    = rd.finish_position;
            const medal  = MEDALS[pos - 1] || `P${pos}`;
            const name   = rd.driver_name || '(Unknown)';
            const status = rd.status && rd.status !== 'classified' ? ` *(${rd.status.toUpperCase()})*` : '';
            return `${medal} ${name}${status}`;
        });

        if (lines.length === 0) lines.push('No classified finishers');

        return {
            title: sortedSplits.length > 1 ? `Split ${splitNum}` : 'Results',
            description: lines.join('\n'),
            color: SPLIT_COLOURS[i % SPLIT_COLOURS.length],
        };
    });

    const headerEmbed = {
        title: `🏁  ${label}`,
        description: `[Read the full race report](${articleUrl})`,
        color: 0xffffff,
        url: articleUrl,
    };

    const allEmbeds = [headerEmbed, ...splitEmbeds].slice(0, 10);

    const discordRes = await fetch(`${DISCORD_API}/channels/${RESULTS_CHANNEL}/messages`, {
        method: 'POST',
        headers: {
            Authorization: `Bot ${BOT_TOKEN}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({ embeds: allEmbeds }),
    });

    if (!discordRes.ok) {
        const text = await discordRes.text();
        console.error('Discord results post failed:', discordRes.status, text);
        return { statusCode: 502, body: `Discord error ${discordRes.status}: ${text}` };
    }

    return {
        statusCode: 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ok: true }),
    };
};
