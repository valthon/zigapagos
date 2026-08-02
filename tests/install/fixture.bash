#!/usr/bin/env bash
# Fixture release builder for the install.sh tests. SOURCED, never executed.
#
# `.bash` and not `.sh` on purpose: CI's `tests/*/*.sh` glob runs every shell
# script under tests/ as a test, and tests/meta/script-coverage.sh fails on one
# that nothing runs. A library is neither. tests/dev/stub-zigbase.ts is the same
# idea with a different extension.
#
# WHY FIXTURES AT ALL. install.sh is mostly download-and-verify, which is the part
# of an installer least likely to be exercised before someone depends on it: you
# cannot test against the live release channel without a published release, and
# once you have one you are testing the network. So install.sh takes --base-url
# and two env hooks, and these functions build exactly the directory layout the
# real release channels have. curl reads file:// URLs, so no server is involved.
#
# Every fixture carries a real SHA256SUMS computed over the real bytes: the
# checksum path is the one part of this script that must never be stubbed out.

fixture_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

# The host's release target, spelled the way install.sh spells it. Kept here
# rather than passed in so a test cannot accidentally build a fixture for the
# wrong platform and then "pass" by never reaching the extraction.
fixture_target() {
  case "$(uname -s)" in
    Darwin) echo "x86_64-macos" ;;
    *) echo "x86_64-linux-musl" ;;
  esac
}

fixture_archive_name() {
  case "$(uname -s)" in
    Darwin) echo "$(fixture_target).zip" ;;
    *) echo "$(fixture_target).tar.xz" ;;
  esac
}

# Read a pin out of install.sh rather than restating it. tests/install/pins.sh
# checks those pins against their sources of truth; duplicating them here would
# make a fixture that agrees with a stale installer and disagrees with reality.
fixture_pin() { # VAR_NAME
  sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" "$FIXTURE_REPO/install.sh" | head -1
}

# fixture_release DIR TAG [BINARY]
# The zigapagos release channel: <DIR>/<TAG>/{<target-archive>,runtime.tar.xz,SHA256SUMS}.
fixture_release() { # DIR TAG [BINARY]
  local dir="$1" tag="$2" binary="${3:-$FIXTURE_BIN}"
  local out="$dir/$tag"
  mkdir -p "$out"

  local stage
  stage="$(mktemp -d)"
  cp "$binary" "$stage/zigapagos"
  chmod +x "$stage/zigapagos"

  case "$(uname -s)" in
    Darwin) ( cd "$stage" && zip -q -9 -j "$out/$(fixture_archive_name)" zigapagos ) ;;
    # -0 rather than the release's default: the Debug binary is ~400 MB and the
    # test does not care how well it compresses, only that the bytes survive.
    *) XZ_OPT=-0 tar -cJf "$out/$(fixture_archive_name)" -C "$stage" zigapagos ;;
  esac
  rm -rf "$stage"

  # The real asset, built by the real script. A hand-rolled tarball here would
  # test the installer against a payload the release never produces.
  if [ -z "${FIXTURE_RUNTIME_CACHE:-}" ] || [ ! -f "$FIXTURE_RUNTIME_CACHE/runtime.tar.xz" ]; then
    FIXTURE_RUNTIME_CACHE="$(mktemp -d)"
    bash "$FIXTURE_REPO/scripts/pack-runtime.sh" "$FIXTURE_RUNTIME_CACHE" >/dev/null
  fi
  cp "$FIXTURE_RUNTIME_CACHE/runtime.tar.xz" "$out/runtime.tar.xz"

  ( cd "$out" && fixture_sha256 "$(fixture_archive_name)" runtime.tar.xz > SHA256SUMS )
}

# fixture_bun DIR — the oven-sh/bun release channel, both CPU variants, so the
# test does not have to know whether the runner has AVX2.
fixture_bun() { # DIR
  local dir="$1"
  local ver tag os
  ver="$(fixture_pin BUN_VERSION)"
  tag="bun-v$ver"
  case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
  mkdir -p "$dir/$tag"

  local stage variant name
  for variant in "" "-baseline"; do
    name="bun-$os-x64$variant"
    stage="$(mktemp -d)"
    mkdir -p "$stage/$name"
    # A stub, not a real Bun: what is under test is that the installer places the
    # binary where the launcher looks, not that Bun works.
    printf '#!/bin/sh\necho "stub bun %s"\n' "$ver" > "$stage/$name/bun"
    chmod +x "$stage/$name/bun"
    ( cd "$stage" && zip -q -r "$dir/$tag/$name.zip" "$name" )
    rm -rf "$stage"
  done
  ( cd "$dir/$tag" && fixture_sha256 ./*.zip > SHASUMS256.txt )
}

# fixture_zigbase DIR — the valthon/zigbase release channel.
fixture_zigbase() { # DIR
  local dir="$1"
  local ver name
  ver="$(fixture_pin ZIGBASE_VERSION)"
  name="zigbase-${ver#v}-$(fixture_target)"
  mkdir -p "$dir/$ver"

  local stage
  stage="$(mktemp -d)"
  mkdir -p "$stage/$name"
  printf '#!/bin/sh\necho "stub zigbase %s"\n' "$ver" > "$stage/$name/zigbase"
  chmod +x "$stage/$name/zigbase"
  tar -czf "$dir/$ver/$name.tar.gz" -C "$stage" "$name"
  rm -rf "$stage"

  # `./`-prefixed, which is how the zigbase channel really spells it (see the
  # note in src/cli/zigbase.zig). zigapagos's own SHA256SUMS uses bare names, so
  # between the two channels the fixtures exercise both spellings install.sh's
  # verifier has to accept.
  ( cd "$dir/$ver" && fixture_sha256 "./$name.tar.gz" > SHA256SUMS )
}
