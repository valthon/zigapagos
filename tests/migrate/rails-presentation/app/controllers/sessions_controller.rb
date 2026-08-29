# Routed via `resource :session, controller: "sessions"` (see
# config/routes.rb's R13 comment: this parser does not pluralize a
# singular resource's controller, so the override is required to match
# this real, pluralized controller class).
class SessionsController < ApplicationController
  # sessions/new.html.erb is a plain `form_with` -- no findings.
  def new
  end

  def create
    session = find_or_create_session
    redirect_to root_path
  end
end
