//! GitHub-compatible heading-id injection (issue #29).
//!
//! SuperMD only stores a heading id when the author writes an explicit
//! `$heading.id(...)`/`$section.id(...)` directive (`ast.ids`, populated by
//! `Ast.init`). Markdown authored for GitHub relies on GitHub's own implicit
//! heading-anchor slugs instead, so importing such a doc verbatim turns
//! every `#anchor` link into an `unknown ref` build error. `apply` is a
//! fork-added post-parse pass (opt in via `Site.auto_heading_ids` /
//! `MultilingualSite.auto_heading_ids`, see `src/root.zig`) that injects a
//! GitHub-compatible slug id into every heading SuperMD didn't already
//! assign one to. Because it runs by mutating the `Ast` in place — adding to
//! `ast.ids` and attaching a `.heading` directive via `Node.setDirective` —
//! the renderer (`src/render/html.zig`) and both `unknown ref` checks
//! (`src/worker.zig`) need zero changes: they already trust `ast.ids` and
//! `directive.id` regardless of who populated them.
//!
//! SuperMD validates `$link.ref` before this pass. After injection we
//! recheck only those diagnostics against the completed id table; unrelated
//! syntax errors and genuinely missing references remain errors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const supermd = @import("supermd");
const table = @import("heading_slugs_table.zig");

/// JS's `\s` character class under the Unicode (`u`) flag: TAB, LF, VT, FF,
/// CR, SPACE, NBSP, every Unicode "space separator", the line/paragraph
/// separators, and the BOM. This is GitHub's own slugifier's whitespace set
/// (it is implemented in JS), reverse-engineered for this codebase already
/// at `site/scripts/gen-docs-mirror.ts`'s `slugifyHeading()`. Both the
/// "keep" step in `slugify` (a whitespace codepoint survives filtering) and
/// the "hyphenate" step (each surviving whitespace codepoint becomes its
/// own `-`) read this same table — defining it once is what keeps the two
/// steps from drifting apart.
const js_whitespace: []const u21 = &.{
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, // TAB LF VT FF CR SPACE
    0xA0, // NBSP
    0x1680, // OGHAM SPACE MARK
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, // EN QUAD .. SIX-PER-EM SPACE
    0x2006, 0x2007, 0x2008, 0x2009, 0x200A, // FIGURE SPACE .. HAIR SPACE
    0x2028, 0x2029, // LINE / PARAGRAPH SEPARATOR
    0x202F, // NARROW NO-BREAK SPACE
    0x205F, // MEDIUM MATHEMATICAL SPACE
    0x3000, // IDEOGRAPHIC SPACE
    0xFEFF, // ZERO WIDTH NO-BREAK SPACE (BOM)
};

fn isJsWhitespace(cp: u21) bool {
    for (js_whitespace) |w| {
        if (w == cp) return true;
    }
    return false;
}

fn asciiLower(b: u8) u8 {
    return switch (b) {
        'A'...'Z' => b - 'A' + 'a',
        else => b,
    };
}

/// Ports GitHub's (html-pipeline) heading-anchor slug algorithm: ASCII-
/// lowercase, drop every codepoint that is not a Unicode letter/number/`_`/
/// `-`/whitespace, trim leading/trailing whitespace, then map each
/// SURVIVING whitespace codepoint individually to `-` — NOT collapsed,
/// which is what produces GitHub's double-hyphen around a space-flanked em
/// dash (the dash itself is dropped as punctuation, leaving the two
/// spaces-turned-hyphens adjacent). Already reverse-engineered for this
/// codebase at `site/scripts/gen-docs-mirror.ts`'s `slugifyHeading()`
/// (JS regex chain: lowercase → trim → drop non `[\p{L}\p{N}\s_-]` → map
/// `\s` to `-`); this is its Zig port.
///
/// Non-ASCII case folding is CUT: only ASCII `A`-`Z` gets lowercased. This
/// is documented, not an oversight — the alternative needs a full Unicode
/// case-folding table (this codebase generates only a letter/number
/// membership table, see `heading_slugs_table.zig`), and GitHub's own
/// heading anchors for a doc that is already lowercase (the overwhelmingly
/// common case) are unaffected either way.
///
/// Allocator contract 1 (self-freeing, NO_SLOP.md §2.2a): the only
/// allocation that escapes is the returned slug. Correct under any
/// allocator, including an arena — `apply` below calls it with one.
///
/// Invalid UTF-8 in `text` cannot crash this: an undecodable byte is
/// skipped, never `unreachable`'d (NO_SLOP.md §2.3/§2.5). Heading text
/// always originates from cmark's own literal-text nodes in practice, so
/// this is defense in depth rather than a path known to trigger today.
pub fn slugify(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    // Pass 1: decode into a codepoint scratch buffer so leading/trailing
    // whitespace can be trimmed BEFORE the keep/hyphenate pass runs.
    // Trimming the OUTPUT bytes instead would wrongly strip a heading's own
    // leading/trailing literal `-` character (kept, not whitespace).
    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) {
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            i += 1;
            continue;
        };
        try codepoints.append(alloc, cp);
        i += seq_len;
    }

    var start: usize = 0;
    var end: usize = codepoints.items.len;
    while (start < end and isJsWhitespace(codepoints.items[start])) start += 1;
    while (end > start and isJsWhitespace(codepoints.items[end - 1])) end -= 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (codepoints.items[start..end]) |cp| {
        if (isJsWhitespace(cp)) {
            try out.append(alloc, '-');
            continue;
        }
        if (cp == '_' or cp == '-' or table.isLetterOrNumber(cp)) {
            if (cp < 0x80) {
                try out.append(alloc, asciiLower(@intCast(cp)));
            } else {
                var buf: [4]u8 = undefined;
                // `cp` round-trips a codepoint this same function already
                // decoded from valid UTF-8 and never modifies (only ASCII
                // gets case-folded above), so re-encoding it cannot fail —
                // this is not user input, it is our own prior output.
                const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                try out.appendSlice(alloc, buf[0..n]);
            }
        }
        // else: dropped — not a letter/number/`_`/`-`/whitespace codepoint.
    }
    return out.toOwnedSlice(alloc);
}

