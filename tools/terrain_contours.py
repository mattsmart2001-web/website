#!/usr/bin/env python3
"""Build contour lines for a GTEC circuit, in GT7 coordinates.

Run once per circuit. Takes the outline the cars traced, fetches real
elevation for the area around it, and writes a file of contour polylines that
the live map can draw straight behind the track with no further maths: the
contours come out in GT7's own coordinates, because that is the space the
elevation is sampled in.

    python3 terrain_contours.py outline.csv --origin 50.352417,6.962805 \
            --name nurburgring-24h --out nurburgring-24h.json

The origin is where GT7's (0,0) sits, found by registering the traced outline
against OpenStreetMap. GT7's axes at the Nordschleife are aligned with the
real world: x points east, z points south, and the scale is 1:1 metres. That
is assumed here, and the script checks it by reporting how well the real
ground agrees with the heights GT7 reported along the lap. A median that is
tens of metres means the origin is wrong and nothing else it prints is worth
having.

Needs nothing installed: standard library only, including its own small PNG
decoder, because asking somebody to set up Pillow to run a script once is a
worse experience than forty lines of zlib.

Elevation comes from the Terrain Tiles dataset on AWS Open Data, which is
built from SRTM and other public sources. Free, no key. Attribution is
written into the output and belongs on any page that draws it.
"""
import argparse, json, math, struct, sys, time, zlib
import urllib.request, urllib.error

TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
ATTRIBUTION = ("Elevation: Terrain Tiles on AWS Open Data (SRTM and others), "
               "public domain. Circuit geometry: traced by GTEC drivers.")

M_LAT = 111132.0


