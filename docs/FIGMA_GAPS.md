# Figma gaps and token changes

Source: Figma file `Qi9ARDNu8fxsTT1C43DDgL` (one page, "Page 1", node `0:1`), read on 2026-11-11 with the Figma MCP (read-only).
Product notes: Granola folder "Village" (meetings 11/2, 11/3, 11/6, 11/9) and the Slack canvas "Village — whiteboard plan (11/9)" (`F0CG8T25BNV`).

"Observed" means I saw it in a Figma frame, a repo file or a running page. "Unclear" means the source is silent, ambiguous or I did not open it.
Reference exports (small PNGs) are in `docs/design/`.

## Important caveat: Figma has no real tokens yet

`get_variable_defs` returned `{}` for every node I tried (`0:1` is not selectable, so `1:4`, `13:10`, `71:1000`). There are no Figma variables, no published styles and no style-guide frame. Every colour below was read from node fills in `get_design_context`, so it is "a value used in a frame", not a named token. Spacing and type scale are not defined anywhere beyond the single hero/button frames.

## (a) Figma pages and frames

One page, `Page 1` (`0:1`), a large free-form canvas of roughly 190 top-level nodes: reference art, colour experiments, logo variants and a handful of page-sized frames. Only the page-sized frames matter for the build.

| Node | Name | What it shows (observed) |
| --- | --- | --- |
| `134:1151` (child `134:1152`) | Group 5 / Desktop - 16 (1440x2048) | Latest landing direction. Hero: logo wordmark (`134:1161`, 579x329), tagline "Build projects, get gear" ("get gear" in yellow), pink CTA "Join 150 other fighters" with arrow, grey placeholder background, then a cream panel with a pink swoosh and sparkle as its top edge. The cream panel is empty. |
| `136:75` (children `136:61`, `136:57`) | Group 8 / Desktop - 18, 19 (1440x2048) | Same layout as Group 5 with the painted boss and town art as the hero background and the pink swoosh over a cream panel. Closest to a finished landing hero. Cream panel is empty. |
| `70:955`, `70:956` | Group 3, Group 4 | Earlier variants of the same hero + panel (Desktop - 16 and 17). |
| `57:384` | Desktop - 9 | Hero with logo, painted boss/town art and three coloured placeholder bars (blue `#0563de`, yellow `#ffda37`, pink `#f861a3`) standing in for text blocks. |
| `57:411` | Desktop - 10 | Hero with art, logo, "Build projects, get gear", a yellow placeholder bar inside a cream pill (CTA placeholder) and a down chevron. |
| `65:494` | Desktop - 15 | Boss and town painting only (no UI). |
| `13:10`, `14:242` | Desktop - 1, Desktop - 5 | Logo plus the same three coloured placeholder bars on a pale-blue checkerboard (Desktop - 5 has a stronger blue gradient). Colour and layout experiment. |
| `57:360` | Desktop - 8 | Checkerboard gradient only. |
| `65:442` | Desktop - 11 | White-to-blue gradient only (likely the panel/background fade). |
| `14:298` | Desktop - 7 | Sky, sun and green hills scene with placeholder blocks (pink tower, tan buildings, blue door). Reads as a town scene mock-up. |
| `65:518`, `65:564` | Desktop - 16, 17 (inside Group 3) | Hero and the swoosh/sparkle divider as separate frames. |
| `71:1000`, `66:858`, `134:1156` | button / Frame 38 / Frame 41 | The CTA component: cream pill, pink face, "Join 150 other fighters", arrow. `71:1000` is the clean copy. |
| `1:4` | MacBook Pro 16" - 1 (1728x1117) | Dashboard concept. Blue-tinted game screenshot as background, a coral placeholder block (588x474, `#fc6c6e`, probably the boss/play area), the text "15 minutes to your daily goal" followed by three "-" lines, and a green striped progress bar (image asset `villagebar`) with a dark brown marker (`1:264`, `#423624`, 5px). |
| `1:268` | MacBook Pro 16" - 5 (1728x1117) | Blue painted-tower background, two pink and one white placeholder block, and a "Lost? Click here for guides" link bottom right. Purpose unclear (looks like a second dashboard or onboarding concept). |
| `1:263` | text "needed here: cta for shipping boss UI" | An explicit design TODO: a CTA for shipping the boss UI is needed and does not exist yet. |
| `13:2`, `14:324`-`14:327`, `14:337`, `14:347` | text notes | Art notes: "landing page reference", "pink guy is boss", "blue guy is the hero", "yellow is the town & buildings", "probably not this pose, but some cool pose for the guy", "some evil villan", "Code a project, get a ..." (Inter, unfinished headline). |
| `68:875`, `71:10xx`, `134:1161` ... | battletownlogo1 1-9 | Logo wordmark variants (blue/pink, blue/yellow/cyan). The yellow and cyan version in Group 5 is the one used in the newest hero. |
| `136:30`-`136:56` | Signpost 1-3, signpost-extruded | Large 3D-looking signpost shapes. Purpose unclear. |
| `14:313`-`14:345`, `47:349`-`47:358`, `65:436`, `65:472` | image 1-16 | Reference/inspiration images and art, not UI. |
| `65:491`-`65:493`, `13:15`-`13:17` | Desktop - 12/13/14 (628x194), Desktop - 2/3/4 (722x251) | Small frames. Not opened (likely button or block variants). Unclear. |

