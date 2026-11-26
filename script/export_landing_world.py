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
# 1b. The sky itself (layer 2, which also runs under the clifftop): opaque, faded out at both sides; the printed edge colors fill the
#     band past it (landing_world_sky.css).
SKY_Y0, SKY_Y1 = 1498, 2700   # the sky layer (2) under the hero swoosh down to the .how bottom
SKY_FADE = 200                # px each side that fade out; the band fills past them with an edge gradient
sky = layer_full(2).crop((0, SKY_Y0, W, SKY_Y1))
top = np.array(sky.getchannel("A"))[100:200, 800:2400] > 250  # a solid stretch, to take the flat top color from
rgb = np.array(sky.convert("RGB"))
top_color = tuple(int(v) for v in np.median(rgb[100:200, 800:2400][top], axis=0))
flat = Image.new("RGBA", sky.size, top_color + (255,))
flat.alpha_composite(sky)                                  # no transparent holes where the painted edge dips under the swoosh
base = np.array(flat)
ramp = np.linspace(0, 1, SKY_FADE)
smooth = ramp * ramp * (3 - 2 * ramp)
edge = np.ones(W, dtype=np.float32)
edge[:SKY_FADE], edge[-SKY_FADE:] = smooth, smooth[::-1]
fade = flat.copy()
fade.putalpha(Image.fromarray((np.tile(edge, (flat.height, 1)) * 255).astype(np.uint8)))
save("sky", "sky", fade)
# The band beyond 1576 px is filled with each edge's own colors, blurred so no brushwork streaks sideways.
for side, cols in (("left", base[:, :60]), ("right", base[:, -60:])):
    col = cols[:, :, :3].mean(axis=1)
    k = np.exp(-0.5 * (np.arange(-60, 61) / 20.0) ** 2)
    k /= k.sum()
    pad = np.pad(col, ((60, 60), (0, 0)), mode="edge")
    sm = np.stack([np.convolve(pad[:, c], k, mode="valid") for c in range(3)], axis=1)
    stops = ", ".join("#%02x%02x%02x %gwu" % (*(int(round(v)) for v in sm[y]), y / 2) for y in range(0, flat.height, 50))
    print("sky edge", side, stops)
print("sky top color", "#%02x%02x%02x" % top_color)

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
#    floor-to-sand seam. And the sand into the pale blue of the last section, flat at both ends (final band).
save("sand", "sand", art.crop((0, 5500, W, 7100)))
save("final", "shore", art.crop((0, 8250, W, 8900)))

# 7. Shells: layers 25 and 26.
for name, i in (("shell-1", 25), ("shell-2", 26)):
    layer = layer_full(i)
    save("sand", name, layer.crop(layer.getchannel("A").getbbox()))

print("flat colors: sky", art.getpixel((60, 2200))[:3], "teal", art.getpixel((60, 3300))[:3],
      "sand", art.getpixel((60, 7500))[:3], "blue", art.getpixel((60, 9500))[:3])
