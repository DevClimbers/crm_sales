require "sidekiq/web"

Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Autenticación
  get    "/login",  to: "sessions#new",     as: :login
  post   "/login",  to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout

  # Dashboard
  root "dashboard#index"

  # Prospectos y actividades
  resources :prospects, only: [:index, :show, :update] do
    resources :activities,  only: [:create, :destroy]
    resource  :web_audit,   only: [:create]
  end

  # Escaneos y configuración
  resources :scan_jobs,     only: [:index, :create]
  resource  :search_config, only: [:show, :update]

  # Pipeline Kanban y etapas
  get "/pipeline", to: "pipeline#index", as: :pipeline
  resources :pipeline_stages, only: [:create, :update, :destroy] do
    collection { patch :reorder }
  end

  # Sidekiq Web UI
  mount Sidekiq::Web => "/sidekiq"
end
