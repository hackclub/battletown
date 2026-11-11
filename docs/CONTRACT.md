# Interface contract

Everything the landing and onboarding pages can rely on. Write "Hack Club" exactly (never "Hackclub"/"HackClub"). The UI name is "Battletown".

## Ownership

- Landing: `app/views/landing/**`, `app/assets/stylesheets/landing.css`, `app/javascript/controllers/landing_*`
- Onboarding: `app/controllers/onboardings_controller.rb`, `app/views/onboardings/**`, `app/assets/stylesheets/onboarding.css`, `app/javascript/controllers/onboarding_*`
- Shared (change only if you must): layout, `application.css`, `tokens.css`, models, `shared/_signup_button`

## Routes

| Route | Notes |
| --- | --- |
| `root` -> `landing#show` | Onboarded users are redirected to `dashboard_path`. Signed-in, not-yet-onboarded users still see it. |
| `GET/PATCH /onboarding` (`onboarding_path`) | `OnboardingsController` stub: requires login. Add `/onboarding/:step` routes if wanted. On finish set `onboarded_at`, then redirect to `dashboard_path`. |
| `dashboard_path` | Requires login + onboarded (`require_onboarded`). |
| `POST /auth/hack_club` | Starts sign-up/sign-in. Use `render "shared/signup_button", label:, css:`. |
| `DELETE /logout` (`logout_path`) | |
| `GET /:slug` | Records `session[:referral_source]` for slugs in `config/referrals.yml` (first touch wins), redirects home. Copied onto the user at first sign-in. No query-param UTMs. |
| `privacy_path`, `terms_path` | Placeholder legal pages. |

## Controller helpers (`ApplicationController`)

`current_user`, `signed_in?` (also view helpers), `require_login`, `require_onboarded`, `sign_in(user)`. Use `before_action :require_login` in onboarding.

## User fields

`display_name`, `email`, `slack_id`, `verification_status` (`verification_needs_submission?` / `_pending?` / `_verified?` / `_ineligible?`), `ysws_eligible`, `referral_source`, `prize_key` (`current_user.prize` -> `Prize` or nil), `project_kind`, `project_idea`, `coding_days` (bitmask; use `coding_day_names` / `coding_day_names=`, Monday = 1 ... Sunday = 64), `coding_time` ("HH:MM"), `time_zone`, `onboarding_step` (0..`User::ONBOARDING_STEPS` = 4), `onboarded_at`, `onboarded?`.

Validation allowlists (all enforced by the model; use strong params and let `save` fail closed):

- `prize_key` in `Prize.keys`
- `project_kind` in `User::PROJECT_KINDS` (game website app tool hardware undecided)
- `project_idea` <= 500 chars
- `coding_time` matches `HH:MM`
- `time_zone` is an `ActiveSupport::TimeZone` name
- `coding_day_names` values are from `User::DAYS`; unknown names are ignored

`Prize.all` / `Prize.find(key)` exposes `key name description hours price_usd emoji image tier`. Landing shows hours, the shop shows currency. Prize data is placeholder. `Referral.all` has `slug name`.

## CSS

Tokens (`tokens.css`, placeholder, will be replaced): `--color-*`, `--text-*`, `--space-*`, `--radius-*`, `--shadow-*`, `--font-*`, `--container-width`. Use tokens, never raw values.
Classes in `application.css`: `.container`, `.page`, `.prose`, `.btn` (`--primary`, `--ghost`, `--lg`), `.card`, `.flash`, `.visually-hidden`. Add `landing.css` / `onboarding.css` in `app/assets/stylesheets/`; propshaft includes every file via `stylesheet_link_tag :app`.

## CSP (enforced)

- No inline `<script>`/`<style>` unless `nonce: true` (`javascript_tag nonce: true do`).
- No `style=""` attributes: use classes, `data-*` + CSS, or set styles from Stimulus (`el.style.setProperty("--progress", "40%")` is fine, CSSOM is not blocked).
- Images/fonts/audio/video must be same-origin (images may also be `data:`). No third-party scripts, fonts or embeds.
- Forms that leave the site (auth) need `data-turbo="false"`.

## JavaScript

Importmap + Stimulus. Add `app/javascript/controllers/foo_controller.js` (auto-registered as `foo`); use `data-controller="foo"`. For vendor packages use `bin/importmap pin <pkg> --download` (keeps scripts same-origin).

## Tests

Minitest + fixtures (`test/fixtures/users.yml` has `new_user` and `onboarded`). To sign in during tests see `test/integration/access_test.rb` (`OmniAuth.config.test_mode`).
