#!/usr/bin/env python3
"""Cut the painted world behind the landing page out of Armand's PSD.

Run it again whenever the painting changes:

    uvx --python 3.12 --with psd-tools --with pillow --with numpy \
      python -I script/export_landing_world.py ~/Downloads/<the>.psd [out_dir]

out_dir defaults to app/assets/images/landing/world (one folder per band: sky, cliff, cave, floor, sand, final).
It also writes the whole painting for people who cut their own pieces, into work_dir (default
~/.local/share/battletown-psd/out): art-only-full.png (3152x9898, overlay hidden), art-only-1576.jpg (the same at
1576 px wide), art-clean-full.png (also without the path and the shells, which are pieces of their own) and
layers/LNN.png (every art layer as a full-canvas RGBA). The PSD is a 2x screenshot of the landing page at 1576 CSS px
wide (3152 px) with the world painted under the page. Layers 31 (signpost), 34 (the page's UI screenshot) and 35/36
(the FAQ boxes) are overlay: the live HTML draws those, so they are hidden here. Layers 0/1/2 hold the hero as a
flat screenshot; the hero is live too, and nothing above y=1498 is exported.

Each piece is written in three sizes, named <piece>@a, @b and @c: 1.0, 1.3 and 2.0 image px per art CSS px (the art
is 1576 CSS px wide, so @c is the canvas itself, @a half of it). landing_world.css picks one with image-set().
Coordinates below are PSD canvas pixels.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from psd_tools import PSDImage

psd_path = sys.argv[1]
out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / "app/assets/images/landing/world"
work = Path(sys.argv[3]) if len(sys.argv) > 3 else Path.home() / ".local/share/battletown-psd/out"
out.mkdir(parents=True, exist_ok=True)
(work / "layers").mkdir(parents=True, exist_ok=True)

W = 3152
VARIANTS = {"a": 0.5, "b": 0.65, "c": 1.0}  # fraction of the canvas size
OVERLAY = {31, 34, 35, 36}
SHELLS = {25, 26}
PATH = {30}

psd = PSDImage.open(psd_path)
layers = list(psd)


def render(hide):
    ids = {id(layers[i]): i for i in range(len(layers))}

    def keep(layer):
        i = ids.get(id(layer))
        if i is not None and i in hide:
            return False
        return layer.visible

    return psd.composite(layer_filter=keep, force=True).convert("RGBA")


def save(band, name, img):
    (out / band).mkdir(exist_ok=True)
    for key, scale in VARIANTS.items():
        size = (max(1, round(img.width * scale)), max(1, round(img.height * scale)))
        im = img if scale == 1.0 else img.resize(size, Image.LANCZOS)
        path = out / band / f"{name}@{key}.webp"
        im.save(path, "WEBP", quality=80, method=6, alpha_quality=90)
        print(f"{path.name:28s} {im.width:5d}x{im.height:<5d} {path.stat().st_size:8d} bytes")


def layer_full(i):
    """A layer as a full-canvas RGBA image."""
    im = layers[i].topil()
    canvas = Image.new("RGBA", (W, psd.height), (0, 0, 0, 0))
    canvas.paste(im, layers[i].offset)
    return canvas


full = render(OVERLAY)
full.save(work / "art-only-full.png")
full.convert("RGB").resize((1576, round(psd.height / 2)), Image.LANCZOS).save(work / "art-only-1576.jpg", quality=88)
for i, layer in enumerate(layers):
    if i not in OVERLAY and layer.visible and layer.topil() is not None:
        layer_full(i).save(work / "layers" / f"L{i:02d}.png")
art = render(OVERLAY | SHELLS | PATH)  # the painting alone; the path and the shells are separate pieces
art.save(work / "art-clean-full.png")

# 1. Cloud (layer 32; layer 33 is the same cloud, so one file serves both): sky band.
layer = layer_full(32)
save("sky", "cloud", layer.crop(layer.getchannel("A").getbbox()))

# 2. Cliff (cliff band): the clifftop with its crack, the cliff face and its shadow, down to a flat teal bottom row
#    (CLIFF_Y1, the lower ground). Above the clifftop it is transparent: the sky band paints the sky, haze included.
#    Left and right of the painting, the clifftop and face are continued by warping the edge columns: each painted edge keeps its own slope, which dies away, so nothing is stretched into streaks (the last 8 px column,
#    stretched, is then truly flat).
CLIFF_Y0, CLIFF_Y1 = 2250, 3150
EXT_W = 1000  # canvas px of continued art on each side (500 CSS px, enough for a 2560 px window)
TEAL = np.array([0x11, 0xBC, 0xB3], float)
face = np.array(layer_full(29).getchannel("A"))[CLIFF_Y0:CLIFF_Y1]
alpha = face.copy()
for x in range(W):
    rows = np.nonzero(face[:, x] > 8)[0]
    if len(rows):
        alpha[rows[-1]:, x] = 255
    else:
        alpha[:, x] = 0
cliff_rgb = np.array(art.crop((0, CLIFF_Y0, W, CLIFF_Y1)).convert("RGB"), float)
H = CLIFF_Y1 - CLIFF_Y0
a_f = alpha / 255.0
out_a = a_f
out_rgb = cliff_rgb
# a flat teal floor under the shadow, so the last rows match the section color exactly
below = np.cumsum(np.abs(cliff_rgb - TEAL).sum(axis=2)[::-1] > 10, axis=0)[::-1] == 0
for x in range(W):
    col = np.nonzero(~below[:, x])[0]
    if len(col):
        out_rgb[col[-1] + 1:, x] = TEAL
cliff_img = Image.fromarray(np.dstack([out_rgb, out_a * 255]).round().clip(0, 255).astype(np.uint8), "RGBA")
save("cliff", "cliff", cliff_img)


def edge_landmarks(col_rgb, col_a):
    """Rows of the painted edges in one column: top of the clifftop, start of the face, end of the face, start of the flat teal."""
    top = int(np.nonzero(col_a > 128)[0][0])
    teal_top = np.array([0x67, 0xE9, 0xD7], float)
    d_top = np.abs(col_rgb - teal_top).sum(axis=1)
    f1 = top + int(np.nonzero(d_top[top:] > 60)[0][0])
    d_flat = np.abs(col_rgb - TEAL).sum(axis=1)
    f3 = int(np.nonzero(d_flat < 14)[0][np.nonzero(np.nonzero(d_flat < 14)[0] > f1 + 50)[0][0]])
    shade = np.abs(col_rgb - np.array([0x08, 0x98, 0xA7], float)).sum(axis=1)
    f2 = f1 + int(np.nonzero(np.abs(col_rgb[f1:f3] - np.array([0x08, 0x98, 0xA7], float)).sum(axis=1) < 30)[0][0]) if (shade[f1:f3] < 30).any() else f3 - 30
    return np.array([top, f1, f2, f3], float)


def continue_edge(side):
    """EXT_W columns of art continuing the painting past its left or right edge; column 0 is the one next to the art."""
    cols = range(0, 8) if side == "l" else range(W - 8, W)
    far = range(300, 308) if side == "l" else range(W - 308, W - 300)
    near_rgb = cliff_rgb[:, list(cols)].mean(axis=1)
    near_a = out_a[:, list(cols)].mean(axis=1) * 255
    near = edge_landmarks(near_rgb, near_a)
    far_lm = edge_landmarks(cliff_rgb[:, list(far)].mean(axis=1), out_a[:, list(far)].mean(axis=1) * 255)
    slope = (near - far_lm) / 300.0  # px per px going outward (positive = lower)
    tau = 260.0
    col4 = np.concatenate([near_rgb * (near_a[:, None] / 255), near_a[:, None]], axis=1)
    out_cols = np.zeros((H, EXT_W, 4))
    yy = np.arange(H, dtype=float)
    for k in range(EXT_W):
        delta = slope * tau * (1 - np.exp(-k / tau))
        dst = near + delta
        xp = np.concatenate([[-1e4], dst, [1e4]])
        fp = np.concatenate([[-1e4 - delta[0]], near, [1e4 - delta[-1]]])
        src = np.interp(yy, xp, fp)
        for c in range(4):
            out_cols[:, k, c] = np.interp(src, yy, col4[:, c])
    a = out_cols[:, :, 3:4]
    rgb = np.where(a > 0.5, out_cols[:, :, :3] / np.maximum(a / 255.0, 1e-3), 0)
    img = np.concatenate([rgb, a], axis=2).round().clip(0, 255).astype(np.uint8)
    img = Image.fromarray(img, "RGBA")
    return img if side == "r" else img.transpose(Image.FLIP_LEFT_RIGHT)


# "l" is built from the left edge outward then flipped, so its right edge touches the painting; "r" starts at the painting
for side in ("l", "r"):
    ext = continue_edge(side)
    save("cliff", f"cliff-ext-{side}", ext)
    last = ext.crop((0, 0, 8, H)) if side == "l" else ext.crop((EXT_W - 8, 0, EXT_W, H))
    save("cliff", f"cliff-fill-{side}", last)

# 3. Path: layer 30, one piece (cliff band). Its top end is the pole foot's spot: canvas (1576, 2566).
PATH_X0, PATH_Y0, PATH_X1, PATH_Y1 = 1340, 2556, 1640, 3436
path = layer_full(30).crop((PATH_X0, PATH_Y0, PATH_X1, PATH_Y1))
save("cliff", "path", path)

# 4. Cave: the rim and the wall with its pillars, down to the floor line. Opaque (the cave band can mask above the rim).
CAVE_Y0, CAVE_Y1 = 3080, 4750
cave = art.crop((0, CAVE_Y0, W, CAVE_Y1))
save("cave", "cave", cave)
save("cave", "cave-edge-l", cave.crop((0, 0, 16, cave.height)))
save("cave", "cave-edge-r", cave.crop((W - 16, 0, W, cave.height)))

# 5. Floor: the pebbled floor under the wall, from a little above the wall's foot (the floor band owns that seam).
save("floor", "floor", art.crop((0, 4650, W, 5600)))

# 6. Sand: the end of the floor, the wavy shore and the sand down to where it is flat. Opaque. The sand band owns the
#    floor-to-sand seam. And the sand into the pale blue of the last section, flat at both ends (final band).
save("sand", "sand", art.crop((0, 5500, W, 7100)))
save("final", "shore", art.crop((0, 8250, W, 8900)))

# 7. Shells: layers 25 and 26.
for name, i in (("shell-1", 25), ("shell-2", 26)):
    layer = layer_full(i)
    save("sand", name, layer.crop(layer.getchannel("A").getbbox()))

print("flat colors: sky", art.getpixel((60, 2200))[:3], "teal", art.getpixel((60, 3300))[:3],
      "sand", art.getpixel((60, 7500))[:3], "blue", art.getpixel((60, 9500))[:3])
