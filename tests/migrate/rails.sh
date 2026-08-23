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
# Full accounting of the fixture's 10 non-.other rows: 14 files walked
# (13 under app/, 1 under public/), 14 counted across these 10 rows — so a
# kind silently dropped from the table shows up here as a count mismatch.
grep -q "Views | 2" "$WORK/one.md" || fail "expected 2 views"
grep -q "Layouts | 1" "$WORK/one.md" || fail "expected 1 layout"
grep -q "Partials | 2" "$WORK/one.md" || fail "expected 2 partials (incl. layouts/_nav)"
grep -q "Mailer views | 1" "$WORK/one.md" || fail "expected 1 mailer view"
grep -q "Controllers | 1" "$WORK/one.md" || fail "expected 1 controller"
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
  # that a genuine, certain route carries no uncertainty marker.
  grep -Fxq -- '- `GET /posts` → `posts#index`' "$WORK/one.md" \
    || fail "resources :posts did not expand, or a certain route gained a spurious uncertainty marker"
  # member { post :publish } nests under the resource's :id.
  grep -Fxq -- '- `POST /posts/:id/publish` → `posts#publish`' "$WORK/one.md" \
    || fail "member route missing"
  # namespace :admin prefixes both the path and the controller module.
  grep -Fxq -- '- `GET /admin/users` → `admin/users#index`' "$WORK/one.md" \
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
  grep -Fxq -- '- `GET /admin/health` → `admin#health` — **uncertain**' "$WORK/one.md" \
    || fail "conditional route missing its uncertainty marker"
  grep -q "RAILS_ROUTE_CONDITIONAL" "$WORK/one.md" || fail "conditional route not reported as a blocker"
else
  echo "SKIP: route assertions (no ruby on PATH)"
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
