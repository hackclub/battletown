# A boss can have its own picture, uploaded by staff at /admin/bosses so the boss can change every week without a deploy. The
# picture is the re-encoded WebP that ShipImages::Processor produces (the original upload is never kept), kept in the row like a
# shop item's; list queries leave the bytes out (Boss.without_art_content). A boss with no picture keeps using the built-in one
# named by art_key. Nothing here is about a person. `lock_version` makes two admins saving the same boss at once a friendly
# "someone else changed it" instead of a silent overwrite.
class AddArtToBosses < ActiveRecord::Migration[8.1]
  def change
    change_table :bosses, bulk: true do |t|
      t.binary :art_content
      t.integer :art_width
      t.integer :art_height
      t.integer :art_byte_size
      t.string :art_sha256, limit: 64
      t.string :art_alt, limit: 200
      t.integer :lock_version, null: false, default: 0
    end

    add_check_constraint :bosses, "art_alt IS NULL OR char_length(art_alt) <= 200", name: "bosses_art_alt_check"
    # A picture is all or nothing (the alt text is checked by the model), no bigger than ship screenshots may be, and really is a
    # WebP file (RIFF....WEBP).
    add_check_constraint :bosses,
                         "(art_content IS NULL AND art_width IS NULL AND art_height IS NULL AND art_byte_size IS NULL AND art_sha256 IS NULL) OR " \
                         "(art_content IS NOT NULL AND art_width > 0 AND art_height > 0 AND art_byte_size BETWEEN 1 AND 5000000 AND " \
                         "octet_length(art_content) = art_byte_size AND art_sha256 ~ '^[0-9a-f]{64}$' AND " \
                         "substring(art_content from 1 for 4) = '\\x52494646'::bytea AND substring(art_content from 9 for 4) = '\\x57454250'::bytea)",
                         name: "bosses_art_check"
  end
end
