#!/usr/bin/env bash
# End-to-end test of the npm distribution: generate the package tree, `npm pack`
# it, INSTALL the tarballs into throwaway projects, and run the `zigapagos`
# command through those installs — through both `@zigapagos/cli` and the bare
# `zigapagos` alias.
#
# WHY AN INSTALL AND NOT JUST A GENERATOR TEST. Everything this channel can get
# wrong lives between `npm pack` and the moment the command runs: a `files` list
# that omits targets.json, an `exports` map that makes the alias's deep require
# unresolvable, a binary that loses its exec bit, an optionalDependency npm
# declines to install, a bin name that resolves to the wrong package. A generator
# whose output was never installed proves none of that. npm/gen-packages.test.mjs
# (run first, below) pins the manifest SHAPE; this pins the behaviour.
#
# TWO BINARIES ARE USED, on purpose:
#
#   a stub  — a 4-line shell script that echoes its argv and exits with $STUB_EXIT.
#             The real generator cannot be asked to exit 7, and cannot report the
#             argv it received; the stub can, so argv passthrough and exit-code
#             propagation are pinned exactly.
#   the real zigapagos — packed, installed and run for real, because a stub cannot
#             show that a 400MB native binary survives `npm pack`, install and
#             exec. `zigapagos version` must print this repo's version, and an
#             unknown subcommand must still exit non-zero through the launcher.
#
# Requires `node` (>= 18) and `npm` on PATH. Deliberately NOT added to mise.toml:
# node is not a zigapagos build dependency, it is the runtime of this one
# distribution channel, and every GitHub runner and every npm user already has it.
# No registry access is needed or allowed — every install below is `--offline`
# over `file:` tarballs.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
# ZIGAPAGOS_BIN is the repo's existing "use this prebuilt binary" convention (ci.yml
# sets it from the build-binary artifact). The release workflow additionally points it
# at the binary extracted from the real release archive, so this same script exercises
# the ReleaseFast bytes that are about to be published.
ZIGAPAGOS="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"

fail() { echo "FAIL: $*"; exit 1; }

command -v node >/dev/null || fail "node is not on PATH (needed to run the npm launcher)"
command -v npm >/dev/null || fail "npm is not on PATH (needed to pack and install the packages)"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || fail "zig build failed"
fi

VERSION="$(scripts/assert-version.sh --print)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 0. Manifest unit tests -------------------------------------------------
echo "== npm/gen-packages.test.mjs =="
node --test npm/gen-packages.test.mjs || fail "generator unit tests failed"

# --- 1. A copy of npm/ to generate into -------------------------------------
# Never generate into the real npm/ tree: this script would then leave 400MB of
# binary and a pile of gitignored manifests in the working copy. `git ls-files`
# with --others --exclude-standard copies the COMMITTED and the not-yet-committed
# files while skipping exactly the generated ones (they are gitignored), so this
# tests the working tree rather than HEAD.
PKG="$WORK/pkg"
mkdir -p "$PKG"
cp build.zig.zon mise.toml "$PKG/"
# publish.mjs stages runtime/ into the CLI package and derives every dependency
# range from runtime/package.json, src/cli/zigbase.zig and mise.toml, so the copy
# needs those too — not just npm/. Tracked files only (`git ls-files`), which is
# what keeps runtime/node_modules out of a 4-file test fixture.
git ls-files --cached --others --exclude-standard -- npm runtime src/cli/zigbase.zig \
  | while IFS= read -r f; do
  mkdir -p "$PKG/$(dirname "$f")"
  cp "$f" "$PKG/$f"
done
[[ -f "$PKG/npm/cli/index.js" ]] || fail "the npm/ copy is missing cli/index.js"
[[ -f "$PKG/runtime/sidecar/standalone.ts" ]] || fail "the runtime/ copy is missing the sidecar"

node "$PKG/npm/gen-packages.mjs" >/dev/null || fail "gen-packages.mjs failed"

# --- 1b. The dependency drift gate ------------------------------------------
# Same placement as the release workflow's: before anything is packed. A range
# that disagrees with pinned_version ships a zigapagos whose `dev` runs one
# zigbase over npm and downloads another on a PATH miss.
node "$PKG/npm/check-toolchain.mjs" --root "$PKG" >/dev/null \
  || fail "npm/check-toolchain.mjs rejected the generated tree"
