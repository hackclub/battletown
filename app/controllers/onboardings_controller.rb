class OnboardingsController < ApplicationController
  STEPS = %w[prize project schedule account celebrate].freeze

  PERMITTED = {
    "prize" => [ :prize_key ],
    "project" => %i[project_kind project_idea],
    "schedule" => [ :coding_time, :time_zone, { coding_day_names: [] } ],
    "account" => [ :referral_source ]
  }.freeze

  REQUIRED = {
    "prize" => %i[prize_key],
    "project" => %i[project_kind],
    "schedule" => %i[coding_time time_zone]
  }.freeze

  before_action :require_login
  before_action :set_step, :enforce_progress, only: %i[step update]

  # Sends the user to the furthest step they have unlocked.
  def show
    redirect_to onboarding_step_path(current_user.onboarded? ? STEPS.first : STEPS.fetch(current_user.onboarding_step))
  end

  def step
    render @step
  end

  def update
    return complete if @step == "celebrate"

    if save_step
      Notifications::Scheduler.refresh(current_user) if @step == "schedule"
      redirect_to after_save_path, notice: (current_user.onboarded? ? "Saved." : nil)
    else
      render @step, status: :unprocessable_content
    end
  end

  private

  def set_step
    @step = STEPS.find { |step| step == params[:step] } || (return head :not_found)
    @index = STEPS.index(@step)
  end

  # Order is enforced here, never by the client: a step is only reachable once the previous ones were saved.
  def enforce_progress
    if @step == "celebrate" && current_user.onboarded?
      redirect_to dashboard_path
    elsif @index > current_user.onboarding_step
      redirect_to onboarding_step_path(STEPS.fetch(current_user.onboarding_step))
    end
  end

  def step_params
    # A scalar `user=...` param would otherwise raise NoMethodError (500) on permit.
    raw = params[:user]
    attrs = (raw.is_a?(ActionController::Parameters) ? raw : ActionController::Parameters.new).permit(*PERMITTED.fetch(@step))
    attrs[:referral_source] = attrs[:referral_source].presence if attrs.key?(:referral_source)
    attrs.delete(:referral_source) if current_user.referral_source_in_database.present?
    attrs
  end

  def save_step
    user = current_user
    user.assign_attributes(step_params)
    user.valid?
    REQUIRED.fetch(@step, []).each { |attribute| user.errors.add(attribute, :blank) if user[attribute].blank? }
    user.errors.add(:coding_days, "must include at least one day") if @step == "schedule" && user.coding_days.zero?
    user.errors.add(:referral_source, :inclusion) if user.referral_source && !ReferralSource.find(user.referral_source)
    return false if user.errors.any?

    user.onboarding_step = [ user.onboarding_step, @index + 1 ].max
    # The project step also creates or updates the user's first project (the old user columns stay populated).
    saved = false
    User.transaction do
      saved = user.save && (@step != "project" || Project.sync_first_from_onboarding(user))
      raise ActiveRecord::Rollback unless saved
    end
    user.errors.add(:project_idea, "couldn't be saved as a project. Please try again.") if !saved && user.errors.empty?
    saved
  end

  def after_save_path
    current_user.onboarded? ? dashboard_path : onboarding_step_path(STEPS.fetch(@index + 1))
  end

  # Idempotent: the lock makes a double submit set onboarded_at only once.
  def complete
    current_user.with_lock { current_user.update!(onboarded_at: Time.current) unless current_user.onboarded? }
    Notifications::Scheduler.refresh(current_user)
    redirect_to dashboard_path
  end
end
