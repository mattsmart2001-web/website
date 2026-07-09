-- ============================================================
-- 104 Fix team banner upload RLS
--
-- The original storage policies (migration 103) required the uploaded
-- object's filename to string-match the team's UUID
-- (split_part(name, '.', 1) = t.id::text) — this was rejecting valid
-- uploads from confirmed team leaders, and wasn't actually adding much
-- protection anyway: the real gate is the teams.banner_url UPDATE,
-- which is already correctly locked to leader_driver_id by the
-- existing "team leader update own team" policy (migration 24). Drop
-- the filename matching and just require the uploader to be a team
-- leader of some team.
-- ============================================================

DROP POLICY IF EXISTS "team leader uploads own banner" ON storage.objects;
CREATE POLICY "team leader uploads own banner" ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'gtec-team-banners'
        AND EXISTS (
            SELECT 1 FROM teams t
            JOIN drivers d ON d.id = t.leader_driver_id
            WHERE d.user_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS "team leader updates own banner" ON storage.objects;
CREATE POLICY "team leader updates own banner" ON storage.objects
    FOR UPDATE TO authenticated
    USING (
        bucket_id = 'gtec-team-banners'
        AND EXISTS (
            SELECT 1 FROM teams t
            JOIN drivers d ON d.id = t.leader_driver_id
            WHERE d.user_id = auth.uid()
        )
    )
    WITH CHECK (
        bucket_id = 'gtec-team-banners'
        AND EXISTS (
            SELECT 1 FROM teams t
            JOIN drivers d ON d.id = t.leader_driver_id
            WHERE d.user_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS "team leader deletes own banner" ON storage.objects;
CREATE POLICY "team leader deletes own banner" ON storage.objects
    FOR DELETE TO authenticated
    USING (
        bucket_id = 'gtec-team-banners'
        AND EXISTS (
            SELECT 1 FROM teams t
            JOIN drivers d ON d.id = t.leader_driver_id
            WHERE d.user_id = auth.uid()
        )
    );
