# Deploying Battletown

Nothing here has been run against a real deployment target: it was written and checked locally (production-mode boot, `db:prepare` against scratch PostgreSQL databases, the test suite) without Docker. Treat the first deploy as the real test and work through the checklist below.

## Shape of the deploy

- One container built from the `Dockerfile` (multi-stage, runs as the non-root user `rails`, uid 1000).
- PostgreSQL is the only service. There is no Redis, no Memcached, no mail server, no object storage. Throttle counters and the landing page cache live in the same PostgreSQL database (Solid Cache).
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
| `SOLID_QUEUE_IN_PUMA` | no, leave unset | Would run the Solid Queue supervisor inside Puma. There are no jobs and no queue tables, so enabling it only crashes the supervisor. See "Background jobs". | |
| `ADMIN_HCA_UIDS` | no (added by the admin work, may not be merged yet) | Comma-separated Hack Club Auth `sub` values of admins. Unset: nobody is an admin and `/admin` returns 404. | `ident!abc123,ident!def456` |
| `SLACK_BOT_TOKEN` | no (added by the notifications work, may not be merged yet) | Bot token that enables real Slack DMs. Unset: the null adapter is used and nothing is sent. Treat as a secret. | `xoxb-...` |

`bin/rails runner 'p Rails.application.config.hosts'` is a quick way to see the host allowlist the container ended up with.

### Hack Club Auth app

Register this redirect URI in the app at auth.hackclub.com (Developer Apps), exactly, with no trailing slash:

```
$APP_URL/auth/hack_club/callback
```

The app requests the scopes `openid profile email name phone birthdate address verification_status slack_id basic_info`, all of which must be enabled on the app.

## Database layout

One PostgreSQL database, set with `DATABASE_URL`. `config/database.yml` defines two connections in production: `primary` (everything the app stores) and `cache` (Solid Cache), both pointing at that database by default. The cache connection has its own migration path (`db/cache_migrate`), so the `solid_cache_entries` table is created by `db:prepare` without touching `db/schema.rb`. `CACHE_DATABASE_URL` moves it to a separate database (`db/cache_schema.rb` is loaded when that database does not exist yet).

Solid Queue and Solid Cable are installed as gems but not configured: the previous `queue` and `cable` database entries had no schema or consumer, would have made `db:prepare` fail on a single-database platform, and are removed. Action Cable uses the in-process `async` adapter (no Redis).

## Background jobs

There are none today and Active Job uses the in-process `:async` adapter (jobs run in the web process and are lost on restart). When real jobs arrive (Slack notifications), either keep `:async` for fire-and-forget work or add Solid Queue properly: run `bin/rails solid_queue:install`, add its tables (queue schema in its own migration path, mirroring `cache` in `config/database.yml`), set `config.active_job.queue_adapter = :solid_queue` in `config/environments/production.rb`, then set `SOLID_QUEUE_IN_PUMA=1`.

## Client IPs and throttling

Rack::Attack limits `POST /auth/*` and `/dev_login` to 10 per minute and all other requests to 300 per 5 minutes, per client IP. The client IP is the one `request.remote_ip` reports: the right-most `X-Forwarded-For` address that is not a trusted proxy, so a spoofed entry written by the client (on the left) never counts. Private and loopback addresses are always trusted. If the proxy in front of the app has a public address (a CDN, a cloud load balancer), add it to `TRUSTED_PROXIES`. Without that every visitor shares the proxy's address and therefore one throttle bucket: a few hundred requests in five minutes would lock everyone out. Do not list a range you do not control, and never a catch-all.

Counters are stored in Solid Cache (PostgreSQL), so limits hold across Puma workers, containers and restarts. If the cache is unavailable (database down, table missing) throttling fails open: requests go through, one log line per minute reads `Rack::Attack cache store failed (...)` with the error class and no key or IP. Development and test use an in-process memory store and need no cache table.

## Pre-deploy checklist

