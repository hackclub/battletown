module Analytics
  # A ceiling on the visits one address can start (plans/analytics.md, section 1.5). Nothing is ever pruned, so a script that sends a browser user
  # agent and no cookie would otherwise add a permanent visit (and a landing event) per request, as fast as the general throttle lets it.
  # Past the ceiling a cookieless request simply starts no visit and records nothing; people who are signed in are never counted.
  #
  # The count lives in Rack::Attack's cache for ten minutes (the same short-lived store as the request throttles), keyed by a keyed hash of the
  # address, never the address itself. Nothing about it reaches the analytics tables. The ceiling is sized for a classroom behind one address.
  module VisitLimit
    LIMIT = 100
    PERIOD = 10.minutes

    class << self
      def allow?(ip)
        return true if ip.blank?

        Rack::Attack.cache.count("analytics:visits:#{digest(ip)}", PERIOD).to_i <= limit
      end

      def limit = LIMIT

      # Tests only: forget every count.
      def reset! = Rack::Attack.cache.store.clear

      private

      def digest(ip) = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.key_generator.generate_key("analytics visit limit"), ip.to_s)
    end
  end
end
