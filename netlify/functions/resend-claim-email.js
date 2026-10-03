// ============================================================
// resend-claim-email
// POST { driver_id }
// Auth: Bearer <supabase access token> belonging to an admin.
//
// Mints a fresh claim token for an unclaimed driver and sends
// them an email with the link. Looks up the email address from
// their accepted application record.
//
// Env vars required:
//   GTEC_SUPABASE_URL       (falls back to SUPABASE_URL)
//   GTEC_SUPABASE_ANON_KEY  (falls back to SUPABASE_ANON_KEY)
//   RESEND_API_KEY
//   GTEC_FROM_EMAIL
// ============================================================

const fetch = require('node-fetch');

const SITE_URL = 'https://sparkstheory.co.uk';

const SUPABASE_URL      = process.env.GTEC_SUPABASE_URL      || process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.GTEC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
const RESEND_API_KEY    = process.env.RESEND_API_KEY;
const FROM_EMAIL        = process.env.GTEC_FROM_EMAIL || 'GTEC <GTEC@sparkstheory.co.uk>';
const DISCORD_URL       = 'https://discord.gg/rMRNYNXnZx';

function esc(s) {
    if (s == null) return '';
    return String(s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function buildEmail(driverName, claimUrl) {
    const name = esc(driverName || 'racer');
    const body = `
        <h2 style="font-family:Impact,'Anton',sans-serif;font-size:26px;letter-spacing:0.04em;text-transform:uppercase;color:#ffd166;margin:0 0 18px">Your profile link, ${name}.</h2>
        <p>Here is a fresh link to activate your GTEC driver profile. It expires in <strong style="color:#f1f5f9">24 hours</strong> and can only be used once.</p>
        <p style="margin:20px 0">
            <a href="${esc(claimUrl)}" style="display:inline-block;background:#ffd166;color:#000000;text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:900;letter-spacing:0.12em;text-transform:uppercase;font-size:13px">Activate Your Profile</a>
        </p>
        <p style="font-size:12px;color:#94a3b8;word-break:break-all">If the button doesn't work, paste this into your browser:<br><a href="${esc(claimUrl)}" style="color:#ffd166">${esc(claimUrl)}</a></p>
        <p>Once your profile is active you'll be able to see your standings, race history, lobby allocations and messages from the admin team.</p>
        <p style="margin:24px 0"><a href="${DISCORD_URL}" style="display:inline-block;background:rgba(255,255,255,0.06);color:#f1f5f9;border:1px solid rgba(255,255,255,0.15);text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:700;letter-spacing:0.15em;text-transform:uppercase;font-size:12px">Join the SparksTheory Discord</a></p>
        <p style="font-size:13px;color:#94a3b8">See you on track.</p>
    `;
    return `<!doctype html><html><body style="margin:0;padding:0;background:#050608;font-family:Helvetica,Arial,sans-serif;color:#f1f5f9">
    <table width="100%" cellpadding="0" cellspacing="0" style="background:#050608"><tr><td align="center" style="padding:40px 16px">
    <table width="560" cellpadding="0" cellspacing="0" style="max-width:560px;background:#0a0e15;border:1px solid rgba(255,255,255,0.08);border-radius:14px">
        <tr><td style="padding:32px 32px 8px">
            <div style="font-family:Impact,'Anton',sans-serif;font-size:14px;letter-spacing:0.32em;text-transform:uppercase;color:#f1f5f9">Gran Turismo <span style="color:#ffd166"></span></div>
            <div style="font-family:'Courier New',monospace;font-size:11px;letter-spacing:0.35em;text-transform:uppercase;color:#94a3b8;margin-top:6px">Endurance Championship</div>
        </td></tr>
        <tr><td style="padding:24px 32px 32px;font-size:15px;line-height:1.65;color:#cbd5e1">${body}</td></tr>
        <tr><td style="padding:18px 32px;background:rgba(255,255,255,0.02);border-top:1px solid rgba(255,255,255,0.06);font-size:12px;color:#64748b;text-align:center">
            <a href="${SITE_URL}/endurance/" style="color:#ffd166;text-decoration:none">sparkstheory.co.uk/endurance</a>
            &nbsp;·&nbsp;
            <a href="${DISCORD_URL}" style="color:#ffd166;text-decoration:none">Discord</a>
        </td></tr>
    </table>
    </td></tr></table></body></html>`;
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

    const { driver_id } = body;
    if (!driver_id) {
        return { statusCode: 400, body: 'driver_id is required' };
    }

    // Verify admin
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

    // Load the driver to confirm they are unclaimed
    const drvRes = await fetch(
        `${SUPABASE_URL}/rest/v1/drivers?select=id,display_name,user_id&id=eq.${driver_id}`,
        { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` } }
    );
    const drvRows = await drvRes.json();
    const driver = Array.isArray(drvRows) ? drvRows[0] : null;
    if (!driver) return { statusCode: 404, body: 'Driver not found' };
    if (driver.user_id) return { statusCode: 400, body: 'Driver has already claimed their profile.' };

    // Find accepted application for this driver to get the email address
    const appRes = await fetch(
        `${SUPABASE_URL}/rest/v1/applications?select=id,email,name&linked_driver_id=eq.${driver_id}&status=eq.accepted&order=created_at.desc&limit=1`,
        { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` } }
    );
    const appRows = await appRes.json();
    const application = Array.isArray(appRows) ? appRows[0] : null;
    if (!application?.email) {
        return { statusCode: 404, body: 'No accepted application with an email address found for this driver.' };
    }

    // Mint a fresh claim token
    const tokRes = await fetch(`${SUPABASE_URL}/rest/v1/driver_claim_tokens`, {
        method: 'POST',
        headers: {
            apikey: SUPABASE_ANON_KEY,
            Authorization: `Bearer ${userToken}`,
            'Content-Type': 'application/json',
            Prefer: 'return=representation',
        },
        body: JSON.stringify({ driver_id }),
    });
    if (!tokRes.ok) {
        return { statusCode: 502, body: 'Failed to create claim token' };
    }
    const tokRows = await tokRes.json();
    const token = Array.isArray(tokRows) ? tokRows[0]?.token : tokRows?.token;
    if (!token) return { statusCode: 502, body: 'Claim token not returned' };

    const claimUrl = `${SITE_URL}/endurance/profile/claim/?token=${token}`;

    // Send via Resend
    const resendRes = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
            Authorization: `Bearer ${RESEND_API_KEY}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({
            from: FROM_EMAIL,
            to: application.email,
            subject: 'Your GTEC driver profile — activate your account',
            html: buildEmail(driver.display_name, claimUrl),
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
        body: JSON.stringify({ ok: true, sent_to: application.email }),
    };
};
