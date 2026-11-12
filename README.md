# Battletown

Battletown is a Hack Club You Ship We Ship (YSWS) program, run by Amber and Armand (formerly called "Village"). Teens code, log time with Hackatime, and chip away at a shared boss to earn prizes from a shop.
This repo is the platform: landing page, sign-up, onboarding, dashboard, projects, a Hackatime hours ledger, streaks and coins, the weekly boss, ships with staff review, the shop and orders, Slack reminders, a small admin area and Hack Club's data-deletion API (Rails 8.1, PostgreSQL, importmap, plain CSS). What is built and what is still open: [docs/PLATFORM_BACKLOG.md](docs/PLATFORM_BACKLOG.md).

## Setup

```sh
bundle install
cp .env.example .env   # then fill in HCA_CLIENT_ID / HCA_CLIENT_SECRET (gitignored; loaded by dotenv-rails in development/test only)
bin/rails db:prepare   # also creates the launch bosses; `bin/rails bosses:seed` is safe to repeat
bin/dev            # or bin/rails s -p 3000
```

For real Hack Club Auth sign-in in development, the app's redirect URI in auth.hackclub.com (Developer Apps) must be exactly `http://localhost:3000/auth/hack_club/callback`, and the server must run on port 3000 (matching `APP_URL`).

Sign in locally with the **Dev login** button (development only, no Hack Club Auth credentials needed). With it you also get development-only tools: `/dev/hours` adds coded time for a local date, the shop has a "Give me 100 test coins" button, and `/dev/boss` previews boss states. `ADMIN_HCA_UIDS=dev-user bin/rails s` makes the Dev login user staff (`/admin`). Staff cannot approve their own ship, so to try the review flow use a second staff id or move the ship's owner to another uid.

## Tests and parallel worktrees

`bin/rails test` uses the `battletown_test` database (plus `battletown_test-N` for the parallel workers). Several checkouts, worktrees or agents running tests at the same time must not share one: give each a unique suffix, for example

```sh
export TEST_DB_SUFFIX=_a
TEST_DB_SUFFIX=_a bin/rails db:test:prepare
TEST_DB_SUFFIX=_a bin/rails test
```

The suffix is appended to the test database name in `config/database.yml` (empty by default, so CI is unchanged).

## Environment

See `.env.example`. Credentials can alternatively live in Rails credentials under `hca: { client_id:, client_secret: }`.

**Production:** the complete variable list (`SECRET_KEY_BASE`, `DATABASE_URL`, `TRUSTED_PROXIES`, ...), the single-database layout, the port and health check (`/up`), the pre-deploy checklist and rollback notes are in [docs/DEPLOY.md](docs/DEPLOY.md). Only PostgreSQL is needed; `RAILS_MASTER_KEY` is optional when the secrets are set as environment variables.

| Variable | Purpose |
| --- | --- |
| `HCA_CLIENT_ID` / `HCA_CLIENT_SECRET` | OAuth app from auth.hackclub.com (Developer Apps) |
| `HCA_ISSUER` | Defaults to `https://auth.hackclub.com` |
| `HACKATIME_CLIENT_ID` / `HACKATIME_CLIENT_SECRET` | Hackatime OAuth app (scopes `profile` and `read` only); redirect URI is `$APP_URL/auth/hackatime/callback`. Optional account linking, see [docs/HACKATIME.md](docs/HACKATIME.md) |
| `HOURS_SOURCE` | Optional override of `hours_source` in `config/game.yml`: `null` (default, no Hackatime calls) or `http` (live Hackatime for linked users; `bin/rails "hackatime:sync[all]"`) |
| `HACKATIME_URL` | Defaults to `https://hackatime.hackclub.com`; `https` only in production. Point it at a local fake provider to test linking |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` / `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` / `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | Encrypt the Hackatime tokens at rest. Required (production refuses to boot without them); in development generate them with `bin/rails db:encryption:init` and put them in `.env`. Tests use fixed throwaway values |
| `APP_URL` | Public URL; redirect URI is `$APP_URL/auth/hack_club/callback` |
| `ADMIN_HCA_UIDS` | Comma-separated Hack Club Auth ids (OIDC `sub`) allowed into `/admin`; empty or unset means nobody (everyone else gets a 404). Locally, `ADMIN_HCA_UIDS=dev-user bin/rails s` makes Dev login an admin |
| `APP_HOST` | Production only: comma-separated allowed hostnames (unset: the host of `APP_URL`; other hosts get 403, except the `/up` health check) |
| `PRIVACY_AUDIENCE` | Audience a data-deletion token must carry (default `battletown`); the value to give Hack Club infrastructure, see `docs/PRIVACY_API.md` |
| `PRIVACY_JWKS_URL` | Where the Hack Club data-deletion signing keys are fetched (default `https://yeet.hackclub.com/.well-known/jwks.json`); leave unset in production, `https` only |
| `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_DOMAIN`, `MAIL_FROM` | Email notifications (behind the Flipper flag `email`, default off; ship decisions and the welcome-back note, each with one-click unsubscribe). Real SMTP only when `SMTP_ADDRESS` and `MAIL_FROM` are set; otherwise nothing is sent. Names only here, values in the environment: see [docs/DEPLOY.md](docs/DEPLOY.md) and the "Email notifications" section of [docs/CONTRACT.md](docs/CONTRACT.md) |
| `SLACK_BOT_TOKEN` / `NOTIFICATIONS_ENABLED` | Slack DM reminders (`app/services/notifications`, tunables in `config/notifications.yml`). Needs a bot token with `chat:write`; nothing is ever sent unless `NOTIFICATIONS_ENABLED` is exactly `true` (default off). Cron `bin/rails notifications:dispatch` every minute, or run `DispatchNotificationsJob`. Everything it can send (daily reminder, link question, ship reminders, ship decisions) and the `/settings/notifications` switches are described in [docs/CONTRACT.md](docs/CONTRACT.md) |

