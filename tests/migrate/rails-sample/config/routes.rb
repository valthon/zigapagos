Rails.application.routes.draw do
  root "posts#index"
  resources :posts do
    member { post :publish }
  end
  namespace :admin do
    resources :users, only: [:index]
  end
  # Deliberately unresolvable: proves the parser reports rather than guesses.
  mount Sidekiq::Web => "/sidekiq"
  # Routes inside a conditional are emitted but flagged: the parser can see
  # their shape, not whether they are active.
  if ENV["ADMIN_UI"]
    get "/admin/health", to: "admin#health"
  end
end
