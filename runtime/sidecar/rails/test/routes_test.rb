require_relative "../routes"

$failures = 0
def check(label, src, expected_pairs, expect_unresolved: [])
  got = RailsRoutes.parse(src, path: "config/routes.rb")
  pairs = got[:routes].map { |r| "#{r[:verb]} #{r[:path]}" }.sort.uniq
  want = expected_pairs.sort.uniq
  if pairs != want
    warn "FAIL #{label}\n  missing: #{(want - pairs).inspect}\n  extra:   #{(pairs - want).inspect}"
    $failures += 1
  end
  codes = got[:unresolved].map { |u| u[:code] }.sort.uniq
  unless expect_unresolved.sort.uniq == codes
    warn "FAIL #{label} (unresolved): expected #{expect_unresolved.inspect}, got #{codes.inspect}"
    $failures += 1
  end
end

# `check` above never inspects :certain -- it only compares verb/path pairs
# and unresolved codes. These two behaviors (genuine-route-set vs.
# custom-router, and conditional routes) are specifically about the
# :certain flag, so they need their own assertion.
def check_certainty(label, src, expect_certain)
  got = RailsRoutes.parse(src, path: "config/routes.rb")
  bad = got[:routes].reject { |r| r[:certain] == expect_certain }
  unless bad.empty?
    warn "FAIL #{label}: expected certain:#{expect_certain} for every route, got #{bad.inspect}"
    $failures += 1
  end
end

# `check` only compares verb/path pairs. These behaviors depend on
# controller/action too (namespace vs. scope module:, singular resources'
# action set), so they need an exact route-set comparison including those
# fields -- otherwise a bug that corrupts controller/action while leaving
# verb/path alone passes silently.
def check_full(label, src, expected)
  got = RailsRoutes.parse(src, path: "config/routes.rb")
  actual = got[:routes].map { |r| { verb: r[:verb], path: r[:path], controller: r[:controller], action: r[:action] } }
  a_sorted = actual.map(&:inspect).sort
  w_sorted = expected.map(&:inspect).sort
  if a_sorted != w_sorted
    warn "FAIL #{label}\n  missing: #{(w_sorted - a_sorted).inspect}\n  extra:   #{(a_sorted - w_sorted).inspect}"
    $failures += 1
  end
end

check "root", 'Rails.application.routes.draw do
  root "home#index"
end', ["GET /"]

check "verb with rocket", 'Rails.application.routes.draw do
  get "/about" => "pages#about"
end', ["GET /about"]

check "verb with to:", 'Rails.application.routes.draw do
  post "/signup", to: "users#create"
end', ["POST /signup"]

# resources generates 8 routes: update is both PATCH and PUT.
check "resources", 'Rails.application.routes.draw do
  resources :posts
end', [
  "GET /posts", "POST /posts", "GET /posts/new", "GET /posts/:id/edit",
  "GET /posts/:id", "PATCH /posts/:id", "PUT /posts/:id", "DELETE /posts/:id",
]

check "singular resource has no index and no :id", 'Rails.application.routes.draw do
  resource :profile
end', [
  "POST /profile", "GET /profile/new", "GET /profile/edit",
  "GET /profile", "PATCH /profile", "PUT /profile", "DELETE /profile",
]

check "only: filters", 'Rails.application.routes.draw do
  resources :posts, only: [:index, :show]
end', ["GET /posts", "GET /posts/:id"]

check "namespace prefixes path and controller", 'Rails.application.routes.draw do
  namespace :admin do
    resources :users, only: [:index]
  end
end', ["GET /admin/users"]

check "member and collection", 'Rails.application.routes.draw do
  resources :posts, only: [] do
    member { post :publish }
    collection { get :archived }
  end
end', ["POST /posts/:id/publish", "GET /posts/archived"]

# A bare route inside a resources block nests under the parent param, and
# the param uses the SINGULAR -- irregular plurals included.
check "bare nested route uses the singular parent param", 'Rails.application.routes.draw do
  resources :people, only: [] do
    get :dossier
  end
end', ["GET /people/:person_id/dossier"]

check "dynamic path is unresolved, not guessed", 'Rails.application.routes.draw do
  get "/#{ENV["PREFIX"]}/x", to: "a#b"
end', [], expect_unresolved: ["RAILS_ROUTE_DYNAMIC_PATH"]

