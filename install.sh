#!/bin/sh
# The Zigapagos installer.
#
#   curl -fsSL https://valthon.github.io/zigapagos/install.sh | sh
#
# Installs a COMPLETE zigapagos — the binary, the @z/runtime tree it needs to
# render islands and SPAs, and (only when the host has none) Bun and ZigBase. The
# result is equivalent in capability to `npm i zigapagos`, without Node.js.
#
# This is deliberately not a two-line "untar a binary into /usr/local/bin"
# script, because that install does not work: the sidecar, the bundlers and the
# runtime slicers are scripts *inside* the @z/runtime tree, the release archives
# contain the binary alone, and a user who installed that way discovers it only
# when their first island fails to render.
#
# WHAT IT TOUCHES, exhaustively:
#
#   $XDG_DATA_HOME/zigapagos/versions/<tag>/   the payload  (default ~/.local/share)
#   $XDG_DATA_HOME/zigapagos/current           symlink to the active version
#   ~/.local/bin/zigapagos                     a generated shim
#   $XDG_CACHE_HOME/zigapagos/zigbase/<ver>/   the binary's own existing cache path
#
# No sudo. No writes outside those paths — in particular it does not edit
# .bashrc, .zshrc or .profile. It prints the line to add if one is needed.
#
# POSIX sh: no bashisms, no `pipefail`. It is piped into whatever /bin/sh is.
set -eu

# --- pins --------------------------------------------------------------------
# Each of these is checked against its source of truth by tests/install/pins.sh,
# because a pin that drifts here installs a different toolchain than every other
# channel and nothing else in the build would notice.
REPO="valthon/zigapagos"
# An exact version, matching mise.toml's `bun = "1.3.14"`. mise moved from a
# range to an exact pin when bun 1.3 landed — a floating minor was how a silent
# bundler change (content-hash drift) could arrive mid-release — so this is now
# equality with mise.toml rather than a member of its range, and
# tests/install/pins.sh holds the two together either way.
BUN_VERSION="1.3.14"
# Mirrors `pinned_version` in src/cli/zigbase.zig — the binary looks for exactly
# this version in exactly the path below, so a different one here would be
# downloaded and then ignored.
ZIGBASE_VERSION="v0.12.0"
ZIGBASE_REPO="valthon/zigbase"

# --- defaults, overridable ---------------------------------------------------
RELEASE_BASE_URL="${ZIGAPAGOS_INSTALL_BASE_URL:-https://github.com/$REPO/releases/download}"
# Test hooks. The download paths are the half of an installer most likely to be
# wrong and least likely to be exercised, so they are pointable at a fixture
# release on local disk (curl reads file:// URLs) rather than reachable only
# through the live internet.
BUN_BASE_URL="${ZIGAPAGOS_INSTALL_BUN_BASE_URL:-https://github.com/oven-sh/bun/releases/download}"
ZIGBASE_BASE_URL="${ZIGAPAGOS_INSTALL_ZIGBASE_BASE_URL:-https://github.com/$ZIGBASE_REPO/releases/download}"

VERSION="${ZIGAPAGOS_VERSION:-}"
DATA_DIR="${ZIGAPAGOS_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zigapagos}"
BIN_DIR="${ZIGAPAGOS_BIN_DIR:-$HOME/.local/bin}"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}"
WANT_BUN=1
WANT_ZIGBASE=1

