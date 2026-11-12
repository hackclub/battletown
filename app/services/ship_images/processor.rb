require "digest"
require "vips"

module ShipImages
  # Turns one uploaded file into the WebP that is stored (flag `ship_screenshots`). Called for one file at a time.
  #
  #  1. The size is checked from the temp file before a byte is read, then the TYPE from the first bytes (magic
  #     bytes: JPEG, PNG, WebP or GIF; the content type and the file name the browser sent are never looked at, and SVG,
  #     HEIC and everything else are refused).
  #  2. libvips opens the file with the loader that matches those bytes (never by guessing) and the pixel count is
  #     read from the header, before any pixel is decoded, so a decompression bomb is refused cheaply.
  #  3. It is decoded as a stream (first frame only for a GIF), turned upright from its EXIF orientation, scaled down
  #     (never up) to `max_edge_px`, and saved as WebP with ALL metadata stripped (EXIF, GPS, ICC, XMP, comments).
  #
  # The result is what gets stored; a polyglot (a valid picture with a script or archive appended) loses the extra
  # bytes because only decoded pixels are re-encoded.
  module Processor
    module_function

    # The loader per kind and the first bytes that identify it.
    LOADERS = { jpeg: :jpegload, png: :pngload, webp: :webpload, gif: :gifload }.freeze
    HEAD_BYTES = 16

    def call(upload, config: Config.current)
      path = path_of(upload)
      check_size!(path, config)
      loader = LOADERS.fetch(sniff(path)) { raise Rejected, "That doesn't look like a PNG, JPEG, WebP or GIF picture. SVG and HEIC aren't supported: take a screenshot or export a PNG instead." }
      encode(path, loader, config)
    rescue Vips::Error => error
      Rails.logger.info("ShipImages: could not read an upload (#{error.class})")
      raise Rejected, "We couldn't read that picture. It may be damaged: try saving it again as a PNG or JPEG."
    end

    def path_of(upload)
      file = upload.respond_to?(:tempfile) ? upload.tempfile : upload
      path = file.respond_to?(:path) ? file.path : file.to_s
      raise Rejected, "That wasn't a file we could read." unless path.present? && File.file?(path)

      path
    end

    def check_size!(path, config)
      size = File.size(path)
      raise Rejected, "That file is empty." if size.zero?
      return if size <= config.max_upload_bytes

      raise Rejected, "That file is #{format('%.1f', size / 1_000_000.0)} MB; the limit is #{format('%g', config.max_upload_bytes / 1_000_000.0)} MB for each screenshot."
    end

    # The kind of picture by its first bytes, or nil.
    def sniff(path)
      head = File.binread(path, HEAD_BYTES).to_s.b
      return :jpeg if head.start_with?("\xFF\xD8\xFF".b)
      return :png if head.start_with?("\x89PNG\r\n\x1A\n".b)
      return :gif if head.start_with?("GIF87a".b, "GIF89a".b)
      return :webp if head.bytesize >= 12 && head.byteslice(0, 4) == "RIFF".b && head.byteslice(8, 4) == "WEBP".b

      nil
    end

    def encode(path, loader, config)
      # Sequential access streams the pixels, so a large picture is never held whole. fail_on: :error makes a truncated
      # or corrupt file an error instead of a half-grey picture. A GIF or WebP loads its first frame only.
      image = Vips::Image.public_send(loader, path, access: :sequential, fail_on: :error)
      too_big!(image, config)
      scaled = image.thumbnail_image(config.max_edge_px, height: config.max_edge_px, size: :down)
      buffer = scaled.webpsave_buffer(Q: config.webp_quality, strip: true)
      raise Rejected, "That picture is still too big after shrinking it. Try a smaller one." if buffer.bytesize > config.max_upload_bytes

      describe(buffer)
    end

    def too_big!(image, config)
      pixels = image.width.to_i * image.height.to_i
      return if pixels.positive? && pixels <= config.max_pixels

      raise Rejected, "That picture is too large (#{format('%.0f', pixels / 1_000_000.0)} megapixels). The limit is #{config.max_megapixels} megapixels: make it smaller and try again."
    end

    # Reads the stored copy's own header, so the numbers kept are those of the bytes kept.
    def describe(buffer)
      stored = Vips::Image.webpload_buffer(buffer)
      Processed.new(content: buffer, width: stored.width, height: stored.height, byte_size: buffer.bytesize, sha256: Digest::SHA256.hexdigest(buffer))
    end
  end
end
