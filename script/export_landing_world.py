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
from PIL import Image, ImageFilter
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


def save(band, name, img, keys=None):
    (out / band).mkdir(exist_ok=True)
    for key, scale in VARIANTS.items():
        if keys and key not in keys:
            continue
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
# 1b. The sky itself (layer 2, which also runs under the clifftop): opaque, full width. Wider windows scale the whole painting up
#     (landing_world.css), so nothing continues past its edges.
SKY_Y0, SKY_Y1 = 1498, 2700   # from under the hero swoosh down to the .how bottom
sky = layer_full(2).crop((0, SKY_Y0, W, SKY_Y1))
top = np.array(sky.getchannel("A"))[100:200, 800:2400] > 250  # a solid stretch, to take the flat top color from
rgb = np.array(sky.convert("RGB"))
top_color = tuple(int(v) for v in np.median(rgb[100:200, 800:2400][top], axis=0))
flat = Image.new("RGBA", sky.size, top_color + (255,))
flat.alpha_composite(sky)                                  # no transparent holes where the painted edge dips under the swoosh
save("sky", "sky", flat)

# 2. Cliff (cliff band): the clifftop with its crack, the cliff face and its shadow, down to a flat teal bottom row
#    (CLIFF_Y1, the lower ground). Above the clifftop it is transparent: the sky band paints the sky, haze included.
CLIFF_Y0, CLIFF_Y1 = 2250, 3150
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


# 3. Path: layer 30, one piece (cliff band). Its top end is the pole foot's spot: canvas (1576, 2566).
PATH_X0, PATH_Y0, PATH_X1, PATH_Y1 = 1340, 2556, 1640, 3436
path = layer_full(30).crop((PATH_X0, PATH_Y0, PATH_X1, PATH_Y1))
save("cliff", "path", path)

# 4. Cave: the rim and the wall with its pillars, cut from the art layers themselves (7 dark band, 8 gray rim stripe,
#    10 brushed dark edge, 13 wall, 15/16/22 crack and pillar shadow) with real transparency above the rim: the teal
#    ground (layer 9) is left out, and the piece is cut away wherever layer 9 is opaque, so the cliff band's teal shows
#    through. Canvas y CAVE_Y0..CAVE_Y1, CAVE_Y1 = the bottom of the .fight section. The floor band covers the last
#    350 design px. The art's outermost 12 px hold a dark sliver, painted over from the next column.
CAVE_Y0, CAVE_Y1 = 3080, 4750
wall = Image.new("RGBA", (W, psd.height), (0, 0, 0, 0))
for i in (7, 8, 10, 13, 15, 16, 22):
    wall.alpha_composite(layer_full(i))
