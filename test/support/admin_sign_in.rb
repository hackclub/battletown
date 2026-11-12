require "test_helper"

# Signing in as staff in integration tests (the Hack Club Auth callback is mocked by OmniAuth test mode).
#
#   include AdminSignIn          # in an ActionDispatch::IntegrationTest
#   as_admin(users(:onboarded))  # ADMIN_HCA_UIDS now holds that user's uid and they are signed in
#
# setup/teardown handle OmniAuth and the environment for you.
module AdminSignIn
  extend ActiveSupport::Concern

  included do
    setup do
      OmniAuth.config.test_mode = true
      @original_admin_uids = ENV["ADMIN_HCA_UIDS"]
      @original_detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
      Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    end

    teardown do
      OmniAuth.config.test_mode = false
      OmniAuth.config.mock_auth[:hack_club] = nil
      Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @original_detailed
      @original_admin_uids.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admin_uids
    end
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def as_admin(user = users(:onboarded))
    ENV["ADMIN_HCA_UIDS"] = user.hca_uid
    sign_in_as user
    user
  end
end
