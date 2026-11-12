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
| `POST /dev_login` | Development only (404 elsewhere). The single "Dev login" button is in the layout header, wrapped in `dev_tool`; do not add more. |
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
- `time_zone` is an `ActiveSupport::TimeZone` name (e.g. "Eastern Time (US & Canada)", not an IANA id; use `ActiveSupport::TimeZone[user.time_zone]`). It defaults at first sign-in from the Hack Club Auth address (`AddressTimeZone`; the address itself is never stored) and the user can change it on the schedule step
- `coding_day_names` values are from `User::DAYS`; unknown names are ignored

`Prize.all` / `Prize.find(key)` / `Prize.paid` expose `key name description coins emoji image tier free_signup`; `hours` is derived (`coins / coins.per_approved_hour` from `config/game.yml`, one decimal at most) and `hours_text` is "2 hours" / "1 hour" / "1.5 hours". The landing page and onboarding show hours, the shop shows coins. `Prize.keys` (every key, the free signup sticker included) is the allowlist for stored `prize_key` values; `Prize.paid` leaves the free sticker out and is what the landing page, onboarding picker and shop grid list. The catalogue is placeholder data the designer will replace, and the only price in it is `coins`. `Referral.all` has `slug name`. `ReferralSource.all` (`key name`) is the onboarding "how did you hear about us" list: generic answers from `config/referral_sources.yml`, then the `Referral` programs, then "Something else"; `users.referral_source` must be one of `ReferralSource.keys` (enforced in `OnboardingsController`). Generic keys are not attribution slugs.

## CSS

Tokens (`tokens.css`, placeholder, will be replaced): `--color-*`, `--text-*`, `--space-*`, `--radius-*`, `--shadow-*`, `--font-*`, `--container-width`. Use tokens, never raw values.
Classes in `application.css`: `.container`, `.page`, `.prose`, `.btn` (`--primary`, `--ghost`, `--lg`), `.card`, `.flash`, `.visually-hidden`. Add `landing.css` / `onboarding.css` in `app/assets/stylesheets/`; propshaft includes every file via `stylesheet_link_tag :app`.

## Projects and Hackatime links

- Models: `Project` (`name` 1..60, `kind` in `User::PROJECT_KINDS`, `idea` <= 500, optional https `repo_url` (GitHub repo only, stored normalised: lowercase, no `www.`, no `.git`, no trailing slash) and `demo_url`, `status` active/archived, `active` flag, nullable `guide_key` sd/playground), `HackatimeLink` (`project`, `user`, `hackatime_project` <= 120, `link_method` manual/auto_repo/confirmed), `LinkSuggestion` (`project`, `hackatime_project`, `state` pending/accepted/declined). A user has at most 10 projects and exactly one active at a time (partial unique index); `current_user.active_project` is the one to read. A Hackatime project links to at most one project per user (`HackatimeLink.project_for(user, name)`). Tables cascade on user deletion.
- Routes: `/projects` (list, new, edit, create, update, destroy), `PATCH /projects/:id/(activate|archive|unarchive)`, `POST|DELETE /projects/:id/hackatime_links`, `PATCH /projects/:project_id/link_suggestions/:id/(accept|decline)`. Signed in and onboarded only; other users' ids are a 404.
- `Projects::AutoLinker.call(user, [ { name:, repo_url: } ])` links on an exact normalised GitHub repo match (`auto_repo`), otherwise makes a pending suggestion for a close name; it never links on a suggestion. `Projects::LinkSuggestions.accept!(suggestion)` / `.decline!(suggestion)` answer one; a declined suggestion is never asked again (an unlink also counts as a no).
- Event: `ActiveSupport::Notifications.instrument("project_link_suggested.battletown", suggestion_id:)` fires after a new pending suggestion is saved. The Slack reminder task subscribes; the projects code sends nothing itself.
- Onboarding's project step creates or updates the user's first project (`Project.sync_first_from_onboarding`) and still fills `users.project_kind` / `project_idea`.

## Staff-only UI

Anything that ordinary users must not see is tinted like Hack Club Bank does: **green = development only**, **orange = admin only** (soft tint, dashed outline, small "Dev" / "Admin" tag).

