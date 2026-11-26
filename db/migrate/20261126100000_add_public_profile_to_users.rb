# Opt-in public profiles. Nothing about a person is visible to other players unless `profile_visible` is true (off by default).
# The public identity is a chosen `profile_name` (never the real name or email) and an opaque random `public_slug` for the URL,
# made the first time someone opts in; the numeric id never appears in a profile URL.
class AddPublicProfileToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :profile_visible, :boolean, default: false, null: false
    add_column :users, :profile_name, :string, limit: 30
    add_column :users, :public_slug, :string, limit: 12
    add_index :users, :public_slug, unique: true, where: "public_slug IS NOT NULL"
    add_check_constraint :users, "profile_name IS NULL OR char_length(profile_name) BETWEEN 1 AND 30", name: "users_profile_name_length_check"
    add_check_constraint :users, "NOT profile_visible OR (public_slug IS NOT NULL AND profile_name IS NOT NULL)", name: "users_profile_visible_needs_identity_check"
  end
end
