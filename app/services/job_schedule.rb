# Which scheduled tasks have gone quiet, from the JobRun rows and config/job_schedule.yml (the cron table in the deploy runbook). Read by the
# admin analytics page. Reads two small queries (the newest run and the newest success of each task) and writes nothing.
#
#   JobSchedule.status          # every scheduled task, with its last run, last success and a state
#   JobSchedule.stale           # only the ones whose last success is older than STALE_FACTOR times their interval
#
# States: `ok` (a success within the allowance), `stale` (a success, but too old), `never_run` (no run recorded: the cron job may not exist yet),
# `off` (its feature flag is off and it has not run lately, which is expected).
class JobSchedule
  STALE_FACTOR = 2
  Entry = Data.define(:name, :interval_minutes, :flag, :state, :last_run_at, :last_status, :last_error_class, :last_duration_seconds, :last_success_at) do
    def stale? = state == :stale
  end

  class << self
    def status(now: Time.current) = new(now).entries

    def stale(now: Time.current) = status(now: now).select(&:stale?)

    # The scheduled tasks: name => { interval_minutes:, flag: }.
    def jobs = @jobs ||= YAML.safe_load_file(Rails.root.join("config/job_schedule.yml"), symbolize_names: true).fetch(:jobs).transform_keys(&:to_s)
  end

  def initialize(now)
    @now = now
  end

  def entries
    names = self.class.jobs.keys
    latest = JobRun.where(name: names).select("DISTINCT ON (name) name, started_at, finished_at, status, error_class")
                   .order(:name, started_at: :desc).index_by(&:name)
    successes = JobRun.where(name: names, status: "ok").group(:name).maximum(:finished_at)
    self.class.jobs.map { |name, job| entry(name, job, latest[name], successes[name]) }
  end

  private

  def entry(name, job, last, last_success)
    Entry.new(name: name, interval_minutes: job.fetch(:interval_minutes), flag: job[:flag]&.to_sym, state: state(job, last_success),
              last_run_at: last&.started_at, last_status: last&.status, last_error_class: last&.error_class,
              last_duration_seconds: last&.finished_at && (last.finished_at - last.started_at).round(3), last_success_at: last_success)
  end

  def state(job, last_success)
    state = raw_state(job, last_success)
    flag_off = job[:flag] && !Features.enabled?(job[:flag])
    flag_off && state != :ok ? :off : state
  end

  def raw_state(job, last_success)
    return :never_run unless last_success

    @now - last_success > STALE_FACTOR * job.fetch(:interval_minutes).minutes ? :stale : :ok
  end
end
