module SlackProfiles
  # The player's choice "Use my Slack name and picture" (Settings, Profile). Both parts are ON until the player turns them off (no row
  # means on). It only controls what other players are shown: every player has a profile either way. Changing it:
  #
  #   turn off          the stored Slack name and picture are deleted at once (the generated avatar and name come back); nothing more is
  #                     fetched. A display name the player typed stays.
  #   turn on           the next fetch is due now, so the name and picture come within moments.
  #
  # A display name the player typed (Settings) always wins over the Slack name (PublicProfile.name_for); the choice only decides
  # whether the Slack name is used when they typed none, and whether the Slack picture is used.
  module Choice
    module_function

    def use_slack?(user)
      profile = SlackProfile.for(user)
      SlackProfiles.use_name?(profile) || SlackProfiles.use_picture?(profile)
    end

    def set(user, use_slack:)
      profile = SlackProfile.find_or_create_by!(user_id: user.id)
      profile.update!(use_name: use_slack, use_picture: use_slack)
      use_slack ? due_now(profile) : wipe(profile)
    end

    def due_now(profile)
      profile.update!(fetched_at: nil, next_attempt_at: nil, failure_count: 0, status: "pending")
    end

    def wipe(profile)
      profile.update!(display_name: nil, picture: nil, picture_sha256: nil, picture_bytes: nil, fetched_at: nil, next_attempt_at: nil,
                      failure_count: 0, status: "pending")
    end
    private_class_method :due_now, :wipe
  end
end
