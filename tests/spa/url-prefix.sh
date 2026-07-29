#!/usr/bin/env bash
# Regression test (issue #26): a site's `url_path_prefix` (a GitHub
# project-pages subpath, e.g. "myproj") must reach the SPA's Router base, not
# just its asset URLs.
#
# The defect this pins: the build used to SSR every SPA route at an
# UNPREFIXED pathname while a real browser has the prefix baked into
# `location.pathname`. `<Link>` resolves its href against the Router's base,
# so a prerendered nav href came out base-relative-but-UNPREFIXED --
# `/app/guides` instead of `/myproj/app/guides` -- dead without JavaScript on
# a project-pages host. Worse: Preact's `hydrate()` does not diff element
# ATTRIBUTES on its first pass, so the wrong href stays wrong in the DOM
# permanently, even after the client router boots.
#
# The fix composes `url_path_prefix` into the Router's effective base at ONE
# point: `runtime/src/router.ts`'s `Router` does
# `base = getUrlPathPrefix() + (props.base ?? "")`. The prefix reaches that
# function over TWO channels that must agree byte-for-byte:
#   - the SSR pass: `src/spa.zig`'s `prerenderAll` computes `norm_prefix` and
#     sends it to the sidecar per render request (`runtime/sidecar/render.ts`'s
#     `req.prefix` -> `setUrlPathPrefix`), so the build's own SSR renders the
#     PREFIXED hrefs into the shell;
#   - the browser: the same `norm_prefix` is baked onto the shell's hydration
#     root as `data-z-prefix`, read by `mountSpa` before the first client
#     render (`runtime/src/router.ts`'s `setUrlPathPrefix(root.getAttribute
#     ("data-z-prefix") ?? "")`), so hydration reproduces the SSR'd markup
#     exactly instead of leaving it permanently wrong.
#
# Three legs:
#   (1) THE ASSERTION: a `url_path_prefix`-carrying site's prerendered shell
#       contains the PREFIXED, resolved href and does NOT contain the
#       unprefixed form.
#   (2) the shell's hydration root carries `data-z-prefix="/myproj"`.
#   (3) THE NO-OP CONTROL: the identical fixture rebuilt with NO
#       `url_path_prefix` contains neither `data-z-prefix` nor any `/myproj`
#       segment -- proving legs (1)/(2) are not vacuously true (e.g. the
#       fixture's own route path happening to contain "myproj") and that an
#       unprefixed site is untouched by this composition.
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

# $2 ("prefixed"|"bare") controls whether zigapagos.ziggy carries
# `url_path_prefix = "myproj"`.
new_site() {
  local dir="$1" mode="$2"
  mkdir -p "$dir/app" "$dir/node_modules/@z"
  cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$dir/"
  cp tests/rendering/simple/zigapagos.ziggy "$dir/"
  if [[ "$mode" == "prefixed" ]]; then
    printf '    .url_path_prefix = "myproj",\n}\n' > "$WORK/.ziggy-tail"
    sed -i.bak '$d' "$dir/zigapagos.ziggy"        # drop the fixture's closing "}"
    cat "$WORK/.ziggy-tail" >> "$dir/zigapagos.ziggy"
    rm -f "$dir/zigapagos.ziggy.bak"
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
  # The <Link> lives in the index route's own component, so it appears
  # directly in the prerendered shell -- no layout indirection needed to
  # exercise the composition.
  cat > "$dir/app/app.spa.tsx" <<'TSX'
import { Router, Link } from "@z/runtime";

export const spa = { base: "/app", title: "Probe" };

function Home() {
  return <div><Link href="/guides">Guides</Link></div>;
}

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
  ( cd "$dir" && "$ZIGAPAGOS" release "--output=$out" --force \
      "--bun=$BUN" \
      "--island-sidecar=$REPO/runtime/sidecar/render.ts" \
      --island-src-dir=. \
      "--spa=app/app.spa.tsx|/app" )
}

# --- (1)+(2) the prefixed site ------------------------------------------------
SITE_PFX="$WORK/pfx"; OUT_PFX="$WORK/out-pfx"
new_site "$SITE_PFX" prefixed
grep -q 'url_path_prefix = "myproj"' "$SITE_PFX/zigapagos.ziggy" \
  || fail "fixture setup bug: url_path_prefix was not appended to zigapagos.ziggy"

build "$SITE_PFX" "$OUT_PFX" >"$WORK/pfx.log" 2>&1 \
  || { sed -n '1,30p' "$WORK/pfx.log"; fail "the url_path_prefix build failed -- fixture broken, test proves nothing"; }

SHELL_PFX="$OUT_PFX/app/index.html"
[[ -f "$SHELL_PFX" ]] || fail "expected shell not written: $SHELL_PFX"

