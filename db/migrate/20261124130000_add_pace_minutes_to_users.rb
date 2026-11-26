# How long a person pledges to code on each of their coding days (the "pace" the dashboard's prize check is measured against,
# like Save Point's daily pace). Null until chosen: the app then assumes the default.
class AddPaceMinutesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :pace_minutes, :integer
    add_check_constraint :users, "pace_minutes IS NULL OR pace_minutes IN (15, 30, 45, 60, 90, 120, 180, 240)", name: "users_pace_minutes_check"
  end
end
