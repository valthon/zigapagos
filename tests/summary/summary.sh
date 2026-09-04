#!/usr/bin/env bash
# Regression test: `zigapagos release --summary` (issue #42) must report what
# the build ACTUALLY emitted.
#
# The cost that produced the issue was a landing page describing a deploy tree
# no build emits -- written from the build's OPTIONS rather than from its
# OUTPUT, because the only way to see the output was `find zig-out/site`. A
# summary is therefore only worth having if it cannot repeat that mistake, so
# the assertions here are deliberately not "the report mentions pages":
#
#   (1) the flag is accepted and prints a summary block on STDOUT (not stderr,
#       where the build log and the pruned-asset warning live),
#   (2) FORWARD: every path the summary prints exists under the output dir,
#   (3) REVERSE (whole tree, not a spot check): the set of paths the summary
#       prints is EXACTLY the set of files in the output tree. This is the
#       assertion that makes the report trustworthy -- an artifact the binary
#       writes but forgets to record fails just as loudly as one it invents,
#       which is what keeps the one category that cannot record at its write
#       (page assets, installed on the worker threads) honest,
#   (4) each category's printed count equals the number of paths under it,
#   (5) the categories are the real ones for this fixture: an alias, an
#       alternative, a page asset, a site asset, SPA shells, a routing manifest
#       and the 404 fallback are each attributed correctly,
#   (6) an UNREFERENCED page asset -- pruned from the output tree -- is absent,
#       so the summary reports what was emitted rather than what exists in the
#       source tree,
#   (7) the report is deterministic: two identical builds print byte-identical
#       summaries (site and page assets are enumerated from hash maps, whose
#       order varies between runs),
#   (8) a build WITHOUT the flag prints no summary at all,
#   (9) a build WITH rendering errors refuses on the SAME stream the report
#       would have used. The refusal started life as a `std.debug.print`, which
#       always targets stderr, so `--summary`'s stream depended on the build's
#       OUTCOME: `zigapagos release --summary >inventory.txt` left an empty file
#       on exactly the run where the reader needs to know why. A caller cannot
#       redirect conditionally on a result it has not seen yet, so the stream
#       has to be a property of the flag, not of the build.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

BUN="$(command -v bun || true)"
[[ -n "$BUN" ]] || { echo "FAIL: bun not found on PATH -- required to spawn the island sidecar for the SPA legs"; exit 1; }
if [[ ! -d "$REPO/runtime/node_modules" ]]; then
  echo "runtime/node_modules missing; running 'bun install --frozen-lockfile'..."
  ( cd "$REPO/runtime" && bun install --frozen-lockfile ) \
    || { echo "FAIL: bun install --frozen-lockfile failed in runtime/"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

SITE="$WORK/site"
mkdir -p "$SITE/content/docs/overview" "$SITE/layouts/templates" "$SITE/assets" \
         "$SITE/app" "$SITE/node_modules/@z"
ln -s "$REPO/runtime" "$SITE/node_modules/@z/runtime"

cat >"$SITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Summary Fixture",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .static_assets = ["style.css"],
}
EOF

printf 'body { color: #111; }\n' >"$SITE/assets/style.css"

cat >"$SITE/layouts/templates/base.shtml" <<'EOF'
<!DOCTYPE html>
<html>
<head><title :text="$site.title"></title></head>
<body id="body">
  <super>
</body>
</html>
EOF

cat >"$SITE/layouts/page.shtml" <<'EOF'
<extend template="base.shtml">
<body id="body">
  <div :html="$page.content()"></div>
</body>
EOF

cat >"$SITE/layouts/rss.shtml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss :html="$page.content()"></rss>
EOF

cat >"$SITE/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "page.shtml",
---
Home page, linking to [docs]($link.sub('docs')).
EOF

cat >"$SITE/content/docs/index.smd" <<'EOF'
---
.title = "Docs",
.layout = "page.shtml",
---
Docs index, linking to [overview]($link.sub('overview')).
EOF

