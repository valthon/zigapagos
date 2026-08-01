#!/usr/bin/env bash
# Self-tests for tests/meta/runtime-deps-doc.sh.
#
# WHY. That gate is greps and an awk range over source text, and the failure
# mode of a text gate is not being wrong — it is being VACUOUS. An awk range
# that matches nothing, or a `grep -o` whose character class forgot a digit,
# prints PASS on every tree forever and reads in review as coverage. (That
# character class is not hypothetical here: the first run of this gate silently
# dropped `e2e` from the command set because the class was `[a-z-]+`.) So every
# rule is pinned from both sides: the smallest tree the gate must reject, and
# the nearest one it must accept.
#
# Each case is a THROWAWAY tree under $TMPDIR with the gate copied in and a
# minimal stand-in for each source it reads. `git init` because the gate locates
# the repository root with `git rev-parse --show-toplevel`; nothing here touches
# this checkout, and nothing needs to be staged (the gate reads the filesystem,
# not the index).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

GATE="$PWD/tests/meta/runtime-deps-doc.sh"
REL=tests/meta/runtime-deps-doc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
case_n=0
d=""

# A minimal tree the gate PASSES. Every case starts here and breaks one thing,
# so a failure names the rule it broke rather than an accumulation.
newcase() {
  case_n=$((case_n + 1))
  d="$TMP/case$case_n"
  mkdir -p "$d/tests/meta" "$d/src/cli" "$d/docs" "$d/runtime" "$d/build"
  cp "$GATE" "$d/$REL"
  git -C "$d" init -q

  cat >| "$d/src/main.zig" <<'EOF'
const Command = enum {
    init,
    release,
    e2e,
    @"explain-code",
    @"-h",
    help,
};
EOF

  cat >| "$d/src/cli/zigbase.zig" <<'EOF'
pub const pinned_version = "v9.9.9";
pub const exe_name = "zigbase";
pub fn cachedPath() void {
    return join(&.{ root, "zigapagos", "zigbase", pinned_version, exe_name });
}
EOF

  cat >| "$d/src/cli/release.zig" <<'EOF'
pub const runtime_dir_env = "ZP_RT_DIR";
// "--bun=" "--css-minify-driver=" "--island-props-check="
// "--island-sidecar=" "--island-src-dir="
EOF

  cat >| "$d/src/cli/dev.zig" <<'EOF'
// "--zigbase=" "--no-download"
EOF

  cat >| "$d/src/cli/e2e.zig" <<'EOF'
// "--download-zigbase"
EOF

  cat >| "$d/runtime/package.json" <<'EOF'
{ "name": "@z/runtime", "private": true }
EOF

  cat >| "$d/build/release.zig" <<'EOF'
zip.addDirectoryArg(exe.getEmittedBin());
tar.addArg("zigapagos");
EOF

  doc <<'EOF'
| Command | Bun | ZigBase |
| --- | --- | --- |
| `zigapagos init` | no | no |
| `zigapagos release` | conditional | no |
| `zigapagos e2e` | no | yes |
| `zigapagos explain-code` | no | no |
| `zigapagos help` | no | no |

Pinned v9.9.9, cached at zigapagos/zigbase/v9.9.9/zigbase, or from
`npm i -D @zigbase/server@9.9.9`. The tree is named by ZP_RT_DIR.

Flags: --bun= --css-minify-driver= --island-props-check= --island-sidecar=
--island-src-dir= --zigbase= --no-download --download-zigbase
EOF
}

doc() { cat >| "$d/docs/runtime-dependencies.md"; }

