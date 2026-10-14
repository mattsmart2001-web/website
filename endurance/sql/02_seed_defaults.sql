-- =============================================================
-- Gran Turismo GTEC — default seed data
-- =============================================================
-- Apply after 01_schema.sql.
-- Idempotent: every insert is guarded by an ON CONFLICT clause.
-- =============================================================


-- ============================================================
-- 1. Default points system
-- ============================================================
-- Per plan decision §14.1: F1 25-18-15-12-10-8-6-4-2-1
-- plus 1 point for pole and 1 point for fastest lap if classified.
INSERT INTO points_systems (id, name, points, pole_points, fastest_lap_points, finish_required_for_fl)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'F1 standard + pole + FL',
    '[
        {"position": 1,  "points": 25},
        {"position": 2,  "points": 18},
        {"position": 3,  "points": 15},
        {"position": 4,  "points": 12},
        {"position": 5,  "points": 10},
        {"position": 6,  "points":  8},
        {"position": 7,  "points":  6},
        {"position": 8,  "points":  4},
        {"position": 9,  "points":  2},
        {"position": 10, "points":  1}
    ]'::jsonb,
    1,    -- pole_points
    1,    -- fastest_lap_points
    true  -- finish_required_for_fl
)
ON CONFLICT (id) DO NOTHING;


-- ============================================================
-- 2. Starter rules pages (placeholders, edit content via admin)
-- ============================================================
INSERT INTO rules_pages (slug, title, content_md, sort_order) VALUES
    ('sporting',  'Sporting Regulations',  '# Sporting Regulations'  || E'\n\n' || '_Coming soon._', 1),
    ('technical', 'Technical Regulations', '# Technical Regulations' || E'\n\n' || '_Coming soon._', 2),
    ('penalties', 'Penalty Guidelines',    '# Penalty Guidelines'    || E'\n\n' || '_Coming soon._', 3),
    ('conduct',   'Driver Conduct',        '# Driver Conduct'        || E'\n\n' || '_Coming soon._', 4),
    ('stewards',  'Stewarding Process',    '# Stewarding Process'    || E'\n\n' || '_Coming soon._', 5)
ON CONFLICT (slug) DO NOTHING;


-- ============================================================
-- 3. Bootstrap your first admin (one-time, MANUAL)
-- ============================================================
-- This block is intentionally commented out. To bootstrap:
--   1. Sign up at /endurance/admin/login once it exists (Phase 4a),
--      OR create your user manually via the Supabase Auth dashboard.
--   2. Find your auth.users.id in the Supabase dashboard.
--   3. Replace <PASTE_YOUR_AUTH_USERS_ID_HERE> below with it.
--   4. Uncomment, run this block. You're admin.
--
-- INSERT INTO user_roles (user_id, role)
-- VALUES ('<PASTE_YOUR_AUTH_USERS_ID_HERE>'::uuid, 'admin')
-- ON CONFLICT (user_id, role) DO NOTHING;
