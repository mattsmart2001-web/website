#!/usr/bin/env python3
"""
GT7 Live Connector
==================
Background system-tray app that bridges Gran Turismo 7 UDP telemetry
to a local WebSocket server at ws://localhost:8765.

Run this, then open the SparksTheory GT7 Telemetry page in your browser.
Right-click the tray icon to quit.
"""

import asyncio
import json
import os
import socket
import struct
import sys
import time
import threading
import logging
from typing import Optional

# ── Silence logging to not flash a console window ──
logging.disable(logging.CRITICAL)

# ── Crypto ──
try:
    from Crypto.Cipher import Salsa20 as _S20
    HAS_SALSA = True
except ImportError:
    HAS_SALSA = False

try:
    import websockets
except ImportError:
    sys.exit(1)

# ── Tray ──
try:
    import pystray
    from PIL import Image, ImageDraw, ImageFont
    HAS_TRAY = True
except ImportError:
    HAS_TRAY = False

# ═══════════════════════════════════════════════════════════════
#  CONFIG
# ═══════════════════════════════════════════════════════════════
VERSION       = "2.2"   # shown in the tray so you can confirm which build is running
GT7_PORT      = 33740
SEND_PORT     = 33739
WS_PORT       = 8765
WS_HOST       = "0.0.0.0"
HEARTBEAT_INT = 1.5    # GT7 stops streaming ~1-2s after the last heartbeat, so re-ping often
HEARTBEAT_EVERY = 100  # also re-ping every N received packets to keep the stream alive

# ═══════════════════════════════════════════════════════════════
#  DECRYPTION
# ═══════════════════════════════════════════════════════════════
# GT7 telemetry is Salsa20-encrypted. The key is the ASCII marker string
# (first 32 bytes). The 8-byte nonce is built from a 32-bit seed stored at
# offset 0x40: nonce = (seed ^ 0xDEADBEAF) little-endian, then seed
# little-endian. Decrypted packets begin with the magic b'G7S0'.
_KEY = b'Simulator Interface Packet GT7 ver 0.0'[:32]

def decrypt_packet(data: bytes) -> Optional[bytes]:
    if len(data) < 0x128:
        return None
    seed = int.from_bytes(data[0x40:0x44], 'little')
    nonce = (seed ^ 0xDEADBEAF).to_bytes(4, 'little') + seed.to_bytes(4, 'little')
    if HAS_SALSA:
        try:
            dec = _S20.new(key=_KEY, nonce=nonce).decrypt(data)
            # Magic 'G7S0' is stored little-endian, so the decoded bytes are
            # 30 53 37 47 -> int 0x47375330. (Comparing to b'G7S0' directly
            # checks the reverse byte order and wrongly rejects valid packets.)
            if int.from_bytes(dec[0:4], 'little') == 0x47375330:
                return dec
        except Exception:
            pass
    return None  # decryption failed — drop packet rather than send garbage

