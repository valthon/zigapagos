#!/usr/bin/env bash
# tests/migrate/rails-presentation.sh -- #167.
#
# Stage 1: the manifest names every fragment a converter would refuse.
# Stage 2: the whole decide -> re-run loop, end to end. Run 1 converts what it
# can and exits 3 with a handoff full of questions; the checked-in
# MIGRATION.decisions.json answers them; run 2 exits 0 with `complete: true`;
# the target it produced then BUILDS with `zigapagos release` and passes
# `zigapagos doctor` -- which is the only definition of "a valid Zigapagos
# project" that cannot be faked by a file listing.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
fail() { echo "FAIL: $*"; exit 1; }
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"
[[ -x "$ZIGAPAGOS" ]] || zig build || fail "zig build failed"
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"
command -v ruby >/dev/null || { echo "SKIP: ruby not on PATH; Stage 1 findings need the sidecar"; exit 0; }
command -v jq >/dev/null || fail "jq required"

DECISIONS="$REPO/tests/migrate/rails-presentation/MIGRATION.decisions.json"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp -R "$REPO/tests/migrate/rails-presentation" "$WORK/app"
before="$(cd "$WORK/app" && find . -type f | sort | xargs shasum)"

# --- run 1: no decisions ----------------------------------------------------
# Exit 3 BY VALUE, not merely non-zero: 3 means "the conversion ran and some
# route is still unanswered", 1 means "discovery is broken or --strict".
# `|| fail` would have accepted either, and the two send an operator (or a CI
# loop) to completely different work.
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out1"
run1_rc=$?
set -e
[[ $run1_rc -eq 3 ]] || fail "run 1 must exit 3 while routes are open, got $run1_rc"

MANIFEST="$WORK/out1/MIGRATION.manifest.json"
HANDOFF="$WORK/out1/MIGRATION.handoff.json"
[[ -f "$MANIFEST" ]] || fail "no manifest"
[[ -f "$HANDOFF" ]] || fail "no handoff"

after="$(cd "$WORK/app" && find . -type f | sort | xargs shasum)"
[[ "$before" == "$after" ]] || fail "source tree modified by run 1"

# --- route names ------------------------------------------------------------
name_of() { jq -r --arg v "$1" --arg p "$2" '.routes[] | select(.verb == $v and .path == $p) | .name' "$MANIFEST"; }
[[ "$(name_of GET /)" == "root" ]] || fail "root name: $(name_of GET /)"
[[ "$(name_of GET /about)" == "about" ]] || fail "about name"
[[ "$(name_of GET /posts)" == "posts" ]] || fail "posts name"
[[ "$(name_of GET /posts/:id)" == "post" ]] || fail "post name"
[[ "$(name_of GET /session/new)" == "new_session" ]] || fail "new_session name"
[[ "$(name_of POST /registration)" == "registration" ]] || fail "registration name"

# --- layouts ---------------------------------------------------------------
about_layout=$(jq -r '.routes[] | select(.path == "/about") | .layout' "$MANIFEST")
[[ "$about_layout" == "app/views/layouts/marketing.html.erb" ]] || fail "declared layout not honoured: $about_layout"
posts_layout=$(jq -r '.routes[] | select(.path == "/posts" and .verb == "GET") | .layout' "$MANIFEST")
[[ "$posts_layout" == "app/views/layouts/application.html.erb" ]] || fail "dynamic layout must fall back to convention: $posts_layout"

