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


def save(band, name, img, quality=80):
    (out / band).mkdir(exist_ok=True)
    for key, scale in VARIANTS.items():
        size = (max(1, round(img.width * scale)), max(1, round(img.height * scale)))
        im = img if scale == 1.0 else img.resize(size, Image.LANCZOS)
        path = out / band / f"{name}@{key}.webp"
        im.save(path, "WEBP", quality=quality, method=6, alpha_quality=min(90, quality))
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

# 2. Cliff: the clifftop, its crack and its face (layer 29 is the transparent cut), and the shadow and flat lower teal
#    under the face down to CLIFF_Y1. Everything below the face is opaque.
CLIFF_Y0, CLIFF_Y1 = 2290, 3100
face = np.array(layer_full(29).getchannel("A"))[CLIFF_Y0:CLIFF_Y1]
alpha = face.copy()
for x in range(W):
    rows = np.nonzero(face[:, x] > 8)[0]
    if len(rows):
        alpha[rows[-1]:, x] = 255
    else:
        alpha[:, x] = 0
band = art.crop((0, CLIFF_Y0, W, CLIFF_Y1))
band.putalpha(Image.fromarray(alpha))
save("cliff", "cliff", band)
save("cliff", "cliff-edge-l", band.crop((0, 0, 16, band.height)))
save("cliff", "cliff-edge-r", band.crop((W - 16, 0, W, band.height)))

# 3. Path: layer 30, one piece (cliff band).
PATH_X0, PATH_X1, PATH_Y0, PATH_Y1 = 1330, 1650, 2540, 3440
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
#    floor-to-sand seam. (The sand-to-blue shore of the final band is a CSS clip, not a piece: see landing_world_final.css.)
save("sand", "sand", art.crop((0, 5500, W, 7100)))

# 7. Shells: layers 25 and 26.
for name, i in (("shell-1", 25), ("shell-2", 26)):
    layer = layer_full(i)
    save("sand", name, layer.crop(layer.getchannel("A").getbbox()))

# 6b. Final: the island's underside. The last section is the island's edge over open sky. The painting has no plain face the
#     width of the page, so the underside is two real stretches of the cliff face (the gray face and its dark top lip, found
#     by color), joined where the painting itself has a step: LEFT (canvas x 0..1245, tilted about 10 degrees, turned level)
#     and RIGHT (canvas x 1950..3151, level), both scaled by the same factor so the strip is exactly W wide, then the whole
#     strip is turned 1.65 degrees to follow the shore's tilt (low at the left, high at the right). Transparent everywhere else.
FACE_Y0, FACE_Y1 = 2350, 3100


def face_pixels(art_rgb):
    region = np.asarray(art_rgb.crop((0, FACE_Y0, W, FACE_Y1))).astype(int)
    near = lambda c, t: np.abs(region - np.array(c)).sum(axis=2) < t
    mask = near((0x97, 0x93, 0xAA), 70) | near((0x63, 0x5C, 0x86), 90) | (
        (region[:, :, 2] > region[:, :, 1] + 15) & (region[:, :, 0] < 190) & (region[:, :, 1] < 175))
    for x in range(W):  # keep each column's longest run (drops the floating shard above the face and the stray flecks)
        col = mask[:, x]
        idx = np.nonzero(col)[0]
        if not len(idx):
            continue
        runs = np.split(idx, np.nonzero(np.diff(idx) > 1)[0] + 1)
        best = max(runs, key=len)
        keep = np.zeros_like(col)
        keep[best] = True
        mask[:, x] = keep
    rgba = np.zeros(region.shape[:2] + (4,), np.uint8)
    rgba[:, :, :3] = region
    rgba[:, :, 3] = mask * 255
    return Image.fromarray(rgba)


def island_strip(art_rgb, left_w=1090, right_x=1950, tilt_left=10.2, tilt_all=1.65, edge_t=105, mid_t=165, overlap=220, fade=0.55):
    face = face_pixels(art_rgb)
    left = face.crop((0, 0, left_w, face.height)).rotate(-tilt_left, resample=Image.BICUBIC, expand=True)
    right = face.crop((right_x, 0, W, face.height))
    parts, tops = [], []
    for i, part in enumerate((left, right)):
        alpha = np.array(part.getchannel("A")) > 8
        cols = np.nonzero(alpha.any(axis=0))[0]
        x0 = cols[0] + (45 if i == 0 else 0)  # the turned stretch's slanted end is trimmed to a vertical edge
        part = part.crop((x0, 0, cols[-1] + 1, part.height))
        alpha = np.array(part.getchannel("A")) > 8
        top = np.array([np.nonzero(alpha[:, x])[0][0] if alpha[:, x].any() else 0 for x in range(part.width)])
        rows = np.nonzero(alpha.any(axis=1))[0]
        part = part.crop((0, rows[0], part.width, rows[-1] + 1))
        tops.append(int(np.median(top - rows[0])))
        parts.append(part)
    # scale so that the two stretches, overlapping by `overlap` output px, span exactly W
    scale = (W + overlap) / sum(p.width for p in parts)
    ph = [round(p.height * scale) for p in parts]
    strip = Image.new("RGBA", (W, max(ph) + 120), (0, 0, 0, 0))
    scaled = [p.resize((round(p.width * scale), h), Image.LANCZOS) for p, h in zip(parts, ph)]
    t_out = [round(t * scale) for t in tops]
    y_ref = 60
    left_img, right_img = scaled
    # the right stretch fades in over the overlap, so the join is a short cross-fade of two similar grays
    xr = left_img.width - overlap
    strip.alpha_composite(left_img, (0, y_ref - t_out[0]))
    ramp = np.ones((right_img.height, right_img.width), float)
    for x in range(overlap):
        ramp[:, x] = x / overlap
    ra = np.array(right_img.getchannel("A")).astype(float) * ramp
    right_img = right_img.copy()
    right_img.putalpha(Image.fromarray(ra.astype(np.uint8)))
    strip.alpha_composite(right_img, (xr, y_ref - t_out[1]))
    # the underside bulges: thickness runs from edge_t at the ends to mid_t in the middle, measured down from the top lip
    a = np.array(strip.getchannel("A")).astype(float)
    for x in range(W):
        col = a[:, x]
        idx = np.nonzero(col > 8)[0]
        if not len(idx):
            continue
        t = edge_t + (mid_t - edge_t) * np.sin(np.pi * x / (W - 1)) ** 1.5
        cut = idx[0] + t
        for y in range(int(cut), a.shape[0]):
            col[y] = 0 if y > cut + 1 else col[y] * max(0.0, cut + 1 - y)
        # the lower part of the face fades out into the sky, so the bottom is never a straight cut
        f0 = idx[0] + t * (1 - fade)
        for y in range(int(f0), int(cut) + 1):
            col[y] *= max(0.0, 1 - max(0.0, (y - f0) / (cut - f0)) ** 1.3)
        a[:, x] = col
    strip.putalpha(Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)))
    strip = strip.rotate(tilt_all, resample=Image.BICUBIC, expand=True)
    bbox = strip.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    return strip.crop(bbox), scale

_strip, _scale = island_strip(art)
save("final", "island", _strip, quality=60)

print("flat colors: sky", art.getpixel((60, 2200))[:3], "teal", art.getpixel((60, 3300))[:3],
      "sand", art.getpixel((60, 7500))[:3], "blue", art.getpixel((60, 9500))[:3])
