-- ============================================================
-- 95 Admin -> all claimed drivers with no manufacturer set
-- Same shape as message_solo_drivers, scoped to
-- current_manufacturer_id IS NULL — lets admins chase drivers who
-- haven't picked a manufacturer yet. Claimed-only for the same reason
-- as message_solo_drivers: an unclaimed driver can't read their
-- inbox yet, so including them wouldn't achieve anything.
-- ============================================================

CREATE OR REPLACE FUNCTION message_no_manufacturer_drivers(p_subject text, p_message text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    inserted_count int;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    IF coalesce(p_message, '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Message body is required.');
    END IF;

    INSERT INTO public.driver_contact_messages
        (driver_id, user_id, subject, message, status, is_broadcast, broadcast_by)
    SELECT  d.id,
            d.user_id,
            nullif(trim(p_subject), ''),
            p_message,
            'in_progress',
            true,
            auth.uid()
    FROM    public.drivers d
    WHERE   d.current_manufacturer_id IS NULL
      AND   d.user_id IS NOT NULL;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'count', inserted_count);
END;
$$;

GRANT EXECUTE ON FUNCTION message_no_manufacturer_drivers(text, text) TO authenticated;
