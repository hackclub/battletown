require "test_helper"

class Projects::ReviewTest < ActiveSupport::TestCase
  setup do
    @owner = users(:new_user)
    @staff = users(:onboarded)
    @second = User.create!(hca_uid: "ident!second-staff", email: "second@example.test", display_name: "Second Staff")
    @project = Project.create!(user: @owner, name: "Cow Game", kind: "game")
  end

  Review = Projects::Review

  test "marking OK appends a row and copies it onto the project" do
    review = Review.ok(project: @project, reviewer: @staff)
    @project.reload
    assert_equal "ok", @project.review_status
    assert_equal review.created_at.to_i, @project.reviewed_at.to_i
    assert_equal [ "ok" ], @project.project_reviews.map(&:status)
    assert_nil review.note
    assert_equal @staff, review.reviewer
  end

  test "marking OK keeps an optional note, squished" do
    review = Review.ok(project: @project, reviewer: @staff, note: "  Looks \n good  ")
    assert_equal "Looks good", review.note
  end

  test "flagging needs a reason: a preset, details, or both" do
    assert_equal "Needs a safety check", Review.flag(project: @project, reviewer: @staff, preset: "Needs a safety check").note
    assert_equal "Links don't work: 404 on the demo", Review.flag(project: @project, reviewer: @staff, preset: "Links don't work", details: "404 on the demo").note
    assert_equal "only my words", Review.flag(project: @project, reviewer: @staff, details: "only my words").note
    assert_equal "flagged", @project.reload.review_status
  end

  test "flagging without a reason is refused and changes nothing" do
    [ [ nil, nil ], [ "", "  " ], [ "Not a preset", "" ], [ "Other", "" ], [ "Other", "   " ] ].each do |preset, details|
      assert_raises(Review::Invalid, [ preset, details ].inspect) { Review.flag(project: @project, reviewer: @staff, preset: preset, details: details) }
    end
    assert_equal "unreviewed", @project.reload.review_status
    assert_nil @project.reviewed_at
    assert_equal 0, ProjectReview.count
  end

  test "an unknown preset is ignored when details are given" do
    assert_equal "my words", Review.flag(project: @project, reviewer: @staff, preset: "<script>", details: "my words").note
  end

  test "the whole reason may be 500 characters and not one more" do
    Review.flag(project: @project, reviewer: @staff, details: "a" * 500)
    error = assert_raises(Review::Invalid) { Review.flag(project: @project, reviewer: @staff, details: "a" * 501) }
    assert_includes error.message, "501"
    assert_raises(Review::Invalid) { Review.flag(project: @project, reviewer: @staff, preset: "Looks like someone else's work", details: "a" * 480) }
    assert_raises(Review::Invalid) { Review.ok(project: @project, reviewer: @staff, note: "b" * 501) }
    assert_equal 1, ProjectReview.count
  end

  test "clearing needs a flag, and records an OK row" do
    error = assert_raises(Review::Invalid) { Review.clear(project: @project, reviewer: @staff) }
    assert_includes error.message, "not flagged"
    Review.flag(project: @project, reviewer: @staff, preset: "Other", details: "odd")
    Review.clear(project: @project, reviewer: @second, note: "Checked, fine")
    assert_equal "ok", @project.reload.review_status
    assert_equal [ "ok", "flagged" ], @project.project_reviews.map(&:status)
    assert_raises(Review::Invalid) { Review.clear(project: @project, reviewer: @staff) } # already cleared
  end

  test "a note keeps the current state and needs a review first" do
    assert_raises(Review::Invalid) { Review.add_note(project: @project, reviewer: @staff, note: "hi") }
    Review.flag(project: @project, reviewer: @staff, details: "odd")
    Review.add_note(project: @project, reviewer: @second, note: "Asked in Slack")
    assert_equal "flagged", @project.reload.review_status
    assert_equal [ "Asked in Slack", "odd" ], @project.project_reviews.map(&:note)
    assert_raises(Review::Invalid) { Review.add_note(project: @project, reviewer: @staff, note: "   ") }
  end

  test "history is newest first and the latest row is the current state" do
    now = Time.current
    travel_to(now - 3.hours) { Review.ok(project: @project, reviewer: @staff) }
    travel_to(now - 2.hours) { Review.flag(project: @project, reviewer: @second, details: "later") }
    travel_to(now - 1.hour) { Review.clear(project: @project, reviewer: @staff) }
    assert_equal %w[ok flagged ok], @project.project_reviews.map(&:status)
    assert_equal "ok", @project.reload.review_status
    assert_equal @project.project_reviews.first.status, @project.review_status
  end

  test "the project's copy always equals its newest row, whatever the sequence" do
    steps = [ -> { Review.ok(project: @project, reviewer: @staff) }, -> { Review.flag(project: @project, reviewer: @second, details: "x") },
              -> { Review.add_note(project: @project, reviewer: @staff, note: "n") }, -> { Review.clear(project: @project, reviewer: @second) },
              -> { Review.flag(project: @project, reviewer: @staff, details: "y") } ]
    steps.each do |step|
      step.call
      @project.reload
      assert_equal @project.project_reviews.first.status, @project.review_status
      assert_equal @project.project_reviews.first.created_at.to_i, @project.reviewed_at.to_i
    end
  end

  test "staff cannot review their own project, and nothing is written" do
    mine = Project.create!(user: @staff, name: "Mine", kind: "tool")
    [ -> { Review.ok(project: mine, reviewer: @staff) }, -> { Review.flag(project: mine, reviewer: @staff, details: "x") },
      -> { Review.clear(project: mine, reviewer: @staff) }, -> { Review.add_note(project: mine, reviewer: @staff, note: "x") } ].each do |attempt|
      error = assert_raises(Review::OwnProject) { attempt.call }
      assert_equal Review::OWN_PROJECT_MESSAGE, error.message
      assert_kind_of Review::Invalid, error
    end
    assert_equal 0, ProjectReview.count
    assert_equal "unreviewed", mine.reload.review_status
  end

  test "a review needs a reviewer" do
    assert_raises(Review::Invalid) { Review.ok(project: @project, reviewer: nil) }
  end

  test "reviewing changes nothing about coding, hours, coins, ships or the project itself" do
    HourEntry.create!(user: @owner, local_date: Date.new(2026, 11, 9), seconds: 3600, source: "manual", note: "t", hackatime_project: "cows", idempotency_key: "r1")
    before = [ @owner.reload.attributes, HourEntry.count, CoinTransaction.count, Ship.count, Order.count, Notification.count ]
    project_before = @project.reload.attributes.except("review_status", "reviewed_at")
    Review.flag(project: @project, reviewer: @staff, details: "x")
    Review.clear(project: @project, reviewer: @staff)
    assert_equal before, [ @owner.reload.attributes, HourEntry.count, CoinTransaction.count, Ship.count, Order.count, Notification.count ]
    assert_equal project_before, @project.reload.attributes.except("review_status", "reviewed_at")
    assert @project.status_active?
  end

  test "a failed audit write rolls the whole review back: the row, the copy and the event go together" do
    original = AdminAudit.method(:record!)
    AdminAudit.define_singleton_method(:record!) { |**| raise "audit down" }
    begin
      assert_raises(RuntimeError) { Review.flag(project: @project, reviewer: @staff, details: "x") }
    ensure
      AdminAudit.define_singleton_method(:record!, original)
    end
    assert_equal 0, ProjectReview.count
    assert_equal "unreviewed", @project.reload.review_status
    assert_equal 0, AdminAuditEvent.count
  end

  test "each action writes one audit event with the project and the new status, and no note text or names" do
    Review.ok(project: @project, reviewer: @staff, note: "Secret staff words")
    Review.flag(project: @project, reviewer: @staff, details: "More secret words")
    Review.add_note(project: @project, reviewer: @staff, note: "Even more")
    Review.clear(project: @project, reviewer: @staff)
    events = AdminAuditEvent.where(subject_type: "Project").order(:id).to_a
    assert_equal %w[project_reviewed project_flagged project_note_added project_cleared], events.map(&:action)
    assert_equal [ @project.id ], events.map(&:subject_id).uniq
    assert_equal [ @staff.id ], events.map(&:actor_id).uniq
    assert_equal [ "ok", "flagged", "flagged", "ok" ], events.map { |event| event.metadata["status"] }
    assert_equal [ [ "status" ] ] * 4, events.map { |event| event.metadata.keys }
    dump = events.map { |event| [ event.metadata, event.subject_type ] }.inspect
    [ "Secret staff words", "More secret words", "Cow Game", "Newbie" ].each { |text| assert_not_includes dump, text }
  end

  test "a refused review (own project, bad input, wrong state) writes no audit event" do
    assert_raises(Review::Invalid) { Review.flag(project: @project, reviewer: @staff) }
    assert_raises(Review::Invalid) { Review.clear(project: @project, reviewer: @staff) }
    assert_raises(Review::OwnProject) { Review.ok(project: Project.create!(user: @staff, name: "Mine", kind: "tool"), reviewer: @staff) }
    assert_equal 0, AdminAuditEvent.count
  end

  test "the audit allowlist names the four review actions" do
    assert_equal %w[project_reviewed project_flagged project_cleared project_note_added].sort, (AdminAudit::REVIEW_ACTIONS & Review::AUDIT_ACTIONS.values).sort
    assert_equal Review::AUDIT_ACTIONS.values.sort, AdminAudit::REVIEW_ACTIONS.sort
  end
end
