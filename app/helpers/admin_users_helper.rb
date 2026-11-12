# Words and chips for the staff user pages (app/views/admin/users, admin/user_*): the same wording everywhere.
module AdminUsersHelper
  VERIFICATION_BADGES = { "verified" => "badge--success", "pending" => "badge--info", "needs_submission" => "badge--muted",
                          "ineligible" => "badge--danger" }.freeze
  VERIFICATION_TEXT = { "verified" => "Verified", "pending" => "Pending", "needs_submission" => "Not submitted", "ineligible" => "Ineligible" }.freeze

  # "45 min", "1 h 05 min", "-30 min", "0 min": coded time for staff tables.
  def admin_duration(seconds)
    minutes = (seconds.to_i.abs / 60.0).round
    text = minutes >= 60 ? format("%d h %02d min", minutes / 60, minutes % 60) : "#{minutes} min"
    seconds.to_i.negative? && minutes.positive? ? "-#{text}" : text
  end

  def admin_person_name(display_name, id) = display_name.presence || "No name (##{id})"

  def admin_verification_badge(status)
    admin_badge(VERIFICATION_TEXT.fetch(status, status.to_s.humanize), VERIFICATION_BADGES.fetch(status, "badge--muted"))
  end

  def admin_eligible_badge(eligible) = eligible ? admin_badge("YSWS eligible", "badge--success") : admin_badge("Not eligible", "badge--muted")

  def admin_yes_no_badge(value, yes: "Yes", no: "No") = value ? admin_badge(yes, "badge--success") : admin_badge(no, "badge--muted")

  def admin_utc(time, format = "%-d %b %Y %H:%M") = time ? "#{time.utc.strftime(format)} UTC" : "never"

  # A signed coin or second amount with an explicit plus sign for gains ("+20", "-5").
  def admin_signed(number) = number.to_i.positive? ? "+#{number}" : number.to_s

  def admin_reference_text(transaction)
    transaction.reference_type.present? ? "#{transaction.reference_type} ##{transaction.reference_id}" : ""
  end

  def admin_sort_options = AdminUsers::Directory::SORT_LABELS.map { |key, label| [ label, key ] }

  def admin_tristate_options(yes: "Yes", no: "No", any: "Any")
    [ [ any, "" ], [ yes, "yes" ], [ no, "no" ] ]
  end
end
