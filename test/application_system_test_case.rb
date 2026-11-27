require "test_helper"

# Browser tests: `bin/rails test:system` (the CI `system-test` job). Not part of `bin/rails test`. They need Chrome
# and chromedriver, which GitHub's ubuntu-latest runners ship; locally install Chrome or Chromium.

# Capybara 3.40.0 (the latest release) resets a Chrome session with `Storage.clearDataForOrigin` for origin "*".
# Chrome 158 (on GitHub's runners since 2026-11-26) rejects that: "invalid argument: * is not a valid URL".
# Clear the cookies and local storage of the current page's origin instead. Drop this once Capybara ships a fix.
module ChromeResetWithoutWildcardOrigin
  def execute_cdp(cmd, params = {})
    return super unless cmd == "Storage.clearDataForOrigin" && params[:origin] == "*"

    super("Network.clearBrowserCookies")
  end
end
Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeResetWithoutWildcardOrigin)

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
end
