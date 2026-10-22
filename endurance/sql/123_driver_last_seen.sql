-- ============================================================
-- 123 Driver last seen (last portal visit)
--
-- last_sign_in_at (migration 122) only moves on a fresh sign-in, so a
-- driver with a persistent session reads as stale even if they open the
-- portal daily. This stamps drivers.last_seen_at on every portal load via
-- a tiny SECURITY DEFINER RPC, giving a true "last active" signal.
--
-- Server-stamped (now()) rather than a client-supplied value so it can't
-- be spoofed and doesn't depend on the visitor's clock. Only fills in
-- going forward — there's no history before this ships.
-- ============================================================

ALTER TABLE drivers ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;

CREATE OR REPLACE FUNCTION touch_last_seen()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.drivers
    SET    last_seen_at = now()
    WHERE  user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION touch_last_seen() TO authenticated;
