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
# The check is deliberately multi-part, exactly mirroring
# tests/islands/undeclared-island.sh's discipline, so a broken fixture cannot
# make any one part look like it proves something it doesn't:
#   (1) POSITIVE: a page with a `<z-island>` in an `=html` fence builds
#       successfully; `scripty:props` resolves `$page` / `$site` prop values,
#       and the emitted HTML carries the SSR'd markup, typed data-z-props, and
#       the import map.
#   (2) COMPATIBILITY: without the marker, `$page.title` remains a literal.
#   (3) SCRIPTY ERROR: a marked prop with an invalid expression fails with the
#       page, component source, and expression in the diagnostic.
#   (4) NEGATIVE PIN: the identical page, but with the fence's `<z-island>`
#       swapped for the plain `<island>` spelling, FAILS the build with
#       superhtml's `invalid_html_tag_name` diagnostic, attributed to the
#       `.smd` file. This is what documents *why* the hyphen is mandatory,
#       and it will fail loudly (not silently pass) if a future supermd/
#       superhtml sync relaxes or renames that validation.
#   (5) CONTROL: the same fixture with the fence removed entirely builds
#       clean — so (1) and (2) are attributable to the fence content, not to
#       some unrelated break in the shared fixture.
#   (6) MARKDOWN SLOTS: `markdown-slot-NAME="section-id"` moves native
#       SuperMD sections into named island slots, preserving Markdown rendering
#       and fenced-code highlighting without leaking the source sections.
#   (7) MISSING SLOT SECTION: a reference to an unknown section fails loudly
#       with the component and missing section id in the diagnostic.
#   (8) UNUSED SLOT SECTION: a marked section that no island references fails
#       instead of silently disappearing from the page.
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
  ln -s "$REPO/runtime/node_modules" "$dir/node_modules"
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
  cat > "$dir/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "preact",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "target": "ESNext"
  }
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
export interface Props { start: number; page_title: string; site_title: string }
export default function Counter({ start, page_title, site_title }: Props) {
  return `CONTENT-ISLAND-SSR-${start}-${page_title}-${site_title}`;
}
EOF
  cat > "$dir/components/Tabs.island.tsx" <<'EOF'
import type { ComponentChildren } from "preact";
export interface Props { label: string }
type SlotProps = Props & {
  children?: ComponentChildren;
  slots?: Record<string, ComponentChildren>;
};
export default function Tabs({ label, children, slots }: SlotProps) {
  return <section data-tabs={label}>
    <div data-panel="default">{children}</div>
    <div data-panel="admin">{slots?.admin}</div>
    <div data-panel="terminal">{slots?.terminal}</div>
  </section>;
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
      "--island-sidecar=$REPO/runtime/sidecar/render.ts" --island-src-dir=. \
      --island-props-check=error )
}

# --- (1) positive: <z-island> in an =html fence builds and SSRs -------------
SITE_POS="$WORK/pos"; OUT_POS="$WORK/out-pos"
write_site "$SITE_POS" '```=html
<z-island src="components/Counter.island.tsx" client:load scripty:props
          :props='"'"'{ .start = 5 }'"'"'
          prop-page_title="$page.title" prop-site_title="$site.title"></z-island>
```'
release "$SITE_POS" "$OUT_POS" >"$WORK/pos.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/pos.log"; fail "positive build (z-island in an =html fence) failed"; }

INDEX_POS="$OUT_POS/index.html"
[[ -f "$INDEX_POS" ]] || fail "positive build did not emit index.html"
grep -q 'CONTENT-ISLAND-SSR-5-Home-Content Island Test' "$INDEX_POS" \
  || { cat "$INDEX_POS"; fail "emitted HTML is missing the SSR'd island markup"; }
grep -q 'data-z-props="z-island-0">' "$INDEX_POS" \
  || { cat "$INDEX_POS"; fail "emitted HTML is missing the data-z-props script"; }
for expected_prop in '"start":5' '"page_title":"Home"' '"site_title":"Content Island Test"'; do
  grep -q "$expected_prop" "$INDEX_POS" \
    || { cat "$INDEX_POS"; fail "emitted data-z-props is missing $expected_prop"; }
done
grep -q '<script type="importmap">' "$INDEX_POS" \
  || { cat "$INDEX_POS"; fail "emitted HTML is missing the import map"; }
if grep -q '<z-island' "$INDEX_POS"; then
  cat "$INDEX_POS"
  fail "the literal <z-island tag survived into the output (not rewritten)"
fi
echo "PASS: a <z-island> inside an =html fence evaluates page/site props, typechecks, and SSRs"

# --- (2) no marker: preserve the historical literal-dollar behavior --------
SITE_LITERAL="$WORK/literal"; OUT_LITERAL="$WORK/out-literal"
write_site "$SITE_LITERAL" '```=html
<z-island src="components/Counter.island.tsx" client:load
          :props='"'"'{ .start = 5, .site_title = "static" }'"'"'
          prop-page_title="$page.title"></z-island>
