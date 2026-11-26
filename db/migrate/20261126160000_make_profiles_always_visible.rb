# Profiles are always visible to signed-in, onboarded players: there is no opt-in and no opt-out (owner decision, projects/battletown/DECISIONS.md).
# So every user needs an address (`public_slug`, opaque, unique) and the "is it switched on" column goes. What this does:
#
#   up    1. gives every user without a `public_slug` a random one: 11 characters of 0-9 a-z, checked against the existing ones in Ruby and
#            written with bound values (no string built into SQL); the unique index is the backstop
#         2. makes `users.public_slug` NOT NULL (the unique index is kept)
#         3. drops the check constraint that tied visibility to a slug and a name, then the `users.profile_visible` column
#            (`profile_name` stays: it is the optional display name the player chose, at most 30 characters)
#         4. makes "Use my Slack name and picture" ON for new slack_profiles rows (rows that already exist keep their values)
#   down  puts the column back as false for everybody (nobody becomes visible by a rollback), restores the constraint, lets `public_slug`
#         be NULL again and the Slack choice default OFF. Slugs given by `up` stay (they are only an address).
class MakeProfilesAlwaysVisible < ActiveRecord::Migration[8.1]
  SLUG_LENGTH = 11
  CONSTRAINT = "users_profile_visible_needs_identity_check".freeze

  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  def up
    backfill_slugs
    change_column_null :users, :public_slug, false
    remove_check_constraint :users, name: CONSTRAINT
    remove_column :users, :profile_visible
    change_column_default :slack_profiles, :use_name, from: false, to: true
    change_column_default :slack_profiles, :use_picture, from: false, to: true
  end

  def down
    change_column_default :slack_profiles, :use_picture, from: true, to: false
    change_column_default :slack_profiles, :use_name, from: true, to: false
    add_column :users, :profile_visible, :boolean, default: false, null: false
    add_check_constraint :users, "NOT profile_visible OR (public_slug IS NOT NULL AND profile_name IS NOT NULL)", name: CONSTRAINT
    change_column_null :users, :public_slug, true
  end

  private

  def backfill_slugs
    MigrationUser.reset_column_information
    taken = MigrationUser.where.not(public_slug: nil).pluck(:public_slug).to_set
    MigrationUser.where(public_slug: nil).select(:id).find_each do |user|
      slug = new_slug
      slug = new_slug while taken.include?(slug)
      taken << slug
      MigrationUser.where(id: user.id).update_all(public_slug: slug)
    end
  end

  def new_slug = SecureRandom.random_number(36**SLUG_LENGTH).to_s(36).rjust(SLUG_LENGTH, "0")
end