echo "ok: dependency ranges agree with runtime/package.json, zigbase.zig and mise.toml"

# The package directory for THIS host. Computed through the resolver rather than
# assumed, so a host outside the release matrix skips below instead of failing on
# a package that was never built.
if ! KEY="$(node -e 'process.stdout.write(require(process.argv[1]).resolveTarget().key)' \
      "$PKG/npm/cli/index.js" 2>/dev/null)"; then
  echo "SKIP: $(node -p 'process.platform + "-" + process.arch') has no release target," \
       "so the packages cannot be installed here. (CI runs this on linux-x64.)"
  exit 0
fi
echo "host maps to @zigapagos/cli-$KEY"

# --- 2. Stub binaries, then assemble + pack ---------------------------------
write_stub() {
  cat > "$1" <<'STUB'
#!/bin/sh
# Test stub standing in for the zigapagos binary: report argv exactly, exit with
# whatever the caller asked for.
echo "stub argc=$#"
for a in "$@"; do echo "stub arg:[$a]"; done
# The launcher's whole contribution to the child is its environment, so report the
# two things it is supposed to add. Only on request: the argv assertions below
# compare the output verbatim.
if [ -n "${STUB_SHOW_ENV:-}" ]; then
  echo "stub env:ZIGAPAGOS_RUNTIME_DIR=[${ZIGAPAGOS_RUNTIME_DIR:-}]"
  echo "stub env:PATH=[${PATH}]"
fi
exit "${STUB_EXIT:-0}"
STUB
  chmod 755 "$1"
}
for dir in "$PKG"/npm/cli-*/; do write_stub "$dir/zigapagos"; done

# --- 2b. Stand-ins for the real npm dependencies ---------------------------
# @zigapagos/cli now declares four real dependencies: preact and
# preact-render-to-string (required — the shipped runtime/src imports them), plus
# bun and @zigbase/server (optional — the two binaries the CLI shells out to).
# None of them can come from the registry here, because every install below is
# `--offline` and must stay that way: this script has to pass on a runner with no
# network and must never let a registry outage look like a packaging defect.
#
# So each is stubbed by a minimal local package of the same name, wired in through
# the same `overrides` mechanism that already redirects our own three packages.
# What that costs is real — none of these stubs can SSR anything — and what it
# buys is the property this script is actually for: that the manifest declares
# them, that npm therefore resolves and links them, and that the launcher puts
# their bin directory where the binary will look. The end-to-end proof that a real
# preact and a real bun render an island belongs to a networked install, not here.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
stub_pkg() {
  local name="$1" version="$2" binname="${3:-}"
  local dir="$STUBS/$(printf '%s' "$name" | tr '/@' '__')"
  mkdir -p "$dir"
  node -e '
    const fs = require("node:fs");
    const [dir, name, version, binname] = process.argv.slice(1);
    const pkg = { name, version, main: "index.js" };
    if (binname) pkg.bin = { [binname]: "bin.js" };
    fs.writeFileSync(dir + "/package.json", JSON.stringify(pkg, null, 2) + "\n");
    fs.writeFileSync(dir + "/index.js", "module.exports = {};\n");
    if (binname) {
      fs.writeFileSync(dir + "/bin.js", "#!/usr/bin/env node\nconsole.log(\"" + binname + " stub\");\n");
    }
  ' "$dir" "$name" "$version" "$binname"
  ( cd "$dir" && npm pack --pack-destination "$TARBALLS" >/dev/null 2>&1 ) \
    || fail "could not pack the $name stub"
}

TARBALLS="$WORK/tarballs"
out="$(node "$PKG/npm/publish.mjs" --pack "$TARBALLS" 2>&1)" \
  || { printf '%s\n' "$out"; fail "publish.mjs --pack failed"; }
printf '%s\n' "$out" | grep -q "verified: versions pinned" \
  || { printf '%s\n' "$out"; fail "publish.mjs did not report a verified tree"; }
printf '%s\n' "$out" | grep -q "nothing was uploaded\|packed" \
  || { printf '%s\n' "$out"; fail "publish.mjs --pack said nothing about packing"; }

