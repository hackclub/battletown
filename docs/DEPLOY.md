# Deploying Battletown

Nothing here has been run against a real deployment target: it was written and checked locally (production-mode boot, `db:prepare` against scratch PostgreSQL databases, the test suite) without Docker. Treat the first deploy as the real test and work through the checklist below.

## Shape of the deploy

- One container built from the `Dockerfile` (multi-stage, runs as the non-root user `rails`, uid 1000).
- PostgreSQL is the only service the app needs. There is no Redis, no Memcached, no object storage (ship screenshots, when that flag is on, are stored in PostgreSQL). Email (flag `email`) needs an SMTP account of your own, only when you switch it on. Throttle counters and the landing page cache live in the same PostgreSQL database (Solid Cache).
- Listens on **port 80** (Thruster, which proxies to Puma on 3000 inside the container). The platform must route to container port 80, terminate TLS in front of it, and send `X-Forwarded-Proto: https`.
- Health check: `GET /up` returns 200 whenever the app booted. It does not touch the database, so it is a liveness probe only, and it is exempt from host authorization, the SSL redirect and request logging, so a load balancer can probe it over plain HTTP with any `Host` header.
- On start the default container command runs `bin/rails db:prepare` (see `bin/docker-entrypoint`), which creates the database if the role may, runs pending migrations and creates the cache table. If you override the container command (anything other than `./bin/thrust ./bin/rails server`), run `bin/rails db:prepare` yourself before starting it.

## Environment variables

Never commit real values. Shapes below are examples only.

