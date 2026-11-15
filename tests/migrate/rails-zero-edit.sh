#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/app"
mkdir -p "$APP/config" "$APP/app/controllers" "$APP/app/views/layouts" "$APP/app/views/welcome"
printf 'source "https://rubygems.org"\ngem "rails"\n' > "$APP/Gemfile"
printf 'class Application < Rails::Application; end\n' > "$APP/config/application.rb"
printf 'Rails.application.routes.draw do\n root "welcome#show"\n get "about", to: "welcome#about"\nend\n' > "$APP/config/routes.rb"
printf 'class ApplicationController < ActionController::Base; end\n' > "$APP/app/controllers/application_controller.rb"
printf 'class WelcomeController < ApplicationController\n def show; end\n def about; end\nend\n' > "$APP/app/controllers/welcome_controller.rb"
printf '<p>about</p>\n' > "$APP/app/views/welcome/about.html.erb"
failed=0
for cause in missing-root void-view void-layout; do
  rm -f "$APP/app/views/welcome/show.html.erb" "$APP/app/views/welcome/show.html.slim"
  printf '<html><body><%%= yield %%></body></html>\n' > "$APP/app/views/layouts/application.html.erb"
  case "$cause" in
    missing-root) printf 'p hi\n' > "$APP/app/views/welcome/show.html.slim"; expected=3 ;;
    void-view) printf '<p>hi<br/>there</p>\n' > "$APP/app/views/welcome/show.html.erb"; expected=0 ;;
    void-layout)
      printf '<p>hi</p>\n' > "$APP/app/views/welcome/show.html.erb"
      printf '<html><body><hr /><img alt="x" src="/logo.png" /><%%= yield %%></body></html>\n' > "$APP/app/views/layouts/application.html.erb"
      expected=0 ;;
  esac
  rc=0
  "$ZIGAPAGOS" migrate "$APP" --from rails --target "$WORK/$cause" || rc=$?
  [[ $rc == "$expected" ]] || { echo "FAIL $cause migrate RC $rc (expected $expected)"; failed=1; }
  if ! (cd "$WORK/$cause" && ZIGAPAGOS_BIN="$ZIGAPAGOS" bash build.sh); then
    echo "FAIL $cause zero-edit release"
    failed=1
  fi
done
# A postfix control and its enclosed output call share real source
# coordinates, but both findings must reach the handoff and their decisions.
for modifier in if unless; do
  printf '<html><body><%%= yield %%></body></html>\n' > "$APP/app/views/layouts/application.html.erb"
  printf '<%%= foo(1) do %%>a<%% end %s ok %%>\n' "$modifier" > "$APP/app/views/welcome/show.html.erb"
  target="$WORK/modifier-$modifier"
  rc=0
  "$ZIGAPAGOS" migrate "$APP" --from rails --target "$target" || rc=$?
  [[ $rc == 3 ]] || { echo "FAIL postfix $modifier initial RC $rc"; failed=1; }
  control=$(jq -r '.findings[] | select(.code == "RAILS_TEMPLATE_CONTROL_FLOW") | .id' "$target/MIGRATION.manifest.json")
  helper=$(jq -r '.findings[] | select(.code == "RAILS_HELPER_UNKNOWN") | .id' "$target/MIGRATION.manifest.json")
  jq -e --arg control "$control" --arg helper "$helper" '.routes[] | select(.route_id == "GET /") | (.findings | index($control) != null and index($helper) != null)' "$target/MIGRATION.handoff.json" >/dev/null || { echo "FAIL postfix $modifier finding missing from handoff"; failed=1; }
  jq -n --arg id "$control" '{schema: "zigapagos.rails-decisions/1", decisions: [{id: $id, choice: "blocked", rationale: "do not ship this condition"}]}' > "$WORK/control-decisions.json"
  rc=0
  "$ZIGAPAGOS" migrate "$APP" --from rails --target "$target-answered" --decisions "$WORK/control-decisions.json" || rc=$?
  [[ $rc == 0 ]] || { echo "FAIL postfix $modifier control decision ignored (RC $rc)"; failed=1; }
  jq -e --arg control "$control" '.complete and any(.routes[]; .route_id == "GET /" and .status == "blocked" and .decision.id == $control)' "$target-answered/MIGRATION.handoff.json" >/dev/null || { echo "FAIL postfix $modifier control decision did not block its route"; failed=1; }
done
# A wholesale templates failure must still be answerable. Keep the other
# two sidecar operations real so the same routes are recovered.
cat > "$WORK/ruby-wrapper" <<'RUBY'
#!/usr/bin/env ruby
require "json"
request = STDIN.gets
if JSON.parse(request)["op"] == "templates"
  if ENV.fetch("UNAVAILABLE_TEMPLATE", "all") == "all"
    puts JSON.generate({ok: false, error: "template service unavailable"})
  else
    IO.popen([ENV.fetch("REAL_RUBY"), *ARGV], "r+") do |child|
      child.write(request)
      child.close_write
      response = JSON.parse(child.read)
      response.fetch("templates").each do |template|
        layout = template.fetch("path").include?("/layouts/")
        if layout == (ENV.fetch("UNAVAILABLE_TEMPLATE") == "layout")
          template["unreadable"] = "test read failure"
          template["nodes"] = []
        end
      end
      puts JSON.generate(response)
    end
  end
