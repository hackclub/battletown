module Bosses
  # The launch run: four weekly bosses, Friday to Thursday, starting Friday 2026-11-13. Placeholder names and health
  # (500 hours each) that an admin edits at /admin/bosses until each boss starts. Idempotent and never overwrites:
  # a boss that already exists for a week (edited or not) is left exactly as it is.
  module Seed
    FIRST_STARTS_ON = Date.new(2026, 11, 13)
    WEEKS = 4
    HP_SECONDS = 500 * 3600

    module_function

    # Returns the number of bosses created.
    def call
      Array.new(WEEKS) { |index| FIRST_STARTS_ON + (index * 7) }.count do |starts_on|
        Boss.find_or_create_by!(starts_on: starts_on) do |boss|
          boss.name = "Boss #{((starts_on - FIRST_STARTS_ON) / 7).to_i + 1}"
          boss.art_key = "placeholder"
          boss.ends_on = starts_on + 6
          boss.hp_seconds = HP_SECONDS
        end.previously_new_record?
      end
    end
  end
end