```'
release "$SITE_LITERAL" "$OUT_LITERAL" >"$WORK/literal.log" 2>&1 \
  || { sed -n '1,60p' "$WORK/literal.log"; fail "unmarked compatibility build failed"; }
grep -q 'CONTENT-ISLAND-SSR-5-\$page.title-static' "$OUT_LITERAL/index.html" \
  || { cat "$OUT_LITERAL/index.html"; fail "unmarked dollar-prefixed prop was not preserved literally"; }
echo "PASS: an unmarked content-island prop keeps its dollar-prefixed value literal"

# --- (3) bad Scripty expression: attributed, actionable build failure -------
SITE_EXPR="$WORK/expr"; OUT_EXPR="$WORK/out-expr"
write_site "$SITE_EXPR" '```=html
<z-island src="components/Counter.island.tsx" client:load scripty:props
          :props='"'"'{ .start = 5 }'"'"'
          prop-page_title="$page.not_a_field" prop-site_title="$site.title"></z-island>
```'
set +e
release "$SITE_EXPR" "$OUT_EXPR" >"$WORK/expr.log" 2>&1
EXPR_RC=$?
set -e
[[ "$EXPR_RC" -ne 0 ]] || fail "an invalid marked Scripty prop built successfully"
grep -q 'content-island prop evaluation failed on content/index.smd: components/Counter.island.tsx' "$WORK/expr.log" \
  || { sed -n '1,60p' "$WORK/expr.log"; fail "Scripty prop failure lacks page/component attribution"; }
grep -q '\$page.not_a_field' "$WORK/expr.log" \
  || { sed -n '1,60p' "$WORK/expr.log"; fail "Scripty prop failure lacks the bad expression"; }
echo "PASS: an invalid marked Scripty prop fails with page, component, and expression context"

# --- (4) negative pin: plain <island> in the SAME fence fails validation ----
SITE_NEG="$WORK/neg"; OUT_NEG="$WORK/out-neg"
write_site "$SITE_NEG" '```=html
<island src="components/Counter.island.tsx" client:load scripty:props :props='"'"'{ .start = 5 }'"'"'
        prop-page_title="$page.title" prop-site_title="$site.title"></island>
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

# --- (5) control: same fixture, no fence at all -> builds clean -------------
SITE_CTRL="$WORK/ctrl"; OUT_CTRL="$WORK/out-ctrl"
write_site "$SITE_CTRL" 'No fence here at all, just prose.'
release "$SITE_CTRL" "$OUT_CTRL" >"$WORK/ctrl.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/ctrl.log"; fail "control build (no fence) failed -- the fixture itself is broken, so parts (1) and (2) prove nothing"; }
[[ -f "$OUT_CTRL/index.html" ]] || fail "control build did not emit index.html"
echo "PASS: the same fixture with the fence removed builds clean (control)"

# --- (6) native SuperMD sections become rendered island slots ---------------
SITE_SLOTS="$WORK/slots"; OUT_SLOTS="$WORK/out-slots"
write_site "$SITE_SLOTS" '```=html
<z-island src="components/Tabs.island.tsx" client:load
          :props='"'"'{ .label = "Setup" }'"'"'
          markdown-slot="intro"
          markdown-slot-admin="admin-steps"
          markdown-slot-terminal="terminal-steps"></z-island>
