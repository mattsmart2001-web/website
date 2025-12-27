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
    const { psnId, profileUrl } = event.queryStringParameters || {};

    // Check if we have either psnId or profileUrl
    if (!psnId && !profileUrl) {
      return {
        statusCode: 400,
        headers,
        body: JSON.stringify({ error: 'PSN ID or Profile URL is required' }),
      };
    }

    let apiUrl;
    if (profileUrl) {
      // Use lookupPSN endpoint for GT7 profile URLs
      console.log('Looking up profile URL:', profileUrl);
      apiUrl = `https://gtstats.live/api/lookupPSN?psn=${encodeURIComponent(profileUrl)}`;
    } else {
      // Use getDriverRatingPSN endpoint for PSN IDs
      console.log('Fetching gtstats for PSN:', psnId);
      apiUrl = `https://gtstats.live/api/getDriverRatingPSN?psn=${encodeURIComponent(psnId)}`;
    }

    const apiResponse = await fetch(apiUrl, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
    });

    if (!apiResponse.ok) {
      console.log('API fetch failed:', apiResponse.status);
      return {
        statusCode: 404,
        headers,
        body: JSON.stringify({ error: 'Player not found' }),
      };
    }

    const data = await apiResponse.json();
    console.log('API response:', JSON.stringify(data, null, 2));

    // Handle lookupPSN response format (returns { users: [...] })
    let statsData;
    if (profileUrl && data.users) {
      // lookupPSN returns array of users
      if (!data.users || data.users.length === 0) {
        console.log('No users found in lookupPSN response');
        return {
          statusCode: 404,
          headers,
          body: JSON.stringify({
            success: false,
            error: 'No Sport Mode data found for this profile. Make sure the player has participated in GT World Series events.'
          }),
        };
      }
      const user = data.users[0];
      statsData = {
        id: user.userID || user.id,
        rank: user.rank,
        dr: user.dr,
        sr: user.sr,
        raceCount: user.raceCount || 0,
        winCount: user.winCount || 0,
        polePositionCount: user.polePositionCount || 0,
        fastestLapCount: user.fastestLapCount || 0,
      };
    } else {
      // getDriverRatingPSN returns direct object
      statsData = {
        id: data.userID || data.id,
        rank: data.rank,
        dr: data.dr,
        sr: data.sr,
        raceCount: data.raceCount || 0,
        winCount: data.winCount || 0,
        polePositionCount: data.polePositionCount || 0,
        fastestLapCount: data.fastestLapCount || 0,
      };
    }

    console.log('Mapped stats data:', JSON.stringify(statsData, null, 2));

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
