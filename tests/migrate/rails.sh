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

# phase-2-review.md F1 / Ruling 17: a real, independent JSON Schema INSTANCE
# validator against the fixture manifest below -- see
# src/cli/rails/schema_validate.zig's module doc for why this is a
# dependency-free Zig CLI rather than a `pip install jsonschema` step this
# repo's toolchain (mise.toml: zig + bun only) does not otherwise have.
RAILS_VALIDATE="$REPO/zig-out/bin/rails_manifest_validate"
if [[ ! -x "$RAILS_VALIDATE" ]]; then
  mise exec -- zig build rails-manifest-validate || fail "zig build rails-manifest-validate failed"
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
# Full accounting of the fixture's 10 non-.other rows: 24 files walked
# (22 under app/, 2 under public/), 24 counted across these 10 rows — so a
# kind silently dropped from the table shows up here as a count mismatch.
# A1's fixture additions (transitive template scanning) contribute 3 views
# (recent.html.erb, featured.html.erb, pages/about.html.erb), 1 layout
# (layouts/posts.html.erb), 1 partial (posts/_meta.html.erb), and 1
# controller (pages_controller.rb) on top of the pre-A1 counts. Task 6 (the
# asset inventory) adds app/assets/stylesheets/application.css.erb, an
# ERB-preprocessed asset the fixture's compiled manifest does not list under
# its own (pre-ERB) filename -- the fixture's `deterministic: false` case
# (see rails.sh's asset-blocker assertions below). Fix round 1 adds
# public/assets/.manifest.json itself, Propshaft's real compiled manifest --
# logo.png's `deterministic: true` counterpart is now read verbatim from
# this file, not computed by this stage.
grep -q "Views | 7" "$WORK/one.md" || fail "expected 7 views"
grep -q "Layouts | 2" "$WORK/one.md" || fail "expected 2 layouts (application, posts)"
grep -q "Partials | 3" "$WORK/one.md" || fail "expected 3 partials (incl. layouts/_nav, posts/_meta)"
grep -q "Mailer views | 1" "$WORK/one.md" || fail "expected 1 mailer view"
grep -q "Controllers | 2" "$WORK/one.md" || fail "expected 2 controllers (posts, pages)"
grep -q "Helpers | 1" "$WORK/one.md" || fail "expected 1 helper"
grep -q "Stimulus controllers | 2" "$WORK/one.md" || fail "expected 2 stimulus controllers (reveal_controller.js, toggle_controller.ts)"
grep -q "JS entrypoints | 1" "$WORK/one.md" || fail "expected 1 JS entrypoint (app/javascript/application.js)"
grep -q "JS modules | 1" "$WORK/one.md" || fail "expected 1 JS module (app/javascript/components/Button.jsx)"
grep -q "Assets | 4" "$WORK/one.md" \
  || fail "expected 4 assets (app/assets/images/logo.png, app/assets/stylesheets/application.css.erb, public/favicon.ico, public/assets/.manifest.json)"

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
  grep -Fxq -- '- `GET /posts` → `posts#index` — content (no request-time state or interactivity found)' "$WORK/one.md" \
    || fail "resources :posts did not expand, or a certain route gained a spurious uncertainty marker"
  # member { post :publish } nests under the resource's :id. POST is a
  # non-GET verb, so rule 1 fires unconditionally -- backend regardless of
  # the fact that no `publish` view or action was ever recovered.
  grep -Fxq -- '- `POST /posts/:id/publish` → `posts#publish` — backend (non-GET verb is a backend responsibility)' "$WORK/one.md" \
    || fail "member route missing"
  # namespace :admin prefixes both the path and the controller module. No
  # `admin/users#index` view or action exists in the fixture, so rule 2's
  # "no view and no action" clause fires -- backend.
  grep -Fxq -- '- `GET /admin/users` → `admin/users#index` — backend (no view template and no controller action were recovered for this route)' "$WORK/one.md" \
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
  grep -Fxq -- '- `GET /admin/health` → `admin#health` — **uncertain** — backend (no view template and no controller action were recovered for this route)' "$WORK/one.md" \
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
  grep -Fxq -- '- `GET /posts/dashboard` → `posts#dashboard` — island (view has an interactive Stimulus controller or component root)' "$WORK/one.md" \
    || fail "Stimulus-marker view did not classify as island"
  # redirect (rule 3): the controller action's body is only `redirect_to`.
  grep -Fxq -- '- `GET /posts/old` → `posts#old` — redirect (controller action only issues a redirect)' "$WORK/one.md" \
    || fail "pure-redirect action did not classify as redirect"
  # unresolved (rule 5): the view reads request-time state (`current_user`).
  grep -Fxq -- '- `GET /posts/profile` → `posts#profile` — unresolved (view reads request-time state)' "$WORK/one.md" \
    || fail "current_user view did not classify as unresolved"
  # unresolved (rule 4): the view's template engine is Haml, not erb --
  # reuses `legacy.html.haml`, already present for the blocker assertion
  # below, now also routed to so a route actually resolves against it.
  grep -Fxq -- '- `GET /posts/legacy` → `posts#legacy` — unresolved (unsupported template engine, never converted)' "$WORK/one.md" \
    || fail "Haml view did not classify as unresolved"
  # backend (rule 2, JSON clause): the controller action renders JSON, not
  # a view -- fires independent of there being no view file for `stats` at
  # all.
  grep -Fxq -- '- `GET /posts/stats` → `posts#stats` — backend (action renders JSON, not a view)' "$WORK/one.md" \
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
  grep -Fxq -- '- `GET /about` → `pages#about` — unresolved (the resolved layout reads request-time state)' "$WORK/one.md" \
    || fail "a marker in the fallback LAYOUT did not force the route unresolved"
  # unresolved: the view is clean and posts' own layout is clean, but a
  # PARTIAL the view renders (_meta.html.erb) reads current_user.
  grep -Fxq -- '- `GET /posts/recent` → `posts#recent` — unresolved (a rendered partial reads request-time state)' "$WORK/one.md" \
    || fail "a marker in a RENDERED PARTIAL did not force the route unresolved"
  # unresolved: the view renders `@post` -- Rails' implicit
  # object-to-partial shorthand -- which this scan cannot resolve to a
  # specific file; the route must not reach content on the strength of
  # what little the view file itself shows.
  grep -Fxq -- '- `GET /posts/featured` → `posts#featured` — unresolved (template renders a dynamic partial target that cannot be resolved statically)' "$WORK/one.md" \
    || fail "an unresolvable render target did not force the route unresolved"

  # --- manifest: routes[]/templates[] need real route recovery, so these
  # live inside the ruby guard (the report-level assertions above already
  # prove the SAME fixture recovers the routes; this proves the manifest
  # carries them too, not just MIGRATION.md's prose rendering of them).
  MANIFEST="$WORK/one.manifest.json"
  [[ -f "$MANIFEST" ]] || fail "no manifest written beside the report"
  jq -e . "$MANIFEST" >/dev/null || fail "manifest is not valid JSON"

  root_route_id=$(jq -r '.routes[] | select(.path == "/" and .verb == "GET") | .id' "$MANIFEST")
  [[ "$root_route_id" == "GET /" ]] || fail "manifest routes[] missing 'GET /' (root route), got: $root_route_id"
  root_line=$(jq -r '.routes[] | select(.path == "/" and .verb == "GET") | .source.line' "$MANIFEST")
  [[ "$root_line" == "2" ]] || fail "manifest root route source.line should be 2, got: $root_line"
  root_class=$(jq -r '.routes[] | select(.path == "/" and .verb == "GET") | .classification' "$MANIFEST")
  [[ "$root_class" == "content" ]] || fail "manifest root route classification should be content, got: $root_class"
  health_confidence=$(jq -r '.routes[] | select(.path == "/admin/health") | .confidence' "$MANIFEST")
  [[ "$health_confidence" == "uncertain" ]] || fail "manifest conditional route confidence should be uncertain, got: $health_confidence"

  # --- Stage 4 Task 12's own fixture addition: dashboard.html.erb's
  # `data-controller="reveal modal"` must reach the manifest as TWO
  # names, not one string and not a raw attribute value -- the same
  # split `template_scan.zig`'s own unit tests pin in isolation, proven
  # here end to end through a real `zigapagos migrate` run.
  dashboard_controllers=$(jq -c '.templates[] | select(.path == "app/views/posts/dashboard.html.erb") | .stimulus_controllers' "$MANIFEST")
  [[ "$dashboard_controllers" == '["reveal","modal"]' ]] \
    || fail "manifest templates[].stimulus_controllers should be [\"reveal\",\"modal\"] for dashboard.html.erb, got: $dashboard_controllers"
