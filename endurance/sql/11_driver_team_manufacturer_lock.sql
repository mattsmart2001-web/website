-- ============================================================
-- 11 Driver / Team manufacturer consistency
-- Team is the source of truth: when a driver is on a team, their
-- current_manufacturer_id is auto-synced to the team's manufacturer.
-- Free agents (current_team_id IS NULL) keep their preferred mfr.
-- ============================================================

CREATE OR REPLACE FUNCTION sync_driver_manufacturer_with_team()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    team_mfr uuid;
BEGIN
    IF NEW.current_team_id IS NOT NULL THEN
        SELECT manufacturer_id INTO team_mfr
        FROM teams
        WHERE id = NEW.current_team_id;
        NEW.current_manufacturer_id := team_mfr;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_driver_manufacturer ON drivers;
CREATE TRIGGER trg_sync_driver_manufacturer
    BEFORE INSERT OR UPDATE OF current_team_id, current_manufacturer_id ON drivers
    FOR EACH ROW
    EXECUTE FUNCTION sync_driver_manufacturer_with_team();


-- One-time cleanup: fix any existing rows where the driver's
-- manufacturer doesn't match their team's manufacturer.
UPDATE drivers d
SET    current_manufacturer_id = t.manufacturer_id
FROM   teams t
WHERE  d.current_team_id = t.id
  AND  d.current_manufacturer_id IS DISTINCT FROM t.manufacturer_id;