check() { # $1 name, $2 expected exit, $3 required substring ("" = none)
  local name=$1 want=$2 needle=${3:-} out status
  set +e
  out=$( cd "$d" && bash "$REL" 2>&1 )
  status=$?
  set -e
  if [ "$status" -ne "$want" ]; then
    echo "FAIL: $name — expected exit $want, got $status"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=$((fail + 1))
    return
  fi
  if [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: $name — exit $status was right but the message never said '$needle'"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=$((fail + 1))
    return
  fi
  pass=$((pass + 1))
}

# ── The baseline, so every rejection below means what it says ────────────────

newcase
check "a consistent tree passes" 0 "PASS"

# ── 1. The command table is the command set ─────────────────────────────────

newcase
sed -i 's/^    e2e,$/    e2e,\n    doctor,/' "$d/src/main.zig"
check "a new subcommand with no table row is caught" 1 "has no row for: doctor"

newcase
printf '| `zigapagos serve` | no | no |\n' >> "$d/docs/runtime-dependencies.md"
check "a table row for a command that does not exist is caught" 1 "documents commands the binary does not have"

# `e2e` is the case that caught the gate's own first bug: a command whose name
# contains a digit. Pinned so the character class cannot lose it again.
newcase
sed -i '/`zigapagos e2e`/d' "$d/docs/runtime-dependencies.md"
check "a dropped row for a digit-bearing command (e2e) is caught" 1 "has no row for: e2e"

# ── 2. The pinned ZigBase version and its cache path ────────────────────────

newcase
sed -i 's/v9\.9\.9/v8.8.8/' "$d/src/cli/zigbase.zig"
check "a pin bump the page did not follow is caught" 1 "but the pin is"

newcase
printf '\nAn older note mentions v1.2.3.\n' >> "$d/docs/runtime-dependencies.md"
check "a second, stale version left on the page is caught" 1 "names version 'v1.2.3'"

newcase
sed -i 's/@zigbase\/server@9\.9\.9/@zigbase\/server@1.0.0/' "$d/docs/runtime-dependencies.md"
check "a stale v-less @zigbase/server pin is caught" 1 "@zigbase/server@1.0.0"

newcase
sed -i 's|zigapagos/zigbase/v9\.9\.9/zigbase|zigapagos/zigbase/v0.0.1/zigbase|' "$d/docs/runtime-dependencies.md"
check "a cache path the page quotes wrong is caught" 1 "does not quote the cache path"

# Dropping the "zigbase" segment while `exe_name = "zigbase"` still sits two
# lines up: the shape a per-segment check would wave through.
newcase
sed -i 's/"zigbase", pinned_version/pinned_version/' "$d/src/cli/zigbase.zig"
check "a cache path that lost a segment in the source is caught" 1 "no longer joins"

# A `zig fmt` reflow to one element per line is not a change; the gate must not
# read it as one.
newcase
sed -i 's/"zigapagos", "zigbase", pinned_version, exe_name/"zigapagos",\n        "zigbase",\n        pinned_version,\n        exe_name/' "$d/src/cli/zigbase.zig"
check "a reflowed join list still passes" 0 "PASS"

# ── 3. The runtime-tree environment variable ────────────────────────────────

newcase
sed -i 's/"ZP_RT_DIR"/"ZP_RUNTIME"/' "$d/src/cli/release.zig"
check "a renamed runtime-dir variable is caught" 1 "never names the runtime-tree variable"

# ── 4. @z/runtime is still private ──────────────────────────────────────────

newcase
printf '{ "name": "@z/runtime", "private": false }\n' >| "$d/runtime/package.json"
check "publishing @z/runtime forces the page to be revisited" 1 "no longer private:true"

# ── 5. A release archive carries the binary alone ───────────────────────────

newcase
printf 'tar.addDirectoryArg(runtime_tree);\n' >> "$d/build/release.zig"
check "shipping a runtime tree inside an archive is caught" 1 "adds a runtime tree to an archive"

newcase
sed -i '/tar.addArg/d' "$d/build/release.zig"
check "an archive that stopped carrying the bare binary is caught" 1 "no longer tars the bare binary"

# ── 6. Every flag the page names still exists ───────────────────────────────

newcase
sed -i 's/"--no-download"//' "$d/src/cli/dev.zig"
check "a flag the page names but dev no longer parses is caught" 1 "no longer parses --no-download"

newcase
sed -i 's/--download-zigbase//' "$d/docs/runtime-dependencies.md"
check "a flag silently dropped from the page is caught" 1 "no longer mentions --download-zigbase"

# ── Anti-vacuity ────────────────────────────────────────────────────────────
# The two ways this gate could pass forever while checking nothing.

newcase
sed -i 's/^const Command = enum {$/const Cmd = enum {/' "$d/src/main.zig"
check "an unparseable command enum fails instead of passing quietly" 1 "parsed no commands"

newcase
doc <<'EOF'
No table here at all, and no pin, and no variable.
EOF
check "a page with no command table fails instead of passing quietly" 1 "found no command rows"

newcase
rm "$d/docs/runtime-dependencies.md"
check "a deleted page fails instead of passing quietly" 1 "missing docs/runtime-dependencies.md"

echo
if [ "$fail" -gt 0 ]; then
  echo "FAIL: $fail of $((pass + fail)) runtime-deps-doc self-tests failed"
  exit 1
fi
echo "PASS: $pass runtime-deps-doc self-tests"