- Helpers (`app/helpers/staff_helper.rb`): `dev_tool(tag = :div, label: true, **html_options) { ... }` renders only when `Rails.env.development?`; `admin_tool(...)` renders only for a signed-in user where `current_user.admin?`. `label: false` drops the visible tag when the content already says it (the header "Dev login" chip). Both add visually-hidden "Dev only:" / "Admin only:" text for screen readers.
- Classes (`app/assets/stylesheets/staff.css`): `.dev-only`, `.admin-only` (and `--unlabelled`). They are what the helpers emit; do not write them by hand without the helper.
- Tokens (`tokens.css`): `--color-dev`, `--color-dev-bg`, `--color-dev-border`, `--color-dev-ink`, and the same four with `admin`. Text, outline and tag pairs pass WCAG AA.
- Rules: never ship staff UI without the helper. The gate is server-side (the helper renders nothing, the route or controller must also refuse: `dev_login` returns 404 outside development). CSS alone hides nothing.
- `User#admin?` is true only when the user's `hca_uid` (the Hack Club Auth `sub`) is in the comma-separated `ADMIN_HCA_UIDS` env var (`AdminAllowlist`: whitespace trimmed, blanks ignored, exact case-sensitive match, empty or unset = nobody). It is read at call time and re-checked from the database user on every request, so removing an id takes effect on the next request or deploy. Admin pages live under `/admin` (`Admin::BaseController`): signed-out visitors and non-admins get the same 404 as an unknown path (never a redirect, no hint the area exists), responses are `Cache-Control: no-store`, and the area is read-only aggregates with no PII (`AdminStats`). The gate is server-side only: `admin_tool` just hides UI, the controller must also refuse. Title: `content_for :title, "Admin"`. Locally, `ADMIN_HCA_UIDS=dev-user` makes the Dev login user an admin.
- The only dev-only UI today is the "Dev login" chip in the header nav (signed-out visitors, once per page).

## CSP (enforced)

- No inline `<script>`/`<style>` unless `nonce: true` (`javascript_tag nonce: true do`).
- No `style=""` attributes: use classes, `data-*` + CSS, or set styles from Stimulus (`el.style.setProperty("--progress", "40%")` is fine, CSSOM is not blocked).
- Images/fonts/audio/video must be same-origin (images may also be `data:`). No third-party scripts, fonts or embeds.
- Forms that leave the site (auth) need `data-turbo="false"`.

## JavaScript

Importmap + Stimulus. Add `app/javascript/controllers/foo_controller.js` (auto-registered as `foo`); use `data-controller="foo"`. For vendor packages use `bin/importmap pin <pkg> --download` (keeps scripts same-origin).

## Tests

Minitest + fixtures (`test/fixtures/users.yml` has `new_user` and `onboarded`). To sign in during tests see `test/integration/access_test.rb` (`OmniAuth.config.test_mode`).

## Hours ledger (`app/services/hours`, `app/services/hackatime`)

Append-only `hour_entries` (seconds per user per frozen local date; `HourEntry` is read-only once saved, corrections are `adjustment` rows). Tunables are in `config/game.yml` under `hours:` (`daily_cap_seconds`, `max_backfill_days`, `active_seconds`; add other features as their own top-level key).

- Write: `Hours::Credit.call(user:, seconds:, source:, idempotency_key:, local_date: nil | at: nil, hackatime_project: nil, note: nil, created_by: nil)` returns a `Result` (`entry`, `status` in `:created :clamped :duplicate :capped`, `credited_seconds`). Raises `Hours::Credit::Rejected` for input that can never be credited.
- Read: `Hours::Totals.seconds_by_date(user, range)`, `.seconds_for_date(user, date)`, `.seconds_in_range(range)` (all users), `.active_user_count(date)`. Dates are the frozen local dates; `Hours::Days.local_date(instant, user)` / `.today(user)` do the zone maths.
- Hackatime seam: `Hackatime::Source#daily_seconds(user:, from:, to:)`, `Hackatime::NullSource` (default), `Hackatime::CsvSource.new(path)`; `Hours::Sync.call(user_or_rows, ...)`. Rake: `hours:import[path]`, `hours:credit[slack_id,date,seconds,note]`.
- Development only: `/dev/hours` adds minutes to the signed-in user for a local date (404 elsewhere).

## Weekly boss (`app/services/bosses`, `app/models/boss.rb`, `app/views/bosses/_card.html.erb`)

One `bosses` row per week (Friday to Thursday, dates inclusive and never overlapping): `name`, `art_key` (allowlist `Boss::ARTS`, image at `app/assets/images/bosses/<key>.webp`), `starts_on`, `ends_on`, `hp_seconds`, `defeated_at`. Damage is never stored: it is the sum of ALL users' raw coded seconds on the local dates inside the week (`Bosses::Damage.for(boss)`, from `Hours::Totals.seconds_in_range`). Health is set per boss by an admin at `/admin/bosses` and is editable until the boss starts; dates are fixed. `bin/rails bosses:seed` (and `db/seeds.rb`) create the four launch weeks idempotently and never overwrite an edited boss.

