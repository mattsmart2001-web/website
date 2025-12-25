const fetch = require('node-fetch');
const cheerio = require('cheerio');

exports.handler = async (event) => {
  // CORS headers
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };

  // Handle preflight
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers, body: '' };
  }

  try {
    const { profileUrl } = JSON.parse(event.body);

    if (!profileUrl) {
      return {
        statusCode: 400,
        headers,
        body: JSON.stringify({ error: 'Profile URL is required' }),
      };
    }

    console.log('Fetching GT7 profile:', profileUrl);

    // Fetch the HTML
    const response = await fetch(profileUrl, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      }
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    const html = await response.text();
    console.log('HTML length:', html.length);
    console.log('HTML preview:', html.substring(0, 500));

    // Load HTML into cheerio
    const $ = cheerio.load(html);

    // Extract text content
    const pageText = $('body').text();
    console.log('Page text length:', pageText.length);
    console.log('Page text preview:', pageText.substring(0, 500));

    // Extract stats from page text using regex
    let driverRating = 'E';
    let sportsmanshipRating = 'E';

    // Try to find DR
    const drMatch = pageText.match(/Driver\s+Rating[^\w]*([ABCDE]\+?)/i);
    if (drMatch) driverRating = drMatch[1];

    // Try to find SR
    const srMatch = pageText.match(/Sportsmanship\s+Rating[^\w]*([SABCDE])/i);
    if (srMatch) sportsmanshipRating = srMatch[1];

    // Extract race stats using regex to find numbers after labels
    const findNumberAfterLabel = (label) => {
      const regex = new RegExp(label + '[^\\d]+(\\d[\\d,]*)', 'i');
      const match = pageText.match(regex);
      return match ? match[1].replace(/,/g, '') : '0';
    };

    const races = findNumberAfterLabel('Races');
    const victories = findNumberAfterLabel('Victories');
    const polePositions = findNumberAfterLabel('Pole Positions?');
    const fastestLaps = findNumberAfterLabel('Fastest Laps?');

    // Clean and parse numbers
    const parseNum = (str) => parseInt(String(str).replace(/[,\s]/g, '')) || 0;

    const stats = {
      driverRating: driverRating.toUpperCase(),
      sportsmanshipRating: sportsmanshipRating.toUpperCase(),
      races: parseNum(races),
      victories: parseNum(victories),
      polePositions: parseNum(polePositions),
      fastestLaps: parseNum(fastestLaps),
      _debug: {
        pageTextLength: pageText.length,
        pageTextPreview: pageText.substring(0, 500),
        htmlPreview: html.substring(0, 500),
        drMatch: drMatch ? drMatch[0] : null,
        srMatch: srMatch ? srMatch[0] : null,
        foundRaces: races,
        foundVictories: victories,
      }
    };

    console.log('Extracted stats:', stats);
    console.log('Debug info:', stats._debug);

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        success: true,
        stats,
        debug: stats._debug,
      }),
    };

  } catch (error) {
    console.error('Scraping error:', error);
    console.error('Error stack:', error.stack);

    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({
        success: false,
        error: 'Failed to fetch profile',
        message: error.message,
        stack: error.stack,
      }),
    };
  }
};
