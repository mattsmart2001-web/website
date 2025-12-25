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
    // Fetch latest videos from YouTube channel
    const videosUrl = `https://www.googleapis.com/youtube/v3/search?key=${YOUTUBE_API_KEY}&channelId=${YOUTUBE_CHANNEL_ID}&part=snippet,id&order=date&maxResults=8&type=video`;

    const response = await fetch(videosUrl);
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

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        success: true,
        videos: data.items || [],
      }),
    };

  } catch (error) {
    console.error('Error fetching YouTube videos:', error);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({
        success: false,
        error: 'Failed to fetch videos',
        message: error.message,
      }),
    };
  }
};
