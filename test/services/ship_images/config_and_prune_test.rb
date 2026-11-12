require "test_helper"
require "rake"
require_relative "../../support/ships_test_support"
require_relative "../../support/ship_images_helper"

class ShipImages::ConfigAndPruneTest < ActiveSupport::TestCase
  include ShipsTestSupport
  include ShipImagesHelper

  def raw = Rails.application.config_for(:game).fetch(:ship_screenshots)

  # --- config ---

  test "the defaults are the ones decided for the first run" do
    config = ShipImages::Config.current
    assert_equal [ 3, 5_000_000, 24, 1600, 82, 30 ], [ config.max_files, config.max_upload_bytes, config.max_megapixels, config.max_edge_px, config.webp_quality, config.withdrawn_retention_days ]
    assert_equal 24_000_000, config.max_pixels
  end

  test "bad values are refused at load, including anything the database could not store" do
    [ { max_files: 4 }, { max_files: 0 }, { max_upload_bytes: 5_000_001 }, { max_upload_bytes: "lots" }, { webp_quality: 101 }, { max_megapixels: -1 } ].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { ShipImages::Config.from_hash(raw.merge(bad)) }
    end
    assert_raises(KeyError) { ShipImages::Config.from_hash(raw.except(:max_edge_px)) }
  end

  test "the schema ceiling and the model constant agree" do
    check = ActiveRecord::Base.connection.check_constraints("ship_images").find { |constraint| constraint.name == "ship_images_byte_size_check" }
    assert_includes check.expression, ShipImage::MAX_BYTES_CEILING.to_s
  end

  # --- prune ---

  setup do
    @user = users(:onboarded)
    @user.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    @project = make_project(@user)
    (7..9).each { |day| code(@user, Date.new(2026, 11, day), HOUR) }
  end

  def ship_with_image(status)
    ship = submit_ship(@project)
    processed = ShipImages::Processor.call(upload_file(png_bytes(12, 12, [ status.length, 5, 5 ])))
    ShipImage.create!(ship: ship, user: @user, position: 1, content: processed.content, width: 12, height: 12, byte_size: processed.byte_size, sha256: processed.sha256)
    Ships::Withdraw.call(ship: ship) if status == "withdrawn"
    ship
  end

  test "images of a ship withdrawn more than the retention period ago go, newer and other ships' images stay" do
    with_feature(:ship_screenshots) do
      old = ship_with_image("withdrawn")
      Ship.where(id: old.id).update_all(updated_at: 31.days.ago)
      recent = ship_with_image("withdrawn")
      Ship.where(id: recent.id).update_all(updated_at: 29.days.ago)
      live = ship_with_image("submitted")

      result = ShipImages::Prune.call
      assert_not result.skipped
      assert_equal [ 1, 0, 0 ], [ result.withdrawn, result.orphaned, result.mismatched ]
      assert_equal [ recent.id, live.id ].sort, ShipImage.pluck(:ship_id).sort
    end
  end

  test "a row tied to a different owner than its ship is removed and counted" do
    with_feature(:ship_screenshots) do
      ship = ship_with_image("submitted")
      ShipImage.where(ship_id: ship.id).update_all(user_id: users(:new_user).id)
      result = ShipImages::Prune.call
      assert_equal 1, result.mismatched
      assert_equal 0, ShipImage.count
    end
  end

  test "it is safe to repeat" do
    with_feature(:ship_screenshots) do
      ship_with_image("submitted")
      2.times { assert_equal [ 0, 0, 0 ], ShipImages::Prune.call.then { |r| [ r.withdrawn, r.orphaned, r.mismatched ] } }
      assert_equal 1, ShipImage.count
    end
  end

  test "the rake tasks print counts only, and the flag gates the prune task" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("ship_images:prune")
    ship_with_image("withdrawn").tap { |ship| Ship.where(id: ship.id).update_all(updated_at: 40.days.ago) }

    Rake::Task["ship_images:prune"].reenable
    assert_match(/skipped: the ship_screenshots flag is off/, capture_io { Rake::Task["ship_images:prune"].invoke }.first)
    assert_equal 1, ShipImage.count

    with_feature(:ship_screenshots) do
      Rake::Task["ship_images:prune"].reenable
      assert_match(/\Aship_images:prune withdrawn=1 orphaned=0 mismatched=0\n\z/, capture_io { Rake::Task["ship_images:prune"].invoke }.first)
    end

    Rake::Task["ship_images:check"].reenable
    assert_match(/ship_images:check libvips=\d+\.\d+\.\d+ missing=none/, capture_io { Rake::Task["ship_images:check"].invoke }.first)
  end
end
