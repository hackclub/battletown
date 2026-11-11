# Battletown

Battletown is a Hack Club You Ship We Ship (YSWS) program, run by Amber and Armand (formerly called "Village"). Teens code, log time with Hackatime, and chip away at a shared boss to earn prizes from a shop.
This repo is the user-facing platform: landing page, sign-up, onboarding and dashboard (Rails 8.1, PostgreSQL, importmap, plain CSS).

## Setup

```sh
bundle install
cp .env.example .env   # then fill in HCA_CLIENT_ID / HCA_CLIENT_SECRET (gitignored; loaded by dotenv-rails in development/test only)
bin/rails db:prepare
bin/dev            # or bin/rails s -p 3000
```

For real Hack Club Auth sign-in in development, the app's redirect URI in auth.hackclub.com (Developer Apps) must be exactly `http://localhost:3000/auth/hack_club/callback`, and the server must run on port 3000 (matching `APP_URL`).

Sign in locally with the **Dev login** button (development only, no Hack Club Auth credentials needed).

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
| `APP_URL` | Public URL; redirect URI is `$APP_URL/auth/hack_club/callback` |
| `ADMIN_HCA_UIDS` | Comma-separated Hack Club Auth ids (OIDC `sub`) allowed into `/admin`; empty or unset means nobody (everyone else gets a 404). Locally, `ADMIN_HCA_UIDS=dev-user bin/rails s` makes Dev login an admin |
| `APP_HOST` | Production only: comma-separated allowed hostnames (unset: the host of `APP_URL`; other hosts get 403, except the `/up` health check) |
| `SLACK_BOT_TOKEN` / `NOTIFICATIONS_ENABLED` | Slack DM reminders (`app/services/notifications`, tunables in `config/notifications.yml`). Needs a bot token with `chat:write`; nothing is ever sent unless `NOTIFICATIONS_ENABLED` is exactly `true` (default off). Cron `bin/rails notifications:dispatch` every minute, or run `DispatchNotificationsJob` |

## How auth works

Hack Club Auth (OIDC, discovery, PKCE, scopes `openid profile email name phone birthdate address verification_status slack_id basic_info`).
"Sign up" and "sign in" are the same flow: `POST /auth/hack_club` (CSRF-protected) -> Hack Club Auth -> `GET /auth/hack_club/callback` -> `SessionsController#create`, which finds or creates the user by `sub` (`users.hca_uid`), resets the session, and routes to onboarding or the dashboard. IDV is **not** required at signup; the status is stored and should be enforced at shipping. Phone, birthdate and address are requested (all scopes enabled on the app) but **not stored or logged** pending a privacy decision; only name, email, Slack ID, verification status and a time zone are persisted. The address is used transiently, in memory, at first sign-in: `AddressTimeZone` (`app/services/address_time_zone.rb`, table in `config/address_time_zones.yml`) turns the primary address's country and region into a time zone name, and only that name is stored as `users.time_zone` (never overwritten on later sign-ins). The onboarding schedule step shows it as one line of text with a "Change time zone" control; if no zone can be derived it falls back to the browser's zone, then to a blank select. The parsing follows the OIDC `address` claim as documented at https://auth.hackclub.com/docs and has not yet been verified against a real response.

## Where to edit things

- Design tokens: `app/assets/stylesheets/tokens.css` (placeholder until the Figma style guide lands)
- Prizes: `config/prizes.yml` (placeholder, Amber owns the final shop)
- Referral slugs (`/haven`, `/terra`, `/stardance`): `config/referrals.yml`
- "How did you hear about us?" options on the onboarding account step: `config/referral_sources.yml` (generic answers) plus the programs from `config/referrals.yml`, via `ReferralSource`
- Interfaces for page work: `docs/CONTRACT.md`

## Security notes

Enforced nonce-based CSP, Permissions-Policy, rack-attack throttles (shared Solid Cache store in production, in-process store in development and test), secure/httponly/lax session cookies with a 30 day idle timeout, host allowlist, filtered sensitive params, allowlist validation on every user-supplied field. Run `bin/ci` (rubocop, bundler-audit, importmap audit, brakeman, tests) before merging.

## Open questions / TODO

- Real Hack Club Auth login: the redirect to auth.hackclub.com works with the registered app; the full round trip (login, consent, callback) still needs a manual run with a real account.
- Final design tokens and copy (Figma style guide pending).
- Privacy policy and terms are placeholders; a GDPR/data request is in progress. Email and Slack ID are stored unencrypted for now.
- Final shop items and prices, boss/streak/Plinko mechanics, notifications (Slack/email/SMS) are not built.
- Production cache store: decided and built, but untested on a real deployment. Production uses Solid Cache in the app's PostgreSQL database for `Rails.cache` and the rack-attack counters (dev/test keep an in-process store); see docs/DEPLOY.md for the single-database layout and the post-deploy store check. Still to confirm with the platform: which container port it routes to (80 by default) and whether a proxy with a public address needs listing in `TRUSTED_PROXIES`.
