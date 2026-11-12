module Privacy
  # Deletes everything this app holds about a data subject (docs/PRIVACY_API.md). The users row is deleted and the
  # database cascades to every table that references it (schema guard: test/models/privacy_schema_guard_test.rb).
  # A dry run uses the exact same code: it really deletes inside a transaction, reads how many rows each table
  # lost, then rolls back, so the numbers an operator reviews are the numbers the real run produces.
  #
  # Counts are per table name, taken from Postgres's own per-transaction delete counters (cascades included).
  # They contain no personal data.
  class Deleter
    Result = Data.define(:found, :deleted, :retained)

    # Records that are kept (detached from the person) because other people depend on them. None exist yet. A rule is
    # { type: "...", reason: "...", count: ->(user_ids) { Integer } }; the response lists each non-zero one as
    # { type:, count:, reason: }. A rule that keeps rows must also stop the cascade from deleting them.
    RETENTION_RULES = [].freeze

    # The yeeter gives up after 15 seconds, so asking Hackatime to revoke tokens gets a short leash: each call times
    # out after REVOKE_TIMEOUT seconds and no new call starts once REVOKE_BUDGET seconds have gone.
    REVOKE_TIMEOUT = 2
    REVOKE_BUDGET = 5

    def initialize(subject)
      @subject = subject
    end

    def call(dry_run:)
      user_ids = SubjectFinder.new(@subject).user_ids
      return Result.new(found: false, deleted: {}, retained: []) if user_ids.empty?

      revoke_hackatime_tokens(user_ids) unless dry_run
      result = nil
      # requires_new: a real transaction (or savepoint) so the dry-run rollback below is always honoured.
      ActiveRecord::Base.transaction(requires_new: true) do
        before = delete_counters
        retained = retained_records(user_ids)
        removed = User.where(id: user_ids).delete_all
        deleted = delete_counters.to_h { |table, count| [ table, count - before.fetch(table, 0) ] }.select { |_, count| count.positive? }
        # The counters must account for every user we meant to delete; if not, refuse rather than report wrongly.
        raise "delete counters disagree with the users deleted" unless removed == user_ids.size && deleted["users"] == removed

        result = Result.new(found: true, deleted: deleted.sort.to_h, retained: retained)
        raise ActiveRecord::Rollback if dry_run
      end
      result
    end

    private

    # Best effort, before the delete (the tokens are gone after it) and outside its transaction. Hackatime being down
    # or slow, or a token that cannot be read, never blocks the deletion. Never on a dry run (or an export).
    def revoke_hackatime_tokens(user_ids)
      deadline = Time.current + REVOKE_BUDGET
      HackatimeConnection.where(user_id: user_ids).find_each do |connection|
        [ connection.access_token, connection.refresh_token ].compact_blank.each do |token|
          break if Time.current >= deadline

          Hackatime::Client.revoke(token, timeout: REVOKE_TIMEOUT)
        end
      rescue StandardError
        next
      end
    rescue StandardError
      nil
    end

    def delete_counters
      ActiveRecord::Base.connection.select_rows(
        "SELECT relname, n_tup_del FROM pg_stat_xact_user_tables WHERE schemaname = current_schema()"
      ).to_h { |table, count| [ table, count.to_i ] }
    end

    def retained_records(user_ids)
      RETENTION_RULES.filter_map do |rule|
        count = rule.fetch(:count).call(user_ids)
        { type: rule.fetch(:type), count: count, reason: rule.fetch(:reason) } if count.positive?
      end
    end
  end
end
