# Privacy API: data deletion and export (Hack Club "yeet")

Hack Club's data-deletion service ("the yeeter", https://yeet.hackclub.com/docs/deletions) calls two endpoints on every program when a person asks for their data to be deleted or exported. There is no self-service account page in this app: requests come through Hack Club.

| Endpoint | Does |
| --- | --- |
| `POST /api/privacy/delete` | Deletes the person's data. With `dry_run: true` in the token it reports the counts and changes nothing |
| `POST /api/privacy/export` | Reports what this app holds about the person. It never changes anything, whatever the token's `dry_run` says |

Both take no body, `Authorization: Bearer <JWT>` and `Accept: application/json`. The yeeter times out after 15 s and does not follow redirects (so the base URL must be the final `https` host). It retries 408, 425, 429, 5xx and network errors (at 10, 30, 90 and 270 s, up to 5 attempts); other errors fail at once. Staff review the dry-run counts before approving the real deletion, which must produce the same numbers.

Code: `app/controllers/api/privacy_controller.rb` and `app/services/privacy/` (`Jwks`, `TokenVerifier`, `SubjectFinder`, `Deleter`), table `privacy_request_tokens`.

## Onboarding (what the owner gives the infrastructure team)

Ask Hack Club infrastructure to register this program with:

1. **Name**: Battletown
2. **Audience**: `battletown` (the default; override with `PRIVACY_AUDIENCE`, then give them that value instead)
3. **Base URL of the API**: the public origin of this app, without `/api/privacy/...`, for example `https://battletown.example.org` (the yeeter appends `/api/privacy/delete` and `/api/privacy/export`).

Requirements on our side:

- The host in the base URL must be in `APP_HOST` (production answers any other host with 403, see `config.hosts`). Use the same host as `APP_URL`.
- It must be reachable over `https` without a redirect: `config.force_ssl` redirects plain `http`, and the yeeter does not follow redirects.
- Run `bin/rails db:prepare` (creates `privacy_request_tokens`).
- Leave `PRIVACY_JWKS_URL` unset in production (it defaults to `https://yeet.hackclub.com/.well-known/jwks.json`).

| Variable | Default | Purpose |
| --- | --- | --- |
| `PRIVACY_AUDIENCE` | `battletown` | The `aud` a token must carry, matched exactly |
| `PRIVACY_JWKS_URL` | `https://yeet.hackclub.com/.well-known/jwks.json` | Where the signing keys are fetched. Production accepts `https` only; development also accepts `http` (for a local key server) |

## How a request is checked

The token is an ES256 JWT. It is accepted only if all of these hold, otherwise the answer is `401 {"error":"invalid_token"}` with no detail:

- header `alg` is `ES256`, `typ` is `JWT`, and `kid` names a key in the JWKS; the signature verifies with that key (no other algorithm, `none` and HMAC included, is ever accepted)
- `iss` is `hackclub-privacy` and `aud` equals the audience exactly
- `iat`/`exp` are integers, `exp - iat` is at most 300 s, and the token is not expired or issued in the future (30 s leeway)
- `jti` and `request_id` are non-empty printable strings, `action` is `delete` or `export`, `dry_run` is a boolean, `subject` is an object

Then, in this order: the `action` must match the endpoint (else `400 {"error":"action_mismatch"}`), and the `jti` is stored in `privacy_request_tokens`; a `jti` seen before gets `409 {"error":"replayed"}`. A `jti` is stored only after the token is verified, so unauthenticated callers cannot fill the table, and a dry run uses up its `jti` like any other call (the yeeter mints a new one per attempt).

The person is identified **only** from the token's `subject`; the body, query string, cookies and session are never read.

Keys: the JWKS is fetched over `https` (3 s open and 5 s read timeout, no redirects, 64 KB cap, only the configured URL), cached in process for 5 minutes, and refetched when a token names an unknown `kid`, at most once every 30 s. If the keys cannot be fetched the answer is `503 {"error":"jwks_unavailable"}` (retried by the yeeter) and nothing is changed. A database outage is `503 {"error":"database_unavailable"}`; any other failure is `500 {"error":"internal_error"}`. Other verbs and paths under `/api/privacy/` answer `405`/`404` in JSON.

