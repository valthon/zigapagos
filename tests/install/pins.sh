#!/usr/bin/env bash
# install.sh restates facts that live somewhere else. This is the gate that keeps
# the copies honest.
#
# An installer is a pile of constants — a bun version, a zigbase version, a cache
# path, a set of target triples, an environment variable name, the wording of a
# refusal. Every one of them is owned by another file, and none of them fails
# visibly when it drifts: a stale zigbase pin downloads a server the binary then
# ignores, a stale target triple 404s on a release that exists, a cache path that
# has moved re-downloads on every `dev`. Nothing in a normal build reads
# install.sh, so nothing would notice.
#
# Pure grep over tracked text: no toolchain, no network, sub-second.
#
# Every single-quoted string below is a LITERAL to find in another file, never a
# shell expansion — that is what this gate does — so SC2016 is off for the file
# rather than repeated above a dozen greps.
# shellcheck disable=SC2016
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS $*"; }

INSTALL=install.sh
[ -f "$INSTALL" ] || fail "install.sh is missing from the repository root"

pin() { sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" "$INSTALL" | head -1; }

# --- bun ---------------------------------------------------------------------
# mise.toml pins a RANGE (`bun = "1.2"`); install.sh needs an exact version,
# because a range is not a download URL. So the assertion is containment, not
# equality: the exact version must be inside the range the rest of the repository
# was built and tested against.
BUN_PIN="$(pin BUN_VERSION)"
[ -n "$BUN_PIN" ] || fail "could not read BUN_VERSION out of install.sh"
MISE_BUN="$(sed -n 's/^[[:space:]]*bun[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' mise.toml | head -1)"
[ -n "$MISE_BUN" ] || fail "could not read the bun pin out of mise.toml"
case "$BUN_PIN" in
  "$MISE_BUN"|"$MISE_BUN".*) ;;
  *) fail "install.sh pins bun $BUN_PIN, which is not inside mise.toml's '$MISE_BUN'" ;;
esac
pass "bun pin $BUN_PIN is inside mise.toml's $MISE_BUN"

# --- zigbase -----------------------------------------------------------------
# Equality, not containment: the binary looks for EXACTLY this version at EXACTLY
# the path below (src/cli/zigbase.zig's `cachedPath`). A different version here is
# a download the locator will never look at, followed by a second download on the
# first `zigapagos dev`.
ZB_PIN="$(pin ZIGBASE_VERSION)"
ZB_ZIG="$(sed -n 's/^pub const pinned_version = "\(.*\)";$/\1/p' src/cli/zigbase.zig)"
[ -n "$ZB_ZIG" ] || fail "could not read pinned_version out of src/cli/zigbase.zig"
[ "$ZB_PIN" = "$ZB_ZIG" ] \
  || fail "install.sh pins zigbase $ZB_PIN, src/cli/zigbase.zig pins $ZB_ZIG"
pass "zigbase pin $ZB_PIN matches src/cli/zigbase.zig"

ZB_REPO="$(pin ZIGBASE_REPO)"
ZB_REPO_ZIG="$(sed -n 's/^pub const release_repo = "\(.*\)";$/\1/p' src/cli/zigbase.zig)"
[ "$ZB_REPO" = "$ZB_REPO_ZIG" ] \
  || fail "install.sh fetches zigbase from '$ZB_REPO', the binary from '$ZB_REPO_ZIG'"
pass "zigbase repo matches src/cli/zigbase.zig"

# The cache layout, which is the whole reason the prefetch is worth doing: land
# the binary anywhere else and it is invisible to the locator.
grep -q 'ZIGBASE_DIR="\$CACHE_ROOT/zigapagos/zigbase/\$ZIGBASE_VERSION"' "$INSTALL" \
  || fail "install.sh's zigbase cache path is not <cache>/zigapagos/zigbase/<version>"
grep -q '"zigapagos", "zigbase", pinned_version, exe_name' src/cli/zigbase.zig \
  || fail "src/cli/zigbase.zig's cachedPath layout changed; install.sh's prefetch path is now wrong"
pass "the zigbase cache path matches the locator's"

# --- the runtime environment variable ----------------------------------------
# The launcher exports it; the binary reads it. A rename on either side produces
# an install that renders no islands and says nothing about why.
grep -q 'ZIGAPAGOS_RUNTIME_DIR' "$INSTALL" || fail "install.sh no longer sets ZIGAPAGOS_RUNTIME_DIR"
grep -rq 'ZIGAPAGOS_RUNTIME_DIR' src/cli/release.zig \
  || fail "src/cli/release.zig no longer reads ZIGAPAGOS_RUNTIME_DIR"
pass "ZIGAPAGOS_RUNTIME_DIR is spelled the same on both sides"

