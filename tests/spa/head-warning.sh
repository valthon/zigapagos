#!/usr/bin/env bash
# Regression test (issue #24): a SPA that declares no `spa.head` on a site
# that HAS stylesheet assets should warn, because a SPA shell's <head> is
# fixed (import map, modulepreloads, boot script) and does NOT inherit site
# stylesheets. `spa.head` is the documented, build-checked way to add one --
# but nothing pointed authors at it, so the dogfooded marketing-site demo
# shipped unstyled with every CSS rule written for it dead.
#
# `src/spa.zig`'s `prerenderAll` now prints a warning (via `spaHeadWarningAsset`)
# when a SPA's `desc.spa.head` is exactly `null` (absent) AND the site has at
# least one `.css` asset. `head: []` is the documented, silent opt-out (a SPA
# that styles itself another way -- inline styles / CSS-in-JS), and a
# non-empty `head` (even preconnect-only) means the author has clearly used
# the hook already -- both stay silent regardless of CSS assets.
#
# This is a WARNING, not a build error: every leg below asserts exit 0. Four
# legs cover the full gating matrix documented on `spaHeadWarningAsset`:
#   (1) head absent, site HAS a .css asset       -> warns, names the asset
#   (2) head: [] (explicit opt-out), site HAS css -> silent
#   (3) head: [a real stylesheet], site HAS css   -> silent
#   (4) head absent, site has NO .css asset       -> silent (nothing to miss)
# Leg (3)'s stylesheet href must point at a file that genuinely exists in the
# fixture's assets dir: the build stages a head asset and fails if nothing
# installs it (a real, unrelated gate -- not what this test pins), so a
# fabricated href would make leg (3) fail for the wrong reason.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

