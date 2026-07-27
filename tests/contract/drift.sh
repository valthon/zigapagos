#!/usr/bin/env bash
# CI hook for the cross-tier codegen gate's own drift test.
#
# The test lives at contract/test/drift.sh, next to its subject — the same layout as
# scripts/assemble-changelog.test.sh and scripts/check-allocator-contracts.test.sh.
# Those two are named explicitly in .github/workflows/ci.yml; this shim exists so the
# drift test is picked up by CI's `tests/*/*.sh` glob instead, which needs no workflow
# edit and therefore cannot go unrun because two branches touched ci.yml at once.
#
# WHY IT NEEDS TO BE IN CI AT ALL. contract/test/drift.sh is the test that proves
# `zig build api-check` and the contract/generated/_assert.ts compile tripwire are not
# vacuous — and it had itself gone vacuous (its Case B asserted only a non-zero exit
# status, which a tsc that failed to LAUNCH also produces, so it printed PASS while
# nothing was type-checked). Nobody noticed because nothing ran it: it sat outside the
# `tests/*/*.sh` glob and was never named in ci.yml. An unrun gate is how that rotted,
# so it goes in the glob.
#
# COST. Measured locally on a warm cache: ~1.5s wall for the whole script. It runs
# `zig build api-check` twice and `apigen` once — all of which are `bun` over a 200-line
# JSON schema plus a `git diff --cached`, with no compilation — and `tsc --noEmit` twice
# over three small files. It spawns no server and builds no consumer project, so it
# belongs in e2e-rest with the other short scripts rather than in a shard of its own.
#
# TREE MUTATION. drift.sh edits contract/zigbase.openapi.json and regenerates
# contract/generated/ on purpose, then restores both from HEAD. e2e-rest runs every
# script sequentially in ONE checkout, so a leak would corrupt whatever runs next.
# drift.sh guards that from three directions: it refuses to start if either path is
# already dirty, its EXIT trap restores on every path (assertion failure, unexpected
# error, SIGINT/SIGTERM — verified by sending it a signal mid-mutation), and that same
# trap fails the run if anything is still dirty afterwards.
set -euo pipefail
exec bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/contract/test/drift.sh"
