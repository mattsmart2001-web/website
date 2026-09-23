-- Track which specific driver in an entry has been nominated as lobby host.
-- NULL = no host assigned. Cleared when the entry is moved/unassigned so stale
-- host assignments don't survive a re-allocation.
ALTER TABLE public.entries
    ADD COLUMN IF NOT EXISTS host_driver_id UUID REFERENCES public.drivers(id) ON DELETE SET NULL;