CLI_TGZ="$TARBALLS/zigapagos-cli-$VERSION.tgz"
PLAT_TGZ="$TARBALLS/zigapagos-cli-$KEY-$VERSION.tgz"
ALIAS_TGZ="$TARBALLS/zigapagos-$VERSION.tgz"
for t in "$CLI_TGZ" "$PLAT_TGZ" "$ALIAS_TGZ"; do
  [[ -f "$t" ]] || fail "expected tarball $t was not produced"
done
echo "ok: packed @zigapagos/cli, @zigapagos/cli-$KEY and the zigapagos alias"

# The runtime tree has to be INSIDE the tarball, not merely staged next to it: a
# `files` list that forgot it produces a package that installs cleanly and then
# fails at the sidecar spawn in a consumer's first island build.
# The listing is taken ONCE into a variable rather than re-piped per file. Under
# `set -o pipefail`, `tar -tzf ... | grep -q X` fails the whole pipeline whenever
# grep matches early enough to exit first: tar then dies of SIGPIPE and pipefail
# reports ITS status, so a present file reads as absent. That is a wrong answer
# rather than an error, which is the shell trap this repo's CLAUDE.md calls out.
cli_files="$(tar -tzf "$CLI_TGZ")"
for f in package/runtime/sidecar/standalone.ts \
         package/runtime/sidecar/bundle-island.ts \
         package/runtime/sidecar/bundle-standalone.ts \
         package/runtime/scripts/build-spa-runtime.ts \
         package/runtime/src/browser-entry.ts \
         package/runtime/src/spa-entry.ts \
         package/runtime/package.json; do
  printf '%s\n' "$cli_files" | grep -qx "$f" \
    || fail "$f is not inside the @zigapagos/cli tarball"
done
# ...and the bun-test suite is NOT, since its fixtures import react, @acme/greeting
# and my-store — bare specifiers nothing we ship depends on.
if printf '%s\n' "$cli_files" | grep -q '\.test\.ts$'; then
  fail "the @zigapagos/cli tarball carries *.test.ts files"
fi
echo "ok: the tarball carries the sidecar and @z/runtime sources, and no tests"

# The four real dependencies, stubbed so every install below stays --offline.
mkdir -p "$TARBALLS"
DEP_TGZ=()
DEP_PAIRS=()
stub_from_manifest() {
  # Names and versions come from the GENERATED manifest, so this cannot drift from
  # whatever gen-packages.mjs derived — a dependency added later is stubbed
  # automatically instead of failing the install with a registry lookup.
  local spec
  while IFS= read -r spec; do
    local name="${spec%@*}" version="${spec##*@}"
    local binname=""
    case "$name" in
      bun) binname="bun" ;;
      @zigbase/server) binname="zigbase" ;;
    esac
    stub_pkg "$name" "$version" "$binname"
    local tgz="$TARBALLS/$(printf '%s' "$name" | sed 's|^@||; s|/|-|')-$version.tgz"
    DEP_TGZ+=("$tgz")
    DEP_PAIRS+=("$name=$tgz")
  done < <(node -e '
    const pkg = require(process.argv[1] + "/npm/cli/package.json");
    const all = { ...(pkg.dependencies ?? {}), ...(pkg.optionalDependencies ?? {}) };
    for (const [n, v] of Object.entries(all)) {
      if (n.startsWith("@zigapagos/")) continue;   // our own platform packages
      // A caret/tilde range cannot BE a version; use its lower bound, padded to
      // a full semver triple (`^1.2` -> `1.2.0`) because npm rejects `1.2` as a
      // package version outright.
      const parts = v.replace(/^[\^~>=<\s]*/, "").split(".");
      while (parts.length < 3) parts.push("0");
      console.log(n + "@" + parts.join("."));
    }
  ' "$PKG")
}
stub_from_manifest
[[ "${#DEP_TGZ[@]}" -ge 4 ]] \
  || fail "expected at least 4 stubbed dependencies, got ${#DEP_TGZ[@]}"
for t in "${DEP_TGZ[@]}"; do
  [[ -f "$t" ]] || fail "dependency stub $t was not packed"
done
echo "ok: stubbed ${#DEP_TGZ[@]} declared dependencies for offline installs"

# The verify step must refuse a tree with a binary missing — otherwise a release
# publishes a platform package whose only reason to exist is absent.
rm "$PKG/npm/cli-$KEY/zigapagos"
if out="$(node "$PKG/npm/publish.mjs" 2>&1)"; then
  printf '%s\n' "$out"
  fail "publish.mjs accepted a tree with a missing platform binary"