```

[]($section.id('"'"'intro'"'"').attrs('"'"'island-slot'"'"'))

Start with the **shared prerequisites**.

[]($section.id('"'"'admin-steps'"'"').attrs('"'"'island-slot'"'"'))

**Use the admin UI.**

```zig
const admin_answer: u8 = 42;
```

[]($section.id('"'"'terminal-steps'"'"').attrs('"'"'island-slot'"'"'))

_Use the terminal._

```js
const terminalAnswer = 42;
```

[]($section.attrs('"'"'island-slot-end'"'"'))'
release "$SITE_SLOTS" "$OUT_SLOTS" >"$WORK/slots.log" 2>&1 \
  || { sed -n '1,80p' "$WORK/slots.log"; fail "rendered-Markdown slot build failed"; }
INDEX_SLOTS="$OUT_SLOTS/index.html"
grep -q 'data-z-slot="admin"' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "admin named slot was not SSR'd"; }
grep -q 'data-z-slot="terminal"' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "terminal named slot was not SSR'd"; }
grep -q 'data-z-slot="default"' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "default Markdown slot was not SSR'd as children"; }
grep -q 'shared prerequisites' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "default slot Markdown was not rendered"; }
grep -q '<strong>Use the admin UI.</strong>' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "admin slot Markdown was not rendered"; }
grep -q '<em>Use the terminal.</em>' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "terminal slot Markdown was not rendered"; }
grep -q 'admin_answer' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "admin slot fenced code was not rendered"; }
grep -q 'terminalAnswer' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "terminal slot fenced code was not rendered"; }
grep -q '<code class="zig"><span class="keyword">const</span>' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "admin slot Zig fence did not receive tree-sitter highlighting"; }
grep -q '<code class="js"><span class="keyword">const</span>' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "terminal slot JS fence did not receive tree-sitter highlighting"; }
grep -q 'data-z-slots="z-island-0"' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "named slots are missing from the hydration payload"; }
if grep -q '<z-markdown-slot-source' "$INDEX_SLOTS"; then
  cat "$INDEX_SLOTS"
  fail "a Markdown slot source reservoir leaked into emitted HTML"
fi
grep -q '<p>More prose.</p>' "$INDEX_SLOTS" \
  || { cat "$INDEX_SLOTS"; fail "ordinary prose after island-slot-end was not rendered"; }
if grep 'data-z-slots="z-island-0"' "$INDEX_SLOTS" | grep -q 'More prose'; then
  cat "$INDEX_SLOTS"
  fail "island-slot-end left following page prose inside the final slot"
fi
echo "PASS: named island slots receive native rendered Markdown and highlighted code fences"

# --- (7) unknown referenced section: actionable build failure --------------
SITE_MISSING="$WORK/missing-slot"; OUT_MISSING="$WORK/out-missing-slot"
write_site "$SITE_MISSING" '```=html
<z-island src="components/Tabs.island.tsx" client:load
          :props='"'"'{ .label = "Setup" }'"'"'
          markdown-slot-admin="does-not-exist"></z-island>
```'
set +e
release "$SITE_MISSING" "$OUT_MISSING" >"$WORK/missing-slot.log" 2>&1
MISSING_RC=$?
set -e
[[ "$MISSING_RC" -ne 0 ]] || fail "an unknown markdown-slot section built successfully"
grep -q "components/Tabs.island.tsx" "$WORK/missing-slot.log" \
  || { sed -n '1,80p' "$WORK/missing-slot.log"; fail "missing-section diagnostic lacks component source"; }
grep -q "does-not-exist" "$WORK/missing-slot.log" \
  || { sed -n '1,80p' "$WORK/missing-slot.log"; fail "missing-section diagnostic lacks section id"; }
echo "PASS: an unknown markdown-slot section fails with component and section context"

# --- (8) unreferenced marked section: never silently drop page content ------
SITE_UNUSED="$WORK/unused-slot"; OUT_UNUSED="$WORK/out-unused-slot"
write_site "$SITE_UNUSED" '[]($section.id('"'"'orphaned-steps'"'"').attrs('"'"'island-slot'"'"'))

This content must not disappear silently.'
set +e
release "$SITE_UNUSED" "$OUT_UNUSED" >"$WORK/unused-slot.log" 2>&1
UNUSED_RC=$?
set -e
[[ "$UNUSED_RC" -ne 0 ]] || fail "an unreferenced island-slot section built successfully"
grep -q "orphaned-steps" "$WORK/unused-slot.log" \
  || { sed -n '1,80p' "$WORK/unused-slot.log"; fail "unused-section diagnostic lacks section id"; }
grep -q "not referenced" "$WORK/unused-slot.log" \
  || { sed -n '1,80p' "$WORK/unused-slot.log"; fail "unused-section diagnostic is not actionable"; }
echo "PASS: an unused island-slot section fails instead of silently dropping content"

echo "ALL PASS: content islands support Scripty props and rendered-Markdown slots"
