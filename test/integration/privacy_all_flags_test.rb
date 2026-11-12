require "test_helper"
require_relative "../support/privacy_helper"
require_relative "../support/every_table_rows"

# The Hack Club deletion service (yeet) with every feature switched on and a person who has rows in every table: the dry run
# and the real run agree, the counts name every table that held something, and nothing about the person is left anywhere.
class PrivacyAllFlagsTest < ActionDispatch::IntegrationTest
  include PrivacyHelper
  include EveryTableRows

  setup do
    install_privacy_jwks
    Features::NAMES.each { |name| Flipper.enable(name) }
    @user = user_with_rows_in_every_table
    @user.update_columns(slack_id: "U0YEETTEST", email: "yeet.person@example.test")
    @bystander = users(:new_user)
  end

  teardown { uninstall_privacy_jwks }

  def call_yeet(dry_run:)
    claims = privacy_claims(dry_run: dry_run, subject: privacy_subject(emails: [ "yeet.person@example.test" ], slack_id: "U0YEETTEST", identity_id: @user.hca_uid))
    privacy_call("delete", privacy_token(claims))
    assert_response :ok
    response.parsed_body
  end

  def tables_with_user_column
    connection = ActiveRecord::Base.connection
    (connection.tables - %w[users]).select { |table| connection.columns(table).any? { |column| column.name == "user_id" } }
  end

  def rows_about(user, table) = ActiveRecord::Base.connection.select_value("SELECT count(*) FROM #{table} WHERE user_id = #{user.id.to_i}").to_i

  test "dry run then real run: same counts, every table that holds the person is named, and nothing is left behind" do
    held = tables_with_user_column.select { |table| rows_about(@user, table).positive? }
    missing = tables_with_user_column - held
    assert_empty missing, "user_with_rows_in_every_table has no row in: #{missing.join(', ')}"

    crew = TeamMembership.find_by!(user_id: @user.id).team
    before_other = rows_about(@bystander, "notifications")

    dry = call_yeet(dry_run: true)
    assert User.exists?(@user.id), "a dry run deletes nothing"
    held.each { |table| assert rows_about(@user, table).positive?, "the dry run kept #{table}" }
    (held + %w[users]).each { |table| assert dry["deleted"].key?(table), "the dry run did not count #{table}" }

    real = call_yeet(dry_run: false)
    assert_equal dry["deleted"], real["deleted"]
    assert_equal dry["retained"], real["retained"]
    assert_not User.exists?(@user.id)
    tables_with_user_column.each { |table| assert_equal 0, rows_about(@user, table), "#{table} still holds the deleted person" }
    assert_not Team.exists?(crew.id), "a crew whose last member was deleted goes too"
    assert_equal before_other, rows_about(@bystander, "notifications"), "someone else's rows are untouched"
  end

  test "the staff audit trail: rows about the person go, rows about their orders stay and are reported, rows they made stay with no actor" do
    order = Order.find_by!(user_id: @user.id)
    about_person = AdminAuditEvent.about("User", @user.id).count
    about_order = AdminAuditEvent.where(subject_type: %w[Order Project]).count # the held order and the flagged project
    by_person = AdminAuditEvent.where(actor_id: @user.id).count
    assert_operator [ about_person, about_order, by_person ].min, :>=, 1

    dry = call_yeet(dry_run: true)
    assert_equal about_person, dry["deleted"]["admin_audit_events"]
    assert_equal [ { "type" => "admin_audit_events", "count" => about_order, "reason" => dry["retained"].first["reason"] } ], dry["retained"]
    assert_match(/ids|amounts/, dry["retained"].first["reason"])

    real = call_yeet(dry_run: false)
    assert_equal dry["deleted"], real["deleted"]
    assert_equal dry["retained"], real["retained"]
    assert_equal 0, AdminAuditEvent.about("User", @user.id).count, "an audit row about the person (with a typed reason) must not outlive them"
    assert_equal about_order, AdminAuditEvent.where(subject_type: %w[Order Project]).count
    assert_equal by_person, AdminAuditEvent.where(actor_id: nil, action: "user_viewed").count
    assert_not_includes AdminAuditEvent.pluck(:metadata).to_json, "Jamie Doe"
  end

  test "a deletion by Slack id alone finds the person and removes the same tables" do
    privacy_call("delete", privacy_token(privacy_claims(subject: privacy_subject(slack_id: "U0YEETTEST"))))
    assert_response :ok
    assert_not User.exists?(@user.id)
    assert_equal 0, ShipImage.where(user_id: @user.id).count
    assert_equal 0, PlinkoPlayer.where(user_id: @user.id).count
  end
end