check "engine mount is unresolved", 'Rails.application.routes.draw do
  mount Sidekiq::Web => "/sidekiq"
end', [], expect_unresolved: ["RAILS_ROUTE_ENGINE_MOUNT"]

check "loop-generated routes are uncertain, not silently dropped", 'Rails.application.routes.draw do
  %w[a b].each do |n|
    get "/\#{n}", to: "x#y"
  end
end', [], expect_unresolved: ["RAILS_ROUTE_LOOP"]

# The custom-router / genuine-route-set split dispatches on the receiver's
# NODE TYPE, not the method name -- `X.routes.draw` (any call chain ending
# in `.routes`, e.g. `Rails.application.routes` or a real Rails app's
# `CanvasRails::Application.routes`) is the genuine route set and must
# descend normally, while a BARE CONSTANT receiver (`ApiRouteSet::V1.draw
# (self)`) is an app-defined router applying a path prefix this parser
# cannot know. A spike that conflated the two lost 40 points of precision,
# so both directions are pinned together in one source below: a "route" is
# not walked into vs. is walked into is not enough to tell them apart on
# its own -- check() only compares verb/path pairs, and either receiver
# type produces a route from the genuine `get "/about"` call either way if
# the discrimination is silently loosened to "any receiver = custom
# router" (the nested draw would just also mark that route uncertain, and
# check() alone wouldn't notice). That is exactly why check_certainty is
# used here too: the assertion that matters is that the genuine call's
# route is certain:true, not merely present.
custom_router_src = 'Rails.application.routes.draw do
  get "/about" => "pages#about"
  ApiRouteSet::V1.draw(self)
end'
check "genuine route set (X.routes.draw) descends; bare-constant receiver is a custom router",
      custom_router_src, ["GET /about"], expect_unresolved: ["RAILS_ROUTE_CUSTOM_ROUTER"]
check_certainty "genuine route set produces certain:true routes", custom_router_src, true

conditional_src = 'Rails.application.routes.draw do
  if Rails.env.development?
    get "/debug", to: "debug#index"
  end
end'
check "routes inside a conditional are emitted, not dropped",
      conditional_src, ["GET /debug"], expect_unresolved: ["RAILS_ROUTE_CONDITIONAL"]
check_certainty "conditional routes are certain:false", conditional_src, false

# ---------------------------------------------------------------------
# Critical 1 (review): a non-literal only:/except: must not fabricate the
# full route set as certain. Reproduced by review: `except: HIDDEN` (a
# bare, unresolvable identifier) silently expanded to all 8 routes,
# certain:true, zero unresolved -- because arr_syms returned [] for the
# non-literal value and an empty except-list excludes nothing. The same
# hole let `only: VISIBLE` silently drop every route (an empty only-list
# matches nothing) with no unresolved entry either -- a silent total
# recall loss, not just a silent fabrication.
check "except: with a non-literal value is unresolved, not empty",
      'Rails.application.routes.draw do
  resources :posts, except: HIDDEN
end', [], expect_unresolved: ["RAILS_ROUTE_DYNAMIC_PATH"]

check "only: with a non-literal value is unresolved, not empty",
      'Rails.application.routes.draw do
  resources :posts, only: VISIBLE
end', [], expect_unresolved: ["RAILS_ROUTE_DYNAMIC_PATH"]

check "except: array containing one non-literal element is unresolved",
      'Rails.application.routes.draw do
  resources :posts, except: [:destroy, SOME_CONST]
end', [], expect_unresolved: ["RAILS_ROUTE_DYNAMIC_PATH"]

# ---------------------------------------------------------------------
# Critical 3 (review): a recursive concern must not crash the (persistent)
# sidecar. Reproduced by review: `concern :a do concerns :a end` +
# `concerns :a` raised SystemStackError straight out of RailsRoutes.parse
# -- unrescuable by the `rescue StandardError` in .parse, since
# SystemStackError < Exception, not StandardError. static_ast mode exists
# for apps that cannot boot, so broken input like this is the EXPECTED
# input class, not an edge case.
check "a directly self-referential concern does not crash, is unresolved",
      'Rails.application.routes.draw do
  concern :a do
    concerns :a
  end
  concerns :a
end', [], expect_unresolved: ["RAILS_ROUTE_CONCERN_CYCLE"]

