#!/usr/bin/env bash
# @zigapagos/cli's dependency ranges must agree with the files that own those
# numbers. This runs npm/check-toolchain.mjs against the real repository (the
# gate), and then against fixture trees where each source is wrong in a different
# way (the gate's own tests).
#
# WHY THE SELF-TESTS. check-toolchain.mjs reads a Zig constant and a TOML pin with
# regexes. Both can stop matching without erroring -- rename `pinned_version`,
# restyle the [tools] table, and a regex-based reader finds nothing. A gate that
# finds nothing prints PASS. Every case below therefore checks a FAILURE the gate
# is supposed to catch, and case 1 checks it still passes on the real tree, so
# neither direction can rot silently. Same reasoning (and the same shape) as
# tests/npm/targets.sh.
#
# WHAT IS ACTUALLY AT STAKE. The zigbase case is the sharp one: npm installs the
# declared range, and a PATH miss downloads `pinned_version` instead. If those
# drift, `zigapagos dev` runs a different zigbase depending on how the user
# installed zigapagos -- two machines that both "have zigapagos X" behaving
# differently, which is close to unreportable.
#
# Hermetic and toolchain-free apart from node: it copies four text files into a
# temp tree, mutates them, and reads exit codes. Under a second. Picked up by
# ci.yml's `tests/*/*.sh` glob.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"

GATE="$REPO/npm/check-toolchain.mjs"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
out=""

# Runs the gate against a fixture root and asserts on the exit status.
# `want` is "ok" (exit 0) or "fail" (any non-zero).
expect() {
  local want="$1" name="$2" root="$3"
  local rc=0
  out="$(node "$GATE" --root "$root" 2>&1)" || rc=$?
  if [ "$want" = ok ] && [ "$rc" -ne 0 ]; then
    echo "FAIL: $name — expected exit 0, got $rc"
    printf '%s\n' "$out" | sed 's/^/    /'
    failures=$((failures + 1))
    return 0
  fi
  if [ "$want" = fail ] && [ "$rc" -eq 0 ]; then
    echo "FAIL: $name — expected non-zero exit, got 0"
    printf '%s\n' "$out" | sed 's/^/    /'
    failures=$((failures + 1))
    return 0
  fi
  echo "ok: $name"
}

# The message matters as much as the exit code: whoever reads it has to know
# which source file to edit, and that the generated manifest is not the fix.
contains() {
  local name="$1" needle="$2"
  case "$out" in
    *"$needle"*) echo "ok: $name" ;;
    *)
      echo "FAIL: $name — output does not contain '$needle'"
      printf '%s\n' "$out" | sed 's/^/    /'
      failures=$((failures + 1))
      ;;
  esac
}

# A fixture is a temp root holding every file the gate reads: the four sources of
# truth plus what genPackages itself needs (the version and the target list).
fixture() {
  local name="$1"
  local root="$tmp/$name"
  rm -rf "$root"
  mkdir -p "$root/npm/cli" "$root/runtime" "$root/src/cli"
  cp "$REPO/npm/cli/targets.json" "$root/npm/cli/targets.json"
  # The gate imports the generator belonging to the tree it is checking, so a
  # fixture can corrupt gen-packages.mjs itself -- which is how a derivation
  # actually gets lost in practice (replaced by a literal).
  cp "$REPO/npm/gen-packages.mjs" "$root/npm/gen-packages.mjs"
  cp "$REPO/runtime/package.json" "$root/runtime/package.json"
  cp "$REPO/src/cli/zigbase.zig" "$root/src/cli/zigbase.zig"
  cp "$REPO/mise.toml" "$root/mise.toml"
  cp "$REPO/build.zig.zon" "$root/build.zig.zon"
  printf '%s\n' "$root"
}

# Rewrites a fixture's runtime/package.json through node: sed on JSON is how a
# test starts asserting on whitespace.
edit_json() {
  local root="$1" expr="$2"
  node -e '
    const fs = require("node:fs");
    const f = process.argv[1] + "/runtime/package.json";
    const pkg = JSON.parse(fs.readFileSync(f, "utf8"));
    const edit = new Function("pkg", process.argv[2]);
    fs.writeFileSync(f, JSON.stringify(edit(pkg) ?? pkg, null, 2) + "\n");
  ' "$root" "$expr"
}

# Replaces a literal string inside one of a fixture's text files.
sub() {
  local root="$1" rel="$2" from="$3" to="$4"
  node -e '
    const fs = require("node:fs");
    const f = process.argv[1] + "/" + process.argv[2];
    const src = fs.readFileSync(f, "utf8");
    if (!src.includes(process.argv[3])) {
      throw new Error("fixture setup: '"'"'" + process.argv[3] + "'"'"' not found in " + process.argv[2]);
    }
    fs.writeFileSync(f, src.replace(process.argv[3], process.argv[4]));
  ' "$root" "$rel" "$from" "$to"
}

# --- 1. The real repository -------------------------------------------------
# This is the gate itself, not a fixture: the tree as committed must agree.
expect ok "the committed tree's dependencies agree with their sources" "$REPO"
contains "the gate names the zigbase package and its source" "@zigbase/server"
contains "  ...and attributes each range to a file" "runtime/package.json"