else
  IO.popen([ENV.fetch("REAL_RUBY"), *ARGV], "r+") do |child|
    child.write(request)
    child.close_write
    STDOUT.write(child.read)
  end
end
RUBY
chmod +x "$WORK/ruby-wrapper"
export REAL_RUBY="$(command -v ruby)"
export ZIGAPAGOS_RUBY="$WORK/ruby-wrapper"
printf '<p>hi</p>\n' > "$APP/app/views/welcome/show.html.erb"
rc=0
"$ZIGAPAGOS" migrate "$APP" --from rails --target "$WORK/unavailable" || rc=$?
[[ $rc == 3 ]] || { echo "FAIL unavailable migrate RC $rc"; failed=1; }
jq -e 'all(.routes[]; .status == "open" and (.findings | length > 0))' "$WORK/unavailable/MIGRATION.handoff.json" >/dev/null || failed=1
jq '{schema: "zigapagos.rails-decisions/1", decisions: [.findings[] | {id, choice: "blocked", rationale: "keep migration blocked until templates are available"}]}' "$WORK/unavailable/MIGRATION.manifest.json" > "$WORK/decisions.json"
rc=0
"$ZIGAPAGOS" migrate "$APP" --from rails --target "$WORK/answered" --decisions "$WORK/decisions.json" || rc=$?
[[ $rc == 0 ]] || { echo "FAIL unavailable findings cannot settle routes (RC $rc)"; failed=1; }
jq -e '.complete and all(.routes[]; .status == "blocked")' "$WORK/answered/MIGRATION.handoff.json" >/dev/null || failed=1
# A retained/blocked root must release successfully without publishing /.
unset ZIGAPAGOS_RUBY
printf '<%%= unknown_helper %%>\n' > "$APP/app/views/welcome/show.html.erb"
"$ZIGAPAGOS" migrate "$APP" --from rails --target "$WORK/root-open" || [[ $? == 3 ]]
for choice in retain blocked; do
  jq --arg choice "$choice" '{schema: "zigapagos.rails-decisions/1", decisions: [.findings[] | {id, choice: $choice, rationale: "root must not ship"}]}' "$WORK/root-open/MIGRATION.manifest.json" > "$WORK/root-decisions.json"
  target="$WORK/root-$choice"
  "$ZIGAPAGOS" migrate "$APP" --from rails --target "$target" --decisions "$WORK/root-decisions.json"
  status="$choice"; [[ "$choice" != retain ]] || status=retained
  jq -e --arg status "$status" '.complete and any(.routes[]; .route_id == "GET /" and .status == $status and (.artifacts | length == 0))' "$target/MIGRATION.handoff.json" >/dev/null || failed=1
  [[ -f "$target/content/index.smd" ]] || failed=1
  if (cd "$target" && ZIGAPAGOS_BIN="$ZIGAPAGOS" bash build.sh); then
    [[ ! -e "$target/zig-out/site/index.html" ]] || { echo "FAIL $choice root published at /"; failed=1; }
    [[ -f "$target/zig-out/site/about/index.html" ]] || { echo "FAIL $choice release lost /about"; failed=1; }
  else
    echo "FAIL $choice root release"; failed=1
  fi
done
# Unreadable views AND layouts on a dynamic SPA must stay answerable.
printf 'Rails.application.routes.draw do\n get "posts/:id", to: "welcome#show"\nend\n' > "$APP/config/routes.rb"
printf '<p>post</p>\n' > "$APP/app/views/welcome/show.html.erb"
export ZIGAPAGOS_RUBY="$WORK/ruby-wrapper"
for unavailable in view layout all; do
  export UNAVAILABLE_TEMPLATE="$unavailable"
  target="$WORK/spa-$unavailable"
  "$ZIGAPAGOS" migrate "$APP" --from rails --target "$target" || [[ $? == 3 ]]
  for choice in unanswered retain blocked; do
    jq --arg choice "$choice" '{schema: "zigapagos.rails-decisions/1", decisions: [.findings[] | if .code == "RAILS_ROUTE_DYNAMIC_SEGMENT" then {id, choice: "spa", rationale: "port the dynamic route"} elif .code == "RAILS_TEMPLATE_UNSCANNED" and $choice != "unanswered" then {id, choice: $choice, rationale: "template unavailable"} else empty end]}' "$target/MIGRATION.manifest.json" > "$WORK/spa-decisions.json"
    answered="$target-$choice"
    rc=0
    "$ZIGAPAGOS" migrate "$APP" --from rails --target "$answered" --decisions "$WORK/spa-decisions.json" || rc=$?
    expected=0; status="$choice"
    if [[ "$choice" == unanswered ]]; then expected=3; status=open; fi
    [[ "$choice" != retain ]] || status=retained
    [[ $rc == "$expected" ]] || { echo "FAIL SPA $unavailable $choice RC $rc"; failed=1; }
    jq -e --arg status "$status" 'any(.routes[]; .route_id == "GET /posts/:id" and .status == $status and (.findings | length > 0))' "$answered/MIGRATION.handoff.json" >/dev/null || { echo "FAIL SPA $unavailable $choice status/findings"; failed=1; }
    [[ ! -e "$answered/spa/posts.spa.tsx" ]] || { echo "FAIL SPA $unavailable $choice emitted placeholder"; failed=1; }
  done
done
exit "$failed"
