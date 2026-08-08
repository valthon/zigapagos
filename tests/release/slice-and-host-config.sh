#!/usr/bin/env bash
# `zigapagos release` must emit the WHOLE output tree — including the two
# artifacts that used to be bolted on by the consumer's build graph rather than
# produced by the binary.
#
# WHAT WAS MISSING, AND WHY IT IS INVISIBLE. Both artifacts are named by markup
# the binary itself writes, so their absence never fails a build:
#
#   1. /islands/_runtime.js — the per-SITE islands runtime SLICE. It needs a
#      second pass over the BUILT island bundles (the decision is a property of
#      the whole set, so it cannot be made until the last bundle is on disk), and
#      that pass only ever ran as a build-graph step. Without it a site simply
#      got the documented no-slice default, which is a bigger runtime and nothing
#      worse — UNTIL the pass exists and the manifest says "sliced", at which
#      point every covered page's import map, modulepreload and module <script>
#      all name a file nothing installed. The page then fails to resolve EVERY
#      module specifier it has.
#
#   2. csp.{nginx,apache,zigbase} at the site root, and per-namespace host config
#      (`.spa` + `zigbase.static_routes.zig` for the default zigbase target)
#      beside each routing-manifest.json. These are read by the SERVER, not the
#      browser, so a tree without them renders perfectly in a local file:// or
#      dumb-static preview and then loses SPA deep-link fallback and ships a CSP
#      that blocks its own inline importmap the moment it is deployed for real.
#
# So the assertions here are PRESENCE-AND-AGREEMENT, not exit status: the build
# exited 0 in both broken states.
#
# This drives the real binary with the real Bun drivers over a real (tiny)
# island+SPA site, with NOTHING on the command line but the entries — exactly the
# npm shape, where `ZIGAPAGOS_RUNTIME_DIR` names the runtime tree shipped beside
# the binary and there is no build graph at all.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"

fail() { echo "FAIL: $*"; exit 1; }

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || fail "zig build failed"
fi

command -v bun >/dev/null || fail "bun not found on PATH -- required for the sidecar and the bundlers"

if [[ ! -d "$REPO/runtime/node_modules" ]]; then
  echo "runtime/node_modules missing; running 'bun install --frozen-lockfile'..."
  ( cd "$REPO/runtime" && bun install --frozen-lockfile ) \
    || fail "bun install --frozen-lockfile failed in runtime/"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SITE="$WORK/site"
OUT="$WORK/out"
mkdir -p "$SITE/content" "$SITE/layouts" "$SITE/assets" "$SITE/components" "$SITE/app"
: > "$SITE/assets/.keep"

cat > "$SITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "CLI Emit Test",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
}
EOF

# jsxImportSource drives bun's JSX transform to `@z/runtime/jsx-runtime`, which
# the bundler keeps external and the sidecar answers by module override. As in
# tests/spa/npm-cli-spa.sh there is deliberately no node_modules/@z/runtime here:
# that symlink is what a repo checkout has and an npm consumer does not.
cat > "$SITE/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "@z/runtime",
    "moduleResolution": "bundler"
  }
}
JSON

# Two islands whose whole @z/runtime surface is a plain named import, so the
# slicer can prove them safe and MUST decide "sliced" rather than fall back —
# a fallback decision would make assertion (1) vacuous.
for c in Counter Ticker; do
  cat > "$SITE/components/$c.island.tsx" <<TSX
import { useState } from "@z/runtime";
export default function $c({ start = 0 }: { start?: number }) {
  const [n, setN] = useState(start);
  return <button data-c="$c" onClick={() => setN(n + 1)}>{n}</button>;
}
TSX
done

# The inline <style> whose hash must land in style-src-elem, and the comment
# that NAMES the tag right before it — the shape that broke the scanner once
# (a non-comment-aware scan hashes the comment prose and loses the real hash).
STYLE_CSS='h1{color:#123456}'

cat > "$SITE/layouts/page.shtml" <<EOF
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <title :text="\$site.title"></title>
    <!-- the <style> element below is inline on purpose; so is the <script> -->
    <style>$STYLE_CSS</style>
  </head>
  <body>
    <div :html="\$page.content()"></div>
    <island src="components/Counter.island.tsx" client:load :props='{ .start = 1 }'></island>
    <island src="components/Ticker.island.tsx" client:load :props='{ .start = 2 }'></island>
  </body>
</html>
EOF

cat > "$SITE/content/index.smd" <<'EOF'
---
.title = "P",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "page.shtml",
.draft = false,
---
Prose.
EOF

cat > "$SITE/app/app.spa.tsx" <<'TSX'
import { Router } from "@z/runtime";
export const spa = { base: "/app", title: "cli emit spa", head: [] };
function Home() { return <div data-view="home">home</div>; }
export const routes = [{ path: "/", component: Home }];
export default function App() { return <Router base={spa.base} routes={routes} />; }
TSX

