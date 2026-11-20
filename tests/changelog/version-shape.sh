#!/usr/bin/env bash
# Pin the current documented provenance scheme; released history is immutable.
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }
preamble="$(awk 'NR > 1 && /^## / { exit } { print }' CHANGELOG.md)"
for required in 'zigapagos 0.5.0' 'commit:      e1d7033abcde' 'build:       fast' \
                'target:      x86_64-linux-musl' 'zig:         0.17.1' \
                '-Dcommit=<sha>' 'unknown' 'version+commit'; do
  grep -qF -- "$required" <<< "$preamble" || fail "missing documentation: $required"
done
if grep -qE 'git describe|dev\.[0-9]|three shapes' <<< "$preamble"; then
  fail "preamble still documents the retired stamp"
fi
grep -qF '"version", @import("../build.zig.zon").version' build/exe.zig || fail 'version must come from zon'
grep -qF '"commit", cfg.commit' build/exe.zig || fail 'commit must reach the binary'
grep -qF 'scripts/assert-version.sh "$GITHUB_REF_NAME"' .github/workflows/release.yml || fail 'release tag guard missing'
grep -qF 'options.version, printedCommit(options.commit)' src/main.zig || fail 'CLI provenance missing'
echo 'ok: version-and-commit documentation matches build and release wiring'
