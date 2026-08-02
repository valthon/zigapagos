#!/usr/bin/env bash
# End-to-end test of install.sh against a fixture release on local disk.
#
# WHAT THIS IS FOR. install.sh is the headline install method, and the thing it
# has to get right is not "put a binary on PATH" — it is that the install can
# RENDER AN ISLAND afterwards. That needs the binary, the @z/runtime tree, the
# vendored node_modules inside it, ZIGAPAGOS_RUNTIME_DIR reaching the process,
# and a bun. Any one of them missing produces an install that passes a `zigapagos
# version` smoke test and then fails on the user's first real build. So phase 2
# below builds a site with an island through the installed launcher, with NO
# --island-* flags of any kind: everything the sidecar needs has to come from the
# environment the generated shim sets up.
#
# Five phases:
#   (1) a fixture install: layout, launcher, `zigapagos version`
#   (2) a REAL island build through the launcher — the assertion that matters
#   (3) bun placement, with bun hidden from PATH
#   (4) idempotence: a second tag repoints `current` and leaves the first intact
#   (5) integrity: a corrupted archive is fatal and installs nothing
#
# Hermetic: no network. curl reads the file:// fixture channels built by
# fixture.bash. Requires bun on PATH (phase 2 runs the real sidecar) and zip.
set -euo pipefail
cd "$(dirname "$0")/../.."
FIXTURE_REPO="$PWD"
export FIXTURE_REPO

FIXTURE_BIN="${ZIGAPAGOS_BIN:-$FIXTURE_REPO/zig-out/bin/zigapagos}"
export FIXTURE_BIN

fail() { echo "FAIL: $*"; exit 1; }

[ -x "$FIXTURE_BIN" ] || fail "no zigapagos binary at $FIXTURE_BIN (run 'zig build', or set ZIGAPAGOS_BIN)"
command -v bun >/dev/null || fail "bun not found on PATH (phase 2 runs the real island sidecar)"
command -v zip >/dev/null || fail "zip not found on PATH (needed to build the fixture bun release)"

# shellcheck source=tests/install/fixture.bash
source "$FIXTURE_REPO/tests/install/fixture.bash"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CHANNEL="$WORK/channel"
BUN_CHANNEL="$WORK/bun-channel"
ZIGBASE_CHANNEL="$WORK/zigbase-channel"
TAG1="v9.9.1"
TAG2="v9.9.2"

echo "building fixture release channels..."
fixture_release "$CHANNEL" "$TAG1"
fixture_bun "$BUN_CHANNEL"
fixture_zigbase "$ZIGBASE_CHANNEL"

# HOME is redirected for every run below. install.sh derives its cache path from
# $XDG_CACHE_HOME/$HOME, and a test that prefetched zigbase into the developer's
# real ~/.cache would be a test with a side effect on the machine running it.
run_install() { # DEST_HOME  extra args…
  local home="$1"; shift
  mkdir -p "$home"
  env HOME="$home" \
      XDG_DATA_HOME="$home/.local/share" \
      XDG_CACHE_HOME="$home/.cache" \
      ZIGAPAGOS_INSTALL_BUN_BASE_URL="file://$BUN_CHANNEL" \
      ZIGAPAGOS_INSTALL_ZIGBASE_BASE_URL="file://$ZIGBASE_CHANNEL" \
      sh "$FIXTURE_REPO/install.sh" --base-url "file://$CHANNEL" "$@"
}

# --- (1) a fixture install ---------------------------------------------------
H1="$WORK/home1"
run_install "$H1" --version "$TAG1" > "$WORK/install1.log" 2>&1 \
  || { cat "$WORK/install1.log"; fail "the fixture install failed"; }

DATA="$H1/.local/share/zigapagos"
LAUNCHER="$H1/.local/bin/zigapagos"

[ -x "$DATA/versions/$TAG1/bin/zigapagos" ] || fail "the binary is not at versions/$TAG1/bin/zigapagos"
[ -f "$DATA/versions/$TAG1/runtime/sidecar/standalone.ts" ] || fail "the runtime tree was not installed"
[ -d "$DATA/versions/$TAG1/runtime/node_modules/preact" ] || fail "the runtime's vendored node_modules is missing preact"