# --- findings: exact id set ------------------------------------------------
# Every finding this stage can emit appears at least once, with the exact
# id that a Stage 2 decision file will reference. An id is (code, path,
# location) -- assert the WHOLE thing so a shifted line is caught.
#
# NOTE on the registration finding's path: `resource :registration` maps
# (by this parser's own tested convention -- see routes_test.rb's "singular
# resource has exactly the 7 non-index actions") to a SINGULAR controller
# identifier "registration", not the pluralized "registrations" real Rails
# would use for a singular resource's controller class. R13 (controller
# ruling): the fixture keeps the REAL, pluralized RegistrationsController/
# SessionsController and app/views/registrations/ / app/views/sessions/
# directories,
# and works around the gap with an explicit `controller: "registrations"`
# (config/routes.rb) -- redundant in real Rails, honest to this parser.
# Filed as a #166 follow-up. Verified empirically: without the override,
# the route never resolved a template at all (zero findings from the
# file), which is what caught the gap in the first place.
have_finding() { jq -e --arg id "$1" '.findings[] | select(.id == $id)' "$MANIFEST" >/dev/null || fail "missing finding $1"; }
have_finding 'RAILS_HELPER_UNKNOWN.app/views/pages/help%2Ehtml%2Eerb.L1C18'
have_finding 'RAILS_RAW_OUTPUT.app/views/pages/help%2Ehtml%2Eerb.L1C47'
have_finding 'RAILS_I18N_UNRESOLVED.app/views/pages/help%2Ehtml%2Eerb.L1C62'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L1C33'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/posts/show%2Ehtml%2Eerb.L1C9'
have_finding 'RAILS_ROUTE_HELPER_DYNAMIC.app/views/posts/_post%2Ehtml%2Eerb.L1C14'
have_finding 'RAILS_LAYOUT_DYNAMIC.app/controllers/posts_controller%2Erb.L2'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/registrations/new%2Ehtml%2Eerb.L1C121'
have_finding 'RAILS_PARTIAL_DYNAMIC.app/views/posts/index%2Ehtml%2Eerb.L1C61'
have_finding 'RAILS_TEMPLATE_CONTROL_FLOW.app/views/posts/_post%2Ehtml%2Eerb.L8C4'
# Self-review coverage: the three codes above don't reach
# (TEMPLATE_PARSE_ERROR, ROUTE_HELPER_UNKNOWN, TEMPLATE_CONTROL_FLOW),
# exercised via small dedicated fragments so every code the derivation
# table can emit at Stage 1 appears at least once somewhere in this
# fixture.
#
# Three of ruling S12's codes are NOT pinned here and cannot be until the
# fixture grows the constructs that raise them: RAILS_TURBO_FRAME,
# RAILS_TURBO_STREAM and RAILS_COMPONENT_ROOT need a turbo_frame_tag, a
# turbo_stream and a react_component call respectively, and this app has
# none (its dashboard.html.erb carries a Stimulus data-controller, which is
# a different marker entirely). They are covered by findings.zig's own
# unit tests. Adding them here changes route classification across the
# fixture, so it is its own change, not a rider on this one.
have_finding 'RAILS_TEMPLATE_PARSE_ERROR.app/views/pages/broken%2Ehtml%2Eerb.L2'
have_finding 'RAILS_ROUTE_HELPER_UNKNOWN.app/views/pages/links%2Ehtml%2Eerb.L1C5'
# #167 Stage 2 ruling S12: the fragment kinds that used to convert to a
# `rails:unmapped` placeholder now derive a finding, so a route holding one can
# be acknowledged. Both form views contribute:
#
#   sessions/new.html.erb    form_with(url: session_path)   -> no model
#   registrations/new.html.erb  form_with(model: @user, ...) -> model `user`
#
# ONE finding per form, not one per field: each of these forms has four
# `f.*_field` calls inside it and none of them adds a second question (the
# outermost form in a nesting is the decision). The per-file counts below are
# what pin that -- a regression to one-per-field would make them 5 and 6.
have_finding 'RAILS_BACKEND_ENDPOINT.app/views/sessions/new%2Ehtml%2Eerb.L1C5'
have_finding 'RAILS_BACKEND_ENDPOINT.app/views/registrations/new%2Ehtml%2Eerb.L1C139'
# The two `errors` regions in registrations/new (`@user&.errors&.any?` and
# `@user.errors.full_messages`) are a different question from the form's --
# how request-time validation state is PRESENTED -- and get the same code an
# ivar read does.
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/registrations/new%2Ehtml%2Eerb.L1C4'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/registrations/new%2Ehtml%2Eerb.L1C36'
# #167 Stage 2 rulings S1/S12: the two ROUTE-scoped rows, keyed on the
# config/routes.rb line the route was declared on rather than on a template.
have_finding 'RAILS_ROUTE_DYNAMIC_SEGMENT.config/routes%2Erb.L14'
have_finding 'RAILS_REDIRECT_HOST_CONFIG.config/routes%2Erb.L47'
sessions_count=$(jq '[.findings[] | select(.source.file == "app/views/sessions/new.html.erb")] | length' "$MANIFEST")
[[ "$sessions_count" == "1" ]] || fail "sessions/new should raise exactly one finding (the form), got $sessions_count"
registrations_count=$(jq '[.findings[] | select(.source.file == "app/views/registrations/new.html.erb")] | length' "$MANIFEST")
[[ "$registrations_count" == "4" ]] || fail "registrations/new should raise 4 findings (1 form, 2 errors, 1 ivar), got $registrations_count"
# linked.html.erb is an ordinary static view HERE; it is the third run below
# that makes the templates op refuse it. Pinning zero findings for it in this
# run is what proves that run's finding comes from the refusal and not from
# the file's own content.
linked_findings=$(jq '[.findings[] | select(.source.file == "app/views/pages/linked.html.erb")] | length' "$MANIFEST")
[[ "$linked_findings" == "0" ]] || fail "linked.html.erb is clean in the primary run, got $linked_findings findings"

# The clean page raises NO finding.
about_count=$(jq '[.findings[] | select(.source.file == "app/views/pages/about.html.erb")] | length' "$MANIFEST")
[[ "$about_count" == "0" ]] || fail "about.html.erb should be clean, got $about_count findings"
# The Haml view raises exactly ONE, and it is #167 Stage 2 ruling S18's:
# `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` as a FINDING beside the #166 blocker.
# The blocker states the fact (this engine has no converter); the finding is
# the operator's half of it, and without an id on this path a route rendering
# a Haml view could never be acknowledged by any choice -- `complete` would be
# unreachable for the whole app. `line: null` is what still proves the
# templates op never parsed the file: a scanned template's findings all carry
# a line.
haml_count=$(jq '[.findings[] | select(.source.file | endswith(".haml"))] | length' "$MANIFEST")
[[ "$haml_count" == "1" ]] || fail "the Haml view should raise exactly the engine finding, got $haml_count"
have_finding 'RAILS_TEMPLATE_ENGINE_UNSUPPORTED.app/views/posts/legacy%2Ehtml%2Ehaml.engine'
haml_line=$(jq -r '.findings[] | select(.source.file | endswith(".haml")) | .source.line' "$MANIFEST")
[[ "$haml_line" == "null" ]] || fail "the Haml finding must carry no line: nothing parsed the file, got $haml_line"
haml_choices=$(jq -r '.findings[] | select(.source.file | endswith(".haml")) | .choices | join(",")' "$MANIFEST")
[[ "$haml_choices" == "retain,blocked" ]] || fail "a Haml route can only be retained or blocked, got: $haml_choices"
jq -e '.blockers[] | select(.code == "RAILS_TEMPLATE_ENGINE_UNSUPPORTED")' "$MANIFEST" >/dev/null || fail "haml blocker missing"

