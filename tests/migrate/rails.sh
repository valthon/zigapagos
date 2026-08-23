#!/usr/bin/env bash
# End-to-end contract for the Rails adapter: detection, source immutability,
# determinism, non-clobbering repeat runs, blocker honesty, and route
# recovery.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"
# Route discovery spawns the Ruby sidecar under runtime/sidecar/rails; without
# this, discoverRoutes degrades to RAILS_SIDECAR_MISSING before ever looking
# for `ruby` on PATH (see src/cli/rails/routes.zig), which would make every
# route assertion below fail regardless of the `command -v ruby` guard.
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"

fail() { echo "FAIL: $*"; exit 1; }
if [[ ! -x "$ZIGAPAGOS" ]]; then
  mise exec -- zig build || fail "zig build failed"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/app"
cp -R "$REPO/tests/migrate/rails-sample" "$APP"

# --- source immutability -----------------------------------------------------
before="$(cd "$APP" && find . -type f | sort | xargs shasum | shasum)"

# --- auto-detection ----------------------------------------------------------
"$ZIGAPAGOS" migrate "$APP" -o "$WORK/one.md" >/dev/null 2>&1 \
  || fail "migrate failed on the Rails fixture"
grep -q "Migrating" "$WORK/one.md" || fail "report missing header"

# --- explicit --from ---------------------------------------------------------
"$ZIGAPAGOS" migrate "$APP" --from rails -o "$WORK/from.md" >/dev/null 2>&1 \
  || fail "--from rails rejected"

# --- non-Rails tree: --from rails must be FATAL, not a confident empty report
EMPTY="$(mktemp -d)"
set +e
"$ZIGAPAGOS" migrate "$EMPTY" --from rails -o "$WORK/none.md" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "--from rails on a non-Rails tree must fail"
[[ ! -e "$WORK/none.md" ]] || fail "--from rails on a non-Rails tree must not write a report"
rm -rf "$EMPTY"

# --- inventory counts --------------------------------------------------------
# Full accounting of the fixture's 10 non-.other rows: 22 files walked
# (21 under app/, 1 under public/), 22 counted across these 10 rows — so a
# kind silently dropped from the table shows up here as a count mismatch.
# A1's fixture additions (transitive template scanning) contribute 3 views
# (recent.html.erb, featured.html.erb, pages/about.html.erb), 1 layout
# (layouts/posts.html.erb), 1 partial (posts/_meta.html.erb), and 1
# controller (pages_controller.rb) on top of the pre-A1 counts.
grep -q "Views | 7" "$WORK/one.md" || fail "expected 7 views"
grep -q "Layouts | 2" "$WORK/one.md" || fail "expected 2 layouts (application, posts)"
grep -q "Partials | 3" "$WORK/one.md" || fail "expected 3 partials (incl. layouts/_nav, posts/_meta)"
grep -q "Mailer views | 1" "$WORK/one.md" || fail "expected 1 mailer view"
grep -q "Controllers | 2" "$WORK/one.md" || fail "expected 2 controllers (posts, pages)"
grep -q "Helpers | 1" "$WORK/one.md" || fail "expected 1 helper"
grep -q "Stimulus controllers | 2" "$WORK/one.md" || fail "expected 2 stimulus controllers (reveal_controller.js, toggle_controller.ts)"
grep -q "JS entrypoints | 1" "$WORK/one.md" || fail "expected 1 JS entrypoint (app/javascript/application.js)"
grep -q "JS modules | 1" "$WORK/one.md" || fail "expected 1 JS module (app/javascript/components/Button.jsx)"
grep -q "Assets | 2" "$WORK/one.md" || fail "expected 2 assets (app/assets/images/logo.png, public/favicon.ico)"