| Variable | Required | Purpose | Example shape |
| --- | --- | --- | --- |
| `APP_URL` | yes | Public URL of the app. Builds the Hack Club Auth redirect URI (`$APP_URL/auth/hack_club/callback`) and is the fallback for `APP_HOST`. Defaults to `http://localhost:3000`, which is wrong in production. | `https://battletown.example.com` |
| `APP_HOST` | recommended | Comma-separated hostnames Rails answers to (DNS rebinding and Host header protection). Unset: the host of `APP_URL`. Add every hostname the platform may use (custom domain plus a platform default domain). Requests with another Host get 403, except `/up`. | `battletown.example.com,battletown.platform.example` |
| `HCA_CLIENT_ID` | yes | OAuth client id of the app at auth.hackclub.com (Developer Apps). Alternative: Rails credentials `hca.client_id`. | `a1b2c3...` |
| `HCA_CLIENT_SECRET` | yes | OAuth client secret of the same app. Alternative: Rails credentials `hca.client_secret`. Treat as a secret. | `s3cr3t...` |
| `HCA_ISSUER` | no | Hack Club Auth issuer, used for OIDC discovery. Default `https://auth.hackclub.com`. | `https://auth.hackclub.com` |
| `HACKATIME_CLIENT_ID` | yes, for Hackatime linking | OAuth client id of the Hackatime app (hackatime.hackclub.com, OAuth apps; scopes `profile` and `read` only). Alternative: Rails credentials `hackatime.client_id`. Without it, "Connect Hackatime" fails with a friendly error; nothing else is affected. | `a1b2c3...` |
| `HACKATIME_CLIENT_SECRET` | yes, for Hackatime linking | OAuth client secret of the same app. Alternative: Rails credentials `hackatime.client_secret`. Treat as a secret. | `s3cr3t...` |
| `HACKATIME_URL` | no | Hackatime base URL, default `https://hackatime.hackclub.com`. Must be `https` in production (the app refuses to boot otherwise). Only change it to point at a fake provider locally. | `https://hackatime.hackclub.com` |
| `HOURS_SOURCE` | no | Overrides `hours_source` in `config/game.yml`: `null` (default, no Hackatime calls) or `http` (live Hackatime for users who linked their account). Then run `bin/rails "hackatime:sync[all]"` on a schedule. | `http` |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | yes | Encrypts the Hackatime OAuth tokens at rest. The app refuses to boot in production without it. Generate once with `bin/rails db:encryption:init` and keep the three values together. **Losing or changing them makes the saved tokens unreadable** (users would have to reconnect Hackatime); never commit them. | 32+ random characters |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | yes | Second key of the same set (required by Active Record encryption even though no column uses deterministic encryption yet). Boot fails without it. | 32+ random characters |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | yes | Third value of the same set. Boot fails without it. | 32+ random characters |
| `SECRET_KEY_BASE` | yes, unless `RAILS_MASTER_KEY` is set and the credentials hold `secret_key_base` | Signs and encrypts the session cookie. The app refuses to boot without one. Generate with `bin/rails secret` (64 hex characters). Changing it signs everyone out. | 128 hex characters |
| `RAILS_MASTER_KEY` | no | Only needed to read `config/credentials.yml.enc`. The app reads the Hack Club Auth credentials from the environment first and falls back to credentials, and `SECRET_KEY_BASE` replaces the credentials secret, so with those variables set no master key is needed. Needed later if email and Slack ID encryption at rest is added. | 32 hex characters (`config/master.key`) |
| `DATABASE_URL` | yes | The PostgreSQL database. The only database setting needed: the cache connection reuses it. | `postgres://user:password@host:5432/dbname` |
| `CACHE_DATABASE_URL` | no | Put the cache table in a separate database. Only set it if you want that; `db:prepare` then creates the cache table there. | `postgres://user:password@host:5432/cachedb` |
| `BATTLETOWN_DATABASE_PASSWORD` | no | Only used when `DATABASE_URL` is not set: `config/database.yml` then falls back to role `battletown`, database `battletown_production` over the local socket. Leave unset on a platform that gives you a URL. | |
| `TRUSTED_PROXIES` | only if a proxy with a public address is in front of the app | Comma-separated IPs or CIDRs of reverse proxies / CDNs / load balancers that forward to the app and are not private addresses. Added to the built-in trusted ranges (loopback and private networks). Invalid entries and catch-all ranges (`0.0.0.0/0`, `::/0`) are ignored with a log warning. See "Client IPs and throttling". | `203.0.113.0/24,2001:db8::/32` |
| `RAILS_MAX_THREADS` | no | Puma threads and the size of each database connection pool. Default 3 threads, pool 5. PostgreSQL connections used are about 2 x threads x Puma workers (primary and cache pools). | `5` |
| `WEB_CONCURRENCY` | no | Number of Puma worker processes (Puma reads it itself). Default 1. Safe above 1: throttle counters are shared through the database. | `2` |
| `RAILS_LOG_LEVEL` | no | Default `info`. Do not use `debug` in production: it can log personal data. Request lines at `info` include the client IP and path. | `info` |
| `HTTP_PORT` | no | Port Thruster listens on inside the container, default 80. Set it if the platform insists on another port (for example the value of its `PORT`). Do not set `PORT` for this: Thruster overrides it for Puma. | `8080` |
| `MAX_REQUEST_BODY` | no | Thruster refuses a request body over this many bytes before Rails sees it. The image sets `17000000` (a ship form with three 5 MB screenshots plus text); the app enforces the same limit itself (`config/initializers/rack_attack.rb`). Do not raise it without raising `ship_screenshots.max_upload_bytes` and reading the screenshot section of CONTRACT. | `17000000` |
| `SOLID_QUEUE_IN_PUMA` | no, leave unset | Would run the Solid Queue supervisor inside Puma. There are no jobs and no queue tables, so enabling it only crashes the supervisor. See "Background jobs". | |
| `ADMIN_HCA_UIDS` | no | Comma-separated Hack Club Auth `sub` values of admins. Unset: nobody is an admin and `/admin` returns 404. | `ident!abc123,ident!def456` |
| `SLACK_BOT_TOKEN` | no | Bot token (scope `chat:write`) that enables real Slack DMs. Unset: the null adapter is used and nothing is sent. Environment only, never the repository; see [SLACK_APP.md](SLACK_APP.md). Treat as a secret. | `xoxb-...` |
| `NOTIFICATIONS_ENABLED` | no | Master switch for sending queued Slack messages: nothing is sent unless it is exactly `true` (default off). In production the dispatcher also refuses to run without a real adapter, so setting it without `SLACK_BOT_TOKEN` sends nothing. | `true` |
| `SMTP_ADDRESS` | only for real email | SMTP server host. Email (flag `email`) goes out over SMTP only when this and `MAIL_FROM` are set; otherwise nothing is sent and the email dispatcher refuses to run in production. | `smtp.example.com` |
| `SMTP_PORT` | no | Default 587 (STARTTLS); 465 means implicit TLS. | `587` |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | only if the server needs a login | Set both or neither (one alone counts as no transport). Environment only, never the repository. Treat the password as a secret. | |
| `SMTP_DOMAIN` | no | HELO domain. | `example.com` |
| `MAIL_FROM` | only for real email | The From header, on a domain with SPF, DKIM and DMARC set up (one-click unsubscribe needs DKIM). Unset: a placeholder on `example.com` is used and, in production, no real transport exists. | `Battletown <noreply@example.com>` |
| `PRIVACY_AUDIENCE` | no | Audience a Hack Club data-deletion token must carry. Default `battletown`. | `battletown` |
| `PRIVACY_JWKS_URL` | no, leave unset | Where the data-deletion signing keys are fetched. Default `https://yeet.hackclub.com/.well-known/jwks.json`; `https` only in production. | |

