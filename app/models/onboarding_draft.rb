# What a visitor has answered so far, kept in the encrypted session cookie until they sign in with Hack Club (the
# step after schedule). It wraps an unsaved User, so the forms, the error helpers and every User validation work
# unchanged; only `save` differs: it writes the answers to the session, never the database. They become a real
# account's answers in User.from_hca_claims!.
class OnboardingDraft < SimpleDelegator
  SESSION_KEY = "onboarding_draft".freeze
  # Index of the sign-up step (see OnboardingsController::STEPS): the furthest a visitor can unlock without an account.
  SIGNUP_STEP = 4
  # Index of the prize step: where an account resumes when the prize in its draft is no longer on offer.
  PRIZE_STEP = 1
  ANSWERS = %w[prize_key project_kind project_idea coding_days coding_time coding_times time_zone].freeze
  # Never a real Hack Club Auth id: only there so the unsaved user passes its own presence validation.
  PLACEHOLDER_UID = "draft".freeze

  def initialize(session)
    @session = session
    stored = session[SESSION_KEY]
    stored = {} unless stored.is_a?(Hash)
    user = User.new(stored.slice(*ANSWERS, "onboarding_step").merge("hca_uid" => PLACEHOLDER_UID))
    user.send(:changes_applied) # what was loaded is the saved baseline, so *_in_database reads it
    super(user)
  end

  # The draft lives in a 4 KB cookie (encrypted, so about 1.8 times bigger, next to the CSRF token, referral slug and
  # splash flag). 500 four-byte emoji overflow it, so an idea is capped in bytes here; ordinary text is never affected.
  # With the biggest idea a different time on all seven days (about 200 bytes more) still leaves roughly 800 bytes free.
  MAX_IDEA_BYTES = 1200

  def valid?(context = nil)
    ok = __getobj__.valid?(context)
    # (an idea over 500 characters already has its own, clearer message)
    if project_idea.to_s.bytesize > MAX_IDEA_BYTES && !errors.of_kind?(:project_idea, :too_long)
      errors.add(:project_idea, :too_many_bytes, message: "That idea has too many emoji or special characters to save before you sign up. Please shorten it a little.")
      ok = false
    end
    ok
  end

  def save
    return false unless valid?

    @session[SESSION_KEY] = attributes.slice(*ANSWERS, "onboarding_step")
    __getobj__.send(:changes_applied)
    true
  end

  def started? = onboarding_step.positive?

  # Copies the answers onto a user who has not finished onboarding. Only a valid draft is used, and the user's step
  # moves forward, never back; finishing the draft unlocks the step after sign-up. True when something was applied.
  # Answers the visitor never gave (nil, blank, or the 0 days default) leave what the account already has alone. A prize
  # that was archived since it was picked is not applied (validation only checks prizes that change, and the loaded
  # draft counts as unchanged, so it is checked here instead of failing the sign-in later): the rest is kept and the
  # account resumes at the prize step to pick another.
  def apply_to(user)
    return false unless started? && valid?

    stale_prize = prize_key.present? && !Prize.find(prize_key)&.active?
    ANSWERS.each do |name|
      next if name == "prize_key" && stale_prize
      next if name == "coding_times" # follows the days, below

      user[name] = self[name] unless self[name].blank? || self[name] == 0
    end
    # Different times belong to the days they were picked with: a chosen schedule replaces the account's, overrides included.
    user.coding_times = coding_times if coding_days.positive?
    unlocked = onboarding_step == SIGNUP_STEP ? SIGNUP_STEP + 1 : onboarding_step
    unlocked = [ unlocked, PRIZE_STEP ].min if stale_prize
    user.onboarding_step = [ user.onboarding_step, unlocked ].max
    true
  end
end
