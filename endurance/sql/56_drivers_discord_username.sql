-- ============================================================
-- 56 Discord username on drivers
-- Applications already carried discord_username (mig 13). Promote it
-- to a first-class field on drivers so the handle survives application
-- acceptance and drivers can update it from their portal.
-- Also backfills the column from the original linked application row
-- where one exists, so existing rostered drivers don't lose theirs.
-- ============================================================

ALTER TABLE drivers
    ADD COLUMN IF NOT EXISTS discord_username text;

-- Backfill from the linked application row, if any. The application's
-- linked_driver_id column was added in mig 10 — we only touch driver
-- rows that have a matching application with a non-blank discord
-- handle and don't already have one set on the driver side.
UPDATE drivers d
   SET discord_username = a.discord_username
  FROM applications a
 WHERE a.linked_driver_id = d.id
   AND coalesce(trim(a.discord_username), '') <> ''
   AND coalesce(trim(d.discord_username), '') = '';
