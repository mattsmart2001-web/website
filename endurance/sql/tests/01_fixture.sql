-- A round at a circuit 13,600 m round, with an outline traced from the
-- line, one entered driver, and a paired reporter.
BEGIN;
INSERT INTO manufacturers (id, name, slug) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Porsche', 'porsche')
    ON CONFLICT DO NOTHING;
INSERT INTO seasons (id, year, name, slug, is_active, starts_on, ends_on,
     points_system_id) VALUES
    ('22222222-2222-2222-2222-222222222222', 2026, 'Season 1', 's1', true,
     date '2026-01-01', date '2026-12-31',
     (SELECT id FROM points_systems LIMIT 1))
    ON CONFLICT DO NOTHING;
INSERT INTO events (id, season_id, round, name, slug, circuit_name, starts_at,
                    live_session_mode, shape_closed, lap_length_m, duration_hours, ends_at)
VALUES ('33333333-3333-3333-3333-333333333333',
        '22222222-2222-2222-2222-222222222222', 8, 'Le Mans', 'le-mans',
        'Circuit de la Sarthe', now() - interval '1 hour', 'practice',
        true, 13600, 8, now() + interval '7 hours')
   ON CONFLICT (id) DO UPDATE
   SET shape_closed = true, lap_length_m = 13600;
INSERT INTO drivers (id, display_name, slug)
VALUES ('44444444-4444-4444-4444-444444444444', 'SparksTheory', 'sparkstheory')
    ON CONFLICT DO NOTHING;
INSERT INTO entries (id, event_id, lobby_number, car_number)
VALUES ('55555555-5555-5555-5555-555555555555',
        '33333333-3333-3333-3333-333333333333', 1, 23) ON CONFLICT DO NOTHING;
INSERT INTO entry_drivers (entry_id, driver_id)
VALUES ('55555555-5555-5555-5555-555555555555',
        '44444444-4444-4444-4444-444444444444') ON CONFLICT DO NOTHING;
INSERT INTO live_timing_tokens (token, driver_id)
VALUES ('tok-test', '44444444-4444-4444-4444-444444444444')
    ON CONFLICT (token) DO UPDATE SET revoked_at = NULL;
-- A circle of 13,600 m, 136 points 100 m apart, seq 0 at the line.
DELETE FROM live_track_path WHERE event_id = '33333333-3333-3333-3333-333333333333';
INSERT INTO live_track_path (event_id, seq, x, z, y)
SELECT '33333333-3333-3333-3333-333333333333', g,
       (13600/(2*pi())) * cos(2*pi()*g/136),
       (13600/(2*pi())) * sin(2*pi()*g/136), 0
  FROM generate_series(0, 135) g;
SELECT live_track_measure('33333333-3333-3333-3333-333333333333');
COMMIT;
UPDATE events SET shape_armed = false, shape_driver_id = NULL,
                  live_practice_always = true,
                  starts_at = now() + interval '20 days',
                  ends_at = now() + interval '20 days 8 hours'
 WHERE id = '33333333-3333-3333-3333-333333333333';
