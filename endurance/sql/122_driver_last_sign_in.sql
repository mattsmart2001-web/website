-- ============================================================
-- 122 Admin: driver last sign-in
--
-- Supabase Auth already records last_sign_in_at on each auth.users row,
-- but that table lives in the auth schema and isn't reachable from the
-- admin page's anon/authenticated client. This exposes it through an
-- admin-only SECURITY DEFINER function that joins it to drivers by
-- user_id, so the Drivers list can show when each claimed driver last
-- logged in.
--
-- Note: last_sign_in_at is the last *fresh* sign-in, not the last visit
-- — a driver with a still-valid session who keeps returning without
-- signing in again won't move this timestamp. It's a coarse engagement
-- signal, not a live "last seen".
-- ============================================================

CREATE OR REPLACE FUNCTION driver_last_sign_in()
RETURNS TABLE (driver_id uuid, last_sign_in_at timestamptz)
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

    RETURN QUERY
    SELECT d.id, u.last_sign_in_at
    FROM   public.drivers d
    JOIN   auth.users u ON u.id = d.user_id
    WHERE  d.user_id IS NOT NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION driver_last_sign_in() TO authenticated;
