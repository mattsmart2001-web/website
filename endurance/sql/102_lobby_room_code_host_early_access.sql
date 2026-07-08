-- ============================================================
-- 102 Let hosts post the lobby room code as soon as splits exist
--
-- The write RLS on lobby_room_codes (migration 101) required
-- events.splits_notified_at to be set — but hosts should be able to
-- prep/post the Lobby ID as soon as they're assigned, not wait for
-- Notify Drivers. Regular (non-host) drivers still only see the card
-- once notified, since before that they don't officially know their
-- own split yet — that part is enforced in the portal query, not RLS,
-- so no DB change needed for it.
-- ============================================================

DROP POLICY IF EXISTS "the lobby host can set the room code" ON lobby_room_codes;
CREATE POLICY "the lobby host can set the room code" ON lobby_room_codes
    FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM   entries en
            JOIN   drivers d ON d.id = en.host_driver_id
            WHERE  en.event_id     = lobby_room_codes.event_id
              AND  en.lobby_number = lobby_room_codes.lobby_number
              AND  d.user_id       = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );

DROP POLICY IF EXISTS "the lobby host can update the room code" ON lobby_room_codes;
CREATE POLICY "the lobby host can update the room code" ON lobby_room_codes
    FOR UPDATE TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM   entries en
            JOIN   drivers d ON d.id = en.host_driver_id
            WHERE  en.event_id     = lobby_room_codes.event_id
              AND  en.lobby_number = lobby_room_codes.lobby_number
              AND  d.user_id       = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM   entries en
            JOIN   drivers d ON d.id = en.host_driver_id
            WHERE  en.event_id     = lobby_room_codes.event_id
              AND  en.lobby_number = lobby_room_codes.lobby_number
              AND  d.user_id       = auth.uid()
        )
        OR EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    );
