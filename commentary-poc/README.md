# AI Race Commentary - Proof of Concept

Turns a Gran Turismo 7 replay into spoken commentary of **your** drive.

This is a standalone prototype living alongside the SparksTheory site but
wired to nothing on it. It exists to answer one question cheaply: **does the
commentary feel amazing?** If it does, it is worth building into a product
(a worldwide creator / enthusiast tool). If it feels flat, we learned that
in an afternoon.

## The core constraint (read this first)

GT7's telemetry stream describes **one car at a time** - the car currently
on screen / being followed - not the whole field. So this does not do
F1-style "battle for P8 back in the pack" commentary; it commentates the
followed driver as the star: their overtakes, pace, mistakes, and the flag.
That is deliberate, and it is the version that actually works for anyone
using GT7, off the exact stream every player already has.

## The two-pass idea

GT7 replays are deterministic (same replay plays identically every time), so:

1. **Pass 1 - capture.** Play the replay once; `recorder.py` saves the
   telemetry to a file, timestamped from the green flag.
2. **Generate.** `analyser.py` finds the moments; `commentary.py` writes and
   voices the lines, each stamped with the time it happened.
3. **Pass 2 - watch.** Play the replay again and fire each audio clip at its
   timestamp. It lines up because the replay is identical.

## Try it now (no console, no keys needed)

```bash
pip install -r requirements.txt          # only needed for the real recorder
python synth.py --out sample.jsonl       # fake but realistic race log
python analyser.py sample.jsonl --out events.json
python commentary.py events.json --out-dir out
```

That prints the paced script with timings using **template** words, so you
can judge the pacing and structure immediately.

## The real test (the part that answers "is it amazing?")

Add keys and the words come from a model and the voice from real TTS:

```bash
export ANTHROPIC_API_KEY=...             # or OPENAI_API_KEY
export ELEVENLABS_API_KEY=...            # optional voice
export ELEVENLABS_VOICE_ID=...           # pick an energetic voice
python commentary.py events.json --out-dir out
```

`out/manifest.json` holds `{t, text, audio}` per line. Lay those clips over
the replay video at their `t` (any video editor, or a small player) and
listen. That clip is the whole pitch in 90 seconds.

For a genuine end-to-end run, capture a real replay first:

```bash
python recorder.py --out race.jsonl      # start the replay, Ctrl+C to stop
python analyser.py race.jsonl --out events.json
python commentary.py events.json --out-dir out
```

## Files

| File | Job |
|------|-----|
| `gt7_packet.py` | Decrypt + parse one GT7 packet (from the trusted connector) |
| `recorder.py`   | Capture a replay's telemetry to JSONL (pass 1) |
| `synth.py`      | Generate a fake race log so the pipeline runs with no capture |
| `analyser.py`   | Log -> timed event list (overtakes, PB, mistakes, finish...) |
| `commentary.py` | Events -> paced script -> optional voiced audio + manifest |

## Known unknowns to validate on a real capture

- **Race-position offset.** `gt7_packet.py` reads position at `0x84`; the
  single-car fields are verbatim from the working connector, but confirm the
  position field against a real replay before trusting overtake detection.
- **Replay telemetry.** Confirmed it streams during replay; confirm it is
  byte-identical across two plays (it should be) so pass-2 sync is exact.

## Roadmap if the proof lands

- Sync player (fire clips over the replay automatically, no manual editing).
- Better event detection (sector pace, tyre/fuel in enduros, corner naming).
- Voice/persona options; per-line loudness matched to moment intensity.
- Phone app as the capture device (no PC needed) - the key to "for everyone".
- Optional heavy "full-field" mode via one replay pass per car (leagues).
- Cost model: LLM + TTS per race is the real COGS; price above it.
