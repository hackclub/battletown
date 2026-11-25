require "test_helper"

class OnboardingDraftTest < ActiveSupport::TestCase
  def draft(stored = {}) = OnboardingDraft.new({ OnboardingDraft::SESSION_KEY => stored })

  test "starts empty and unstarted, never a real account" do
    d = draft
    assert_not d.started?
    assert_not d.onboarded?
    assert_nil d.prize_key
    assert_equal 0, d.onboarding_step
    assert_no_difference("User.count") { d.save }
  end

  test "save validates like a user and writes only the answers to the session" do
    session = {}
    d = OnboardingDraft.new(session)
    d.assign_attributes(prize_key: "nope")
    assert_not d.save
    assert_empty session

    d = OnboardingDraft.new(session)
    d.assign_attributes(prize_key: "tshirt", onboarding_step: 2)
    assert d.save
    assert_equal %w[coding_days coding_time coding_times onboarding_step pace_minutes prize_key project_idea project_kind time_zone], session[OnboardingDraft::SESSION_KEY].keys.sort
    assert_equal "tshirt", OnboardingDraft.new(session).prize_key
    assert_equal "tshirt", OnboardingDraft.new(session).prize_key_in_database
  end

  test "a tampered or malformed session value is ignored" do
    assert_not OnboardingDraft.new({ OnboardingDraft::SESSION_KEY => "junk" }).started?
    assert_equal 0, OnboardingDraft.new({ OnboardingDraft::SESSION_KEY => { "evil" => 1, "onboarded_at" => "now" } }).onboarding_step
  end

  test "apply_to copies only answers that were given and moves the step forward, never back" do
    user = User.new(hca_uid: "ident!x", coding_days: 3, coding_time: "07:00", onboarding_step: 3)
    assert draft("prize_key" => "tshirt", "onboarding_step" => 2).apply_to(user)
    assert_equal [ "tshirt", 3, "07:00", 3 ], [ user.prize_key, user.coding_days, user.coding_time, user.onboarding_step ]
  end

  test "apply_to copies the pace, and leaves the account's alone when the draft has none" do
    user = User.new(hca_uid: "ident!pace", pace_minutes: 30)
    assert draft("prize_key" => "tshirt", "onboarding_step" => 2).apply_to(user)
    assert_equal 30, user.pace_minutes

    assert draft("prize_key" => "tshirt", "pace_minutes" => 120, "onboarding_step" => 2).apply_to(user)
    assert_equal 120, user.pace_minutes
  end

  test "a pace that is not offered makes the draft invalid and is never saved" do
    session = {}
    d = OnboardingDraft.new(session)
    d.assign_attributes(pace_minutes: 7)
    assert_not d.save
    assert d.errors.of_kind?(:pace_minutes, :inclusion)
    assert_empty session

    assert_not draft("prize_key" => "tshirt", "pace_minutes" => 7, "onboarding_step" => 2).apply_to(User.new(hca_uid: "ident!bad"))
  end

  test "apply_to unlocks the step after sign-up for a complete draft, and refuses an unstarted or archived one" do
    user = User.new(hca_uid: "ident!y")
    full = { "prize_key" => "tshirt", "project_kind" => "game", "coding_days" => 5, "coding_time" => "18:30", "time_zone" => "UTC", "onboarding_step" => OnboardingDraft::SIGNUP_STEP }
    assert draft(full).apply_to(user)
    assert_equal OnboardingDraft::SIGNUP_STEP + 1, user.onboarding_step

    assert_not draft.apply_to(User.new(hca_uid: "ident!z"))

    # An archived prize is left out, the rest is kept, and the account resumes at the prize step.
    ShopItem.find_by!(key: "tshirt").update!(active: false)
    Prize.reload!
    late = User.new(hca_uid: "ident!w")
    assert draft(full).apply_to(late)
    assert_equal [ nil, "game", "18:30", OnboardingDraft::PRIZE_STEP ], [ late.prize_key, late.project_kind, late.coding_time, late.onboarding_step ]
  ensure
    ShopItem.find_by(key: "tshirt")&.update!(active: true)
    Prize.reload!
  end
end
