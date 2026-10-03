-- ============================================================
-- 135 Leaving a team detaches the driver from that team's future
--     entries, and leader handover picks a deterministic successor
--
-- Two problems, both only reachable mid-season (admin editing a
-- roster directly, since is_team_window_open() blocks the driver-
-- facing path while a season is active).
--
-- 1. sync_solo_entries_to_team() only ever handled JOINING: it bailed
--    out when current_team_id became NULL. Entries are created per
--    event ahead of time, and team championship points are read off
--    entries.team_id, so a driver removed from a team kept their
--    entry_drivers link to that team's entry for every round already
--    on the calendar and carried on scoring for the team they had
--    just left. The admin "register everyone" flow could not rescue
--    them either: it treats free agents as drivers with no team AND
--    no existing entry_drivers row for the event, and theirs was
--    still there, so no solo entry was ever created. Nothing warned
--    anyone. The same gap applied to a straight team A -> team B
--    move, which left the driver on A's entry.
--
--    The replacement handles every direction. Only 'scheduled',
--    unlocked events are touched, so nothing that has already been
--    raced or frozen can move.
--
-- 2. leave_team() promoted a successor with `LIMIT 1` and no ORDER
--    BY, so which team-mate inherited a team was whatever the planner
--    happened to return. Now it is: the driver the team nominated for
--    its car number, else the highest points scorer in the active
--    season, else alphabetical. Points and standings are untouched by
--    any of this; leadership is not a scoring concept.
--
-- Points attribution itself does not change and does not need to.
-- team_standings reads entries.team_id per event, so points scored
-- while a driver was on a team stay with that team for good, and
-- driver_standings sums the driver's own result rows, so the driver
-- keeps them too. This migration only makes sure that FUTURE rounds
-- are attributed to where the driver actually is.
-- ============================================================


-- ============================================================
-- 1. Entry sync, both directions
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_driver_entries_on_team_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_events       uuid[] := '{}';
    v_event_id     uuid;
    v_old_entry    uuid;
    v_target_entry uuid;
    v_team_mfr     uuid;
    v_mfr          uuid;
    v_car_model    text;
    v_car_number   int;
BEGIN
    IF NEW.current_team_id IS NOT DISTINCT FROM OLD.current_team_id THEN
        RETURN NEW;
    END IF;

    ----------------------------------------------------------------
    -- 1a. Leave: unpick the old team's not-yet-run entries
    ----------------------------------------------------------------
    IF OLD.current_team_id IS NOT NULL THEN
        FOR v_event_id, v_old_entry IN
            SELECT ev.id, en.id
            FROM   entries       en
            JOIN   entry_drivers ed ON ed.entry_id = en.id
            JOIN   events        ev ON ev.id       = en.event_id
            WHERE  ed.driver_id = NEW.id
              AND  en.team_id   = OLD.current_team_id
              AND  ev.status    = 'scheduled'
              AND  NOT ev.is_locked
        LOOP
            DELETE FROM entry_drivers
             WHERE entry_id = v_old_entry AND driver_id = NEW.id;

            v_events := v_events || v_event_id;

            -- A team entry with nobody left in it would sit on the grid
            -- as a phantom car. Only ever removed when it has no result
            -- and no qualifying time hanging off it.
            IF NOT EXISTS (SELECT 1 FROM entry_drivers      WHERE entry_id = v_old_entry)
               AND NOT EXISTS (SELECT 1 FROM results            WHERE entry_id = v_old_entry)
               AND NOT EXISTS (SELECT 1 FROM qualifying_results WHERE entry_id = v_old_entry) THEN
                DELETE FROM entries WHERE id = v_old_entry;
            END IF;
        END LOOP;
    END IF;

    ----------------------------------------------------------------
    -- 1b. Re-enter them for the rounds we just took them out of, so a
    --     roster change never silently drops a driver off the grid
    ----------------------------------------------------------------
    IF NEW.current_team_id IS NULL THEN
        -- Now a free agent: they keep the car they were racing, since
        -- current_manufacturer_id is left alone on the way out.
        SELECT m.id, COALESCE(m.car_name, m.name)
          INTO v_mfr, v_car_model
          FROM manufacturers m
         WHERE m.id = NEW.current_manufacturer_id;
    ELSE
        SELECT t.manufacturer_id, COALESCE(m.car_name, m.name)
          INTO v_team_mfr, v_car_model
          FROM teams t
          LEFT JOIN manufacturers m ON m.id = t.manufacturer_id
         WHERE t.id = NEW.current_team_id;
    END IF;

    FOREACH v_event_id IN ARRAY v_events LOOP
        -- Respect a round they have already flagged themselves out of.
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM driver_event_absences a
             WHERE a.driver_id = NEW.id AND a.event_id = v_event_id
        );

        IF NEW.current_team_id IS NULL THEN
            -- One team-less entry per round.
            v_car_number := NEW.career_number;
            IF v_car_number IS NOT NULL AND EXISTS (
                SELECT 1 FROM entries e
                 WHERE e.event_id = v_event_id AND e.car_number = v_car_number
            ) THEN
                v_car_number := NULL;   -- taken this round; admin can assign one
            END IF;

            INSERT INTO entries (event_id, team_id, car_number, manufacturer_id, car_model, status)
            VALUES (v_event_id, NULL, v_car_number, v_mfr, COALESCE(v_car_model, 'TBC'), 'confirmed')
            RETURNING id INTO v_target_entry;
        ELSE
            -- Ride along on the new team's entry for the round.
            SELECT id INTO v_target_entry
              FROM entries
             WHERE event_id = v_event_id
               AND team_id  = NEW.current_team_id
             LIMIT 1;

            -- Not entered for this round yet, so enter them. The lock
            -- trigger refuses a team with no team_seasons row, and fills
            -- manufacturer_id in from it once there is one.
            IF v_target_entry IS NULL THEN
                INSERT INTO team_seasons (team_id, season_id, manufacturer_id)
                SELECT NEW.current_team_id, ev.season_id, v_team_mfr
                  FROM events ev
                 WHERE ev.id = v_event_id AND v_team_mfr IS NOT NULL
                ON CONFLICT (team_id, season_id) DO NOTHING;

                INSERT INTO entries (event_id, team_id, car_number, manufacturer_id, car_model, status)
                VALUES (v_event_id, NEW.current_team_id, NULL, NULL, COALESCE(v_car_model, 'TBC'), 'confirmed')
                RETURNING id INTO v_target_entry;
            END IF;
        END IF;

        INSERT INTO entry_drivers (entry_id, driver_id, stint_role)
        VALUES (v_target_entry, NEW.id, 'starting')
        ON CONFLICT DO NOTHING;
    END LOOP;

    ----------------------------------------------------------------
    -- 1c. Join: adopt the driver's own team-less entries (unchanged
    --     behaviour, carried over from 36)
    ----------------------------------------------------------------
    IF NEW.current_team_id IS NOT NULL THEN
        SELECT manufacturer_id INTO v_team_mfr
          FROM teams WHERE id = NEW.current_team_id;

        -- The entries manufacturer lock refuses a team that has no
        -- team_seasons row, so backfill one first.
        INSERT INTO team_seasons (team_id, season_id, manufacturer_id)
        SELECT DISTINCT
               NEW.current_team_id,
               ev.season_id,
               COALESCE(v_team_mfr, en.manufacturer_id)
        FROM   entries        en
        JOIN   entry_drivers  ed ON ed.entry_id = en.id
        JOIN   events         ev ON ev.id       = en.event_id
        WHERE  ed.driver_id = NEW.id
          AND  en.team_id   IS NULL
          AND  ev.status    = 'scheduled'
          AND  NOT ev.is_locked
          AND  COALESCE(v_team_mfr, en.manufacturer_id) IS NOT NULL
        ON CONFLICT (team_id, season_id) DO NOTHING;

        -- Clearing manufacturer_id lets the lock trigger refill it from
        -- team_seasons (or pass silently if the team still has none).
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
              AND  NOT ev.is_locked
         );
    END IF;

    RETURN NEW;
