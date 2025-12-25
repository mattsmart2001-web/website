const chromium = require('@sparticuz/chromium');
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

    // Launch headless browser
    const browser = await puppeteer.launch({
      args: chromium.args,
      defaultViewport: chromium.defaultViewport,
      executablePath: await chromium.executablePath(),
      headless: chromium.headless,
    });

    const page = await browser.newPage();

    // Navigate to profile
    await page.goto(profileUrl, { waitUntil: 'networkidle0', timeout: 30000 });

    // Wait for stats to load (wait for Sport section to appear)
    await page.waitForSelector('body', { timeout: 10000 });

    // Extract stats from the page
    const stats = await page.evaluate(() => {
      // Helper function to get text content by searching for label
      const getStatByLabel = (label) => {
        const elements = Array.from(document.querySelectorAll('*'));
        const labelElement = elements.find(el =>
          el.textContent.trim() === label &&
          el.children.length === 0
        );

        if (labelElement && labelElement.nextElementSibling) {
          return labelElement.nextElementSibling.textContent.trim();
        }

        // Try finding in same parent
        if (labelElement && labelElement.parentElement) {
          const parent = labelElement.parentElement;
          const nextSibling = Array.from(parent.childNodes).find(
            (node, idx, arr) => {
              const labelIdx = arr.indexOf(labelElement);
              return idx > labelIdx && node.nodeType === Node.TEXT_NODE && node.textContent.trim();
            }
          );
          if (nextSibling) return nextSibling.textContent.trim();
        }

        return null;
      };

      // Get DR and SR from header badges
      let driverRating = 'E';
      let sportsmanshipRating = 'E';

      // Look for Driver Rating
      const drElements = Array.from(document.querySelectorAll('*'));
      const drLabel = drElements.find(el => el.textContent.trim() === 'Driver Rating');
      if (drLabel) {
        const container = drLabel.closest('div');
        if (container) {
          const ratingText = Array.from(container.querySelectorAll('*'))
            .find(el => /^[ABCDE]\+?$/.test(el.textContent.trim()));
          if (ratingText) driverRating = ratingText.textContent.trim();
        }
      }

      // Look for Sportsmanship Rating
      const srLabel = drElements.find(el => el.textContent.trim() === 'Sportsmanship Rating');
      if (srLabel) {
        const container = srLabel.closest('div');
        if (container) {
          const ratingText = Array.from(container.querySelectorAll('*'))
            .find(el => /^[SABCDE]$/.test(el.textContent.trim()));
          if (ratingText) sportsmanshipRating = ratingText.textContent.trim();
        }
      }

      // Get Sport section stats
      const races = getStatByLabel('Races') || '0';
      const victories = getStatByLabel('Victories') || '0';
      const polePositions = getStatByLabel('Pole Positions') || '0';
      const fastestLaps = getStatByLabel('Fastest Laps') || '0';

      return {
        driverRating,
        sportsmanshipRating,
        races: parseInt(races.replace(/,/g, '')) || 0,
        victories: parseInt(victories.replace(/,/g, '')) || 0,
        polePositions: parseInt(polePositions.replace(/,/g, '')) || 0,
        fastestLaps: parseInt(fastestLaps.replace(/,/g, '')) || 0,
      };
    });

    await browser.close();

    console.log('Scraped stats:', stats);

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        success: true,
        stats,
      }),
    };

  } catch (error) {
    console.error('Scraping error:', error);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({
        error: 'Failed to scrape profile',
        message: error.message,
      }),
    };
  }
};
