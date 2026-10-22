-- ============================================================
-- 43 Prevent duplicate drivers via PSN
-- A user could apply once as a driver, again as a team (which spins up
-- the applicant as the team leader) and end up with two driver rows
-- sharing the same PSN. The duplicate isn't tied to a user account so
-- lobby allocation skips it, but they still show on the public site.
--
-- This migration:
--   1. Auto-deletes the "loser" of any PSN collision where the loser is
--      unclaimed AND has no race / entry history. Safe to drop because
--      there's nothing to migrate.
--   2. Adds a case-insensitive unique index on drivers.psn_id (where it
--      isn't null / blank), so any future duplicate is refused at the DB.
--
-- If a real, history-bearing duplicate still exists after step 1, step 2
-- raises and the admin needs to merge the rows by hand first. Query:
--   SELECT lower(psn_id) AS psn, count(*), array_agg(id)
--   FROM drivers WHERE coalesce(trim(psn_id), '') <> ''
--   GROUP BY lower(psn_id) HAVING count(*) > 1;
-- ============================================================

WITH normalised AS (
    SELECT id,
           lower(trim(psn_id)) AS psn,
           user_id IS NOT NULL AS claimed,
           career_number,
           joined_at,
           created_at
    FROM   drivers
    WHERE  coalesce(trim(psn_id), '') <> ''
),
groups AS (
    SELECT psn, count(*) AS c FROM normalised GROUP BY psn HAVING count(*) > 1
),
ranked AS (
    SELECT n.id, n.psn,
           ROW_NUMBER() OVER (
               PARTITION BY n.psn
               -- Keep claimed first, then anyone with a career number,
               -- then the oldest record. Everything else loses.
               ORDER BY n.claimed DESC NULLS LAST,
                        (n.career_number IS NOT NULL) DESC,
                        n.created_at ASC NULLS LAST
           ) AS rk
    FROM   normalised n
    JOIN   groups g ON g.psn = n.psn
),
losers AS (
    SELECT id FROM ranked WHERE rk > 1
),
deletable AS (
    SELECT l.id
    FROM   losers l
    WHERE  NOT EXISTS (SELECT 1 FROM result_drivers rd WHERE rd.driver_id = l.id)
      AND  NOT EXISTS (SELECT 1 FROM entry_drivers  ed WHERE ed.driver_id = l.id)
)
DELETE FROM drivers WHERE id IN (SELECT id FROM deletable);


CREATE UNIQUE INDEX IF NOT EXISTS drivers_psn_id_ci_unique
    ON drivers (lower(trim(psn_id)))
    WHERE coalesce(trim(psn_id), '') <> '';
