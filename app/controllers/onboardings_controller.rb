class OnboardingsController < ApplicationController
  # Age, prize, project and schedule are answered before anyone has an account. Signing in with Hack Club is the
  # step after them; account (identity check, how you found us) and celebrate need the signed-in user.
  # The list itself lives in Onboarding::Flow (one ordered list read by this controller, the progress bar and the tests).
  STEPS = Onboarding::Flow::KEYS
  # The screens with a page of their own; every other step renders the generic choice, multi or info page.
  OWN_PAGE = %w[age prize project schedule signup account celebrate].freeze
  # Steps a signed-in user has no need for: the age gate is for visitors, and they are already signed up.
  SKIPPED_WHEN_SIGNED_IN = %w[age signup].freeze
  # Saving these plays a short "N others picked this too" transition over the next step (see OnboardingProof).
  PROOF_AFTER = [].freeze # the "others like you" splashes are off until the new answer screens replace them

  PERMITTED = {
    "age" => [],
    "prize" => [ :prize_key ],
    "project" => %i[project_kind project_idea],
    "schedule" => [ :coding_time, :time_zone, :pace_minutes, { coding_day_names: [], coding_times: User::DAYS } ],
    "account" => [ :referral_source ]
  }.freeze

  REQUIRED = {
    "prize" => %i[prize_key],
    "project" => %i[project_kind],
    "schedule" => %i[coding_time time_zone]
  }.freeze

  helper_method :subject, :answers

  before_action :set_step, only: %i[step update]
  before_action :enforce_progress, only: %i[step update]

  # Sends the user to the furthest step they have unlocked.
  def show
    session[:pledge_moment] = true if signed_in? && !current_user.onboarded? # the way back from Hack Club sign-in lands here: show the signed pledge first
    redirect_to onboarding_step_path(current_user&.onboarded? ? STEPS.fetch(first_index) : STEPS.fetch(unlocked_index))
  end

  def step
    @transition = transition_for_step
    return render "pledge_signed" if @step == "account" && signed_in? && !current_user.onboarded? && session.delete(:pledge_moment)

    OWN_PAGE.include?(@step) ? render(@step) : render("generic")
  end

  def update
    return complete if @step == "celebrate"
    return update_generic unless OWN_PAGE.include?(@step)
    return redirect_to onboarding_step_path(@step) if @step == "signup"
    return answer_age if @step == "age"
    return hackatime_required if @step == "account" && !hackatime_ready?

    if save_step
      Notifications::Scheduler.refresh(current_user) if @step == "schedule" && signed_in?
      redirect_to after_save_path, notice: (current_user&.onboarded? ? "Saved." : nil)
    else
      render @step, status: :unprocessable_content
    end
  end

  private

  # Hackatime is how coding time counts, so the account step is finished only with a working connection. Someone who is
  # already in (editing their plan later) is not stopped by it.
  def hackatime_ready?
    return true if current_user&.onboarded?

    connection = current_user&.hackatime_connection
    connection.present? && !connection.needs_reconnect?
  end

  def hackatime_required
    redirect_to onboarding_step_path("account"), alert: "Connect Hackatime first. It's how your coding time counts."
  end

  # Whoever the answers belong to: the signed-in user, or the session-backed draft of a visitor who hasn't signed in.
  def subject
    @subject ||= current_user || OnboardingDraft.new(session)
  end

  def answers = @answers ||= Onboarding::Answers.new(session, subject)

  def signed_in_flow? = signed_in?

  def set_step
    @step = STEPS.find { |step| step == params[:step] } || (return head :not_found)
    @index = STEPS.index(@step)
  end

  # Order is enforced here, never by the client: a step is only reachable once the previous ones were saved.
  def enforce_progress
    if (@step == "celebrate" || !OWN_PAGE.include?(@step)) && current_user&.onboarded?
      redirect_to dashboard_path
    elsif signed_in? && SKIPPED_WHEN_SIGNED_IN.include?(@step)
      redirect_to onboarding_step_path(STEPS.fetch(current_user.onboarded? ? first_index : unlocked_index))
    elsif !Onboarding::Flow.visible?(Onboarding::Flow.find(@step), answers, signed_in: signed_in?)
      redirect_to onboarding_step_path(Onboarding::Flow.from(@index, answers, signed_in: signed_in?)) # a screen these answers make pointless
    elsif @index > unlocked_index
      redirect_to onboarding_step_path(STEPS.fetch(unlocked_index))
    elsif @step == "celebrate" && signed_in? && !hackatime_ready?
      hackatime_required # a connection that lapsed after the account step was saved counts as missing
    end
  end

  def first_index = Onboarding::Flow.index(Onboarding::Flow.from(0, answers, signed_in: signed_in?))

  # The furthest step reachable: the step the person reached (kept in the session), or, with none (an account saved before the quiz, or a new
  # session), the step the saved phase names (the old column: age, prize, project, schedule, signup, account, celebrate). Past the quiz the saved
  # phase always counts. Moved on past the steps these answers or being signed in make pointless.
  def unlocked_index
    saved = subject.onboarding_step.to_i
    floor = Onboarding::Flow.index(OWN_PAGE.fetch(saved, OWN_PAGE.last))
    floor = 0 if answers.pos && saved == 2 # inside the project phase the session knows better than the column
    reached = answers.pos ? Onboarding::Flow.index(answers.pos).to_i : 0
    reached = [ reached, Onboarding::Flow.index("prize") ].min if subject.prize_key.blank? # a prize that is gone sends them back to pick another
    Onboarding::Flow.index(Onboarding::Flow.from([ floor, reached ].max, answers, signed_in: signed_in?))
  end

  def next_index = Onboarding::Flow.index(Onboarding::Flow.next_key(@step, answers, signed_in: signed_in?))

  # Moves the person's place on to the step after this one: the saved phase (so the old column keeps its meaning) and the session's furthest step.
  def advance
    following = STEPS.fetch(next_index)
    answers.pos = following if next_index > (answers.pos ? Onboarding::Flow.index(answers.pos).to_i : 0)
    subject.onboarding_step = [ subject.onboarding_step.to_i, Onboarding::Flow.phase(following) ].max
  end

  # A step on the generic page: a pick (:choice), several picks (:multi) or a plain Continue (:info). Only values the screen offered are kept.
  def update_generic
    step = Onboarding::Flow.find(@step)
    raw = params[:answer].is_a?(ActionController::Parameters) ? params[:answer] : ActionController::Parameters.new
    allowed = Onboarding::Questions.for(@step, answers)&.options&.map { |option| option[:value] } || []
    case step.kind
    when :choice
      value = raw[:value].to_s
      return render("generic", status: :unprocessable_content) unless allowed.include?(value)

      answers[@step] = value
    when :multi
      values = Array(raw[:values]).map(&:to_s) & allowed
      values = %w[none] if values.include?("none")
      return render("generic", status: :unprocessable_content) if values.empty?

      answers[@step] = values
    end
    advance
    subject.save
    redirect_to onboarding_step_path(STEPS.fetch(next_index))
  end

  def step_params
    # A scalar `user=...` param would otherwise raise NoMethodError (500) on permit.
    raw = params[:user]
    attrs = (raw.is_a?(ActionController::Parameters) ? raw : ActionController::Parameters.new).permit(*PERMITTED.fetch(@step))
    attrs[:referral_source] = attrs[:referral_source].presence if attrs.key?(:referral_source)
    attrs[:project_idea] = attrs[:project_idea].to_s.strip if attrs.key?(:project_idea)
    attrs.delete(:referral_source) if subject.try(:referral_source_in_database).present?
    attrs
  end

  # Self-attested and deliberately simple: a teen carries on, anyone else gets a kind explanation and no progress.
  # Nothing here is checked against an ID: the Hack Club Auth verification status is stored at sign-in and only gates
  # spending (the shop and merch claims), not signing up or shipping.
  def answer_age
    raw = params[:user] # a scalar `user=...` is just a wrong answer, not an error
    if raw.is_a?(ActionController::Parameters) && raw[:age_group] == "teen" && subject.valid?
      advance
      subject.save
      redirect_to onboarding_step_path(STEPS.fetch(next_index))
    else
      # Turbo only shows a form response that is a redirect or an error status, so this is a 422 like the other steps.
      render :ineligible, status: :unprocessable_content
    end
  end

  def save_step
    user = subject
    user.assign_attributes(step_attributes)
    user.valid?
    REQUIRED.fetch(@step, []).each { |attribute| user.errors.add(attribute, :blank) if user[attribute].blank? }
    user.errors.add(:coding_days, :blank) if @step == "schedule" && user.coding_days.zero? # worded by OnboardingsHelper
    user.errors.add(:pace_minutes, :inclusion) if @step == "schedule" && pace_not_a_whole_number?(user) && !user.errors.of_kind?(:pace_minutes, :inclusion)
    user.errors.add(:referral_source, :inclusion) if user.referral_source && !ReferralSource.find(user.referral_source)
    return false if user.errors.any?

    advance
    # The project step also creates or updates a signed-in user's first project (the old user columns stay populated);
    # a visitor's project is created when they sign up.
    saved = false
    User.transaction do
      saved = user.save && (@step != "project" || !signed_in? || Project.sync_first_from_onboarding(user))
      raise ActiveRecord::Rollback unless saved
    end
    user.errors.add(:project_idea, :not_saved, message: "We couldn't save your project just now. Please try again.") if !saved && user.errors.empty?
    saved
  end

  # The schedule step sends the browser's own time zone (an IANA name such as America/New_York) and never asks. It is mapped to the zone
  # name the app stores, checked against the known list, and never trusted raw: missing or unknown falls back to the zone already saved, else UTC.
  def step_attributes
    attributes = step_params
    return attributes unless @step == "schedule" && attributes.key?(:time_zone)

    attributes.merge(time_zone: stored_time_zone_name(attributes[:time_zone]))
  end

  IANA_LOOKING = %r{\A[A-Za-z_]+(/[A-Za-z0-9_+-]+)+\z}

  def stored_time_zone_name(raw)
    raw = raw.to_s.strip
    zones = ActiveSupport::TimeZone.all
    return raw if zones.any? { |zone| zone.name == raw } # a zone name from the settings-style picker
    return "UTC" if %w[UTC Etc/UTC GMT Etc/GMT].include?(raw)
    return zones.find { |zone| zone.tzinfo.name == raw }.name if zones.any? { |zone| zone.tzinfo.name == raw }
    return raw unless raw.blank? || raw.match?(IANA_LOOKING) # not a zone name at all: let validation refuse it

    subject.time_zone.presence || "UTC"
  end

  # An integer column quietly turns "15.5" into 15 and "15abc" into 15; only a plain whole number is an answer.
  def pace_not_a_whole_number?(user)
    raw = user.pace_minutes_before_type_cast
    raw.is_a?(String) && raw.present? && !raw.match?(/\A\d+\z/)
  end

  def after_save_path
    return dashboard_path if current_user&.onboarded?

    # The transition plays once, on the page that loads next (it is read and cleared there, so reloading or going back
    # never replays it).
    session[:onboarding_transition] = @step if PROOF_AFTER.include?(@step)
    onboarding_step_path(STEPS.fetch(next_index))
  end

  # Which transition plays over this step, if any: the one for the step just saved ("prize" or "project"), else the
  # welcome splash on a visitor's first look at the first step. Once per visit for the splash.
  def transition_for_step
    saved = session.delete(:onboarding_transition)
    return saved if PROOF_AFTER.include?(saved) && STEPS[STEPS.index(saved) + 1] == @step && !current_user&.onboarded?

    return unless @step == STEPS.first && !signed_in? && !session[:onboarding_intro_seen]

    session[:onboarding_intro_seen] = true
    "welcome"
  end

  # Idempotent: the lock makes a double submit set onboarded_at only once.
  def complete
    return redirect_to onboarding_step_path(STEPS.fetch(unlocked_index)) unless signed_in?
    return hackatime_required unless hackatime_ready?

    current_user.with_lock { current_user.update!(onboarded_at: Time.current) unless current_user.onboarded? }
    Notifications::Scheduler.refresh(current_user)
    redirect_to dashboard_path
  end
end