To turn email on: set the SMTP variables and `MAIL_FROM`, make sure `NOTIFICATIONS_ENABLED=true`, then switch the Flipper flag `email` on at `/admin/flipper` (try it on admins first with the `admins` group). Nothing is sent until all of those are true; `/admin/email` shows whether a real transport is configured.

`bin/rails runner 'p Rails.application.config.hosts'` is a quick way to see the host allowlist the container ended up with.

### Hack Club Auth app

Register this redirect URI in the app at auth.hackclub.com (Developer Apps), exactly, with no trailing slash:

```
$APP_URL/auth/hack_club/callback
```

The app requests the scopes `openid profile email name phone birthdate address verification_status slack_id basic_info`, all of which must be enabled on the app.

### Hackatime OAuth app

Account linking is optional and separate from sign-in. Register this redirect URI on the Hackatime OAuth app, exactly, with no trailing slash, and give the app only the scopes `profile` and `read`:

```
$APP_URL/auth/hackatime/callback
```

Details of the endpoints used, token lifetime and the hours source: [HACKATIME.md](HACKATIME.md). Set `HACKATIME_CLIENT_ID` and `HACKATIME_CLIENT_SECRET` plus the three `ACTIVE_RECORD_ENCRYPTION_*` values in the production environment before launch.

## Database layout

One PostgreSQL database, set with `DATABASE_URL`. `config/database.yml` defines two connections in production: `primary` (everything the app stores) and `cache` (Solid Cache), both pointing at that database by default. The cache connection has its own migration path (`db/cache_migrate`), so the `solid_cache_entries` table is created by `db:prepare` without touching `db/schema.rb`. `CACHE_DATABASE_URL` moves it to a separate database (`db/cache_schema.rb` is loaded when that database does not exist yet).

Solid Queue and Solid Cable are installed as gems but not configured: the previous `queue` and `cable` database entries had no schema or consumer, would have made `db:prepare` fail on a single-database platform, and are removed. Action Cable uses the in-process `async` adapter (no Redis).

## Scheduled commands (cron)

Nothing runs by itself, and there is ONE table of everything that can be scheduled. Schedule these on the host (or as Orchard jobs, below) with the same environment as the app. All are safe to repeat; the Slack and email ones stay silent while `NOTIFICATIONS_ENABLED` is not `true`; every task of a feature behind a Flipper flag returns at once, reading and writing nothing, while its flag is off, so creating the job early is harmless (it only costs a pod start).

