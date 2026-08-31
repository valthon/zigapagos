#!/usr/bin/env bash
# Regression test for issue #131 item 2: `zigapagos init` generates AGENTS.md
# (agent-facing instructions: build is spelled `release`, serve is spelled
# `dev`, the NDJSON fix loop) and a one-line CLAUDE.md shim (@AGENTS.md --
# Claude Code does not read AGENTS.md natively).
#
# DISCRIMINATOR: unpatched, init creates neither file.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

( cd "$WORK" && "$ZIGAPAGOS" init ) >"$WORK/init.out" 2>&1 || { cat "$WORK/init.out"; fail "init exited non-zero"; }

[[ -f "$WORK/AGENTS.md" ]] || fail "init did not create AGENTS.md"
[[ -f "$WORK/CLAUDE.md" ]] || fail "init did not create CLAUDE.md"

# CLAUDE.md is exactly the import shim -- content drift here silently
# disconnects Claude Code from the real instructions.
[[ "$(cat "$WORK/CLAUDE.md")" == "@AGENTS.md" ]] \
  || { cat "$WORK/CLAUDE.md"; fail "CLAUDE.md is not exactly '@AGENTS.md'"; }

# AGENTS.md must carry the load-bearing facts. Substrings, not full-file
# comparison: wording may evolve, these facts may not disappear.
grep -q 'zigapagos release' "$WORK/AGENTS.md" || fail "AGENTS.md missing 'zigapagos release'"
grep -q 'no `build` command' "$WORK/AGENTS.md" || fail "AGENTS.md missing the build->release trap"
grep -q 'no `serve` command' "$WORK/AGENTS.md" || fail "AGENTS.md missing the serve->dev trap"
grep -q -- '--format=json' "$WORK/AGENTS.md" || fail "AGENTS.md missing the --format=json fix loop"
grep -q 'explain-code' "$WORK/AGENTS.md" || fail "AGENTS.md missing explain-code"
grep -q 'Match on `code`' "$WORK/AGENTS.md" || fail "AGENTS.md missing the match-on-code rule"
grep -q 'test/parity.ts' "$WORK/AGENTS.md" || fail "AGENTS.md missing the Rails parity runner guidance"
grep -q 'authorization remains enforced by ZigBase rules' "$WORK/AGENTS.md" || fail "AGENTS.md moved enforcement into the browser"

# Re-run: both files must be skipped, not clobbered (a user may have edited
# AGENTS.md; init's exclusive-create + warn path covers this already, pin it
# for the new files too).
( cd "$WORK" && "$ZIGAPAGOS" init ) >"$WORK/init2.out" 2>&1 || { cat "$WORK/init2.out"; fail "re-run init exited non-zero"; }
grep -q "'AGENTS.md' already exists, skipping" "$WORK/init2.out" || { cat "$WORK/init2.out"; fail "re-run did not skip AGENTS.md"; }

echo "PASS: tests/init/agents-md.sh"
