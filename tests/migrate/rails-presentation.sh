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
# Stage 3: the backend boundary. `--backend backend/openapi.json` (a REAL
# `zigbase openapi` document -- see that directory's README) is what turns a
# Rails mutation into a binding: the auth journey becomes an AuthForm/
# AuthStatus pair against the `users` collection, `GET /feed` becomes
# `listPosts`, and `complete` is only reachable BECAUSE those answers exist.
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
# The document lives INSIDE the fixture app so the e2e migrates the same tree
# a developer would: `--backend` names a file, and naming one under the app is
# what a real operator does with the artifact their backend emitted.
BACKEND="$WORK/app/backend/openapi.json"
[[ -f "$BACKEND" ]] || fail "the fixture's backend document is missing"

# --- run 1: no decisions ----------------------------------------------------
# Exit 3 BY VALUE, not merely non-zero: 3 means "the conversion ran and some
# route is still unanswered", 1 means "discovery is broken or --strict".
# `|| fail` would have accepted either, and the two send an operator (or a CI
# loop) to completely different work.
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out1" --backend "$BACKEND"
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
# #176, from the naming side. `resource :session` routes to the PLURAL
# SessionsController while every helper name stays SINGULAR -- a fix that
# pluralized the stem too would break every `session_path` in the app it was
# supposed to make work.
[[ "$(name_of DELETE /session)" == "session" ]] || fail "the sign-out route's name must stay singular: $(name_of DELETE /session)"
# ...and the controller really is the plural, with no `controller:` override
# anywhere in this fixture's config/routes.rb. Before #176 this said
# "session", the fixture carried the override, and the auth journey (which is
# detected by the `sessions`/`registrations` controller names) could not be
# found in any real app.
sess_ctrl=$(jq -r '.routes[] | select(.verb == "DELETE" and .path == "/session") | .controller' "$MANIFEST")
[[ "$sess_ctrl" == "sessions" ]] || fail "#176: a singular resource routes to the PLURAL controller, got '$sess_ctrl'"
reg_ctrl=$(jq -r '.routes[] | select(.verb == "POST" and .path == "/registration") | .controller' "$MANIFEST")
[[ "$reg_ctrl" == "registrations" ]] || fail "#176: registration controller should be 'registrations', got '$reg_ctrl'"
# ...on a fixture that carries no override to lean on. Comment lines are
# excluded because routes.rb explains the rule in prose right above it.
if grep -v '^[[:space:]]*#' "$WORK/app/config/routes.rb" | grep -q 'controller:'; then
  fail "the fixture must carry no controller: override; without one it exercises the real #176 rule"
fi

# --- layouts ---------------------------------------------------------------
about_layout=$(jq -r '.routes[] | select(.path == "/about") | .layout' "$MANIFEST")
[[ "$about_layout" == "app/views/layouts/marketing.html.erb" ]] || fail "declared layout not honoured: $about_layout"
posts_layout=$(jq -r '.routes[] | select(.path == "/posts" and .verb == "GET") | .layout' "$MANIFEST")
[[ "$posts_layout" == "app/views/layouts/application.html.erb" ]] || fail "dynamic layout must fall back to convention: $posts_layout"

# --- findings: exact id set ------------------------------------------------
# Every finding this stage can emit appears at least once, with the exact
# id that a decision file will reference. An id is (code, path, location) --
# assert the WHOLE thing so a shifted line is caught.
#
# ON RE-PINNING THESE. A finding id carries the LINE and COLUMN the construct
# sits at, so every fixture edit moves every id after it. Re-derive from run 1
# (`jq -r '.findings[].id' MIGRATION.manifest.json`) after ANY fixture edit and
# re-pin both here and in MIGRATION.decisions.json; a stale answer surfaces as
# a RAILS_DECISION_STALE blocker and a run that will not complete, not as
# anything obviously wrong.
have_finding() { jq -e --arg id "$1" '.findings[] | select(.id == $id)' "$MANIFEST" >/dev/null || fail "missing finding $1"; }
have_finding 'RAILS_HELPER_UNKNOWN.app/views/pages/help%2Ehtml%2Eerb.L1C18'
have_finding 'RAILS_RAW_OUTPUT.app/views/pages/help%2Ehtml%2Eerb.L1C47'
have_finding 'RAILS_I18N_UNRESOLVED.app/views/pages/help%2Ehtml%2Eerb.L1C62'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L1C33'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/posts/show%2Ehtml%2Eerb.L1C9'
have_finding 'RAILS_BACKEND_ENDPOINT.app/views/posts/new%2Ehtml%2Eerb.L3C5'
have_finding 'RAILS_ROUTE_HELPER_DYNAMIC.app/views/posts/_post%2Ehtml%2Eerb.L1C14'
# L3, not L2: #167 Stage 3 put `before_action :require_login` on line 2 of
# posts_controller.rb and pushed `layout :choose` down one.
have_finding 'RAILS_LAYOUT_DYNAMIC.app/controllers/posts_controller%2Erb.L3'
have_finding 'RAILS_PARTIAL_DYNAMIC.app/views/posts/index%2Ehtml%2Eerb.L1C61'
have_finding 'RAILS_TEMPLATE_CONTROL_FLOW.app/views/posts/_post%2Ehtml%2Eerb.L8C4'
have_finding 'RAILS_TEMPLATE_PARSE_ERROR.app/views/pages/broken%2Ehtml%2Eerb.L2'
have_finding 'RAILS_ROUTE_HELPER_UNKNOWN.app/views/pages/links%2Ehtml%2Eerb.L1C5'
have_finding 'RAILS_STIMULUS_CONTROLLER.app/views/pages/widgets%2Ehtml%2Eerb.L2C1'
have_finding 'RAILS_TURBO_FRAME.app/views/pages/widgets%2Ehtml%2Eerb.L6C5'
have_finding 'RAILS_TURBO_FRAME.app/views/pages/widgets%2Ehtml%2Eerb.L7C5'
have_finding 'RAILS_COMPONENT_ROOT.app/views/pages/widgets%2Ehtml%2Eerb.L8C5'
have_finding 'RAILS_TURBO_STREAM.app/views/pages/live%2Ehtml%2Eerb.L1C5'
have_finding 'RAILS_COMPONENT_VUE_UNSUPPORTED.app/views/pages/live%2Ehtml%2Eerb.L1C33'
have_finding 'RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry'
finding_field() { jq -r --arg id "$1" --arg field "$2" '.findings[] | select(.id == $id) | if $field == "choices" then (.choices | join(",")) elif $field == "line" then (.source.line | tostring) else .[$field] end' "$MANIFEST"; }
[[ "$(finding_field 'RAILS_STIMULUS_CONTROLLER.app/views/pages/widgets%2Ehtml%2Eerb.L2C1' choices)" == 'island,drop,retain,blocked' ]] || fail "stimulus choices changed"
[[ "$(finding_field 'RAILS_STIMULUS_CONTROLLER.app/views/pages/widgets%2Ehtml%2Eerb.L2C1' message)" == 'stimulus `reveal` on <div>; actions: click->reveal#toggle; targets: details; source app/javascript/controllers/reveal_controller.js' ]] || fail "stimulus message changed"
[[ "$(finding_field 'RAILS_TURBO_FRAME.app/views/pages/widgets%2Ehtml%2Eerb.L6C5' choices)" == 'island,retain,blocked' ]] || fail "dynamic frame choices changed"
[[ "$(finding_field 'RAILS_TURBO_FRAME.app/views/pages/widgets%2Ehtml%2Eerb.L6C5' message)" == 'turbo-frame `latest` src=/posts' ]] || fail "dynamic frame message changed"
[[ "$(finding_field 'RAILS_TURBO_FRAME.app/views/pages/widgets%2Ehtml%2Eerb.L7C5' choices)" == 'inline,retain,blocked' ]] || fail "static frame choices changed"
[[ "$(finding_field 'RAILS_TURBO_FRAME.app/views/pages/widgets%2Ehtml%2Eerb.L7C5' message)" == 'turbo-frame `static` (no src)' ]] || fail "static frame message changed"
[[ "$(finding_field 'RAILS_COMPONENT_ROOT.app/views/pages/widgets%2Ehtml%2Eerb.L8C5' choices)" == 'island,retain,blocked' ]] || fail "React root choices changed"
[[ "$(finding_field 'RAILS_COMPONENT_ROOT.app/views/pages/widgets%2Ehtml%2Eerb.L8C5' message)" == 'React root `Chart` props {points, series}; source app/javascript/components/Chart.jsx' ]] || fail "React root message changed"
stream_msg="$(finding_field 'RAILS_TURBO_STREAM.app/views/pages/live%2Ehtml%2Eerb.L1C5' message)"
[[ "$stream_msg" == 'turbo-stream `posts`: a realtime subscription has no converter (see #'*')' ]] || fail "Turbo stream message must name posts and its follow-up issue: $stream_msg"
[[ "$(finding_field 'RAILS_COMPONENT_VUE_UNSUPPORTED.app/views/pages/live%2Ehtml%2Eerb.L1C33' choices)" == 'retain,blocked' ]] || fail "Vue choices changed"
jq -e '.blockers[] | select(.code == "RAILS_COMPONENT_VUE_UNSUPPORTED" and .severity == "warn" and .integrity == false)' "$MANIFEST" >/dev/null || fail "Vue finding must also carry the non-integrity warning blocker"
[[ "$(finding_field 'RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry' choices)" == 'drop,blocked' ]] || fail "JS entry choices changed"
[[ "$(finding_field 'RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry' line)" == 'null' ]] || fail "JS entry must not claim a source line"
index_state_msg="$(finding_field 'RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L1C33' message)"
[[ "$index_state_msg" == *'; collection posts (in --backend)' ]] || fail "portable index state must name the backend collection: $index_state_msg"
# #167 Stage 2 ruling S12 gave each of this fixture's two forms its own
# `RAILS_BACKEND_ENDPOINT`. #167 Stage 3 assumption A5 replaces BOTH with the
# one journey finding below: they are the sign-in and sign-up halves of a
# single authentication flow, and the answer to both is a single ZigBase auth
# collection shared by an `AuthForm` and an `AuthStatus`. Asking each form
# separately would let an operator answer them inconsistently.
#
# Keyed on the SMALLEST routes.rb line the journey occupies (ruling S22):
# `resource :session` at L38, ahead of `resource :registration` at L42.
have_finding 'RAILS_AUTH_JOURNEY.config/routes%2Erb.L38'
journey_msg=$(jq -r '.findings[] | select(.code == "RAILS_AUTH_JOURNEY") | .message' "$MANIFEST")
# The message names every route the journey speaks for -- including the
# sign-out `DELETE /session` #167 Stage 3 added -- and, because this run has a
# document, the auth collection the artifact must name. Without `--backend` it
# says "pass --backend to validate the name" instead (pinned in run 1b).
[[ "$journey_msg" == "auth journey: DELETE /session, GET /session/new, POST /session, GET /registration/new, POST /registration; island needs artifact = the ZigBase auth collection name (in --backend: users)" ]] \
  || fail "auth journey message: $journey_msg"
