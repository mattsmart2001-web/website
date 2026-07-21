// ============================================================
// send-lobby-host-email
// POST { driver_id, event_name, round, lobby_number, starts_at }
// Auth: Bearer <supabase access token> belonging to an admin.
//
// Sends a lobby-host notification email to the driver via Resend.
// The driver's email is looked up from their linked application record.
//
// Env vars required:
//   GTEC_SUPABASE_URL       (falls back to SUPABASE_URL if unset)
//   GTEC_SUPABASE_ANON_KEY  (falls back to SUPABASE_ANON_KEY if unset)
//   RESEND_API_KEY
//   GTEC_FROM_EMAIL
// ============================================================

const fetch = require('node-fetch');

const SITE_URL = 'https://sparkstheory.co.uk';

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

function buildRaceSettingsTable(rs) {
    if (!rs) return '';
    const rows = [
        rs.weather         && ['Weather',          rs.weather],
        rs.time_of_day     && ['Time of Day',      rs.time_of_day],
        rs.tyre_wear       && ['Tyre Wear',        rs.tyre_wear],
        rs.fuel_consumption&& ['Fuel Consumption', rs.fuel_consumption],
        rs.time_multiplier && ['Time Multiplier',  rs.time_multiplier],
        rs.damage_level    && ['Damage',           rs.damage_level.charAt(0).toUpperCase() + rs.damage_level.slice(1)],
        rs.slipstream      && ['Slipstream',       rs.slipstream.charAt(0).toUpperCase() + rs.slipstream.slice(1)],
        rs.grip_reduction_off_track && ['Grip Reduction Off Track', rs.grip_reduction_off_track === 'real' ? 'Real' : 'Low'],
        rs.nitrous         && ['Nitrous',          rs.nitrous === 'allowed' ? 'Allowed' : 'Prohibited'],
        rs.engine_swap     && ['Engine Swap',      rs.engine_swap === 'allowed' ? 'Allowed' : 'Prohibited'],
        rs.race_start      && ['Race Start',       { grid_start_fsc: 'Grid Start with False Start Check', grid_start: 'Grid Start', rolling_start: 'Rolling Start' }[rs.race_start] || rs.race_start],
        rs.autodrive       && ['AutoDrive',        rs.autodrive === 'allowed' ? 'Allowed' : 'Prohibited'],
        rs.settings_allowed&& ['Settings Allowed', rs.settings_allowed === 'brake_balance_only' ? 'Brake Balance Only' : 'None'],
        rs.initial_fuel    && ['Initial Fuel',     rs.initial_fuel === '50l' ? '50L' : 'Default'],
        rs.bop_enabled     && ['Balance of Performance', 'Enabled'],
        rs.equal_conditions_mode   && ['Equal Conditions Mode', 'On'],
        rs.shortcut_penalty        && ['Shortcut Penalty', 'On - Weak'],
        rs.wall_collision_penalty  && ['Wall Collision Penalty', 'On - Weak'],
        rs.car_collision_penalty   && ['Car Collision Penalty', 'On'],
        rs.correct_vehicle_course  && ['Correct Vehicle Course', 'On'],
        rs.flag_rules               && ['Flag Rules', 'On'],
        rs.ghosting                && ['Ghosting', 'On'],
        rs.pit_lane_cutting_penalty&& ['Pit Lane Cutting Penalty', 'On'],
    ].filter(Boolean);
    if (!rows.length) return '';
    return `<table style="width:100%;border-collapse:collapse;margin:10px 0 0">
        ${rows.map(([k, v]) => `<tr>
            <td style="padding:5px 10px 5px 0;font-size:13px;color:#94a3b8;white-space:nowrap;vertical-align:top">${esc(k)}</td>
            <td style="padding:5px 0;font-size:13px;color:#f1f5f9;font-weight:600">${esc(String(v))}</td>
        </tr>`).join('')}
    </table>`;
}