# One page carrying every per-page emission shape at once: an alias, an
# alternative output, a REFERENCED page asset and an UNREFERENCED one.
cat >"$SITE/content/docs/overview/index.smd" <<'EOF'
---
.title = "Overview",
.layout = "page.shtml",
.aliases = ["/overview.html"],
.alternatives = [{
    .name = "rss",
    .output = "index.xml",
    .layout = "rss.shtml",
}],
---
Overview content, referencing []($image.asset('diagram.svg')).
EOF
printf '<svg xmlns="http://www.w3.org/2000/svg"></svg>' >"$SITE/content/docs/overview/diagram.svg"
printf 'not-referenced' >"$SITE/content/docs/overview/unused.png"

cat >"$SITE/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "@z/runtime",
    "moduleResolution": "bundler",
    "paths": {
      "react/jsx-runtime": ["./node_modules/@z/runtime/src/jsx-runtime.ts"],
      "react/jsx-dev-runtime": ["./node_modules/@z/runtime/src/jsx-runtime.ts"]
    }
  }
}
JSON

cat >"$SITE/app/app.spa.tsx" <<'TSX'
import { Router } from "@z/runtime";

export const spa = { base: "/app", title: "Summary SPA" };

function Home() { return <div>home</div>; }
function About() { return <div>about</div>; }

export const routes = [
  { path: "/", component: Home },
  { path: "/about", component: About },
];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
TSX

# This suite inventories root.run's outputs, not the CLI's self-bundling and
# host-config passes. Register minimal external client assets so the SPA shell
# is runnable without enabling those additional emitters.
printf 'export default function App(){}\n' >"$WORK/app.js"
printf 'export function mountSpa(){}\n' >"$WORK/runtime.js"

# stdout and stderr are captured SEPARATELY: which stream the summary lands on
# is part of what this test pins (the build log and the pruned-asset warning go
# to stderr; the report a user asked for by name goes to stdout, so it can be
# parsed and diffed).
build() { # $1 = tag, remaining = extra release args
  local tag="$1"; shift
  set +e
  { ( cd "$SITE" && "$ZIGAPAGOS" release "--output=$WORK/$tag-out" --force \
        "--bun=$BUN" "--island-sidecar=$REPO/runtime/sidecar/render.ts" \
        --island-src-dir=. "--spa=app/app.spa.tsx|/app" \
        --build-asset=spa-app "$WORK/app.js" --install-always=spa/app.js \
        --build-asset=spa-runtime "$WORK/runtime.js" --install-always=zigapagos-runtime.js "$@" \
    ) >"$WORK/$tag.out" 2>"$WORK/$tag.err"; } 2>/dev/null
  echo $? >"$WORK/$tag.rc"
  set -e
}

# --- (1) the flag is accepted and the report lands on stdout -----------------
build s1 --summary
[[ "$(cat "$WORK/s1.rc")" -eq 0 ]] || {
  echo "--- stderr ---"; sed -n '1,40p' "$WORK/s1.err"
  fail "(1) 'zigapagos release --summary' failed"
}
OUT="$WORK/s1-out"
grep -q '^build summary: ' "$WORK/s1.out" || {
  echo "--- stdout ---"; cat "$WORK/s1.out"
  fail "(1) no 'build summary:' header on STDOUT"
}
grep -q '^build summary: ' "$WORK/s1.err" \
  && { echo "--- stderr ---"; sed -n '1,40p' "$WORK/s1.err"; fail "(1) the summary was written to stderr as well"; }
echo "PASS (1): --summary prints a summary block on stdout"

# Paths are the 4-space-indented lines; category headings are the 2-space ones.
mapfile -t PRINTED < <(sed -n 's/^    \(.*\)$/\1/p' "$WORK/s1.out")
[[ "${#PRINTED[@]}" -gt 0 ]] || { cat "$WORK/s1.out"; fail "parsed zero paths out of the summary"; }

# --- (2) FORWARD: every printed path exists ---------------------------------
for p in "${PRINTED[@]}"; do
  [[ -f "$OUT/$p" ]] || { cat "$WORK/s1.out"; fail "(2) FORWARD: summary printed '$p' but no such file exists under the output dir"; }
done
echo "PASS (2): FORWARD -- every path the summary printed exists on disk"

