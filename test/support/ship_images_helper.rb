require "vips"

# Picture fixtures for the screenshot tests, made in memory with libvips (no binary files are committed).
module ShipImagesHelper
  # A flat-colour picture; `color` is [r, g, b].
  def solid(width, height, color = [ 200, 40, 40 ])
    Vips::Image.black(width, height).new_from_image(color).copy(interpretation: :srgb)
  end

  def png_bytes(width = 20, height = 10, color = [ 200, 40, 40 ]) = solid(width, height, color).pngsave_buffer

  def jpeg_bytes(width = 20, height = 10, color = [ 40, 120, 200 ]) = solid(width, height, color).jpegsave_buffer(Q: 90)

  def gif_bytes(width = 20, height = 10, color = [ 40, 200, 40 ]) = solid(width, height, color).gifsave_buffer

  def webp_bytes(width = 20, height = 10, color = [ 120, 40, 200 ]) = solid(width, height, color).webpsave_buffer

  # A JPEG carrying an EXIF block with GPS tags (a latitude and longitude reference) and an orientation, built by hand so the
  # fixture does not depend on how libvips writes EXIF. The block goes in as an APP1 segment right after the SOI marker.
  def jpeg_with_gps_exif(width = 40, height = 20, orientation: 1)
    gps_ifd_offset = 8 + 2 + (2 * 12) + 4
    tiff = "II".b + [ 42, 8 ].pack("vV")
    tiff << [ 2 ].pack("v")
    tiff << [ 0x0112, 3, 1, orientation, 0 ].pack("vvVvv")
    tiff << [ 0x8825, 4, 1, gps_ifd_offset ].pack("vvVV")
    tiff << [ 0 ].pack("V")
    tiff << [ 2 ].pack("v")
    tiff << [ 0x0001, 2, 2 ].pack("vvV") << "N\0\0\0".b
    tiff << [ 0x0003, 2, 2 ].pack("vvV") << "E\0\0\0".b
    tiff << [ 0 ].pack("V")
    app1 = "Exif\0\0".b + tiff
    jpeg = jpeg_bytes(width, height)
    jpeg.byteslice(0, 2) + "\xFF\xE1".b + [ app1.bytesize + 2 ].pack("n") + app1 + jpeg.byteslice(2..)
  end

  # The RIFF chunk names of a WebP, to prove no EXIF, XMP or ICC chunk was written.
  def webp_chunks(bytes)
    chunks = []
    offset = 12
    while offset + 8 <= bytes.bytesize
      name = bytes.byteslice(offset, 4)
      size = bytes.byteslice(offset + 4, 4).unpack1("V")
      chunks << name
      offset += 8 + size + (size.odd? ? 1 : 0)
    end
    chunks
  end

  # A Tempfile holding `bytes`, named like a real upload would be.
  def upload_file(bytes, name: "screenshot.png", type: "image/png")
    tempfile = Tempfile.new([ File.basename(name, ".*"), File.extname(name) ], binmode: true)
    tempfile.write(bytes)
    tempfile.flush
    (@upload_tempfiles ||= []) << tempfile
    Rack::Test::UploadedFile.new(tempfile.path, type, true, original_filename: name)
  end
end
