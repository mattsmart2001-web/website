# Gran Turismo GTEC — Build Plan & Specification

(brand: **Gran Turismo GTEC**; the project was initially scoped as
"GT Endurance Championship" and that phrase still appears in several
places below — they all refer to Gran Turismo GTEC.)

> **Status:** Pre-build planning. No production code yet.
> Hidden behind `/endurance/` during development.
> Last updated: 2026-05.

---

## 0. Document purpose

This document is the agreed-upon source of truth before any code lands in
`/endurance/`. It captures:

- The architecture and stack we'll use
- The full database schema
- Auth model and permission structure
- Every public page, with content + interaction notes
- Every admin capability
- The statistics + Elo rating engines
- The API / function surface
- Build phasing with realistic effort estimates
- Open decisions that need your input
- Tech risks and how we mitigate them

Nothing here is final until you sign off. Treat the **Open Questions**
section at the bottom as the gating list — those need answers before
Phase 2 begins.

---

## 1. Vision & scope

### What GTEC is

A professional-feeling motorsport championship platform for the Gran
Turismo 7 endurance league:

- Single-class racing (Gr.3 cars only)
- Teams of 2 drivers
- Cars locked to a manufacturer for the season
- Each race ≥ 6 hours
- Multiple seasons supported with permanent historical data
- Design language: dark, professional, FIA-WEC / F1-stats inspired

### What GTEC is **not** (out of initial scope)

- Live in-race telemetry (parked under "future features")
- Driver transfer market (future)
- Fantasy league (future)
- Public broadcast overlay (future)
- Mobile apps (web-only, but mobile-responsive)
- Public open registration (drivers are added by admins)

---

## 2. Architecture decisions

| Concern | Decision | Why |
|---|---|---|
| Hosting | Existing Netlify site | Already configured, CDN-cached, no extra cost |
| Frontend | Static HTML + vanilla JS modules | Matches existing site, no build pipeline, easy to maintain |
| Database | Supabase (Postgres) | Already loaded on `sparkstheory.co.uk`, generous free tier, has Auth + RLS built in |
| Auth | Supabase Auth (email/password + magic-link) | Built-in, no third-party signup |
| Storage | Supabase Storage | Co-located with DB, cheap, simple SDK |
| Server-side compute | Netlify Functions for heavy / privileged work | Existing pattern in this repo |
| Stats / Elo recomputation | Postgres functions (PL/pgSQL) + scheduled jobs | Keep logic close to data, avoid round-trips |
| Real-time updates | Supabase realtime channels (race-day standings) | Built into Supabase, no extra infra |
| Search | Postgres full-text search (initial), Algolia later if needed | Free, good enough for ~thousands of rows |
| Charts | Chart.js (already loaded on main site) | Reuse existing dependency |

### Stack diagram

```
  ┌───────────────┐         ┌──────────────────────────────┐
  │   Browser     │  HTTPS  │  Netlify CDN                 │
  │ static pages  │ ◄─────► │  /endurance/*.html, *.js     │
  │ admin SPA     │         │                              │
  └──────┬────────┘         │  Netlify Functions           │
         │                  │  /.netlify/functions/…       │
         │ Supabase JS SDK  └──────────────┬───────────────┘
         │                                 │
         ▼                                 ▼
  ┌──────────────────────────────────────────────────────┐
  │  Supabase                                            │
  │  ┌─────────────┐  ┌────────┐  ┌──────────────────┐   │
  │  │ Postgres    │  │ Auth   │  │ Storage (assets) │   │
  │  │  RLS rules  │  │ JWT    │  │  logos, photos   │   │
  │  └─────────────┘  └────────┘  └──────────────────┘   │
  └──────────────────────────────────────────────────────┘
```

### What does **not** change about the existing site

- Main domain remains the SparksTheory racing site
- `/signup`, `/drivers`, `/lights-out`, etc. stay as they are
- GTEC lives entirely under `/endurance/*` with its own nav
- Until launch, `/endurance/*` is `noindex` + disallowed in `robots.txt`

---

## 3. Database schema

All tables live in the Supabase `public` schema. UUIDs for primary keys.
Naming convention: snake_case table names, plural.

### 3.1 Entity overview

```
seasons ──┬─< events ──< entries ──< results
          │             │           └─< qualifying_results
          │             │           └─< penalties
          │             │           └─< steward_decisions
          │             │           └─< driver_ratings (snapshot)
          │             └─< event_media
          └─< standings_drivers (materialized)
          └─< standings_teams   (materialized)
          └─< standings_makes   (materialized)

teams ──< team_drivers >── drivers
manufacturers ──< teams
manufacturers ──< drivers (current_manufacturer)

users (Supabase Auth) ──< user_roles
users ──< drivers.user_id (1:1 optional)

news_articles
hall_of_fame_records (cached / materialized)
rules_pages
```

### 3.2 Tables

#### `users`
Supabase's built-in `auth.users`. We don't duplicate it — we reference
`auth.users.id` in `user_roles`.

