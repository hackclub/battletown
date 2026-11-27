class PagesController < ApplicationController
  def privacy
  end

  def terms
  end

  # /docs is the first page; /docs/<slug> the others (the routes only match known slugs).
  def docs
    @page = DocsHelper::PAGES.find { |page| page.slug == (params[:page] || "start") }
  end
end
