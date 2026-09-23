#!/usr/bin/env python3
"""
Commentary: event list -> paced script -> (optional) voiced audio.

Steps:
  1. Pace the events so lines do not tread on each other (keep the most
     interesting moment in any short window; leave silence between them).
  2. Turn the kept events into commentary lines. With an LLM key set the
     words come from the model (varied, natural); without one it falls back
     to templates so you can still see the timing and structure today.
  3. With a TTS key set, render each line to an audio clip. Without one it
     just writes the script + timings so you can eyeball pacing.

Output: out-dir/manifest.json  ->  {meta, lines:[{t, text, audio}]}
plus one audio clip per line when TTS is enabled. On pass 2 you play the
replay and fire each clip at its t (seconds from the green flag).

Keys (all optional; set what you have):
  ANTHROPIC_API_KEY     use Claude for the script
  OPENAI_API_KEY        use OpenAI for the script (if no Anthropic key)
  ELEVENLABS_API_KEY    render voice   (ELEVENLABS_VOICE_ID to pick a voice)

Usage:  python commentary.py events.json --out-dir out [--min-gap 3.5]
"""

import argparse
import json
import os
import random
import urllib.request

MODEL_ANTHROPIC = "claude-sonnet-4-5-20250929"
MODEL_OPENAI = "gpt-4o-mini"


def describe(e):
    """Plain-English description of an event, fed to the model or template."""
    k = e['kind']
    if k == 'start':    return f"Race start. You line up P{e['pos']} of {e.get('numCars', '?')}."
    if k == 'overtake': return f"You overtake for P{e['to']} (up from P{e['from']})."
    if k == 'lost':     return f"You lose a place, dropping to P{e['to']}."
    if k == 'pb':       return f"You set your fastest lap so far: {e.get('lapStr')} (lap {e.get('lap')})."
    if k == 'lap':      return f"You complete lap {e.get('lap')} in {e.get('lapStr')}."
    if k == 'mistake':  return f"A big lock-up / slide: speed dropped about {int(e.get('drop', 0))} km/h."
    if k == 'lastlap':  return "The final lap begins."
    if k == 'topspeed': return f"Your top speed of the race: {int(e.get('speed', 0))} km/h."
    if k == 'finish':   return f"You take the flag P{e['pos']}. Best lap {e.get('bestStr')}."
    return k


def pace(events, min_gap):
    """Keep events spaced by >= min_gap seconds, preferring higher score in
    any collision, but never dropping the start or the finish."""
    kept = []
    for e in events:
        if e['kind'] in ('start', 'finish'):
            kept.append(e)
            continue
        if kept and (e['t'] - kept[-1]['t']) < min_gap:
            if e['score'] > kept[-1]['score'] and kept[-1]['kind'] not in ('start', 'finish'):
                kept[-1] = e
            continue
        kept.append(e)
    kept.sort(key=lambda e: e['t'])
    return kept


# ---- Template words (used when no LLM key is set) --------------------------
_TEMPLATES = {
    'start':   ["Lights out! You get away from P{pos}.", "Green flag, and you launch from P{pos}."],
    'overtake':["And you're through! That's P{to}.", "Move made, up to P{to} - clean and decisive.",
                "You send it up the inside for P{to}."],
    'lost':    ["Ah, you slip back to P{to} there.", "Lost one - that's P{to} now, heads down."],
    'pb':      ["Fastest lap yet, a {lapStr}. The pace is coming.", "That's a personal best, {lapStr}!"],
    'lap':     ["Lap done, {lapStr}. Steady.", "Another one banked in {lapStr}."],
    'mistake': ["Big lock-up! Held it, but that hurt.", "Whoa - massive slide, somehow you keep it out of the wall."],
    'lastlap': ["Last lap. This is where it counts.", "White flag out - one lap to settle it."],
    'topspeed':["Flat out - {speed} km/h down the straight.", "Absolutely flying, {speed} km/h."],
    'finish':  ["Across the line P{pos}! Best lap of a {bestStr}.", "Chequered flag, P{pos}. Job done."],
}


def template_lines(kept, rng):
    out = []
    for e in kept:
        pool = _TEMPLATES.get(e['kind'])
        if not pool:
            continue
        text = rng.choice(pool).format(
            pos=e.get('pos', ''), to=e.get('to', ''),
            lapStr=e.get('lapStr', ''), speed=int(e.get('speed', 0)) if e.get('speed') else '',
            bestStr=e.get('bestStr', ''))
        out.append({"t": e['t'], "text": text})
    return out