# Every finding has the wire shape and a choices list drawn from the fixed vocabulary.
bad=$(jq -r '.findings[] | select((.id|type) != "string" or (.choices|length) == 0 or (.choices - ["island","spa","backend","retain","blocked"] | length) != 0) | .id' "$MANIFEST")
[[ -z "$bad" ]] || fail "malformed findings: $bad"

# Schema validation of both real instances. `rails_manifest_validate` takes
# any schema + any instance, so the handoff is validated by the same tool.
[[ -x "$REPO/zig-out/bin/rails_manifest_validate" ]] || zig build rails-manifest-validate || fail "validator build"
"$REPO/zig-out/bin/rails_manifest_validate" "$REPO/contract/rails-presentation.v1.schema.json" "$MANIFEST" || fail "manifest fails schema"
"$REPO/zig-out/bin/rails_manifest_validate" "$REPO/contract/rails-handoff.v1.schema.json" "$HANDOFF" || fail "handoff fails schema"

grep -q '^## Findings' "$WORK/out1/MIGRATION.md" || fail "MIGRATION.md lacks a Findings section"
grep -q '^## Handoff' "$WORK/out1/MIGRATION.md" || fail "MIGRATION.md lacks a Handoff section"

# --- run 1: the handoff's verdict, route by route --------------------------
# The whole point of the artifact: which routes are DONE, which are waiting on
# a human, and which need neither. Pinned per route rather than by counts, so
# a status that moves from `migrated` to `open` (or the reverse) names itself.
[[ "$(jq -r '.complete' "$HANDOFF")" == "false" ]] || fail "run 1 must not be complete"
route_count=$(jq '.routes | length' "$HANDOFF")
[[ "$route_count" == "14" ]] || fail "expected 14 routes in the handoff, got $route_count -- a new route needs a pin below"
status_of() { jq -r --arg r "$1" '.routes[] | select(.route_id == $r) | .status' "$HANDOFF"; }
want_status() {
  local got; got="$(status_of "$1")"
  [[ "$got" == "$2" ]] || fail "run 1: $1 should be $2, got '$got'"
}
# `/` is `root "pages#about"` and `/about` is the same action: one view, one
# layout, two URLs. Ruling S16 lets a view be shared as long as the LAYOUT is
# the same (it is -- PagesController declares `layout "marketing"` for both),
# so both migrate off one `layouts/pages/about.shtml`.
want_status 'GET /'                  migrated
want_status 'GET /about'             migrated
want_status 'GET /linked'            migrated
# Every open route below names a finding the decisions file answers.
want_status 'GET /help'              open
want_status 'GET /broken'            open
want_status 'GET /links'             open
want_status 'GET /posts'             open
want_status 'GET /posts/:id'         open
want_status 'GET /posts/legacy'      open
want_status 'GET /session/new'       open
want_status 'GET /registration/new'  open
# No page, no decision, no question: a pure `redirect_to` action is answered
# by the host config, and a non-GET route is Stage 3's endpoint work.
want_status 'GET /old'               redirect
want_status 'POST /session'          backend
want_status 'POST /registration'     backend
# ...and the redirect is reported as one, with no target: Stage 2 records that
# the route redirects, not where to.
[[ "$(jq -r '.redirects | length' "$HANDOFF")" == "1" ]] || fail "expected exactly one redirect"
[[ "$(jq -r '.redirects[0].from' "$HANDOFF")" == "/old" ]] || fail "the redirect should be /old"

# --- run 1: the converted tree ---------------------------------------------
listing="$(cd "$WORK/out1" && find . -type f | sort | tr '\n' ' ')"
expected_listing="./.gitignore ./AGENTS.md ./CLAUDE.md ./MIGRATION.handoff.json ./MIGRATION.manifest.json ./MIGRATION.md ./assets/images/logo.png ./assets/robots.txt ./assets/stylesheets/application.css ./build.sh ./content/about/index.smd ./content/help/index.smd ./content/index.smd ./content/linked/index.smd ./content/links/index.smd ./content/posts/index.smd ./content/registration/new/index.smd ./content/session/new/index.smd ./layouts/pages/about.shtml ./layouts/pages/help.shtml ./layouts/pages/linked.shtml ./layouts/pages/links.shtml ./layouts/posts/index.shtml ./layouts/registrations/new.shtml ./layouts/sessions/new.shtml ./layouts/templates/application.shtml ./layouts/templates/marketing.shtml ./zigapagos.ziggy "
[[ "$listing" == "$expected_listing" ]] || fail "run 1 target listing changed:
  got:      $listing
  expected: $expected_listing"