# --- 2. The zigbase pin moving without the npm range ------------------------
# The failure this whole gate exists for: npm installs one zigbase, the download
# fallback fetches another, and `zigapagos dev` behaves differently by install path.
#
# Both fixtures MOVE the pin, so they need to know where it currently sits —
# read from the file that owns it rather than restated, which would make every
# pin bump edit this test for no assertion's benefit. `sub` still hard-errors
# when its needle is absent, so a renamed declaration fails loudly here too.
PIN="$(sed -n 's/^[[:space:]]*pub const pinned_version[[:space:]]*=[[:space:]]*"\(v\{0,1\}[0-9.]*\)".*/\1/p' "$REPO/src/cli/zigbase.zig")"
if [ -z "$PIN" ]; then
  echo "FAIL: could not read pinned_version from src/cli/zigbase.zig — this test is now setting up nothing"
  exit 1
fi
# The version both fixtures move the pin TO. Never published, so it cannot
# silently coincide with whatever the pin happens to be.
MOVED=v9.9.9

root="$(fixture zigbase-pin-bumped)"
sub "$root" src/cli/zigbase.zig "pinned_version = \"$PIN\"" "pinned_version = \"$MOVED\""
expect ok "a pin bump alone stays consistent, because the range is derived" "$root"
contains "  ...and the derived range follows the pin" "@zigbase/server ${MOVED#v}"

# A literal is how the derivation actually gets lost, so simulate exactly that:
# freeze the range inside the fixture's generator AT TODAY'S PIN — which is what
# someone reaching for a literal would write — then move the pin underneath it.
root="$(fixture zigbase-literal)"
sub "$root" src/cli/zigbase.zig "pinned_version = \"$PIN\"" "pinned_version = \"$MOVED\""
sub "$root" npm/gen-packages.mjs \
  'return { "@zigbase/server": m[1] };' \
  "return { \"@zigbase/server\": \"${PIN#v}\" };"
expect fail "a hardcoded range while pinned_version moved" "$root"
contains "  ...names the file that owns the number" "src/cli/zigbase.zig pins"
contains "  ...and says to fix the source, not the manifest" "Fix the source of truth"

# --- 3. Depending on the bare `zigbase` alias -------------------------------
# The alias was published exactly once, so 0.12.0 is the only version it will
# ever have and it cannot follow a pin. The gate rejects it on presence rather
# than on the version it resolves to, so moving the pin cannot silence the test.
# Called out by name because it is the obvious dependency to reach for, and the
# one that splits behaviour by install path.
root="$(fixture bare-alias)"
sub "$root" npm/gen-packages.mjs \
  'return { "@zigbase/server": m[1] };' \
  'return { zigbase: m[1] };'
expect fail "depending on the bare zigbase alias" "$root"
contains "  ...says why the alias cannot track the pin" "published only at"

# --- 4. The runtime growing a dependency the CLI would not ship -------------
# @zigapagos/cli ships runtime/src, so runtime/'s imports are the CLI's imports.
root="$(fixture runtime-new-dep)"
edit_json "$root" 'pkg.dependencies["nanostores"] = "^0.11.0"; return pkg;'
expect ok "a new runtime dependency is picked up automatically" "$root"
contains "  ...and appears as a required dependency" "nanostores ^0.11.0 (required)"

# --- 5. Anti-vacuity: each parser must fail rather than match nothing -------
root="$(fixture renamed-zig-pin)"
sub "$root" src/cli/zigbase.zig "pub const pinned_version" "pub const zigbase_release"
expect fail "renamed pinned_version in src/cli/zigbase.zig" "$root"
contains "  ...says the gate is now checking nothing" "this gate is now checking nothing"

root="$(fixture no-bun-pin)"
# The pin line is derived from the fixture rather than restated: a literal here
# (this used to say `bun = "1.2"`) breaks fixture setup on every bun bump while
# asserting nothing about the gate. The emptiness check keeps the anti-vacuity
# that `sub`'s not-found throw provided — an empty needle would make `sub`
# prepend instead of replace, silently leaving the pin in place.
bun_pin_line="$(grep '^bun = ' "$root/mise.toml" || true)"
[ -n "$bun_pin_line" ] || { echo "FAIL: fixture setup: no 'bun = ' line in mise.toml"; exit 1; }
sub "$root" mise.toml "$bun_pin_line" '# bun pin removed'
expect fail "mise.toml with no bun pin" "$root"
contains "  ...names mise.toml" "could not read the bun pin from mise.toml"

root="$(fixture runtime-no-deps)"
edit_json "$root" 'delete pkg.dependencies; return pkg;'
expect fail "runtime/package.json with no dependencies" "$root"
contains "  ...says the runtime lost Preact" "runtime lost Preact"

root="$(fixture runtime-no-typescript)"
edit_json "$root" 'delete pkg.devDependencies.typescript; return pkg;'
expect fail "runtime/package.json with no typescript devDependency" "$root"
contains "  ...says the gate would be checking nothing" "this gate is now checking nothing"

# --- 6. The typescript cap being widened past the compiler-API cliff --------
# The one range here whose UPPER bound is the point. typescript 7 is the Go
# rewrite and has no JavaScript compiler API, so `ts.createSourceFile` — which
# scripts/slice-host.ts and sidecar/hot-transform.ts both call — is gone. Both
# callers degrade gracefully by design, so publishing a range that admits 7 does
# not fail anything: it silently stops slicing and silently stops fast refresh.
# A literal in the generator is again how it happens.
root="$(fixture typescript-cap-widened)"
sub "$root" npm/gen-packages.mjs \
  'return { typescript: range };' \
  'return { typescript: ">=6" };'
expect fail "a typescript range wider than runtime/package.json's cap" "$root"
contains "  ...names the silent failure it causes" "fails SILENTLY"

if [ "$failures" -ne 0 ]; then
  echo "FAILED: $failures case(s)"
  exit 1
fi
echo "PASS: npm toolchain-dependency drift gate"
