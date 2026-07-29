#!/usr/bin/env bash
# Regression test: `zigapagos explain <route>` (issue #47) -- resolves an
# output route to its content source, layout chain, frontmatter, islands,
# page assets and EMITTED PATHS.
#
# The highest-risk part of this command is the "emitted paths" section
# (H7 in the `dx/introspection` plan): a naive re-derivation from
# frontmatter (e.g. assuming the site's `url_path_prefix` belongs in a disk
# path) reproduces the exact defect issue #47 exists to fix. This script
# proves the derivation is REAL, not merely "looks plausible", two ways:
#   - FORWARD: every path `explain` prints for a route actually exists on
#     disk after a real `zigapagos release`.
#   - REVERSE (scoped to one route, not a whole-tree diff -- `out/` also
#     holds site assets, the runtime bundle, etc.): the set `explain` prints
#     equals the literal, hand-enumerated set this fixture is authored to
#     produce.
# Both checks are proven non-vacuous by MUTATING the derivation (skipping
# `.page_alias` hints) and confirming the reverse check goes red naming
# `overview.html` -- see step (4) below and the PR body for the captured
# failure output.
#
# This test spawns the REAL Bun sidecar for the `release` leg (needs bun on
# PATH + runtime/node_modules), matching tests/islands/content-island.sh's
# discipline. `explain` itself never needs bun -- every `explain` invocation
# below additionally runs with a minimal PATH to prove that.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

