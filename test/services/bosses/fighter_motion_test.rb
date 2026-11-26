require "test_helper"

# How each circle on the boss stage moves (Bosses::FighterMotion): fixed by its key, different from everybody else's, and the same
# numbers in the stylesheet and the live controller.
class FighterMotionTest < ActiveSupport::TestCase
  KEYS = %w[3fa91c07d2b4 a07be5119c3d 5d2e88f0a461 c91470be6a23 08b3d6f19e75 e46a0c2d7b18 7b19f3a5c0e2 d0c58a3e1f96 21e7b94d06ac 94f60d1b8e37].freeze

  def steps(key) = Bosses::FighterMotion.for_key(key)

  test "the same key always gives the same steps, and every step is inside its range" do
    KEYS.each do |key|
      assert_equal steps(key), steps(key)
      assert_equal Bosses::FighterMotion::STEPS.keys, steps(key).keys
      steps(key).each { |name, step| assert_includes 0...Bosses::FighterMotion::STEPS[name], step, "#{key} #{name}" }
    end
  end

  test "ten typical players never share a start offset and cycle length" do
    pairs = KEYS.map { |key| [ Bosses::FighterMotion.delay(steps(key)), Bosses::FighterMotion.duration(steps(key)) ] }
    assert_equal KEYS.size, pairs.uniq.size, pairs.inspect
    assert_equal KEYS.size, KEYS.map { |key| steps(key) }.uniq.size
  end

  test "the offset starts every circle part-way through (negative), and a cycle lasts 2.4 to 4.2 seconds" do
    all = (1..500).map { |index| steps("key#{index}") }
    assert(all.all? { |one| Bosses::FighterMotion.delay(one) <= 0 })
    assert(all.all? { |one| Bosses::FighterMotion.duration(one).between?(2.4, 4.2) })
    assert_operator all.map { |one| Bosses::FighterMotion.delay(one) }.min, :<=, -3.5, "offsets reach across a whole cycle"
    assert_in_delta 2.4, all.map { |one| Bosses::FighterMotion.duration(one) }.min, 0.15
    assert_in_delta 4.2, all.map { |one| Bosses::FighterMotion.duration(one) }.max, 0.15
  end

  test "the keys spread over every step of every kind" do
    all = (1..2000).map { |index| steps("spread#{index}") }
    Bosses::FighterMotion::STEPS.each do |name, count|
      seen = all.map { |one| one[name] }.tally
      assert_equal count, seen.size, "#{name}: every step is used"
      assert_operator seen.values.min, :>, 2000 / count / 2, "#{name}: no step is starved"
    end
  end

  test "the classes name the steps" do
    assert_equal %w[stage__fan--da1 stage__fan--db2], Bosses::FighterMotion.classes(da: 1, db: 2)
  end

  test "the stylesheet has a rule for every step, with the numbers the Ruby side adds up" do
    css = Rails.root.join("app/assets/stylesheets/dashboard.css").read
    Bosses::FighterMotion::STEPS.each do |name, count|
      count.times { |step| assert_includes css, ".stage__fan--#{name}#{step} { --#{name}: #{step}; }" }
      assert_not_includes css, ".stage__fan--#{name}#{count} {"
    end
    assert_includes css, "--delay: calc(-1s * (var(--da) * #{Bosses::FighterMotion::DELAY_COARSE} + var(--db) * #{Bosses::FighterMotion::DELAY_FINE}));"
    assert_includes css, "--dur: calc(#{Bosses::FighterMotion::DURATION_BASE}s + var(--dc) * #{Bosses::FighterMotion::DURATION_COARSE}s + var(--de) * #{Bosses::FighterMotion::DURATION_FINE}s);"
  end

  test "the live controller knows the same steps" do
    js = Rails.root.join("app/javascript/controllers/boss_fighters_controller.js").read
    listed = js[/const MOTION_STEPS = \{([^}]*)\}/, 1].scan(/(\w+): (\d+)/).to_h { |name, count| [ name.to_sym, count.to_i ] }
    assert_equal Bosses::FighterMotion::STEPS, listed
  end
end
