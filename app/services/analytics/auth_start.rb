module Analytics
  # OmniAuth's before_request_phase hook (config/initializers/omniauth.rb): the moment a sign-up or Hackatime button is pressed, before the
  # redirect to the provider. That is Rack middleware, outside any controller, so it does the same checks a controller event does: nothing for
  # a bot, a prefetch or Do Not Track, and a POST never starts a visit (the visit is the session's, found by its token).
  #
  # signup_started: someone who is not signed in pressed "Sign up with Hack Club". hackatime_connect_started: a signed-in person pressed Connect.
  module AuthStart
    class << self
      def call(env)
        request = ActionDispatch::Request.new(env)
        return if RequestInfo.new(request).ignorable?

        Analytics.safely("auth_start") { track(env["omniauth.strategy"]&.name.to_s, request.session) }
        nil
      end

      private

      def track(strategy, session)
        user = User.find_by(id: session[:user_id]) if session[:user_id]
        visit = -> { Visitor.new(session).current }
        case strategy
        when "hack_club"
          Analytics.track(:signup_started, visit: visit) unless user
        when "hackatime"
          Analytics.track(:hackatime_connect_started, user: user, visit: visit, from: Journey.hackatime_from(user, chained: session[:hackatime_chain])) if user
        end
      end
    end
  end
end
