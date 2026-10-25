# Cross-split live timing — Phase 1 (hosts only)

Phase 1 puts every split's **host** on a live map during a race, so the
whole championship can be watched running at once. It is deliberately the
smallest version that proves the idea, on a stream, without asking
anything of the grid.

## What it delivers

- A public page at `/endurance/live/` showing one card per split: the
  host's lap, last lap, best lap, and whether they are on track.
- A single track map with a dot per split, moving in real time.
- Nothing to install for anyone but the eight hosts.

## What it explicitly does not do

Worth being clear, because the obvious assumption is wrong: with one
reporter per split there are **no gaps between cars**. A timing tower
needs most of a lobby reporting, which is phase 2. Phase 1 shows how far
through the race each split is and where its host is on track. That is
already unprecedented for a GT7 league, but it is not a timing screen.

Also out of scope: iOS, replay and history, any non-host driver.

---

## Why the client has to be native

The existing `ANDROID_APP.md` plan is a Trusted Web Activity, a browser
shell around the PWA. A browser cannot open a raw UDP socket, so the TWA
cannot do this. Phase 1 needs a small native Android service.

It is genuinely small. On the same WiFi as the console it must:

1. Send the heartbeat so GT7 starts streaming.
2. Decrypt the packet (Salsa20 — port the logic from the existing
   connector rather than rewriting it).
3. Pull six or seven fields.
4. POST them every two seconds.

No UI beyond "paired / reporting / lost signal" and a foreground-service
notification. The phone stays in a pocket.

### The reframe this rests on

One machine cannot see sixteen cars. It does not need to. Each device
reports **only its own car**, and the server assembles the field from
single-car feeds. GT7's per-console limitation stops mattering the
moment every device is a reporter rather than an observer. Phase 1 has
eight reporters; phase 2 has as many as opt in; the server code is the
same either way.

---

## Architecture

```
PS5 ──UDP──▶ host's phone (native service) ──HTTPS──▶ live_beacon() RPC
                                                            │
                                                            ▼
                                                     live_positions
                                                            │
                                     /endurance/live/ ◀──polls──┘
```

Four parts, no Netlify function in the path. The reporter calls a
Supabase RPC directly, which keeps invocation cost and latency out of it.

---

## Pairing and auth

The app must never hold a driver's credentials. Instead:

1. Host opens their portal on race day and taps **Start live timing**.
2. The portal calls `live_timing_token_issue(p_event_id)`, which returns
   a short token tied to `driver_id` + `event_id`, expiring at
   `starts_at + duration_hours + 2 hours`.
3. The portal shows it as a QR code and a six-character fallback.
4. The app stores the token and sends it with every beacon.

The token is the only secret the app holds, it is useless after the
race, and revoking it is deleting one row. A host who reinstalls mid-race
pairs again and keeps reporting; the server keys on
(`event_id`, `driver_id`), not on the token, so a new token continues
the same car rather than creating a second dot.

---

## Wire format

One POST every two seconds to `live_beacon`:

```json
{
  "token":       "a1b2c3d4e5f6…",
  "lap":         37,
  "lap_ms":      48210,
  "last_lap_ms": 112480,
  "best_lap_ms": 111930,
  "x":           412.8,
  "z":          -1183.4,
  "speed_kph":   214,
  "on_track":    true
}
```

- `x` / `z` are the ground plane. GT7's `y` is elevation, so the 2D map
  ignores it. (Confirm against the connector's parser before building —
  `lap-coach.js` carries `y` through with a `|| 0` fallback, which
  suggests it is not always populated.)
- `on_track` covers menus, pauses and the pre-race lobby, so the map can
  grey a car out rather than freezing it mid-corner.
- Everything is derived from one packet, so a beacon is a snapshot, never
  an aggregate. No state in the app.

The RPC ignores any beacon arriving less than 1.5 seconds after the last
one for that car, so a buggy or malicious client cannot flood the table.

---

## Storage

One row per car per event, upserted. No history in phase 1.

```sql
CREATE TABLE live_positions (
    event_id    uuid REFERENCES events(id) ON DELETE CASCADE,
    driver_id   uuid REFERENCES drivers(id) ON DELETE CASCADE,
    lobby_number int,
    lap          int,
    lap_ms       int,
    last_lap_ms  int,
    best_lap_ms  int,
    x            real,
    z            real,
    speed_kph    int,
    on_track     boolean NOT NULL DEFAULT true,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, driver_id)
);
```