command -v bun >/dev/null 2>&1 || { echo "FAIL: bun not found on PATH (required for the release leg's real island sidecar)"; exit 1; }
if [[ ! -d "$REPO/runtime/node_modules" ]]; then
  echo "runtime/node_modules missing; running 'bun install --frozen-lockfile'..."
  ( cd "$REPO/runtime" && bun install --frozen-lockfile ) \
    || { echo "FAIL: bun install --frozen-lockfile failed in runtime/"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

SITE="$WORK/site"
mkdir -p "$SITE/content/docs/overview" "$SITE/layouts/templates" "$SITE/components"

cat >"$SITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Explain Fixture",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF

cat >"$SITE/layouts/templates/base.shtml" <<'EOF'
<!DOCTYPE html>
<html>
<head><title :text="$site.title"></title></head>
<body id="body">
  <super>
</body>
</html>
EOF

# The layout mounts ONE real island, plus a commented-out one and a code
# fence containing the literal text "<island" -- all three must be tokenizer-
# aware (pass.zig is comment- and raw-text-aware), so only the real, live
# island may show up in `explain`'s "islands:" section.
cat >"$SITE/layouts/page.shtml" <<'EOF'
<extend template="base.shtml">
<body id="body">
  <island src="components/Counter.island.tsx" client:load></island>
  <!-- <island src="components/Ghost.island.tsx" client:load></island> -->
  <div :html="$page.content()"></div>
</body>
EOF

cat >"$SITE/layouts/rss.shtml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss :html="$page.content()"></rss>
EOF

cat >"$SITE/components/Counter.island.tsx" <<'EOF'
export default function Counter() {
  return "EXPLAIN-FIXTURE-COUNTER";
}
EOF

cat >"$SITE/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "page.shtml",
---
Home page, linking to [docs]($link.sub('docs')).

A code fence with the literal text "<island" in it must NOT be picked up as
a real island instance:

```
<island src="components/Ghost.island.tsx" client:load></island>
```
EOF

cat >"$SITE/content/docs/index.smd" <<'EOF'
---
.title = "Docs",
.layout = "page.shtml",
---
Docs index, linking to [overview]($link.sub('overview')).
EOF

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

OUT="$WORK/out"
( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force --bun="$(command -v bun)" \
    "--island-sidecar=$REPO/runtime/sidecar/render.ts" --island-src-dir=. \
) >"$WORK/release.log" 2>&1 \
  || { sed -n '1,60p' "$WORK/release.log"; fail "the fixture's 'zigapagos release' failed"; }

# stdout and stderr are captured to SEPARATE files, not merged with 2>&1.
# `explain`'s report goes through a buffered stdout Writer, flushed once at
# the very end; the Debug-build banner (`main.zig`) goes to stderr via
# unbuffered `std.debug.print`, immediately. When both are redirected to the
# SAME file descriptor, each writer tracks its own file position
# independently and the LATER flush (the report) overwrites the START of
# whatever the earlier one already wrote -- a real, pre-existing corruption
# (reproduced identically with `zigapagos doctor`, so it's not new to this
# PR) that would silently break exact structured-content parsing (the
# FORWARD/REVERSE emitted-paths checks below) if the two streams shared a
# file. Tracked as issue #78; this helper is the workaround, not the fix.
# `.log` is the two concatenated IN A DETERMINISTIC ORDER (this
# script's own `cat`, not an OS-level write race) for the substring checks
# that don't care which stream a message landed on.
run() { # $1 = tag, remaining = explain args
  local tag="$1"; shift
  set +e
  ( cd "$SITE" && env PATH=/usr/bin:/bin "$ZIGAPAGOS" explain "$@" ) >"$WORK/$tag.out" 2>"$WORK/$tag.err"
  echo $? >"$WORK/$tag.rc"
  set -e
  cat "$WORK/$tag.out" "$WORK/$tag.err" >"$WORK/$tag.log"
}

# --- (2) resolve /docs/overview/ --------------------------------------------
run overview /docs/overview/
[[ "$(cat "$WORK/overview.rc")" -eq 0 ]] || {
  echo "--- output ---"; cat "$WORK/overview.log"
  fail "(2) 'explain /docs/overview/' must exit 0"
}
grep -q "source: content/docs/overview/index.smd" "$WORK/overview.out" || {
  echo "--- output ---"; cat "$WORK/overview.log"
  fail "(2) wrong or missing source line"
}
echo "PASS (2): resolves /docs/overview/ to its content source"

# --- (3) FORWARD: every emitted path explain prints exists under $OUT ------
mapfile -t EMITTED < <(sed -n '/^emitted paths/,$ p' "$WORK/overview.out" | tail -n +2 | sed -n 's/^  \([^ ]*\)   .*/\1/p')
[[ "${#EMITTED[@]}" -gt 0 ]] || { cat "$WORK/overview.log"; fail "(3) parsed zero emitted paths out of explain's report"; }
for p in "${EMITTED[@]}"; do
  [[ -f "$OUT/$p" ]] || { cat "$WORK/overview.log"; fail "(3) FORWARD check: explain printed '$p' but it does not exist under \$OUT"; }
done
echo "PASS (3): FORWARD -- every path explain printed for /docs/overview/ exists on disk"

# --- (4) REVERSE (scoped to this route): the printed set equals the
# hand-enumerated set this fixture is authored to produce. Proven
# non-vacuous below by mutating the derivation.
EXPECTED_SORTED="docs/overview/index.html
docs/overview/index.xml
overview.html"
ACTUAL_SORTED="$(printf '%s\n' "${EMITTED[@]}" | sort)"
[[ "$ACTUAL_SORTED" == "$EXPECTED_SORTED" ]] || {
  echo "--- expected ---"; echo "$EXPECTED_SORTED"
  echo "--- actual ---"; echo "$ACTUAL_SORTED"
  fail "(4) REVERSE check: emitted-path set does not match the fixture's authored set"
}
echo "PASS (4): REVERSE -- emitted-path set exactly matches the fixture's authored set"

# --- (5) alias route resolves to the same source ----------------------------
run alias-route /overview.html
[[ "$(cat "$WORK/alias-route.rc")" -eq 0 ]] || {
  echo "--- output ---"; cat "$WORK/alias-route.log"
  fail "(5) 'explain /overview.html' (the alias route) must exit 0"
}
grep -q "source: content/docs/overview/index.smd" "$WORK/alias-route.out" || {
  echo "--- output ---"; cat "$WORK/alias-route.log"
  fail "(5) alias route resolved to the wrong source"
}
echo "PASS (5): alias route /overview.html resolves to the same source"

# --- (6) raw index.html route resolves -------------------------------------
run raw-route /docs/overview/index.html
[[ "$(cat "$WORK/raw-route.rc")" -eq 0 ]] || {
  echo "--- output ---"; cat "$WORK/raw-route.log"
  fail "(6) 'explain /docs/overview/index.html' (raw route) must exit 0"
}
grep -q "source: content/docs/overview/index.smd" "$WORK/raw-route.out" || {
  echo "--- output ---"; cat "$WORK/raw-route.log"
  fail "(6) raw route resolved to the wrong source"
}
echo "PASS (6): raw route /docs/overview/index.html resolves"

# --- (7) a miss names the route and says SPA routes aren't covered ---------
run miss /docs/nope/
[[ "$(cat "$WORK/miss.rc")" -eq 1 ]] || {
  echo "--- output ---"; cat "$WORK/miss.log"
  fail "(7) a route that resolves to nothing must exit 1"
}
grep -q "/docs/nope/" "$WORK/miss.log" || {
  echo "--- output ---"; cat "$WORK/miss.log"
  fail "(7) the miss message must name the route"
}
grep -qi "SPA" "$WORK/miss.log" || {
  echo "--- output ---"; cat "$WORK/miss.log"
  fail "(7) the miss message must mention SPA routes are not covered"
}
echo "PASS (7): a miss names the route and mentions SPA coverage"

# --- (8) islands list is exactly Counter -- not the commented-out Ghost,
# not the code-fence literal text ("<island" inside a plain fence on the
# homepage AND inside the commented-out tag on this very page).
ISLANDS_SECTION="$(sed -n '/^islands:/,/^page assets:/p' "$WORK/overview.out")"
echo "$ISLANDS_SECTION" | grep -q "components/Counter.island.tsx" || {
  echo "--- islands section ---"; echo "$ISLANDS_SECTION"
  fail "(8) Counter.island.tsx is missing from the islands list"
}
echo "$ISLANDS_SECTION" | grep -q "Ghost" && {
  echo "--- islands section ---"; echo "$ISLANDS_SECTION"
  fail "(8) the commented-out Ghost island must NOT appear in the islands list"
}
[[ "$(echo "$ISLANDS_SECTION" | grep -c "Counter.island.tsx")" -eq 1 ]] || {
  echo "--- islands section ---"; echo "$ISLANDS_SECTION"
  fail "(8) Counter.island.tsx must appear exactly once"
}
echo "PASS (8): islands list contains exactly Counter.island.tsx"

# --- (9) page assets: unused.png NOT referenced + absent from \$OUT;
# diagram.svg referenced + present.
grep -q "unused.png.*NOT referenced" "$WORK/overview.out" || {
  echo "--- output ---"; cat "$WORK/overview.log"
  fail "(9) unused.png must be reported as NOT referenced"
}
[[ -f "$OUT/docs/overview/unused.png" ]] && fail "(9) unused.png must be ABSENT from \$OUT (never referenced -> pruned)"
grep -q "diagram.svg.*referenced" "$WORK/overview.out" || {
  echo "--- output ---"; cat "$WORK/overview.log"
  fail "(9) diagram.svg must be reported as referenced"
}
[[ -f "$OUT/docs/overview/diagram.svg" ]] || fail "(9) diagram.svg must be PRESENT under \$OUT (referenced -> installed)"
echo "PASS (9): page-asset referenced/pruned status matches the real output tree"

# --- (10) an EXTENSIONLESS route with no trailing slash resolves too.
# This is explain's one deliberate addition over serve.zig's resolution
# (serve never needs it -- a browser navigates to an explicit URL; a route
# typed on a command line benefits from the directory-index retry). It is
# a distinct code path from (2)/(6), so it gets its own pin.
run extensionless /docs/overview
[[ "$(cat "$WORK/extensionless.rc")" -eq 0 ]] || {
  echo "--- output ---"; cat "$WORK/extensionless.log"
  fail "(10) 'explain /docs/overview' (extensionless, no trailing slash) must exit 0"
}
grep -q "source: content/docs/overview/index.smd" "$WORK/extensionless.out" || {
  echo "--- output ---"; cat "$WORK/extensionless.log"
  fail "(10) the extensionless route must resolve to the same source as /docs/overview/"
}
echo "PASS (10): an extensionless route resolves via the directory-index retry"

# --- (10a) an ALTERNATIVE route reports the ALTERNATIVE's layout ------------
# The fixture's `rss` alternative renders /docs/overview/index.xml through
# `rss.shtml`, NOT through the page's `page.shtml`. Reporting the page's
# layout here would be this command's own defect class in miniature -- a
# report describing something the build does not do (#47) -- so both halves
# are pinned: the right layout IS named, and the wrong one is NOT.
#
# Proven non-vacuous: reverting printReport to print `page.layout`
# unconditionally makes this case fail on the first grep (report says
# "layout: page.shtml").
run alt-route /docs/overview/index.xml
[[ "$(cat "$WORK/alt-route.rc")" -eq 0 ]] || {
  echo "--- output ---"; cat "$WORK/alt-route.log"
  fail "(10a) 'explain /docs/overview/index.xml' (an alternative route) must exit 0"
}
grep -q "^layout: rss.shtml$" "$WORK/alt-route.out" || {
  echo "--- output ---"; cat "$WORK/alt-route.log"
  fail "(10a) an alternative route must report the ALTERNATIVE's layout (rss.shtml)"
}
if grep -q "^layout: page.shtml$" "$WORK/alt-route.out"; then
  echo "--- output ---"; cat "$WORK/alt-route.log"
  fail "(10a) an alternative route must NOT report the page's layout"
fi
grep -q "this route is the 'rss' alternative" "$WORK/alt-route.out" || {
  echo "--- output ---"; cat "$WORK/alt-route.log"
  fail "(10a) an alternative route must say which alternative it is"
}
# The MAIN route is unaffected -- the alternative lookup must not leak into it.
grep -q "^layout: page.shtml$" "$WORK/overview.out" || {
  echo "--- output ---"; cat "$WORK/overview.log"
  fail "(10a) the main route must still report the page's own layout"
}
echo "PASS (10a): an alternative route reports its own layout, not the page's"

# --- (11)+(12) url_path_prefix: THE H7 REGRESSION GUARD ---------------------
# Issue #47 exists because a document claimed a deploy tree no build emits.
# `url_path_prefix` is a SERVING prefix: it changes which ROUTE reaches a
# page and must NEVER appear in an emitted DISK path. Adding it to the
# fixture config lets us pin both halves of that rule at once.
#
# Proven non-vacuous: appending the prefix to worker.zig's `pageDir` result
# (i.e. treating the serving prefix as a disk prefix -- exactly the #47
# defect) makes (12) fail with
#   expected: docs/overview/index.html ... actual: zigapagos/docs/overview/index.html
python3 - "$SITE/zigapagos.ziggy" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
assert ".url_path_prefix" not in s
s = s.replace('.assets_dir_path = "content",',
              '.assets_dir_path = "content",\n    .url_path_prefix = "zigapagos",')
io.open(p, "w", encoding="utf-8").write(s)
PYEOF

# (11) the UNPREFIXED route now misses, and says how to spell it.
run prefixed-miss /docs/overview/
[[ "$(cat "$WORK/prefixed-miss.rc")" -ne 0 ]] || {
  echo "--- output ---"; cat "$WORK/prefixed-miss.log"
  fail "(11) with a url_path_prefix set, the unprefixed route must NOT resolve"
}
grep -q "url_path_prefix" "$WORK/prefixed-miss.log" || {
  echo "--- output ---"; cat "$WORK/prefixed-miss.log"
  fail "(11) the miss must name url_path_prefix as the reason"
}
grep -q "/zigapagos/docs/overview/" "$WORK/prefixed-miss.log" || {
  echo "--- output ---"; cat "$WORK/prefixed-miss.log"
  fail "(11) the miss must suggest the prefixed spelling"
}
echo "PASS (11): url_path_prefix miss names the reason and suggests the prefixed route"

# (12) the PREFIXED route resolves, and its emitted paths are byte-identical
# to the no-prefix run -- the serving prefix does not leak into disk paths.
run prefixed-hit /zigapagos/docs/overview/
[[ "$(cat "$WORK/prefixed-hit.rc")" -eq 0 ]] || {
  echo "--- output ---"; cat "$WORK/prefixed-hit.log"
  fail "(12) 'explain /zigapagos/docs/overview/' must resolve when url_path_prefix is set"
}
mapfile -t EMITTED_PREFIXED < <(sed -n '/^emitted paths/,$ p' "$WORK/prefixed-hit.out" | tail -n +2 | sed -n 's/^  \([^ ]*\)   .*/\1/p')
ACTUAL_PREFIXED_SORTED="$(printf '%s\n' "${EMITTED_PREFIXED[@]}" | sort)"
[[ "$ACTUAL_PREFIXED_SORTED" == "$EXPECTED_SORTED" ]] || {
  echo "--- expected (identical to the no-prefix run) ---"; echo "$EXPECTED_SORTED"
  echo "--- actual ---"; echo "$ACTUAL_PREFIXED_SORTED"
  fail "(12) H7: url_path_prefix is a SERVING prefix and must not appear in any emitted DISK path"
}
echo "PASS (12): H7 -- url_path_prefix changes the ROUTE, never an emitted disk path"

echo "ALL PASS: tests/explain/explain.sh"
