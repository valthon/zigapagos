#!/usr/bin/env bash
# Regression test: a `spa.head` href must follow a fingerprinted site asset
# (issues #53 + #24).
#
# WHY THIS IS ITS OWN SCRIPT. `spa.head` is the THIRD seam that prints a
# site-asset URL, and it is the odd one out. The other two — `.link()` in
# `context/Asset.zig` and the `![](...)` directive in `render/html.zig` —
# print from a `PathName` and were switched to the shared fingerprint
# formatter. A `spa.head` href is a STRING the site author typed into
# `.spa.tsx` (`href: "/style.css"`), copied verbatim into every prerendered
# shell. With `asset_fingerprint = true` the install pass writes
# `/style.<hash>.css` instead, so an unrewritten shell links a file that does
# not exist — and the surrounding staging check (which exists precisely to
# stop a silent-404 head asset) would still pass, because it only proves
# SOMETHING installs the asset, not that it installs it under that name.
#
# So `prerenderAll` rewrites the href, and this pins it end to end: the URL in
# the shell must name a file that is actually in the output tree.
#
# Legs:
#   (1) fingerprint ON  -> the shell links /style.<hash>.css, the file exists,
#                          and the unhashed /style.css does NOT.
#   (2) fingerprint OFF -> the shell links /style.css verbatim (control: the
#                          rewrite is opt-in and changes nothing otherwise).
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

# Same fixture shape as tests/spa/head-warning.sh: a site with its own assets
# dir plus the `@z/runtime` symlink + tsconfig react-jsx wiring the SPA build
# needs. $2 = "on"|"off" for `asset_fingerprint`.
new_site() {
  local dir="$1" flag="$2"
  mkdir -p "$dir/app" "$dir/assets" "$dir/node_modules/@z"
  cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$dir/"
  cp tests/rendering/simple/zigapagos.ziggy "$dir/"
  sed -i.bak 's/\.assets_dir_path = "content"/.assets_dir_path = "assets"/' "$dir/zigapagos.ziggy"
  rm -f "$dir/zigapagos.ziggy.bak" # BSD sed's -i needs a suffix; GNU's accepts empty -- .bak+rm works on both
  if [[ "$flag" == "on" ]]; then
    # NOT `sed 's/^}$/…\n}/'`: a `\n` in the REPLACEMENT half of an `s///` is a
    # GNU extension — BSD/macOS sed emits a literal `n` — and the line above
    # states BSD/GNU portability as this fixture's goal. Dropping the closing
    # brace and re-appending is the portable spelling of the same edit.
    sed '$d' "$dir/zigapagos.ziggy" > "$dir/zigapagos.ziggy.tmp"
    printf '    .asset_fingerprint = true,\n}\n' >> "$dir/zigapagos.ziggy.tmp"
    mv "$dir/zigapagos.ziggy.tmp" "$dir/zigapagos.ziggy"
    grep -q '^    \.asset_fingerprint = true,$' "$dir/zigapagos.ziggy" ||
      { cat "$dir/zigapagos.ziggy"; fail "could not enable asset_fingerprint in the fixture config"; }
  fi
  printf 'body { color: red; }\n' > "$dir/assets/style.css"
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
  cat > "$dir/app/app.spa.tsx" <<'TSX'
import { Router } from "@z/runtime";

export const spa = {
  base: "/app",
  title: "Probe",
  head: [{ rel: "stylesheet", href: "/style.css" }],
};

function Home() { return <div>home</div>; }

export const routes = [
  { path: "/", component: Home },
];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
TSX
}

build() {
  local dir="$1" out="$2"
  ( cd "$dir" && ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime" "$ZIGAPAGOS" release "--output=$out" --force \
      "--bun=$BUN" \
      "--island-sidecar=$REPO/runtime/sidecar/render.ts" \
      --island-src-dir=. \
      "--spa=app/app.spa.tsx|/app" )
}

# --- (1) fingerprint ON: the shell must follow the hashed name --------------
ON="$WORK/on"; ON_OUT="$WORK/on-out"
new_site "$ON" on
build "$ON" "$ON_OUT" >"$WORK/on.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/on.log"; fail "leg 1 build failed"; }

SHELL_HTML="$ON_OUT/app/index.html"
[[ -f "$SHELL_HTML" ]] || fail "leg 1: no SPA shell was prerendered at app/index.html"

HASHED="$(grep -o 'href="/style\.[0-9a-f]\{8\}\.css"' "$SHELL_HTML" | head -1 |
  sed 's|.*href="/||; s|"$||')" \
  || { sed -n '1,5p' "$SHELL_HTML"; fail "leg 1: the SPA shell's spa.head href was not rewritten to the fingerprinted name"; }
[[ -n "$HASHED" ]] || fail "leg 1: no fingerprinted stylesheet href in the shell"
[[ -f "$ON_OUT/$HASHED" ]] \
  || fail "leg 1: the shell links '/$HASHED' but the install pass wrote no such file"
[[ ! -f "$ON_OUT/style.css" ]] \
  || fail "leg 1: the unhashed style.css was also installed"
grep -q 'href="/style.css"' "$SHELL_HTML" \
  && fail "leg 1: the shell still links the unhashed /style.css — that file does not exist in the output"
echo "leg 1 OK: spa.head href rewritten to /$HASHED and that file is installed"

# --- (2) fingerprint OFF control -------------------------------------------
OFF="$WORK/off"; OFF_OUT="$WORK/off-out"
new_site "$OFF" off
build "$OFF" "$OFF_OUT" >"$WORK/off.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/off.log"; fail "leg 2 build failed"; }

OFF_SHELL="$OFF_OUT/app/index.html"
[[ -f "$OFF_SHELL" ]] || fail "leg 2: no SPA shell was prerendered at app/index.html"
grep -q 'href="/style.css"' "$OFF_SHELL" \
  || fail "leg 2: the control shell does not link /style.css verbatim — the rewrite is not opt-in"
[[ -f "$OFF_OUT/style.css" ]] || fail "leg 2: style.css was not installed at its verbatim path"
echo "leg 2 OK: with the flag off the shell links /style.css verbatim"

echo "PASS: a spa.head href follows the fingerprinted site asset"
