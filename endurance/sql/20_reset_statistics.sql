-- ============================================================
-- 20 Reset statistics RPCs
-- Admin-only helpers to wipe race-day data without dropping the
-- structural records (events, drivers, teams).
--   * reset_event_stats(event_id)  — clears a single event
--   * reset_all_stats()             — clears every event
-- Both keep events, drivers, teams, manufacturers and seasons.
-- ============================================================

CREATE OR REPLACE FUNCTION reset_event_stats(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    -- Children of results / entries cascade via FK; we still clear
    -- the per-event lookups explicitly for clarity + safety.
    DELETE FROM public.steward_decisions  WHERE event_id = p_event_id;
    DELETE FROM public.penalties          WHERE event_id = p_event_id;
    DELETE FROM public.driver_ratings     WHERE event_id = p_event_id;
    DELETE FROM public.qualifying_results WHERE event_id = p_event_id;
    DELETE FROM public.results            WHERE event_id = p_event_id;
    DELETE FROM public.entries            WHERE event_id = p_event_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;


CREATE OR REPLACE FUNCTION reset_all_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    DELETE FROM public.steward_decisions;
    DELETE FROM public.penalties;
    DELETE FROM public.driver_ratings;
    DELETE FROM public.qualifying_results;
    DELETE FROM public.results;
    DELETE FROM public.entries;
    DELETE FROM public.hall_of_fame_records;

    RETURN jsonb_build_object('ok', true);
END;
$$;


GRANT EXECUTE ON FUNCTION reset_event_stats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION reset_all_stats()       TO authenticated;
