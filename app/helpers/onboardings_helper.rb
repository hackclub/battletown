module OnboardingsHelper
  STEP_COPY = {
    "age" => { label: "Age", title: "How old are you?", encouragement: "Battletown is only for teens aged 13–18, and is run by Hack Club, a nonprofit for teens, by teens.", progress: "onboarding progress (this will be quick, we promise)" },
    "prize" => { label: "Prize", title: "Pick your prize", encouragement: "Every hour you code gets you closer. Choose what you're working toward.", progress: "onboarding progress (the fun part: picking a prize)" },
    "project" => { label: "Project", title: "What are you making?", encouragement: "Nothing here is binding. You can change your mind later.", progress: "onboarding progress (nearly halfway there)" },
    "schedule" => { label: "Schedule", title: "When do you want to code?", encouragement: "Small, regular sessions beat big, rare ones. We'll nudge you on Slack.", progress: "onboarding progress (past halfway now)" },
    "signup" => { label: "Sign up", title: "Lock in your plan", encouragement: "One quick sign-in with Hack Club and you're on the board. Your picks come with you.", progress: "onboarding progress (one quick sign in to go)" },
    "account" => { label: "Account", title: "Connect Hackatime", encouragement: "One last thing: Hackatime counts your coding time, so your hours show up on their own.", progress: "onboarding progress (almost done)" },
    "celebrate" => { label: "Go!", title: "You're in!", encouragement: "The town is better with you in it.", progress: "onboarding progress (done, you made it!)" }
  }.freeze

  PROJECT_KINDS = {
    "game" => { name: "Game", emoji: "🎮" },
    "website" => { name: "Website", emoji: "🌐" },
    "app" => { name: "App", emoji: "📱" },
    "tool" => { name: "Tool or bot", emoji: "🛠️" },
    "hardware" => { name: "Hardware", emoji: "🔌" }, # not supported (User::OFFERED_PROJECT_KINDS): kept so saved ones show a name
    "undecided" => { name: "Not sure yet", emoji: "🤔" }
  }.freeze

  HACKATIME_SETUP_URL = "https://hackatime.hackclub.com/setup".freeze
  HACKATIME_EDITOR_GUIDES_URL = "https://hackatime.hackclub.com/docs#editor-guides".freeze
  # The editors Hackatime's own docs give steps for (https://hackatime.hackclub.com/docs/editors/<slug>, read 2026-11-27). Every one
  # starts with the setup page; `steps` are what the docs say to do in the editor after it, `code` is text to copy exactly as the
  # docs print it. Anything else gets the "other" path: the docs' list of every editor guide.
  HACKATIME_EDITORS = [
    { key: "vscode", name: "VS Code", url: "https://hackatime.hackclub.com/docs/editors/vs-code",
      steps: [ "Open Extensions, search for Hackatime Time Tracker and install it. Do not install the extension called only Hackatime: it is unofficial.", "Restart VS Code and start coding." ] },
    { key: "cursor", name: "Cursor", url: "https://hackatime.hackclub.com/docs/editors/cursor",
      steps: [ "Open Extensions, search for WakaTime and install it.", "Reload Cursor if it asks." ] },
    { key: "jetbrains", name: "JetBrains IDEs", url: "https://hackatime.hackclub.com/docs/editors/intellij-idea",
      steps: [ "Open Settings, then Plugins, then Marketplace. Search for WakaTime and install it.", "Accept the third-party notice, then restart the IDE." ] },
    { key: "neovim", name: "Neovim", url: "https://hackatime.hackclub.com/docs/editors/neovim",
      steps: [ "With lazy.nvim, add this plugin line (keep lazy = false):", "Restart Neovim. To check, run :WakaTimeToday." ], code: '{ "wakatime/vim-wakatime", lazy = false },' },
    { key: "vim", name: "Vim", url: "https://hackatime.hackclub.com/docs/editors/vim",
      steps: [ "Add this line to your .vimrc:", "Restart Vim, then run :PlugInstall." ], code: "Plug 'wakatime/vim-wakatime'" },
    { key: "sublime", name: "Sublime Text", url: "https://hackatime.hackclub.com/docs/editors/sublime-text",
      steps: [ "Install Package Control if you do not have it (command palette, then Install Package Control).", "In the command palette choose Package Control: Install Package, then pick wakatime." ] },
    { key: "zed", name: "Zed", url: "https://hackatime.hackclub.com/docs/editors/zed",
      steps: [ "Open Extensions, search for hackatime and install it.", "If Zed asks, choose Trust and Continue for your project." ] },
    { key: "xcode", name: "Xcode", url: "https://hackatime.hackclub.com/docs/editors/xcode",
      steps: [ "Run this in a terminal:", "Open System Settings, then Privacy and Security, then Accessibility, and turn on xcode-hackatime." ], code: "curl -fsSL https://raw.githubusercontent.com/hackclub/xcode-hackatime/main/install.sh | bash" }
  ].freeze

  IDEA_PRESETS = [
    "A small platformer with one great mechanic",
    "A Slack bot that makes my friends' lives easier",
    "A personal site that shows off what I've built",
    "A tool that automates a chore I do every day",
    "A multiplayer game I can play with friends"
  ].freeze

  # Names people see for the attributes that can fail (attribute names are column names such as prize_key).
  ERROR_LABELS = {
    prize_key: "Prize", project_kind: "Project type", project_idea: "Project idea", coding_time: "Time",
    coding_times: "Times for some days", coding_days: "Days", time_zone: "Time zone", pace_minutes: "Daily pace", referral_source: "How you found us"
  }.freeze

  # The id of the control an error should jump to (the first radio or day pill for the grouped fields).
  ERROR_ANCHORS = {
    project_kind: "user_project_kind_game", project_idea: "user_project_idea", coding_time: "user_coding_time",
    coding_times: "day-times-hint", coding_days: "user_day_monday", time_zone: "user_time_zone", pace_minutes: "user_pace_minutes", referral_source: "user_referral_source"
  }.freeze

  # What to tell people for each kind of failure, as a short instruction (never "can't be blank"). Keyed by attribute and
  # error type; a model's own message is only the fallback. :custom is an error the model added as plain text.
  ERROR_MESSAGES = {
    prize_key: { blank: "Pick a prize to continue", inclusion: "Pick a prize from the list", custom: "Pick another prize. That one isn't in the shop any more." },
    project_kind: { blank: "Pick a kind of project", inclusion: "Pick a kind of project from the list", custom: "Pick another kind of project. That one isn't offered any more." },
    project_idea: { too_long: "Shorten your idea to %{count} characters or fewer" },
    coding_days: { blank: "Pick at least one day" },
    coding_time: { blank: "Choose a time to code", invalid: "Use a time like 5:30 pm" },
    time_zone: { blank: "Choose your time zone", inclusion: "Choose your time zone from the list" },
    pace_minutes: { inclusion: "Pick a pace from the list" },
    referral_source: { inclusion: "Pick one of the options in the list", invalid: "Pick one of the options in the list" }
  }.freeze

  def onboarding_copy(step) = STEP_COPY.fetch(step)

  # Inline SVG icons for the onboarding, drawn on a 24-unit box with the shape centered in it, so a grid or flex box centers them exactly.
  def onboarding_arrow
    tag.svg(tag.path(d: "M5 12h14M13 6l6 6-6 6"), class: "btn__arrow", viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": 3, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": true, focusable: false)
  end

  # A button label with the arrow after it.
  def onboarding_label(text) = safe_join([ text, onboarding_arrow ])

  # The pick badge of a chosen card: a yellow circle with a navy check, shown only on the checked card (see onboarding_world.css).
  def onboarding_check
    tag.svg(tag.circle(cx: 12, cy: 12, r: 12) + tag.path(d: "M7 12.5l3.5 3.5 6.5-7.5"), class: "choice__check", viewBox: "0 0 24 24", "aria-hidden": true, focusable: false)
  end

  PROJECT_PHRASES = {
    "game" => "a game", "website" => "a website", "app" => "an app", "tool" => "a tool or bot",
    "undecided" => "something, and aren't sure what yet"
  }.freeze

  # The project kinds a person can pick now.
  def offered_project_kinds = PROJECT_KINDS.select { |kind, _| User::OFFERED_PROJECT_KINDS.include?(kind) }

  # This week's boss for someone who may not have an account yet, as the same presenter the dashboard uses, built from the
  # community totals only (no user is read). Nil-safe: with no boss standing it has state :none.
  def onboarding_boss
    @onboarding_boss ||= begin
      today = Hours::Days.today("UTC")
      boss = Boss.without_art_content.covering(today).first
      boss ||= Boss.without_art_content.where(ends_on: (today - Bosses::Config.current.afterglow_days)...today).order(ends_on: :desc).first
      facts = Bosses::Presenter::Facts.new(today: today, boss: boss, damage: (boss ? Bosses::Damage.for(boss) : 0), user_seconds: 0, active_today: 0,
                                           upcoming_on: (boss ? nil : Boss.where(starts_on: (today + 1)..).minimum(:starts_on)), previous_escaped_name: nil)
      Bosses::Presenter.new(facts: facts)
    end
  end

  # The "N others picked this too" transition after the prize and project steps: { headline:, body:, prize:, emoji: }. Only totals
  # are shown (OnboardingProof); a small number is never quoted, it becomes "be one of the first" instead.
  def onboarding_proof(step)
    others = ->(count, mine) { [ count - (signed_in? && mine ? 1 : 0), 0 ].max }
    enough = ->(count) { count >= OnboardingProof::MIN_OTHERS }
    joined = fighter_count >= LandingHelper::FIGHTER_COUNT_THRESHOLD ? "#{number_with_delimiter(fighter_count)} fighters have already joined Battletown." : "Be one of the first fighters in Battletown."

    if step == "prize"
      prize = onboarding_saved_prize
      count = others.call(OnboardingProof.prize_count(prize.key), subject.prize_key_in_database == prize.key)
      headline = enough.call(count) ? "#{number_with_delimiter(count)} other fighters are working toward the #{prize.name} too!" : "Great pick! Hardly anyone has chosen the #{prize.name} yet."
      { headline: headline, body: joined, prize: prize }
    else
      kind = subject.project_kind_in_database
      phrase = PROJECT_PHRASES.fetch(kind)
      count = others.call(OnboardingProof.project_kind_count(kind), true)
      headline = if !enough.call(count) then (kind == "undecided" ? "Not sure yet? That's a fine way to start." : "You'll be one of the first to build #{phrase} here!")
      elsif kind == "undecided" then "#{number_with_delimiter(count)} other teens aren't sure what to build yet either, and that's fine!"
      else "#{number_with_delimiter(count)} other teens are building #{phrase} too!"
      end
      { headline: headline, body: "Nothing is locked in. You can change your project any time.", emoji: PROJECT_KINDS.dig(kind, :emoji) }
    end
  end

  # Error lines like "Pick a prize to continue", each saying what to do (see ERROR_MESSAGES). An empty field also trips
  # the format/inclusion validations, so when a field is blank the "blank" line alone is enough. Pass an attribute to
  # get only that field's messages.
  def onboarding_errors(attribute = nil)
    list = subject.errors.group_by(&:attribute).flat_map { |_, errors| errors.any? { |e| e.type == :blank } ? errors.select { |e| e.type == :blank } : errors }
    list = list.select { |error| error.attribute == attribute } if attribute
    list.map { |error| [ error.attribute, onboarding_error_message(error) ] }
  end

  # One error as an instruction. A message set on purpose (the :message option) is used as written; a model's own
  # wording with no entry here still reads as "Label message".
  def onboarding_error_message(error)
    return error.message if error.options[:message].is_a?(String)
    return onboarding_coding_times_message if error.attribute == :coding_times

    type = error.type.is_a?(Symbol) ? error.type : :custom
    text = ERROR_MESSAGES.dig(error.attribute, type)
    return format(text, count: error.options[:count]) if text

    "#{ERROR_LABELS.fetch(error.attribute, error.attribute.to_s.humanize)} #{error.message}"
  end

  # Names the day when only one is wrong ("Check Monday's time: use something like 5:30 pm").
  def onboarding_coding_times_message
    days = subject.coding_times.reject { |_, time| time.is_a?(String) && time.match?(User::TIME_FORMAT) }.keys
    names = days.map { |day| day_label(day) }
    case names.size
    when 0 then "Use a time like 5:30 pm"
    when 1 then "Check #{names.first}'s time: use something like 5:30 pm"
    else "Check the times for #{names.to_sentence}: use something like 5:30 pm"
    end
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
  def onboarding_saved_prize = Prize.find(subject.prize_key_in_database)

  def onboarding_prize_selection
    picked = subject.prize_key || session[:prize_key]
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

  # The pace question's choices, in minutes a coding day (all are in User::PACES).
  ONBOARDING_PACES = [ 30, 60, 120, 180 ].freeze
  # What the days and time are before the person has chosen any: every day at 6 pm. The pace step does not ask for them
  # but the schedule still needs them (see OnboardingsController REQUIRED), so they are sent with the answer.
  DEFAULT_CODING_TIME = "18:00".freeze

  # Whole coding days the prize takes at `minutes` a day, from the shop price and the base coins-per-hour rate (no bonus).
  # The same sum the dashboard's pace line makes for a new person on a seven-day plan (Dashboard::PrizePace).
  def onboarding_days_to_prize(prize, minutes)
    return unless prize && prize.coins.to_i.positive?

    seconds = Rational(prize.coins * 3600, Game::Config.current.coins_per_hour)
    [ (seconds / (minutes * 60)).ceil, 1 ].max
  end

  # "About 14 days to your 8BitDo Pro 2" for a prize at a pace; nil when there is no paid prize to count toward.
  def onboarding_days_text(prize, minutes)
    days = onboarding_days_to_prize(prize, minutes)
    safe_join([ "About #{pluralize(days, 'day')} to your ", tag.span(prize.name, class: "nowrap") ]) if days
  end

  # "1 hour 30 minutes" for a daily pace given in minutes (the select's option text).
  def pace_text(minutes)
    hours, rest = minutes.divmod(60)
    [ (pluralize(hours, "hour") if hours.positive?), (pluralize(rest, "minute") if rest.positive?) ].compact.join(" ")
  end

  def pace_options = User::PACES.map { |minutes| [ pace_text(minutes), minutes ] }

  # "18:30" as "6:30 pm" (the stored value stays 24-hour HH:MM).
  def coding_time_text(time)
    Time.strptime(time.to_s, "%H:%M").strftime("%-l:%M %P")
  rescue ArgumentError
    time.to_s
  end

  # "Every day" for all seven, otherwise "Monday, Wednesday, and Friday".
  def coding_days_text(user)
    return "Every day" if user.coding_days == 127

    user.coding_day_names.map { |day| day_label(day) }.to_sentence
  end

  # The whole plan in one phrase. One time for every day reads as before ("Every day at 6:30 pm", "Monday and Friday at
  # 6:30 pm"); with different times per day the days are grouped by time, in week order, with short names:
  # "Mon at 5:00 pm, Tue and Thu at 6:30 pm, Sun at 6:00 pm".
  def coding_schedule_text(user)
    groups = user.coding_day_names.group_by { |day| user.coding_time_for(day) }
    return "#{coding_days_text(user)} at #{coding_time_text(groups.keys.first)}" if groups.size == 1 && groups.keys.first

    groups.map do |time, days|
      names = days.map { |day| day_label(day).first(3) }.to_sentence(two_words_connector: " and ", last_word_connector: " and ")
      time ? "#{names} at #{coding_time_text(time)}" : names
    end.join(", ")
  end

  # The user's current zone as an ActiveSupport::TimeZone, or nil when unset or not a valid zone name.
  def onboarding_time_zone
    ActiveSupport::TimeZone[subject.time_zone] if subject.time_zone.present?
  end

  def time_zone_options
    ActiveSupport::TimeZone.all.map { |zone| [ zone.to_s, zone.name, { data: { iana: zone.tzinfo.name } } ] }
  end
end
