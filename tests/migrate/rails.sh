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
# #167 Stage 3 reads a route's `endpoint` object out of the handoff, which is
# a field lookup no grep can do honestly (a `grep -q operation_id` cannot say
# WHICH route carries it). `jq` is already a hard requirement of the two
# sibling Rails e2e scripts, so this adds no new tool to CI.
command -v jq >/dev/null || fail "jq required"

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

  # #167 Stage 1: route names and findings on the original fixture.
  [[ "$(jq -r '.routes[] | select(.verb == "POST" and .path == "/posts/:id/publish") | .name' "$MANIFEST")" == "publish_post" ]] || fail "publish_post name"
  [[ "$(jq -r '.routes[] | select(.path == "/admin/users") | .name' "$MANIFEST")" == "admin_users" ]] || fail "admin_users name"
  [[ "$(jq -r '.routes[] | select(.path == "/admin/health") | .name' "$MANIFEST")" == "null" ]] || fail "an uncertain route must stay unnamed"
  jq -e '.findings[] | select(.code == "RAILS_REQUEST_TIME_STATE" and .source.file == "app/views/posts/profile.html.erb")' "$MANIFEST" >/dev/null || fail "profile finding"
  jq -e '.findings[] | select(.code == "RAILS_PARTIAL_DYNAMIC" and .source.file == "app/views/posts/featured.html.erb")' "$MANIFEST" >/dev/null || fail "featured render @post finding"
  dashboard_finding='RAILS_STIMULUS_CONTROLLER.app/views/posts/dashboard%2Ehtml%2Eerb.L2C1'
  jq -e --arg id "$dashboard_finding" '.findings[] | select(.id == $id and .message == "stimulus `reveal modal` on <div>; source not found (app/javascript/controllers/modal_controller.{js,ts,jsx,tsx})" and (.choices == ["drop","retain","blocked"]))' "$MANIFEST" >/dev/null \
    || fail "dashboard must follow the empty reveal controller, report missing modal, and refuse an unbuildable island choice"
  jq -e '.findings[] | select(.id == "RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry" and .source.line == null and (.choices == ["drop","blocked"]))' "$MANIFEST" >/dev/null \
    || fail "the Rails sample's application.js must become the global JS-entry question"
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

# --- --target DIR: Rails assembles a real project (#167 Stage 2) ------------
# The exact listing is the assertion that matters: a bare "DIR is non-empty"
# check would also pass an implementation that wrote only the discovery
# artifacts (the pre-Stage-2 behaviour), or that scaffolded a page for a route
# whose template it could not convert.
#
# Exit 3, not 0: this fixture has routes nobody has decided about, and that is
# the whole point of the new code -- the run wrote everything it meant to and
# the migration is not finished. `|| fail` would pass on ANY non-zero, so the
# code is captured and compared exactly.
TARGET="$WORK/target-dir"
set +e
"$ZIGAPAGOS" migrate "$APP" --target "$TARGET" >"$WORK/target.out" 2>&1
target_rc=$?
set -e
[[ $target_rc -eq 3 ]] \
  || fail "--target on a fixture with open routes must exit 3 (incomplete handoff), got $target_rc"
grep -q -- "route(s) open" "$WORK/target.out" \
  || fail "exit 3 did not say how to make progress"
grep -q -- "MIGRATION.decisions.json" "$WORK/target.out" \
  || fail "exit 3 did not name the file the operator has to write"