usage() {
  cat <<'EOF'
Install zigapagos.

  curl -fsSL https://valthon.github.io/zigapagos/install.sh | sh
  curl -fsSL https://valthon.github.io/zigapagos/install.sh | sh -s -- --version v0.2.0

Options:
  --version <tag>   install this release instead of the newest  [$ZIGAPAGOS_VERSION]
  --prefix <dir>    payload directory   [$ZIGAPAGOS_INSTALL_DIR, ~/.local/share/zigapagos]
  --bin-dir <dir>   where the launcher goes  [$ZIGAPAGOS_BIN_DIR, ~/.local/bin]
  --no-bun          never install a private Bun (use whatever is on PATH)
  --no-zigbase      never prefetch ZigBase (`zigapagos dev` will fetch it itself)
  --base-url <url>  fetch release assets from here instead of GitHub
  -h, --help        this

Installing is idempotent: re-running places a new version alongside the old one
and repoints the launcher. Nothing is ever removed.
EOF
}

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- arguments ---------------------------------------------------------------
# `sh -s -- --flag` is how a piped script receives arguments; an unknown flag is
# an error rather than a silent no-op, because a typo'd `--prefix` would
# otherwise install to the default location and report success.
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || fail "--version needs a tag"; VERSION="$2"; shift 2 ;;
    --prefix) [ $# -ge 2 ] || fail "--prefix needs a directory"; DATA_DIR="$2"; shift 2 ;;
    --bin-dir) [ $# -ge 2 ] || fail "--bin-dir needs a directory"; BIN_DIR="$2"; shift 2 ;;
    --base-url) [ $# -ge 2 ] || fail "--base-url needs a URL"; RELEASE_BASE_URL="$2"; shift 2 ;;
    --no-bun) WANT_BUN=0; shift ;;
    --no-zigbase) WANT_ZIGBASE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown option '$1'" ;;
  esac
done

# --- host --------------------------------------------------------------------
uname_s="$(uname -s)"
uname_m="$(uname -m)"

case "$uname_m" in
  x86_64|amd64) ZIG_ARCH="x86_64"; BUN_ARCH="x64" ;;
  arm64|aarch64) ZIG_ARCH="aarch64"; BUN_ARCH="aarch64" ;;
  *) fail "unsupported architecture '$uname_m'. Prebuilt: x86_64 and arm64 on Linux and macOS." ;;
esac

case "$uname_s" in
  Linux)
    TARGET="$ZIG_ARCH-linux-musl"
    ARCHIVE="$TARGET.tar.xz"
    BUN_OS="linux"
    ;;
  Darwin)
    TARGET="$ZIG_ARCH-macos"
    ARCHIVE="$TARGET.zip"
    BUN_OS="darwin"
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    fail "Windows is not supported yet (upstream's WindowsWatcher.zig/wuffs.zig do not
compile on released Zig 0.16.0). Use WSL2 meanwhile."
    ;;
  *)
    fail "unsupported OS '$uname_s'. Prebuilt: Linux and macOS."
    ;;
esac

# --- preflight ---------------------------------------------------------------
# Up front, before ~30 MB of downloads, so a host missing `unzip` learns that in
# the first second rather than the last.
have() { command -v "$1" >/dev/null 2>&1; }

need() {
  have "$1" || fail "'$1' is required and was not found on PATH.$2"
}

need curl " Install curl and re-run."
need tar " Install tar and re-run."

# `unzip` is needed for two independent reasons, and BOTH are decided here rather
# than at the point of use:
#
#   - the macOS release asset is a zip;
#   - Bun's release assets are zips on every platform, so a host that has no bun
#     for us to reuse needs unzip to get one.
#
# The second case is why this is not simply `if Darwin`. A Linux host with no bun
# and no unzip used to install "successfully" and then skip Bun with a warning —
# which left a launcher that fails on the user's first island build, having
# reported success, and contradicted the promise that this install is complete.
# Failing here instead means the user learns before any download, and the fix
# (install unzip, or `--no-bun` and bring your own Bun) is stated with it.
if [ "$uname_s" = "Darwin" ]; then
  need unzip " The macOS release asset is a zip. Install unzip and re-run."
elif [ "$WANT_BUN" -eq 1 ] && ! have bun; then
  need unzip " Bun's release assets are zips and this host has no bun to reuse.
