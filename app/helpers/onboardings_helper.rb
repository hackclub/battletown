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

  def onboarding_copy(step) = STEP_COPY.fetch(step)

  # The saved prize, so a rejected form submission can't change what the header shows.
  def onboarding_saved_prize = Prize.find(current_user.prize_key_in_database)

  def onboarding_prize_selection
    current_user.prize_key || (session[:prize_key] if Prize.find(session[:prize_key]))
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

  def time_zone_options
    ActiveSupport::TimeZone.all.map { |zone| [ zone.to_s, zone.name, { data: { iana: zone.tzinfo.name } } ] }
  end
end
