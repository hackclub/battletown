# Plan: first game slice (dashboard + boss + streaks)

> Note: this is the original planning document for the first game slice. The slice is now built; the current behaviour is in `docs/CONTRACT.md` and the tunable numbers in `config/game.yml`. Open product questions are tracked in `docs/PLATFORM_BACKLOG.md`.

Status: historical plan (see the note above).
Source tags: [N2] [N3] [N6] [N9] = the team's planning notes, in date order. [C] = the team's planning board. [R] = repo. [A] = an assumption, to be confirmed.
Note: the 11/2 and 11/3 notes describe an earlier role-based "village" economy (farming, doctors, deflation). The 11/6 notes replace it with the boss + shop model, so only 11/6 and 11/9 plus the canvas are treated as current.

## 1. Scope of the first slice

In:
- Dashboard with the boss card, a today panel, and the two streaks (15-minute, daily goal) [N6, N9, C].
- An append-only ledger of coding time, in integer seconds. Hours enter via admin tooling or a Hackatime stub (section 3).
- A weekly boss derived from the ledger, with a "defeated" state.
- The daily-goal streak bonus ramp 5% -> 20% [C, N9], with one auto-applied streak freeze [C].
- Prize progress on the dashboard (payout hours vs `Prize#hours`, [R] `config/prizes.yml`).

Out (each is a later slice):
- **Plinko / minigames**: no dependency on the ledger. The only link is "a ball per 5 minutes coded" [N6], and that can read the ledger later.
- **Shop and currency**: prices are still placeholder [R]. The ledger is designed so a later `purchases` table can debit it.
- **Quests, team and returning bonuses**: quest bonus is flagged "urgent for MVP" in [N9], but its mechanic is undefined. Team bonus needs team data that does not exist.
- **Notifications** (Slack, email, SMS), NPS, ship reminders, metrics, admin UI, sticker fulfillment.
- **Live Hackatime sync**: only the seam and a manual source ship now.

Why this cut: the boss and streaks are the core loop [N6 "Home page loop"]. They are pure functions of one ledger, so they can be built and tested without Hackatime, the shop, or art. Everything out of scope either needs undecided product rules or touches money and shipping.

Slice assumptions:
- Server-rendered dashboard, no new JSON endpoints, no client JS required.
- No new user-facing mutation endpoints. Hours enter only via rake tasks (production) or a development-only route.
- Launch is Friday 2026-11-13 [N9]; run is 1 month with an optional extension [N9, C].

## 2. Open questions that block the spec (with recommended defaults)

