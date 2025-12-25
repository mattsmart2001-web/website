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

    console.log('Search response status:', searchResponse.status);
    console.log('Search response data:', JSON.stringify(searchData));
    console.log('Search data type:', typeof searchData);
    console.log('Search data length:', Array.isArray(searchData) ? searchData.length : 'not an array');

    if (!searchData || (Array.isArray(searchData) && searchData.length === 0)) {
      return {
        statusCode: 404,
        headers,
        body: JSON.stringify({
          error: 'Player not found',
          debug: {
            searchResponse: searchData,
            psnId: psnId
          }
        }),
      };
    }

    // Get first result - handle if response is object or array
    const player = Array.isArray(searchData) ? searchData[0] : searchData;

    console.log('Player object:', JSON.stringify(player));
    console.log('Player keys:', Object.keys(player || {}));
    console.log('Player id:', player?.id);
    console.log('Player user_id:', player?.user_id);
    console.log('Player userId:', player?.userId);

    // Try different possible ID field names
    const playerId = player?.id || player?.user_id || player?.userId || player?.player_id;

    if (!playerId) {
      return {
        statusCode: 500,
        headers,
        body: JSON.stringify({
          error: 'Could not extract player ID',
          debug: {
            player: player,
            searchData: searchData
          }
        }),
      };
    }

    // Fetch detailed stats
    const statsResponse = await fetch(`https://gtstats.live/api/player/${playerId}`);
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
