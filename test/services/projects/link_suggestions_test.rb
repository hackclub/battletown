require "test_helper"

class Projects::LinkSuggestionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:onboarded)
    @project = Project.create!(user: @user, name: "Space Farm")
    @other_project = Project.create!(user: @user, name: "Website")
    @suggestion = @project.link_suggestions.create!(hackatime_project: "space-farm-dev")
  end

  test "accept! links with the confirmed method and marks the suggestion accepted" do
    link = Projects::LinkSuggestions.accept!(@suggestion)
    assert_equal "confirmed", link.link_method
    assert_equal @project, link.project
    assert_equal @user.id, link.user_id
    assert @suggestion.reload.accepted?
  end

  test "decline! remembers the no and links nothing" do
    Projects::LinkSuggestions.decline!(@suggestion)
    assert @suggestion.reload.declined?
    assert_equal 0, HackatimeLink.count
  end

  test "an answered suggestion cannot be answered again" do
    Projects::LinkSuggestions.decline!(@suggestion)
    assert_raises(Projects::LinkSuggestions::NotPending) { Projects::LinkSuggestions.accept!(@suggestion) }
    assert_raises(Projects::LinkSuggestions::NotPending) { Projects::LinkSuggestions.decline!(@suggestion) }
    assert_equal 0, HackatimeLink.count
  end

  test "accept! fails cleanly when the Hackatime project got linked elsewhere, leaving the suggestion pending" do
    @other_project.hackatime_links.create!(user_id: @user.id, hackatime_project: "space-farm-dev", link_method: "manual")
    assert_raises(ActiveRecord::RecordInvalid) { Projects::LinkSuggestions.accept!(@suggestion) }
    assert @suggestion.reload.pending?
    assert_equal @other_project, HackatimeLink.project_for(@user, "space-farm-dev")
  end

  test "suggest! saves, announces once with only the suggestion id, and is a no-op for repeats" do
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("project_link_suggested.battletown") { |event| payloads << event.payload }
    created = Projects::LinkSuggestions.suggest!(@other_project, "my-site")
    assert created.pending?
    assert_equal [ { suggestion_id: created.id } ], payloads
    assert_nil Projects::LinkSuggestions.suggest!(@other_project, "my-site")
    assert_equal 1, payloads.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "remember_decline! turns an unlink into a remembered no, creating or updating the row" do
    Projects::LinkSuggestions.remember_decline!(@project, "space-farm-dev")
    assert @suggestion.reload.declined?
    Projects::LinkSuggestions.remember_decline!(@project, "brand-new")
    assert @project.link_suggestions.find_by!(hackatime_project: "brand-new").declined?
  end
end
