-- Add willing_host to applications and drivers.
-- Applicants can opt-in to hosting a lobby; this carries through to their driver record.
ALTER TABLE public.applications ADD COLUMN IF NOT EXISTS willing_host BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.drivers      ADD COLUMN IF NOT EXISTS willing_host BOOLEAN NOT NULL DEFAULT FALSE;
