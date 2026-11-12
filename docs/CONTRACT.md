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
- `User#admin?` is true only when the user's `hca_uid` (the Hack Club Auth `sub`) is in the comma-separated `ADMIN_HCA_UIDS` env var (`AdminAllowlist`: whitespace trimmed, blanks ignored, exact case-sensitive match, empty or unset = nobody). It is read at call time and re-checked from the database user on every request, so removing an id takes effect on the next request or deploy. Admin pages live under `/admin` (`Admin::BaseController`): signed-out visitors and non-admins get the same 404 as an unknown path (never a redirect, no hint the area exists), responses are `Cache-Control: no-store`, and the dashboard is read-only aggregates with no PII (`AdminStats`); the ship review queue is the one place that shows a teen's display name (never email, Slack id or Hack Club Auth id). The gate is server-side only: `admin_tool` just hides UI, the controller must also refuse. Title: `content_for :title, "Admin"`. Locally, `ADMIN_HCA_UIDS=dev-user` makes the Dev login user an admin.
- Dev-only UI today: the "Dev login" chip in the header (signed-out visitors, once per page), `/dev/hours`, `/dev/boss` and the shop's test-coins button. Admin-only UI: the "Admin" header link and everything under `/admin`. Small staff chips drop their button chrome; buttons inside a staff page or panel look like normal buttons.

## Admin metrics (`/admin/metrics`, `AdminMetrics`, `Admin::MetricsController`)

Read-only, aggregate counts only (no names, emails or ids), linked from the admin dashboard, 404 for everyone but admins. `AdminMetrics.call(today:)` runs one grouped SQL query per table (4 in all, whatever the number of users).

