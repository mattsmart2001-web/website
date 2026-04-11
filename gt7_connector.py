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
GT7_PORT      = 33740
SEND_PORT     = 33739
WS_PORT       = 8765
WS_HOST       = "0.0.0.0"
HEARTBEAT_INT = 10

# ═══════════════════════════════════════════════════════════════
#  DECRYPTION
# ═══════════════════════════════════════════════════════════════
_KEY = (b'\x52\xC3\x33\x99\x65\x92\x87\xA4\x3C\xBF\xFE\x22\x51\x31\x22\x10'
        b'\x5A\x0A\x53\xE7\xFB\x80\x81\x70\xFA\x3B\x3B\x6D\x12\xFD\x11\xAA')

def decrypt_packet(data: bytes) -> Optional[bytes]:
    if len(data) < 0x128:
        return None
    iv = data[0x40:0x48]
    if HAS_SALSA:
        try:
            return _S20.new(key=_KEY, nonce=iv).decrypt(data)
        except Exception:
            pass
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
        enc = Cipher(algorithms.ChaCha20(_KEY, bytes(4) + iv), mode=None).encryptor()
        return enc.update(data)
    except Exception:
        return data

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
        self.rpm         = self._f(0x3C)
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
        self.tfl_sus     = self._f(0xB4)
        self.tfr_sus     = self._f(0xB8)
        self.trl_sus     = self._f(0xBC)
        self.trr_sus     = self._f(0xC0)
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

async def _ws_handler(ws):
    _clients.add(ws)
    try:
        await ws.send(json.dumps({"type":"connected","message":"GT7 Live Connector ready"}))
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

async def _heartbeat(ip_ref):
    _hb('255.255.255.255')
    while True:
        await asyncio.sleep(HEARTBEAT_INT)
        _hb(ip_ref[0] or '255.255.255.255')

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

        if detected is None:
            detected = addr[0]
            ip_ref[0] = detected
            _hb(detected)
            await _broadcast(json.dumps({"type":"gt7_detected","ip":detected}))

        dec = decrypt_packet(raw)
        if dec is None:
            continue
        pkt = GT7Packet(dec)
        if not pkt.valid or pkt.packet_id == last_id:
            continue
        last_id = pkt.packet_id
        if _clients:
            await _broadcast(json.dumps(pkt.to_dict()))


# ═══════════════════════════════════════════════════════════════
#  ASYNCIO MAIN (runs in background thread)
# ═══════════════════════════════════════════════════════════════
_loop = None

async def _async_main(ps5_ip):
    ip_ref = [ps5_ip]
    server = await websockets.serve(_ws_handler, WS_HOST, WS_PORT)
    await asyncio.gather(
        server.wait_closed(),
        _receiver(ps5_ip, ip_ref),
        _heartbeat(ip_ref),
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


def main():
    ps5_ip = sys.argv[1] if len(sys.argv) > 1 else None

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
