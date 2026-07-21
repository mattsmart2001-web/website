// ============================================================
// send-split-announcement-emails
// POST { event_id, event_name, round, starts_at, circuit_name }
// Auth: Bearer <supabase access token> belonging to an admin.
//
// Emails every driver with a confirmed, split-assigned entry for the
// event — not just lobby hosts (those already get a separate, more
// detailed hosting-instructions email from send-lobby-host-email).
// This is the "hey, check your portal" nudge for drivers who aren't
// on Discord or haven't opted into push notifications.
//
// Sent via Resend's batch endpoint (up to 100 messages per call) so a
// ~150-driver roster only costs 1-2 API requests instead of one per
// driver.
//
// Env vars required:
//   GTEC_SUPABASE_URL       (falls back to SUPABASE_URL if unset)
//   GTEC_SUPABASE_ANON_KEY  (falls back to SUPABASE_ANON_KEY if unset)
//   RESEND_API_KEY
//   GTEC_FROM_EMAIL
// ============================================================

const fetch = require('node-fetch');

const SITE_URL = 'https://sparkstheory.co.uk';
const RESEND_BATCH_SIZE = 100;

const SUPABASE_URL      = process.env.GTEC_SUPABASE_URL      || process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.GTEC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
const RESEND_API_KEY    = process.env.RESEND_API_KEY;
const FROM_EMAIL        = process.env.GTEC_FROM_EMAIL || 'GTEC <GTEC@sparkstheory.co.uk>';