# --- routes -------------------------------------------------------------
# Route recovery needs `ruby` on PATH (the sidecar statically parses
# config/routes.rb) -- unlike every assertion above, which only exercises
# the Zig-side inventory/integration/blocker code. Skip loudly rather than
# silently passing when it's absent, mirroring the permission-check pattern
# further down this file.
if command -v ruby >/dev/null 2>&1; then
  grep -q "## Routes" "$WORK/one.md" || fail "no Routes section"
  grep -q "static_ast" "$WORK/one.md" || fail "route mode not stated"

  # resources :posts expands to the full CRUD set. Matched against the
  # exact rendered line (-Fx), not a loose substring: this doubles as proof
  # that a genuine, certain route carries no uncertainty marker. The
  # trailing " — content" is Task 6's classification suffix -- `posts#index`
  # has a plain static view and a recovered action, so it reaches rule 7.
  grep -Fxq -- '- `GET /posts` → `posts#index` — content' "$WORK/one.md" \
    || fail "resources :posts did not expand, or a certain route gained a spurious uncertainty marker"
  # member { post :publish } nests under the resource's :id. POST is a
  # non-GET verb, so rule 1 fires unconditionally -- backend regardless of
  # the fact that no `publish` view or action was ever recovered.
  grep -Fxq -- '- `POST /posts/:id/publish` → `posts#publish` — backend' "$WORK/one.md" \
    || fail "member route missing"
  # namespace :admin prefixes both the path and the controller module. No
  # `admin/users#index` view or action exists in the fixture, so rule 2's
  # "no view and no action" clause fires -- backend.
  grep -Fxq -- '- `GET /admin/users` → `admin/users#index` — backend' "$WORK/one.md" \
    || fail "namespaced route missing"

  # The engine mount is a construct the parser cannot evaluate at all -- it
  # must surface as a coded blocker, never as a silently-dropped route.
  grep -q "RAILS_ROUTE_ENGINE_MOUNT" "$WORK/one.md" || fail "mount not reported as a blocker"

  # A route inside a conditional IS emitted (its shape is fully known from
  # the source) but flagged uncertain (its activation is not). Asserted on
  # the exact rendered line, not on "the word uncertain appears somewhere"
  # -- this section's own unconditional intro sentence uses that word to
  # explain the marker, so a document-level substring check would still
  # pass with the per-route marker deleted entirely. That exact vacuous
  # assertion is what Task 6's review caught and rejected; this pins the
  # marker to the one route that must carry it.
  # Same "no view, no action" gap as admin/users above, plus the
  # uncertainty marker -- the two are independent claims, both asserted on
  # the one line.
  grep -Fxq -- '- `GET /admin/health` → `admin#health` — **uncertain** — backend' "$WORK/one.md" \
    || fail "conditional route missing its uncertainty marker"
  grep -q "RAILS_ROUTE_CONDITIONAL" "$WORK/one.md" || fail "conditional route not reported as a blocker"

  # --- classification: every rule the classifier defines is exercised ------
  # Task 6 extends the fixture to reach every classification rule at least
  # once. Both the summary counts AND one exact rendered line per reached
  # class are asserted -- counts alone would pass even if a route's rule
  # attribution were wrong (e.g. two routes swapped between `backend` and
  # `unresolved` while the totals stayed put), and a line alone would not
  # prove the summary table's arithmetic matches the per-route list.
  #
  # `spa` is asserted at zero deliberately: Stage 3 declares the value but
  # never assigns it (see classify.zig's module doc) -- nothing in this
  # stage's evidence proves a component root owns routing. Pinning the zero
  # here is what would catch a future change that starts guessing.
  grep -q "| content | 2 |" "$WORK/one.md" || fail "expected 2 content routes"
  grep -q "| island | 1 |" "$WORK/one.md" || fail "expected 1 island route"
  grep -q "| spa | 0 |" "$WORK/one.md" || fail "expected 0 spa routes (Stage 3 never assigns spa)"
  grep -q "| backend | 11 |" "$WORK/one.md" || fail "expected 11 backend routes"
  grep -q "| redirect | 1 |" "$WORK/one.md" || fail "expected 1 redirect route"
  # 5, not 2: fix round A / A1 adds three more unresolved routes below
  # (/about, /posts/recent, /posts/featured), all exercising transitive
  # template scanning rather than rules 4/5 on the view file alone.
  grep -q "| unresolved | 5 |" "$WORK/one.md" || fail "expected 5 unresolved routes"

  # island (rule 6): the view wires up a Stimulus controller
  # (`data-controller="reveal"`).
  grep -Fxq -- '- `GET /posts/dashboard` → `posts#dashboard` — island' "$WORK/one.md" \
    || fail "Stimulus-marker view did not classify as island"
  # redirect (rule 3): the controller action's body is only `redirect_to`.
  grep -Fxq -- '- `GET /posts/old` → `posts#old` — redirect' "$WORK/one.md" \
    || fail "pure-redirect action did not classify as redirect"
  # unresolved (rule 5): the view reads request-time state (`current_user`).
  grep -Fxq -- '- `GET /posts/profile` → `posts#profile` — unresolved' "$WORK/one.md" \
    || fail "current_user view did not classify as unresolved"
  # unresolved (rule 4): the view's template engine is Haml, not erb --
  # reuses `legacy.html.haml`, already present for the blocker assertion
  # below, now also routed to so a route actually resolves against it.
  grep -Fxq -- '- `GET /posts/legacy` → `posts#legacy` — unresolved' "$WORK/one.md" \
    || fail "Haml view did not classify as unresolved"
  # backend (rule 2, JSON clause): the controller action renders JSON, not
  # a view -- fires independent of there being no view file for `stats` at
  # all.
  grep -Fxq -- '- `GET /posts/stats` → `posts#stats` — backend' "$WORK/one.md" \
    || fail "JSON-rendering action did not classify as backend"

  # --- A1: transitive template scanning (layout + partials) ----------------
  # `posts#index`'s own view (index.html.erb, rendering partial "post") was
  # already reached above (grep for `- \`GET /posts\` ... content`) -- these
  # three prove the NEW evidence surfaces, not just that the old ones still
  # work. All three views look entirely static in isolation; only scanning
  # what they (or their layout) pull in tells the honest story.
  #
  # unresolved: the view is clean, but the resolved LAYOUT
  # (layouts/application.html.erb, the app-wide fallback -- `pages` has no
  # layout of its own) carries csrf_meta_tags.
  grep -Fxq -- '- `GET /about` → `pages#about` — unresolved' "$WORK/one.md" \
    || fail "a marker in the fallback LAYOUT did not force the route unresolved"
  # unresolved: the view is clean and posts' own layout is clean, but a
  # PARTIAL the view renders (_meta.html.erb) reads current_user.
  grep -Fxq -- '- `GET /posts/recent` → `posts#recent` — unresolved' "$WORK/one.md" \
    || fail "a marker in a RENDERED PARTIAL did not force the route unresolved"
  # unresolved: the view renders `@post` -- Rails' implicit
  # object-to-partial shorthand -- which this scan cannot resolve to a
  # specific file; the route must not reach content on the strength of
  # what little the view file itself shows.
  grep -Fxq -- '- `GET /posts/featured` → `posts#featured` — unresolved' "$WORK/one.md" \
    || fail "an unresolvable render target did not force the route unresolved"
