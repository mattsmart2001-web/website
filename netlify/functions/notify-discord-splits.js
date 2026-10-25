// ============================================================
// notify-discord-splits
// POST { event_id, event_name, round }
// Auth: Bearer <supabase admin token>
//
// Fetches the split assignments for an event and posts a summary
// embed to the #split-announcements Discord channel so drivers can see their
// split without opening the portal.
//
// Env vars required:
//   GTEC_DISCORD_BOT_TOKEN      — Discord bot token
//   DISCORD_SPLITS_CHANNEL_ID   — #split-announcements channel ID
//   GTEC_SUPABASE_URL           (falls back to SUPABASE_URL)
//   GTEC_SUPABASE_ANON_KEY      (falls back to SUPABASE_ANON_KEY)
// ============================================================

const fetch = require('node-fetch');

const SUPABASE_URL      = process.env.GTEC_SUPABASE_URL      || process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.GTEC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
const BOT_TOKEN         = process.env.GTEC_DISCORD_BOT_TOKEN;
const SPLITS_CHANNEL    = process.env.DISCORD_SPLITS_CHANNEL_ID;

const DISCORD_API = 'https://discord.com/api/v10';

// Embed colour per split number (cycles after 5)
const SPLIT_COLOURS = [0xffd166, 0x5dd3ff, 0x4ade80, 0xf97316, 0xc084fc];

exports.handler = async (event) => {
    if (event.httpMethod !== 'POST') {
        return { statusCode: 405, body: 'Method not allowed' };
    }

    if (!BOT_TOKEN)      return { statusCode: 500, body: 'GTEC_DISCORD_BOT_TOKEN not configured' };
    if (!SPLITS_CHANNEL) return { statusCode: 500, body: 'DISCORD_SPLITS_CHANNEL_ID not configured' };
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

    const { event_id, event_name, round } = body;
    if (!event_id) return { statusCode: 400, body: 'event_id required' };

    // Fetch entries with drivers and lobby numbers
    const entriesRes = await fetch(
        `${SUPABASE_URL}/rest/v1/entries?select=lobby_number,car_number,teams(name),entry_drivers(drivers(display_name,career_number))&event_id=eq.${event_id}&order=lobby_number`,
        { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` } }
    );
    const entries = await entriesRes.json();
    if (!Array.isArray(entries) || entries.length === 0) {
        return { statusCode: 404, body: 'No entries found for this event' };
    }

    // Group by lobby_number
    const splits = {};
    for (const en of entries) {
        const num = en.lobby_number ?? 0;
        if (!splits[num]) splits[num] = [];
        const drivers = (en.entry_drivers || []).map(ed => ed.drivers?.display_name).filter(Boolean);
        const number  = en.car_number ? `#${en.car_number}` : null;
        const team    = en.teams?.name || null;
        splits[num].push({ drivers, number, team });
    }

    const sortedNums = Object.keys(splits).map(Number).filter(n => n > 0).sort((a, b) => a - b);
    if (sortedNums.length === 0) {
        return { statusCode: 400, body: 'No split assignments set for this event' };
    }

    const label = [
        event_name || 'Upcoming Event',
        round ? `· Round ${round}` : '',
    ].filter(Boolean).join(' ');

    const embeds = sortedNums.map((num, i) => {
        const rows = splits[num];
        const lines = rows.map(r => {
            const parts = [];
            if (r.number) parts.push(r.number);
            if (r.team)   parts.push(r.team);
            const drvStr = r.drivers.length ? r.drivers.join(' & ') : '(TBC)';
            parts.push(drvStr);
            return parts.join(' · ');
        });
        return {
            title: `Split ${num}`,
            description: lines.join('\n'),
            color: SPLIT_COLOURS[i % SPLIT_COLOURS.length],
        };
    });

    // Prepend a header embed
    const headerEmbed = {
        title: `🏁  Split Assignments — ${label}`,
        description: `${sortedNums.length} split${sortedNums.length === 1 ? '' : 's'} · ${entries.length} entr${entries.length === 1 ? 'y' : 'ies'}`,
        color: 0xffffff,
    };

    // Discord allows up to 10 embeds per message
    const allEmbeds = [headerEmbed, ...embeds].slice(0, 10);

    const discordRes = await fetch(`${DISCORD_API}/channels/${SPLITS_CHANNEL}/messages`, {
        method: 'POST',
        headers: {
            Authorization: `Bot ${BOT_TOKEN}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({ embeds: allEmbeds }),
    });

    if (!discordRes.ok) {
        const text = await discordRes.text();
        console.error('Discord post failed:', discordRes.status, text);
        return { statusCode: 502, body: `Discord error ${discordRes.status}: ${text}` };
    }

    return {
        statusCode: 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ok: true, splits: sortedNums.length }),
    };
};