fi
printf '%s\n' "$out" | grep -q "cli-$KEY/zigapagos is missing" \
  || { printf '%s\n' "$out"; fail "publish.mjs did not name the missing binary"; }
echo "ok: publish.mjs rejects a tree with a missing platform binary"
write_stub "$PKG/npm/cli-$KEY/zigapagos"

# --- 3. Install helpers ------------------------------------------------------
# `overrides` is what keeps this hermetic: without it npm resolves
# @zigapagos/cli's optionalDependency from the registry (a 404 for an unpublished
# version, which npm then IGNORES because it is optional — leaving an install
# that resolves and cannot run). Pointing the override at the local tarball means
# --offline succeeds and the platform package under test is the one just packed.
install_project() {
  local dir="$1"; shift
  mkdir -p "$dir"
  node -e '
    const fs = require("node:fs");
    const { basename } = require("node:path");
    const [dir, version, ...rest] = process.argv.slice(1);
    // Our own three packages are named from their `-<version>.tgz` suffix; the
    // stubbed dependencies carry their own versions, so they arrive already
    // labelled as `name=path` after a `--` separator.
    const sep = rest.indexOf("--");
    const tgz = sep < 0 ? rest : rest.slice(0, sep);
    const pairs = sep < 0 ? [] : rest.slice(sep + 1);
    // zigapagos-cli-linux-x64-<v>.tgz -> @zigapagos/cli-linux-x64
    // zigapagos-<v>.tgz               -> zigapagos
    const suffix = `-${version}.tgz`;
    const nameOf = (t) => {
      const b = basename(t);
      if (!b.endsWith(suffix)) throw new Error(`unexpected tarball name: ${b}`);
      const stem = b.slice(0, -suffix.length);
      return stem === "zigapagos" ? "zigapagos" : stem.replace(/^zigapagos-/, "@zigapagos/");
    };
    const spec = Object.fromEntries(tgz.map((t) => [nameOf(t), "file:" + t]));
    for (const p of pairs) {
      const i = p.indexOf("=");
      spec[p.slice(0, i)] = "file:" + p.slice(i + 1);
    }
    fs.writeFileSync(
      dir + "/package.json",
      JSON.stringify(
        { name: "zigapagos-npm-smoke", version: "0.0.0", private: true,
          dependencies: spec, overrides: spec },
        null, 2,
      ) + "\n",
    );
  ' "$dir" "$VERSION" "$@" -- "${DEP_PAIRS[@]}"
  ( cd "$dir" && npm install --no-audit --no-fund --offline >/dev/null 2>&1 ) \
    || fail "npm install failed in $dir"
}

# Asserts a command's exit status and that its output holds a needle.
expect_run() {
  local name="$1" want_rc="$2" needle="$3"; shift 3
  local rc=0 got
  got="$("$@" 2>&1)" || rc=$?
  if [[ "$rc" != "$want_rc" ]]; then
    printf '%s\n' "$got" | sed 's/^/    /'
    fail "$name — expected exit $want_rc, got $rc"
  fi
  if [[ -n "$needle" ]] && ! printf '%s\n' "$got" | grep -qF "$needle"; then
    printf '%s\n' "$got" | sed 's/^/    /'
    fail "$name — output does not contain '$needle'"
  fi
  echo "ok: $name"
}

# --- 4. @zigapagos/cli, installed ------------------------------------------
CLI_PROJ="$WORK/proj-cli"
install_project "$CLI_PROJ" "$CLI_TGZ" "$PLAT_TGZ"
[[ -x "$CLI_PROJ/node_modules/.bin/zigapagos" ]] \
  || fail "npm did not link node_modules/.bin/zigapagos for @zigapagos/cli"

# Argv passthrough, exactly: five arguments including one with a space and a bare
# `--`, which is where a shim that re-splits or re-quotes its input shows up.
argv_out="$("$CLI_PROJ/node_modules/.bin/zigapagos" build --port 1990 "two words" -- --after 2>&1)"
expected="stub argc=6
stub arg:[build]
stub arg:[--port]
stub arg:[1990]
stub arg:[two words]
stub arg:[--]
stub arg:[--after]"
[[ "$argv_out" == "$expected" ]] || {
  echo "--- got ---"; printf '%s\n' "$argv_out"
  echo "--- want ---"; printf '%s\n' "$expected"
  fail "argv was not passed through unchanged"
}
echo "ok: argv passes through the launcher unchanged"