/// Concatenates a heading's inline literal text in document order, mirroring
/// `tocRenderHeading` in `src/render/html.zig` (so TOC text and injected
/// anchors agree): a `SOFTBREAK` contributes a space (cmark's own literal()
/// is null for it, unlike a real line-broken word), and every other inline
/// node (TEXT, CODE, and — matching `src/render/html.zig`'s AUD-006 fallback
/// — anything else, e.g. inline HTML) contributes its own literal() if it
/// has one. Deliberately NOT HTML-escaped: this text feeds `slugify`, not a
/// page body.
///
/// Allocator contract 1 (self-freeing): the only allocation that escapes is
/// the returned buffer.
fn headingText(alloc: Allocator, heading: supermd.Node) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var it = supermd.Ast.Iter.init(heading);
    defer it.deinit();
    while (it.next()) |ev| {
        if (ev.dir != .enter) continue;
        switch (ev.node.nodeType()) {
            .SOFTBREAK => try out.appendSlice(alloc, " "),
            else => if (ev.node.literal()) |lit| try out.appendSlice(alloc, lit),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// GitHub dedupe semantics: the first heading to produce a given base slug
/// keeps it unsuffixed; the Nth later duplicate becomes `<base>-<N-1>`
/// (`seen[base]` tracks how many times `base` has been claimed so far).
/// There is deliberately NO re-check that the suffixed form is itself free
/// — e.g. two headings named "Foo" plus one literally named "Foo 1" can
/// collide with the auto `foo-1`. That is GitHub's own behaviour, matched
/// faithfully here, not a bug.
///
/// Allocator contract 1 (self-freeing, NO_SLOP.md §2.2a): exactly one
/// allocation escapes — the returned slug — and nothing is left unfreed
/// behind it. `seen`'s map storage is grown through the caller's `alloc`
/// and is the caller's to release (it owns the map), and on a first claim
/// the map BORROWS `base` as its key rather than duplicating it.
///
/// Precondition, therefore: `base` must outlive `seen`. `apply` satisfies
/// this by allocating every `base` from the same scratch arena that backs
/// `seen`, which it frees in one `defer` after the walk. Duplicating the key
/// here instead would be a second escaping allocation that no `defer` in
/// this function pairs with — contract 4 without the type, which §2.2a
/// exists to stop.
fn claimSlug(
    alloc: Allocator,
    seen: *std.StringArrayHashMapUnmanaged(u32),
    base: []const u8,
) Allocator.Error![]u8 {
    const gop = try seen.getOrPut(alloc, base);
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
        // Not `return base`: a borrowed-or-owned return (borrowed when
        // unique, owned when suffixed) cannot be freed by a caller that
        // doesn't know which branch ran — §2.2a flags exactly that shape.
        return alloc.dupe(u8, base);
    }
    const n = gop.value_ptr.*;
    gop.value_ptr.* = n + 1;
    return std.fmt.allocPrint(alloc, "{s}-{d}", .{ base, n });
}

/// The injection pass. Called once per page (see `src/context/Page.zig`'s
/// `parse`, and `src/Variant.zig`'s `Section.activate` for section
/// `index.smd` pages) right after `supermd.Ast.init`, gated on
/// `auto_heading_ids`.
///
/// Walks the whole tree in document order; for every `.HEADING` node whose
/// directive is missing or has no `.id`, builds its text (`headingText`),
/// slugifies it (`slugify`), dedupes it against every id already claimed —
/// seeded from every id `Ast.init` itself already assigned, so an explicit
/// `$heading.id(...)`/`$section.id(...)` always wins and is never
/// overwritten — and attaches the result: either mutating an EXISTING
/// directive's `.id` field (preserving its other fields, e.g. `.attrs`) or
/// creating a new `.heading` directive when the heading had none. An empty
/// slug (a heading with no letter/number/`_`/`-` content, e.g. one made
/// entirely of punctuation) injects NOTHING — `tocRenderHeading` in
/// `src/render/html.zig` asserts a non-empty, non-whitespace id, so handing
/// it an empty one would be a crash, not a degraded anchor.
///
/// Allocator contract: closest to NO_SLOP.md §2.2a's contract 2
/// (owned-result). All bookkeeping scratch — the dedupe map, and every
/// heading's intermediate text/slug buffer — lives in a throwaway arena
/// freed by a single `defer` before this function returns; none of it
/// escapes. The allocations that DO escape (the id strings, and one new
/// `Directive` per newly-tagged heading) are placed in `ast`'s OWN arena
/// instead of `gpa` directly — promoted from its saved `.state` via the same
/// `arena.promote(gpa)` / `defer ast.arena = promoted.state` pattern
/// `Ast.deinit` itself uses, then demoted back. That keeps every escaping
/// allocation this pass makes on the exact same lifetime as the rest of
/// `Ast.init`'s own allocations, so whatever eventually reclaims a given
/// `Ast` (there is no separate `apply`-specific cleanup to keep in sync)
/// reclaims these too.
pub fn apply(gpa: Allocator, ast: *supermd.Ast) Allocator.Error!void {
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var seen: std.StringArrayHashMapUnmanaged(u32) = .empty;
    for (ast.ids.keys()) |k| try seen.put(scratch, k, 1);

    var promoted = ast.arena.promote(gpa);
    defer ast.arena = promoted.state;
    const arena_alloc = promoted.allocator();

    var it = supermd.Ast.Iter.init(ast.md.root);
    defer it.deinit();
    while (it.next()) |ev| {
        if (ev.dir != .enter or ev.node.nodeType() != .HEADING) continue;

        const existing = ev.node.getDirective();
        if (existing) |d| {
            if (d.id != null) continue; // explicit id wins, never overwritten
        }

        const text = try headingText(scratch, ev.node);
        const base = try slugify(scratch, text);
        if (base.len == 0) continue; // no letter/number/`_`/`-` survived

        // `base` is scratch-allocated and never freed before the walk ends,
        // which is what lets `claimSlug` borrow it as a map key.
        const claimed = try claimSlug(scratch, &seen, base);
        const id_owned = try arena_alloc.dupe(u8, claimed);

        if (existing) |d| {
            // Mutate the EXISTING directive pointer (e.g. one carrying only
            // `.attrs`) rather than replacing it — a fresh directive would
            // clobber those other fields.
            d.id = id_owned;
        } else {
            var directive: supermd.Directive = .{
                .id = id_owned,
                .kind = .{ .heading = .{} },
            };
            _ = try ev.node.setDirective(arena_alloc, &directive, true);
        }
        try ast.ids.put(arena_alloc, id_owned, ev.node);
    }

    if (ast.errors.len == 0) return;
    var resolved: std.AutoHashMapUnmanaged(supermd.Range, void) = .empty;
    var links = supermd.Ast.Iter.init(ast.md.root);
    defer links.deinit();
    while (links.next()) |ev| {
        if (ev.dir != .enter) continue;
        const d = ev.node.getDirective() orelse continue;
        if (d.kind != .link) continue;
        const link = d.kind.link;
        const source = link.src orelse continue;
        if (source != .self_page or link.ref_unsafe) continue;
        const ref = link.ref orelse continue;
        if (ast.ids.contains(ref)) try resolved.put(scratch, ev.node.range(), {});
    }
    // Ast.init owns mutable arena storage behind this read-only public slice.
    // Compact it in place; the arena, not the shortened slice, owns the bytes.
    const errors = @constCast(ast.errors);
    var count: usize = 0;
    for (ast.errors) |err| {
        if (err.kind == .invalid_ref and resolved.contains(err.main)) continue;
        errors[count] = err;
        count += 1;
    }
    ast.errors = errors[0..count];
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "apply: link.ref accepts generated ids but retains missing refs" {
    const gpa = std.testing.allocator;
    var ast = try parseTestAst(gpa,
        \\# Hello World
        \\
        \\[valid]($link.ref('hello-world'))
        \\
        \\[missing]($link.ref('absent'))
        \\
    );
    defer ast.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), ast.errors.len);
    const missing = for (ast.errors) |err| {
        if (err.main.start.row == 5) break err;
    } else return error.TestUnexpectedResult;
    const errors_ptr = ast.errors.ptr;
    try apply(gpa, &ast);
    try std.testing.expectEqual(@as(usize, 1), ast.errors.len);
    try std.testing.expectEqualDeep(missing, ast.errors[0]);
    try std.testing.expectEqual(errors_ptr, ast.errors.ptr);
}