wall = np.array(wall.crop((0, CAVE_Y0, W, CAVE_Y1))).astype(np.float64)
teal = np.array(layer_full(9).getchannel("A").crop((0, CAVE_Y0, W, CAVE_Y1))).astype(np.float64) / 255
alpha = wall[:, :, 3] / 255 * (1 - teal)
pm = np.dstack([wall[:, :, :3] / 255 * alpha[:, :, None], alpha])  # premultiplied RGBA, 0..1
pm[:, :12] = pm[:, 12:13]
pm[:, W - 12:] = pm[:, W - 13:W - 12]
out_rgb = np.divide(pm[:, :, :3], pm[:, :, 3:4], out=np.zeros_like(pm[:, :, :3]), where=pm[:, :, 3:4] > 1e-4)
cave = Image.fromarray((np.clip(np.dstack([out_rgb, pm[:, :, 3:4]]), 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")
save("cave", "cave", cave)
# 5. Floor: the pebbled floor under the wall, from a little above the wall's foot (the floor band owns that seam).
# 5. Floor (floor band): the painted wall foot and the painted pebble floor, both unaltered pixels of the painting.
#    floor-top is the wall-to-floor seam at the painting's own scale: transparent above the wall's bottom edge (the cave piece
#    paints the same pixels there), opaque down to FADE0, then fading to transparent by FADE1 over the floor-fill piece.
#    floor-tile is the painted floor's own cell shapes (the pebble layer, 20) at the painting's scale, one continuous column of real
#    cells from canvas y 4750 to TILE_Y1 (the layer runs far below the shore, under the sand, so there is a lot of it), in two flat tones
#    taken from the painting where the floor meets the sand. Its last TILE_B rows are cross-faded with the real rows just above its top
#    (canvas y 4750-TILE_B..4750), so it repeats down with no seam and no mirror. Brightness is NOT in the tile: CSS puts one smooth
#    gradient over the whole section (landing_world_floor.css), from the wall's shadow tone to the tone at the sand.
#    Anchored to canvas y 4750 = .prizes top.
l20 = layer_full(20).getchannel("A")
l18 = np.asarray(layer_full(18).getchannel("A"))
art_rgb = art.convert("RGB")
F_Y0, F_Y1 = 4700, 5200          # top piece rows (canvas)
FADE0, FADE1 = 4960, 5120        # top piece opaque until FADE0, transparent from FADE1
TILE_Y0, TILE_Y1, TILE_B = 4750, 7440, 380   # tile rows, and the wrap-blend height (14% of the tile)
TILE_GAP, TILE_PEB = (102, 93, 170), (68, 60, 137)  # the painting's two floor tones just above the sand (rows 5700-5780)


def smooth(t):
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


O = np.asarray(art_rgb.crop((0, F_Y0, W, F_Y1)), dtype=np.float32)
ys = np.arange(F_Y0, F_Y1, dtype=np.float32)
# alpha: opaque from just above the wall's bottom edge (the cave piece paints the same pixels above it)
edge = np.array([np.argmax(l18[4600:5000, x] > 128) + 4600 for x in range(W)])
k = 41
pad = np.pad(edge, k // 2, mode="edge")
edge = np.array([np.median(pad[i:i + k]) for i in range(W)]).astype(int)
top = np.minimum(edge - 6, 4735)
# a 16-row ramp (not a hard edge), so any rounding difference with the cave piece's identical pixels cannot show as a line
alpha = 255 * smooth((ys[:, None] - (top[None, :] - 10)) / 16)
alpha = alpha * (1 - smooth((ys[:, None] - FADE0) / (FADE1 - FADE0)))
save("floor", "floor-top", Image.fromarray(np.dstack([O, alpha]).clip(0, 255).astype(np.uint8), "RGBA"))
pm_all = np.clip((140.0 - np.asarray(l20.filter(ImageFilter.GaussianBlur(0.7)), dtype=np.float32)) / 80.0, 0, 1)  # pebble coverage 0..1
H_T = TILE_Y1 - TILE_Y0
cells = pm_all[TILE_Y0 - TILE_B:TILE_Y1]                      # TILE_B rows above the top, then the tile's rows
tile_m = cells[TILE_B:].copy()
w_t = smooth((np.arange(TILE_B, dtype=np.float32) + 0.5) / TILE_B)[:, None]
tile_m[H_T - TILE_B:] = tile_m[H_T - TILE_B:] * (1 - w_t) + cells[:TILE_B] * w_t   # last rows fade into the rows above the top
tile = np.array(TILE_GAP, np.float32) * (1 - tile_m[..., None]) + np.array(TILE_PEB, np.float32) * tile_m[..., None]
save("floor", "floor-tile", Image.fromarray(tile.clip(0, 255).astype(np.uint8), "RGB"))

# 6. Sand: the end of the floor, the wavy shore and the sand down to where it is flat. Opaque. The sand band owns the
#    floor-to-sand seam. (The sand-to-blue shore of the final band is a CSS clip, not a piece: see landing_world_final.css.)
# The sand piece is cut along the shore's curve: transparent above it (the floor band's pebbles show through), opaque sand
# below, ending in the flat sand color. Canvas y 5700..7300.
# --- sand-cut-begin
def sand_cut(art_img, y0=5700, y1=7300):
    a = np.asarray(art_img.convert("RGB")).astype(float)[y0:y1]
    t = np.clip((a[:, :, 0] - a[:, :, 2] + 20) / 123.0, 0, 1)  # 0 on the lavender floor, 1 on sand
    full_rows = np.argmax(t > 0.99, axis=0)  # first solid sand row per column
    pad = np.pad(full_rows, 30, mode="edge")  # a dark fleck can hide the curve in a column: follow its neighbors instead
    full_rows = np.minimum(full_rows, np.array([int(np.median(pad[i:i + 61])) + 1 for i in range(len(full_rows))]))
    rgb = a.copy()
    alpha = np.ones_like(t)
    for x in range(a.shape[1]):
        f = int(full_rows[x])
        rgb[:f, x] = a[min(f + 6, a.shape[0] - 1), x]
        alpha[:max(f - 3, 0), x] = 0
        alpha[max(f - 3, 0):f, x] = t[max(f - 3, 0):f, x]
        for y in range(f + 1, min(f + 60, a.shape[0])):  # the art has a few dark pebble flecks just under the curve
            if t[y, x] < 0.9:
                rgb[y, x] = rgb[y - 1, x]
    out_img = np.dstack([rgb, alpha * 255]).clip(0, 255).astype(np.uint8)
    return Image.fromarray(out_img, "RGBA")
# --- sand-cut-end
save("sand", "sand", sand_cut(art), keys="c")  # only @c: the page draws it inside an SVG clipped by the traced shore curve (see _sand.html.erb)

# 6c. The sand's side (final band). The sand's tilted edge (the polygon in landing_world_final.css, listed here in wu from the page middle, y in
#    wu below the final band's box top) gets a CONSTRUCTED front, the way the prize stones get theirs (script/export_prize_stones.py): under the
#    top plane's edge a thin rim band, then one flat face, in flat tones of the sand family, ending in a base line that follows the edge loosely
#    with a few calm, seeded, low-frequency irregularities. No gradient, texture, outline or shadow; antialiased shape edges only.
#    The image is 3152 wide (the painting's width, 1 canvas px = 0.5 wu), laid under the edge, its top 1.5 wu above the edge so the sky
#    never shows between sand and rim. Sky starts at the edge (the CSS clip) and shows below the base.
# --- sand-side-begin
SIDE_EDGE = [(-788, 64.5), (-638, 55), (-488, 48), (-338, 42), (-188, 37), (0, 31.5), (162, 27.5), (312, 25), (512, 22.5), (712, 20.5), (787.5, 19)]
SIDE_TOP_WU = 14          # the image's top, wu below the final band's box top
SIDE_RIM = (211, 175, 108)    # his darker sand #d3af6c
SIDE_FACE = (192, 158, 102)   # the earth tone derived from his wall face
SIDE_RIM_WU, SIDE_OVERLAP_WU = 9.0, 1.5
SIDE_DEPTH = [(-788, 50), (-300, 58), (200, 78), (788, 86)]  # face height in wu: shallower under the heading, taller on the right; nothing under it but sky


def sand_side(width=3152, supersample=1):
    xs = np.arange(width)
    xwu = xs / 2.0 - 788.0
    ex, ey = zip(*SIDE_EDGE)
    edge = np.interp(xwu, ex, ey)                      # the existing edge, in wu
    dx, dy = zip(*SIDE_DEPTH)
    depth = np.interp(xwu, dx, dy)
    rng = np.random.default_rng(2026)

    def noise(sigma, amp):
        v = ndi_gauss(rng.standard_normal(width + 6 * sigma), sigma)[3 * sigma:3 * sigma + width]
        return amp * v / (np.abs(v).max() + 1e-9)

    base = edge + SIDE_RIM_WU + depth + noise(260, 4.5) + noise(90, 1.6)    # wu
    rim = SIDE_RIM_WU + noise(70, 1.8) + noise(25, 0.5)                      # wu thickness
    y_top = (edge - SIDE_OVERLAP_WU - SIDE_TOP_WU) * 2                      # canvas px from the image top
    y_rim = (edge + rim - SIDE_TOP_WU) * 2
    y_base = (base - SIDE_TOP_WU) * 2
    h = int(np.ceil(y_base.max())) + 4
    y = np.arange(h, dtype=np.float32)[:, None]

    def cover(lo, hi):
        return np.clip(np.minimum(y + 1, hi[None, :]) - np.maximum(y, lo[None, :]), 0, 1)

    face_a = cover(y_top, y_base)          # the whole front
    rim_a = cover(y_top, y_rim)            # the rim over its top
    out = np.zeros((h, width, 4), np.float32)
    # premultiplied "over": face first, rim on top (rim only where inside the front)
    rim_a = np.minimum(rim_a, face_a)
    col = (np.array(SIDE_FACE, np.float32)[None, None, :] * (face_a - rim_a)[..., None] + np.array(SIDE_RIM, np.float32)[None, None, :] * rim_a[..., None])
    out[..., :3] = col / np.maximum(face_a, 1e-4)[..., None]
    out[..., 3] = face_a * 255
    return Image.fromarray(out.clip(0, 255).astype(np.uint8), "RGBA")


def ndi_gauss(v, sigma):
    r = int(4 * sigma)
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    return np.convolve(v, k / k.sum(), mode="same")
# --- sand-side-end
save("final", "sand-side", sand_side())

# 7. Shells: layers 25 and 26, recolored with the page's own palette. The painted shell has three tones (flat fills of the painter's
#    brush shapes): light (181,135,37) luminance 137.6, mid (154,104,13) 108.6 and a dark shaded edge (146,82,2) 92, plus an orange
#    rim (174,112,10) between mid and light. Each pixel's luminance is mapped piecewise-linearly onto dark -> mid -> light of the new hue,
#    so the bands, brush shapes and anti-aliased edges (alpha untouched) are exactly the painting's. No hue-rotate, no redraw.
SHELL_L = (92.0, 108.6, 137.6)
SHELL_COLORS = {  # (dark, mid, light), all from the page's palette (tokens.css / the world's teal and the signpost blue)
    "shell-1": ((0x08, 0x98, 0xA7), (0x11, 0xBC, 0xB3), (0x67, 0xE9, 0xD7)),  # teal of the plateau: --world-teal-shade, --world-teal, --world-teal-top
    "shell-2": ((0x11, 0x4F, 0xAB), (0x18, 0x7B, 0xE0), (0x4A, 0x9A, 0xF0)),  # signpost blue: --color-sign-blue-edge, --color-sign-blue, a lighter step of it
}


def recolor_shell(img, dark, mid, light):
    a = np.asarray(img.convert("RGBA")).astype(np.float32)
    lum = a[..., :3] @ np.array([0.299, 0.587, 0.114], np.float32)
    xs = np.array(SHELL_L)
    chans = [np.interp(lum, xs, [dark[c], mid[c], light[c]]) for c in range(3)]
    return Image.fromarray(np.dstack(chans + [a[..., 3]]).clip(0, 255).astype(np.uint8), "RGBA")


for name, i in (("shell-1", 25), ("shell-2", 26)):
    layer = layer_full(i)
    save("sand", name, recolor_shell(layer.crop(layer.getchannel("A").getbbox()), *SHELL_COLORS[name]))

print("flat colors: sky", art.getpixel((60, 2200))[:3], "teal", art.getpixel((60, 3300))[:3],
      "sand", art.getpixel((60, 7500))[:3], "blue", art.getpixel((60, 9500))[:3])
