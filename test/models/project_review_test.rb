require "test_helper"

class ProjectReviewTest < ActiveSupport::TestCase
  setup do
    @owner = users(:new_user)
    @staff = users(:onboarded)
    @project = Project.create!(user: @owner, name: "Review me", kind: "game")
  end

  def build(**attrs) = ProjectReview.new({ project: @project, reviewer: @staff, status: "ok", created_at: Time.current }.merge(attrs))

  def connection = ActiveRecord::Base.connection

  # Runs the block in a savepoint, so a refused statement does not poison the test's transaction.
  def refused(error = ActiveRecord::StatementInvalid, &block)
    assert_raises(error) { ActiveRecord::Base.transaction(requires_new: true, &block) }
  end

  # Raw INSERT, bypassing the model, to prove the database refuses what the model would.
  def insert_review!(**values)
    row = { project_id: @project.id, reviewer_id: @staff.id, status: "ok", note: nil, created_at: Time.current }.merge(values)
    columns = row.keys.map { |key| connection.quote_column_name(key) }.join(", ")
    connection.execute("INSERT INTO project_reviews (#{columns}) VALUES (#{row.values.map { |value| connection.quote(value) }.join(', ')})")
  end

  test "ok needs no note and flagged needs one" do
    assert build.valid?
    assert build(status: "flagged", note: "Looks off").valid?
    flagged = build(status: "flagged", note: "   ")
    assert_not flagged.valid?
    assert_includes flagged.errors[:note].join, "say why"
    assert_not build(status: "flagged", note: nil).valid?
  end

  test "status must be ok or flagged" do
    %w[unreviewed cleared OK bogus].each { |status| assert_not build(status: status).valid?, status }
    assert_not build(status: nil).valid?
  end

  test "the note is at most 500 characters, counted as characters" do
    assert build(note: "a" * 500).valid?
    assert_not build(note: "a" * 501).valid?
    assert build(note: "é" * 500).valid?
    assert build(note: "🦦" * 500).valid?
    assert_not build(note: "🦦" * 501).valid?
  end

  test "staff cannot review their own project, at the model" do
    review = build(reviewer: @owner)
    assert_not review.valid?
    assert_includes review.errors[:base], Projects::Review::OWN_PROJECT_MESSAGE
  end

  test "a review without a reviewer is allowed (a former staff member) but needs a project" do
    assert build(reviewer: nil).valid?
    assert_not build(project: nil).valid?
  end

  test "a saved review can never be edited or deleted through the model" do
    review = build.tap(&:save!)
    assert review.readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) { review.update!(note: "changed") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { review.destroy }
  end

  test "latest_first orders by time and then by id" do
    now = Time.current
    first = build(created_at: now - 2.minutes).tap(&:save!)
    tie_a = build(created_at: now).tap(&:save!)
    tie_b = build(created_at: now, status: "flagged", note: "x").tap(&:save!)
    assert_equal [ tie_b, tie_a, first ], ProjectReview.latest_first.to_a
  end

  # --- the database, bypassing the model ---

  test "the database refuses an unknown status" do
    refused { insert_review!(status: "unreviewed") }
    refused { insert_review!(status: "Flagged", note: "x") }
    refused { insert_review!(status: nil) }
  end

  test "the database refuses a flag without a reason" do
    refused { insert_review!(status: "flagged", note: nil) }
    refused { insert_review!(status: "flagged", note: "  \n ") }
    assert_nothing_raised { insert_review!(status: "flagged", note: "reason") }
  end

  test "the database refuses a note over 500 characters" do
    refused { insert_review!(note: "a" * 501) }
    assert_nothing_raised { insert_review!(note: "a" * 500) }
  end

  test "the database refuses a review for a project that does not exist" do
    refused(ActiveRecord::InvalidForeignKey) { insert_review!(project_id: 0) }
  end

  test "the database refuses a project review_status outside the allowlist" do
    %w[Flagged cleared reviewed].each do |value|
      refused { @project.update_columns(review_status: value, reviewed_at: Time.current) }
    end
    refused { @project.update_columns(review_status: nil) }
  end

  test "the database keeps reviewed_at and review_status in step" do
    refused { @project.update_columns(review_status: "ok", reviewed_at: nil) }
    refused { @project.update_columns(review_status: "unreviewed", reviewed_at: Time.current) }
    assert_nothing_raised { @project.update_columns(review_status: "flagged", reviewed_at: Time.current) }
  end

  test "projects start unreviewed" do
    assert_equal "unreviewed", @project.reload.review_status
    assert_nil @project.reviewed_at
    assert @project.review_unreviewed?
  end

  test "the project model validates its review status" do
    @project.review_status = "bogus"
    assert_not @project.valid?
  end

  # --- cascades ---

  test "deleting the project deletes its reviews" do
    insert_review!
    assert_difference("ProjectReview.count", -1) { @project.destroy! }
  end

  test "deleting the owner deletes the reviews of their projects" do
    insert_review!
    assert_difference("ProjectReview.count", -1) { @owner.destroy! }
  end

  test "deleting the reviewer keeps the review and forgets who wrote it" do
    insert_review!(status: "flagged", note: "kept")
    assert_no_difference("ProjectReview.count") { @staff.destroy! }
    assert_nil ProjectReview.last.reviewer_id
    assert_equal "kept", ProjectReview.last.note
    assert_equal "flagged", ProjectReview.last.status
  end

  test "the history index exists newest first" do
    index = connection.indexes(:project_reviews).find { |i| i.columns == %w[project_id created_at] }
    assert index
    assert_equal({ "created_at" => :desc }, index.orders.transform_keys(&:to_s))
  end
end
