require "test_helper"
require_relative "../support/bosses_helper"
require_relative "../support/ship_images_helper"

# A boss's own picture (see Boss and Bosses::ArtConfig): stored like a shop item's, without its bytes in any list query.
class BossArtTest < ActiveSupport::TestCase
  include BossesHelper
  include ShipImagesHelper

  def processed(bytes = png_bytes(64, 32)) = ShipImages::Processor.call(upload_file(bytes), config: Bosses::ArtConfig.current)

  # A PNG whose right half is fully transparent.
  def cutout_png(width = 40, height = 20)
    colour = solid(width, height, [ 200, 40, 40 ])
    opaque_left = Vips::Image.black(width / 2, height).new_from_image([ 255 ]).embed(0, 0, width, height, extend: :black)
    colour.bandjoin(opaque_left.cast(:uchar)).pngsave_buffer
  end

  def db_refuses(&block) = assert_raises(ActiveRecord::StatementInvalid) { Boss.transaction(requires_new: true, &block) }

  def with_art(boss = make_boss, alt: "A tall boss in a red coat")
    boss.attach_art(processed)
    boss.art_alt = alt
    boss.save!
    boss
  end

  test "the config comes from game.yml and answers what the Processor asks" do
    config = Bosses::ArtConfig.current
    assert_equal [ 5_000_000, 16, 1600, 85 ], [ config.max_upload_bytes, config.max_megapixels, config.max_edge_px, config.webp_quality ]
    assert_equal 16_000_000, config.max_pixels
    assert_equal "picture", config.picture_noun
    assert_equal 5_000_000 + 64.kilobytes, config.max_request_bytes
  end

  test "the config refuses a value that is not a positive number or is past the database's ceiling" do
    good = { max_upload_bytes: 5_000_000, max_megapixels: 16, max_edge_px: 1600, webp_quality: 85 }
    assert_raises(ArgumentError) { Bosses::ArtConfig.from_hash(good.merge(max_edge_px: 0)) }
    assert_raises(ArgumentError) { Bosses::ArtConfig.from_hash(good.merge(max_upload_bytes: 5_000_001)) }
    assert_raises(ArgumentError) { Bosses::ArtConfig.from_hash(good.merge(webp_quality: 101)) }
    assert_raises(KeyError) { Bosses::ArtConfig.from_hash(good.except(:webp_quality)) }
  end

  test "a boss with no picture uses the built-in one" do
    boss = make_boss
    assert_not_predicate boss, :art?
    assert_equal "bosses/placeholder.webp", boss.art_path
    assert_equal Boss::ARTS.fetch("placeholder"), boss.art_alt_text
  end

  test "an attached picture is stored with its size, hash and bytes, and is a WebP" do
    boss = with_art
    boss = Boss.find(boss.id)
    assert_predicate boss, :art?
    assert_equal "RIFF", boss.art_content.byteslice(0, 4)
    assert_equal [ 64, 32 ], [ boss.art_width, boss.art_height ]
    assert_equal boss.art_content.bytesize, boss.art_byte_size
    assert_match(%r{\A/bosses/#{boss.id}/art\?v=#{boss.art_sha256.first(12)}\z}, boss.art_path)
    assert_equal "A tall boss in a red coat", boss.art_alt_text
  end

  test "the picture's alt text is needed, squished and at most 200 characters" do
    boss = make_boss
    boss.attach_art(processed)
    assert_not boss.valid?
    assert_includes boss.errors.full_messages, "Alt text is needed to describe the picture"

    boss.art_alt = "   "
    assert_not boss.valid?
    boss.art_alt = "  A   tall\nboss "
    assert boss.valid?
    assert_equal "A tall boss", boss.art_alt

    boss.art_alt = "x" * 200
    assert boss.valid?
    boss.art_alt = "x" * 201
    assert_not boss.valid?
  end

  test "a boss without a picture does not need alt text" do
    assert_predicate make_boss, :persisted?
    assert_nil make_boss(starts_on: FRIDAY + 7).art_alt
  end

  test "the picture is a transparent cut-out: the alpha channel survives the re-encode" do
    picture = processed(cutout_png)
    stored = Vips::Image.webpload_buffer(picture.content)
    assert_predicate stored, :has_alpha?
    assert_equal 255, stored.extract_band(3).getpoint(5, 5).first
    assert_equal 0, stored.extract_band(3).getpoint(35, 5).first
  end

  test "an uploaded cut-out keeps its transparency once stored on a boss" do
    boss = make_boss
    boss.attach_art(processed(cutout_png))
    boss.art_alt = "A cut-out"
    boss.save!
    stored = Vips::Image.webpload_buffer(Boss.art_content_for(boss.id))
    assert_predicate stored, :has_alpha?
    assert_equal 0, stored.extract_band(3).getpoint(35, 5).first
  end

  test "removing the picture clears every picture column and the alt text" do
    boss = with_art
    boss.remove_art
    boss.save!
    assert_equal [ nil ] * 6, boss.reload.attributes.values_at("art_content", "art_width", "art_height", "art_byte_size", "art_sha256", "art_alt")
    assert_equal "bosses/placeholder.webp", boss.art_path
    assert_equal Boss::ARTS.fetch("placeholder"), boss.art_alt_text
  end

  test "replacing the picture changes the version in its URL" do
    boss = with_art
    first = boss.art_path
    boss.attach_art(processed(png_bytes(64, 32, [ 9, 9, 200 ])))
    boss.save!
    assert_not_equal first, boss.art_path
  end

  test "the alt text of a picture that was removed is not used" do
    boss = make_boss
    boss.update_columns(art_alt: "stale")
    assert_equal Boss::ARTS.fetch("placeholder"), boss.art_alt_text
  end

  test "the fallback description names the boss when the built-in picture has none" do
    boss = make_boss
    boss.art_key = "other"
    assert_equal "The boss, #{boss.name}", boss.art_alt_text
  end

  test "lists leave the picture bytes out" do
    with_art
    listed = Boss.without_art_content.chronological.to_a
    assert_equal 1, listed.size
    assert_predicate listed.first, :art?
    assert_match(%r{/bosses/\d+/art\?v=}, listed.first.art_path)
    assert_raises(ActiveModel::MissingAttributeError) { listed.first.art_content }
    assert_no_match(/art_content/, Boss.without_art_content.to_sql)
  end

  test "a list query never asks the database for the bytes" do
    with_art
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] if payload[:sql].match?(/FROM "bosses"/) }
    Boss.without_art_content.chronological.to_a
    Bosses::Presenter.new(user: users(:onboarded), today: FRIDAY + 1).stage_art
    Bosses::Current.for(FRIDAY + 1)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_predicate statements, :any?
    statements.each { |sql| assert_no_match(/art_content/, sql) }
  end

  test "a row loaded without its bytes can still be renamed and does not lose them" do
    boss = with_art
    listed = Boss.without_art_content.find(boss.id)
    listed.update!(name: "Renamed")
    assert_equal "Renamed", Boss.find(boss.id).name
    assert_predicate Boss.art_content_for(boss.id), :present?
  end

  test "art_content_for returns just the bytes, or nil" do
    boss = with_art
    assert_equal boss.art_content, Boss.art_content_for(boss.id)
    assert_nil Boss.art_content_for(make_boss(starts_on: FRIDAY + 7).id)
    assert_nil Boss.art_content_for(0)
  end

  test "copy_art_from takes another boss's picture and alt text, even when it was loaded without its bytes" do
    last_week = with_art
    this_week = make_boss(starts_on: FRIDAY + 7)
    this_week.copy_art_from(Boss.without_art_content.find(last_week.id))
    this_week.save!
    this_week = Boss.find(this_week.id)
    assert_equal last_week.art_sha256, this_week.art_sha256
    assert_equal last_week.art_content, this_week.art_content
    assert_equal [ last_week.art_width, last_week.art_height, last_week.art_byte_size, last_week.art_alt ],
                 [ this_week.art_width, this_week.art_height, this_week.art_byte_size, this_week.art_alt ]
  end

  test "copy_art_from does nothing when the other boss has no picture" do
    boss = make_boss(starts_on: FRIDAY + 7)
    boss.copy_art_from(make_boss)
    assert_not_predicate boss, :art?
    assert_not_predicate boss, :changed?
  end

  test "the database refuses a half-set picture, a lie about its size, a non-WebP and one past the ceiling" do
    boss = make_boss
    good = processed
    db_refuses { boss.update_columns(art_sha256: good.sha256) }
    db_refuses do
      boss.update_columns(art_content: good.content, art_width: 1, art_height: 1, art_byte_size: good.byte_size + 1, art_sha256: good.sha256)
    end
    db_refuses do
      boss.update_columns(art_content: png_bytes, art_width: 1, art_height: 1, art_byte_size: png_bytes.bytesize, art_sha256: good.sha256)
    end
    db_refuses do
      boss.update_columns(art_content: good.content, art_width: 1, art_height: 1, art_byte_size: good.byte_size, art_sha256: "xyz")
    end
    db_refuses do
      big = "RIFF".b + "\0\0\0\0".b + "WEBP".b + ("a".b * 5_000_000)
      boss.update_columns(art_content: big, art_width: 1, art_height: 1, art_byte_size: big.bytesize, art_sha256: good.sha256)
    end
    assert_not_predicate boss.reload, :art?
  end

  test "the database refuses alt text over 200 characters" do
    db_refuses { make_boss.update_columns(art_alt: "x" * 201) }
  end

  test "two admins saving the same boss: the second save is refused" do
    boss = make_boss
    stale = Boss.find(boss.id)
    boss.update!(name: "First")
    assert_raises(ActiveRecord::StaleObjectError) { stale.update!(name: "Second") }
    assert_equal "First", boss.reload.name
  end
end
