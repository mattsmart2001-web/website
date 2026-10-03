-- ============================================================
-- 85 Owner-only Reset All Statistics
--
-- reset_all_stats() wipes every event's race data in one shot
-- (results, qualifying, ratings, penalties, steward decisions,
-- Hall of Fame). Previously any user with the 'admin' role could
-- call it. Since admin access may be shared with other organisers
-- or stewards, this restricts the global wipe to the site owner's
-- account specifically, while leaving reset_event_stats (the
-- single-event reset) open to all admins as before.
-- ============================================================

CREATE OR REPLACE FUNCTION reset_all_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM auth.users u
        WHERE u.id = auth.uid()
          AND lower(u.email) = lower('mattsmart2001@gmail.com')
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    DELETE FROM public.steward_decisions    WHERE true;
    DELETE FROM public.penalties            WHERE true;
    DELETE FROM public.driver_ratings       WHERE true;
    DELETE FROM public.qualifying_results   WHERE true;
    DELETE FROM public.results              WHERE true;
    DELETE FROM public.entries              WHERE true;
    DELETE FROM public.hall_of_fame_records WHERE true;

    RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION reset_all_stats() TO authenticated;