else
  echo "SKIP: route assertions (no ruby on PATH)"
fi

# --- A3: app/controllers/ missing must not hand out backend on a missing
# action -------------------------------------------------------------------
# Regression for fix round A / A3: under a WHOLESALE controller-shape
# degradation, `action == null` is not evidence about any particular route,
# so rule 2's first sub-clause must not fire `backend` on it -- these routes
# must land on `unresolved` instead. Uncaught by every OTHER assertion in
# this file: none of them removes app/controllers/, so this scenario is the
# only thing that actually exercises `controllerEvidenceAvailable`'s wiring
# end to end (confirmed by mutation -- see the fix report).
if command -v ruby >/dev/null 2>&1; then
  DEGRADED="$WORK/degraded-controllers-app"
  cp -R "$REPO/tests/migrate/rails-sample" "$DEGRADED"
  rm -rf "$DEGRADED/app/controllers"
  set +e
  "$ZIGAPAGOS" migrate "$DEGRADED" -o "$WORK/degraded.md" >"$WORK/degraded.out" 2>"$WORK/degraded.err"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || fail "a missing app/controllers/ is a non-integrity degradation and must still exit 0, not $rc"
  grep -q "RAILS_CONTROLLERS_MISSING" "$WORK/degraded.md" || fail "missing app/controllers/ not reported as a blocker"
  # Before the A3 fix, both of these rendered ` — backend` -- action==null
  # was treated as a positive finding about the route instead of the
  # absence of ANY evidence about it.
  grep -Fxq -- '- `GET /admin/users` → `admin/users#index` — unresolved' "$WORK/degraded.md" \
    || fail "a view-less, action-less route under wholesale controller degradation must be unresolved, not backend"
  grep -Fxq -- '- `GET /posts/old` → `posts#old` — unresolved' "$WORK/degraded.md" \
    || fail "a route that is normally a redirect must be unresolved (not backend) when controller evidence never confirmed it"