### Slack app

The Slack app that sends the reminder DMs is defined by `config/slack/manifest.yml` (bot scope `chat:write` only; no events, commands or Socket Mode). To create it, use api.slack.com/apps, Create New App, From a manifest, pick the Hack Club workspace, paste the manifest, install it and put the Bot User OAuth Token in `SLACK_BOT_TOKEN` (environment only, never the repo). Then run `bin/rails slack:check` to verify the token and its scopes, and set `NOTIFICATIONS_ENABLED=true` only when ready. Details, ownership and admin-approval notes: [docs/SLACK_APP.md](docs/SLACK_APP.md).

### Cron entries needed at go-live

Nothing runs by itself; schedule these on the host (all are safe to repeat, and the Slack ones stay silent while `NOTIFICATIONS_ENABLED` is not `true`):

| Every | Command | Why |
| --- | --- | --- |
| minute | `bin/rails notifications:dispatch` | sends the queued Slack DMs |
| 15 minutes | `bin/rails notifications:ship_reminders` | queues the 5 hour reminder and 10 hour nudge for projects that crossed them |
| hour | `bin/rails game:settle` | settles finished days (streaks and bonuses) |
| hour, only with `HOURS_SOURCE=http` | `bin/rails "hackatime:sync[all]"` | pulls recent Hackatime hours for linked accounts |

## How auth works

Hack Club Auth (OIDC, discovery, PKCE, scopes `openid profile email name phone birthdate address verification_status slack_id basic_info`).
"Sign up" and "sign in" are the same flow: `POST /auth/hack_club` (CSRF-protected) -> Hack Club Auth -> `GET /auth/hack_club/callback` -> `SessionsController#create`, which finds or creates the user by `sub` (`users.hca_uid`), resets the session, and routes to onboarding or the dashboard. IDV is **not** required at signup; the status is stored and should be enforced at shipping. Phone, birthdate and address are requested (all scopes enabled on the app) but **not stored or logged** pending a privacy decision; only name, email, Slack ID, verification status and a time zone are persisted. The address is used transiently, in memory, at first sign-in: `AddressTimeZone` (`app/services/address_time_zone.rb`, table in `config/address_time_zones.yml`) turns the primary address's country and region into a time zone name, and only that name is stored as `users.time_zone` (never overwritten on later sign-ins). The onboarding schedule step shows it as one line of text with a "Change time zone" control; if no zone can be derived it falls back to the browser's zone, then to a blank select. The parsing follows the OIDC `address` claim as documented at https://auth.hackclub.com/docs and has not yet been verified against a real response.

## Where to edit things

- Design tokens: `app/assets/stylesheets/tokens.css` (placeholder until the Figma style guide lands)
- Game numbers (daily cap, streak bonus ramp, coins per hour, boss settings, ship thresholds): `config/game.yml`; Slack message copy and timing: `config/notifications.yml`
- Shop items: `config/prizes.yml` (placeholder, the designer replaces them; the only price is `coins`, hours are derived from `config/game.yml`)
- Referral slugs (`/haven`, `/terra`, `/stardance`): `config/referrals.yml`
- "How did you hear about us?" options on the onboarding account step: `config/referral_sources.yml` (generic answers) plus the programs from `config/referrals.yml`, via `ReferralSource`
- Interfaces for page work: `docs/CONTRACT.md`

## Security notes

Enforced nonce-based CSP, Permissions-Policy, rack-attack throttles (shared Solid Cache store in production, in-process store in development and test), secure/httponly/lax session cookies with a 30 day idle timeout, host allowlist, filtered sensitive params, allowlist validation on every user-supplied field, and the Hack Club data-deletion API (`POST /api/privacy/delete` and `/export`, ES256 token verified against Hack Club's keys, one-time `jti`, no personal data logged; `docs/PRIVACY_API.md`). Run `bin/ci` (rubocop, bundler-audit, importmap audit, brakeman, tests) before merging.

## Open questions / TODO

- Before launch: register with the Hack Club yeet deletion service, see docs/DEPLOY.md ("Before launch (blocking)").
- Real Hack Club Auth login: the redirect to auth.hackclub.com works with the registered app; the full round trip (login, consent, callback) still needs a manual run with a real account.
- Final design tokens and copy (Figma style guide pending).
- Privacy policy and terms are placeholders; a GDPR/data request is in progress. Email and Slack ID are stored unencrypted for now.
- Final shop items and prices, Plinko and the shipping-address decision (orders are requests; the team arranges delivery on Slack) are open.
- Production cache store: decided and built, but untested on a real deployment. Production uses Solid Cache in the app's PostgreSQL database for `Rails.cache` and the rack-attack counters (dev/test keep an in-process store); see docs/DEPLOY.md for the single-database layout and the post-deploy store check. Still to confirm with the platform: which container port it routes to (80 by default) and whether a proxy with a public address needs listing in `TRUSTED_PROXIES`.
