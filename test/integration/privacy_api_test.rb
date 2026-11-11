require "test_helper"
require_relative "../support/privacy_helper"

class PrivacyApiTest < ActionDispatch::IntegrationTest
  include PrivacyHelper

  setup do
    install_privacy_jwks
    @user = users(:onboarded)
    @user.update_columns(slack_id: "U0TESTSLACK", email: "Done@Example.com")
    @other = users(:new_user)
  end

  teardown { uninstall_privacy_jwks }

  def subject_for(**attrs) = privacy_subject(emails: [ "done@example.com" ], **attrs)

  def delete_with(**overrides)
    privacy_call("delete", privacy_token(privacy_claims({ subject: subject_for }.merge(overrides))))
  end

  def add_notifications(user, count)
    count.times do |i|
      Notification.create!(user: user, kind: "daily_reminder", status: "sent", scheduled_for: Time.current, due_at: Time.current,
                           idempotency_key: "k-#{user.id}-#{i}-#{SecureRandom.hex(3)}")
    end
  end

  test "a valid delete removes the person and reports counts only" do
    add_notifications(@user, 2)
    delete_with(request_id: "req-123")

    assert_response :ok
    assert_equal "application/json", response.media_type
    body = response.parsed_body
    assert_equal({ "request_id" => "req-123", "dry_run" => false, "found" => true, "deleted" => { "notifications" => 2, "users" => 1 }, "retained" => [] }, body)
    assert_not User.exists?(@user.id)
    assert User.exists?(@other.id)
    assert_equal 0, Notification.where(user_id: @user.id).count
  end

  test "a dry run deletes nothing and its counts equal the later real run" do
    add_notifications(@user, 3)

    delete_with(dry_run: true, request_id: "req-dry")
    assert_response :ok
    dry = response.parsed_body
    assert_equal true, dry["dry_run"]
    assert_equal "req-dry", dry["request_id"]
    assert User.exists?(@user.id)
    assert_equal 3, Notification.where(user_id: @user.id).count

    delete_with(dry_run: false)
    assert_response :ok
    assert_equal dry["deleted"], response.parsed_body["deleted"]
    assert_equal dry["retained"], response.parsed_body["retained"]
    assert_not User.exists?(@user.id)
  end

  test "export changes nothing, even when the token says dry_run false" do
    add_notifications(@user, 1)
    before = [ User.count, Notification.count ]

    privacy_call("export", privacy_token(privacy_claims(action: "export", dry_run: false, subject: subject_for)))

    assert_response :ok
    assert_equal({ "notifications" => 1, "users" => 1 }, response.parsed_body["deleted"])
    assert_equal false, response.parsed_body["dry_run"]
    assert_equal true, response.parsed_body["found"]
    assert_equal before, [ User.count, Notification.count ]
    assert_equal "Done@Example.com", @user.reload.email
  end

  test "an unknown subject is a 200 with found false" do
    delete_with(subject: privacy_subject(emails: [ "nobody@example.com" ], slack_id: "U0NOBODY", identity_id: "ident!nobody"))

    assert_response :ok
    assert_equal({ "request_id" => response.parsed_body["request_id"], "dry_run" => false, "found" => false, "deleted" => {}, "retained" => [] }, response.parsed_body)
    assert_equal 2, User.where(id: [ @user.id, @other.id ]).count
  end

  test "an empty subject finds nobody" do
    delete_with(subject: privacy_subject)
    assert_response :ok
    assert_equal false, response.parsed_body["found"]
    assert_equal 2, User.where(id: [ @user.id, @other.id ]).count
  end

  test "the person is matched by email, case-insensitively, among several emails" do
    delete_with(subject: privacy_subject(emails: [ "someone@else.example", "DONE@EXAMPLE.COM" ]))
    assert_equal true, response.parsed_body["found"]
    assert_not User.exists?(@user.id)
  end

  test "the person is matched by Slack id alone" do
    delete_with(subject: privacy_subject(slack_id: "U0TESTSLACK"))
    assert_equal true, response.parsed_body["found"]
    assert_not User.exists?(@user.id)
    assert User.exists?(@other.id)
  end

  test "the person is matched by identity id alone" do
    delete_with(subject: privacy_subject(identity_id: @user.hca_uid))
    assert_equal true, response.parsed_body["found"]
    assert_not User.exists?(@user.id)
    assert User.exists?(@other.id)
  end

  test "an identity id is not matched against anything but hca_uid" do
    delete_with(subject: privacy_subject(identity_id: "Done@Example.com"))
    assert_equal false, response.parsed_body["found"]
  end

  test "one subject matching two users deletes both" do
    delete_with(subject: privacy_subject(emails: [ "done@example.com", @other.email ]))
    assert_equal({ "users" => 2 }, response.parsed_body["deleted"])
    assert_not User.exists?(@user.id)
    assert_not User.exists?(@other.id)
  end

  test "only the token claims identify the person: body and query parameters are ignored" do
    token = privacy_token(privacy_claims(subject: privacy_subject(emails: [ "nobody@example.com" ])))
    post "/api/privacy/delete?email=#{CGI.escape(@user.email)}&slack_id=#{@user.slack_id}&identity_id=#{CGI.escape(@user.hca_uid)}",
         headers: privacy_headers(token), params: { emails: [ @user.email ], slack_id: @user.slack_id, identity_id: @user.hca_uid }

    assert_response :ok
    assert_equal false, response.parsed_body["found"]
    assert User.exists?(@user.id)
  end

  test "responses contain no email, Slack id or identity id" do
    delete_with(request_id: "req-x")
    assert_not_includes response.body, "example.com"
    assert_not_includes response.body, "U0TESTSLACK"
    assert_not_includes response.body, "ident!"
  end

  test "responses are not cacheable and set no cookie" do
    delete_with
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil response.headers["Set-Cookie"]

    privacy_call("delete", "garbage")
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil response.headers["Set-Cookie"]
  end

  test "the controller does not use the application's session, login or CSRF behaviour" do
    assert_not_includes Api::PrivacyController.ancestors, ApplicationController
    assert_not_includes Api::PrivacyController.ancestors, ActionController::RequestForgeryProtection
    assert_not Api::PrivacyController.method_defined?(:current_user)
  end

  test "a signed-in browser session is neither used nor touched" do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: @other.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    assert_not_nil response.headers["Set-Cookie"].presence || cookies["_battletown_session"].presence || cookies.to_hash.presence

    delete_with
    assert_response :ok
    assert_nil response.headers["Set-Cookie"]
    assert User.exists?(@other.id)
  ensure
    OmniAuth.config.test_mode = false
  end

  # ---- rejected tokens

  def assert_invalid_token
    assert_response :unauthorized
    assert_equal({ "error" => "invalid_token" }, response.parsed_body)
    assert_equal 2, User.where(id: [ @user.id, @other.id ]).count
    assert_equal 0, PrivacyRequestToken.count
  end

  test "a missing Authorization header is rejected" do
    post "/api/privacy/delete", headers: { "Accept" => "application/json" }
    assert_invalid_token
  end

  test "a wrong scheme, an empty bearer and malformed tokens are rejected" do
    [ "Basic abc", "Bearer ", "Bearer", "Bearer not-a-jwt", "Bearer a.b.c", "Bearer a.b", "Bearer ....", "Bearer #{"a" * 5000}" ].each do |value|
      post "/api/privacy/delete", headers: { "Authorization" => value, "Accept" => "application/json" }
      assert_invalid_token
    end
  end

  test "tokens signed with other algorithms are rejected" do
    claims = privacy_claims(subject: subject_for)
    delete_with_token = ->(token) { privacy_call("delete", token) }

    delete_with_token.call(JWT.encode(claims, "a-shared-secret", "HS256", { kid: PrivacyHelper::KID, typ: "JWT" }))
    assert_invalid_token

    delete_with_token.call(JWT.encode(claims, nil, "none", { kid: PrivacyHelper::KID, typ: "JWT" }))
    assert_invalid_token

    delete_with_token.call(JWT.encode(claims, OpenSSL::PKey::RSA.generate(2048), "RS256", { kid: PrivacyHelper::KID, typ: "JWT" }))
    assert_invalid_token

    # HS256 keyed with the public key's coordinates must not work either (algorithm confusion).
    delete_with_token.call(JWT.encode(claims, PrivacyHelper::KEY.public_to_der, "HS256", { kid: PrivacyHelper::KID, typ: "JWT" }))
    assert_invalid_token
  end

  test "a wrong typ, or a missing kid, is rejected" do
    claims = privacy_claims(subject: subject_for)
    privacy_call("delete", privacy_token(claims, header: { typ: "at+jwt" }))
    assert_invalid_token

    privacy_call("delete", JWT.encode(claims, PrivacyHelper::KEY, "ES256", { typ: "JWT" }))
    assert_invalid_token
  end

  test "an unknown kid is rejected" do
    privacy_call("delete", privacy_token(privacy_claims(subject: subject_for), header: { kid: "nobody-knows-me" }))
    assert_invalid_token
  end

  test "a bad signature is rejected" do
    privacy_call("delete", privacy_token(privacy_claims(subject: subject_for), key: OpenSSL::PKey::EC.generate("prime256v1")))
    assert_invalid_token

    token = privacy_token(privacy_claims(subject: subject_for))
    header, payload, signature = token.split(".")
    tampered = Base64.urlsafe_encode64({ **JSON.parse(Base64.urlsafe_decode64(payload)), "subject" => { "emails" => [ @other.email ] } }.to_json, padding: false)
    privacy_call("delete", [ header, tampered, signature ].join("."))
    assert_invalid_token
  end

  {
    "wrong issuer" => { iss: "someone-else" },
    "wrong audience" => { aud: "flavortown" },
    "an audience list" => { aud: [ "battletown" ] },
    "expired" => -> { { iat: Time.now.to_i - 400, exp: Time.now.to_i - 100 } },
    "issued in the future" => -> { { iat: Time.now.to_i + 120, exp: Time.now.to_i + 200 } },
    "lifetime over 5 minutes" => -> { { iat: Time.now.to_i, exp: Time.now.to_i + 301 } },
    "no expiry" => { exp: nil },
    "fractional expiry" => -> { { exp: Time.now.to_f + 100 } },
    "no jti" => { jti: nil },
    "empty jti" => { jti: "" },
    "no request id" => { request_id: nil },
    "request id with a newline" => { request_id: "a\nprivacy outcome=ok" },
    "unknown action" => { action: "purge" },
    "no dry_run" => { dry_run: nil },
    "dry_run as a string" => { dry_run: "false" },
    "subject not an object" => { subject: "done@example.com" },
    "emails not a list" => { subject: { emails: "done@example.com" } }
  }.each do |name, overrides|
    test "a token with #{name} is rejected" do
      overrides = instance_exec(&overrides) if overrides.respond_to?(:call)
      privacy_call("delete", privacy_token(privacy_claims({ subject: subject_for }.merge(overrides))))
      assert_invalid_token
    end
  end

  test "a few seconds of clock skew is tolerated" do
    delete_with(iat: Time.now.to_i - 280, exp: Time.now.to_i - 10)
    assert_response :ok

    delete_with(iat: Time.now.to_i + 10, exp: Time.now.to_i + 200)
    assert_response :ok
  end

  test "the action must match the endpoint" do
    privacy_call("export", privacy_token(privacy_claims(action: "delete", subject: subject_for)))
    assert_response :bad_request
    assert_equal({ "error" => "action_mismatch" }, response.parsed_body)

    privacy_call("delete", privacy_token(privacy_claims(action: "export", subject: subject_for)))
    assert_response :bad_request
    assert User.exists?(@user.id)
  end

  test "a token can be used once, a dry run included" do
    token = privacy_token(privacy_claims(jti: "jti-once", dry_run: true, subject: subject_for))
    privacy_call("delete", token)
    assert_response :ok

    privacy_call("delete", token)
    assert_response :conflict
    assert_equal({ "error" => "replayed" }, response.parsed_body)

    # Even as a non-dry-run delete the same jti is refused: the new token only differs in its dry_run claim.
    privacy_call("delete", privacy_token(privacy_claims(jti: "jti-once", dry_run: false, subject: subject_for)))
    assert_response :conflict
    assert User.exists?(@user.id)
  end

  test "a rejected token leaves no jti behind" do
    privacy_call("delete", privacy_token(privacy_claims(jti: "jti-bad", aud: "nope")))
    assert_response :unauthorized
    assert_not PrivacyRequestToken.exists?(jti: "jti-bad")

    privacy_call("export", privacy_token(privacy_claims(jti: "jti-mismatch", action: "delete")))
    assert_response :bad_request
    assert_not PrivacyRequestToken.exists?(jti: "jti-mismatch")
  end

  test "an unreachable key server is a 503 and nothing is deleted" do
    privacy_fetcher.fails = true
    delete_with
    assert_response :service_unavailable
    assert_equal({ "error" => "jwks_unavailable" }, response.parsed_body)
    assert User.exists?(@user.id)
    assert_equal 0, PrivacyRequestToken.count
  end

  test "an unreadable key set is a 503" do
    Privacy::Jwks.current = Privacy::Jwks.new(fetcher: ->(_url) { "<html>maintenance</html>" })
    delete_with
    assert_response :service_unavailable
    assert User.exists?(@user.id)
  end

  test "a database failure is a 503" do
    stub_method(PrivacyRequestToken, :consume!, ->(_claims) { raise ActiveRecord::ConnectionNotEstablished, "down" }) do
      delete_with
    end
    assert_response :service_unavailable
    assert_equal({ "error" => "database_unavailable" }, response.parsed_body)
    assert User.exists?(@user.id)
  end

  test "an unexpected failure is a plain 500 that leaks nothing" do
    boom = Object.new
    boom.define_singleton_method(:call) { |**| raise "exploded for done@example.com" }
    stub_method(Privacy::Deleter, :new, ->(_subject) { boom }) do
      delete_with
    end
    assert_response :internal_server_error
    assert_equal({ "error" => "internal_error" }, response.parsed_body)
    assert_not_includes response.body, "example.com"
  end

  test "other verbs and paths answer in JSON" do
    get "/api/privacy/delete"
    assert_response :method_not_allowed
    assert_equal "POST", response.headers["Allow"]
    assert_equal({ "error" => "method_not_allowed" }, response.parsed_body)

    delete "/api/privacy/export"
    assert_response :method_not_allowed

    get "/api/privacy/other"
    assert_response :not_found
    assert_equal({ "error" => "not_found" }, response.parsed_body)

    post "/api/privacy/delete.json", headers: privacy_headers(privacy_token)
    assert_response :not_found
  end

  # ---- logging

  test "the log has the request id and outcome but no token, email, Slack id or identity id" do
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io, level: :debug)
    old = [ Rails.logger, ActionController::API.logger, ActiveRecord::Base.logger ]
    Rails.logger = ActionController::API.logger = ActiveRecord::Base.logger = logger
    token = privacy_token(privacy_claims(request_id: "req-log-1", subject: subject_for(slack_id: "U0TESTSLACK", identity_id: @user.hca_uid)))
    begin
      post "/api/privacy/delete?email=done@example.com", headers: privacy_headers(token)
      privacy_call("delete", "bogus.token.value")
    ensure
      Rails.logger, ActionController::API.logger, ActiveRecord::Base.logger = old
    end

    log = io.string
    assert_includes log, "privacy request_id=req-log-1 action=delete outcome=ok"
    assert_includes log, "privacy action=delete outcome=invalid_token"
    [ token, token.split(".").first, token.split(".")[1], token.split(".").last, "bogus.token.value", "done@example.com", "Done@Example.com",
      "U0TESTSLACK", @user.hca_uid, "Bearer" ].each do |secret|
      assert_not_includes log, secret
    end
  end

  # ---- housekeeping

  test "using a token records only the jti, request id, action and dry_run, and purges old rows" do
    old = PrivacyRequestToken.create!(jti: "ancient", created_at: 8.days.ago)
    recent = PrivacyRequestToken.create!(jti: "recent", created_at: 6.days.ago)

    delete_with(jti: "jti-new", request_id: "req-new", dry_run: true)

    row = PrivacyRequestToken.find_by!(jti: "jti-new")
    assert_equal [ "req-new", "delete", true ], [ row.request_id, row.action, row.dry_run ]
    assert_not PrivacyRequestToken.exists?(old.id)
    assert PrivacyRequestToken.exists?(recent.id)
    assert_equal %w[action created_at dry_run id jti request_id], PrivacyRequestToken.column_names.sort
  end
