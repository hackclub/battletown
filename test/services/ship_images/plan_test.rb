require "test_helper"
require_relative "../../support/ships_test_support"
require_relative "../../support/ship_images_helper"

class ShipImages::PlanTest < ActiveSupport::TestCase
  include ShipsTestSupport
  include ShipImagesHelper

  setup do
    @user = users(:onboarded)
    @user.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    @project = make_project(@user)
    (7..9).each { |day| code(@user, Date.new(2026, 11, day), HOUR) }
  end

  def slot(bytes: nil, name: "pic.png", **rest) = { file: (bytes && upload_file(bytes, name: name)), **rest }.compact

  def plan(params, options = {}) = ShipImages::Plan.build(params: params, **options)

  def draft = submit_ship(@project, submit: false)

  # Saves like the controller: the plan is committed inside the ship's own transaction.
  def save_ship(plan, ship: nil, submit: false)
    Ships::Submit.call(project: @project, ship: ship, attributes: ship_attrs, submit: submit, after_save: ->(saved) { plan.commit!(saved) })
  end

  # Puts a ship in a status directly (what each status requires is kept consistent for the database checks).
  def force_status(ship, status)
    columns = { status: status, submitted_at: Time.current, reviewed_at: nil, approved_seconds: nil, rejection_reason: nil }
    columns.merge!(reviewed_at: Time.current, approved_seconds: HOUR) if status == "approved"
    columns.merge!(reviewed_at: Time.current, rejection_reason: "Needs more") if status == "rejected"
    ship.update_columns(columns)
  end

  def stored(ship) = ShipImage.where(ship_id: ship.id).order(:position).to_a

  # --- adding ---

  test "files in slots become images at those positions, stored as WebP, when the ship is saved" do
    plan = plan("1" => slot(bytes: png_bytes(30, 20)), "3" => slot(bytes: jpeg_bytes(50, 40), name: "b.jpg", alt: "The  boss"))
    assert_not plan.errors?
    assert_predicate plan, :changes?

    ship = save_ship(plan)
    images = stored(ship)
    assert_equal [ 1, 3 ], images.map(&:position)
    assert_equal [ [ 30, 20 ], [ 50, 40 ] ], images.map { |image| [ image.width, image.height ] }
    assert_equal [ nil, "The boss" ], images.map(&:alt)
    assert(images.all? { |image| image.content.byteslice(8, 4) == "WEBP" && image.user_id == @user.id })
  end

  test "nothing is written until the plan is committed, and an empty form changes nothing" do
    plan = plan({ "1" => slot(bytes: png_bytes) })
    assert_equal 0, ShipImage.count
    assert_not plan("1" => { alt: "" }).changes?
    assert_not plan(nil).changes?
    assert_not plan({}).errors?
    assert_nothing_raised { save_ship(plan("1" => { remove: "0" })) }
  end

  test "an image with a wrong position, or more than the limit, is an error" do
    errors = plan("4" => slot(bytes: png_bytes)).errors
    assert_equal [ "You can add up to 3 screenshots." ], errors
    assert_predicate plan("0" => slot(bytes: png_bytes)), :errors?
    assert_predicate plan("x" => slot(bytes: png_bytes)), :errors?
    full = plan("1" => slot(bytes: png_bytes(10, 10)), "2" => slot(bytes: png_bytes(11, 11)), "3" => slot(bytes: png_bytes(12, 12)), "4" => slot(bytes: png_bytes(13, 13)))
    assert_equal [ "You can add up to 3 screenshots." ], full.errors
  end

  test "the limit follows the config" do
    ShipImages::Config.instance_variable_set(:@current, ShipImages::Config.from_hash(Rails.application.config_for(:game).fetch(:ship_screenshots).merge(max_files: 1)))
    assert_predicate plan("2" => slot(bytes: png_bytes)), :errors?
    assert_not plan("1" => slot(bytes: png_bytes)).errors?
  ensure
    ShipImages::Config.reset!
  end

  # --- friendly errors, per file ---

  test "each bad file gets its own message naming its slot, and the good one is not stored" do
    plan = plan("1" => slot(bytes: png_bytes), "2" => slot(bytes: "<svg/>", name: "logo.png"), "3" => slot(bytes: png_bytes(6000, 6000)))
    assert_equal 2, plan.errors.size
    assert_match(/\AScreenshot 2: That doesn't look like a PNG, JPEG, WebP or GIF/, plan.errors.first)
    assert_match(/\AScreenshot 3: That picture is too large/, plan.errors.last)
    assert_equal 0, ShipImage.count
  end

  test "a value that is not an uploaded file is refused" do
    assert_match(/Screenshot 1: that wasn't a file/, plan("1" => { file: "C:\\fakepath\\me.png" }).errors.first)
  end

  test "a description over 140 characters is refused" do
    assert_match(/Screenshot 1: the description is too long/, plan("1" => slot(bytes: png_bytes, alt: "x" * 141)).errors.first)
  end

  test "the same picture twice is refused, even in different formats of the same pixels" do
    twice = plan("1" => slot(bytes: png_bytes(30, 30)), "2" => slot(bytes: png_bytes(30, 30)))
    assert_equal [ "Screenshot 2 is the same picture as screenshot 1. Each one should be different." ], twice.errors
  end

  # --- changing a draft ---

  test "a file replaces the picture in its slot, remove empties a slot, and a description alone only changes the text" do
    ship = save_ship(plan("1" => slot(bytes: png_bytes(30, 30)), "2" => slot(bytes: png_bytes(31, 31)), "3" => slot(bytes: png_bytes(32, 32))))
    before = stored(ship).index_by(&:position)

    plan = plan({ "1" => slot(bytes: png_bytes(40, 40)), "2" => { remove: "1" }, "3" => { alt: "New words" } }, ship: ship.reload)
    assert_not plan.errors?
    save_ship(plan, ship: ship)

    after = stored(ship).index_by(&:position)
    assert_equal [ 1, 3 ], after.keys
    assert_equal 40, after[1].width
    assert_not_equal before[1].sha256, after[1].sha256
    assert_equal before[3].sha256, after[3].sha256
    assert_equal "New words", after[3].alt
  end

  test "a picture can be moved to a freed-up slot in the same save without tripping the duplicate rule" do
    ship = save_ship(plan("1" => slot(bytes: png_bytes(30, 30)), "2" => slot(bytes: png_bytes(31, 31))))
    plan = plan({ "1" => { remove: "1" }, "2" => slot(bytes: png_bytes(30, 30)) }, ship: ship.reload)
    assert_not plan.errors?, plan.errors.inspect
    save_ship(plan, ship: ship)
    assert_equal [ 2 ], stored(ship).map(&:position)
  end

  test "uploading the same picture again over its own slot is fine" do
    ship = save_ship(plan("1" => slot(bytes: png_bytes(30, 30))))
    plan = plan({ "1" => slot(bytes: png_bytes(30, 30)) }, ship: ship.reload)
    assert_not plan.errors?
    save_ship(plan, ship: ship)
    assert_equal 1, stored(ship).size
  end

  # --- edit rules by status ---

  test "a draft can be changed, a rejected one can too (that is what carrying over uses), and nothing else" do
    ship = save_ship(plan("1" => slot(bytes: png_bytes(30, 30))))
    assert_not plan({ "1" => { remove: "1" } }, ship: ship.reload).errors?

    %w[submitted approved withdrawn].each do |status|
      force_status(ship, status)
      for_status = plan({ "1" => { remove: "1" } }, ship: Ship.find(ship.id))
      assert_equal [ "Screenshots can't be changed once a ship has been submitted." ], for_status.errors, status
      assert_not for_status.changes?, status
    end
    assert_equal 1, stored(ship).size

    force_status(ship, "rejected")
    assert_not plan({ "1" => { remove: "1" } }, ship: Ship.find(ship.id)).errors?
  end

  test "an untouched form on a submitted ship is not an error (the page just does not send the fields)" do
    ship = save_ship(plan("1" => slot(bytes: png_bytes(30, 30))))
    force_status(ship, "submitted")
    assert_not plan({ "1" => { alt: "" } }, ship: Ship.find(ship.id)).errors?
  end

  # --- fix and ship again ---

  def rejected_ship_with_images
    ship = save_ship(plan("1" => slot(bytes: png_bytes(30, 30), alt: "First"), "2" => slot(bytes: png_bytes(31, 31))), submit: true)
    force_status(ship, "rejected")
    Ship.find(ship.id)
  end

  test "a new ship made from a rejected one keeps its screenshots unless they are changed or removed" do
    rejected = rejected_ship_with_images
    plan = plan({ "2" => { remove: "1" }, "3" => slot(bytes: png_bytes(33, 33)) }, carry_from: rejected)
    assert_not plan.errors?, plan.errors.inspect
    fresh = save_ship(plan)

    assert_not_equal rejected.id, fresh.id
    images = stored(fresh)
    assert_equal [ 1, 3 ], images.map(&:position)
    assert_equal "First", images.first.alt
    assert_equal stored(rejected).first.sha256, images.first.sha256
    assert_equal [ 1, 2 ], stored(rejected).map(&:position), "the rejected ship keeps its own pictures"
  end

  test "carried pictures are copied as they are, not processed again, and a replaced one is not carried" do
    rejected = rejected_ship_with_images
    plan = plan({ "1" => slot(bytes: png_bytes(44, 44)) }, carry_from: rejected)
    fresh = save_ship(plan)
    images = stored(fresh).index_by(&:position)
    assert_equal 44, images[1].width
    assert_equal stored(rejected).last.sha256, images[2].sha256
  end

  test "a plan with only a carry-over and no form fields still carries" do
    rejected = rejected_ship_with_images
    fresh = save_ship(plan(nil, carry_from: rejected))
    assert_equal [ 1, 2 ], stored(fresh).map(&:position)
  end
end
