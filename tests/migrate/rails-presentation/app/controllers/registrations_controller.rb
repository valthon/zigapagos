# Routed via `resource :registration` -- same #176 plural-controller rule
# as SessionsController, and the same absent `controller:` override.
class RegistrationsController < ApplicationController
  # registrations/new.html.erb: `@user&.errors&.any?` and
  # `@user.errors.full_messages.each` both classify as the `errors` kind
  # (no Stage 1 finding -- any call chain rooted in `.errors` is its own
  # question, not a generic ivar one). Both are answered `island` in
  # #167 Stage 3: the bound AuthForm renders the backend's own field
  # errors where the ERB rendered `full_messages`.
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
    params.require(:user).permit(:email, :password, :password_confirmation)
  end
end
