-- ============================================================
-- 129 Driver stream links
--
-- Drivers who are broadcasting their race (YouTube, Twitch, Kick, …)
-- can post the link from their portal once their split has been
-- allocated, and every stream for the current event is surfaced on the
-- public Media page so viewers can follow the racing live.
--
-- Mirrors the Race Lobby card's gating: a driver can only post a link
-- for an event they're entered in whose split has been allocated
-- (their entry has a lobby_number). One link per driver per event,
-- editable and removable by that driver.
-- ============================================================

CREATE TABLE IF NOT EXISTS driver_stream_links (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id   uuid NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    event_id    uuid NOT NULL REFERENCES events(id)  ON DELETE CASCADE,
    url         text NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (driver_id, event_id)
);

CREATE INDEX IF NOT EXISTS driver_stream_links_event_idx ON driver_stream_links (event_id);

ALTER TABLE driver_stream_links ENABLE ROW LEVEL SECURITY;

-- Public read: the Media page lists streams for everyone, logged in or not.
DROP POLICY IF EXISTS "public read stream links" ON driver_stream_links;
CREATE POLICY "public read stream links" ON driver_stream_links
    FOR SELECT USING (true);

-- A driver may post a link only for their own driver record, and only for an
-- event they're entered in whose split has been allocated (entry.lobby_number
-- is set) — the same moment the Race Lobby card unlocks in the portal.
DROP POLICY IF EXISTS "driver posts own stream link" ON driver_stream_links;
CREATE POLICY "driver posts own stream link" ON driver_stream_links
    FOR INSERT TO authenticated
    WITH CHECK (
        driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
        AND EXISTS (
            SELECT 1
            FROM   entries en
            JOIN   entry_drivers ed ON ed.entry_id = en.id
            WHERE  ed.driver_id    = driver_stream_links.driver_id
              AND  en.event_id     = driver_stream_links.event_id
              AND  en.lobby_number IS NOT NULL
        )
    );

-- A driver may edit or remove their own link.
DROP POLICY IF EXISTS "driver updates own stream link" ON driver_stream_links;
CREATE POLICY "driver updates own stream link" ON driver_stream_links
    FOR UPDATE TO authenticated
    USING      (driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid()))
    WITH CHECK (driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS "driver deletes own stream link" ON driver_stream_links;
CREATE POLICY "driver deletes own stream link" ON driver_stream_links
    FOR DELETE TO authenticated
    USING (driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid()));

-- Admins can moderate (remove) any link if needed.
DROP POLICY IF EXISTS "admin manages stream links" ON driver_stream_links;
CREATE POLICY "admin manages stream links" ON driver_stream_links
    FOR ALL TO authenticated
    USING      (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
    WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));
