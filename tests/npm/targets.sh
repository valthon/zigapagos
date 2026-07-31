#!/usr/bin/env bash
# The release target matrix must agree across its three declarations. This runs
# npm/check-targets.mjs against the real repository (the gate), and then against
# fixture trees where each of the three files is wrong in a different way (the
# gate's own tests).
#
# WHY THE SELF-TESTS. check-targets.mjs reads two files written in other
# languages: a Zig array literal and a YAML matrix. Both parsers can stop matching
# without erroring -- rename the `targets` declaration, reindent the matrix, and a
# regex-based reader finds nothing. A gate that finds nothing prints PASS. Every
# case below therefore checks a FAILURE the gate is supposed to catch, and case 1
# checks it still passes on the real tree, so neither direction can rot silently.
# Same reasoning as scripts/check-allocator-contracts.test.sh and
# tests/release/scripts.sh.
#
# Hermetic and toolchain-free apart from node: it copies three text files into a
# temp tree, mutates them, and reads exit codes. Under a second. Picked up by
# ci.yml's `tests/*/*.sh` glob.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"

GATE="$REPO/npm/check-targets.mjs"
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

# The message matters as much as the exit code: this gate fires during a release
# and whoever reads it has to know which of the three files to edit.
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

# A fixture is a temp root holding the three files the gate reads.
fixture() {
  # Two statements, not one `local a= b=$a`: bash expands every argument of the
  # `local` builtin before running it, so the second would read an unset `name`
  # and abort under `set -u`.
  local name="$1"
  local root="$tmp/$name"
  rm -rf "$root"
  mkdir -p "$root/npm/cli" "$root/build" "$root/.github/workflows"
  cp "$REPO/npm/cli/targets.json" "$root/npm/cli/targets.json"
  cp "$REPO/build/release.zig" "$root/build/release.zig"
  cp "$REPO/.github/workflows/release.yml" "$root/.github/workflows/release.yml"
  printf '%s\n' "$root"
}

# Rewrites a fixture's targets.json through node: sed on JSON is how a test
# starts asserting on whitespace.
edit_json() {
  local root="$1" expr="$2"
  node -e '
    const fs = require("node:fs");
    const f = process.argv[1] + "/npm/cli/targets.json";
    const targets = JSON.parse(fs.readFileSync(f, "utf8"));
    const edit = new Function("targets", process.argv[2]);
    fs.writeFileSync(f, JSON.stringify(edit(targets) ?? targets, null, 2) + "\n");
  ' "$root" "$expr"
}

# --- 1. The real repository -------------------------------------------------
# This is the gate itself, not a fixture: the tree as committed must agree.
expect ok "the committed tree agrees across all three declarations" "$REPO"
contains "the gate names each target it checked" "@zigapagos/cli-linux-x64"

# --- 2. A target npm would publish that nothing builds ----------------------
root="$(fixture publish-unbuilt)"
edit_json "$root" '
  targets.push({ key: "linux-arm64", zig: "aarch64-linux-musl", os: "linux",
                 cpu: "arm64", archive: "aarch64-linux-musl.tar.xz" });
  return targets;'
expect fail "targets.json row with no build/release.zig entry" "$root"
contains "  ...names the target and both files" "aarch64-linux-musl: in npm/cli/targets.json but not in build/release.zig"

# --- 3. A target that ships but is never published --------------------------
root="$(fixture built-unpublished)"
edit_json "$root" 'return targets.filter((t) => t.zig !== "x86_64-macos");'
expect fail "build/release.zig target with no targets.json row" "$root"
contains "  ...names the missing npm side" "x86_64-macos: in build/release.zig but not in npm/cli/targets.json"

# --- 4. A target with nowhere to build --------------------------------------
# The reverse direction (a matrix row naming an absent triple) is already caught
# by build/release.zig's -Drelease-target guard; this is the half that was not.
root="$(fixture no-runner)"
node -e '
  const fs = require("node:fs");
  const f = process.argv[1] + "/.github/workflows/release.yml";
  const yml = fs.readFileSync(f, "utf8").replace(
    /          - target: x86_64-macos\n            runner: macos-latest\n            archive: x86_64-macos\.zip\n/,
    "",
  );
  fs.writeFileSync(f, yml);
' "$root"
expect fail "release.zig target with no release.yml matrix row" "$root"
contains "  ...names the workflow" "in build/release.zig but not in release.yml's build matrix"

# --- 5. A hand-edited npm key that the triple does not imply ----------------
root="$(fixture wrong-key)"
edit_json "$root" '
  targets.find((t) => t.zig === "x86_64-linux-musl").key = "linux-arm64";
  return targets;'
expect fail "targets.json key disagreeing with its own zig triple" "$root"
contains "  ...shows both the value and the derivation" "derives key='linux-x64'"

# --- 6. An archive name the release does not produce ------------------------
root="$(fixture wrong-archive)"
edit_json "$root" '
  targets.find((t) => t.zig === "x86_64-macos").archive = "x86_64-macos.tar.xz";
  return targets;'
expect fail "targets.json archive with the wrong format for its os" "$root"
contains "  ...names the derived archive" "derives archive='x86_64-macos.zip'"

# --- 7. Two targets claiming the same npm package ---------------------------
root="$(fixture duplicate-key)"
edit_json "$root" '
  targets[1].key = targets[0].key;
  return targets;'
expect fail "two targets sharing one npm key" "$root"
contains "  ...names the duplicate" "duplicate key"

# --- 8. The parsers must never silently match nothing -----------------------
root="$(fixture renamed-zig-decl)"
node -e '
  const fs = require("node:fs");
  const f = process.argv[1] + "/build/release.zig";
  fs.writeFileSync(
    f,
    fs.readFileSync(f, "utf8").replace(
      "const targets: []const std.Target.Query",
      "const release_targets: []const std.Target.Query",
    ),
  );
' "$root"
expect fail "renamed declaration in build/release.zig" "$root"
contains "  ...says the gate is now checking nothing" "this gate is now checking nothing"

root="$(fixture emptied-matrix)"
node -e '
  const fs = require("node:fs");
  const f = process.argv[1] + "/.github/workflows/release.yml";
  fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace(/^ *- target: .*$/gm, "          # removed"));
' "$root"
expect fail "release.yml with no matrix rows left" "$root"
contains "  ...says the matrix moved" "the build matrix moved"

if [ "$failures" -ne 0 ]; then
  echo "FAILED: $failures case(s)"
  exit 1
fi
echo "PASS: npm release-target drift gate"