Install unzip, or pass --no-bun and install Bun yourself (https://bun.sh)."
fi
# GNU tar shells out to the `xz` binary for .tar.xz; bsdtar (macOS) links liblzma
# and does not. Both release payloads on Linux are .tar.xz, so this is required
# there and not here.
if [ "$uname_s" = "Linux" ]; then
  need xz " Install xz-utils and re-run."
fi

# Whichever of the three is present. An install that proceeded without verifying
# would be a `curl | sh` that executes unauthenticated bytes, which is the one
# thing this script must never do.
if have sha256sum; then SHA_TOOL=sha256sum
elif have shasum; then SHA_TOOL=shasum
elif have openssl; then SHA_TOOL=openssl
else
  fail "no SHA-256 tool found (looked for sha256sum, shasum, openssl).
Downloads cannot be verified, so nothing was installed."
fi

# The three tools put the digest in different places, so the field is chosen per
# tool rather than by a clever rule that reads both:
#   sha256sum / shasum   `<hex>  <file>`          -> first field
#   openssl dgst         `SHA2-256(<file>)= <hex>` -> last field
# Writing to a file rather than piping, because this repo's shells disagree about
# `pipefail` and a digest tool that failed mid-pipe would otherwise hand back an
# empty string that the caller compares against the expected hash.
sha256_of() {
  case "$SHA_TOOL" in
    sha256sum) sha256sum "$1" > "$TMP/.sum" && awk '{ print $1 }' "$TMP/.sum" ;;
    shasum) shasum -a 256 "$1" > "$TMP/.sum" && awk '{ print $1 }' "$TMP/.sum" ;;
    openssl) openssl dgst -sha256 "$1" > "$TMP/.sum" && awk '{ print $NF }' "$TMP/.sum" ;;
  esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zigapagos-install.XXXXXX")"
# Everything downloaded lands here and is verified here. The payload directory is
# only ever written to after a checksum has matched, so an interrupted or
# tampered download cannot leave a half-installed version behind.
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

fetch() {
  curl -fsSL --retry 2 -o "$2" "$1" ||
    fail "download failed: $1"
}

# Verify $1 (a local file) against the entry for $2 in the SHA256SUMS-style file
# $3. Handles the `./name` spelling `find -printf` and `sha256sum -b`'s `*name`,
# because the two release channels this reads from format theirs differently.
verify() {
  verify_expected="$(
    awk -v want="$2" '
      { name = $2; sub(/^\.\//, "", name); sub(/^\*/, "", name)
        if (name == want) { print $1; exit } }
    ' "$3"
  )"
  [ -n "$verify_expected" ] ||
    fail "'$2' has no entry in the published checksums; refusing to install it."
  verify_actual="$(sha256_of "$1")"
  [ -n "$verify_actual" ] || fail "could not compute a SHA-256 for '$2'."
  [ "$verify_expected" = "$verify_actual" ] || fail "checksum mismatch for '$2'.
  expected $verify_expected
  actual   $verify_actual
Nothing was installed."
}

# --- which release -----------------------------------------------------------
# The `releases/latest` REDIRECT, not api.github.com. The API rate-limits
# unauthenticated callers to 60 requests per hour per IP; behind a corporate NAT
# or on a CI runner that is an install which fails for a reason the user cannot
# see and cannot fix. The redirect has no such limit.
if [ -z "$VERSION" ]; then
  latest_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/$REPO/releases/latest")" ||
    fail "could not reach GitHub to find the latest release.
Pass --version <tag> to install a specific one."
  VERSION="${latest_url##*/}"
  case "$VERSION" in
    v*) ;;
    *) fail "could not parse a version tag out of '$latest_url'.
Pass --version <tag> instead." ;;
  esac
fi

ASSET_URL="$RELEASE_BASE_URL/$VERSION"
VERSION_DIR="$DATA_DIR/versions/$VERSION"

say "installing zigapagos $VERSION ($TARGET) into $VERSION_DIR"

# --- download and verify -----------------------------------------------------
fetch "$ASSET_URL/SHA256SUMS" "$TMP/SHA256SUMS"
fetch "$ASSET_URL/$ARCHIVE" "$TMP/$ARCHIVE"
fetch "$ASSET_URL/runtime.tar.xz" "$TMP/runtime.tar.xz"
verify "$TMP/$ARCHIVE" "$ARCHIVE" "$TMP/SHA256SUMS"
verify "$TMP/runtime.tar.xz" "runtime.tar.xz" "$TMP/SHA256SUMS"

# --- unpack ------------------------------------------------------------------
# Into a scratch directory first, then moved into place, so a failure part-way
# through extraction does not leave a version directory that looks installed.
STAGE="$TMP/stage"
mkdir -p "$STAGE/bin"
case "$ARCHIVE" in
  *.zip) unzip -q -o "$TMP/$ARCHIVE" -d "$STAGE/bin" ;;
  *) tar -xJf "$TMP/$ARCHIVE" -C "$STAGE/bin" ;;