else
  echo "SKIP: A3 controller-degradation assertions (no ruby on PATH)"
fi

# --- empty routes.rb: a legitimate zero-route result, not a degraded one ----
# Regression for the "See Blockers for why" finding (PR #169): discovery can
# run cleanly and genuinely recover zero routes (an empty
# `Rails.application.routes.draw do end`). That must read as "routes.rb
# declares no routes", never point at a Blockers section that has nothing to
# say about routes -- and the run must still exit 0, since nothing failed.
# Same ruby-on-PATH guard as the block above: the sidecar has to actually run
# for route_mode to reach "static_ast" rather than degrading to "none".
if command -v ruby >/dev/null 2>&1; then
  EMPTY_ROUTES="$WORK/empty-routes-app"
  cp -R "$REPO/tests/migrate/rails-sample" "$EMPTY_ROUTES"
  cat >"$EMPTY_ROUTES/config/routes.rb" <<'EOF'
Rails.application.routes.draw do
end
EOF
  set +e
  "$ZIGAPAGOS" migrate "$EMPTY_ROUTES" -o "$WORK/empty-routes.md" >"$WORK/empty-routes.out" 2>"$WORK/empty-routes.err"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || fail "an empty routes.rb is a legitimate result and must exit 0, not $rc"
  grep -Fxq -- '`config/routes.rb` declares no routes.' "$WORK/empty-routes.md" \
    || fail "empty routes.rb must say routes.rb declares no routes"
  grep -q "See Blockers below for why" "$WORK/empty-routes.md" \
    && fail "empty routes.rb must not point readers at Blockers -- nothing there explains routes"
  # std.debug.print writes to stderr (see the "could not be read" assertion
  # against perm.err above), not stdout -- hence .err here, not .out.
  grep -q "config/routes.rb declares no routes" "$WORK/empty-routes.err" \
    || fail "the CLI summary must state the same conclusion as the report, not just the report itself"
  grep -q "no routes recovered -- see Blockers" "$WORK/empty-routes.err" \
    && fail "the CLI summary must not point at Blockers for a genuinely-empty routes.rb"
else
  echo "SKIP: empty routes.rb assertions (no ruby on PATH)"
fi

# --- integrations ------------------------------------------------------------
grep -q "propshaft" "$WORK/one.md" || fail "propshaft not detected"
grep -q "turbo" "$WORK/one.md" || fail "turbo not detected"
grep -q "stimulus" "$WORK/one.md" || fail "stimulus not detected"
grep -q "sprockets" "$WORK/one.md" && fail "commented-out gem must not be detected"

# --- blocker honesty ---------------------------------------------------------
grep -q "RAILS_TEMPLATE_ENGINE_UNSUPPORTED" "$WORK/one.md" \
  || fail "Haml view was not reported as a blocker"
grep -q "legacy.html.haml" "$WORK/one.md" || fail "blocker missing its source path"

# --- determinism -------------------------------------------------------------
"$ZIGAPAGOS" migrate "$APP" -o "$WORK/two.md" >/dev/null 2>&1
diff -u "$WORK/one.md" "$WORK/two.md" || fail "output is not deterministic"

# --- source unchanged --------------------------------------------------------
after="$(cd "$APP" && find . -type f | sort | xargs shasum | shasum)"
[[ "$before" == "$after" ]] || fail "migrate modified the source tree"

# --- repeat run overwrites the report, and does so identically ---------------
# createFile(..., .{}) truncates by design: the report is regenerated, not
# versioned. The `.new` rule covers scaffolded islands and copied assets, which
# this stage does not emit. Assert the documented behaviour rather than a
# `.new` file that must never appear here.
cp "$WORK/one.md" "$WORK/one.before.md"
"$ZIGAPAGOS" migrate "$APP" -o "$WORK/one.md" >/dev/null 2>&1
[[ ! -e "$WORK/one.md.new" ]] || fail "report must be overwritten, not versioned to .new"
diff -u "$WORK/one.before.md" "$WORK/one.md" || fail "regenerated report differs"

