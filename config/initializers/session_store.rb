# Encrypted cookie sessions. expire_after is refreshed on each request, so it acts as an idle timeout.
Rails.application.config.session_store :cookie_store,
  key: "_battletown_session",
  expire_after: 30.days,
  httponly: true,
  same_site: :lax,
  secure: Rails.env.production?
