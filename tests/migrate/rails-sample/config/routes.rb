Rails.application.routes.draw do
  root "posts#index"
  resources :posts do
    member { post :publish }
  end
  namespace :admin do
    resources :users, only: [:index]
  end
  # Classifier rule 3 fixture: routes to a controller action that only redirects.
  get "/posts/old", to: "posts#old"
  # Classifier rule 2 fixture: routes to a controller action that renders JSON.
  get "/posts/stats", to: "posts#stats"
  # Classifier rule 5 fixture: routes to a view that reads current_user.
  get "/posts/profile", to: "posts#profile"
  # Classifier rule 6 fixture: routes to a view with a Stimulus controller.
  get "/posts/dashboard", to: "posts#dashboard"
  # Classifier rule 4 fixture: routes to the existing unsupported-engine
  # (Haml) view below; no controller action need exist for the route to
  # resolve to that view and unresolve on its engine.
  get "/posts/legacy", to: "posts#legacy"
  # A1 fixture: view looks static, a rendered PARTIAL carries the marker.
  get "/posts/recent", to: "posts#recent"
  # A1 fixture: view renders an unresolvable dynamic target (`render @post`).
  get "/posts/featured", to: "posts#featured"
  # A1 fixture: view looks static, the FALLBACK LAYOUT carries the marker.
  get "/about", to: "pages#about"
  # Deliberately unresolvable: proves the parser reports rather than guesses.
  mount Sidekiq::Web => "/sidekiq"
  # Routes inside a conditional are emitted but flagged: the parser can see
  # their shape, not whether they are active.
  if ENV["ADMIN_UI"]
    get "/admin/health", to: "admin#health"
  end
end