esac
[ -f "$STAGE/bin/zigapagos" ] ||
  fail "'$ARCHIVE' did not contain a 'zigapagos' binary."
chmod +x "$STAGE/bin/zigapagos"

# The tarball's single root is `runtime/`, so this lands at $STAGE/runtime.
tar -xJf "$TMP/runtime.tar.xz" -C "$STAGE"
[ -f "$STAGE/runtime/sidecar/standalone.ts" ] ||
  fail "'runtime.tar.xz' did not contain the Bun sidecar."

rm -rf "$VERSION_DIR"
mkdir -p "$DATA_DIR/versions"
mv "$STAGE" "$VERSION_DIR"

# --- bun ---------------------------------------------------------------------
# Only when the host has none. A bun already on PATH is the user's choice of
# version and toolchain, and replacing it — or shadowing it — is not this
# script's business.
if [ "$WANT_BUN" -eq 1 ] && ! have bun; then
  # Bun publishes a `-baseline` x64 build for CPUs without AVX2, and the default
  # build crashes with SIGILL on them rather than reporting anything useful. Bun's
  # own installer makes the same distinction; skipping it would make this script
  # break on exactly the older hardware most likely to be someone's only machine.
  BUN_VARIANT=""
  if [ "$BUN_ARCH" = "x64" ]; then
    if [ "$BUN_OS" = "linux" ]; then
      grep -qw avx2 /proc/cpuinfo 2>/dev/null || BUN_VARIANT="-baseline"
    else
      sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -q AVX2 || BUN_VARIANT="-baseline"
    fi
  fi
  BUN_ASSET="bun-$BUN_OS-$BUN_ARCH$BUN_VARIANT.zip"
  BUN_TAG="bun-v$BUN_VERSION"
  say "installing bun $BUN_VERSION (none found on PATH)"
  # No `have unzip` guard here: the preflight already refused to start an install
  # that would reach this point without it. Degrading silently at this stage would
  # be the worst place to do it — the payload is on disk and the launcher is about
  # to be written, so the install reports success and fails later, in the user's
  # build, naming bun rather than naming unzip.
  fetch "$BUN_BASE_URL/$BUN_TAG/$BUN_ASSET" "$TMP/$BUN_ASSET"
  fetch "$BUN_BASE_URL/$BUN_TAG/SHASUMS256.txt" "$TMP/SHASUMS256.txt"
  verify "$TMP/$BUN_ASSET" "$BUN_ASSET" "$TMP/SHASUMS256.txt"
  unzip -q -o "$TMP/$BUN_ASSET" -d "$TMP/bun"
  # The zip wraps the binary in a directory named after the asset.
  [ -f "$TMP/bun/bun-$BUN_OS-$BUN_ARCH$BUN_VARIANT/bun" ] ||
    fail "'$BUN_ASSET' did not contain a 'bun' binary."
  mkdir -p "$VERSION_DIR/bun"
  mv "$TMP/bun/bun-$BUN_OS-$BUN_ARCH$BUN_VARIANT/bun" "$VERSION_DIR/bun/bun"
  chmod +x "$VERSION_DIR/bun/bun"
fi

