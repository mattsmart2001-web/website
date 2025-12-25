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

    // Check if we got data - response is an object with numeric keys
    if (!searchData || Object.keys(searchData).length === 0) {
      return {
        statusCode: 404,
        headers,
        body: JSON.stringify({ error: 'Player not found' }),
      };
    }

    // Get the latest entry (key "0" has the most recent stats)
    const latestStats = searchData['0'] || searchData[0];

    if (!latestStats) {
      return {
        statusCode: 404,
        headers,
        body: JSON.stringify({ error: 'No stats found' }),
      };
    }

    console.log('Latest stats:', JSON.stringify(latestStats));

    // Response already contains all stats we need!
    const statsData = {
      id: latestStats.userID,
      rank: latestStats.rank,
      dr: latestStats.dr,
      sr: latestStats.sr,
      raceCount: latestStats.raceCount,
      winCount: latestStats.winCount,
      polePositionCount: latestStats.polePositionCount,
      fastestLapCount: latestStats.fastestLapCount,
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
