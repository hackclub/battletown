module DevSimulatorHelper
  # Whether the dashboard shows the event simulator: only in development AND only with a database on this machine (the
  # simulator writes made-up players into it). False in test and production, so the panel is never in the page there.
  def dev_simulator? = Rails.env.development? && DevSimulator.local_database?
end
