# Screenshots a teen attaches to a ship (flag `ship_screenshots`, docs/CONTRACT.md "Ship screenshots"). Up to three per
# ship, stored as the RE-ENCODED WebP only (never the original upload, so no EXIF/GPS and no file name survive) and
# served by an app controller to the owner and staff. Deleted with the ship and with the user by the database
# (ON DELETE CASCADE), so the data-deletion API stays truthful.
#
# The byte_size ceiling (5,000,000) and the three positions are hard limits of the schema; config/game.yml
# (`ship_screenshots:`) can lower the upload limit but never raise it above the ceiling.
class CreateShipImages < ActiveRecord::Migration[8.1]
  def change
    create_table :ship_images do |t|
      t.references :ship, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.integer :position, null: false
      t.binary :content, null: false
      t.integer :width, null: false
      t.integer :height, null: false
      t.integer :byte_size, null: false
      t.string :sha256, null: false, limit: 64
      t.string :alt, limit: 140
      t.datetime :created_at, null: false
    end

    add_index :ship_images, [ :ship_id, :position ], unique: true
    add_index :ship_images, [ :ship_id, :sha256 ], unique: true
    add_check_constraint :ship_images, "position BETWEEN 1 AND 3", name: "ship_images_position_check"
    add_check_constraint :ship_images, "byte_size BETWEEN 1 AND 5000000", name: "ship_images_byte_size_check"
    add_check_constraint :ship_images, "octet_length(content) = byte_size", name: "ship_images_content_size_check"
    add_check_constraint :ship_images, "width > 0 AND height > 0", name: "ship_images_dimensions_check"
    add_check_constraint :ship_images, "sha256 ~ '^[0-9a-f]{64}$'", name: "ship_images_sha256_check"
    add_check_constraint :ship_images, "alt IS NULL OR char_length(alt) <= 140", name: "ship_images_alt_check"
  end
end
