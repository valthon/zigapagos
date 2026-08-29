#!/usr/bin/env bash
# tests/migrate/rails-presentation.sh -- #167 Stage 1: the manifest names
# every fragment a converter would refuse, and nothing else changes yet
# (no target output beyond the two discovery artifacts).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
fail() { echo "FAIL: $*"; exit 1; }
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"
[[ -x "$ZIGAPAGOS" ]] || zig build || fail "zig build failed"
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"
command -v ruby >/dev/null || { echo "SKIP: ruby not on PATH; Stage 1 findings need the sidecar"; exit 0; }
command -v jq >/dev/null || fail "jq required"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp -R "$REPO/tests/migrate/rails-presentation" "$WORK/app"
before="$(cd "$WORK/app" && find . -type f | sort | xargs shasum)"

"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out" || fail "migrate exited $?"
MANIFEST="$WORK/out/MIGRATION.manifest.json"
[[ -f "$MANIFEST" ]] || fail "no manifest"
listing="$(cd "$WORK/out" && find . -type f | sort | tr '\n' ' ')"
[[ "$listing" == "./MIGRATION.manifest.json ./MIGRATION.md " ]] || fail "Stage 1 must write only the two artifacts, got: $listing"

after="$(cd "$WORK/app" && find . -type f | sort | xargs shasum)"
[[ "$before" == "$after" ]] || fail "source tree modified"

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
have_finding 'RAILS_TEMPLATE_PARSE_ERROR.app/views/pages/broken%2Ehtml%2Eerb.L2'
have_finding 'RAILS_ROUTE_HELPER_UNKNOWN.app/views/pages/links%2Ehtml%2Eerb.L1C5'
# linked.html.erb is an ordinary static view HERE; it is the third run below
# that makes the templates op refuse it. Pinning zero findings for it in this
# run is what proves that run's finding comes from the refusal and not from
# the file's own content.
linked_findings=$(jq '[.findings[] | select(.source.file == "app/views/pages/linked.html.erb")] | length' "$MANIFEST")
[[ "$linked_findings" == "0" ]] || fail "linked.html.erb is clean in the primary run, got $linked_findings findings"

# The clean page raises NO finding; the Haml page raises none either (its
# blocker already exists and it was never sent to the templates op).
about_count=$(jq '[.findings[] | select(.source.file == "app/views/pages/about.html.erb")] | length' "$MANIFEST")
[[ "$about_count" == "0" ]] || fail "about.html.erb should be clean, got $about_count findings"
haml_count=$(jq '[.findings[] | select(.source.file | endswith(".haml"))] | length' "$MANIFEST")
[[ "$haml_count" == "0" ]] || fail "haml must not reach the templates op"
jq -e '.blockers[] | select(.code == "RAILS_TEMPLATE_ENGINE_UNSUPPORTED")' "$MANIFEST" >/dev/null || fail "haml blocker missing"

# Findings are not blockers: the exit code and --strict are unchanged by them.
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out2" >/dev/null || fail "second run failed"
cmp "$MANIFEST" "$WORK/out2/MIGRATION.manifest.json" || fail "manifest not deterministic"

# Every finding has the wire shape and a choices list drawn from the fixed vocabulary.
bad=$(jq -r '.findings[] | select((.id|type) != "string" or (.choices|length) == 0 or (.choices - ["island","spa","backend","retain","blocked"] | length) != 0) | .id' "$MANIFEST")
[[ -z "$bad" ]] || fail "malformed findings: $bad"

# Schema validation of the real instance.
[[ -x "$REPO/zig-out/bin/rails_manifest_validate" ]] || zig build rails-manifest-validate || fail "validator build"
"$REPO/zig-out/bin/rails_manifest_validate" "$REPO/contract/rails-presentation.v1.schema.json" "$MANIFEST" || fail "manifest fails schema"

grep -q '^## Findings' "$WORK/out/MIGRATION.md" || fail "MIGRATION.md lacks a Findings section"

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
ZIGAPAGOS_RUBY="$WORK/ruby-wrapper.sh" "$ZIGAPAGOS" migrate "$WORK/app3" --from rails --target "$WORK/out3" >/dev/null || fail "third run failed"
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

# --- R16: a locale file that will not load (RAILS_I18N_LOCALE_UNREADABLE) ---
# `RailsI18n.load` SKIPS a `config/locales/*` file it cannot parse and carries
# on, so a broken en.yml leaves an EMPTY translation table and every `t()` key
# in the app comes back missing. Without the blocker the manifest reports N
# confident RAILS_I18N_UNRESOLVED findings and no cause at all. Again its own
# copy and its own run, so the primary run's determinism is untouched.
cp -R "$REPO/tests/migrate/rails-presentation" "$WORK/app4"
printf 'en:\n\tbroken: [unclosed\n' > "$WORK/app4/config/locales/en.yml"
"$ZIGAPAGOS" migrate "$WORK/app4" --from rails --target "$WORK/out4" >/dev/null || fail "fourth run failed"
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
echo "PASS: tests/migrate/rails-presentation.sh"
