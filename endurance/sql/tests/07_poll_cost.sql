-- 07 What one viewer's poll costs the database
--
-- The live page asks for the whole field every 1.5 seconds, and every
-- open page asks separately. The cars are not the load: a full grid
-- sends about eight beacons a second between them. Two hundred people
-- watching is a hundred and thirty-three polls a second, and the only
-- thing standing between that and a stalled board is how long one call
-- to live_field() takes.
--
-- So measure it, on a grid the size of a real one, rather than guessing
-- from how the SQL looks.
--
-- This is a local Postgres on a container, not Supabase, and it leaves
-- out PostgREST, TLS and the network. It measures the part that scales
-- with the number of viewers, which is the part in question.

\pset format unaligned
\pset tuples_only on
SET client_min_messages = notice;

-- A field. Each car needs a token of its own, because the beacon
-- identifies a car by its token and nothing else.
DO $$
DECLARE i int; d uuid; a double precision;
BEGIN
    FOR i IN 1..24 LOOP
        d := ('cccccccc-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
        INSERT INTO drivers (id, display_name, slug)
             VALUES (d, 'Load Car ' || i, 'load-car-' || i)
        ON CONFLICT (id) DO NOTHING;
        INSERT INTO live_timing_tokens (token, driver_id)
             VALUES ('load-' || i, d)
        ON CONFLICT (token) DO UPDATE SET revoked_at = NULL;
        -- Spread round the lap so the rows differ, as they would in a race.
        a := 2*pi() * (i / 24.0);
        PERFORM live_beacon(
            p_token => 'load-' || i, p_lap => 20 + (i % 3),
            p_last_lap_ms => 211000 + i * 17,
            p_x => ((13600/(2*pi())) * cos(a))::real,
            p_z => ((13600/(2*pi())) * sin(a))::real,
            p_speed_kph => 200 + i, p_on_track => true,
            p_fuel_pct => (40 + i)::real, p_client => 'pc');
    END LOOP;
END $$;

\echo ''
\echo '  07_poll_cost'
\echo -n '    cars in the field:   '
SELECT count(*) FROM public.live_field();

DO $$
DECLARE t0 timestamptz; n int := 400; i int; ms numeric;
BEGIN
    PERFORM public.live_field();              -- warm the plan and the cache
    t0 := clock_timestamp();
    FOR i IN 1..n LOOP PERFORM public.live_field(); END LOOP;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000 / n;
    RAISE NOTICE '    live_field():        % ms a call', round(ms, 3);
    -- One core, doing nothing else. Real headroom is lower, and a managed
    -- instance has more cores; this is the shape, not a promise.
    RAISE NOTICE '    one core would take: % polls a second, so % viewers at 1.5s apart',
        round(1000 / ms), round(1000 / ms * 1.5);
END $$;