# The exact tree. `pages#about` converts under the `application` layout; the
# `posts` routes that render a dynamic partial stay open (their pages are
# still written -- an open route is one nobody has decided about, not one that
# produced nothing); `/posts/old` is a redirect and `/posts/:id` is backend.
#
# Note what is NOT here: `assets/assets/.manifest.json`. Ruling S17 --
# `public/assets/**` is the pipeline's compiled OUTPUT (Propshaft's
# `.manifest.json`, and a digested copy of every `app/assets/` source), and
# copying it would ship each asset twice plus a Rails bookkeeping file no
# Zigapagos site reads. The sources themselves are copied from `app/assets/`
# (`assets/images/logo.png` below).
#
# Also note what #167 Stage 3 did NOT add: no `package.json`, no
# `tsconfig.json`, no `lib/zb.ts`, no `components/`. This fixture has no
# answered `RAILS_BACKEND_ENDPOINT` and therefore no binding, and a run with
# no binding must emit no island machinery at all -- the listing is the only
# assertion that can catch a scaffolder that writes `lib/zb.ts`
# unconditionally, since nothing else here would notice one extra file.
target_listing="$(cd "$TARGET" && find . -type f | sort)"
expected_listing="$(cat <<'LISTING'
./.gitignore
./AGENTS.md
./CLAUDE.md
./MIGRATION.handoff.json
./MIGRATION.manifest.json
./MIGRATION.md
./assets/favicon.ico
./assets/images/logo.png
./build.sh
./content/about/index.smd
./content/index.smd
./content/posts/dashboard/index.smd
./content/posts/featured/index.smd
./content/posts/index.smd
./content/posts/profile/index.smd
./content/posts/recent/index.smd
./layouts/pages/about.shtml
./layouts/posts/dashboard.shtml
./layouts/posts/featured.shtml
./layouts/posts/index.shtml
./layouts/posts/profile.shtml
./layouts/posts/recent.shtml
./layouts/templates/application.shtml
./layouts/templates/posts.shtml
./zigapagos.ziggy
LISTING
)"
[[ "$target_listing" == "$expected_listing" ]] \
  || fail "--target wrote an unexpected tree. got:
$target_listing
want:
$expected_listing"

# Never clobbers: the scaffold writes with exclusive-create, so a `.new`
# anywhere in the target would mean something took the `--scaffold` versioning
# path by mistake.
[[ -z "$(cd "$TARGET" && find . -name '*.new*' -print -quit)" ]] \
  || fail "--target must never version a file as .new; it writes into an empty tree"

# Nothing leaked to the default out_path location either. Both artifacts,
# not just the report: final-review.md F11 found the manifest leaking to the
# repo root under a mutated railsManifestPath call while this check only
# covered MIGRATION.md, so the leak was caught solely by the exact-listing
# assertion above and left a stray untracked file behind afterward.
[[ ! -e "$REPO/MIGRATION.md" ]] \
  || fail "--target must not also write to the default ./MIGRATION.md location"
[[ ! -e "$REPO/MIGRATION.manifest.json" ]] \
  || fail "--target must not also write the manifest to the default ./MIGRATION.manifest.json location"

# The MANIFEST is byte-identical to the same app's -o run: it is discovery's
# verdict, and discovery does not depend on where the CLI writes its output or
# on whether a scaffold was assembled afterwards.
diff -u "$WORK/one.manifest.json" "$TARGET/MIGRATION.manifest.json" \
  || fail "--target's manifest is not byte-identical to the -o run's manifest"

# The REPORT is deliberately NOT identical any more (ruling S2): with a target
# it gains a Handoff section describing the conversion, which the -o run has
# nothing to say about. What must still hold is that everything ABOVE that
# section is unchanged -- the report is the same discovery rendering plus a
# suffix, not a differently-rendered document.
sed -n '/^## Handoff$/,$p' "$TARGET/MIGRATION.md" >"$WORK/target-handoff-section.md"
[[ -s "$WORK/target-handoff-section.md" ]] \
  || fail "--target's report is missing the Handoff section"
# The whole section, byte for byte. A `grep -q '^complete: false$'` (which is
# all this used to be) passes an implementation that renders the section
# twice, drops the status table, or -- the #167 Stage 3 case -- omits the
# `backend:`/`endpoints:` lines entirely. This run passed no `--backend`, so
# it also pins what those two lines say when there is no document: `none`,
# and `0 of the 11` -- NOT a line that disappears, because the operator
# wondering why their `RAILS_BACKEND_ENDPOINT` findings offered nothing but
# `retain`/`blocked` is precisely the operator who forgot the flag.
diff -u - "$WORK/target-handoff-section.md" <<'HANDOFF' \
  || fail "--target's Handoff section is not the expected bytes"
## Handoff

complete: false
backend: none

`MIGRATION.handoff.json` records what each recovered route became.