# An `open` route still gets its page -- open means nobody has decided, not
# that nothing was produced -- so there are more content pages than migrated
# routes. The two routes with NO page are the ones whose view could not be
# converted at all (broken.html.erb, legacy.html.haml).
[[ ! -e "$WORK/out1/content/broken" ]] || fail "an unconvertible view must not leave a page behind"
[[ ! -e "$WORK/out1/content/posts/legacy" ]] || fail "the Haml route must not leave a page behind"
# Ruling S17: public/assets/** is the pipeline's compiled OUTPUT. The sources
# are copied from app/assets/ (see assets/images/logo.png), so copying it too
# would ship every asset twice plus a Rails bookkeeping file.
[[ -f "$WORK/out1/assets/images/logo.png" ]] || fail "app/assets image not copied"
[[ -f "$WORK/out1/assets/robots.txt" ]] || fail "public/robots.txt not copied"
[[ ! -e "$WORK/out1/assets/assets" ]] || fail "public/assets/** must not be copied as site assets (ruling S17)"
# The scaffold writes with exclusive-create; a `.new` file would mean
# something took `--scaffold`'s versioning path instead.
new_files="$(find "$WORK/out1" -name '*.new*' | tr '\n' ' ')"
[[ -z "$new_files" ]] || fail "the target must never contain .new files, got: $new_files"

# The page's frontmatter, byte for byte. `.layout` names the per-view
# template, and `.custom.rails` is the audit trail back to the Rails source.
cat > "$WORK/about.expected" <<'SMD'
---
.title = "About",
.layout = "pages/about.shtml",
.custom = {
    .rails = {
        .route = "GET /about",
        .controller = "pages",
        .action = "about",
        .source = "app/views/pages/about.html.erb",
    },
},
---
SMD
cmp "$WORK/about.expected" "$WORK/out1/content/about/index.smd" || fail "content/about/index.smd frontmatter changed"

# The layout is a SuperHTML template: a `head` block (ruling S7 -- always
# declared, so a view may fill it) and a `main` block where Rails yielded.
marketing="$WORK/out1/layouts/templates/marketing.shtml"
grep -q '<head id="head">' "$marketing" || fail "the layout must declare a head block"
grep -q '<super></head>' "$marketing" || fail "the layout's head must end with a <super>"
grep -q '<div id="main"><super></div>' "$marketing" || fail "the layout must carry the main block"
# ...and the view extends it. First line, not merely 'contains': SuperHTML
# requires `<extend>` to be the first thing in the file.
head -1 "$WORK/out1/layouts/pages/about.shtml" | grep -qx '<extend template="marketing.shtml">' \
  || fail "layouts/pages/about.shtml must start with <extend template=\"marketing.shtml\">"

# --- run 2: the operator's answers -----------------------------------------
# The checked-in decisions file answers every finding that keeps a route open.
#
# ON THE IDS IN THAT FILE (it is JSON, and `decisions.zig` rejects any key
# outside schema/decisions, so the note has to live here): a finding id is
# `<code>.<path>.<loc>`, and `<loc>` is the LINE and COLUMN the construct sits
# at. Editing a fixture template therefore moves every id after the edit --
# `registrations/new.html.erb` alone accounts for four -- and the answers stop
# matching, which surfaces as `RAILS_DECISION_STALE` blockers and a run that
# will not complete rather than as anything obviously wrong. Re-derive them
# from run 1's manifest (`jq -r '.findings[].id'`) after any fixture edit, and
# re-pin the `have_finding` lines above with them.
# `--runtime-path` points the generated package.json at this checkout's
# runtime/ so the SPA scaffold's `@z/runtime` dependency resolves without a
# published npm package -- the same thing site/build.sh does via
# ZIGAPAGOS_RUNTIME_DIR.
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out2" \
  --decisions "$DECISIONS" --runtime-path "$REPO/runtime"
run2_rc=$?
set -e
[[ $run2_rc -eq 0 ]] || fail "run 2 must exit 0 once every route is answered, got $run2_rc"
HANDOFF2="$WORK/out2/MIGRATION.handoff.json"
[[ "$(jq -r '.complete' "$HANDOFF2")" == "true" ]] || fail "run 2 must be complete"
"$REPO/zig-out/bin/rails_manifest_validate" "$REPO/contract/rails-handoff.v1.schema.json" "$HANDOFF2" || fail "run 2 handoff fails schema"
# No route may be left `open` when `complete` is true -- that is the whole
# claim the exit code rests on.
still_open="$(jq -r '.routes[] | select(.status == "open") | .route_id' "$HANDOFF2" | tr '\n' ' ')"
[[ -z "$still_open" ]] || fail "complete:true with open routes: $still_open"
want2() {
  local got; got="$(jq -r --arg r "$1" '.routes[] | select(.route_id == $r) | .status' "$HANDOFF2")"
  [[ "$got" == "$2" ]] || fail "run 2: $1 should be $2, got '$got'"
}
want2 'GET /help'             blocked
want2 'GET /broken'           blocked
want2 'GET /links'            blocked
want2 'GET /posts/legacy'     blocked
want2 'GET /posts'            retained
want2 'GET /session/new'      retained
# Ruling S19, and the only route that exercises it: registrations/new.html.erb
# renders `full_messages.each do |m| … <%= m %>`, and `m` is an unbound block
# local that `convert.zig` leaves as `<!-- rails:unmapped local -->` with no
# finding id. Ruling S6's net used to run BEFORE the decision was read, so this
# route stayed `open` however it was answered and the whole run could never
# complete. The answer is honoured now -- `retain` means the page stays on
# Rails, so what the converter could not map is moot -- and the unmapped
# region is still reported, as a footnote that cannot change the status.
want2 'GET /registration/new' retained
reg_note=$(jq -r '.routes[] | select(.route_id == "GET /registration/new") | .note' "$HANDOFF2")
grep -q 'local left unmapped' <<<"$reg_note" || fail "the retained route must still report its unmapped region: $reg_note"
want2 'GET /posts/:id'        migrated
# A decision on a redirect is RECORDED but never changes the status: the host
# config answered it before anyone was asked.
want2 'GET /old'              redirect
[[ "$(jq -r '.routes[] | select(.route_id == "GET /old") | .decision.choice' "$HANDOFF2")" == "retain" ]] \
  || fail "the redirect's decision should still be recorded"