| Command | Schedule (UTC) | Create when | What it does |
| --- | --- | --- | --- |
| `bin/rails game:settle` | hourly (`5 * * * *`) | always | settles finished local days into `daily_results` (streaks and bonuses; the dashboard and ship approval also settle lazily). Exits 1 when any user failed |
| `bin/rails privacy:purge_tokens` | daily (`20 9 * * *`) | always | deletes used data-deletion token ids older than 7 days (also purged as requests arrive) |
| `bin/rails notifications:prune` | daily (`40 9 * * *`) | always | deletes finished notification rows older than `retention_days` (`config/notifications.yml`); sends nothing |
| `bin/rails "hackatime:sync[all]"` | hourly (`35 * * * *`) | `HOURS_SOURCE=http` | pulls recent Hackatime hours for linked accounts (prints "skipped" and exits 0 otherwise) |
| `bin/rails notifications:dispatch` | every 5 minutes (`*/5 * * * *`; once a minute if you want) | notifications switched on (`NOTIFICATIONS_ENABLED=true` and a bot token) | sends the queued Slack DMs and, with flag `email` on and SMTP configured, the queued emails |
| `bin/rails notifications:ship_reminders` | every 15 minutes | notifications switched on | queues the 5 hour reminder and 10 hour nudge for projects that crossed them |
| `bin/rails notifications:schedule_all` | daily (`50 9 * * *`) | notifications switched on | re-queues the daily reminder for anyone whose chain stopped |
| `bin/rails notifications:returning_nudges` | daily (`10 15 * * *`) | flag `returning` on (and notifications switched on) | queues the one welcome-back Slack DM per idle period |
| `bin/rails notifications:nps_prompts` | a few times a day (`30 14,18,22 * * *`) | flag `nps` on (and notifications switched on) | queues the one-click NPS survey DM for people due one |
| `bin/rails nps:prune` | daily (`0 10 * * *`) | flag `nps` on | empties survey comments older than `nps.comment_retention_days` (90); scores are kept. Without it comments are kept for ever |
| `bin/rails team:pay_pending` | every 15 minutes | flag `team` on | pays the crew bonus for recently approved ships whose payout did not run or was still waiting for a day to settle |
| `bin/rails quests:evaluate` | hourly (`15 * * * *`) | flag `quests` on | records finished weekly quests and pays the rewards waiting on an approved ship (the dashboard and ship approval do this too, so it is the safety net for people who do not visit) |
| `bin/rails returning:evaluate` | hourly (`25 * * * *`) | flag `returning` on (optional) | settles everyone's days so welcome-back windows open on time; the same work as `game:settle`, so skip it when that already runs hourly |
| `bin/rails ship_images:prune` | daily (`0 11 * * *`) | flag `ship_screenshots` on | deletes screenshots of ships withdrawn more than 30 days ago and orphaned rows |

Checks to run by hand, not on a schedule: `bin/rails slack:check` (bot token and scopes), `bin/rails ship_images:check` (libvips can read and write what screenshots need), `bin/rails db:encryption:init` (once, to make the encryption keys).

Once, after the first `db:prepare`: `bin/rails bosses:seed` creates the launch bosses (idempotent; `db:seed` calls it too, and `db:prepare` only seeds a brand-new database).

### On Orchard

**None of these jobs exist yet. Creating them is an owner action** (Orchard dashboard or API); nothing in this repository creates them.

Each job is an `app` step on the `web` deployment of `<project>`: it runs the command in the same image (`WORKDIR /rails`) with the same environment as the site. The entrypoint only runs `db:prepare` for the server command, so a job never migrates. Leave `envVars` empty: the jobs must read the same `NOTIFICATIONS_ENABLED`, `HOURS_SOURCE` and `SLACK_BOT_TOKEN` as `web`, never their own copies. Every run is a fresh pod that boots Rails, so cadence has a real cost (a per-minute job is 1,440 pod starts a day).

Schedules are UTC, and that is fine: no command depends on when it fires. `game:settle` works out each user's settled days in that user's own time zone (local midnight plus `grace_hours` from `config/game.yml`), so an hourly run settles every zone, half-hour offsets included, within the hour; the dashboard also settles lazily. Daily reminder times and quiet hours are likewise computed per user by the dispatcher.

Every job uses `concurrencyPolicy: forbid` (a fire is skipped while the previous run is still going) and one `app` step; `deployment: web` stands for the `deploymentId` of `web` in the same project. The first three can be created now; the rest only under the condition in their comment.