| Status | Routes |
| --- | --- |
| migrated | 1 |
| open | 7 |
| blocked | 0 |
| retained | 0 |
| backend | 11 |
| redirect | 1 |

endpoints: 0 of the 11 `backend` route(s) are bound to a ZigBase operation.

Next: each `open` route in `MIGRATION.handoff.json` lists the
finding ids still unanswered. Answer each one in
`MIGRATION.decisions.json` -- `{"id": "<finding id>", "choice":
"<one of that finding's choices>", "rationale": "why"}` -- then
delete everything in the target except that file and re-run the
same command.
HANDOFF
# Everything strictly above the section, minus the single blank line that
# separates it, must be the -o report byte for byte. `head -n -N` is a GNU
# extension and CI also runs macOS, so the line count is taken explicitly.
awk '/^## Handoff$/{exit} {print}' "$TARGET/MIGRATION.md" >"$WORK/target-head-raw.md"
head_lines=$(wc -l <"$WORK/target-head-raw.md")
head -n "$((head_lines - 1))" "$WORK/target-head-raw.md" >"$WORK/target-report-head.md"
diff -u "$WORK/one.md" "$WORK/target-report-head.md" \
  || fail "--target's report differs from the -o run's above the Handoff section"

# The handoff carries its own schema marker and agrees with the exit code.
grep -q '"schema": "zigapagos.rails-handoff/1"' "$TARGET/MIGRATION.handoff.json" \
  || fail "the handoff does not carry its schema marker"
grep -q '"complete": false' "$TARGET/MIGRATION.handoff.json" \
  || fail "the handoff's complete verdict disagrees with the exit code"
# #167 Stage 3: no `--backend`, so the document reference is null and every
# route's endpoint is too. The wire shape is present either way -- a consumer
# reads one schema whether or not the operator passed the flag.
grep -q '^  "backend": null,$' "$TARGET/MIGRATION.handoff.json" \
  || fail "a run without --backend must still emit a null backend object"
grep -q '"endpoint": ' "$TARGET/MIGRATION.handoff.json" \
  || fail "the handoff is missing the per-route endpoint field"
! grep -q '"operation_id"' "$TARGET/MIGRATION.handoff.json" \
  || fail "a run with no binding must bind no route to an operation"

# The source tree is still read-only after --target, same invariant as the
# plain -o path above. This is the assertion that stops the converter from
# ever writing back into the Rails app it is reading.
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

# ...with exactly one exception (ruling S3): a target holding nothing but
# MIGRATION.decisions.json is accepted, because that is the state the
# decide-and-re-run loop leaves behind after the operator wipes the generated
# output and keeps their answers. The file is also picked up as the default
# --decisions input without being named on the command line.
DECIDED="$WORK/decided-target"
mkdir -p "$DECIDED"
printf '{"schema": "zigapagos.rails-decisions/1", "decisions": []}\n' >"$DECIDED/MIGRATION.decisions.json"
set +e
"$ZIGAPAGOS" migrate "$APP" --target "$DECIDED" >"$WORK/decided.out" 2>&1
decided_rc=$?
set -e
[[ $decided_rc -eq 3 ]] \
  || fail "--target on a directory holding only MIGRATION.decisions.json must be accepted (exit 3 here, routes still open), got $decided_rc"
[[ -e "$DECIDED/MIGRATION.handoff.json" ]] \
  || fail "the decisions-only target was accepted but nothing was assembled into it"
# The answers file survives the run untouched -- losing it would break the very
# loop this exception exists for.
grep -q 'zigapagos.rails-decisions/1' "$DECIDED/MIGRATION.decisions.json" \
  || fail "--target overwrote the operator's decisions file"

# --- --backend FILE: the ZigBase contract widens the choices (#167 Stage 3) --
# The document used here is the repo's OWN checked-in `contract/
# zigbase.openapi.json` -- a real 3.0.3 document with three consumer routes
# and no collections -- rather than a fixture written to fit: a reader who
# doubts an assertion below can open the file the assertion is about.
#
# Like --decisions, --backend needs no --target: without one it still widens
# what the manifest publishes, and the manifest is what an operator reads
# BEFORE writing any answers. That is what this first run pins.
BACKEND_DOC="$REPO/contract/zigbase.openapi.json"
"$ZIGAPAGOS" migrate "$APP" --from rails --backend "$BACKEND_DOC" -o "$WORK/backend.md" >/dev/null 2>&1 \
  || fail "--backend on a Rails source was rejected"

