require "test_helper"
require_relative "../support/ships_test_support"
require_relative "../support/ship_images_helper"

class ShipImageTest < ActiveSupport::TestCase
  include ShipsTestSupport
  include ShipImagesHelper

  setup do
    @user = users(:onboarded)
    @user.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    @project = make_project(@user)
    (7..9).each { |day| code(@user, Date.new(2026, 11, day), HOUR) }
    @ship = submit_ship(@project, submit: false)
  end

  def attributes(**overrides)
    content = webp_bytes
    { ship: @ship, user: @user, position: 1, content: content, byte_size: content.bytesize, width: 20, height: 10, sha256: Digest::SHA256.hexdigest(content) }.merge(overrides)
  end

  def create_image(**overrides) = ShipImage.create!(attributes(**overrides))

  # --- the model ---

  test "a screenshot needs a position of 1 to 3, a size, a SHA-256 and the ship's owner" do
    assert create_image.persisted?
    [ 0, 4, -1 ].each { |position| assert_not ShipImage.new(attributes(position: position)).valid?, position }
    assert_not ShipImage.new(attributes(width: 0)).valid?
    assert_not ShipImage.new(attributes(byte_size: ShipImage::MAX_BYTES_CEILING + 1)).valid?
    assert_not ShipImage.new(attributes(sha256: "nope")).valid?
    assert_not ShipImage.new(attributes(user: users(:new_user))).valid?
  end

  test "the description is optional, tidied, and at most 140 characters" do
    assert_nil create_image.alt
    assert_equal "A cow", create_image(position: 2, content: webp_bytes(5, 5), alt: "  A   cow ", byte_size: webp_bytes(5, 5).bytesize, sha256: Digest::SHA256.hexdigest(webp_bytes(5, 5))).alt
    assert ShipImage.new(attributes(alt: "x" * 140)).valid?
    assert_not ShipImage.new(attributes(alt: "x" * 141)).valid?
  end

  test "the default text for a screen reader is the position" do
    assert_equal "Screenshot 2", ShipImage.new(position: 2).alt_text
    assert_equal "A cow", ShipImage.new(position: 2, alt: "A cow").alt_text
  end

  test "a ship's images are listed in order without loading the bytes" do
    create_image(position: 2, content: webp_bytes(8, 8), byte_size: webp_bytes(8, 8).bytesize, sha256: Digest::SHA256.hexdigest(webp_bytes(8, 8)))
    create_image(position: 1)
    images = Ship.find(@ship.id).images.to_a
    assert_equal [ 1, 2 ], images.map(&:position)
    assert_raises(ActiveModel::MissingAttributeError) { images.first.content }
    assert_equal 20, images.first.width
  end

  # --- the database says no, whatever the model says ---

  def insert_raw(**overrides)
    values = { ship_id: @ship.id, user_id: @user.id, position: 1, content: "RIFFxxxxWEBP", byte_size: 12, width: 1, height: 1, sha256: "b" * 64, created_at: Time.current }.merge(overrides)
    # A savepoint, so a refused insert does not poison the test transaction.
    ShipImage.transaction(requires_new: true) { ShipImage.insert!(values) }
  end

  test "the database refuses a position outside 1 to 3, a size over the ceiling, a wrong size, bad dimensions and a bad hash" do
    insert_raw(position: 3)
    assert_raises(ActiveRecord::StatementInvalid) { insert_raw(position: 0, sha256: "c" * 64) }
    assert_raises(ActiveRecord::StatementInvalid) { insert_raw(position: 4, sha256: "d" * 64) }
    assert_raises(ActiveRecord::StatementInvalid) { insert_raw(position: 2, byte_size: 13, sha256: "e" * 64) }
    assert_raises(ActiveRecord::StatementInvalid) { insert_raw(position: 2, width: 0, sha256: "f" * 64) }
    assert_raises(ActiveRecord::StatementInvalid) { insert_raw(position: 2, sha256: "NOT-HEX") }
    assert_raises(ActiveRecord::StatementInvalid) { insert_raw(position: 2, sha256: "1" * 64, alt: "x" * 141) }
    assert_raises(ActiveRecord::StatementInvalid) { insert_raw(position: 2, sha256: "2" * 64, content: "x" * 5_000_001, byte_size: 5_000_001) }
  end

  test "the database allows one picture per position and refuses the same picture twice on a ship" do
    insert_raw(position: 1, sha256: "a" * 64)
    assert_raises(ActiveRecord::RecordNotUnique) { insert_raw(position: 1, sha256: "b" * 64) }
    assert_raises(ActiveRecord::RecordNotUnique) { insert_raw(position: 2, sha256: "a" * 64) }
    insert_raw(position: 2, sha256: "b" * 64)
  end

  # --- deletion: the database cascades (docs/PRIVACY_API.md) ---

  test "deleting the ship deletes its images" do
    create_image
    assert_difference("ShipImage.count", -1) { Ship.where(id: @ship.id).delete_all }
  end

  test "deleting the project deletes the ship's images" do
    create_image
    assert_difference("ShipImage.count", -1) { Project.where(id: @project.id).delete_all }
  end

  test "deleting the user deletes their images, and the privacy deleter counts them" do
    create_image
    other = users(:new_user)
    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: @user.hca_uid)
    result = Privacy::Deleter.new(subject).call(dry_run: true)
    assert_equal 1, result.deleted.fetch("ship_images")
    assert_equal 1, ShipImage.count, "a dry run deletes nothing"

    result = Privacy::Deleter.new(subject).call(dry_run: false)
    assert_equal 1, result.deleted.fetch("ship_images")
    assert_equal 0, ShipImage.count
    assert User.exists?(other.id)
  end
end