# --- (3) REVERSE: the printed set IS the output tree ------------------------
# `find | sed`, not `find -printf '%P\n'`: `-printf` is a GNU extension and BSD
# find (macOS) rejects it outright, so the whole REVERSE half of this test would
# die on a contributor's mac rather than report anything. `sed 's|^\./||'`
# reproduces `%P` exactly -- strip the starting point, which here is always the
# literal `.` this subshell cd'd to.
( cd "$OUT" && find . -type f | sed 's|^\./||' | sort ) >"$WORK/tree.txt"
printf '%s\n' "${PRINTED[@]}" | sort -u >"$WORK/printed.txt"
if ! diff -u "$WORK/tree.txt" "$WORK/printed.txt" >"$WORK/tree.diff"; then
  echo "--- diff (left: files on disk, right: paths the summary printed) ---"
  cat "$WORK/tree.diff"
  fail "(3) REVERSE: the summary's path set is not exactly the emitted tree"
fi
echo "PASS (3): REVERSE -- the summary's path set is exactly the emitted tree ($(wc -l <"$WORK/tree.txt") files)"

# --- (4) each category's printed count matches its path count ---------------
python3 - "$WORK/s1.out" <<'PY' || fail "(4) a category count did not match the number of paths under it"
import re, sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if l.startswith("build summary: "))
total_claimed = int(re.match(r"build summary: (\d+) file\(s\)", lines[start]).group(1))
cat, claimed, seen, total_seen, ok = None, 0, 0, 0, True
def close():
    global ok
    if cat is not None and claimed != seen:
        print(f"category '{cat}': header says {claimed}, {seen} path(s) printed")
        ok = False
for l in lines[start + 1:]:
    m = re.match(r"^  (.+) \((\d+)\):$", l)
    if m:
        close()
        cat, claimed, seen = m.group(1), int(m.group(2)), 0
        continue
    if l.startswith("    "):
        seen += 1
        total_seen += 1
close()
if total_claimed != total_seen:
    print(f"header says {total_claimed} file(s), {total_seen} path(s) printed")
    ok = False
sys.exit(0 if ok else 1)
PY
echo "PASS (4): every category count matches the paths printed under it"

# --- (5) categories are attributed correctly --------------------------------
# `<heading>|<path>` for each printed path, so a path in the WRONG group fails.
python3 - "$WORK/s1.out" >"$WORK/pairs.txt" <<'PY'
import re, sys
cat = None
for l in open(sys.argv[1]).read().splitlines():
    m = re.match(r"^  (.+) \((\d+)\):$", l)
    if m:
        cat = m.group(1)
        continue
    if l.startswith("    ") and cat:
        print(f"{cat}|{l.strip()}")
PY
want() {
  grep -qxF "$1" "$WORK/pairs.txt" || { echo "--- summary ---"; cat "$WORK/s1.out"; fail "(5) expected '$1' in the summary"; }
}
want "pages|index.html"
want "pages|docs/index.html"
want "pages|docs/overview/index.html"
want "page aliases|overview.html"
want "page alternatives|docs/overview/index.xml"
want "page assets|docs/overview/diagram.svg"
want "site assets|style.css"
want "SPA shells|app/index.html"
want "SPA shells|app/about/index.html"
want "SPA routing manifests|app/routing-manifest.json"
want "SPA 404 fallback|404.html"
echo "PASS (5): every emitted artifact is attributed to the right category"

# --- (6) a pruned page asset is NOT reported --------------------------------
grep -q 'unused\.png' "$WORK/s1.out" \
  && { cat "$WORK/s1.out"; fail "(6) an unreferenced page asset (never installed) was listed as emitted"; }
[[ ! -f "$OUT/docs/overview/unused.png" ]] || fail "(6) fixture assumption broken: the unreferenced asset WAS installed"
echo "PASS (6): an unreferenced (pruned) page asset is not reported as emitted"

# --- (7) deterministic across builds ----------------------------------------
build s2 --summary
[[ "$(cat "$WORK/s2.rc")" -eq 0 ]] || { sed -n '1,40p' "$WORK/s2.err"; fail "(7) the second build failed"; }
# Compare only the summary block: the second build writes to its own output dir,
# which is named in the header line.
sed -n '/^build summary: /,$ p' "$WORK/s1.out" | tail -n +2 >"$WORK/s1.block"
sed -n '/^build summary: /,$ p' "$WORK/s2.out" | tail -n +2 >"$WORK/s2.block"
diff -u "$WORK/s1.block" "$WORK/s2.block" >"$WORK/block.diff" || {
  cat "$WORK/block.diff"; fail "(7) two identical builds printed different summaries"
}
echo "PASS (7): the report is byte-identical across two identical builds"