# --- parenthesized Gemfile syntax is still detected (P3 PR-review repro) ----
# The reviewer's exact repro: `gem("rails")` with config/application.rb
# removed -- routes.rb + app/views + a rails gem is the OTHER conclusive
# detection branch, and the old literal `"gem "` prefix check missed the
# parenthesized call entirely, so this used to be rejected as not Rails.
PAREN="$WORK/paren-app"
cp -R "$REPO/tests/migrate/rails-sample" "$PAREN"
rm "$PAREN/config/application.rb"
cat >"$PAREN/Gemfile" <<'EOF'
source "https://rubygems.org"
gem("rails", "~> 7.1")
EOF
"$ZIGAPAGOS" migrate "$PAREN" --from rails -o "$WORK/paren.md" >/dev/null 2>&1 \
  || fail "gem(\"rails\") Gemfile syntax was not detected as Rails"

# --- an integrity blocker makes the command exit non-zero -------------------
# P1/P5: a permission error reading part of the inventory must not produce a
# confident zero-exit report. This needs a real permission-denied directory
# (same platform caveat as the Zig unit tests in inventory.zig) -- skipped
# when stripping permissions turns out not to block access in this
# environment (root, or a sandbox that ignores mode bits).
PERM="$WORK/perm-app"
cp -R "$REPO/tests/migrate/rails-sample" "$PERM"
chmod 000 "$PERM/app/views" 2>/dev/null || true
if [[ ! -r "$PERM/app/views" ]]; then
  set +e
  "$ZIGAPAGOS" migrate "$PERM" -o "$WORK/perm.md" >"$WORK/perm.out" 2>"$WORK/perm.err"
  rc=$?
  set -e
  chmod 755 "$PERM/app/views"
  [[ $rc -ne 0 ]] || fail "an unreadable inventory root must exit non-zero"
  [[ -e "$WORK/perm.md" ]] || fail "the report must still be written despite the integrity blocker"
  grep -q "RAILS_INVENTORY_" "$WORK/perm.md" || fail "the integrity blocker must be named in the report"
  grep -q "could not be read" "$WORK/perm.err" || fail "stderr must warn about the unreadable inventory"
else
  chmod 755 "$PERM/app/views"
  echo "SKIP: permission-denied inventory-root check (this environment does not enforce chmod 000)"
fi

# --- an unreadable Gemfile on a branch-B tree must PROCEED, not fatal ------
# Reviewer's repro: config/application.rb removed (so branch A is dead) but
# routes.rb + app/views + a Gemfile that declares rails are all present --
# the structural evidence IS Rails-shaped, and only the Gemfile confirmation
# is blocked by a permission error. `verdict` must call that .indeterminate,
# not .not_rails, so --from rails proceeds into discovery instead of fataling
# the way the EMPTY-dir case above correctly does. Discovery then reports
# RAILS_GEMFILE_UNREADABLE as an integrity blocker and the run still exits
# non-zero -- same platform caveat as the PERM block above (permission bits
# not enforced under root or some sandboxes).
INDET="$WORK/indet-app"
cp -R "$REPO/tests/migrate/rails-sample" "$INDET"
rm "$INDET/config/application.rb"
chmod 000 "$INDET/Gemfile" 2>/dev/null || true
if [[ ! -r "$INDET/Gemfile" ]]; then
  set +e
  "$ZIGAPAGOS" migrate "$INDET" --from rails -o "$WORK/indet.md" >"$WORK/indet.out" 2>"$WORK/indet.err"
  rc=$?
  set -e
  chmod 644 "$INDET/Gemfile"
  [[ $rc -ne 0 ]] || fail "an unreadable Gemfile on a branch-B tree must still exit non-zero (integrity blocker)"
  [[ -e "$WORK/indet.md" ]] || fail "--from rails on a Rails-shaped tree with an unreadable Gemfile must proceed and write the report, not fatal"
  grep -q "RAILS_GEMFILE_UNREADABLE" "$WORK/indet.md" || fail "the unreadable Gemfile must be named as RAILS_GEMFILE_UNREADABLE in the report"
else
  chmod 644 "$INDET/Gemfile"
  echo "SKIP: indeterminate-detection unreadable-Gemfile check (this environment does not enforce chmod 000)"
fi

echo "PASS: tests/migrate/rails.sh"