#### `user_roles`
```
id                uuid PK
user_id           uuid FK auth.users(id)
role              enum('admin','steward','editor','team_manager')
team_id           uuid FK teams(id)  -- only for team_manager
created_at        timestamptz
```
RLS: only admins can insert/update. Self-readable.

#### `manufacturers`
```
id                uuid PK
name              text unique   -- "BMW", "Porsche", "Ferrari", …
slug              text unique
logo_url          text          -- Supabase Storage URL
brand_color       text          -- hex, used across UI
country           text
created_at        timestamptz
```

#### `drivers`
```
id                uuid PK
user_id           uuid FK auth.users(id) NULL  -- optional, links a self-managed profile
display_name      text
slug              text unique
psn_id            text
nationality       text          -- ISO country code
date_of_birth     date NULL
bio               text
photo_url         text
joined_at         date
current_team_id   uuid FK teams(id) NULL
current_manufacturer_id  uuid FK manufacturers(id) NULL
career_number     int  NULL     -- driver's racing number, like F1
created_at        timestamptz
updated_at        timestamptz
```

#### `teams`
```
id                uuid PK
name              text
slug              text unique
logo_url          text
founded_on        date
manager_user_id   uuid FK auth.users(id) NULL
manufacturer_id   uuid FK manufacturers(id)     -- current season default
home_country      text
bio               text
created_at        timestamptz
```

#### `team_seasons`
A team's season registration. Locks the team to a single manufacturer
for the whole season (strict manufacturer lock, per decision §14.4).
```
id                uuid PK
team_id           uuid FK teams(id)
season_id         uuid FK seasons(id)
manufacturer_id   uuid FK manufacturers(id)
registered_at     timestamptz
admin_override_at timestamptz NULL    -- set if manufacturer was changed mid-season
admin_override_reason text NULL
UNIQUE (team_id, season_id)
```
A `BEFORE INSERT OR UPDATE` trigger on `entries` checks that
`entries.manufacturer_id` equals `team_seasons.manufacturer_id` for
`(entries.team_id, entries.event.season_id)`. Mismatch → raises an
exception, blocked at the DB level.

#### `team_drivers`
Join table, snapshots driver lineup per season.
```
id                uuid PK
team_id           uuid FK teams(id)
driver_id         uuid FK drivers(id)
season_id         uuid FK seasons(id)
role              enum('lead','co','reserve')
joined_event_id   uuid FK events(id) NULL     -- if mid-season addition
left_event_id     uuid FK events(id) NULL     -- if mid-season departure
created_at        timestamptz
UNIQUE (team_id, driver_id, season_id)
```

#### `seasons`
```
id                uuid PK
year              int unique          -- 2027, 2028, …
name              text                -- "2027 Championship"
slug              text unique         -- "2027"
starts_on         date
ends_on           date
points_system_id  uuid FK points_systems(id)
is_active         boolean
hero_image_url    text
description       text
created_at        timestamptz
```

#### `points_systems`
A season can use a different points table.
```
id                uuid PK
name              text                -- "Standard 25-18-15-12-10-8-6-4-2-1"
points            jsonb               -- [{ position: 1, points: 25 }, …]
pole_points       int default 0
fastest_lap_points int default 0
finish_required_for_fl boolean default true
created_at        timestamptz
```

#### `events`
```
id                uuid PK
season_id         uuid FK seasons(id)
round             int
name              text                -- "Spa 6 Hours"
slug              text                -- "spa-6h"
circuit_name      text
circuit_country   text                -- ISO
circuit_length_km numeric(5,3)
duration_hours    numeric(4,1)        -- 6, 8, 12, 24
starts_at         timestamptz
ends_at           timestamptz
weather_summary   text
hero_image_url    text
status            enum('scheduled','in_progress','completed','cancelled')
replay_url        text NULL
notes             text
created_at        timestamptz
UNIQUE (season_id, round)
```

#### `entries`
The starting list — one row per car per event.
```
id                uuid PK
event_id          uuid FK events(id)
team_id           uuid FK teams(id)
car_number        int
manufacturer_id   uuid FK manufacturers(id)
car_model         text                -- "BMW M6 GT3 Endurance Model '16"
livery_image_url  text NULL
status            enum('confirmed','withdrawn','dnq')
created_at        timestamptz
UNIQUE (event_id, car_number)
```

#### `entry_drivers`
Which drivers crew which entry.
```
id                uuid PK
entry_id          uuid FK entries(id)
driver_id         uuid FK drivers(id)
stint_role        enum('starting','reserve')   -- starting driver gets the grid slot
created_at        timestamptz
UNIQUE (entry_id, driver_id)
```

#### `qualifying_results`
```
id                uuid PK
event_id          uuid FK events(id)
entry_id          uuid FK entries(id)
position          int
best_lap_ms       int NULL              -- best qualifying lap in ms
gap_ms            int NULL              -- to pole
notes             text
created_at        timestamptz
UNIQUE (event_id, entry_id)
UNIQUE (event_id, position)
```

