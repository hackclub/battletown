# Feature flags, on Flipper (https://www.flippercloud.io/docs). Every new feature ships switched OFF and stays dark
# (no rows, no messages, no coins, nothing shown) until the owner turns it on at /admin/flipper (admins only).
#
#   Features.enabled?(:team)                # everyone
#   Features.enabled?(:team, current_user)  # when an actor makes sense (the `admins` group lets staff dogfood a flag)
#
# An unknown name raises ArgumentError, so a typo fails loudly instead of quietly staying off. No flipper_features
# row or gate means off. If the flag store cannot be read (database down, tables not migrated yet) a flag counts as
# off and the problem is logged: a flagged-off feature must never be the thing that takes a page down.
# See docs/CONTRACT.md ("Feature flags").
module Features
  # The known flags, each with a short label. Add a new flag here, then gate its routes, pages, jobs and messages.
  KNOWN = {
    team: "Team bonus",
    quests: "Quests",
    returning: "Returning-user bonus",
    plinko: "Plinko",
    ship_screenshots: "Ship screenshots",
    merch_track: "Weekly merch track",
    email: "Email notifications",
    nps: "NPS survey",
    eligibility_gate: "Eligibility gate"
  }.freeze
  NAMES = KNOWN.keys.freeze

  class << self
    def enabled?(name, actor = nil)
      Flipper.enabled?(validate!(name), actor)
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.error("Features: could not read flag #{name}: #{error.class}")
      false
    end

    # The flag's symbol, or ArgumentError for a name that is not in KNOWN.
    def validate!(name)
      key = name.to_s.to_sym
      raise ArgumentError, "unknown feature #{name.inspect}; known: #{NAMES.join(', ')}" unless KNOWN.key?(key)

      key
    end

    # Makes every known flag appear in the Flipper UI (a feature with no gates is off). Idempotent, and a no-op when
    # the flag tables do not exist yet (db:prepare, schema load, assets:precompile) or the database is unreachable.
    def register_known!
      return unless ActiveRecord::Base.connection.data_source_exists?("flipper_features")

      NAMES.each { |name| Flipper.add(name) }
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("Features: flags not registered: #{error.class}")
    end
  end
end
