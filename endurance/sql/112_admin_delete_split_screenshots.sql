-- ============================================================
-- 112 Let admins delete split result screenshots
--
-- Migration 108 added INSERT/UPDATE storage policies for hosts and a
-- public SELECT policy, but no DELETE policy at all — so even an
-- admin had no way to actually remove a screenshot file from storage,
-- only the lobby_result_screenshots row referencing it (which the
-- table-level "admins delete split screenshots" policy from 108
-- already allows). Needed so admin can reclaim storage space by
-- clearing out old rounds' screenshots once results are entered.
-- ============================================================

CREATE POLICY "admins delete split screenshot files" ON storage.objects
    FOR DELETE TO authenticated
    USING (
        bucket_id = 'gtec-split-screenshots'
        AND EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );
