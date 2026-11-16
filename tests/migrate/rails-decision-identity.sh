#!/usr/bin/env bash
# Saved decisions must survive unrelated insertions and become stale on edits.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/app"
mkdir -p "$APP/config" "$APP/app/controllers" "$APP/app/views/pages"
printf 'gem "rails"\n' > "$APP/Gemfile"
printf 'class Application < Rails::Application; end\n' > "$APP/config/application.rb"
printf 'Rails.application.routes.draw do\n root "pages#show"\nend\n' > "$APP/config/routes.rb"
printf 'class PagesController < ActionController::Base\n def show; end\nend\n' > "$APP/app/controllers/pages_controller.rb"
# Exercise real discovery/conversion while simulating the sidecar's invalid
# coordinates. The template source, helper kinds and all other operations stay real.
cat > "$WORK/ruby-wrapper" <<'RUBY'
#!/usr/bin/env ruby
require "json"
request = STDIN.gets
IO.popen([ENV.fetch("REAL_RUBY"), *ARGV], "r+") do |child|
  child.write(request)
  child.close_write
  response = JSON.parse(child.read)
  if JSON.parse(request)["op"] == "templates"
    response.fetch("templates").each do |template|
      template.fetch("nodes").each do |node|
        next unless node["t"] == "code"
        node["line"] = 0
        node["col"] = 0
      end
    end
  end
  puts JSON.generate(response)
end
RUBY
chmod +x "$WORK/ruby-wrapper"
export REAL_RUBY="$(command -v ruby)"
export ZIGAPAGOS_RUBY="$WORK/ruby-wrapper"
run_open() {
  local rc=0
  "$ZIGAPAGOS" migrate "$APP" --from rails --target "$1" "${@:2}" || rc=$?
  [[ "$rc" == 3 ]] || { echo "FAIL expected open migration, got $rc"; exit 1; }
}
printf '<%%= foo(1) %%><%%= bar(2) %%>' > "$APP/app/views/pages/show.html.erb"
run_open "$WORK/before"
bar=$(jq -er '.findings[] | select(.message | contains("bar")) | .id' "$WORK/before/MIGRATION.manifest.json")
jq -n --arg id "$bar" '{schema:"zigapagos.rails-decisions/1", decisions:[{id:$id, choice:"blocked", rationale:"bar must not ship"}]}' > "$WORK/decisions.json"
printf '<%%= added(3) %%><%%= foo(1) %%><%%= bar(2) %%>' > "$APP/app/views/pages/show.html.erb"
"$ZIGAPAGOS" migrate "$APP" --from rails --target "$WORK/inserted" --decisions "$WORK/decisions.json"
jq -e --arg id "$bar" 'any(.findings[]; (.message | contains("bar")) and .id == $id) and all(.findings[]; if (.message | contains("foo")) then .id != $id else true end)' "$WORK/inserted/MIGRATION.manifest.json" >/dev/null
# The route's acknowledgement still points to bar, not the helper now at
# bar's old ordinal. The emitted manifest above identifies that exact fragment.
jq -e --arg id "$bar" 'any(.routes[]; .status == "blocked" and .decision.id == $id)' "$WORK/inserted/MIGRATION.handoff.json" >/dev/null
printf '<%%= added(3) %%><%%= foo(1) %%><%%= changed(2) %%>' > "$APP/app/views/pages/show.html.erb"
run_open "$WORK/edited" --decisions "$WORK/decisions.json"
jq -e 'any(.blockers[]; .code == "RAILS_DECISION_STALE")' "$WORK/edited/MIGRATION.manifest.json" >/dev/null
echo 'PASS saved positionless decisions stay on their source fragment'

# Real shared coordinates: only the closing postfix predicate changes.
unset ZIGAPAGOS_RUBY
for modifier in if unless; do
  printf '<%%= foo(1) do %%>a<%% end %s ok %%>' "$modifier" > "$APP/app/views/pages/show.html.erb"
  run_open "$WORK/postfix-$modifier-before"
  control=$(jq -er '.findings[] | select(.code == "RAILS_TEMPLATE_CONTROL_FLOW") | .id' "$WORK/postfix-$modifier-before/MIGRATION.manifest.json")
  jq -n --arg id "$control" '{schema:"zigapagos.rails-decisions/1", decisions:[{id:$id, choice:"blocked", rationale:"condition reviewed"}]}' > "$WORK/postfix-decisions.json"
  "$ZIGAPAGOS" migrate "$APP" --from rails --target "$WORK/postfix-$modifier-accepted" --decisions "$WORK/postfix-decisions.json"
  printf '<%%= foo(1) do %%>a<%% end %s changed %%>' "$modifier" > "$APP/app/views/pages/show.html.erb"
  run_open "$WORK/postfix-$modifier-edited" --decisions "$WORK/postfix-decisions.json"
  jq -e 'any(.blockers[]; .code == "RAILS_DECISION_STALE")' "$WORK/postfix-$modifier-edited/MIGRATION.manifest.json" >/dev/null
done
echo 'PASS saved shared-position decisions become stale on postfix predicate edits'
