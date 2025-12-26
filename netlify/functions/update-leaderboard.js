const fetch = require('node-fetch');
const { createClient } = require('@supabase/supabase-js');

// Initialize Supabase
const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_ANON_KEY;
const supabase = createClient(supabaseUrl, supabaseKey);

// Delay helper for rate limiting
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

exports.handler = async (event, context) => {
  console.log('Starting leaderboard auto-update...');

  try {
    // Fetch all players from database
    const { data: players, error: fetchError } = await supabase
      .from('players')
      .select('psn_id, user_guid');

    if (fetchError) {
      console.error('Error fetching players:', fetchError);
      return {
        statusCode: 500,
        body: JSON.stringify({ error: 'Failed to fetch players' }),
      };
    }

    if (!players || players.length === 0) {
      console.log('No players to update');
      return {
        statusCode: 200,
        body: JSON.stringify({ message: 'No players to update' }),
      };
    }

    console.log(`Found ${players.length} players to update`);

    let successCount = 0;
    let errorCount = 0;
    let notFoundCount = 0;

    // Update each player (with rate limiting)
    for (const player of players) {
      try {
        // Add delay to avoid rate limiting (500ms between requests)
        await delay(500);

        console.log(`Updating ${player.psn_id}...`);

        // Fetch fresh stats from gtstats.live
        const response = await fetch(
          `https://gtstats.live/api/getDriverRatingPSN?psn=${encodeURIComponent(player.psn_id)}`,
          {
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
          }
        );

        if (!response.ok) {
          console.log(`Player ${player.psn_id} not found in gtstats.live (${response.status})`);
          notFoundCount++;
          continue;
        }

        const stats = await response.json();

        // Calculate percentages
        const totalRaces = stats.raceCount || 0;
        const wins = stats.winCount || 0;
        const poles = stats.polePositionCount || 0;
        const fastestLaps = stats.fastestLapCount || 0;

        const winPercentage = totalRaces > 0 ? ((wins / totalRaces) * 100).toFixed(2) : 0;
        const polePercentage = totalRaces > 0 ? ((poles / totalRaces) * 100).toFixed(2) : 0;
        const fastestLapPercentage = totalRaces > 0 ? ((fastestLaps / totalRaces) * 100).toFixed(2) : 0;

        // Get SR grade from SR number
        function getSRGrade(sr) {
          const grades = ['E', 'E', 'D', 'C', 'B', 'A', 'S'];
          return grades[sr] || 'E';
        }

        // Update player in database
        const { error: updateError } = await supabase
          .from('players')
          .update({
            dr: stats.dr || 0,
            rank: stats.rank || 'E',
            sr: stats.sr || 0,
            sr_grade: getSRGrade(stats.sr),
            total_races: totalRaces,
            wins: wins,
            poles: poles,
            fastest_laps: fastestLaps,
            win_percentage: parseFloat(winPercentage),
            pole_percentage: parseFloat(polePercentage),
            fastest_lap_percentage: parseFloat(fastestLapPercentage),
            updated_at: new Date().toISOString(),
          })
          .eq('psn_id', player.psn_id);

        if (updateError) {
          console.error(`Error updating ${player.psn_id}:`, updateError);
          errorCount++;
        } else {
          console.log(`✓ Updated ${player.psn_id}: DR ${stats.dr}, Rank ${stats.rank}`);
          successCount++;
        }

      } catch (error) {
        console.error(`Error processing ${player.psn_id}:`, error);
        errorCount++;
      }
    }

    const summary = {
      total: players.length,
      updated: successCount,
      notFound: notFoundCount,
      errors: errorCount,
      timestamp: new Date().toISOString(),
    };

    console.log('Update complete:', summary);

    return {
      statusCode: 200,
      body: JSON.stringify({
        message: 'Leaderboard update complete',
        summary,
      }),
    };

  } catch (error) {
    console.error('Fatal error:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: error.message }),
    };
  }
};