```yaml
- name: game-settle
  description: Settle finished local days into daily_results (idempotent)
  scheduleCron: "5 * * * *"        # UTC; settlement is per user's own zone, so any hourly minute works
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails game:settle", timeoutSeconds: 1800, retries: 1 }

- name: privacy-purge-tokens
  description: Delete used data-deletion token ids older than 7 days
  scheduleCron: "20 9 * * *"       # UTC; night in the Americas, a tiny delete either way
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails privacy:purge_tokens", timeoutSeconds: 600, retries: 1 }

- name: notifications-prune
  description: Delete finished notification rows past retention_days (sends nothing)
  scheduleCron: "40 9 * * *"       # UTC
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails notifications:prune", timeoutSeconds: 600, retries: 1 }

- name: hackatime-sync              # create once HOURS_SOURCE=http is set on web (a no-op until then)
  description: Credit recent Hackatime time for linked accounts
  scheduleCron: "35 * * * *"       # UTC; half an hour away from game-settle
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails \"hackatime:sync[all]\"", timeoutSeconds: 1800, retries: 0 }

# The three below: create only when the owner enables notifications.
- name: notifications-dispatch
  description: Send due Slack DMs (no-op unless NOTIFICATIONS_ENABLED=true)
  scheduleCron: "*/5 * * * *"      # UTC
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails notifications:dispatch", timeoutSeconds: 1800, retries: 0 }

- name: notifications-ship-reminders
  description: Queue ship reminders for projects that crossed an hours threshold
  scheduleCron: "*/15 * * * *"     # UTC
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails notifications:ship_reminders", timeoutSeconds: 900, retries: 1 }

- name: notifications-schedule-all
  description: Re-queue the next daily reminder for every eligible user (idempotent)
  scheduleCron: "50 9 * * *"       # UTC
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails notifications:schedule_all", timeoutSeconds: 900, retries: 1 }

# Feature jobs: create each one only when its flag is switched on (until then it would only start a pod that returns at once).
- name: returning-nudges
  description: Queue the one welcome-back Slack DM per idle period (flag returning)
  scheduleCron: "10 15 * * *"      # UTC
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails notifications:returning_nudges", timeoutSeconds: 900, retries: 1 }

- name: nps-prompts
  description: Queue the NPS survey DM (flag nps)
  scheduleCron: "30 14,18,22 * * *" # UTC
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails notifications:nps_prompts", timeoutSeconds: 900, retries: 1 }

- name: nps-prune
  description: Empty survey comments past nps.comment_retention_days (flag nps)
  scheduleCron: "0 10 * * *"       # UTC
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails nps:prune", timeoutSeconds: 600, retries: 1 }

- name: team-pay-pending
  description: Pay crew bonuses that did not run at approval (flag team)
  scheduleCron: "*/15 * * * *"     # UTC
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails team:pay_pending", timeoutSeconds: 900, retries: 1 }

- name: quests-evaluate
  description: Record finished weekly quests and pay waiting rewards (flag quests)
  scheduleCron: "15 * * * *"       # UTC
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails quests:evaluate", timeoutSeconds: 1800, retries: 1 }

- name: ship-images-prune
  description: Delete screenshots of long-withdrawn ships (flag ship_screenshots)
  scheduleCron: "0 11 * * *"       # UTC
  enabled: true
  concurrencyPolicy: forbid
  steps:
    - { type: app, deployment: web, command: "bin/rails ship_images:prune", timeoutSeconds: 600, retries: 1 }
```

Notes:

