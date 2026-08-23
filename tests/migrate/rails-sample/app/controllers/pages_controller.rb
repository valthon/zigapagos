class PagesController < ApplicationController
  # A1 fixture: this view (app/views/pages/about.html.erb) is entirely
  # static on its own. `pages` has no layout of its own, so it falls back
  # to layouts/application.html.erb -- which carries a request-state marker
  # -- and must classify unresolved because of the LAYOUT, not the view.
  def about; end
end
