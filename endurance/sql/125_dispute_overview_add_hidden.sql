-- ============================================================
-- 125 Rebuild dispute_overview to expose hidden_from_portal
--
-- Migration 124 added disputes.hidden_from_portal, but a view's "dp.*"
-- is expanded to a fixed column list when the view is created — adding a
-- column to the base table does NOT flow through. So dispute_overview
-- (created in 120) never exposed the new column, which broke the admin
-- Hide/Show toggle (always read as not-hidden) and the portal's
-- hidden_from_portal filter (referenced a column the view didn't have).
--
-- CREATE OR REPLACE can't insert a column mid-list, so drop and recreate.
-- Nothing in the database depends on this view (frontend reads only), so
-- the drop is safe. Definition is otherwise identical to migration 120;
-- dp.* now re-expands to include hidden_from_portal.
-- ============================================================

DROP VIEW IF EXISTS dispute_overview;

CREATE VIEW dispute_overview
WITH (security_invoker = true) AS
SELECT
    dp.*,
    cd.display_name AS complainant_name,
    cd.psn_id       AS complainant_psn,
    ad.display_name AS accused_name,
    ad.psn_id       AS accused_psn,
    ev.name         AS event_name,
    ev.round        AS event_round,
    ev.slug         AS event_slug,
    ev.starts_at    AS event_starts_at,
    s.year          AS season_year
FROM   disputes dp
JOIN   drivers cd ON cd.id = dp.complainant_driver_id
JOIN   drivers ad ON ad.id = dp.accused_driver_id
JOIN   events  ev ON ev.id = dp.event_id
LEFT   JOIN seasons s ON s.id = dp.season_id;

GRANT SELECT ON dispute_overview TO authenticated;
