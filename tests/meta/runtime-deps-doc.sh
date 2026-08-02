#!/usr/bin/env bash
# docs/runtime-dependencies.md says what the standalone binary needs at run
# time. This gate checks that page against the sources every claim came from.
#
# WHY THIS EXISTS. A "what does this need installed" page is the single most
# drift-prone document a tool can have: nothing in a normal change breaks it,
# and nothing in a normal review looks at it, so it rots quietly and is then
# read as authoritative by exactly the person least able to notice — someone
# setting the tool up for the first time. Every fact on that page therefore
# either lives in a source file this reads, or is not on the page.
#
# WHAT IT CHECKS, and what each one is defending:
#
#   1. The command table is EXACTLY the binary's command set. A new subcommand
#      that needs Bun and is not on the table is the exact failure this whole
#      page exists to prevent, and a table row for a command that was deleted
#      is the same lie in the other direction. Both fail here.
#   2. The pinned ZigBase version and its cache path match src/cli/zigbase.zig.
#      The path is quoted so a user can drop a binary into it by hand; a stale
#      version segment sends them to a directory nothing reads.
#   3. The environment variable naming the runtime tree matches
#      src/cli/release.zig. Renaming it and leaving the page is a doc that
#      cannot work.
#   4. `@z/runtime` is still private and unpublished. The page tells the reader
#      they cannot npm-install it; if that ever stops being true, the advice
#      that replaces it ("get the tree from a checkout or @zigapagos/cli") is
#      wrong and someone has to rewrite the section.
#   5. The release archives still carry the binary alone. The page's
#      distribution table says an archive ships no runtime tree, which is the
#      one row a reader acts on before discovering otherwise.
#   6. Every CLI flag the page names still exists. A page naming a flag the
#      binary rejects is worse than silence.
#   7. The installer column of the distribution table is not fiction. The page
#      now tells a reader that `install.sh` supplies the runtime tree, Bun and
#      ZigBase; if the script or the asset it unpacks stops existing, that is a
#      column instructing someone to run a command that cannot work.
#
# Pure grep/awk over tracked text: no toolchain, no build, no network,
# sub-second. Picked up by CI's `tests/*/*.sh` glob like everything else here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

DOC=docs/runtime-dependencies.md
MAIN=src/main.zig
ZIGBASE=src/cli/zigbase.zig
RELEASE=src/cli/release.zig
PKG=runtime/package.json
ARCHIVE=build/release.zig

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

for f in "$DOC" "$MAIN" "$ZIGBASE" "$RELEASE" "$PKG" "$ARCHIVE"; do
  [ -f "$f" ] || { echo "FAIL: missing $f — the layout changed and this gate is now checking nothing" >&2; exit 1; }
done

# ── 1. The command table is the command set ─────────────────────────────────
# From `const Command = enum { … };` in src/main.zig. The four flag spellings
# (-h/--help/-v/--version) are dropped: they are documented in prose on the
# `help` and `version` rows, not as rows of their own, because a table row per
# spelling would say four times that a flag needs nothing installed.
mapfile -t COMMANDS < <(
  awk '/^const Command = enum \{/ { f = 1; next }
       f && /^\};/                { exit }
       f                          { print }' "$MAIN" |
  sed -e 's/[[:space:],]//g' -e 's/^@"//' -e 's/"$//' |
  grep -vE '^-' | grep -v '^$' | LC_ALL=C sort
)
[ "${#COMMANDS[@]}" -gt 0 ] || bad "parsed no commands out of $MAIN — the enum's spelling changed"

# From the page: rows whose first cell is `zigapagos <command>`.
mapfile -t DOCUMENTED < <(
  grep -oE '^\| `zigapagos [a-z0-9-]+`' "$DOC" |
  sed -e 's/^| `zigapagos //' -e 's/`$//' | LC_ALL=C sort
)
[ "${#DOCUMENTED[@]}" -gt 0 ] || bad "found no command rows in $DOC — the table's shape changed"

if [ "${#COMMANDS[@]}" -gt 0 ] && [ "${#DOCUMENTED[@]}" -gt 0 ]; then
  missing=$(comm -23 <(printf '%s\n' "${COMMANDS[@]}") <(printf '%s\n' "${DOCUMENTED[@]}"))
  extra=$(comm -13 <(printf '%s\n' "${COMMANDS[@]}") <(printf '%s\n' "${DOCUMENTED[@]}"))
  [ -z "$missing" ] || bad "$DOC has no row for: $(echo $missing) — say what each needs installed"
  [ -z "$extra" ] || bad "$DOC documents commands the binary does not have: $(echo $extra)"
fi

# ── 2. The pinned ZigBase version, and its cache path ───────────────────────
PIN=$(sed -n 's/^pub const pinned_version = "\([^"]*\)";$/\1/p' "$ZIGBASE")
[ -n "$PIN" ] || bad "could not read pinned_version from $ZIGBASE"

