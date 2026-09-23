-- ============================================================
-- 28 Per-driver scoring, pole auto-derive from quali, solo entries
-- Fixes a bunch of related issues:
--   * Per-driver positions / points on driver standings (so the
--     driver championship is properly separate from teams).
--   * Pole is derived from qualifying (driver with quali pos 1)
--     instead of asked again on the results form.
--   * qualifying_results loses its (event,entry) and (event,position)
--     UNIQUE constraints — those broke per-driver entry and per-
--     lobby duplicate positions.
--   * entries.team_id and entries.manufacturer_id become nullable so
--     team-less drivers can be entered into events as "solo".
--   * BEFORE-trigger on drivers syncs solo entries to the team once
--     the driver joins one (for events not yet completed).
-- ============================================================

-- 1. Per-driver scoring columns on result_drivers
ALTER TABLE result_drivers
    ADD COLUMN IF NOT EXISTS points_awarded     int     NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS pole_point         boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS fastest_lap_point  boolean NOT NULL DEFAULT false;

-- 2. Qualifying: relax position constraints + allow per-driver rows
ALTER TABLE qualifying_results
    ALTER COLUMN position DROP NOT NULL;

DO $$
DECLARE c text;
BEGIN
    FOR c IN
        SELECT conname FROM pg_constraint
        WHERE  conrelid = 'public.qualifying_results'::regclass
          AND  contype  = 'u'
          AND  (
            conkey = ARRAY[
                (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.qualifying_results'::regclass AND attname = 'event_id'),
                (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.qualifying_results'::regclass AND attname = 'position')
            ]::int2[]
            OR
            conkey = ARRAY[
                (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.qualifying_results'::regclass AND attname = 'event_id'),
                (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.qualifying_results'::regclass AND attname = 'entry_id')
            ]::int2[]
          )
    LOOP
        EXECUTE format('ALTER TABLE public.qualifying_results DROP CONSTRAINT %I', c);
    END LOOP;
END $$;

-- 3. entries: allow solo (team-less) entries
ALTER TABLE entries
    ALTER COLUMN team_id        DROP NOT NULL,
    ALTER COLUMN manufacturer_id DROP NOT NULL,
    ALTER COLUMN car_model       DROP NOT NULL;

-- 4. Manufacturer-lock trigger: skip when team_id is NULL (solo entry)
CREATE OR REPLACE FUNCTION check_entry_manufacturer_lock()
RETURNS TRIGGER AS $$
DECLARE
    season_id_v uuid;
    locked_mfr  uuid;
BEGIN
    -- Solo entries: nothing to lock against.
    IF NEW.team_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT season_id INTO season_id_v FROM events WHERE id = NEW.event_id;
    IF season_id_v IS NULL THEN
        RAISE EXCEPTION 'Entry references event that does not exist (%)', NEW.event_id;
    END IF;

    SELECT manufacturer_id INTO locked_mfr
    FROM team_seasons
    WHERE team_id = NEW.team_id AND season_id = season_id_v;

    -- If a team isn't registered for the season but is on an entry, allow it
    -- but only if no manufacturer is set (admin will fill in later).
    IF locked_mfr IS NULL THEN
        IF NEW.manufacturer_id IS NOT NULL THEN
            RAISE EXCEPTION
                'Team % is not registered for season % — create a team_seasons row first.',
                NEW.team_id, season_id_v;
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.manufacturer_id IS NOT NULL AND NEW.manufacturer_id <> locked_mfr THEN
        RAISE EXCEPTION
            'Entry manufacturer (%) does not match the team-season lock (%).',
            NEW.manufacturer_id, locked_mfr;
    END IF;

    -- Auto-fill the locked manufacturer if it was left blank.
    IF NEW.manufacturer_id IS NULL THEN
        NEW.manufacturer_id := locked_mfr;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- 5. compute_event_points — per-driver scoring + pole-from-quali
-- ============================================================
CREATE OR REPLACE FUNCTION compute_event_points(p_event_id uuid)
RETURNS json AS $$
DECLARE
    v_season_id uuid;
    v_ps        points_systems%ROWTYPE;
    r           record;
    pts         int;
    fl_bonus    int;
    pole_bonus  int;
BEGIN
    SELECT season_id INTO v_season_id FROM events WHERE id = p_event_id;
    IF v_season_id IS NULL THEN
        RETURN json_build_object('error', 'Event not found');
    END IF;

    SELECT ps.* INTO v_ps
    FROM   seasons s JOIN points_systems ps ON ps.id = s.points_system_id
    WHERE  s.id = v_season_id;

    IF v_ps IS NULL THEN
        RETURN json_build_object('error', 'Season has no points system');
    END IF;

    -- Make sure every entry has a result row (so result_drivers can hang
    -- off it). If there's none yet, create an empty one per entry.
    INSERT INTO results (event_id, entry_id)
    SELECT en.event_id, en.id
    FROM   entries en
    LEFT   JOIN results res ON res.event_id = en.event_id AND res.entry_id = en.id
    WHERE  en.event_id = p_event_id
      AND  res.id IS NULL;

    -- Make sure every entry's driver has a result_drivers row.
    INSERT INTO result_drivers (result_id, driver_id, points_share)
    SELECT res.id, ed.driver_id, 1.0
    FROM   results res
    JOIN   entry_drivers ed ON ed.entry_id = res.entry_id
    LEFT   JOIN result_drivers rd ON rd.result_id = res.id AND rd.driver_id = ed.driver_id
    WHERE  res.event_id = p_event_id
      AND  rd.id IS NULL;

    -- Pole carries from qualifying: reset all pole flags, then set true
    -- for the driver who qualified position 1 (per car).
    UPDATE result_drivers
       SET pole_point = false
     WHERE result_id IN (
        SELECT id FROM results WHERE event_id = p_event_id
     );

    UPDATE result_drivers
       SET pole_point = true
     WHERE id IN (
        SELECT rd.id
        FROM   result_drivers rd
        JOIN   results res
          ON   res.id = rd.result_id
        JOIN   qualifying_results qr
          ON   qr.event_id  = res.event_id
         AND   qr.entry_id  = res.entry_id
         AND   qr.driver_id = rd.driver_id
        WHERE  res.event_id = p_event_id
          AND  qr.position  = 1
     );

    -- Per-driver points
    FOR r IN
        SELECT rd.id, rd.finish_position, rd.pole_point, rd.fastest_lap_point, rd.status
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        WHERE  res.event_id = p_event_id
    LOOP
        pts := COALESCE((
            SELECT (elem->>'points')::int
            FROM   jsonb_array_elements(v_ps.points) AS elem
            WHERE  (elem->>'position')::int = r.finish_position
        ), 0);

        fl_bonus := 0;
        IF r.fastest_lap_point THEN
            IF NOT v_ps.finish_required_for_fl
               OR r.status IS NULL
               OR r.status = 'classified' THEN
                fl_bonus := v_ps.fastest_lap_points;
            END IF;
        END IF;

        pole_bonus := CASE WHEN r.pole_point THEN v_ps.pole_points ELSE 0 END;

        UPDATE result_drivers
           SET points_awarded = pts + fl_bonus + pole_bonus
         WHERE id = r.id;
    END LOOP;

    -- Entry-level points keep using the entry's finish_position (the car's
    -- overall finish) so the team championship doesn't double-count when two
    -- drivers share a car. Pole + FL bonuses apply if any driver on the entry
    -- claimed them.
    FOR r IN SELECT * FROM results WHERE event_id = p_event_id LOOP
        pts := COALESCE((
            SELECT (elem->>'points')::int
            FROM   jsonb_array_elements(v_ps.points) AS elem
            WHERE  (elem->>'position')::int = r.finish_position
        ), 0);

        fl_bonus := 0;
        IF EXISTS (
            SELECT 1 FROM result_drivers rd
            WHERE  rd.result_id = r.id AND rd.fastest_lap_point
        ) THEN
            IF NOT v_ps.finish_required_for_fl OR r.status = 'classified' THEN
                fl_bonus := v_ps.fastest_lap_points;
            END IF;
        END IF;

        pole_bonus := CASE WHEN EXISTS (
            SELECT 1 FROM result_drivers rd
            WHERE  rd.result_id = r.id AND rd.pole_point
        ) THEN v_ps.pole_points ELSE 0 END;

        UPDATE results
           SET points_awarded = pts + fl_bonus + pole_bonus
         WHERE id = r.id;
    END LOOP;

    RETURN json_build_object('success', true, 'event_id', p_event_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================
-- 6. driver_standings — per-driver scoring
-- ============================================================
DROP VIEW IF EXISTS driver_standings CASCADE;
CREATE VIEW driver_standings AS
WITH driver_season_team AS (
    SELECT DISTINCT ON (rd.driver_id, s.id)
        rd.driver_id,
        s.id  AS season_id,
        en.team_id,
        ts.manufacturer_id
    FROM   result_drivers rd
    JOIN   results res    ON res.id = rd.result_id
    JOIN   entries en     ON en.id  = res.entry_id
    JOIN   events  ev     ON ev.id  = res.event_id
    JOIN   seasons s      ON s.id   = ev.season_id
    LEFT   JOIN team_seasons ts ON ts.team_id = en.team_id AND ts.season_id = s.id
    ORDER  BY rd.driver_id, s.id, ev.starts_at DESC
)
SELECT
    d.id                                                AS driver_id,
    d.display_name                                      AS driver_name,
    d.slug                                              AS driver_slug,
    d.nationality                                       AS nationality,
    d.career_number                                     AS career_number,
    s.id                                                AS season_id,
    s.year                                              AS season_year,
    dst.team_id                                         AS team_id,
    t.name                                              AS team_name,
    t.slug                                              AS team_slug,
    dst.manufacturer_id                                 AS manufacturer_id,
    m.name                                              AS manufacturer_name,
    m.brand_color                                       AS brand_color,
    m.logo_url                                          AS manufacturer_logo_url,
    COALESCE(SUM(rd.points_awarded), 0)::numeric(10,2)  AS points,
    COUNT(DISTINCT res.event_id)                        AS races,
    COUNT(*) FILTER (WHERE rd.finish_position = 1)      AS wins,
    COUNT(*) FILTER (WHERE rd.finish_position BETWEEN 1 AND 3) AS podiums,
    COUNT(*) FILTER (WHERE rd.pole_point)               AS poles,
    COUNT(*) FILTER (WHERE rd.fastest_lap_point)        AS fastest_laps
FROM   result_drivers rd
JOIN   results res ON res.id = rd.result_id
JOIN   events  ev  ON ev.id  = res.event_id
JOIN   seasons s   ON s.id   = ev.season_id
JOIN   drivers d   ON d.id   = rd.driver_id
LEFT   JOIN driver_season_team dst ON dst.driver_id = d.id AND dst.season_id = s.id
LEFT   JOIN teams         t ON t.id = dst.team_id
LEFT   JOIN manufacturers m ON m.id = dst.manufacturer_id
GROUP  BY d.id, s.id, s.year, dst.team_id, t.name, t.slug,
          dst.manufacturer_id, m.name, m.brand_color, m.logo_url;

GRANT SELECT ON driver_standings TO anon, authenticated;


-- ============================================================
-- 7. Sync solo entries when a driver joins a team
-- For events that are still 'scheduled' (not yet completed/cancelled),
-- any entry where the driver is on a team-less ('solo') entry gets
-- its team_id reassigned to the driver's new team.
-- ============================================================
CREATE OR REPLACE FUNCTION sync_solo_entries_to_team()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_team_id IS NOT NULL
       AND NEW.current_team_id IS DISTINCT FROM OLD.current_team_id THEN
        UPDATE entries en
           SET team_id = NEW.current_team_id
          FROM entry_drivers ed
          JOIN events ev ON ev.id = en.event_id
         WHERE ed.entry_id  = en.id
           AND ed.driver_id = NEW.id
           AND en.team_id   IS NULL
           AND ev.status    = 'scheduled';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS drivers_sync_solo_entries ON drivers;
CREATE TRIGGER drivers_sync_solo_entries
    AFTER UPDATE OF current_team_id ON drivers
    FOR EACH ROW EXECUTE FUNCTION sync_solo_entries_to_team();