| # | Question | Recommended default | Source / ambiguity |
|---|---|---|---|
| Q1 | How are hours credited before Hackatime linking exists? Is launch gated on linking? | Admin-only credit (rake task or CSV import from Hackatime exports). No self-reported hours in production. If Hackatime is not ready by launch, the dashboard shows "the boss awakens" with no hours. | [C] lists "Hackatime auto-link" as a P2 platform task. [N6] says hours come from Hackatime. Nothing says what happens in between. [A] |
| Q2 | Boss HP: fixed 100h for everyone, or scaled to the cohort? | HP is a per-boss column (`hp_seconds`), set by an admin before each week from the sign-up count. Recommend roughly 0.5-1h x expected weekly active users. | [N6] says "1 hour = 1% of a 100-hour boss". 100h is gone in minutes if 300 teens sign up. Unclear if 100h is a global pool or an example. [A] |
| Q3 | What does killing the boss give? Is the boss a payout gate? | No gate. Payout hours (the future currency) accrue regardless. Boss death means a celebration state, a Slack shout-out, and a "Boss slayer" badge for anyone with at least 15 minutes that week. No new cost. | [N6] calls the boss "functionally staggered payouts". [C] lists "Weekly stickers" and "Weekly merch" under Budgeting without saying whether they are boss rewards or streak rewards. Ambiguous. |
| Q4 | Which streak gives what? "Daily goal streak" is "1 merch per week" in [C] but a payout multiplier in [N9]. The 15-minute streak gives a daily sticker [C, N9], "a sticker at a week" [N6], or maybe no daily sticker [N9 transcript fragment]. | Slice 1 tracks streaks and the multiplier only. Sticker and merch eligibility is displayed, not fulfilled. Treat the multiplier as the daily-goal reward; sticker/merch tracks stay out until budgeted. | Direct conflict among [N6], [N9], [C]. Also a cost risk: the bonus ramp stacks with weekly merch, plus daily stickers. Needs one cost model. |
| Q5 | Ramp shape. [C] says Day 1 5%, Day 2 7%, ..., Day 14 20%, Day 15+ 20%. | Store the 14 values as an explicit table in `config/game.yml`. Default generator is linear, rounded to whole percent: `pct(d) = 5 + round((d-1)*15/13)` (5,6,7,8,10,11,12,13,14,15,17,18,19,20). | Internal contradiction in [C]: +2%/day would reach 20% on day 9 (5,7,9,...), not day 14. A linear ramp gives day 2 = 6%, not 7%. Amber must pick. |
| Q6 | What is "the daily goal"? | A global constant, 60 minutes (`config/game.yml`, owner-editable). Not tied to prize or user choice in slice 1. | [N6] says "full daily goal (e.g. 2-3 hrs)", and "resets if prize target is lowered, not raised". How goal derives from the prize is undefined. 2-3h/day is above what most teens will do and conflicts with the program's cost limits. [A] |
| Q7 | What is a "day", and in which time zone? | The user's local calendar date in `users.time_zone` (already collected at onboarding [R]), midnight rollover, falling back to UTC if nil. The date is frozen on each ledger entry at write time. A day is settled at local midnight + 6h grace. | Not stated in any source. Midnight is unfriendly to night-owl teens (a 04:00 rollover is a cheap alternative: one config constant). [A] |
| Q8 | Do the bonus and the freeze affect boss damage? | Boss damage uses raw seconds only. Bonuses affect payout hours only. | [N9]: the multiplier is "toward payout (not a discount)". Silent on boss damage. Raw-only keeps "100h = 100 real hours" honest. [A] |
| Q9 | Freeze mechanics. | One freeze at a time, auto-applied to the first missed day if a streak exists. It protects the daily-goal streak only. It is re-earned after 7 more consecutive goal days. A bridged day does not increment the streak. | [C] says only "1 day streak freeze". Single, one-time, per-week, earned, and purchased are all plausible. [A] |
| Q10 | Rest days. Onboarding collects preferred `coding_days` [R]. | Ignore them for streak purposes in slice 1 (every calendar day counts). They stay reminder-scheduling data. | Sources never say whether non-coding days break a streak. Strict daily streaks are harsh on teens with school. This is a product-tone call. [A] |
| Q11 | Week boundaries and how the boss "resets". | There is no reset. Each boss is a row with `starts_on` and `ends_on` local dates; "this week's boss" is the row covering today's date. Default weeks are 7 days aligned to launch (Fri 11/13-Thu 11/19, ...), 4 rows for the first month. Hours are attributed by each entry's frozen `local_date`. | [C] says "weekly boss battle"; [N2] debated rolling vs fixed end. Launch-aligned avoids a stub first week. Date attribution avoids DST and time-zone instant maths. Mild skew across zones is accepted. [A] |
| Q12 | Overflow hours after the kill, and hours when the boss survives. | Overflow still counts toward personal payout (it is just raw time) and does not carry into the next boss. Displayed as "overkill". A surviving boss simply "escapes": no penalty, hours are still paid. | Not covered in the sources. Carry-over would trivialise next week's boss. [A] |
| Q13 | Rounding. | Integer seconds everywhere. Bonus = `floor(raw * bps / 10_000)`. Display truncates (never rounds up) to 0.1h. A goal day needs `>=` goal seconds. A 15-minute day needs `>= 900`. | Not in the sources. [A] |
| Q14 | Anti-cheat and idle caps. | Trust Hackatime's own heartbeat/idle handling. We add: a hard cap of 12h creditable per local day (clamped, `config/game.yml`), a 24h DB check per entry, and a nightly "outlier" report via rake (over 10h/day). Exclude Hackatime users flagged as untrusted (verify the field exists). IDV is enforced at shipping, not here [C, R]. | [C] mentions "force IDV" at shipping and ship-reminder hour deductions "(?)". Nothing on idle time. [A] |
| Q15 | Who sees whose activity? | Dashboard shows aggregates only ("N adventurers coded today"), no names or avatars. | [N6] wants "community member icons showing who's locked in". That exposes teens' identities and activity. Needs an opt-in and a GDPR decision before it ships. |
| Q16 | Retention and erasure of coding-time data. | `ON DELETE CASCADE` from users. After the program ends, delete per-user ledger rows after 90 days; keep only boss aggregates. | A GDPR request is open [R README, N3]. [A] |
| Q17 | Who owns what? | Treat Amber as platform owner and Armand as shop/design, per the brief and [C] (assuming the [C] initials map AB=Amber, AP=Armand, which I could not verify). | [N9] summary says "Amber on spec/deliverables, Armand on platform build", the opposite of [C]. Confirm before dividing work. |

