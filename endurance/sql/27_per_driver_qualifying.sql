-- ============================================================
-- 27 Per-driver qualifying
-- Lets each driver in an entry record their own qualifying lap.
-- The driver_id column was previously absent and qualifying was
-- keyed per (event, entry). Now it's keyed per (event, entry, driver)
-- so two drivers sharing a car each get their own row.
-- ============================================================

ALTER TABLE qualifying_results
    ADD COLUMN IF NOT EXISTS driver_id uuid REFERENCES drivers(id) ON DELETE CASCADE;

-- Drop the old uniqueness (event_id, entry_id) — created when there was
-- only one row per entry — and add a new one that includes driver_id.
DO $$
DECLARE
    existing_constraint text;
BEGIN
    SELECT conname INTO existing_constraint
    FROM   pg_constraint
    WHERE  conrelid = 'public.qualifying_results'::regclass
      AND  contype  = 'u'
      AND  conkey  = ARRAY[
              (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.qualifying_results'::regclass AND attname = 'event_id'),
              (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.qualifying_results'::regclass AND attname = 'entry_id')
          ]::int2[];
    IF existing_constraint IS NOT NULL THEN
        EXECUTE format('ALTER TABLE public.qualifying_results DROP CONSTRAINT %I', existing_constraint);
    END IF;
END $$;

-- NULL driver_id is still allowed (for any legacy rows), but the unique
-- index ensures we don't insert duplicate (event, entry, driver) triples.
CREATE UNIQUE INDEX IF NOT EXISTS qualifying_results_event_entry_driver_unique
    ON qualifying_results (event_id, entry_id, driver_id);


-- ============================================================
-- Per-driver finish data on result_drivers
-- The shared car still finishes in one position, but admins can
-- now record each driver's individual finish (useful when drivers
-- race in separate lobby splits) plus a per-driver status.
-- ============================================================
ALTER TABLE result_drivers
    ADD COLUMN IF NOT EXISTS finish_position int,
    ADD COLUMN IF NOT EXISTS classified      boolean,
    ADD COLUMN IF NOT EXISTS status          text;
