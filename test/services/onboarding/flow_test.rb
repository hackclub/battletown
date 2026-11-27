require "test_helper"

class Onboarding::FlowTest < ActiveSupport::TestCase
  Flow = Onboarding::Flow

  def answers_for(kind:, stops: [], pace: nil, prize: "tshirt")
    session = { onb: { "stops" => stops } }
    user = User.new(hca_uid: "flow", project_kind: kind, prize_key: prize, pace_minutes: pace)
    Onboarding::Answers.new(session, user)
  end

  test "every step has a unique key, a known kind, and phases never go backward" do
    assert_equal Flow::KEYS.uniq, Flow::KEYS
    assert Flow::STEPS.all? { |step| %i[choice multi info prize pledge system].include?(step.kind) }
    assert_equal Flow::STEPS.map(&:phase).sort, Flow::STEPS.map(&:phase)
    assert_equal User::ONBOARDING_STEPS, Flow.phase("celebrate")
  end

  test "every generic question step has words and options, and no two options share a value" do
    answers = answers_for(kind: "game")
    Flow::STEPS.select { |step| %i[choice multi].include?(step.kind) && !OnboardingsController::OWN_PAGE.include?(step.key) }.each do |step|
      question = Onboarding::Questions.for(step.key, answers)
      assert question, step.key
      assert question.title.present?, step.key
      values = question.options.map { |option| option[:value] }
      assert_operator values.size, :>=, (%w[when crew].include?(step.key) ? 2 : 3), step.key
      assert_equal values.uniq, values, step.key
    end
  end

  test "Not sure yet skips every question about the project, and goes straight to the idea" do
    undecided = Flow.visible(answers_for(kind: "undecided")).map(&:key)
    assert_equal %w[project idea], undecided.each_cons(2).find { |a, _| a == "project" }
    %w[detail audience started size crew reflect].each { |key| assert_not_includes undecided, key }
  end

  def counts(kind, stops: %w[time])
    list = Flow.visible(answers_for(kind: kind, stops: stops))
    [ list.count(&:question), list.count { |step| step.kind == :info } ]
  end

  test "question and info screens per branch, with the crew question off and on" do
    without_feature(:team) do
      %w[game website app tool].each { |kind| assert_equal [ 13, 6 ], counts(kind), kind }
      assert_equal [ 10, 4 ], counts("undecided", stops: %w[none]), "undecided with nothing stopping them: no obstacle answer screen"
      assert_equal [ 10, 5 ], counts("undecided")
    end
    with_feature(:team) do
      %w[game website app tool].each { |kind| assert_equal [ 14, 6 ], counts(kind), kind }
      assert_equal [ 10, 5 ], counts("undecided")
    end
  end

  test "the screens tell one story in this order, and the idea question is only for Not sure yet" do
    decided = Flow.visible(answers_for(kind: "game", stops: %w[time], prize: "mechanical_keyboard")).map(&:key)
    assert_equal %w[age prize use cost how when made project detail audience started size reflect editor coding_when schedule pace_date stops stops_answer summary signup account celebrate], decided
    undecided = Flow.visible(answers_for(kind: "undecided", stops: %w[time], prize: "mechanical_keyboard")).map(&:key)
    assert_equal %w[age prize use cost how when made project idea editor coding_when schedule pace_date stops stops_answer summary signup account celebrate], undecided
  end

  test "When do you want it? is asked only when its dated frames lead to at least two different paces" do
    shown = ->(prize) { Flow.visible(answers_for(kind: "game", prize: prize)).map(&:key).include?("when") }
    %w[custom_sticker keychain tshirt orpheus_plushie].each { |prize| assert_not shown.(prize), "#{prize}: every frame ends at the smallest pace" }
    assert shown.("mechanical_keyboard"), "30 hours: 3 hours a day in 2 weeks, 1 hour a day in a month"
    assert_not shown.("headphones"), "50 hours: only one dated frame is reachable"
    skipped = Flow.visible(answers_for(kind: "game")).map(&:key)
    assert_equal "how", skipped[skipped.index("cost") + 1]
    assert_equal "made", skipped[skipped.index("how") + 1]
  end

  test "next and previous skip hidden screens in both directions" do
    answers = answers_for(kind: "undecided")
    assert_equal "idea", Flow.next_key("project", answers)
    assert_equal "project", Flow.previous_key("idea", answers)
    assert_equal "prize", Flow.next_key("age", answers_for(kind: "game"), signed_in: false)
  end

  test "a signed-in person never sees the age or the pledge" do
    keys = Flow.visible(answers_for(kind: "game"), signed_in: true).map(&:key)
    assert_not_includes keys, "age"
    assert_not_includes keys, "signup"
  end

  test "progress counts only the screens this person will see" do
    answers = answers_for(kind: "undecided")
    position, total = Flow.progress("idea", answers)
    assert_equal Flow.visible(answers).size, total
    assert_equal Flow.visible(answers).map(&:key).index("idea") + 1, position
  end
end