- **`game-settle`** runs at minute 5 so the settle instant of whole-hour zones has just passed. It tries every user, prints its counts line, then exits 1 when any user failed (`errors=` above 0), so the run shows as failed; the one retry and the next hour try those users again (settling is idempotent).
- **`hackatime-sync`** checks the hours source first, the same way the app does (`HOURS_SOURCE`, else `hours_source` in `config/game.yml`): unless it is `http` it prints `hackatime:sync skipped: ...`, exits 0 and never calls Hackatime (an unknown value fails the run). So creating the job early is harmless, but it only costs pod starts until `HOURS_SOURCE=http` is set on `web`. Per-user failures are counted (`retry_later=`, `needs_reconnect=`), not raised, so retries stay at 0 and the next hour tries again. Order against `game-settle` does not matter: the grace period gives late hours several hours to land before a day settles.
- **`privacy-purge-tokens`** is only a backstop (expired ids are also deleted as requests arrive). The time is arbitrary off-peak.
- **`notifications-prune`** is the exception among the notification tasks: it sends nothing and only enforces retention, and finished rows exist even while notifications are off (changing a reminder schedule cancels the pending row), so create it now.
- **`notifications-dispatch`** prints `enabled=false` and exits 0 while `NOTIFICATIONS_ENABLED` is not `true`, and in production refuses to send without `SLACK_BOT_TOKEN` (`halted=true`). Every 5 minutes is 288 pod starts a day instead of 1,440: reminders go out up to 5 minutes late, far inside `max_lateness_seconds` (3 hours), and the 5-minute send lease matches the cadence. A run handles at most 100 rows and one message per person (the task's built-in limit), roughly 1,200 an hour at this cadence; if reminders bunch up at popular times beyond that, tighten to `*/2` rather than adding steps. Retries 0 and a generous timeout because a run killed mid-send is the one way a DM can repeat (the leased row comes back after 5 minutes); the next fire is never more than 5 minutes away anyway.
- **`notifications-ship-reminders`** only queues rows. Running it while notifications are off would queue messages the dispatcher later drops as stale (`event_max_lateness_seconds`, two days), so there is no point creating it earlier. To save pod starts it can be folded into the dispatch job, either as a first step (a failing scan then skips that dispatch) or as one command, `bin/rails notifications:ship_reminders notifications:dispatch` (one Rails boot for both; rake stops at the first task that raises). The scan then runs every 5 minutes instead of 15, which is more database work but changes nothing else: it is idempotent.
- **`notifications-schedule-all`** is a safety net: daily reminders normally re-queue themselves (onboarding, settings changes, each send). It walks every onboarded user, which is why it is daily rather than a step of the dispatch job. Run it once on demand right after switching notifications on.

## Background jobs

Active Job uses the in-process `:async` adapter (jobs run in the web process and are lost on restart); the only job is `DispatchNotificationsJob`, which the cron command above replaces. If real jobs arrive, either keep `:async` for fire-and-forget work or add Solid Queue properly: run `bin/rails solid_queue:install`, add its tables (queue schema in its own migration path, mirroring `cache` in `config/database.yml`), set `config.active_job.queue_adapter = :solid_queue` in `config/environments/production.rb`, then set `SOLID_QUEUE_IN_PUMA=1`.

## Client IPs and throttling

Rack::Attack limits `POST /auth/*` and `/dev_login` to 10 per minute, `/api/privacy/*` to 120 per minute writes under `/admin/shop` to 60 per minute and all other requests to 300 per 5 minutes, per client IP. The client IP is the one `request.remote_ip` reports: the right-most `X-Forwarded-For` address that is not a trusted proxy, so a spoofed entry written by the client (on the left) never counts. Private and loopback addresses are always trusted. If the proxy in front of the app has a public address (a CDN, a cloud load balancer), add it to `TRUSTED_PROXIES`. Without that every visitor shares the proxy's address and therefore one throttle bucket: a few hundred requests in five minutes would lock everyone out. Do not list a range you do not control, and never a catch-all.

Counters are stored in Solid Cache (PostgreSQL), so limits hold across Puma workers, containers and restarts. If the cache is unavailable (database down, table missing) throttling fails open: requests go through, one log line per minute reads `Rack::Attack cache store failed (...)` with the error class and no key or IP. Development and test use an in-process memory store and need no cache table.

## Before launch (blocking)

**Launch-blocking: do not open sign-ups until the Hack Club "yeet" deletion service is set up.** Hack Club's yeeter calls `POST /api/privacy/delete` and `POST /api/privacy/export` on every program when a person asks for their data to be deleted or exported, and there is no self-service alternative in this app. The endpoints are built and tested; what is left is the registration and a real dry run. Details of the API, token checks and responses are in `docs/PRIVACY_API.md`.

- [ ] Ask Hack Club infrastructure to register Battletown as a deletion target with: program name `Battletown`; audience `battletown` (give them the `PRIVACY_AUDIENCE` value instead if you changed it); base URL = the public origin of the API server, for example `https://battletown.example.com`, with no `/api/privacy/...` path (the yeeter appends it). If the API runs on a different host than the frontend, use the API host: the frontend URL is wrong.
- [ ] Make sure that host is in `APP_HOST` (production answers any other host with 403) and that `https://<host>/api/privacy/delete` is reachable over https with no redirect. The yeeter does not follow redirects and gives up after 15 seconds, so plain `http`, a `www` redirect or a slow cold start all fail.
- [ ] Run `bin/rails db:prepare` against the production database so the `privacy_request_tokens` table exists (the default container command already does). Leave `PRIVACY_JWKS_URL` unset in production so the signing keys come from `https://yeet.hackclub.com/.well-known/jwks.json`.
- [ ] Ask infrastructure to run a dry run against a test account (sign in once with your own email to create it). Check the response has `found: true`, `dry_run: true`, 1 user and your notifications, that the account still exists afterwards, and review the counts before approving a real deletion (which must produce the same numbers).
- [ ] Decide how long to keep the `request_id` log lines (`privacy request_id=... outcome=...`; they hold no personal data) and which records, if any, must be kept after a deletion. If some must be kept, add entries to `RETENTION_RULES` in `Privacy::Deleter` and make those rows survive the cascade. Today nothing is retained.
- [ ] Confirm the export response shape with infrastructure during the dry run. It is an assumption mirrored from Flavortown (the same fields as the delete response, computed as a dry run), not taken from a spec.

## Pre-deploy checklist

1. Set at least `APP_URL`, `DATABASE_URL`, `SECRET_KEY_BASE`, `HCA_CLIENT_ID`, `HCA_CLIENT_SECRET`; set `APP_HOST` if there is more than one hostname.
2. Register `$APP_URL/auth/hack_club/callback` in Developer Apps (above) and confirm the app has all scopes enabled. Register `$APP_URL/auth/hackatime/callback` on the Hackatime OAuth app (scopes `profile` and `read`), and set the three `ACTIVE_RECORD_ENCRYPTION_*` values (production does not boot without them).
3. Check the platform routes to container port 80 (or set `HTTP_PORT`), terminates TLS and sends `X-Forwarded-Proto: https`.
4. Point the platform health check at `GET /up` (expects 200) over HTTP or HTTPS, any host.
5. Decide `TRUSTED_PROXIES` (above). If unsure, deploy without it, then check from two different networks that one is not throttled by the other's traffic.
6. Database: the first start runs `bin/rails db:prepare`. To run it by hand: `bin/rails db:prepare` with the production environment variables. Confirm it printed `Migrating to CreateSolidCacheEntries` on a fresh database and that `\dt` shows `users` and `solid_cache_entries`.
7. After the app is up:
   - `curl -i https://$APP_HOST/up` returns 200; a request with a wrong `Host` returns 403 on any other path.
   - Throttle store check: `bin/rails runner 'p [Rails.cache.class, Rack::Attack.cache.store.class]'` prints `SolidCache::Store` and `FailOpenCacheStore`. Counters appear in `solid_cache_entries` (`select count(*) from solid_cache_entries;` grows as pages are requested). Sending 11 `POST /auth/hack_club` from one machine within a minute (without a valid CSRF token is fine) returns 429 on the 11th; that machine is then blocked for up to a minute.
   - No `Rack::Attack cache store failed` lines in the log.
8. First-login smoke test with a real account: landing page, "Sign up with Hack Club", consent at auth.hackclub.com, callback, onboarding steps through to the dashboard, log out, log in again (goes straight to the dashboard). Check the log shows no parameters from the onboarding form (they are filtered).
9. Remove any leftover test account you do not want. Then work through "Before launch (blocking)" above: registering with the Hack Club yeet deletion service is required before real users sign up.

Dockerfile note: it has no `HEALTHCHECK` instruction, because a wrong one can mark a healthy container unhealthy on some platforms. If yours wants one, this matches the default layout: `HEALTHCHECK --interval=30s --timeout=5s --start-period=40s CMD curl -fsS http://localhost:${HTTP_PORT:-80}/up || exit 1`.

## Rollback

- Redeploy the previous image. Sessions are cookie based (signed with `SECRET_KEY_BASE`), so a rollback does not log anyone out as long as that variable is unchanged.
- The only schema change in this readiness work is the additive `solid_cache_entries` table; older code ignores it. The cache holds nothing that cannot be rebuilt: `truncate solid_cache_entries;` is always safe, and so is dropping the table.
- Migrations are forward only. Before shipping a migration that drops or rewrites data, take a database backup; roll a migration back with `bin/rails db:migrate:down:primary VERSION=<timestamp>` (or `db:migrate:down:cache` for the cache connection) only after the old image is serving.
- To undo only the shared throttle store (for example if the cache database misbehaves), the fail-open wrapper already keeps the site up; redeploy the previous image to return to the previous in-process counters.

## Performance

Checked locally against a throwaway database seeded at launch-scale volume (thousands of users with mixed time zones, about half a million hours rows over four weeks, plus the matching settled days, ships, orders, coin ledger rows and notifications), with production-like settings (no reloading, eager loading, info logging) and server times read from the Rails log.

- **User pages** (dashboard, shop, orders, projects, ships, settings, Hackatime): every one is under the 150 ms server-time target, met with room to spare. The dashboard is the heaviest: most of its time is the two community aggregates on the boss card (the week's damage and today's active count), which scan the whole week of the ledger and grow with it. If it ever nears the target, cache those two numbers for a minute; never cache the defeat check.
- **Admin pages**: all under 150 ms except `/admin/metrics`, which stays under a second. Its funnel used to take far longer (an `IN (subquery)` inside an aggregate `FILTER` that PostgreSQL re-read once per user); it now uses `EXISTS`.
- **`game:settle`**: an hourly run for everyone takes seconds, and even settling four weeks for every user from nothing stays under three minutes. Target (a few minutes) met.
- **Hours writes**: each new ledger row used to re-sum the boss week. `Hours::Sync`, `hours:import` and `hackatime:sync` now run inside `Bosses::CheckDefeat.batched`, so a sync checks each boss once (several times cheaper per synced day).
- **`notifications:ship_reminders`**: seconds per run (one pass over the projects with linked Hackatime projects, owners preloaded). `notifications:dispatch` handles at most 100 rows per run and stays well under a second with the null adapter; with `NOTIFICATIONS_ENABLED` unset it does nothing.
- **Indexes added**: a partial index on pending notifications by `subject_id` (`index_notifications_on_pending_subject_id`, built `CONCURRENTLY`), so submitting a ship cancels its reminders without scanning every pending row. A covering index for the boss sums was tried and did not help (the ledger is already laid out by date), so it was not added.

To re-check: create a separate scratch database (never the shared development one), `db:schema:load` it, bulk-load fake data with `insert_all` or `COPY`, run `bin/rails game:settle` once, then start the server on a spare port with `DATABASE_URL` pointing at it and time the pages from `log/development.log` (`Completed ... in Xms`). Use `EXPLAIN (ANALYZE, BUFFERS)` on anything slow. Keep the seed script and raw numbers out of the repository, and drop the database afterwards.

## Known limits (not defects)

- A missing `HCA_CLIENT_ID` / `HCA_CLIENT_SECRET` is not detected at boot; sign-in fails when a visitor tries it. The smoke test catches it.
- `/up` does not check the database. A database outage shows up as 500s, not as a failing health check.
- If the cache table is missing (only possible if `db:prepare` did not run), the landing page's cached member count raises; run `db:prepare`.
- Only the Rails frameworks the app uses are loaded (no Active Storage, Action Mailbox or Action Text), so there are no `/rails/...` upload or inbound-email endpoints.
- Headers: Rails default security headers, an enforced nonce-based CSP, a Permissions-Policy, and HSTS (one year, subdomains included) via `force_ssl`. HSTS is sent whenever the request looks like HTTPS, and `assume_ssl` makes every request look like HTTPS, so the proxy must be the only way in.
