# One run of a scheduled task: its name, when it started and finished, how it ended and the integer counts it printed. It refers to no person.
# Never pruned (plans/analytics.md, sections 1.7 and 5). Every scheduled rake task wraps its body in `JobRun.record`; `JobSchedule` reads the rows
# back to say which tasks have gone quiet.
class JobRun < ApplicationRecord
  STATUSES = %w[running ok failed].freeze
  NAME_FORMAT = /\A[a-z][a-z0-9_]*(:[a-z][a-z0-9_]*)+\z/
  COUNT_KEY_FORMAT = /\A[a-z][a-z0-9_]{0,39}\z/
  MAX_COUNTS = 30

  validates :status, inclusion: { in: STATUSES }

  # Wraps a task body: writes a `running` row, yields a hash for the body to fill with the numbers it prints, then writes `ok` or `failed`
  # (the exception's class name, never its message) and lets the exception, `exit 1` or `abort` carry on exactly as before, so a scheduled
  # run's exit code does not change. Recording is best effort: if the row cannot be written the task still runs, and a failure is logged by class.
  #
  #   JobRun.record("game:settle") do |counts|
  #     counts.merge!(Game::Settle.all)
  #     exit 1 if counts[:errors].positive?
  #   end
  def self.record(name)
    raise ArgumentError, "job name #{name.inspect} must look like game:settle" unless name.is_a?(String) && name.match?(NAME_FORMAT) && name.length <= 60

    run = start(name)
    counts = {}
    completed = false
    begin
      result = yield counts
      completed = true
      result
    ensure
      finish(run, counts, completed ? nil : $!)
    end
  end

  # Keeps only what a count may be: a lowercase key and a whole number (true and false become 1 and 0). Anything else is dropped.
  def self.clean_counts(raw)
    raw.to_h.each_with_object({}) do |(key, value), clean|
      key = key.to_s
      number = [ true, false ].include?(value) ? (value ? 1 : 0) : value
      clean[key] = number if key.match?(COUNT_KEY_FORMAT) && number.is_a?(Integer) && clean.size < MAX_COUNTS
    end
  end

  def self.start(name)
    create!(name: name, started_at: Time.current, status: "running")
  rescue StandardError => error
    Rails.logger.error("JobRun: could not record the start of #{name}: #{error.class}")
    nil
  end
  private_class_method :start

  def self.finish(run, counts, error)
    return unless run

    passed = error.nil? || (error.is_a?(SystemExit) && error.success?)
    run.update!(finished_at: Time.current, status: passed ? "ok" : "failed", error_class: passed ? nil : error.class.name.to_s.first(80),
                counts: clean_counts(counts))
  rescue StandardError => problem
    Rails.logger.error("JobRun: could not record the end of #{run.name}: #{problem.class}")
  end
  private_class_method :finish

  # Seconds the run took, or nil while it is running (or if the process died before it could say).
  def duration_seconds = finished_at && (finished_at - started_at).round(3)

  def ok? = status == "ok"
end
