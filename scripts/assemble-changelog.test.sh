#!/usr/bin/env bash
# Self-test for assemble-changelog.sh.
#
# Each case builds a throwaway "repo" in $TMPDIR — scripts/assemble-changelog.sh,
# build.zig.zon, CHANGELOG.md, changelog.d/ — and runs the real script against it, so
# nothing here reads or writes the repo's own CHANGELOG.md. The script `cd`s to its own
# parent's parent, which is what makes that isolation work.
#
# Case 12 is the load-bearing one. The emitted `## [x.y.z] - YYYY-MM-DD` heading is an
# interface with scripts/extract-release-notes.sh (a different file, owned by a different
# branch), which locates a section by matching `## [<version>]` at the start of a line and
# prints through to the next `## `. Drift there produces empty or run-on GitHub release
# notes rather than any error, so it needs pinning. Case 12 invokes the real extractor when
# the checkout has one and falls back to a minimal locator when it does not; either way it
# asserts only the properties both guarantee — see the comment there.

set -euo pipefail

script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/assemble-changelog.sh"
repo_root="$(cd -- "$(dirname -- "$script")/.." && pwd)"
failures=0

pass() { echo "ok   — $1"; }
fail() {
    echo "FAIL — $1"
    failures=$((failures + 1))
}

# make_repo <dir> — a minimal tree with the same shape the real script expects.
make_repo() {
    mkdir -p "$1/scripts" "$1/changelog.d"
    cp "$script" "$1/scripts/"
    printf '.{\n    .name = .zigapagos,\n    .version = "0.4.2",\n}\n' > "$1/build.zig.zon"
    cat > "$1/CHANGELOG.md" << 'EOF'
# Changelog

Preamble that must survive untouched.

## [Unreleased]

Unreleased changes live as fragments in `changelog.d/`.

## [0.1.0] - 2026-07-26

### Added

- The first release.

[Unreleased]: https://github.com/valthon/zigapagos/compare/22ea4a0...HEAD
[0.1.0]: https://github.com/valthon/zigapagos/compare/496e42d...22ea4a0
EOF
    # A README that would blow up loudly if it were ever treated as a fragment: it holds a
    # bullet under a real section name AND a line of prose before any heading.
    cat > "$1/changelog.d/README.md" << 'EOF'
Prose before any heading — a fragment parser would reject this.

### Added

- README BULLET THAT MUST NEVER BE ASSEMBLED
EOF
}

# run <dir> [args...] — run the script, capture stdout+stderr in $out, exit code in $rc.
run() {
    local dir="$1"
    shift
    rc=0
    out="$(bash "$dir/scripts/assemble-changelog.sh" "$@" 2>&1)" || rc=$?
}

# expect_exit <want> <name> <dir> [args...]
expect_exit() {
    local want="$1" name="$2" dir="$3"
    shift 3
    run "$dir" "$@"
    if [ "$rc" -eq "$want" ]; then pass "$name"; else
        fail "$name (want exit $want, got $rc)"
        printf '%s\n' "$out" | sed 's/^/       | /'
    fi
}

# assert <name> <condition-description> ... used as: assert <name> && / ||
check() { # check <name> <test-expression-result-as-command>
    if "${@:2}"; then pass "$1"; else fail "$1"; fi
}

out_has() { printf '%s\n' "$out" | grep -qF -- "$1"; }
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
hasre() { grep -qE -- "$2" "$1"; }

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

# --- case 1: multiple fragments aggregate into ONE section, in glob order ----
make_repo "$t/c1"
cat > "$t/c1/changelog.d/a-first.md" << 'EOF'
### Added

- alpha bullet
EOF
cat > "$t/c1/changelog.d/b-second.md" << 'EOF'
### Added

- beta bullet
EOF
expect_exit 0 "two fragments, same section: assembles" "$t/c1" 0.2.0 2026-08-01
cl="$t/c1/CHANGELOG.md"
check "exact heading format '## [0.2.0] - 2026-08-01'" hasre "$cl" '^## \[0\.2\.0\] - 2026-08-01$'
check "the two fragments share one '### Added'" test "$(grep -c '^### Added$' "$cl")" -eq 2 # 0.2.0 + 0.1.0
check "alpha bullet present" has "$cl" '- alpha bullet'
check "beta bullet present" has "$cl" '- beta bullet'
check "bullets aggregate contiguously, in glob order" \
    test "$(grep -n -- '- beta bullet' "$cl" | cut -d: -f1)" \
    -eq "$(($(grep -n -- '- alpha bullet' "$cl" | cut -d: -f1) + 1))"