# --- target triples ----------------------------------------------------------
# Derive every required arch and OS suffix from targets.json. This deliberately
# has no target count: adding a supported target extends the gate automatically.
while read -r triple; do
  arch="${triple%%-*}"
  os_abi="${triple#*-}"
  case "$arch" in
    x86_64) grep -qF 'ZIG_ARCH="x86_64"' "$INSTALL" || fail "no installer arch mapping for '$triple'" ;;
    aarch64) grep -qF 'ZIG_ARCH="aarch64"' "$INSTALL" || fail "no installer arch mapping for '$triple'" ;;
    *) grep -qF "ZIG_ARCH=\"$arch\"" "$INSTALL" || fail "no installer arch mapping for '$triple'" ;;
  esac
  grep -qF "TARGET=\"\$ZIG_ARCH-$os_abi\"" "$INSTALL" \
    || fail "install.sh cannot derive target '$triple'"
done < <(node -e 'for (const t of require("./npm/cli/targets.json")) console.log(t.zig)')
pass "install.sh can derive every target in the release matrix"

# And the archive names, which install.sh builds rather than lists.
while read -r archive; do
  case "$archive" in
    *.tar.xz) grep -q 'ARCHIVE="\$TARGET.tar.xz"' "$INSTALL" || fail "no .tar.xz branch for '$archive'" ;;
    *.zip) grep -q 'ARCHIVE="\$TARGET.zip"' "$INSTALL" || fail "no .zip branch for '$archive'" ;;
    *) fail "unknown archive extension in targets.json: '$archive'" ;;
  esac
done < <(node -e '
  for (const t of require("./npm/cli/targets.json")) console.log(t.archive);
')
pass "install.sh derives the same archive names as the release matrix"

# --- the runtime asset -------------------------------------------------------
# Three files have to agree on one filename, and two of them are in different
# languages from the third.
grep -q 'runtime.tar.xz' "$INSTALL" || fail "install.sh does not fetch runtime.tar.xz"
grep -q 'ARCHIVE="\$OUT_DIR/runtime.tar.xz"' scripts/pack-runtime.sh \
  || fail "scripts/pack-runtime.sh no longer produces runtime.tar.xz"
grep -q 'runtime.tar.xz' .github/workflows/release.yml \
  || fail "the release workflow does not publish runtime.tar.xz — install.sh would 404"
pass "runtime.tar.xz is named identically by the installer, the packer and the release"

# --- the runtime asset is reproducible ---------------------------------------
# `runtime.tar.xz` must vendor the typescript version runtime/bun.lock RESOLVED,
# never the `^6.0.3` range from package.json. Resolving a range at pack time means
# the same tag rebuilt later can ship a different compiler from identical sources
# — the thing npm/publish.mjs already refuses to do ("a rebuild, even from the
# same commit, is a second chance to be different").
#
# STATIC, and deliberately so. tests/install/e2e.sh asserts the installed version
# equals the lockfile's, but that comparison cannot fail while the lockfile's
# version is still the newest in its range — it is a pin that arms itself when
# typescript next publishes, not one that fails today. This one fails the moment
# the derivation is reverted.
grep -q 'runtime/bun.lock' scripts/pack-runtime.sh \
  || fail "scripts/pack-runtime.sh no longer reads runtime/bun.lock — the runtime asset is no longer reproducible"
grep -q 'typescript@\$TS_VERSION' scripts/pack-runtime.sh \
  || fail "scripts/pack-runtime.sh does not install typescript at an exact version"
if grep -qE 'typescript@\$TS_RANGE|devDependencies\.typescript' scripts/pack-runtime.sh; then
  fail "scripts/pack-runtime.sh resolves typescript from a semver range again; use the exact version in runtime/bun.lock"
fi
grep -qE '"typescript@[0-9]' runtime/bun.lock \
  || fail "runtime/bun.lock has no resolved typescript entry — scripts/pack-runtime.sh's extraction would find nothing"
pass "the runtime asset pins typescript from runtime/bun.lock, not from a range"

# --- refusal wording ---------------------------------------------------------
# npm and the installer still refuse Windows with the same explanation.
for fragment in "Windows is not supported yet"; do
  grep -qF "$fragment" "$INSTALL" || fail "install.sh no longer says '$fragment'"
  grep -qF "$fragment" npm/cli/index.js || fail "npm/cli/index.js no longer says '$fragment'"
done
pass "the Windows refusal is worded the same as npm's"

# --- the repository ----------------------------------------------------------
[ "$(pin REPO)" = "valthon/zigapagos" ] || fail "install.sh's REPO is not valthon/zigapagos"
pass "the release repository is valthon/zigapagos"

echo "PASS tests/install/pins.sh"