# ═══════════════════════════════════════════════════════════════
#  PACKET PARSER
# ═══════════════════════════════════════════════════════════════
class GT7Packet:
    def __init__(self, raw: bytes):
        self.valid = False
        if len(raw) < 0x128:
            return
        try:
            self._r = raw
            self._parse()
            self.valid = True
        except Exception:
            pass

    def _f(self, o): return struct.unpack_from('<f', self._r, o)[0]
    def _i(self, o): return struct.unpack_from('<i', self._r, o)[0]
    def _h(self, o): return struct.unpack_from('<h', self._r, o)[0]
    def _H(self, o): return struct.unpack_from('<H', self._r, o)[0]
    def _B(self, o): return struct.unpack_from('<B', self._r, o)[0]

    def _parse(self):
        self.packet_id   = self._i(0x70)
        self.speed_ms    = self._f(0x4C)
        self.speed_kmh   = self.speed_ms * 3.6
        self.rpm         = self._f(0x38)
        self.fuel        = self._f(0x44)
        self.fuel_cap    = self._f(0x48)
        self.boost       = self._f(0x50)
        self.oil_press   = self._f(0x54)
        self.water_temp  = self._f(0x58)
        self.oil_temp    = self._f(0x5C)
        self.tfl_temp    = self._f(0x60)
        self.tfr_temp    = self._f(0x64)
        self.trl_temp    = self._f(0x68)
        self.trr_temp    = self._f(0x6C)
        self.lap_count   = self._h(0x74)
        self.laps_in_race= self._h(0x76)
        self.best_lap    = self._i(0x78)
        self.last_lap    = self._i(0x7C)
        flags            = self._H(0x8E)
        self.in_race     = bool(flags & 0x0001)
        self.paused      = bool(flags & 0x0002)
        gear_raw         = self._B(0x90)
        self.gear        = gear_raw & 0x0F
        self.throttle    = self._B(0x91) / 255.0
        self.brake       = self._B(0x92) / 255.0
        self.tfl_rps     = self._f(0xA4)
        self.tfr_rps     = self._f(0xA8)
        self.trl_rps     = self._f(0xAC)
        self.trr_rps     = self._f(0xB0)
        self.tfl_sus     = self._f(0xC4)
        self.tfr_sus     = self._f(0xC8)
        self.trl_sus     = self._f(0xCC)
        self.trr_sus     = self._f(0xD0)
        self.max_alert   = self._h(0x8A)
        self.angvel_y    = self._f(0x2C)
        self.vel_x       = self._f(0x10)
        self.vel_z       = self._f(0x18)
        self.angvel_x    = self._f(0x28)
        self.angvel_z    = self._f(0x30)
        self.rot_yaw     = self._f(0x20)
        self.pos_x       = self._f(0x04)
        self.pos_y       = self._f(0x08)
        self.pos_z       = self._f(0x0C)
        self.vehicle_id  = self._i(0xF4)
        speed = max(self.speed_ms, 0.1)
        self.lat_g   = self.angvel_y * speed / 9.81
        self.long_g  = (self.vel_x * self.angvel_z - self.vel_z * self.angvel_x) / 9.81
        steer_raw = self.lat_g / 2.0
        self.steer_est = max(-1.0, min(1.0, steer_raw))

    def to_dict(self):
        return {
            "type":       "telemetry",
            "packetId":   self.packet_id,
            "speed":      round(self.speed_kmh, 1),
            "rpm":        round(self.rpm, 0),
            "rpmMax":     int(self.max_alert) if self.max_alert > 1000 else 9000,
            "gear":       self.gear,
            "throttle":   round(self.throttle * 100, 1),
            "brake":      round(self.brake * 100, 1),
            "steer":      round(self.steer_est * 100, 1),
            "latG":       round(self.lat_g, 3),
            "longG":      round(self.long_g, 3),
            "lapCount":   self.lap_count,
            "lapsInRace": self.laps_in_race,
            "bestLap":    self.best_lap,
            "lastLap":    self.last_lap,
            "inRace":     self.in_race,
            "paused":     self.paused,
            "tyreTempFL": round(self.tfl_temp, 1),
            "tyreTempFR": round(self.tfr_temp, 1),
            "tyreTempRL": round(self.trl_temp, 1),
            "tyreTempRR": round(self.trr_temp, 1),
            "tyreSusFL":  round(self.tfl_sus, 4),
            "tyreSusFR":  round(self.tfr_sus, 4),
            "tyreSusRL":  round(self.trl_sus, 4),
            "tyreSusRR":  round(self.trr_sus, 4),
            "tyreRpsFL":  round(self.tfl_rps, 2),
            "tyreRpsFR":  round(self.tfr_rps, 2),
            "tyreRpsRL":  round(self.trl_rps, 2),
            "tyreRpsRR":  round(self.trr_rps, 2),
            "fuel":       round(self.fuel, 2),
            "fuelCap":    round(self.fuel_cap, 2),
            "boost":      round(self.boost, 3),
            "oilPress":   round(self.oil_press, 2),
            "waterTemp":  round(self.water_temp, 1),
            "oilTemp":    round(self.oil_temp, 1),
            "vehicleId":  self.vehicle_id,
            "posX":       round(self.pos_x, 2),
            "posY":       round(self.pos_y, 2),
            "posZ":       round(self.pos_z, 2),
            "rotYaw":     round(self.rot_yaw, 4),
        }


# ═══════════════════════════════════════════════════════════════
#  WEBSOCKET SERVER
# ═══════════════════════════════════════════════════════════════
_clients = set()
# Live status so the web page (and tray tooltip) can tell whether the console
# is actually sending telemetry, not just whether the bridge is up.
_stats = {"packets": 0, "raw": 0, "ps5": None, "last": 0.0, "debug": None}

