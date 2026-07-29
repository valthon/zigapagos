#!/usr/bin/env bash
# e2e for islands-in-content (issue #30): a `.smd` page can embed an island
# inside a fenced code block whose fence info is `=html` — SuperMD's existing
# raw-HTML escape hatch, which runs the fence body through superhtml's HTML
# validator and maps errors back to `.smd` line numbers. The one gap: an
# unhyphenated custom element name (`<island>`) fails that validator per the
# HTML spec (`invalid_html_tag_name`) — `.superhtml` mode (layouts) is lax
# about unknown elements, `.html` mode (content) is not. `<z-island>` is a
# hyphenated alias the islands pass (src/islands/pass.zig) recognizes
# identically to `<island>`, and it sails through validation unmodified.
#
# The check is deliberately three-part, exactly mirroring
# tests/islands/undeclared-island.sh's discipline, so a broken fixture cannot
# make any one part look like it proves something it doesn't:
#   (1) POSITIVE: a page with a `<z-island>` in an `=html` fence builds
#       successfully and the emitted HTML carries the SSR'd markup, the
#       data-z-props script, and the import map.
#   (2) NEGATIVE PIN: the identical page, but with the fence's `<z-island>`
#       swapped for the plain `<island>` spelling, FAILS the build with
#       superhtml's `invalid_html_tag_name` diagnostic, attributed to the
#       `.smd` file. This is what documents *why* the hyphen is mandatory,
#       and it will fail loudly (not silently pass) if a future supermd/
#       superhtml sync relaxes or renames that validation.
#   (3) CONTROL: the same fixture with the fence removed entirely builds
#       clean — so (1) and (2) are attributable to the fence content, not to
#       some unrelated break in the shared fixture.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

# This test spawns the REAL Bun sidecar (not a stub) to SSR the content
# island, so it needs an actual `bun` on PATH. Fail loudly rather than skip —
# a test that silently skips in CI is a test that doesn't exist.
command -v bun >/dev/null 2>&1 || { echo "FAIL: bun not found on PATH (required to run the real island sidecar)"; exit 1; }

if [[ ! -d "$REPO/runtime/node_modules" ]]; then
  echo "runtime/node_modules missing; running 'bun install --frozen-lockfile'..."
  ( cd "$REPO/runtime" && bun install --frozen-lockfile ) \
    || { echo "FAIL: bun install --frozen-lockfile failed in runtime/"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# write_site DIR BODY: a fresh single-page site fixture whose content page's
# body (after the frontmatter) is exactly $BODY. Shared shape across all three
# phases so a failure in one phase can't be blamed on fixture drift between
# phases.
write_site() {
  local dir="$1" body="$2"
  mkdir -p "$dir/content" "$dir/layouts" "$dir/assets" "$dir/components"
  : > "$dir/assets/.keep"
  cat > "$dir/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Content Island Test",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
}
EOF
  cat > "$dir/layouts/plain.shtml" <<'EOF'
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <title :text="$site.title"></title>
  </head>
  <body>
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
  </body>
</html>
EOF
  cat > "$dir/components/Counter.island.tsx" <<'EOF'
export interface Props { start: number }
export default function Counter({ start }: Props) {
  return `CONTENT-ISLAND-SSR-${start}`;
}
EOF
  {
    cat <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "plain.shtml",
.draft = false,
---
Some prose.

EOF
    printf '%s\n' "$body"
    cat <<'EOF'

More prose.
EOF
  } > "$dir/content/index.smd"
}

release() { # SITE OUT
  ( cd "$1" && "$ZIGAPAGOS" release "--output=$2" --force --bun="$(command -v bun)" \
      "--island-sidecar=$REPO/runtime/sidecar/render.ts" --island-src-dir=. )
}

# --- (1) positive: <z-island> in an =html fence builds and SSRs -------------
SITE_POS="$WORK/pos"; OUT_POS="$WORK/out-pos"
write_site "$SITE_POS" '```=html
<z-island src="components/Counter.island.tsx" client:load :props='"'"'{ .start = 5 }'"'"'></z-island>
```'
release "$SITE_POS" "$OUT_POS" >"$WORK/pos.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/pos.log"; fail "positive build (z-island in an =html fence) failed"; }

INDEX_POS="$OUT_POS/index.html"
[[ -f "$INDEX_POS" ]] || fail "positive build did not emit index.html"
grep -q 'CONTENT-ISLAND-SSR-5' "$INDEX_POS" \
  || { cat "$INDEX_POS"; fail "emitted HTML is missing the SSR'd island markup"; }
grep -q 'data-z-props="z-island-0">{"start":5}</script>' "$INDEX_POS" \
  || { cat "$INDEX_POS"; fail "emitted HTML is missing the data-z-props script"; }
grep -q '<script type="importmap">' "$INDEX_POS" \
  || { cat "$INDEX_POS"; fail "emitted HTML is missing the import map"; }
if grep -q '<z-island' "$INDEX_POS"; then
  cat "$INDEX_POS"
  fail "the literal <z-island tag survived into the output (not rewritten)"
fi
echo "PASS: a <z-island> inside an =html fence SSRs, with props script + import map"

# --- (2) negative pin: plain <island> in the SAME fence fails validation ----
SITE_NEG="$WORK/neg"; OUT_NEG="$WORK/out-neg"
write_site "$SITE_NEG" '```=html
<island src="components/Counter.island.tsx" client:load :props='"'"'{ .start = 5 }'"'"'></island>
```'
set +e
release "$SITE_NEG" "$OUT_NEG" >"$WORK/neg.log" 2>&1
NEG_RC=$?
set -e

[[ "$NEG_RC" -ne 0 ]] || {
  echo "--- build output ---"; sed -n '1,40p' "$WORK/neg.log"
  fail "a plain <island> inside an =html fence built SUCCESSFULLY -- the hyphen requirement regressed"
}
# Assert on the actual superhtml diagnostic, not just a non-zero exit: this is
# what pins WHY the hyphen matters and would catch a supermd/superhtml sync
# that changes how unhyphenated custom elements are handled.
grep -q 'invalid_html_tag_name' "$WORK/neg.log" \
  || { echo "--- build output ---"; sed -n '1,40p' "$WORK/neg.log"
       fail "the build failed but not with superhtml's invalid_html_tag_name diagnostic (some other error?)"; }
grep -qE 'content/index\.smd:[0-9]+:[0-9]+: \[invalid_html_tag_name\]' "$WORK/neg.log" \
  || { echo "--- build output ---"; sed -n '1,40p' "$WORK/neg.log"
       fail "the diagnostic is not attributed to a .smd line (supermd's line-mapping regressed)"; }
echo "PASS: a plain <island> inside an =html fence fails with superhtml's invalid_html_tag_name, attributed to the .smd line"

# --- (3) control: same fixture, no fence at all -> builds clean -------------
SITE_CTRL="$WORK/ctrl"; OUT_CTRL="$WORK/out-ctrl"
write_site "$SITE_CTRL" 'No fence here at all, just prose.'
release "$SITE_CTRL" "$OUT_CTRL" >"$WORK/ctrl.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/ctrl.log"; fail "control build (no fence) failed -- the fixture itself is broken, so parts (1) and (2) prove nothing"; }
[[ -f "$OUT_CTRL/index.html" ]] || fail "control build did not emit index.html"
echo "PASS: the same fixture with the fence removed builds clean (control)"

echo "ALL PASS: islands in content via a hyphenated <z-island> inside an =html fence"
