# The page asks Hack Club Auth, from the browser, whether the visitor has a Hack Club session (app/javascript/controllers/whoami_client.js).
# Nothing it learns reaches this server: the answer only changes wording on the page, and who the person is is decided by the real sign-in.
module WhoamiHelper
  # Stand-in wording (Armand writes the final copy). The default labels stay in the markup; this replaces them only after Auth answers.
  WHOAMI_LOGIN_LABEL = "Log in with Hack Club".freeze
  # The page is left alone when the answer takes longer than this, so nothing jumps late.
  WHOAMI_SWAP_WITHIN_MS = 1500

  def whoami_enabled? = Rails.configuration.x.hca.whoami_enabled.present?

  # data attributes for an element that listens to whoami: {} (so no controller at all) while the switch is off.
  def whoami_data(identifier, action: nil, **values)
    return {} unless whoami_enabled?

    key = identifier.tr("-", "_")
    data = { controller: identifier, "#{key}_url_value": Rails.configuration.x.hca.whoami_url }
    values.each { |name, value| data[:"#{key}_#{name}_value"] = value }
    data[:action] = action if action
    data
  end

  # The landing page's two sign-up buttons: only a visitor with no BattleTown session can be shown the log-in wording.
  def whoami_login_data
    return {} if signed_in?

    whoami_data("whoami-login", label: WHOAMI_LOGIN_LABEL, form: "whoami-login-form", within: WHOAMI_SWAP_WITHIN_MS,
                action: "click->whoami-login#go")
  end
end
