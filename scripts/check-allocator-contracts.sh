#!/usr/bin/env bash
# check-allocator-contracts.sh — enforce NO_SLOP.md §2.2a.
#
# Wrapping `std.testing.allocator` in an `ArenaAllocator` turns Zig's leak
# detector OFF for that test: the arena frees everything in one shot at
# `deinit`, so a missing `defer free` in the code under test can never be
# observed. NO_SLOP.md allows that only for a contract-4 (arena-scoped)
# function, and only with a written justification.
#
# This script finds every such site and compares it against
# scripts/allocator-allowlist.txt, which carries a per-file count and a
# one-line justification. It fails when a file grows a NEW site, or when a
# file that is not on the list has any site at all. Removing sites never
# fails the build (progress must not be punished) — run `--update` to record
# the lower count.
#
# Detection notes (the reason this is awk and not a one-line grep):
#   * The spelling this repo uses most is NOT `ArenaAllocator.init(
#     std.testing.allocator)`. It is `ArenaAllocator.init(gpa)` where a
#     preceding `const gpa = std.testing.allocator;` binds the alias. A grep
#     for the literal spellings misses ~2/3 of the real sites, so the scanner
#     resolves aliases, scoped by brace depth.
#   * Strings, char literals, `\\` multiline-string lines and `//` comments are
#     blanked before braces are counted, so depth tracking is not thrown off by
#     a `{` inside a string.
#
# Usage:
#   scripts/check-allocator-contracts.sh            # gate (exit 1 on a new site)
#   scripts/check-allocator-contracts.sh --list     # print every detected site
#   scripts/check-allocator-contracts.sh --update   # rewrite the allowlist counts
#
# Exit codes: 0 ok, 1 violation, 2 usage/internal error.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
allowlist="$repo_root/scripts/allocator-allowlist.txt"

mode="check"
case "${1-}" in
    "") ;;
    --list) mode="list" ;;
    --update) mode="update" ;;
    -h|--help)
        sed -n '2,30p' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    *)
        echo "check-allocator-contracts.sh: unknown argument '$1'" >&2
        exit 2
        ;;
esac

# Scan first-party Zig only. Vendored deps live in the Zig package cache and
# tests/**/assets holds fixture files that are not compiled by this project.
scan_roots=()
for d in src build; do
    [ -d "$repo_root/$d" ] && scan_roots+=("$repo_root/$d")
done
if [ ${#scan_roots[@]} -eq 0 ]; then
    echo "check-allocator-contracts.sh: no source roots found under $repo_root" >&2
    exit 2
fi

scanner='
function blank(l,   t) {
    # A `\\` line is a whole multiline-string-literal line: nothing on it is code.
    t = l
    sub(/^[ \t]*/, "", t)
    if (substr(t, 1, 2) == "\\\\") return ""
    gsub(/'"'"'([^'"'"'\\]|\\.)*'"'"'/, "CH", l)   # char literals
    gsub(/"([^"\\]|\\.)*"/, "STR", l)              # string literals
    sub(/\/\/.*/, "", l)                           # line comments
    return l
}

function braces(l,   i, c, n) {
    n = 0
    for (i = 1; i <= length(l); i++) {
        c = substr(l, i, 1)
        if (c == "{") n++
        else if (c == "}") n--
    }
    return n
}

function drop_scoped(d,   k, i, n, dead) {
    # Leave every scope deeper than d: its aliases are dead. Collect first,
    # then delete — deleting while iterating is not portable across awks.
    n = 0
    for (k in alias) if (alias[k] > d) dead[++n] = k
    for (i = 1; i <= n; i++) delete alias[dead[i]]
}

BEGIN { FS = "\n" }

FNR == 1 {
    for (k in alias) delete alias[k]
    depth = 0
    in_test = 0
    test_depth = -1
}

