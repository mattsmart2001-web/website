-- ============================================================
-- 206 A coaching tab, for one driver to start with
--
-- The lap coach on the main site already has everything it needs from a
-- GTEC driver: gt7_connector serves the full 60 Hz packet to any page on
-- that computer at ws://localhost:8765, position, throttle and brake
-- included. So a coaching section in the portal needs no new download and
-- no new telemetry. What it needs is somewhere to be switched on.
--
-- This is that switch, and it is deliberately the dullest possible one: a
-- boolean on the driver, off for everybody, on for whoever is testing. It
-- scales from one driver to five without another migration, and when the
-- feature is ready for the grid the column is dropped and the tab shows
-- for everyone.
--
-- What this is NOT is a security boundary, and it is worth writing that
-- down so nobody later mistakes it for one. The portal is public
-- JavaScript: anyone can read it and set the flag in their own browser.
-- That is fine while the coaching tab only ever reads the driver's OWN
-- connector on their OWN machine, because there is nothing behind the gate
-- to protect. Forcing it on shows you your own telemetry, which was always
-- yours. The flag exists so nobody stumbles into a half-built feature.
--
-- The day laps are uploaded and drivers are compared with each other, that
-- stops being true and the question becomes row-level security on the
-- stored laps, enforced by the server. That is a different migration and a
-- different problem, and this one should not be stretched to cover it.
-- ============================================================

ALTER TABLE drivers
    ADD COLUMN IF NOT EXISTS coach_beta boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN drivers.coach_beta IS
    'Shows the portal''s coaching tab for this driver. A convenience while '
    'the feature is being built, not a security boundary: the portal is '
    'public JavaScript and the tab only reads this driver''s own connector '
    'over localhost.';

-- On for the driver doing the testing. By slug, because a migration lives
-- in a public repository and an email address does not belong in one.
--
-- If the slug is wrong this quietly matches nothing, which would be a
-- puzzling afternoon, so it says so either way.
DO $$
DECLARE v_slug text := 'sparkstheory';   -- change this to test as someone else
        v_n int;
BEGIN
    UPDATE drivers SET coach_beta = true WHERE slug = v_slug;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 1 THEN
        RAISE NOTICE 'Coaching tab switched on for %', v_slug;
    ELSE
        RAISE WARNING 'No driver with slug %, so the coaching tab is on for '
                      'nobody. Check the slug on the drivers page and run '
                      'the UPDATE again by hand.', v_slug;
    END IF;
END $$;
