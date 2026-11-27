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
SIDE_FRACTION = 0.34           # the side's depth in the middle, as a fraction of the top's height
LEAN = 0.06                    # walls lean in at most this fraction of the width per side
CORNER = 0.035                 # radius of the rounded base corners, as a fraction of the width
BEVEL_PX = 9                   # bevel thickness in wu (painting px)
FACE_DARK = (81, 92, 188)      # his cracks and the shaded strip beside them: (2320,4150), (2300,4184)
PATCH = (134, 145, 242)        # the pale blue-violet blobs on his ledge top: (2170,3965)
TOP_BACK = (170, 176, 230)     # a step darker than the lit top: (2300,3926) and (2300,3554 neighbors)
SHADOW = (20, 18, 92)          # the darkest tone of his floor: median of its darkest 10% at canvas (200..3000, 5000..5100)
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

# The real ragged edge of his bevel: along his ledge (canvas x 1900..2900, y 3900..4450) the thickness of the band between the lit top and the face,
# column by column. Each stone takes its own stretch of that series (some read backwards), so the rim's nicks and drips are his, not invented.
_art = np.array(Image.open(work / "art-only-full.png").convert("RGB"))
_th = []
for _x in range(1900, 2900):
    _col = _art[3900:4450, _x].astype(int)
    _idx = np.nonzero(np.abs(_col - np.array(BEVEL)).sum(1) < 24)[0]
    if len(_idx) < 3:
        _th.append(np.nan); continue
    _runs = np.split(_idx, np.nonzero(np.diff(_idx) > 2)[0] + 1)
    _th.append(len(max(_runs, key=len)))
