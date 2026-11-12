require "test_helper"

# /feedback/:token, the public one-click survey page behind the `nps` flag.
class NpsFeedbackTest < ActionDispatch::IntegrationTest
  DATE = Date.new(2026, 11, 12)

  setup do
    @user = users(:onboarded)
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    Flipper.enable(:nps)
  end

  teardown do
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
  end

  def token(user = @user, date = DATE, now: Time.current) = Nps::Token.generate(user, date, now: now)

  def answer!(token_value, score: 9, comment: nil)
    post feedback_path(token_value), params: { nps: { score: score, comment: comment } }
  end

  def with_forgery_protection
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  # --- the flag ---

  test "with the flag off the page and the answer are a 404 and nothing is stored" do
    value = token
    without_feature(:nps) do
      get feedback_path(value)
      assert_response :not_found
      post feedback_path(value), params: { nps: { score: 9 } }
      assert_response :not_found
    end
    assert_equal 0, NpsResponse.count
  end

  # --- the page ---

  test "a signed-out visitor with a good link sees the rating form and nothing personal" do
    get feedback_path(token)
    assert_response :success
    assert_select "title", "BattleTown"
    assert_select "h1", "Quick question"
    assert_select "fieldset legend", /How likely are you to recommend Battletown/
    assert_select "input[type=radio][name='nps[score]']", 11
    (0..10).each { |value| assert_select "input#nps_score_#{value}[value='#{value}']" }
    assert_select ".toggle__label", text: /\A0/
    assert_select "textarea[name='nps[comment]'][maxlength='300']"
    assert_select ".nps__ends", /Not likely.*Very likely/m
    assert_no_match(/#{Regexp.escape(@user.display_name.to_s)}/, response.body) if @user.display_name.present?
    assert_no_match(/#{Regexp.escape(@user.email.to_s)}/, response.body) if @user.email.present?
    assert_no_match(/#{Regexp.escape(@user.slack_id.to_s)}/, response.body) if @user.slack_id.present?
    assert_select "a[href=?]", dashboard_path, count: 0
  end

  test "the page is kept out of caches, search engines and the Referer header" do
    get feedback_path(token)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    assert_match(/noindex/, response.headers["X-Robots-Tag"])
  end

  test "a bad link of any kind gets the same page and reveals nothing" do
    good = token
    bad_links = [ "a" * 40, good[0..-2] + (good[-1] == "a" ? "b" : "a"), good.sub(/\A./, "Z"), token(now: Time.current - 8.days),
                  token(User.new.tap { |u| u.id = 999_999_999 }) ]
    pages = bad_links.map do |link|
      get feedback_path(link)
      assert_response :not_found
      assert_select "h1", "This link isn't working"
      assert_select "input[type=radio]", 0
      css_select("main").first.to_s
    end
    assert_equal 1, pages.uniq.size, "every kind of bad link renders the identical page"
    post feedback_path(bad_links.first), params: { nps: { score: 9 } }
    assert_response :not_found
    assert_equal 0, NpsResponse.count
  end

  test "the link works on the last day and not after it" do
    get feedback_path(token(now: Time.current - 7.days + 1.hour))
    assert_response :success
    get feedback_path(token(now: Time.current - 7.days - 1.hour))
    assert_response :not_found
  end

  test "a token signed for another purpose does not open the page" do
    other = ActiveSupport::MessageVerifier.new(Rails.application.key_generator.generate_key(Nps::Token::SALT), digest: "SHA256", serializer: JSON, url_safe: true)
    get feedback_path(other.generate({ "u" => @user.id, "w" => DATE.iso8601 }, purpose: "session", expires_in: 1.day))
    assert_response :not_found
  end

  # --- answering ---

  test "a score alone is saved for the person and window in the token, and a thank-you is shown" do
    freeze_time do
      answer!(token, score: 9)
      assert_response :success
      assert_select "h1", "Thanks for telling us!"
      response_row = NpsResponse.sole
      assert_equal [ @user.id, 9, nil, DATE, Time.current ], [ response_row.user_id, response_row.score, response_row.comment, response_row.prompt_window_date, response_row.answered_at ]
    end
  end

  test "the comment is stored as plain text and shown escaped" do
    value = token
    answer!(value, score: 4, comment: "  <script>alert(1)</script>\n  <b>hi</b> & bye ")
    assert_equal "<script>alert(1)</script> <b>hi</b> & bye", NpsResponse.sole.comment
    assert_not_includes response.body, "<script>alert(1)"
  end

  test "a score outside 0 to 10 or not a number is refused with a message and nothing is stored" do
    value = token
    [ "11", "-1", "abc", "", "5.5", "1e1", "05" ].each do |score|
      answer!(value, score: score, comment: "keep this text")
      assert_response :unprocessable_content, score.inspect
      assert_select ".alert", /Pick a number from 0 to 10/
      assert_select "textarea", /keep this text/
    end
    post feedback_path(value), params: {}
    assert_response :unprocessable_content
    assert_equal 0, NpsResponse.count
  end

  test "a comment over 300 characters is refused, exactly 300 is fine" do
    value = token
    answer!(value, score: 7, comment: "x" * 301)
    assert_response :unprocessable_content
    assert_select ".alert", /300 characters/
    assert_equal 0, NpsResponse.count
    answer!(value, score: 7, comment: "x" * 300)
    assert_response :success
    assert_equal 300, NpsResponse.sole.comment.length
  end

  test "odd parameter shapes do not raise" do
    value = token
    post feedback_path(value), params: { nps: { score: [ "9" ], comment: { a: "b" } } }
    assert_response :unprocessable_content
    post feedback_path(value), params: { nps: "nonsense" }
    assert_response :unprocessable_content
    assert_equal 0, NpsResponse.count
  end

  test "a second use of the link shows you already answered, changes nothing and shows no answer" do
    value = token
    answer!(value, score: 10, comment: "first words")
    answer!(value, score: 0, comment: "second words")
    assert_response :success
    assert_select "h1", "Thanks, you already answered"
    assert_equal [ 10, "first words" ], [ NpsResponse.sole.score, NpsResponse.sole.comment ]
    get feedback_path(value)
    assert_select "h1", "Thanks, you already answered"
    assert_no_match(/first words|second words/, response.body)
    assert_select "input[type=radio]", 0
  end

  test "a lost race on the unique index is the same already answered page" do
    value = token
    NpsResponse.create!(user: @user, score: 5, answered_at: Time.current, prompt_window_date: DATE)
    original = NpsResponse.method(:exists?)
    calls = 0
    NpsResponse.define_singleton_method(:exists?) do |*args|
      calls += 1
      calls == 1 ? false : original.call(*args)
    end
    begin
      answer!(value, score: 1)
    ensure
      NpsResponse.define_singleton_method(:exists?, original)
    end
    assert_select "h1", "Thanks, you already answered"
    assert_equal 5, NpsResponse.sole.score
  end

  test "a window after the cooldown is a new survey for the same person" do
    answer!(token(@user, DATE), score: 8)
    answer!(token(@user, DATE + Nps::Config.current.cooldown_days), score: 6)
    assert_equal [ 6, 8 ], NpsResponse.pluck(:score).sort
  end

  test "an older link still inside its lifetime cannot take a second answer within the cooldown, in either order" do
    answer!(token(@user, DATE + 2), score: 8)
    answer!(token(@user, DATE), score: 1, comment: "again")
    assert_select "h1", "Thanks, you already answered"
    answer!(token(@user, DATE + 4), score: 2)
    assert_select "h1", "Thanks, you already answered"
    assert_equal [ 8 ], NpsResponse.pluck(:score), "one answer per cooldown, whichever DM was opened"
    assert_nil NpsResponse.sole.comment

    other = users(:new_user)
    answer!(token(other, DATE), score: 3)
    assert_equal [ 3, 8 ], NpsResponse.pluck(:score).sort, "someone else's answer never counts against this person"
  end

  test "a signed-in person can answer too, and cannot use it to read or change anyone else's answer" do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: users(:new_user).hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    answer!(token(@user), score: 7)
    assert_equal [ @user.id ], NpsResponse.pluck(:user_id), "the answer belongs to the person in the token, not the signed-in person"
  ensure
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  # --- CSRF ---

  test "an answer without the CSRF token is refused when protection is on, and works with it" do
    with_forgery_protection do
      value = token
      post feedback_path(value), params: { nps: { score: 9 } }
      assert_response :unprocessable_content
      assert_equal 0, NpsResponse.count

      get feedback_path(value)
      form_token = css_select("form.nps__form input[name=authenticity_token]").first["value"]
      post feedback_path(value), params: { authenticity_token: form_token, nps: { score: 9 } }
      assert_response :success
      assert_equal 1, NpsResponse.count
    end
  end

  # --- logs ---

  test "the comment is not written to the request log" do
    io = StringIO.new
    old = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(io)
    begin
      answer!(token, score: 3, comment: "UNIQUE-COMMENT-TEXT-987")
    ensure
      ActionController::Base.logger = old
    end
    assert_includes io.string, "Parameters:"
    assert_not_includes io.string, "UNIQUE-COMMENT-TEXT-987"
  end
end
