require "test_helper"
require "rake"

# Retention: comments are emptied after nps.comment_retention_days, scores stay, whatever the flag says.
class Nps::PruneTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 11, 12, 12)

  setup do
    @user = users(:onboarded)
    @days = Nps::Config.current.comment_retention_days
  end

  def answer(age_days, comment: "some words", score: 7)
    date = Date.new(2026, 11, 12) - age_days
    NpsResponse.create!(user: @user, score: score, comment: comment, answered_at: NOW - age_days.days, prompt_window_date: date)
  end

  test "comments older than the retention period are emptied and their scores kept" do
    old = answer(@days + 1, score: 3)
    boundary_in = answer(@days - 1, score: 9)
    assert_equal 1, Nps::Prune.call(now: NOW)
    assert_nil old.reload.comment
    assert_equal 3, old.score
    assert_equal "some words", boundary_in.reload.comment
  end

  test "it is safe to repeat and leaves rows with no comment alone" do
    answer(@days + 5)
    answer(@days + 6, comment: nil)
    assert_equal 1, Nps::Prune.call(now: NOW)
    assert_equal 0, Nps::Prune.call(now: NOW)
    assert_equal 2, NpsResponse.count
  end

  test "it runs whether or not the flag is on" do
    answer(@days + 1)
    without_feature(:nps) { assert_equal 1, Nps::Prune.call(now: NOW) }
  end

  test "the rake task prunes with the configured retention" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("nps:prune")
    old = answer(@days + 1)
    kept = answer(1)
    Rake::Task["nps:prune"].reenable
    out, = capture_io { Rake::Task["nps:prune"].invoke }
    assert_match(/nps:prune emptied=1/, out)
    assert_nil old.reload.comment
    assert_equal "some words", kept.reload.comment
  end
end
