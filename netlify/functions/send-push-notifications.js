// ============================================================
// send-push-notifications
// POST { event_id, title, body, url }
// Auth: Bearer <supabase admin token>
//
// Sends a web push notification to every driver with a lobby_number
// assigned for the given event — same audience as the split-assignment
// portal message. Best-effort per subscription; stale endpoints (404/410
// from the push service) are deleted as they're found.
//
// Env vars required:
//   GTEC_SUPABASE_URL       (falls back to SUPABASE_URL if unset)
//   GTEC_SUPABASE_ANON_KEY  (falls back to SUPABASE_ANON_KEY if unset)
//   VAPID_PUBLIC_KEY
//   VAPID_PRIVATE_KEY
//   VAPID_SUBJECT            (optional — mailto: or https: contact URL)
// ============================================================

const fetch = require('node-fetch');
const webpush = require('web-push');

const SUPABASE_URL      = process.env.GTEC_SUPABASE_URL      || process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.GTEC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
const VAPID_PUBLIC_KEY  = process.env.VAPID_PUBLIC_KEY;
const VAPID_PRIVATE_KEY = process.env.VAPID_PRIVATE_KEY;
const VAPID_SUBJECT     = process.env.VAPID_SUBJECT || 'mailto:admin@sparkstheory.co.uk';

exports.handler = async (event) => {
    if (event.httpMethod !== 'POST') {
        return { statusCode: 405, body: 'Method not allowed' };
    }

    if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) return { statusCode: 500, body: 'VAPID keys not configured' };
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return { statusCode: 500, body: 'Supabase env vars not configured' };

    webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

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

    const { event_id, title, body: msgBody, url } = body;
    if (!event_id) return { statusCode: 400, body: 'event_id required' };
    if (!title || !msgBody) return { statusCode: 400, body: 'title and body required' };

    const authHeaders = { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` };

    // Every driver with a split assigned for this event.
    const entriesRes = await fetch(
        `${SUPABASE_URL}/rest/v1/entries?select=entry_drivers(driver_id)&event_id=eq.${event_id}&lobby_number=not.is.null`,
        { headers: authHeaders }
    );
    const entries = await entriesRes.json();
    if (!Array.isArray(entries)) return { statusCode: 502, body: 'Could not load entries' };

    const driverIds = Array.from(new Set(
        entries.flatMap(en => (en.entry_drivers || []).map(ed => ed.driver_id)).filter(Boolean)
    ));
    if (driverIds.length === 0) return { statusCode: 200, body: JSON.stringify({ ok: true, sent: 0 }) };

    const subsRes = await fetch(
        `${SUPABASE_URL}/rest/v1/push_subscriptions?select=id,driver_id,endpoint,p256dh,auth&driver_id=in.(${driverIds.join(',')})`,
        { headers: authHeaders }
    );
    const subs = await subsRes.json();
    if (!Array.isArray(subs) || subs.length === 0) return { statusCode: 200, body: JSON.stringify({ ok: true, sent: 0 }) };

    const payload = JSON.stringify({ title, body: msgBody, url: url || '/endurance/profile/' });

    let sent = 0;
    const stale = [];
    await Promise.all(subs.map(async (s) => {
        try {
            await webpush.sendNotification(
                { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
                payload
            );
            sent++;
        } catch (err) {
            if (err.statusCode === 404 || err.statusCode === 410) stale.push(s.id);
            else console.warn('Push send failed:', s.endpoint, err.statusCode, err.body);
        }
    }));

    if (stale.length) {
        await fetch(`${SUPABASE_URL}/rest/v1/push_subscriptions?id=in.(${stale.join(',')})`, {
            method: 'DELETE',
            headers: authHeaders,
        }).catch(() => null);
    }

    return { statusCode: 200, body: JSON.stringify({ ok: true, sent, stale: stale.length }) };
};
