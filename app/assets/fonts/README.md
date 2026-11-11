# Self-hosted fonts

Latin subset woff2 files, downloaded from fonts.gstatic.com (the files Google Fonts serves for the `latin` unicode range).
Both families are licensed under the SIL Open Font License 1.1 (https://openfontlicense.org), which permits self-hosting and redistribution.

| File | Family | Weight | Designer / source |
| --- | --- | --- | --- |
| `poetsen-one-400.woff2` | Poetsen One (display, headings, buttons) | 400 | Rodrigo Fuenzalida, https://fonts.google.com/specimen/Poetsen+One |
| `mplus-rounded-1c-400.woff2`, `-500`, `-700` | M PLUS Rounded 1c (the Figma "Rounded Mplus 1c", body text) | 400, 500, 700 | M+ FONTS PROJECT, https://fonts.google.com/specimen/M+PLUS+Rounded+1c |

The `@font-face` rules live in `app/assets/stylesheets/fonts.css`; the stacks are the `--font-display` and `--font-body` tokens in `tokens.css`.
Only the Latin range is included, so characters outside it (for example CJK) fall back to the system font.
