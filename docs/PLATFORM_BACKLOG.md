# Platform backlog

Sources: Slack canvas "Village - whiteboard plan (11/9)" (`F0CG8T25BNV`, section "Website - Platform", priority **P2 = medium, by launch**, owner AB) and the Granola folder "Village" (notes 11/2 to 11/9). Design, art, shop content and marketing items are out of scope here. Launch is Friday 2026-11-13 per the 11/9 notes; the run is one month with an optional second month.

Status key: **done**, **unblocked** (being built on `feat/platform`), **owner-decision** (a product rule is undecided; the decision is named), **external** (needs access we do not have). "Owns" lists the files a feature would add or touch.

Rules that apply to everything (from the notes and the owner): never hard-block someone from coding (soft friction only); no IDV or eligibility check before shipping; never auto-link a low-certainty Hackatime project without asking; referrals by path only (no UTM); shop prices are the same for everyone; users are teens, so minimise personal data.

## Canvas platform tasks

| # | Feature | Canvas priority / source | Status | Size | Depends on | Owns (files) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Onboarding: IDV status shown | P2, canvas | **done** (account step shows status, not enforced) | S | - | `app/views/onboardings/**` |
| 2 | Onboarding: Hackatime auto-link | P2, canvas; 11/9 discussion | **external**: no endpoint, auth scheme or API owner stated anywhere. Rules from 11/9: auto-link only on a matching GitHub repo; for low certainty DM "is this your project?", yes links, no stops asking | M | Hackatime API access; Slack DM (#9) for the low-certainty question | would add `app/services/hackatime/**`, `app/models/hackatime_link.rb`, migration |
| 3 | Onboarding: team suggest | P2, canvas | **owner-decision**: "team" is undefined (11/9 describes a buddy bonus where the partner need not share a project; suggestion rule not stated). Decision: what is a team, how are people matched, is it opt-in? | M | team data model | would add `app/models/team*.rb` |
| 4 | Onboarding: Slack DM with account links (?) | P2, canvas (marked unreadable) | **external**: needs a Slack bot token and an owner for the bot (not stated). Plumbing is built under #9 | S | #9 | `app/services/notifications/**` |
| 5 | Shipping: force IDV | P2, canvas; 11/9 "no check until after they ship" | **owner-decision**: there is no ship flow yet (what a "ship" is, who reviews). The check itself is cheap (`verification_verified?`); the decision is the ship flow and what happens to an unverified shipper | S after the ship flow | ship flow | `app/models/user.rb`, future ship controller |
| 6 | 15 min streak: daily sticker | P2, canvas; 11/9 | **owner-decision** (docs/PLAN_GAME_SLICE.md Q4, Q5, Q6, Q7, Q9, Q10 unanswered) and **external** (needs hours from Hackatime) | M | hours ledger, Hackatime | see `docs/PLAN_GAME_SLICE.md` |
| 7 | Daily goal streak: 1 merch per week (bonus ramp 5% to 20% over 14 days) | P2, canvas | **owner-decision**: the canvas ramp is internally inconsistent (+2% a day reaches 20% on day 9, not day 14); what the daily goal is; merch vs multiplier (Q4, Q5, Q6) | M | #6 | `docs/PLAN_GAME_SLICE.md` |
| 8 | 1 day streak freeze, weekly boss battle | P2, canvas | **owner-decision** (Q2, Q3, Q8, Q9, Q11, Q12 in `docs/PLAN_GAME_SLICE.md`) | L | #6 | `docs/PLAN_GAME_SLICE.md` |
| 9 | Notification system: Slack first, then email, SMS | P2, canvas; 11/6, 11/9 | Plumbing **unblocked**: adapter with a null/log implementation, outbox table, reminder due-time computation from onboarding coding days, time and time zone. Real Slack sending is **external** (`SLACK_BOT_TOKEN`, bot owner). Email: **owner-decision** (transactional with unsubscribe page, canvas says "workflow?"). SMS: **owner-decision** (Twilio, communications policy and consent wording must be confirmed before launch, canvas says "?") | M | - | `app/services/notifications/**`, `app/models/notification*.rb`, `app/jobs/**`, migration |
| 10 | Ship reminders: MVP at 10h, reminder at 5h, deductions after 6h (?) | P2, canvas; 11/9 | **owner-decision**: penalty maths is "not done" (0.8x after about 6 to 7 hours vs "small penalty"); and **external** (needs hours). Reminder scheduling will reuse #9 | M | #9, hours | `app/services/notifications/**` |
| 11 | Metrics: DAU, DHC (daily hours coded), dropout funnel | P2, canvas; 11/9 | DAU and the funnel are **unblocked** (definitions to be written down and flagged as the default; owner can change them). DHC is **external** (needs Hackatime hours) | M | admin foundation (#16) to display | `app/services/metrics/**`, `app/models/activity_day.rb`, migration |
| 12 | Guides: SD, Playground | P2, canvas; 11/6 (ideation help only) | **owner-decision**/content: guide text comes from design/content; onboarding already shows "coming soon" placeholders | S | content | `app/views/onboardings/**` |
| 13 | Quests | P2, canvas; 11/9 "quest bonus urgent for MVP" | **owner-decision**: no mechanic defined | L | - | - |
| 14 | Minigames, Daily Plinko | P2, canvas; 11/6 | **owner-decision** (Plinko vs fishing undecided; one ball per 5 coded minutes needs hours) | L | hours | - |
| 15 | Referral: custom events | P2, canvas; 11/6 | Path referrals **done** (`/haven`, `/terra`, `/stardance`, first touch, stored at first sign-in). "Custom events", user referrals and the Haven bonus/revenue share are **owner-decision** (partner terms still to be negotiated) | M | partner terms | `config/referrals.yml`, `app/controllers/referrals_controller.rb` |
| 16 | Admin: shop, projects, fulfillment (?) | P2, canvas; 11/9 "very much after launch" for review and fulfillment queues | Admin **foundation** and read-only dashboard **unblocked** (allowlist of Hack Club Auth ids in `ADMIN_HCA_UIDS`; `/admin` returns 404 for non-admins). Shop, project review and fulfillment queues are **owner-decision** (no ship flow, no final shop) | S now, L later | - | `app/controllers/admin/**`, `app/views/admin/**`, `app/models/user.rb`, `config/routes.rb` |
| 17 | NPS every 2 days | P2, canvas; 11/6 (team responds and DMs users) | **owner-decision**: survey copy, who sees answers, how long they are kept. Delivery would reuse #9 | M | #9 | - |

## Added by the owner (not on the canvas)

| # | Feature | Source | Status | Size | Owns (files) |
| --- | --- | --- | --- | --- | --- |
| 18 | Account data export and deletion (self-service, GDPR) | Owner request; a GDPR request is open (11/3 notes, README) | **unblocked**, highest value | M | `app/controllers/accounts_controller.rb`, `app/views/accounts/**`, `app/services/account_*.rb`, `app/views/pages/privacy.html.erb`, `app/controllers/sessions_controller.rb` (recent-login timestamp), `config/routes.rb` |
| 19 | Production readiness for the pending deploy: shared cache store for rack-attack, `trusted_proxies` via env, documented env vars, health check (`/up` already exists), production config and Dockerfile review | Owner request | **unblocked**. Deployment target (Orchard) is not accessible: nothing is deployed | S | `config/environments/production.rb`, `config/initializers/rack_attack.rb`, `config/cache.yml`, `Dockerfile`, `README.md`, `.env.example` |
| 20 | Email and Slack ID encrypted at rest | README open question | **owner-decision** (needs a production `RAILS_MASTER_KEY` and a key-rotation plan; also affects lookups by Slack ID) | S | `app/models/user.rb`, credentials |

## Decisions the owner still has to make (summary)

See the final report for the recommended default of each: admin identification (default: env allowlist), the game rules in `docs/PLAN_GAME_SLICE.md`, the ship flow and IDV enforcement point, email/SMS policy, who owns the Slack bot, Hackatime API access, team definition, NPS, data retention periods, encryption of email and Slack ID.

## Seams for external work

- **Hackatime**: nothing in the sources states an endpoint, auth scheme or rate limit, so no client is written. When access exists, add `Hackatime::Client` behind a small interface (`projects_for(user)`, `seconds_for(user, date_range)`) so the ledger and link logic can be tested with a fake, mirroring the Slack adapter in #9.
- **Slack**: `SLACK_BOT_TOKEN` (never in the repo). Without it the null/log adapter is used and nothing is sent.
