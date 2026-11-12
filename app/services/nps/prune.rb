module Nps
  # Retention: comments are free text from teens and can hold personal data, so they are emptied (set to NULL) once they are
  # older than `nps.comment_retention_days`. The scores stay: they are numbers about no one. Safe to repeat. Runs whether or
  # not the `nps` flag is on, because deleting data must never depend on a feature switch.
  module Prune
    module_function

    # How many comments were emptied.
    def call(now: Time.current, config: Config.current)
      NpsResponse.where.not(comment: nil).where(answered_at: ...(now - config.comment_retention_days.days)).update_all(comment: nil, updated_at: now)
    end
  end
end
