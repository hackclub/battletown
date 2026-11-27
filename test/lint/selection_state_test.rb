require "test_helper"

# Selection state comes from native inputs, never from a class that JavaScript adds (Armand, 2026-11-27: after going back in
# the browser two options looked selected at once). A single choice is a radio group, a multiple choice is checkboxes, the
# selected look is CSS on :checked, and the text inside a selected option changes color through one rule on the container.
# This fails on JavaScript that adds, toggles or replaces a class whose name says picked, selected, checked, chosen or active.
class SelectionStateTest < ActiveSupport::TestCase
  JAVASCRIPT = Rails.root.join("app/javascript")
  STATE_CLASS = /classList\.(?:add|toggle|replace)\([^)]*["'`][\w-]*(?:picked|selected|checked|chosen|active)[\w-]*["'`]/i

  # The onboarding agent owns this one and is replacing it with :checked CSS; delete the entry when it goes.
  ALLOWED = [
    "controllers/onboarding_step_controller.js"
  ].freeze

  def self.offenders
    Dir[JAVASCRIPT.join("**/*.js")].sort.filter_map do |path|
      relative = path.delete_prefix("#{JAVASCRIPT}/")
      relative if File.read(path).match?(STATE_CLASS)
    end
  end

  test "no JavaScript adds a selected or picked class" do
    assert_empty self.class.offenders - ALLOWED, "Use a radio group or checkboxes and style :checked in CSS."
  end

  test "the allowlist has no stale entries" do
    assert_empty ALLOWED - self.class.offenders
  end
end
