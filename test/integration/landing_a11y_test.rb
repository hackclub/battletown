require "test_helper"

# Landing page accessibility and plain language: the FAQ answer about coding time is a list of short rules, and the
# stylesheet keeps the footer, the sign-in link, the call to action and the prize names readable at large text sizes.
class LandingA11yTest < ActionDispatch::IntegrationTest
  CSS = Rails.root.join("app/assets/stylesheets/landing.css").read

  # The text of one rule block, from its selector to the closing brace (the rules here have no nested braces).
  def rule(selector)
    CSS[/^\s*#{Regexp.escape(selector)}\s*\{([^}]*)\}/m, 1] || flunk("no rule for #{selector}")
  end

  def faq_answer(question)
    get "/"
    details = css_select(".faq details").find { |node| node.at_css("summary").text.strip == question }
    assert details, "no FAQ question #{question.inspect}"
    details
  end

  test "coding time FAQ is a list of one-rule sentences of 20 words or fewer" do
    answer = faq_answer("What counts as coding time?")
    items = answer.css("ul.faq__rules > li").map { |li| li.text.squish }
    assert_equal 7, items.size
    assert_empty answer.css("p"), "the rules are a list, not a paragraph"
    items.each do |text|
      sentences = text.split(/(?<=[.!?])\s+/)
      sentences.each { |sentence| assert_operator sentence.split.size, :<=, 20, sentence }
    end
  end

  test "coding time FAQ keeps every rule and defines Hackatime once, in plain words" do
    text = faq_answer("What counts as coding time?").css("li").map { |li| li.text.squish }.join(" ")
    assert_equal 1, text.scan("Hackatime is a free tool that tracks the time you spend coding.").size
    assert_match(/Only time tracked with Hackatime while you build your project counts/, text)
    assert_match(/Never add extra hours/, text)
    assert_match(/Reading docs or watching videos counts only once you build something with what you learned/, text)
    assert_match(/art usually counts only up to about a third of your project time/, text)
    assert_match(/only count toward one You Ship We Ship program/, text)
    assert_match(/before the program started does not count/, text)
    assert_no_match(/inflate|capped|—/, text)
  end

  test "FAQ answers use no relative dates and state the age range" do
    get "/"
    faq = css_select(".faq details").map { |node| node.text.squish }.join(" ")
    assert_no_match(/this week|today|tomorrow|next week/i, faq)
    assert_select ".faq details", text: /Any teen aged 13 to 18/
    assert_select ".faq details", text: /runs for at least a month/
  end

  test "the footer and the sign-in link are on the page the stylesheet rules target" do
    get "/"
    assert_select "footer.site-footer nav[aria-label='Legal'] a", 4
    {
      "Hack Club" => "https://hackclub.com",
      "Terms & Privacy" => "https://hackclub.com/privacy-and-terms",
      "Fulfillment" => "https://forms.hackclub.com/bounty",
      "Security" => "https://security.hackclub.com"
    }.each do |label, href|
      assert_select "footer.site-footer nav[aria-label='Legal'] a[href='#{href}'][rel='noopener noreferrer']", text: label
    end
    assert_select "footer.site-footer .site-footer__credit", text: "made with <3 by @amber and @armand"
    assert_select "footer.site-footer .site-footer__credit a[href='https://hackclub.enterprise.slack.com/team/U07ABEP916X'][target='_blank'][rel='noopener']", text: "@armand"
    assert_select "footer.site-footer .site-footer__credit a[href='https://hackclub.enterprise.slack.com/team/U054VC2KM9P'][target='_blank'][rel='noopener']", text: "@amber"
    assert_select ".hero__signin-form", 0
  end

  test "the footer has no box and does not overlay the last section: in flow, navy on the sky" do
    block = rule("body:has(.landing) .site-footer")
    assert_match(/background: none/, block)
    assert_match(/color: var\(--color-navy\)/, block)
    assert_no_match(/position: absolute/, block)
    assert_no_match(/background: var\(--color-ink-blue\)/, CSS[/The footer sits in flow.*?\n\n/m].to_s)
  end

  test "the call to action can wrap and never drops below 24px" do
    cta = rule(".landing .cta")
    assert_no_match(/white-space:\s*nowrap/, cta)
    assert_match(/font: 400 clamp\(1\.5rem,/, cta)
    assert_match(/font-size: clamp\(1\.5rem,/, rule(".landing .cta--big"))
  end

  test "prize names wrap inside their card" do
    assert_match(/overflow-wrap: anywhere/, rule(".landing .prize h3"))
  end
end
