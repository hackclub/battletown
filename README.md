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

## Environment

See `.env.example`. Credentials can alternatively live in Rails credentials under `hca: { client_id:, client_secret: }`.

| Variable | Purpose |
| --- | --- |
| `HCA_CLIENT_ID` / `HCA_CLIENT_SECRET` | OAuth app from auth.hackclub.com (Developer Apps) |
| `HCA_ISSUER` | Defaults to `https://auth.hackclub.com` |
| `APP_URL` | Public URL; redirect URI is `$APP_URL/auth/hack_club/callback` |
| `APP_HOST` | Production only: comma-separated allowed hostnames (set it, otherwise any Host is accepted) |

## How auth works

Hack Club Auth (OIDC, discovery, PKCE, scopes `openid profile email name phone birthdate address verification_status slack_id basic_info`).
"Sign up" and "sign in" are the same flow: `POST /auth/hack_club` (CSRF-protected) -> Hack Club Auth -> `GET /auth/hack_club/callback` -> `SessionsController#create`, which finds or creates the user by `sub` (`users.hca_uid`), resets the session, and routes to onboarding or the dashboard. IDV is **not** required at signup; the status is stored and should be enforced at shipping. Phone, birthdate and address are requested (all scopes enabled on the app) but **not stored or logged** pending a privacy decision; only name, email, Slack ID and verification status are persisted.

## Where to edit things

- Design tokens: `app/assets/stylesheets/tokens.css` (placeholder until the Figma style guide lands)
- Prizes: `config/prizes.yml` (placeholder, Amber owns the final shop)
- Referral slugs (`/haven`, `/terra`, `/stardance`): `config/referrals.yml`
- "How did you hear about us?" options on the onboarding account step: `config/referral_sources.yml` (generic answers) plus the programs from `config/referrals.yml`, via `ReferralSource`
- Interfaces for page work: `docs/CONTRACT.md`

## Security notes

Enforced nonce-based CSP, Permissions-Policy, rack-attack throttles (need a real cache store in production), secure/httponly/lax session cookies with a 30 day idle timeout, host allowlist, filtered sensitive params, allowlist validation on every user-supplied field. Run `bin/ci` (rubocop, bundler-audit, importmap audit, brakeman, tests) before merging.

## Open questions / TODO

- Real Hack Club Auth login: the redirect to auth.hackclub.com works with the registered app; the full round trip (login, consent, callback) still needs a manual run with a real account.
- Final design tokens and copy (Figma style guide pending).
- Privacy policy and terms are placeholders; a GDPR/data request is in progress. Email and Slack ID are stored unencrypted for now.
- Final shop items and prices, boss/streak/Plinko mechanics, notifications (Slack/email/SMS) are not built.
- Production cache store for rack-attack (Rails.cache is a null store in dev/test).