# --- zigbase -----------------------------------------------------------------
# Into the cache path the binary already looks in, so nothing new has to be
# taught about it: this is step 3 of src/cli/zigbase.zig's locator, prefetched.
# `zigapagos dev` would do exactly this on first run; doing it here moves the
# download off the critical path of someone's first command.
ZIGBASE_DIR="$CACHE_ROOT/zigapagos/zigbase/$ZIGBASE_VERSION"
if [ "$WANT_ZIGBASE" -eq 1 ] && ! have zigbase && [ ! -x "$ZIGBASE_DIR/zigbase" ]; then
  ZIGBASE_ASSET="zigbase-${ZIGBASE_VERSION#v}-$TARGET.tar.gz"
  say "prefetching zigbase $ZIGBASE_VERSION (none found on PATH)"
  mkdir -p "$ZIGBASE_DIR"
  fetch "$ZIGBASE_BASE_URL/$ZIGBASE_VERSION/$ZIGBASE_ASSET" "$TMP/$ZIGBASE_ASSET"
  fetch "$ZIGBASE_BASE_URL/$ZIGBASE_VERSION/SHA256SUMS" "$TMP/zigbase-SHA256SUMS"
  verify "$TMP/$ZIGBASE_ASSET" "$ZIGBASE_ASSET" "$TMP/zigbase-SHA256SUMS"
  # --strip-components=1: the tarball wraps everything in `zigbase-<ver>-<target>/`
  # and the binary must land exactly at $ZIGBASE_DIR/zigbase, which is the path
  # the locator computes.
  tar -xzf "$TMP/$ZIGBASE_ASSET" -C "$ZIGBASE_DIR" --strip-components=1
  [ -f "$ZIGBASE_DIR/zigbase" ] ||
    fail "'$ZIGBASE_ASSET' did not contain a 'zigbase' binary."
  chmod +x "$ZIGBASE_DIR/zigbase"
fi

# --- activate ----------------------------------------------------------------
# One symlink flip. The launcher below points at `current`, never at a version
# directory, so upgrading never rewrites it and an older tag can be re-activated
# by pointing this somewhere else.
#
# `-n` is load-bearing, not decoration: without it, `ln -sf` given an existing
# symlink-to-a-directory follows it and creates the new link *inside* the old
# version's directory. `-n` makes it replace the link, which is the whole
# operation. Both GNU and BSD ln have it.
mkdir -p "$DATA_DIR"
ln -sfn "$VERSION_DIR" "$DATA_DIR/current"

mkdir -p "$BIN_DIR"
LAUNCHER="$BIN_DIR/zigapagos"
cat > "$LAUNCHER" <<EOF
#!/bin/sh
# Generated by the zigapagos installer. Edits here are lost on the next install.
#
# ZIGAPAGOS_RUNTIME_DIR is what lets this install render islands and SPAs: the
# sidecar, the bundlers and the runtime slicers are scripts inside that tree, and
# the binary has no other way to find them. Setting it here rather than in a shell
# profile keeps it scoped to the process that needs it — an exported variable in a
# dotfile is invisible to non-login shells and CI, leaks into every other program,
# and outlives an uninstall.
ZIGAPAGOS_HOME="$DATA_DIR/current"
ZIGAPAGOS_RUNTIME_DIR="\$ZIGAPAGOS_HOME/runtime"
export ZIGAPAGOS_RUNTIME_DIR

# APPENDED, never prepended — the same rule npm/cli/index.js documents for its own
# node_modules/.bin. The zigbase locator's second step is a PATH scan, so a bun or
# zigbase the user put on PATH deliberately has to keep winning; this is a
# fallback for a host that had neither, not a substitution.
if [ -x "\$ZIGAPAGOS_HOME/bun/bun" ]; then
  PATH="\$PATH:\$ZIGAPAGOS_HOME/bun"
  export PATH
fi

exec "\$ZIGAPAGOS_HOME/bin/zigapagos" "\$@"
EOF
chmod +x "$LAUNCHER"

say ""
say "zigapagos $VERSION installed."
say "  launcher  $LAUNCHER"
say "  payload   $VERSION_DIR"

# --- PATH advice -------------------------------------------------------------
# Printed, never applied. Editing someone's shell profile from a piped script is
# a side effect they did not ask for and cannot see, and getting it wrong (the
# wrong file, a login-vs-interactive shell, a profile that re-sets PATH later)
# fails in ways that are tedious to diagnose.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    say ""
    say "$BIN_DIR is not on your PATH. Add it:"
    say ""
    say "  export PATH=\"\$PATH:$BIN_DIR\""
    say ""
    zigapagos_shell="${SHELL:-}"
    case "${zigapagos_shell##*/}" in
      zsh) say "  (put that in ~/.zshrc)" ;;
      bash) say "  (put that in ~/.bashrc)" ;;
      fish) say "  (fish: fish_add_path $BIN_DIR)" ;;
      *) say "  (put that in your shell's startup file)" ;;
    esac
    ;;
esac

say ""
say "Next:  zigapagos init && zigapagos dev"