check "preamble survived" has "$cl" 'Preamble that must survive untouched.'
check "[Unreleased] heading survived" has "$cl" '## [Unreleased]'
check "prior release survived" has "$cl" '## [0.1.0] - 2026-07-26'
check "consumed fragments deleted" test ! -e "$t/c1/changelog.d/a-first.md"
check "README.md is not consumed" test -f "$t/c1/changelog.d/README.md"
check "README bullet never assembled" hasnt "$cl" 'README BULLET THAT MUST NEVER BE ASSEMBLED'
check "[Unreleased] link re-pointed at the new tag" \
    has "$cl" '[Unreleased]: https://github.com/valthon/zigapagos/compare/v0.2.0...HEAD'
check "new version link takes over the old Unreleased base" \
    has "$cl" '[0.2.0]: https://github.com/valthon/zigapagos/compare/22ea4a0...v0.2.0'
check "prior version link untouched" \
    has "$cl" '[0.1.0]: https://github.com/valthon/zigapagos/compare/496e42d...22ea4a0'

# --- case 2: one fragment spanning several sections, emitted canonically ----
make_repo "$t/c2"
# Written out of canonical order on purpose: Internal, Fixed, Added.
cat > "$t/c2/changelog.d/spanning.md" << 'EOF'
### Internal

- internal bullet

### Fixed

- fixed bullet

### Added

- added bullet
EOF
cat > "$t/c2/changelog.d/zz-more.md" << 'EOF'
### Known limitations

- limitation bullet
EOF
expect_exit 0 "fragment spanning multiple sections: assembles" "$t/c2" 0.3.0 2026-08-02
cl="$t/c2/CHANGELOG.md"
order="$(grep -n -E '^### (Added|Fixed|Known limitations|Internal)$' "$cl" | head -4 | cut -d: -f2 | tr '\n' '|')"
check "sections emitted in canonical order (Added|Fixed|Known limitations|Internal)" \
    test "$order" = "### Added|### Fixed|### Known limitations|### Internal|"
check "cross-fragment section merged in (Known limitations)" has "$cl" '- limitation bullet'

# --- case 3: README.md alone is not a fragment -------------------------------
make_repo "$t/c3"
expect_exit 1 "only README.md present: no-fragments error" "$t/c3" 0.2.0 2026-08-01
check "no-fragments run left CHANGELOG.md untouched" hasnt "$t/c3/CHANGELOG.md" '0.2.0'
check "no-fragments error names the directory" out_has 'no fragments in changelog.d/'

# --- case 4: authoring mistakes fail loudly ---------------------------------
make_repo "$t/c4a"
printf '### Featurez\n\n- typo\n' > "$t/c4a/changelog.d/bad.md"
expect_exit 1 "unknown section name fails" "$t/c4a" 0.2.0 2026-08-01
check "unknown-section run wrote nothing" hasnt "$t/c4a/CHANGELOG.md" '0.2.0'
check "fragment not deleted on failure" test -f "$t/c4a/changelog.d/bad.md"

make_repo "$t/c4b"
printf 'a bullet with no section\n\n### Added\n\n- ok\n' > "$t/c4b/changelog.d/bad.md"
expect_exit 1 "content before the first heading fails" "$t/c4b" 0.2.0 2026-08-01

make_repo "$t/c4c"
printf '%s\n' '- just a bullet, no heading at all' > "$t/c4c/changelog.d/bad.md"
expect_exit 1 "fragment with no heading fails" "$t/c4c" 0.2.0 2026-08-01

make_repo "$t/c4d"
printf '### Added\n\n### Fixed\n\n' > "$t/c4d/changelog.d/empty.md"
expect_exit 1 "headings with no bullets fail" "$t/c4d" 0.2.0 2026-08-01

# --- case 5: a duplicate version is refused ---------------------------------
make_repo "$t/c5"
printf '### Added\n\n- x\n' > "$t/c5/changelog.d/f.md"
expect_exit 1 "re-assembling an already-released version fails" "$t/c5" 0.1.0 2026-08-01
check "duplicate-version run left the fragment in place" test -f "$t/c5/changelog.d/f.md"

