require "test_helper"

# Where the circles on the boss stage rest and how far they lunge (dashboard.css, `.stage__fan--pN`): on arcs AROUND the boss's picture box
# (`.stage__ring`), never over it, never over each other, and the lunge stops before the box. A place is a point on the box's outline (--x, --y
# in percent of its width and height) pushed away by --nx and --ny rings, so the numbers can be checked without a browser: the box is taken at
# the smallest sizes the page gives it (the stylesheet says them: a minimum height, and a width that is at most 19rem on a phone, 29rem from
# 48rem up, and at 1024 px about 20rem).
class FighterRingTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/stylesheets/dashboard.css").read
  REM = 16.0
  KEYS = %i[x y nx ny nd tx ty qx qy].freeze

  # The smallest boxes the stage makes ([width, height] in rem) and a big one. The phone box is 19rem wide on every phone of 320 px and up:
  # the arena has no side padding there, the ring runs above and below.
  BOXES = { phone: [ 19, 15 ], desktop: [ 20, 20 ], wide: [ 29, 30 ] }.freeze
  # How much clearance, at the very least, the biggest circle keeps from the box (a rem is a positive but tight margin).
  AIR = 0.75 * REM

  def rem(text) = text.to_f * REM

  def parse(body) = body.scan(/--(\w+):\s*(-?[\d.]+)%?;/).to_h { |name, value| [ name.to_sym, value.to_f ] }

  # The twelve places, as numbers: `:phone` is the base rules, `:desktop` the ones inside `@media (min-width: 48rem)`.
  def slots(layout)
    @slots ||= {}
    @slots[layout] ||= begin
      pattern = layout == :phone ? /^\.stage__fan--p(\d+)\s*\{([^}]*)\}/ : /^ {2}\.stage__fan--p(\d+)\s*\{([^}]*)\}/
      CSS.scan(pattern).to_h { |number, body| [ number.to_i, { x: 0, y: 0, nx: 0, ny: 0, nd: 1, tx: 1, ty: 0, qx: 0, qy: 1 }.merge(parse(body)) ] }
    end
  end

  def arena(layout)
    block = layout == :phone ? CSS[/^\.stage__arena \{[^}]*\}/] : CSS[/@media \(min-width: 48rem\) \{\s*\.stage__arena \{([^}]*)\}/, 1]
    %i[size_max ring room].to_h { |name| [ name, rem(block[/--#{name.to_s.tr('_', '-')}:\s*([\d.]+)rem/, 1]) ] }
  end

  # The sizes of the five bands, in px.
  def sizes(layout)
    block = layout == :phone ? CSS : CSS[/@media \(min-width: 48rem\) \{\s*\.stage__fan--s1.*?\n\}/m]
    (1..5).map { |band| rem(block[/\.stage__fan--s#{band} \{ --size: ([\d.]+)rem/, 1]) }
  end

  def layout_of(box) = box == :phone ? :phone : :desktop

  def centre(slot, width, height, ring) = [ (slot[:x] / 100 * width) + (slot[:nx] * ring), (slot[:y] / 100 * height) + (slot[:ny] * ring) ]

  # Straight-line distance from a point to the box [0, width] x [0, height] (0 inside it).
  def away(point, width, height) = Math.hypot([ -point[0], point[0] - width, 0 ].max, [ -point[1], point[1] - height, 0 ].max)

  def each_box
    BOXES.each do |box, (width_rem, height_rem)|
      layout = layout_of(box)
      yield box, layout, arena(layout), width_rem * REM, height_rem * REM
    end
  end

  test "there is one place for every circle the stage draws, on a phone and from 48rem up" do
    %i[phone desktop].each { |layout| assert_equal (1..Bosses::Fighters::LIMIT).to_a, slots(layout).keys.sort, layout.to_s }
    slots(:phone).each_value { |slot| assert_equal KEYS.sort, slot.keys.sort }
  end

  test "the stylesheet gives the picture box the sizes this test assumes, and the ring is made for the biggest circle" do
    assert_includes CSS, "inline-size: min(100%, 19rem);\n  min-block-size: 15rem;"
    assert_includes CSS, ".stage__ring { inline-size: min(100%, 29rem); min-block-size: 20rem; }"
    %i[phone desktop].each do |layout|
      one = arena(layout)
      assert_equal one[:size_max], sizes(layout).max, "#{layout}: the ring is made for the biggest band"
      assert_operator one[:ring] - (one[:size_max] / 2), :>=, AIR, "#{layout}: a circle of the biggest band rests at least #{AIR / REM} rem from the picture"
      furthest = slots(layout).values.map { |slot| slot[:nd] }.max
      assert_operator one[:room], :>=, (furthest * one[:ring]) + (one[:size_max] / 2) - 0.1, "#{layout}: the arena keeps room for the furthest place"
    end
  end

  test "every place is outside the picture box by at least a ring, which is the biggest circle's radius and its air" do
    each_box do |box, layout, one, width, height|
      slots(layout).each do |number, slot|
        point = centre(slot, width, height, one[:ring])
        distance = away(point, width, height)
        assert_operator distance, :>=, (one[:size_max] / 2) + AIR - 0.01, "#{box}: place #{number} is too close to the boss (#{point.map(&:round)} in a #{width.round} x #{height.round} box)"
        assert_in_delta slot[:nd] * one[:ring], distance, 0.5, "#{box}: place #{number} --nd is its true distance in rings (the lunge counts on it)"
        assert_operator slot[:nd], :>=, 1.0
        assert_in_delta Math.hypot(slot[:nx], slot[:ny]), slot[:nd], 0.011, "#{box}: place #{number}"
      end
    end
  end

  test "the places stay inside the room the arena keeps around the box, and the sides keep clear of the top where the plates hang" do
    each_box do |box, layout, one, width, height|
      radius = one[:size_max] / 2
      slots(layout).each do |number, slot|
        x, y = centre(slot, width, height, one[:ring])
        assert_operator y - radius, :>=, -one[:room] - 0.5, "#{box}: place #{number} is past the room above"
        assert_operator y + radius, :<=, height + one[:room] + 0.5, "#{box}: place #{number} is past the room below"
        next if layout == :phone # no side room, and none is needed: a phone's places are above and below

        assert_operator x - radius, :>=, -one[:room] - 0.5, "#{box}: place #{number} is past the room on the left"
        assert_operator x + radius, :<=, width + one[:room] + 0.5, "#{box}: place #{number} is past the room on the right"
        assert_operator y, :>=, 0.3 * height - 0.5, "#{box}: place #{number} is not up where the health plates hang"
      end
      next unless layout == :phone

      slots(layout).each do |number, slot|
        x = centre(slot, width, height, one[:ring]).first
        # a 320 px phone leaves 8 px each side of the 19rem picture
        assert_operator x - radius, :>=, -8, "#{box}: place #{number} stays within the screen"
        assert_operator x + radius, :<=, width + 8, "#{box}: place #{number} stays within the screen"
      end
    end
  end

  test "no two places overlap, even with a circle of the biggest band in every one of them" do
    each_box do |box, layout, one, width, height|
      points = slots(layout).transform_values { |slot| centre(slot, width, height, one[:ring]) }
      points.to_a.combination(2).each do |(first, a), (second, b)|
        assert_operator Math.hypot(a[0] - b[0], a[1] - b[1]), :>=, one[:size_max] + 4, "#{box}: places #{first} and #{second} touch"
      end
    end
  end

  test "the arcs are not straight lines: a side or a row has places at more than one distance from the box" do
    %i[phone desktop].each do |layout|
      distances = slots(layout).values.map { |slot| slot[:nd] }
      assert_operator distances.uniq.size, :>=, 3, "#{layout}: the places are staggered on arcs, not in a rigid line"
      assert_operator distances.max - distances.min, :>=, 0.25
    end
  end

  test "every place fights toward the boss, with a drift that goes across its way and never toward the box" do
    %i[phone desktop].each do |layout|
      slots(layout).each do |number, slot|
        inward = [ -slot[:nx] / slot[:nd], -slot[:ny] / slot[:nd] ]
        assert_operator (slot[:tx] * inward[0]) + (slot[:ty] * inward[1]), :>=, 0.95, "#{layout} place #{number}: the lunge points toward the box"
        assert_operator Math.hypot(slot[:tx], slot[:ty]), :<=, 1.2
        assert_operator ((slot[:qx] * inward[0]) + (slot[:qy] * inward[1])).abs, :<=, 0.2, "#{layout} place #{number}: the drift does not go toward the box"
      end
    end
  end

  test "the lunge stops short of the box in every place and every size band: a shipper nearly touches it, a steady pace jabs lighter" do
    top = Bosses::FighterMotion::STEPS[:la] - 1
    drift = ((Bosses::FighterMotion::STEPS[:lb] - 1) / 2.0) * 0.2 * REM
    ship = CSS.match(/^\s*--reach: calc\(([\d.]+) \+ var\(--la\) \* ([\d.]+)\);/).captures.map(&:to_f)
    code = CSS.match(/^\.stage__fan--hit-code \{ --reach: calc\(([\d.]+) \+ var\(--la\) \* ([\d.]+)\); \}/).captures.map(&:to_f)
    ship_range = [ ship[0], ship[0] + (ship[1] * top) ]
    code_range = [ code[0], code[0] + (code[1] * top) ]

    assert_operator ship_range.last, :<, 1, "even the longest lunge ends before the edge"
    assert_operator ship_range.first, :>=, 0.5
    assert_operator code_range.last, :<, ship_range.first + 0.01, "a steady pace never goes further than the shortest shipper"
    assert_operator code_range.first, :>, 0

    each_box do |box, layout, one, width, height|
      sizes(layout).each do |size|
        slots(layout).each do |number, slot|
          rest = centre(slot, width, height, one[:ring])
          gap = (slot[:nd] * one[:ring]) - (size / 2)
          assert_operator gap, :>, 0, "#{box}: place #{number} has free distance to the box"
          [ ship_range.last, code_range.last ].each do |reach|
            [ -drift, 0, drift ].each do |slide|
              point = [ rest[0] + (slot[:tx] * gap * reach) + (slot[:qx] * slide), rest[1] + (slot[:ty] * gap * reach) + (slot[:qy] * slide) ]
              assert_operator away(point, width, height), :>=, (size / 2) - 0.01, "#{box}: place #{number} (circle #{size.round}px, reach #{reach.round(2)}, slide #{slide.round(1)}) goes onto the boss"
            end
          end
          # the longest shipper's lunge ends within a tenth of the free distance (and a pixel) of the edge
          far = [ rest[0] + (slot[:tx] * gap * ship_range.last), rest[1] + (slot[:ty] * gap * ship_range.last) ]
          assert_operator away(far, width, height) - (size / 2), :<=, (0.1 * gap) + 1.0, "#{box}: place #{number}'s heaviest hit stops close to the boss"
        end
      end
    end

    keyframes = CSS[/@keyframes stage-lunge \{.*?\n\}\n@keyframes stage-jab \{.*?\n\}\n/m]
    assert_not_nil keyframes
    assert_no_match(/--dir|--dy|--axis/, keyframes, "the old across-the-boss lunge is gone")
    assert_match(/var\(--gap\) \* var\(--reach\)/, keyframes, "the reach is a share of the free distance to the box")
    assert_includes CSS, "--gap: calc(var(--nd) * var(--ring) - var(--size) / 2);"
  end

  test "the ring is the box the places and the lunge are measured from: the markup has it around the picture and the circles" do
    view = Rails.root.join("app/views/dashboard/_stage.html.erb").read
    assert_match(/<div class="stage__ring.*?<ul class="stage__crowd".*?<%= image_tag art_path.*?stage__art.*?<\/div>/m, view)
  end
end
