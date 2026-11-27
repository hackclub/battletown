# Walks the generic quiz screens of the onboarding (Onboarding::Flow) in an integration test: every question is answered with its first option
# (a multi with its first), every info screen just continues, until the next screen is `target` or one with a page of its own (age, prize, project,
# schedule, signup, account, celebrate). The tests of those pages use it to get there without repeating the quiz.
module OnboardingQuiz
  def current_quiz_step
    get onboarding_path
    URI(response.location).path.split("/").last if response.redirect?
  end

  def walk_quiz_to(target = nil)
    following = nil
    40.times do
      key = following || current_quiz_step # a screen can sit before the furthest one reached (the halfway screen), so follow each answer's own redirect
      following = nil
      return key if key.nil? || key == target || OnboardingsController::OWN_PAGE.include?(key)

      get onboarding_step_path(key)
      input = css_select("input.choice__input").first
      params = input ? { input["name"].delete_suffix("[]").then { |name| name.sub(/\A(\w+)\[(\w+)\]\z/, '\1[\2]') } => (input["name"].end_with?("[]") ? [ input["value"] ] : input["value"]) } : {}
      patch onboarding_step_path(key), params: Rack::Utils.parse_nested_query(params.map { |k, v| Array(v).map { |x| "#{k}#{'[]' if v.is_a?(Array)}=#{Rack::Utils.escape(x)}" } }.flatten.join("&"))
      raise "the quiz stuck on #{key}: #{response.status}" if response.status >= 400

      following = URI(response.location).path.split("/").last if response.redirect?
    end
    raise "the quiz did not end"
  end

  # Like walk_quiz_to, but also answers the project kind and the pace (the two quiz questions that have a page of their own) on the way.
  def reach_quiz_step(target, project_kind: "game", pace: 60)
    10.times do
      key = walk_quiz_to(target)
      return key if key == target

      case key
      when "project" then patch onboarding_step_path("project"), params: { user: { project_kind: project_kind } }
      when "schedule" then patch onboarding_step_path("schedule"), params: { user: { coding_day_names: %w[monday], coding_time: "18:00", time_zone: "UTC", pace_minutes: pace } }
      else return key
      end
    end
  end
end
