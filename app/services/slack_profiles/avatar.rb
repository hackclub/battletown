require "digest"
require "tempfile"
require "vips"

module SlackProfiles
  # Turns the bytes of a picture (from Slack, or a development fixture) into the one thing that is stored and served: a small square
  # WebP. It reuses the ship screenshot pipeline's parts (ShipImages::Processor): the type is found from the first bytes (JPEG, PNG,
  # WebP or GIF; the content type a server claims is never looked at, SVG and everything else is refused), libvips opens it with the
  # matching loader and the pixel count is read from the header before any pixel is decoded (a decompression bomb is refused cheaply),
  # then it is decoded as a stream (first frame only), turned upright, cropped to a centred square, scaled to SIZE px, and saved with
  # ALL metadata removed (EXIF, GPS, ICC, XMP, comments). Only decoded pixels are re-encoded, so a polyglot (a picture with a script
  # appended) loses the extra bytes. The original is never kept.
  #
  # Raises Rejected with a short code, never a message that carries file contents.
  module Avatar
    class Rejected < StandardError; end

    SIZE = 128
    QUALITY = 80
    MAX_INPUT_BYTES = Download::MAX_BYTES
    MAX_PIXELS = 16_000_000
    Processed = Data.define(:content, :byte_size, :sha256)

    module_function

    def call(bytes)
      bytes = bytes.to_s.b
      raise Rejected, "empty_image" if bytes.empty?
      raise Rejected, "too_large" if bytes.bytesize > MAX_INPUT_BYTES

      Tempfile.create([ "slack-avatar", ".bin" ], binmode: true) do |file|
        file.write(bytes)
        file.flush
        encode(file.path)
      end
    rescue Vips::Error => error
      Rails.logger.info("SlackProfiles: could not read a picture (#{error.class})")
      raise Rejected, "unreadable_image"
    end

    def encode(path)
      loader = ShipImages::Processor::LOADERS[ShipImages::Processor.sniff(path)] or raise Rejected, "not_an_image"
      image = Vips::Image.public_send(loader, path, access: :sequential, fail_on: :error)
      pixels = image.width.to_i * image.height.to_i
      raise Rejected, "too_many_pixels" unless pixels.positive? && pixels <= MAX_PIXELS

      square = image.thumbnail_image(SIZE, height: SIZE, crop: :centre)
      clean = ShipImages::Processor.without_metadata(square)
      buffer = ShipImages::Processor.strip_metadata_chunks(clean.webpsave_buffer(Q: QUALITY, strip: true))
      raise Rejected, "too_large" if buffer.bytesize > SlackProfile::MAX_PICTURE_BYTES

      Processed.new(content: buffer, byte_size: buffer.bytesize, sha256: Digest::SHA256.hexdigest(buffer))
    end
    private_class_method :encode
  end
end