# The vendored typescript is the version runtime/bun.lock names, not whatever the
# `^6.0.3` range resolved to at pack time. Asserted on the INSTALLED tree rather
# than only inside the packer, because this is the property a user gets: the same
# tag rebuilt later must vendor the same compiler.
LOCK_TS="$(sed -n 's/.*"typescript@\([0-9][^"]*\)".*/\1/p' "$FIXTURE_REPO/runtime/bun.lock" | head -1)"
[ -n "$LOCK_TS" ] || fail "could not read a resolved typescript version out of runtime/bun.lock"
INSTALLED_TS="$(node -e 'process.stdout.write(require(process.argv[1]).version)' \
  "$DATA/versions/$TAG1/runtime/node_modules/typescript/package.json")"
[ "$INSTALLED_TS" = "$LOCK_TS" ] \
  || fail "installed typescript is $INSTALLED_TS, runtime/bun.lock pins $LOCK_TS"
[ -L "$DATA/current" ] || fail "$DATA/current is not a symlink"
[ -x "$LAUNCHER" ] || fail "no launcher at $LAUNCHER"

# The launcher must point at `current`, never at a version directory: that is what
# makes an upgrade a symlink flip rather than a rewrite, and phase 4 depends on it.
grep -q 'ZIGAPAGOS_HOME="'"$DATA"'/current"' "$LAUNCHER" \
  || { cat "$LAUNCHER"; fail "the launcher does not resolve through \$DATA/current"; }
grep -q 'export ZIGAPAGOS_RUNTIME_DIR' "$LAUNCHER" \
  || fail "the launcher does not export ZIGAPAGOS_RUNTIME_DIR"
# Appended, never prepended — see the launcher's own comment and npm/cli/index.js.
# A prepend here would silently shadow a bun the user chose.
# shellcheck disable=SC2016 # a literal to find in the generated launcher, not an expansion
grep -q 'PATH="\$PATH:\$ZIGAPAGOS_HOME/bun"' "$LAUNCHER" \
  || { cat "$LAUNCHER"; fail "the launcher prepends to PATH instead of appending"; }

"$LAUNCHER" version > "$WORK/version.txt" 2>&1 || { cat "$WORK/version.txt"; fail "'zigapagos version' failed through the launcher"; }
grep -qi zigapagos "$WORK/version.txt" || { cat "$WORK/version.txt"; fail "'version' did not identify zigapagos"; }

# ZigBase landed in the cache path the BINARY computes, not merely somewhere.
ZB="$H1/.cache/zigapagos/zigbase/$(fixture_pin ZIGBASE_VERSION)/zigbase"
[ -x "$ZB" ] || fail "zigbase was not prefetched to $ZB"

echo "PASS (1) layout, launcher, version, zigbase prefetch"

# --- (2) a real island build through the launcher ----------------------------
# No --island-sidecar, no --island-src-dir, no --bun. If the installed tree is
# wrong in any way, this is where it shows.
SITE="$WORK/site"
mkdir -p "$SITE/content" "$SITE/layouts" "$SITE/assets" "$SITE/components"
: > "$SITE/assets/.keep"
cat > "$SITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Installer Test",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
}
EOF
cat > "$SITE/layouts/plain.shtml" <<'EOF'
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <title :text="$site.title"></title>
  </head>
  <body>
    <island src="components/Counter.island.tsx" client:load :props='{ .start = 41 }'></island>
    <div :html="$page.content()"></div>
  </body>
</html>
EOF
cat > "$SITE/components/Counter.island.tsx" <<'EOF'
export interface Props { start: number }
export default function Counter({ start }: Props) {
  return `INSTALLER-SSR-${start}`;
}
EOF
cat > "$SITE/content/index.smd" <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "plain.shtml",
.draft = false,
---
Some prose.
EOF

( cd "$SITE" && "$LAUNCHER" release --output="$WORK/out" --force ) > "$WORK/build.log" 2>&1 \
  || { sed -n '1,60p' "$WORK/build.log"; fail "the island build failed through the installed launcher"; }

INDEX="$WORK/out/index.html"
[ -f "$INDEX" ] || fail "no index.html was emitted"
grep -q 'INSTALLER-SSR-41' "$INDEX" \
  || { sed -n '1,40p' "$INDEX"; fail "the island was not server-rendered — the installed runtime tree did not work"; }
grep -q 'data-z-props' "$INDEX" \
  || fail "no data-z-props block: the island was not spliced back into the page"

echo "PASS (2) a real island SSR'd through the installed tree"

# --- (3) bun placement -------------------------------------------------------
# With bun hidden, the installer must fetch and place one. Phase 1 could not test
# this: the machine running the tests has a bun, and skipping is the correct
# behaviour there.
H3="$WORK/home3"
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
# A PATH with everything install.sh needs EXCEPT bun. Symlinks rather than a
# filtered PATH string because `command -v bun` searches directories, and the
# only reliable way to hide one tool is to control the whole search path.
# This list is also a specification: install.sh must not depend on a tool that is
# not on it. `dirname` was on it once, and removing it from the list is what
# found — and removed — a needless dependency in the installer.
for tool in curl tar xz gzip unzip zip sha256sum shasum openssl mktemp awk sed grep uname \
            chmod mkdir rm mv ln cat env sh sysctl; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$STUBS/$tool"
done
command -v bun >/dev/null && [ ! -e "$STUBS/bun" ] || fail "the stub PATH must not contain bun"

mkdir -p "$H3"
env -i HOME="$H3" PATH="$STUBS" \
    XDG_DATA_HOME="$H3/.local/share" XDG_CACHE_HOME="$H3/.cache" \
    ZIGAPAGOS_INSTALL_BUN_BASE_URL="file://$BUN_CHANNEL" \
    ZIGAPAGOS_INSTALL_ZIGBASE_BASE_URL="file://$ZIGBASE_CHANNEL" \
    sh "$FIXTURE_REPO/install.sh" --base-url "file://$CHANNEL" --version "$TAG1" \
    > "$WORK/install3.log" 2>&1 \
  || { cat "$WORK/install3.log"; fail "the install failed with bun absent from PATH"; }

BUN_BIN="$H3/.local/share/zigapagos/versions/$TAG1/bun/bun"
[ -x "$BUN_BIN" ] || { cat "$WORK/install3.log"; fail "no bun was installed at $BUN_BIN"; }
grep -q "stub bun" <("$BUN_BIN") || fail "the installed bun is not the one from the fixture channel"

echo "PASS (3) bun is fetched and placed when the host has none"

# --- (4) idempotence ---------------------------------------------------------
fixture_release "$CHANNEL" "$TAG2"
run_install "$H1" --version "$TAG2" > "$WORK/install4.log" 2>&1 \
  || { cat "$WORK/install4.log"; fail "the second install failed"; }

[ -d "$DATA/versions/$TAG1" ] || fail "the first version's directory was removed by the second install"
[ -d "$DATA/versions/$TAG2" ] || fail "the second version was not installed"
# The `-n` on `ln -sfn`: without it the second install creates the link INSIDE
# the first version's directory and `current` still resolves to $TAG1.
resolved="$(cd "$DATA/current" && pwd -P)"
[ "$resolved" = "$(cd "$DATA/versions/$TAG2" && pwd -P)" ] \
  || fail "current points at '$resolved', expected versions/$TAG2"
[ ! -e "$DATA/versions/$TAG1/$TAG2" ] \
  || fail "the symlink was created inside the old version directory (ln is missing -n)"

echo "PASS (4) a second install repoints current and keeps the old version"

# --- (5) integrity -----------------------------------------------------------
# A corrupted archive must be fatal BEFORE anything is written. This is the one
# failure mode a `curl | sh` cannot get wrong.
BAD="$WORK/bad-channel"
mkdir -p "$BAD"
cp -R "$CHANNEL/$TAG1" "$BAD/$TAG1"
printf 'corrupted\n' >> "$BAD/$TAG1/$(fixture_archive_name)"

H5="$WORK/home5"
mkdir -p "$H5"
set +e
env HOME="$H5" XDG_DATA_HOME="$H5/.local/share" XDG_CACHE_HOME="$H5/.cache" \
    ZIGAPAGOS_INSTALL_BUN_BASE_URL="file://$BUN_CHANNEL" \
    ZIGAPAGOS_INSTALL_ZIGBASE_BASE_URL="file://$ZIGBASE_CHANNEL" \
    sh "$FIXTURE_REPO/install.sh" --base-url "file://$BAD" --version "$TAG1" \
    > "$WORK/install5.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { cat "$WORK/install5.log"; fail "a corrupted archive was installed instead of rejected"; }
grep -q "checksum mismatch" "$WORK/install5.log" \
  || { cat "$WORK/install5.log"; fail "the failure did not name the checksum mismatch"; }
[ ! -e "$H5/.local/bin/zigapagos" ] || fail "a launcher was created despite the checksum failure"
[ ! -d "$H5/.local/share/zigapagos/versions/$TAG1" ] \
  || fail "a version directory survived the checksum failure"

echo "PASS (5) a corrupted archive is fatal and installs nothing"
echo "PASS tests/install/e2e.sh"
