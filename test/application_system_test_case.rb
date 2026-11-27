require "test_helper"

# Browser tests: `bin/rails test:system` (the CI `system-test` job). Not part of `bin/rails test`. They need Chrome
# and chromedriver, which GitHub's ubuntu-latest runners ship; locally install Chrome or Chromium.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
end
