Rails.application.routes.draw do
  # Root and the /about alias both resolve to pages#about, which declares a
  # literal `layout "marketing"` -- proves a declared layout is honoured
  # over the app-wide convention (pinned in rails-presentation.sh).
  root "pages#about"
  get "/about", to: "pages#about"
  # pages#help's view (help.html.erb) is the one template that exercises
  # HELPER_UNKNOWN, RAW_OUTPUT, and I18N_UNRESOLVED all in one line.
  get "/help", to: "pages#help"
  # posts#index/#show: PostsController declares `layout :choose` (a
  # dynamic/symbol layout -- RAILS_LAYOUT_DYNAMIC), which must fall back to
  # the app-wide convention (application.html.erb) since no
  # app/views/layouts/posts.html.erb exists.
  resources :posts, only: [:index, :show]
  # Routes to legacy.html.haml with no controller action required -- the
  # Haml engine blocker (RAILS_TEMPLATE_ENGINE_UNSUPPORTED) fires from a
  # plain app/views walk regardless of routing, but this proves a route can
  # still resolve to it.
  get "/posts/legacy", to: "posts#legacy"
  # R13 (#166 follow-up): this parser computes a SINGULAR controller
  # identifier for a singular `resource` (see
  # runtime/sidecar/rails/test/routes_test.rb's "singular resource has
  # exactly the 7 non-index actions": `resource :profile` yields
  # `controller: "profile"`, not the pluralized "profiles" real Rails
  # would route to). Real Rails resolves `resource :session` to
  # `SessionsController` (pluralized) with NO explicit `controller:`
  # needed -- the explicit override below is redundant in a real app and
  # exists only to keep this fixture's controller/view pair
  # (SessionsController / app/views/sessions/) honest against this
  # parser's current gap.
  resource :session, only: [:new, :create], controller: "sessions"
  # Same #166 gap, same override -- RegistrationsController /
  # app/views/registrations/. This view also carries the one
  # RAILS_REQUEST_TIME_STATE finding that is NOT inside an `errors` chain
  # (see registrations/new.html.erb's own comment).
  resource :registration, only: [:new, :create], controller: "registrations"
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
