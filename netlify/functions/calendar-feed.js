// ============================================================
// calendar-feed
// GET — no auth required (public schedule, same for every driver)
//
// Returns an iCalendar (.ics) feed of every event in the active
// season, so drivers can subscribe once and have every round show up
// automatically in whatever calendar app they use — no per-driver
// personalization (that would need a stable per-driver token and
// updating events as splits change, which isn't worth the complexity
// for "when is the next race").
//
// Env vars required:
//   GTEC_SUPABASE_URL       (falls back to SUPABASE_URL if unset)
//   GTEC_SUPABASE_ANON_KEY  (falls back to SUPABASE_ANON_KEY if unset)
// ============================================================

const fetch = require('node-fetch');

const SUPABASE_URL      = process.env.GTEC_SUPABASE_URL      || process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.GTEC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;

// RFC 5545 §3.3.11 — escape backslash, semicolon, comma, then newlines.
function icsEscape(s) {
    return String(s || '')
        .replace(/\\/g, '\\\\')
        .replace(/;/g, '\\;')
        .replace(/,/g, '\\,')
        .replace(/\n/g, '\\n');
}

function icsDate(iso) {
    return new Date(iso).toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z';
}

// Long lines must be folded at 75 octets per RFC 5545 §3.1, continuation
// lines start with a single space — otherwise some calendar clients
// (notably older Outlook) silently truncate anything past that.
function foldLine(line) {
    if (line.length <= 75) return line;
    const parts = [];
    let rest = line;
    while (rest.length > 75) {
        parts.push(rest.slice(0, 75));
        rest = ' ' + rest.slice(75);
    }
    parts.push(rest);
    return parts.join('\r\n');
}

exports.handler = async () => {
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
        return { statusCode: 500, body: 'Supabase env vars not configured' };
    }

    const seasonRes = await fetch(
        `${SUPABASE_URL}/rest/v1/seasons?select=id,name&is_active=eq.true&limit=1`,
        { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` } }
    );
    const seasons = await seasonRes.json();
    const season = Array.isArray(seasons) ? seasons[0] : null;

    let events = [];
    if (season) {
        const eventsRes = await fetch(
            `${SUPABASE_URL}/rest/v1/events?select=id,name,round,circuit_name,circuit_country,starts_at,duration_hours,status,slug&season_id=eq.${season.id}&status=neq.cancelled&order=round.asc`,
            { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` } }
        );
        events = await eventsRes.json();
        if (!Array.isArray(events)) events = [];
    }

    const lines = [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'PRODID:-//GTEC//Race Calendar//EN',
        'CALSCALE:GREGORIAN',
        'METHOD:PUBLISH',
        `X-WR-CALNAME:${icsEscape(season ? `GTEC ${season.name}` : 'GTEC Race Calendar')}`,
        'X-WR-TIMEZONE:UTC',
        // A short refresh hint — most clients that honour it will poll on
        // roughly this interval rather than only on manual refresh.
        'REFRESH-INTERVAL;VALUE=DURATION:PT6H',
        'X-PUBLISHED-TTL:PT6H',
    ];

    events.forEach(ev => {
        if (!ev.starts_at) return;
        const start = new Date(ev.starts_at);
        const end = new Date(start.getTime() + (Number(ev.duration_hours) || 1) * 3600000);
        const summary = `GTEC R${ev.round} — ${ev.name}`;
        const location = [ev.circuit_name, ev.circuit_country].filter(Boolean).join(', ');
        const description = `Round ${ev.round}${ev.circuit_name ? ' at ' + ev.circuit_name : ''}. Check the portal for your split once assigned.\nhttps://sparkstheory.co.uk/endurance/calendar/`;

        lines.push(
            'BEGIN:VEVENT',
            `UID:${ev.id}@sparkstheory.co.uk`,
            `DTSTAMP:${icsDate(new Date().toISOString())}`,
            `DTSTART:${icsDate(ev.starts_at)}`,
            `DTEND:${icsDate(end.toISOString())}`,
            `SUMMARY:${icsEscape(summary)}`,
            `LOCATION:${icsEscape(location)}`,
            `DESCRIPTION:${icsEscape(description)}`,
            `URL:https://sparkstheory.co.uk/endurance/results/?slug=${encodeURIComponent(ev.slug || '')}`,
            'END:VEVENT'
        );
    });

    lines.push('END:VCALENDAR');

    const body = lines.map(foldLine).join('\r\n') + '\r\n';

    return {
        statusCode: 200,
        headers: {
            'Content-Type': 'text/calendar; charset=utf-8',
            'Content-Disposition': 'inline; filename="gtec-calendar.ics"',
            'Cache-Control': 'public, max-age=3600',
        },
        body,
    };
};
