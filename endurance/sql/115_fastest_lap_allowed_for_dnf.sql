-- ============================================================
-- 115 Fastest lap can be earned by a DNF
--
-- League rule: a driver who set the fastest lap keeps the point even if
-- they retired (DNF) — they were on track and posted the time. Drivers
-- who were disqualified, didn't start, or withdrew still get nothing.
--
-- compute_event_points awards the fastest-lap bonus when:
--     NOT finish_required_for_fl OR status IS NULL OR status = 'classified'
-- and it already zeroes ALL points (including FL) for dsq / dns /
-- withdrawn before that check. So flipping finish_required_for_fl to
-- false makes the FL bonus reach a DNF while leaving dsq/dns/withdrawn
-- at zero — exactly the rule we want. No function change needed.
--
-- The admin results form now lets FL be ticked for a DNF too (positions
-- and pole stay classified-only). After applying this, use Recompute
-- Points on any event where a DNF driver should receive the FL point.
--
-- Note: this does not change the "Fastest Laps" stat counters, which
-- still count classified finishes only (per decision — point only).
-- ============================================================

UPDATE points_systems
   SET finish_required_for_fl = false
 WHERE finish_required_for_fl IS DISTINCT FROM false;
