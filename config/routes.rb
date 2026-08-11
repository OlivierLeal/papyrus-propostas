Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  resources :users, except: :show

  resources :conversations, only: %i[index new create show] do
    member do
      post :confirm
      delete "attachments/:attachment_id", action: :remove_attachment, as: :remove_attachment
    end

    resources :messages, only: :create
  end

  namespace :settings do
    root to: "dashboard#index"
    resources :study_types, except: :show
    resources :professionals, except: :show
    resources :study_templates, except: :show
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "conversations#index"
end
