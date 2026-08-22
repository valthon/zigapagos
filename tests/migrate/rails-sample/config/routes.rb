Rails.application.routes.draw do
  root "posts#index"
  resources :posts do
    member { post :publish }
  end
end
