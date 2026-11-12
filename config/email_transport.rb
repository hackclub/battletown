# Where email goes, decided from the environment alone (so config/environments/production.rb can use it before the app
# loads, and nothing here depends on Rails). Loaded from config/application.rb.
#
# A real SMTP transport exists only when SMTP_ADDRESS and MAIL_FROM are both set (and SMTP_USERNAME and SMTP_PASSWORD
# are either both set or both absent). Anything less is "no transport": production then uses a delivery method that
# delivers nothing, and the dispatcher (Notifications::Email::Dispatcher) refuses to run, so no message is ever
# recorded as sent without a real transport. Values are read from the environment only, never from the repository.
module EmailTransport
  DEFAULT_FROM = "Battletown <noreply@example.com>".freeze # a reserved domain: safe to leave in place, delivers nowhere useful
  DEFAULT_PORT = 587

  module_function

  # The From header. MAIL_FROM, or a placeholder on a reserved domain that cannot be mistaken for a real sender.
  def sender(env = ENV)
    from = env["MAIL_FROM"].to_s.strip
    from.empty? ? DEFAULT_FROM : from
  end

  # The Action Mailer smtp_settings hash, or nil when the environment does not describe a complete transport.
  def smtp_settings(env = ENV)
    address = env["SMTP_ADDRESS"].to_s.strip
    return nil if address.empty? || env["MAIL_FROM"].to_s.strip.empty?

    username = env["SMTP_USERNAME"].to_s
    password = env["SMTP_PASSWORD"].to_s
    return nil if username.empty? != password.empty?

    port = Integer(env["SMTP_PORT"].to_s.strip, exception: false) || DEFAULT_PORT
    settings = { address: address, port: port, open_timeout: 10, read_timeout: 20 }
    domain = env["SMTP_DOMAIN"].to_s.strip
    settings[:domain] = domain unless domain.empty?
    settings.merge!(user_name: username, password: password, authentication: :plain) unless username.empty?
    # 465 is implicit TLS; everything else MUST upgrade with STARTTLS (never "when offered": a network attacker could strip
    # the offer and read the credentials and the messages).
    port == 465 ? settings.merge(tls: true) : settings.merge(enable_starttls: :always)
  end

  def configured?(env = ENV) = !smtp_settings(env).nil?
end