#### `results`
```
id                uuid PK
event_id          uuid FK events(id)
entry_id          uuid FK entries(id)
finish_position   int NULL              -- NULL if DNF
classified        boolean               -- met minimum laps
laps_completed    int
total_time_ms     int NULL
gap_to_winner_ms  int NULL
status            enum('classified','dnf','dsq','dns','withdrawn')
dnf_reason        text NULL
fastest_lap_ms    int NULL
fastest_lap_lap   int NULL
points_awarded    int default 0
fastest_lap_point boolean default false
pole_point        boolean default false
notes             text
created_at        timestamptz
UNIQUE (event_id, entry_id)
```

#### `result_drivers`
Which drivers actually drove the car in the race (for stats credit).
```
id                uuid PK
result_id         uuid FK results(id)
driver_id         uuid FK drivers(id)
stint_seconds     int NULL              -- their drive time
laps_driven       int NULL
points_share      numeric(5,2)          -- 0.0 to 1.0
created_at        timestamptz
UNIQUE (result_id, driver_id)
```

#### `penalties`
```
id                uuid PK
event_id          uuid FK events(id)
entry_id          uuid FK entries(id)
driver_id         uuid FK drivers(id) NULL    -- if attributable to one driver
penalty_type      enum('drive_through','stop_go','time_add','grid_drop','dsq','warning','reprimand')
penalty_value     text                  -- "30s", "5s", "5 grid", …
reason            text
laps_remaining_when_applied int NULL
created_at        timestamptz
issued_by         uuid FK auth.users(id) NULL
```

#### `steward_decisions`
```
id                uuid PK
event_id          uuid FK events(id)
entry_id          uuid FK entries(id) NULL
driver_id         uuid FK drivers(id) NULL
decision_no       text                  -- "Doc 12"
title             text
content           text                  -- markdown
ruling            enum('no_action','reprimand','penalty','dsq')
issued_at         timestamptz
issued_by         uuid FK auth.users(id)
```

#### `driver_ratings`
Snapshot after every event. The current rating = most recent row.
```
id                uuid PK
driver_id         uuid FK drivers(id)
event_id          uuid FK events(id)
rating_before     int
rating_after      int
delta             int
reason            text                  -- "Finished P3 vs expected P7"
created_at        timestamptz
UNIQUE (driver_id, event_id)
```

#### `news_articles`
```
id                uuid PK
title             text
slug              text unique
author_user_id    uuid FK auth.users(id)
content_md        text
featured_image    text
published_at      timestamptz NULL      -- NULL = draft
tags              text[]
season_id         uuid FK seasons(id) NULL
event_id          uuid FK events(id) NULL
created_at        timestamptz
updated_at        timestamptz
```

#### `media`
```
id                uuid PK
url               text                  -- Supabase Storage URL
type              enum('image','video_embed','youtube')
caption           text
season_id         uuid FK seasons(id) NULL
event_id          uuid FK events(id) NULL
driver_id         uuid FK drivers(id) NULL
team_id           uuid FK teams(id) NULL
sort_order        int default 0
created_at        timestamptz
```

#### `rules_pages`
```
id                uuid PK
slug              text unique           -- 'sporting', 'technical', 'penalties', …
title             text
content_md        text
sort_order        int
updated_at        timestamptz
updated_by_user_id uuid FK auth.users(id)
```

#### `hall_of_fame_records`
Manually curated and/or auto-populated.
```
id                uuid PK
category          enum('most_wins','most_championships','highest_rating',
                       'most_race_hours','longest_win_streak',
                       'most_consecutive_finishes','fastest_lap')
driver_id         uuid FK drivers(id) NULL
team_id           uuid FK teams(id) NULL
value             text                  -- "47 wins", "5:19.55", …
context           text                  -- "set at Spa 6h, 2027"
event_id          uuid FK events(id) NULL
sort_order        int default 0
auto_generated    boolean default false
created_at        timestamptz
```

#### Materialized views

For high-traffic stats pages we use `MATERIALIZED VIEW`s refreshed on
data change:

- `standings_drivers` (season_id, driver_id, points, wins, podiums, poles,
  flaps, starts, dnfs, avg_finish)
- `standings_teams` (season_id, team_id, points, wins, podiums, …)
- `standings_makes` (season_id, manufacturer_id, points, wins, podiums, …)
- `career_stats_drivers` (driver_id, all-time totals)
- `career_stats_teams` (team_id, all-time totals)

Refresh trigger: any insert/update on `results`, `qualifying_results`,
`penalties` → enqueue refresh via Postgres `LISTEN`/`NOTIFY` or scheduled
cron.

---

## 4. Authentication & permissions

### Roles

