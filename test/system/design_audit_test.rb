require "application_system_test_case"

# Runs the design-fundamentals DOM walker (test/support/design_audit.js, rules in .claude/skills/verify/ui-brief.md) in a real
# browser on the pages anyone can open: concentric corners, even insets, 44px targets, orphaned last rows, half-hanging badges.
# The same file runs in headless Firefox through .claude/skills/verify/audit.py, which also covers the signed-in pages. This
# test could not be run where it was written (no Chrome there), so if it fails in CI, read the finding: the selector, what was
# measured and what was expected are in the message.
class DesignAuditSystemTest < ApplicationSystemTestCase
  WALKER = Rails.root.join("test/support/design_audit.js").read
  RULES = %w[concentric even-inset targets orphan badge].freeze
  PAGES = { "the landing page" => "/", "the privacy page" => "/privacy", "the terms page" => "/terms" }.freeze

  PAGES.each do |name, path|
    [ [ 1781, 1150 ], [ 390, 844 ] ].each do |width, height|
      test "#{name} at #{width}px has no design-fundamentals violations" do
        page.driver.browser.manage.window.resize_to(width, height)
        visit path
        page.execute_script("document.querySelectorAll('img').forEach(i => { i.loading = 'eager' })")
        page.execute_script("for (let y = 0; y < document.documentElement.scrollHeight; y += 600) window.scrollTo(0, y); window.scrollTo(0, 0)")
        findings = page.evaluate_script("(#{WALKER})({ skip: [] })").select { |f| RULES.include?(f["rule"]) }
        assert_empty findings.map { |f| "#{f['rule']}: #{f['selector']} measured #{f['measured']}, expected #{f['expected']}" }
      end
    end
  end
end
