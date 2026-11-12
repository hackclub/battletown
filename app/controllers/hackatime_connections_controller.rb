# Voluntary Hackatime account linking (docs/HACKATIME.md). Additive to Hack Club Auth: the visitor must already be
# signed in and onboarded, and nothing here ever creates a user or starts a session. Linking never blocks coding.
class HackatimeConnectionsController < ApplicationController
  ALREADY_LINKED = "That Hackatime account is already connected to another Battletown account.".freeze
  # Revoking old tokens runs inside the request, so a slow Hackatime gets a short leash: all revoke calls together take
  # at most REVOKE_BUDGET seconds (each one's connect and read timeouts are cut to fit what is left of it).
  REVOKE_BUDGET = 2.0
  REVOKE_TIMEOUT = 1.0

  before_action :require_login
  before_action :require_onboarded
  before_action :no_store

  def show
    @connection = current_user.hackatime_connection
  end

  # GET /auth/hackatime/callback. OmniAuth has already checked the state and exchanged the code by now.
  #
  # A rejected link does not revoke the token Hackatime just issued: Hackatime reuses one token per person and app,
  # so revoking it could cut off the connection of whoever legitimately holds that Hackatime account here.
  def create
    auth = request.env["omniauth.auth"]
    uid = auth&.provider.to_s == "hackatime" ? auth.uid.to_s : nil
    token = auth&.credentials&.token.to_s
    unless uid&.match?(HackatimeConnection::UID_FORMAT) && token.present?
      return redirect_to hackatime_path, alert: "We couldn't connect to Hackatime. Please try again."
    end

    attributes = connection_attributes(auth, token)
    unless (HackatimeConnection::REQUIRED_SCOPES - attributes[:scopes].split).empty?
      return redirect_to hackatime_path, alert: "Hackatime didn't grant the access we need. Connect again and keep both permissions ticked."
    end
    return redirect_to hackatime_path, alert: ALREADY_LINKED if taken_by_someone_else?(uid)

    connection = current_user.hackatime_connection || current_user.build_hackatime_connection
    # Tokens this replaces (a reconnect, maybe to another Hackatime account). One Hackatime handed back again is kept.
    replaced = [ connection.access_token, connection.refresh_token ].compact_blank - [ token, attributes[:refresh_token] ]
    connection.assign_attributes(attributes.merge(hackatime_uid: uid, connected_at: Time.current, needs_reconnect: false, last_error_code: nil))
    connection.save!
    # After the save, as when disconnecting: they are no longer kept here, so Hackatime should drop them too. Never raises.
    revoke(replaced)
    redirect_to hackatime_path, notice: "Hackatime connected."
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Two accounts racing for the same Hackatime uid: the unique index decides, and nobody is told who the other is.
    redirect_to hackatime_path, alert: ALREADY_LINKED
  end

  def destroy
    connection = current_user.hackatime_connection
    if connection
      tokens = [ connection.access_token, connection.refresh_token ].compact_blank
      connection.destroy!
      # After the delete, so a slow or failing Hackatime can never keep the tokens here. Never raises.
      revoke(tokens)
    end
    redirect_to hackatime_path, notice: "Hackatime disconnected.", status: :see_other
  end

  private

  # Best effort and never raises (Hackatime::Client.revoke). A call's connect and read timeouts are each at most half of
  # the budget left, so the calls together stay within REVOKE_BUDGET; once it is spent, the rest are skipped.
  def revoke(tokens)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REVOKE_BUDGET
    tokens.each do |token|
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if left < 0.1

      Hackatime::Client.revoke(token, timeout: [ REVOKE_TIMEOUT, left / 2 ].min)
    end
  end

  def taken_by_someone_else?(uid)
    HackatimeConnection.where(hackatime_uid: uid).where.not(user_id: current_user.id).exists?
  end

  def connection_attributes(auth, token)
    credentials = auth.credentials
    {
      access_token: token,
      refresh_token: credentials.refresh_token.presence,
      scopes: credentials.scope.to_s.first(100),
      expires_at: credentials.expires_at.present? ? Time.zone.at(credentials.expires_at.to_i) : nil
    }
  end

  def no_store
    response.headers["Cache-Control"] = "no-store"
  end
end
