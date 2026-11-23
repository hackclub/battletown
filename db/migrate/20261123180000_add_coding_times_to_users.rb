# Different days can have different reminder times ("5 pm on Monday, 6 pm on Sunday"). coding_time stays the usual
# time; coding_times holds only the overrides, { "monday" => "17:00" }, and a day without one uses coding_time.
class AddCodingTimesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :coding_times, :jsonb, default: {}, null: false
    add_check_constraint :users, "jsonb_typeof(coding_times) = 'object'", name: "users_coding_times_check"
  end
end
