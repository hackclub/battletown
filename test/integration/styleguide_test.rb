require "test_helper"

# /dev/styleguide: every token and shared component on one page. Development only; a 404 everywhere else, signed in or
# not (same answer as an unknown path), like the other dev pages.
class StyleguideTest < ActionDispatch::IntegrationTest
  def in_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  setup do
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
  end

  teardown { Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed }

  test "404 in test and production, with no hint the page exists" do
    get "/dev/styleguide"
    assert_response :not_found

    %w[test production].each do |env|
      in_env(env) do
        get "/dev/styleguide"
        assert_response :not_found, env
      end
    end
  end

  test "development shows it without logging in, with every component and a passing contrast table" do
    in_env("development") { get "/dev/styleguide" }
    assert_response :success
    assert_select "h1", "Battletown style guide"
    assert_select ".dev-only", minimum: 1
    %w[.btn--primary .btn--cta .btn--danger .btn--ghost .field__error .toggle__input .card--chunky .panel .band--map .badge--success
       .progress--boss .progress--goal .progress--prize progress.progress__bar .table .alert--danger .flash--notice .empty
       .site-menu .list].each do |selector|
      assert_select selector, minimum: 1, message: "missing #{selector}"
    end
    assert_select "ul.sg-swatches li.sg-swatch", DesignSystem::Tokens.colors.size
    assert_select "#colours td .badge--danger", 0, "a contrast pair fails"
    assert_select "#colours td .badge--success", DesignSystem::Contrast::PAIRS.size
  end

  test "the page uses no inline style or script, so the CSP keeps working" do
    in_env("development") { get "/dev/styleguide" }
    assert_select "[style]", 0
    assert_select "script:not([src]):not([nonce])", 0
    assert_no_match(/\son[a-z]+=/, response.body)
  end
end