function buildEmail(driverName, eventName, round, lobbyNumber, startsAt, raceSettings, qualiSameAsRace, qualiNotes) {
    const name       = esc(driverName || 'Driver');
    const event      = esc(eventName  || 'the upcoming race');
    const raceTime   = formatRaceTime(startsAt);
    const splitLabel = lobbyNumber ? `Split ${lobbyNumber}` : 'your split';
    const settingsTable = buildRaceSettingsTable(raceSettings);
    const qualiBlock = qualiSameAsRace !== false
        ? `<p style="background:rgba(255,209,102,0.06);border:1px solid rgba(255,209,102,0.15);border-radius:8px;padding:0.75rem 1rem;font-size:14px;color:#ffd166;margin:0">Qualifying uses the same lobby settings as the race. No changes needed between sessions.</p>`
        : (qualiNotes
            ? `<p style="background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.1);border-radius:8px;padding:0.75rem 1rem;font-size:14px;color:#cbd5e1;margin:0">${esc(qualiNotes)}</p>`
            : `<p style="font-size:14px;color:#94a3b8;margin:0">Check the race calendar for qualifying-specific settings.</p>`);

    return {
        subject: `You're hosting ${splitLabel} — GTEC Round ${round || ''}`.trim().replace(/\s+/g, ' '),
        html: shell('Lobby Host — ' + splitLabel, `
            <h2 style="font-family:Impact,'Anton',sans-serif;font-size:26px;letter-spacing:0.04em;text-transform:uppercase;color:#ffd166;margin:0 0 18px">You're hosting, ${name}.</h2>
            <p>You've been selected as lobby host for <strong style="color:#f1f5f9">${splitLabel}</strong> at <strong style="color:#f1f5f9">${event}</strong>.</p>
            ${raceTime ? `<p style="background:rgba(255,209,102,0.08);border:1px solid rgba(255,209,102,0.2);border-radius:8px;padding:0.85rem 1rem;font-family:'Courier New',monospace;font-size:0.9rem;color:#ffd166">${esc(raceTime)}</p>` : ''}
            <p><strong style="color:#f1f5f9">What you need to do:</strong></p>
            <ol style="padding-left:1.25rem;color:#cbd5e1;line-height:1.9">
                <li>Create a <strong>Custom Race</strong> lobby in Gran Turismo 7 before the race start time.</li>
                <li>Set the lobby settings as below for qualifying, then update for the race once qualifying is complete.</li>
                <li>Share the lobby password with your split's drivers via the Discord <strong style="color:#f1f5f9">${lobbyNumber ? `#split-${lobbyNumber}` : 'split'}</strong> channel.</li>
                <li>Start the lobby on time — aim to have everyone in the room <strong>15 minutes</strong> before the scheduled start.</li>
                <li>If any driver disconnects within the <strong>first lap</strong>, a restart is allowed. Call it in the Discord channel and requeue everyone.</li>
            </ol>
            ${settingsTable ? `
            <div style="background:rgba(255,255,255,0.03);border:1px solid rgba(255,255,255,0.08);border-radius:10px;padding:16px 20px;margin:16px 0">
                <div style="font-size:11px;font-weight:700;letter-spacing:0.2em;text-transform:uppercase;color:#94a3b8;margin-bottom:6px">Race Settings</div>
                ${settingsTable}
            </div>` : ''}
            <div style="background:rgba(255,255,255,0.03);border:1px solid rgba(255,255,255,0.08);border-radius:10px;padding:16px 20px;margin:16px 0">
                <div style="font-size:11px;font-weight:700;letter-spacing:0.2em;text-transform:uppercase;color:#94a3b8;margin-bottom:10px">Qualifying Settings</div>
                ${qualiBlock}
            </div>
            <p>If you have any problems or cannot host, contact an admin as soon as possible so we can arrange a replacement host.</p>
            <p style="margin:24px 0"><a href="${SITE_URL}/endurance/calendar/" style="display:inline-block;background:#ffd166;color:#000000;text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:900;letter-spacing:0.12em;text-transform:uppercase;font-size:13px">View Race Details</a></p>
            <p style="font-size:13px;color:#94a3b8">Thank you for helping make the championship run smoothly.</p>
        `),
    };
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

    const { driver_id, hosts, event_name, round, starts_at, race_settings, quali_same_as_race, quali_notes, test_email } = body;
    let { lobby_number } = body;
    const bulkMode = Array.isArray(hosts) && hosts.length > 0;
    if (!driver_id && !bulkMode && !test_email) {
        return { statusCode: 400, body: 'driver_id (or hosts[]) is required' };
    }

    // Verify caller is admin
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

    const sbHeaders = { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` };

    // Test mode — no driver data is queried; sends one sample hosting-
    // instructions email straight to the given address.
    if (test_email) {
        const tpl = buildEmail('Test Host', event_name || 'Test Event', round || 1, lobby_number || 1, starts_at, race_settings, quali_same_as_race, quali_notes);
        const resendRes = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({ from: FROM_EMAIL, to: test_email, subject: tpl.subject, html: tpl.html }),
        });
        const resendBody = await resendRes.json().catch(() => null);
        if (!resendRes.ok) {
            return { statusCode: 502, body: JSON.stringify({ ok: false, error: resendBody?.message || `Resend error ${resendRes.status}` }) };
        }
        return {
            statusCode: 200,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ok: true, test: true, sent_to: test_email }),
        };
    }

    // ------------------------------------------------------------------
    // Bulk mode — one Resend batch call for every host in the round,
    // instead of one Resend request per host. Keeps a whole round's host
    // notifications inside Resend's per-second request-rate limit
    // regardless of how many splits it has.
    // ------------------------------------------------------------------
    if (bulkMode) {
        const driverIds = hosts.map(h => h.driver_id).filter(Boolean);
        const idList = driverIds.join(',');

        const [drvRes, appRes] = await Promise.all([
            fetch(`${SUPABASE_URL}/rest/v1/drivers?select=id,display_name&id=in.(${idList})`, { headers: sbHeaders }),
            fetch(`${SUPABASE_URL}/rest/v1/applications?select=email,linked_driver_id,created_at&linked_driver_id=in.(${idList})&order=created_at.desc`, { headers: sbHeaders }),
        ]);
        const drvRows = await drvRes.json();
        const appRows = await appRes.json();

        const nameByDriver  = new Map((Array.isArray(drvRows) ? drvRows : []).map(d => [d.id, d.display_name]));
        const emailByDriver = new Map();
        (Array.isArray(appRows) ? appRows : []).forEach(a => {
            if (!emailByDriver.has(a.linked_driver_id) && a.email) emailByDriver.set(a.linked_driver_id, a.email);
        });

        const messages = [];
        let skipped = 0;
        hosts.forEach(h => {
            const email = emailByDriver.get(h.driver_id);
            if (!email) { skipped++; return; }
            const tpl = buildEmail(nameByDriver.get(h.driver_id), event_name, round, h.lobby_number, starts_at, race_settings, quali_same_as_race, quali_notes);
            messages.push({ from: FROM_EMAIL, to: email, subject: tpl.subject, html: tpl.html });
        });

        let sent = 0;
        const errors = [];
        for (let i = 0; i < messages.length; i += 100) {
            const chunk = messages.slice(i, i + 100);
            const res = await fetch('https://api.resend.com/emails/batch', {
                method: 'POST',
                headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
                body: JSON.stringify(chunk),
            });
            const resBody = await res.json().catch(() => null);
            if (res.ok) sent += chunk.length;
            else errors.push(resBody?.message || `Resend batch error ${res.status}`);
        }

        return {
            statusCode: errors.length && sent === 0 ? 502 : 200,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ok: sent > 0 || messages.length === 0, count: sent, skipped, errors: errors.length ? errors : undefined }),
        };
    }

    // ------------------------------------------------------------------
    // Single mode — unchanged, used by the manual "Set Host" action.
    // ------------------------------------------------------------------

    // Look up driver display name
    const drvRes = await fetch(
        `${SUPABASE_URL}/rest/v1/drivers?select=display_name&id=eq.${driver_id}`,
        { headers: sbHeaders }
    );
    const drvRows = await drvRes.json();
    const driverName = Array.isArray(drvRows) ? drvRows[0]?.display_name : null;

    // Look up driver email via their linked application record
    const appRes = await fetch(
        `${SUPABASE_URL}/rest/v1/applications?select=email&linked_driver_id=eq.${driver_id}&order=created_at.desc&limit=1`,
        { headers: sbHeaders }
    );
    const appRows = await appRes.json();
    const email = Array.isArray(appRows) ? appRows[0]?.email : null;

    if (!email) {
        return { statusCode: 404, body: `No email address found for driver ${driver_id}` };
    }

    const tpl = buildEmail(driverName, event_name, round, lobby_number, starts_at, race_settings, quali_same_as_race, quali_notes);

    // Send via Resend
    const resendRes = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
            Authorization: `Bearer ${RESEND_API_KEY}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({
            from: FROM_EMAIL,
            to: email,
            subject: tpl.subject,
            html: tpl.html,
        }),
    });

    const resendBody = await resendRes.json();
    if (!resendRes.ok) {
        return {
            statusCode: 502,
            body: JSON.stringify({ ok: false, error: resendBody?.message || `Resend error ${resendRes.status}` }),
        };
    }

    return {
        statusCode: 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ok: true, provider_id: resendBody?.id || null, sent_to: email }),
    };
};