# --- (8) no flag, no summary ------------------------------------------------
build plain
[[ "$(cat "$WORK/plain.rc")" -eq 0 ]] || { sed -n '1,40p' "$WORK/plain.err"; fail "(8) the no-flag build failed"; }
grep -q 'build summary' "$WORK/plain.out" "$WORK/plain.err" \
  && { fail "(8) a build without --summary printed a summary anyway"; }
[[ ! -s "$WORK/plain.out" ]] || {
  echo "--- stdout ---"; cat "$WORK/plain.out"
  fail "(8) a build without --summary wrote to stdout"
}
echo "PASS (8): without the flag nothing is printed"

# --- (9) a failed build refuses on stdout, not stderr ------------------------
# A SEPARATE fixture, deliberately: the site above must keep building clean for
# legs (1)-(8), and the error has to be a RENDERING error rather than an
# analysis one -- `run` returns at `any_prerendering_error` long before the
# summary block, so a bad `$link.page()` would prove nothing about this branch.
# A page that mounts an `<island>` with no sidecar configured is the cheapest
# render-time failure there is: `worker.zig` logs it, sets
# `any_rendering_error`, and carries on, which is exactly the state the refusal
# exists for.
ERRSITE="$WORK/errsite"
mkdir -p "$ERRSITE/content" "$ERRSITE/layouts/templates" "$ERRSITE/assets"
cat >"$ERRSITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Rendering-Error Fixture",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
}
EOF
cat >"$ERRSITE/layouts/templates/base.shtml" <<'EOF'
<!DOCTYPE html>
<html><head><title :text="$site.title"></title></head>
<body id="body"><super></body></html>
EOF
cat >"$ERRSITE/layouts/page.shtml" <<'EOF'
<extend template="base.shtml">
<body id="body">
  <island src="Counter.island.tsx"></island>
  <div :html="$page.content()"></div>
</body>
EOF
cat >"$ERRSITE/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "page.shtml",
---
Home.
EOF
set +e
# No --bun / --island-sidecar / --island-src-dir: that is what makes the island
# unrenderable.
( cd "$ERRSITE" && "$ZIGAPAGOS" release "--output=$WORK/err-out" --force --summary \
  ) >"$WORK/err.out" 2>"$WORK/err.err"
ERR_RC=$?
set -e
[[ "$ERR_RC" -ne 0 ]] || {
  echo "--- stderr ---"; sed -n '1,40p' "$WORK/err.err"
  fail "(9) fixture assumption broken: the erroring build exited 0, so nothing was refused"
}
grep -q 'island rendering error' "$WORK/err.err" || {
  echo "--- stderr ---"; sed -n '1,40p' "$WORK/err.err"
  fail "(9) fixture assumption broken: the build failed for some reason other than the island render"
}
grep -q '^summary: not printed' "$WORK/err.out" || {
  echo "--- stdout ($(wc -c <"$WORK/err.out") bytes) ---"; cat "$WORK/err.out"
  echo "--- stderr ---"; sed -n '1,40p' "$WORK/err.err"
  fail "(9) the refusal is not on stdout -- --summary's stream depends on the build's outcome"
}
grep -q 'summary: not printed' "$WORK/err.err" && {
  echo "--- stderr ---"; sed -n '1,40p' "$WORK/err.err"
  fail "(9) the refusal was ALSO written to stderr -- it must appear exactly once, on stdout"
}
# The refusal must not masquerade as a report: a script that greps the header to
# find the inventory has to read a refusal as "no inventory", not "empty one".
grep -q '^build summary: ' "$WORK/err.out" && {
  cat "$WORK/err.out"; fail "(9) an incomplete output tree was inventoried anyway"
}
echo "PASS (9): a build with rendering errors refuses on stdout, the same stream the report uses"

echo "PASS: --summary reports exactly the artifacts the build emitted"