There are no frames for: the 5 onboarding steps, the shop, Plinko, streak UI, team UI, a mobile layout, or any form field/input. Dashboard exists only as the one concept (`1:4`).

## (b) Token changes in `app/assets/stylesheets/tokens.css`

All token names are unchanged. The big decision: Figma is a light, sky-and-cream UI (cream `#fffef5` panel, sky blue, bright pink CTA), so the dark placeholder theme was flipped to light. Values marked "derived" are not in Figma; they were chosen to pass WCAG AA against the Figma cream.

| Token | Old | New | Source |
| --- | --- | --- | --- |
| `--color-bg` | `#0f1117` | `#fffef5` | Figma cream (`71:1000`, `134:1152`) |
| `--color-surface` | `#181b25` | `#ffffff` | derived (card lift off cream) |
| `--color-surface-raised` | `#222636` | `#ffeada` | Figma cream button edge (`71:1000`) |
| `--color-border` | `#2f3447` | `#dcc7a1` | derived (decorative only; inputs use `--color-text-muted`) |
| `--color-text` | `#f2f3f7` | `#000000` | Figma text colour (`1:263`) |
| `--color-text-muted` | `#9aa1b5` | `#6b6150` | derived, 6.0:1 on bg, 5.2:1 on raised |
| `--color-primary` | `#ff6b3d` | `#cc0052` | derived from Figma pink `#ff4797`, darkened (see below) |
| `--color-primary-contrast` | `#1a0b05` | `#fffef5` | Figma cream button label; 5.6:1 on primary |
| `--color-secondary` | `#7c5cff` | `#0563de` | Figma blue (`13:10`) |
| `--color-success` | `#3ddc97` | `#067a46` | derived (not in Figma), 5.4:1 on bg |
| `--color-danger` | `#ff5470` | `#c4143c` | derived (not in Figma), 5.9:1 on bg |
| `--color-focus` | `#ffd166` | `#0563de` | Figma blue; Figma yellow is only 1.35:1 on cream, focus rings need 3:1 |
| `--radius-lg` | `1.25rem` | `1.75rem` | Figma inner button radius 28px (`71:1001`) |
| `--shadow-sm` | `0 1px 2px rgb(0 0 0 / 0.4)` | `0 1px 2px rgb(66 54 36 / 0.18)` | derived for light theme |
| `--shadow-md` | `0 8px 24px rgb(0 0 0 / 0.35)` | `0 8px 24px rgb(66 54 36 / 0.16)` | derived for light theme |

New tokens (Figma defines something with no existing slot; nothing references them yet):

| Token | Value | Source |
| --- | --- | --- |
| `--color-cta` | `#ff4797` | Figma pink CTA fill (`71:1001`) |
| `--color-highlight` | `#ffda37` | Figma yellow "get gear" and block (`134:1153`, `13:10`) |
| `--color-sky` | `#b1dcfe` | Figma hero gradient stop (`134:1152`) |
| `--color-sky-soft` | `#aacaf9` | Figma checkerboard blue (`13:10`) |
| `--color-ink-brown` | `#423624` | Figma progress marker (`1:264`) |
| `--text-display` | `3rem` | Figma 48px display/CTA type |
| `--tracking-display` | `-0.06em` | Figma -2.88px at 48px |
| `--radius-xl` | `3rem` | Figma outer button radius 48px (`71:1000`) |
| `--shadow-button-edge` | `inset 0 -8px 0 rgb(0 0 0 / 0.41)` | Figma inset shadow on the pink button |
| `--border-chunky` | `0.375rem` | Figma 6px cream button bottom border |

