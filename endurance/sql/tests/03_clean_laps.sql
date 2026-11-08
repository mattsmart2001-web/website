-- Four ordinary laps, nobody pits. Nothing may be lost.
CREATE OR REPLACE FUNCTION pg_temp.b(p_dist real, p_lap int, p_last int DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb; a double precision; BEGIN
    a := 2*pi() * (p_dist / 13600.0);
    v := live_beacon(p_token => 'tok-test', p_lap => p_lap, p_last_lap_ms => p_last,
         p_x => ((13600/(2*pi())) * cos(a))::real, p_z => ((13600/(2*pi())) * sin(a))::real,
         p_speed_kph => 240, p_on_track => true, p_fuel_pct => 60::real, p_client => 'pc');
    UPDATE live_positions SET updated_at = now() - interval '2 seconds'
     WHERE driver_id = '44444444-4444-4444-4444-444444444444';
    RETURN v; END $$;
DELETE FROM live_laps WHERE event_id = '33333333-3333-3333-3333-333333333333';
DELETE FROM live_positions WHERE event_id = '33333333-3333-3333-3333-333333333333';
SELECT pg_temp.b(d, 1) FROM unnest(ARRAY[0,3400,6800,10200,13000]::real[]) d;
SELECT pg_temp.b(20, 2);
SELECT pg_temp.b(d, 2) FROM unnest(ARRAY[3400,6800,10200,13000]::real[]) d;
SELECT pg_temp.b(20, 3, 211000);
SELECT pg_temp.b(d, 3) FROM unnest(ARRAY[3400,6800,10200,13000]::real[]) d;
SELECT pg_temp.b(20, 4, 210000);
SELECT pg_temp.b(d, 4) FROM unnest(ARRAY[3400,6800,10200,13000]::real[]) d;
SELECT pg_temp.b(20, 5, 209500);
SELECT 'laps logged:    ' || COALESCE(string_agg(lap_ms::text, ', ' ORDER BY id), 'none')
  FROM live_laps WHERE event_id = '33333333-3333-3333-3333-333333333333'
UNION ALL SELECT 'best on screen: ' || COALESCE(best_lap_ms::text, 'none')
  FROM live_positions WHERE driver_id = '44444444-4444-4444-4444-444444444444';
