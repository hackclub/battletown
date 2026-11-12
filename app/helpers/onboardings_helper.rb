module OnboardingsHelper
  STEP_COPY = {
    "prize" => { label: "Prize", title: "Pick your prize", encouragement: "Every hour you code gets you closer. Choose what you're working toward." },
    "project" => { label: "Project", title: "What are you making?", encouragement: "Nothing here is binding. You can change your mind later." },
    "schedule" => { label: "Schedule", title: "When do you want to code?", encouragement: "Small, regular sessions beat big, rare ones. We'll nudge you on Slack." },
    "account" => { label: "Account", title: "Quick account check", encouragement: "Nearly there. Nothing here blocks you from starting." },
    "celebrate" => { label: "Go!", title: "You're in!", encouragement: "The town is better with you in it." }
  }.freeze

  PROJECT_KINDS = {
    "game" => { name: "Game", emoji: "🎮" },
    "website" => { name: "Website", emoji: "🌐" },
    "app" => { name: "App", emoji: "📱" },
    "tool" => { name: "Tool or bot", emoji: "🛠️" },
    "hardware" => { name: "Hardware", emoji: "🔌" },
    "undecided" => { name: "Not sure yet", emoji: "🤔" }
  }.freeze

  IDEA_PRESETS = [
    "A small platformer with one great mechanic",
    "A Slack bot that makes my friends' lives easier",
    "A personal site that shows off what I've built",
    "A tool that automates something annoying I do every day",
    "A multiplayer game I can play with friends"
  ].freeze

  VERIFICATION_COPY = {
    "verified" => "You're verified. You're all set to ship.",
    "pending" => "Your verification is being reviewed. You can keep going in the meantime.",
    "needs_submission" => "You haven't verified your identity yet. You can start without it, but you'll need to before you ship.",
    "ineligible" => "Your Hack Club account isn't eligible for this program right now. Reach out in Slack if you think that's a mistake."
  }.freeze

  # Names people see for the attributes that can fail (attribute names are column names such as prize_key).
  ERROR_LABELS = {
    prize_key: "Prize", project_kind: "Project type", project_idea: "Project idea", coding_time: "Time",
    coding_days: "Days", time_zone: "Time zone", referral_source: "How you found us"
  }.freeze

  # The id of the control an error should jump to (the first radio or day pill for the grouped fields).
  ERROR_ANCHORS = {
    project_kind: "user_project_kind_game", project_idea: "user_project_idea", coding_time: "user_coding_time",
    coding_days: "user_day_monday", time_zone: "user_time_zone", referral_source: "user_referral_source"
  }.freeze

  # The status pill beside the identity verification copy (the pill says it in words; colour is only a hint).
  VERIFICATION_BADGES = {
    "verified" => { label: "Verified", tone: "success" },
    "pending" => { label: "In review", tone: "info" },
    "needs_submission" => { label: "Not verified yet", tone: "warning" },
    "ineligible" => { label: "Not eligible", tone: "danger" }
  }.freeze

  def onboarding_copy(step) = STEP_COPY.fetch(step)

  # Error sentences like "Prize can't be blank". An empty field also trips the format/inclusion validations, so when
  # a field is blank "can't be blank" alone is enough. Pass an attribute to get only that field's messages.
  def onboarding_errors(attribute = nil)
    list = current_user.errors.group_by(&:attribute).flat_map { |_, errors| errors.any? { |e| e.type == :blank } ? errors.select { |e| e.type == :blank } : errors }
    list = list.select { |error| error.attribute == attribute } if attribute
    list.map { |error| [ error.attribute, "#{ERROR_LABELS.fetch(error.attribute, error.attribute.to_s.humanize)} #{error.message}" ] }
  end

  def onboarding_error_anchor(attribute)
    return "user_prize_key_#{Prize.paid.first&.key}" if attribute == :prize_key

    ERROR_ANCHORS[attribute]
  end

  # The error paragraph under a field (or group of fields); nil when the field is fine. Its id is "#{id}-error".
  def onboarding_field_error(attribute, id:)
    messages = onboarding_errors(attribute).map(&:last)
    return if messages.empty?

    tag.p(safe_join(messages, tag.br), class: "field__error", id: "#{id}-error")
  end

  # aria-invalid and aria-describedby for a control, merged with an optional hint id.
  def onboarding_aria(attribute, id:, hint: nil)
    invalid = onboarding_errors(attribute).any?
    described = [ hint, ("#{id}-error" if invalid) ].compact.join(" ")
    { invalid: (true if invalid), describedby: described.presence }.compact
  end

  # The saved prize, so a rejected form submission can't change what the header shows.
  def onboarding_saved_prize = Prize.find(current_user.prize_key_in_database)

  def onboarding_prize_selection
    picked = current_user.prize_key || session[:prize_key]
    picked if Prize.paid.any? { |prize| prize.key == picked } # an archived item can't be re-picked
  end

  def referral_name(key) = ReferralSource.find(key)&.name

  # Copy for a user whose source is already saved (program links are "came from", survey answers are "you told us").
  def referral_summary(key)
    source = ReferralSource.find(key)
    return "Thanks for joining through a friend." unless source

    Referral.find(key) ? "You came from #{source.name}." : "You told us: #{source.name}."
  end

  # Select options: generic sources, then the Hack Club programs in their own group, "Something else" last.
  def referral_source_options
    pairs = ->(sources) { sources.map { |source| [ source.name, source.key ] } }
    selected = current_user.referral_source
    safe_join([
      options_for_select(pairs.call(ReferralSource.generic), selected),
      content_tag(:optgroup, options_for_select(pairs.call(ReferralSource.programs), selected), label: "Hack Club programs"),
      options_for_select(pairs.call([ ReferralSource.other ]), selected)
    ])
  end

  def day_label(day) = day.capitalize

  # "Every day" for all seven, otherwise "Monday, Wednesday, and Friday".
  def coding_days_text(user)
    return "Every day" if user.coding_days == 127

    user.coding_day_names.map { |day| day_label(day) }.to_sentence
  end

  # The user's current zone as an ActiveSupport::TimeZone, or nil when unset or not a valid zone name.
  def onboarding_time_zone
    ActiveSupport::TimeZone[current_user.time_zone] if current_user.time_zone.present?
  end

  def time_zone_options
    ActiveSupport::TimeZone.all.map { |zone| [ zone.to_s, zone.name, { data: { iana: zone.tzinfo.name } } ] }
  end
end
