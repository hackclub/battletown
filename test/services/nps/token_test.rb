require "test_helper"

# The survey link's token: signed, purpose-scoped, expiring, and carrying nothing personal.
class Nps::TokenTest < ActiveSupport::TestCase
  DATE = Date.new(2026, 11, 12)

  setup do
    @user = users(:onboarded)
    @now = Time.utc(2026, 11, 12, 12)
  end

  def token(now: @now) = Nps::Token.generate(@user, DATE, now: now)

  test "a fresh token parses back to the person and the window" do
    claims = Nps::Token.parse(token(now: Time.current))
    assert_equal [ @user.id, DATE ], [ claims.user_id, claims.window_date ]
  end

  test "it is URL-safe and matches the route format" do
    assert_match(/\A#{Nps::Token::PATH_FORMAT}\z/, token)
  end

  test "it carries only a user id and a date, never a name, email or Slack id" do
    decoded = Base64.urlsafe_decode64(token.split("--").first.then { |part| part + "=" * (-part.length % 4) })
    assert_not_includes decoded, @user.email.to_s if @user.email
    assert_not_includes decoded, @user.slack_id.to_s if @user.slack_id
    assert_not_includes decoded, @user.display_name.to_s if @user.display_name
  end

  test "it expires after nps.token_ttl_days" do
    ttl = Nps::Config.current.token_ttl
    issued = Time.current - ttl + 1.minute
    assert Nps::Token.parse(token(now: issued)), "still good a minute before the end"
    assert_nil Nps::Token.parse(token(now: Time.current - ttl - 1.minute)), "refused a minute after the end"
  end

  test "a changed token is refused, wherever it was changed" do
    valid = token(now: Time.current)
    flipped = valid.dup
    flipped[5] = flipped[5] == "A" ? "B" : "A"
    [ flipped, valid[0..-2] + (valid[-1] == "a" ? "b" : "a"), "x" + valid, valid + "x", valid.sub("--", "-"), "", "garbage", "a" * 60 ].each do |bad|
      assert_nil Nps::Token.parse(bad), bad
    end
  end

  test "a token for another user or window cannot be built by editing the payload" do
    payload, digest = token(now: Time.current).split("--")
    forged = Base64.urlsafe_encode64(Base64.urlsafe_decode64(payload + "=" * (-payload.length % 4)).sub(@user.id.to_s, (@user.id + 1).to_s), padding: false)
    assert_nil Nps::Token.parse("#{forged}--#{digest}")
  end

  test "a token signed with another key or for another purpose is refused" do
    other_key = ActiveSupport::MessageVerifier.new("another secret key", digest: "SHA256", serializer: JSON, url_safe: true)
    claims = { "u" => @user.id, "w" => DATE.iso8601 }
    assert_nil Nps::Token.parse(other_key.generate(claims, purpose: Nps::Token::PURPOSE, expires_in: 1.day))

    own_key = ActiveSupport::MessageVerifier.new(Rails.application.key_generator.generate_key(Nps::Token::SALT), digest: "SHA256", serializer: JSON, url_safe: true)
    assert_nil Nps::Token.parse(own_key.generate(claims, purpose: "something_else", expires_in: 1.day))
    assert_nil Nps::Token.parse(own_key.generate(claims, expires_in: 1.day)), "no purpose at all"
    assert Nps::Token.parse(own_key.generate(claims, purpose: Nps::Token::PURPOSE, expires_in: 1.day)), "positive control: the right purpose works"
  end

  test "payloads of the wrong shape are refused" do
    own_key = ActiveSupport::MessageVerifier.new(Rails.application.key_generator.generate_key(Nps::Token::SALT), digest: "SHA256", serializer: JSON, url_safe: true)
    [ { "u" => "1", "w" => DATE.iso8601 }, { "u" => @user.id, "w" => "not a date" }, { "u" => @user.id }, [ 1, 2 ], "text" ].each do |payload|
      assert_nil Nps::Token.parse(own_key.generate(payload, purpose: Nps::Token::PURPOSE, expires_in: 1.day)), payload.inspect
    end
  end

  test "non-strings are refused without raising" do
    [ nil, 5, [], {}, "a" * 1000 ].each { |value| assert_nil Nps::Token.parse(value) }
  end
end
