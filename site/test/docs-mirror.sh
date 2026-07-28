#!/usr/bin/env bash
# site/test/docs-mirror.sh — the docs mirror is generated, complete, and fresh.
#
# Mirrors are gitignored build artifacts. This asserts three things the site
# silently depends on: that every registry entry produces a file, that the
# generated frontmatter is Ziggy (not YAML, which SuperMD would reject), and
# that regenerating produces no diff — i.e. the generator is deterministic and
# nobody has hand-edited a mirror.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pure-transform unit tests for the module the generator is built on. Run
# first and unconditionally: a failure here means the generator itself is
# producing wrong output, and every check below this line would otherwise be
# diagnosing symptoms of that.
bun test test/md-to-smd.test.ts

bun run scripts/gen-docs-mirror.ts

MISSING=0
while IFS= read -r mirror; do
  if [ ! -f "content/docs/$mirror" ]; then
    echo "FAIL: registry entry produced no file: content/docs/$mirror"
    MISSING=1
  fi
done < <(bun -e 'for (const e of require("./scripts/docs-registry.json")) console.log(e.mirror)')
[ "$MISSING" -eq 0 ] || exit 1

# Ziggy frontmatter, not YAML: the first line must be `---` and the second
# must be a Ziggy field assignment.
while IFS= read -r mirror; do
  head -2 "content/docs/$mirror" | tail -1 | grep -qE '^\s*\.title = ' \
    || { echo "FAIL: $mirror has no Ziggy .title in frontmatter"; exit 1; }
done < <(bun -e 'for (const e of require("./scripts/docs-registry.json")) console.log(e.mirror)')

# Determinism: a second run must not change anything.
BEFORE=$(cat content/docs/*.smd | shasum | cut -d' ' -f1)
bun run scripts/gen-docs-mirror.ts >/dev/null
AFTER=$(cat content/docs/*.smd | shasum | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL: generator is not deterministic"; exit 1; }

# No mirror may be committed — they are build artifacts.
while IFS= read -r mirror; do
  if git ls-files --error-unmatch "content/docs/$mirror" >/dev/null 2>&1; then
    echo "FAIL: mirror is tracked in git: content/docs/$mirror"
    exit 1
  fi
done < <(bun -e 'for (const e of require("./scripts/docs-registry.json")) console.log(e.mirror)')

# Regression pin: a heading id must never be carried by wrapping the
# heading's OWN text in a link. A heading whose text already contains
# `[`/`]` (e.g. CHANGELOG's `## [Unreleased]`, a reference-style link) would
# then nest a link inside a link, which CommonMark refuses to parse — the
# `$heading.id(...)` directive leaks into the page as literal text and the
# heading gets no id at all. `[[` is what that mistake looks like in the
# generated markdown; the generator instead prefixes a leading EMPTY link
# (`[]($heading.id(...))`), which can never produce it.
if grep -l '\[\[' content/docs/*.smd >/dev/null 2>&1; then
  echo "FAIL: a mirror contains '[[' — a heading's own text was wrapped in a link instead of prefixed with an empty one"
  grep -l '\[\[' content/docs/*.smd
  exit 1
fi

# Same regression, checked at the other end: build the site and confirm no
# unparsed Scripty directive leaked into the rendered HTML as visible text.
zig build
while IFS= read -r slug; do
  html="zig-out/site/docs/$slug/index.html"
  [ -f "$html" ] || continue
  if grep -q '\$heading\.id\|\$link\.page' "$html"; then
    echo "FAIL: $html has a literal Scripty directive in its rendered output"
    exit 1
  fi
done < <(bun -e 'for (const e of require("./scripts/docs-registry.json")) console.log(e.slug)')

echo PASS