end

class PrivacyApiThrottleTest < ActionDispatch::IntegrationTest
  include PrivacyHelper

  WINDOW_START = Time.utc(2030, 1, 1, 12, 0, 0)

  setup do
    travel_to WINDOW_START
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    install_privacy_jwks
  end

  teardown do
    uninstall_privacy_jwks
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
    travel_back
  end

  test "the service's normal calls are not throttled, even once the general per-IP limit is used up" do
    300.times { get "/privacy", headers: { "REMOTE_ADDR" => "203.0.113.50" } }
    get "/privacy", headers: { "REMOTE_ADDR" => "203.0.113.50" }
    assert_response :too_many_requests

    3.times do
      post "/api/privacy/delete", headers: privacy_headers(privacy_token(privacy_claims)).merge("REMOTE_ADDR" => "203.0.113.50")
      assert_response :ok
    end
  end

  test "a flood on /api/privacy is limited to 120 a minute per IP" do
    120.times { post "/api/privacy/delete", headers: { "REMOTE_ADDR" => "203.0.113.51" } }
    assert_response :unauthorized
    post "/api/privacy/delete", headers: { "REMOTE_ADDR" => "203.0.113.51" }
    assert_response :too_many_requests
    post "/api/privacy/delete", headers: { "REMOTE_ADDR" => "203.0.113.52" }
    assert_response :unauthorized
  end
end