# The ONLY difference from the no-backend run of the same app is the `choices`
# of the RAILS_BACKEND_ENDPOINT rows. Everything else in the manifest --
# classifications, ids, messages, every other finding -- is discovery's
# verdict about the RAILS app, which a ZigBase document cannot change. A diff
# reduced to its changed lines is the assertion: a bare "the choices grew"
# grep would also pass an implementation that renamed a finding or
# reclassified a route as a side effect of reading the document.
#
# Sorted, NOT deduplicated: the multiplicities are the assertion. Four GET
# rows gain `getFlagsState` and two POST rows gain the two POST operations,
# and a `sort -u` here would pass an implementation that offered an operation
# to one route too many or too few.
diff "$WORK/one.manifest.json" "$WORK/backend.manifest.json" \
  | grep -E '^[<>]' >"$WORK/backend-manifest-delta.txt" || true
sort "$WORK/backend-manifest-delta.txt" >"$WORK/backend-manifest-delta-sorted.txt"
diff -u - "$WORK/backend-manifest-delta-sorted.txt" <<'DELTA' \
  || fail "--backend changed more (or less) of the manifest than the RAILS_BACKEND_ENDPOINT choices"
>         "clubLogin",
>         "clubLogin",
>         "getFlagsState",
>         "getFlagsState",
>         "getFlagsState",
>         "getFlagsState",
>         "submitContact",
>         "submitContact",
DELTA
# ...and those added words really are operation ids from that document, not
# invented ones. `getFlagsState` is a GET route, so it is offered to the GET
# rows; `clubLogin`/`submitContact` are POSTs and are offered to the POST
# rows. A verb never crosses over (`backend.choicesFor` refuses to), which is
# what makes an answer checkable at all.
grep -q '"operationId": "getFlagsState"' "$BACKEND_DOC" \
  || fail "the fixture assumption is stale: getFlagsState is not in the contract document"
grep -q 'GET /posts/stats (choices: getFlagsState, retain, blocked)' "$WORK/backend.md" \
  || fail "a GET backend route was not offered the document's GET operation"
grep -q 'POST /posts (choices: clubLogin, submitContact, retain, blocked)' "$WORK/backend.md" \
  || fail "a POST backend route was not offered the document's POST operations"
grep -q 'GET /posts/stats (choices: retain, blocked)' "$WORK/one.md" \
  || fail "the no-backend baseline this delta is measured against has moved"

# With --target, the document is recorded in both artifacts the operator
# reads. `file` is the BASENAME: the handoff is committed, and "no absolute
# paths in any artifact" is a determinism rule, so two operators running this
# from different checkouts must produce the same bytes.
BACKEND_TARGET="$WORK/backend-target"
set +e
"$ZIGAPAGOS" migrate "$APP" --from rails --target "$BACKEND_TARGET" --backend "$BACKEND_DOC" >"$WORK/backend-target.out" 2>&1
backend_target_rc=$?
set -e
[[ $backend_target_rc -eq 3 ]] \
  || fail "--backend must not change the exit code of a run with open routes, got $backend_target_rc"
grep -q '"file": "zigbase.openapi.json"' "$BACKEND_TARGET/MIGRATION.handoff.json" \
  || fail "the handoff does not name the backend document by basename"
grep -q '"contract_version": "2026-06-27.1"' "$BACKEND_TARGET/MIGRATION.handoff.json" \
  || fail "the handoff does not carry the document's contract version"
! grep -q "$REPO" "$BACKEND_TARGET/MIGRATION.handoff.json" \
  || fail "the handoff leaked the absolute path of the backend document"
grep -q '^backend: zigbase.openapi.json (2026-06-27.1)$' "$BACKEND_TARGET/MIGRATION.md" \
  || fail "the Handoff section does not name the backend document"