# The `spa` choice is the only one that emits code, so it is the only one with
# an artifact to check.
[[ -f "$WORK/out2/spa/posts.spa.tsx" ]] || fail "the spa decision must scaffold spa/posts.spa.tsx"
[[ -f "$WORK/out2/package.json" ]] || fail "a SPA needs a package.json"
[[ -f "$WORK/out2/tsconfig.json" ]] || fail "a SPA needs a tsconfig.json"
grep -q "^export const spa = { base: \"/posts\" };$" "$WORK/out2/spa/posts.spa.tsx" || fail "the SPA must mount at /posts"
# Quoted in build.sh: `--spa=path|base` unquoted is a shell PIPELINE.
grep -qF -- "--spa='spa/posts.spa.tsx|/posts'" "$WORK/out2/build.sh" || fail "build.sh must carry a quoted --spa entry"

# --- run 2: the answered tree (ruling S20) ---------------------------------
# The exact tree, which is what makes S20 visible: an acknowledged route
# writes NO page and NO view file. Compare with run 1's listing above --
# `content/help`, `content/links`, `content/posts`, `content/session`,
# `content/registration` and their `layouts/<ctrl>/<action>.shtml` are all
# gone, because `retained` means the page stays on Rails and `blocked` means
# it does not ship. Emitting them anyway made `blocked` a relabelling: the
# built site served a blank `<main>` for a route the handoff called blocked,
# which is worse than a 404 because it looks deliberate.
#
# `layouts/templates/application.shtml` DOES survive with no page extending
# it: a layout is shared chrome, written once per layout rather than per
# route, and every route using this one happens to be retained here.
listing2="$(cd "$WORK/out2" && find . -type f | sort | tr '\n' ' ')"
expected_listing2="./.gitignore ./AGENTS.md ./CLAUDE.md ./MIGRATION.handoff.json ./MIGRATION.manifest.json ./MIGRATION.md ./assets/images/logo.png ./assets/robots.txt ./assets/stylesheets/application.css ./build.sh ./content/about/index.smd ./content/index.smd ./content/linked/index.smd ./layouts/pages/about.shtml ./layouts/pages/linked.shtml ./layouts/templates/application.shtml ./layouts/templates/marketing.shtml ./package.json ./spa/posts.spa.tsx ./tsconfig.json ./zigapagos.ziggy "
[[ "$listing2" == "$expected_listing2" ]] || fail "run 2 target listing changed:
  got:      $listing2
  expected: $expected_listing2"
# ...and the handoff agrees: an acknowledged route claims no artifact, so the
# record and the tree cannot drift apart.
for r in 'GET /help' 'GET /links' 'GET /posts' 'GET /session/new' 'GET /registration/new'; do
  n=$(jq -r --arg r "$r" '.routes[] | select(.route_id == $r) | .artifacts | length' "$HANDOFF2")
  [[ "$n" == "0" ]] || fail "$r is acknowledged and must claim no artifact, got $n"
done

# --- determinism ------------------------------------------------------------
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out2b" \
  --decisions "$DECISIONS" --runtime-path "$REPO/runtime" >/dev/null
cmp "$WORK/out2/MIGRATION.manifest.json" "$WORK/out2b/MIGRATION.manifest.json" || fail "manifest not deterministic"
cmp "$HANDOFF2" "$WORK/out2b/MIGRATION.handoff.json" || fail "handoff not deterministic"
# MIGRATION.md joins the determinism cmp set (#178). Both runs migrate the
# same source path, so this cmp alone would not have caught the old
# path-as-given title; the two greps below are the pins for that.
cmp "$WORK/out2/MIGRATION.md" "$WORK/out2b/MIGRATION.md" || fail "MIGRATION.md not deterministic"
# The fixture is migrated from its scratch copy at $WORK/app, so the basename
# the title must carry is `app` -- and nothing of the scratch path above it.
grep -q "^# Migrating app to Zigapagos" "$WORK/out2/MIGRATION.md" || fail "MIGRATION.md title must be the app basename"
grep -q "$WORK" "$WORK/out2/MIGRATION.md" && fail "MIGRATION.md embeds the scratch path"

