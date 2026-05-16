const fetch = require('node-fetch');

const YOUTUBE_CHANNEL_ID = 'UCuUCB1yQyF23u5ESGvNZKNg';
const YOUTUBE_API_KEY = 'AIzaSyBRxCoE4FhqnNfVOHWgVxLApLSnxIlbQ4w';

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Content-Type': 'application/json',
    // Edge-cache for 60s so the YouTube API only gets hit once per minute,
    // regardless of how many viewers are on the site.
    'Cache-Control': 'public, max-age=60, s-maxage=60',
  };

  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers, body: '' };
  }

  try {
    const url =
      'https://www.googleapis.com/youtube/v3/search' +
      `?part=snippet&channelId=${YOUTUBE_CHANNEL_ID}` +
      '&eventType=live&type=video' +
      `&key=${YOUTUBE_API_KEY}`;

    const r = await fetch(url);
    const data = await r.json();

    if (data.error) {
      console.error('YouTube live API error:', data.error);
      return {
        statusCode: 500,
        headers,
        body: JSON.stringify({ live: false, error: data.error.message }),
      };
    }

    if (data.items && data.items.length > 0) {
      const item = data.items[0];
      return {
        statusCode: 200,
        headers,
        body: JSON.stringify({
          live: true,
          videoId: item.id && item.id.videoId,
          title: item.snippet && item.snippet.title,
        }),
      };
    }

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ live: false }),
    };
  } catch (err) {
    console.error('youtube-live function error:', err);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({ live: false, error: err.message || 'Unknown error' }),
    };
  }
};
