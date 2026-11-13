class PagesController < ApplicationController
  def privacy
  end

  def terms
  end

  # The style guide: every colour, type style and component of the design on one page. It is a working reference, not
  # for the public, so anyone who is not a developer (development) or an admin gets a 404.
  def styleguide
    head :not_found unless Rails.env.development? || (signed_in? && current_user.admin?)
  end
end
