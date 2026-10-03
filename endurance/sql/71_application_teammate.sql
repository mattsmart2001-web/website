-- Capture the teammate's details on team applications so admins have a
-- complete picture without waiting for the second driver to apply separately.
ALTER TABLE public.applications
    ADD COLUMN IF NOT EXISTS teammate_name TEXT,
    ADD COLUMN IF NOT EXISTS teammate_psn  TEXT;
