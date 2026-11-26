# The two ops tables of the analytics plan (section 5), created with the rest so one migration owns db/schema.rb. Neither refers to a person.
# `job_runs`: one row per run of a scheduled task (the name, when, how it ended, the integer counts it printed).
# `analytics_daily_snapshots`: stored daily aggregates (a number per key per day), because deleting people and changing ship statuses
# rewrites anything recomputed from the live tables.
class CreateJobRunsAndAnalyticsDailySnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :job_runs do |t|
      t.string :name, limit: 60, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.string :status, limit: 10, null: false, default: "running"
      t.string :error_class, limit: 80
      t.jsonb :counts, null: false, default: {}
    end
    add_index :job_runs, %i[name started_at], order: { started_at: :desc }
    add_check_constraint :job_runs, "status IN ('running', 'ok', 'failed')", name: "job_runs_status_check"
    add_check_constraint :job_runs, "jsonb_typeof(counts) = 'object'", name: "job_runs_counts_check"

    create_table :analytics_daily_snapshots do |t|
      t.date :day, null: false
      t.string :key, limit: 60, null: false
      t.bigint :value, null: false, default: 0
    end
    add_index :analytics_daily_snapshots, %i[day key], unique: true
  end
end
