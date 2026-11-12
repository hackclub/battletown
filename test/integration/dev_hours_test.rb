require "test_helper"

class DevHoursTest < ActionDispatch::IntegrationTest
  def in_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  setup do
    # Render the public 404 page like production does, not the detailed debug page.
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
  end

  teardown { Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed }

  def dev_login = in_env("development") { post "/dev_login" }

  test "404 outside development, signed in or not" do
    get "/dev/hours"
    assert_response :not_found

    dev_login
    %w[test production].each do |env|
      in_env(env) do
        get "/dev/hours"
        assert_response :not_found, env
        assert_no_difference "HourEntry.count" do
          post "/dev/hours", params: { local_date: Date.current.iso8601, minutes: "30" }
        end
        assert_response :not_found, env
      end
    end
  end

  test "signed-out visitors are sent to sign in in development" do
    in_env("development") { get "/dev/hours" }
    assert_redirected_to root_path
  end

  test "shows a green dev-only form to a signed-in user in development" do
    dev_login
    in_env("development") { get "/dev/hours" }

    assert_response :success
    assert_select "section.dev-only form[action='/dev/hours'][method='post']", 1
    assert_select "input[name='local_date'][type='date']", 1
    assert_select "input[name='minutes'][type='number']", 1
    assert_select "[style]", 0
    assert_select "title", /Dev hours/
  end

  test "adds minutes for a chosen local date to the current user only" do
    dev_login
    user = User.find_by!(hca_uid: "dev-user")
    other = users(:onboarded)
    date = Hours::Days.today(user) - 1

    in_env("development") do
      assert_difference "HourEntry.where(user_id: user.id).count", 1 do
        post "/dev/hours", params: { local_date: date.iso8601, minutes: "45" }
      end
      assert_redirected_to "/dev/hours"
      follow_redirect!
      assert_select ".flash", /Added 45 minutes/
      assert_select "tbody tr", 7
      assert_select "tbody tr:nth-child(2) td", "45"
    end

    entry = HourEntry.find_by!(user_id: user.id)
    assert_equal [ date, 2_700, "manual", "dev:hours" ], [ entry.local_date, entry.seconds, entry.source, entry.created_by ]
    assert_equal 0, HourEntry.where(user_id: other.id).count
  end

  test "bad input and refused credits show a message and write nothing" do
    dev_login
    in_env("development") do
      assert_no_difference "HourEntry.count" do
        post "/dev/hours", params: { local_date: "nope", minutes: "30" }
        assert_redirected_to "/dev/hours"
        post "/dev/hours", params: { local_date: Date.current.iso8601, minutes: "-5" }
        post "/dev/hours", params: { local_date: (Date.current - 30).iso8601, minutes: "30" }
        follow_redirect!
        assert_select ".flash", /Not added/
        post "/dev/hours", params: { local_date: Date.current.iso8601, minutes: "0" }
      end
    end
  end

  test "the daily cap is reported, not an error" do
    dev_login
    in_env("development") do
      date = Hours::Days.today(User.find_by!(hca_uid: "dev-user")).iso8601
      post "/dev/hours", params: { local_date: date, minutes: "720" }
      post "/dev/hours", params: { local_date: date, minutes: "10" }
      follow_redirect!
      assert_select ".flash", /daily cap/
    end
    assert_equal 43_200, HourEntry.where(user: User.find_by!(hca_uid: "dev-user")).sum(:seconds)
  end
end
