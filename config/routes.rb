Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "landing#show"

  get "dashboard", to: "dashboard#show"
  get "onboarding", to: "onboardings#show"
  scope "onboarding/:step", constraints: { step: Regexp.union(OnboardingsController::STEPS) } do
    get "", to: "onboardings#step", as: :onboarding_step
    patch "", to: "onboardings#update"
  end

  get "account", to: "accounts#show", as: :account
  delete "account", to: "accounts#destroy"
  get "account/export", to: "accounts#export", as: :account_export
  get "account/delete", to: "accounts#confirm_delete", as: :delete_account
  get "account/reauth", to: "accounts#reauth", as: :reauth_account

  get "privacy", to: "pages#privacy"
  get "terms", to: "pages#terms"

  get "auth/:provider/callback", to: "sessions#create", constraints: { provider: "hack_club" }
  get "auth/failure", to: "sessions#failure"
  delete "logout", to: "sessions#destroy"
  post "dev_login", to: "sessions#dev_login"

  # Staff-only, read-only; a non-admin gets a 404. Keep above the /:ref catch-all (a referral slug can never be "admin").
  namespace :admin do
    root "dashboard#show"
  end

  # Must stay last: /<slug> records a known referral source (e.g. /haven), anything else is a 404.
  get ":ref", to: "referrals#show", as: :referral, constraints: { ref: /[a-z0-9_-]{1,32}/ }
end