# Nothing was bound (this fixture answers no finding), so the endpoint count
# is still zero -- passing a document is not itself an answer.
grep -q '^endpoints: 0 of the 11 `backend` route(s) are bound to a ZigBase operation.$' "$BACKEND_TARGET/MIGRATION.md" \
  || fail "the Handoff section's endpoint count is wrong for a run that bound nothing"

# ...and now ANSWER one of those findings with one of the operations the
# document offered. This is the whole chain in one run: the document widens a
# finding's choices, the operator names an operation, and the route comes out
# of `MIGRATION.handoff.json` with a real `endpoint` object rather than a
# note. Without this case the endpoint machinery is only ever exercised at
# `null`, which every one of the assertions above is equally happy with.
#
# `GET /posts/stats` (config/routes.rb:12) is the fixture's JSON-rendering
# action -- classified `backend` by the "action renders JSON, not a view"
# rule asserted near the top of this file -- so it is the one route here that
# ruling A2 can actually bite on: a user-facing GET that needs an answer.
BOUND="$WORK/backend-bound"
mkdir -p "$BOUND"
cat >"$BOUND/MIGRATION.decisions.json" <<'DECISIONS'
{"schema": "zigapagos.rails-decisions/1", "decisions": [
  {"id": "RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L12.GET.posts",
   "choice": "getFlagsState",
   "rationale": "posts#stats renders the same JSON the flags-state route serves"}
]}
DECISIONS
set +e
"$ZIGAPAGOS" migrate "$APP" --from rails --target "$BOUND" --backend "$BACKEND_DOC" >"$WORK/bound.out" 2>&1
bound_rc=$?
set -e
# Still 3: six other routes remain open. The point is the endpoint, not the
# exit code -- and pinning the code exactly is what stops this case from
# passing on an unrelated failure.
[[ $bound_rc -eq 3 ]] || fail "the bound run should still be incomplete (other routes are open), got $bound_rc"
grep -q '^endpoints: 1 of the 11 `backend` route(s) are bound to a ZigBase operation.$' "$BOUND/MIGRATION.md" \
  || fail "an answered RAILS_BACKEND_ENDPOINT did not raise the report's endpoint count"
# The wire shape: all three fields, and the verb/path come from the DOCUMENT
# (`/api/flags/state`), not from the Rails route (`/posts/stats`). That is
# the difference between recording an answer and resolving it.
bound_endpoint=$(jq -c '.routes[] | select(.route_id == "GET /posts/stats") | .endpoint' "$BOUND/MIGRATION.handoff.json")
[[ "$bound_endpoint" == '{"operation_id":"getFlagsState","verb":"GET","path":"/api/flags/state"}' ]] \
  || fail "the answered route did not carry the document's operation as its endpoint, got: $bound_endpoint"
# One answer binds one route -- and no other.
bound_routes=$(jq -r '[.routes[] | select(.endpoint != null) | .route_id] | join(",")' "$BOUND/MIGRATION.handoff.json")
[[ "$bound_routes" == "GET /posts/stats" ]] \
  || fail "one answer bound more than the route it named: $bound_routes"

# A file that is not a ZigBase OpenAPI document is fatal, and the message
# names the file AND which of the three ways it failed -- `InvalidJson` (a
# truncated or hand-edited document), `NotOpenApi3` (the wrong file
# entirely), `NoPaths` (a document generated against an empty data dir) send
# an operator to three different fixes. Exit 1, not 3: the operator's own
# input is wrong, which is a failure of this invocation and not an unfinished
# migration.
set +e
"$ZIGAPAGOS" migrate "$APP" --from rails --target "$WORK/backend-bad" --backend "$APP/Gemfile" >"$WORK/backend-bad.out" 2>&1
backend_bad_rc=$?
set -e
[[ $backend_bad_rc -eq 1 ]] \
  || fail "--backend at a non-OpenAPI file must exit 1, got $backend_bad_rc"
grep -q 'is not a ZigBase OpenAPI document: InvalidJson' "$WORK/backend-bad.out" \
  || fail "the --backend rejection did not name the file and the reason"
[[ ! -e "$WORK/backend-bad" ]] \
  || fail "a rejected --backend must not create the target directory"