# --- the target is a real Zigapagos project --------------------------------
# The criterion no listing can fake: the emitted tree BUILDS, and the built
# site passes the auditor. `build.sh` is the target's own entry point (bun
# install + `zigapagos release --spa=...`), so this exercises the generated
# command line too, not a hand-written one.
if command -v bun >/dev/null; then
  ( cd "$WORK/out2" && ZIGAPAGOS_BIN="$ZIGAPAGOS" bash build.sh >"$WORK/release.log" 2>&1 ) \
    || { tail -20 "$WORK/release.log"; fail "zigapagos release failed on the migrated target"; }
  [[ -f "$WORK/out2/zig-out/site/about/index.html" ]] || fail "the release did not emit the about page"
  [[ -f "$WORK/out2/zig-out/site/posts/_shell.html" ]] || fail "the release did not emit the SPA shell"
  # Ruling S20 in the BUILT site, which is where it actually matters: a
  # blocked route has no page here at all. Before S20 these existed and
  # rendered an empty `<main>` -- a route the handoff called blocked, served
  # as a blank page.
  [[ ! -e "$WORK/out2/zig-out/site/help/index.html" ]] || fail "a blocked route must not be served at all"
  [[ ! -e "$WORK/out2/zig-out/site/links/index.html" ]] || fail "a blocked route must not be served at all"
  [[ ! -e "$WORK/out2/zig-out/site/session/new/index.html" ]] || fail "a retained route stays on Rails; the static tree must not answer it"
  # A KNOWN GAP, pinned so it flips loudly the day the emitter grows a
  # `head:`: the scaffolded `.spa.tsx` declares no `spa.head`, so the SPA's
  # routes render without the site's stylesheet. `release` says so; when the
  # emitter starts emitting the site's stylesheet assets into `spa.head` this
  # grep fails and this comment is the instruction to delete it.
  grep -q "declares no spa.head" "$WORK/release.log" \
    || fail "the no-spa.head warning is gone -- if the scaffold now emits a head:, delete this pin"
  "$ZIGAPAGOS" doctor "$WORK/out2/zig-out/site" >"$WORK/doctor.log" 2>&1 || { cat "$WORK/doctor.log"; fail "doctor failed"; }
  grep -q 'doctor: 0 errors' "$WORK/doctor.log" || { cat "$WORK/doctor.log"; fail "doctor reported errors on the migrated site"; }
  # The warnings that DO remain are S20's honest consequence and nothing
  # else: the shared `_nav` partial links to /session/new, which is retained
  # -- Rails still serves it, this tree does not, and a dangling link is
  # exactly the right thing for the auditor to say about a partial migration.
  # Any OTHER warning is a real regression, so the check is per-line.
  other=$(grep '^warn ' "$WORK/doctor.log" | grep -v "dangling-internal-link: .*href '/session/new'" || true)
  [[ -z "$other" ]] || { cat "$WORK/doctor.log"; fail "unexpected doctor warnings: $other"; }
else
  echo "SKIP(partial): bun not on PATH -- the migrated target was not built or audited"
fi

# --- a decisions file that does not fit this run ---------------------------
# A choice the finding does not offer is a user error, and fatal: exit 1, with
# the entry, the choice AND the allowed set named. `migrated` is not a choice
# anywhere in the vocabulary, so this is also what stops an operator declaring
# the Haml route done.
cat > "$WORK/badchoice.json" <<'JSON'
{"schema":"zigapagos.rails-decisions/1","decisions":[
  {"id":"RAILS_TEMPLATE_ENGINE_UNSUPPORTED.app/views/posts/legacy%2Ehtml%2Ehaml.engine","choice":"migrated","rationale":"wishful"}
]}
JSON
set +e
badchoice_out="$("$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/bad1" --decisions "$WORK/badchoice.json" 2>&1)"
badchoice_rc=$?
set -e
[[ $badchoice_rc -eq 1 ]] || fail "an unofferable choice must exit 1, got $badchoice_rc"
grep -q 'choice "migrated" is not offered' <<<"$badchoice_out" || fail "the error must name the rejected choice: $badchoice_out"
grep -q 'allowed: retain, blocked' <<<"$badchoice_out" || fail "the error must name the allowed choices: $badchoice_out"

# An id that answers no finding in THIS run is not fatal, and is not silent:
# it becomes a RAILS_DECISION_STALE blocker naming the id. Unknown and stale
# are ONE case on purpose -- nothing can tell a typo from an answer whose
# finding was fixed since, and refusing to run would strand an operator whose
# only sin is a tidied-up template.
cat > "$WORK/stale.json" <<'JSON'
{"schema":"zigapagos.rails-decisions/1","decisions":[
  {"id":"RAILS_HELPER_UNKNOWN.app/views/pages/ghost%2Ehtml%2Eerb.L9C1","choice":"blocked","rationale":"answers nothing"}
]}
JSON
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/stale-out" --decisions "$WORK/stale.json" >/dev/null 2>&1
stale_rc=$?
set -e
[[ $stale_rc -eq 3 ]] || fail "a stale decision must not change the exit code (still 3 here), got $stale_rc"
stale_msg=$(jq -r '.blockers[] | select(.code == "RAILS_DECISION_STALE") | .message' "$WORK/stale-out/MIGRATION.manifest.json")
grep -q 'RAILS_HELPER_UNKNOWN.app/views/pages/ghost%2Ehtml%2Eerb.L9C1' <<<"$stale_msg" \
  || fail "the stale blocker must name the id: $stale_msg"
