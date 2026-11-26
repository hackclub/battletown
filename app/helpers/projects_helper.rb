module ProjectsHelper
  FIELD_LABELS = { name: "Name", kind: "Type", idea: "Idea", repo_url: "GitHub link", demo_url: "Demo link", base: "" }.freeze

  def project_kind_info(kind) = OnboardingsHelper::PROJECT_KINDS.fetch(kind, OnboardingsHelper::PROJECT_KINDS.fetch("undecided"))

  def project_kind_options = OnboardingsHelper::PROJECT_KINDS.map { |kind, info| [ "#{info[:emoji]} #{info[:name]}", kind ] }

  # An outbound link to a project's GitHub or demo URL. They are validated as https when saved; this checks
  # again at render time so nothing but an https URL can ever become an href.
  def project_external_link(label, url)
    return unless url.to_s.start_with?("https://")

    link_to label, url.to_s, rel: "noopener noreferrer", target: "_blank"
  end

  # "Name is too long ..." style sentences with the labels people see on the form.
  def project_error_messages(record)
    record.errors.map do |error|
      label = FIELD_LABELS.fetch(error.attribute, error.attribute.to_s.humanize)
      label.empty? ? error.message : "#{label} #{error.message}"
    end
  end

  # How many ships a project card lists (the newest ones); the count above the list is always all of them.
  SHIP_HISTORY_LIMIT = 5

  # The local date a ship counts from (submitted, or created for a draft) in the signed-in person's own time zone, "Nov 11" or
  # "Nov 11, 2025" when it is not this year. Uses the current user, so a card never loads each ship's owner.
  def project_ship_date(ship)
    stamp = ship.submitted_at || ship.created_at
    date = Game::Days.local_date(stamp, current_user.time_zone)
    date.strftime(date.year == Game::Days.local_date(Time.current, current_user.time_zone).year ? "%b %-d" : "%b %-d, %Y")
  end

  # The hours a ship is about: what staff approved once it is approved, otherwise what was coded.
  def project_ship_hours(ship) = ship_hours(ship.status_approved? ? ship.approved_seconds : ship.coded_seconds)
end
