#!/usr/bin/env bash
# install.sh's host mapping and failure modes: accepted targets, refused hosts,
# required tools, and rejected arguments.
#
# WHY THESE ARE TESTED AT ALL. Every one of them is a path a developer never walks
# — you do not run the installer on an unsupported architecture, and your machine
# has curl. So they are exactly the paths that rot: a refusal that stopped
# matching, a preflight check that was never reached, a message that names the
# wrong tool. The person who hits one is a stranger with a broken install and no
# way to tell whether the message is right.
#
# Two mechanisms:
#   a stubbed `uname`, to stand on a host we do not have;
#   a stubbed PATH containing every tool install.sh needs EXCEPT one, because
#   `command -v` searches directories and controlling the whole search path is
#   the only reliable way to hide a single tool.
#
# Accepted-host cases reach a deliberately missing fixture download; refusal and
# preflight cases fail before the first fetch.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
INSTALL="$REPO/install.sh"

fail() { echo "FAIL: $*"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Every external tool install.sh may invoke. Kept in one place so a case can drop
# exactly one and keep the rest honest.
TOOLS=(curl tar xz gzip unzip sha256sum shasum openssl mktemp awk sed grep uname
       chmod mkdir rm mv ln cat env sh sysctl)

# make_path DIR [omit…] — a directory of symlinks to every tool except the named
# ones, for use as a complete PATH.
make_path() {
  local dir="$1"; shift
  local omit=" $* "
  mkdir -p "$dir"
  local tool src
  for tool in "${TOOLS[@]}"; do
    case "$omit" in *" $tool "*) continue ;; esac
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$dir/$tool"
  done
}

# run_expect_fail LABEL EXPECTED_SUBSTRING PATH_DIR [env assignments…]
# Runs the installer and asserts it exits non-zero with EXPECTED_SUBSTRING in its
# output. The substring is checked, not just the exit code: an installer that
# refused for the wrong reason is as bad as one that did not refuse.
run_expect_fail() {
  local label="$1" expected="$2" path_dir="$3"; shift 3
  local log="$WORK/log.$$"
  set +e
  env -i PATH="$path_dir" HOME="$WORK/home" "$@" \
    "$path_dir/sh" "$INSTALL" --version v0.0.0 --base-url "file://$WORK/nowhere" \
    > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || { cat "$log"; fail "$label: expected a non-zero exit, got 0"; }
  grep -qF "$expected" "$log" \
    || { cat "$log"; fail "$label: output does not contain '$expected'"; }
  echo "PASS $label"
}

FULL="$WORK/path-full"
make_path "$FULL"
mkdir -p "$WORK/nowhere/v0.0.0"
: > "$WORK/nowhere/v0.0.0/SHA256SUMS"

# --- host mapping ------------------------------------------------------------
# A stub uname exercises ARM target selection from any runner. The fixture URL
# deliberately does not exist: reaching the correctly named download proves the
# host was accepted and mapped without needing a foreign executable.
stub_uname() { # DIR  SYSNAME  MACHINE
  local dir="$1"
  # `rm` first: make_path already symlinked the real uname in here, and a
  # redirect through a symlink writes to its TARGET — which is /usr/bin/uname.
  rm -f "$dir/uname"
  cat > "$dir/uname" <<EOF
#!/bin/sh
case "\$1" in
  -s) echo "$2" ;;
  -m) echo "$3" ;;
  *) echo "$2" ;;
esac
EOF
  chmod +x "$dir/uname"
}

for row in "Linux aarch64 aarch64-linux-musl.tar.xz" "Darwin arm64 aarch64-macos.zip"; do
  # shellcheck disable=SC2086 # splitting the row into three fields is the point
  set -- $row
  dir="$WORK/path-$1-$2"
  make_path "$dir"
  stub_uname "$dir" "$1" "$2"
  run_expect_fail "aarch64 target selected ($1/$2)" "download failed: file://$WORK/nowhere/v0.0.0/$3" "$dir"
done

dir="$WORK/path-windows"
make_path "$dir"
stub_uname "$dir" "Windows_NT" "x86_64"
run_expect_fail "Windows refused" "Windows is not supported yet" "$dir"

