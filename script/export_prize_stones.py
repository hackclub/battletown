#!/usr/bin/env python3
"""Cut the prize stones out of Armand's painted pebble cells.

Run after script/export_landing_world.py (it writes the full-canvas layers this reads):

    uvx --python 3.12 --with pillow --with numpy --with scipy python -I script/export_prize_stones.py [out_dir] [work_dir]

out_dir defaults to app/assets/images/landing/world/stones; work_dir to ~/.local/share/battletown-psd/out (layers/L20.png, the
pebble-cell layer: opaque light "gap" with transparent holes where the cells are; the floor tile is made from the same layer).

Each stone is ONE real cell, cut with its own outline (nothing is drawn, no ellipse), in two flat tones sampled from the painting: the
lit lavender of his stepping-stone tops (#b2b7e6, painted at canvas (1600,3880)) for the top, and the same shape moved down a little in the
mid violet of his cliff's shaded rock (#515ab3, canvas (1600,3560)) for the side, so it reads as a pebble raised slightly out of the floor.
No gradient, shadow or outline. Uniform shrink only (never enlarged, never mirrored); each cell is used once.

Sizes: 1 painting px = 1 world unit (--wu). A cell is 250-500 wu wide in the painting, bigger than a prize wants, so each is shrunk by the one
factor given in STONES (target width, wu). Files: <name>@a.webp is 1 px per wu, @b 1.3, @c 2 (the image-set convention of the world pieces);
@c is canvas px times the shrink, so never above the painting's own resolution. The printed table gives each file's width, height and top
face height in wu for landing.css.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "app/assets/images/landing/world/stones"
work = Path(sys.argv[2]) if len(sys.argv) > 2 else Path.home() / ".local/share/battletown-psd/out"
out.mkdir(parents=True, exist_ok=True)
Image.MAX_IMAGE_PIXELS = None

TOP, SIDE = (178, 183, 230), (81, 90, 179)
CLOSE = 22                     # canvas px
LIFT = 13                      # wu the side shows below the top face
SHRINK = 0.68                  # all targets below are multiplied by this (five stones fit across the content column)
VARIANTS = {"a": 1.0, "b": 1.3, "c": 2.0}
# (name, bbox left, bbox top of the cell in canvas px of layer 20, target width in wu). Reading order of the nine prizes.
STONES = [
    ("stone-1", 1195, 6004, 204),   # 508x539 canvas px
    ("stone-2", 588, 5405, 238),    # 741x519
    ("stone-3", 450, 6426, 262),    # 979x636
    ("stone-4", 418, 5940, 232),    # 733x496
    ("stone-5", 2054, 6660, 236),   # 727x613
    ("stone-6", 960, 4629, 296),    # 1036x765
    ("stone-7", 1748, 4256, 246),   # 786x470
    ("stone-8", 2253, 6151, 206),   # 558x511
    ("stone-9", 1364, 5358, 208),   # 561x622
]

alpha = np.array(Image.open(work / "layers" / "L20.png").getchannel("A"))
labels, _ = ndi.label(alpha < 100)
boxes = ndi.find_objects(labels)
cov_all = np.clip((140.0 - alpha.astype(np.float32)) / 80.0, 0, 1)  # the same pebble coverage the floor tile uses

print(f"{'stone':9s} {'wu wide':>8s} {'wu high':>8s} {'top face':>9s}   bytes@a/@b/@c")
for name, x0, y0, target in STONES:
    idx = next(i for i, sl in enumerate(boxes, 1) if abs(sl[1].start - x0) <= 3 and abs(sl[0].start - y0) <= 3)
    sl = boxes[idx - 1]
    comp = labels[sl] == idx
    pad = 4
    ys, xs = slice(max(0, sl[0].start - pad), sl[0].stop + pad), slice(max(0, sl[1].start - pad), sl[1].stop + pad)
    comp = ndi.binary_dilation(labels[ys, xs] == idx, iterations=3)
    # A neighbor cell's bite out of the outline, narrower than 2 x CLOSE canvas px, is filled; the cell's own outline is otherwise untouched.
    disk = np.hypot(*np.mgrid[-CLOSE:CLOSE + 1, -CLOSE:CLOSE + 1]) <= CLOSE
    comp = ndi.binary_closing(np.pad(comp, CLOSE + 2), disk)[CLOSE + 2:-CLOSE - 2, CLOSE + 2:-CLOSE - 2]
    cov = cov_all[ys, xs] * comp
    h, w = cov.shape
    s = target * SHRINK / (w * 0.5)                       # canvas px -> wu, shrunk
    assert s <= 1.0, (name, s)
    lift_px = round(LIFT * 2 / s)                # the side's lift in canvas px at this stone's shrink (1 wu = 2 / s canvas px)
    top = np.zeros((h + lift_px, w), np.float32); top[:h] = cov
    side = np.zeros_like(top); side[lift_px:] = cov
    img = Image.new("RGBA", top.shape[::-1], SIDE + (0,))
    side_im = Image.new("RGBA", top.shape[::-1], SIDE + (255,)); side_im.putalpha(Image.fromarray((side * 255).astype(np.uint8)))
    top_im = Image.new("RGBA", top.shape[::-1], TOP + (255,)); top_im.putalpha(Image.fromarray((top * 255).astype(np.uint8)))
    img = Image.alpha_composite(img, side_im)
    img = Image.alpha_composite(img, top_im)
    sizes = []
    for key, dens in VARIANTS.items():
        k = s * 0.5 * dens
        size = (max(1, round(img.width * k)), max(1, round(img.height * k)))
        im = img.resize(size, Image.LANCZOS)
        path = out / f"{name}@{key}.webp"
        im.save(path, "WEBP", quality=82, method=6, alpha_quality=90)
        sizes.append(path.stat().st_size)
    wu_w = img.width * s * 0.5
    wu_h = img.height * s * 0.5
    print(f"{name:9s} {wu_w:8.1f} {wu_h:8.1f} {wu_h - LIFT:9.1f}   {'/'.join(map(str, sizes))}")