else
  echo "SKIP: route assertions (no ruby on PATH)"
fi

# --- manifest: the deliverable, unconditionally (design spec, "The
# manifest": "the deliverable; MIGRATION.md is a rendering of it") --------
# Everything below is pure Zig/Gemfile-text (assets, integrations,
# blockers, source.version): none of it needs Ruby, unlike routes[]/
# templates[] above, so this runs regardless of the `command -v ruby`
# guard.
MANIFEST="$WORK/one.manifest.json"
[[ -f "$MANIFEST" ]] || fail "no manifest written beside the report"

# --- manifest: real INSTANCE validation against the COMMITTED schema -------
# phase-2-review.md F1: `rails-check` only ever compares schema to schema
# (it has no instance), and `manifestGoldenBytes` (Task 9) pins a hand-built
# manifest with `"assets": []`, which structurally cannot contain the one
# field (`assets[].pipeline`, a nullable enum) the shipped defect broke on.
# This is the first check on the branch that asks the consumer-side
# question: does a REAL manifest actually validate against the schema this
# tool publishes?
"$RAILS_VALIDATE" "$REPO/contract/rails-presentation.v1.schema.json" "$MANIFEST" \
  || fail "manifest failed instance validation against the committed schema"

schema=$(jq -r '.schema' "$MANIFEST")
[[ "$schema" == "zigapagos.rails-presentation/1" ]] || fail "manifest schema mismatch: $schema"
schema_version=$(jq -r '.schema_version' "$MANIFEST")
[[ "$schema_version" == "1" ]] || fail "manifest schema_version mismatch: $schema_version"
generator_tool=$(jq -r '.generator.tool' "$MANIFEST")
[[ "$generator_tool" == "zigapagos" ]] || fail "manifest generator.tool mismatch: $generator_tool"