| Role | Can |
|---|---|
| `admin` | Everything. Manages all data, all users. |
| `steward` | Create steward decisions + penalties. Cannot edit results directly. |
| `editor` | Create + edit news articles, manage media. No competition data. |
| `team_manager` | Edit own team's profile + logo + lineup. Cannot edit results. |
| `driver` | Edit own driver profile (bio, photo, social handles) via the driver portal. Cannot edit anything else. |
| (no role) | Read-only public access. |

### Driver claim flow

Driver records are created by admins. To activate self-edit on a profile:
1. Admin clicks "Generate claim link" on the driver record.
2. A short-lived (24h) signed URL is emailed (or shared via Discord) to
   the driver: `/endurance/profile/claim/<token>`.
3. The driver signs up with Supabase Auth on that page; the token is
   exchanged for a row in `user_roles` (`role = 'driver'`) and the
   `drivers.user_id` field is set to their `auth.users.id`.
4. From then on they can log into `/endurance/profile/` and edit their
   own bio/photo/socials only.

### RLS policies

- All competition tables (`events`, `entries`, `results`, etc.) are
  **read public** for published seasons, **write admin-only**.
- `news_articles`: read-public if `published_at <= now()`; write editor/admin.
- `teams`: read public; team_manager can update own row only.
- `drivers`: read public; admin can write any row; a driver linked
  via `user_id` can update their own `bio` and `photo_url` only.
- `user_roles`: admin-only read/write. Self-readable for current user.

### Login flow

- `/endurance/admin/login` page: email + password (Supabase Auth) +
  optional magic-link fallback.
- On successful login: check `user_roles`. Redirect to `/endurance/admin/`
  dashboard. No role → log out + message.
- Sessions persist via Supabase's auto-refresh cookies.

### Bootstrap admin

The first admin is seeded by hand: SQL `insert into user_roles (user_id,
role) values (<your auth.users.id>, 'admin')`. Documented in the README.

---

## 5. URL & routing structure

### Public

```
/endurance/                              Home
/endurance/seasons/                      Season index (all seasons)
/endurance/seasons/2027/                 Current season hub
/endurance/seasons/2027/calendar/        Calendar
/endurance/seasons/2027/standings/       Standings (drivers/teams/makes tabs)
/endurance/seasons/2027/standings/teams/
/endurance/seasons/2027/standings/manufacturers/
/endurance/races/spa-6h-2027/            Race centre
/endurance/teams/                        Teams index
/endurance/teams/<slug>/                 Team profile
/endurance/drivers/                      Drivers index
/endurance/drivers/<slug>/               Driver profile
/endurance/statistics/                   Stats centre
/endurance/hall-of-fame/                 Records
/endurance/media/                        Gallery
/endurance/news/                         News index
/endurance/news/<slug>/                  Article
/endurance/rules/                        Rules index
/endurance/rules/<slug>/                 Rules page
```

### Admin (SPA, hash-routed inside `admin/`)

```
/endurance/admin/                        Dashboard summary
/endurance/admin/seasons                 List + create + edit
/endurance/admin/events                  Per-event editor
/endurance/admin/events/:id/entries
/endurance/admin/events/:id/qualifying
/endurance/admin/events/:id/results
/endurance/admin/events/:id/penalties
/endurance/admin/events/:id/decisions
/endurance/admin/teams
/endurance/admin/drivers
/endurance/admin/manufacturers
/endurance/admin/news
/endurance/admin/media
/endurance/admin/rules
/endurance/admin/hall-of-fame
/endurance/admin/users                   Role management
```

### Functions (server-side)

```
/.netlify/functions/gtec-recalc-standings     trigger refresh of all
                                              materialized views for a season
/.netlify/functions/gtec-recalc-elo           recompute ratings forward from
                                              an event (after a result edit)
/.netlify/functions/gtec-csv-import           parse CSV of race results
                                              and write rows
/.netlify/functions/gtec-discord-post         (future) post race summaries
                                              to Discord webhook
```

---

## 6. Page specifications

For each public page: purpose, content blocks, data sources, interaction
notes. Wireframes are text-based; final layout in design phase.

### 6.1 Home (`/endurance/`)

**Purpose:** Land-and-orient. Make it clear what GTEC is, what's
happening now, what's next.

**Blocks:**
1. **Hero** — full-bleed image, "GT Endurance Championship", current
   season tagline. CTA: "View standings", "Next race".
2. **Live ribbons** — three small cards: Drivers' leader, Teams' leader,
   Manufacturers' leader (avatar/logo + name + points).
3. **Next race countdown** — flip-clock style, target = next `events.starts_at`.
4. **Latest results** — last completed race: podium with photos.
5. **Standings preview** — top 5 drivers + top 3 teams, "View full standings".
6. **Featured driver** — rotating spotlight (random or curated via flag).
7. **Recent news** — three latest published articles.
8. **Historical records strip** — current-season highlights (fastest lap,
   most wins this year, etc.).

**Data:** mostly from materialized views + a couple of `events` queries.

### 6.2 Championship (`/endurance/seasons/2027/`)

Per-season hub: hero, description, points system explainer, season
results so far, links into Calendar/Standings/Drivers/Teams scoped to
this season, season news.