if [ -n "$PIN" ]; then
  grep -qF -- "$PIN" "$DOC" || bad "$DOC never names the pinned zigbase version ($PIN)"
  # Every vX.Y.Z on the page must BE the pin. Checking only that the pin appears
  # would pass a page that names the new pin in one paragraph and the old one in
  # the next, which is the shape a half-done bump actually takes.
  while IFS= read -r v; do
    [ "$v" = "$PIN" ] || bad "$DOC names version '$v', but the pin is '$PIN'"
  done < <(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$DOC" | sort -u)
  # The bare (v-less) spelling too: `@zigbase/server@0.12.0` in prose.
  while IFS= read -r v; do
    [ "$v" = "${PIN#v}" ] || bad "$DOC names @zigbase/server@$v, but the pin is ${PIN#v}"
  done < <(grep -oE '@zigbase/server@[0-9][^ `)]*' "$DOC" | sed 's/^@zigbase\/server@//' | sort -u)

  # The cache path the page tells a user they may drop a binary into. Matched
  # against cachedPath's join list AS A SEQUENCE — checking the segments
  # individually would pass a reordering, and `exe_name`'s own `"zigbase"`
  # literal would vouch for a path that no longer contains that directory.
  # Whitespace is flattened first so a `zig fmt` reflow of the argument list
  # (one element per line is a shape it produces) is not a failure.
  if ! tr -s '[:space:]' ' ' < "$ZIGBASE" |
       grep -qF -- '"zigapagos", "zigbase", pinned_version, exe_name'; then
    bad "$ZIGBASE no longer joins <cache>/zigapagos/zigbase/<pin>/<exe> in that order"
  fi
  grep -qF -- "zigapagos/zigbase/$PIN/zigbase" "$DOC" ||
    bad "$DOC does not quote the cache path 'zigapagos/zigbase/$PIN/zigbase'"
fi

# ── 3. The runtime-tree environment variable ────────────────────────────────
ENVVAR=$(sed -n 's/^pub const runtime_dir_env = "\([^"]*\)";$/\1/p' "$RELEASE")
[ -n "$ENVVAR" ] || bad "could not read runtime_dir_env from $RELEASE"
[ -z "$ENVVAR" ] || grep -qF -- "$ENVVAR" "$DOC" || bad "$DOC never names the runtime-tree variable ($ENVVAR)"

# ── 4. @z/runtime is still private and unpublished ──────────────────────────
# The page states this as the reason "install bun from npm" is not sufficient
# advice. If the package is ever published, that whole section is wrong.
grep -qE '"name"[[:space:]]*:[[:space:]]*"@z/runtime"' "$PKG" ||
  bad "$PKG no longer declares the name @z/runtime — $DOC's runtime-tree section assumes it"
grep -qE '"private"[[:space:]]*:[[:space:]]*true' "$PKG" ||
  bad "$PKG is no longer private:true — $DOC says @z/runtime cannot be installed from npm"

# ── 5. A release archive carries the binary alone ───────────────────────────
grep -qF 'tar.addArg("zigapagos")' "$ARCHIVE" || bad "$ARCHIVE no longer tars the bare binary — recheck $DOC's distribution table"
grep -qF 'zip.addDirectoryArg(' "$ARCHIVE" || bad "$ARCHIVE no longer zips the emitted binary — recheck $DOC's distribution table"
if hits=$(grep -nE '(addArg|addDirectoryArg|addFileArg).*runtime' "$ARCHIVE"); then
  bad "$ARCHIVE adds a runtime tree to an archive, but $DOC says an archive ships the binary alone:"
  printf '%s\n' "$hits" | sed 's/^/      /' >&2
fi

# ── 6. Every flag the page names still exists ───────────────────────────────
# Each row is `<flag>` `<file it is parsed in>`. The page tells a reader to type
# these; a flag the binary rejects is a worse doc than no doc.
while read -r flag file; do
  [ -n "$flag" ] || continue
  grep -qF -- "$flag" "$DOC" || bad "$DOC no longer mentions $flag — drop this row if that is deliberate"
  grep -qF -- "\"$flag" "$file" || bad "$file no longer parses $flag, but $DOC tells the reader to pass it"
done <<'FLAGS'
--bun= src/cli/release.zig
--css-minify-driver= src/cli/release.zig
--island-props-check= src/cli/release.zig
--island-sidecar= src/cli/release.zig
--island-src-dir= src/cli/release.zig
--zigbase= src/cli/dev.zig
--no-download src/cli/dev.zig
--download-zigbase src/cli/e2e.zig
FLAGS

# ── 7. The installer column describes something that exists ─────────────────
# The page's distribution table is the part a reader ACTS on, and its newest
# column tells them one command gets them everything. Three things have to be
# true for that: the script exists, it is what the page tells them to run, and
# the payload it needs is published. tests/install/pins.sh checks the script's
# own constants; this checks the page against the script.
INSTALLER=install.sh
if [ ! -f "$INSTALLER" ]; then
  bad "$INSTALLER is gone, but $DOC's distribution table has an install.sh column"
else
  grep -qF 'install.sh | sh' "$DOC" ||
    bad "$DOC no longer shows the curl|sh command — drop the install.sh column if that is deliberate"
  grep -qF 'runtime.tar.xz' "$INSTALLER" ||
    bad "$INSTALLER no longer fetches runtime.tar.xz, but $DOC says it supplies the runtime tree"
  grep -qF 'runtime.tar.xz' "$DOC" ||
    bad "$DOC stopped naming the runtime.tar.xz asset the archive row points a reader at"
  # The two flags the page promises. A reader on an air-gapped box or with their
  # own toolchain is told these exist.
  for flag in --no-bun --no-zigbase; do
    grep -qF -- "$flag" "$DOC" || bad "$DOC no longer mentions $flag"
    grep -qF -- "$flag)" "$INSTALLER" || bad "$INSTALLER no longer parses $flag, but $DOC names it"
  done
fi

[ "$fail" -eq 0 ] || exit 1
echo "PASS: ${#DOCUMENTED[@]} commands documented, zigbase pin $PIN, $ENVVAR"
