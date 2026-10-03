-- ============================================================
-- 113 Storage usage summary for the admin dashboard
--
-- storage.objects lives outside the public schema and isn't exposed
-- over PostgREST, so there's no direct way for the admin dashboard to
-- see how close the project is to its plan's storage cap (1GB on
-- Supabase's free tier — easy to blow through once split result
-- screenshots start piling up across a season). This SECURITY DEFINER
-- function lets an admin query object sizes it otherwise couldn't see.
-- ============================================================

CREATE OR REPLACE FUNCTION admin_storage_usage()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_by_bucket jsonb;
    v_total     bigint;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT COALESCE(jsonb_object_agg(bucket_id, bucket_bytes), '{}'::jsonb),
           COALESCE(SUM(bucket_bytes), 0)
    INTO   v_by_bucket, v_total
    FROM (
        SELECT bucket_id, SUM(COALESCE((metadata->>'size')::bigint, 0)) AS bucket_bytes
        FROM   storage.objects
        GROUP  BY bucket_id
    ) t;

    RETURN jsonb_build_object('total_bytes', v_total, 'by_bucket', v_by_bucket);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_storage_usage() TO authenticated;
