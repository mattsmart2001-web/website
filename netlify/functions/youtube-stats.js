const fetch = require('node-fetch');

const YOUTUBE_CHANNEL_ID = 'UCuUCB1yQyF23u5ESGvNZKNg';
const YOUTUBE_API_KEY = 'AIzaSyBRxCoE4FhqnNfVOHWgVxLApLSnxIlbQ4w';

exports.handler = async (event) => {
  // CORS headers
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
  };

  // Handle preflight
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers, body: '' };
  }

  try {
    // Fetch channel statistics
    const statsUrl = `https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}`;

    const response = await fetch(statsUrl);
    const data = await response.json();

    if (data.error) {
      console.error('YouTube API error:', data.error);
      return {
        statusCode: 500,
        headers,
        body: JSON.stringify({
          success: false,
          error: data.error.message,
        }),
      };
    }

    if (data.items && data.items.length > 0) {
      const stats = data.items[0].statistics;
      return {
        statusCode: 200,
        headers,
        body: JSON.stringify({
          success: true,
          subscriberCount: stats.subscriberCount,
          viewCount: stats.viewCount,
          videoCount: stats.videoCount,
        }),
      };
    }

    return {
      statusCode: 404,
      headers,
      body: JSON.stringify({
        success: false,
        error: 'Channel not found',
      }),
    };

  } catch (error) {
    console.error('Error fetching YouTube stats:', error);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({
        success: false,
        error: 'Failed to fetch stats',
        message: error.message,
      }),
    };
  }
};