END;
$$;


-- Repoint the trigger, then retire the join-only function it used to
-- call. The name no longer described what it does.
DROP TRIGGER IF EXISTS drivers_sync_solo_entries ON drivers;
CREATE TRIGGER drivers_sync_solo_entries
    AFTER UPDATE OF current_team_id ON drivers
    FOR EACH ROW EXECUTE FUNCTION public.sync_driver_entries_on_team_change();

DROP FUNCTION IF EXISTS public.sync_solo_entries_to_team();


-- ============================================================
-- 2. leave_team(): deterministic leadership handover
-- ============================================================
CREATE OR REPLACE FUNCTION leave_team()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_driver_id  uuid;
    v_team_id    uuid;
    v_is_leader  boolean;
    v_next_lead  uuid;
BEGIN
    SELECT id, current_team_id
      INTO v_driver_id, v_team_id
      FROM drivers
     WHERE user_id = auth.uid();

    IF NOT FOUND OR v_team_id IS NULL THEN
        RETURN json_build_object('error', 'You are not currently on a team.');
    END IF;

    IF NOT public.is_team_window_open() THEN
        RETURN json_build_object('error', 'Team changes are locked during the active season.');
    END IF;

    SELECT (leader_driver_id = v_driver_id)
      INTO v_is_leader
      FROM teams
     WHERE id = v_team_id;

    IF v_is_leader THEN
        -- Successor, in order: the driver the team nominated to carry
        -- its car number, then the team-mate with the most championship
        -- points to their name, then alphabetical, so the result is
        -- never arbitrary. Career points rather than this season's,
        -- because leave_team() only runs between seasons.
        SELECT d.id
          INTO v_next_lead
          FROM drivers d
          LEFT JOIN teams t ON t.id = v_team_id
          LEFT JOIN LATERAL (
              SELECT COALESCE(SUM(ds.points), 0) AS points
              FROM   driver_standings ds
              WHERE  ds.driver_id = d.id
          ) pts ON true
         WHERE d.current_team_id = v_team_id
           AND d.id <> v_driver_id
         ORDER BY (d.id = t.car_number_driver_id) DESC,
                  pts.points DESC,
                  d.display_name ASC
         LIMIT 1;

        UPDATE teams
           SET leader_driver_id = v_next_lead   -- NULL if no one else
         WHERE id = v_team_id;
    END IF;

    UPDATE drivers
       SET current_team_id = NULL
     WHERE id = v_driver_id;

    DELETE FROM team_join_requests
     WHERE driver_id = v_driver_id
       AND status    = 'pending';

    RETURN json_build_object(
        'success',       true,
        'was_leader',    v_is_leader,
        'new_leader_id', v_next_lead
    );
END;
$$;

GRANT EXECUTE ON FUNCTION leave_team() TO authenticated;
