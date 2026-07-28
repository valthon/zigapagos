#!/usr/bin/env bash
# A site with islands/SPAs can be built by a PREBUILT zigapagos (`zigapagos = .path`),
# not only from source.
#
# This used to be rejected at configure time. `build/site.zig` panicked in both
# `website()` and `serve()` on `zigapagos = .path` whenever islands or SPAs were
# declared, on the grounds that "a registry of the site's components" had to be
# compiled into the binary. That was true of the retired Zig-island/wasm path and
# is not true of TSX islands: SSR happens in the Bun sidecar, which reaches the
# binary as `--island-sidecar=`, and every other input is a CLI argument or a
# bundled asset. The comment six lines below the panic said so ("no comptime
# registry, no wasm ... the empty registry") while the panic said the opposite.
#
# The cost of the stale restriction was not theoretical: a consumer declaring one
# island had to compile the generator and its whole dependency tree — 653 compile
# steps, 632 of them tree-sitter grammar objects for 82 languages — to produce a
# site whose own build work is under a second. On a 2-core CI runner that was
# ~6 minutes per deploy.
#
# What this pins:
#   1. configure succeeds with islands + SPAs + `zigapagos = .path` (the panic is gone)
#   2. the resulting site is byte-identical to the from-source build
#
# (2) is the one that matters. (1) alone would pass against a binary that silently
# skipped SSR.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The fixture already declares four islands and five SPAs.
fixture=examples/tsx-site
grep -q 'zigapagos.Island' "$fixture/build.zig" || fail "$fixture no longer declares islands"

echo "building the generator once..."
zig build -Doptimize=ReleaseFast
exe="$root/zig-out/bin/zigapagos"
[ -x "$exe" ] || fail "no binary at $exe"

manifest() { # manifest <site-dir> -> checksum listing on stdout
    (cd "$1" && find . -type f | sort | while IFS= read -r f; do
        printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
    done)
}

# Absolute paths in the restore, deliberately. An earlier version registered a
# trap using the bare name `build.zig` from inside a pushd — traps fire at script
# exit, by which point popd has run, so the restore copied the FIXTURE's build.zig
# over the REPO ROOT's on every invocation.
fixture_build="$root/$fixture/build.zig"
cp "$fixture_build" "$work/build.zig.orig"
restore() { command cp -f "$work/build.zig.orig" "$fixture_build"; }
trap 'restore; rm -rf "$work"' EXIT

pushd "$fixture" > /dev/null

# Same prep the sibling fixture scripts do (examples/tsx-site/test/ssr.sh): the
# island bundler resolves `preact` upward from runtime/src, and this fixture's
# npm-compat island imports a local workspace package. Without both installs the
# bundle step fails on unresolved imports, which looks like a code defect and is not.
(cd ../../runtime && bun install --frozen-lockfile > /dev/null)
bun install --frozen-lockfile > /dev/null

echo "A: building from source..."
rm -rf zig-out
zig build
manifest zig-out/site > "$work/from-source.txt"
[ -s "$work/from-source.txt" ] || fail "from-source build produced no files"

echo "B: building with a prebuilt binary (zigapagos = .path)..."
# Inject the option next to `.output_path`, which website() callers always set.
python3 - "$exe" << 'PY'
import sys
p = "build.zig"
s = open(p).read()
assert ".zigapagos = ." not in s, "fixture already pins a zigapagos source"
needle = '.output_path = "site",'
assert needle in s, "fixture no longer sets .output_path — update this test"
s = s.replace(needle, '.zigapagos = .{ .path = "%s" },\n        %s' % (sys.argv[1], needle), 1)
open(p, "w").write(s)
PY
rm -rf zig-out
zig build
manifest zig-out/site > "$work/prebuilt.txt"
restore
popd > /dev/null

cmp -s "$work/from-source.txt" "$work/prebuilt.txt" \
    || { echo "--- from-source vs prebuilt ---"; command diff "$work/from-source.txt" "$work/prebuilt.txt" | head -20; \
         fail "a prebuilt binary produced a different site than the from-source build"; }

echo "PASS: prebuilt zigapagos builds an islands+SPA site byte-identically ($(wc -l < "$work/from-source.txt") files)"