LEDGE = np.array(_th, float)
_ok = ~np.isnan(LEDGE)
LEDGE = np.interp(np.arange(len(LEDGE)), np.nonzero(_ok)[0], LEDGE[_ok])
LEDGE_MEDIAN = float(np.median(LEDGE))
del _art

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
    padx = int(0.08 * cov.shape[1])
    cov = np.pad(cov, ((0, 0), (padx, padx)))                     # room for the contact shadow, equal on both sides so the stone stays centered
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
    wu_px = 2.0 / s                                   # canvas px in one wu
    W_px = float(x_hi - x_lo + 1)
    rng = np.random.default_rng(1000 + n)

    def noise(sigmas, amps):
        """Irregular low-frequency noise along x, in units of 1: a few scales, seeded per stone, so no two edges look alike."""
        tot = np.zeros(ww)
        for sg, am in zip(sigmas, amps):
            v = ndi.gaussian_filter1d(rng.standard_normal(ww), sg)
            tot += am * v / (np.abs(v).max() + 1e-9)
        return tot

    cx = np.arange(ww, dtype=np.float32)
    on_cols = mb.any(axis=0)
    D = SIDE_FRACTION * top_h                         # the side's height in the middle
    flat = float(bot_y[cols].max())
    # The base: the top's front curve loosely (about half of it, the rest a flat line), dropped by D, with bumps at three scales. Not a parallel copy.
    base = 0.5 * bot_y + 0.5 * flat + D
    base = base + D * noise([0.16 * W_px, 0.05 * W_px, 0.018 * W_px], [0.10, 0.06, 0.035])
    base = np.maximum(base, bot_y + 0.55 * D)
    y_c = float(bot_y[cols[:12]].mean())              # where the top is widest: the walls start here
    # The walls drop nearly straight from the widest points (a lean of at most 6% of the width per side over their whole height).
    lean = LEAN * W_px
    Hn = max(hh, int(base[cols].max() + 0.25 * D) + 8)
    rows_y = np.arange(Hn, dtype=np.float32)[:, None]
    t = np.clip((rows_y - y_c) / max(1.0, float(base[cols].max()) - y_c), 0, 1)
    in_x = (cx[None, :] >= x_lo + lean * t) & (cx[None, :] <= x_hi - lean * t)
    below = (rows_y >= bot_y[None, :] - 6) & (rows_y <= base[None, :]) & on_cols[None, :]
    wall = (below & in_x)
    # Round the base corners like his pillars: an opening on the whole body (top + wall) with a small disk.
    mbf = np.zeros((Hn, ww), bool); mbf[:hh] = mb
    body = mbf.copy()
    body |= wall
    r = max(6, int(CORNER * W_px))
    dk = np.hypot(*np.mgrid[-r:r + 1, -r:r + 1]) <= r
    body = ndi.binary_opening(np.pad(body, r + 2), dk)[r + 2:-r - 2, r + 2:-r - 2]
    face_m = ndi.gaussian_filter((body & ~mbf).astype(np.float32), 1.2)
    # The bevel: a thin, roughly constant band along the top's front edge (8-12 painting px), ragged along its lower edge.
    off = int(rng.integers(0, max(1, len(LEDGE) - int(W_px)))) if W_px < len(LEDGE) else 0
    seg = LEDGE[off:off + int(W_px)] if W_px < len(LEDGE) else np.interp(np.linspace(0, len(LEDGE) - 1, int(W_px)), np.arange(len(LEDGE)), LEDGE)
    if n % 2:
        seg = seg[::-1]
    bev_series = np.zeros(ww); bev_series[x_lo:x_lo + len(seg)] = seg[:ww - x_lo]
    bev_series = 0.7 * ndi.gaussian_filter1d(bev_series, 0.03 * W_px) + 0.3 * LEDGE_MEDIAN * (bev_series > 0) * 0 + 0.3 * bev_series * 0.35 + 0.3 * LEDGE_MEDIAN * (bev_series > 0)
    bev_t = bev_series * (BEVEL_PX * wu_px / LEDGE_MEDIAN)
    bev_m = ((rows_y >= bot_y[None, :] - 6) & (rows_y <= (bot_y + bev_t)[None, :]) & on_cols[None, :] & in_x)
    bev_m = ndi.gaussian_filter(bev_m.astype(np.float32), 1.0) * (face_m > 0.05)
    H = Hn + 4
    yy = np.arange(H, dtype=np.float32)[:, None]

    def soft(m, sg=1.0):
        return ndi.gaussian_filter(m.astype(np.float32), sg)

    face = np.zeros((H, ww), np.float32); face[:Hn] = face_m
    bev = np.zeros((H, ww), np.float32); bev[:Hn] = bev_m
    topc = np.zeros((H, ww), np.float32); topc[:hh] = cov
    wall_f = (face > 0.5) & (bev < 0.5)
    # (b) The face: a step darker down its right side on every stone (light comes from the left), a boundary that leans and wobbles.
    xr_line = x_hi - (0.20 + 0.05 * rng.random()) * W_px + noise([0.05 * W_px, 0.02 * W_px], [0.025 * W_px, 0.012 * W_px]) + 0.05 * W_px * ((yy - y_c) / max(1.0, D)) * rng.uniform(0.3, 1.0)
    shade = soft(wall_f & (cx[None, :] >= xr_line))
    layers = [(SHADOW, None), (FACE, face), (FACE_DARK, np.clip(shade, 0, 1) * face)]
    if False:        # a darker band along the foot of the face, ragged
        band_h = 0.20 * D * (1 + noise([0.06 * W_px, 0.02 * W_px], [0.35, 0.2]))
        foot = soft(wall_f & (yy >= (base - band_h)[None, :]))
        layers.append((FACE_DARK, foot * face))
    # a crack: one slanted painted line with a soft round top, on some stones only; its place and slant differ per stone
    if False:
        frac = rng.uniform(0.28, 0.66); slant = rng.choice([-1, 1]) * rng.uniform(0.07, 0.17)
        xc0 = x_lo + frac * W_px
        ytop = float(np.interp(xc0, cx, bot_y)) + 1.4 * float(np.interp(xc0, cx, bev_t)) + 0.03 * D
        ybot = float(np.interp(xc0, cx, base)) + 4
        cw = 0.030 * W_px
        ts = np.linspace(0, 1, 24)
        px = xc0 + slant * (ts * (ybot - ytop)) + np.cumsum(rng.normal(0, 0.9, 24))
        py = ytop + ts * (ybot - ytop)
        dist = np.full((H, ww), 1e9, np.float32)
        gx = cx[None, :]
        for i in range(23):
            ax, ay, bx, by = px[i], py[i], px[i + 1], py[i + 1]
            vx, vy = bx - ax, by - ay
            tt = np.clip(((gx - ax) * vx + (yy - ay) * vy) / (vx * vx + vy * vy), 0, 1)
            dist = np.minimum(dist, np.hypot(gx - (ax + tt * vx), yy - (ay + tt * vy)))
        width = cw * (1 + 0.18 * np.sin(np.linspace(0, 5, 1)[0] + yy * 0))
        crack = np.clip(cw / 2 - dist + 0.5, 0, 1)
        layers.append((FACE_DARK, crack * face * (bev < 0.5)))
    layers += [(BEVEL, bev), (TOP, topc)]
    # (a) The top: a pale blue-violet patch, like the blobs on his ledge, on some stones; a slightly darker flat strip along the back edge on others.
    if False:
        bx = x_lo + rng.uniform(0.22, 0.45) * W_px; by = float(np.interp(bx, cx, top_y)) + rng.uniform(0.22, 0.36) * top_h
        ang = np.linspace(0, 2 * np.pi, 360, endpoint=False)
        rad = 1 + 0.22 * np.sin(3 * ang + rng.uniform(0, 6)) + 0.12 * np.sin(5 * ang + rng.uniform(0, 6)) + 0.07 * np.sin(8 * ang + rng.uniform(0, 6))
        rx, ry = rng.uniform(0.10, 0.16) * W_px, rng.uniform(0.06, 0.10) * top_h
        poly = np.stack([bx + rx * rad * np.cos(ang), by + ry * rad * np.sin(ang)], 1)
        pm = Image.new("L", (ww, H), 0)
        from PIL import ImageDraw
        ImageDraw.Draw(pm).polygon([tuple(p_) for p_ in poly], fill=255)
        patch = soft(np.array(pm) > 0, 1.2) * topc
        layers.append((PATCH, patch))
    if False:
        strip_h = (0.13 + 0.05 * rng.random()) * top_h * (1 + noise([0.07 * W_px, 0.025 * W_px], [0.30, 0.18]))
        top_pad = np.zeros(ww); top_pad[:] = top_y
        back = soft((yy <= (top_pad + strip_h)[None, :]) & on_cols[None, :]) * topc
        layers.append((TOP_BACK, back))
        # keep the pale patch (if any) above the strip's tone: patches were appended earlier, strips go before the top highlight only
    # (c) A flat contact shadow under the base, in the darkest floor tone: the base's own wobbly contour dropped a little, a bit further right than left.
    sd = 0.12 * D * (1 + noise([0.08 * W_px, 0.03 * W_px], [0.35, 0.2]))
    sh_base = base + sd
    shadow = soft((yy >= (base - 6)[None, :]) & (yy <= sh_base[None, :]) & (cx[None, :] >= x_lo + 0.07 * W_px) & (cx[None, :] <= x_hi - 0.06 * W_px)
                  & ~(face > 0.5), 1.2)
    layers[0] = (SHADOW, shadow * 0)   # the owner removed the contact shadow: nothing darker under the base
    img = Image.new("RGBA", (ww, H), (0, 0, 0, 0))
    for color, m in layers:
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
