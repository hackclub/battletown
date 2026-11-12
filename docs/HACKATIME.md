# Hackatime account linking and live hours

Players can link their Hackatime account (voluntary; it never blocks coding). Identity is the **Hackatime user id** returned by Hackatime, not a Slack id match. Public-safe: no secrets here.

Sources: Hackatime docs (https://hackatime.hackclub.com/docs/oauth/oauth-apps, https://hackatime.hackclub.com/api-docs, OpenAPI at `/openapi.json`) and the public source (https://github.com/hackclub/hackatime: `config/initializers/doorkeeper.rb`, `app/controllers/api/v1/authenticated/*`, `app/services/project_stats_query.rb`).

## OAuth

| Thing | Value |
| --- | --- |
| Authorize | `GET https://hackatime.hackclub.com/oauth/authorize` (`response_type=code`, `client_id`, `redirect_uri`, `scope`, `state`, `code_challenge`, `code_challenge_method=S256`) |
| Token | `POST /oauth/token`, form body (`grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `client_secret`, `code_verifier`) |
| Revoke | `POST /oauth/revoke` (`token`, `client_id`, `client_secret`) |
| Scopes requested | exactly `profile read` (the Hackatime app has no others) |
| Redirect URI | `$APP_URL/auth/hackatime/callback` |
| Token lifetime | about 16 years (Doorkeeper `access_token_expires_in 16.years`, `reuse_access_token`). No `use_refresh_token` setting was found, so Hackatime most likely issues **no refresh token**. |

The app uses PKCE (S256) and `state` (OmniAuth), and a confidential client (secret in the request body). Doorkeeper's PKCE support is documented on the OAuth apps page; the source has no explicit PKCE setting, so the first real round trip confirms it is accepted.

Because tokens last so long and cannot be refreshed, `Hackatime::Client` refreshes only if a refresh token and an expiry exist; otherwise an expired or rejected token marks the connection `needs_reconnect` and the user connects again from `/hackatime`.

## API calls used

| Call | Scope | Used for |
| --- | --- | --- |
| `GET /api/v1/authenticated/me` | `profile` | The Hackatime user `id` at link time. Nothing else from the response (emails, Slack id, GitHub name) is read or stored. |
| `GET /api/v1/authenticated/projects?start_date=<ISO 8601>&end_date=<ISO 8601>&include_archived=true` | `read` | Seconds per project inside a time window. Called once per local day, so it yields per-day, per-project seconds. |

Why not the obvious endpoints:

- `GET /api/hackatime/v1/users/current/summaries` (per-day, per-project) is the best shape, **but it only accepts Hackatime API keys, not OAuth tokens**: `Api::Hackatime::V1::HackatimeController#set_user` calls `api_user_from_credentials` without `oauth_scopes`.
- `GET /api/v1/authenticated/hours?start_date&end_date` accepts OAuth `read`, but returns one total, has no project, and buckets days in the server's time zone (no timezone parameter), so it cannot respect a player's local day.
- `GET /api/v1/my/heartbeats` (OAuth `read`) returns raw heartbeats; usable as a fallback but heavy (a full day can be thousands of rows).

`/authenticated/projects` is documented only with `include_archived`. The `start_date` / `end_date` window is read from the source (`ProjectStatsQuery#stats_start_time`: `start`/`start_date`, `end`/`end_date`, parsed with `to_datetime`, so a UTC offset is honoured; the filter is inclusive at both ends and ignores `rollup` caching once a window is given). Treat this as the one piece to confirm against the live service (see the checklist below). Projects with no project name are not counted by this endpoint.

Time zones: `Hackatime::HttpSource` uses the player's `users.time_zone` (an ActiveSupport zone name, default from their Hack Club Auth address). For each local date it sends the local midnight and the next local midnight minus one millisecond, with the UTC offset, so a 23 or 25 hour day around DST is correct. "Today" is the player's today (future days are never requested).

Rate limits: nothing is documented for OAuth callers. The Hackatime source configures a general throttle of 300 requests a minute per OAuth user on `/api/v1/authenticated/*` (currently disabled in the code). One day costs one request; the source refuses ranges over 62 days.

## What is stored

Table `hackatime_connections` (one row per user, `ON DELETE CASCADE`, so deleting a user or a data-deletion request removes it): `hackatime_uid`, `access_token` and `refresh_token` (Active Record encryption, never logged), `scopes`, `expires_at`, `connected_at`, `last_synced_at`, `last_error_code` (a short code, never a message), `needs_reconnect`. Nothing else about the person is requested or kept.

## Hours source seam

`Hackatime::HttpSource#daily_seconds(user:, from:, to:)` returns `Hackatime::DaySeconds(date:, seconds:, project:)` rows and raises `Hackatime::Client::AuthError` (user must reconnect) or `Hackatime::Client::RetryableError` (rate limited, Hackatime down). A user with no connection, or one that needs reconnecting, has no rows. A successful call sets `last_synced_at`.

Wiring: `Hackatime::HttpSource` includes `Hackatime::Source`. `Hackatime.source` (the default of `Hours::Sync`) returns it when `hours_source: http` under `hours:` in `config/game.yml`, or when the `HOURS_SOURCE=http` environment variable is set (the variable wins); the shipped default is `null`, so nothing calls Hackatime until you flip it. `bin/rails "hackatime:sync[all]"` (or `hackatime:sync[<user id>]`) runs `Hours::Sync` with the live source for every linked user who does not need a reconnect, and prints counts only (users, needs_reconnect, retry_later, credited seconds/days). It is safe to repeat and meant for cron. A rejected token marks the connection `needs_reconnect`; 429, 5xx and timeouts are counted as `retry_later` and tried again on the next run.

## Verifying the real round trip

1. Put the OAuth app credentials in `.env` (`HACKATIME_CLIENT_ID`, `HACKATIME_CLIENT_SECRET`) and the three `ACTIVE_RECORD_ENCRYPTION_*` values (`bin/rails db:encryption:init`).
2. The Hackatime app's redirect URI must be exactly `http://localhost:3000/auth/hackatime/callback`; run `bin/rails s` on port 3000.
3. Sign in (Hack Club Auth or Dev login), finish onboarding, open `/hackatime`, press Connect. Expect a Hackatime consent screen asking for `profile` and `read`, then the page showing Connected.
4. In `bin/rails console`, `Hackatime::HttpSource.new.daily_seconds(user: User.find(...), from: Date.current - 2, to: Date.current)` should return the rows you expect. Compare one day with the Hackatime dashboard. If the window parameters are ignored, every day would return the same all-time totals.
5. Disconnect and confirm the row is gone and Hackatime no longer lists the app as authorised.
