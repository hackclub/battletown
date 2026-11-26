class OnboardingsController < ApplicationController
  # Age, prize, project and schedule are answered before anyone has an account. Signing in with Hack Club is the
  # step after them; account (identity check, how you found us) and celebrate need the signed-in user.
  STEPS = %w[age prize project schedule signup account celebrate].freeze
  # Steps a signed-in user has no need for: the age gate is for visitors, and they are already signed up.
  SKIPPED_WHEN_SIGNED_IN = %w[age signup].freeze
  # Saving these plays a short "N others picked this too" transition over the next step (see OnboardingProof).
  PROOF_AFTER = %w[prize project].freeze

  PERMITTED = {
    "age" => [],
    "prize" => [ :prize_key ],
    "project" => %i[project_kind project_idea],
    "schedule" => [ :coding_time, :time_zone, :pace_minutes, { coding_day_names: [], coding_times: User::DAYS } ],
    "account" => %i[referral_source]
  }.freeze

  REQUIRED = {
    "prize" => %i[prize_key],
    "project" => %i[project_kind],
    "schedule" => %i[coding_time time_zone]
  }.freeze

  helper_method :subject, :hackatime_required?

  before_action :set_step, only: %i[step update]
  before_action :enforce_progress, only: %i[step update]

  # Sends the user to the furthest step they have unlocked.
  def show
    redirect_to onboarding_step_path(current_user&.onboarded? ? STEPS.fetch(first_index) : STEPS.fetch(unlocked_index))
  end

  def step
    @transition = transition_for_step
    track_event(:onboarding_step_viewed, step: @step) unless current_user&.onboarded?
    render @step
  end

  def update
    return complete if @step == "celebrate"
    return redirect_to onboarding_step_path(@step) if @step == "signup"
    return answer_age if @step == "age"
    return hackatime_required if @step == "account" && !hackatime_ready?

    if save_step
      track_step_saved
      Notifications::Scheduler.refresh(current_user) if @step == "schedule" && signed_in?
      redirect_to after_save_path, notice: (current_user&.onboarded? ? "Saved." : nil)
    else
      render @step, status: :unprocessable_content
    end
  end

  private

  # Hackatime is how coding time counts, so the account step is finished only with a working connection. Someone who is
  # already in (editing their plan later) is not stopped by it. HACKATIME_REQUIRED=0 (config.x.hackatime.required) makes the
  # step optional for everyone: the escape hatch if Hackatime or its OAuth app is down.
  def hackatime_ready?
    return true unless hackatime_required?
    return true if current_user&.onboarded?

    connection = current_user&.hackatime_connection
    connection.present? && !connection.needs_reconnect?
  end

  def hackatime_required? = Rails.configuration.x.hackatime.required

  def hackatime_required
    redirect_to onboarding_step_path("account"), alert: "Connect Hackatime first. It's how your coding time counts."
  end

  # Whoever the answers belong to: the signed-in user, or the session-backed draft of a visitor who hasn't signed in.
  def subject
    @subject ||= current_user || OnboardingDraft.new(session)
  end

  def set_step
    @step = STEPS.find { |step| step == params[:step] } || (return head :not_found)
    @index = STEPS.index(@step)
  end

  # Order is enforced here, never by the client: a step is only reachable once the previous ones were saved.
  def enforce_progress
    if @step == "celebrate" && current_user&.onboarded?
      redirect_to dashboard_path
    elsif signed_in? && SKIPPED_WHEN_SIGNED_IN.include?(@step)
      redirect_to onboarding_step_path(STEPS.fetch(current_user.onboarded? ? first_index : unlocked_index))
    elsif @index > unlocked_index
      redirect_to onboarding_step_path(STEPS.fetch(unlocked_index))
    elsif @step == "celebrate" && signed_in? && !hackatime_ready?
      hackatime_required # a connection that lapsed after the account step was saved counts as missing
    end
  end

  def first_index = STEPS.index { |step| !(signed_in? && SKIPPED_WHEN_SIGNED_IN.include?(step)) }

  # The furthest step reachable: what was saved, moved past the steps a signed-in user never sees.
  def unlocked_index
    index = subject.onboarding_step
    index += 1 while signed_in? && SKIPPED_WHEN_SIGNED_IN.include?(STEPS[index])
    index
  end

  def next_index
    index = @index + 1
    index += 1 while signed_in? && SKIPPED_WHEN_SIGNED_IN.include?(STEPS[index])
    index
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
      subject.onboarding_step = [ subject.onboarding_step, next_index ].max
      subject.save
      track_event(:onboarding_step_completed, step: "age")
      redirect_to onboarding_step_path(STEPS.fetch(next_index))
    else
      track_event(:onboarding_ineligible)
      # Turbo only shows a form response that is a redirect or an error status, so this is a 422 like the other steps.
      render :ineligible, status: :unprocessable_content
    end
  end

  def save_step
    user = subject
    user.assign_attributes(step_params)
    user.valid?
    REQUIRED.fetch(@step, []).each { |attribute| user.errors.add(attribute, :blank) if user[attribute].blank? }
    user.errors.add(:coding_days, :blank) if @step == "schedule" && user.coding_days.zero? # worded by OnboardingsHelper
    user.errors.add(:pace_minutes, :inclusion) if @step == "schedule" && pace_not_a_whole_number?(user) && !user.errors.of_kind?(:pace_minutes, :inclusion)
    user.errors.add(:referral_source, :inclusion) if user.referral_source && !ReferralSource.find(user.referral_source)
    return false if user.errors.any?

    user.onboarding_step = [ user.onboarding_step, next_index ].max
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

  # Analytics for a saved step: the first run through is onboarding events (the answers reduced to enums, never the idea or the times); a
  # player who is already in and edits their plan records only the settings change.
  def track_step_saved
    editing = current_user&.onboarded?
    track_event(:onboarding_step_completed, step: @step, **Analytics::Journey.onboarding_props(@step, subject)) unless editing
    track_event(:settings_saved, section: "schedule") if editing && @step == "schedule"
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

    finished = current_user.with_lock { !current_user.onboarded? && current_user.update!(onboarded_at: Time.current) }
    track_event(:onboarding_completed) if finished
    Notifications::Scheduler.refresh(current_user)
    redirect_to dashboard_path
  end
end