check "an indirectly cyclic concern (a -> b -> a) does not crash, is unresolved",
      'Rails.application.routes.draw do
  concern :a do
    concerns :b
  end
  concern :b do
    concerns :a
  end
  concerns :a
end', [], expect_unresolved: ["RAILS_ROUTE_CONCERN_CYCLE"]

check "a concern that is NOT recursive still expands normally",
      'Rails.application.routes.draw do
  concern :commentable do
    resources :comments, only: [:index]
  end
  resources :posts, only: [] do
    concerns :commentable
  end
end', ["GET /posts/:post_id/comments"]

# ---------------------------------------------------------------------
# Whole-branch review I-2: `concerns :a, :b` (the multi-name bare form the
# Rails routing guide documents, e.g. `concerns :commentable,
# :image_attachable`) previously took only pos[0] -- every name after the
# first silently vanished, with no unresolved entry. flat_map over every
# positional arg fixes it.
check "concerns :a, :b (multi-name form) expands every name, not just the first",
      'Rails.application.routes.draw do
  concern :commentable do
    resources :comments, only: [:index]
  end
  concern :taggable do
    resources :tags, only: [:index]
  end
  resources :posts, only: [] do
    concerns :commentable, :taggable
  end
end', ["GET /posts/:post_id/comments", "GET /posts/:post_id/tags"]

# Same root cause, the OPTION form: `resources :x, concerns: :y` ignored
# concerns: entirely -- also a silent drop, and changelog.d/rails-routes.md
# already advertises this form as supported. Covers both the bare-symbol
# and array spellings of the option value.
check "resources concerns: option (single symbol) expands",
      'Rails.application.routes.draw do
  concern :commentable do
    resources :comments, only: [:index]
  end
  resources :posts, only: [], concerns: :commentable
end', ["GET /posts/:post_id/comments"]

check "resources concerns: option (array) expands every name",
      'Rails.application.routes.draw do
  concern :commentable do
    resources :comments, only: [:index]
  end
  concern :taggable do
    resources :tags, only: [:index]
  end
  resources :posts, only: [], concerns: [:commentable, :taggable]
end', ["GET /posts/:post_id/comments", "GET /posts/:post_id/tags"]

# ---------------------------------------------------------------------
# Whole-branch review I-2 (related, same class): `Mapper#match` accepts
# multiple positional paths -- `get "/a", "/b", to: "x#y"` is valid Rails
# and yields two routes. `pos[0]` alone silently dropped every path after
# the first, with no unresolved entry -- rarer than the concerns gap but
# the same silent-drop family.
check "get with multiple positional paths yields a route for each",
      'Rails.application.routes.draw do
  get "/a", "/b", to: "x#y"
end', ["GET /a", "GET /b"]

check "one unresolvable path among several does not erase the resolvable ones",
      'Rails.application.routes.draw do
  get "/a", SOME_CONST, to: "x#y"
end', ["GET /a"], expect_unresolved: ["RAILS_ROUTE_DYNAMIC_PATH"]

# ---------------------------------------------------------------------
# Minor (review): devise_scope's block holds real, hand-written routes --
# unlike devise_for, it must descend transparently, not get lumped in as
# gem-generated (which would silently drop routes this parser can read).
check "devise_scope descends into its real hand-written routes",
      'Rails.application.routes.draw do
  devise_for :users
  devise_scope :user do
    get "/login", to: "sessions#new"
  end
end', ["GET /login"], expect_unresolved: ["RAILS_ROUTE_GEM_GENERATED"]

# ---------------------------------------------------------------------
# Critical 2 (review): an unresolvable to:/action:/controller: target must
# not invent the action from the path segment. Reproduced by review:
# `get "/old", to: redirect("/new")` emitted GET /old -> #/old, certain,
# unflagged -- ctrl_action(nil) fell through to `action ||= seg`, which
# assigned the raw path string as the action.
check "to: with an unresolvable value is unresolved, not path-as-action",
      'Rails.application.routes.draw do
  get "/old", to: redirect("/new")
end', [], expect_unresolved: ["RAILS_ROUTE_DYNAMIC_PATH"]

check "an unresolvable to: inside member is unresolved, not resource#seg",
      'Rails.application.routes.draw do
  resources :posts, only: [] do
    member { get :publish, to: PUBLISH_TARGET }
  end
end', [], expect_unresolved: ["RAILS_ROUTE_DYNAMIC_PATH"]

