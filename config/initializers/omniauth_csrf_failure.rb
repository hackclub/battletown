# omniauth-rails_csrf_protection checks the form token of the sign-in POST (/auth/hack_club, /auth/hackatime, ...) and raises
# ActionController::InvalidAuthenticityToken. OmniAuth only rescues its own OmniAuth::AuthenticityError, so a stale token (a
# page left open overnight, a session cookie that was cleared) escaped as an exception and ended on the bare 422 page.
# Translate it, so OmniAuth routes it like any other failure to /auth/failure?message=authenticity_error, where
# SessionsController#failure says "That sign-in link expired" instead of the generic message.
class FriendlyCsrfVerifier
  def initialize(inner)
    @inner = inner
  end

  def call(env)
    @inner.call(env)
  rescue ActionController::InvalidAuthenticityToken => e
    raise OmniAuth::AuthenticityError, e.message
  end
end

# After the gem's own initializer has installed its verifier (and in the order it did), wrap it once.
Rails.application.config.after_initialize do
  current = OmniAuth.config.request_validation_phase
  OmniAuth.config.request_validation_phase = FriendlyCsrfVerifier.new(current) if current && !current.is_a?(FriendlyCsrfVerifier)
end