grep -q 'href="/myproj/app/guides"' "$SHELL_PFX" \
  || { echo "--- shell ---"; cat "$SHELL_PFX"
       fail "the prerendered shell does not contain the PREFIXED href /myproj/app/guides"; }
echo "leg 1a OK: prerendered shell contains the prefixed href"

grep -q 'href="/app/guides"' "$SHELL_PFX" \
  && { echo "--- shell ---"; cat "$SHELL_PFX"
       fail "the prerendered shell ALSO contains the unprefixed href /app/guides -- SSR and the prefix disagree"; }
echo "leg 1b OK: the shell does not also contain the unprefixed form"

grep -q 'data-z-prefix="/myproj"' "$SHELL_PFX" \
  || { echo "--- shell ---"; cat "$SHELL_PFX"
       fail "the shell's hydration root does not carry data-z-prefix=\"/myproj\" -- the browser has no way to reproduce the SSR'd base on hydration"; }
echo "leg 2 OK: hydration root carries data-z-prefix=\"/myproj\""

# --- (2b) the manifest carries the prefix as its OWN field ------------------
# The host-config emitters need to know where the tree is mounted, but they
# need it SEPARATELY from the route values: those name positions inside the
# output tree, which has no prefix directory, and two of the three emitters
# consume them tree-relative (Apache's per-directory patterns, ZigBase's
# `.serve`). So the manifest must carry the prefix and leave the routes alone —
# asserting only that the field is present would still pass if the route values
# had ALSO been prefixed, which is the bug this shape exists to avoid.
MANIFEST_PFX="$OUT_PFX/app/routing-manifest.json"
[[ -f "$MANIFEST_PFX" ]] || fail "expected manifest not written: $MANIFEST_PFX"
grep -q '"url_path_prefix":"/myproj"' "$MANIFEST_PFX" \
  || { echo "--- manifest ---"; cat "$MANIFEST_PFX"
       fail "the routing manifest does not carry url_path_prefix -- the host-config emitters cannot know where the tree is mounted"; }
grep -q '"fallback":"/app/index.html"' "$MANIFEST_PFX" \
  || { echo "--- manifest ---"; cat "$MANIFEST_PFX"
       fail "the manifest's fallback is not tree-relative -- a prefixed one names a file that does not exist on disk"; }
grep -q '"/myproj/app' "$MANIFEST_PFX" \
  && { echo "--- manifest ---"; cat "$MANIFEST_PFX"
       fail "a manifest ROUTE value carries the prefix -- route values must stay tree-relative"; }
echo "leg 2b OK: manifest carries url_path_prefix; its route values stay tree-relative"

# --- (3) THE NO-OP CONTROL: the same fixture with NO url_path_prefix --------
SITE_BARE="$WORK/bare"; OUT_BARE="$WORK/out-bare"
new_site "$SITE_BARE" bare
grep -q 'url_path_prefix' "$SITE_BARE/zigapagos.ziggy" \
  && fail "fixture setup bug: the bare control's zigapagos.ziggy unexpectedly carries url_path_prefix"

build "$SITE_BARE" "$OUT_BARE" >"$WORK/bare.log" 2>&1 \
  || { sed -n '1,30p' "$WORK/bare.log"; fail "the control (no url_path_prefix) build failed"; }

SHELL_BARE="$OUT_BARE/app/index.html"
[[ -f "$SHELL_BARE" ]] || fail "expected control shell not written: $SHELL_BARE"

grep -q 'data-z-prefix' "$SHELL_BARE" \
  && { echo "--- shell ---"; cat "$SHELL_BARE"
       fail "control: an UNPREFIXED site's shell carries data-z-prefix -- unprefixed sites are affected by this composition"; }
grep -q '/myproj' "$SHELL_BARE" \
  && { echo "--- shell ---"; cat "$SHELL_BARE"
       fail "control: an UNPREFIXED site's shell contains a /myproj segment -- leaked from the prefixed fixture somehow"; }
grep -q 'href="/app/guides"' "$SHELL_BARE" \
  || { echo "--- shell ---"; cat "$SHELL_BARE"
       fail "control: the unprefixed shell does not even contain the plain href -- fixture is broken, not proving the no-op"; }
grep -q 'url_path_prefix' "$OUT_BARE/app/routing-manifest.json" \
  && { echo "--- manifest ---"; cat "$OUT_BARE/app/routing-manifest.json"
       fail "control: an UNPREFIXED site's manifest carries a url_path_prefix key -- it must be omitted entirely, not emitted as \"\""; }
echo "leg 3 OK: an unprefixed site's shell and manifest carry neither data-z-prefix nor /myproj"

echo "PASS: url_path_prefix composes into the SPA Router base, SSR and hydration agree, and unprefixed sites are unaffected"
