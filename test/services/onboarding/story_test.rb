require "test_helper"

class Onboarding::StoryTest < ActiveSupport::TestCase
  S = Onboarding::Story
  NBSP = " ".freeze

  test "every project kind, detail, audience and size reads as one sensible sentence, with the last two words held together" do
    S::DETAILS.each do |kind, details|
      (details.keys + [ nil ]).each do |detail|
        (S::AUDIENCES.keys + [ nil ]).each do |audience|
          (S::SIZES.keys + [ nil ]).each do |size|
            text = S.reflection(kind: kind, detail: detail, audience: audience, size: size)
            label = [ kind, detail, audience, size ].inspect
            assert text.present?, label
            assert_match(/\A[A-Z]/, text, label)
            assert text.end_with?("."), label
            assert_no_match(/  |,,|\.\./, text, label)
            assert_no_match(/\bfor for\b/, text, label)
            assert_equal 1, text.count("."), label
            assert_match(/\S#{NBSP}\S+\.\z/, text, label) if text.split(/[ #{NBSP}]/).size >= 3 # no orphaned last word
          end
        end
      end
    end
  end

  test "the sentence from the brief" do
    assert_equal "A puzzle game for your friends, a few weeks of#{NBSP}work.", S.reflection(kind: "game", detail: "puzzle", audience: "friends", size: "weeks")
  end

  test "an unknown kind gives no sentence" do
    assert_nil S.reflection(kind: "undecided", detail: nil, audience: nil, size: nil)
  end

  test "time frames show the hours a day each needs for the prize, computed, and drop the impossible" do
    today = Date.new(2026, 12, 1)
    options = S.frame_options(10, ends_on: nil, today: today)
    assert_equal %w[two_weeks month no_rush], options.map(&:first) # no end date: no "end of the program"
    assert_equal "about 1 hour a day", options.find { |o| o.first == "two_weeks" }.last # 10 h / 14 days = 43 min, rounded up to a pace choice
    assert_equal "about 30 minutes a day", options.find { |o| o.first == "month" }.last # 20 min a day rounds up to 30... 10h/30d = 20 min
    assert_nil options.last.last
    # a prize too big for a fortnight at 8 hours a day is not offered that frame
    assert_not_includes S.frame_options(200, ends_on: nil, today: today).map(&:first), "two_weeks"
  end

  test "the wish line names the picked frame, and No rush or nothing gives none" do
    assert_equal "You wanted it in a month.", S.wish_line("month")
    assert_equal "You wanted it in 2 weeks.", S.wish_line("two_weeks")
    assert_equal "You wanted it by the end of the program.", S.wish_line("program")
    assert_nil S.wish_line("no_rush")
    assert_nil S.wish_line(nil)
  end

  test "every a-day figure the earlier screens show is a pace the pace question offers" do
    [ 1, 3, 5, 6, 10, 30, 50 ].each do |hours|
      figures = S.frame_options(hours, ends_on: nil, today: Date.new(2026, 12, 1)).filter_map(&:last)
      figures << Onboarding::DailyTime.text(Onboarding::DailyTime.minutes_a_day(hours, ends_on: nil))
      figures.compact.each { |text| assert_includes Onboarding::DailyTime::PACES.map { |pace| Onboarding::DailyTime.text(pace) }, text, "#{hours} h" }
    end
  end

  test "with an end date, frames past it are not offered and the end of the program is" do
    today = Date.new(2026, 12, 1)
    options = S.frame_options(10, ends_on: today + 19, today: today) # 20 days left
    assert_equal %w[two_weeks program no_rush], options.map(&:first)
    assert_equal "about 30 minutes a day", options.find { |o| o.first == "program" }.last # 10 h / 20 d = 30 min
    assert_empty S.frame_options(10, ends_on: today - 1, today: today)
  end

  test "the pace that meets a frame is the smallest that earns the prize in time, else the biggest" do
    paces = [ 30, 60, 120, 180 ]
    assert_equal 120, S.pace_for("two_weeks", 20, paces, ends_on: nil) # 20 h in 14 days = 86 min: 60 is not enough
    assert_equal 60, S.pace_for("two_weeks", 14, paces, ends_on: nil) # 60 minutes exactly
    assert_equal 180, S.pace_for("two_weeks", 100, paces, ends_on: nil)
    assert_nil S.pace_for("no_rush", 20, paces, ends_on: nil)
  end

  test "dates and days to a prize are plain arithmetic, day one being today" do
    assert_equal 5, S.days_to_earn(5, 60)
    assert_equal Date.new(2026, 12, 5), S.date_at(5, 60, from: Date.new(2026, 12, 1))
    assert_equal "December 5", S.date_text(Date.new(2026, 12, 5))
  end

  test "hours before a boss week ends" do
    assert_equal 3, S.hours_before(3, 60)
    assert_equal 1.5, S.hours_before(3, 30)
    assert_nil S.hours_before(0, 60)
  end

  test "an obstacle line names only a feature that exists: the crew bonus only while crews are on" do
    assert_equal [ "time", "lost" ].size, S.obstacle_lines(%w[time stuck lost idea none], team: false).size
    assert_equal 3, S.obstacle_lines(%w[time stuck lost], team: true).size
    assert_empty S.obstacle_lines(%w[idea none], team: true)
    assert_empty S.obstacle_lines(%w[stuck], team: false)
    time_line = S.obstacle_lines(%w[time], team: false).first.last
    assert_includes time_line, "#{Ships::Config.current.min_seconds / 3600} hour"
    lost = S.obstacle_lines(%w[lost], team: false).first.last
    assert_includes lost, "Friday to Thursday"
    assert_includes lost, "5 and 10 hours"
  end
end