### 6.3 Calendar (`/endurance/seasons/2027/calendar/`)

Vertical timeline. Each round: round number, name, circuit, country
flag, date, duration, status (scheduled / done / next-up highlight).
Past rounds link to race centre. Future rounds show countdown.

### 6.4 Race Centre (`/endurance/races/<slug>/`)

Tabs: **Overview · Entry List · Qualifying · Race · Penalties ·
Stewards · Media**.

- **Overview**: hero, track info, weather, narrative summary,
  podium + fastest lap, replay download link.
- **Entry List**: sortable table — car #, team, manufacturer, drivers,
  livery thumbnail.
- **Qualifying**: position table with gap-to-pole and lap times.
- **Race**: full result table — Pos, # , Team, Drivers, Laps, Gap,
  Status, Pts, FL marker, Pole marker. Sortable.
- **Penalties**: list of penalties applied during the race.
- **Stewards**: published steward decisions, each a card with title,
  ruling, expandable content.
- **Media**: image gallery + embedded videos for this event.

### 6.5 Standings (`/endurance/seasons/2027/standings/`)

Three tabs: **Drivers · Teams · Manufacturers**. Each is a ranked
table with points, wins, podiums, poles, fastest laps, starts. Click
a row → driver/team/manufacturer profile.

### 6.6 Teams (`/endurance/teams/`)

Grid of team cards: logo, name, manufacturer, current season points.
Click → team profile.

### 6.7 Team profile (`/endurance/teams/<slug>/`)

- Hero: logo, name, manufacturer
- Quick stats: starts, wins, podiums, championships, all-time points
- Current drivers (linked to driver profiles)
- Season-by-season points history (Chart.js line)
- Recent race results table
- Driver lineup history table

### 6.8 Drivers (`/endurance/drivers/`)

Same pattern as Teams index — grid of driver cards (photo, name,
nationality flag, rank pill, team).

### 6.9 Driver profile (`/endurance/drivers/<slug>/`)

- Hero: photo, name, nationality flag, current rating + rank pill,
  current team
- Bio
- Stats panel: starts, wins, podiums, poles, fastest laps, race hours,
  laps completed, avg finish, DNFs, reliability %, championships,
  career points
- Rating history graph (line chart from `driver_ratings`)
- Season results table per season
- Recent races (last 5)

### 6.10 Statistics (`/endurance/statistics/`)

Tabs: **Drivers · Teams · Manufacturers**. Each tab shows multiple
sortable leaderboard widgets — e.g. Most Wins, Most Podiums,
Highest Rating, Best Avg Finish, etc.

### 6.11 Hall of Fame (`/endurance/hall-of-fame/`)

A grid of record cards. Each card: category, record holder
(driver/team), value, context, when set. Categories pulled from
`hall_of_fame_records` ordered by `sort_order`.

### 6.12 Media (`/endurance/media/`)

Masonry image grid. Filters: season, race, driver, team.
Lightbox on click. YouTube embeds inline.

### 6.13 News (`/endurance/news/`)

Article index. Title, hero image, excerpt, publish date, tags.
Article page renders rendered Markdown content with hero.

### 6.14 Rules (`/endurance/rules/`)

Sidebar list of sections, content area renders Markdown. Sections
come from `rules_pages` ordered by `sort_order`.

---

## 7. Admin dashboard specification

A SPA at `/endurance/admin/` requiring login. Layout: left sidebar
of sections, top bar with current user / logout, main content area.

### Capabilities by section

- **Dashboard summary**: stat cards (current season events done / left,
  pending steward decisions, draft news count, recently-updated rows).
- **Seasons**: CRUD. Mark `is_active`. Pick `points_system`.
- **Events**: CRUD. Status changes auto-cascade (mark `completed` →
  trigger standings refresh).
- **Entry List editor**: per-event table, add/remove entries, assign
  drivers.
- **Qualifying editor**: enter positions + lap times. Auto-compute gap.
- **Race results editor**: enter positions + laps + total time + DNFs.
  On save: trigger points calc + standings refresh + Elo recalc.
- **Penalties editor**: add per-event penalties, optionally retroactively
  adjusting points (admin choice).
- **Steward decisions editor**: rich text (markdown). Publish-toggle.
- **Teams**: CRUD, logo upload (Supabase Storage), driver lineup history.
- **Drivers**: CRUD, photo upload, link to `auth.users` account.
- **Manufacturers**: CRUD, logo upload, brand colour.
- **News**: CRUD, rich-text editor (we'll use markdown + preview to
  keep deps minimal; later we can upgrade to TipTap if needed),
  publish-toggle, schedule future publish.
- **Media**: bulk upload to Supabase Storage, tag by season/event/etc.
- **Rules**: edit each section's markdown. Diff history (Postgres
  `pg_temporal_tables` or a manual revisions table).
- **Hall of Fame**: manual records + button to refresh
  auto-generated ones.
