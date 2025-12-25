const fetch = require('node-fetch');
const cheerio = require('cheerio');

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

    // Step 1: Scrape the profile page to find the user_id (UUID)
    const profileUrl = `https://gtstats.live/profile/${encodeURIComponent(psnId)}`;
    const profileResponse = await fetch(profileUrl, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
    });

    if (!profileResponse.ok) {
      console.log('Profile fetch failed:', profileResponse.status);
      return {
        statusCode: 404,
        headers,
        body: JSON.stringify({ error: 'Player not found' }),
      };
    }

    const html = await profileResponse.text();

    // Extract user_id (UUID format) from the HTML
    // UUIDs look like: 85596fe8-f2f8-45c1-9474-f3357e8d9446
    const uuidMatches = html.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi);

    console.log('Found UUIDs in page:', uuidMatches);

    // Try each UUID found until we get valid stats
    let statsData = null;

    if (uuidMatches && uuidMatches.length > 0) {
      // Filter out the Nuxt build ID (appears in __NUXT__.config)
      const buildIdMatch = html.match(/buildId:"([0-9a-f-]+)"/);
      const buildId = buildIdMatch ? buildIdMatch[1] : null;

      for (const userId of uuidMatches) {
        // Skip if this is the build ID
        if (userId === buildId) {
          console.log('Skipping build ID:', userId);
          continue;
        }

        console.log('Trying getDriverRating with user_id:', userId);

        // Step 2: Call the getDriverRating API with the user_id
        const apiResponse = await fetch(`https://gtstats.live/api/getDriverRating?user_id=${userId}`);

        if (apiResponse.ok) {
          const data = await apiResponse.json();
          console.log('API response:', data);

          // Check if this is the right player
          if (data.psn && data.psn.toLowerCase() === psnId.toLowerCase()) {
            statsData = {
              id: data.userID,
              rank: data.rank,
              dr: data.dr,
              sr: data.sr,
              raceCount: data.raceCount,
              winCount: data.winCount,
              polePositionCount: data.polePositionCount,
              fastestLapCount: data.fastestLapCount,
            };
            console.log('Found matching player:', statsData);
            break;
          }
        }
      }
    }

    // If we didn't find stats via API, fall back to HTML scraping
    if (!statsData) {
      console.log('Falling back to HTML scraping');

      const $ = cheerio.load(html);
      const bodyText = $.text();

      let rank = 'E';
      let dr = 0;
      let sr = 0;
      let raceCount = 0;
      let winCount = 0;
      let polePositionCount = 0;
      let fastestLapCount = 0;

      // Extract stats from HTML
      const rankMatch = bodyText.match(/(?:Rank|Rating|DR)[:\s]+([A-E]\+?)/i);
      if (rankMatch) rank = rankMatch[1];

      const drMatch = bodyText.match(/DR[:\s]+(\d+)/i) || bodyText.match(/Driver\s*Rating[:\s]+(\d+)/i);
      if (drMatch) dr = parseInt(drMatch[1]);

      const srMatch = bodyText.match(/SR[:\s]+(\d+)/i) || bodyText.match(/Sportsman\s*ship[:\s]+(\d+)/i);
      if (srMatch) sr = parseInt(srMatch[1]);

      const raceMatch = bodyText.match(/Races?[:\s]+(\d[\d,]*)/i);
      if (raceMatch) raceCount = parseInt(raceMatch[1].replace(/,/g, ''));

      const winMatch = bodyText.match(/(?:Victories|Wins?)[:\s]+(\d[\d,]*)/i);
      if (winMatch) winCount = parseInt(winMatch[1].replace(/,/g, ''));

      const poleMatch = bodyText.match(/Pole\s*Positions?[:\s]+(\d[\d,]*)/i);
      if (poleMatch) polePositionCount = parseInt(poleMatch[1].replace(/,/g, ''));

      const fastestMatch = bodyText.match(/Fastest\s*Laps?[:\s]+(\d[\d,]*)/i);
      if (fastestMatch) fastestLapCount = parseInt(fastestMatch[1].replace(/,/g, ''));

      console.log('Scraped stats:', { rank, dr, sr, raceCount, winCount, polePositionCount, fastestLapCount });

      if (dr === 0 && raceCount === 0) {
        return {
          statusCode: 404,
          headers,
          body: JSON.stringify({ error: 'No stats found for this player' }),
        };
      }

      statsData = {
        id: psnId,
        rank,
        dr,
        sr,
        raceCount,
        winCount,
        polePositionCount,
        fastestLapCount,
      };
    }

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
