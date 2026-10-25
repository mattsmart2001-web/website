-- ============================================================
-- 160 Restore the beacon's helper constants
--
-- live_beacon ends by calling live_beacon_interval_ms(p_on_track), and
-- returns early through live_beacon_idle_ms(). Those are one-line constants
-- created by 155 and 157. On a database where either migration was skipped
-- the beacon parses and deploys perfectly well, then fails at runtime the
-- moment it reaches that line.
--
-- Which is a genuinely nasty failure, for three reasons:
--
--   1. PostgREST maps Postgres 42883, undefined function, to HTTP 404. So a
--      missing one-line helper is reported to the client as if the whole
--      live_beacon endpoint did not exist. An entire evening went on
--      checking that live_beacon existed, which it did.
--
--   2. It only fails on the path that reaches it. Calling live_beacon with
--      an invalid token returns "Not paired." from the third line and never
--      touches the helper, so every quick test with a dummy token passes.
--      Only a real paired driver, actually driving, hits it.
--
--   3. The failing statement is in the RETURN, after the upsert, so the
--      transaction rolls back and live_positions stays empty. The symptom
--      is "nothing appears on the live page", which looks like a window or
--      a pairing problem rather than a missing function.
--
-- So all three constants are asserted here, idempotently, in one place with
-- no dependency on which earlier migration did or did not run. Deliberately
-- NOT redefining live_beacon: 155 carries its own copy of the 154-era body,
-- so running 155 to recover the helper would silently revert the track path,
-- the idle pacing and the practice window.
--
-- Values are identical to 155, 156 and 157. Nothing changes on a database
-- where those were applied.
-- ============================================================

-- From 155. How often a reporter beacons while the car is circulating.
-- 1.5s is the floor the beacon's own rate limit enforces, so this is as
-- often as it can report without being throttled.
CREATE OR REPLACE FUNCTION public.live_beacon_interval_ms(p_on_track boolean)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN COALESCE(p_on_track, true) THEN 1500 ELSE 15000 END;
$$;

-- From 157. How long a reporter waits when there is no race to report to.
-- Short enough that opening a window is noticed almost at once.
CREATE OR REPLACE FUNCTION public.live_beacon_idle_ms()
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT 10000;
$$;

-- From 156. How many outline points are enough: several laps of any
-- circuit, and bounded whatever happens.
CREATE OR REPLACE FUNCTION public.live_track_path_max()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 2000; $$;

GRANT EXECUTE ON FUNCTION public.live_beacon_interval_ms(boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.live_beacon_idle_ms()            TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.live_track_path_max()            TO anon, authenticated;


-- ============================================================
-- Say plainly whether the live timing chain is complete, so this class of
-- fault is one query rather than an evening. Every function live_beacon
-- depends on, and whether it is actually there.
-- ============================================================
CREATE OR REPLACE FUNCTION public.live_timing_selftest()
RETURNS TABLE (needs text, present boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT w.needs,
           EXISTS (SELECT 1 FROM pg_proc p
                     JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public'
                      AND p.oid::regprocedure::text = w.needs)
    FROM (VALUES
        ('live_beacon(text,integer,integer,integer,integer,real,real,integer,boolean,real,integer,real)'),
        ('live_beacon_interval_ms(boolean)'),
        ('live_beacon_idle_ms()'),
        ('live_track_path_max()'),
        ('live_active_event()'),
        ('live_field(uuid)'),
        ('live_track(uuid)'),
        ('live_in_practice(time without time zone,time without time zone)'),
        ('live_practice_tz()'),
        ('live_practice_window()'),
        ('live_is_race_day()'),
        ('live_timing_status()')
    ) AS w(needs);
$$;

GRANT EXECUTE ON FUNCTION public.live_timing_selftest() TO authenticated;