{
    line = blank($0)

    # --- alias bindings: const <ident> = [std.]testing.allocator;
    if (match(line, /const[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*(std\.)?testing\.allocator[ \t]*;/)) {
        decl = substr(line, RSTART, RLENGTH)
        sub(/^const[ \t]+/, "", decl)
        sub(/[ \t]*=.*$/, "", decl)
        alias[decl] = depth
    }

    # --- the site itself: ArenaAllocator.init(<arg>)
    if (match(line, /ArenaAllocator\.init\([^()]*\)/)) {
        call = substr(line, RSTART, RLENGTH)
        arg = call
        sub(/^ArenaAllocator\.init\(/, "", arg)
        sub(/\)$/, "", arg)
        gsub(/[ \t]/, "", arg)
        hit = 0
        if (arg == "std.testing.allocator" || arg == "testing.allocator") hit = 1
        else if (arg in alias) hit = 1
        if (hit) {
            rel = FILENAME
            sub(root "/", "", rel)
            printf "%s\t%d\t%s\t%s\n", rel, FNR, arg, (in_test ? "test" : "non-test")
        }
    }

    # --- test-block tracking (informational column only).
    # Matched against the RAW line: blank() has already rewritten the test name
    # literal to STR, so the quote is gone from `line`.
    if (!in_test && $0 ~ /^[ \t]*test[ \t]*("|\{)/) {
        in_test = 1
        test_depth = depth
    }

    delta = braces(line)
    depth += delta
    if (depth < 0) depth = 0
    drop_scoped(depth)
    if (in_test && depth <= test_depth) in_test = 0
}
'

detected="$(mktemp)"
sources="$(mktemp)"
trap 'rm -f "$detected" "$detected.counts" "$detected.expected" "$sources"' EXIT

find "${scan_roots[@]}" -name '*.zig' -type f -print0 | LC_ALL=C sort -z >"$sources"
if [ -s "$sources" ]; then
    # `xargs` with an empty list would run awk with no file operands, which
    # reads stdin and hangs; the -s guard above is portable, `xargs -r` is not.
    xargs -0 awk -v root="$repo_root" "$scanner" <"$sources" >"$detected"
else
    : >"$detected"
fi

if [ "$mode" = "list" ]; then
    if [ -s "$detected" ]; then
        printf 'file\tline\tallocator-expr\tcontext\n'
        cat "$detected"
    else
        echo "no arena-wrapped testing allocators found"
    fi
    exit 0
fi

# path -> count
awk -F'\t' '{ n[$1]++ } END { for (p in n) printf "%s\t%d\n", p, n[p] }' "$detected" |
    LC_ALL=C sort >"$detected.counts"

if [ "$mode" = "update" ]; then
    if [ ! -f "$allowlist" ]; then
        echo "check-allocator-contracts.sh: $allowlist is missing; write its header first" >&2
        exit 2
    fi
    tmp="$(mktemp)"
    # Keep the header/comments, replace the data rows, preserving each file's
    # existing justification so --update never silently erases a rationale.
    awk -F'\t' '
        FNR == NR { if ($0 !~ /^[ \t]*#/ && NF >= 3) why[$1] = $3; next }
        { printf "%s\t%d\t%s\n", $1, $2, ($1 in why ? why[$1] : "TODO: justify or fix — see NO_SLOP.md 2.2a") }
    ' "$allowlist" "$detected.counts" >"$tmp"
    awk '/^[ \t]*#/ || NF == 0 { print; next } { exit }' "$allowlist" >"$allowlist.new"
    cat "$tmp" >>"$allowlist.new"
    mv "$allowlist.new" "$allowlist"
    rm -f "$tmp"
    echo "updated $allowlist"
    exit 0
fi

if [ ! -f "$allowlist" ]; then
    echo "check-allocator-contracts.sh: missing $allowlist (NO_SLOP.md 2.2a requires it)" >&2
    exit 2
fi

# Data rows only. Done in awk, not `grep -v | awk`: an allowlist that is all
# comments makes grep exit 1, which under `set -o pipefail` would abort the
# whole run instead of reporting the (correct) "nothing is allowlisted".
awk -F'\t' '
    /^[ \t]*#/ { next }
    NF == 0 { next }
    { printf "%s\t%s\n", $1, $2 }
' "$allowlist" | LC_ALL=C sort >"$detected.expected"

status=0
while IFS=$'\t' read -r path count; do
    [ -n "$path" ] || continue
    allowed="$(awk -F'\t' -v p="$path" '$1 == p { print $2 }' "$detected.expected")"
    if [ -z "$allowed" ]; then
        status=1
        printf '\n%s: %s arena-wrapped testing allocator(s), file not on the allowlist\n' "$path" "$count"
        awk -F'\t' -v p="$path" '$1 == p { printf "    %s:%s  ArenaAllocator.init(%s)  [%s]\n", $1, $2, $3, $4 }' "$detected"
    elif [ "$count" -gt "$allowed" ]; then
        status=1
        printf '\n%s: %s arena-wrapped testing allocator(s), allowlist permits %s\n' "$path" "$count" "$allowed"
        awk -F'\t' -v p="$path" '$1 == p { printf "    %s:%s  ArenaAllocator.init(%s)  [%s]\n", $1, $2, $3, $4 }' "$detected"
    fi
done <"$detected.counts"

if [ "$status" -ne 0 ]; then
    cat >&2 <<'MSG'

NO_SLOP.md 2.2a: wrapping std.testing.allocator (or an alias bound to it) in an
ArenaAllocator disables Zig's leak detector for that test.

Fix it by passing the raw testing allocator and pairing every allocation with a
defer/errdefer. If the code under test is genuinely contract-4 (arena-scoped —
an interlinked graph the caller reclaims by dropping the arena), add the file to
scripts/allocator-allowlist.txt with a one-line justification saying WHY.
"It was already written that way" is not a justification.

Run `scripts/check-allocator-contracts.sh --list` to see every site.
MSG
    exit 1
fi

total="$(wc -l <"$detected" | tr -d ' ')"
echo "allocator contracts OK: $total arena-wrapped testing allocator(s), all allowlisted"
exit 0