function esc(s) {
    if (s == null) return '';
    return String(s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function shell(title, bodyHtml) {
    return `<!doctype html><html><body style="margin:0;padding:0;background:#050608;font-family:Helvetica,Arial,sans-serif;color:#f1f5f9">
    <table width="100%" cellpadding="0" cellspacing="0" style="background:#050608"><tr><td align="center" style="padding:40px 16px">
    <table width="560" cellpadding="0" cellspacing="0" style="max-width:560px;background:#0a0e15;border:1px solid rgba(255,255,255,0.08);border-radius:14px">
        <tr><td style="padding:32px 32px 8px">
            <div style="font-family:Impact,'Anton',sans-serif;font-size:14px;letter-spacing:0.32em;text-transform:uppercase;color:#f1f5f9">Gran Turismo <span style="color:#ffd166"></span></div>
            <div style="font-family:'Courier New',monospace;font-size:11px;letter-spacing:0.35em;text-transform:uppercase;color:#94a3b8;margin-top:6px">${esc(title)}</div>
        </td></tr>
        <tr><td style="padding:24px 32px 32px;font-size:15px;line-height:1.65;color:#cbd5e1">
            ${bodyHtml}
        </td></tr>
        <tr><td style="padding:18px 32px;background:rgba(255,255,255,0.02);border-top:1px solid rgba(255,255,255,0.06);font-size:12px;color:#64748b;text-align:center">
            <a href="${SITE_URL}/endurance/" style="color:#ffd166;text-decoration:none">sparkstheory.co.uk/endurance</a>
        </td></tr>
    </table>
    </td></tr></table></body></html>`;
}

function formatRaceTime(startsAt) {
    if (!startsAt) return null;
    try {
        const d = new Date(startsAt);
        return d.toUTCString().replace('GMT', 'UTC');
    } catch { return startsAt; }
}

function buildEmail(driverName, eventName, round, lobbyNumber, startsAt, circuitName, hostName, isHost) {
    const name       = esc(driverName || 'Driver');
    const event      = esc(eventName  || 'the upcoming race');
    const raceTime   = formatRaceTime(startsAt);
    const splitLabel = `Split ${lobbyNumber}`;

    const hostLine = isHost
        ? `<p style="background:rgba(255,209,102,0.06);border:1px solid rgba(255,209,102,0.15);border-radius:8px;padding:0.75rem 1rem;font-size:14px;color:#ffd166;margin:0">You're hosting this split — check your inbox for a separate email with full hosting instructions.</p>`
        : (hostName
            ? `<p style="font-size:14px;color:#94a3b8;margin:0">Hosted by <strong style="color:#f1f5f9">${esc(hostName)}</strong>.</p>`
            : `<p style="font-size:14px;color:#94a3b8;margin:0">Host to be confirmed — check the Discord ${lobbyNumber ? `#split-${lobbyNumber}` : 'split'} channel closer to race time.</p>`);

    return {
        subject: `Splits are up — you're in ${splitLabel} · GTEC Round ${round || ''}`.trim().replace(/\s+/g, ' '),
        html: shell('Split Assignment · ' + splitLabel, `
            <h2 style="font-family:Impact,'Anton',sans-serif;font-size:26px;letter-spacing:0.04em;text-transform:uppercase;color:#ffd166;margin:0 0 18px">You're in, ${name}.</h2>
            <p>Splits have been announced for <strong style="color:#f1f5f9">${event}</strong>. You've been assigned to <strong style="color:#f1f5f9">${splitLabel}</strong>.</p>
            ${raceTime ? `<p style="background:rgba(255,209,102,0.08);border:1px solid rgba(255,209,102,0.2);border-radius:8px;padding:0.85rem 1rem;font-family:'Courier New',monospace;font-size:0.9rem;color:#ffd166">${esc(raceTime)}${circuitName ? ` &middot; ${esc(circuitName)}` : ''}</p>` : ''}
            ${hostLine}
            <p style="margin:24px 0"><a href="${SITE_URL}/endurance/profile/" style="display:inline-block;background:#ffd166;color:#000000;text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:900;letter-spacing:0.12em;text-transform:uppercase;font-size:13px">View Your Portal</a></p>
            <p style="font-size:13px;color:#94a3b8">Full lobby settings, room code once posted, and your split history all live in your driver portal. Discord has the room password and live chat for your split.</p>
        `),
    };
}

async function sendBatch(messages) {
    const res = await fetch('https://api.resend.com/emails/batch', {
        method: 'POST',
        headers: {
            Authorization: `Bearer ${RESEND_API_KEY}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(messages),
    });
    const body = await res.json().catch(() => null);
    return { ok: res.ok, status: res.status, body };
}

exports.handler = async (event) => {
    if (event.httpMethod !== 'POST') {
        return { statusCode: 405, body: 'Method not allowed' };
    }
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
        return { statusCode: 500, body: 'Server not configured (Supabase env vars missing).' };
    }
    if (!RESEND_API_KEY) {
        return { statusCode: 500, body: 'Server not configured (RESEND_API_KEY missing).' };
    }

    const auth = event.headers.authorization || event.headers.Authorization || '';
    if (!auth.startsWith('Bearer ')) {
        return { statusCode: 401, body: 'Missing bearer token' };
    }
    const userToken = auth.slice(7);

    let body;
    try { body = JSON.parse(event.body || '{}'); }
    catch { return { statusCode: 400, body: 'Invalid JSON body' }; }

    const { event_id, event_name, round, starts_at, circuit_name } = body;
    if (!event_id) {
        return { statusCode: 400, body: 'event_id is required' };
    }

    const sbHeaders = { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` };

    // Verify caller is admin
    const meRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: sbHeaders });
    if (!meRes.ok) return { statusCode: 401, body: 'Invalid token' };
    const me = await meRes.json();

    const roleRes = await fetch(
        `${SUPABASE_URL}/rest/v1/user_roles?select=role&user_id=eq.${me.id}&role=eq.admin`,
        { headers: sbHeaders }
    );
    const roles = await roleRes.json();
    if (!Array.isArray(roles) || roles.length === 0) {
        return { statusCode: 403, body: 'Admin role required' };
    }

    // Confirmed, split-assigned entries for this event — same scope the
    // portal "Notify Drivers" broadcast uses.
    const entriesRes = await fetch(
        `${SUPABASE_URL}/rest/v1/entries?select=lobby_number,host_driver_id,entry_drivers(driver_id,drivers(id,display_name))` +
        `&event_id=eq.${event_id}&status=eq.confirmed&lobby_number=not.is.null`,
        { headers: sbHeaders }
    );
    const entries = await entriesRes.json();
    if (!Array.isArray(entries) || !entries.length) {
        return { statusCode: 200, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ok: true, count: 0, skipped: 0, host_count: 0 }) };
    }

    // Host name per lobby number, for the "hosted by X" line.
    const hostNameByLobby = new Map();
    const hostDriverIds = new Set();
    entries.forEach(en => {
        if (!en.host_driver_id) return;
        hostDriverIds.add(en.host_driver_id);
        const hostEntry = (en.entry_drivers || []).find(ed => ed.driver_id === en.host_driver_id);
        if (hostEntry?.drivers?.display_name) hostNameByLobby.set(en.lobby_number, hostEntry.drivers.display_name);
    });

    // One row per driver (a driver only appears in one entry per event).
    const driverRows = [];
    const seenDrivers = new Set();
    entries.forEach(en => {
        (en.entry_drivers || []).forEach(ed => {
            if (!ed.driver_id || seenDrivers.has(ed.driver_id)) return;
            seenDrivers.add(ed.driver_id);
            driverRows.push({
                driverId:    ed.driver_id,
                driverName:  ed.drivers?.display_name,
                lobbyNumber: en.lobby_number,
                isHost:      hostDriverIds.has(ed.driver_id),
                hostName:    hostNameByLobby.get(en.lobby_number) || null,
            });
        });
    });

    if (!driverRows.length) {
        return { statusCode: 200, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ok: true, count: 0, skipped: 0, host_count: hostDriverIds.size }) };
    }

    // Look up each driver's email via their most recent linked application.
    const idList = driverRows.map(r => r.driverId).join(',');
    const appsRes = await fetch(
        `${SUPABASE_URL}/rest/v1/applications?select=email,linked_driver_id,created_at&linked_driver_id=in.(${idList})&order=created_at.desc`,
        { headers: sbHeaders }
    );
    const apps = await appsRes.json();
    const emailByDriver = new Map();
    if (Array.isArray(apps)) {
        apps.forEach(a => {
            if (!emailByDriver.has(a.linked_driver_id) && a.email) emailByDriver.set(a.linked_driver_id, a.email);
        });
    }

    const messages = [];
    let skipped = 0;
    driverRows.forEach(r => {
        const email = emailByDriver.get(r.driverId);
        if (!email) { skipped++; return; }
        const tpl = buildEmail(r.driverName, event_name, round, r.lobbyNumber, starts_at, circuit_name, r.hostName, r.isHost);
        messages.push({ from: FROM_EMAIL, to: email, subject: tpl.subject, html: tpl.html });
    });

    let sent = 0;
    const errors = [];
    for (let i = 0; i < messages.length; i += RESEND_BATCH_SIZE) {
        const chunk = messages.slice(i, i + RESEND_BATCH_SIZE);
        const result = await sendBatch(chunk);
        if (result.ok) sent += chunk.length;
        else errors.push(result.body?.message || `Resend batch error ${result.status}`);
    }

    return {
        statusCode: errors.length && sent === 0 ? 502 : 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ok: sent > 0 || messages.length === 0, count: sent, skipped, host_count: hostDriverIds.size, errors: errors.length ? errors : undefined }),
    };
};