1. Set at least `APP_URL`, `DATABASE_URL`, `SECRET_KEY_BASE`, `HCA_CLIENT_ID`, `HCA_CLIENT_SECRET`; set `APP_HOST` if there is more than one hostname.
2. Register `$APP_URL/auth/hack_club/callback` in Developer Apps (above) and confirm the app has all scopes enabled.
3. Check the platform routes to container port 80 (or set `HTTP_PORT`), terminates TLS and sends `X-Forwarded-Proto: https`.
4. Point the platform health check at `GET /up` (expects 200) over HTTP or HTTPS, any host.
5. Decide `TRUSTED_PROXIES` (above). If unsure, deploy without it, then check from two different networks that one is not throttled by the other's traffic.
6. Database: the first start runs `bin/rails db:prepare`. To run it by hand: `bin/rails db:prepare` with the production environment variables. Confirm it printed `Migrating to CreateSolidCacheEntries` on a fresh database and that `\dt` shows `users` and `solid_cache_entries`.
7. After the app is up:
   - `curl -i https://$APP_HOST/up` returns 200; a request with a wrong `Host` returns 403 on any other path.
   - Throttle store check: `bin/rails runner 'p [Rails.cache.class, Rack::Attack.cache.store.class]'` prints `SolidCache::Store` and `FailOpenCacheStore`. Counters appear in `solid_cache_entries` (`select count(*) from solid_cache_entries;` grows as pages are requested). Sending 11 `POST /auth/hack_club` from one machine within a minute (without a valid CSRF token is fine) returns 429 on the 11th; that machine is then blocked for up to a minute.
   - No `Rack::Attack cache store failed` lines in the log.
8. First-login smoke test with a real account: landing page, "Sign up with Hack Club", consent at auth.hackclub.com, callback, onboarding steps through to the dashboard, log out, log in again (goes straight to the dashboard). Check the log shows no parameters from the onboarding form (they are filtered).
9. Then remove any leftover test account you do not want (there is a self-service data deletion page if the account feature has been merged).

Dockerfile note: it has no `HEALTHCHECK` instruction, because a wrong one can mark a healthy container unhealthy on some platforms. If yours wants one, this matches the default layout: `HEALTHCHECK --interval=30s --timeout=5s --start-period=40s CMD curl -fsS http://localhost:${HTTP_PORT:-80}/up || exit 1`.

## Rollback

- Redeploy the previous image. Sessions are cookie based (signed with `SECRET_KEY_BASE`), so a rollback does not log anyone out as long as that variable is unchanged.
- The only schema change in this readiness work is the additive `solid_cache_entries` table; older code ignores it. The cache holds nothing that cannot be rebuilt: `truncate solid_cache_entries;` is always safe, and so is dropping the table.
- Migrations are forward only. Before shipping a migration that drops or rewrites data, take a database backup; roll a migration back with `bin/rails db:migrate:down:primary VERSION=<timestamp>` (or `db:migrate:down:cache` for the cache connection) only after the old image is serving.
- To undo only the shared throttle store (for example if the cache database misbehaves), the fail-open wrapper already keeps the site up; redeploy the previous image to return to the previous in-process counters.

## Known limits (not defects)

- A missing `HCA_CLIENT_ID` / `HCA_CLIENT_SECRET` is not detected at boot; sign-in fails when a visitor tries it. The smoke test catches it.
- `/up` does not check the database. A database outage shows up as 500s, not as a failing health check.
- If the cache table is missing (only possible if `db:prepare` did not run), the landing page's cached member count raises; run `db:prepare`.
- Active Storage is loaded by Rails but unused (`config.active_storage.service = :local`, nothing is uploaded).
- Headers: Rails default security headers, an enforced nonce-based CSP, a Permissions-Policy, and HSTS (one year, subdomains included) via `force_ssl`. HSTS is sent whenever the request looks like HTTPS, and `assume_ssl` makes every request look like HTTPS, so the proxy must be the only way in.
