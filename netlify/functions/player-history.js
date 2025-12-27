const { createClient } = require('@supabase/supabase-js');

// Initialize Supabase
const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_ANON_KEY;
const supabase = createClient(supabaseUrl, supabaseKey);

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
    const { userGuid, days = 7 } = event.queryStringParameters || {};

    if (!userGuid) {
      return {
        statusCode: 400,
        headers,
        body: JSON.stringify({ error: 'User GUID is required' }),
      };
    }

    console.log(`Fetching ${days} days of history for user:`, userGuid);

    // Calculate date range
    const daysAgo = new Date();
    daysAgo.setDate(daysAgo.getDate() - parseInt(days));

    // Fetch historical data
    const { data, error } = await supabase
      .from('player_history')
      .select('dr, rank, sr, sr_grade, total_races, recorded_at')
      .eq('user_guid', userGuid)
      .gte('recorded_at', daysAgo.toISOString())
      .order('recorded_at', { ascending: true });

    if (error) {
      console.error('Error fetching history:', error);
      return {
        statusCode: 500,
        headers,
        body: JSON.stringify({ error: 'Failed to fetch history' }),
      };
    }

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        success: true,
        history: data || [],
        days: parseInt(days),
      }),
    };

  } catch (error) {
    console.error('Error:', error);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({
        error: 'Internal server error',
        message: error.message,
      }),
    };
  }
};
