#!/usr/bin/env bash
# A native SPA must build from the TOOLCHAIN-FREE path — the one an `npm i
# zigapagos` install takes, where `ZIGAPAGOS_RUNTIME_DIR` names the runtime tree
# shipped beside the binary and there is no build graph at all.
#
# WHAT THIS PINS, AND WHY IT IS NOT A "does it exit 0" TEST. Before the CLI could
# bundle a SPA itself, this exact invocation SUCCEEDED: the prerender pass wrote
# `public/app/index.html` and its routing manifest and exited 0, while nothing
# ever produced the `/spa/app.js` that shell imports. Every file in the output
# tree looked right; the SPA 404'd on its own entry script in the browser. A test
# that only checked the exit status — or only that some `spa/` directory
# existed — would have passed in that state.
#
# So the assertion is RESOLUTION, not presence: every absolute `…/*.js` URL the
# emitted shell names (the entry `modulepreload`, the inline `import`, the import
# map's `@z/runtime` target, the runtime `<script src>`, the lazy route's chunk
# preload) is resolved against the output tree and the file must be there. That
# is the property the browser actually needs, and it is checked for the whole set
# rather than for `/spa/<name>.js` alone, because the same class of defect
# (something referenced that nothing installs) has now appeared for the entry
# bundle, the shared runtime and the sliced runtime in turn.
#
# The fixture declares a LAZY route on purpose. A no-lazy SPA bundles to a single
# entry file, which would prove nothing about the part that made this hard: a
# code-split build writes a DIRECTORY of content-hashed chunks whose names are
# unknown until bun has run, and installing that directory is the part this path
# once refused to do at all.
#
# There is deliberately NO `node_modules/@z/runtime` symlink here, unlike the
# other tests/spa fixtures. That symlink is what a repo checkout has and an npm
# consumer does not, and removing it is what makes this exercise the real
# resolution path: the SSR sidecar and the SPA bundler both have to answer the
# bare `@z/runtime` specifier out of the shipped tree themselves.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"

fail() { echo "FAIL: $*"; exit 1; }

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || fail "zig build failed"
fi

command -v bun >/dev/null || fail "bun not found on PATH -- required for the sidecar and the bundler"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SITE="$WORK/site"
OUT="$WORK/out"
mkdir -p "$SITE/app/views"
cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$SITE/"
cp tests/rendering/simple/zigapagos.ziggy "$SITE/"

# jsxImportSource drives bun's JSX transform to `@z/runtime/jsx-runtime`, which
# both the bundler (kept external) and the sidecar (module override) answer. No
# `paths` entry and no node_modules: nothing here resolves the name from disk.
cat > "$SITE/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "@z/runtime",
    "moduleResolution": "bundler"
  }
}
JSON

cat > "$SITE/app/views/Heavy.tsx" <<'TSX'
// Code-split into its own chunk by the `lazy()` call in app.spa.tsx.
export default function Heavy() {
  return <section data-view="heavy">NPM-CLI-HEAVY-CHUNK</section>;
}
TSX

cat > "$SITE/app/app.spa.tsx" <<'TSX'
import { Router, lazy } from "@z/runtime";

export const spa = { base: "/app", title: "npm-cli spa", head: [] };

function Home() { return <div data-view="home">home</div>; }
// A lazy route's component cannot render until its chunk loads, so the build
// requires a skeleton for SSR and the first client render.
function HeavySkeleton() { return <div data-view="heavy-skeleton">loading</div>; }

export const routes = [
  { path: "/", component: Home },
  { path: "/heavy", component: lazy(() => import("./views/Heavy.tsx")), skeleton: HeavySkeleton },
];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
TSX

