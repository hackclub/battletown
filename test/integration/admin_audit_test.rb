require "test_helper"
require_relative "../support/admin_sign_in"

class AdminAuditTest < ActionDispatch::IntegrationTest
  include AdminSignIn

  setup do
    @staff = users(:onboarded)
    @other_staff = users(:new_user)
    @subject = User.create!(hca_uid: "ident!audit-subject", display_name: "Audit Subject")
  end

  def event(action: "user_viewed", actor: @staff, at: Time.current, subject: @subject, metadata: {})
    AdminAudit.record!(actor: actor, action: action, subject: subject, metadata: metadata).tap { |row| row.class.connection.execute("UPDATE admin_audit_events SET created_at = '#{at.utc.iso8601}' WHERE id = #{row.id}") }
  end

  test "signed-out visitors and non-admins get a 404" do
    get admin_audit_path
    assert_response :not_found
    sign_in_as @staff
    get admin_audit_path
    assert_response :not_found
  end

  test "an admin sees the events newest first, with ids and amounts but no names or emails" do
    event(action: "coins_adjusted", at: Time.utc(2026, 11, 10, 9), metadata: { amount: -20, reason: "Duplicate purchase refund" })
    event(action: "user_viewed", at: Time.utc(2026, 11, 11, 9))
    as_admin(@staff)
    get admin_audit_path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".admin-only"
    assert_select "tbody tr", 2
    assert_select "tbody tr:first-child th", "User viewed"
    assert_select "tbody tr:last-child td", /amount: -20, reason: Duplicate purchase refund/
    assert_select "tbody a[href=?]", "/admin/users/#{@subject.id}"
    assert_not_includes response.body, "Audit Subject"
    assert_not_includes response.body, @staff.email
    assert_includes response.body, @staff.display_name
  end

  test "a deleted staff member shows as a former staff member and a subject that is not a user is not linked" do
    event(actor: @other_staff, subject: [ "ShopItem", @subject.id ])
    as_admin(@staff)
    @other_staff.update_columns(hca_uid: "ident!gone")
    User.where(id: @other_staff.id).delete_all
    get admin_audit_path
    assert_select "tbody td", "Former staff member"
    assert_select "tbody a", 0
    assert_select "tbody td", /ShopItem ##{@subject.id}/
  end

  test "filters by action, staff member and date, and ignores junk filters" do
    event(action: "user_viewed", actor: @staff, at: Time.utc(2026, 11, 1, 12))
    event(action: "coins_adjusted", actor: @staff, at: Time.utc(2026, 11, 5, 12))
    event(action: "coins_adjusted", actor: @other_staff, at: Time.utc(2026, 11, 9, 12))
    as_admin(@staff)

    get admin_audit_path(event: "coins_adjusted")
    assert_select "tbody tr", 2
    get admin_audit_path(event: "coins_adjusted", actor_id: @other_staff.id)
    assert_select "tbody tr", 1
    get admin_audit_path(from: "2026-11-02", to: "2026-11-06")
    assert_select "tbody tr", 1
    get admin_audit_path(from: "2026-11-05", to: "2026-11-05")
    assert_select "tbody tr", 1, "the end date is a whole day"
    get admin_audit_path(from: "2026-12-01")
    assert_select "tbody tr", 0
    assert_select ".alert", "No events match."

    [ "'; DROP TABLE users; --", "x" * 5000, "../../etc", "%00" ].each do |junk|
      get admin_audit_path(event: junk, actor_id: junk, from: junk, to: junk, page: junk)
      assert_response :success
      assert_select "tbody tr", 3, "junk filters mean no filter"
    end
    assert User.exists?
  end

  test "paginates 50 at a time and clamps the page" do
    60.times { |i| event(at: Time.utc(2026, 11, 1) + i.minutes) }
    as_admin(@staff)
    get admin_audit_path
    assert_select "tbody tr", 50
    assert_select "#audit-count", "60"
    assert_select "nav.admin-pager", /Page 1 of 2/
    assert_select "nav.admin-pager a[rel=next][href=?]", "/admin/audit?page=2"
    get admin_audit_path(page: 2)
    assert_select "tbody tr", 10
    assert_select "nav.admin-pager a[rel=prev]"
    [ 0, -3, 999_999_999_999, "abc" ].each do |page|
      get admin_audit_path(page: page)
      assert_response :success
    end
    get admin_audit_path(page: 999)
    assert_select "nav.admin-pager", /Page 2 of 2/
  end

  test "it is linked from the admin dashboard under People" do
    as_admin(@staff)
    get admin_root_path
    assert_select "h2", "People"
    assert_select "a[href=?]", admin_audit_path
  end

  test "looking at the page leaves no trace and cannot change a row" do
    event
    as_admin(@staff)
    assert_no_difference -> { AdminAuditEvent.count } do
      get admin_audit_path
    end
    patch "/admin/audit", params: { id: 1 }
    assert_response :not_found
    delete "/admin/audit"
    assert_response :not_found
  end
end