# ---------------------------------------------------------------- PNG ----
def png_rgb(data):
    """Decode an 8-bit RGB or RGBA PNG to (width, height, rows of bytes)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG (the server probably returned an error page)")
    pos, idat, w = 8, [], None
    while pos < len(data):
        ln, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, depth, colour = struct.unpack(">IIBB", body[:10])
            if depth != 8 or colour not in (2, 6):
                raise ValueError(f"unsupported PNG: depth {depth}, colour {colour}")
            channels = 3 if colour == 2 else 4
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
        pos += 12 + ln
    raw = zlib.decompress(b"".join(idat))
    stride = w * channels
    out, prev = [], bytearray(stride)
    p = 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                c = prev[i - channels] if i >= channels else 0
                b = prev[i]
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif f != 0:
            raise ValueError(f"unknown PNG filter {f}")
        out.append(line)
        prev = line
    return w, h, out, channels


# --------------------------------------------------------------- tiles ----
def tile_of(lat, lon, z):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    la = math.radians(lat)
    y = (1.0 - math.asinh(math.tan(la)) / math.pi) / 2.0 * n
    return x, y


class Dem:
    """Terrarium tiles, fetched on demand and sampled bilinearly."""

    def __init__(self, zoom, url, pause=0.0):
        self.z, self.url, self.pause = zoom, url, pause
        self.tiles = {}
        self.fetched = 0

    def tile(self, tx, ty):
        key = (tx, ty)
        if key in self.tiles:
            return self.tiles[key]
        u = self.url.format(z=self.z, x=tx, y=ty)
        for attempt in range(4):
            try:
                with urllib.request.urlopen(u, timeout=30) as r:
                    data = r.read()
                break
            except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
                if attempt == 3:
                    raise SystemExit(f"\ncould not fetch {u}\n  {e}\n"
                                     "If this is a 403 or 404 the tile set has moved; "
                                     "pass a different --url.")
                time.sleep(1.5 * (attempt + 1))
        w, h, rows, ch = png_rgb(data)
        grid = [[0.0] * w for _ in range(h)]
        for j in range(h):
            row = rows[j]
            for i in range(w):
                k = i * ch
                grid[j][i] = (row[k] * 256 + row[k + 1] + row[k + 2] / 256.0) - 32768.0
        self.tiles[key] = (w, grid)
        self.fetched += 1
        if self.pause:
            time.sleep(self.pause)
        return self.tiles[key]

    def at(self, lat, lon):
        fx, fy = tile_of(lat, lon, self.z)
        tx, ty = int(fx), int(fy)
        size, _ = self.tile(tx, ty)
        px, py = (fx - tx) * size, (fy - ty) * size
        x0, y0 = int(px), int(py)
        dx, dy = px - x0, py - y0
        acc = 0.0
        for ox, oy, wgt in ((0, 0, (1 - dx) * (1 - dy)), (1, 0, dx * (1 - dy)),
                            (0, 1, (1 - dx) * dy), (1, 1, dx * dy)):
            ax, ay = x0 + ox, y0 + oy
            ttx, tty = tx, ty
            if ax >= size: ttx, ax = tx + 1, ax - size
            if ay >= size: tty, ay = ty + 1, ay - size
            s, g = self.tile(ttx, tty)
            acc += g[ay][ax] * wgt
        return acc


# ------------------------------------------------------- marching squares ----
def contours(grid, x0, z0, step, level):
    """Segments where the surface crosses one height, in grid coordinates.

    The level is nudged by a hair so that it never falls exactly on a grid
    node. When it does, several cells interpolate to the identical point and
    the contour becomes a junction of four or six segment ends rather than a
    chain, which the stitching below then closes early and leaves the rest of
    the ring in pieces. Elevation tiles are quantised, so flat ground and
    plateaus land on round numbers often enough for this to matter.
    """
    level += 1e-6
    segs = []
    h = len(grid); w = len(grid[0])

    def lerp(a, b, va, vb):
        t = 0.5 if va == vb else (level - va) / (vb - va)
        return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)

    for j in range(h - 1):
        for i in range(w - 1):
            v = (grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i])
            case = sum(1 << k for k in range(4) if v[k] >= level)
            if case in (0, 15):
                continue
            p = ((x0 + i * step, z0 + j * step),
                 (x0 + (i + 1) * step, z0 + j * step),
                 (x0 + (i + 1) * step, z0 + (j + 1) * step),
                 (x0 + i * step, z0 + (j + 1) * step))
            e = [None] * 4
            for k in range(4):
                a, b = k, (k + 1) % 4
                if (v[a] >= level) != (v[b] >= level):
                    e[k] = lerp(p[a], p[b], v[a], v[b])
            edges = [k for k in range(4) if e[k] is not None]
            if len(edges) == 2:
                segs.append((e[edges[0]], e[edges[1]]))
            elif len(edges) == 4:
                # A saddle. Split it the way the cell's average suggests.
                if sum(v) / 4.0 >= level:
                    segs.append((e[0], e[1])); segs.append((e[2], e[3]))
                else:
                    segs.append((e[1], e[2])); segs.append((e[3], e[0]))
    return segs


def stitch(segs, tol=0.05):
    """Join segments end to end into polylines.

    Neighbouring cells compute the point on their shared edge from the same
    two corner heights, so the two copies are identical, but rounding them to
    a key puts a pair either side of a bucket boundary into different buckets
    and the contour comes apart. A circle arrived as seven lines that way.
    So every lookup checks the neighbouring buckets as well.
    """
    key = lambda p: (round(p[0] / tol), round(p[1] / tol))
    ends = {}
    for s in segs:
        ends.setdefault(key(s[0]), []).append((s, 0))
        ends.setdefault(key(s[1]), []).append((s, 1))

    def candidates(p):
        kx, ky = key(p)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for c in ends.get((kx + dx, ky + dy), ()):
                    yield c

    used, lines = set(), []
    for s in segs:
        if id(s) in used:
            continue
        used.add(id(s))
        line = [s[0], s[1]]
        for end in (1, 0):
            while True:
                tip = line[-1] if end else line[0]
                nxt = None
                for cand, which in candidates(tip):
                    if id(cand) not in used and math.dist(cand[which], tip) <= tol:
                        nxt = (cand, which); break
                if not nxt:
                    break
                cand, which = nxt
                used.add(id(cand))
                other = cand[1 - which]
                if end:
                    line.append(other)
                else:
                    line.insert(0, other)
        lines.append(line)
    return lines


def simplify(line, tol):
    """Douglas-Peucker, iteratively so a long contour cannot blow the stack."""
    if len(line) < 3:
        return line
    keep = [False] * len(line)
    keep[0] = keep[-1] = True
    stack = [(0, len(line) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        ax, az = line[a]; bx, bz = line[b]
        dx, dz = bx - ax, bz - az
        dd = dx * dx + dz * dz
        worst, wi = -1.0, None
        for i in range(a + 1, b):
            px, pz = line[i]
            if dd == 0:
                d = (px - ax) ** 2 + (pz - az) ** 2
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (pz - az) * dz) / dd))
                d = (px - ax - t * dx) ** 2 + (pz - az - t * dz) ** 2
            if d > worst:
                worst, wi = d, i
        if worst > tol * tol:
            keep[wi] = True
            stack.append((a, wi)); stack.append((wi, b))
    return [p for p, k in zip(line, keep) if k]


ASPECT_STEPS = 64


def aspect_at(grid, x0, z0, step, nx, nz, x, z):
    """Which way is uphill at a point, in 64ths of a turn from east to south.

    Nothing downstream can work this out for itself. Marching squares emits a
    cell's two ends in whatever order its case table gives, and the stitching
    reverses runs to join them, so a contour's direction carries no sign and
    its normal could point either up the hill or down it. Here the height grid
    is still in hand, which makes it a central difference.

    Returns None where the ground is flat enough to have no aspect at all.
    """
    i0 = min(max(int((x - x0) / step), 1), nx - 2)
    j0 = min(max(int((z - z0) / step), 1), nz - 2)
    dx = grid[j0][i0 + 1] - grid[j0][i0 - 1]
    dz = grid[j0 + 1][i0] - grid[j0 - 1][i0]
    if dx == 0 and dz == 0:
        return None
    return int(round(math.atan2(dz, dx) / (2 * math.pi) * ASPECT_STEPS)) % ASPECT_STEPS


# ---------------------------------------------------------------- main ----
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", help="outline exported from live_track_path (seq,x,y,z)")
    ap.add_argument("--origin", required=True, help="lat,lon where GT7 (0,0) sits")
    ap.add_argument("--name", required=True, help="circuit slug for the output file")
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=25.0, help="contour spacing, metres")
    ap.add_argument("--margin", type=float, default=2500.0,
                    help="how far beyond the circuit to sample")
    ap.add_argument("--square", action="store_true",
                    help="keep the sampled square instead of clipping to a circle")
    ap.add_argument("--grid", type=float, default=25.0, help="sampling step, metres")
    ap.add_argument("--zoom", type=int, default=13)
    ap.add_argument("--simplify", type=float, default=6.0)
    ap.add_argument("--url", default=TILE_URL)
    a = ap.parse_args()

    lat0, lon0 = (float(v) for v in a.origin.split(","))
    m_lon = 111320.0 * math.cos(math.radians(lat0))
    # GT7 x is east, z is SOUTH, so north decreases as z increases.
    to_ll = lambda x, z: (lat0 - z / M_LAT, lon0 + x / m_lon)

    import csv as _csv
    pts = []
    with open(a.csv, newline="") as fh:
        for r in _csv.DictReader(fh):
            pts.append((float(r["x"]), float(r["z"]), float(r["y"])))
    if not pts:
        raise SystemExit("no points in that CSV")

    xs = [p[0] for p in pts]; zs = [p[1] for p in pts]
    cx = (min(xs) + max(xs)) / 2.0
    cz = (min(zs) + max(zs)) / 2.0
    # A square about the circuit rather than a rectangle hugging it, because
    # the output is clipped to the circle inscribed in this region: from a
    # rectangle that circle reaches the asked-for margin only on the short
    # axis and falls short at the ends of a long circuit, which is exactly
    # where a reader is most likely to notice the ground running out.
    half = max(max(xs) - cx, max(zs) - cz) + a.margin
    minx, maxx = cx - half, cx + half
    minz, maxz = cz - half, cz + half
    nx = int((maxx - minx) / a.grid) + 1
    nz = int((maxz - minz) / a.grid) + 1
    print(f"circuit spans {max(xs)-min(xs):.0f} x {max(zs)-min(zs):.0f} m, "
          f"sampling {nx} x {nz} = {nx*nz:,} points at {a.grid:.0f} m")

    dem = Dem(a.zoom, a.url)

    # The vertical offset first, from the track itself, so a wrong origin is
    # caught before spending time on a grid.
    diffs = []
    for x, z, y in pts:
        la, lo = to_ll(x, z)
        diffs.append(dem.at(la, lo) - y)
    diffs.sort()
    offset = diffs[len(diffs) // 2]
    spread = diffs[int(len(diffs) * 0.9)] - diffs[int(len(diffs) * 0.1)]
    print(f"\nvertical offset   {offset:+.1f} m   (GT7 height + this = metres above sea level)")
    print(f"spread, 10th to 90th percentile   {spread:.1f} m")
    if spread > 60:
        print("\n  That spread is too wide. Either the origin is wrong, or the game's")
        print("  terrain differs from the real ground by more than contours can")
        print("  usefully sit under. Check the origin before trusting the rest.")
    else:
        print("  A spread of a few tens of metres is expected: Polyphony adjust the")
        print("  ground for racing, so the game's surface is not the real surface.")

    print(f"\nsampling terrain ({dem.fetched} tiles so far)", end="", flush=True)
    grid = []
    for j in range(nz):
        row = []
        z = minz + j * a.grid
        for i in range(nx):
            la, lo = to_ll(minx + i * a.grid, z)
            row.append(dem.at(la, lo))
        grid.append(row)
        if j % 25 == 0:
            print(".", end="", flush=True)
    print(f" done, {dem.fetched} tiles")

    lo_h = min(min(r) for r in grid); hi_h = max(max(r) for r in grid)
    print(f"ground runs {lo_h:.0f} m to {hi_h:.0f} m above sea level")

    levels = []
    lv = math.ceil(lo_h / a.interval) * a.interval
    while lv <= hi_h:
        levels.append(lv); lv += a.interval

    # Clipped to the circle inscribed in that square. A square has corners,
    # and rotating the map brings them into view as a hard straight edge where
    # the contours stop. A disc has no such edge from any angle, and the page
    # fades the outer part of it to nothing.
    radius = 0.0 if a.square else half

    def clip(line):
        """Runs of the line that lie inside the circle, as separate lines."""
        if not radius:
            return [line]
        runs, cur = [], []
        for p in line:
            if math.hypot(p[0] - cx, p[1] - cz) <= radius:
                cur.append(p)
            elif cur:
                runs.append(cur); cur = []
        if cur:
            runs.append(cur)
        return runs

    # Which way the ground faces at each point, so the page can light the
    # contours from one side. The marching squares above emit a cell's two
    # ends in whatever order the case table gives, and stitching reverses runs
    # to join them, so nothing downstream can tell uphill from downhill out of
    # the geometry alone. Here the height grid is still in hand, which makes
    # it a central difference and an arctangent.
    #
    # Stored as a sixth of a turn's worth of resolution, 0 to 63, because a
    # degree would cost three times the characters to say nothing the eye can
    # see. 0 is uphill due east, counting round towards south.
    aspect = lambda x, z: aspect_at(grid, minx, minz, a.grid, nx, nz, x, z)

    out, total, flat_pts = [], 0, 0
    for lv in levels:
        for ln in stitch(contours(grid, minx, minz, a.grid, lv)):
            for piece in clip(ln):
                s = simplify(piece, a.simplify)
                if len(s) >= 2:
                    asp = [aspect(p[0], p[1]) for p in s]
                    flat_pts += sum(1 for v in asp if v is None)
                    out.append({"h": round(lv - offset, 1),
                                "p": [[round(p[0], 1), round(p[1], 1)] for p in s],
                                "a": [0 if v is None else v for v in asp]})
                    total += len(s)
    print(f"{len(levels)} contour levels, {len(out)} lines, {total:,} points")
    if flat_pts:
        print(f"{flat_pts:,} of them on ground too flat to have an aspect, "
              f"lit as though facing east")
    if radius:
        print(f"clipped to a circle of radius {radius:.0f} m about "
              f"({cx:.0f}, {cz:.0f}) in GT7 coordinates")

    doc = {"circuit": a.name, "interval_m": a.interval,
           "y_offset_m": round(offset, 1),
           # The page fades the outer part of this disc to nothing, so it
           # needs to know where the middle is and how far it reaches.
           "centre": [round(cx, 1), round(cz, 1)],
           "radius_m": round(radius, 1),
           # Which way is uphill at each point of each line, in 64ths of a
           # turn from due east towards south. The page lights the hills with
           # it; a file without it is simply drawn unlit.
           "aspect_steps": ASPECT_STEPS,
           "note": "Heights are in GT7's own vertical frame, matching live_track_path.y",
           "attribution": ATTRIBUTION, "lines": out}
    with open(a.out, "w") as fh:
        json.dump(doc, fh, separators=(",", ":"))
    import os
    print(f"\nwrote {a.out}  ({os.path.getsize(a.out)/1024:.0f} KB)")
    print("Send me that file and I will draw it behind the track.")


if __name__ == "__main__":
    main()
