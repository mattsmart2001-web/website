#!/usr/bin/env python3
"""
Recorder: capture a GT7 replay's telemetry to a JSONL log.

Run this on a machine (or later a phone app) on the same network as the
PS5, start the replay, and it writes one JSON line per packet with a
timestamp anchored to the first in-race packet. That file is the input to
analyser.py.

This is pass 1 of the two-pass workflow: because GT7 replays are
deterministic, the timestamps captured here line up with the same replay
played again later, so the generated commentary drops straight onto it.

Usage:
    python recorder.py --out race.jsonl [--ip 192.168.1.50] [--seconds 0]

    --ip       PS5 address. Omit to broadcast (auto-discovers on most LANs).
    --seconds  Stop after N seconds. 0 (default) records until Ctrl+C.

Requires: pycryptodome  (pip install pycryptodome)
"""

import argparse
import json
import socket
import time

from gt7_packet import GT7Packet, decrypt_packet, HAS_SALSA

GT7_PORT = 33740      # we bind here to receive
SEND_PORT = 33739     # heartbeat goes here
HEARTBEAT_INT = 1.5   # GT7 stops streaming ~1-2s after the last heartbeat


def _heartbeat_target(ip):
    if ip:
        return ip
    # Best-effort subnet broadcast for the interface that reaches the net,
    # which lands on more home networks than 255.255.255.255 alone.
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        parts = s.getsockname()[0].split('.')
        s.close()
        if len(parts) == 4:
            parts[3] = '255'
            return '.'.join(parts)
    except Exception:
        pass
    return '255.255.255.255'


def _send_heartbeat(target):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.sendto(b'A', (target, SEND_PORT))
        s.close()
    except Exception:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True, help='output JSONL path')
    ap.add_argument('--ip', default=None, help='PS5 IP (omit to broadcast)')
    ap.add_argument('--seconds', type=float, default=0, help='auto-stop after N seconds (0 = until Ctrl+C)')
    ap.add_argument('--replay', action='store_true',
                    help='start on the first packet, not the first in-race one (replays may not set the in-race flag)')
    args = ap.parse_args()

    if not HAS_SALSA:
        raise SystemExit("pycryptodome is required: pip install pycryptodome")

    target = _heartbeat_target(args.ip)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', GT7_PORT))
    sock.settimeout(2.0)

    _send_heartbeat(target)
    last_hb = time.time()
    started = None          # wall-clock of the first in-race packet
    count = 0

    print(f"Recording to {args.out}. Start the replay. Ctrl+C to stop.")
    with open(args.out, 'w', encoding='utf-8') as fh:
        try:
            while True:
                now = time.time()
                if now - last_hb >= HEARTBEAT_INT:
                    _send_heartbeat(target)
                    last_hb = now

                try:
                    raw, _ = sock.recvfrom(4096)
                except socket.timeout:
                    _send_heartbeat(target)  # nudge the stream back to life
                    continue

                dec = decrypt_packet(raw)
                if not dec:
                    continue
                pkt = GT7Packet(dec)
                if not pkt.valid:
                    continue

                d = pkt.to_dict()
                # Anchor t=0 to the first in-race packet so pass-2 sync is
                # measured from the green flag, not from when we hit record.
                if started is None:
                    # Replays may not raise the in-race flag, so --replay starts
                    # on the first packet we decode instead of waiting for it.
                    if not args.replay and not d['inRace']:
                        continue
                    started = now
                d['t'] = round(now - started, 3)
                fh.write(json.dumps(d) + '\n')
                count += 1
                if count % 200 == 0:
                    fh.flush()
                    print(f"  {count} packets  (t={d['t']}s, lap {d['lapCount']}, P{d['posInRace']})")

                if args.seconds and started and (now - started) >= args.seconds:
                    break
        except KeyboardInterrupt:
            pass

    print(f"Done. {count} packets written to {args.out}")


if __name__ == '__main__':
    main()
