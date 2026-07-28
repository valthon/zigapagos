#!/usr/bin/env bash
# site/test/docs-mirror.sh — the docs mirror is generated, complete, and fresh.
#
# Mirrors are gitignored build artifacts. This asserts three things the site
# silently depends on: that every registry entry produces a file, that the
# generated frontmatter is Ziggy (not YAML, which SuperMD would reject), and
# that regenerating produces no diff — i.e. the generator is deterministic and
# nobody has hand-edited a mirror.
#
# This script is the copyable freshness gate referenced by
# docs/generated-content.md. Adapting it to another project is editing the
# variables below; everything after them is structural and should not need to
# change.
set -euo pipefail
cd "$(dirname "$0")/.."

GENERATOR=scripts/gen-docs-mirror.ts
REGISTRY=scripts/docs-registry.json
MIRROR_DIR=content/docs
BUILD_OUT=zig-out/site
PAGE_PATH_PREFIX=docs          # a mirror with slug X is emitted at $BUILD_OUT/$PAGE_PATH_PREFIX/X/index.html
BUILD_CMD=(zig build)          # bash array; invoked as "${BUILD_CMD[@]}"
UNIT_TESTS=test/md-to-smd.test.ts

# Pure-transform unit tests for the generic module the generator is built on
# (see docs/generated-content.md). Run first and unconditionally: a failure
# here means the generator itself is producing wrong output, and every check
# below this line would otherwise be diagnosing symptoms of that. They run
# from inside this gate rather than as their own CI step so that a project
# adopting the recipe gets both halves by wiring up one entry point.
bun test "$UNIT_TESTS"

bun run "$GENERATOR"

MISSING=0
while IFS= read -r mirror; do
  if [ ! -f "$MIRROR_DIR/$mirror" ]; then
    echo "FAIL: registry entry produced no file: $MIRROR_DIR/$mirror"
    MISSING=1
  fi
done < <(REGISTRY="$REGISTRY" bun -e 'for (const e of require("./" + process.env.REGISTRY)) console.log(e.mirror)')
[ "$MISSING" -eq 0 ] || exit 1

# Ziggy frontmatter, not YAML: the first line must be `---` and the second
# must be a Ziggy field assignment. BOTH are checked. Asserting only the
# second would let a mirror that lost its opening delimiter through — the
# `.title` line alone is equally consistent with a file that has no
# frontmatter block at all — and the failure would then surface much later,
# out of SuperMD's parser, pointing at the page rather than at the generator
# that wrote it.
while IFS= read -r mirror; do
  head -1 "$MIRROR_DIR/$mirror" | grep -qE '^---[[:space:]]*$' \
    || { echo "FAIL: $mirror does not open with a --- frontmatter delimiter"; exit 1; }
  head -2 "$MIRROR_DIR/$mirror" | tail -1 | grep -qE '^\s*\.title = ' \
    || { echo "FAIL: $mirror has no Ziggy .title in frontmatter"; exit 1; }
done < <(REGISTRY="$REGISTRY" bun -e 'for (const e of require("./" + process.env.REGISTRY)) console.log(e.mirror)')

# Determinism: a second run must not change anything.
BEFORE=$(cat "$MIRROR_DIR"/*.smd | shasum | cut -d' ' -f1)
bun run "$GENERATOR" >/dev/null
AFTER=$(cat "$MIRROR_DIR"/*.smd | shasum | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL: generator is not deterministic"; exit 1; }

# No mirror may be committed — they are build artifacts.
while IFS= read -r mirror; do
  if git ls-files --error-unmatch "$MIRROR_DIR/$mirror" >/dev/null 2>&1; then
    echo "FAIL: mirror is tracked in git: $MIRROR_DIR/$mirror"
    exit 1
  fi
done < <(REGISTRY="$REGISTRY" bun -e 'for (const e of require("./" + process.env.REGISTRY)) console.log(e.mirror)')

# Regression pin: a heading id must never be carried by wrapping the
# heading's OWN text in a link. A heading whose text already contains
# `[`/`]` (e.g. CHANGELOG's `## [Unreleased]`, a reference-style link) would
# then nest a link inside a link, which CommonMark refuses to parse — the
# `$heading.id(...)` directive leaks into the page as literal text and the
# heading gets no id at all. `[[` is what that mistake looks like in the
# generated markdown; the generator instead prefixes a leading EMPTY link
# (`[]($heading.id(...))`), which can never produce it. This glob deliberately
# covers every *.smd in $MIRROR_DIR, not just registry entries — an authored
# page living alongside the mirrors is worth checking too, and narrowing this
# to the registry would be a strictly weaker gate for no benefit.
if grep -l '\[\[' "$MIRROR_DIR"/*.smd >/dev/null 2>&1; then
  echo "FAIL: a mirror contains '[[' — a heading's own text was wrapped in a link instead of prefixed with an empty one"
  grep -l '\[\[' "$MIRROR_DIR"/*.smd
  exit 1
fi

# Same regression, checked at the other end: build the site and confirm no
# unparsed Scripty directive leaked into the rendered HTML as visible PROSE.
# A directive appearing inside a documented code sample (this project's own
# docs/generated-content.md shows `$heading.id(...)` and `$link.page(...)` as
# literal text on purpose) is not a leak — it's the same "sample text, not a
# real directive" reasoning the generator itself applies to fenced code
# blocks in the source. So strip <pre>/<code> elements before matching.
"${BUILD_CMD[@]}"
while IFS= read -r slug; do
  html="$BUILD_OUT/$PAGE_PATH_PREFIX/$slug/index.html"
  [ -f "$html" ] || continue
  if ! ZP_HTML="$html" bun -e '
    const src = require("fs").readFileSync(process.env.ZP_HTML, "utf8");
    const prose = src.replace(/<pre\b[\s\S]*?<\/pre>/g, "").replace(/<code\b[\s\S]*?<\/code>/g, "");
    process.exit(/\$heading\.id|\$link\.page/.test(prose) ? 1 : 0);
  '; then
    echo "FAIL: $html has a literal Scripty directive in its rendered prose"
    exit 1
  fi
done < <(REGISTRY="$REGISTRY" bun -e 'for (const e of require("./" + process.env.REGISTRY)) console.log(e.slug)')

echo PASS
