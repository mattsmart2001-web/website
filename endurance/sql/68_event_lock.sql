-- ============================================================
-- 68 Lock completed events so nothing can be added or edited
--
-- Once an event is done, admin should be able to "freeze" it so no
-- entries, qualifying times, results, penalties, steward decisions
-- or ratings can be added / changed / deleted for it. Toggleable —
-- if a correction genuinely needs to happen, admin unlocks, edits,
-- and re-locks.
--
-- Implementation:
--   * events.is_locked boolean (default false)
--   * Generic trigger on every event-scoped child table that
--     refuses INSERT / UPDATE / DELETE when the event is locked
--   * Specialised triggers on result_drivers (event lives on the
--     parent results row) and entry_drivers (event lives on the
--     parent entries row).
-- ============================================================

ALTER TABLE public.events
    ADD COLUMN IF NOT EXISTS is_locked  boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS locked_at  timestamptz,
    ADD COLUMN IF NOT EXISTS locked_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL;


-- ---- Generic blocker: tables with event_id on the row itself ----
CREATE OR REPLACE FUNCTION public.block_writes_to_locked_event()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    locked boolean := false;
BEGIN
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        SELECT ev.is_locked INTO locked FROM public.events ev WHERE ev.id = NEW.event_id;
        IF locked THEN
            RAISE EXCEPTION 'Event is locked. Unlock it before making changes.'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        SELECT ev.is_locked INTO locked FROM public.events ev WHERE ev.id = OLD.event_id;
        IF locked THEN
            RAISE EXCEPTION 'Event is locked. Unlock it before making changes.'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

-- Attach to every event-scoped child that has event_id directly.
DROP TRIGGER IF EXISTS gtec_lock_entries             ON public.entries;
DROP TRIGGER IF EXISTS gtec_lock_qualifying_results  ON public.qualifying_results;
DROP TRIGGER IF EXISTS gtec_lock_results             ON public.results;
DROP TRIGGER IF EXISTS gtec_lock_penalties           ON public.penalties;
DROP TRIGGER IF EXISTS gtec_lock_steward_decisions   ON public.steward_decisions;
DROP TRIGGER IF EXISTS gtec_lock_driver_ratings      ON public.driver_ratings;

CREATE TRIGGER gtec_lock_entries
    BEFORE INSERT OR UPDATE OR DELETE ON public.entries
    FOR EACH ROW EXECUTE FUNCTION public.block_writes_to_locked_event();

CREATE TRIGGER gtec_lock_qualifying_results
    BEFORE INSERT OR UPDATE OR DELETE ON public.qualifying_results
    FOR EACH ROW EXECUTE FUNCTION public.block_writes_to_locked_event();

CREATE TRIGGER gtec_lock_results
    BEFORE INSERT OR UPDATE OR DELETE ON public.results
    FOR EACH ROW EXECUTE FUNCTION public.block_writes_to_locked_event();

CREATE TRIGGER gtec_lock_penalties
    BEFORE INSERT OR UPDATE OR DELETE ON public.penalties
    FOR EACH ROW EXECUTE FUNCTION public.block_writes_to_locked_event();

CREATE TRIGGER gtec_lock_steward_decisions
    BEFORE INSERT OR UPDATE OR DELETE ON public.steward_decisions
    FOR EACH ROW EXECUTE FUNCTION public.block_writes_to_locked_event();

CREATE TRIGGER gtec_lock_driver_ratings
    BEFORE INSERT OR UPDATE OR DELETE ON public.driver_ratings
    FOR EACH ROW EXECUTE FUNCTION public.block_writes_to_locked_event();


-- ---- result_drivers: event_id lives on the parent results row ----
CREATE OR REPLACE FUNCTION public.block_result_drivers_when_event_locked()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    locked boolean := false;
BEGIN
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        SELECT ev.is_locked INTO locked
        FROM   public.results res
        JOIN   public.events  ev ON ev.id = res.event_id
        WHERE  res.id = NEW.result_id;
        IF locked THEN
            RAISE EXCEPTION 'Event is locked. Unlock it before making changes.'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        SELECT ev.is_locked INTO locked
        FROM   public.results res
        JOIN   public.events  ev ON ev.id = res.event_id
        WHERE  res.id = OLD.result_id;
        IF locked THEN
            RAISE EXCEPTION 'Event is locked. Unlock it before making changes.'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS gtec_lock_result_drivers ON public.result_drivers;
CREATE TRIGGER gtec_lock_result_drivers
    BEFORE INSERT OR UPDATE OR DELETE ON public.result_drivers
    FOR EACH ROW EXECUTE FUNCTION public.block_result_drivers_when_event_locked();


-- ---- entry_drivers: event_id lives on the parent entries row ----
CREATE OR REPLACE FUNCTION public.block_entry_drivers_when_event_locked()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    locked boolean := false;
BEGIN
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        SELECT ev.is_locked INTO locked
        FROM   public.entries en
        JOIN   public.events  ev ON ev.id = en.event_id
        WHERE  en.id = NEW.entry_id;
        IF locked THEN
            RAISE EXCEPTION 'Event is locked. Unlock it before making changes.'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        SELECT ev.is_locked INTO locked
        FROM   public.entries en
        JOIN   public.events  ev ON ev.id = en.event_id
        WHERE  en.id = OLD.entry_id;
        IF locked THEN
            RAISE EXCEPTION 'Event is locked. Unlock it before making changes.'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS gtec_lock_entry_drivers ON public.entry_drivers;
CREATE TRIGGER gtec_lock_entry_drivers
    BEFORE INSERT OR UPDATE OR DELETE ON public.entry_drivers
    FOR EACH ROW EXECUTE FUNCTION public.block_entry_drivers_when_event_locked();
