#!/usr/bin/env bash
# Self-test for check-allocator-contracts.sh (NO_SLOP.md §2.2a).
#
# Each case builds a throwaway tree in $TMPDIR with its own src/ and allowlist,
# so nothing here reads or writes the real repo. Case 2 is the regression test
# for the defect that motivated the gate: an alias-spelled site
# (`ArenaAllocator.init(gpa)` after `const gpa = std.testing.allocator;`) is
# invisible to a literal grep, so a scanner without alias resolution passes
# case 2 and the gate is worthless. Case 4 is its guard rail: a *parameter*
# named `gpa` must NOT be flagged, or alias resolution just trades a false
# negative for a false positive.

set -euo pipefail

script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/check-allocator-contracts.sh"
failures=0

# make_tree <dir> <allowlist-body>
make_tree() {
    mkdir -p "$1/scripts" "$1/src"
    cp "$script" "$1/scripts/"
    printf '# self-test fixture\n%s' "$2" >"$1/scripts/allocator-allowlist.txt"
}

# expect <exit-code> <name> <dir>
expect() {
    local want="$1" name="$2" dir="$3" got=0
    bash "$dir/scripts/check-allocator-contracts.sh" >/dev/null 2>&1 || got=$?
    if [ "$got" -eq "$want" ]; then
        echo "ok   — $name"
    else
        echo "FAIL — $name (want exit $want, got $got)"
        failures=$((failures + 1))
    fi
}

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

# --- case 1: an allowlisted site passes -------------------------------------
make_tree "$t/c1" 'src/ok.zig	1	JUSTIFIED contract 4: fixture.
'
cat >"$t/c1/src/ok.zig" <<'EOF'
const std = @import("std");
test "allowed site" {
    const gpa = std.testing.allocator;
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
}
EOF
expect 0 "allowlisted site passes" "$t/c1"

# --- case 2: a NEW alias-spelled site fails (the blind-spot regression) ------
cp -r "$t/c1" "$t/c2"
cat >>"$t/c2/src/ok.zig" <<'EOF'
test "new alias-spelled site" {
    const alloc = std.testing.allocator;
    var b = std.heap.ArenaAllocator.init(alloc);
    defer b.deinit();
}
EOF
expect 1 "new alias-spelled site fails (no literal std.testing.allocator on the init line)" "$t/c2"

# --- case 3: any site in an unlisted file fails -----------------------------
cp -r "$t/c1" "$t/c3"
cat >"$t/c3/src/new.zig" <<'EOF'
const std = @import("std");
test "unlisted file" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
}
EOF
expect 1 "unlisted file with a site fails" "$t/c3"

# --- case 4: a parameter named gpa is not the testing allocator -------------
make_tree "$t/c4" ''
cat >"$t/c4/src/prod.zig" <<'EOF'
const std = @import("std");
fn realCode(gpa: std.mem.Allocator) !void {
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
}
test "unrelated test" {
    try realCode(std.testing.allocator);
}
EOF
expect 0 "parameter named gpa is not flagged (alias scoping)" "$t/c4"

# --- case 5: a brace inside a string must not corrupt scope tracking --------
make_tree "$t/c5" 'src/tricky.zig	1	JUSTIFIED contract 4: fixture.
'
cat >"$t/c5/src/tricky.zig" <<'EOF'
const std = @import("std");
test "brace in a string literal" {
    const s = "{{{";
    _ = s;
    // }}} not real braces either
}
test "site after the tricky test" {
    const gpa = std.testing.allocator;
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
}
EOF
expect 0 "unbalanced braces inside strings/comments do not break scoping" "$t/c5"

# --- case 6: removing a site never fails the build --------------------------
make_tree "$t/c6" 'src/ok.zig	2	JUSTIFIED contract 4: fixture (one site since deleted).
'
cat >"$t/c6/src/ok.zig" <<'EOF'
const std = @import("std");
test "only one left" {
    const gpa = std.testing.allocator;
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
}
EOF
expect 0 "count going down does not fail" "$t/c6"

if [ "$failures" -ne 0 ]; then
    echo "$failures self-test case(s) failed" >&2
    exit 1
fi
echo "all check-allocator-contracts self-tests passed"
