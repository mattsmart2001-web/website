-- ============================================================
-- 164 A driver can see their own pairing code again
--
-- 149 showed the code once and never again, on the reasoning that it is a
-- credential and credentials are shown once. That reasoning was borrowed
-- from API keys without checking whether it fits, and it does not.
--
-- An API key is shown once because the holder is a developer who will store
-- it, and because the damage from a leak is unbounded. Here the holder is a
-- driver pairing a phone on their sofa, and the worst a leaked code can do
-- is put a fake car on a live timing page. The costs are nothing alike, and
-- the friction is real and recurring: a driver setting up a second device
-- has to issue a new code, which revokes the first, which silently breaks
-- the device they already had working. That is exactly what happened the
-- first time anyone paired a phone having already paired a PC.
--
-- So the code is retrievable by the driver it belongs to. One code, usable
-- on as many devices as they like, visible whenever they need it.
--
-- Deliberately a separate function rather than a field on
-- live_timing_status(): the portal polls status on load, and a secret should
-- travel only when it is actually asked for, not on every poll of a page
-- that merely wants to know whether pairing exists.
--
-- live_timing_tokens still has no RLS policies at all, so the table remains
-- unreadable through the API. This is the only way out, it returns one
-- driver's own code, and it is bound to auth.uid() rather than to anything
-- the caller passes in.
-- ============================================================

CREATE OR REPLACE FUNCTION public.live_timing_code()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_driver_id uuid;
    v_token     text;
BEGIN
    -- The driver is resolved from the session, never from an argument, so
    -- there is no parameter here to point at somebody else's code.
    SELECT id INTO v_driver_id FROM drivers WHERE user_id = auth.uid();
    IF v_driver_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No driver profile for this account.');
    END IF;

    SELECT token INTO v_token
      FROM live_timing_tokens
     WHERE driver_id = v_driver_id AND revoked_at IS NULL
     ORDER BY created_at DESC
     LIMIT 1;

    IF v_token IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'paired', false);
    END IF;

    RETURN jsonb_build_object('ok', true, 'paired', true, 'code', v_token);
END;
$$;

-- Postgres grants EXECUTE to PUBLIC on every new function, so without this
-- the anon role can call it too. An anonymous caller has no auth.uid() and
-- gets nothing back, so this is not a hole being closed; it is making the
-- boundary explicit rather than relying on the body to hold the line. For a
-- function whose entire purpose is to return a secret, that is worth the
-- extra line.
REVOKE EXECUTE ON FUNCTION public.live_timing_code() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.live_timing_code() TO authenticated;
