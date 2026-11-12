# Operator tools for ship screenshots (app/services/ship_images/**; flag `ship_screenshots`). Print counts only.
namespace :ship_images do
  desc "Delete screenshots of ships withdrawn more than ship_screenshots.withdrawn_retention_days ago, and any orphaned or mismatched rows (safe to repeat; a no-op while the flag is off)"
  task prune: :environment do
    result = ShipImages::Prune.call
    if result.skipped
      puts "ship_images:prune skipped: the ship_screenshots flag is off"
    else
      puts "ship_images:prune withdrawn=#{result.withdrawn} orphaned=#{result.orphaned} mismatched=#{result.mismatched}"
    end
  end

  desc "Check that libvips can do what screenshot processing needs (JPEG, PNG, WebP and GIF readers, WebP writer). Exits 1 if not"
  task check: :environment do
    needed = %w[jpegload pngload webpload gifload webpsave_buffer thumbnail_image]
    missing = needed.reject { |name| Vips.type_find("VipsOperation", name).to_i.positive? }
    puts "ship_images:check libvips=#{Vips::LIBRARY_VERSION} missing=#{missing.join(',').presence || 'none'}"
    exit 1 if missing.any?
  end
end
