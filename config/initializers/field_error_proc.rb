# Rails wraps an invalid form control (and its label) in <div class="field_with_errors">, which breaks the card, pill
# and grid layouts the design system builds around controls. Keep the markup bare instead. The control is still marked
# invalid for assistive technology (aria-invalid="true", unless the view already says so, as onboarding does); labels
# are left alone. Visible error text and styling come from .field--invalid / .field__error (docs/CONTRACT.md).
Rails.application.config.action_view.field_error_proc = proc do |html_tag, instance|
  next html_tag if instance.is_a?(ActionView::Helpers::Tags::Label) || html_tag.include?("aria-invalid") ||
                   html_tag.match?(/type="(radio|checkbox|hidden)"/)

  html_tag.sub(/\A<(input|textarea|select)\b/) { "<#{$1} aria-invalid=\"true\"" }.html_safe # rubocop:disable Rails/OutputSafety
end
