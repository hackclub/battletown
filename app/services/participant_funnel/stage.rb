class ParticipantFunnel
  # One person's place in the funnel, derived and never stored: the first step they have not reached (steps happen out of order, so the first gap, not
  # the furthest), or :completed, and since when they have been there (the latest step they did reach). Nil for someone who is not measured (staff, a
  # simulated or listed tester). Works for anyone who signed up before this existed: it reads the product tables.
  Stage = Data.define(:key, :label, :entered_at) do
    def self.for(user)
      row = ActiveRecord::Base.connection.select_one(
        ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, { id: user.id } ]), "ParticipantFunnel::Stage"
          SELECT funnel_stage, funnel_stage_entered_at FROM insights.funnel_facts
          WHERE person_id = (SELECT analytics_id FROM users WHERE users.id = :id)
        SQL
      )
      return unless row

      key = row["funnel_stage"].to_sym
      label = key == :completed ? "Completed the funnel" : ParticipantFunnel::STEPS.find { |step| step.key == key }.label
      new(key: key, label: label, entered_at: row["funnel_stage_entered_at"])
    end

    # Whole days since they reached their latest step.
    def days_stuck(now: Time.current) = entered_at ? ((now - entered_at.in_time_zone("UTC")) / 1.day).floor : nil
  end
end