# It is the only finding in the vocabulary that demands an artifact, and the
# artifact is a fact about the DESTINATION (which ZigBase collection holds the
# users), which no amount of reading the Rails app recovers.
journey_artifact=$(jq -r '.findings[] | select(.code == "RAILS_AUTH_JOURNEY") | .requires_artifact' "$MANIFEST")
[[ "$journey_artifact" == "true" ]] || fail "the auth journey must require an artifact, got $journey_artifact"
journey_choices=$(jq -r '.findings[] | select(.code == "RAILS_AUTH_JOURNEY") | .choices | join(",")' "$MANIFEST")
[[ "$journey_choices" == "island,retain,blocked" ]] || fail "auth journey choices: $journey_choices"
# ONE finding for five routes across two declarations, and exactly one per
# app: a second would mean the journey was split.
journey_count=$(jq '[.findings[] | select(.code == "RAILS_AUTH_JOURNEY")] | length' "$MANIFEST")
[[ "$journey_count" == "1" ]] || fail "the auth journey must be one finding, got $journey_count"
# A5 from the other side: `POST /session`, `DELETE /session` and
# `POST /registration` are API traffic and would each carry a route-level
# `RAILS_BACKEND_ENDPOINT` -- except that the journey is already their
# question. `GET /feed` is NOT part of the journey and does carry one.
route_backend_ids=$(jq -r '[.findings[] | select(.code == "RAILS_BACKEND_ENDPOINT") | select(.source.file == "config/routes.rb") | .id] | join(" ")' "$MANIFEST")
[[ "$route_backend_ids" == "RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L14.POST.posts RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L20.GET.posts" ]] \
  || fail "the posts create and feed route-level backend questions changed: $route_backend_ids"
# Ruling S3-R2: the route-level row is keyed on (line, VERB, resource), not on
# the line alone -- one routes.rb line can declare several verbs, and each verb
# gets different operations offered.
have_finding 'RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L20.GET.posts'
have_finding 'RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L14.POST.posts'
feed_choices=$(jq -r '.findings[] | select(.id == "RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L20.GET.posts") | .choices | join(",")' "$MANIFEST")
# The document's own GET operations, resource-matching group first, each group
# by operation id -- then the two reserved answers. No POST/PATCH/DELETE
# operation may appear: a verb never crosses over.
[[ "$feed_choices" == "listPosts,viewPosts,listUsers,viewUsers,retain,blocked" ]] \
  || fail "the feed route's choices must be the document's GET operations: $feed_choices"
create_choices=$(jq -r '.findings[] | select(.id == "RAILS_BACKEND_ENDPOINT.app/views/posts/new%2Ehtml%2Eerb.L3C5") | .choices | join(",")' "$MANIFEST")
[[ "$create_choices" == "createPosts,createUsers,retain,blocked" ]] \
  || fail "the posts form must offer POST operations with createPosts first: $create_choices"
feed_msg=$(jq -r '.findings[] | select(.id == "RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L20.GET.posts") | .message' "$MANIFEST")
[[ "$feed_msg" == "route is API traffic and needs a backend operation: GET /feed" ]] || fail "feed message: $feed_msg"
# Assumption A7's new code, on the routes.rb line the guarded route was
# declared on (S22). `public` is its new choice word.
have_finding 'RAILS_ROUTE_AUTH_GUARD.config/routes%2Erb.L14'
guard_choices=$(jq -r '.findings[] | select(.code == "RAILS_ROUTE_AUTH_GUARD") | .choices | join(",")' "$MANIFEST")
[[ "$guard_choices" == "public,retain,blocked" ]] || fail "auth guard choices: $guard_choices"
guard_msg=$(jq -r '.findings[] | select(.code == "RAILS_ROUTE_AUTH_GUARD") | .message' "$MANIFEST")
[[ "$guard_msg" == "page is guarded by before_action :require_login on posts; a static page cannot enforce it: GET /posts" ]] \
  || fail "auth guard message: $guard_msg"
# The shared nav, since #167 Stage 3: a complementary `unless current_user` /
# `if current_user` pair (two regions on one predicate) plus the email read
# inside the signed-in half plus the sign-out control's own question.
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L4C6'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L5C6'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L5C28'
have_finding 'RAILS_BACKEND_ENDPOINT.app/views/shared/_nav%2Ehtml%2Eerb.L5C54'
link_msg=$(jq -r '.findings[] | select(.id == "RAILS_BACKEND_ENDPOINT.app/views/shared/_nav%2Ehtml%2Eerb.L5C54") | .message' "$MANIFEST")
[[ "$link_msg" == 'link performs a mutation: button_to `Sign out` method=delete' ]] || fail "sign-out link message: $link_msg"
# A DELETE control is offered the document's DELETE operations and nothing
# else -- there is no `session` collection, so the list is honestly useless
# here, which is exactly why the region's `island` answer is what settles it.
link_choices=$(jq -r '.findings[] | select(.id == "RAILS_BACKEND_ENDPOINT.app/views/shared/_nav%2Ehtml%2Eerb.L5C54") | .choices | join(",")' "$MANIFEST")
[[ "$link_choices" == "deletePosts,deleteUsers,retain,blocked" ]] || fail "sign-out link choices: $link_choices"
# The two `errors` regions in registrations/new (`@user&.errors&.any?` and
# `@user.errors.full_messages`) are a different question from the form's --
# how request-time validation state is PRESENTED -- and get the same code an
# ivar read does.
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/registrations/new%2Ehtml%2Eerb.L1C4'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/registrations/new%2Ehtml%2Eerb.L1C36'
# #167 Stage 2 rulings S1/S12: the two ROUTE-scoped rows, keyed on the
# config/routes.rb line the route was declared on rather than on a template.
have_finding 'RAILS_ROUTE_DYNAMIC_SEGMENT.config/routes%2Erb.L14'
have_finding 'RAILS_REDIRECT_HOST_CONFIG.config/routes%2Erb.L53'
# Zero and two. Assumption A5 moves both forms' question to the ROUTE-scoped
# `RAILS_AUTH_JOURNEY`, so the sign-in view raises nothing at all; the sign-up
# view keeps only its two `errors` regions (#167 Stage 3 dropped the separate
# `<%= @user.email %>` read -- the plain-ivar shape is still covered by
# posts/index and posts/show).
sessions_count=$(jq '[.findings[] | select(.source.file == "app/views/sessions/new.html.erb")] | length' "$MANIFEST")
[[ "$sessions_count" == "0" ]] || fail "sessions/new's only question is the auth journey's, got $sessions_count findings"
registrations_count=$(jq '[.findings[] | select(.source.file == "app/views/registrations/new.html.erb")] | length' "$MANIFEST")
[[ "$registrations_count" == "2" ]] || fail "registrations/new should raise 2 errors findings, got $registrations_count"
nav_count=$(jq '[.findings[] | select(.source.file == "app/views/shared/_nav.html.erb")] | length' "$MANIFEST")
[[ "$nav_count" == "4" ]] || fail "the nav should raise 4 findings (2 halves, 1 email, 1 sign-out), got $nav_count"
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

# Every finding has the wire shape and a non-empty choices list. Stage 3's
# vocabulary is no longer a fixed set -- an operation id is whatever the
# ZigBase document calls an operation -- so the closed-set check now covers
# the WORDS only, and the operation ids are pinned per finding above.
bad=$(jq -r '.findings[] | select((.id|type) != "string" or (.choices|length) == 0) | .id' "$MANIFEST")
[[ -z "$bad" ]] || fail "malformed findings: $bad"
badwords=$(jq -r '.findings[] | select((.choices - ["island","spa","backend","public","drop","inline","retain","blocked","listPosts","viewPosts","listUsers","viewUsers","createPosts","createUsers","deletePosts","deleteUsers"] | length) != 0) | .id' "$MANIFEST")
[[ -z "$badwords" ]] || fail "findings offering a choice outside the vocabulary + this document's ids: $badwords"

# Schema validation of both real instances. `rails_manifest_validate` takes
# any schema + any instance, so the handoff is validated by the same tool.
[[ -x "$REPO/zig-out/bin/rails_manifest_validate" ]] || zig build rails-manifest-validate || fail "validator build"
"$REPO/zig-out/bin/rails_manifest_validate" "$REPO/contract/rails-presentation.v1.schema.json" "$MANIFEST" || fail "manifest fails schema"
"$REPO/zig-out/bin/rails_manifest_validate" "$REPO/contract/rails-handoff.v1.schema.json" "$HANDOFF" || fail "handoff fails schema"

grep -q '^## Findings' "$WORK/out1/MIGRATION.md" || fail "MIGRATION.md lacks a Findings section"
grep -q '^## Handoff' "$WORK/out1/MIGRATION.md" || fail "MIGRATION.md lacks a Handoff section"
# #167 Stage 3: the report names the document and counts the bindings. Both
# lines are unconditional -- an operator whose backend choices were all
# `retain, blocked` is precisely the operator who forgot the flag.
grep -qx 'backend: openapi.json (1.0.0)' "$WORK/out1/MIGRATION.md" \
  || fail "the Handoff section must name the backend document by basename and version"
grep -q "$WORK" "$WORK/out1/MIGRATION.md" && fail "MIGRATION.md embeds the scratch path"
grep -qx 'endpoints: 0 of the 5 `backend` route(s) are bound to a ZigBase operation.' "$WORK/out1/MIGRATION.md" \
  || fail "run 1 binds nothing, and the report must say so"