BUN="$(command -v bun || true)"
[[ -n "$BUN" ]] || { echo "FAIL: bun not found on PATH -- required to spawn the island sidecar"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# A fresh site directory with its OWN assets dir (kept separate from
# tests/rendering/simple's content-as-assets so a `.css` file can be dropped
# in or left out per leg without touching content/layouts), plus the
# `@z/runtime` symlink + tsconfig `react-jsx` wiring `link-outside-router.sh`
# already proved works.
#
# $2 ("css"|"nocss") controls whether assets/style.css is present.
new_site() {
  local dir="$1" css="$2"
  mkdir -p "$dir/app" "$dir/assets" "$dir/node_modules/@z"
  cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$dir/"
  cp tests/rendering/simple/zigapagos.ziggy "$dir/"
  sed -i.bak 's/\.assets_dir_path = "content"/.assets_dir_path = "assets"/' "$dir/zigapagos.ziggy"
  rm -f "$dir/zigapagos.ziggy.bak" # BSD sed's -i needs a suffix; GNU's accepts empty -- .bak+rm works on both
  if [[ "$css" == "css" ]]; then
    printf 'body { color: red; }\n' > "$dir/assets/style.css"
  fi
  ln -s "$REPO/runtime" "$dir/node_modules/@z/runtime"
  cat > "$dir/tsconfig.json" <<'JSON'
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
}

build() {
  local dir="$1" out="$2"
  ( cd "$dir" && ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime" "$ZIGAPAGOS" release "--output=$out" --force \
      "--bun=$BUN" \
      "--island-sidecar=$REPO/runtime/sidecar/render.ts" \
      --island-src-dir=. \
      "--spa=app/app.spa.tsx|/app" )
}

minimal_spa() {
  local dir="$1" head_field="$2"
  cat > "$dir/app/app.spa.tsx" <<TSX
import { Router } from "@z/runtime";

export const spa = { base: "/app", title: "Probe"$head_field };

function Home() { return <div>home</div>; }

export const routes = [
  { path: "/", component: Home },
];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
TSX
}

# --- (1) head absent, site HAS a .css asset -> warns, names the asset -------
SITE1="$WORK/1"; OUT1="$WORK/out1"
new_site "$SITE1" css
minimal_spa "$SITE1" ""
build "$SITE1" "$OUT1" >"$WORK/1.log" 2>&1 \
  || { sed -n '1,30p' "$WORK/1.log"; fail "leg 1 build failed (exit != 0) -- this is a WARNING, the build must still succeed"; }
grep -q 'declares no spa.head' "$WORK/1.log" \
  || { sed -n '1,30p' "$WORK/1.log"; fail "leg 1: no spa.head + a site .css asset produced no warning"; }
grep -qE '\.css' "$WORK/1.log" \
  || { sed -n '1,30p' "$WORK/1.log"; fail "leg 1: the warning does not name a .css file"; }
# The SUGGESTED SNIPPET must name the detected file too, not a hardcoded
# example. This fixture's stylesheet is `style.css` precisely so the two are
# distinguishable: the warning used to point at '/style.css' and then hand the
# author `href: "/site.css"` to paste, which is a broken suggestion on every
# site whose stylesheet isn't literally called site.css (and would fail the
# head-asset staging check the moment they pasted it).
grep -qF 'href: "/style.css"' "$WORK/1.log" \
  || { sed -n '1,30p' "$WORK/1.log"; fail "leg 1: the suggested spa.head snippet does not name the detected stylesheet"; }
grep -qF '/site.css' "$WORK/1.log" \
  && { sed -n '1,30p' "$WORK/1.log"; fail "leg 1: the suggestion still hardcodes /site.css instead of the detected file"; }
echo "leg 1 OK: warns, names a .css file, and its suggestion is copy-pasteable (exit 0)"

# --- (2) head: [] (documented opt-out), site HAS css -> silent --------------
SITE2="$WORK/2"; OUT2="$WORK/out2"
new_site "$SITE2" css
minimal_spa "$SITE2" ", head: []"
build "$SITE2" "$OUT2" >"$WORK/2.log" 2>&1 \
  || { sed -n '1,30p' "$WORK/2.log"; fail "leg 2 build failed (exit != 0)"; }
grep -q 'declares no spa.head' "$WORK/2.log" \
  && { sed -n '1,30p' "$WORK/2.log"; fail "leg 2: head: [] (the documented opt-out) still warned"; }
echo "leg 2 OK: head: [] stays silent even with a css asset present (exit 0)"

# --- (3) a real stylesheet head, site HAS css -> silent ---------------------
# The href must resolve to a REAL installed asset (style.css, same file leg 1
# used) or the build fails for the unrelated "missing head asset" gate.
SITE3="$WORK/3"; OUT3="$WORK/out3"
new_site "$SITE3" css
minimal_spa "$SITE3" ', head: [{ rel: "stylesheet", href: "/style.css" }]'
build "$SITE3" "$OUT3" >"$WORK/3.log" 2>&1 \
  || { sed -n '1,30p' "$WORK/3.log"; fail "leg 3 build failed (exit != 0) -- check the head href resolves to a real installed asset"; }
grep -q 'declares no spa.head' "$WORK/3.log" \
  && { sed -n '1,30p' "$WORK/3.log"; fail "leg 3: a real spa.head stylesheet still warned"; }
echo "leg 3 OK: a real spa.head stylesheet stays silent (exit 0)"

# --- (4) bonus: head absent, site has NO .css asset -> silent ---------------
SITE4="$WORK/4"; OUT4="$WORK/out4"
new_site "$SITE4" nocss
minimal_spa "$SITE4" ""
build "$SITE4" "$OUT4" >"$WORK/4.log" 2>&1 \
  || { sed -n '1,30p' "$WORK/4.log"; fail "leg 4 build failed (exit != 0)"; }
grep -q 'declares no spa.head' "$WORK/4.log" \
  && { sed -n '1,30p' "$WORK/4.log"; fail "leg 4: no spa.head warned even though the site has no css asset to be missing"; }
echo "leg 4 OK: no spa.head stays silent when the site has no css asset (exit 0)"

echo "PASS: spa.head warning fires only when head is absent AND the site has a stylesheet"