- **Users**: list of `auth.users` + their `user_roles`. Add/revoke roles.

### Admin UX patterns

- Form validation client-side + server-side (Postgres CHECK + RLS).
- Optimistic UI: show change immediately, rollback on error.
- Confirm modals on destructive ops.
- Toast notifications for success/error.
- Per-row "history" link → reveal change log.

---

## 8. Elo rating engine

### Starting rating: **1500**

### Calculation (per race, per driver)

For each driver D in result R of event E:
1. **Expected position** = predicted finish based on starting rating vs
   field's ratings. Higher rating ⇒ better expected position.
2. **Actual position** = `result.finish_position`. DNF treated as
   `(field_size + 1) / 2` median penalty (not last) to avoid harsh
   punishment for mechanical failures outside driver's control.
3. **Score** = `1 - (actual_position - 1) / (field_size - 1)`
   (1.0 for the winner, 0.0 for last).
4. **Expected score** = average expectation against the field, computed
   as Σ for each other driver of `1 / (1 + 10^((other_rating - my_rating) / 400))`
   normalised by field size.
5. **K-factor**:
   - 32 for first 10 races (rookie scaling)
   - 24 for races 11–30
   - 16 thereafter
6. **Delta** = round(K × (Score − ExpectedScore))
7. **New rating** = clamp(old + delta, 800, 3000)
8. Insert row into `driver_ratings` with the before/after.

### Multi-driver teams

The team's race finish gives a points share to each driver per their
`stint_seconds / total_stint_seconds`. Rating delta is scaled by the
same share — a driver who drove 10% of the race only gets 10% of the
rating delta. Prevents free rides AND prevents unfair penalties for
short stints.

### Recompute-forward semantics

If an admin edits a past result, we must invalidate every `driver_ratings`
row from that event onwards and recompute in chronological order. The
`gtec-recalc-elo` function does this.

### Rank labels

- 2500+ Legend
- 2200+ Elite
- 1900+ Pro
- 1600+ Gold
- 1300+ Silver
- < 1300 Bronze

---

## 9. Statistics engine

### Computed on result-write triggers

Most stats are derivable from the underlying tables. Two approaches:

- **Materialized views** for season standings + career totals. Refreshed
  on result change.
- **Computed columns** (Postgres generated columns) for per-row derived
  values (e.g. `gap_to_winner_ms`).

### Stats computed per driver (career)

- starts, wins, podiums, poles, fastest_laps, dnfs
- laps_completed, race_hours
- avg_finish (only counts classified results)
- reliability_pct = classified_results / starts × 100
- championships (count of season_id where driver placed 1st in
  driver standings)
- career_points (sum across seasons)
- best_finish, worst_finish
- average_qual_position
- longest_win_streak, longest_podium_streak, longest_finish_streak
- current_rating (from latest `driver_ratings` row)

### Stats computed per team (career)

Same fields plus team-specific:
- championships_won (manufacturer + team)
- highest_finish_at_each_event
- longest_active_season_streak

### Stats computed per manufacturer (career)

- wins, podiums, poles, championships
- by-season points history

### Refresh schedule

- On `INSERT/UPDATE/DELETE` on `results`/`qualifying_results`/`penalties`,
  enqueue a refresh via `pg_notify`.
- A scheduled Postgres function (or Netlify scheduled function) runs
  `REFRESH MATERIALIZED VIEW CONCURRENTLY` for affected views.
- Hall-of-Fame `auto_generated` rows are recomputed nightly + on
  championship season close.

---

## 10. API / function surface

### Public read endpoints

All public reads go directly to Supabase via the JS SDK using the
anon key. RLS enforces what's readable. No custom REST layer needed
for reads.

### Privileged writes & expensive operations

| Function | Purpose | Auth |
|---|---|---|
| `gtec-recalc-standings` | Refresh materialized views for a season | Admin JWT |
| `gtec-recalc-elo` | Replay rating calculations forward from an event | Admin JWT |
| `gtec-csv-import` | Bulk-import race results from a CSV | Admin JWT |
| `gtec-storage-sign` | Issue signed Supabase Storage upload URLs | Admin/Editor JWT |
| `gtec-discord-post` | Post a race summary to Discord webhook | Cron / Admin |

Each function verifies the Supabase JWT in the `Authorization` header
and the `user_roles` row before acting.

### Public JSON API (future)

When ready, expose `GET /endurance/api/v1/...` (Netlify Functions
proxying Supabase queries) with API-key gating and rate limits. Out of
scope for Phase 1–5.

---

## 11. Media & file storage

- **Bucket layout** in Supabase Storage:
  - `gtec-logos/teams/<team_id>.png`
  - `gtec-logos/manufacturers/<manufacturer_id>.png`
  - `gtec-drivers/<driver_id>.jpg`
  - `gtec-media/<season>/<event>/<filename>`
  - `gtec-news/<article_id>/<filename>`
- All buckets are **public read**, **authenticated write**.
- Uploads use signed URLs from `gtec-storage-sign` so the admin SPA
  never needs the service-role key.
