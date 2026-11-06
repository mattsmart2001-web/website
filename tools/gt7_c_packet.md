# GT7's 'C' telemetry packet

What is in the 368-byte packet GT7 sends when the heartbeat byte is `C`,
as far as we have established it. Written up because it took four
captures to get and the findings would otherwise live nowhere.

Everything here came from GT7 itself, through `gt7_probe.py`, on a real
console. Nothing is copied from a community map, and the negative results
are recorded as carefully as the positive ones so nobody repeats the work.

Captured November 2026, game build current at that date.

## How to read the packet at all

GT7 encrypts every telemetry packet with Salsa20 under the key

    'Simulator Interface Packet GT7 ver 0.0'[:32]

and writes the nonce seed into the ciphertext in the clear, after
encrypting, which is the only reason a listener can derive it. That much
is public and is what the connector already does for the `A` packet.

The part that is not public: **the nonce XOR mask differs per packet
type.** The `A` packet uses `0xDEADBEAF`. The `C` packet uses
`0xDEADBEEF`. One letter apart, and it is the whole difference between
3,597 packets that decode and 3,597 that look like noise.

The magic check also needs relaxing. `A` decodes to magic `G7S0`, read
little-endian from `0x47375330`, so the plaintext bytes read `0S7G`. `C`
is in the same family but demanding an exact match on all four
characters rejects valid packets. Match the `G7S` family and accept the
fourth character.

Sizes by letter, as the probe sees them:

| Letter | Size | State |
|---|---|---|
| `A` | 296 (0x128) | what the connector uses, fully mapped publicly |
| `B` | 316 | not captured here |
| `~` | 344 | not captured here; reported to add per-tyre surface |
| `C` | 368 | 72 bytes past `A`, mapped below |

## What is in the extra 72 bytes

Offsets are absolute, from the start of the decoded packet. Everything
below `0x128` is the ordinary `A` packet and already documented.

### 0x158 · per-wheel surface type

Four ASCII bytes, one per wheel, front-left first.

| Byte | Meaning |
|---|---|
| `T` (84) | tarmac |
| `C` (67) | concrete, which is what a kerb reads as |
| `G` (71) | grass |

Confirmed in all four captures. In a five-minute stint: 557 samples of
`TTTT`, then `CTCT` and `TCTC` where two wheels on one side took a kerb,
and a single sample of `CCCC` with all four wheels on something hard.
The patterns match where the car actually was, which is the test that
matters.

This is presumably the same field the `~` packet is reported to carry.

### 0x15C · current lap time, milliseconds

Little-endian uint32. Climbs at 999 per second, which is a 1000 Hz
counter sampled against a slightly slow wall clock, not a bug.

Reads zero until the car completes its first lap, then counts the lap in
progress. Confirmed across four captures: 0 to 33,267 and 0 to 35,000 on
two one-minute runs, 0 to 275,217 on a five-minute one, each starting the
moment the lap counter ticked from 0 to 1.

### 0x16B · car category, null-terminated ASCII

Five bytes. A Gr.3 car reads `40 47 52 33 00`, which is `@GR3`. A Gr.4
car reads `40 47 52 34 00`, `@GR4`. Confirmed by running the same probe
in two cars of different classes and diffing one line.

This is GT7 reporting the car's class directly, which is worth noting for
a single-class series: every legitimate GTEC car reports `@GR3`, so
anything else is a car in the wrong class, detectable with one string
comparison and no table of allowed classes.

### Fields seen but not identified

These move but we have not pinned them down. Recorded so the next person
starts ahead of where we did.

| Offset | Shape | Observed |
|---|---|---|
| 0x128 | float | roughly -2.5 to +2.9, no correlation with speed |
| 0x12C, 0x130, 0x134, 0x138 | floats | roughly -27 to +29, no correlation with speed |
| 0x154 | float | 0 to about 1.4, weak positive correlation with speed (r about +0.43) |
| 0x160, 0x164 | floats | small, within about ±0.23 |
| 0x168 | float | steady per car: 2.49 in one Gr.3 car, 2.67 in a Gr.4. Varies by under 0.03 within a run and does not track speed, so it is a car property rather than a live reading |

### 0x140 to 0x153 · twenty-two bytes of nothing

Flat zero in every capture, including a five-minute stint with fuel
consumption demonstrably on. Five floats' worth. Four of them sitting
together looked exactly like a per-wheel field, which is why it was
chased. It is not.

## What is NOT in this packet

Both of these were the reason the probe was written, so the negative
results are the headline finding, not a footnote.

### Tyre compound · tested directly, absent

Two one-minute captures, same car, same track, one on Racing Hard and one
on Racing Soft. Of the 72 unmapped bytes, 29 hold still through both
runs, and **every one of those 29 is identical between the two
compounds.** The only two bytes that differ at all are explained: 0x15B
is surface type picking up a kerb strike, and 0x16A is the top byte of
the wobbling float at 0x168.

All nine changing floats were also checked for a systematic shift between
the runs. Ranges, means and speed correlations match to three decimals.

GT7 does not send tyre compound in this packet.

### Tyre wear · tested, absent

One five-minute stint, pushing, fuel burning 5.71% over the capture so
consumption was certainly enabled. The whole 72 bytes was scanned three
ways for anything trending with time: every float, every single byte, and
every 16-bit pair. Exactly one hit, and it is the lap timer at 0x15C.

The one caveat worth stating: fuel consumption being on makes it likely
tyre wear was on in the same lobby settings, but it does not prove it.

GT7 does not appear to send tyre wear in this packet.

### Why that is probably the end of it

`C` at 368 bytes is the largest packet GT7 sends. A smaller packet
carrying a field the largest one omits is unlikely, though `B` and `~`
have not been captured and so this is inference rather than proof. It
does explain why no community project exposes tyre data: it is not there
to expose.

## Reproducing any of this

GT7 streams to one listener at a time, so close the connector first.

    python tools\gt7_probe.py --letter C --seconds 60 --out c-run.csv

On Windows use `python`, not `python3`, which hits the Microsoft Store
stub. The address is optional: the probe broadcasts to find the console
and prints where it answered from. Get in a car and drive, because GT7
sends nothing from the menus.

A control run is worth doing once if nothing decodes:

    python tools\gt7_probe.py --letter A --seconds 20 --out a-control.csv

If `A` works and `C` does not, the game build has no `C` packet and that
is the answer.

To test a hypothesis, take two captures that differ in exactly one thing
and diff the bytes that hold still within each. The probe prints that
`held still` line itself, so a single-field change often shows up without
any analysis at all.

## Captures this rests on

| File | Length | Conditions |
|---|---|---|
| `a-control.csv` | 20s | `A` packet, to prove the probe and the key work |
| `c-gr4.csv` | 20s | Gr.4 car, lap 0 |
| `c-hard.csv` (first) | 60s | Gr.3 car, lap 1 |
| `c-hard.csv` / `c-soft.csv` | 60s each | same Gr.3 car, Racing Hard then Racing Soft |
| `c-wear.csv` | 300s | Gr.3 car, fuel consumption on, pushing |