def _capture_debug(raw):
    """One-shot capture of the first datagram so undecodable formats can be
    diagnosed: length, header bytes, and what the standard decrypt yields."""
    info = {"len": len(raw), "head": raw[:min(len(raw), 0x48)].hex()}
    try:
        if HAS_SALSA and len(raw) >= 0x44:
            seed = int.from_bytes(raw[0x40:0x44], 'little')
            nonce = (seed ^ 0xDEADBEAF).to_bytes(4, 'little') + seed.to_bytes(4, 'little')
            info["dec"] = _S20.new(key=_KEY, nonce=nonce).decrypt(raw)[:8].hex()
        else:
            info["dec"] = "n/a"
    except Exception:
        info["dec"] = "err"
    _stats["debug"] = info

def _status_msg():
    return json.dumps({
        "type": "status",
        "packets": _stats["packets"],   # valid, decoded telemetry packets
        "raw": _stats["raw"],           # raw UDP datagrams received (before decode)
        "ps5": _stats["ps5"],
        "debug": _stats["debug"],
        "listening": True,
    })

async def _ws_handler(ws):
    _clients.add(ws)
    try:
        await ws.send(json.dumps({"type":"connected","message":"GT7 Live Connector ready"}))
        await ws.send(_status_msg())          # tell a fresh page what we're seeing right away
        async for _ in ws:
            pass
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        _clients.discard(ws)

async def _broadcast(msg: str):
    dead = set()
    for ws in _clients:
        try:
            await ws.send(msg)
        except Exception:
            dead.add(ws)
    _clients.difference_update(dead)

# ═══════════════════════════════════════════════════════════════
#  UDP RECEIVER + HEARTBEAT
# ═══════════════════════════════════════════════════════════════
def _hb(ip):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.sendto(b'A', (ip, SEND_PORT))
        s.close()
    except Exception:
        pass

