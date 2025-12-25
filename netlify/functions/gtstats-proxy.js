const fetch = require('node-fetch');

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
    const { psnId } = event.queryStringParameters || {};

    if (!psnId) {
      return {
        statusCode: 400,
        headers,
        body: JSON.stringify({ error: 'PSN ID is required' }),
      };
    }

    console.log('Fetching gtstats for:', psnId);

    // Search for player
    const searchResponse = await fetch(`https://gtstats.live/api/search?psn=${encodeURIComponent(psnId)}`);
    const searchData = await searchResponse.json();

    console.log('Search response:', searchData);

    if (!searchData || searchData.length === 0) {
      return {
        statusCode: 404,
        headers,
        body: JSON.stringify({ error: 'Player not found' }),
      };
    }

    // Get first result
    const player = searchData[0];

    // Fetch detailed stats
    const statsResponse = await fetch(`https://gtstats.live/api/player/${player.id}`);
    const statsData = await statsResponse.json();

    console.log('Stats response:', statsData);

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        success: true,
        player: statsData,
      }),
    };

  } catch (error) {
    console.error('Error fetching gtstats:', error);
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