source_framework=$(jq -r '.source.framework' "$MANIFEST")
[[ "$source_framework" == "rails" ]] || fail "manifest source.framework mismatch: $source_framework"
# The fixture's checked-in Gemfile.lock locks rails at 7.1.3 (several other
# gems alongside it -- Task 12's fixture requirement for a Gemfile.lock
# naming several gems, already satisfied by the existing fixture).
rails_version=$(jq -r '.source.version.value' "$MANIFEST")
[[ "$rails_version" == "7.1.3" ]] || fail "manifest source.version.value mismatch: $rails_version"
root_evidence=$(jq -c '.source.root_evidence' "$MANIFEST")
[[ "$root_evidence" == '["config/application.rb","config/routes.rb","app/views","Gemfile"]' ]] \
  || fail "manifest source.root_evidence mismatch: $root_evidence"

# --- assets[]: both the deterministic and non-deterministic case, the SAME
# discrimination `rails.zig`'s own "the fixture's assets discriminate" unit
# test pins at the Zig level, now proven through a real CLI run's output
# file.
logo_deterministic=$(jq -r '.assets[] | select(.source == "app/assets/images/logo.png") | .deterministic' "$MANIFEST")
[[ "$logo_deterministic" == "true" ]] || fail "manifest logo.png should be deterministic: $logo_deterministic"
logo_url=$(jq -r '.assets[] | select(.source == "app/assets/images/logo.png") | .public_url' "$MANIFEST")
[[ "$logo_url" == "/assets/images/logo-9f86d081884c.png" ]] || fail "manifest logo.png public_url mismatch: $logo_url"
css_deterministic=$(jq -r '.assets[] | select(.source == "app/assets/stylesheets/application.css.erb") | .deterministic' "$MANIFEST")
[[ "$css_deterministic" == "false" ]] || fail "manifest application.css.erb should NOT be deterministic: $css_deterministic"
css_url=$(jq -r '.assets[] | select(.source == "app/assets/stylesheets/application.css.erb") | .public_url' "$MANIFEST")
[[ "$css_url" == "null" ]] || fail "manifest application.css.erb public_url should be null, got: $css_url"

