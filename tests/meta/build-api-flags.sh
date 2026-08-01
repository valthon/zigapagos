#!/usr/bin/env bash
# Every CLI flag the consumer build API emits is one the CLI still parses.
#
# WHY THIS EXISTS. `build/harness.zig` is a translation layer: `e2e()` and `dev()`
# take a Zig options struct and emit an argv for `zigapagos e2e` / `zigapagos dev`.
# Nothing type-checks that argv against the parser on the other side of the process
# boundary, and no in-repo project sets every option, so a renamed flag ships a
# build API whose documented option makes the command exit non-zero — with every
# gate green, because the option nothing sets is the option nothing tested.
#
# That is not hypothetical. When the bundled server was replaced by the zero-config
# `zigapagos dev`, `--download-zigbase` became `--no-download` in `src/cli/dev.zig`,
# and `dev()` kept emitting the old spelling. `zig build dev` with
# `DevOptions.download_zigbase = true` died on "unexpected 'zigapagos dev' argument
# '--download-zigbase'". The union of both parsers still contained the flag —
# `zigapagos e2e` legitimately keeps it — so only a PER-COMMAND check finds this.
# Hence the awk pass below attributes each flag to the function that emits it.
#
# Pure `grep`/`awk` over tracked source: no toolchain, no build, no network. It runs
# in CI's `tests/*/*.sh` glob like everything else here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

HARNESS=build/harness.zig

# Which CLI source parses the argv each harness function builds.
declare -A PARSER=(
  [e2e]=src/cli/e2e.zig
  [dev]=src/cli/dev.zig
)

# Emission sites only — `addArg`/`addArgs` lines. Deliberately NOT the whole file:
# the doc comments quote zigbase's own flags (`--http-port`, `--serve-static`) and
# name flags in prose, none of which this repo's parsers have ever accepted.
#
# `--` on its own (the rebuild-command separator) has no name and is skipped by the
# `--[a-z]` shape.
mapfile -t PAIRS < <(
  awk '
    /^pub fn [A-Za-z0-9_]+\(/ { fn = $3; sub(/\(.*/, "", fn) }
    /addArgs?\(/ && /--[a-z]/ {
      line = $0
      while (match(line, /--[a-z][a-z0-9-]*/)) {
        print fn "\t" substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$HARNESS" | sort -u
)

# Anti-vacuity. A refactor that renames the functions, moves the emission out of
# `addArg`, or splits the file leaves the loop below with nothing to check and this
# gate reporting success while checking nothing — the exact failure mode
# tests/meta/script-coverage.sh was written about.
[ "${#PAIRS[@]}" -gt 0 ] || {
  echo "FAIL: extracted no flags from $HARNESS — the emission shape changed and this gate is checking nothing" >&2
  exit 1
}

fails=0
declare -A SEEN_FN=()
for pair in "${PAIRS[@]}"; do
  fn=${pair%%$'\t'*}
  flag=${pair#*$'\t'}
  SEEN_FN["$fn"]=1
  parser=${PARSER[$fn]:-}
  if [ -z "$parser" ]; then
    echo "FAIL: $HARNESS's $fn() emits '$flag' but this gate has no parser mapped for $fn()" >&2
    echo "      Add it to PARSER above, or the new function's flags go unchecked." >&2
    fails=$((fails + 1))
    continue
  fi
  # Both parser shapes: `std.mem.eql(u8, arg, "--flag")` for a boolean, and
  # `std.mem.startsWith(u8, arg, "--flag=")` for one that takes a value. The
  # leading quote is what keeps `--port` from matching `--reload-port=`.
  if ! grep -qF -e "\"$flag\"" -e "\"$flag=" "$parser"; then
    echo "FAIL: $HARNESS's $fn() emits '$flag', which $parser does not parse." >&2
    echo "      The command rejects it: 'unexpected argument'. Rename one side or the other." >&2
    fails=$((fails + 1))
  fi
done

for fn in "${!PARSER[@]}"; do
  [ -n "${SEEN_FN[$fn]:-}" ] || {
    echo "FAIL: PARSER maps $fn(), but no flag was extracted from it — stale row, or its emission moved" >&2
    fails=$((fails + 1))
  }
done

[ "$fails" -eq 0 ] || exit 1
echo "PASS: ${#PAIRS[@]} build-API flags all parsed by the commands they are sent to"
