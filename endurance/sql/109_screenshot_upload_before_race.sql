-- ============================================================
-- 109 Let hosts post screenshots as soon as they're assigned
--
-- Migration 108 gated screenshot uploads on the event having already
-- started, mirroring the "only meaningful once its time has come"
-- caution used for room codes. In practice the host wants to see
-- (and can usefully use) the upload card as soon as splits are
-- allocated, well before race day — so drop the starts_at check.
-- The real-world reason it disappears is splits being cleared
-- (lobby_number/host_driver_id set back to null), which the "host of
-- this split" check already handles with no separate gate needed.
-- ============================================================

DROP POLICY IF EXISTS "the lobby host can post their split's screenshots" ON lobby_result_screenshots;
CREATE POLICY "the lobby host can post their split's screenshots" ON lobby_result_screenshots
    FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM   entries en
            JOIN   drivers d ON d.id = en.host_driver_id
            WHERE  en.event_id     = lobby_result_screenshots.event_id
              AND  en.lobby_number = lobby_result_screenshots.lobby_number
              AND  d.user_id       = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

DROP POLICY IF EXISTS "the lobby host can update their split's screenshots" ON lobby_result_screenshots;
CREATE POLICY "the lobby host can update their split's screenshots" ON lobby_result_screenshots
    FOR UPDATE TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM   entries en
            JOIN   drivers d ON d.id = en.host_driver_id
            WHERE  en.event_id     = lobby_result_screenshots.event_id
              AND  en.lobby_number = lobby_result_screenshots.lobby_number
              AND  d.user_id       = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM   entries en
            JOIN   drivers d ON d.id = en.host_driver_id
            WHERE  en.event_id     = lobby_result_screenshots.event_id
              AND  en.lobby_number = lobby_result_screenshots.lobby_number
              AND  d.user_id       = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );
