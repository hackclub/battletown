require "test_helper"
require_relative "../support/bosses_helper"

class BossCardTest < ActionView::TestCase
  include BossesHelper

  MONDAY = Date.new(2026, 11, 16)

  setup do
    @user = users(:onboarded)
    @other = users(:new_user)
    @other.update!(display_name: "Zed Zebra-Person", email: "zed.person@example.com", slack_id: "U0ZEDSLACK")
    @boss = make_boss(name: "Boss 1")
  end

  def card(**options)
    render partial: "bosses/card", locals: { presenter: Bosses::Presenter.new(user: @user, today: MONDAY, **options) }
    rendered
  end

  test "in progress: a labelled native progress with the text alternative and same-origin art with alt text" do
    add_hours(@other, FRIDAY, 310 * HOUR)
    card

    assert_select "section.boss-card--in-progress[aria-labelledby='boss-card-title'] h2#boss-card-title", "Boss 1"
    assert_select "label[for='boss-card-health']", "Boss health"
    assert_select "progress#boss-card-health[max='100'][value='38'][aria-describedby='boss-card-summary']", 1
    assert_select "#boss-card-summary", "Boss at 38% health, about 190 hours to go. Ends Thursday."
    assert_select ".boss-card__percent", "38% left"
    assert_select "img.boss-card__art[alt]:not([alt=''])[src^='/assets/bosses/placeholder-']", 1
    assert_select "[role='status']", 0, "no defeat banner while the boss stands"
    assert_select "[style]", 0, "no inline styles (CSP)"
    assert_select "script", 0
    assert_match(/4 days left, ends Thursday/, rendered)
    assert_match(/Everyone's coding chips away/, rendered)
  end

  test "the label beside the bar never reads 100% left once any damage has landed" do
    { 0 => [ "Full health", "100", /\ABoss at full health, no hits yet this week/ ],
      36 => [ "Under 1% damage", "100", /\ABoss has taken under 1% damage/ ],
      250 * HOUR => [ "50% left", "50", /\ABoss at 50% health/ ],
      (500 * HOUR) - 60 => [ "1% left", "1", /\ABoss at 1% health, less than an hour to go/ ],
      (500 * HOUR) + 60 => [ "0% left", "0", /\ABoss defeated\./ ] }.each do |seconds, (label, value, summary)|
      HourEntry.delete_all
      Boss.update_all(defeated_at: nil)
      @rendered = self.class.content_class.new(+"")
      add_hours(@other, FRIDAY, seconds) if seconds.positive?
      card

      assert_select ".boss-card__percent", { count: 1, text: label }, "#{seconds} seconds"
      assert_select "progress#boss-card-health[value='#{value}']", label, "#{seconds} seconds"
      assert_select "#boss-card-summary", summary
      assert_no_match(/100% left/, rendered)
    end
  end

  test "defeated: a role=status banner, overkill, an empty bar, and the slayer badge for a contributor" do
    add_hours(@user, FRIDAY, 20 * 60)
    add_hours(@other, FRIDAY, (500 * HOUR) + HOUR)
    card

    assert_select "section.boss-card--defeated"
    assert_select ".boss-card__banner[role='status']", text: /Boss defeated!.*Together you took down Boss 1.*overkill/m
    assert_select "progress[value='0']", 1
    assert_select ".boss-card__badge-label", /Boss slayer/
    assert_select ".boss-card__badge-label span[aria-hidden='true']", 1, "the star is decorative"
    assert_select ".boss-card__yours", "You've dealt 20 minutes of damage this week."
  end

  test "defeated without enough time: no badge, a hint while the week is on" do
    add_hours(@user, FRIDAY, 899)
    add_hours(@other, FRIDAY, 600 * HOUR)
    card

    assert_select ".boss-card__badge", 0
    assert_select ".boss-card__days", text: /Code for 15 minutes before the week ends to earn the Boss slayer badge/
  end

  test "escaped: supportive copy and no banner" do
    add_hours(@other, FRIDAY, 100 * HOUR)
    render partial: "bosses/card", locals: { presenter: Bosses::Presenter.new(user: @user, today: THURSDAY + 2) }

    assert_select "section.boss-card--escaped"
    assert_select "[role='status']", 0
    assert_select ".boss-card__days", text: /got away this time\. No harm done/
    assert_select ".boss-card__state", "Escaped"
  end

  test "none: a calm card with no bar and no art" do
    render partial: "bosses/card", locals: { presenter: Bosses::Presenter.new(user: @user, today: FRIDAY - 2) }

    assert_select "section.boss-card--none h2", "No boss right now"
    assert_select "progress", 0
    assert_select "img", 0
    assert_match(/The next boss arrives Friday 13 November\./, rendered)
    assert_select ".boss-card__community", "Be the first to code today."
  end

  test "every state shows exactly one h2 and states in words, never colour alone" do
    [ FRIDAY - 2, MONDAY, THURSDAY + 2 ].each do |day|
      render partial: "bosses/card", locals: { presenter: Bosses::Presenter.new(user: @user, today: day) }
      assert_select "h2", 1
    end
  end

  test "no other user's name, email, Slack id, auth id or user id leaks, only aggregates" do
    add_hours(@other, MONDAY, 3_600)
    add_hours(@other, FRIDAY, 50 * HOUR)
    add_hours(@user, MONDAY, 900)

    presenter = Bosses::Presenter.new(user: @user, today: MONDAY)
    html = card
    exposed = [ html, presenter.summary, presenter.community_text, presenter.contributed_text, presenter.boss_name, presenter.art_alt ].join(" ")

    [ @other.display_name, @other.email, @other.slack_id, @other.hca_uid, "Zebra", "zed.person" ].each do |secret|
      assert_not_includes exposed, secret
    end
    assert_not_includes exposed, @user.email
    assert_not_includes exposed, @user.hca_uid
    assert_no_match(/user[-_ ]?id|data-user|\/users\//i, html)
    assert_equal "2 people coded today.", presenter.community_text
    assert_equal "You've dealt 15 minutes of damage this week.", presenter.contributed_text, "only the viewer's own 15 minutes, never the other user's 51 hours"
  end

  test "the presenter exposes no user objects or ids" do
    add_hours(@other, MONDAY, 3_600)
    presenter = Bosses::Presenter.new(user: @user, today: MONDAY)
    values = (presenter.public_methods(false) - [ :preview ]).filter_map do |name|
      presenter.public_send(name) if presenter.method(name).arity.zero?
    end
    assert(values.none? { |value| value.is_a?(User) || value.is_a?(HourEntry) || value.is_a?(Boss) })
  end
end