STUB_EXIT=7 expect_run "the child's exit code 7 is propagated" 7 "" \
  "$CLI_PROJ/node_modules/.bin/zigapagos"
STUB_EXIT=0 expect_run "exit 0 is propagated" 0 "stub argc=0" \
  "$CLI_PROJ/node_modules/.bin/zigapagos"

# --- 4b. What the launcher adds to the child's environment ------------------
# These two are the entire mechanism by which an npm install builds islands and
# runs `dev`, and neither is visible from the manifest: the binary has to be TOLD
# where the bundled runtime is, and the tools npm just installed have to be
# reachable from wherever zigapagos was invoked.
env_out="$(STUB_SHOW_ENV=1 "$CLI_PROJ/node_modules/.bin/zigapagos" 2>&1)"

# The sidecar path the binary resolves ZIGAPAGOS_RUNTIME_DIR into must exist —
# pointing at a directory that is not there would be worse than not setting it,
# because the failure would name a file the user never asked for.
rt_dir="$(printf '%s\n' "$env_out" | sed -n 's/^stub env:ZIGAPAGOS_RUNTIME_DIR=\[\(.*\)\]$/\1/p')"
[[ -n "$rt_dir" ]] || { printf '%s\n' "$env_out"; fail "the launcher did not set ZIGAPAGOS_RUNTIME_DIR"; }
[[ -f "$rt_dir/sidecar/standalone.ts" ]] \
  || fail "ZIGAPAGOS_RUNTIME_DIR=$rt_dir does not contain sidecar/standalone.ts"
[[ -f "$rt_dir/src/browser-entry.ts" ]] \
  || fail "ZIGAPAGOS_RUNTIME_DIR=$rt_dir does not contain src/browser-entry.ts"
echo "ok: the launcher points ZIGAPAGOS_RUNTIME_DIR at the installed sidecar"

# The dependency bin directory, so `bun` and `zigbase` resolve for a bare
# `zigapagos dev` and for `npm i -g`, not only under `npm run`/`npx`.
child_path="$(printf '%s\n' "$env_out" | sed -n 's/^stub env:PATH=\[\(.*\)\]$/\1/p')"
case ":$child_path:" in
  *":$CLI_PROJ/node_modules/.bin:"*) ;;
  *) printf '%s\n' "$env_out"; fail "the launcher did not add node_modules/.bin to the child PATH" ;;
esac
[[ -x "$CLI_PROJ/node_modules/.bin/zigbase" ]] \
  || fail "the @zigbase/server dependency did not link a zigbase bin"
[[ -x "$CLI_PROJ/node_modules/.bin/bun" ]] \
  || fail "the bun dependency did not link a bun bin"
echo "ok: bun and zigbase are installed, linked, and on the child's PATH"

# APPENDED, not prepended: a zigbase or bun the user put on PATH deliberately has
# to keep winning, and the zigbase locator reports whichever it finds first.
first_path_entry="${child_path%%:*}"
[[ "$first_path_entry" != "$CLI_PROJ/node_modules/.bin" ]] \
  || fail "the launcher PREPENDED its bin dir, which would shadow the user's own tools"
echo "ok: the launcher appends its bin dir rather than shadowing the user's PATH"

# targets.json must be inside the published tarball: index.js requires it.
CLI_MOD="$CLI_PROJ/node_modules/@zigapagos/cli"
[[ -f "$CLI_MOD/targets.json" ]] \
  || fail "targets.json is not in the published @zigapagos/cli files"

# binaryPath() is the documented programmatic entry point. Required by absolute
# path rather than by name from a cwd: node resolves the platform package from the
# location of the module that asks, so this is the same lookup a consumer gets.
expect_run "binaryPath() resolves into the platform package" 0 \
  "@zigapagos/cli-$KEY/zigapagos" \
  node -e 'console.log(require(process.argv[1]).binaryPath())' "$CLI_MOD"

# --- 5. The bare `zigapagos` alias, installed ------------------------------
ALIAS_PROJ="$WORK/proj-alias"
install_project "$ALIAS_PROJ" "$ALIAS_TGZ" "$CLI_TGZ" "$PLAT_TGZ"
[[ -f "$ALIAS_PROJ/node_modules/zigapagos/bin/zigapagos.js" ]] \
  || fail "the alias package did not install its launcher"

