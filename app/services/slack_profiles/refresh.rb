module SlackProfiles
  # Fetches ONE person's Slack display name and picture and stores what is allowed to be shown (see SlackProfiles). Safe to
  # call any time, from a job or a rake task: it decides for itself whether a fetch is due and it never raises.
  #
  #   outcome = SlackProfiles::Refresh.call(user)     # => Outcome(status:, retry_in:)
  #
  # Steps: no Slack id, no token, or the choice switched off: nothing happens, no request. Otherwise the person's row is
  # CLAIMED under a lock for a few minutes (two jobs for the same person cannot both call Slack), the shared limit is asked (Gate), and
  # one users.info call is made, then the picture is downloaded from Slack's own host and re-encoded (Download, Avatar). Whatever
  # fails, the generated avatar and the current name stay as they were:
  #
  #   ok / no_picture   fetched_at is set: the next fetch is a day away
  #   ratelimited       Slack said wait: the whole app is held for Retry-After (Gate) and this person is retried then
  #   missing_scope,    the app's setup is wrong (the bot needs users:read; token missing, revoked or rejected): one clear log line,
  #   invalid_auth,     the whole app is held for ten minutes, and this person is tried again in an hour, so a reinstall fixes it
  #   no_token          without anyone doing anything
  #   not_found         the person is not in the workspace (or is a bot or deactivated): tried again in a day
  #   error             a network or Slack problem: back off 15 minutes, 1 hour, 6 hours, then a day
  #
  # The name Slack gives is sanitised (Sanitizer) and kept on the person's slack_profiles row when they kept "use my Slack name"; it is
  # shown unless they typed a display name of their own (PublicProfile.name_for). Counts only go to analytics (slack_profile_fetched /
  # slack_profile_failed).
  class Refresh
    Outcome = Data.define(:status, :retry_in)

    LEASE = 5.minutes
    BACKOFF = [ 15.minutes, 1.hour, 6.hours, 24.hours ].freeze
    SETUP_RETRY = 1.hour
    SETUP_BLOCK = 10.minutes
    NOT_FOUND_CODES = %w[user_not_found not_found user_not_visible].freeze
    SCOPE_CODES = %w[missing_scope no_permission].freeze
    AUTH_CODES = %w[invalid_auth not_authed token_revoked token_expired account_inactive org_login_required team_access_not_granted access_denied].freeze

    def self.call(user, now: Time.current, client: Client.new) = new(user, now, client).call

    def initialize(user, now, client)
      @user = user
      @now = now
      @client = client
    end

    def call
      return outcome(:skipped) unless SlackProfiles.eligible?(@user)

      @profile = claim
      return outcome(:skipped) unless @profile

      wait = Gate.wait(now: @now)
      return release(wait) if wait.positive?

      result = @client.user_info(@user.slack_id)
      result.ok? ? succeed(result) : fail_with(result)
    rescue StandardError => error
      Rails.logger.warn("SlackProfiles: refresh failed user_id=#{@user&.id} (#{error.class})")
      outcome(:error)
    end

    private

    def outcome(status, retry_in = nil) = Outcome.new(status: status, retry_in: retry_in)

    # The row, locked for a moment and leased for LEASE, or nil when there is nothing to do (switched off, not due).
    def claim
      attempts = 0
      begin
        SlackProfile.transaction do
          profile = SlackProfile.without_picture.lock.find_by(user_id: @user.id) || SlackProfile.create!(user_id: @user.id)
          next unless (profile.use_name || profile.use_picture) && profile.due?(@now)

          profile.update_columns(next_attempt_at: @now + LEASE, updated_at: @now)
          profile
        end
      rescue ActiveRecord::RecordNotUnique
        retry if (attempts += 1) < 2
        nil
      end
    end

    # The shared limit says wait: give the lease back for that long and come again then.
    def release(wait)
      @profile.update_columns(next_attempt_at: @now + wait, updated_at: @now)
      outcome(:waiting, wait + 1)
    end

    def succeed(result)
      profile = SlackProfile.find(@profile.id)
      name = Sanitizer.display_name(result.name)
      picture_state = store_picture(profile, result)
      profile.display_name = name if profile.use_name
      profile.assign_attributes(status: picture_state.status, failure_count: 0, fetched_at: @now, next_attempt_at: nil)
      profile.save!
      track(:slack_profile_fetched, picture: profile.picture?)
      track(:slack_profile_failed, reason: "image_rejected") if picture_state.rejected
      Rails.logger.info("SlackProfiles: refreshed user_id=#{@user.id} status=#{profile.status} picture=#{profile.picture?}")
      outcome(:ok)
    rescue TransientPictureError
      fail_with(Client::Result.failure("network_error"))
    end

    PictureState = Data.define(:status, :rejected)
    # Slack's picture host could not be reached or answered with an error: not a verdict on the picture, so try again soon.
    class TransientPictureError < StandardError; end
    TRANSIENT_PICTURE_CODES = %w[network_error download_failed].freeze

    # Downloads and re-encodes the picture when one is wanted. A picture that is refused (not an image, too big, a host that is not
    # Slack's) is dropped and the old one kept; a network problem fetching it is a failure to try again soon.
    def store_picture(profile, result)
      return PictureState.new(status: "ok", rejected: false) unless profile.use_picture

      unless result.image_url
        profile.assign_attributes(picture: nil, picture_sha256: nil, picture_bytes: nil)
        return PictureState.new(status: "no_picture", rejected: false)
      end

      processed = Avatar.call(Download.call(result.image_url))
      profile.assign_attributes(picture: processed.content, picture_sha256: processed.sha256, picture_bytes: processed.byte_size)
      PictureState.new(status: "ok", rejected: false)
    rescue Download::Refused, Avatar::Rejected => error
      raise TransientPictureError if TRANSIENT_PICTURE_CODES.include?(error.message)

      Rails.logger.warn("SlackProfiles: picture not used user_id=#{@user.id} reason=#{error.message.to_s.first(40)}")
      PictureState.new(status: (profile.picture? ? "ok" : "no_picture"), rejected: true)
    end

    def fail_with(result)
      code = result.error_code.to_s
      if code == "ratelimited"
        seconds = result.retry_after || Client::DEFAULT_RETRY_AFTER
        Gate.block!(seconds, now: @now)
        record_failure("ratelimited", @now + seconds, count: false)
        return outcome(:ratelimited, seconds + 1)
      end
      return setup_problem(code) if SCOPE_CODES.include?(code) || AUTH_CODES.include?(code) || code == "no_token"
      return not_found if NOT_FOUND_CODES.include?(code)

      count = @profile.failure_count + 1
      delay = BACKOFF[[ count - 1, BACKOFF.size - 1 ].min]
      record_failure("error", @now + delay, count: true)
      outcome(:error, (delay if count <= 2))
    end

    def not_found
      record_failure("not_found", @now + 24.hours, count: false)
      outcome(:not_found)
    end

    def setup_problem(code)
      status = SCOPE_CODES.include?(code) ? "missing_scope" : (code == "no_token" ? "no_token" : "invalid_auth")
      Gate.block!(SETUP_BLOCK, now: @now)
      record_failure(status, @now + SETUP_RETRY, count: false)
      hint = status == "missing_scope" ? "the Slack app needs the users:read bot scope: add it and reinstall the app (runbooks/slack-app.md)" : "check SLACK_BOT_TOKEN (bin/rails slack:check)"
      Rails.logger.error("SlackProfiles: Slack refused the profile lookup (#{code}); #{hint}. Players keep their generated avatars.")
      outcome(status.to_sym)
    end

    def record_failure(status, retry_at, count:)
      attrs = { status: status, next_attempt_at: retry_at, updated_at: @now }
      attrs[:failure_count] = @profile.failure_count + 1 if count
      @profile.update_columns(attrs)
      track(:slack_profile_failed, reason: status)
      true
    end

    def track(name, **props)
      Analytics.track(name, user: @user, **props)
    end
  end
end
