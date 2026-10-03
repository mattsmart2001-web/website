-- ============================================================
-- 33 DSQ penalty zeroes points immediately
-- The trigger from migration 31 set status='dsq' but didn't touch
-- points_awarded, so admins also had to hit Recompute Points to
-- actually drop the driver to zero. Now the trigger zeroes the
-- per-driver and entry-level points (plus any pole/FL flags) in
-- one shot, so the driver/team standings drop straight away.
-- ============================================================

CREATE OR REPLACE FUNCTION apply_dsq_penalty_to_results()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.penalty_type = 'dsq' THEN
        IF NEW.driver_id IS NOT NULL THEN
            -- Driver-specific DSQ: zero just that driver on the entry.
            UPDATE result_drivers rd
               SET status            = 'dsq',
                   classified        = false,
                   points_awarded    = 0,
                   pole_point        = false,
                   fastest_lap_point = false
              FROM results res
             WHERE rd.result_id = res.id
               AND res.event_id = NEW.event_id
               AND res.entry_id = NEW.entry_id
               AND rd.driver_id = NEW.driver_id;
        ELSE
            -- Whole-entry DSQ: zero every driver on the entry + the
            -- entry-level row.
            UPDATE result_drivers rd
               SET status            = 'dsq',
                   classified        = false,
                   points_awarded    = 0,
                   pole_point        = false,
                   fastest_lap_point = false
              FROM results res
             WHERE rd.result_id = res.id
               AND res.event_id = NEW.event_id
               AND res.entry_id = NEW.entry_id;

            UPDATE results
               SET status            = 'dsq',
                   classified        = false,
                   points_awarded    = 0,
                   pole_point        = false,
                   fastest_lap_point = false
             WHERE event_id = NEW.event_id
               AND entry_id = NEW.entry_id;
        END IF;

        -- Roll the entry-level points down to the sum of the
        -- (now possibly partially-zeroed) per-driver rows.
        UPDATE results
           SET points_awarded = COALESCE((
               SELECT SUM(rd.points_awarded)::int
               FROM   result_drivers rd
               WHERE  rd.result_id = results.id
           ), 0)
         WHERE event_id = NEW.event_id
           AND entry_id = NEW.entry_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
