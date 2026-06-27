// ============================================================
// send-application-email
// POST { application_id, email_type }
// Auth: Bearer <supabase access token> belonging to an admin.
//
// Sends an acceptance / waitlist / rejection email via Resend and
// logs the result to public.application_emails.
// On acceptance, also assigns the Discord "Driver" role if the applicant
// is already in the server and their discord_username is on record.
//
// Env vars required:
//   GTEC_SUPABASE_URL       (falls back to SUPABASE_URL if unset)
//   GTEC_SUPABASE_ANON_KEY  (falls back to SUPABASE_ANON_KEY if unset)
//   RESEND_API_KEY
//   GTEC_FROM_EMAIL         (e.g. "GTEC <noreply@yourdomain.com>")
//   GTEC_DISCORD_BOT_TOKEN  — Discord bot token (required for role assignment)
// ============================================================

const fetch = require('node-fetch');

const SITE_URL    = 'https://sparkstheory.co.uk';
const DISCORD_URL = 'https://discord.gg/rMRNYNXnZx';

// Discord constants — guild and Driver role are fixed for this deployment.
const DISCORD_GUILD_ID   = '1063051073536929845';
const DISCORD_DRIVER_ROLE = '1520483316418085107';

const SUPABASE_URL      = process.env.GTEC_SUPABASE_URL      || process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.GTEC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
const RESEND_API_KEY    = process.env.RESEND_API_KEY;
const FROM_EMAIL        = process.env.GTEC_FROM_EMAIL
    || 'GTEC <GTEC@sparkstheory.co.uk>';

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
            &nbsp;·&nbsp;
            <a href="${DISCORD_URL}" style="color:#ffd166;text-decoration:none">Discord</a>
        </td></tr>
    </table>
    </td></tr></table></body></html>`;
}

function templateFor(emailType, app, claimUrl) {
    const name = esc(app.name || 'racer');
    switch (emailType) {
        case 'accepted':
            return {
                subject: 'You\'re in — GTEC',
                html: shell('Application Accepted', `
                    <h2 style="font-family:Impact,'Anton',sans-serif;font-size:26px;letter-spacing:0.04em;text-transform:uppercase;color:#ffd166;margin:0 0 18px">Welcome to the grid, ${name}.</h2>
                    <p>Your application to GTEC has been <strong style="color:#4ade80">accepted</strong>. Congrats.</p>
                    ${claimUrl ? `
                    <p>To set up your driver portal — where you'll see your standings, race history, lobby allocations and admin messages — open the secure link below and pick a password. It's valid for 24 hours.</p>
                    <p style="margin:20px 0"><a href="${claimUrl}" style="display:inline-block;background:#ffd166;color:#1a1300;text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:700;letter-spacing:0.15em;text-transform:uppercase;font-size:12px">Activate Your Profile</a></p>
                    <p style="font-size:12px;color:#94a3b8;word-break:break-all">If the button doesn't work, paste this into your browser:<br><a href="${claimUrl}" style="color:#ffd166">${claimUrl}</a></p>
                    ` : ''}
                    <p>Jump into the Discord to meet the rest of the grid.</p>
                    <p style="margin:24px 0"><a href="${DISCORD_URL}" style="display:inline-block;background:rgba(255,255,255,0.06);color:#f1f5f9;border:1px solid rgba(255,255,255,0.15);text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:700;letter-spacing:0.15em;text-transform:uppercase;font-size:12px">Join the SparksTheory Discord</a></p>
                    <p style="font-size:13px;color:#94a3b8">See you on track.</p>`),
            };
        case 'waitlisted':
            return {
                subject: 'Waitlisted — GTEC',
                html: shell('Application Waitlisted', `
                    <h2 style="font-family:Impact,'Anton',sans-serif;font-size:24px;letter-spacing:0.04em;text-transform:uppercase;color:#ffd166;margin:0 0 18px">Thanks for applying, ${name}.</h2>
                    <p>The grid is full for now, but we'd like to keep you on the <strong>waitlist</strong>. If a seat opens up before the season starts, we'll be in touch.</p>
                    <p>Either way, you're welcome to follow along — standings, results, and team coverage live on the site.</p>
                    <p style="margin:24px 0"><a href="${SITE_URL}/endurance/" style="display:inline-block;background:rgba(255,255,255,0.06);color:#f1f5f9;border:1px solid rgba(255,255,255,0.15);text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:700;letter-spacing:0.15em;text-transform:uppercase;font-size:12px">Follow the season</a></p>`),
            };
        case 'rejected':
            return {
                subject: 'Application update — GTEC',
                html: shell('Application Update', `
                    <h2 style="font-family:Impact,'Anton',sans-serif;font-size:24px;letter-spacing:0.04em;text-transform:uppercase;color:#ffd166;margin:0 0 18px">Thanks for applying, ${name}.</h2>
                    <p>Unfortunately we're unable to offer you a seat in this season of GTEC. The grid filled up faster than we expected and we had to make some tough calls.</p>
                    <p>You're welcome to apply again next season — and to follow this one from the sidelines.</p>
                    <p style="margin:24px 0;font-size:13px;color:#94a3b8">Thanks for your interest.</p>`),
            };
        default:
            return null;
    }
}

// Attempt to assign the Driver role in Discord.
// Returns { ok, reason } — never throws.
async function assignDiscordRole(discordUsername) {
    const botToken = process.env.GTEC_DISCORD_BOT_TOKEN;
    if (!botToken)        return { ok: false, reason: 'no bot token configured' };
    if (!discordUsername) return { ok: false, reason: 'no discord username on application' };

    // Support both legacy "user#1234" and the new username-only format.
    const username = discordUsername.split('#')[0].toLowerCase().trim();
    if (!username) return { ok: false, reason: 'empty username' };

    const base = 'https://discord.com/api/v10';
    const auth = { Authorization: `Bot ${botToken}` };

    // Search the guild's member list for this username.
    const searchRes = await fetch(
        `${base}/guilds/${DISCORD_GUILD_ID}/members/search?query=${encodeURIComponent(username)}&limit=10`,
        { headers: auth }
    );
    if (!searchRes.ok) {
        return { ok: false, reason: `Discord members/search returned ${searchRes.status}` };
    }

    const members = await searchRes.json();
    // Match on the account username (new system) or server nickname.
    const member = members.find(m =>
        m.user.username.toLowerCase() === username ||
        (m.nick && m.nick.toLowerCase() === username)
    );

    if (!member) {
        return { ok: false, reason: 'not in server yet — role can be assigned manually once they join' };
    }

    if (member.roles.includes(DISCORD_DRIVER_ROLE)) {
        return { ok: true, reason: 'already has Driver role' };
    }

    const addRes = await fetch(
        `${base}/guilds/${DISCORD_GUILD_ID}/members/${member.user.id}/roles/${DISCORD_DRIVER_ROLE}`,
        { method: 'PUT', headers: { ...auth, 'X-Audit-Log-Reason': 'GTEC driver accepted' } }
    );

    return addRes.status === 204
        ? { ok: true, reason: 'Driver role assigned' }
        : { ok: false, reason: `Discord PUT roles returned ${addRes.status}` };
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

    const { application_id, email_type } = body;
    if (!application_id || !email_type) {
        return { statusCode: 400, body: 'application_id and email_type are required' };
    }
    if (!['accepted', 'waitlisted', 'rejected'].includes(email_type)) {
        return { statusCode: 400, body: 'email_type must be accepted, waitlisted, or rejected' };
    }

    // Resolve the caller's user id + verify admin role using their access token.
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

    // Load the application
    const appRes = await fetch(
        `${SUPABASE_URL}/rest/v1/applications?select=*&id=eq.${application_id}`,
        { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` } }
    );
    const apps = await appRes.json();
    if (!Array.isArray(apps) || apps.length === 0) {
        return { statusCode: 404, body: 'Application not found' };
    }
    const app = apps[0];
    if (!app.email) {
        return { statusCode: 400, body: 'This application has no email address.' };
    }

    // For acceptance: if the application has a linked driver who hasn't
    // claimed their account yet, mint a single-use claim token and bake
    // the URL into the email.
    let claimUrl = null;
    if (email_type === 'accepted' && app.linked_driver_id) {
        try {
            const drvRes = await fetch(
                `${SUPABASE_URL}/rest/v1/drivers?select=user_id&id=eq.${app.linked_driver_id}`,
                { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` } }
            );
            const drvRows = await drvRes.json();
            const driver = Array.isArray(drvRows) ? drvRows[0] : null;
            if (driver && !driver.user_id) {
                const tokRes = await fetch(`${SUPABASE_URL}/rest/v1/driver_claim_tokens`, {
                    method: 'POST',
                    headers: {
                        apikey: SUPABASE_ANON_KEY,
                        Authorization: `Bearer ${userToken}`,
                        'Content-Type': 'application/json',
                        Prefer: 'return=representation',
                    },
                    body: JSON.stringify({ driver_id: app.linked_driver_id }),
                });
                if (tokRes.ok) {
                    const rows = await tokRes.json();
                    const token = Array.isArray(rows) ? rows[0]?.token : rows?.token;
                    if (token) claimUrl = `${SITE_URL}/endurance/profile/claim/?token=${token}`;
                }
            }
        } catch (err) {
            // Non-fatal — we'll still send the email without the claim link.
            console.warn('Claim-token mint failed:', err.message);
        }
    }

    const tpl = templateFor(email_type, app, claimUrl);
    if (!tpl) return { statusCode: 400, body: 'Unknown email_type' };

    // Send via Resend
    let providerId = null;
    let ok = true;
    let errorText = null;
    try {
        const resendRes = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: {
                Authorization: `Bearer ${RESEND_API_KEY}`,
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                from: FROM_EMAIL,
                to: app.email,
                subject: tpl.subject,
                html: tpl.html,
            }),
        });
        const resendBody = await resendRes.json();
        if (!resendRes.ok) {
            ok = false;
            errorText = resendBody?.message || `Resend error ${resendRes.status}`;
        } else {
            providerId = resendBody?.id || null;
        }
    } catch (err) {
        ok = false;
        errorText = err.message || String(err);
    }

    // Log to application_emails (best effort)
    await fetch(`${SUPABASE_URL}/rest/v1/application_emails`, {
        method: 'POST',
        headers: {
            apikey: SUPABASE_ANON_KEY,
            Authorization: `Bearer ${userToken}`,
            'Content-Type': 'application/json',
            Prefer: 'return=minimal',
        },
        body: JSON.stringify({
            application_id,
            email_type,
            sent_to: app.email,
            sent_by: me.id,
            provider_id: providerId,
            ok,
            error: errorText,
        }),
    }).catch(() => {});

    if (!ok) {
        return { statusCode: 502, body: JSON.stringify({ ok: false, error: errorText }) };
    }

    // On acceptance, silently try to grant the Discord Driver role.
    let discordResult = { ok: false, reason: 'skipped' };
    if (email_type === 'accepted') {
        try {
            discordResult = await assignDiscordRole(app.discord_username);
        } catch (err) {
            discordResult = { ok: false, reason: err.message || String(err) };
        }
        console.log('Discord role assignment:', discordResult);
    }

    return {
        statusCode: 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ok: true, provider_id: providerId, discord: discordResult }),
    };
};