- All images served via Supabase's transformation API (resize/quality).
- Caching: long max-age on logos and driver photos; shorter on
  newsroom assets.

---

## 12. Hidden development setup

Until you flip the launch switch:

- **robots.txt**: add `Disallow: /endurance/`
- **Per-page meta**: `<meta name="robots" content="noindex, nofollow">` on
  every `/endurance/*` HTML file.
- **Not linked from any other page**: no nav entry, no footer link.
- **Optional**: a Netlify Edge Function or `_redirects` rule that
  password-gates `/endurance/*` during dev:
  ```
  /endurance/*  https://gate.netlify.app  401!  Basic-Auth-User=admin
  ```
  We'd ship a simple HTTP-basic gate so only people who know the
  password can see it, even if they guess the URL.
- **Search engine sweep**: once we launch, remove the robots disallow
  and submit the sitemap.

---

## 13. Build phases (revised, with realistic effort)

Each phase ends with a shippable artefact behind the hidden gate.

| Phase | Deliverable | Est. hours | Dependencies |
|---|---|---|---|
| **1** | This plan doc + folder scaffolding + `robots.txt` update | 3 | – |
| **2** | Supabase project setup. Apply full schema migration. Bootstrap admin user. README updated with credentials handling. | 4 | DB password and project info from you |
| **3** | Hidden landing page at `/endurance/` (coming-soon style, GTEC branding, planned 2027 calendar teaser) | 3 | Phase 1 |
| **4a** | Admin auth + login page + protected admin shell. CRUD for **Seasons**, **Manufacturers**, **Teams**, **Drivers**, **team_seasons** (strict manufacturer-lock registration). | 12 | Phase 2 |
| **4b** | Driver self-serve **profile portal** at `/endurance/profile/`. Claim-link flow. Driver edits bio / photo / socials only. RLS rules for the `driver` role. | 6 | Phase 4a |
| **5** | Admin CRUD for **Events** + **Entries** + **Entry Drivers** (with `team_seasons` manufacturer-lock validation). Public Calendar + Race-Centre Overview page. | 14 | Phase 4a |
| **6** | Admin: **Qualifying** + **Results** + **Penalties** entry. Points calculation + standings materialized views. Public Standings page. | 18 | Phase 5 |
| **7** | Public **Driver profiles** + **Team profiles** + career stats. | 12 | Phase 6 |
| **8** | **Elo engine** + driver rating snapshots + rating history graph. | 10 | Phase 7 |
| **9** | **Statistics centre** + **Hall of Fame** auto-records. | 10 | Phase 8 |
| **10** | **News CMS** + **Media gallery** + **Rules** editor. | 14 | Phase 4 |
| **11** | Seed data: one complete fictional 2027 season (drivers, teams, 6 events with full results) so the platform can be demoed. | 8 | Phase 6 |
| **12** | Steward decisions + penalty workflow polish. | 6 | Phase 6 |
| **13** | Pre-launch QA, accessibility pass, mobile polish, real performance audit. | 6 | All |
| **14** | Launch: drop robots disallow, add nav entry, submit sitemap, announce. | 1 | Owner ready |

**Estimated total**: ~120 hours of focused work. Spread across (say) 2–3 sessions per week at 4 hours each, that's 10–15 weeks to full feature parity with the spec.

Phases 1–6 (~54 hours) cover the **competition core**: you can run a
season end-to-end on it. Phases 7–10 add the polished public face.
Phases 11–14 are pre-launch sealing.

### Future-features phases (out of MVP)

- Live timing integration
- Driver transfer market
- Fantasy league
- Race control dashboard
- Broadcast overlay support
- Public JSON API
- Mobile apps

---

## 14. Decisions (all locked) ✅