# --- integrations[]: Gemfile-detected, no Ruby needed.
turbo_evidence=$(jq -r '.integrations[] | select(.name == "turbo") | .evidence' "$MANIFEST")
[[ -n "$turbo_evidence" && "$turbo_evidence" != "null" ]] || fail "manifest integrations[] missing turbo evidence"

# --- blockers[]: the Haml view is detected independent of route recovery
# (a plain app/views walk, see inventory.zig), so this fires with or
# without ruby on PATH -- the severity/integrity axes Task 1 added must
# both reach the manifest, not just the summary counts.
haml_severity=$(jq -r '.blockers[] | select(.code == "RAILS_TEMPLATE_ENGINE_UNSUPPORTED") | .severity' "$MANIFEST" | head -1)
[[ "$haml_severity" == "warn" ]] || fail "manifest RAILS_TEMPLATE_ENGINE_UNSUPPORTED severity should be warn, got: $haml_severity"
haml_integrity=$(jq -r '.blockers[] | select(.code == "RAILS_TEMPLATE_ENGINE_UNSUPPORTED") | .integrity' "$MANIFEST" | head -1)
[[ "$haml_integrity" == "false" ]] || fail "manifest RAILS_TEMPLATE_ENGINE_UNSUPPORTED integrity should be false, got: $haml_integrity"

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
  grep -Fxq -- '- `GET /admin/users` → `admin/users#index` — unresolved (no view template, and controller evidence was unavailable for this run)' "$WORK/degraded.md" \
    || fail "a view-less, action-less route under wholesale controller degradation must be unresolved, not backend"
  grep -Fxq -- '- `GET /posts/old` → `posts#old` — unresolved (no view template, and controller evidence was unavailable for this run)' "$WORK/degraded.md" \
    || fail "a route that is normally a redirect must be unresolved (not backend) when controller evidence never confirmed it"
  # A second, differently-shaped instance through the same validator: a
  # wholesale-degraded run stresses different nullable/enum fields
  # (`controller`/`action` null, `classification: "unresolved"`) than the
  # healthy fixture above.
  "$RAILS_VALIDATE" "$REPO/contract/rails-presentation.v1.schema.json" "$WORK/degraded.manifest.json" \
    || fail "degraded manifest failed instance validation against the committed schema"
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

# --- Task 6 / fix round 1: asset determinism honesty -------------------------
# Every app/assets/ URL is read verbatim from Propshaft's real compiled
# manifest (public/assets/.manifest.json, added to the fixture in fix round
# 1) -- never derived by re-implementing a digest scheme this stage cannot
# verify. The ERB-preprocessed stylesheet legitimately never appears under
# its own (pre-ERB) filename in that manifest, so it must be reported as
# exactly that -- never a guessed /assets/... URL that would 404 in
# production. The rendered report only surfaces this via the Blockers
# section (Task 8's manifest -- not yet built -- is what will list
# `assets[]` itself, incl. the deterministic counterpart, logo.png; that
# per-asset discrimination is pinned at the Zig level in rails.zig's
# "discover: the fixture's assets discriminate" test, which reads
# Discovery.assets directly).
grep -q "RAILS_ASSET_DIGEST_UNAVAILABLE" "$WORK/one.md" \
  || fail "the manifest-unlisted ERB-preprocessed asset was not reported as a blocker"
