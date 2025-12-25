const chromium = require('chrome-aws-lambda');
const puppeteer = require('puppeteer-core');

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

  let browser = null;

  try {
    const { profileUrl } = JSON.parse(event.body);

    if (!profileUrl) {
      return {
        statusCode: 400,
        headers,
        body: JSON.stringify({ error: 'Profile URL is required' }),
      };
    }

    console.log('Scraping GT7 profile:', profileUrl);

    // Launch headless browser with chrome-aws-lambda
    browser = await puppeteer.launch({
      args: chromium.args,
      defaultViewport: chromium.defaultViewport,
      executablePath: await chromium.executablePath,
      headless: chromium.headless,
    });

    const page = await browser.newPage();

    // Set user agent
    await page.setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

    // Navigate to profile
    await page.goto(profileUrl, {
      waitUntil: 'networkidle2',
      timeout: 30000
    });

    // Wait a bit for JavaScript to execute
    await page.waitForTimeout(3000);

    // Extract stats from the page
    const stats = await page.evaluate(() => {
      // Helper to find text by searching all elements
      const findTextByLabel = (label) => {
        const allElements = Array.from(document.querySelectorAll('*'));

        // Find the label element
        const labelEl = allElements.find(el =>
          el.textContent.trim() === label &&
          el.children.length === 0
        );

        if (!labelEl) return null;

        // Try to find value in sibling or parent
        const parent = labelEl.parentElement;
        if (!parent) return null;

        // Get all text nodes in parent
        const siblings = Array.from(parent.childNodes);
        const labelIndex = siblings.indexOf(labelEl);

        // Look for next text node
        for (let i = labelIndex + 1; i < siblings.length; i++) {
          const sibling = siblings[i];
          if (sibling.nodeType === Node.TEXT_NODE && sibling.textContent.trim()) {
            return sibling.textContent.trim();
          }
          if (sibling.nodeType === Node.ELEMENT_NODE) {
            const text = sibling.textContent.trim();
            if (text && text !== label) {
              return text;
            }
          }
        }

        return null;
      };

      // Extract DR and SR ratings
      let driverRating = 'E';
      let sportsmanshipRating = 'E';

      // Look for "Driver Rating" text and find the rating nearby
      const allText = document.body.innerText;

      // Try to find DR
      const drMatch = allText.match(/Driver\s+Rating[^\w]*([ABCDE]\+?)/i);
      if (drMatch) driverRating = drMatch[1];

      // Try to find SR
      const srMatch = allText.match(/Sportsmanship\s+Rating[^\w]*([SABCDE])/i);
      if (srMatch) sportsmanshipRating = srMatch[1];

      // Get Sport stats
      const races = findTextByLabel('Races') || '0';
      const victories = findTextByLabel('Victories') || '0';
      const polePositions = findTextByLabel('Pole Positions') || '0';
      const fastestLaps = findTextByLabel('Fastest Laps') || '0';

      // Clean and parse numbers (remove commas)
      const parseNum = (str) => parseInt(String(str).replace(/[,\s]/g, '')) || 0;

      return {
        driverRating: driverRating.toUpperCase(),
        sportsmanshipRating: sportsmanshipRating.toUpperCase(),
        races: parseNum(races),
        victories: parseNum(victories),
        polePositions: parseNum(polePositions),
        fastestLaps: parseNum(fastestLaps),
        // Debug info
        _debug: {
          pageTextLength: allText.length,
          pageTextPreview: allText.substring(0, 500),
          drMatch: drMatch ? drMatch[0] : null,
          srMatch: srMatch ? srMatch[0] : null,
          foundRaces: races,
          foundVictories: victories,
        }
      };
    });

    await browser.close();
    browser = null;

    console.log('Scraped stats:', stats);
    console.log('Debug info:', stats._debug);

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        success: true,
        stats,
        debug: stats._debug, // Include debug info in response
      }),
    };

  } catch (error) {
    console.error('Scraping error:', error);

    if (browser) {
      await browser.close();
    }

    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({
        success: false,
        error: 'Failed to scrape profile',
        message: error.message,
      }),
    };
  }
};
