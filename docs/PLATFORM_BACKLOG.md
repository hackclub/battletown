# Platform backlog

What the platform has, and what is still open. Design, art, shop content and marketing are out of scope here.

Status key: **built** (works end to end and is tested), **partly built** (the useful core exists, the rest is named), **blocked** (needs access or a decision from outside the code), **owner-decision** (a product rule is still open; the decision is named), **not started**.

Rules that apply to everything: never hard-block someone from coding (soft friction only); no identity check before someone ships (verification only gates spending coins); never auto-link a low-certainty Hackatime project without asking; referrals by path only; shop prices are the same for everyone; users are teens, so minimise personal data.

## Features

| # | Feature | Status | Notes |
| --- | --- | --- | --- |
| 1 | Onboarding (prize, project, schedule, account check, celebration) | **built** | Five steps; the project step creates the first project; the time zone defaults from the Hack Club Auth address. Identity status is shown, not enforced. |
| 2 | Hackatime linking | **built** (live access **blocked** until the OAuth app is registered) | `/hackatime` OAuth connect, encrypted tokens, `Hackatime::Client`, per-day sync. Projects are linked by name or auto-linked on a matching GitHub repository; a low-certainty match asks the teen first ("is this yours?"). `docs/HACKATIME.md`. Needs `HACKATIME_CLIENT_ID` and `HACKATIME_CLIENT_SECRET`, and `HOURS_SOURCE=http` to read live hours. |
| 3 | Hours ledger | **built** | Append-only `hour_entries` with a daily cap and a short back-fill window; sources are Hackatime, manual (development page) and adjustments. |
| 4 | Projects | **built** | Several projects, one active; Hackatime links; archive and delete. |
| 5 | Streaks and coins | **built** | A day settles shortly after local midnight into an immutable `daily_results` row (`bin/rails game:settle`); 15-minute streak with a bonus ramp and one freeze; a 60-minute daily-goal streak counter; coins credited from approved hours plus a streak bonus. Numbers live in `config/game.yml`. |
| 6 | Weekly boss | **built** | Friday to Thursday bosses; damage is the sum of everyone's coded time on the boss's dates; defeat state, "Boss slayer" badge, admin editing of health before a boss starts (`bin/rails bosses:seed`). Art is a placeholder until the artwork lands. |
| 7 | Ship flow and staff review | **built** | Ship a project from the project list; staff approve (hours can only be lowered) or reject with a reason in `/admin/ships`; staff cannot review their own ship; approval pays coins once. Streak days still inside the settling grace period are flagged to the reviewer. |
| 8 | Shop and orders | **built** (final items and prices **owner-decision**) | Prices in coins from `config/prizes.yml`; coins stay locked until the teen is verified; orders are requests the team fulfils on Slack; cancelling refunds; a free sign-up sticker claim. `/admin/orders` to fulfil or cancel. |
| 9 | Dashboard | **built** | Boss, today, streaks, coins, active project, Hackatime state and prize progress. |
| 10 | Slack notifications | **built** (real sending **blocked** on a Slack bot token) | Outbox table with a null/log adapter; daily reminder, link question, ship reminders at the configured hour thresholds, ship decisions, and (behind flags) the welcome-back nudge and the survey prompt; per-person switches at `/settings/notifications`. Nothing is sent unless `NOTIFICATIONS_ENABLED=true` and a token exists. `docs/SLACK_APP.md`. |
| 11 | Admin area | **partly built** | Aggregate dashboard, bosses, orders, the ship queue, user management (search, a person's page, audited hours and coin adjustments, private notes) and an audit trail, gated by `ADMIN_HCA_UIDS` (everyone else gets a 404). A project review queue and richer metrics are not started. |
| 12 | Data deletion and export (Hack Club "yeet" protocol) | **built** (registration is an owner task) | `docs/PRIVACY_API.md`. |
| 13 | Referrals by path | **built** | `config/referrals.yml`; first touch recorded at sign-up. Custom referral events and user referrals are **owner-decision**. |
| 14 | Production readiness | **built**, unproven on a real deploy | Shared cache store, trusted proxies, host allowlist, health check, documented variables (`docs/DEPLOY.md`). Nothing has been deployed from this repository yet. |
| 15 | Email and Slack id encrypted at rest | **owner-decision** | Hackatime tokens are encrypted already. Encrypting email and Slack id needs a key-rotation plan and affects lookups by Slack id. |
| 16 | Guides (ideation help) | **owner-decision** | Placeholders in the onboarding project step until content exists. |
| 17 | Crews and the crew coin bonus | **built, flagged** (`team`) | Invite link, display names only, bonus paid at ship approval on days a crewmate also coded. Needs cron `team:pay_pending`. What a crew is beyond that stays an **owner-decision**. |
| 18 | Weekly quests | **built, flagged** (`quests`) | One quest per boss week chosen by staff from a fixed menu; reward paid with the next approved ship. |
| 19 | Welcome-back boost and Slack nudge | **built, flagged** (`returning`) | Streak-bonus floor for three days after a comeback, one nudge per idle period. |
| 20 | Plinko (daily toy) | **built, flagged** (`plinko`) | Balls from coded minutes, server-decided drops, opt-in nickname leaderboard; awards no coins. The final decision on a real minigame stays with the owner. |
| 21 | Ship screenshots | **built, flagged** (`ship_screenshots`) | Up to three images per ship, re-encoded, owner and staff only. Needs libvips and `MAX_REQUEST_BODY` (docs/DEPLOY.md). |
| 22 | Weekly merch track | **built, flagged** (`merch_track`) | Goal days in a boss week earn that week's item; claim needs verification (and the eligibility gate when on) and an approved ship. Items are placeholders. |
| 23 | Email notifications | **built, flagged** (`email`); real sending **blocked** on an SMTP account and a sender domain with SPF and DKIM | Ship decisions and the welcome-back note, one-click unsubscribe. SMS stays **owner-decision**. |
| 24 | NPS survey | **built, flagged** (`nps`); sending **blocked** on the Slack bot token | One-click survey page, staff results, comments emptied after 90 days (cron `nps:prune`). Who may read the comments is decided as staff-only. |
| 25 | Eligibility gate on spending | **built, flagged** (`eligibility_gate`) | Spending also needs YSWS eligibility and a recent sign-in. A real periodic re-check against Hack Club Auth is **not started** (needs an API call and credentials). |
| 26 | Daily sticker rewards | **not started** | Needs a product rule: which streak earns a physical reward. |
| 27 | Metrics (daily active users, hours coded, drop-out funnel) | **partly built** | The admin dashboard shows signups, the onboarding funnel and verification counts; daily active users and hours coded are not shown yet. |

## Decisions the owner still has to make

- The game rules that are still open (which streak earns a physical reward, whether a boss defeat gives anything beyond the celebration).
- The final shop items and prices.
- Whether identity verification should also gate anything beyond spending coins.
- Email and SMS policy; who owns the Slack bot and its token.
- Which feature flags to switch on for launch, in what order (docs/CONTRACT.md has the index of all nine; each is OFF until switched on at `/admin/flipper`).
- Whether the merch claim and the crew, quest and returning payouts should be announced in the Slack ship message (the ship page and message count only the base and streak coins today).
- Data retention periods; whether to encrypt email and Slack id at rest.

## Seams for external work

- **Hackatime**: `Hackatime::Client` behind `Hours::Sync`, with a fake provider in the tests; point `HACKATIME_URL` at a local fake to try linking without the real service.
- **Slack**: `Notifications::Slack.adapter` picks the real adapter only when `SLACK_BOT_TOKEN` is present (never in the repository); otherwise the null or log adapter is used and nothing is sent.