The controller is an `ActionController::API`: no session, no cookie (`Set-Cookie` is never sent), no CSRF check (bearer auth only), `Cache-Control: no-store`.

## Finding the person

A user matches if any one of these is true: `lower(users.email)` is one of `subject.emails` (compared case-insensitively), `users.slack_id` equals `subject.slack_id`, or `users.hca_uid` equals `subject.identity_id`. `hca_uid` is the Hack Club Auth OIDC `sub`, shaped `ident!...` (the Dev login user in development is `dev-user` and never matches a real request). Empty values never match. No match is `200` with `found: false`.

## Response

```json
{ "request_id": "...", "dry_run": false, "found": true,
  "deleted": { "notifications": 2, "users": 1 }, "retained": [] }
```

`request_id` and `dry_run` are echoed from the token. `deleted` is the number of rows removed per table (counts only, no personal data); `retained` lists `{ "type", "count", "reason" }` for records kept because other people depend on them. `export` returns the same shape, computed as a dry run, with `dry_run` echoed from the token.

## What is deleted, what is retained

- **Deleted**: the `users` row (name, email, Slack id, Hack Club Auth id, schedule, onboarding answers, referral source) and, through `ON DELETE CASCADE` foreign keys, everything that belongs to it (today: `notifications`). One code path serves dry and real runs: the deletion runs in a transaction, Postgres's per-transaction delete counters give the per-table counts, and a dry run rolls back, so the reviewed numbers are the executed numbers. The deletion refuses (500, nothing changed) if the counters do not account for every user it deleted.
- **Retained**: nothing today (`retained` is `[]`). If a future table must keep rows (for example shared records others rely on), add a rule to `Privacy::Deleter::RETENTION_RULES` and make the rows survive the cascade. Anything that needs a human decision should answer `409 {"error":"manual_review_required"}`; nothing does today.
- **Not covered here**: Slack messages already sent, and copies in systems Hack Club runs (Hack Club Auth, Airtable, backups). Backups age out with the database backup retention.
- A guard test (`test/models/privacy_schema_guard_test.rb`) fails the suite when a table references `users` without `ON DELETE CASCADE`, when a column that looks personal (`user_id`, email, Slack, ...) is neither a cascading foreign key nor listed with a reason, or when a table that references users is not shown in the deletion counts. Add the table to that test when you add one.

## Logging

Only the `request_id` and the outcome are logged, for example `privacy request_id=abc action=delete outcome=ok`. Outcomes: `ok`, `invalid_token` (no request id: the token is not trusted), `action_mismatch`, `replayed`, `jwks_unavailable`, `database_unavailable`, `error` (with the exception class name, never its message). Never log tokens, emails, Slack ids, identity ids or per-person counts. The controller silences Active Record's query log below `info` while it runs (at `debug` Rails would otherwise log the SQL with the matched email), so even a debug log holds nothing about the person; production stays at `info` anyway.

## Token table and clean-up

`privacy_request_tokens` holds `jti`, `request_id`, `action`, `dry_run` and `created_at`, no personal data, with check constraints (non-empty `jti`, length caps). Rows older than 7 days are deleted as requests arrive, and by hand or cron with `bin/rails privacy:purge_tokens`.

## Rate limit

Rack::Attack allows 120 requests a minute per client IP on `/api/privacy/*` (the same client-IP logic as the other limits); those paths are excluded from the general per-IP limit. The yeeter retries a 429.

## Testing a dry run

Against a deployed app only Hack Club's service can mint a valid token. Ask infrastructure to run a dry run for a test account (a user you created by signing in, with your own email), and check that the response has `found: true`, `dry_run: true`, and counts of 1 user and your notifications, and that the account still exists afterwards. For a local check, run a local key server, set `PRIVACY_JWKS_URL=http://127.0.0.1:<port>/jwks.json` (development only), sign a token with the matching private key and `curl -X POST -H "Authorization: Bearer $TOKEN" http://localhost:3800/api/privacy/delete`. The automated tests (`test/integration/privacy_api_test.rb`) do the same with a generated key and a stub in place of the network.
