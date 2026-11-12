require "test_helper"
require_relative "../../support/ship_images_helper"

class ShipImages::ProcessorTest < ActiveSupport::TestCase
  include ShipImagesHelper

  def process(bytes, name: "pic.png", type: "image/png", config: ShipImages::Config.current)
    ShipImages::Processor.call(upload_file(bytes, name: name, type: type), config: config)
  end

  def config_with(**overrides)
    raw = Rails.application.config_for(:game).fetch(:ship_screenshots).merge(overrides)
    ShipImages::Config.from_hash(raw)
  end

  def assert_rejected(bytes, pattern = nil, **options)
    error = assert_raises(ShipImages::Rejected) { process(bytes, **options) }
    assert_match pattern, error.message if pattern
    error
  end

  # --- what is accepted, and what comes out ---

  test "a PNG becomes a WebP with its own size, size in bytes and SHA-256" do
    result = process(png_bytes(60, 30))
    assert_equal "RIFF", result.content.byteslice(0, 4)
    assert_equal "WEBP", result.content.byteslice(8, 4)
    assert_equal [ 60, 30 ], [ result.width, result.height ]
    assert_equal result.content.bytesize, result.byte_size
    assert_equal Digest::SHA256.hexdigest(result.content), result.sha256
    assert_equal Encoding::BINARY, result.content.encoding
  end

  test "JPEG, WebP and GIF are accepted too (a GIF by its first frame)" do
    { jpeg_bytes => "pic.jpg", webp_bytes => "pic.webp", gif_bytes => "pic.gif" }.each do |bytes, name|
      result = process(bytes, name: name)
      assert_equal "WEBP", result.content.byteslice(8, 4), name
      assert_equal [ 20, 10 ], [ result.width, result.height ], name
    end
  end

  test "the type comes from the bytes: a wrong name or content type does not matter" do
    assert_equal "WEBP", process(jpeg_bytes, name: "holiday.png", type: "image/png").content.byteslice(8, 4)
    assert_equal "WEBP", process(png_bytes, name: "no-extension", type: "application/octet-stream").content.byteslice(8, 4)
  end

  test "a long side over the limit is scaled down to it, keeping the shape, and a small picture is never scaled up" do
    big = process(png_bytes(3200, 1600))
    assert_equal [ 1600, 800 ], [ big.width, big.height ]
    tall = process(png_bytes(800, 4000))
    assert_equal [ 320, 1600 ], [ tall.width, tall.height ]
    small = process(png_bytes(120, 80))
    assert_equal [ 120, 80 ], [ small.width, small.height ]
  end

  test "the long-side limit and the quality come from the config" do
    result = process(png_bytes(1000, 500), config: config_with(max_edge_px: 400))
    assert_equal [ 400, 200 ], [ result.width, result.height ]
  end

  test "the stored copy carries no metadata: GPS EXIF is gone and so are EXIF, XMP and ICC chunks" do
    original = jpeg_with_gps_exif
    fixture_fields = Vips::Image.new_from_buffer(original, "").get_fields
    assert fixture_fields.any? { |field| field.include?("GPS") }, "the fixture must really carry GPS tags: #{fixture_fields.inspect}"

    result = process(original, name: "phone.jpg", type: "image/jpeg")
    stored = Vips::Image.webpload_buffer(result.content)
    assert_empty stored.get_fields.grep(/exif|gps|xmp|icc|orientation/i)
    assert_empty webp_chunks(result.content) & %w[EXIF XMP\  ICCP]
    assert_not_includes result.content, "GPS"
    assert_not_includes result.content, "Exif"
  end

  # libvips before 8.15 (Debian bookworm's 8.14, which the Docker image is built on) ignores `strip` for WebP and writes EXIF.
  test "metadata chunks the encoder wrote anyway are cut out of the WebP, flags and sizes included" do
    vp8x = "VP8X".b + [ 10 ].pack("V") + [ 0x2C ].pack("C") + "\0".b * 9
    exif = "EXIF".b + [ 5 ].pack("V") + "GPS!!".b + "\0".b
    xmp = "XMP ".b + [ 2 ].pack("V") + "ab".b
    image = "VP8 ".b + [ 3 ].pack("V") + "xyz".b + "\0".b
    body = vp8x + exif + xmp + image
    dirty = "RIFF".b + [ body.bytesize + 4 ].pack("V") + "WEBP".b + body

    clean = ShipImages::Processor.strip_metadata_chunks(dirty)
    assert_equal [ "VP8X", "VP8 " ], webp_chunks(clean)
    assert_equal 0, clean.getbyte(20) & 0x2C, "the ICC, EXIF and XMP flags are cleared"
    assert_equal clean.bytesize - 8, clean.byteslice(4, 4).unpack1("V")
    assert_not_includes clean, "GPS"
  end

  test "a picture is turned upright from its EXIF orientation before the metadata is dropped" do
    result = process(jpeg_with_gps_exif(40, 20, orientation: 6), name: "phone.jpg", type: "image/jpeg")
    assert_equal [ 20, 40 ], [ result.width, result.height ]
  end

  test "the same picture gives the same bytes, so duplicates can be told apart by SHA-256" do
    assert_equal process(png_bytes(30, 30)).sha256, process(png_bytes(30, 30)).sha256
    assert_not_equal process(png_bytes(30, 30)).sha256, process(png_bytes(30, 30, [ 1, 2, 3 ])).sha256
  end

  # --- what is refused ---

  test "text, SVG, an executable, a PDF and HEIC are refused whatever they are called" do
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><script>alert(1)</script></svg>)
    {
      "a text file" => "just some words",
      "SVG" => svg,
      "SVG with an XML header" => %(<?xml version="1.0"?>#{svg}),
      "a Windows executable" => "MZ\x90\x00\x03\x00\x00\x00".b + ("\x00".b * 64),
      "a PDF" => "%PDF-1.7\n1 0 obj\n<<>>\nendobj\n",
      "HEIC" => "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic".b,
      "HTML" => "<!DOCTYPE html><html><body><script>alert(1)</script></body></html>",
      "a shell script" => "#!/bin/sh\nrm -rf /\n"
    }.each do |label, body|
      %w[image/png image/jpeg image/svg+xml].each do |claimed|
        error = assert_raises(ShipImages::Rejected, "#{label} claiming #{claimed} must be refused") { process(body, name: "innocent.png", type: claimed) }
        assert_match(/PNG, JPEG, WebP or GIF/, error.message)
      end
    end
  end

  test "an empty file is refused" do
    assert_rejected "", /empty/
  end

  test "a file that only starts like a picture is refused as damaged, not stored" do
    assert_rejected "GIF89a<script>alert(1)</script>", /couldn't read/
    assert_rejected "\x89PNG\r\n\x1A\nnot really a png".b, /couldn't read/
    assert_rejected "\xFF\xD8\xFFthis is not a jpeg".b, /couldn't read/
    assert_rejected "RIFF\x04\x00\x00\x00WEBPjunk".b, /couldn't read/
  end

  test "a truncated picture is refused" do
    assert_rejected png_bytes(300, 300).byteslice(0, 40), /couldn't read/
  end

  test "a polyglot (a real picture with a script or an archive appended) is accepted but only its pixels survive" do
    script = "<script>alert(document.cookie)</script>"
    [ png_bytes + script, jpeg_bytes + script, gif_bytes + script ].each do |bytes|
      result = process(bytes)
      assert_not_includes result.content, "<script"
      assert_not_includes result.content, "alert("
      assert_equal "WEBP", result.content.byteslice(8, 4)
    end
    zipped = png_bytes + "PK\x03\x04".b + ("A".b * 200)
    assert_not_includes process(zipped).content, "PK\x03\x04".b
  end

  test "text inside a PNG chunk does not survive either" do
    marked = solid(10, 10)
    marked.set_type(GObject::GSTR_TYPE, "png-comment-0-Description", "<script>alert(1)</script> Jane Doe, 12 Main Street")
    bytes = marked.pngsave_buffer
    assert_includes Vips::Image.new_from_buffer(bytes, "").get_fields, "png-comment-0-Description", "the fixture must carry the text"
    stored = process(bytes).content
    assert_empty Vips::Image.webpload_buffer(stored).get_fields.grep(/comment|description/i)
    assert_not_includes stored, "Jane Doe"
  end

  # --- limits ---

  test "a picture over the pixel limit is refused from its header, before it is decoded" do
    bomb = png_bytes(6000, 6000)
    assert_operator bomb.bytesize, :<, 1_000_000, "a decompression bomb is tiny on the wire"
    error = assert_rejected(bomb, /36 megapixels.*limit is 24/)
    assert_no_match(/\.png|tmp/, error.message)
  end

  test "the pixel limit is exact and comes from the config" do
    one_megapixel = config_with(max_megapixels: 1)
    assert_equal [ 1000, 1000 ], process(png_bytes(1000, 1000), config: one_megapixel).then { |result| [ result.width, result.height ] }
    assert_raises(ShipImages::Rejected) { process(png_bytes(1001, 1000), config: one_megapixel) }
  end

  test "a file over the size limit is refused before anything is read" do
    tiny_limit = config_with(max_upload_bytes: 2000)
    big = png_bytes(100, 100) + ("\x00".b * 4000)
    error = assert_raises(ShipImages::Rejected) { process(big, config: tiny_limit) }
    assert_match(/limit is 0\.002 MB|MB; the limit/, error.message)
    assert_equal "WEBP", process(png_bytes(10, 10), config: tiny_limit).content.byteslice(8, 4)
  end

  test "the default limit is 5 MB per file" do
    assert_equal 5_000_000, ShipImages::Config.current.max_upload_bytes
    over = png_bytes + ("\x00".b * 5_000_000)
    assert_rejected over, /the limit is 5 MB/
  end

  test "libvips refuses untrusted loaders (SVG) as a second wall" do
    skip "this libvips has no block switch" unless Vips.respond_to?(:block_untrusted)
    assert_raises(Vips::Error) { Vips::Image.svgload_buffer("<svg xmlns='http://www.w3.org/2000/svg' width='5' height='5'/>") }
  end
end
