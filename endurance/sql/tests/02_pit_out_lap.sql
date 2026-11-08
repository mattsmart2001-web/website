CREATE OR REPLACE FUNCTION pg_temp.beacon_at(p_dist real, p_lap int,
                                             p_last int DEFAULT NULL,
                                             p_on boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb; a double precision;
BEGIN
    a := 2*pi() * (p_dist / 13600.0);
    v := live_beacon(p_token => 'tok-test', p_lap => p_lap,
                     p_last_lap_ms => p_last,
                     p_x => ((13600/(2*pi())) * cos(a))::real,
                     p_z => ((13600/(2*pi())) * sin(a))::real,
                     p_speed_kph => 240, p_on_track => p_on,
                     p_fuel_pct => 60::real, p_client => 'pc');
    UPDATE live_positions SET updated_at = now() - interval '2 seconds'
     WHERE driver_id = '44444444-4444-4444-4444-444444444444';
    RETURN v;
END $$;

DELETE FROM live_laps WHERE event_id = '33333333-3333-3333-3333-333333333333';
DELETE FROM live_positions WHERE event_id = '33333333-3333-3333-3333-333333333333';

-- Lap 1, a warm-up so the car is one the beacon has watched.
SELECT pg_temp.beacon_at(d, 1) FROM unnest(ARRAY[0,3400,6800,10200,13000]::real[]) d;
SELECT pg_temp.beacon_at(20, 2);

-- Lap 2, an ordinary lap driven from the line. 3:30.
SELECT pg_temp.beacon_at(d, 2) FROM unnest(ARRAY[3400,6800,10200,13000]::real[]) d;
SELECT pg_temp.beacon_at(20, 3, 210000);

-- Lap 3, the in-lap: round to the pit entry, then into the pit lane. The
-- car is still reporting, still on track as far as GT7 is concerned.
SELECT pg_temp.beacon_at(d, 3) FROM unnest(ARRAY[3400,6800,10200,13300]::real[]) d;

-- The stop. GT7's counter ticks when the car comes back out, 1,200 m past
-- the line, and the time it hands back is the whole in-lap plus the stop.
SELECT pg_temp.beacon_at(1200, 4, 400000);

-- The out-lap: from the pit exit round to the line. GT7 times it from the
-- pit exit, so it is 90% of a lap reported as a lap. 3:10.
SELECT pg_temp.beacon_at(d, 4) FROM unnest(ARRAY[4000,8000,12000]::real[]) d;
SELECT pg_temp.beacon_at(20, 5, 190000);

-- And a clean lap afterwards, which must still count. 3:29.
SELECT pg_temp.beacon_at(d, 5) FROM unnest(ARRAY[3400,6800,10200,13000]::real[]) d;
SELECT pg_temp.beacon_at(20, 6, 209000);

SELECT 'laps logged:    ' || COALESCE(string_agg(lap_ms::text, ', ' ORDER BY id), 'none')
  FROM live_laps WHERE event_id = '33333333-3333-3333-3333-333333333333'
UNION ALL SELECT 'last on screen: ' || COALESCE(last_lap_ms::text, 'none')
  FROM live_positions WHERE driver_id = '44444444-4444-4444-4444-444444444444'
UNION ALL SELECT 'best on screen: ' || COALESCE(best_lap_ms::text, 'none')
  FROM live_positions WHERE driver_id = '44444444-4444-4444-4444-444444444444';
