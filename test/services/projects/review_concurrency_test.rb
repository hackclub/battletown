require "test_helper"

# Two staff reviewing the same project at the same moment, on real connections (so not inside a rolled-back transaction).
class Projects::ReviewConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @owner = User.create!(hca_uid: "ident!race-owner", email: "race-owner@example.test", display_name: "Race Owner")
    @one = User.create!(hca_uid: "ident!race-one", email: "race-one@example.test", display_name: "Race One")
    @two = User.create!(hca_uid: "ident!race-two", email: "race-two@example.test", display_name: "Race Two")
    @project = Project.create!(user: @owner, name: "Race project", kind: "game")
  end

  teardown do
    AdminAuditEvent.where(subject_type: "Project", subject_id: @project.id).delete_all # not cascaded: the trail outlives its subject
    User.where(id: [ @owner.id, @one.id, @two.id ]).delete_all # the database cascades to projects and reviews
  end

  def race(*blocks)
    gate = Queue.new
    ready = Queue.new
    threads = blocks.map do |block|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          gate.pop
          [ :ok, block.call ]
        rescue StandardError => error
          [ :error, error ]
        end
      end
    end
    blocks.size.times { Timeout.timeout(20) { ready.pop } }
    blocks.size.times { gate << true }
    threads.map(&:value)
  end

  test "two staff at once both land in the history and the project ends on the newest row" do
    outcomes = race(
      -> { Projects::Review.flag(project: Project.find(@project.id), reviewer: User.find(@one.id), details: "from one") },
      -> { Projects::Review.ok(project: Project.find(@project.id), reviewer: User.find(@two.id), note: "from two") }
    )
    assert_equal [ :ok, :ok ], outcomes.map(&:first), outcomes.inspect
    reviews = ProjectReview.where(project_id: @project.id).latest_first.to_a
    assert_equal 2, reviews.size
    project = Project.find(@project.id)
    assert_equal reviews.first.status, project.review_status
    assert_equal reviews.first.created_at.to_i, project.reviewed_at.to_i
  end

  test "two staff clearing the same flag at once: one clears it, the other is told it is no longer flagged" do
    Projects::Review.flag(project: @project, reviewer: @one, details: "odd")
    outcomes = race(
      -> { Projects::Review.clear(project: Project.find(@project.id), reviewer: User.find(@one.id)) },
      -> { Projects::Review.clear(project: Project.find(@project.id), reviewer: User.find(@two.id)) }
    )
    assert_equal 1, outcomes.count { |kind, _| kind == :ok }, outcomes.inspect
    failed = outcomes.find { |kind, _| kind == :error }
    assert_kind_of Projects::Review::Invalid, failed.last
    assert_equal %w[ok flagged], ProjectReview.where(project_id: @project.id).latest_first.map(&:status)
    assert_equal "ok", Project.find(@project.id).review_status
  end
end
