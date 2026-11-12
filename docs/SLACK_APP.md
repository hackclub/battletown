# Slack app

Battletown sends reminder DMs through a Slack app (a bot) in the Hack Club workspace. The Rails app does all the work
(`Notifications::Slack::WebApiAdapter`, see `app/services/notifications/`), so there is no separate server or Node
project. The app only needs a bot token.

The app is described by `config/slack/manifest.yml`: name "Battletown", one bot scope (`chat:write`), no user scopes,
no event subscriptions, no interactivity, no slash commands, no Socket Mode. `chat:write` lets the bot post messages,
including into a person's DM with it (a Slack user id works as the `channel`). It cannot read messages, channels, users
or email addresses. A new scope, event or command needs the project owner's approval, and the test in
`test/services/notifications/slack/check_test.rb` fails if the manifest and `EXPECTED_SCOPES` drift apart.

## Create the app (once, by a person)

An app cannot be created from code here without a Slack configuration token, and nobody should paste one into chat or
commit one. Do it by hand:

1. Open https://api.slack.com/apps and choose Create New App, then From a manifest.
2. Pick the **Hack Club** workspace.
3. Paste the contents of `config/slack/manifest.yml` (the YAML tab) and create the app.
4. Choose Install to Workspace. If the workspace requires app approval, Slack sends the request to the workspace admins;
   wait for them to approve it.
5. Open OAuth & Permissions and copy the **Bot User OAuth Token** (starts with `xoxb-`).
6. Put it in the Rails app's environment as `SLACK_BOT_TOKEN` (your host's secret/env settings, or a local `.env` that
   is never committed). Never put it in the repo, a chat or a log.
7. Run `bin/rails slack:check`. It calls Slack's `auth.test`, prints the workspace, the bot name and its scopes (never
   the token), and exits non-zero if the token is missing, rejected, not a bot token, or has scopes beyond `chat:write`.
8. Optional: `bin/rails "slack:self_test[U...]"` sends one test DM to the Slack user id you give (use your own). It
   refuses to run without `SLACK_BOT_TOKEN` and never sends to anyone else. It does not need `NOTIFICATIONS_ENABLED`
   because it is a single message you asked for.
9. Only when ready, set `NOTIFICATIONS_ENABLED=true` to let the app send the daily reminders to users (see
   `config/notifications.yml`; run `bin/rails notifications:dispatch` from cron or the `DispatchNotificationsJob`).
   Unset it or set anything else to stop all sending at once. Without `SLACK_BOT_TOKEN` (development) the dispatcher
   uses the log adapter and records each due row as `skipped` (code `not_delivered`), never `sent`; in production it
   refuses to run at all without the token.

## Who owns and runs it

- Prefer creating the app under a shared Hack Club-owned Slack account (or at least add a second admin as a
  collaborator under Settings, Collaborators) rather than one person's account, so the app and its token do not depend on
  one person.
- Workspace admins may need to approve the app before it can be installed.
- Decide who can see and rotate the token. If it leaks, revoke or reinstall from OAuth & Permissions, update
  `SLACK_BOT_TOKEN`, and run `bin/rails slack:check` again.
- Users are teens: the bot only sends the reminder copy from `config/notifications.yml`, only to users who finished
  onboarding with a Slack id, and nothing is stored beyond the existing notification rows.