# --- case 6: malformed version/date are refused (heading is an interface) ----
make_repo "$t/c6"
printf '### Added\n\n- x\n' > "$t/c6/changelog.d/f.md"
expect_exit 1 "non-semver version refused" "$t/c6" "0.2" 2026-08-01
expect_exit 1 "malformed date refused" "$t/c6" 0.2.0 "Aug 1 2026"
expect_exit 2 "unknown option refused" "$t/c6" --nope
expect_exit 2 "extra positional argument refused" "$t/c6" 0.2.0 2026-08-01 extra

# --- case 7: version defaults to build.zig.zon, leading v accepted -----------
make_repo "$t/c7a"
printf '### Added\n\n- x\n' > "$t/c7a/changelog.d/f.md"
expect_exit 0 "no arguments: version from build.zig.zon, date from today (UTC)" "$t/c7a"
check "defaulted heading uses build.zig.zon's 0.4.2" \
    hasre "$t/c7a/CHANGELOG.md" '^## \[0\.4\.2\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$'
make_repo "$t/c7b"
printf '### Added\n\n- x\n' > "$t/c7b/changelog.d/f.md"
expect_exit 0 "leading v on the version argument is accepted" "$t/c7b" v0.9.0 2026-08-04
check "leading v stripped from the heading" hasre "$t/c7b/CHANGELOG.md" '^## \[0\.9\.0\] - 2026-08-04$'

# --- case 8: --dry-run writes nothing ---------------------------------------
make_repo "$t/c8"
printf '### Added\n\n- dry bullet\n' > "$t/c8/changelog.d/f.md"
before="$(cat "$t/c8/CHANGELOG.md")"
expect_exit 0 "--dry-run succeeds" "$t/c8" 0.2.0 2026-08-01 --dry-run
check "--dry-run left CHANGELOG.md byte-identical" test "$before" = "$(cat "$t/c8/CHANGELOG.md")"
check "--dry-run left the fragment in place" test -f "$t/c8/changelog.d/f.md"
check "--dry-run printed the heading it would emit" out_has '## [0.2.0] - 2026-08-01'
check "--dry-run listed the fragment it would remove" out_has 'changelog.d/f.md'

# --- case 9: blank-line handling --------------------------------------------
make_repo "$t/c9"
cat > "$t/c9/changelog.d/a.md" << 'EOF'
### Changed

- bullet with a follow-up paragraph.

  The paragraph, which must survive.
EOF
cat > "$t/c9/changelog.d/b.md" << 'EOF'

### Changed

- a second fragment's bullet
EOF
expect_exit 0 "blank-line fragment assembles" "$t/c9" 0.2.0 2026-08-01
cl="$t/c9/CHANGELOG.md"
check "interior blank line preserved inside a chunk" \
    test "$(($(grep -n 'The paragraph, which must survive' "$cl" | cut -d: -f1) - 2))" \
    -eq "$(grep -n 'bullet with a follow-up paragraph' "$cl" | cut -d: -f1)"
check "no gap introduced between fragments' bullets" \
    test "$(($(grep -n "a second fragment's bullet" "$cl" | cut -d: -f1) - 1))" \
    -eq "$(grep -n 'The paragraph, which must survive' "$cl" | cut -d: -f1)"

# --- case 10: tracked fragments are removed with git rm ---------------------
make_repo "$t/c10"
(
    cd "$t/c10"
    git init -q .
    printf '### Added\n\n- tracked bullet\n' > changelog.d/tracked.md
    git add -A
    # gpgsign off explicitly: the fixture repo inherits the developer's global git config,
    # and a signing prompt would hang or fail the gate for reasons unrelated to the script.
    git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false \
        commit -q -m fixture
)
expect_exit 0 "tracked fragment: assembles" "$t/c10" 0.2.0 2026-08-01
check "tracked fragment gone from the working tree" test ! -e "$t/c10/changelog.d/tracked.md"
check "tracked fragment removal is staged (git rm, not rm)" \
    test -n "$(cd "$t/c10" && git diff --cached --name-only --diff-filter=D)"

# --- case 11: a missing [Unreleased] link warns but still inserts -----------
make_repo "$t/c11"
grep -v '^\[Unreleased\]:' "$t/c11/CHANGELOG.md" > "$t/c11/CHANGELOG.tmp"
mv "$t/c11/CHANGELOG.tmp" "$t/c11/CHANGELOG.md"
printf '### Added\n\n- x\n' > "$t/c11/changelog.d/f.md"
expect_exit 0 "missing [Unreleased] link definition does not fail the release" "$t/c11" 0.2.0 2026-08-01
check "section still inserted" hasre "$t/c11/CHANGELOG.md" '^## \[0\.2\.0\] - 2026-08-01$'