# --- run 1: the handoff's verdict, route by route --------------------------
# The whole point of the artifact: which routes are DONE, which are waiting on
# a human, and which need neither. Pinned per route rather than by counts, so
# a status that moves from `migrated` to `open` (or the reverse) names itself.
[[ "$(jq -r '.complete' "$HANDOFF")" == "false" ]] || fail "run 1 must not be complete"
route_count=$(jq '.routes | length' "$HANDOFF")
[[ "$route_count" == "20" ]] || fail "expected 20 routes in the handoff, got $route_count -- a new route needs a pin below"
status_of() { jq -r --arg r "$1" '.routes[] | select(.route_id == $r) | .status' "$HANDOFF"; }
want_status() {
  local got; got="$(status_of "$1")"
  [[ "$got" == "$2" ]] || fail "run 1: $1 should be $2, got '$got'"
}
# EVERY page route is `open` in run 1, and that is #167 Stage 3's doing: the
# shared `_nav` partial now reads `current_user`, and a layout's findings ride
# on every route under it (ruling S21). `GET /`, `GET /about` and `GET /linked`
# were `migrated` here in Stage 2 and regain it in run 2, once the nav's
# regions are answered.
want_status 'GET /'                  open
want_status 'GET /about'             open
want_status 'GET /linked'            open
want_status 'GET /help'              open
want_status 'GET /broken'            open
want_status 'GET /links'             open
want_status 'GET /posts'             open
want_status 'GET /posts/new'         open
want_status 'GET /posts/:id'         open
want_status 'GET /posts/legacy'      open
want_status 'GET /session/new'       open
want_status 'GET /registration/new'  open
want_status 'GET /widgets'           open
want_status 'GET /live'              open
# No page, no decision, no question: a pure `redirect_to` action is answered
# by the host config.
want_status 'GET /old'               redirect
# Non-GET traffic, plus the one GET that renders JSON instead of a view.
want_status 'POST /session'          backend
want_status 'DELETE /session'        backend
want_status 'POST /registration'     backend
want_status 'GET /feed'              backend
want_status 'POST /posts'            backend
# Nothing is bound yet: `--backend` alone widens the questions, it answers
# none of them.
unbound=$(jq -r '[.routes[] | select(.endpoint != null) | .route_id] | join(" ")' "$HANDOFF")
[[ -z "$unbound" ]] || fail "run 1 answers nothing, so no route may carry an endpoint: $unbound"
# ...and the document itself is recorded by BASENAME. An absolute path in a
# committed artifact would make the handoff non-reproducible.
[[ "$(jq -r '.backend.file' "$HANDOFF")" == "openapi.json" ]] || fail "the handoff must name the backend document by basename"
[[ "$(jq -r '.backend.contract_version' "$HANDOFF")" == "1.0.0" ]] || fail "backend contract_version: $(jq -r '.backend.contract_version' "$HANDOFF")"
grep -q "$WORK" "$HANDOFF" && fail "the handoff embeds the scratch path"
# The redirect is reported WITH its target since #167 Stage 3's redirect
# recovery: `pages#old` calls `redirect_to about_path`, and the host config
# needs the destination, not just the fact.
[[ "$(jq -r '.redirects | length' "$HANDOFF")" == "1" ]] || fail "expected exactly one redirect"
[[ "$(jq -r '.redirects[0].from' "$HANDOFF")" == "/old" ]] || fail "the redirect should be /old"
[[ "$(jq -r '.redirects[0].to' "$HANDOFF")" == "/about" ]] || fail "the redirect target should be /about"

# An UNANSWERED mutating link keeps its page open. `GET /` renders the shared
# nav, whose `button_to ..., method: :delete` raised a RAILS_BACKEND_ENDPOINT
# nobody has answered -- so the route is `open` ON THAT ID, and the converted
# layout carries an empty finding region instead of an `<a href="/session">`
# that would GET the route the control was supposed to DELETE.
root_ids=$(jq -r '.routes[] | select(.route_id == "GET /") | .findings | join(" ")' "$HANDOFF")
[[ "$root_ids" == "RAILS_BACKEND_ENDPOINT.app/views/shared/_nav%2Ehtml%2Eerb.L5C54 RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L4C6 RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L5C28 RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L5C6" ]] \
  || fail "GET / must be open on all four nav findings plus the global JS entry, got: $root_ids"
run1_nav="$WORK/out1/layouts/templates/marketing.shtml"
grep -q 'href="/session">' "$run1_nav" && fail "an unanswered mutating link must not become a GET link to the DELETE route"
grep -q 'method="delete"' "$run1_nav" && fail 'a method= attribute on an <a> does nothing in a static site'

# --- run 1: the converted tree ---------------------------------------------
listing="$(cd "$WORK/out1" && find . -type f | sort | tr '\n' ' ')"
expected_listing="./.gitignore ./AGENTS.md ./CLAUDE.md ./MIGRATION.handoff.json ./MIGRATION.manifest.json ./MIGRATION.md ./assets/images/logo.png ./assets/robots.txt ./assets/stylesheets/application.css ./build.sh ./content/about/index.smd ./content/help/index.smd ./content/index.smd ./content/linked/index.smd ./content/links/index.smd ./content/live/index.smd ./content/posts/index.smd ./content/posts/new/index.smd ./content/registration/new/index.smd ./content/session/new/index.smd ./content/widgets/index.smd ./layouts/pages/about.shtml ./layouts/pages/help.shtml ./layouts/pages/linked.shtml ./layouts/pages/links.shtml ./layouts/pages/live.shtml ./layouts/pages/widgets.shtml ./layouts/posts/index.shtml ./layouts/posts/new.shtml ./layouts/registrations/new.shtml ./layouts/sessions/new.shtml ./layouts/templates/application.shtml ./layouts/templates/marketing.shtml ./test/journey_playwright.py ./test/parity.ts ./zigapagos.ziggy "
[[ "$listing" == "$expected_listing" ]] || fail "run 1 target listing changed:
  got:      $listing
  expected: $expected_listing"
# An `open` route still gets its page -- open means nobody has decided, not
# that nothing was produced -- so there are more content pages than migrated
# routes. The two routes with NO page are the ones whose view could not be
# converted at all (broken.html.erb, legacy.html.haml).
[[ ! -e "$WORK/out1/content/broken" ]] || fail "an unconvertible view must not leave a page behind"
[[ ! -e "$WORK/out1/content/posts/legacy" ]] || fail "the Haml route must not leave a page behind"
# Nothing is BOUND in run 1, so nothing that only a binding produces exists:
# no client library, no island, no package.json. This listing is the only
# assertion that catches a scaffolder writing lib/zb.ts unconditionally.
[[ ! -e "$WORK/out1/lib" ]] || fail "run 1 binds nothing, so there is no client library to write"
[[ ! -e "$WORK/out1/components" ]] || fail "run 1 binds nothing, so there is no island to write"
[[ ! -e "$WORK/out1/package.json" ]] || fail "run 1 needs no npm dependencies"
registration_open="$WORK/out1/layouts/registrations/new.shtml"
grep -q 'rails:finding' "$registration_open" || fail "the unanswered errors region must remain an answerable finding"
grep -q 'rails:unmapped local' "$registration_open" \
  && fail "a block local owned by an answerable errors region must not add an id-less marker"
widgets_open="$WORK/out1/layouts/pages/widgets.shtml"
grep -qF '<!-- rails:finding RAILS_STIMULUS_CONTROLLER.app/views/pages/widgets%2Ehtml%2Eerb.L2C1 --><div data-controller="reveal"' "$widgets_open" || fail "the unanswered Stimulus marker must precede its controller element"
grep -q 'data-turbo-action' "$widgets_open" && fail "Turbo Drive attributes are dropped during conversion"
# Ruling S17: public/assets/** is the pipeline's compiled OUTPUT. The sources
# are copied from app/assets/ (see assets/images/logo.png), so copying it too
# would ship every asset twice plus a Rails bookkeeping file.
[[ -f "$WORK/out1/assets/images/logo.png" ]] || fail "app/assets image not copied"
[[ -f "$WORK/out1/assets/robots.txt" ]] || fail "public/robots.txt not copied"
[[ ! -e "$WORK/out1/assets/assets" ]] || fail "public/assets/** must not be copied as site assets (ruling S17)"
# The backend document is an input, not an asset: it must not be copied into
# the site tree by the inventory walk.
[[ ! -e "$WORK/out1/assets/openapi.json" ]] || fail "the --backend document is an input, not a site asset"
[[ ! -e "$WORK/out1/backend" ]] || fail "the --backend document is an input, not a site asset"
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

# --- run 1b: the same app with NO --backend --------------------------------
# The flag is what makes an operation answerable at all. Without it the two
# backend questions are still ASKED -- the operator has to acknowledge them
# somehow -- but the only answers on offer are the two that ship nothing, and
# the journey message says how to get the third.
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out1b" >/dev/null
run1b_rc=$?
set -e
[[ $run1b_rc -eq 3 ]] || fail "run 1b should still exit 3, got $run1b_rc"
M1B="$WORK/out1b/MIGRATION.manifest.json"
feed_choices_nb=$(jq -r '.findings[] | select(.id == "RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L20.GET.posts") | .choices | join(",")' "$M1B")
[[ "$feed_choices_nb" == "retain,blocked" ]] || fail "without a document there is no operation to offer: $feed_choices_nb"
journey_msg_nb=$(jq -r '.findings[] | select(.code == "RAILS_AUTH_JOURNEY") | .message' "$M1B")
[[ "$journey_msg_nb" == *"(pass --backend to validate the name)" ]] \
  || fail "the journey message must say how to get the collection validated: $journey_msg_nb"
[[ "$(jq -r '.backend' "$WORK/out1b/MIGRATION.handoff.json")" == "null" ]] || fail "no document, no backend object"
grep -qx 'backend: none' "$WORK/out1b/MIGRATION.md" || fail "the report must say `backend: none` rather than omitting the line"
index_state_nb=$(jq -r '.findings[] | select(.id == "RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L1C33") | .message' "$M1B")
[[ "$index_state_nb" == 'request-time state `@posts`' ]] || fail "without --backend the ivar must carry no collection hint: $index_state_nb"
for id in \
  'RAILS_STIMULUS_CONTROLLER.app/views/pages/widgets%2Ehtml%2Eerb.L2C1' \
  'RAILS_TURBO_FRAME.app/views/pages/widgets%2Ehtml%2Eerb.L6C5' \
  'RAILS_TURBO_FRAME.app/views/pages/widgets%2Ehtml%2Eerb.L7C5' \
  'RAILS_COMPONENT_ROOT.app/views/pages/widgets%2Ehtml%2Eerb.L8C5'; do
  with_backend=$(jq -r --arg id "$id" '.findings[] | select(.id == $id) | .choices | join(",")' "$MANIFEST")
  without_backend=$(jq -r --arg id "$id" '.findings[] | select(.id == $id) | .choices | join(",")' "$M1B")
  [[ "$with_backend" == "$without_backend" ]] || fail "$id must not depend on --backend: $with_backend != $without_backend"
done

# --- run 2: the operator's answers -----------------------------------------
# The checked-in decisions file answers every finding that keeps a route open.
# `--runtime-path` points the generated package.json at this checkout's
# runtime/ so the generated `@z/runtime` dependency resolves without a
# published npm package -- the same thing site/build.sh does via
# ZIGAPAGOS_RUNTIME_DIR (run 2c below covers the variable).
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out2" \
  --decisions "$DECISIONS" --backend "$BACKEND" --runtime-path "$REPO/runtime"
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
want2 'GET /live'             blocked
want2 'GET /posts'            migrated
want2 'GET /posts/new'        migrated
want2 'GET /posts/:id'        migrated
want2 'GET /widgets'          migrated
# The three routes the shared nav kept open in run 1, back to `migrated` now
# that its regions are answered -- ruling S21 running in the other direction.
want2 'GET /'                 migrated
want2 'GET /about'            migrated
want2 'GET /linked'           migrated
# The journey's two page routes. In Stage 2 these were `retained`; the
# `island` answer is what moves them, and it is the reason `content/session/
# new/index.smd` is back in the listing below.
want2 'GET /session/new'      migrated
want2 'GET /registration/new' migrated
# A decision on a redirect is RECORDED but never changes the status: the host
# config answered it before anyone was asked.
want2 'GET /old'              redirect
[[ "$(jq -r '.routes[] | select(.route_id == "GET /old") | .decision.choice' "$HANDOFF2")" == "retain" ]] \
  || fail "the redirect's decision should still be recorded"

