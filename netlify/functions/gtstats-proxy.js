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

    console.log('Fetching gtstats for PSN:', psnId);

    // Use the getDriverRatingPSN endpoint that accepts PSN directly
    const apiResponse = await fetch(
      `https://gtstats.live/api/getDriverRatingPSN?psn=${encodeURIComponent(psnId)}`,
      {
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      }
    );

    if (!apiResponse.ok) {
      console.log('API fetch failed:', apiResponse.status);
      return {
        statusCode: 404,
        headers,
        body: JSON.stringify({ error: 'Player not found' }),
      };
    }

    const data = await apiResponse.json();
    console.log('API response:', data);

    // Map the API response to our expected format
    const statsData = {
      id: data.userID,
      rank: data.rank,
      dr: data.dr,
      sr: data.sr,
      raceCount: data.raceCount,
      winCount: data.winCount,
      polePositionCount: data.polePositionCount,
      fastestLapCount: data.fastestLapCount,
    };

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