grep -q "app/assets/stylesheets/application.css.erb" "$WORK/one.md" \
  || fail "asset blocker missing its source path"

# --- determinism -------------------------------------------------------------
"$ZIGAPAGOS" migrate "$APP" -o "$WORK/two.md" >/dev/null 2>&1
diff -u "$WORK/one.md" "$WORK/two.md" || fail "output is not deterministic"
diff -u "$WORK/one.manifest.json" "$WORK/two.manifest.json" || fail "manifest is not deterministic"

# --- source unchanged --------------------------------------------------------
after="$(cd "$APP" && find . -type f | sort | xargs shasum | shasum)"
[[ "$before" == "$after" ]] || fail "migrate modified the source tree"

# --- repeat run overwrites the report, and does so identically ---------------
# createFile(..., .{}) truncates by design: the report is regenerated, not
# versioned. The `.new` rule covers scaffolded islands and copied assets, which
# this stage does not emit. Assert the documented behaviour rather than a
# `.new` file that must never appear here. The manifest follows the exact
# same rule (see migrate.zig's own comment at the manifest write site).
cp "$WORK/one.md" "$WORK/one.before.md"
cp "$WORK/one.manifest.json" "$WORK/one.manifest.before.json"
"$ZIGAPAGOS" migrate "$APP" -o "$WORK/one.md" >/dev/null 2>&1
[[ ! -e "$WORK/one.md.new" ]] || fail "report must be overwritten, not versioned to .new"
[[ ! -e "$WORK/one.manifest.json.new" ]] || fail "manifest must be overwritten, not versioned to .new"
diff -u "$WORK/one.before.md" "$WORK/one.md" || fail "regenerated report differs"
diff -u "$WORK/one.manifest.before.json" "$WORK/one.manifest.json" || fail "regenerated manifest differs"

# --- --strict: exits non-zero on any blocker, changes NOTHING else ---------
# The fixture's Haml view (legacy.html.haml) alone produces
# RAILS_TEMPLATE_ENGINE_UNSUPPORTED independent of route recovery (see the
# unconditional blocker assertions above), so this fixture ALWAYS has at
# least one blocker, with or without ruby on PATH -- --strict must fail on
# it regardless. The discriminating property (task-11-brief.md): --strict
# changes ONLY the exit code. Compared byte-for-byte, not just "both files
# exist" -- an implementation that also suppressed or altered output under
# --strict would still pass a weaker check.
"$ZIGAPAGOS" migrate "$APP" -o "$WORK/strict-off.md" >/dev/null 2>&1 \
  || fail "plain (non-strict) migrate should exit 0 on this fixture"
set +e
"$ZIGAPAGOS" migrate "$APP" --strict -o "$WORK/strict-on.md" >/dev/null 2>&1
strict_rc=$?
set -e
[[ $strict_rc -ne 0 ]] || fail "--strict must exit non-zero: the fixture has at least one blocker (RAILS_TEMPLATE_ENGINE_UNSUPPORTED)"
diff -u "$WORK/strict-off.md" "$WORK/strict-on.md" || fail "--strict changed the report bytes"
diff -u "$WORK/strict-off.manifest.json" "$WORK/strict-on.manifest.json" || fail "--strict changed the manifest bytes"

# --- --strict is rejected for a non-Rails source (no blocker concept there) -
ASTRO_LIKE="$WORK/astro-like"
mkdir -p "$ASTRO_LIKE/src/pages"
touch "$ASTRO_LIKE/astro.config.mjs"
set +e
"$ZIGAPAGOS" migrate "$ASTRO_LIKE" --strict -o "$WORK/astro-like.md" >"$WORK/astro-strict.err" 2>&1
astro_strict_rc=$?
set -e
[[ $astro_strict_rc -ne 0 ]] || fail "--strict on a non-Rails source must be rejected, not silently accepted"
grep -q -- "--strict only applies to Rails sources" "$WORK/astro-strict.err" \
  || fail "--strict rejection on a non-Rails source did not explain why"
