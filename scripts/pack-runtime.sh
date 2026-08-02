#!/usr/bin/env bash
# pack-runtime.sh — build the release's `runtime.tar.xz` asset.
#
#   scripts/pack-runtime.sh <output-dir>
#
# WHY THIS ASSET EXISTS. The per-target release archives carry the zigapagos
# binary and nothing else, so an archive install cannot render an island: the
# sidecar, the bundlers and the runtime slicers are all scripts *inside* the
# @z/runtime tree, and that tree is not in the archive. npm gets it by shipping
# it inside `@zigapagos/cli`. Everyone else — and specifically install.sh, the
# curl installer — gets it from this asset.
#
# It is packed SELF-CONTAINED: `node_modules` is vendored, so the installer
# unpacks a tree that already resolves `preact` and never contacts a registry.
# An installer that ran `bun install` for the user would make an install that
# succeeded today capable of failing tomorrow, for reasons in someone else's
# infrastructure, on a release whose bytes never changed.
#
# WHAT GOES IN is not decided here: npm/stage-runtime.mjs owns the entry list and
# the exclusions, because `@zigapagos/cli` stages the same tree and the two
# channels must ship the same files. This script adds only node_modules on top.
#
# Requires: node (for the staging module), bun (to resolve dependencies), tar
# with xz support.
set -euo pipefail

OUT_DIR="${1:-}"
if [[ -z "$OUT_DIR" ]]; then
  echo "usage: scripts/pack-runtime.sh <output-dir>" >&2
  exit 2
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

for tool in node bun tar; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not found on PATH" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/runtime"

node "$REPO/npm/stage-runtime.mjs" "$STAGE"

# The lockfile comes along only for the install below; it is deleted afterwards
# so the shipped tree cannot be mistaken for something a consumer should
# `bun install` in. What ships is the resolved result, not the recipe.
cp "$REPO/runtime/bun.lock" "$STAGE/bun.lock"

# --- dependencies -----------------------------------------------------------
# TWO STEPS, and the split is load-bearing.
#
# 1. `--production` resolves `dependencies` — preact and preact-render-to-string
#    — at exactly the versions in the lockfile. `--frozen-lockfile` makes a
#    lockfile that no longer matches package.json a build failure rather than a
#    silent re-resolution, which is the whole point of packing from a lockfile.
#
# 2. typescript is in `devDependencies`, so step 1 correctly drops it — but it is
#    not dev-only at run time. `--island-props-check` shells out to `bun x tsc`,
#    and the per-SPA runtime slicer uses the compiler API; without it every SPA
#    page silently falls back to loading the whole shared runtime. `@zigapagos/cli`
#    ships it for the same reason, as an optionalDependency. Resolving it in a
#    SEPARATE directory and copying the result in is safe *because typescript has
#    no transitive dependencies*: there is no shared subgraph for the second
#    resolution to move out from under the first. That property is asserted below
#    rather than assumed.
#
# Why a separate directory rather than `bun add` in the staged tree. `bun add
# --no-save` against a tree that already has a lockfile is a NO-OP that reports
# success: it prints "installed typescript" and writes nothing, because --no-save
# leaves the lockfile authoritative and typescript is not in it. Dropping
# --no-save works, but then the shipped package.json carries a `dependencies`
# entry the repository's does not — and the two staged trees (this one and npm's)
# would no longer be byte-identical, which is the property that makes the shared
# staging module worth having. Copying sidesteps both.
#
# THE EXACT VERSION, FROM THE LOCKFILE — not the `^6.0.3` range in
# package.json. Resolving a range at pack time means rebuilding the same tag
# later can vendor a different typescript and produce a different
# `runtime.tar.xz` from identical sources. npm/publish.mjs states the principle
# this repository already holds itself to: "a rebuild — even from the same commit
# — is a second chance to be different." The lockfile is the only place an exact
# version exists, and step 1 above runs `--frozen-lockfile` over that same
# lockfile, so a lockfile that had drifted from package.json would have failed
# the build before this line is reached.
# shellcheck disable=SC2016 # the node program is a literal; $STAGE is spliced deliberately
TS_VERSION="$(node -e '
  const fs = require("node:fs");
  const src = fs.readFileSync(process.argv[1], "utf8");
  // Regex, not JSON.parse: bun.lock is JSONC (trailing commas), so it is not
  // valid JSON. The resolved entry is `"typescript": ["typescript@6.0.3", …]`;
  // the `@` is what distinguishes it from the range in the dependencies block.
  const m = src.match(/"typescript@([0-9][^"]*)"/);
  if (!m) {
    throw new Error(
      "pack-runtime: no resolved typescript version in runtime/bun.lock — the " +
      "lockfile format changed, or typescript is no longer a dependency."
    );
  }
  process.stdout.write(m[1]);
