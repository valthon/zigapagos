#!/usr/bin/env bash
# Regression test (issue #23): a <Link> rendered OUTSIDE a <Router> must fail
# the build, not silently ship a dead href.
#
# The defect this pins: `Link` resolves its `href` against the enclosing
# `Router`'s base (`resolveHref(href, ctx.base)`). With no Router context the
# base is unknown, so the OLD behaviour rendered the href verbatim and wired
# no click interception -- a plain, unresolved anchor. The marketing site's
# SPA demo put its chrome (nav bar) in a JSX wrapper AROUND <Router> -- a
# perfectly natural way to write a layout -- so every prerendered nav href
# came out as e.g. "/guides" instead of "/app/guides": a hard 404 on a
# path-prefixed host, and the build stayed green throughout.
#
# `runtime/src/router.ts`'s `Link` now calls `noRouterLink(href)` when it
# finds no context, and that function throws on the SERVER tier (the build's
# SSR pass, `runtime/sidecar/render.ts`'s `renderToString`) precisely because
# that is the pass that produces the defective shell. The throw propagates
# through the sidecar's NDJSON protocol as a structured error,
# `src/islands/sidecar.zig` turns it into `RenderError`, and `src/spa.zig`
# fatals -- naming the SPA source and the route being rendered.
#
# The check is deliberately two-phase, for the same reason
# tests/islands/undeclared-island.sh is:
#   (1) the SAME fixture with the Link moved INSIDE the Router (a layout
#       route) builds clean -- control: the fixture and the release
#       invocation are otherwise fine, so phase (2)'s failure is caused by
#       the Link placement and nothing else.
#   (2) the Link left OUTSIDE the Router's tree fails the build, and the
#       diagnostic both says "outside a <Router>" AND attributes the failure
#       to the offending SPA source / route -- not just "build failed
#       somewhere".
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

# A fresh site directory: the shared `tests/rendering/simple` content/layouts
# (unrelated to the SPA under test, just needed for a valid non-SPA build),
# plus a `node_modules/@z/runtime` symlink so bun's module resolution (from
# the SPA source file, upward) finds the real runtime, and a tsconfig so the
# `react-jsx` transform resolves through `@z/runtime`'s jsx-runtime instead of
# a real `react` package (mirrors `examples/tsx-site`/`site`'s tsconfig.json).
new_site() {
  local dir="$1"
  mkdir -p "$dir/app" "$dir/node_modules/@z"
  cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$dir/"
  cp tests/rendering/simple/zigapagos.ziggy "$dir/"
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

# --- (1) control: the Link lives INSIDE the Router's tree (a layout route) ---
SITE_OK="$WORK/ok"; OUT_OK="$WORK/out-ok"
new_site "$SITE_OK"
cat > "$SITE_OK/app/app.spa.tsx" <<'TSX'
import { Router, Link } from "@z/runtime";

export const spa = { base: "/app", title: "Probe" };

// The layout route IS inside <Router>'s own tree, so its <Link> can resolve
// against router context -- this is the fixed version of the shape below.
function Chrome({ children }: { children?: unknown }) {
  return (
    <div>
      <Link href="/guides">Guides</Link>
      {children}
    </div>
  );
}
function Home() { return <div>home</div>; }

export const routes = [
  { path: "/", component: Chrome, children: [{ path: "/", component: Home }] },
];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
TSX

build "$SITE_OK" "$OUT_OK" >"$WORK/ok.log" 2>&1 \
  || { sed -n '1,30p' "$WORK/ok.log"; fail "control build failed -- the fixture itself is broken, so this test proves nothing"; }
echo "control: Link inside the Router's tree builds clean"

# --- (2) the Link's enclosing chrome WRAPS <Router> -- outside its tree ------
SITE_BAD="$WORK/bad"; OUT_BAD="$WORK/out-bad"
new_site "$SITE_BAD"
cat > "$SITE_BAD/app/app.spa.tsx" <<'TSX'
import { Router, Link } from "@z/runtime";

export const spa = { base: "/app", title: "Probe" };

function Home() { return <div>home</div>; }

export const routes = [
  { path: "/", component: Home },
];

// Chrome WRAPS <Router> -- a natural way to write a top-level layout -- so
// this <Link> renders with no enclosing Router context.
export default function App() {
  return (
    <div>
      <Link href="/guides">Guides</Link>
      <Router base={spa.base} routes={routes} />
    </div>
  );
}
TSX

set +e
build "$SITE_BAD" "$OUT_BAD" >"$WORK/bad.log" 2>&1
BAD_RC=$?
set -e

[[ "$BAD_RC" -ne 0 ]] || {
  echo "--- build output ---"; sed -n '1,30p' "$WORK/bad.log"
  fail "a <Link> outside a <Router> built SUCCESSFULLY (exit 0) -- the SSR guard regressed"
}
echo "a <Link> outside a <Router> failed the build (exit $BAD_RC)"

grep -q 'outside a <Router>' "$WORK/bad.log" \
  || { echo "--- build output ---"; sed -n '1,30p' "$WORK/bad.log"
       fail "the build failed but not with the 'outside a <Router>' diagnostic (different error -- test is measuring the wrong thing)"; }
echo "diagnostic names the defect ('outside a <Router>')"

# The diagnostic must be ATTRIBUTED -- name the SPA source or the route --
# not just "it failed somewhere". `src/spa.zig`'s renderSkeleton wraps every
# sidecar render error as "SPA skeleton SSR failed: <src> (route <pathname>)"
# before the thrown message; assert on that attribution independent of the
# exact source/route spelling.
grep -qE 'app/app\.spa\.tsx|route /app' "$WORK/bad.log" \
  || { echo "--- build output ---"; sed -n '1,30p' "$WORK/bad.log"
       fail "the diagnostic does not name the offending SPA source or route -- an author with multiple SPAs couldn't find which one"; }
echo "diagnostic attributes the failure to the SPA source / route"

echo "PASS: a <Link> rendered outside a <Router> fails the build with an attributed diagnostic"
