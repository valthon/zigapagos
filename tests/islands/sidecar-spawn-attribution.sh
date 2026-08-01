#!/usr/bin/env bash
# Regression test: a failed island-sidecar spawn must name the input that is
# actually missing (issue #82).
#
# The defect this pins: `Sidecar.spawn` takes three inputs -- the interpreter
# (`--bun`), the sidecar script (`--island-sidecar`) and the island source dir
# (`--island-src-dir`, which becomes the child's cwd) -- and POSIX reports "no
# such executable", "no such script" and "no such cwd" all as ENOENT. root.zig
# had ONE catch-all that stringified the raw errno beside the bun+script pair:
#
#   error: failed to spawn island sidecar (bun .../render.ts): FileNotFound
#
# so a missing `bun` -- the overwhelmingly common case, and a first-run failure
# mode for an npm-installed user who has node but not bun (#81) -- sent the
# reader to look at `render.ts`, a path that resolves. That is misattribution,
# not a missing detail.
#
# The check is four-part, because asserting only "it fails" would pass on any
# build error at all, and asserting only the bun case would let a missing
# script or cwd inherit the interpreter's message:
#   (1) control: the same fixture with all three inputs valid builds clean,
#   (2) a missing INTERPRETER names the interpreter, mentions the script path
#       it is exonerating, points at build.zig's `.islands`, and does NOT print
#       the pre-fix raw `): FileNotFound` form,
#   (3) a missing SCRIPT names the script and must NOT blame the interpreter,
#   (4) a missing ISLAND SOURCE DIR names that dir and must NOT blame the
#       interpreter.
#
# (3) and (4) are what stop the "fix" from being "always say bun is missing",
# which would trade one misattribution for two.
#
# (5) closes the same hole on the OTHER side. `spawn` tells a missing cwd from a
# missing interpreter by probing the cwd with `openDir`, and the first cut of
# that probe mapped EVERY probe failure to "island source dir not found" -- so a
# project root that exists but merely cannot be opened was reported as absent,
# reintroducing exactly the misattribution this file exists to pin. (5) points
# the build at a directory that is REAL but search-only (`0111`) and asserts
# that it is not blamed.
#
# Read the platform note before "fixing" this leg: it can only ever FAIL on
# macOS. `Io.Threaded.dirOpenDirPosix` adds `O_PATH` when `iterate` is false,
# and only Linux has `O_PATH`, so:
#   * on Linux the probe needs search on the PARENTS and nothing on the target,
#     which is strictly weaker than the `chdir` the child already survived --
#     every permission failure is therefore reported by `spawn` itself
#     (verified: a `0000` cwd and an unsearchable parent both come back as
#     `AccessDenied` from `spawn`, never reaching the probe), so this leg passes
#     on Linux with or without the narrowing;
#   * on macOS/BSD the same call is a real `O_RDONLY` open needing READ on the
#     target, so `0111` denies the probe while `chdir` walked in happily. That
#     is where the blanket `catch` printed "island source dir not found" about a
#     working directory, and where this leg bites.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"
SIDECAR="$REPO/runtime/sidecar/render.ts"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi
[[ -f "$SIDECAR" ]] || { echo "FAIL: $SIDECAR missing -- this fixture's assumption is broken"; exit 1; }
command -v bun >/dev/null 2>&1 || { echo "FAIL: bun not found on PATH (needed for the control leg)"; exit 1; }
BUN="$(command -v bun)"
if [[ ! -d "$REPO/runtime/node_modules" ]]; then
  echo "runtime/node_modules missing; running 'bun install --frozen-lockfile'..."
  ( cd "$REPO/runtime" && bun install --frozen-lockfile ) \
    || { echo "FAIL: bun install --frozen-lockfile failed in runtime/"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# A fresh copy of the shared fixture per phase, so one phase's output tree
# cannot influence the next.
new_site() {
  local site="$1"
  mkdir -p "$site"
  cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$site/"
  cp tests/rendering/simple/zigapagos.ziggy "$site/"
}

# Run `zigapagos release` with the three island inputs, capturing merged output.
# The sidecar is spawned before any page renders, so the fixture needs no
# <island> of its own: what is under test is the spawn diagnostic itself.
release() { # $1 = tag, $2 = bun, $3 = sidecar script, $4 = island src dir
  local tag="$1" bun="$2" script="$3" srcdir="$4"
  local site="$WORK/$tag-site"
  new_site "$site"
  set +e
  # The brace group's stderr is silenced so bash's own "Aborted (core dumped)"
  # job report stays out of this script's output: `fatal.msg` panics under a
  # Debug build (which is what `zig build` produces and what CI runs), so every
  # failing leg below dies on SIGABRT by design. The child's own output is
  # already captured to $tag.log by the inner redirection.
  { ( cd "$site" && "$ZIGAPAGOS" release "--output=$WORK/$tag-out" --force \
      "--bun=$bun" "--island-sidecar=$script" "--island-src-dir=$srcdir" \
  ) >"$WORK/$tag.log" 2>&1; } 2>/dev/null
  echo $? >"$WORK/$tag.rc"
  set -e
}

# --- (1) control: every input valid -> the build succeeds --------------------
release ok "$BUN" "$SIDECAR" "$REPO/runtime"
[[ "$(cat "$WORK/ok.rc")" -eq 0 ]] || {
  sed -n '1,30p' "$WORK/ok.log"
  fail "(1) control build failed -- the fixture itself is broken, so this test would prove nothing"
}
echo "PASS (1): control -- all three island inputs valid, build succeeds"

# --- (2) missing INTERPRETER -------------------------------------------------
release nobun "$WORK/definitely-missing-bun" "$SIDECAR" "$REPO/runtime"
[[ "$(cat "$WORK/nobun.rc")" -ne 0 ]] || {
  sed -n '1,30p' "$WORK/nobun.log"; fail "(2) a missing interpreter must fail the build"
}
grep -q 'interpreter' "$WORK/nobun.log" \
  || { sed -n '1,30p' "$WORK/nobun.log"; fail "(2) the diagnostic does not attribute the failure to the interpreter"; }
grep -qF "$WORK/definitely-missing-bun" "$WORK/nobun.log" \
  || { sed -n '1,30p' "$WORK/nobun.log"; fail "(2) the diagnostic does not name the interpreter path that was tried"; }
# The regression itself: the raw `(<bun> <script>): FileNotFound` form, which
# reads as "render.ts is missing" when render.ts is right there.
if grep -q '): FileNotFound' "$WORK/nobun.log"; then
  sed -n '1,30p' "$WORK/nobun.log"; fail "(2) the pre-fix raw-errno message is still being printed"
fi
# ...and it must say the script is NOT the problem, since that is exactly the
# wrong inference the old message invited.
grep -qF "$SIDECAR" "$WORK/nobun.log" \
  || { sed -n '1,30p' "$WORK/nobun.log"; fail "(2) the diagnostic does not mention the script path it is exonerating"; }
grep -qF '.islands' "$WORK/nobun.log" \
  || { sed -n '1,30p' "$WORK/nobun.log"; fail "(2) the diagnostic does not point at build.zig's .islands integration"; }
echo "PASS (2): a missing interpreter is attributed to the interpreter"

# --- (3) missing SIDECAR SCRIPT ---------------------------------------------
release noscript "$BUN" "$WORK/definitely-missing-render.ts" "$REPO/runtime"
[[ "$(cat "$WORK/noscript.rc")" -ne 0 ]] || {
  sed -n '1,30p' "$WORK/noscript.log"; fail "(3) a missing sidecar script must fail the build"
}
grep -qF "$WORK/definitely-missing-render.ts" "$WORK/noscript.log" \
  || { sed -n '1,30p' "$WORK/noscript.log"; fail "(3) the diagnostic does not name the missing sidecar script"; }
if grep -qE "interpreter '[^']*' not found" "$WORK/noscript.log"; then
  sed -n '1,30p' "$WORK/noscript.log"; fail "(3) a missing SCRIPT was blamed on the interpreter"
fi
echo "PASS (3): a missing sidecar script is attributed to the script"

# --- (4) missing ISLAND SOURCE DIR ------------------------------------------
release nosrcdir "$BUN" "$SIDECAR" "$WORK/definitely-missing-src-dir"
[[ "$(cat "$WORK/nosrcdir.rc")" -ne 0 ]] || {
  sed -n '1,30p' "$WORK/nosrcdir.log"; fail "(4) a missing island source dir must fail the build"
}
grep -qF "$WORK/definitely-missing-src-dir" "$WORK/nosrcdir.log" \
  || { sed -n '1,30p' "$WORK/nosrcdir.log"; fail "(4) the diagnostic does not name the missing island source dir"; }
if grep -qE "interpreter '[^']*' not found" "$WORK/nosrcdir.log"; then
  sed -n '1,30p' "$WORK/nosrcdir.log"; fail "(4) a missing SOURCE DIR was blamed on the interpreter"
fi
echo "PASS (4): a missing island source dir is attributed to that dir"

# --- (5) PRESENT island source dir that the probe cannot open ----------------
# Real directory, mode 0111: `chdir` into it succeeds, so it is emphatically not
# "not found". Paired with a missing interpreter so the spawn still fails with
# the ENOENT that sends `spawn` to its probe in the first place.
SEARCHONLY="$WORK/searchable-not-readable"
mkdir -p "$SEARCHONLY"
chmod 0111 "$SEARCHONLY"
release lockeddir "$WORK/definitely-missing-bun" "$SIDECAR" "$SEARCHONLY"
# Restore before any assertion can `exit`, so the EXIT trap's rm -rf can descend.
chmod 0755 "$SEARCHONLY"
[[ "$(cat "$WORK/lockeddir.rc")" -ne 0 ]] || {
  sed -n '1,30p' "$WORK/lockeddir.log"; fail "(5) a missing interpreter must fail the build"
}
if grep -qF 'island source dir not found' "$WORK/lockeddir.log"; then
  sed -n '1,30p' "$WORK/lockeddir.log"
  fail "(5) a project root that EXISTS was reported as missing -- the probe collapsed a non-ENOENT failure into ProjectRootNotFound"
fi
echo "PASS (5): a present-but-unopenable island source dir is not reported as missing"

echo "PASS: a failed sidecar spawn names the input that is actually missing"