`lobby_number` is copied from the driver's entry when the token is
issued, so the live page never has to join back to `entries` mid-race.

RLS: public read, no public write. Writes happen only through
`live_beacon`, which is `SECURITY DEFINER` and validates the token. The
table is therefore append-free, bounded at one row per reporter, and
costs nothing to read.

Rows are cleared when the event completes.

---

## Liveness: dropping in and out

This is the part that decides whether the map looks alive or broken. A
dot that vanishes reads as a bug; a dot frozen in a corner reads as a
crash that never happened.

The page derives state from `updated_at` alone:

| Age of last beacon | State | What the page shows |
|---|---|---|
| under 6s | **live** | Dot moves normally |
| 6s to 30s | **drifting** | Dot holds last position, dimmed, no "offline" wording yet |
| 30s to 5min | **signal lost** | Dot ghosted at last position, card keeps lap and last lap, label "signal lost" |
| over 5min | **offline** | Dot removed, card keeps the last known lap and reads "offline" |

Three rules behind that:

- **Never contradict the race.** If a host is on lap 37 and the phone
  dies, the card still says lap 37. Losing the reporter is not the same
  as losing the car, and the page must not imply otherwise.
- **Be slow to alarm.** A two-second cadence over hotel WiFi will skip
  beacons constantly. Six seconds of silence is normal; thirty is worth
  showing.
- **Be quick to recover.** One good beacon returns a car straight to
  live, with no smoothing or hysteresis, so a host who walks into
  better signal is instantly correct again.

`on_track = false` is handled separately from staleness: the car is
greyed and labelled "in menus", because that is a known state rather
than a lost one.

---

## The map

GT7 world coordinates are metres and consistent per track, so each
circuit needs one affine transform (scale, rotate, translate) onto its
SVG outline. Derive it once per track from a recorded lap — the Lap
Coach already captures exactly the sample stream needed — and store it
beside the existing shapes that `netlify/functions/track-shape.js` and
`track-shapes-review.js` handle.

Calibration is a one-off per circuit and does not block the build: until
a track has a transform, that round falls back to the cards without the
map.

Dots are coloured by split, with the split number inside. At eight dots
there is no label collision problem worth solving yet.

---

## The public page

`/endurance/live/`, polling `live_positions` every two seconds. Polling
rather than Supabase Realtime for phase 1: the table is a handful of
rows, polling has no connection ceiling, and a dropped poll is invisible
whereas a dropped socket needs reconnection logic. Realtime is a
worthwhile upgrade once the field is larger.

The page must open in a sensible state outside a race: when no event is
live it shows the next round and when it starts, not an empty map.

---

## Failure modes to design for

| Failure | Handling |
|---|---|
| Phone sleeps | Foreground service with a persistent notification; this is the main reason it cannot be a TWA |
| Phone dies mid-race (12h) | Document that the host should keep it on charge; the card degrades per the liveness table |
| WiFi drops | Beacons simply stop; no queueing, since stale positions are worse than none |
| Host rejoins the lobby | Lap counter may reset; take the **max** of reported and stored lap rather than overwriting |
| Host is not actually the one racing | Token is tied to `driver_id`, so the dot is labelled by driver, not by "the host" |
| Two devices reporting one driver | Upsert on (event, driver) means last write wins, which is correct |

---

## Volume and cost

Eight reporters at one beacon per two seconds over a twelve-hour race is
about 173,000 RPC calls, averaging under 4 per second. That is
comfortable for Supabase and the table never grows beyond eight rows.
Readers are the larger number, and polling a tiny public table is the
cheapest thing on the site.

---

## Verify before building

1. **Does a PS5 stream to two devices at once?** The port conflict in
   `ADVANCED_UDP.txt` is a single-PC problem, and separate IPs each
   sending a heartbeat should each receive, but this is unconfirmed. It
   matters because a host running SimHub on a PC must not be knocked out
   by the phone.
2. **Is the lap counter in the packet, or inferred?** `lap-coach.js`
   reconstructs laps from samples in places, which may mean the counter
   is derived rather than read. If derived, the app needs that logic too.
3. **Android foreground service over twelve hours** — battery, doze, and
   what the OS does to a socket held that long.
4. **Whether `y` is populated**, which decides if elevation is available
   for a later 3D or gradient view.

---

## Phase 2, for context only

Open the same reporter to any driver who wants to appear. The server
code does not change. At that point gaps, a real timing tower, and
position-on-track for a whole lobby all become possible, and visibility
becomes the incentive to install rather than something to chase.
