-- Add qualifying settings fields to events
-- quali_same_as_race: when true, qualifying uses identical lobby settings to the race
-- quali_notes: free-text qualifying instructions shown to the lobby host (used when quali_same_as_race is false)

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS quali_same_as_race boolean NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS quali_notes text;