- `Bosses::BossMath` (pure): `damage(sum)`, `percent` (integer floor, capped 100), `ratio` (capped 1.0), `remaining`, `overkill`, `defeated?`. Overkill is shown and never carried over.
- `Bosses::Current.for(date)` / `.for_user(user)`: the boss covering that local date, or `:none`.
- `Bosses::CheckDefeat.call(boss)`: sets `defeated_at` once (under `boss.with_lock`, conditional `UPDATE ... WHERE defeated_at IS NULL`) when damage >= health; it is called from `HourEntry` after commit for the bosses covering the entry's date, and a later correction never clears it.
- `Bosses::Presenter.new(user:, today: nil)` returns plain values for the view: `state` (`:none :in_progress :defeated :escaped`), `boss_name`, `art_path`, `art_alt`, `health_percent` / `health_ratio` (what is left, for the bar), `damage_percent` / `damage_ratio`, `remaining_seconds`, `hours_to_go_text` ("about 190 hours to go", truncated), `overkill_seconds` / `overkill_text`, `days_left` (calendar, includes today), `ends_on`, `end_day_name`, `summary` (the text alternative), `user_slayer?` (>= `boss.slayer_seconds` of the user's own coded time in that week, boss down), `community_active_today` / `community_text` (a count, never names), `contributed_seconds_this_week` / `contributed_text` (the viewer's own only). A surviving boss "escapes" with no penalty.
- View: `<%= render "bosses/card", presenter: Bosses::Presenter.new(user: current_user) %>`, once per page (fixed element ids; one `h2`). Styles in `bosses.css`.
- Tunables in `config/game.yml` under `boss:` (`slayer_seconds`, `afterglow_days`).
- Privacy: only aggregates and the viewer's own total are ever read for display; the card never shows another person's name, avatar, id or damage. `bosses` has no user reference.
- Development only: `/dev/boss` shows the real card for you; `?state=in_progress|defeated|escaped|none&percent=<health left>` shows a made-up boss.

## Shop, coins spending and orders (`app/services/shop`, `app/models/order.rb`)

Spending is locked until the user's identity is verified with Hack Club. Coding, earning and the coin balance are never blocked by it. No address (or phone, or birthdate) is collected: an order is a request and the team messages the person on Slack to arrange delivery.

- `Shop::Spendable.balance(user)` is the total coin balance if `user.verification_verified?`, else 0 (`unlocked?` / `locked?`). Ask this, not `Coins::Balance.total`, when something needs "can this person pay".
- `Shop::Purchase.call(user:, prize_key:, idempotency_key:)` runs in `user.with_lock`: creates the `Order` (price snapshot in `coins`) and the `Coins::Ledger.debit` (kind `purchase`, reference the order) in one transaction. Idempotent on the key (a replay returns the same order, charges nothing more). Raises `Shop::NotVerified`, `InsufficientCoins`, `UnknownPrize`, `FreeItem`, `KeyConflict` (all `Shop::Error`, messages fit to show people).
- `Shop::ClaimSticker.call(user:)`: the free signup sticker, one per user, zero coins, allowed unverified (`Shop::AlreadyClaimed` after that; a partial unique index backs it).
- `Shop::Cancel.call(order:, by:)`: only while `requested`; the owner or an admin; refunds with one `refund` ledger entry (key `shop:refund:<order id>`), exactly once; cancelling again is a no-op. `Shop::Fulfill.call(order:, by:)` (admin only, idempotent, keeps the first `fulfilled_at`).
- `orders`: `user_id` (cascade), `prize_key` (model allowlist `Prize.keys`), `prize_name` and `coins` (snapshots at order time), `kind` purchase/signup_sticker, `status` requested/fulfilled/cancelled, `idempotency_key` (unique per user), `fulfilled_at`, `cancelled_at`; check constraints mirror the model and one signup sticker per user.
- Routes (signed in and onboarded): `/shop`, `/shop/items/:key` (confirmation, makes the idempotency key), `POST /shop/orders`, `/shop/orders`, `PATCH /shop/orders/:id/cancel`, `POST /shop/sticker`. Staff: `/admin/orders` (orange, 404 for non-admins; filter by status and kind; fulfil; cancel with refund; shows display name, Slack id and verification status). Development only: `POST /dev/coins` (the green button on /shop) adds 100 test coins as an `adjustment`.