# The alias's OWN shim, invoked directly. This is the path `npx zigapagos` takes,
# and the reason it is called out: with both packages present npm links
# node_modules/.bin/zigapagos to @zigapagos/cli's bin (a bin-name collision it
# resolves in favour of the transitive package), so testing only `.bin` would
# never execute the alias's three lines at all.
alias_out="$(node "$ALIAS_PROJ/node_modules/zigapagos/bin/zigapagos.js" a "b c" 2>&1)"
[[ "$alias_out" == "stub argc=2
stub arg:[a]
stub arg:[b c]" ]] || { printf '%s\n' "$alias_out"; fail "the alias shim altered argv"; }
echo "ok: the alias shim hands off to @zigapagos/cli with argv intact"

STUB_EXIT=3 expect_run "the alias propagates the child's exit code" 3 "" \
  node "$ALIAS_PROJ/node_modules/zigapagos/bin/zigapagos.js"

# --- 6. Resolver failure paths ----------------------------------------------
# A missing optionalDependency is the `--omit=optional` install, and it must not
# be reported as an unsupported platform: the fix is completely different.
NOPLAT_PROJ="$WORK/proj-no-platform"
install_project "$NOPLAT_PROJ" "$CLI_TGZ"
expect_run "a missing platform package names the install flag" 1 \
  "reinstall without it" \
  node -e 'require(process.argv[1]).binaryPath()' \
  "$NOPLAT_PROJ/node_modules/@zigapagos/cli"

# ...and any OTHER resolve failure must survive as itself. An `exports` map on the
# platform package makes require.resolve throw ERR_PACKAGE_PATH_NOT_EXPORTED with the
# package plainly installed; reporting that as "not installed" would send the reader
# after a reinstall that cannot help. Mutating the installed copy is the only way to
# produce the condition, so this reaches into node_modules on purpose.
BADEXP_PROJ="$WORK/proj-bad-exports"
install_project "$BADEXP_PROJ" "$CLI_TGZ" "$PLAT_TGZ"
node -e '
  const fs = require("node:fs");
  const f = process.argv[1] + "/package.json";
  const pkg = JSON.parse(fs.readFileSync(f, "utf8"));
  pkg.exports = { ".": "./package.json" };
  fs.writeFileSync(f, JSON.stringify(pkg, null, 2));
' "$BADEXP_PROJ/node_modules/@zigapagos/cli-$KEY"
badexp="$(node -e 'try { require(process.argv[1]).binaryPath() } catch (e) {
    console.log(e.code + " :: " + e.message) }' \
  "$BADEXP_PROJ/node_modules/@zigapagos/cli" 2>&1)"
case "$badexp" in
  *"is not installed"*)
    printf '%s\n' "$badexp"
    fail "an exports-map resolve failure was reported as a missing package"
    ;;
  *ERR_PACKAGE_PATH_NOT_EXPORTED*) echo "ok: a non-MODULE_NOT_FOUND resolve error is rethrown as itself" ;;
  *)
    printf '%s\n' "$badexp"
    fail "expected ERR_PACKAGE_PATH_NOT_EXPORTED, got the above"
    ;;
esac

expect_run "an unsupported platform is reported as such" 1 \
  "unsupported platform 'sunos-x64'" \
  node -e 'Object.defineProperty(process,"platform",{value:"sunos"});
           Object.defineProperty(process,"arch",{value:"x64"});
           require(process.argv[1]).binaryPath()' "$CLI_MOD"

# --- 6b. Both arm64 hosts resolve to native packages -------------------------
# These packages are not installed in this x64 fixture, but resolution itself
# must name each native package rather than refusing it or substituting x64.
for host in linux darwin; do
  expect_run "$host-arm64 resolves to its native package" 0 \
    "@zigapagos/cli-$host-arm64" \
    node -e 'Object.defineProperty(process,"platform",{value:process.argv[2]});
             Object.defineProperty(process,"arch",{value:"arm64"});
             console.log(require(process.argv[1]).resolveTarget().pkg)' \
    "$CLI_MOD" "$host"
done