# --- run 2: the bindings ----------------------------------------------------
# The stage's whole claim, route by route. Two of the three journey endpoints
# are CollectionService METHOD names rather than operation ids, because
# `x-zigbase-coverage.allAuthMethods` is always false -- auth-with-password
# and auth-logout are not in any ZigBase OpenAPI document. `createUsers` is
# re-derived by the same rule that names them, not looked up, so a trio where
# one member came from the document and two were synthesized cannot disagree.
endpoint_of() { jq -r --arg r "$1" '.routes[] | select(.route_id == $r) | .endpoint | "\(.operation_id) \(.verb) \(.path)"' "$HANDOFF2"; }
[[ "$(endpoint_of 'GET /feed')" == "listPosts GET /api/collections/posts/records" ]] \
  || fail "GET /feed endpoint: $(endpoint_of 'GET /feed')"
[[ "$(endpoint_of 'POST /session')" == "authWithPassword POST /api/collections/users/auth-with-password" ]] \
  || fail "POST /session endpoint: $(endpoint_of 'POST /session')"
[[ "$(endpoint_of 'DELETE /session')" == "logout POST /api/collections/users/auth-logout" ]] \
  || fail "DELETE /session endpoint: $(endpoint_of 'DELETE /session')"
[[ "$(endpoint_of 'POST /registration')" == "createUsers POST /api/collections/users/records" ]] \
  || fail "POST /registration endpoint: $(endpoint_of 'POST /registration')"
[[ "$(endpoint_of 'POST /posts')" == "createPosts POST /api/collections/posts/records" ]] \
  || fail "POST /posts endpoint: $(endpoint_of 'POST /posts')"
# ...and only those five. A page route must never claim an endpoint.
bound_routes=$(jq -r '[.routes[] | select(.endpoint != null) | .route_id] | join(",")' "$HANDOFF2")
[[ "$bound_routes" == "GET /feed,POST /posts,POST /registration,DELETE /session,POST /session" ]] \
  || fail "exactly the five backend routes are bound, got: $bound_routes"
grep -qx 'endpoints: 5 of the 5 `backend` route(s) are bound to a ZigBase operation.' "$WORK/out2/MIGRATION.md" \
  || fail "the report's endpoint tally must say every backend route is bound"

# Stage 5's handoff is pinned as exact canonical JSON, not merely by counts.
# Kept as a function so the three semantic mutants below must make the SAME
# production assertion fail rather than a purpose-built mutant assertion.
assert_stage5_parity() {
  local handoff="$1" parity_hash
  parity_hash=$(jq -c '.parity' "$handoff" | shasum -a 256 | awk '{print $1}')
  [[ "$parity_hash" == "933e5d7504085309d299cfa4692411ede19c0a7afba7e659bbeb04b3fcf6e387" ]] || return 1
  jq -e '.parity[] | select(.id == "signup:users" and .expect.status == 201)' "$handoff" >/dev/null || return 1
  jq -e '.parity[] | select(.id == "navigate:GET /about" and (.expect.links | index("/?from=about#top")))' "$handoff" >/dev/null || return 1
  jq -e '[.parity[] | select(.kind == "navigate" and (.expect.links | index("/account")))] | length == 0' "$handoff" >/dev/null || return 1
  jq -e '.parity[] | select(.id == "navigate:GET /posts/new" and .expect.title == "New post" and .expect.h1 == "New post")' "$handoff" >/dev/null || return 1
  jq -e '.parity[] | select(.id == "submit_allowed:createPosts" and .expect.page_url == "/posts/new" and .expect.status_family == 2)' "$handoff" >/dev/null || return 1
  jq -e '.parity[] | select(.id == "submit_denied:createPosts" and (.expect.statuses == [401,403]))' "$handoff" >/dev/null || return 1
  jq -e '.parity[] | select(.id == "validation_error:createPosts:title" and .expect.field == "title" and ([.expect.fields[] | select(.name == "title") | .invalid_value] == [""]))' "$handoff" >/dev/null || return 1
}
assert_stage5_parity "$HANDOFF2" || fail "the exact Stage 5 parity JSON changed"
! grep -R -qF '/account' "$WORK/out2/content" "$WORK/out2/layouts" "$WORK/out2/components" \
  || fail "literal links inside replaced auth regions must reach neither artifacts nor parity"

# The `spa` choice and the `island` answers are the ones that emit code.
[[ -f "$WORK/out2/spa/posts.spa.tsx" ]] || fail "the spa decision must scaffold spa/posts.spa.tsx"
[[ -f "$WORK/out2/tsconfig.json" ]] || fail "a SPA needs a tsconfig.json"
grep -qF 'head: [{ rel: "stylesheet", href: "/stylesheets/application.css" }]' "$WORK/out2/spa/posts.spa.tsx" || fail "the SPA must carry the Rails layout stylesheet in spa.head"
grep -qF 'useParams' "$WORK/out2/spa/posts.spa.tsx" || fail "the ported show view must read its dynamic id"
grep -qF 'getOne(params.id)' "$WORK/out2/spa/posts.spa.tsx" || fail "the ported show view must fetch one record"
# Quoted in build.sh: `--spa=path|base` unquoted is a shell PIPELINE.
grep -qF -- "--spa='spa/posts.spa.tsx|/posts'" "$WORK/out2/build.sh" || fail "build.sh must carry a quoted --spa entry"
# ONE AuthForm file for both halves of the journey (assumption A5: one
# finding, one answer, one component), told apart by a prop.
[[ -f "$WORK/out2/components/AuthForm.island.tsx" ]] || fail "the journey must scaffold components/AuthForm.island.tsx"
[[ -f "$WORK/out2/components/AuthStatus.island.tsx" ]] || fail "the nav's answered region must scaffold components/AuthStatus.island.tsx"
[[ -f "$WORK/out2/lib/zb.ts" ]] || fail "a bound island needs the client library"
grep -qF 'authCollection: "users"' "$WORK/out2/lib/zb.ts" \
  || fail "lib/zb.ts must name the auth collection the journey was answered with"
grep -qF '<island src="components/AuthForm.island.tsx" client:load :props='"'"'{ .mode = "signin" }'"'"'></island>' "$WORK/out2/layouts/sessions/new.shtml" \
  || fail "sessions/new must mount the AuthForm in signin mode"
grep -qF '<island src="components/AuthForm.island.tsx" client:load :props='"'"'{ .mode = "signup" }'"'"'></island>' "$WORK/out2/layouts/registrations/new.shtml" \
  || fail "registrations/new must mount the AuthForm in signup mode"
# Ruling S6 / #181: the `full_messages.each do |m|` block local was the one
# region convert.zig could not map and could not be asked about. The island
# owns the whole errors region now, so it never reaches the converter at all.
grep -q 'rails:unmapped' "$WORK/out2/layouts/registrations/new.shtml" \
  && fail "a bound auth form leaves no unmapped region behind"
# The complementary pair is ONE mount. Two would print the nav's sign-in link
# twice in the built page: AuthStatus renders BOTH branches itself.
# `|| true`: grep -c exits 1 on zero matches, which under `set -e` would kill
# the script at the assignment, before the `fail` that exists to name it.
status_mounts=$(grep -c '<island src="components/AuthStatus.island.tsx"' "$WORK/out2/layouts/templates/marketing.shtml" || true)
[[ "$status_mounts" == "1" ]] || fail "an if/unless pair on one predicate is one AuthStatus mount, got $status_mounts"
# ...and the route says which half was folded into which, so the operator can
# see the two answers became one component.
root_note=$(jq -r '.routes[] | select(.route_id == "GET /") | .note' "$HANDOFF2")
grep -q '`if current_user` folded into the AuthStatus island above it' <<<"$root_note" \
  || fail "the absorbed half must be named in the note: $root_note"
# The sign-out control is inside that region, so the island replaced it: no
# link to the DELETE route survives, and no separate click island was written.
grep -q 'href="/session">' "$WORK/out2/layouts/templates/marketing.shtml" \
  && fail "the AuthStatus island replaces the sign-out control; no link to /session may survive"
[[ -f "$WORK/out2/components/forms/posts_new.island.tsx" ]] || fail "the bound posts form must scaffold exactly one form island"
[[ "$(find "$WORK/out2/components/forms" -type f | wc -l)" -eq 1 ]] || fail "the posts form must be the only standalone form island"
# npm dependencies: the client, pinned, and the runtime at the path we asked
# for. `--runtime-path` SHADOWS ZIGAPAGOS_RUNTIME_DIR; run 2c covers the
# variable on its own.
grep -qF '"@zigbase/client": "0.3.0"' "$WORK/out2/package.json" || fail "package.json must pin @zigbase/client"
grep -qF "\"@z/runtime\": \"file:$REPO/runtime\"" "$WORK/out2/package.json" || fail "--runtime-path must fill the runtime dependency"
# Each island reaches `release` once, quoted, in path order.
for isl in components/AuthForm.island.tsx components/AuthStatus.island.tsx components/Chart.island.tsx components/TurboFrame.island.tsx components/data/posts_index.island.tsx components/forms/posts_new.island.tsx components/stimulus/reveal.island.tsx; do
  n=$(grep -o -- "--island='$isl'" "$WORK/out2/build.sh" | wc -l)
  [[ "$n" -eq 1 ]] || fail "build.sh must carry --island='$isl' exactly once, got $n"
done

widgets2="$WORK/out2/layouts/pages/widgets.shtml"
grep -qF '<island src="components/stimulus/reveal.island.tsx" client:load><div data-controller="reveal"' "$widgets2" || fail "widgets must mount the reveal island around its controller element"
grep -qF '<island src="components/TurboFrame.island.tsx" client:load :props='"'"'{ .id = "latest", .src = "/posts" }'"'"'><p>Loading latest…</p></island>' "$widgets2" || fail "widgets must mount the fetching Turbo frame"
grep -qF '<turbo-frame id="static"><p>Just markup</p></turbo-frame>' "$widgets2" || fail "the source-less Turbo frame must stay inline"
grep -qF '<island src="components/Chart.island.tsx" client:load :props='"'"'{ .points = 3, .series = "a" }'"'"'></island>' "$widgets2" || fail "the React root must mount with sorted literal props"
grep -q 'data-turbo-action' "$widgets2" && fail "Turbo Drive attributes must not survive run 2"
grep -qF '<island src="components/data/posts_index.island.tsx" client:load></island>' "$WORK/out2/layouts/posts/index.shtml" || fail "the posts index must be replaced by its data island"
grep -q 'rails:finding' "$WORK/out2/layouts/posts/index.shtml" && fail "a bound data region must leave no finding marker"
grep -qF 'getList(1, 50)' "$WORK/out2/components/data/posts_index.island.tsx" || fail "the posts data island must fetch its first 50 records"
grep -qF '"/posts/" + encodeURIComponent(String(rec.id ?? ""))' "$WORK/out2/components/data/posts_index.island.tsx" || fail "the posts data island must preserve record links"
cmp "$WORK/app/app/javascript/components/Chart.jsx" "$WORK/out2/components/react/Chart.jsx" || fail "the React source closure must be copied byte-for-byte"
[[ "$(cat "$WORK/out2/z-runtime.config.json")" == '{"islandImports":{"firstParty":[],"npmCompat":[]},"resolve":{"react":"@z/runtime/compat","react-dom":"@z/runtime/compat","react-dom/client":"@z/runtime/compat/client","react/jsx-runtime":"@z/runtime/jsx-runtime","react/jsx-dev-runtime":"@z/runtime/jsx-dev-runtime"}}' ]] || fail "z-runtime.config.json bytes changed"
grep -q '"allowJs": true' "$WORK/out2/tsconfig.json" || fail "copied JSX requires allowJs"

