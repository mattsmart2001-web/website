-- ============================================================
-- 97 Split-scaled points
--
-- driver_standings is one shared championship table across every
-- split (no partitioning by lobby_number), but points were awarded
-- purely by finish_position with no regard for which split that
-- position was earned in — so winning the weakest split paid exactly
-- the same as winning the strongest one, even though splits are
-- explicitly skill-tiered by the auto-allocator. Elo already accounts
-- for this (split-scoped pairwise comparison); points didn't.
--
-- split_points_multiplier(lobby_number): Split 1 = 100%, then -10%
-- per split down to a 50% floor from Split 6 on. Applied to the whole
-- per-race total (position points + pole + fastest lap) and rounded
-- to the nearest whole point, so points_awarded stays a plain int and
-- no schema change is needed. NULL lobby_number (events with no split
-- concept) defaults to full value.
-- ============================================================

CREATE OR REPLACE FUNCTION split_points_multiplier(p_lobby_number int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT GREATEST(0.5, 1.0 - 0.1 * (COALESCE(p_lobby_number, 1) - 1));
$$;


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
    -- of finish_position. Scaled by the entry's split.
    FOR r IN
        SELECT rd.id, rd.finish_position, rd.pole_point, rd.fastest_lap_point, rd.status,
               en.lobby_number
        FROM   result_drivers rd
        JOIN   results res ON res.id = rd.result_id
        JOIN   entries  en ON en.id  = res.entry_id
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
           SET points_awarded = ROUND((pts + fl_bonus + pole_bonus) * split_points_multiplier(r.lobby_number))::int
         WHERE id = r.id;
    END LOOP;

    -- Roll entry-level points from entry finish_position. DSQ entries
    -- (status dsq/dns/withdrawn) get 0 here too. Scaled by the entry's
    -- own split — same multiplier as its drivers.
    FOR r IN
        SELECT res.*, en.lobby_number
        FROM   results res
        JOIN   entries  en ON en.id = res.entry_id
        WHERE  res.event_id = p_event_id
    LOOP
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
           SET points_awarded = ROUND((pts + fl_bonus + pole_bonus) * split_points_multiplier(r.lobby_number))::int
         WHERE id = r.id;
    END LOOP;

    RETURN json_build_object('success', true, 'event_id', p_event_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
