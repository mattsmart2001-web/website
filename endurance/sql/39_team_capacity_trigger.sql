-- ============================================================
-- 39 Enforce team driver capacity at the DB
-- A BEFORE trigger on drivers.current_team_id refuses to set the
-- team if it already has teams.max_drivers (default 2) entries.
-- Catches every path — admin UI direct UPDATE, join-request RPC,
-- raw SQL — not just the spots that remembered to check.
-- ============================================================

CREATE OR REPLACE FUNCTION check_team_capacity()
RETURNS TRIGGER AS $$
DECLARE
    team_max       int;
    current_count  int;
BEGIN
    IF NEW.current_team_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- No change in team membership → nothing to check.
    IF TG_OP = 'UPDATE'
       AND NEW.current_team_id IS NOT DISTINCT FROM OLD.current_team_id THEN
        RETURN NEW;
    END IF;

    SELECT max_drivers INTO team_max
    FROM   teams
    WHERE  id = NEW.current_team_id;

    IF team_max IS NULL THEN
        team_max := 2;
    END IF;

    SELECT COUNT(*) INTO current_count
    FROM   drivers
    WHERE  current_team_id = NEW.current_team_id
      AND  id <> NEW.id;

    IF current_count >= team_max THEN
        RAISE EXCEPTION
            'Team is already at capacity (%/% drivers).',
            current_count, team_max;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS drivers_check_team_capacity ON drivers;
CREATE TRIGGER drivers_check_team_capacity
    BEFORE INSERT OR UPDATE OF current_team_id ON drivers
    FOR EACH ROW EXECUTE FUNCTION check_team_capacity();