stale_path=$(jq -r '.blockers[] | select(.code == "RAILS_DECISION_STALE") | .source.file' "$WORK/stale-out/MIGRATION.manifest.json")
[[ "$stale_path" == "stale.json" ]] || fail "the stale blocker's path must be a basename, never an absolute path: $stale_path"
# ...and a RELATIVE `--decisions` path is reduced the same way. It encodes
# where the operator happened to stand just as an absolute one does, so two
# runs of the same migration from different directories would otherwise differ
# in the manifest -- and the manifest is byte-compared for determinism.
mkdir -p "$WORK/sub"
cp "$WORK/stale.json" "$WORK/sub/stale.json"
set +e
( cd "$WORK" && "$ZIGAPAGOS" migrate app --from rails --target stale-rel --decisions sub/stale.json >/dev/null 2>&1 )
stale_rel_rc=$?
set -e
[[ $stale_rel_rc -eq 3 ]] || fail "the relative-path stale run should still exit 3, got $stale_rel_rc"
stale_rel_path=$(jq -r '.blockers[] | select(.code == "RAILS_DECISION_STALE") | .source.file' "$WORK/stale-rel/MIGRATION.manifest.json")
[[ "$stale_rel_path" == "stale.json" ]] || fail "a relative --decisions path must be reduced to its basename too, got: $stale_rel_path"

# --- what a --target directory may already contain -------------------------
# Ruling S3: the decide -> re-run loop needs the answers file to survive a
# re-run, and everything else must be gone -- so the operator wipes the
# previous output and keeps one file. This is the loop's real shape: the
# decisions file lives IN the target and is passed from there.
mkdir -p "$WORK/loop"
cp "$DECISIONS" "$WORK/loop/MIGRATION.decisions.json"
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/loop" \
  --decisions "$WORK/loop/MIGRATION.decisions.json" --runtime-path "$REPO/runtime" >/dev/null
loop_rc=$?
set -e
[[ $loop_rc -eq 0 ]] || fail "a target holding only MIGRATION.decisions.json must be accepted, got $loop_rc"
[[ -f "$WORK/loop/MIGRATION.decisions.json" ]] || fail "the answers file must survive the run"
[[ "$(jq -r '.complete' "$WORK/loop/MIGRATION.handoff.json")" == "true" ]] || fail "the in-place loop must complete"

mkdir -p "$WORK/dirty"
printf 'notes\n' > "$WORK/dirty/README.md"
set +e
dirty_out="$("$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/dirty" 2>&1)"
dirty_rc=$?
set -e
[[ $dirty_rc -eq 1 ]] || fail "a target holding anything else must be rejected, got $dirty_rc"
grep -q 'already exists and is non-empty' <<<"$dirty_out" || fail "the rejection must say why: $dirty_out"

# --- R15: a view the templates op refuses (RAILS_TEMPLATE_UNSCANNED) --------
# `fragments.Template.unreadable` is what the sidecar answers for a view it
# could not read or that resolves outside the app root. Reaching it takes a
# file that the inventory walk lists, the transitive scan reads, and the
# sidecar then refuses -- i.e. a file REPLACED mid-run, which is exactly the
# race the code has to survive. Staged deterministically here: a `ruby`
# wrapper swaps the view for a symlink pointing out of the app tree, and the
# first Ruby spawn of a run is the routes op, which lands after the inventory
# walk (real file -> an inventory entry) and before the transitive scan (which
# follows the symlink and reads it happily, so no RAILS_TEMPLATE_UNREADABLE).
# The templates op then resolves the same path with `File.realpath`, lands
# outside the root, and answers `unreadable`.
#
# In its OWN copy of the app, and its own run: the swap leaves a symlink where
# a file was, which the primary run's source-tree-unmodified check would (and
# should) catch.
cp -R "$REPO/tests/migrate/rails-presentation" "$WORK/app3"
mkdir -p "$WORK/outside"
cp "$WORK/app3/app/views/pages/linked.html.erb" "$WORK/outside/linked.html.erb"
cat > "$WORK/ruby-wrapper.sh" <<WRAPPER
#!/usr/bin/env bash
ln -sfn "$WORK/outside/linked.html.erb" "$WORK/app3/app/views/pages/linked.html.erb"
exec ruby "\$@"
WRAPPER
chmod +x "$WORK/ruby-wrapper.sh"
# Exit 3, like every undecided run: this app's open routes are not the point
# here, the finding is.
set +e
ZIGAPAGOS_RUBY="$WORK/ruby-wrapper.sh" "$ZIGAPAGOS" migrate "$WORK/app3" --from rails --target "$WORK/out3" >/dev/null
rc3=$?
set -e
[[ $rc3 -eq 3 ]] || fail "third run should exit 3, got $rc3"
M3="$WORK/out3/MIGRATION.manifest.json"
[[ -L "$WORK/app3/app/views/pages/linked.html.erb" ]] || fail "the wrapper never swapped the view; the staging is vacuous"
jq -e --arg id 'RAILS_TEMPLATE_UNSCANNED.app/views/pages/linked%2Ehtml%2Eerb.unscanned' \
  '.findings[] | select(.id == $id)' "$M3" >/dev/null || fail "missing RAILS_TEMPLATE_UNSCANNED finding"
