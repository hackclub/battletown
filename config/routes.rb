Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "landing#show"

  get "dashboard", to: "dashboard#show"
  get "onboarding", to: "onboardings#show"
  scope "onboarding/:step", constraints: { step: Regexp.union(OnboardingsController::STEPS) } do
    get "", to: "onboardings#step", as: :onboarding_step
    patch "", to: "onboardings#update"
  end

  # Signed-in, onboarded users only; every lookup is scoped to the current user (others' ids are a 404).
  resources :projects, except: :show do
    member do
      patch :activate
      patch :archive
      patch :unarchive
    end
    resources :hackatime_links, only: %i[create destroy]
    resources :link_suggestions, only: [] do
      member do
        patch :accept
        patch :decline
      end
    end
  end

  get "privacy", to: "pages#privacy"
  get "terms", to: "pages#terms"

  get "auth/:provider/callback", to: "sessions#create", constraints: { provider: "hack_club" }
  get "auth/failure", to: "sessions#failure"
  delete "logout", to: "sessions#destroy"
  post "dev_login", to: "sessions#dev_login"

  # Development-only tools (404 everywhere else, enforced in the controller).
  namespace :dev do
    resource :hours, only: %i[show create], controller: "hours"
  end

  # Staff-only, read-only; a non-admin gets a 404. Keep above the /:ref catch-all (a referral slug can never be "admin").
  namespace :admin do
    root "dashboard#show"
  end

  # Hack Club's data-deletion service (docs/PRIVACY_API.md): bearer-token authenticated, JSON only. The catch-all
  # answers other verbs and paths under /api/privacy with JSON. Keep above the /:ref catch-all.
  post "api/privacy/delete", to: "api/privacy#delete", format: false
  post "api/privacy/export", to: "api/privacy#export", format: false
  match "api/privacy/*path", to: "api/privacy#fallback", via: :all, format: false

  # Must stay last: /<slug> records a known referral source (e.g. /haven), anything else is a 404.
  get ":ref", to: "referrals#show", as: :referral, constraints: { ref: /[a-z0-9_-]{1,32}/ }
end