# `binaryPath()` should now report only that this deliberately host-only fixture
# did not install the otherwise-supported ARM package.
cat > "$WORK/as-darwin-arm64.js" <<'PRELOAD'
Object.defineProperty(process, "platform", { value: "darwin" });
Object.defineProperty(process, "arch", { value: "arm64" });
PRELOAD
arm_rc=0
arm_launch="$(node --require "$WORK/as-darwin-arm64.js" "$CLI_MOD/bin/zigapagos.js" 2>&1)" \
  || arm_rc=$?
[[ "$arm_rc" == 1 ]] || {
  printf '%s\n' "$arm_launch"
  fail "the launcher exited $arm_rc on darwin-arm64, expected 1"
}
printf '%s\n' "$arm_launch" | grep -qF "@zigapagos/cli-darwin-arm64' package is not installed" \
  || { printf '%s\n' "$arm_launch"; fail "the launcher did not request the native arm64 package"; }
echo "ok: the launcher requests the native darwin-arm64 package"

# The install-time half of the same refusal: npm reads `os`/`cpu` off the launcher
# packages, so a host outside the matrix gets EBADPLATFORM instead of an install
# that resolves and contains no binary. Asserted on the INSTALLED manifest — npm only enforces
# what is inside the published tarball. (The enforcement itself cannot be tested
# here: npm has no flag to pretend the host is another platform, and this runs on
# an x64 runner.)
node -e '
  const assert = require("node:assert/strict");
  const pkg = require(process.argv[1] + "/package.json");
  const plat = require(process.argv[1] + "/targets.json");
  assert.deepEqual(pkg.os, [...new Set(plat.map((t) => t.os))].sort(), "os");
  assert.deepEqual(pkg.cpu, [...new Set(plat.map((t) => t.cpu))].sort(), "cpu");
' "$CLI_MOD" || fail "the installed @zigapagos/cli does not restrict os/cpu to its real targets"
echo "ok: the installed @zigapagos/cli declares only the os/cpu it has binaries for"

# --- 7. The real binary, through a real install -----------------------------
# Same tarballs, but the platform package now carries the actual 400MB native
# binary rather than a stub.
cp "$ZIGAPAGOS" "$PKG/npm/cli-$KEY/zigapagos"
chmod 755 "$PKG/npm/cli-$KEY/zigapagos"
REAL_TARBALLS="$WORK/tarballs-real"
mkdir -p "$REAL_TARBALLS"
out="$(cd "$PKG/npm/cli-$KEY" && npm pack --pack-destination "$REAL_TARBALLS" 2>&1)" \
  || { printf '%s\n' "$out"; fail "npm pack of the real platform package failed"; }
REAL_PLAT_TGZ="$REAL_TARBALLS/zigapagos-cli-$KEY-$VERSION.tgz"
[[ -f "$REAL_PLAT_TGZ" ]] || fail "expected $REAL_PLAT_TGZ"

# `zigapagos version` prints the version the BINARY was stamped with — one line,
# `options.version` verbatim (src/main.zig's printVersion) — which
# build/config.zig derives from `git describe --match '*.*.*' --tags` AT BUILD
# TIME. Its `getVersion` can produce exactly three strings, and nothing else:
#
#   v<zon version>           `.tag` — describe landed ON a tag, so the tag is
#                            printed verbatim. Tags here are `v<semver>`:
#                            build/release.zig compares `version.tag[1..]` with
#                            the zon version and refuses to build a release when
#                            they disagree, so a release build says `v$VERSION`.
#   v<prev tag>-dev.<n>+<sha>  `.commit` — an untagged commit, assembled as
#                            `{ancestor}-dev.{height}+{sha}`. The ancestor is that
#                            same v-prefixed tag and contains no `-` (config.zig
#                            only takes this branch when describe's output holds
#                            exactly two of them); the height is describe's decimal
#                            commit count; the sha is its abbreviated hex id with
#                            the `g` stripped — config.zig PANICS if that `g` is
#                            absent, so it is never part of the string.
#   unknown                  no `git` on PATH, or `git describe` failed — a shallow
#                            checkout. ci.yml's build-binary job does not fetch
#                            tags, so the artifact this runs against in CI says
#                            `unknown` while the release workflow's says the real
#                            version.
#
# The second shape is not an edge case, it is every release pull request: the tag
# has to point at the commit that bumps build.zig.zon, so between the bump and the
# tag `git describe` necessarily still reports the PREVIOUS version. Matching only
# `v$VERSION*` made this assertion red for the whole life of every release PR — and
# release.yml runs tests/npm/** on pull requests, so it would have been discovered
# there every time.
#
# WHY A REGEX AND NOT A GLOB. Admitting the dev stamp as `v*-dev.*+*` also admitted
# `v-dev.+`, `v1-dev.x+` and a stamp whose sha is empty — an assertion that named a
# format it did not actually pin, right under a comment claiming it accepted "those
# three and nothing else". A reformat that dropped the sha, or a `git describe` that
# stopped abbreviating to hex, would have sailed through it.
#
# `{4,40}` rather than a fixed 7: git widens the abbreviation as the object count
# grows and `core.abbrev` can narrow it to 4, its own floor. The sha's LENGTH is not
# what is being pinned — that it is hex and non-empty is.
version_stamp_re='^v[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+\+[0-9a-f]{4,40}$'