' "$REPO/runtime/bun.lock")"
echo "typescript $TS_VERSION (exact, from runtime/bun.lock)"
(
  cd "$STAGE"
  bun install --frozen-lockfile --production
)
(
  mkdir -p "$WORK/ts"
  cd "$WORK/ts"
  echo '{"name":"ts-resolve","version":"0.0.0"}' > package.json
  bun add --production "typescript@$TS_VERSION"
)
cp -R "$WORK/ts/node_modules/typescript" "$STAGE/node_modules/typescript"
# Relative, exactly as bun writes them, so they still resolve after the tarball is
# unpacked anywhere.
mkdir -p "$STAGE/node_modules/.bin"
ln -sfn ../typescript/bin/tsc "$STAGE/node_modules/.bin/tsc"
ln -sfn ../typescript/bin/tsserver "$STAGE/node_modules/.bin/tsserver"

# Anti-vacuity. Each of these has failed silently in some form during
# development: a `--production` that resolved nothing, a typescript add that
# no-op'd, a bun version that started hoisting differently. A tarball missing any
# of them still unpacks, still looks right, and then fails inside the sidecar with
# an error naming preact rather than naming this script.
for dep in preact preact-render-to-string typescript; do
  [[ -d "$STAGE/node_modules/$dep" ]] || {
    echo "FAIL: node_modules/$dep is missing from the staged runtime" >&2
    exit 1
  }
done

# The version actually vendored is the version the lockfile named. `bun add` with
# an exact spec should always satisfy this, which is the point: if it ever stops
# doing so the asset has silently become unreproducible again, and that is exactly
# the failure this pin exists to prevent.
PACKED_TS="$(node -e 'process.stdout.write(require("'"$STAGE"'/node_modules/typescript/package.json").version)')"
if [[ "$PACKED_TS" != "$TS_VERSION" ]]; then
  echo "FAIL: packed typescript is $PACKED_TS, runtime/bun.lock pins $TS_VERSION" >&2
  exit 1
fi

# `bun x tsc` is how the props-check gate runs the compiler, and it finds it
# through node_modules/.bin. Present as a relative symlink into the package, so
# it survives the tar.
[[ -e "$STAGE/node_modules/.bin/tsc" ]] || {
  echo "FAIL: node_modules/.bin/tsc is missing; --island-props-check would fetch" >&2
  echo "      typescript from the registry instead of using the packed one." >&2
  exit 1
}

# The other direction. `--production` is easy to drop from one of the two install
# lines and nothing downstream would notice — the tarball would just quietly grow
# the bun-test suite's dependencies.
for dev in happy-dom @types/bun @happy-dom; do
  if [[ -e "$STAGE/node_modules/$dev" ]]; then
    echo "FAIL: dev-only '$dev' was packed into the runtime asset; a --production" >&2
    echo "      flag is missing from one of the installs above." >&2
    exit 1
  fi
done

# The claim step 2 rests on. If typescript ever grows a dependency, the two-pass
# install stops being obviously safe and this fails rather than shipping a tree
# whose preact version was quietly re-resolved by the second pass.
TS_DEPS="$(node -e '
  const p = require("'"$STAGE"'/node_modules/typescript/package.json");
  process.stdout.write(Object.keys(p.dependencies ?? {}).join(","));
')"
if [[ -n "$TS_DEPS" ]]; then
  echo "FAIL: typescript now has dependencies ($TS_DEPS); the two-pass install in" >&2
  echo "      scripts/pack-runtime.sh is no longer safe — resolve it with the" >&2
  echo "      production deps in one pass instead." >&2
  exit 1
fi

rm -f "$STAGE/bun.lock"

# `tar -C "$WORK" runtime`, so the tarball has a single `runtime/` root: the
# installer extracts it into a version directory and gets `<version>/runtime`,
# with no --strip-components guesswork and no chance of spraying files into the
# extraction directory if the archive is ever repacked differently.
ARCHIVE="$OUT_DIR/runtime.tar.xz"
rm -f "$ARCHIVE"
tar -cJf "$ARCHIVE" -C "$WORK" runtime

echo "packed $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
