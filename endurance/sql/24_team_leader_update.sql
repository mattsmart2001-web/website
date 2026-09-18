-- ============================================================
-- 24 Let team leaders update their own team
-- The existing "team manager update own team" policy uses
-- teams.manager_user_id, which we don't populate. Add a parallel
-- policy that allows the team's leader (looked up via the driver
-- row) to update the team — useful for the portal's Team Settings
-- card so leaders can edit bio / home_country without an admin.
-- ============================================================

DROP POLICY IF EXISTS "team leader update own team" ON teams;
CREATE POLICY "team leader update own team" ON teams
    FOR UPDATE TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM drivers d
            WHERE  d.id = teams.leader_driver_id
              AND  d.user_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM drivers d
            WHERE  d.id = teams.leader_driver_id
              AND  d.user_id = auth.uid()
        )
    );
