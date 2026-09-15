#!/usr/bin/env python3
"""ui-measure.py — pixel measurements off a window screenshot.

Turns "is the icon centred / is the padding balanced" into numbers. Captures
are Retina, so **2 device px = 1 point**; every command reports both.

    ui-measure.py box    <png> X0 X1 Y0 Y1    # ink bounding box in a region
    ui-measure.py runs   <png> X0 X1 Y0 Y1    # control runs + the gaps between
    ui-measure.py weight <png> X0 X1 Y0 Y1    # ink / spread / solidity of strokes
    ui-measure.py rows   <png> X Y0 Y1        # colour transitions down a column

No numpy/Pillow on this machine's pythons — run it through uv:
`uv run --with numpy --with pillow ui-measure.py …`

Coordinates are device pixels in the PNG. Region args are inclusive-exclusive.

`box` is the workhorse: it reports the tight bounding box of "ink" (dark on
light, light on dark — pass --dark) plus its centre, which is what you compare
against a control's centre to prove an icon is or is not centred.

`runs` finds horizontal spans of control-fill colour and prints the gaps
between them — the way to check that button spacing is even without eyeballing.

`rows` dumps where colours change down a single column: use it to find a
field's bezel and focus-ring boundaries before measuring anything inside it.
"""
import sys

import numpy as np
from PIL import Image


def load(path):
    return np.array(Image.open(path).convert("RGB")).astype(int)


def ink_mask(sub, dark_mode=False):
    """Ink = clearly darker (light mode) or lighter (dark mode) than the local
    background, with blue-dominant pixels excluded so a focus ring or text
    caret is never mistaken for glyph ink."""
    lum = sub.mean(axis=2)
    bg = np.median(lum)
    not_blue = (sub[:, :, 2] - sub[:, :, 0]) < 40
    return ((lum > bg + 30) if dark_mode else (lum < bg - 30)) & not_blue


def cmd_box(png, x0, x1, y0, y1, dark_mode=False):
    a = load(png)
    m = ink_mask(a[y0:y1, x0:x1], dark_mode)
    if not m.any():
        print("no ink found in region")
        return
    rs, cs = np.where(m.any(axis=1))[0], np.where(m.any(axis=0))[0]
    top, bot, left, right = rs.min() + y0, rs.max() + y0, cs.min() + x0, cs.max() + x0
    print(f"x {left}..{right} ({(right - left + 1) / 2:.2f} pt wide)")
    print(f"y {top}..{bot} ({(bot - top + 1) / 2:.2f} pt tall)")
    print(f"centre x={(left + right) / 2:.1f} y={(top + bot) / 2:.1f} (device px)")


def cmd_runs(png, x0, x1, y0, y1):
    a = load(png)
    sub = a[y0:y1, x0:x1]
    # Control fill: mid greys, plus anything strongly blue (a checked checkbox).
    fill = (((sub[:, :, 0] > 215) & (sub[:, :, 0] < 242)) |
            ((sub[:, :, 2] - sub[:, :, 0]) > 60)).sum(axis=0)
    runs, start = [], None
    for i, v in enumerate(fill):
        on = v > 15
        if on and start is None:
            start = i
        if not on and start is not None:
            runs.append((start + x0, i - 1 + x0))
            start = None
    if start is not None:
        runs.append((start + x0, len(fill) - 1 + x0))
    runs = [r for r in runs if r[1] - r[0] > 3]
    print("runs:", runs)
    for i in range(len(runs) - 1):
        gap = runs[i + 1][0] - runs[i][1] - 1
        print(f"  gap {runs[i][1]}..{runs[i + 1][0]} = {gap} px = {gap / 2:.1f} pt")


def cmd_weight(png, x0, x1, y0, y1, dark_mode=False):
    """Stroke weight/sharpness of the ink in a region, for comparing two
    captures of the same drawing (Edit vs Read, before vs after a fix).

    A bitmap blitted to a fractional device offset, or scaled by something that
    isn't exactly its pixel:point ratio, gets resampled: the *ink* is conserved
    but it spreads over more pixels at lower coverage, which reads as bolder and
    softer. So `ink` staying put while `inked` grows and `solid` collapses is the
    signature of a resample — not of a genuinely heavier glyph.
    """
    a = load(png)
    sub = a[y0:y1, x0:x1]
    lum = sub.mean(axis=2)
    bg = np.median(lum)
    # Coverage: 0 at the local background, 1 at full ink. Direction-aware so the
    # same numbers mean the same thing in dark mode.
    cov = (lum - bg) / (255 - bg) if dark_mode else (bg - lum) / bg
    cov = np.clip(cov, 0, 1)
    inked = cov > 0.06          # anything the eye can see at all
    n = int(inked.sum())
    if n == 0:
        print("no ink found in region")
        return
    # "Solid" is relative to the darkest ink actually present, not to black: Read
    # mode draws math in #1a1a1a, so an absolute threshold reports 0 solid pixels
    # for a perfectly crisp bitmap and the two modes stop being comparable.
    full = np.percentile(cov[inked], 99)
    solid = cov > full * 0.9
    print(f"ink    {cov.sum():8.1f}   (sum of coverage — conserved by a resample)")
    print(f"inked  {n:8d}   device px carrying any ink")
    print(f"solid  {int(solid.sum()):8d}   px at >90% of this region's own max ink "
          f"({solid.sum() / n * 100:.0f}% of inked)")
    print(f"mean   {cov[inked].mean():8.3f}   coverage per inked px (max here {full:.3f})")


def cmd_rows(png, x, y0, y1):
    a = load(png)
    prev = None
    for y in range(y0, y1):
        cur = tuple(a[y, x])
        if cur != prev:
            print(y, cur)
            prev = cur


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 64
    cmd, png, rest = argv[0], argv[1], [int(v) for v in argv[2:] if v != "--dark"]
    dark = "--dark" in argv
    if cmd == "box":
        cmd_box(png, *rest[:4], dark_mode=dark)
    elif cmd == "runs":
        cmd_runs(png, *rest[:4])
    elif cmd == "weight":
        cmd_weight(png, *rest[:4], dark_mode=dark)
    elif cmd == "rows":
        cmd_rows(png, *rest[:3])
    else:
        print(__doc__)
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