test "apply: same-line resolved and missing refs retain distinct ranges" {
    const gpa = std.testing.allocator;
    var ast = try parseTestAst(gpa,
        \\# Hello World
        \\
        \\[a]($link.ref('hello-world')) [b]($link.ref('absent'))
    );
    defer ast.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), ast.errors.len);
    // The second link starts later on the same row; row alone cannot identify it.
    const missing = for (ast.errors) |err| {
        if (err.main.start.col > 1) break err;
    } else return error.TestUnexpectedResult;
    try apply(gpa, &ast);
    try std.testing.expectEqual(@as(usize, 1), ast.errors.len);
    try std.testing.expectEqualDeep(missing, ast.errors[0]);
}

fn parseTestAst(gpa: Allocator, src: []const u8) !supermd.Ast {
    supermd.c.cmark_gfm_core_extensions_ensure_registered();
    const cmark = supermd.Ast.CmarkParser.default();
    defer supermd.c.cmark_parser_free(cmark.parser);
    return supermd.Ast.init(gpa, src, cmark);
}

test "slugify: em-dash flanked by spaces produces GitHub's double hyphen" {
    const gpa = std.testing.allocator;
    const slug = try slugify(gpa, "Calling the backend — apiFetch");
    defer gpa.free(slug);
    try std.testing.expectEqualStrings("calling-the-backend--apifetch", slug);
}