Why `--color-primary` is not the exact Figma pink: `a`, `.landing-prize__price`, `.choice__meta` and the current onboarding step all use `--color-primary` as text colour, and `#ff4797` on cream is 3.14:1 (fails AA for normal text). `#cc0052` keeps the hue and gives 5.6:1. The exact Figma pink is kept in `--color-cta` for fills and large type. Cream-on-`#ff4797` is also 3.14:1, so the Figma button label only passes as large text (the Figma label is 48px).

Left as-is because Figma defines nothing: spacing scale (`--space-*`), type scale (`--text-xs` to `--text-3xl`), `--leading-*`, `--container-width` (`72rem`; Figma frames are 1440 and 1728 wide with no container), `--font-mono`.
Not changed because I cannot self-host them from the files I own: `--font-body` and `--font-display` (see P0 below).

## (c) Gaps

Priorities follow the whiteboard canvas (P0 = EOD 11/11, P1 = high, P2 = by launch). Note the sources disagree on landing: the 11/9 meeting notes say landing is P0 and the canvas says P1. I use P0 for things that block the landing looking like the Figma.

### Figma vs the current build

| Pri | Gap | Figma ref | Build today (observed) |
| --- | --- | --- | --- |
| P0 | No style guide, variables or type/spacing scale in Figma. Tokens above are fills read from frames plus derived AA values. The pending style guide should replace the derived rows. | whole file | `tokens.css` updated as in (b) |
| P0 | Fonts not available. Figma uses Poetsen One (display and CTA, `134:1153`, `71:1002`) and Rounded Mplus 1c Medium (dashboard text, `1:263`); one headline uses Inter (`13:2`). Both rounded faces are Google Fonts families; the CSP forbids third-party fonts, so they need self-hosted woff2 files in `app/assets/fonts` plus `@font-face` in a stylesheet I do not own. Licence not verified here. | `134:1153`, `71:1002`, `1:263` | System font stack for both `--font-body` and `--font-display` |
| P0 | Landing hero does not match Figma: no logo wordmark, no boss/town art, no "Build projects, get gear" tagline, one text-only H1 "Battletown" plus eyebrow and subtitle. The logo (`battletownlogo1 8`, `134:1161`) and hero painting (`65:494` / `136:75`) are not in the repo (`app/assets/images` is empty). `--art-hero-background` is wired in `landing.css` but never set. | `134:1151`, `136:75` | `landing/show.html.erb` hero |
| P0 | Hero CTA copy and style: Figma says "Join 150 other fighters" (with arrow) in a chunky cream pill with pink face. The 150 looks like a hard-coded count; the build comment says no made-up numbers, so a real count source is needed (unclear whether 150 is a goal, a real count or a placeholder). The build CTA is "Sign up with Hack Club" in a flat pill. | `71:1000`, `134:1156` | `landing/_cta.html.erb`, `.btn--primary` |
| P1 | Chunky button style (cream outer pill 48px, 6px cream-edge bottom, pink inner pill 28px, inset bottom shadow, 48px display type) is captured as tokens but no CSS uses them yet. | `71:1000` | `.btn`, `.btn--lg` use `--radius-full`, no edge |
| P1 | Cream content panel with pink swoosh and sparkle edge below the hero. Figma panel content is empty (unclear what goes in it). Build sections are flat on the page background. | `134:1151`, `136:75` | `.landing-section` blocks |
| P1 | Dashboard concept: boss/play area, a "15 minutes to your daily goal" label with a striped green progress bar and a marker, and a missing CTA for shipping boss UI. Progress bar art (`villagebar`, `13:11`) is an image; its green is not in the node data. Build is a greeting, the chosen prize and "Boss battle coming soon". Figma note `1:263` confirms the boss UI CTA is undesigned. | `1:4`, `1:263`, `13:11` | `dashboard/show.html.erb` |
| P1 | Scroll chevron under the hero CTA (Figma only). | `57:411` | none |
| P2 | Onboarding: no Figma frames exist for any of the 5 steps, so the build (prize, project, schedule, account, celebrate) has nothing to be checked against. It currently inherits the new tokens; I checked prize, schedule and account at 375px and 1440px and saw no overflow. | none | `onboardings/*` |
| P2 | Mobile: no mobile frames anywhere in Figma. | none | responsive CSS exists, unreviewed against a design |
| P2 | `1:268` (blue tower, "Lost? Click here for guides") has no stated purpose; the signposts (`136:30`-`136:56`), image refs and small frames (`65:491`-`65:493`, `13:15`-`13:17`) were not mapped to any screen. | listed in (a) | none |
| P2 | Art is the stated launch blocker: boss, hero and background due EOD 11/11, two more bosses TBD (canvas, 11/9 meeting). Figma has one boss/town painting and a hero; the notes call for 2-3 boss assets. | `65:494`, `14:324`-`14:327` | none |

