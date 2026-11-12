require "test_helper"
require_relative "../../support/ships_test_support"

class Ships::WithdrawDraftTest < ActiveSupport::TestCase
  include ShipsTestSupport

  test "a draft can be discarded: it becomes withdrawn and its window is free again" do
    user = users(:onboarded)
    user.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    project = make_project(user)
    (7..9).each { |day| code(user, Date.new(2026, 11, day), HOUR) }
    draft = submit_ship(project, submit: false)
    assert_nil draft.submitted_at

    assert Ships::Withdraw.call(ship: draft)
    assert_equal "withdrawn", draft.reload.status
    assert_not_nil draft.submitted_at
    assert_nothing_raised { submit_ship(project) }
  end
end
