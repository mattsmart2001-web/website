-- ============================================================
-- 31 DSQ → 0 points for the round
--   * compute_event_points awards 0 points when a driver's status
--     is 'dsq', 'dns', or 'withdrawn' (their finish_position is
--     ignored even if one was set).
--   * A penalty of type 'dsq' automatically flips that driver's
--     result_drivers.status to 'dsq' on insert, so admins don't
--     have to also edit the Results panel.
-- ============================================================

-- Updated compute_event_points
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

    -- Make sure every entry has a result row.
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

    -- Pole carries from qualifying.
    UPDATE result_drivers
       SET pole_point = false
     WHERE result_id IN (SELECT id FROM results WHERE event_id = p_event_id);

    UPDATE result_drivers
       SET pole_point = true
     WHERE id IN (
        SELECT rd.id
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        JOIN   qualifying_results qr
          ON   qr.event_id  = res.event_id
         AND   qr.entry_id  = res.entry_id
         AND   qr.driver_id = rd.driver_id
        WHERE  res.event_id = p_event_id
          AND  qr.position  = 1
     );

    -- Per-driver points. DSQ / DNS / withdrawn → 0 points regardless
    -- of finish_position.
    FOR r IN
        SELECT rd.id, rd.finish_position, rd.pole_point, rd.fastest_lap_point, rd.status
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        WHERE  res.event_id = p_event_id
    LOOP
        IF r.status IN ('dsq', 'dns', 'withdrawn') THEN
            pts        := 0;
            fl_bonus   := 0;
            pole_bonus := 0;
        ELSE
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
        END IF;

        UPDATE result_drivers
           SET points_awarded = pts + fl_bonus + pole_bonus
         WHERE id = r.id;
    END LOOP;

    -- Roll entry-level points from entry finish_position. DSQ entries
    -- (status dsq/dns/withdrawn) get 0 here too.
    FOR r IN SELECT * FROM results WHERE event_id = p_event_id LOOP
        IF r.status IN ('dsq', 'dns', 'withdrawn') THEN
            pts := 0; fl_bonus := 0; pole_bonus := 0;
        ELSE
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
        END IF;

        UPDATE results
           SET points_awarded = pts + fl_bonus + pole_bonus
         WHERE id = r.id;
    END LOOP;

    RETURN json_build_object('success', true, 'event_id', p_event_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================
-- Auto-flip status to 'dsq' when a DSQ penalty is recorded
-- against a driver (and a result_drivers row exists for them).
-- ============================================================
CREATE OR REPLACE FUNCTION apply_dsq_penalty_to_results()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.penalty_type = 'dsq' THEN
        -- If a specific driver was named, flip just that driver.
        IF NEW.driver_id IS NOT NULL THEN
            UPDATE result_drivers rd
               SET status = 'dsq',
                   classified = false
              FROM results res
             WHERE rd.result_id  = res.id
               AND res.event_id  = NEW.event_id
               AND res.entry_id  = NEW.entry_id
               AND rd.driver_id  = NEW.driver_id;
        ELSE
            -- Whole-entry DSQ: flip every driver on the entry, plus the
            -- entry-level results row.
            UPDATE result_drivers rd
               SET status = 'dsq',
                   classified = false
              FROM results res
             WHERE rd.result_id  = res.id
               AND res.event_id  = NEW.event_id
               AND res.entry_id  = NEW.entry_id;

            UPDATE results
               SET status = 'dsq',
                   classified = false
             WHERE event_id = NEW.event_id
               AND entry_id = NEW.entry_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS penalties_apply_dsq ON penalties;
CREATE TRIGGER penalties_apply_dsq
    AFTER INSERT ON penalties
    FOR EACH ROW EXECUTE FUNCTION apply_dsq_penalty_to_results();