# --- run 2: every route's note, exactly (rulings S3-R6 and S3-R7) ----------
# The note is the whole handoff for a `migrated` route -- the status says the
# route is finished, and only the note says what the operator's answers turned
# into. Pinned as an exact string per route rather than by `grep -q`, because
# the defect ruling S3-R7 closes is a note that says something TRUE TWICE: a
# presence check passes just as happily on one copy as on two.
#
# Ruling S3-R7 applies every answer on a route instead of only the
# strongest-ranked one, so the nav's `<%= current_user.email %>` -- answered
# `island` in the decisions file, and swallowed by the `<% if current_user %>`
# region the AuthStatus island replaced -- now reaches `settleSuperseded` on
# all five routes the nav rides on. It settles there and says nothing, because
# the status-region walk below it already reports that region by file and line
# ("mounts nothing of its own"). What `settleSuperseded` still says is the
# supersession the walk cannot see: the error summary on `/registration/new`,
# swallowed by the AuthForm the JOURNEY answer built, twice over (the region
# and the block local inside it).
note2() {
  local got
  got="$(jq -r --arg r "$1" '.routes[] | select(.route_id == $r) | .note // "<null>"' "$HANDOFF2")"
  [[ "$got" == "$2" ]] || fail "run 2: the note on $1 changed
  want: $2
  got:  $got"
}
head2='csrf_meta_tags dropped; javascript_importmap_tags dropped; app/javascript/application.js dropped by decision'
# The two facts the status-region walk reports about the shared nav: the
# signed-out half folded into its complement, and the greeting inside the
# region the island replaced.
nav2='app/views/shared/_nav.html.erb:5 `if current_user` folded into the AuthStatus island above it; app/views/shared/_nav.html.erb:5 `current_user.email` is inside the region the AuthStatus island replaced, so it mounts nothing of its own'
# `settleSuperseded`'s note, on the one route that earns it. Both ids are
# named because neither alone is actionable: the operator knows which finding
# they answered and cannot otherwise tell which answer made theirs redundant
# -- and here the superseder is the auth JOURNEY, so there is no
# "mounts nothing of its own" line coming to say it instead.
absorbed2='choice island on RAILS_REQUEST_TIME_STATE.app/views/registrations/new%2Ehtml%2Eerb.L1C36 superseded by the island answering RAILS_AUTH_JOURNEY.config/routes%2Erb.L38, which replaced the region it sits in; choice island on RAILS_REQUEST_TIME_STATE.app/views/registrations/new%2Ehtml%2Eerb.L1C4 superseded by the island answering RAILS_AUTH_JOURNEY.config/routes%2Erb.L38, which replaced the region it sits in'
note2 "GET /"                 "$head2; $nav2"
note2 "GET /about"            "$head2; $nav2"
note2 "GET /linked"           "$head2; $nav2"
note2 "GET /session/new"      "$head2; $nav2"
note2 "GET /registration/new" "$head2; $absorbed2; $nav2"
# The nav does not reach a dynamic route's shell, so nothing is folded there.
note2 "GET /posts/:id"        "<null>"
# The unmigrated rows, pinned in the same pass so a change to the walk cannot
# move a note off a migrated route and onto one of these unnoticed.
note2 "GET /posts"            "$head2; guarded by before_action :require_login; shipped public by decision; $nav2"
widgets_note2='data-turbo attributes dropped; Turbo Drive is ordinary navigation here; csrf_meta_tags dropped; javascript_importmap_tags dropped; app/javascript/application.js dropped by decision; turbo-frame `static` inlined; app/views/shared/_nav.html.erb:5 `if current_user` folded into the AuthStatus island above it; app/views/shared/_nav.html.erb:5 `current_user.email` is inside the region the AuthStatus island replaced, so it mounts nothing of its own'
note2 "GET /widgets"          "$widgets_note2"
note2 "GET /help"             "csrf_meta_tags dropped; javascript_importmap_tags dropped"
note2 "GET /links"            "csrf_meta_tags dropped; javascript_importmap_tags dropped"
note2 "GET /live"             "csrf_meta_tags dropped; javascript_importmap_tags dropped"
note2 "GET /broken"           "view app/views/pages/broken.html.erb was not converted"
note2 "GET /posts/legacy"     "view app/views/posts/legacy.html.haml was not converted"
note2 "GET /feed"             "<null>"
note2 "GET /old"              "<null>"
note2 "POST /registration"    "<null>"
note2 "POST /session"         "<null>"
note2 "DELETE /session"       "<null>"

# --- run 2: the answered tree (ruling S20) ---------------------------------
# The exact tree, which is what makes S20 visible: an acknowledged route
# writes NO page and NO view file -- `content/help`, `content/links`,
# `content/posts` and their `layouts/<ctrl>/<action>.shtml` are gone, because
# `retained` means the page stays on Rails and `blocked` means it does not
# ship. Emitting them anyway made `blocked` a relabelling: the built site
# served a blank `<main>` for a route the handoff called blocked, which is
# worse than a 404 because it looks deliberate.
#
# `layouts/templates/application.shtml` DOES survive with no page extending
# it: a layout is shared chrome, written once per layout rather than per
# route, and it mounts the AuthStatus island the nav's answer produced.
listing2="$(cd "$WORK/out2" && find . -type f | sort | tr '\n' ' ')"
expected_listing2="./.gitignore ./AGENTS.md ./CLAUDE.md ./MIGRATION.handoff.json ./MIGRATION.manifest.json ./MIGRATION.md ./assets/images/logo.png ./assets/robots.txt ./assets/stylesheets/application.css ./build.sh ./components/AuthForm.island.tsx ./components/AuthStatus.island.tsx ./components/Chart.island.tsx ./components/TurboFrame.island.tsx ./components/data/posts_index.island.tsx ./components/forms/posts_new.island.tsx ./components/react/Chart.jsx ./components/stimulus/reveal.island.tsx ./content/about/index.smd ./content/index.smd ./content/linked/index.smd ./content/posts/index.smd ./content/posts/new/index.smd ./content/registration/new/index.smd ./content/session/new/index.smd ./content/widgets/index.smd ./layouts/pages/about.shtml ./layouts/pages/linked.shtml ./layouts/pages/widgets.shtml ./layouts/posts/index.shtml ./layouts/posts/new.shtml ./layouts/registrations/new.shtml ./layouts/sessions/new.shtml ./layouts/templates/application.shtml ./layouts/templates/marketing.shtml ./lib/stimulus.ts ./lib/zb.ts ./package.json ./spa/posts.spa.tsx ./test/journey_playwright.py ./test/parity.ts ./tsconfig.json ./z-runtime.config.json ./zigapagos.ziggy "
[[ "$listing2" == "$expected_listing2" ]] || fail "run 2 target listing changed:
  got:      $listing2
  expected: $expected_listing2"
# ...and the handoff agrees: an acknowledged route claims no artifact, so the
# record and the tree cannot drift apart.
for r in 'GET /help' 'GET /links' 'GET /live'; do
  n=$(jq -r --arg r "$r" '.routes[] | select(.route_id == $r) | .artifacts | length' "$HANDOFF2")
  [[ "$n" == "0" ]] || fail "$r is acknowledged and must claim no artifact, got $n"
done
new_files2="$(find "$WORK/out2" -name '*.new*' | tr '\n' ' ')"
[[ -z "$new_files2" ]] || fail "the target must never contain .new files, got: $new_files2"

# --- determinism ------------------------------------------------------------
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out2b" \
  --decisions "$DECISIONS" --backend "$BACKEND" --runtime-path "$REPO/runtime" >/dev/null
cmp "$WORK/out2/MIGRATION.manifest.json" "$WORK/out2b/MIGRATION.manifest.json" || fail "manifest not deterministic"
cmp "$HANDOFF2" "$WORK/out2b/MIGRATION.handoff.json" || fail "handoff not deterministic"
# MIGRATION.md joins the determinism cmp set (#178). Both runs migrate the
# same source path, so this cmp alone would not have caught the old
# path-as-given title; the two greps below are the pins for that.
cmp "$WORK/out2/MIGRATION.md" "$WORK/out2b/MIGRATION.md" || fail "MIGRATION.md not deterministic"
# The islands are generated code, and generated code that moves between two
# identical runs is not shippable.
cmp "$WORK/out2/components/AuthForm.island.tsx" "$WORK/out2b/components/AuthForm.island.tsx" || fail "AuthForm not deterministic"
cmp "$WORK/out2/components/AuthStatus.island.tsx" "$WORK/out2b/components/AuthStatus.island.tsx" || fail "AuthStatus not deterministic"
for generated in components/Chart.island.tsx components/TurboFrame.island.tsx components/data/posts_index.island.tsx components/forms/posts_new.island.tsx components/react/Chart.jsx components/stimulus/reveal.island.tsx lib/stimulus.ts test/parity.ts test/journey_playwright.py z-runtime.config.json; do
  cmp "$WORK/out2/$generated" "$WORK/out2b/$generated" || fail "$generated not deterministic"
done
parity_runner_hash="$(shasum -a 256 "$WORK/out2/test/parity.ts" | awk '{print $1}')"
[[ "$parity_runner_hash" == "7a8bb6cd2780f69443a1eea954472455cbfae46211a4cf34b5ed8c91d94be2b6" ]] \
  || fail "fixed Bun parity runner bytes changed: got $parity_runner_hash"
[[ "$(shasum -a 256 "$WORK/out2/test/journey_playwright.py" | awk '{print $1}')" == "4c0f2f7ba13cebd4efd671c2ce2314f2cb963fc6a4d27a572b694c44d2b206f8" ]] \
  || fail "fixed Playwright journey runner bytes changed"