check "root with an unresolvable to: is unresolved, not root -> #index",
      'Rails.application.routes.draw do
  root to: redirect("/x")
end', [], expect_unresolved: ["RAILS_ROUTE_DYNAMIC_PATH"]

check "controller: with a non-literal value is unresolved",
      'Rails.application.routes.draw do
  get "/x", controller: SOME_CONST, action: "y"
end', [], expect_unresolved: ["RAILS_ROUTE_DYNAMIC_PATH"]

# ---------------------------------------------------------------------
# Important 4 (review): case/when and begin/rescue must not silently drop
# routes with no trace at all -- a silent drop is invisible to the
# consumer even though nothing was fabricated, which still defeats "knows
# when it cannot". case is morally an if -> descend under CONDITIONAL;
# begin is transparent -> descend normally with no marking.
check "routes inside case/when are emitted, marked conditional",
      'Rails.application.routes.draw do
  case Rails.env
  when "development"
    get "/d", to: "d#i"
  else
    get "/e", to: "e#i"
  end
end', ["GET /d", "GET /e"], expect_unresolved: ["RAILS_ROUTE_CONDITIONAL"]

check "routes inside begin/rescue are emitted, not marked (transparent)",
      'Rails.application.routes.draw do
  begin
    get "/b", to: "b#i"
  rescue StandardError
    nil
  end
end', ["GET /b"]

# ---------------------------------------------------------------------
# Important 5 (review): the else branch of if/unless must be walked too.
# UnlessNode exposes its else via else_clause, not subsequent -- a fix
# that only follows `subsequent` (as IfNode does) silently drops
# unless/else routes.
check "if/elsif/else: every branch is emitted, not just the first",
      'Rails.application.routes.draw do
  if a
    get "/x1", to: "x#one"
  elsif b
    get "/x2", to: "x#two"
  else
    get "/x3", to: "x#three"
  end
end', ["GET /x1", "GET /x2", "GET /x3"], expect_unresolved: ["RAILS_ROUTE_CONDITIONAL"]

check "unless/else: the else branch is not dropped",
      'Rails.application.routes.draw do
  unless a
    get "/y1", to: "y#one"
  else
    get "/y2", to: "y#two"
  end
end', ["GET /y1", "GET /y2"], expect_unresolved: ["RAILS_ROUTE_CONDITIONAL"]

# ---------------------------------------------------------------------
# Important 6 (review): mutation-tested gaps. `check` alone never compares
# controller/action, so these three real bugs all passed the suite
# unnoticed:
#   - scope module: also prefixing the path (should only prefix controller)
#   - namespace no longer prefixing the controller module
#   - a singular `resource` gaining a spurious :index action
# check_full closes this by comparing the full {verb, path, controller,
# action} set, not just verb/path pairs.
check_full "namespace prefixes both path and controller module",
           'Rails.application.routes.draw do
  namespace :admin do
    resources :users, only: [:index]
  end
end', [
  { verb: "GET", path: "/admin/users", controller: "admin/users", action: "index" },
]

check_full "scope path: prefixes the path only, not the controller",
           'Rails.application.routes.draw do
  scope path: "v1" do
    get "/x", to: "a#b"
  end
end', [
  { verb: "GET", path: "/v1/x", controller: "a", action: "b" },
]

check_full "scope module: prefixes the controller only, not the path",
           'Rails.application.routes.draw do
  scope module: "api" do
    get "/x", to: "a#b"
  end
end', [
  { verb: "GET", path: "/x", controller: "api/a", action: "b" },
]

check_full "singular resource has exactly the 7 non-index actions",
           'Rails.application.routes.draw do
  resource :profile
end', [
  { verb: "POST",   path: "/profile",      controller: "profile", action: "create" },
  { verb: "GET",    path: "/profile/new",  controller: "profile", action: "new" },
  { verb: "GET",    path: "/profile/edit", controller: "profile", action: "edit" },
  { verb: "GET",    path: "/profile",      controller: "profile", action: "show" },
  { verb: "PATCH",  path: "/profile",      controller: "profile", action: "update" },
  { verb: "PUT",    path: "/profile",      controller: "profile", action: "update" },
  { verb: "DELETE", path: "/profile",      controller: "profile", action: "destroy" },
]

abort "#{$failures} routes failure(s)" if $failures > 0
puts "PASS: routes_test.rb"
