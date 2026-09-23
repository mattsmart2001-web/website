// ============================================================
// notify-discord-application
// Called by a Supabase Database Webhook on INSERT to public.applications.
//
// Posts a formatted embed to a Discord channel so admins get an
// instant ping every time someone submits a driver or team application.
//
// Env vars required:
//   GTEC_DISCORD_WEBHOOK_URL     — Discord channel webhook URL
// Optional:
//   GTEC_DISCORD_WEBHOOK_SECRET  — If set, must match the
//                                  x-webhook-secret header Supabase sends
//   GTEC_SUPABASE_URL            (falls back to SUPABASE_URL)
// ============================================================

const fetch = require('node-fetch');

const DISCORD_WEBHOOK = process.env.GTEC_DISCORD_WEBHOOK_URL;
const WEBHOOK_SECRET  = process.env.GTEC_DISCORD_WEBHOOK_SECRET || '';
const ADMIN_URL       = 'https://sparkstheory.co.uk/endurance/admin/';

// Discord embed colours
const COLOUR = {
    driver: 0xffd166,  // gold
    team:   0x5dd3ff,  // cyan
};

function shortDR(dr) {
    return dr ? `DR-${dr}` : null;
}
function shortSR(sr) {
    return sr ? `SR-${sr}` : null;
}

function buildEmbed(record) {
    const isTeam  = record.application_type === 'team';
    const name    = record.name || '(no name)';
    const psn     = record.psn || null;
    const discord = record.discord_username || null;
    const number  = record.preferred_number ? `#${record.preferred_number}` : null;
    const dr      = shortDR(record.gt7_dr);
    const sr      = shortSR(record.gt7_sr);
    const email   = record.email || null;
    const notes   = record.notes || null;

    const ratingStr = [dr, sr].filter(Boolean).join(' / ') || null;

    const fields = [];

    if (psn)       fields.push({ name: 'PSN',         value: psn,        inline: true });
    if (discord)   fields.push({ name: 'Discord',      value: discord,    inline: true });
    if (ratingStr) fields.push({ name: 'GT7 Rating',   value: ratingStr,  inline: true });
    if (number)    fields.push({ name: 'Pref. Number', value: number,     inline: true });
    if (email)     fields.push({ name: 'Email',        value: email,      inline: false });
    if (notes) {
        const truncated = notes.length > 200 ? notes.slice(0, 197) + '…' : notes;
        fields.push({ name: 'Notes', value: truncated, inline: false });
    }

    return {
        embeds: [{
            title: isTeam
                ? `🏎️  New Team Application — ${name}`
                : `🪖  New Driver Application — ${name}`,
            url: ADMIN_URL,
            color: isTeam ? COLOUR.team : COLOUR.driver,
            fields,
            footer: {
                text: 'Review it in the GTEC Admin panel',
            },
            timestamp: record.created_at || new Date().toISOString(),
        }],
    };
}

exports.handler = async (event) => {
    if (event.httpMethod !== 'POST') {
        return { statusCode: 405, body: 'Method not allowed' };
    }

    // Verify shared secret if configured
    if (WEBHOOK_SECRET) {
        const incoming = event.headers['x-webhook-secret'] || event.headers['x-supabase-webhook-secret'] || '';
        if (incoming !== WEBHOOK_SECRET) {
            return { statusCode: 401, body: 'Unauthorized' };
        }
    }

    if (!DISCORD_WEBHOOK) {
        console.error('GTEC_DISCORD_WEBHOOK_URL is not set');
        return { statusCode: 500, body: 'Discord webhook URL not configured' };
    }

    let payload;
    try {
        payload = JSON.parse(event.body || '{}');
    } catch {
        return { statusCode: 400, body: 'Invalid JSON' };
    }

    // Supabase Database Webhooks send: { type, table, schema, record, old_record }
    if (payload.type !== 'INSERT' || !payload.record) {
        // Not an insert — ignore silently (Supabase may fire UPDATE too if misconfigured)
        return { statusCode: 200, body: 'ignored' };
    }

    const embed = buildEmbed(payload.record);

    const res = await fetch(DISCORD_WEBHOOK, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(embed),
    });

    if (!res.ok) {
        const text = await res.text();
        console.error('Discord webhook failed:', res.status, text);
        return { statusCode: 502, body: `Discord error ${res.status}` };
    }

    return { statusCode: 200, body: 'ok' };
};