# `loc` is the word `unscanned`, not an `L<line>`: the file was never parsed,
# and a stand-in line would point someone at source nothing ever read.
unscanned_line=$(jq -r '.findings[] | select(.code == "RAILS_TEMPLATE_UNSCANNED") | .source.line' "$M3")
[[ "$unscanned_line" == "null" ]] || fail "UNSCANNED must carry no line, got $unscanned_line"
jq -r '.findings[] | select(.code == "RAILS_TEMPLATE_UNSCANNED") | .message' "$M3" | grep -q 'outside root' \
  || fail "UNSCANNED must carry the sidecar's own reason"
# The whole point of the code: nothing ELSE says anything about this file. No
# nodes, no parse error, and no blocker -- the scan read it fine.
[[ -z "$(jq -r '.blockers[] | select(.source.file == "app/views/pages/linked.html.erb") | .code' "$M3")" ]] \
  || fail "a blocker already covers linked.html.erb; UNSCANNED would be a duplicate"
# ...and the route that renders it is `open` on exactly that finding, which is
# how an operator gets to answer it at all.
jq -e '.routes[] | select(.route_id == "GET /linked") | select(.status == "open")' \
  "$WORK/out3/MIGRATION.handoff.json" >/dev/null || fail "the refused view's route must be open"

# --- R16: a locale file that will not load (RAILS_I18N_LOCALE_UNREADABLE) ---
# `RailsI18n.load` SKIPS a `config/locales/*` file it cannot parse and carries
# on, so a broken en.yml leaves an EMPTY translation table and every `t()` key
# in the app comes back missing. Without the blocker the manifest reports N
# confident RAILS_I18N_UNRESOLVED findings and no cause at all. Again its own
# copy and its own run, so the primary run's determinism is untouched.
cp -R "$REPO/tests/migrate/rails-presentation" "$WORK/app4"
printf 'en:\n\tbroken: [unclosed\n' > "$WORK/app4/config/locales/en.yml"
set +e
"$ZIGAPAGOS" migrate "$WORK/app4" --from rails --target "$WORK/out4" >/dev/null
rc4=$?
set -e
[[ $rc4 -eq 3 ]] || fail "fourth run should exit 3, got $rc4"
M4="$WORK/out4/MIGRATION.manifest.json"
locale_blocker=$(jq -r '.blockers[] | select(.code == "RAILS_I18N_LOCALE_UNREADABLE") | .source.file' "$M4")
[[ "$locale_blocker" == "config/locales/en.yml" ]] || fail "no RAILS_I18N_LOCALE_UNREADABLE for the broken locale, got: $locale_blocker"
jq -e '.blockers[] | select(.code == "RAILS_I18N_LOCALE_UNREADABLE") | select(.integrity == false and .severity == "warn")' "$M4" >/dev/null \
  || fail "the locale blocker must be warn/non-integrity: the inventory and route graph are unaffected"
jq -r '.blockers[] | select(.code == "RAILS_I18N_LOCALE_UNREADABLE") | .message' "$M4" | grep -q 'Psych::SyntaxError' \
  || fail "the locale blocker must carry the sidecar's own reason"
# ...and every key the empty table now reports as missing says WHY, so the
# operator is not sent hunting for translations that were never loaded.
unresolved=$(jq -r '[.findings[] | select(.code == "RAILS_I18N_UNRESOLVED")] | length' "$M4")
[[ "$unresolved" -gt 0 ]] || fail "a broken locale must still raise I18N_UNRESOLVED findings; the check below would be vacuous"
unqualified=$(jq -r '.findings[] | select(.code == "RAILS_I18N_UNRESOLVED") | select(.message | contains("a locale file failed to load: config/locales/en.yml") | not) | .id' "$M4")
[[ -z "$unqualified" ]] || fail "I18N_UNRESOLVED messages missing the locale caveat: $unqualified"
# The mirror image, in the PRIMARY run: with every locale file loading, the
# message says nothing about locale files and no blocker is raised.
# (`if`, not `cmd && fail`: under `set -e` a bare failing left-hand side is
# exempt only by a rule worth not relying on in a gate.)
if jq -e '.blockers[] | select(.code == "RAILS_I18N_LOCALE_UNREADABLE")' "$MANIFEST" >/dev/null; then
  fail "a healthy app must raise no RAILS_I18N_LOCALE_UNREADABLE"
fi
if jq -r '.findings[] | select(.code == "RAILS_I18N_UNRESOLVED") | .message' "$MANIFEST" | grep -q 'failed to load'; then
  fail "a healthy app's I18N_UNRESOLVED message must carry no locale caveat"
fi
# --- the source tree, once more, at the very end ---------------------------
# Re-checked after every run above, not just run 1: the runs that carry
# `--decisions` read a file that lives INSIDE the fixture app, and the
# decide-and-re-run loop's whole premise is that the Rails app is read-only.
# `$WORK/app` is this test's own copy, so a regression that wrote back into
# the source would land here and nowhere else.
final="$(cd "$WORK/app" && find . -type f | sort | xargs shasum)"
[[ "$before" == "$final" ]] || fail "source tree modified by a later run (the --decisions runs are read-only too)"

echo "PASS: tests/migrate/rails-presentation.sh"