set +e
( cd "$SITE" && ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime" \
    "$ZIGAPAGOS" release "--output=$OUT" --force \
    --island=components/Counter.island.tsx \
    --island=components/Ticker.island.tsx \
    "--spa=app/app.spa.tsx|/app" ) > "$WORK/build.log" 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  sed -n '1,80p' "$WORK/build.log"
  fail "the toolchain-free island+SPA build exited $rc"
fi

PAGE="$OUT/index.html"
[[ -f "$PAGE" ]] || fail "no index.html was written"

# --- 1. The per-SITE islands runtime slice ----------------------------------
[[ -f "$OUT/islands/_runtime.js" ]] \
  || fail "islands/_runtime.js was not installed — nothing ran the per-site islands slicer"
grep -q '"@z/runtime":"/islands/_runtime.js"' "$PAGE" \
  || { grep -o '<script type="importmap">[^<]*' "$PAGE"; fail "the page's import map does not name the slice"; }
grep -q '<script type="module" src="/islands/_runtime.js"></script>' "$PAGE" \
  || fail "the page does not load the slice as its runtime module"
# Both must be true together. Naming the slice while the file is absent is the
# 404-on-every-specifier failure; installing it while the page still names the
# shared runtime is dead weight; naming BOTH is the two-Preact catastrophe.
grep -q 'zigapagos-runtime\.js' "$PAGE" \
  && fail "the shared runtime survives on a fully-covered page — a page loading both gets two Preacts"
echo "ok: the islands slice is built, installed, and is the only runtime the covered page names"

# Every absolute .js URL the page names resolves on disk — the same
# resolution-not-presence assertion tests/spa/npm-cli-spa.sh makes, so a slice
# that is named but not installed cannot pass by satisfying the greps above.
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  [[ -f "$OUT/${url#/}" ]] || fail "the page references '$url' but $OUT${url} does not exist"
done < <(grep -o '"/[^"]*\.js"' "$PAGE" | tr -d '"' | sort -u)

# --- 2. Host config + strict-CSP artifacts ----------------------------------
for f in csp.nginx.conf csp.apache.conf csp.zigbase.txt; do
  [[ -f "$OUT/$f" ]] || fail "$f was not emitted — nothing ran the host-config emitter"
done
# The CSP is only worth anything if it actually allowlists the inline scripts
# this very build wrote; an emitter run over an empty tree would still produce
# three files.
grep -q "sha256-" "$OUT/csp.nginx.conf" \
  || fail "csp.nginx.conf carries no inline-script hash — it was emitted over a tree with no pages"

# The style-src-elem/style-src-attr split (issue #130): a blanket `style-src
# 'unsafe-inline'` grants inline-style-ELEMENT injection sitewide when only
# style ATTRIBUTES (the framework's `display:contents` slot wrappers) need the
# lenient grant. This is the CI-visible pin — the Playwright CSP e2e that
# proves the split works end to end in a real browser is NOT wired into
# ci.yml (see examples/tsx-site/test/spa_csp_playwright.py).
grep -q "style-src-attr 'unsafe-inline'" "$OUT/csp.nginx.conf" \
  || fail "csp.nginx.conf grants no style-src-attr — the framework's inline style attributes would be blocked"
grep -Eq "(^|; )style-src ['\"]" "$OUT/csp.nginx.conf" \
  && fail "csp.nginx.conf still emits a blanket style-src — issue #130 asks for the elem/attr split"
grep -q "style-src-elem 'self'" "$OUT/csp.nginx.conf" \
  || fail "csp.nginx.conf has no strict style-src-elem"

# ...and the hash must be BYTE-EXACT against the <style> the same build served.
# A strict style-src-elem with a wrong hash is worse than the old blanket grant:
# it blocks the site's own stylesheet and the build still exits 0. The layout
# above deliberately puts a comment NAMING <style>/<script> in front of the real
# element — a scan that is not comment-aware hashes the comment text instead and
# silently drops the real hash, which is exactly how this shipped once.
STYLE_HASH="$(printf '%s' "$STYLE_CSS" | bun -e '
  const { createHash } = require("node:crypto");
  process.stdout.write(createHash("sha256").update(await Bun.stdin.text(), "utf8").digest("base64"));
')" || fail "could not compute the expected inline-style hash"
grep -q "sha256-$STYLE_HASH" "$OUT/csp.nginx.conf" \
  || { cat "$OUT/csp.nginx.conf"; fail "style-src-elem is missing the byte-exact hash of the page's own <style> (expected sha256-$STYLE_HASH) — the deployed CSP would block it"; }

# The zigbase default target, beside the SPA's routing manifest.
[[ -f "$OUT/app/routing-manifest.json" ]] || fail "no routing-manifest.json for the SPA"
[[ -f "$OUT/app/.spa" ]] \
  || fail "no .spa marker beside the routing manifest — zigbase would not fall back for deep links"
ZBR="$OUT/app/zigbase.static_routes.zig"
[[ -f "$ZBR" ]] || fail "zigbase.static_routes.zig was not emitted"
grep -q '\.serve = "/app/index.html"' "$ZBR" \
  || { cat "$ZBR"; fail "the generated zigbase route does not serve the SPA's shell"; }
echo "ok: the site-wide CSP artifacts and the per-namespace zigbase config were emitted"

echo "PASS: zigapagos release emits the islands slice and the host config with no build graph"
