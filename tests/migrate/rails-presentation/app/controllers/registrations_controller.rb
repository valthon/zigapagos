# Routed via `resource :registration, controller: "registrations"` -- same
# #166 parser-gap override as SessionsController; see config/routes.rb.
class RegistrationsController < ApplicationController
  # registrations/new.html.erb: `@user&.errors&.any?` and
  # `@user.errors.full_messages.each` both classify as the `errors` kind
  # (no Stage 1 finding -- any call chain rooted in `.errors` is its own
  # question, not a generic ivar one), but the separate `<%= @user.email %>`
  # is a plain ivar read -- REQUEST_TIME_STATE.
  def new
    @user = User.new
  end

  def create
    @user = User.new(registration_params)
    if @user.save
      redirect_to root_path
    else
      render :new
    end
  end

  private

  def registration_params
    params.require(:user).permit(:email, :password)
  end
end
