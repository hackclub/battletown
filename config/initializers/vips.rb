# Screenshot uploads are decoded by libvips (ShipImages::Processor). Refuse its loaders that are unsafe for untrusted input
# (SVG, PDF and other document or vector formats, which can read other files or fetch URLs) outright, as a second wall behind
# the magic-byte check that only lets JPEG, PNG, WebP and GIF through. libvips comes with the Docker image (Dockerfile); if it is
# missing the app still boots (the flag is off by default) and `bin/rails ship_images:check` says what is wrong.
begin
  require "vips"
  Vips.block_untrusted(true) if Vips.respond_to?(:block_untrusted)
rescue LoadError => error
  Rails.logger.warn("libvips is not available (#{error.class}): ship screenshots cannot be processed")
end
