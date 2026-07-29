//! Fork-added (issue #31). Everything in here supports the "unknown code-fence
//! language" authoring loop: a did-you-mean suggestion for `analyzeContent`'s
//! `unknown_language` diagnostic (src/worker.zig) and the language list printed
//! by `zigapagos languages` (src/cli/languages.zig). New logic lives in this
//! file rather than the inherited src/worker.zig so upstream syncs stay
//! tractable (see CLAUDE.md's "Architecture" section).
const std = @import("std");
const syntax = @import("syntax");

/// Bounded case-insensitive Levenshtein distance between `a` and `b`, or null
/// if the two strings' length difference alone already exceeds `threshold`
/// (the common case for a genuinely unrelated word -- skips the O(len(a) *
/// len(b)) DP entirely). A non-null result is NOT guaranteed to be
/// `<= threshold`; callers compare the returned distance themselves.
///
/// NO_SLOP contract: caller-buffer (allocates nothing). `b` (always a
/// registered flow_syntax name or extension) is the row width; the longest of
/// either list is "Directory.Build.props" at 21 bytes, so a 64-byte stack
/// buffer is comfortable headroom without allocating. Any longer `b` is
/// rejected outright (`return null`) rather than silently truncated.
fn levenshtein(a: []const u8, b: []const u8, threshold: usize) ?usize {
    const len_diff = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (len_diff > threshold) return null;

    const max_row = 64;
    if (b.len >= max_row) return null;

    var row_a: [max_row]usize = undefined;
    var row_b: [max_row]usize = undefined;
    var prev: []usize = row_a[0 .. b.len + 1];
    var cur: []usize = row_b[0 .. b.len + 1];

    for (prev, 0..) |*v, i| v.* = i;

    for (a, 1..) |ca, i| {
        cur[0] = i;
        for (b, 1..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            cur[j] = @min(@min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
        }
        const tmp = prev;
        prev = cur;
        cur = tmp;
    }

    return prev[b.len];
}

/// True when `a` and `b` are a case-insensitive prefix match of one another
/// (either direction, either equal length or not -- equal-length inputs at
/// distance 2 are two substitutions, never a prefix relation, so this only
/// ever fires for a length-differing pair).
fn isPrefixMatch(a: []const u8, b: []const u8) bool {
    const shorter, const longer = if (a.len <= b.len) .{ a, b } else .{ b, a };
    return std.ascii.startsWithIgnoreCase(longer, shorter);
}

/// Did-you-mean for an unrecognized code-fence / `$code` language. Searches
/// every flow_syntax registered language NAME and EXTENSION (`syntax.FileType
/// .get_all()`) and returns the closest one within the threshold, or null.
///
/// Threshold: 1 when `input.len < 4`, else 2 -- a short input needs the
/// tighter bound, or a 2-3 byte typo would sit at distance 2 from a large
/// fraction of the (mostly short) extension list and produce noise instead of
/// a suggestion. On a distance tie, a NAME wins over an EXTENSION (the
/// candidate is what the user should type in the fence, and the canonical
/// name reads better there).
///
/// A distance-2 match is additionally required to be a case-insensitive
/// PREFIX of one string over the other (either direction) -- e.g. "zig++" /
/// "zig". At distance 2 that prefix/suffix-trim shape is the only one that
/// still reads as a plausible typo; anything else at distance 2 rewrites two
/// of a handful of characters and produces a confidently wrong answer instead
/// of no answer (issue #31's own motivating example, "nginx", is distance 2
/// from the "nix" name/extension with no prefix relation -- "did you mean
/// 'nix'?" is worse than staying silent). Distance 0/1 stays unconditional.
///
/// KNOWN, ACCEPTED TRADE: this also silences equal-length TRANSPOSITION typos.
/// "pyhton" is distance 2 from "python" with no prefix relation either way, so
/// it now suggests nothing where a plain threshold-2 would have suggested
/// correctly. Accepted because the rule has to be decided on shape alone --
/// plain Levenshtein cannot tell a transposition from two unrelated
/// substitutions, which is exactly what makes "nginx"/"nix" indistinguishable
/// from a real typo. Switching to Damerau-Levenshtein (which scores a
/// transposition as ONE edit) would recover this class through the
/// unconditional distance-0/1 path without re-admitting "nginx" -- the
/// principled follow-up if transposition typos turn out to matter in practice.
///
/// Extensions are real candidates, not a nicety: `languageExists`
/// (src/worker.zig) already accepts an unregistered-as-a-name string when it
/// matches a registered extension via `FileType.guess_static("file.<lang>",
/// "")` -- "yml" and "sh" are accepted today. Those inputs never reach this
/// function at all (languageExists returns true first), which is exactly why
/// they must never appear as a suggestion here either: nothing has verified
/// the flip side (an extension close to, but not equal to, a real one).
///
/// NO_SLOP contract: caller-buffer (allocates nothing) -- this is a
/// failure-path-only loop (~91 names + ~200 extensions) so the cost is nil
/// regardless, but `levenshtein`'s length-gap short-circuit keeps the common
/// "not even close" case from running the DP at all.
pub fn suggest(input: []const u8) ?[]const u8 {
    const threshold: usize = if (input.len < 4) 1 else 2;

    var best: ?[]const u8 = null;
    var best_dist: usize = threshold + 1; // sentinel: worse than any acceptable match
    var best_is_name = false;

    for (syntax.FileType.get_all()) |ft| {
        if (levenshtein(input, ft.name, threshold)) |d| {
            if (d < 2 or isPrefixMatch(input, ft.name)) {
                if (d < best_dist or (best != null and d == best_dist and !best_is_name)) {
                    best = ft.name;
                    best_dist = d;
                    best_is_name = true;
                }
            }
        }

        for (ft.extensions) |ext| {
            if (levenshtein(input, ext, threshold)) |d| {
                if (d < 2 or isPrefixMatch(input, ext)) {
                    // Strictly less, never a tie override: a NAME already at
                    // this distance keeps its spot (see doc comment above).
                    if (d < best_dist) {
                        best = ext;
                        best_dist = d;
                        best_is_name = false;
                    }
                }
            }
        }
    }

    return best;
}

test "suggest: jsonc suggests json" {
    try std.testing.expectEqualStrings("json", suggest("jsonc").?);
}

test "suggest: zig++ suggests zig" {
    try std.testing.expectEqualStrings("zig", suggest("zig++").?);
}

test "suggest: is case-insensitive" {
    try std.testing.expectEqualStrings("json", suggest("JSONC").?);
}

test "suggest: yml is accepted by languageExists's guess fallback, so it never reaches suggest" {
    // Mirrors the exact mechanism src/worker.zig's languageExists relies on: a
    // language string that fails FileType.get_by_name_static is still accepted
    // if FileType.guess_static("file.<lang>", "") resolves it via extension
    // match. "yml" is a registered extension of the `yaml` filetype, so
    // languageExists("yml") is true and suggest() is never called for it.
    // Pinned against the flow_syntax API directly (rather than duplicating
    // languageExists here, or importing worker.zig and creating a cycle) so a
    // flow_syntax version bump that broke this falls out of this test, not a
    // silently-wrong suggestion in the wild.
    try std.testing.expect(syntax.FileType.guess_static("file.yml", "") != null);
}

test "suggest: no near match returns null" {
    // "frobnicate" was picked by empirically measuring its distance against
    // every registered name and extension (min distance 7, far past the
    // threshold of 2 for a 10-byte input).
    try std.testing.expect(suggest("frobnicate") == null);
}

test "suggest: nginx (issue #31's own example) returns null, not 'nix'" {
    // "nginx" is distance 2 from the "nix" name/extension, but "nix" is NOT a
    // prefix of "nginx" (or vice versa) -- at distance 2 that's the only
    // shape trustworthy enough to call a plausible typo (see suggest's doc
    // comment). A pure two-substitution hop like this one is confidently
    // wrong, and "did you mean 'nix'?" for the issue's own motivating example
    // would be worse than offering no suggestion at all.
    try std.testing.expect(suggest("nginx") == null);
}

test "suggest: distance-2 prefix relation is still suggested (zig++ -> zig)" {
    // Pins the rule directly, independent of the "zig++ suggests zig" test
    // above (which exercises the same case but doesn't name the mechanism):
    // "zig" is a case-insensitive prefix of "zig++", so the distance-2 match
    // survives the extra check.
    try std.testing.expectEqualStrings("zig", suggest("zig++").?);
    try std.testing.expect(isPrefixMatch("zig++", "zig")); // candidate is a prefix of input
    try std.testing.expect(isPrefixMatch("zig", "zig++")); // symmetric: order doesn't matter
    try std.testing.expect(!isPrefixMatch("nginx", "nix")); // the distance-2 case that must NOT match
}