[[ ! -e "$WORK/astro-like.md" ]] || fail "a rejected --strict combination must not write a report"

# --- --target DIR: the two discovery artifacts land in DIR, nothing else,
# byte-identical to the -o run (task-1-brief.md's own "Discriminate"
# requirement -- a bare "DIR is non-empty" check would also pass an
# implementation that wrote only one of the two artifacts, or that wrote a
# scaffold Rails must not produce: converting content/scaffolding islands
# is #167's job, not this one's). --------------------------------------------
TARGET="$WORK/target-dir"
"$ZIGAPAGOS" migrate "$APP" --target "$TARGET" >/dev/null 2>&1 \
  || fail "--target should exit 0 on this fixture (blockers present, but none are integrity blockers, and --strict was not passed)"

# Exactly the two discovery artifacts, nothing else -- no components/,
# content/, assets/, layouts/, build.sh, package.json, .gitignore, etc. (the
# scaffold the other eight sources' --target assembles).
target_listing="$(cd "$TARGET" && find . -type f | sort)"
expected_listing="$(printf './MIGRATION.manifest.json\n./MIGRATION.md\n' | sort)"
[[ "$target_listing" == "$expected_listing" ]] \
  || fail "--target must write exactly MIGRATION.md and MIGRATION.manifest.json into DIR and nothing else, got: $target_listing"

# Nothing leaked to the default out_path location either. Both artifacts,
# not just the report: final-review.md F11 found the manifest leaking to the
# repo root under a mutated railsManifestPath call while this check only
# covered MIGRATION.md, so the leak was caught solely by the exact-listing
# assertion above and left a stray untracked file behind afterward.
[[ ! -e "$REPO/MIGRATION.md" ]] \
  || fail "--target must not also write to the default ./MIGRATION.md location"
[[ ! -e "$REPO/MIGRATION.manifest.json" ]] \
  || fail "--target must not also write the manifest to the default ./MIGRATION.manifest.json location"

# Byte-identical to the same app's -o run: the report/manifest depend only
# on the source tree's discovery, never on where the CLI happens to write
# them.
diff -u "$WORK/one.manifest.json" "$TARGET/MIGRATION.manifest.json" \
  || fail "--target's manifest is not byte-identical to the -o run's manifest"
diff -u "$WORK/one.md" "$TARGET/MIGRATION.md" \
  || fail "--target's report is not byte-identical to the -o run's report"

# The source tree is still read-only after --target, same invariant as the
# plain -o path above.
after_target="$(cd "$APP" && find . -type f | sort | xargs shasum | shasum)"
[[ "$before" == "$after_target" ]] || fail "--target modified the source tree"

# --target reuses the same nested/non-empty guards every other source's
# --target uses (assembleTarget's own pathIsInside/targetHasEntries) rather
# than a Rails-specific bypass.
set +e
"$ZIGAPAGOS" migrate "$APP" --target "$APP/nested-target" >"$WORK/nested.out" 2>&1
nested_rc=$?
set -e
[[ $nested_rc -ne 0 ]] || fail "--target inside the Rails source must be rejected"
[[ ! -e "$APP/nested-target" ]] || fail "a rejected nested --target must not create the directory"

NONEMPTY="$WORK/nonempty-target"
mkdir -p "$NONEMPTY"
touch "$NONEMPTY/keep.txt"
set +e
"$ZIGAPAGOS" migrate "$APP" --target "$NONEMPTY" >"$WORK/nonempty.out" 2>&1
nonempty_rc=$?
set -e
[[ $nonempty_rc -ne 0 ]] || fail "--target on a non-empty directory must be rejected"
[[ ! -e "$NONEMPTY/MIGRATION.md" ]] || fail "a rejected non-empty --target must not write the report"

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
