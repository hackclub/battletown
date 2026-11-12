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
    resources :ships, only: %i[new create]
    resources :link_suggestions, only: [] do
      member do
        patch :accept
        patch :decline
      end
    end
  end

  # The shop (signed in and onboarded). Orders are always looked up through current_user (others' ids are a 404).
  get "shop", to: "shop#index"
  get "shop/items/:key", to: "shop#show", as: :shop_item, constraints: { key: /[a-z0-9_]{1,60}/ }
  get "shop/sticker", to: "sticker_claims#new", as: :new_shop_sticker
  post "shop/sticker", to: "sticker_claims#create", as: :shop_sticker
  # An item's picture. Public (the landing page shows it too), same-origin, cached privately and revalidated by ETag.
  get "shop/items/:key/image", to: "shop_item_images#show", as: :shop_item_image, format: false, constraints: { key: /[a-z0-9_]{1,60}/ }
  scope "shop" do
    resources :orders, only: %i[index show create] do
      member do
        patch :cancel
        # The delivery address of a physical order: pick one of the Hack Club Auth addresses just loaded (GET), and save it (PATCH).
        get :address
        patch "address", action: :update_address, as: :update_address
      end
    end
  end

  # Ships (signed in and onboarded only): a user sees and changes only their own; others' ids are a 404.
  resources :ships, only: %i[index show edit update] do
    member { patch :withdraw }
  end

  # Ship screenshots (flag `ship_screenshots`: the routes do not exist while it is off). The owner and staff only; others get a 404.
  constraints Features::Constraint.new(:ship_screenshots) do
    get "ships/:ship_id/images/:position", to: "ship_images#show", as: :ship_image, format: false,
                                           constraints: { ship_id: /\d+/, position: /[1-3]/ }
  end

  # Which Slack messages to receive (signed in and onboarded; only the current user's own switches).
  namespace :settings do
    resource :notifications, only: %i[show update]
  end

  # The weekly merch track (flag `merch_track`): the routes exist only while it is on, otherwise a plain 404.
  constraints Features::Constraint.new(:merch_track) do
    get "merch", to: "merch#index", as: :merch
    post "merch/weeks/:boss_id/claim", to: "merch_claims#create", as: :merch_claim, constraints: { boss_id: /\d+/ }
  end

  # The NPS survey page (flag `nps`: the routes do not exist while it is off). PUBLIC BY DESIGN: someone clicking the Slack link
  # must not need to log in, so the signed token in the path is the only credential (Nps::Token: signed, purpose-scoped,
  # expires, one answer per person and window). It can show a rating form and a thank-you, never anything personal.
  constraints Features::Constraint.new(:nps) do
    get "feedback/:token", to: "feedback#show", as: :feedback, constraints: { token: Nps::Token::PATH_FORMAT }
    post "feedback/:token", to: "feedback#create", constraints: { token: Nps::Token::PATH_FORMAT }
  end

  # Crews, the "team bonus" (flag `team`): the routes do not exist while it is off. Always the signed-in person's own crew;
  # /team/join/<token> is the invite link (a plain 404 for any token that does not work). Admin list at /admin/teams.
  constraints Features::Constraint.new(:team) do
    resource :team, only: %i[show create update] do
      post :invite
      delete :leave
    end
    get "team/join/:token", to: "team_joins#show", as: :team_join, constraints: { token: Team::TOKEN_FORMAT_PATH }
    post "team/join/:token", to: "team_joins#create", constraints: { token: Team::TOKEN_FORMAT_PATH }
    namespace :admin do
      resources :teams, only: %i[index destroy]
    end
  end

  # Plinko, the daily toy: the routes exist only while the `plinko` flag is on (a plain 404 otherwise; the controllers
  # check the flag too). Signed in and onboarded only. Drops are JSON and decided on the server (docs/CONTRACT.md).
  constraints Features::Constraint.new(:plinko) do
    resource :plinko, only: :show, controller: "plinko" do
      patch :leaderboard
      post :nickname
    end
    post "plinko/drops", to: "plinko_drops#create", as: :plinko_drops
  end

  # Email notifications (flag `email`; the routes do not exist while it is off). The signed token is the credential: GET
  # shows a confirmation page and changes nothing, POST unsubscribes (the button, and the RFC 8058 one-click request
  # from mail providers, which carries no CSRF token: the one POST in the app besides /api/privacy that skips it).
  # Keep above the /:ref catch-all.
  constraints Features::Constraint.new(:email) do
    scope "email/unsubscribe/:token", constraints: { token: /[A-Za-z0-9_-]{1,300}/ } do
      get "", to: "email_unsubscribes#show", as: :email_unsubscribe, format: false
      post "", to: "email_unsubscribes#create", format: false
    end
  end

  get "privacy", to: "pages#privacy"
  get "terms", to: "pages#terms"

  get "auth/:provider/callback", to: "sessions#create", constraints: { provider: "hack_club" }
  # Hackatime account linking, additive to sign-in: the callback never signs anyone in (HackatimeConnectionsController).
  get "auth/hackatime/callback", to: "hackatime_connections#create"
  # The shipping-address lookup at checkout, also additive to sign-in: the callback never signs anyone in (AddressCallbacksController).
  get "auth/hack_club_address/callback", to: "address_callbacks#create"
  get "auth/failure", to: "sessions#failure"
  resource :hackatime, only: [ :show, :destroy ], controller: "hackatime_connections"
  delete "logout", to: "sessions#destroy"
  post "dev_login", to: "sessions#dev_login"

  # Development-only tools (404 everywhere else, enforced in the controller).
  namespace :dev do
    resource :hours, only: %i[show create], controller: "hours"
    resource :boss, only: :show, controller: "bosses"
    resource :coins, only: :create, controller: "coins"
    resource :styleguide, only: :show, controller: "styleguide"
  end

  # The feature-flag console (Flipper UI): admins only, a plain 404 for everyone else. Keep it above the /:ref catch-all.
  constraints Features::AdminConstraint.new do
    mount Flipper::UI.app(Flipper) => "/admin/flipper", as: :flipper_ui
  end

  # Staff-only, read-only; a non-admin gets a 404. Keep above the /:ref catch-all (a referral slug can never be "admin").
  namespace :admin do
    root "dashboard#show"
    resource :metrics, only: :show
    # The audit trail (read-only) and user management. Writes live under users/:user_id and are throttled (rack_attack.rb).
    get "audit", to: "audit#index", as: :audit
    resources :users, only: %i[index show], constraints: { id: /\d{1,12}/ } do
      scope constraints: { user_id: /\d{1,12}/ } do
        resource :hours_adjustment, path: "hours", only: %i[new create], controller: "user_hours_adjustments" do
          post :confirm
        end
        resource :coin_adjustment, path: "coins", only: %i[new create], controller: "user_coin_adjustments" do
          post :confirm
        end
        resources :notes, only: :create, controller: "user_notes"
      end
    end
    constraints(Features::Constraint.new(:plinko)) { resource :plinko, only: :show, controller: "plinko" }
    # Email row counts per week (flag `email`: the route does not exist while it is off).
    constraints Features::Constraint.new(:email) do
      resource :email, only: :show, controller: "email_notifications"
    end
    resources :bosses, only: %i[index edit update]
    constraints Features::Constraint.new(:nps) do
      get "nps", to: "nps#index", as: :nps
      post "nps/:id/reveal", to: "nps#reveal", as: :nps_reveal, constraints: { id: /\d+/ }
    end
    # Flag `quests`: the routes do not exist while it is off (a plain 404); the controller checks the flag too.
    constraints Features::Constraint.new(:quests) do
      resources :quests, only: %i[index new create edit update]
    end
    # Orders: the queue, one order's page and its writes (each an Orders::* service). The CSV export is a POST (CSRF, audited).
    resources :orders, only: %i[index show] do
      collection { post :export }
      member do
        patch :hold
        patch :release
        patch :ship
        patch :fulfil
        patch :cancel
        patch :refund
        patch :tracking
        post :note
        # Opens the full shipping address for this one response, after writing it to the audit trail. A POST, never a GET.
        post "address/reveal", action: :reveal_address, as: :reveal_address
      end
    end
    resources :ships, only: %i[index show] do
      member do
        patch :approve
        patch :reject
      end
    end
    # Staff project review: a queue, one project with its history, and four writes (all POST). No flag: it changes nothing for teens.
    resources :projects, only: %i[index show], constraints: { id: /\d+/ } do
      member do
        post :ok
        post :flag
        post :clear
        post :note
      end
    end
    # The shop catalogue (Prize / ShopItem): list, add, edit, archive and restore, reorder. Items are found by their key and
    # never deleted. Orange admin pages like the rest of /admin.
    get "shop", to: "shop_items#index", as: :shop_items, format: false
    post "shop", to: "shop_items#create", format: false
    get "shop/new", to: "shop_items#new", as: :new_shop_item, format: false
    scope "shop/:key", constraints: { key: /[a-z0-9_]{1,60}/ }, format: false do
      get "edit", to: "shop_items#edit", as: :edit_shop_item
      patch "", to: "shop_items#update", as: :shop_item
      patch "archive", to: "shop_items#archive", as: :archive_shop_item
      patch "restore", to: "shop_items#restore", as: :restore_shop_item
      patch "move", to: "shop_items#move", as: :move_shop_item
    end
    # The weekly merch track queue (flag `merch_track`).
    constraints Features::Constraint.new(:merch_track) do
      get "merch", to: "merch_claims#index", as: :merch_claims
      patch "merch/:id/fulfill", to: "merch_claims#fulfill", as: :fulfill_merch_claim, constraints: { id: /\d+/ }
      patch "merch/:id/cancel", to: "merch_claims#cancel", as: :cancel_merch_claim, constraints: { id: /\d+/ }
    end
    constraints Features::Constraint.new(:ship_screenshots) do
      delete "ships/:ship_id/images/:position", to: "ship_images#destroy", as: :ship_image, format: false,
                                                constraints: { ship_id: /\d+/, position: /[1-3]/ }
    end
  end

  # Hack Club's data-deletion service (docs/PRIVACY_API.md): bearer-token authenticated, JSON only. The catch-all
  # answers other verbs and paths under /api/privacy with JSON. Keep above the /:ref catch-all.
  post "api/privacy/delete", to: "api/privacy#delete", format: false
  post "api/privacy/export", to: "api/privacy#export", format: false
  match "api/privacy/*path", to: "api/privacy#fallback", via: :all, format: false

  # Must stay last: /<slug> records a known referral source (e.g. /haven), anything else is a 404.
  get ":ref", to: "referrals#show", as: :referral, constraints: { ref: /[a-z0-9_-]{1,32}/ }
end