# `--backend` as the last word on the command line is a usage error naming
# the flag, not a crash and not a silent run without a document. Trailing
# flags are how a half-typed command usually arrives.
set +e
"$ZIGAPAGOS" migrate "$APP" --from rails -o "$WORK/backend-noarg.md" --backend >"$WORK/backend-noarg.out" 2>&1
backend_noarg_rc=$?
set -e
[[ $backend_noarg_rc -eq 1 ]] || fail "--backend with no argument must exit 1, got $backend_noarg_rc"
grep -q -- "error: --backend needs a file path" "$WORK/backend-noarg.out" \
  || fail "--backend with no argument did not name the flag"
[[ ! -e "$WORK/backend-noarg.md" ]] || fail "a rejected --backend must not write a report"

# A path that does not resolve is the SAME exit 1, not a crash (ruling
# S3-R4). This arm exists because both reads used to end in `fatal.file`,
# which routes through `fatal.msg` and PANICS under a Debug build -- and
# Debug is what `zig build` produces and what this script runs, so a typo'd
# path arrived as SIGABRT/134. Nothing tested either read path in either
# direction, so the whole class was invisible.
#
# Four shapes, because they take four different routes through the kernel and
# only the first was ever likely to be tried by hand: absent, a DIRECTORY
# where a file was meant (IsDir), unreadable (mode 000 -- skipped for root,
# who can read it anyway), and over the 16 MiB cap.
backend_read_failure() {  # <label> <path>
  local label="$1" path="$2" rc
  set +e
  "$ZIGAPAGOS" migrate "$APP" --from rails -o "$WORK/backend-$label.md" --backend "$path" \
    >"$WORK/backend-$label.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || fail "--backend at $label must exit 1 (not a panic), got $rc"
  grep -q -- "error: --backend $path could not be read:" "$WORK/backend-$label.out" \
    || fail "--backend at $label did not name the flag, the path and the OS error"
  [[ ! -e "$WORK/backend-$label.md" ]] || fail "a rejected --backend ($label) must not write a report"
}
backend_read_failure missing "$WORK/no-such-openapi.json"
mkdir -p "$WORK/backend-as-dir"
backend_read_failure isdir "$WORK/backend-as-dir"
# 17 MiB of zeros: one megabyte past the cap `readRailsInput` is given.
dd if=/dev/zero of="$WORK/huge.json" bs=1048576 count=17 status=none
backend_read_failure toobig "$WORK/huge.json"
rm -f "$WORK/huge.json"
if [[ "$(id -u)" != "0" ]]; then
  cp "$BACKEND_DOC" "$WORK/unreadable.json"
  chmod 000 "$WORK/unreadable.json"
  backend_read_failure unreadable "$WORK/unreadable.json"
  chmod 644 "$WORK/unreadable.json"
fi

# The SAME rule for --decisions, which shares the reader and shared the
# defect. An explicit --decisions is held to a higher standard than the
# --target default: the operator named this file, so its absence is an error
# rather than the ordinary first-run state.
set +e
"$ZIGAPAGOS" migrate "$APP" --from rails -o "$WORK/dec-missing.md" --decisions "$WORK/no-such-answers.json" \
  >"$WORK/dec-missing.out" 2>&1
dec_missing_rc=$?
set -e
[[ $dec_missing_rc -eq 1 ]] \
  || fail "an explicitly-named --decisions file that does not exist must exit 1 (not a panic), got $dec_missing_rc"
grep -q -- "error: --decisions $WORK/no-such-answers.json could not be read:" "$WORK/dec-missing.out" \
  || fail "the missing --decisions file was not named with its OS error"
[[ ! -e "$WORK/dec-missing.md" ]] || fail "a rejected --decisions must not write a report"

# ...and the FIRST run of a migration, with no --decisions and no answers
# file in the target, is still the ordinary case: existence-gated, not
# read-gated. Without this control the arm above is satisfied by a build that
# made every run demand an answers file.
FIRSTRUN="$WORK/first-run-target"
set +e
"$ZIGAPAGOS" migrate "$APP" --from rails --target "$FIRSTRUN" >"$WORK/first-run.out" 2>&1
first_run_rc=$?
set -e
[[ $first_run_rc -eq 3 ]] \
  || fail "a first run with no decisions file must reach the handoff (exit 3), got $first_run_rc"