# --- case 12: the emitted section is parseable by extract-release-notes.sh ---
# Prefer the REAL extractor. A mirrored copy would pin whatever the mirror does rather than
# what ships, which is worse than no test — the shipped script deliberately differs from the
# obvious implementation (it strips the `## [x.y.z]` heading, since `gh release create
# --title` already renders the version, and it terminates on the reference-link block as
# well as on the next `## `). The fallback below therefore asserts only what BOTH agree on:
# the section is located by `## [<version>]` at the start of a line and ends at the next
# `## `. Nothing here asserts whether the heading line or the link block are included —
# that is the extractor's business, not the assembler's.
if [ -x "$repo_root/scripts/extract-release-notes.sh" ] || [ -f "$repo_root/scripts/extract-release-notes.sh" ]; then
    extractor_kind="the real scripts/extract-release-notes.sh"
    extract() { # extract <changelog> <version>
        # It resolves CHANGELOG.md relative to its own directory, so run a copy in place.
        cp "$repo_root/scripts/extract-release-notes.sh" "$(dirname "$1")/scripts/"
        bash "$(dirname "$1")/scripts/extract-release-notes.sh" "$2"
    }
else
    extractor_kind="a minimal locator (extract-release-notes.sh not in this checkout)"
    extract() { # extract <changelog> <version>
        awk -v ver="$2" '
          /^## / {
            if (found) exit
            if (index($0, "## [" ver "]") == 1) { found=1 }
          }
          found { print }
          END { if (!found) { print "error: version " ver " not found" > "/dev/stderr"; exit 1 } }
        ' "$1"
    }
fi
echo "     (release-notes compatibility checked against $extractor_kind)"

make_repo "$t/c12"
# Drive it against a COPY of the repo's real CHANGELOG.md, so the contract is proven against
# the file that actually ships rather than against a fixture shaped to pass.
cp "$repo_root/CHANGELOG.md" "$t/c12/CHANGELOG.md"
cat > "$t/c12/changelog.d/one.md" << 'EOF'
### Added

- extractable added bullet

### Fixed

- extractable fixed bullet
EOF
cat > "$t/c12/changelog.d/two.md" << 'EOF'
### Internal

- extractable internal bullet
EOF
expect_exit 0 "assembles into a copy of the real CHANGELOG.md" "$t/c12" 0.2.0 2026-08-05
notes="$t/c12/notes.txt"
if extract "$t/c12/CHANGELOG.md" 0.2.0 > "$notes" 2> /dev/null; then
    pass "the extractor locates the assembled section by its heading"
else
    fail "the extractor locates the assembled section by its heading"
fi
check "extracted notes are non-empty" test -s "$notes"
check "extracted notes carry the first section's bullets" has "$notes" '- extractable added bullet'
check "extracted notes carry the last section's bullets" has "$notes" '- extractable internal bullet'
check "extracted notes stop before the next release's heading" hasnt "$notes" '## [0.1.0]'
check "extracted notes carry none of the next release's bullets" \
    hasnt "$notes" 'First public release. Fork point'
check "extracted notes do not leak the preamble" hasnt "$notes" 'Two things to know'
check "the real preamble survived assembly" \
    has "$t/c12/CHANGELOG.md" 'This file starts at the first public release, deliberately.'
check "the inherited-tags warning survived assembly" \
    has "$t/c12/CHANGELOG.md" 'are not Zigapagos'
# The pre-existing section must stay extractable after an insert above it — the assembler
# must not have disturbed its heading or the boundary below it.
if extract "$t/c12/CHANGELOG.md" 0.1.0 > "$t/c12/old.txt" 2> /dev/null; then
    pass "the pre-existing 0.1.0 section is still extractable after assembly"
else
    fail "the pre-existing 0.1.0 section is still extractable after assembly"
fi
check "0.1.0 extraction does not reach up into the 0.2.0 section" \
    hasnt "$t/c12/old.txt" '## [0.2.0]'
check "0.1.0 extraction carries none of 0.2.0's bullets" \
    hasnt "$t/c12/old.txt" '- extractable added bullet'
check "0.1.0 extraction still carries its own content" \
    has "$t/c12/old.txt" 'First public release. Fork point'

if [ "$failures" -ne 0 ]; then
    echo "$failures self-test case(s) failed" >&2
    exit 1
fi
echo "all assemble-changelog self-tests passed"
