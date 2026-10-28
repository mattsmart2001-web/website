"""Cutting sheets for a layered cardboard terrain model.

One page per layer, all at the same scale, each showing the outline to cut
and — dashed, inside it — the outline of the layer that goes on top. That
dashed line is what makes the stack line up: glue the next layer along it
and the model registers itself, with no marks to measure and nothing to
line up by eye.

A first page shows every layer nested, as the guide to what is being
built, and a last line on each sheet says which layer it is and how high.

    python3 contour_model_pdf.py --box 38.779,15.195,38.817,15.248 \\
        --title "Stromboli" --layers 20 --out stromboli-model.pdf
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from terrain_contours import Dem, contours, stitch, simplify, TILE_URL, M_LAT
from contour_map_pdf import Pdf, A4, MARGIN


def ring_area(p):
    a = 0.0
    for (x0, y0), (x1, y1) in zip(p, p[1:] + [p[0]]):
        a += x0 * y1 - x1 * y0
    return abs(a) / 2.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--box", required=True, help="south,west,north,east in degrees")
    ap.add_argument("--title", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--layers", type=int, default=20)
    ap.add_argument("--base", type=float, default=0.0,
                    help="height of the bottom layer, metres")
    ap.add_argument("--grid", type=float, default=25.0)
    ap.add_argument("--zoom", type=int, default=13)
    ap.add_argument("--simplify", type=float, default=12.0,
                    help="larger is smoother, and easier to cut")
    ap.add_argument("--card-mm", type=float, default=0.0,
                    help="cardboard thickness, to report the exaggeration")
    ap.add_argument("--url", default=TILE_URL)
    a = ap.parse_args()

    s, w, n, e = (float(v) for v in a.box.split(","))
    lat0 = (s + n) / 2.0
    m_lon = 111320.0 * math.cos(math.radians(lat0))
    width_m = (e - w) * m_lon
    height_m = (n - s) * M_LAT
    nx = int(width_m / a.grid) + 1
    nz = int(height_m / a.grid) + 1
    print(f"{width_m/1000:.1f} x {height_m/1000:.1f} km, "
          f"sampling {nx} x {nz} = {nx*nz:,} points")

    dem = Dem(a.zoom, a.url)
    print("fetching elevation", end="", flush=True)
    grid = []
    for j in range(nz):
        lat = s + (n - s) * (j / max(1, nz - 1))
        grid.append([dem.at(lat, w + (e - w) * (i / max(1, nx - 1))) for i in range(nx)])
        if j % 40 == 0:
            print(".", end="", flush=True)
    print(f" done, {dem.fetched} tiles")

    hi = max(max(r) for r in grid)
    # An interval that gives the asked-for number of layers and is still a
    # round number, because "every 45 m" is a thing a child can write down
    # and "every 44.8 m" is not.
    raw = (hi - a.base) / a.layers
    step = 5 if raw < 60 else 10 if raw < 150 else 25
    interval = max(step, round(raw / step) * step)
    levels = [a.base + k * interval for k in range(a.layers)]
    levels = [lv for lv in levels if lv < hi]
    print(f"summit {hi:.0f} m, {len(levels)} layers every {interval:.0f} m "
          f"from {a.base:.0f} m")

    # The biggest closed ring at each height. A layer is one piece of card,
    # so where a level breaks into several the main one is the model and the
    # rest are detail this cannot carry.
    rings, dropped = [], 0
    for lv in levels:
        pieces = [simplify(p, a.simplify) for p in stitch(contours(grid, 0.0, 0.0, a.grid, lv))]
        pieces = [p for p in pieces if len(p) >= 3]
        if not pieces:
            continue
        pieces.sort(key=ring_area, reverse=True)
        dropped += len(pieces) - 1
        rings.append((lv, pieces[0]))
    print(f"{len(rings)} layers to cut, {dropped} smaller pieces per-level left out")

    # ---- one transform for every page, set by the biggest ring ----------
    base_ring = rings[0][1]
    xs = [p[0] for p in base_ring]; ys = [p[1] for p in base_ring]
    bw, bh = max(xs) - min(xs), max(ys) - min(ys)
    pad = 26
    portrait_fit = min((A4[0] - 2*MARGIN) / bw, (A4[1] - 2*MARGIN - 60) / bh)
    land_fit = min((A4[1] - 2*MARGIN) / bw, (A4[0] - 2*MARGIN - 60) / bh)
    landscape = land_fit > portrait_fit
    pw, ph = (A4[1], A4[0]) if landscape else A4
    scale = (land_fit if landscape else portrait_fit) * 0.94
    cx = (max(xs) + min(xs)) / 2
    cy = (max(ys) + min(ys)) / 2
    px = lambda mx: pw / 2 + (mx - cx) * scale
    py = lambda my: (ph - 26) / 2 + (my - cy) * scale

    pdf = Pdf(pw, ph)
    mm = scale * 1000 / 2.8346457   # page mm per km on the ground

    def footer(line):
        pdf.text(MARGIN, 20, 7, line, grey=0.45)

    # ---- page 1: the guide ---------------------------------------------
    pdf.text(MARGIN, ph - MARGIN - 6, 17, f"{a.title}: {len(rings)} layers", grey=0.05)
    pdf.text(MARGIN, ph - MARGIN - 20, 8.5,
             f"Every layer nested. Cut one of each from the pages that follow, "
             f"then stack them in order.", grey=0.35)
    for k, (lv, ring) in enumerate(rings):
        pdf.line_width(0.8 if k == 0 else 0.4)
        pdf.grey(0.1 if k == 0 else 0.5)
        pdf.path([(px(x), py(y)) for x, y in ring] + [(px(ring[0][0]), py(ring[0][1]))])
    for k, (lv, ring) in enumerate(rings):
        if k % 2 or len(ring) < 6:
            continue
        i = max(range(len(ring)), key=lambda t: ring[t][1])
        pdf.fill_grey(1.0)
        pdf.rect(px(ring[i][0]) - 9, py(ring[i][1]) - 3.5, 18, 8, fill=True)
        pdf.text(px(ring[i][0]) - 7, py(ring[i][1]) - 1.5, 6, f"{k+1}", grey=0.1)
    footer(f"{interval:.0f} m per layer.  1 km on the ground = {mm:.0f} mm on the page.  "
           f"Summit {hi:.0f} m.")

    # ---- a page per layer ----------------------------------------------
    for k, (lv, ring) in enumerate(rings):
        pdf.page_break()
        pdf.text(MARGIN, ph - MARGIN - 6, 15,
                 f"Layer {k+1} of {len(rings)}", grey=0.05)
        pdf.text(MARGIN, ph - MARGIN - 19, 9,
                 f"{a.title} · {lv:.0f} m above sea level"
                 + ("  ·  the base, cut this one first" if k == 0 else ""), grey=0.35)

        # The layer above, dashed and inside: where the next piece goes.
        if k + 1 < len(rings):
            nxt = rings[k + 1][1]
            pdf.ops.append("[3 3] 0 d")
            pdf.line_width(0.5)
            pdf.grey(0.55)
            pdf.path([(px(x), py(y)) for x, y in nxt] + [(px(nxt[0][0]), py(nxt[0][1]))])
            pdf.ops.append("[] 0 d")

        # The cut line itself, heaviest thing on the page.
        pdf.line_width(1.4)
        pdf.grey(0.0)
        pdf.path([(px(x), py(y)) for x, y in ring] + [(px(ring[0][0]), py(ring[0][1]))])

        footer("Cut the solid line.  "
               + ("The dashed line is layer " + str(k + 2)
                  + ": glue it along that and the stack lines itself up."
                  if k + 1 < len(rings) else "Last layer, the summit."))

    pdf.write(a.out)
    print(f"wrote {a.out}  ({os.path.getsize(a.out)/1024:.0f} KB, "
          f"{len(rings)+1} pages, A4 {'landscape' if landscape else 'portrait'})")
    print(f"scale: 1 km = {mm:.0f} mm, so one layer is "
          f"{interval * scale / 2.8346457:.2f} mm tall at true scale")
    if a.card_mm:
        true_mm = interval * scale / 2.8346457
        print(f"with {a.card_mm:.1f} mm card the model is "
              f"{a.card_mm / true_mm:.1f}x vertically exaggerated")


if __name__ == "__main__":
    main()
