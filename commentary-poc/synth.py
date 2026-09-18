#!/usr/bin/env python3
"""
Synthetic telemetry generator.

Fakes a believable single-car GT7 replay log so the analyser and commentary
generator can be exercised end to end before a real capture exists. The
scripted race has a bit of everything worth commentating: a couple of
overtakes, a personal best, a lock-up mistake, and a fastest lap on the
final tour.

Usage:  python synth.py --out sample.jsonl
"""

import argparse
import json
import math
import random

HZ = 20                     # packets per second
LAPS = 4
NUM_CARS = 8

# Per-lap script: (lap_time_seconds, [events]). Events are (fraction_of_lap,
# kind, payload) applied as the lap plays out.
LAPS_SCRIPT = [
    (46.0, [(0.00, 'start', 4)]),
    (45.2, [(0.55, 'pass', 3)]),                       # move up to P3, new best
    (47.1, [(0.40, 'lockup', None), (0.62, 'lost', 4), (0.80, 'pass', 3)]),
    (44.8, [(0.85, 'pass', 2)]),                       # fastest lap + last-lap pass to P2
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    rng = random.Random(7)
    rows = []
    t = 0.0
    pid = 0
    best_ms = -1
    last_ms = -1
    pos = 4

    for lap_idx, (lap_time, events) in enumerate(LAPS_SCRIPT):
        lap_no = lap_idx + 1
        ticks = int(lap_time * HZ)
        # Map events to the tick they fire on.
        ev_by_tick = {int(frac * ticks): (kind, payload) for frac, kind, payload in events}

        for k in range(ticks):
            frac = k / ticks
            # Base speed profile: a rolling straight/corner pattern so braking
            # zones and corner apexes look plausible.
            wave = math.sin(frac * math.pi * 6)
            speed = 210 + 70 * wave + rng.uniform(-3, 3)
            brake = max(0.0, -wave) * 90
            throttle = max(0.0, wave) * 100
            lat_g = 2.4 * math.cos(frac * math.pi * 6) + rng.uniform(-0.1, 0.1)
            long_g = -1.5 * max(0.0, -wave) + 1.0 * max(0.0, wave)
            gear = max(1, min(7, int(2 + 5 * (speed / 280))))

            ev = ev_by_tick.get(k)
            if ev:
                kind, payload = ev
                if kind in ('start', 'pass', 'lost'):
                    pos = payload
                elif kind == 'lockup':
                    # A hard lock-up: speed collapses, full brake, big slide.
                    speed = 70 + rng.uniform(-5, 5)
                    brake = 100
                    lat_g = 3.6
                    long_g = -3.2

            rows.append({
                't': round(t, 3),
                'packetId': pid,
                'speed': round(max(0.0, speed), 1),
                'gear': gear,
                'throttle': round(throttle, 1),
                'brake': round(brake, 1),
                'latG': round(lat_g, 3),
                'longG': round(long_g, 3),
                'lapCount': lap_no,
                'lapsInRace': LAPS,
                'bestLap': best_ms,
                'lastLap': last_ms,
                'posInRace': pos,
                'numCars': NUM_CARS,
                'inRace': True,
                'paused': False,
                'fuel': round(60 - lap_idx * 12 - frac * 12, 2),
                'fuelCap': 100.0,
                'vehicleId': 1,
                'posX': round(200 * math.cos(frac * 2 * math.pi), 2),
                'posY': 0.0,
                'posZ': round(200 * math.sin(frac * 2 * math.pi), 2),
            })
            t += 1.0 / HZ
            pid += 1

        # Lap just completed: record its time and update the personal best.
        last_ms = int(lap_time * 1000)
        best_ms = last_ms if best_ms < 0 else min(best_ms, last_ms)

    # A couple of post-race packets so the analyser sees the race end.
    for _ in range(HZ):
        rows.append({**rows[-1], 't': round(t, 3), 'packetId': pid,
                     'inRace': False, 'speed': 40.0, 'brake': 100.0})
        t += 1.0 / HZ
        pid += 1

    with open(args.out, 'w', encoding='utf-8') as fh:
        for r in rows:
            fh.write(json.dumps(r) + '\n')
    print(f"Wrote {len(rows)} synthetic packets to {args.out} "
          f"({LAPS} laps, finishing P{pos}).")


if __name__ == '__main__':
    main()
