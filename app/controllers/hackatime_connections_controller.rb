# Hackatime account linking (projects/battletown/specs/hackatime.md). Additive to Hack Club Auth: the visitor must already be
# signed in, and nothing here ever creates a user or starts a session. Connecting is a required step of onboarding (the
# account step sends people here and takes them back); after that it is managed on /hackatime. It never blocks coding.
class HackatimeConnectionsController < ApplicationController
  ALREADY_LINKED = "That Hackatime account is already connected to another Battletown account.".freeze
  # Revoking old tokens runs inside the request, so a slow Hackatime gets a short leash: all revoke calls together take
  # at most REVOKE_BUDGET seconds (each one's connect and read timeouts are cut to fit what is left of it).
  REVOKE_BUDGET = 2.0
  REVOKE_TIMEOUT = 1.0

  before_action :require_login
  # The callback is part of onboarding, so someone who has not finished can come back through it; the connect page and
  # disconnecting are for people who are in.
  before_action :require_onboarded, except: :create
  before_action :no_store

  def show
    @connection = current_user.hackatime_connection
  end

  # GET /auth/hackatime/callback. OmniAuth has already checked the state and exchanged the code by now.
  #
  # A rejected link does not revoke the token Hackatime just issued: Hackatime reuses one token per person and app,
  # so revoking it could cut off the connection of whoever legitimately holds that Hackatime account here.
  def create
    @chained = session.delete(:hackatime_chain) # started by the sign-in chain, not from a page
    auth = request.env["omniauth.auth"]
    uid = auth&.provider.to_s == "hackatime" ? auth.uid.to_s : nil
    token = auth&.credentials&.token.to_s
    unless uid&.match?(HackatimeConnection::UID_FORMAT) && token.present?
      return redirect_to after_path, alert: "We couldn't connect to Hackatime. Please try again."
    end

    attributes = connection_attributes(auth, token)
    unless (HackatimeConnection::REQUIRED_SCOPES - attributes[:scopes].split).empty?
      return redirect_to after_path, alert: "Hackatime didn't grant the access we need. Connect again and keep both permissions ticked."
    end
    return redirect_to after_path, alert: ALREADY_LINKED if taken_by_someone_else?(uid)

    connection = current_user.hackatime_connection || current_user.build_hackatime_connection
    # Tokens this replaces (a reconnect, maybe to another Hackatime account). One Hackatime handed back again is kept.
    replaced = [ connection.access_token, connection.refresh_token ].compact_blank - [ token, attributes[:refresh_token] ]
    connection.assign_attributes(attributes.merge(hackatime_uid: uid, connected_at: Time.current, needs_reconnect: false, last_error_code: nil))
    connection.save!
    # After the save, as when disconnecting: they are no longer kept here, so Hackatime should drop them too. Never raises.
    revoke(replaced)
    redirect_to after_path, notice: "Hackatime connected."
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Two accounts racing for the same Hackatime uid: the unique index decides, and nobody is told who the other is.
    redirect_to after_path, alert: ALREADY_LINKED
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

  # Where a connect attempt ends: back on the onboarding account step for someone still onboarding, else /hackatime.
  # Someone who is in and came here through the sign-in chain never asked to see the Hackatime page: back to the dashboard.
  def after_path
    return onboarding_step_path("account") unless current_user.onboarded?

    @chained ? dashboard_path : hackatime_path
  end

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