- **Active**: a user is active on a local date when their net ledger seconds that date (credits plus adjustments) reach the 15-minute streak threshold (`streaks.quick_minutes`, `Game::Config.current.quick_seconds`). Dates are the frozen `hour_entries.local_date`; "today" is the UTC date, and its row is still filling in.
- **Daily** (last 28 days): active users per date, and hours coded (each user's net seconds that date, floored at zero, summed).
- **Weekly** (last 8 weeks): distinct users active on at least one date in the week. Weeks run Friday to Thursday, like the boss; the newest is the current week.
- **Funnel** (all-time, each step counted on its own, % of all users): signed up; onboarded (`onboarded_at`); connected Hackatime (a connection now, or any `hackatime` ledger row); first coded day (any active day); first ship submitted (`submitted_at` set, whatever happened next); first ship approved; first purchase (a `purchase` order not cancelled; the free sticker is not one).
- **Last active day**: everyone ever active, by days between today and their most recent active date: today, 1 to 14, more than 14. Local dates after today are ignored.

## Header navigation (`app/views/layouts/application.html.erb`)

Signed-in, onboarded users get `<nav aria-label="Main">`: Dashboard, Projects, Ships, Shop, then a native `<details class="site-menu">` "Settings" holding Hackatime and Notifications (no JavaScript). Admin and Sign out sit in `.site-header__account` (signed-out visitors get Sign in and the Dev login chip there). Use `nav_link(label, path)` (`ApplicationHelper`) for a header link: it adds `aria-current="page"` on the current section. New top-level pages go in the Main nav only if they are everyday pages; everything else goes under Settings.

## Security conventions (enforced by `test/integration/route_security_test.rb`, which reads the router)

- Every `/admin` route answers 404, never a redirect, for signed-out visitors and non-admins.
- Every user-scoped record (projects, links, link suggestions, ships, orders) is looked up through `current_user`; someone else's id is a 404.
- Every POST, PATCH, PUT and DELETE route has CSRF protection, except `/api/privacy/*` (bearer-token JSON API).
- Only the Rails frameworks the app uses are loaded (`config/application.rb`): no Active Storage, Action Mailbox or Action Text, so no `/rails/...` upload or inbound-email endpoints.
- Logs carry no email, name, Slack id, tokens or free text (`test/integration/full_flow_log_privacy_test.rb`; `config/initializers/filter_parameter_logging.rb`).

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

Append-only `hour_entries` (seconds per user per frozen local date; `HourEntry` is read-only once saved, corrections are `adjustment` rows). Tunables are in `config/game.yml` under `hours:` (`daily_cap_seconds`, `max_backfill_days`, `active_seconds`, `days_before_signup_counted`; add other features as their own top-level key).

- Write: `Hours::Credit.call(user:, seconds:, source:, idempotency_key:, local_date: nil | at: nil, hackatime_project: nil, note: nil, created_by: nil)` returns a `Result` (`entry`, `status` in `:created :clamped :duplicate :capped`, `credited_seconds`). Raises `Hours::Credit::Rejected` for input that can never be credited.
- Sign-up cutoff: hours count for the game only from `Hours::Days.first_counted_date(user)`, the local date the account was created on (in the user's zone; minus `days_before_signup_counted`, default 0). The sign-up date counts fully for everything; earlier dates (Hackatime backfill) stay in the ledger but give no boss damage, streak day, coins (they are left out of ship windows) or dashboard time. Every `Hours::Totals` read below applies it (the all-users ones in SQL), as do `Game::Settle`, `Dashboard::Streaks`, `Ships::Window` and `Coins::ApproveShip`; only `.ledger_seconds_by_date` (the development ledger page) reads the raw rows.
- Read: `Hours::Totals.seconds_by_date(user, range)`, `.seconds_for_date(user, date)`, `.seconds_in_range(range)` (all users), `.active_user_count(date)`. Dates are the frozen local dates; `Hours::Days.local_date(instant, user)` / `.today(user)` do the zone maths.
- Hackatime seam: `Hackatime::Source#daily_seconds(user:, from:, to:)`, `Hackatime::NullSource` (default), `Hackatime::CsvSource.new(path)`; `Hours::Sync.call(user_or_rows, ...)`. Rake: `hours:import[path]`, `hours:credit[slack_id,date,seconds,note]`.
- Development only: `/dev/hours` adds minutes to the signed-in user for a local date (404 elsewhere).

## Weekly boss (`app/services/bosses`, `app/models/boss.rb`, `app/views/bosses/_card.html.erb`)

One `bosses` row per week (Friday to Thursday, dates inclusive and never overlapping): `name`, `art_key` (allowlist `Boss::ARTS`, image at `app/assets/images/bosses/<key>.webp`), `starts_on`, `ends_on`, `hp_seconds`, `defeated_at`. Damage is never stored: it is the sum of ALL users' raw coded seconds on the local dates inside the week (`Bosses::Damage.for(boss)`, from `Hours::Totals.seconds_in_range`), leaving out each user's dates before they signed up (the sign-up cutoff above). Health is set per boss by an admin at `/admin/bosses` and is editable until the boss starts; dates are fixed. `bin/rails bosses:seed` (and `db/seeds.rb`) create the four launch weeks idempotently and never overwrite an edited boss.

- `Bosses::BossMath` (pure): `damage(sum)`, `percent` (integer floor, capped 100), `ratio` (capped 1.0), `remaining`, `overkill`, `defeated?`. Overkill is shown and never carried over.
- `Bosses::Current.for(date)` / `.for_user(user)`: the boss covering that local date, or `:none`.
- `Bosses::CheckDefeat.call(boss)`: sets `defeated_at` once (under `boss.with_lock`, conditional `UPDATE ... WHERE defeated_at IS NULL`) when damage >= health; it is called from `HourEntry` after commit for the bosses covering the entry's date, and a later correction never clears it.
- `Bosses::Presenter.new(user:, today: nil)` returns plain values for the view: `state` (`:none :in_progress :defeated :escaped`), `boss_name`, `art_path`, `art_alt`, `health_percent` / `health_ratio` (what is left, for the bar), `health_text` (the words beside the bar: "Full health" before any hit, "Under 1% damage" while the floored percent is still 0, else "38% left"; never "100% left"), `damage_percent` / `damage_ratio`, `remaining_seconds`, `hours_to_go_text` ("about 190 hours to go", truncated), `overkill_seconds` / `overkill_text`, `days_left` (calendar, includes today), `ends_on`, `end_day_name`, `summary` (the text alternative), `user_slayer?` (>= `boss.slayer_seconds` of the user's own coded time in that week, boss down), `community_active_today` / `community_text` (a count, never names), `contributed_seconds_this_week` / `contributed_text` (the viewer's own only). A surviving boss "escapes" with no penalty.
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

## Ships and review (`app/models/ship.rb`, `app/services/ships`, `ShipsController`, `Admin::ShipsController`)

A ship asks staff to turn the time coded on one project since its last ship into approved hours and coins. Coins come from APPROVED hours only; coding is never blocked.

- `Ship`: `user`, `project` (same-owner composite key), `status` draft/submitted/approved/rejected/withdrawn (DB check), `description` (1..1000, needed to submit), `repo_url` (GitHub repo, https, needed to submit; defaults from the project) and optional `demo_url` (https), `coded_seconds` plus `window_start_date`, `window_end_date` and `daily_seconds` (`{ "2026-11-09" => 3600 }`) frozen when the ship is saved, `approved_seconds` (set only when approved, `0 < n <= coded_seconds`), `reviewer` (staff user, nulled when that user is deleted), `reviewed_at`, `rejection_reason` (<= 300, set only when rejected), `payout_note` (<= 300, set only when approved), `submitted_at`. The coin credit is not stored on the ship: `ship.coin_breakdown` reads the `Coins::Ledger` rows that reference it (`{ base:, bonus:, total: }`). One open (draft or submitted) ship per project, enforced by a partial unique index. Deleted with the user and with the project; a project with a waiting or approved ship cannot be deleted from the UI (`project.deletable?`), archive it instead.
- `Ships::Window.call(project)` returns `{ seconds:, start_date:, end_date:, hours_since_previous_ship_before_window:, seconds_by_date: }`: ledger entries whose `hackatime_project` is linked to the project, on local dates after the previous submitted or approved ship's `window_end_date` (a rejected or withdrawn ship gives its window back). The last value is always 0 (the window is everything since the previous ship). No linked Hackatime project or no hours means it cannot be shipped. Whole local dates are the unit: time coded on a ship's last date after it was submitted belongs to no ship.
- `Ships::Submit.call(project:, attributes:, submit:, ship: nil)` (under the project row lock; raises `NoHackatimeLink`, `NoHours`, `TooFewHours`, `AlreadyOpen`, `NotEditable`), `Ships::Withdraw.call(ship:)`, `Ships::Reject.call(ship:, reviewer:, reason:)`, `Ships::Approve.call(ship:, reviewer:, approved_seconds:, now:)`. Approval runs in one transaction under `ship.with_lock` with the status checked again, then calls `Coins::ApproveShip` (idempotent by the ship reference) with the ship's own snapshot as the hours source, so two admins or a double click credit once. `Ships::Approve.unsettled_dates(ship)` lists window days still inside the settling grace period (no bonus for them yet); an approval records them in `payout_note`. The user's verification status never blocks a ship or its credit: unverified users see "your coins unlock when you verify your identity with Hack Club" (the same Hack Club Auth link as onboarding) wherever approved coins are shown, and the shop enforces spending.
- Tunables in `config/game.yml` under `ships:` (`min_hours`, `approval_step_hours`, `rejection_reasons`), read through `Ships::Config.current`.
- Routes (signed in and onboarded; other users' ids are a 404): `GET /ships`, `GET /ships/:id`, `GET|PATCH /ships/:id/edit` (drafts), `PATCH /ships/:id/withdraw`, `GET /projects/:project_id/ships/new` (`?from=<rejected ship id>` pre-fills a fix), `POST /projects/:project_id/ships` (`ship_action=draft|submit`). Staff (orange `admin_tool`, 404 for everyone else): `GET /admin/ships` (waiting first, oldest first, `?status=`), `GET /admin/ships/:id`, `PATCH /admin/ships/:id/approve` (`approved_hours`, blank = all coded, can only be lowered, in steps), `PATCH /admin/ships/:id/reject` (`reason_preset` and/or `reason_note`).
- Events (`ActiveSupport::Notifications`, payload is the ship id only, never a name or text; fired after the change is saved; the Slack reminder task can subscribe, the ship code sends nothing): `ship_submitted.battletown` (`ship_id:`), `ship_approved.battletown` (`ship_id:`), `ship_rejected.battletown` (`ship_id:`).
- Staff can never approve or reject their own ship: `Ships::Approve::OwnShip` / `Ships::Reject::OwnShip` (kinds of `Invalid`, friendly message), and the admin page shows no forms for it.
- A ship's submitted date is shown in the teen's local time zone (`ship_submitted_on`), so it lines up with the window's local dates.
- Not built yet: screenshot uploads (needs storage and CSP decisions).

## Notifications (`app/services/notifications`, `app/models/notification.rb`, `Settings::NotificationsController`)

Slack DMs only (no email or SMS, no buttons: the Slack app has `chat:write` and nothing else, so every message that needs an answer links to the web page that handles it). Coding is never blocked and the copy never shames. A message is an outbox row (`notifications`: `kind`, `subject_id`, `idempotency_key`, status); no text and no address is stored, the dispatcher builds the text from `config/notifications.yml` and reads `users.slack_id` when it sends.

- Kinds (`Notification::KINDS`, mirrored by a check constraint): `daily_reminder` (the user's coding days and time, `Notifications::Scheduler`), `link_question` (a Hackatime project may match one of their projects; links to `/projects`, where yes or no is answered and a no is never asked again), `ship_reminder` and `ship_mvp` (links to the ship form), `ship_approved` (approved hours, coins, and the "your coins unlock when you verify your identity with Hack Club" note when unverified; links to the ship) and `ship_rejected` (the reviewer's reason and a link that pre-fills the fix). Links are built on `APP_URL`. The copy in `config/notifications.yml` is placeholder wording the owner edits (`{project}`, `{hours}`, `{coins}`, `{reason}`, `{unlock_note}`, `{link}`); values are one line, shortened and escaped for Slack.
- Thresholds: `ships.reminder_hours: [5, 10]` in `config/game.yml` (hours coded on a project since its last counted ship, per `Ships::Window`): the first is the `ship_reminder`, the second the `ship_mvp` nudge. Only the highest threshold reached is queued, once per project per ship window (key `<kind>:<project id>:<window start>:<threshold>`; the window start is the day after the previous submitted or approved ship's last day, `first` for none), so the next ship starts a new window and can nudge again.
- Events consumed (`Notifications::Triggers`, subscribed once at boot in `config/initializers/notification_triggers.rb`; handlers only create or cancel outbox rows, run in a savepoint and swallow errors, logging the class name only): `project_link_suggested.battletown` (one `link_question` per suggestion, key `link_question:<suggestion id>`), `ship_approved.battletown` / `ship_rejected.battletown` (one decision DM per ship, key `ship_decision:<ship id>`), `ship_submitted.battletown` (no message; pending ship reminders for that project are cancelled).
- The scan: `Notifications::ShipReminders.scan(now:)` (rake `notifications:ship_reminders`, every 15 minutes) queues the reminders for projects whose hours crossed a threshold. Safe to repeat; one bad project never stops the rest. `Notifications::Outbox.enqueue(user:, kind:, subject_id:, key:)` is the single door into the outbox: it returns nil, not an error, for a person with no Slack id, who has not finished onboarding or who switched that kind off.
- Preferences: table `notification_preferences` (`user_id` cascade, `kind` allowlist, `enabled`; unique per user and kind; no row means on). `Notifications::Preferences.enabled?(user, kind)` is checked before any row is created and again by the dispatcher just before sending (an opt-out after queueing cancels the row with `opted_out`). Screen `/settings/notifications` (`settings_notifications_path`, signed in and onboarded, a plain form, `PATCH` throttled by rack-attack, only the signed-in person's own switches); labels come from `preference_labels` in `config/notifications.yml`.
- The daily reminder is queued by `Notifications::Scheduler.refresh(user)` (`schedule_next` that never raises) when onboarding finishes, when the schedule step is saved, when a sign-in changes the Slack id, and when the daily switch is saved.
- Quiet hours (default 22:00 to 07:00 in the person's zone) move a send to the end of the window. Event messages older than `event_max_lateness_seconds` (two days) are dropped, and the dispatcher cancels a row whose subject is gone or no longer true (`subject_gone`: a question already answered, a project shipped meanwhile).
- Staying dark: `Notifications::Dispatcher` does nothing unless `NOTIFICATIONS_ENABLED` is exactly `true`, refuses to run in production without a bot token, and tests and development use the null and log adapters (never the network). Queued rows simply wait (and expire) until the switch is on.
- Statuses: `pending`, `sent` (only when the real Slack adapter got an ok), `failed`, `cancelled`, and `skipped`: handled by an adapter that does not deliver (the log adapter in development without `SLACK_BOT_TOKEN`, the null adapter in tests), `last_error_code` `not_delivered`, no `sent_at`. A skipped daily reminder still queues the next one, so the pipeline can be exercised end to end without messaging anyone. The dispatch summary and `notifications:dispatch` report `skipped=` next to `sent=`.
