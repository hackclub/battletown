# Staff-only UI: green for development-only controls, orange for admin-only ones (like Hack Club Bank).
# Always wrap staff UI in one of these helpers so it cannot reach ordinary users; the gating is server-side.
# See docs/CONTRACT.md ("Staff-only UI") and app/assets/stylesheets/staff.css.
module StaffHelper
  # Renders the block only when Rails.env is development.
  #   <%= dev_tool(:div) { button_to "Dev login", dev_login_path } %>
  # `label: false` drops the "Dev" tag when the content already says so (e.g. the Dev login button).
  def dev_tool(tag = :div, label: true, **options, &block)
    return unless Rails.env.development?

    staff_tool("dev", "Dev", tag, label, options, &block)
  end

  # Renders the block only for a signed-in admin (User#admin?, currently always false).
  def admin_tool(tag = :div, label: true, **options, &block)
    return unless signed_in? && current_user.admin?

    staff_tool("admin", "Admin", tag, label, options, &block)
  end

  private

  def staff_tool(kind, name, tag, label, options, &block)
    options[:class] = class_names("#{kind}-only", ("#{kind}-only--unlabelled" unless label), options[:class])
    content_tag(tag, options) do
      # Real text for screen readers; the visible CSS tag has empty content alt text so it is not read twice.
      safe_join([ (content_tag(:span, "#{name} only: ", class: "visually-hidden") if label), capture(&block) ].compact)
    end
  end
end
