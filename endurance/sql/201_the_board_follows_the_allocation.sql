-- ============================================================
-- 201 The board follows the allocation
--
-- Splits were allocated, the live board picked them up, the allocation was
-- then cleared because it was only a test, and the board went on showing
-- the splits. It would have gone on showing them until the round was over.
--
-- The board reads live_positions.lobby_number, which the beacon writes,
-- and the beacon writes it like this:
--
--     lobby_number = COALESCE(EXCLUDED.lobby_number, lp.lobby_number)
--
-- A driver whose entry has no split gives EXCLUDED.lobby_number = NULL, so
-- the COALESCE falls through to whatever was there before. Moving somebody
-- from Split 3 to Split 5 works, because 5 is not null. Taking them out of
-- Split 3 does not, because null is exactly what that line is written to
-- ignore. Once a split has been on the board there is no way to take it
-- off, which is the shape of the bug: it only goes one way.
--
-- The fix is a trigger rather than a change to the beacon. Two reasons,
-- one good and one practical.
--
--   The good one: the beacon is the wrong place to learn this. It finds
--   out a second and a half after the admin pressed the button, and only
--   for drivers who happen to still be reporting. A driver who has gone to
--   make a cup of tea keeps the old split on the board indefinitely,
--   because nothing is arriving to correct it. The allocation changing IS
--   the event, so the allocation changing is what should write it.
--
--   The practical one: the round is on Saturday. This adds a trigger and
--   touches nothing that is already running. Re-issuing eight hundred
--   lines of live_beacon three days out, to fix something a trigger fixes
--   completely, is not a trade worth making. The COALESCE stays, and with
--   this in place it can no longer do any harm: by the time the next
--   beacon arrives lp.lobby_number is already null, so COALESCE(null,
--   null) is null and it stays null.
--
-- Deletes are handled BEFORE rather than AFTER, because entry_drivers
-- cascades off entries and an AFTER trigger would be looking for rows the
-- cascade had already taken away.
-- ============================================================

CREATE OR REPLACE FUNCTION public.live_lobby_follows_entry()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        -- The entry is going. Whoever was in it is no longer in a split,
        -- whatever the board currently says.
        UPDATE live_positions lp
           SET lobby_number = NULL
          FROM entry_drivers ed
         WHERE ed.entry_id   = OLD.id
           AND lp.event_id   = OLD.event_id
           AND lp.driver_id  = ed.driver_id
           AND lp.lobby_number IS NOT NULL;
        RETURN OLD;
    END IF;

    -- UPDATE OF lobby_number fires whenever the column is in the SET list,
    -- changed or not, and the allocator writes every entry on every run.
    -- The IS DISTINCT FROM keeps that from being three hundred pointless
    -- writes to live_positions.
    UPDATE live_positions lp
       SET lobby_number = NEW.lobby_number
      FROM entry_drivers ed
     WHERE ed.entry_id   = NEW.id
       AND lp.event_id   = NEW.event_id
       AND lp.driver_id  = ed.driver_id
       AND lp.lobby_number IS DISTINCT FROM NEW.lobby_number;
    RETURN NEW;
END $$;


DROP TRIGGER IF EXISTS entries_lobby_to_board     ON entries;
DROP TRIGGER IF EXISTS entries_lobby_to_board_del ON entries;

CREATE TRIGGER entries_lobby_to_board
    AFTER UPDATE OF lobby_number ON entries
    FOR EACH ROW EXECUTE FUNCTION public.live_lobby_follows_entry();

CREATE TRIGGER entries_lobby_to_board_del
    BEFORE DELETE ON entries
    FOR EACH ROW EXECUTE FUNCTION public.live_lobby_follows_entry();


-- ---- and the splits already stuck on the board ----
--
-- One pass to bring every live_positions row into line with whatever its
-- entry now says, which is what clears the ones left over from the test.
-- A driver with no entry at all is a test-mode car and has no split, so
-- the subquery's null is the right answer for them too.
DO $sync$
DECLARE n int;
BEGIN
    WITH want AS (
        SELECT lp.event_id, lp.driver_id,
               (SELECT en.lobby_number
                  FROM entries en
                  JOIN entry_drivers ed ON ed.entry_id = en.id
                 WHERE en.event_id  = lp.event_id
                   AND ed.driver_id = lp.driver_id
                 LIMIT 1) AS lobby
          FROM live_positions lp
    )
    UPDATE live_positions lp
       SET lobby_number = w.lobby
      FROM want w
     WHERE w.event_id  = lp.event_id
       AND w.driver_id = lp.driver_id
       AND lp.lobby_number IS DISTINCT FROM w.lobby;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'brought % live timing row(s) into line with the allocation', n;
END $sync$;
