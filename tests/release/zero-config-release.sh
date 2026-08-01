#!/usr/bin/env bash
# Runs the EXACT build that zero-config `zigapagos dev` shells out for, with
# nothing else in the way.
#
# Why this exists as its own script. CI failed tests/dev/dev.sh three times with
# `Illegal instruction at address 0x99ad43b` in dev's log, and the first two
# diagnoses blamed dev: the message said "dev never became ready", and dev is
# what the harness launches. dev was innocent both times. Its rebuild command on
# the zero-config leg is `zigapagos release --output=public --force`, and that
# CHILD is what crashed -- invisible behind a parent that stayed alive and a
# readiness timeout that named the wrong process.
#
# So this invokes `release` directly. If the crash is in `release`, this fails
# with the signal and the trace and no dev in the picture. If this passes while
# dev.sh fails, the fault is in how dev spawns or supervises the child, not in
# the build. Either outcome is a real answer; the two scripts land in DIFFERENT
# CI shards (dev.sh is in SHARDED_OUT, this is not), so one run tests both in
# parallel.
#
# It is a cheap always-on regression test regardless: a toolchain-free consumer's
# very first command is a bare `zigapagos release`, and nothing else asserted
# that the default output path and flags work on a stock site.
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# See tests/dev/dev.sh for why a missing trace is itself a finding: the binary is
# a Debug build with debug_info (build/config.zig leaves preferred_optimize_mode
# commented out), so a signal death should print frames.
has_zig_trace() { grep -qE '0x[0-9a-f]+ in ' "$1" 2>/dev/null; }

report_crash() { # $1 = log, $2 = exit status
  local log=$1 status=$2
  echo "--- release output ---"; cat "$log"; echo "--- end release output ---"
  if (( status > 128 )); then
    local signame; signame=SIG$(kill -l $((status - 128)) 2>/dev/null || echo "?($((status - 128)))")
    echo "release was KILLED BY $signame (status $status)"
    if ! has_zig_trace "$log"; then
      echo "NOTE: no Zig stack trace, though the binary is a Debug build with"
      echo "      debug_info -- the unwind failed or the trace was lost."
      local pat; pat=$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo "<unreadable>")
      local core; core=$(ls -t "$SRC"/core* /tmp/core* 2>/dev/null | head -1)
      if [[ -n "$core" ]]; then
        echo "core: $core"
        if command -v gdb >/dev/null 2>&1; then
          gdb -batch -ex 'thread apply all bt' "$ZIGAPAGOS" "$core" 2>&1 | tail -40
        else
          echo "(no gdb to read it)"
        fi
      else
        echo "no core file (kernel.core_pattern = $pat; ulimit -c = $(ulimit -c))"
      fi
    fi
    fail "zigapagos release CRASHED -- this is the child tests/dev/dev.sh was blaming dev for"
  fi
  fail "zigapagos release exited $status"
}

ulimit -c unlimited 2>/dev/null || true

ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"
if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  ( cd "$REPO" && mise exec -- zig build ) || fail "zig build failed"
fi

# The same fixture tests/dev/dev.sh builds, staged the same way, so a difference
# in outcome between the two scripts is about dev and not about the input.
SRC="$WORK/site"
mkdir -p "$SRC"
cp -r "$REPO/tests/rendering/simple/content" "$REPO/tests/rendering/simple/layouts" "$SRC/"
cp "$REPO/tests/rendering/simple/zigapagos.ziggy" "$SRC/"
printf '\nDEVLOOP-MARKER-V1\n' >> "$SRC/content/index.smd"

# Verbatim the argv dev builds for its zero-config rebuild, run from the site
# root exactly as dev runs it.
LOG="$WORK/release.log"
status=0
( cd "$SRC" && "$ZIGAPAGOS" release --output=public --force ) > "$LOG" 2>&1 || status=$?
(( status == 0 )) || report_crash "$LOG" "$status"

[[ -f "$SRC/public/index.html" ]] \
  || { cat "$LOG"; fail "release exited 0 but wrote no public/index.html"; }
grep -q 'DEVLOOP-MARKER-V1' "$SRC/public/index.html" \
  || { cat "$LOG"; fail "public/index.html does not carry the fixture's marker"; }

# A second run over an existing tree: --force must overwrite rather than trip on
# what the first run left behind. dev rebuilds into the same directory on every
# edit, so this is the shape it actually exercises, not a fresh-tree special case.
status=0
( cd "$SRC" && "$ZIGAPAGOS" release --output=public --force ) > "$LOG" 2>&1 || status=$?
(( status == 0 )) || report_crash "$LOG" "$status"

echo "PASS: zero-config \`zigapagos release --output=public --force\` builds a stock site (twice)"
