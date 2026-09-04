-- ============================================================
-- 19 Lobby allocation
-- entries.lobby_number lets admins split a big grid into multiple
-- skill-based race lobbies (Split 1, Split 2, ...). Optional —
-- NULL means "unassigned / single lobby".
-- ============================================================

ALTER TABLE entries
    ADD COLUMN IF NOT EXISTS lobby_number int CHECK (lobby_number IS NULL OR lobby_number > 0);

CREATE INDEX IF NOT EXISTS entries_event_lobby_idx ON entries (event_id, lobby_number);