1. **Points system.** F1 25-18-15-12-10-8-6-4-2-1 + 1 point for pole + 1 point for fastest lap (only if classified).
2. **Driver substitutions mid-season.** Allowed any time. Points credited to the driver who actually drove.
3. **Per-driver vs per-team scoring.** All entered drivers of an entry get the full points; the team gets one set of points; per-driver Elo is scaled by stint share.
4. **Manufacturer lock.** **Strict.** Each team registers ONE manufacturer per season. All entries that team enters must use that manufacturer for the entire season. Drivers in those entries inherit the manufacturer from the team-season registration. Enforced at the DB level via `team_seasons` table (see §3 update) and at the admin UI level.
5. **Result data entry.** Manual via admin form only for MVP. CSV import deferred to future feature.
6. **Steward decisions.** Publish **immediately on save** (no draft state). The "Edit" affordance stays available afterwards in case of correction.
7. **News editor.** Markdown with live preview.
8. **Driver photos / team logos.** Drivers upload via a self-service profile portal (new scope — see §4 and Phase 4b below). Team logos uploaded by team_manager role.
9. **Hall of Fame.** Auto-generated only. No curator's-picks section.
10. **Discord integration.** Deferred (post-MVP).
11. **Hidden-mode protection.** No HTTP basic-auth gate — trust `noindex` + `Disallow` in `robots.txt` + obscure URL. Saves us the edge-function complexity but means anyone who knows the URL can read.
12. **Domain.** Stay on `sparkstheory.co.uk/endurance/`.
13. **Supabase project.** New project (clean isolation from the main site's Supabase).
14. **Historical data.** None — 2027 starts fresh.
15. **Design reference.** Blend of FIA WEC + F1 stats sites: dark theme, dense data tables, professional motorsport feel.

### Implications of decision #8 (driver self-serve portal)

Adding driver self-upload means:
- New **`driver`** role (in addition to admin/steward/editor/team_manager).
- A driver portal lives at `/endurance/profile/` (or similar). It requires login.
- Drivers can log in and edit their own bio, photo, social handles. Cannot edit race results / standings.
- Admins still **create** the driver record; the driver claims/links it via their auth account (one-time `claim-code` or admin invite link).
- Phase 4 splits into 4a (admin CRUD) and 4b (driver portal + claim flow). Adds ~6 hours.

### Implications of decision #4 (strict manufacturer lock)

- New table `team_seasons` (team_id + season_id → manufacturer_id, locked at season registration).
- A Postgres trigger on `entries` insert/update verifies `entries.manufacturer_id` matches the team's `team_seasons.manufacturer_id` for that season. Hard error if it doesn't.
- Admin UI dropdown for entry's manufacturer is pre-filled and disabled once the season is locked.
- Mid-season manufacturer change for a team = explicit admin override (with audit log entry).

---

## 15. Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Supabase free-tier row read limits hit at scale | Med | Med | Heavy use of materialized views (one read serves many viewers via CDN). Monitor + upgrade tier when needed. |
| Result edits cascade-recalculate cause performance hits | Med | Low | Recompute happens server-side asynchronously; UI shows "recalculating…" badge. Triggered via Netlify Function so the admin UI doesn't block. |
| Admins enter inconsistent data (typos, wrong positions) | High | High | Form validation + DB constraints + diff history. Confirm-modals on destructive ops. |
| Photos / logos balloon Supabase Storage cost | Med | Med | Server-side image transformation (Supabase Image API) at multiple sizes; cap upload sizes; long CDN cache. |
| Driver Elo can be gamed by sandbagging | Med | Med | K-factor scales down with experience; rating clamped at 800/3000. |
| Mid-season driver swaps complicate stats | Med | Med | `entry_drivers` + `result_drivers` model both starting lineup and actual drivers, so points + Elo can be attributed precisely. |
| Markdown content injects script tags | Low | High | Server-side sanitisation (DOMPurify or rehype-sanitize) at render time. Never `innerHTML` untrusted content directly. |
| Steward decisions are written then need redacting | Low | Med | Soft-delete on `steward_decisions` with an `is_redacted` flag rather than hard delete; redacted version replaces content. |
| Solo dev hit by bus | Low | High | All code in this Git repo. Plan doc + schema doc + README mean someone else can pick up. |

---

## 16. Definition of done (per phase)

A phase is "done" when:

1. All code is in the repo on a feature branch and reviewed.
2. The deliverable is reachable behind the hidden gate.
3. Manual smoke test of the new functionality passes.
4. Any new tables/columns are in the schema migration file.
5. Any new env vars are documented in the README.
6. Open Questions list updated with anything new that came up.
7. You've signed off.

---

## 17. Definition of LAUNCH-ready

Before the robots disallow comes off and the nav entry appears:

- All MVP phases (1–13) complete and signed-off
- One full demo season seeded
- Standings + Elo recalculate correctly under all admin actions
- Login flow works for at least one admin and one steward
- All public pages render correctly on a 360px-wide screen
- No console errors on any public page
- Lighthouse mobile score ≥ 80 for accessibility, performance,
  SEO, and best-practices
- robots.txt updated; sitemap.xml entry added
- Backup of the Supabase database taken
- README written so a stranger could spin up a copy

---

## 18. Glossary

- **GTEC** — GT Endurance Championship
- **Gr.3** — Gran Turismo's GT3-equivalent racing class
- **Elo** — chess-derived rating system that adjusts after each contest
- **Entry** — one car at one event (a team + drivers + manufacturer + #)
- **Result** — that entry's finishing record after the race
- **DNF** — Did Not Finish
- **DSQ** — Disqualified
- **DNS** — Did Not Start
- **DNQ** — Did Not Qualify
- **K-factor** — Elo's volatility coefficient; bigger K = bigger
  rating swings per race
- **RLS** — Row-Level Security; Postgres feature that filters rows by
  the calling user's claims
- **Materialized view** — a pre-computed query result stored as a
  table, refreshed on demand
- **SPA** — Single-Page Application; client-rendered, no full page loads

---

**End of plan.** Reply with answers to §14 (or "use the defaults") and a
go/no-go on Phase 1 scaffolding and I'll start building.
