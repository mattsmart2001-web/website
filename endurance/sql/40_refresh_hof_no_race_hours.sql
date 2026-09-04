-- ============================================================
-- 40 Remove race_hours from refresh_hall_of_fame
-- Migration 38 dropped race_hours from driver_career_stats, but
-- refresh_hall_of_fame still selected it, throwing
-- "column race_hours does not exist" when admin clicked the button.
-- This rewrites the function without that section. Everything else
-- (most wins, highest rating, fastest lap, longest win streak)
-- stays as it was.
-- ============================================================

CREATE OR REPLACE FUNCTION refresh_hall_of_fame()
RETURNS json AS $$
DECLARE
    v_inserted int := 0;
    v_row      record;
BEGIN
    IF NOT has_role('admin') THEN
        RETURN json_build_object('error', 'Admin role required.');
    END IF;

    DELETE FROM hall_of_fame_records WHERE auto_generated = true;

    -- Most wins
    SELECT driver_id, driver_name, wins INTO v_row
    FROM   driver_career_stats
    WHERE  wins > 0
    ORDER  BY wins DESC, driver_name
    LIMIT  1;
    IF FOUND THEN
        INSERT INTO hall_of_fame_records (category, driver_id, value, context, auto_generated, sort_order)
        VALUES ('most_wins', v_row.driver_id, v_row.wins::text || ' wins', v_row.driver_name, true, 1);
        v_inserted := v_inserted + 1;
    END IF;

    -- Highest rating (peak)
    SELECT dr.driver_id, d.display_name AS driver_name, MAX(dr.rating_after) AS peak INTO v_row
    FROM   driver_ratings dr
    JOIN   drivers d ON d.id = dr.driver_id
    GROUP  BY dr.driver_id, d.display_name
    ORDER  BY peak DESC, d.display_name
    LIMIT  1;
    IF FOUND THEN
        INSERT INTO hall_of_fame_records (category, driver_id, value, context, auto_generated, sort_order)
        VALUES ('highest_rating', v_row.driver_id, v_row.peak::text || ' Elo', 'Peak — ' || v_row.driver_name, true, 2);
        v_inserted := v_inserted + 1;
    END IF;

    -- Fastest lap (best qualifying lap, all-time, any circuit)
    DECLARE
        v_cr record;
    BEGIN
        SELECT cr.driver_id, cr.driver_name, cr.best_lap_ms, cr.circuit_name, cr.event_id INTO v_cr
        FROM   circuit_records cr
        ORDER  BY cr.best_lap_ms ASC
        LIMIT  1;
        IF FOUND THEN
            INSERT INTO hall_of_fame_records (category, driver_id, value, context, event_id, auto_generated, sort_order)
            VALUES (
                'fastest_lap',
                v_cr.driver_id,
                LPAD(FLOOR(v_cr.best_lap_ms / 60000)::text, 1, '0') || ':' ||
                LPAD(FLOOR((v_cr.best_lap_ms % 60000) / 1000)::text, 2, '0') || '.' ||
                LPAD((v_cr.best_lap_ms % 1000)::text, 3, '0'),
                v_cr.driver_name || ' — ' || v_cr.circuit_name,
                v_cr.event_id,
                true, 4
            );
            v_inserted := v_inserted + 1;
        END IF;
    END;

    -- Longest current win streak
    DECLARE
        v_streak record;
    BEGIN
        WITH ordered AS (
            SELECT
                rd.driver_id,
                ev.starts_at,
                (rd.finish_position = 1 AND COALESCE(rd.status, 'classified') = 'classified') AS is_win,
                ROW_NUMBER() OVER (PARTITION BY rd.driver_id ORDER BY ev.starts_at) AS rn,
                ROW_NUMBER() OVER (PARTITION BY rd.driver_id, (rd.finish_position = 1 AND COALESCE(rd.status, 'classified') = 'classified') ORDER BY ev.starts_at) AS win_rn
            FROM result_drivers rd
            JOIN results res ON res.id = rd.result_id
            JOIN events  ev  ON ev.id = res.event_id
        ),
        streaks AS (
            SELECT driver_id, COUNT(*) AS streak
            FROM   ordered
            WHERE  is_win
            GROUP  BY driver_id, rn - win_rn
        )
        SELECT s.driver_id, d.display_name AS driver_name, MAX(s.streak) AS best
        INTO   v_streak
        FROM   streaks s
        JOIN   drivers d ON d.id = s.driver_id
        GROUP  BY s.driver_id, d.display_name
        ORDER  BY best DESC, d.display_name
        LIMIT  1;
        IF FOUND AND v_streak.best > 1 THEN
            INSERT INTO hall_of_fame_records (category, driver_id, value, context, auto_generated, sort_order)
            VALUES ('longest_win_streak', v_streak.driver_id, v_streak.best::text || ' in a row', v_streak.driver_name, true, 5);
            v_inserted := v_inserted + 1;
        END IF;
    END;

    RETURN json_build_object('success', true, 'records_inserted', v_inserted);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
