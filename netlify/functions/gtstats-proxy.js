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

    // Scrape the gtstats.live profile page directly (API is down)
    const profileUrl = `https://gtstats.live/profile/${encodeURIComponent(psnId)}`;
    const response = await fetch(profileUrl, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
    });

    if (!response.ok) {
      console.log('Profile fetch failed:', response.status);
      return {
        statusCode: 404,
        headers,
        body: JSON.stringify({ error: 'Player not found' }),
      };
    }

    const html = await response.text();
    const $ = cheerio.load(html);

    console.log('Successfully fetched profile page');

    // Extract stats from the HTML
    // Look for the stats in the page structure
    let rank = 'E';
    let dr = 0;
    let sr = 0;
    let raceCount = 0;
    let winCount = 0;
    let polePositionCount = 0;
    let fastestLapCount = 0;

    // Try to find DR and SR ratings
    const bodyText = $.text();

    // Look for rank patterns (A+, A, B, etc.)
    const rankMatch = bodyText.match(/(?:Rank|Rating|DR)[:\s]+([A-E]\+?)/i);
    if (rankMatch) rank = rankMatch[1];

    // Look for DR number
    const drMatch = bodyText.match(/DR[:\s]+(\d+)/i) || bodyText.match(/Driver\s*Rating[:\s]+(\d+)/i);
    if (drMatch) dr = parseInt(drMatch[1]);

    // Look for SR
    const srMatch = bodyText.match(/SR[:\s]+(\d+)/i) || bodyText.match(/Sportsman\s*ship[:\s]+(\d+)/i);
    if (srMatch) sr = parseInt(srMatch[1]);

    // Look for race stats
    const raceMatch = bodyText.match(/Races?[:\s]+(\d[\d,]*)/i);
    if (raceMatch) raceCount = parseInt(raceMatch[1].replace(/,/g, ''));

    const winMatch = bodyText.match(/(?:Victories|Wins?)[:\s]+(\d[\d,]*)/i);
    if (winMatch) winCount = parseInt(winMatch[1].replace(/,/g, ''));

    const poleMatch = bodyText.match(/Pole\s*Positions?[:\s]+(\d[\d,]*)/i);
    if (poleMatch) polePositionCount = parseInt(poleMatch[1].replace(/,/g, ''));

    const fastestMatch = bodyText.match(/Fastest\s*Laps?[:\s]+(\d[\d,]*)/i);
    if (fastestMatch) fastestLapCount = parseInt(fastestMatch[1].replace(/,/g, ''));

    console.log('Extracted stats:', { rank, dr, sr, raceCount, winCount, polePositionCount, fastestLapCount });

    // If we didn't find any stats, profile might not exist
    if (dr === 0 && raceCount === 0) {
      return {
        statusCode: 404,
        headers,
        body: JSON.stringify({ error: 'No stats found for this player' }),
      };
    }

    const statsData = {
      id: psnId,
      rank,
      dr,
      sr,
      raceCount,
      winCount,
      polePositionCount,
      fastestLapCount,
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
