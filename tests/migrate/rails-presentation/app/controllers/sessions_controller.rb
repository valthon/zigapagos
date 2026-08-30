# Routed via `resource :session` (config/routes.rb). Since #176 that needs
# no `controller:` override: a singular resource routes to the PLURAL
# controller, which is this class, with its views in app/views/sessions/.
class SessionsController < ApplicationController
  # sessions/new.html.erb is a plain `form_with` -- no findings.
  def new
  end

  def create
    session = find_or_create_session
    redirect_to root_path
  end

  # #167 Stage 3: the sign-out half. The shared nav's
  # `button_to "Sign out", session_path, method: :delete` targets this
  # action. The generated AuthStatus island does NOT follow the redirect
  # below -- after `logout()` it calls `location.reload()`.
  def destroy
    reset_session
    redirect_to root_path
  end
end
