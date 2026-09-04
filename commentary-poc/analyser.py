#!/usr/bin/env python3
"""
Analyser: telemetry log -> timed event list.

Reads a JSONL log (from recorder.py or synth.py) and extracts the moments
worth commentating on, each stamped with the time it happened (t seconds
from the green flag) and an "interest" score the commentary step uses for
pacing. Single-car only, by design: everything here is about the followed
driver ("you").

Usage:  python analyser.py race.jsonl --out events.json
"""

import argparse
import json
from collections import deque


def fmt_lap(ms):
    if ms is None or ms < 0:
        return None
    s = ms / 1000.0
    return f"{int(s // 60)}:{s % 60:06.3f}" if s >= 60 else f"{s:.3f}"


def analyse(rows):
    events = []
    prev = None
    best_seen = None
    speed_window = deque()      # (t, speed) over the last ~0.5s
    top_speed = (0.0, 0.0)      # (speed, t)
    last_mistake_t = -99
    lastlap_emitted = False
    started = False
    final = {"pos": None, "bestMs": None, "laps": 0, "numCars": 0}

    for r in rows:
        t = r.get('t', 0.0)
        in_race = r.get('inRace', False)
        speed = r.get('speed', 0.0)
        pos = r.get('posInRace', 0)
        lap = r.get('lapCount', 0)
        laps_in = r.get('lapsInRace', 0)
        final['numCars'] = r.get('numCars', final['numCars'])
        final['laps'] = max(final['laps'], laps_in)

        if in_race and speed > top_speed[0]:
            top_speed = (speed, t)

        # Green flag.
        if in_race and not started:
            started = True
            if pos:
                events.append({"t": t, "kind": "start", "pos": pos,
                               "numCars": r.get('numCars', 0), "score": 6})

        if prev is not None:
            # Lap completed: lapCount ticked up. lastLap now holds its time.
            if lap > prev['lapCount'] and prev['lapCount'] > 0:
                ms = r.get('lastLap', -1)
                done_lap = prev['lapCount']
                is_best = ms and ms > 0 and (best_seen is None or ms < best_seen)
                if is_best:
                    best_seen = ms
                events.append({
                    "t": t, "kind": "pb" if is_best else "lap",
                    "lap": done_lap, "timeMs": ms, "lapStr": fmt_lap(ms),
                    "score": 8 if is_best else 3,
                })

            # Position change (the driver's own overtake or place lost).
            if in_race and pos and prev['posInRace'] and pos != prev['posInRace'] \
                    and 1 <= pos <= max(1, final['numCars']):
                if pos < prev['posInRace']:
                    events.append({"t": t, "kind": "overtake", "to": pos,
                                   "from": prev['posInRace'], "score": 7})
                else:
                    events.append({"t": t, "kind": "lost", "to": pos,
                                   "from": prev['posInRace'], "score": 5})

            # Last lap begins.
            if in_race and laps_in and lap == laps_in and not lastlap_emitted:
                lastlap_emitted = True
                events.append({"t": t, "kind": "lastlap", "score": 7})

            # Finish: dropped out of the race after being in it.
            if prev['inRace'] and not in_race:
                final['pos'] = prev['posInRace']
                final['bestMs'] = best_seen
                events.append({"t": t, "kind": "finish", "pos": prev['posInRace'],
                               "bestMs": best_seen, "bestStr": fmt_lap(best_seen),
                               "score": 10})

        # Mistake: a hard, sudden speed loss under braking (lock-up / spin /
        # off), with a cooldown so one moment fires once.
        speed_window.append((t, speed))
        while speed_window and t - speed_window[0][0] > 0.5:
            speed_window.popleft()
        if in_race and speed_window:
            earlier = speed_window[0][1]
            drop = earlier - speed
            big_slide = abs(r.get('latG', 0)) > 3.2
            if (drop > 45 and r.get('brake', 0) > 70 or big_slide) \
                    and speed < earlier and (t - last_mistake_t) > 2.5 and earlier > 120:
                last_mistake_t = t
                events.append({"t": t, "kind": "mistake",
                               "drop": round(drop, 0), "score": 6})

        prev = r

    if top_speed[0] > 0:
        events.append({"t": round(top_speed[1], 3), "kind": "topspeed",
                       "speed": round(top_speed[0], 0), "score": 4})

    events.sort(key=lambda e: e['t'])
    return {"meta": final, "events": events}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--out', default='events.json')
    args = ap.parse_args()

    with open(args.log, encoding='utf-8') as fh:
        rows = [json.loads(line) for line in fh if line.strip()]

    result = analyse(rows)
    with open(args.out, 'w', encoding='utf-8') as fh:
        json.dump(result, fh, indent=2)

    ev = result['events']
    print(f"{len(rows)} packets -> {len(ev)} events. Wrote {args.out}")
    for e in ev:
        print(f"  t={e['t']:>7.2f}s  [{e['score']:>2}] {e['kind']}"
              + (f" -> P{e.get('to')}" if e.get('to') else "")
              + (f" P{e.get('pos')}" if e.get('pos') else "")
              + (f" {e.get('lapStr')}" if e.get('lapStr') else "")
              + (f" {e.get('speed')}kmh" if e.get('speed') else ""))


if __name__ == '__main__':
    main()
