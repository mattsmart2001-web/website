-- ============================================================
-- 108 Split result screenshots
--
-- Each split host takes 4 screenshots after the race (2 qualifying,
-- 2 race results) and needs to get them to admin so results can be
-- entered. Lets the host upload them straight from their portal
-- instead of over Discord, and gives admin a per-split view to check
-- what's in.
--
-- Same shape as lobby_room_codes (migration 101): keyed by
-- (event_id, lobby_number) since lobby_number lives on entries, not
-- as its own table. Unlike room codes there's no splits_notified_at
-- gate — hosts only have anything to upload once the race has
-- actually happened, so the gate here is simply "the event has
-- started".
-- ============================================================

CREATE TABLE IF NOT EXISTS lobby_result_screenshots (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id                uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    lobby_number            int  NOT NULL,
    quali_screenshot_1_url  text,
    quali_screenshot_2_url  text,
    race_screenshot_1_url   text,
    race_screenshot_2_url   text,
    updated_by              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    updated_at              timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, lobby_number)
);

ALTER TABLE lobby_result_screenshots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "the lobby host can read their split's screenshots" ON lobby_result_screenshots
    FOR SELECT TO authenticated
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
    );

CREATE POLICY "the lobby host can post their split's screenshots" ON lobby_result_screenshots
    FOR INSERT TO authenticated
    WITH CHECK (
        (
            EXISTS (
                SELECT 1
                FROM   entries en
                JOIN   drivers d ON d.id = en.host_driver_id
                WHERE  en.event_id     = lobby_result_screenshots.event_id
                  AND  en.lobby_number = lobby_result_screenshots.lobby_number
                  AND  d.user_id       = auth.uid()
            )
            AND EXISTS (
                SELECT 1 FROM events ev
                WHERE ev.id = lobby_result_screenshots.event_id AND ev.starts_at <= now()
            )
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

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
        (
            EXISTS (
                SELECT 1
                FROM   entries en
                JOIN   drivers d ON d.id = en.host_driver_id
                WHERE  en.event_id     = lobby_result_screenshots.event_id
                  AND  en.lobby_number = lobby_result_screenshots.lobby_number
                  AND  d.user_id       = auth.uid()
            )
            AND EXISTS (
                SELECT 1 FROM events ev
                WHERE ev.id = lobby_result_screenshots.event_id AND ev.starts_at <= now()
            )
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

CREATE POLICY "admins delete split screenshots" ON lobby_result_screenshots
    FOR DELETE TO authenticated
    USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- Storage bucket for the screenshot uploads. 8MB cap (console screenshots
-- run larger than the driver-avatar/team-banner uploads). Object path is
-- "{event_id}-{lobby_number}-{slot}.{ext}" — same relaxed write policy as
-- the team banner bucket (migration 104): just require the uploader to be
-- *a* lobby host somewhere, since the real per-split gate is the table
-- RLS above, not the storage path.
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('gtec-split-screenshots', 'gtec-split-screenshots', true, 8388608)
ON CONFLICT (id) DO UPDATE SET file_size_limit = EXCLUDED.file_size_limit;

CREATE POLICY "public read gtec-split-screenshots" ON storage.objects
    FOR SELECT TO public USING (bucket_id = 'gtec-split-screenshots');

CREATE POLICY "lobby hosts upload split screenshots" ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'gtec-split-screenshots'
        AND EXISTS (
            SELECT 1 FROM entries en
            JOIN drivers d ON d.id = en.host_driver_id
            WHERE d.user_id = auth.uid()
        )
    );

CREATE POLICY "lobby hosts update split screenshots" ON storage.objects
    FOR UPDATE TO authenticated
    USING (
        bucket_id = 'gtec-split-screenshots'
        AND EXISTS (
            SELECT 1 FROM entries en
            JOIN drivers d ON d.id = en.host_driver_id
            WHERE d.user_id = auth.uid()
        )
    )
    WITH CHECK (
        bucket_id = 'gtec-split-screenshots'
        AND EXISTS (
            SELECT 1 FROM entries en
            JOIN drivers d ON d.id = en.host_driver_id
            WHERE d.user_id = auth.uid()
        )
    );