# True for a string `zigapagos version` can legitimately print. What is being pinned
# is that the real native binary ran through the installed launcher and answered in
# one of build/config.zig's shapes — not which one, since that is a property of the
# checkout the binary was built from.
version_ok() {
  case "$1" in
    "$VERSION" | "v$VERSION" | unknown) return 0 ;;
  esac
  [[ "$1" =~ $version_stamp_re ]]
}

# The matcher's own self-test, because the defect it replaces was invisible from
# the outside: a pattern that accepts garbage passes this suite exactly as a
# correct one does, so only driving it with garbage can tell them apart. Every
# rejected string below was ACCEPTED by the `v*-dev.*+*` glob. Pure string
# matching, no process spawns — it costs nothing to run on every invocation.
for good in "$VERSION" "v$VERSION" unknown \
            "v0.1.1-dev.85+e1d7033" "v0.11.2-dev.0+0123456789abcdef0123"; do
  version_ok "$good" || fail "version_ok rejected the legitimate stamp '$good'"
done
for bad in "v-dev.+" "v1-dev.x+" "v0.1.1-dev.12+" "v0.1.1-dev.+e1d7033" \
           "v0.1.1-dev.12+zzzzzzz" "v0.1.1-dev.12+E1D7033" \
           "v0.1.1-dev.12+e1d7033-dirty" "0.1.1-dev.12+e1d7033" \
           "v$VERSION-rc.1" "Unknown" ""; do
  ! version_ok "$bad" || fail "version_ok accepted the malformed stamp '$bad'"
done
echo "ok: the version matcher takes every shape build/config.zig emits and no other"

expect_version() {
  local name="$1"; shift
  local rc=0 got last
  got="$("$@" 2>&1)" || rc=$?
  if [[ "$rc" != 0 ]]; then
    printf '%s\n' "$got" | sed 's/^/    /'
    fail "$name — expected exit 0, got $rc"
  fi
  last="$(printf '%s\n' "$got" | grep -v '^[[:space:]]*$' | tail -1)"
  if version_ok "$last"; then
    echo "ok: $name (reported '$last')"
  else
    printf '%s\n' "$got" | sed 's/^/    /'
    fail "$name — last line '$last' is none of '$VERSION', 'v$VERSION', a 'v<tag>-dev.<n>+<sha>' stamp, or 'unknown'"
  fi
}

REAL_PROJ="$WORK/proj-real"
install_project "$REAL_PROJ" "$CLI_TGZ" "$REAL_PLAT_TGZ"
expect_version "the real binary runs through the installed launcher" \
  "$REAL_PROJ/node_modules/.bin/zigapagos" version
# A real non-zero exit, not a stub's: this is the launcher forwarding the
# generator's own failure status.
expect_run "a real failing subcommand exits non-zero through the launcher" 1 "" \
  "$REAL_PROJ/node_modules/.bin/zigapagos" definitely-not-a-subcommand

REAL_ALIAS_PROJ="$WORK/proj-real-alias"
install_project "$REAL_ALIAS_PROJ" "$ALIAS_TGZ" "$CLI_TGZ" "$REAL_PLAT_TGZ"
expect_version "the real binary runs through the bare zigapagos alias" \
  node "$REAL_ALIAS_PROJ/node_modules/zigapagos/bin/zigapagos.js" version

echo "PASS: npm packaging e2e"
