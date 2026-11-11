require "test_helper"

class StaffHelperTest < ActionView::TestCase
  # Stand-ins for the ApplicationController view helpers.
  attr_accessor :current_user

  def signed_in?
    current_user.present?
  end

  def with_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  test "dev_tool renders only in development, with the dev-only class and screen reader text" do
    with_env("development") do
      html = dev_tool(:section, class: "extra") { "Seed data" }
      assert_dom_equal %(<section class="dev-only extra"><span class="visually-hidden">Dev only: </span>Seed data</section>), html
    end
  end

  test "dev_tool renders nothing in test and production" do
    %w[test production].each do |env|
      with_env(env) { assert_nil dev_tool { "Seed data" }, env }
    end
  end

  test "dev_tool can drop the tag when the content already says it" do
    with_env("development") do
      html = dev_tool(label: false) { "Dev login" }
      assert_dom_equal %(<div class="dev-only dev-only--unlabelled">Dev login</div>), html
    end
  end

  test "admin_tool renders nothing for signed-out visitors" do
    self.current_user = nil
    assert_nil admin_tool { "Ban hammer" }
  end

  test "admin_tool renders nothing for an ordinary user" do
    self.current_user = users(:onboarded)
    assert_not current_user.admin?
    assert_nil admin_tool { "Ban hammer" }
  end

  test "admin_tool renders the orange block for an admin" do
    admin = users(:onboarded)
    admin.define_singleton_method(:admin?) { true }
    self.current_user = admin
    assert_dom_equal %(<div class="admin-only"><span class="visually-hidden">Admin only: </span>Ban hammer</div>), admin_tool { "Ban hammer" }
  end

  test "nobody is an admin until the project defines how admins are identified" do
    assert User.all.none?(&:admin?)
  end
end
