require "test_helper"

class AccountExportTest < ActiveSupport::TestCase
  def export_for(user) = JSON.parse(AccountExport.new(user).to_json)

  test "contains the person's own stored data" do
    user = users(:onboarded)
    profile = export_for(user).dig("data", "profile")

    assert_equal user.hca_uid, profile["hca_uid"]
    assert_equal "done@example.com", profile["email"]
    assert_equal "Veteran", profile["display_name"]
    assert_equal "tshirt", profile["prize_key"]
    assert_equal "UTC", profile["time_zone"]
    assert_equal %w[monday wednesday], profile["coding_day_names"]
    assert_equal "2026-11-10T12:00:00Z", profile["onboarded_at"]
  end

  test "leaves out the internal id" do
    assert_not_includes export_for(users(:onboarded)).dig("data", "profile").keys, "id"
  end

  test "contains nothing about any other user" do
    json = AccountExport.new(users(:onboarded)).to_json

    assert_not_includes json, users(:new_user).email
    assert_not_includes json, users(:new_user).display_name
    assert_not_includes json, users(:new_user).hca_uid
  end

  test "never has phone, birthdate or address keys, at any depth" do
    keys = collect_keys(export_for(users(:onboarded)))

    assert_empty keys & AccountData::NEVER_EXPORT
  end

  test "says how it was made and what is not stored" do
    meta = export_for(users(:onboarded))["battletown_data_export"]

    assert_equal AccountExport::FORMAT_VERSION, meta["format_version"]
    assert_match(/not stored/, meta["about"])
  end

  private

  def collect_keys(node)
    case node
    when Hash then node.keys + node.values.flat_map { |v| collect_keys(v) }
    when Array then node.flat_map { |v| collect_keys(v) }
    else []
    end
  end
end
