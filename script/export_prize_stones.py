#!/usr/bin/env python3
"""Cut the prize stones out of Armand's painted pebble cells.

Run after script/export_landing_world.py (it writes the full-canvas layers this reads):

    uvx --python 3.12 --with pillow --with numpy --with scipy --with scikit-image python -I script/export_prize_stones.py [out_dir] [work_dir]

out_dir defaults to app/assets/images/landing/world/stones; work_dir to ~/.local/share/battletown-psd/out (layers/L20.png, the
pebble-cell layer: opaque light "gap" with transparent holes where the cells are; the floor tile is made from the same layer).

Each stone is ONE real cell. Its outline is the cell's own (turned about its middle so its long axis is level, shrunk uniformly, never
enlarged or mirrored), and it is the stone's TOP plane. The stone's side is built the way his ledges and pillars are painted (the lit top plane,
under its front edge a mid-tone bevel, under that the darker face), in three flat tones sampled from the painting (canvas px):
    top   #b2b7e6  (178,183,230) at (700,3860) and (1000,3752)   the lit ledge plane
    bevel #8891d5  (136,145,213) at (1000,4166) and (2300,4106)   the band between the plane and the wall
    face  #606ac3  (96,106,195)  at (1000,4190), (2300,4118) and (700,4466)   the shaded rock face
The side is not a copy of the top moved down. It exists only under the FRONT (lower) edge of the top: its depth is zero at the top's widest points,
grows to a flat-ish base in the middle, and wobbles a little along its length (slow sines with a per-stone phase), so the base contour is not the top's
lower contour moved. The bevel's thickness wobbles on its own and has one small bump. Nothing of the side shows above or behind the top.
No gradient, texture, shadow or outline: flat regions with his antialiased shape edge.

Sizes: 1 painting px = 1 world unit (--wu). Each cell is shrunk by the one factor that gives the top its target width (wu) below. Files:
<name>@a.webp is 1 px per wu, @b 1.3, @c 2 (the image-set convention of the world pieces); @c is at most the painting's own resolution. The
printed table gives each file's width, height and top-face height in wu for landing.css.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from skimage.measure import regionprops

args = [a for a in sys.argv[1:] if not a.startswith("--")]
out = Path(args[0]) if args else Path(__file__).resolve().parent.parent / "app/assets/images/landing/world/stones"
work = Path(args[1]) if len(args) > 1 else Path.home() / ".local/share/battletown-psd/out"
out.mkdir(parents=True, exist_ok=True)
Image.MAX_IMAGE_PIXELS = None

TOP, BEVEL, FACE = (178, 183, 230), (136, 145, 213), (96, 106, 195)
SIDE_FRACTION = 0.26           # the side's depth in the middle, as a fraction of the top's height
VARIANTS = {"a": 1.0, "b": 1.3, "c": 2.0}
# (name, cell bbox left, top in canvas px of layer 20, target width of the top in wu). Reading order of the nine prizes.
STONES = [
    ("stone-1", 656, 4263, 152),    # 579x632, turned level
    ("stone-2", 588, 5405, 172),    # 741x519
    ("stone-3", 1364, 5358, 172),   # 561x622, turned level
    ("stone-4", 2253, 6151, 150),   # 558x511
    ("stone-5", 2054, 6660, 166),   # 727x613
    ("stone-6", 960, 4629, 196),    # 1036x765
    ("stone-7", 1748, 4256, 178),   # 786x470
    ("stone-8", 1923, 4972, 156),   # 555x649, turned level
    ("stone-9", 1195, 6004, 150),   # 508x539, turned level
]

alpha = np.array(Image.open(work / "layers" / "L20.png").getchannel("A"))
labels, _ = ndi.label(alpha < 100)
props = {r.label: r for r in regionprops(labels)}
boxes = ndi.find_objects(labels)
cov_all = np.clip((140.0 - alpha.astype(np.float32)) / 80.0, 0, 1)  # the same pebble coverage the floor tile uses


def level(cov):
    """Turn the cell about its middle so its long axis is horizontal (the turn that makes it widest)."""
    best = None
    for ang in range(-90, 91, 6):
        r = ndi.rotate(cov, ang, reshape=True, order=1) > 0.5
        ys, xs = np.nonzero(r)
        ratio = (xs.max() - xs.min()) / (ys.max() - ys.min())
        if best is None or ratio > best[0]:
            best = (ratio, ang)
    for ang in range(best[1] - 6, best[1] + 7):
        r = ndi.rotate(cov, ang, reshape=True, order=1) > 0.5
        ys, xs = np.nonzero(r)
        ratio = (xs.max() - xs.min()) / (ys.max() - ys.min())
        if ratio > best[0]:
            best = (ratio, ang)
    return ndi.rotate(cov, best[1], reshape=True, order=1)


def band(h, w, y_lo, y_hi):
    """Float coverage of the rows between per-column y_lo and y_hi (sub-pixel at both ends), for columns where y_hi > y_lo."""
    y = np.arange(h, dtype=np.float32)[:, None]
    return np.clip(np.minimum(y + 1, y_hi[None, :]) - np.maximum(y, y_lo[None, :]), 0, 1)


print(f"{'stone':9s} {'wu wide':>8s} {'wu high':>8s} {'top face':>9s}   bytes@a/@b/@c")
for n, (name, x0, y0, target) in enumerate(STONES):
    idx = next(i for i, sl in enumerate(boxes, 1) if abs(sl[1].start - x0) <= 3 and abs(sl[0].start - y0) <= 3)
    sl = boxes[idx - 1]
    pad = 12
    ys_, xs_ = slice(max(0, sl[0].start - pad), sl[0].stop + pad), slice(max(0, sl[1].start - pad), sl[1].stop + pad)
    cell = ndi.binary_dilation(labels[ys_, xs_] == idx, iterations=3)
    disk = np.hypot(*np.mgrid[-16:17, -16:17]) <= 16
    cell = ndi.binary_closing(np.pad(cell, 20), disk)[20:-20, 20:-20]   # fills a speck-sized notch; a real bite is left (pick another cell)
    cov = cov_all[ys_, xs_] * cell + (cell & (cov_all[ys_, xs_] < 0.5)) * 1.0
    cov = level(cov)
    on = np.nonzero(cov.max(axis=0) > 0.5)[0]
    rows = np.nonzero(cov.max(axis=1) > 0.5)[0]
    cov = cov[max(0, rows[0] - 4):rows[-1] + 5, max(0, on[0] - 4):on[-1] + 5]
    hh, ww = cov.shape
    mb = cov > 0.5
    cols = np.nonzero(mb.any(axis=0))[0]
    top_y = np.where(mb.any(axis=0), mb.argmax(axis=0), 0).astype(np.float32)
    bot_y = np.where(mb.any(axis=0), hh - 1 - mb[::-1].argmax(axis=0) + 1, 0).astype(np.float32)   # first row below the cell
    x_lo, x_hi = cols[0], cols[-1]
    bot_y = np.where(mb.any(axis=0), ndi.median_filter(bot_y, size=25, mode="nearest"), 0)   # a hair on the outline must not become a spike in the side
    top_h = float((bot_y - top_y)[cols].max())
    s = target / ((x_hi - x_lo + 1) * 0.5)           # canvas px -> wu
    assert s <= 1.0, (name, s)
    u = (np.arange(ww, dtype=np.float32) - (x_lo + x_hi) / 2) / ((x_hi - x_lo) / 2)
    inside = (np.abs(u) < 1.0) & mb.any(axis=0)
    rng = np.random.default_rng(1000 + n)
    ph = rng.uniform(0, 2 * np.pi, 4)
    depth_prof = np.clip(1 - np.abs(u) ** 5, 0, 1)                       # zero at the widest points, a flat-ish plateau between
    depth_prof *= 1 + 0.07 * np.sin(2.4 * u * np.pi + ph[0]) + 0.03 * np.sin(5.3 * u * np.pi + ph[1])
    depth = np.where(inside, np.clip(depth_prof, 0, None), 0) * SIDE_FRACTION * top_h
    bev_prof = np.clip(1 - np.abs(u) ** 2, 0, 1) * (1 + 0.28 * np.sin(3.1 * u * np.pi + ph[2]) + 0.5 * np.exp(-((u - rng.uniform(-0.5, 0.5)) / 0.12) ** 2))
    bevel = np.where(inside, np.clip(bev_prof, 0, None), 0) * SIDE_FRACTION * top_h * 0.34
    bevel = np.minimum(bevel, depth * 0.7)
    out_h = int(np.ceil((bot_y + depth)[cols].max())) + 4
    H = max(hh, out_h)
    g = lambda a: ndi.gaussian_filter1d(a, 2.0)      # his edges are hand-drawn, not razor columns: soften the column steps
    y_top_hidden = bot_y - 6                          # the side starts under the top's own lower edge, so nothing of it shows above
    face = band(H, ww, y_top_hidden, g(bot_y + depth)) * inside[None, :]
    bev = band(H, ww, y_top_hidden, g(bot_y + bevel)) * inside[None, :]
    topc = np.zeros((H, ww), np.float32); topc[:hh] = cov
    img = Image.new("RGBA", (ww, H), FACE + (0,))
    for color, m in ((FACE, face), (BEVEL, bev), (TOP, topc)):
        layer = Image.new("RGBA", (ww, H), color + (255,))
        layer.putalpha(Image.fromarray((np.clip(m, 0, 1) * 255).astype(np.uint8)))
        img = Image.alpha_composite(img, layer)
    sizes = []
    for key, dens in VARIANTS.items():
        k = s * 0.5 * dens
        size = (max(1, round(img.width * k)), max(1, round(img.height * k)))
        im = img.resize(size, Image.LANCZOS)
        path = out / f"{name}@{key}.webp"
        im.save(path, "WEBP", quality=82, method=6, alpha_quality=90)
        sizes.append(path.stat().st_size)
    if "--sil" in sys.argv:   # the outline of top + side in one color, to check the side is not a second copy of the top moved down
        Image.fromarray((np.maximum(topc, np.maximum(face, bev)) * 255).astype(np.uint8)).save(work / f"sil-{name}.png")
    print(f"{name:9s} {img.width * s * 0.5:8.1f} {img.height * s * 0.5:8.1f} {top_h * s * 0.5:9.1f}   {'/'.join(map(str, sizes))}")
