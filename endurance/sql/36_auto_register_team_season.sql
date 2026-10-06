-- ============================================================
-- 36 Auto-register team to the season when driver joins
-- When a solo entry gets transferred to a team (via the driver
-- joining), the entries.manufacturer-lock trigger refused because
-- the team had no team_seasons row. Now we backfill team_seasons
-- first (using the team's default manufacturer, falling back to
-- the entry's), then transfer the entries.
-- ============================================================

CREATE OR REPLACE FUNCTION sync_solo_entries_to_team()
RETURNS TRIGGER AS $$
DECLARE
    new_team_mfr uuid;
BEGIN
    IF NEW.current_team_id IS NULL
       OR NEW.current_team_id IS NOT DISTINCT FROM OLD.current_team_id THEN
        RETURN NEW;
    END IF;

    -- Team's default manufacturer (used to backfill team_seasons rows).
    SELECT manufacturer_id INTO new_team_mfr
    FROM   teams WHERE id = NEW.current_team_id;

    -- Make sure team_seasons exists for every season we're about to
    -- transfer a solo entry into. Skip rows where neither the team nor
    -- the entry has a manufacturer (admin will need to fix manually).
    INSERT INTO team_seasons (team_id, season_id, manufacturer_id)
    SELECT DISTINCT
           NEW.current_team_id,
           ev.season_id,
           COALESCE(new_team_mfr, en.manufacturer_id)
    FROM   entries        en
    JOIN   entry_drivers  ed ON ed.entry_id = en.id
    JOIN   events         ev ON ev.id       = en.event_id
    WHERE  ed.driver_id = NEW.id
      AND  en.team_id   IS NULL
      AND  ev.status    = 'scheduled'
      AND  COALESCE(new_team_mfr, en.manufacturer_id) IS NOT NULL
    ON CONFLICT (team_id, season_id) DO NOTHING;

    -- Flip the solo entries onto the team. Clear manufacturer_id so the
    -- mfr-lock trigger auto-fills from team_seasons (or returns silently
    -- if the team still has no season registration).
    UPDATE entries
       SET team_id         = NEW.current_team_id,
           manufacturer_id = NULL
     WHERE id IN (
        SELECT en.id
        FROM   entries        en
        JOIN   entry_drivers  ed ON ed.entry_id = en.id
        JOIN   events         ev ON ev.id       = en.event_id
        WHERE  ed.driver_id = NEW.id
          AND  en.team_id   IS NULL
          AND  ev.status    = 'scheduled'
     );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
