-- ============================================================
-- 150 Live timing: is this driver paired?
--
-- 149 gave live_timing_tokens no RLS policies at all, deliberately, so a
-- token cannot be read back through the API. That is right, but it left
-- the portal unable to tell whether a driver has already paired, which it
-- needs in order to show the right thing.
--
-- This returns the fact without the secret: whether an active token
-- exists, when it was issued, and when a reporter last used it. The token
-- itself is returned exactly once, by live_timing_token_issue(), and
-- never again — the same way an API key is handled anywhere else. A
-- driver who did not keep it generates a new one, which revokes the old.
--
-- last_used_at is the useful part in practice: it answers "is my phone
-- actually working" without the driver having to be mid-race to find out.
-- ============================================================

CREATE OR REPLACE FUNCTION public.live_timing_status()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_driver_id uuid;
    v_row       record;
BEGIN
    SELECT id INTO v_driver_id FROM drivers WHERE user_id = auth.uid();
    IF v_driver_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No driver profile for this account.');
    END IF;

    SELECT created_at, last_used_at INTO v_row
      FROM live_timing_tokens
     WHERE driver_id = v_driver_id AND revoked_at IS NULL
     ORDER BY created_at DESC
     LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', true, 'paired', false);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'paired', true,
        'paired_at', v_row.created_at,
        'last_used_at', v_row.last_used_at
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.live_timing_status() TO authenticated;