# The npm invocation, exactly: the runtime dir in the environment and NOT one
# --island-sidecar / --island-bundle-driver / --spa-chunks / --spa-slice flag on
# the command line. Everything below has to be derived by the binary.
set +e
( cd "$SITE" && ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime" \
    "$ZIGAPAGOS" release "--output=$OUT" --force "--spa=app/app.spa.tsx|/app" ) \
  > "$WORK/build.log" 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  sed -n '1,60p' "$WORK/build.log"
  fail "the toolchain-free SPA build exited $rc"
fi
echo "ok: built a .spa.tsx with no flags but ZIGAPAGOS_RUNTIME_DIR (exit 0)"

SHELL_HTML="$OUT/app/index.html"
[[ -f "$SHELL_HTML" ]] || fail "no SPA shell was written at app/index.html"

# --- 1. The chunk directory exists and really is SPLIT ----------------------
[[ -d "$OUT/spa" ]] || fail "public/spa/ was not created — the client bundle was never installed"
[[ -f "$OUT/spa/app.js" ]] || fail "public/spa/app.js (the entry chunk) is missing"
heavy_chunks=("$OUT"/spa/Heavy-*.js)
[[ -f "${heavy_chunks[0]}" ]] \
  || fail "no Heavy-<hash>.js chunk in public/spa/ — the lazy route was not code-split, so the directory install is untested"
echo "ok: public/spa/ holds the entry chunk and the lazy route's chunk ($(basename "${heavy_chunks[0]}"))"

# --- 2. EVERY script the shell names resolves on disk -----------------------
# This is the assertion the original defect walked straight through. Every
# absolute `"/…js"` in the shell — modulepreload hrefs, the runtime <script src>,
# the import map's target and the inline `import … from`.
refs="$(grep -o '"/[^"]*\.js"' "$SHELL_HTML" | tr -d '"' | sort -u)"
[[ -n "$refs" ]] || fail "the shell names no .js at all, which cannot be right"
n=0
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  rel="${url#/}"
  [[ -f "$OUT/$rel" ]] \
    || fail "the shell references '$url' but $OUT/$rel does not exist — this is the silent 404"
  n=$((n + 1))
done <<< "$refs"
echo "ok: all $n script URLs in the shell resolve to files in the output tree"

# The entry bundle specifically, by name, so a shell that somehow stopped naming
# it could not make the loop above vacuous.
grep -q '"/spa/app\.js"' "$SHELL_HTML" \
  || fail "the shell does not import /spa/app.js"

# --- 3. The lazy route's shell preloads its chunk, and it exists -------------
# `spa-chunks.json` is what carries the route→chunk map from the bundler to the
# prerender; a shell with no modulepreload here means the map arrived empty,
# which is how this degrades when the bundler cannot import the SPA entry.
HEAVY_SHELL="$OUT/app/heavy/index.html"
[[ -f "$HEAVY_SHELL" ]] || fail "no shell was written for the /heavy route"
preload="$(grep -o 'modulepreload" href="/spa/Heavy-[^"]*\.js"' "$HEAVY_SHELL" | head -1 || true)"
[[ -n "$preload" ]] \
  || fail "the /heavy shell has no modulepreload for its chunk — the route→chunk map from spa-chunks.json is empty"
chunk_url="${preload##*href=\"}"; chunk_url="${chunk_url%\"}"
[[ -f "$OUT/${chunk_url#/}" ]] \
  || fail "the /heavy shell preloads '$chunk_url', which does not exist"
echo "ok: the lazy route's shell preloads its real chunk ($chunk_url)"

# --- 4. The routing manifest agrees with what was emitted -------------------
MANIFEST="$OUT/app/routing-manifest.json"
[[ -f "$MANIFEST" ]] || fail "no routing-manifest.json was written"
node -e '
  const fs = require("node:fs");
  const [manifestPath, out] = process.argv.slice(1);
  const m = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const missing = [];
  const check = (u) => { if (u && u.startsWith("/") && !fs.existsSync(out + u)) missing.push(u); };
  check(m.bundle);
  for (const u of Object.values(m.chunks ?? {})) check(u);
  if (!fs.existsSync(out + "/" + m.fallback.replace(/^\//, ""))) missing.push(m.fallback);
  if (missing.length) {
    console.error("routing-manifest.json names files that do not exist: " + missing.join(", "));
    process.exit(1);
  }
  const chunkCount = Object.keys(m.chunks ?? {}).length;
  if (chunkCount < 1) {
    console.error("routing-manifest.json lists no chunks, but the SPA has a lazy route");
    process.exit(1);
  }
  console.log(`ok: routing-manifest.json bundle + ${chunkCount} chunk entr${chunkCount === 1 ? "y" : "ies"} + fallback all exist on disk`);
' "$MANIFEST" "$OUT" || fail "the routing manifest disagrees with the emitted files"

# --- 5. The runtime the shells actually load --------------------------------
# Either the shared /zigapagos-runtime.js or this SPA's sliced /spa/app-runtime.js
# — whichever the slicer decided. Step 2 already proved the chosen one exists;
# this pins that the DECISION and the emitted files agree, which is the pair the
# slicer's fallback path gets wrong when nothing installs its output.
if grep -q '"/spa/app-runtime\.js"' "$SHELL_HTML"; then
  [[ -f "$OUT/spa/app-runtime.js" ]] || fail "the shell uses the sliced runtime but it was not installed"
  echo "ok: the SPA got a sliced per-deployable runtime, and it is installed"
else
  grep -q '"/zigapagos-runtime\.js"' "$SHELL_HTML" \
    || fail "the shell names neither the sliced nor the shared runtime"
  [[ -f "$OUT/zigapagos-runtime.js" ]] || fail "the shell falls back to the shared runtime but it was not installed"
  [[ ! -f "$OUT/spa/app-runtime.js" ]] \
    || fail "the slicer fell back to the shared runtime, yet a stale sliced runtime was installed"
  echo "ok: the slicer fell back to the shared runtime, and that is what is installed"
fi

# --- 6. …and none of it needed `--spa=` in the first place ------------------
# A `.spa.tsx` the command line does not mention is discovered by the same scan
# that finds island entries, for the reason the island scan exists: `build.zig`'s
# `Spa` list is the enumeration this path has no equivalent of, and a SPA that is
# simply not built says nothing at all. The declared base is left empty, so the
# module's own `spa.base` decides — hence the identical `/app` output below.
OUT2="$WORK/out2"
set +e
( cd "$SITE" && ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime" \
    "$ZIGAPAGOS" release "--output=$OUT2" --force ) > "$WORK/build2.log" 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  sed -n '1,60p' "$WORK/build2.log"
  fail "the discovered-SPA build (no --spa= at all) exited $rc"
fi
[[ -f "$OUT2/app/index.html" ]] \
  || fail "no shell at app/index.html — the .spa.tsx was not discovered"
[[ -f "$OUT2/spa/app.js" ]] \
  || fail "the discovered SPA's entry chunk was not built"
echo "ok: the .spa.tsx is discovered and built with no --spa= on the command line"

echo "PASS: a lazy-route SPA builds from the toolchain-free CLI path with every referenced script present"