if command -v bun >/dev/null 2>&1; then
  mkdir -p "$WORK/get-head-parity/test"
  cp "$WORK/out2/test/parity.ts" "$WORK/get-head-parity/test/parity.ts"
  cat > "$WORK/get-head-parity/MIGRATION.handoff.json" <<'JSON'
{"schema_version":1,"parity":[{"id":"submit_denied:getSecret","kind":"submit_denied","url":"/secret","expect":{"operation_id":"getSecret","method":"GET","statuses":[401],"fields":[{"name":"q","value":"x","invalid_value":null}]}},{"id":"submit_denied:headSecret","kind":"submit_denied","url":"/secret-head","expect":{"operation_id":"headSecret","method":"HEAD","statuses":[401],"fields":[{"name":"q","value":"x","invalid_value":null}]}}]}
JSON
  (
    cd "$WORK/get-head-parity"
    ZIGAPAGOS_ORIGIN=http://example.invalid bun -e '
      const seen = [];
      globalThis.fetch = async (_url, init) => {
        const method = init?.method;
        if (method !== "GET" && method !== "HEAD") throw new Error(`unexpected method ${method}`);
        if (init?.body !== undefined) throw new Error(`${method} carried a body`);
        if (new Headers(init?.headers).has("content-type")) throw new Error(`${method} carried a content type`);
        seen.push(method);
        return new Response("", { status: 401 });
      };
      await import("./test/parity.ts");
      if (seen.join(",") !== "GET,HEAD") throw new Error(`unexpected requests ${seen.join(",")}`);
    '
  ) || fail "fixed Bun parity runner sent a body with GET/HEAD"
else
  echo "SKIP: Bun unavailable; GET/HEAD parity runtime regression not executed"
fi
cmp "$WORK/out2/lib/zb.ts" "$WORK/out2b/lib/zb.ts" || fail "lib/zb.ts not deterministic"
cmp "$WORK/out2/build.sh" "$WORK/out2b/build.sh" || fail "build.sh not deterministic"
# The fixture is migrated from its scratch copy at $WORK/app, so the basename
# the title must carry is `app` -- and nothing of the scratch path above it.
grep -q "^# Migrating app to Zigapagos" "$WORK/out2/MIGRATION.md" || fail "MIGRATION.md title must be the app basename"
grep -q "$WORK" "$WORK/out2/MIGRATION.md" && fail "MIGRATION.md embeds the scratch path"

# --- Stage 5 semantic mutation checks -------------------------------------
# Each mutant is fed to the same exact parity assertion used above. If any
# one survives, the fixture is pinning shape rather than the promised fact.
jq 'del(.parity[] | select(.id == "navigate:GET /posts/new"))' "$HANDOFF2" > "$WORK/mut-no-navigate.json"
if assert_stage5_parity "$WORK/mut-no-navigate.json"; then
  fail "mutation survived: removing one navigate fact must fail the parity pin"
fi

# Invert the operation's real access evidence and regenerate. Public create
# must remove submit_denied; merely editing the finished handoff would not
# exercise backend parsing and parity derivation together.
jq '(.paths["/api/collections/posts/records"].post["x-zigbase-access"]) = "public"
    | del(.paths["/api/collections/posts/records"].post["x-zigbase-rule"])' "$BACKEND" > "$WORK/backend-public.json"
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/mut-public-access" \
  --decisions "$DECISIONS" --backend "$WORK/backend-public.json" --runtime-path "$REPO/runtime" >/dev/null
if assert_stage5_parity "$WORK/mut-public-access/MIGRATION.handoff.json"; then
  fail "mutation survived: public createPosts must fail the denied-access parity pin"
fi
if jq -e '.parity[] | select(.id == "submit_denied:createPosts")' "$WORK/mut-public-access/MIGRATION.handoff.json" >/dev/null; then
  fail "public createPosts still emitted submit_denied"
fi

jq '(.parity[] | select(.id == "validation_error:createPosts:title") | .expect.field) = ""' "$HANDOFF2" > "$WORK/mut-blank-validation-field.json"
if assert_stage5_parity "$WORK/mut-blank-validation-field.json"; then
  fail "mutation survived: blanking the validation field must fail the parity pin"
fi

# --- run 2c: the same answers with NO --runtime-path (#179) ----------------
# `--runtime-path` shadows ZIGAPAGOS_RUNTIME_DIR, so every run above proves
# nothing about the variable -- and the variable is the ONLY thing standing
# between a generated package.json and `file:TODO-SET-RUNTIME-PATH`, which
# `bun install` cannot resolve. This run is that seam's only coverage.
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out2c" \
  --decisions "$DECISIONS" --backend "$BACKEND" >/dev/null
grep -qF "\"@z/runtime\": \"file:$REPO/runtime\"" "$WORK/out2c/package.json" \
  || fail "#179: ZIGAPAGOS_RUNTIME_DIR must fill the runtime dependency when --runtime-path is absent"
grep -q 'TODO-SET-RUNTIME-PATH' "$WORK/out2c/package.json" \
  && fail "#179: the placeholder must not survive when the environment names a runtime"

# --- run 2d: the operator ALSO answers the nested sign-out link (S3-R6) ----
# The `button_to "Sign out"` sits INSIDE the `if current_user` region the
# AuthStatus island replaces, and the island performs the logout itself -- so
# run 2's decisions deliberately leave it alone. But the handoff lists its
# finding under every route the nav rides on, so an operator working down that
# list answers it, and that answer must be ACCEPTED: it is a correct answer to
# a question that is simply already settled.
#
# The defect this pins shut: `applyAcknowledgement`'s backend arm asked only
# whether the answer produced a BINDING, never whether an enclosing region's
# binding had already swallowed the id -- so the run exited 3 with
# `needs the --backend document that names it`, on a run given a document, for
# a `custom:` answer that needs no document at all.
DEC2D="$WORK/decisions-2d.json"
jq '.decisions += [{
      "id": "RAILS_BACKEND_ENDPOINT.app/views/shared/_nav%2Ehtml%2Eerb.L5C54",
      "choice": "custom:/api/logout",
      "rationale": "answered from the handoff, not knowing the AuthStatus island already logs out"
    }]' "$DECISIONS" > "$DEC2D"
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out2d" \
  --decisions "$DEC2D" --backend "$BACKEND" --runtime-path "$REPO/runtime" >/dev/null
run2d_rc=$?
set -e
[[ $run2d_rc -eq 0 ]] || fail "S3-R6: answering a finding inside a bound region must not fail the run, got $run2d_rc"
HANDOFF2D="$WORK/out2d/MIGRATION.handoff.json"
[[ "$(jq -r '.complete' "$HANDOFF2D")" == "true" ]] || fail "S3-R6: run 2d must still be complete"
still_open_2d="$(jq -r '.routes[] | select(.status == "open") | .route_id' "$HANDOFF2D" | tr '\n' ' ')"
[[ -z "$still_open_2d" ]] || fail "S3-R6: routes left open by a redundant answer: $still_open_2d"
# The route the extra answer is read on. `pickDecision` ranks `custom:…` and
# `island` equally and breaks the tie on the smallest id, so the sign-out
# answer is what `GET /` is decided by -- which is exactly why it had to be
# accepted rather than deferred.
root_note_2d=$(jq -r '.routes[] | select(.route_id == "GET /") | .note' "$HANDOFF2D")
[[ "$(jq -r '.routes[] | select(.route_id == "GET /") | .status' "$HANDOFF2D")" == "migrated" ]] \
  || fail "S3-R6: GET / must still be migrated: $root_note_2d"
# BOTH ids: the operator knows which finding they answered, and cannot
# otherwise tell which other answer made theirs redundant.
grep -q 'superseded by the island answering' <<<"$root_note_2d" \
  || fail "S3-R6: the note must say the answer was superseded: $root_note_2d"
grep -q 'RAILS_BACKEND_ENDPOINT.app/views/shared/_nav%2Ehtml%2Eerb.L5C54' <<<"$root_note_2d" \
  || fail "S3-R6: the note must name the answer that was superseded: $root_note_2d"
grep -q 'RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L5C6' <<<"$root_note_2d" \
  || fail "S3-R6: the note must name the island answer that superseded it: $root_note_2d"
grep -q 'needs the --backend document' <<<"$root_note_2d" \
  && fail "S3-R6: the run WAS given a --backend document; that note is a lie: $root_note_2d"
# Accepted, not acted on: the redundant answer builds nothing of its own. The
# page still has no link to /session (the island replaced the control), and
# `DELETE /session` still binds the journey's `logout`, not `custom`.
grep -q 'href="/session">' "$WORK/out2d/layouts/templates/marketing.shtml" \
  && fail "S3-R6: a superseded answer must not resurrect the control the island replaced"
[[ -f "$WORK/out2d/components/forms/posts_new.island.tsx" ]] \
  || fail "S3-R6: the ordinary posts form island must survive"
[[ "$(find "$WORK/out2d/components/forms" -type f | wc -l)" -eq 1 ]] \
  || fail "S3-R6: a superseded answer must not scaffold a second click island"
ep_2d=$(jq -r '.routes[] | select(.route_id == "DELETE /session") | [.endpoint.operation_id, .endpoint.verb, .endpoint.path] | join(" ")' "$HANDOFF2D")
[[ "$ep_2d" == "logout POST /api/collections/users/auth-logout" ]] \
  || fail "S3-R6: DELETE /session must still bind the journey's logout, got: $ep_2d"

