"""A printable contour map of anywhere on Earth, as a PDF.

The same machinery that puts the Eifel behind the GTEC track map: SRTM
elevation from Terrarium tiles, marching squares for the contours, and
Douglas-Peucker to thin them. What changes is the other end. Instead of a
circuit's own coordinate frame it takes a latitude and longitude box, and
instead of JSON for a canvas it writes a PDF you can print.

Standard library only, the PDF included. A one page vector drawing is a
few hundred bytes of header and a content stream of moveto and lineto, and
the fourteen base fonts need no embedding, so a dependency would buy
nothing here.

    python3 contour_map_pdf.py --box 36.00,-112.30,36.25,-112.00 \
        --title "Grand Canyon" --interval 100 --out grand-canyon.pdf
"""
import argparse
import math
import os
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from terrain_contours import Dem, contours, stitch, simplify, TILE_URL, M_LAT

# A4 at 72 points to the inch, which is the unit a PDF works in.
A4 = (595.28, 841.89)
MARGIN = 38.0           # about 13 mm, inside any printer's dead zone


# ------------------------------------------------------------------ pdf ----
class Pdf:
    """One page of vector line art. No images, no embedded fonts."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.ops = []
        self.pages = []          # finished pages, as op lists

    def page_break(self):
        """Bank the current page and start a new one."""
        self.pages.append(self.ops)
        self.ops = []

    def line_width(self, pt):      self.ops.append(f"{pt:.2f} w")
    def grey(self, g):             self.ops.append(f"{g:.3f} G")
    def fill_grey(self, g):        self.ops.append(f"{g:.3f} g")

    def path(self, pts):
        if len(pts) < 2:
            return
        self.ops.append(f"{pts[0][0]:.2f} {pts[0][1]:.2f} m")
        for x, y in pts[1:]:
            self.ops.append(f"{x:.2f} {y:.2f} l")
        self.ops.append("S")

    def rect(self, x, y, w, h, fill=False):
        self.ops.append(f"{x:.2f} {y:.2f} {w:.2f} {h:.2f} re")
        self.ops.append("f" if fill else "S")

    def text(self, x, y, size, s, grey=0.0, angle=None):
        # WinAnsi covers the whole of latin-1's printable range, so a middle
        # dot or an accent is fine; only what falls outside it becomes a
        # question mark. Filtering at 127 turned every separator into one.
        s = "".join(ch if 32 <= ord(ch) <= 255 and ord(ch) != 127 else "?"
                    for ch in str(s))
        s = s.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")
        self.ops.append("BT")
        self.ops.append(f"{grey:.3f} g")
        self.ops.append(f"/F1 {size:.2f} Tf")
        if angle is None:
            self.ops.append(f"1 0 0 1 {x:.2f} {y:.2f} Tm")
        else:
            c, sn = math.cos(angle), math.sin(angle)
            self.ops.append(f"{c:.4f} {sn:.4f} {-sn:.4f} {c:.4f} {x:.2f} {y:.2f} Tm")
        self.ops.append(f"({s}) Tj")
        self.ops.append("ET")

    def write(self, path):
        pages = self.pages + ([self.ops] if self.ops else [])
        if not pages:
            pages = [[]]
        # Object numbering: 1 catalog, 2 pages, 3 font, then a page object
        # and a content stream for each page.
        first = 4
        kids = " ".join(f"{first + 2*i} 0 R" for i in range(len(pages)))
        objs = [
            b"<< /Type /Catalog /Pages 2 0 R >>",
            (f"<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>").encode(),
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        for i, ops in enumerate(pages):
            stream = zlib.compress("\n".join(ops).encode("latin-1"))
            objs.append(
                (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {self.w:.2f} {self.h:.2f}] "
                 f"/Resources << /Font << /F1 3 0 R >> >> "
                 f"/Contents {first + 2*i + 1} 0 R >>").encode())
            objs.append(
                b"<< /Length " + str(len(stream)).encode() + b" /Filter /FlateDecode >>\nstream\n"
                + stream + b"\nendstream")
        out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = []
        for i, body in enumerate(objs, start=1):
            offsets.append(len(out))
            out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
        xref = len(out)
        out += f"xref\n0 {len(objs) + 1}\n".encode()
        out += b"0000000000 65535 f \n"
        for off in offsets:
            out += f"{off:010d} 00000 n \n".encode()
        out += (f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\n"
                f"startxref\n{xref}\n%%EOF\n").encode()
        with open(path, "wb") as fh:
            fh.write(out)


# ----------------------------------------------------------------- main ----
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--box", required=True,
                    help="south,west,north,east in degrees")
    ap.add_argument("--title", required=True)
    ap.add_argument("--subtitle", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=100.0,
                    help="contour spacing, metres")
    ap.add_argument("--index-every", type=int, default=5,
                    help="every Nth contour drawn heavier and labelled")
    ap.add_argument("--grid", type=float, default=60.0,
                    help="sampling step, metres")
    ap.add_argument("--zoom", type=int, default=12)
    ap.add_argument("--simplify", type=float, default=12.0)
    ap.add_argument("--url", default=TILE_URL)
    a = ap.parse_args()

    s, w, n, e = (float(v) for v in a.box.split(","))
    if n <= s or e <= w:
        raise SystemExit("box must be south,west,north,east")

    lat0 = (s + n) / 2.0
    m_lon = 111320.0 * math.cos(math.radians(lat0))
    # Flat metres about the middle of the box, which at this size is close
    # enough that nothing is visibly stretched.
    to_m = lambda lat, lon: ((lon - (w + e) / 2) * m_lon, (lat - lat0) * M_LAT)
    x0, y0 = to_m(s, w)
    x1, y1 = to_m(n, e)
    width_m, height_m = x1 - x0, y1 - y0
    print(f"{width_m/1000:.1f} km wide by {height_m/1000:.1f} km tall")

    nx = int(width_m / a.grid) + 1
    nz = int(height_m / a.grid) + 1
    print(f"sampling {nx} x {nz} = {nx*nz:,} points at {a.grid:.0f} m")

    dem = Dem(a.zoom, a.url)
    print("fetching elevation", end="", flush=True)
    grid = []
    for j in range(nz):
        lat = s + (n - s) * (j / max(1, nz - 1))
        row = [dem.at(lat, w + (e - w) * (i / max(1, nx - 1))) for i in range(nx)]
        grid.append(row)
        if j % 40 == 0:
            print(".", end="", flush=True)
    print(f" done, {dem.fetched} tiles")

    lo = min(min(r) for r in grid)
    hi = max(max(r) for r in grid)
    print(f"ground runs {lo:.0f} m to {hi:.0f} m above sea level, "
          f"{hi-lo:.0f} m of relief")

    levels = []
    lv = math.ceil(lo / a.interval) * a.interval
    while lv <= hi:
        levels.append(lv)
        lv += a.interval

    # ---- the page -------------------------------------------------------
    # Whichever way round prints the map bigger, which is not the same as
    # whichever way round the map is. A square area on A4 is limited by the
    # page's width in portrait and by its height in landscape, and portrait's
    # usable width beats landscape's usable height, so a square map wants
    # portrait even though it is not taller than it is wide.
    def fit(pw, ph):
        top = ph - MARGIN - 34      # room for the title
        bottom = MARGIN + 54        # room for the scale bar and the two notes
        bw, bh = pw - 2 * MARGIN, top - bottom
        return min(bw / width_m, bh / height_m), top, bottom, bw, bh

    portrait = fit(*A4)
    landscaped = fit(A4[1], A4[0])
    landscape = landscaped[0] > portrait[0]
    pw, ph = (A4[1], A4[0]) if landscape else A4
    scale, top, bottom, box_w, box_h = landscaped if landscape else portrait
    pdf = Pdf(pw, ph)
    ox = MARGIN + (box_w - width_m * scale) / 2
    oy = bottom + (box_h - height_m * scale) / 2
    # Grid coordinates are metres from the box's south-west corner; PDF y
    # counts up from the bottom of the page, which is the same direction.
    px = lambda mx: ox + mx * scale
    py = lambda my: oy + my * scale

    pdf.rect(ox - 4, oy - 4, width_m * scale + 8, height_m * scale + 8)

    drawn = 0
    labels = []
    for k, lv in enumerate(levels):
        index = (round(lv / a.interval) % a.index_every) == 0
        pdf.line_width(0.9 if index else 0.3)
        pdf.grey(0.15 if index else 0.55)
        for ln in stitch(contours(grid, 0.0, 0.0, a.grid, lv)):
            pts = simplify(ln, a.simplify)
            if len(pts) < 2:
                continue
            pdf.path([(px(p[0]), py(p[1])) for p in pts])
            drawn += 1
            # One height on the longest run of each index contour, placed
            # along the line so it reads the way a map's does.
            if index and len(pts) > 25:
                labels.append((pts, int(round(lv))))

    # Labels last, so no contour is drawn over one.
    placed = []
    for pts, height in sorted(labels, key=lambda t: -len(t[0])):
        i = len(pts) // 2
        xm, ym = px(pts[i][0]), py(pts[i][1])
        if any((xm - qx) ** 2 + (ym - qy) ** 2 < 48 ** 2 for qx, qy in placed):
            continue
        dx = pts[min(i + 2, len(pts) - 1)][0] - pts[max(i - 2, 0)][0]
        dy = pts[min(i + 2, len(pts) - 1)][1] - pts[max(i - 2, 0)][1]
        ang = math.atan2(dy, dx)
        if ang > math.pi / 2: ang -= math.pi
        if ang < -math.pi / 2: ang += math.pi
        pdf.fill_grey(1.0)
        pdf.rect(xm - 13, ym - 4, 26, 9, fill=True)
        pdf.text(xm - 11, ym - 2, 6.5, f"{height} m", grey=0.1, angle=ang)
        placed.append((xm, ym))

    # ---- titles, scale, the small print ---------------------------------
    pdf.text(MARGIN, ph - MARGIN - 14, 17, a.title, grey=0.05)
    if a.subtitle:
        pdf.text(MARGIN, ph - MARGIN - 28, 9, a.subtitle, grey=0.35)

    # A scale bar in whole kilometres, as long as fits in a third of the page.
    km = 1
    while (km + 1) * 1000 * scale < box_w / 3:
        km += 1
    bar = km * 1000 * scale
    bx, by = MARGIN, MARGIN + 26
    pdf.line_width(1.0)
    pdf.grey(0.1)
    pdf.path([(bx, by), (bx + bar, by)])
    pdf.path([(bx, by - 3), (bx, by + 3)])
    pdf.path([(bx + bar, by - 3), (bx + bar, by + 3)])
    pdf.path([(bx + bar / 2, by - 2), (bx + bar / 2, by + 2)])
    # Both ends labelled where they actually are. Padding one string with
    # spaces put the far label a third of the way along the bar.
    pdf.text(bx - 2, by + 6, 7.5, "0", grey=0.1)
    pdf.text(bx + bar - 11, by + 6, 7.5, f"{km} km", grey=0.1)

    # North is up: the box is drawn straight from latitude and longitude.
    nx_, ny_ = pw - MARGIN - 10, MARGIN + 22
    pdf.line_width(1.0)
    pdf.path([(nx_, ny_), (nx_, ny_ + 16)])
    pdf.path([(nx_ - 3.5, ny_ + 11), (nx_, ny_ + 16)])
    pdf.path([(nx_ + 3.5, ny_ + 11), (nx_, ny_ + 16)])
    pdf.text(nx_ - 2.5, ny_ - 7, 7.5, "N", grey=0.1)

    # Two lines rather than one. Placed by a guessed width, the attribution
    # ran straight into the end of the note with no gap at all.
    note = (f"Contours every {a.interval:.0f} m, every {a.index_every}th heavier and labelled.  "
            f"Ground {lo:.0f} to {hi:.0f} m above sea level, {hi-lo:.0f} m of relief.  "
            f"{s:.3f}, {w:.3f} to {n:.3f}, {e:.3f}.")
    pdf.text(MARGIN, MARGIN + 10, 6.5, note, grey=0.45)
    pdf.text(MARGIN, MARGIN + 1, 6.5,
             "Elevation: SRTM via Terrain Tiles on AWS Open Data, public domain.",
             grey=0.45)

    pdf.write(a.out)
    print(f"{len(levels)} levels, {drawn} contour lines, {len(placed)} labels")
    print(f"wrote {a.out}  ({os.path.getsize(a.out)/1024:.0f} KB, "
          f"A4 {'landscape' if landscape else 'portrait'})")


if __name__ == "__main__":
    main()
