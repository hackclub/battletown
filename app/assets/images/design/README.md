# Design assets

Art for the Figma restyle (file key `Qi9ARDNu8fxsTT1C43DDgL`, read-only export, November 2026). Everything here is served same-origin through Propshaft (`image_tag "design/<file>"` in views, `url("design/<file>")` in stylesheets). Total weight is about 270 KB (the three WebP files are most of it). SVGs were sanitised: no scripts, no event handlers, no external references (internal `#id` references only), ids kept only where referenced. Decorative art always gets `alt=""`.

Not copied on purpose: the 2.2 MB glow layer (`151:310`), the raw PNG exports, the third-party controller product photo (`156:663`), the old dashboard bar PNGs (build the bar in CSS: `.progress--goal`) and the HP bar SVGs (build in CSS: `.progress--boss`).

| File | Figma node | Use | Size / bytes |
| --- | --- | --- | --- |
| `logo.svg` | `151:275` | Header brand (44px tall) and the landing hero `<h1>` logo | 579x329, 42 KB |
| `signpost-1-yellow.svg` | `151:349` | "How it works" sign 1 (Build), yellow face `#ffd000` | 911x280, 0.6 KB |
| `signpost-2-blue.svg` | `151:358` | Sign 2 (Ship), blue face `#187be0`, points left | 964x247, 0.8 KB |
| `signpost-3-pink.svg` | `151:368` | Sign 3 (Get your prize), pink face `#ff4797` | 1022x250, 0.8 KB |
| `signpost-pole.svg` | `152:534` | The grey-blue pole behind the three signs (`#466c8a`) | 88x854, 1.2 KB |
| `swoosh-sky.svg` | `151:269` | Sky swoosh edge under the hero (solid `#b1dcfe`) | 1529x339, 0.6 KB |
| `swoosh-fade.svg` | `151:268` | Same swoosh with a cream fade | 1529x476, 0.7 KB |
| `wave-top.svg` | authored for the foundation (no Figma node) | Mask for `.band--wave`, the wavy top edge of a band (modelled on the wave at the top of `152:469`) | 1440x120, 0.3 KB |
| `map-band.svg` | `152:526` | The `#1472d5` map band shape with a wavy top | 1607x2344, 0.3 KB |
| `map-river.svg` | `152:529` | The 101px river stroke (needs `mix-blend-mode: soft-light` when used as a layer) | 911x1842, 0.4 KB |
| `map-tree.svg` | `156:562` (Group 12 `156:558`) | Map decoration and empty-state art | 73x119, 1.3 KB |
| `map-house.svg` | `156:617` (Group 14 `156:616`) | Map decoration | 150x72, 0.8 KB |
| `boss-shadow.svg` | `152:542` | Soft ellipse under the boss (`soft-light`) | 470x202, 0.3 KB |
| `icon-arrow.svg` | `151:274` | CTA arrow, cream stroke; prefer an inline SVG with `currentColor` (see `.btn .icon`) | 42x42, 0.3 KB |
| `boss-weekly.webp` | `152:541` (cropped: x 2106, y 310, 1810x1746 of the 4096x2635 source) | Weekly boss art on the landing map and the dashboard boss card | 1000x965, 97 KB |
| `hero-painting.webp` | `151:266` background | Painted town behind the hero (alpha, painting is the top 279px) | 1024x659, 45 KB; ask the designer for a 2x export (it is upscaled at 1440) |
| `hero-character.webp` | `151:311` | The hero in the cloak peeking from the bottom-right corner of the map section (hide on mobile) | 900x757, 41 KB |

Colours in the SVGs match the tokens in `tokens.css` (`--color-sign-*`, `--color-pole`, `--color-map`). The signs, pole, map band and river carry `preserveAspectRatio="none"` (as in the Figma export) so the narrow-screen landing can stretch them behind text.

The landing page also uses `../landing/`: `hero-painting.webp` (the painted top 1024x279 of the Figma export `151:266`, which the landing shows stretched to 1440 wide and 988 tall exactly as Figma does) and `hero-overlay.svg` (the sky fade, `151:268` and `151:269` swooshes of that frame as one 1440x1000 SVG). Re-exported and checked against Figma on 2026-11-12: no changes since the first export.