[[ -e "$FIRSTRUN/MIGRATION.handoff.json" ]] || fail "the first run assembled nothing"

# Well-formed JSON that is not OpenAPI 3.x is the same fatal, with the reason
# that distinguishes it. This is the case a bare "could not parse" message
# would leave an operator guessing about.
printf '{"swagger": "2.0", "paths": {}}\n' >"$WORK/swagger2.json"
set +e
"$ZIGAPAGOS" migrate "$APP" --from rails -o "$WORK/backend-v2.md" --backend "$WORK/swagger2.json" >"$WORK/backend-v2.out" 2>&1
backend_v2_rc=$?
set -e
[[ $backend_v2_rc -eq 1 ]] || fail "--backend at a Swagger 2.0 document must exit 1, got $backend_v2_rc"
grep -q 'is not a ZigBase OpenAPI document: NotOpenApi3' "$WORK/backend-v2.out" \
  || fail "a non-3.x document was not rejected as NotOpenApi3"
[[ ! -e "$WORK/backend-v2.md" ]] || fail "a rejected --backend must not write a report"

# --backend is Rails-only, rejected the same way --strict and --decisions are
# rather than silently ignored ("report, never omit silently").
BACKEND_ASTRO="$WORK/backend-astro"
mkdir -p "$BACKEND_ASTRO/src/pages"
touch "$BACKEND_ASTRO/astro.config.mjs"
set +e
"$ZIGAPAGOS" migrate "$BACKEND_ASTRO" --backend "$BACKEND_DOC" -o "$WORK/backend-astro.md" >"$WORK/backend-astro.out" 2>&1
backend_astro_rc=$?
set -e
[[ $backend_astro_rc -eq 1 ]] || fail "--backend on a non-Rails source must exit 1, got $backend_astro_rc"
grep -q -- "--backend only applies to Rails sources" "$WORK/backend-astro.out" \
  || fail "the --backend rejection on a non-Rails source did not explain why"
[[ ! -e "$WORK/backend-astro.md" ]] || fail "a rejected --backend combination must not write a report"

# `--doctor` is mutually exclusive with `--backend`, and the message lists it.
# Both halves matter: dropping `or backend_path != null` from the guard leaves
# `--doctor --backend` running the doctor and silently ignoring the document,
# and dropping the word from the message leaves an operator reading a list
# that does not include the flag they passed. Nothing pinned this message
# before (review finding M-3).
set +e
"$ZIGAPAGOS" migrate "$APP" --from rails --doctor "$WORK/nonexistent-site" --backend "$BACKEND_DOC" \
  >"$WORK/backend-doctor.out" 2>&1
backend_doctor_rc=$?
set -e
[[ $backend_doctor_rc -eq 1 ]] \
  || fail "--doctor with --backend must exit 1, got $backend_doctor_rc"
grep -q -- "error: --doctor is mutually exclusive with --target, --decisions, --backend, --scaffold, --convert-content, and --copy-assets" \
  "$WORK/backend-doctor.out" \
  || fail "the --doctor exclusion message does not list --backend"

# #187. `--runtime-path`'s help described the Rails half as the `.spa.tsx` a
# `spa` decision produced, which was true before Stage 3 and is not now: every
# island a backend answer binds emits a `package.json` too, which made
# `file:TODO-SET-RUNTIME-PATH` the ordinary outcome of a successful run rather
# than a rare one -- the defect #179 fixed by falling back to
# ZIGAPAGOS_RUNTIME_DIR. Neither fact was in the help, and an operator reading
# it had no reason to set either. Pinned like the exclusion message above, on
# the two sentences that would go stale if the emission rule moved again.
"$ZIGAPAGOS" migrate --help >"$WORK/help.out" 2>&1
grep -q -- "every island a" "$WORK/help.out" \
  || fail "--runtime-path help does not say a backend answer's islands emit a package.json"
grep -q -- "Falls back to ZIGAPAGOS_RUNTIME_DIR when that is" "$WORK/help.out" \
  || fail "--runtime-path help does not name the ZIGAPAGOS_RUNTIME_DIR fallback (#179)"

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