def _local_subnet_bcast():
    """Best-effort subnet broadcast address (e.g. 192.168.1.255) for the
    interface that reaches the internet. Directed broadcast reaches consoles
    that the limited 255.255.255.255 broadcast misses on many home networks."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))          # no packet sent; just picks the interface
        ip = s.getsockname()[0]
        s.close()
        parts = ip.split('.')
        if len(parts) == 4:
            parts[3] = '255'
            return '.'.join(parts)
    except Exception:
        pass
    return None

async def _heartbeat(ip_ref):
    sub = _local_subnet_bcast()
    def ping():
        tgt = ip_ref[0]
        if tgt:
            _hb(tgt)                         # known/configured console: unicast straight to it
        else:
            _hb('255.255.255.255')           # limited broadcast
            if sub:
                _hb(sub)                     # subnet-directed broadcast (reaches more networks)
    ping()
    while True:
        await asyncio.sleep(HEARTBEAT_INT)
        ping()

async def _status_loop():
    # Push a heartbeat of our own state to any connected page every 2s, so the
    # dashboard can show "listening, no telemetry yet" vs "receiving".
    while True:
        await asyncio.sleep(2)
        if _clients:
            await _broadcast(_status_msg())

async def _receiver(ps5_ip, ip_ref):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', GT7_PORT))
    sock.setblocking(False)
    loop = asyncio.get_event_loop()
    last_id = -1
    detected = ps5_ip
    if ps5_ip:
        ip_ref[0] = ps5_ip

    while True:
        await asyncio.sleep(0)
        try:
            raw, addr = await loop.run_in_executor(None, lambda: sock.recvfrom(4096))
        except BlockingIOError:
            await asyncio.sleep(0.001)
            continue
        except Exception:
            await asyncio.sleep(0.01)
            continue

        _stats["raw"] += 1                # a datagram arrived (before any decode)
        if _stats["raw"] == 1:
            _capture_debug(raw)           # snapshot the first packet for diagnosis

        if detected is None:
            detected = addr[0]
            ip_ref[0] = detected
            _stats["ps5"] = detected
            _hb(detected)
            await _broadcast(json.dumps({"type":"gt7_detected","ip":detected}))

        dec = decrypt_packet(raw)
        if dec is None:
            continue
        pkt = GT7Packet(dec)
        if not pkt.valid or pkt.packet_id == last_id:
            continue
        last_id = pkt.packet_id
        _stats["packets"] += 1
        _stats["last"] = time.time()
        # Keep the console streaming: GT7 sends ~100 packets per heartbeat, then
        # stops. Re-ping every HEARTBEAT_EVERY packets so the feed never stalls.
        if pkt.packet_id % HEARTBEAT_EVERY == 0:
            _hb(ip_ref[0] or detected or '255.255.255.255')
        if _clients:
            await _broadcast(json.dumps(pkt.to_dict()))


# ═══════════════════════════════════════════════════════════════
#  ASYNCIO MAIN (runs in background thread)
# ═══════════════════════════════════════════════════════════════
_loop = None

async def _async_main(ps5_ip):
    ip_ref = [ps5_ip]
    server = await websockets.serve(_ws_handler, WS_HOST, WS_PORT)
    if ps5_ip:
        _stats["ps5"] = ps5_ip
    await asyncio.gather(
        server.wait_closed(),
        _receiver(ps5_ip, ip_ref),
        _heartbeat(ip_ref),
        _status_loop(),
    )

def _run_bridge(ps5_ip):
    global _loop
    _loop = asyncio.new_event_loop()
    asyncio.set_event_loop(_loop)
    _loop.run_until_complete(_async_main(ps5_ip))


# ═══════════════════════════════════════════════════════════════
#  TRAY ICON
# ═══════════════════════════════════════════════════════════════
def _make_icon():
    """Draw a small GT7-style icon: dark bg, red circle, 'G7' text."""
    size = 64
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Outer circle (dark)
    draw.ellipse([2, 2, 61, 61], fill=(13, 15, 24, 255), outline=(28, 31, 46, 255))
    # Inner accent circle (red)
    draw.ellipse([14, 14, 49, 49], fill=(255, 45, 59, 220))
    # Inner dark circle to make a ring
    draw.ellipse([22, 22, 41, 41], fill=(13, 15, 24, 255))
    return img

def _quit(icon, _item):
    icon.stop()
    if _loop:
        _loop.call_soon_threadsafe(_loop.stop)
    sys.exit(0)


def _resolve_ps5_ip():
    """Where to send the heartbeat. Broadcast is tried by default, but on
    networks that block broadcast (or a console on another subnet) you can
    point the connector straight at the console: pass the IP as an argument,
    set the GT7_PS5_IP environment variable, or drop a `gt7-console-ip.txt`
    file (one line, the console's IP) next to the .exe."""
    if len(sys.argv) > 1 and sys.argv[1].strip():
        return sys.argv[1].strip()
    env = os.environ.get("GT7_PS5_IP", "").strip()
    if env:
        return env
    try:
        base = os.path.dirname(sys.executable if getattr(sys, "frozen", False) else os.path.abspath(__file__))
        cfg = os.path.join(base, "gt7-console-ip.txt")
        if os.path.exists(cfg):
            with open(cfg, "r", encoding="utf-8") as fh:
                ip = fh.readline().strip()
                if ip:
                    return ip
    except Exception:
        pass
    return None

def _tray_status(icon):
    while True:
        time.sleep(2)
        ip = _stats["ps5"] or "searching…"
        p = _stats["packets"]
        raw = _stats["raw"]
        if p > 0:
            state = "receiving"
        elif raw > 0:
            d = _stats.get("debug") or {}
            state = f"undecoded len={d.get('len')} dec={d.get('dec')}"
        else:
            state = "nothing from console — is GT7 on track?"
        try:
            icon.title = f"GT7 Live Connector v{VERSION}\nConsole: {ip}\nRaw: {raw}  Decoded: {p}\n{state}"
        except Exception:
            pass

def main():
    ps5_ip = _resolve_ps5_ip()

    # Start bridge in background thread
    t = threading.Thread(target=_run_bridge, args=(ps5_ip,), daemon=True)
    t.start()

    if HAS_TRAY:
        icon = pystray.Icon(
            name="GT7 Live Connector",
            icon=_make_icon(),
            title="GT7 Live Connector — Running\nws://localhost:8765",
            menu=pystray.Menu(
                pystray.MenuItem("GT7 Live Connector — Running", None, enabled=False),
                pystray.MenuItem("Port: 8765", None, enabled=False),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("Quit", _quit),
            )
        )
        threading.Thread(target=_tray_status, args=(icon,), daemon=True).start()
        icon.run()
    else:
        # Fallback: no tray, just keep main thread alive
        print("GT7 Live Connector running on ws://localhost:8765")
        print("Press Ctrl+C to stop.")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
