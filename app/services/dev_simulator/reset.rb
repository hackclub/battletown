module DevSimulator
  # Removes the simulated players (hca_uid "sim!...") and everything about them, one person at a time through
  # Privacy::Deleter, the same code the data-deletion API runs, so the database cascades to every table that references a
  # user (a new table is covered by test/models/privacy_schema_guard_test.rb). Nobody else's rows are touched.
  #
  # `clear_defeat: true` also clears `defeated_at` on the boss whose week covers `today`. The game never does that (a boss
  # that fell stays down), but without it a local boss could be beaten only once per week; it is off unless asked for.
  class Reset
    Result = Data.define(:removed, :cleared_defeat)

    def self.call(**args) = new(**args).call

    def initialize(today:, clear_defeat: false)
      @today = today
      @clear_defeat = clear_defeat
    end

    def call
      DevSimulator.check_local_database!
      uids = DevSimulator.players.order(:id).pluck(:hca_uid)
      uids.each do |uid|
        Privacy::Deleter.new(Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: uid)).call(dry_run: false)
      end
      Result.new(removed: uids.size, cleared_defeat: @clear_defeat ? clear_defeat : 0)
    end

    private

    def clear_defeat = Boss.covering(@today).where.not(defeated_at: nil).update_all(defeated_at: nil, updated_at: Time.current)
  end
end
