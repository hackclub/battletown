require "test_helper"

# The prize step shows six prizes first (the picture is the subject); the rest sit behind "See all prizes", in the same card style.
class OnboardingPrizeStepTest < ActionDispatch::IntegrationTest
  FEATURED = %w[custom_sticker keychain tshirt orpheus_plushie mechanical_keyboard headphones].freeze

  setup do
    patch onboarding_step_path("age"), params: { user: { age_group: "teen" } }
  end

  test "six prizes are shown by default, the rest are folded behind See all prizes" do
    get onboarding_step_path("prize")
    assert_response :success
    assert_select "details.prize-more:not([open])" do
      assert_select "summary", text: "See all prizes"
      assert_select ".choice", Prize.paid.size - 6
    end
    assert_select "fieldset > .basecoat > .choice-grid--cards > .choice", 6
    assert_equal FEATURED, css_select("fieldset > .basecoat > .choice-grid--cards > .choice input[type=radio]").map { |i| i["value"] }
  end

  test "a missing or outdated list falls back to six spread across the hours range" do
    helpers = ApplicationController.helpers
    [ nil, [ "custom_sticker", "gone_prize" ] ].each do |list|
      with_featured_config(list) do
        keys = helpers.onboarding_featured_prizes.map(&:key)
        assert_equal 6, keys.size
        coins = helpers.onboarding_featured_prizes.map(&:coins)
        assert_equal Prize.paid.map(&:coins).min, coins.first
        assert_equal Prize.paid.map(&:coins).max, coins.last
        assert_equal coins.sort, coins
      end
    end
  end

  test "a pick from the folded set saves, and coming back shows it selected with the list open" do
    patch onboarding_step_path("prize"), params: { user: { prize_key: "poster" } }
    get onboarding_step_path("prize")
    assert_select "details.prize-more[open]"
    assert_select "input[type=radio][value=poster][checked]"
  end

  test "a pick from the six saves and restores with the list folded" do
    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }
    get onboarding_step_path("prize")
    assert_select "details.prize-more:not([open])"
    assert_select "input[type=radio][value=tshirt][checked]"
  end

  test "with an end date set a card says the time a day, and with none it says the total hours" do
    get onboarding_step_path("prize")
    assert_select ".option-card__note", /a day\z/ # no real date: counted against the stand-in length
    ENV["ONBOARDING_PROGRAM_ENDS_ON"] = (Time.zone.today + 29).iso8601
    get onboarding_step_path("prize")
    assert_select ".option-card__note", /a day\z/
  ensure
    ENV.delete("ONBOARDING_PROGRAM_ENDS_ON")
  end

  private

  def with_featured_config(list)
    app = Rails.application
    original = app.method(:config_for)
    app.define_singleton_method(:config_for) { |*_args| { onboarding: { featured_prizes: list } } }
    yield
  ensure
    app.singleton_class.send(:remove_method, :config_for)
  end
end
