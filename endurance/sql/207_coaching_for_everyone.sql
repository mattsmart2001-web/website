-- ============================================================
-- 207 Coaching, for everyone
--
-- 206 added coach_beta so the coaching tab could be built and tested
-- against one driver's real laps without the grid seeing a half-finished
-- feature. It has been, the report comes out right and the track map
-- matches the circuit driven, so the gate comes off.
--
-- The column stays. Dropping it would mean another migration to put it
-- back the next time one driver needs something switched on or off, and
-- it costs a boolean. What changes is which way round it points: new
-- drivers get it on, and everyone who already exists is switched on now.
--
-- It is still not a security boundary, for the same reason as before: the
-- tab reads the driver's own connector over localhost and uploads
-- nothing. It is a switch, and from here it is mostly an off switch.
--
-- Worth writing down, because it will come up: a driver reporting from a
-- phone now has a tab they cannot use. The iPhone and Android reporters
-- do not serve telemetry to a browser and never will, so there is nothing
-- to connect to on that machine. The card says PC and Mac in its title
-- rather than three lines down, which is the earliest the page can say
-- it, and the status line underneath says plainly that no connector
-- answered. That is the honest answer, not a fault to fix.
-- ============================================================

ALTER TABLE drivers ALTER COLUMN coach_beta SET DEFAULT true;

COMMENT ON COLUMN drivers.coach_beta IS
    'Shows the portal''s coaching tab for this driver. On by default since '
    '207. Not a security boundary: the tab reads this driver''s own '
    'connector over localhost and uploads nothing. Kept as an off switch.';

DO $$
DECLARE v_n int;
BEGIN
    UPDATE drivers SET coach_beta = true WHERE coach_beta IS NOT TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RAISE NOTICE 'Coaching switched on for % driver(s) who did not have it.', v_n;
END $$;
