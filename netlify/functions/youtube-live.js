const fetch = require('node-fetch');

// SparksTheory channel — same id the other youtube-* functions use.
const YOUTUBE_CHANNEL_ID = 'UCuUCB1yQyF23u5ESGvNZKNg';

// A search.list call costs 100 quota units, and the default daily quota is
// 10,000. If every visitor hit the API directly that would run out fast, so
// we cache the answer in module memory. Netlify keeps a warmed function
// instance alive between requests, so this bounds live API calls to roughly
// one per minute no matter how many people are on the site.
const CACHE_MS = 60 * 1000;
let cache = { at: 0, payload: null };

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Content-Type': 'application/json',
    // Let the CDN/browser cache it briefly too, as a second layer.
    'Cache-Control': 'public, max-age=45',
  };

  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers, body: '' };
  }

  // Serve the cached answer if it's still fresh.
  const now = Date.now();
  if (cache.payload && (now - cache.at) < CACHE_MS) {
    return { statusCode: 200, headers, body: JSON.stringify({ ...cache.payload, cached: true }) };
  }

  const YOUTUBE_API_KEY = process.env.YOUTUBE_API_KEY;
  if (!YOUTUBE_API_KEY) {
    return { statusCode: 500, headers, body: JSON.stringify({ success: false, error: 'YOUTUBE_API_KEY env var not set' }) };
  }

  try {
    // eventType=live + type=video returns only currently-live broadcasts.
    const url = `https://www.googleapis.com/youtube/v3/search?part=snippet&channelId=${YOUTUBE_CHANNEL_ID}` +
      `&eventType=live&type=video&maxResults=1&key=${YOUTUBE_API_KEY}`;
    const res = await fetch(url);
    const data = await res.json();

    if (data.error) {
      // On an API error (e.g. quota), don't flap the badge — report not-live
      // but keep the error out of the public payload. Short-cache it so we
      // retry soon rather than hammering a failing/quota-exhausted API.
      console.error('youtube-live API error:', data.error.message);
      const payload = { success: false, live: false };
      cache = { at: now, payload };
      return { statusCode: 200, headers, body: JSON.stringify(payload) };
    }

    const item = (data.items || [])[0];
    let payload;
    if (item && item.id && item.id.videoId) {
      const id = item.id.videoId;
      payload = {
        success: true,
        live: true,
        videoId: id,
        title: (item.snippet && item.snippet.title) || '',
        url: `https://www.youtube.com/watch?v=${id}`,
      };
    } else {
      payload = { success: true, live: false };
    }

    cache = { at: now, payload };
    return { statusCode: 200, headers, body: JSON.stringify(payload) };
  } catch (err) {
    console.error('youtube-live failed:', err);
    // Fail closed (not live) so a transient error never shows a stale badge.
    return { statusCode: 200, headers, body: JSON.stringify({ success: false, live: false }) };
  }
};
