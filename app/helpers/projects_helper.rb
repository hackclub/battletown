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
end