test "slugify: leading and trailing whitespace is trimmed, not hyphenated" {
    const gpa = std.testing.allocator;
    const slug = try slugify(gpa, "  Hello World  \n");
    defer gpa.free(slug);
    try std.testing.expectEqualStrings("hello-world", slug);
}

test "slugify: punctuation-only heading text slugifies to empty" {
    const gpa = std.testing.allocator;
    const slug = try slugify(gpa, "!!!");
    defer gpa.free(slug);
    try std.testing.expectEqualStrings("", slug);
}

test "slugify: non-ascii letters are kept, only ascii case folds" {
    const gpa = std.testing.allocator;
    const slug = try slugify(gpa, "Café");
    defer gpa.free(slug);
    try std.testing.expectEqualStrings("café", slug);
}

test "slugify: invalid UTF-8 bytes are skipped, not a crash" {
    const gpa = std.testing.allocator;
    const slug = try slugify(gpa, "ab\xffcd");
    defer gpa.free(slug);
    try std.testing.expectEqualStrings("abcd", slug);
}

test "slugify: underscore and hyphen survive verbatim" {
    const gpa = std.testing.allocator;
    const slug = try slugify(gpa, "snake_case-kebab");
    defer gpa.free(slug);
    try std.testing.expectEqualStrings("snake_case-kebab", slug);
}

test "apply: duplicate headings get -1 / -2 suffixes" {
    const gpa = std.testing.allocator;
    var ast = try parseTestAst(gpa,
        \\# Foo
        \\
        \\# Foo
        \\
        \\# Foo
        \\
    );
    defer ast.deinit(gpa);

    try apply(gpa, &ast);

    try std.testing.expect(ast.ids.contains("foo"));
    try std.testing.expect(ast.ids.contains("foo-1"));
    try std.testing.expect(ast.ids.contains("foo-2"));
}

test "apply: explicit heading.id is seeded and never overwritten" {
    const gpa = std.testing.allocator;
    var ast = try parseTestAst(gpa,
        \\# []($heading.id('foo')) Explicit
        \\
        \\# Foo
        \\
    );
    defer ast.deinit(gpa);

    try apply(gpa, &ast);

    // The explicit id survives, and the auto-generated duplicate is bumped
    // rather than colliding with (or replacing) it.
    try std.testing.expect(ast.ids.contains("foo"));
    try std.testing.expect(ast.ids.contains("foo-1"));
}

test "apply: empty slug injects no id" {
    const gpa = std.testing.allocator;
    var ast = try parseTestAst(gpa,
        \\# !!!
        \\
    );
    defer ast.deinit(gpa);

    const before = ast.ids.count();
    try apply(gpa, &ast);
    try std.testing.expectEqual(before, ast.ids.count());
}

test "apply: unicode heading text slugifies with letters kept" {
    const gpa = std.testing.allocator;
    var ast = try parseTestAst(gpa,
        \\# Café
        \\
    );
    defer ast.deinit(gpa);

    try apply(gpa, &ast);

    try std.testing.expect(ast.ids.contains("café"));
}