### Product notes vs Figma and the build

Build status below is observed from the repo views and the running app, not from the notes.

| Pri | Concept (source) | In Figma | In the build |
| --- | --- | --- | --- |
| P0 | Weekly community boss: 1 hour = 1% of a 100-hour boss, community icons on the home page (11/6 meeting, canvas "Weekly boss battle") | Only an unlabelled coral block (`1:305`) and a CTA TODO (`1:263`). No boss HP bar, no community icons. | Not built. Landing copy mentions a boss health bar; dashboard says "coming soon". |
| P0 | Landing prizes priced in hours, shop in currency (11/9) | No prize UI on the landing frames (Group 5/8 panels are empty). No shop frame. | Landing shows hours (`pluralize(prize.hours, "hour")`); `price_usd` exists in `config/prizes.yml` but there is no shop page or currency concept. Prize list is a set of cards, not a selectable picker that carries through, which the 11/6 notes ask for. |
| P0 | Free sticker for signup (11/6, canvas "Signup sticker") | Not shown. | Landing line "Free sticker when you sign up". Fulfilment and budget not built. |
| P1 | Streaks: 15-minute daily sticker streak; daily-goal streak with a bonus ramp of 5% to 20% over 14 days, holding at the cap; 1-day freeze (canvas, 11/9, 11/6) | Only the "15 minutes to your daily goal" label and bar in `1:4`. No streak counter, ramp or freeze UI. | Not built. Onboarding stores coding days and time only. Landing FAQ mentions streak bonuses in general terms. |
| P1 | Team, quest and returning bonuses (canvas, 11/9) | Nothing. | Not built. Canvas defines team bonus as a small multiplier on overlapping hours; the 11/9 meeting describes it as a buddy/invite bonus. Whether those are the same rule is unclear. |
| P1 | Onboarding: prize (visible throughout), project with ideation help, schedule, referral capture by path, celebration with sound, progress bar on top (11/6) | Nothing. | Built: progress bar, saved prize shown from step 2, presets, "Guides (coming soon)" and "Jumpstart playground (coming soon)" placeholders, schedule, account (IDV status, Hackatime placeholder), celebration with synth sound and mute, path referrals (`/haven`, `/terra`, `/stardance`). |
| P1 | Shipping: force IDV; ship reminders at 5h/10h; hour deductions after 6h (marked "?" on the canvas) (canvas, 11/6) | Nothing. | IDV status stored, not enforced (README says enforce at shipping). Reminders not built. |
| P2 | Plinko daily minigame: one ball per 5 minutes coded, leaderboard, shareable to Slack (11/6, canvas "Daily Plinko") | Nothing. | Not built. Fishing was floated as an alternative; not decided. |
| P2 | Home loop: Plinko, then code 15 minutes, hit goal, celebrate; prominent streak display; one start-coding button into Hackatime; sidebar (11/6) | Partly implied by `1:4` (one progress bar). | Not built. |
| P2 | Notifications (Slack, email, SMS), NPS every 2 days, metrics, guides, admin (canvas) | Nothing. | Not built. Schedule step says "We'll nudge you on Slack", but sending is not built. |
| P2 | 1 month run, possible 1 month extension (canvas, 11/9) | n/a | Stated in landing FAQ ("launches this week and runs for at least a month"). |

Source discrepancies worth a decision: day 1 of the streak ramp is 5% on the canvas but "base" in the 11/9 notes; "Village" (notes) versus "Battletown" (Figma, build); and Group 5's grey hero background looks like a placeholder for the painted art in Group 8.

## Verification (observed on 2026-11-11)

- `bin/rails test`: one run showed 59 runs, 2 failures, both in `test/integration/rack_attack_test.rb` (that run overlapped with my server starting); three later runs, including one with my change stashed, showed 59 runs, 0 failures. I did not find the cause of the single failing run.
- `bundle exec rubocop`: 48 files, no offenses.
- Browser (paseo, dev server on port 3000, Dev login): landing at 1440px and 375px, `/onboarding/prize` at 1440px and 375px, `/onboarding/schedule` and `/onboarding/account` at 375px, and the dashboard at 1440px. No horizontal overflow, text legible, selected states and focus colours visible, progress track pale but visible. The browser console buffer was empty on each page I checked (I did not see any CSP violation reported). I could not run a computed-style check because the page CSP blocks `evaluate`. `/onboarding/celebrate` was not opened.
- Known visual changes from the token flip: the whole site is now light; the landing hero gradient is a pale blue glow on cream; the onboarding progress track (`--color-surface-raised`) is low contrast against cream by design (decorative).
