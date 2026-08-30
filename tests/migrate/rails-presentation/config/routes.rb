Rails.application.routes.draw do
  # Root and the /about alias both resolve to pages#about, which declares a
  # literal `layout "marketing"` -- proves a declared layout is honoured
  # over the app-wide convention (pinned in rails-presentation.sh).
  root "pages#about"
  get "/about", to: "pages#about"
  # pages#help's view (help.html.erb) is the one template that exercises
  # HELPER_UNKNOWN, RAW_OUTPUT, and I18N_UNRESOLVED all in one line.
  get "/help", to: "pages#help"
  # posts#index/#show: `layout :choose` (a dynamic/symbol layout --
  # RAILS_LAYOUT_DYNAMIC) falls back to the app-wide convention; and #167
  # Stage 3's `before_action :require_login, only: [:index]` puts a
  # RAILS_ROUTE_AUTH_GUARD on THIS line, answerable `public`.
  resources :posts, only: [:index, :show]
  # #167 Stage 3: a GET route whose action renders JSON, not a view. It is
  # the one route assumption A2 bites on -- a user-facing GET the handoff
  # calls `backend` stays UNACCOUNTED until an operation is chosen for it,
  # so a run that ignores it cannot reach `complete`. Its choices are the
  # --backend document's own GET operations.
  get "/feed", to: "posts#feed"
  # Routes to legacy.html.haml with no controller action required -- the
  # Haml engine blocker (RAILS_TEMPLATE_ENGINE_UNSUPPORTED) fires from a
  # plain app/views walk regardless of routing, but this proves a route can
  # still resolve to it.
  get "/posts/legacy", to: "posts#legacy"
  # #176: a singular `resource` routes to the PLURAL controller --
  # SessionsController, app/views/sessions/ -- exactly as Rails does
  # (SingletonResource#controller defaults to `name.to_s.pluralize`) while
  # the path and every route helper stay singular (`/session`,
  # `session_path`, `new_session_path`). This fixture therefore carries NO
  # `controller:` override: the override it used to need was a workaround
  # for the parser gap #176 closed, and keeping it would have meant the
  # fixture never exercised the rule a real app depends on.
  #
  # `destroy` is what the shared nav's `button_to ..., method: :delete`
  # targets: the sign-out half of the journey, and the fixture's only
  # mutating link.
  resource :session, only: [:new, :create, :destroy]
  # Same rule, same absent override -- RegistrationsController /
  # app/views/registrations/. That view carries the two `errors` regions
  # this fixture answers `island` (see its own comment).
  resource :registration, only: [:new, :create]
  # Self-review coverage: TEMPLATE_PARSE_ERROR and ROUTE_HELPER_UNKNOWN are
  # not in the Stage 1 vocabulary's core pins, but every code Stage 1 can
  # emit should appear at least once. broken.html.erb has an unclosed
  # `<% if x %>` (no matching `<% end %>`); links.html.erb calls a route
  # helper (`ghost_path`) that names no route this run recovered.
  # #167 Stage 2: pages#old is a pure redirect (classifier rule 3), so this
  # route becomes `redirect` in the handoff and raises
  # RAILS_REDIRECT_HOST_CONFIG -- the host config owns it, not the static
  # tree. It is the fixture's only route that is COMPLETE without a page and
  # without an operator decision.
  get "/old", to: "pages#old"
  get "/broken", to: "pages#broken"
  get "/links", to: "pages#links"
  # R15: linked.html.erb is swapped for a symlink out of the app tree by
  # rails-presentation.sh, so the templates op refuses it while the
  # transitive scan (which follows symlinks) reads it -- the gap
  # RAILS_TEMPLATE_UNSCANNED closes. It needs a route to be reached at all:
  # the templates op only ever sees route-reachable views.
  get "/linked", to: "pages#linked"
end