dir="$WORK/path-solaris"
make_path "$dir"
stub_uname "$dir" "SunOS" "x86_64"
run_expect_fail "unknown OS refused" "unsupported OS 'SunOS'" "$dir"

dir="$WORK/path-riscv"
make_path "$dir"
stub_uname "$dir" "Linux" "riscv64"
run_expect_fail "unknown architecture refused" "unsupported architecture 'riscv64'" "$dir"

# --- missing tools -----------------------------------------------------------
# Each names the tool it is missing. A generic "a dependency is missing" would
# leave the reader to guess which of six it is.
for tool in curl tar; do
  dir="$WORK/path-no-$tool"
  make_path "$dir" "$tool"
  run_expect_fail "missing $tool is named" "'$tool' is required" "$dir"
done

if [ "$(uname -s)" = "Linux" ]; then
  # .tar.xz is the Linux payload format, and GNU tar shells out to `xz` for it.
  dir="$WORK/path-no-xz"
  make_path "$dir" xz
  run_expect_fail "missing xz is named" "'xz' is required" "$dir"
fi

# `unzip` on a host that has no bun. The Linux payload is a .tar.xz, so unzip is
# not needed for the install itself — but Bun's release assets are zips on every
# platform, and TOOLS deliberately omits bun, so every case in this file stands on
# a host with none.
#
# This used to be a WARNING and a completed install: the launcher was written, the
# run reported success, and the first island build failed naming bun. An installer
# whose advertised outcome is "complete" must not have a silent degraded mode, so
# the check moved into the preflight. (On macOS the same message comes from the
# unconditional check, since the release asset itself is a zip.)
dir="$WORK/path-no-unzip"
make_path "$dir" unzip
run_expect_fail "missing unzip is named when bun must be installed" "'unzip' is required" "$dir"

# ...and NOT when the user has opted out of the bun install, because then nothing
# on Linux needs unzip at all. Refusing there would be a check that costs a user
# an install for a tool it never uses. This case must get PAST the preflight and
# fail later, at the (nonexistent) fixture download.
if [ "$(uname -s)" = "Linux" ]; then
  dir="$WORK/path-no-unzip-nobun"
  make_path "$dir" unzip
  set +e
  env -i PATH="$dir" HOME="$WORK/home" \
    "$dir/sh" "$INSTALL" --version v0.0.0 --base-url "file://$WORK/nowhere" --no-bun \
    > "$WORK/nobun.log" 2>&1
  set -e
  if grep -qF "'unzip' is required" "$WORK/nobun.log"; then
    cat "$WORK/nobun.log"
    fail "--no-bun still demanded unzip on Linux, where nothing needs it"
  fi
  grep -qF "download failed" "$WORK/nobun.log" \
    || { cat "$WORK/nobun.log"; fail "--no-bun run did not reach the download step"; }
  echo "PASS --no-bun does not demand unzip on Linux"
fi

# All three digest tools gone: the install must stop rather than proceed
# unverified. This is the single most important refusal in the script.
dir="$WORK/path-no-sha"
make_path "$dir" sha256sum shasum openssl
run_expect_fail "no digest tool refuses to install" "no SHA-256 tool found" "$dir"

# --- arguments ---------------------------------------------------------------
set +e
sh "$INSTALL" --frobnicate > "$WORK/badflag.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { cat "$WORK/badflag.log"; fail "an unknown flag was accepted"; }
grep -q "unknown option '--frobnicate'" "$WORK/badflag.log" \
  || { cat "$WORK/badflag.log"; fail "the unknown flag was not named"; }
echo "PASS unknown flag is rejected by name"

# A flag that takes a value and was given none must not silently consume the next
# flag, or `--version --no-bun` would install a release called "--no-bun".
set +e
sh "$INSTALL" --version > "$WORK/noval.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { cat "$WORK/noval.log"; fail "--version with no argument was accepted"; }
echo "PASS --version with no argument is rejected"

sh "$INSTALL" --help > "$WORK/help.log" 2>&1 || fail "--help exited non-zero"
grep -q -- "--no-zigbase" "$WORK/help.log" || fail "--help does not document --no-zigbase"
echo "PASS --help works and documents the flags"

echo "PASS tests/install/refusals.sh"