# --- the target is a real Zigapagos project --------------------------------
# The criterion no listing can fake: the emitted tree BUILDS, and the built
# site passes the auditor. `build.sh` is the target's own entry point (bun
# install + `zigapagos release --spa=... --island=...`), so this exercises the
# generated command line too, not a hand-written one. `bun install` fetches
# `@zigbase/client@0.3.0` from npm (assumption A8): the skip below is for a
# missing bun, never for a missing network.
if command -v bun >/dev/null; then
  ( cd "$WORK/out2" && ZIGAPAGOS_BIN="$ZIGAPAGOS" bash build.sh >"$WORK/release.log" 2>&1 ) \
    || { tail -20 "$WORK/release.log"; fail "zigapagos release failed on the migrated target"; }
  [[ -f "$WORK/out2/zig-out/site/about/index.html" ]] || fail "the release did not emit the about page"
  [[ -f "$WORK/out2/zig-out/site/posts/_shell.html" ]] || fail "the release did not emit the SPA shell"
  # The islands the backend boundary produced, bundled and SSR'd. Their bytes
  # having been written is not the claim -- the claim is that a browser gets
  # them, with the props the layout declared.
  [[ -f "$WORK/out2/zig-out/site/islands/AuthForm.island.js" ]] || fail "the AuthForm island was not bundled"
  [[ -f "$WORK/out2/zig-out/site/islands/AuthStatus.island.js" ]] || fail "the AuthStatus island was not bundled"
  [[ -f "$WORK/out2/zig-out/site/islands/posts_new.island.js" ]] || fail "the posts form island was not bundled"
  [[ -f "$WORK/out2/zig-out/site/session/new/index.html" ]] || fail "the sign-in page was not built"
  [[ -f "$WORK/out2/zig-out/site/posts/new/index.html" ]] || fail "the posts/new page was not built"
  grep -q 'data-z-module="/islands/posts_new.island.js"' "$WORK/out2/zig-out/site/posts/new/index.html" \
    || fail "posts/new does not SSR the bound form island"
  grep -q 'name="title"' "$WORK/out2/zig-out/site/posts/new/index.html" \
    || fail "posts/new SSR lost the validation field"
  grep -q 'data-z-props' "$WORK/out2/zig-out/site/session/new/index.html" || fail "the sign-in page carries no SSR'd island"
  grep -qF '{"mode":"signin"}' "$WORK/out2/zig-out/site/session/new/index.html" || fail "the sign-in page's island is not in signin mode"
  grep -qF '{"mode":"signup"}' "$WORK/out2/zig-out/site/registration/new/index.html" || fail "the sign-up page's island is not in signup mode"
  # The layout's AuthStatus rides on every built page, ONCE.
  nav_ssr=$(grep -c 'data-z-module="/islands/AuthStatus.island.js"' "$WORK/out2/zig-out/site/about/index.html" || true)
  [[ "$nav_ssr" == "1" ]] || fail "the nav's AuthStatus must be SSR'd exactly once per page, got $nav_ssr"
  # Ruling S20 in the BUILT site, which is where it actually matters: a
  # blocked route has no page here at all. Before S20 these existed and
  # rendered an empty `<main>` -- a route the handoff called blocked, served
  # as a blank page.
  [[ ! -e "$WORK/out2/zig-out/site/help/index.html" ]] || fail "a blocked route must not be served at all"
  [[ ! -e "$WORK/out2/zig-out/site/links/index.html" ]] || fail "a blocked route must not be served at all"
  [[ ! -e "$WORK/out2/zig-out/site/live/index.html" ]] || fail "the blocked realtime route must not be served"
  widgets_html="$WORK/out2/zig-out/site/widgets/index.html"
  grep -qF 'data-z-module="/islands/reveal.island.js"' "$widgets_html" || fail "the reveal island was not bundled into widgets"
  grep -q 'data-z-slots' "$widgets_html" || fail "the reveal island must carry its original element as a slot"
  grep -qF '<button type="button">a:3</button>' "$widgets_html" || fail "the React component did not SSR through the compatibility bridge"
  grep -qF '{"id":"latest","src":"/posts"}' "$widgets_html" || fail "the frame island's SSR props changed"
  grep -qF '<link rel="stylesheet" href="/stylesheets/application.css">' "$WORK/out2/zig-out/site/posts/_shell.html" || fail "spa.head must reach the built shell"
  grep -q "declares no spa.head" "$WORK/release.log" && fail "the generated SPA declares a stylesheet head; the old warning must stay gone"
  ( cd "$WORK/out2" && bunx tsc -p tsconfig.json ) >"$WORK/tsc.log" 2>&1 \
    || { cat "$WORK/tsc.log"; fail "generated target must pass TypeScript without TS7026 or any other diagnostic"; }
  "$ZIGAPAGOS" doctor "$WORK/out2/zig-out/site" >"$WORK/doctor.log" 2>&1 || { cat "$WORK/doctor.log"; fail "doctor failed"; }
  grep -q 'doctor: 0 errors' "$WORK/doctor.log" || { cat "$WORK/doctor.log"; fail "doctor reported errors on the migrated site"; }
  # ZERO warnings, not a permitted set. In Stage 2 the shared `_nav` linked to
  # `/session/new`, which was retained, and the auditor rightly called it a
  # dangling internal link. #167 Stage 3 migrates that route AND replaces the
  # link with the AuthStatus island, so the last warning is gone and any new
  # one is a regression.
  warns=$(grep '^warn ' "$WORK/doctor.log" || true)
  [[ -z "$warns" ]] || { cat "$WORK/doctor.log"; fail "unexpected doctor warnings: $warns"; }

  mkdir -p "$WORK/out2/test"
  cat > "$WORK/out2/bunfig.toml" <<'TOML'
[test]
preload = ["@z/runtime/testing/preload"]
TOML
  cat > "$WORK/out2/test/hydrate.test.ts" <<'TS'
import { afterEach, expect, mock, test } from "bun:test";
import { click, flush, renderIsland } from "@z/runtime/testing";
import { slotVNode } from "@z/runtime/slots";
import Reveal from "../components/stimulus/reveal.island.tsx";
import TurboFrame from "../components/TurboFrame.island.tsx";
import ChartIsland from "../components/Chart.island.tsx";
import PostsIndex from "../components/data/posts_index.island.tsx";

const originalFetch = globalThis.fetch;
// Do not call mock.restore() here: the preload's module overrides are Bun
// mocks too, and restoring them splits generated islands from the harness's
// one Preact runtime after the first test.
afterEach(() => { globalThis.fetch = originalFetch; document.body.innerHTML = ""; });
const settleEffects = async () => { await flush(); await new Promise((resolve) => setTimeout(resolve, 20)); await flush(); };

test("Stimulus action bindings survive hydration", async () => {
  const originalWarn = console.warn;
  const warnings: unknown[][] = [];
  console.warn = (...args: unknown[]) => { warnings.push(args); };
  const r = renderIsland(Reveal, { children: slotVNode("default", '<div data-controller="reveal" data-reveal-open-value="false"><button data-action="click->reveal#toggle">Show</button><p data-reveal-target="details" class="hidden">D</p></div>') });
  await settleEffects();
  await click(r.get("button"));
  expect(warnings).toContainEqual(["zigapagos: reveal#toggle is not ported"]);
  console.warn = originalWarn;
  r.unmount();
});

test("Turbo frame fetches and replaces its body", async () => {
  const fetchMock = mock(() => Promise.resolve({ text: async () => '<html><body><div id="latest">loaded</div></body></html>' } as Response));
  const originalWarn = console.warn;
  const warnings: unknown[][] = [];
  console.warn = (...args: unknown[]) => { warnings.push(args); };
  const r = renderIsland(TurboFrame, { id: "latest", src: "/posts" });
  // renderIsland installs its mock host (and therefore its default fetch);
  // replace that fetch before the post-mount effect is flushed.
  globalThis.fetch = fetchMock as typeof fetch;
  await settleEffects();
  expect(fetchMock).toHaveBeenCalled();
  expect(warnings).toHaveLength(0);
  expect(r.text()).toContain("loaded");
  console.warn = originalWarn;
  r.unmount();
});

test("React compatibility root hydrates", () => {
  const r = renderIsland(ChartIsland, { series: "a", points: 3 });
  expect(r.text()).toBe("a:3");
  r.unmount();
});

test("data island fetches and renders records", async () => {
  const fetchMock = mock(() => Promise.resolve({ ok: true, status: 200, text: async () => JSON.stringify({ items: [{ id: "1", title: "Hello", published: true }], page: 1, perPage: 50, totalItems: 1 }) } as Response));
  const r = renderIsland(PostsIndex, {});
  globalThis.fetch = fetchMock as typeof fetch;
  await settleEffects();
  expect(fetchMock).toHaveBeenCalled();
  expect(r.text()).toContain("Hello");
  expect(r.get("a").getAttribute("href")).toBe("/posts/1");
  expect(r.text()).toContain("Hello");
  expect(r.text()).toContain("Published");
  r.unmount();
});
TS
  ( cd "$WORK/out2" && bun test test/hydrate.test.ts ) || fail "generated islands failed hydration coverage"
else
  echo "SKIP(partial): bun not on PATH -- the migrated target was not built or audited"
fi

# --- negative: an unusable --backend document ------------------------------
# Exit 1, not 3 and not a panic: the operator's input is wrong, which is the
# same class as an unusable decisions file, and both print and return rather
# than going through `fatal.msg` (which panics under the Debug build every
# shell e2e drives, delivering 134).
set +e
notdoc_out="$("$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/badbk" --backend "$WORK/app/Gemfile" 2>&1)"
notdoc_rc=$?
set -e
[[ $notdoc_rc -eq 1 ]] || fail "a --backend file that is not an OpenAPI document must exit 1, got $notdoc_rc"
grep -q 'is not a ZigBase OpenAPI document: InvalidJson' <<<"$notdoc_out" || fail "the error must name the reason: $notdoc_out"
[[ ! -e "$WORK/badbk" ]] || fail "a rejected --backend must create no target"
# Ruling S3-R4: a path that does not resolve is the same class of mistake, and
# gets the same treatment. It arrived as 134 before that ruling.
set +e
missing_out="$("$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/badbk2" --backend "$WORK/no-such-file.json" 2>&1)"
missing_rc=$?
set -e
[[ $missing_rc -eq 1 ]] || fail "a missing --backend file must exit 1 (not a panic), got $missing_rc"
grep -q -- '--backend .* could not be read: FileNotFound' <<<"$missing_out" || fail "the error must name the flag, the path and the OS error: $missing_out"

# --- negative: answers the document refuses --------------------------------
# The artifact must be an auth collection the DOCUMENT knows, and the error
# names the ones it has -- otherwise an operator guesses collection names
# against a backend they cannot see.
python3 - "$DECISIONS" "$WORK/members.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for x in d["decisions"]:
    if x["id"].startswith("RAILS_AUTH_JOURNEY"):
        x["artifact"] = "members"
json.dump(d, open(sys.argv[2], "w"))
PY
set +e
members_out="$("$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/m1" --decisions "$WORK/members.json" --backend "$BACKEND" 2>&1)"
members_rc=$?
set -e
[[ $members_rc -eq 1 ]] || fail "an artifact naming no auth collection must exit 1, got $members_rc"
grep -q 'artifact "members" is not an auth collection in the backend document; auth collections: users' <<<"$members_out" \
  || fail "the error must name the collections the document does have: $members_out"

# An operation of the WRONG VERB is not merely unhelpful, it is not offered:
# `createPosts` is a POST, and this finding is a GET route's.
python3 - "$DECISIONS" "$WORK/wrongverb.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for x in d["decisions"]:
    if x["id"].startswith("RAILS_BACKEND_ENDPOINT.config"):
        x["choice"] = "createPosts"
json.dump(d, open(sys.argv[2], "w"))
PY
set +e
wrongverb_out="$("$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/m2" --decisions "$WORK/wrongverb.json" --backend "$BACKEND" 2>&1)"
wrongverb_rc=$?
set -e
[[ $wrongverb_rc -eq 1 ]] || fail "an operation of the wrong verb must exit 1, got $wrongverb_rc"
grep -q 'allowed: listPosts, viewPosts, listUsers, viewUsers, retain, blocked' <<<"$wrongverb_out" \
  || fail "the rejection must name the allowed set: $wrongverb_out"