# ---- LLM words ------------------------------------------------------------
def _http_json(url, headers, payload):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers=headers, method='POST')
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def llm_lines(kept, meta):
    beats = [{"t": e['t'], "event": describe(e)} for e in kept]
    system = (
        "You are an energetic but tasteful sim-racing commentator for Gran "
        "Turismo 7. You are commentating ONE driver's race and you address "
        "them as 'you'. You are given a timeline of race events. Write one "
        "short spoken line per event: punchy, natural, varied, never robotic, "
        "at most about 18 words. Do not invent events that are not listed. "
        "Match the energy to the moment (calm on a routine lap, loud on an "
        "overtake or a save). Return ONLY a JSON array of "
        '{"t": number, "text": string}, keeping each t from the input.')
    user = "Events:\n" + json.dumps(beats, indent=2)

    if os.environ.get('ANTHROPIC_API_KEY'):
        data = _http_json(
            "https://api.anthropic.com/v1/messages",
            {"x-api-key": os.environ['ANTHROPIC_API_KEY'],
             "anthropic-version": "2023-06-01", "content-type": "application/json"},
            {"model": MODEL_ANTHROPIC, "max_tokens": 1500, "system": system,
             "messages": [{"role": "user", "content": user}]})
        text = "".join(b.get('text', '') for b in data.get('content', []))
    elif os.environ.get('OPENAI_API_KEY'):
        data = _http_json(
            "https://api.openai.com/v1/chat/completions",
            {"Authorization": "Bearer " + os.environ['OPENAI_API_KEY'],
             "content-type": "application/json"},
            {"model": MODEL_OPENAI, "temperature": 0.8,
             "messages": [{"role": "system", "content": system},
                          {"role": "user", "content": user}]})
        text = data['choices'][0]['message']['content']
    else:
        return None

    text = text.strip()
    if text.startswith('```'):
        text = text.split('```')[1].lstrip('json').strip()
    try:
        return json.loads(text)
    except Exception:
        print("  LLM did not return clean JSON; falling back to templates.")
        return None


# ---- TTS ------------------------------------------------------------------
def tts(lines, out_dir):
    key = os.environ.get('ELEVENLABS_API_KEY')
    if not key:
        return False
    voice = os.environ.get('ELEVENLABS_VOICE_ID', '21m00Tcm4TlvDq8ikWAM')
    for i, ln in enumerate(lines):
        try:
            req = urllib.request.Request(
                f"https://api.elevenlabs.io/v1/text-to-speech/{voice}",
                data=json.dumps({"text": ln['text'], "model_id": "eleven_turbo_v2_5"}).encode(),
                headers={"xi-api-key": key, "content-type": "application/json",
                         "accept": "audio/mpeg"}, method='POST')
            with urllib.request.urlopen(req, timeout=60) as r:
                audio = r.read()
            fn = f"line_{i:03d}.mp3"
            with open(os.path.join(out_dir, fn), 'wb') as fh:
                fh.write(audio)
            ln['audio'] = fn
        except Exception as ex:
            print(f"  TTS failed for line {i}: {ex}")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('events')
    ap.add_argument('--out-dir', default='out')
    ap.add_argument('--min-gap', type=float, default=3.5)
    ap.add_argument('--no-llm', action='store_true')
    ap.add_argument('--no-tts', action='store_true')
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    with open(args.events, encoding='utf-8') as fh:
        data = json.load(fh)

    kept = pace(data['events'], args.min_gap)
    print(f"{len(data['events'])} events -> {len(kept)} lines after pacing (min gap {args.min_gap}s)")

    lines = None
    if not args.no_llm:
        lines = llm_lines(kept, data.get('meta', {}))
        if lines:
            print("  script: LLM")
    if lines is None:
        lines = template_lines(kept, random.Random(7))
        print("  script: templates (set ANTHROPIC_API_KEY or OPENAI_API_KEY for model-written words)")

    lines.sort(key=lambda x: x['t'])

    voiced = False if args.no_tts else tts(lines, args.out_dir)
    print("  voice: " + ("ElevenLabs" if voiced else "none (set ELEVENLABS_API_KEY to render audio)"))

    manifest = {"meta": data.get('meta', {}), "lines": lines}
    with open(os.path.join(args.out_dir, 'manifest.json'), 'w', encoding='utf-8') as fh:
        json.dump(manifest, fh, indent=2)

    print(f"\nWrote {args.out_dir}/manifest.json\n")
    for ln in lines:
        print(f"  {ln['t']:>7.2f}s  {ln['text']}")


if __name__ == '__main__':
    main()
