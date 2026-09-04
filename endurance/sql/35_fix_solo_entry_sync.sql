-- ============================================================
-- 35 Fix sync_solo_entries_to_team trigger
-- The original UPDATE … FROM … JOIN pattern referenced the target
-- table alias inside the FROM clause, which PostgreSQL rejects with
-- "invalid reference to FROM-clause entry for table 'en'". Rewriting
-- with a subquery sidesteps it.
-- ============================================================

CREATE OR REPLACE FUNCTION sync_solo_entries_to_team()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_team_id IS NOT NULL
       AND NEW.current_team_id IS DISTINCT FROM OLD.current_team_id THEN
        UPDATE entries
           SET team_id = NEW.current_team_id
         WHERE id IN (
            SELECT en.id
            FROM   entries        en
            JOIN   entry_drivers  ed ON ed.entry_id = en.id
            JOIN   events         ev ON ev.id       = en.event_id
            WHERE  ed.driver_id = NEW.id
              AND  en.team_id   IS NULL
              AND  ev.status    = 'scheduled'
         );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