jq '(.decisions[] | select(.id == "RAILS_TURBO_STREAM.app/views/pages/live%2Ehtml%2Eerb.L1C5") | .choice) = "island"' "$DECISIONS" > "$WORK/stream-island.json"
set +e
stream_bad_out="$("$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/stream-bad" --decisions "$WORK/stream-island.json" --backend "$BACKEND" 2>&1)"
stream_bad_rc=$?
set -e
[[ $stream_bad_rc -eq 1 ]] || fail "Turbo streams cannot be answered island, got $stream_bad_rc"
grep -q 'allowed: retain, blocked' <<<"$stream_bad_out" || fail "Turbo stream rejection must name its allowed set: $stream_bad_out"

jq '(.decisions[] | select(.id == "RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L1C33") | .artifact) = "nope"' "$DECISIONS" > "$WORK/bad-data-artifact.json"
set +e
data_artifact_out="$("$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/data-artifact-bad" --decisions "$WORK/bad-data-artifact.json" --backend "$BACKEND" 2>&1)"
data_artifact_rc=$?
set -e
[[ $data_artifact_rc -eq 1 ]] || fail "an unknown data collection artifact must exit 1, got $data_artifact_rc"
grep -q 'collections: posts, users' <<<"$data_artifact_out" || fail "the data artifact rejection must list collections: $data_artifact_out"

# The same answers WITHOUT the document: `listPosts` is a word the run cannot
# check, so it is refused rather than trusted. This is the discrimination for
# every `--backend` assertion above -- if the flag did nothing, this run would
# succeed.
set +e
nodoc_out="$("$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/m3" --decisions "$DECISIONS" 2>&1)"
nodoc_rc=$?
set -e
[[ $nodoc_rc -eq 1 ]] || fail "an operation id without a document must exit 1, got $nodoc_rc"
grep -q 'choice "listPosts" is not offered' <<<"$nodoc_out" || fail "the rejection must name the choice: $nodoc_out"
grep -q 'allowed: retain, blocked' <<<"$nodoc_out" || fail "without a document only the two reserved answers are allowed: $nodoc_out"

# A no-document decisions pass that uses only choices still offered without
# the artifact reaches the scaffold boundary: `island` is the same data port
# as `backend`, but cannot be generated until a list operation is known.
jq '(.decisions[] | select(.id == "RAILS_AUTH_JOURNEY.config/routes%2Erb.L38") | .choice) = "retain"
    | del(.decisions[] | select(.id == "RAILS_AUTH_JOURNEY.config/routes%2Erb.L38") | .artifact)
    | (.decisions[] | select(.id == "RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L20.GET.posts") | .choice) = "retain"
    | (.decisions[] | select(.id == "RAILS_BACKEND_ENDPOINT.app/views/posts/new%2Ehtml%2Eerb.L3C5") | .choice) = "retain"
    | (.decisions[] | select(.id == "RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L1C33") | .choice) = "island"
    | (.decisions[] | select(.id == "RAILS_REQUEST_TIME_STATE.app/views/posts/show%2Ehtml%2Eerb.L1C9") | .choice) = "island"' "$DECISIONS" > "$WORK/no-backend-port.json"
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/no-backend-port" --decisions "$WORK/no-backend-port.json" --runtime-path "$REPO/runtime" >/dev/null
no_backend_port_rc=$?
set -e
[[ $no_backend_port_rc -eq 3 ]] || fail "a data port without --backend must remain open, got $no_backend_port_rc"
no_backend_posts_note=$(jq -r '.routes[] | select(.route_id == "GET /posts") | .note' "$WORK/no-backend-port/MIGRATION.handoff.json")
grep -q 'needs a --backend document with a list operation' <<<"$no_backend_posts_note" || fail "the posts data port must say which backend capability is missing: $no_backend_posts_note"

# `custom:/<path>` (assumption A3) is the escape hatch for a route no
# collection operation matches: accepted on a RAILS_BACKEND_ENDPOINT, never
# enumerated in `choices` (a free-form token cannot be), and it binds.
python3 - "$DECISIONS" "$WORK/custom.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for x in d["decisions"]:
    if x["id"].startswith("RAILS_BACKEND_ENDPOINT.config"):
        x["choice"] = "custom:/api/feed"
json.dump(d, open(sys.argv[2], "w"))
PY
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/m4" --decisions "$WORK/custom.json" \
  --backend "$BACKEND" --runtime-path "$REPO/runtime" >/dev/null
custom_rc=$?
set -e
[[ $custom_rc -eq 0 ]] || fail "a custom: answer must still complete the run, got $custom_rc"
custom_ep=$(jq -r '.routes[] | select(.route_id == "GET /feed") | .endpoint | "\(.operation_id) \(.verb) \(.path)"' "$WORK/m4/MIGRATION.handoff.json")
[[ "$custom_ep" == "custom GET /api/feed" ]] || fail "a custom: answer binds {custom, the route's verb, the given path}, got: $custom_ep"

# Delete ONE answer and the run stops completing. Without this the exit-0
# above could be explained by a completion rule that never looked at the
# journey at all.
python3 - "$DECISIONS" "$WORK/nojourney.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["decisions"] = [x for x in d["decisions"] if not x["id"].startswith("RAILS_AUTH_JOURNEY")]
json.dump(d, open(sys.argv[2], "w"))
PY
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/m5" --decisions "$WORK/nojourney.json" \
  --backend "$BACKEND" --runtime-path "$REPO/runtime" >/dev/null
nojourney_rc=$?
set -e
[[ $nojourney_rc -eq 3 ]] || fail "dropping the journey answer must reopen the run, got $nojourney_rc"
[[ ! -e "$WORK/m5/components/AuthForm.island.tsx" ]] || fail "an unanswered journey scaffolds nothing"

jq 'del(.decisions[] | select(.id == "RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry"))' "$DECISIONS" > "$WORK/no-js-entry.json"
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/no-js-entry" --decisions "$WORK/no-js-entry.json" --backend "$BACKEND" --runtime-path "$REPO/runtime" >/dev/null
no_js_rc=$?
set -e
[[ $no_js_rc -eq 3 ]] || fail "dropping the global JS entry answer must reopen the run, got $no_js_rc"
for route in 'GET /' 'GET /about' 'GET /linked' 'GET /posts' 'GET /posts/new' 'GET /registration/new' 'GET /session/new' 'GET /widgets'; do
  jq -e --arg route "$route" '.routes[] | select(.route_id == $route and .status == "open" and (.findings | index("RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry")))' "$WORK/no-js-entry/MIGRATION.handoff.json" >/dev/null || fail "$route must reopen on the unanswered global JS entry"
done
for route in 'GET /help' 'GET /links' 'GET /live'; do
  jq -e --arg route "$route" '.routes[] | select(.route_id == $route and (.findings | index("RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry")))' "$WORK/no-js-entry/MIGRATION.handoff.json" >/dev/null || fail "$route must also carry the unanswered global JS entry beside its blocking answer"
done

jq '(.decisions[] | select(.id == "RAILS_STIMULUS_CONTROLLER.app/views/pages/widgets%2Ehtml%2Eerb.L2C1") | .choice) = "drop"' "$DECISIONS" > "$WORK/drop-stimulus.json"
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/drop-stimulus" --decisions "$WORK/drop-stimulus.json" --backend "$BACKEND" --runtime-path "$REPO/runtime" >/dev/null || fail "dropping a portable Stimulus controller must still complete"
grep -q '<div>' "$WORK/drop-stimulus/layouts/pages/widgets.shtml" || fail "Stimulus drop must keep a plain div"
grep -q 'data-' "$WORK/drop-stimulus/layouts/pages/widgets.shtml" && fail "Stimulus drop must remove all data attributes from the controller element"
[[ ! -e "$WORK/drop-stimulus/components/stimulus" ]] || fail "Stimulus drop must scaffold no controller island"

# Delete the feed answer and the run stops completing TOO -- assumption A2 in
# one assertion. Every other route is answered; the only thing keeping this
# run open is a user-facing GET the handoff calls `backend` with nothing bound
# to it. Under Stage 2's rule (S11) `backend` was accounted unconditionally
# and this run would have exited 0 with an unanswered route.
python3 - "$DECISIONS" "$WORK/nofeed.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["decisions"] = [x for x in d["decisions"] if not x["id"].startswith("RAILS_BACKEND_ENDPOINT.config")]
json.dump(d, open(sys.argv[2], "w"))
PY
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/m6" --decisions "$WORK/nofeed.json" \
  --backend "$BACKEND" --runtime-path "$REPO/runtime" >/dev/null
nofeed_rc=$?
set -e
[[ $nofeed_rc -eq 3 ]] || fail "A2: an unbound user-facing GET must keep the run open, got $nofeed_rc"
feed_status=$(jq -r '.routes[] | select(.route_id == "GET /feed") | "\(.status) \(.endpoint) \(.decision)"' "$WORK/m6/MIGRATION.handoff.json")
[[ "$feed_status" == "backend null null" ]] || fail "the unbound feed row: $feed_status"
# ...and its non-GET neighbours are still exempt, which is what stops A2 from
# being "every backend route must be answered".
post_status=$(jq -r '.routes[] | select(.route_id == "POST /session") | .status' "$WORK/m6/MIGRATION.handoff.json")
[[ "$post_status" == "backend" ]] || fail "POST /session should still be backend, got $post_status"

# --- the auth guard survives an unanswered data port -----------------------
jq 'del(.decisions[] | select(.id == "RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L1C33"))' "$DECISIONS" > "$WORK/guardonly.json"
set +e
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/g1" --decisions "$WORK/guardonly.json" \
  --backend "$BACKEND" --runtime-path "$REPO/runtime" >/dev/null
guard_rc=$?
set -e
[[ $guard_rc -eq 3 ]] || fail "the guard-only variant should still exit 3, got $guard_rc"
G="$WORK/g1/MIGRATION.handoff.json"
[[ "$(jq -r '.routes[] | select(.route_id == "GET /posts") | .status' "$G")" == "open" ]] \
  || fail "public settles the guard, not the route"
[[ -f "$WORK/g1/content/posts/index.smd" ]] || fail "public SHIPS the page -- that is the whole difference from retain"
guard_note=$(jq -r '.routes[] | select(.route_id == "GET /posts") | .note' "$G")
grep -q 'guarded by before_action :require_login; shipped public by decision' <<<"$guard_note" \
  || fail "the note must say a guarded page is shipping public: $guard_note"
# The guard's own id is settled and no longer listed; the questions nobody
# answered still are.
guard_open=$(jq -r '.routes[] | select(.route_id == "GET /posts") | .findings | join(" ")' "$G")
grep -q 'RAILS_ROUTE_AUTH_GUARD' <<<"$guard_open" && fail "an answered-and-acted-on guard must not stay open: $guard_open"
grep -q 'RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L1C33' <<<"$guard_open" || fail "the unanswered data question must still be listed: $guard_open"

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
  --decisions "$WORK/loop/MIGRATION.decisions.json" --backend "$BACKEND" --runtime-path "$REPO/runtime" >/dev/null
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