## 3. Data model

New tables only; `users` needs no change (reuses `time_zone`, `slack_id`, `hca_uid`). All times are UTC `datetime`; "local" dates are `date` columns frozen at write time.

### `bosses`
| column | type | constraints |
|---|---|---|
| id | bigint PK | |
| name | string(60) | not null |
| art_key | string(40) | not null; validated against an allowlist (maps to a same-origin asset) |
| starts_on, ends_on | date | not null; check `ends_on >= starts_on` |
| hp_seconds | integer | not null; check `hp_seconds > 0` (default 360000 = 100h) |
| defeated_at | datetime | null; set once, never cleared |
| timestamps | | |

Indexes and constraints:
- Unique on `starts_on`.
- Exclusion constraint so date ranges cannot overlap: `EXCLUDE USING gist (daterange(starts_on, ends_on, '[]') WITH &&)` (`add_exclusion_constraint`, Rails 8.1 dumps it in schema.rb).

### `hour_entries` (the immutable ledger)
| column | type | constraints |
|---|---|---|
| id | bigint PK | |
| user_id | bigint | not null, FK `users` `ON DELETE CASCADE` |
| source | string | not null; check in (`hackatime`,`manual`,`adjustment`) |
| idempotency_key | string(120) | not null |
| seconds | integer | not null; check `seconds BETWEEN -86400 AND 86400 AND seconds <> 0`; check `source = 'adjustment' OR seconds > 0` |
| local_date | date | not null (user's local date, frozen at write) |
| recorded_at | datetime | not null, default now |
| note | string(200) | null; check non-null when source in (`manual`,`adjustment`) |
| created_by | string(40) | null; operator tag such as `rake:credit` (no personal data) |

Indexes:
- Unique `(user_id, idempotency_key)`.
- `(user_id, local_date)`.
- `(local_date)` for boss sums.

Immutability:
- `readonly?` returns true once persisted; no update path exists.
- Corrections are a new `adjustment` row with negative seconds and a note.
- No DB trigger, because GDPR erasure needs the FK cascade to delete rows.

Idempotency keys:
- Hackatime: `hackatime:<local_date>:<cumulative_seconds_for_day>`.
- Manual: `manual:<operator-chosen token>`.

### `daily_results` (settled day, written once, immutable)
| column | type | constraints |
|---|---|---|
| id | bigint PK | |
| user_id | bigint | not null, FK cascade |
| local_date | date | not null |
| raw_seconds | integer | not null, check `>= 0` |
| quick_met | boolean | not null (raw >= 900) |
| goal_met | boolean | not null |
| freeze_used | boolean | not null, default false |
| quick_streak | integer | not null, check `>= 0` |
| goal_streak | integer | not null, check `>= 0` |
| bonus_bps | integer | not null, default 0, check `0 <= bonus_bps <= 10000` |
| bonus_seconds | integer | not null, default 0, check `>= 0` |
| created_at | datetime | not null |

Constraints:
- Unique `(user_id, local_date)`.
- Check `NOT (bonus_seconds > 0 AND NOT goal_met)`.
- Check `NOT (freeze_used AND goal_met)`.

Later bonuses (team, quest, returning) become a separate `bonus_awards` table with unique `(user_id, kind, local_date)`. The payout balance will be `SUM(hour_entries.seconds) + SUM(daily_results.bonus_seconds) + SUM(bonus_awards.seconds)`.

### Stored vs derived
- **Stored**: raw time (`hour_entries`), settled days (`daily_results`), boss definition and `defeated_at`.
- **Derived at read time**: boss damage (`SUM(seconds) WHERE local_date BETWEEN starts_on AND ends_on`), percent, remaining, current streaks (last `daily_results` row plus today's partial), prize progress, "adventurers today" count.
- **Not stored**: a boss HP counter. A mutable counter would be a hot row under concurrent writes and could drift from the ledger.

### Minimal PII
- The ledger holds only (user, date, duration). No project names, repos, editors, languages or file paths.
- Hackatime sync requests aggregate durations only.
- Add `:note`, `:idempotency_key` to `filter_parameter_logging`.
- `config/game.yml` holds tunables only (goal, ramp table, caps, freeze rules); no per-user data.

### Hackatime integration seam
```ruby
# duck type: Hackatime::Source
def daily_seconds(user:, from:, to:)  # => [Hackatime::DaySeconds(date:, seconds:)]
```
- `Hackatime::NullSource`: returns `[]` (default).
- `Hackatime::CsvSource`: reads a CSV given by path argument (never committed): `slack_id,date,seconds`.
- `Hackatime::HttpSource`: later; keyed by `users.slack_id`, which already exists [R]. Verify the exact API and auth before building. The day boundary Hackatime uses may differ from the user's `time_zone`; if so, trust Hackatime's reported date as `local_date` and document it.
- `Game::Sync.call(user)`: asks the source for days, computes `delta = reported_total - already_credited_for_date`, and calls `Credit` with key `hackatime:<date>:<reported_total>`. If delta < 0 it logs and skips (no automatic clawback).
- `config/game.yml: hours_source: null | csv | http` picks the implementation.

## 4. Domain logic (pure Ruby, `app/services/game/`)

Pure objects take plain values (Date, Integer, Hash) and touch neither the DB nor `Time.current`.

- **`Game::Config`**: `Data.define` loaded via `config_for(:game)`, like `Prize` [R]. Holds `goal_seconds` (3600), `quick_seconds` (900), `daily_cap_seconds` (43200), `grace_hours` (6), `ramp_bps` (14 values), `freeze_regen_days` (7).
- **`Game::Days`**
  - `local_date(instant, zone)` = `instant.in_time_zone(zone).to_date`. The zone is `Time.find_zone(zone) || UTC`.
  - `settles_at(date, zone)` = `zone.local(date.year, date.month, date.day) + 1.day + grace` computed as `zone.local(...next_date...)` (never `+ 24.hours`, which is wrong on DST days) plus grace hours.
- **`Game::BossMath`**
  - `damage(entries_seconds)` = `max(0, sum)`.
  - `percent(damage, hp)` = `min(100, damage * 100 / hp)` (integer floor). 1h on 360000s HP = 1%.
  - `ratio(damage, hp)` = `min(1.0, damage.to_f / hp)` for the `<progress>` value.
  - `defeated?(damage, hp)` = `damage >= hp`.
  - `overkill(damage, hp)` = `max(0, damage - hp)`.
  - `remaining(damage, hp)` = `max(0, hp - damage)`.
- **`Game::BonusRamp`**
  - `bps(streak_day)` = `ramp_bps[min(streak_day, 14) - 1] * 100` (percent -> basis points); returns 0 for `streak_day < 1`.
  - Day 1 = 5%, day 14 and up = 20%.
- **`Game::StreakCalculator.step(state, day)`**: one pure transition.
  - Input state: `goal_streak`, `quick_streak`, `freeze_ready`, `days_since_freeze`.
  - Input day: `raw_seconds`.
  - Output: new state plus `goal_met`, `quick_met`, `freeze_used`, `bonus_bps`, `bonus_seconds`.
  - `goal_met = raw >= goal_seconds`; `quick_met = raw >= quick_seconds`.
  - `quick_streak = quick_met ? quick_streak + 1 : 0` (no freeze on this streak).
  - If `goal_met`: `goal_streak += 1`, `bonus_bps = BonusRamp.bps(goal_streak)`, `bonus_seconds = floor(raw * bonus_bps / 10_000)`.
  - Else if `goal_streak > 0` and `freeze_ready`: `freeze_used = true`, streak unchanged, `bonus_bps = 0`.
  - Else `goal_streak = 0`, which restarts the ramp at 5% on the next goal day.
  - Freeze regen: after `freeze_regen_days` consecutive goal days since last use, `freeze_ready = true` (cap 1).
- **`Game::StreakCalculator.replay(days)`** folds `step` over settled days from the user's first day, for tests and consistency checks.
- **Bonus timing**: the bonus for day D is computed at settlement (after local midnight + grace), over all raw seconds of day D. Awarded only if day D met the goal. The dashboard shows today's likely bonus as "pending until the day closes".

Impure services:
- **`Game::Ledger::Credit.call(user:, source:, idempotency_key:, seconds:, local_date:, note: nil, created_by: nil)`**
  - Runs inside `user.with_lock` (same pattern as `OnboardingsController#complete` [R]).
  - Clamps positive seconds to `daily_cap - already credited that date`.
  - Inserts; on `ActiveRecord::RecordNotUnique` returns the existing row marked duplicate.
  - Then calls `Game::Boss::CheckDefeat`.
  - Rejects `local_date` older than 3 days unless source is `adjustment`.
- **`Game::Boss::CheckDefeat(boss)`**: computes damage; if `defeated?`, runs `boss.with_lock` and `UPDATE ... SET defeated_at = now WHERE id = ? AND defeated_at IS NULL`.
- **`Game::Settle.call(user, through: today)`**: under `user.with_lock`, for each unsettled local date whose `settles_at` has passed, loads that day's raw seconds, runs `step`, inserts a `daily_results` row (unique index is the idempotency backstop). Dashboard calls it lazily, and `rake game:settle` is the ops path. It does not depend on Solid Queue [R: production queue DB migrations are not present in `db/`].
- **`Game::DashboardPresenter`**: read model for the view.
  - Fields: `boss` (name, art_key, percent, ratio, remaining_seconds, ends_on, state), `today` (raw_seconds, goal_seconds, quick_met, goal_met, projected_bps), `streaks` (quick, goal, best, freeze_ready, freeze_used_yesterday, state), `prize` (progress ratio), `community` (active_today_count), `hours_linked?`.
  - `boss.state` is one of `:none`, `:in_progress`, `:defeated`, `:escaped`.
  - `streaks.state` is one of `:empty`, `:active`, `:broken`, `:frozen`.

### Edge cases to unit test
- **DST**
  - America/New_York fall back 2026-11-01 (25h day): entries at 04:30Z, 05:30Z, 06:30Z map to the right local dates; `settles_at` is correct.
  - Spring forward 2027-03-14 (23h day).
  - A zone whose DST gap is at midnight (e.g. America/Havana): `local(...)` still returns a valid instant.
- **Zones**: Pacific/Kiritimati (+14) vs Pacific/Pago_Pago (-11) for the same instant; Asia/Kolkata (+5:30); Asia/Kathmandu (+5:45); nil and invalid zone -> UTC.
- **Zone change mid-streak**: existing `local_date`s are frozen and do not shift.
- **Boundaries**
  - Entry at 23:59:59 vs 00:00:00 local.
  - `local_date == starts_on`, `== ends_on`, and `ends_on + 1` (belongs to the next boss or none).
  - A gap between bosses; no active boss.
  - Overlapping boss rows rejected by the exclusion constraint.
- **Boss math**
  - Damage exactly equal to HP (defeated).
  - One second short (not defeated; percent 99).
  - Overkill.
  - Negative adjustment dropping a boss below HP after defeat (`defeated_at` stays set).
  - 1h on 100h = 1%; 36s = 0%.
- **Streaks**
  - 899s vs 900s; goal -1s vs goal.
  - Streak days 1, 2, 14, 15, 30 (bonus 5%, 6%, 20%, 20%, 20% with the default ramp).
  - Miss resets to 5%.
  - Freeze consumed once, not on two consecutive misses.
  - Freeze regen after 7 days.
  - A frozen day does not increment.
  - First-ever day.
  - Late Hackatime data after settlement (raw credited, `daily_results` unchanged).
  - A user onboarded mid-day.
- **Rounding**: `floor` of `raw * bps / 10000` for odd values (e.g. 3599s x 500 bps = 179).
- **Idempotency and concurrency** (use `self.use_transactional_tests = false` plus cleanup for thread tests)
  - Same key twice -> one row.
  - Two threads crediting the same user -> serialized, daily cap respected.
  - Two threads crossing HP -> `defeated_at` set exactly once.
  - `Settle` run twice, and in parallel -> one `daily_results` row per day.
- **Anti-cheat**: clamp at the 12h cap, the 24h entry check, negative seconds on non-adjustment rejected.

## 5. UI (dashboard)

Existing: `app/views/dashboard/show.html.erb` shows a welcome, the chosen prize, and "Boss battle coming soon" [R]. Replace the placeholder with sections:

1. **Header**: "Welcome, <name>" (existing), plus prize progress using a native `<progress>`.
2. **Boss card**: name, art (same-origin image from `app/assets/images/bosses/`; a text/emoji-free placeholder when art is missing, since art is due 11/11 [N9]), HP as `<progress value max>` with a visible text alternative ("Boss at 62% health, 38 hours to go. Week ends Thursday"). Date text, not a live countdown.
3. **Today panel**: minutes coded vs goal (a `<progress>`), whether the 15-minute mark is hit, projected bonus ("Hit your goal today for +5%, day 1"), one primary "Start coding" action. The Hackatime link target is a config URL (unknown; ask). If hours are not linked, the panel shows a "Connect Hackatime (coming soon)" note rather than a dead button.
4. **Streaks**: two cards, "15-minute streak" and "Daily goal streak" (day N, ramp %, freeze status in text).
5. **Community**: "N adventurers coded today" (aggregate only, Q15).

States to render:
- **Empty**: no hours yet; copy "Code for 15 minutes to start your streak."
- **In progress**: boss alive, streaks active.
- **Boss defeated**: success banner (`role="status"`), full bar, overkill text, "Boss slayer" badge if the user contributed at least 15 minutes that boss week.
- **Boss escaped**: last week's boss shown briefly, supportive copy, no penalty.
- **No active boss** (pre-launch, between weeks, program ended).
- **Streak broken**: neutral, encouraging copy ("A fresh start. Your best was N days."), never shaming.
- **Freeze used**: "Your freeze kept your streak alive."
- **Hackatime not linked**.

Accessibility:
- One `h1`, then `h2` per section; native `<progress>` with an associated label plus a text value, so meaning never depends on color alone.
- All emoji or icons `aria-hidden` with text equivalents.
- `prefers-reduced-motion` respected for any bar or celebration animation.
- Visible `:focus-visible` (already in tokens).
- Works at 320px.
- Use design tokens only [R].

CSP constraints [R docs/CONTRACT.md]:
- No `style=""`, no inline `<script>`/`<style>` without `nonce: true`.
- Bar widths via native `<progress>`, not inline width.
- Images same-origin or `data:`.
- Any external "Start coding" link is a plain navigation (allowed; `connect-src` is not involved), with `rel="noopener"`.
- No third-party scripts, fonts, or embeds.
- New CSS goes in `app/assets/stylesheets/dashboard.css` (propshaft picks it up).
- No JS is required for slice 1. A celebration Stimulus controller can come later, and sound must be same-origin media.

## 6. Work breakdown

Interface contract shared by all tasks: the table/column definitions in section 3, the pure service signatures in section 4, and the presenter shape in section 4. T2 and T5 can start immediately against those without waiting for T1.

| Task | Owns (files) | Acceptance tests | Depends on |
|---|---|---|---|
| **T1 Schema, models, config** | `db/migrate/*` (bosses, hour_entries, daily_results), `db/schema.rb`, `app/models/{boss,hour_entry,daily_result}.rb`, `config/game.yml`, `app/services/game/config.rb`, `test/fixtures/{bosses,hour_entries,daily_results}.yml`, `test/models/{boss,hour_entry,daily_result}_test.rb` | Check constraints reject bad rows; unique and exclusion constraints; ledger rows are read-only; user deletion cascades; fixtures load | none |
| **T2 Pure domain** | `app/services/game/{days,boss_math,bonus_ramp,streak_calculator}.rb`, `test/services/game/*_test.rb` | Every edge case in section 4 for DST, zones, boundaries, rounding, ramp, freeze, reset | none (uses `Game::Config` struct; stub it until T1 lands) |
| **T3 Ledger services, Hackatime seam, ops tasks** | `app/services/game/{ledger/credit,boss/check_defeat,settle,sync}.rb`, `app/services/hackatime/*`, `lib/tasks/game.rake` (`credit`, `import_hackatime`, `settle`, `report`), seed for 4 launch-aligned bosses in `db/seeds.rb` | Idempotent credit; cap clamping; concurrent credit and settle tests; `defeated_at` set once; `NullSource` and `CsvSource` behaviour; rake tasks are idempotent | T1, T2 |
| **T4 Dashboard controller and presenter** | `app/controllers/dashboard_controller.rb`, `app/services/game/dashboard_presenter.rb`, `config/routes.rb` (development-only hours route, mirroring `dev_login`), `test/controllers/dashboard_controller_test.rb`, `test/services/game/dashboard_presenter_test.rb` | Presenter returns each state (none/in_progress/defeated/escaped; empty/active/broken/frozen); `Settle` is invoked lazily; no data about other users; the dev route 404s outside development | T1 (fixtures), T2 interfaces |
| **T5 Dashboard views, CSS, a11y** | `app/views/dashboard/{show,_boss,_today,_streaks,_community}.html.erb`, `app/assets/stylesheets/dashboard.css`, `test/integration/dashboard_states_test.rb` | One integration test per state; `<progress>` present with label and text; no `style=` attributes; heading order; copy says "Hack Club" correctly | T4 contract (can build against a fake presenter) |
| **T6 Privacy, security hardening, docs** | `app/views/pages/privacy.html.erb`, `config/initializers/filter_parameter_logging.rb`, `config/initializers/rack_attack.rb`, `test/integration/{access_test,log_privacy_test,rack_attack_test}.rb` additions, `README.md`, `docs/CONTRACT.md` additions | Unauthenticated and non-onboarded users cannot see the dashboard; cross-user data never rendered; new POST throttled; privacy page discloses coding-time data; `bin/ci` is green | T1 |

No file is owned by more than one task. Recommended order: T1 and T2 in parallel first, then T3 and T4, then T5, with T6 alongside T3-T5.

## 7. Security, privacy, risks

- **Authorization**: `DashboardController` keeps `require_login` and `require_onboarded` [R]. Presenter queries are scoped to `current_user.id`; add a test that user A's entries never appear for user B. No endpoint accepts a user id or a `local_date` from the client.
- **No client-driven mutation**: slice 1 has no production endpoint that writes hours. Rake tasks require server access. The development-only route returns 404 elsewhere, like `dev_login` [R].
- **Admin path**: there is no admin role in the app. Do not add one in this slice. If an admin UI is added later, use an HCA-uid allowlist from env and audit-log every adjustment (the `note` and `created_by` columns already support this).
- **Rate limits**: add a `rack-attack` throttle for any new POST. Note the store is in-process, so limits are per-process [R `rack_attack.rb`].
- **Race conditions**: `user.with_lock` serializes per-user credit and settle; unique indexes are the backstop; `defeated_at` is set with a conditional UPDATE. No hot counter row.
- **Time**: all arithmetic uses calendar dates and `zone.local`, never `+ 24.hours`. The time-zone-change abuse vector (changing zones to gain extra days) is limited by frozen `local_date`s; also consider restricting zone changes after onboarding to once per 7 days (Q7).
- **Cheating**: ledger daily cap, outlier report, untrusted-user exclusion (verify Hackatime exposes this). A stronger control is IDV before first payout [C "force IDV"].
- **Cost risk**: the ramp, weekly merch and daily stickers stack (Q4). Work out the worst case per user per week before launch.
- **Product risk**: Q2 (HP scaling). A boss that dies in minutes, or never, undermines the loop. Make `hp_seconds` adjustable before a boss starts.
- **GDPR / minors**: new data is per-day coding durations for teens. Update the privacy page; define retention (Q16); keep the cascade delete tested; show no peer identities (Q15); keep project names out of the ledger.
- **Hackatime day mismatch**: if Hackatime's day boundary differs from the user's `time_zone`, streaks could disagree with what users see. Verify before building `HttpSource`.
- **Dependency risk**: art is the launch critical path (due 11/11) [N9]. The boss card must work with a placeholder image.
- **Queue**: no job infrastructure is assumed. Lazy settlement and rake tasks avoid a dependency on Solid Queue being provisioned.

## Questions for Amber

1. Is launch gated on Hackatime linking, and how are hours credited until it exists (default: admin-only credit, no self-reporting)?
2. Boss HP: fixed 100h or scaled to sign-ups (default: per-boss `hp_seconds` set by an admin)?
3. What does killing the boss give, and is the daily-goal streak reward the multiplier or the weekly merch (notes and canvas conflict; stacked cost risk)?
4. Which ramp is right (canvas says Day 2 = 7% but Day 14 = 20%, which can't both hold linearly), and what is the daily goal?
5. What counts as a day (local midnight vs 4am rollover), and what are the freeze and rest-day rules?
