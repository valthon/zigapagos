const Template = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const superhtml = @import("superhtml");
const tracy = @import("tracy");
const root = @import("root.zig");
const fatal = @import("fatal.zig");
const worker = @import("worker.zig");
const Build = @import("Build.zig");
const StringTable = @import("StringTable.zig");
const String = StringTable.String;
const PathTable = @import("PathTable.zig");
const Path = PathTable.Path;
const PathName = PathTable.PathName;

src: []const u8 = undefined,
html_ast: superhtml.html.Ast = undefined,
// Only present if html_ast.errors.len == 0
ast: superhtml.Ast = undefined,
missing_parent: bool = false,
layout: bool,

pub fn deinit(t: *const Template, gpa: Allocator) void {
    gpa.free(t.src);
    t.html_ast.deinit(gpa);
    if (t.html_ast.errors.len == 0) t.ast.deinit(gpa);
}

/// An attribute whose name starts with `:` but is not a recognized directive —
/// the silent footgun where `:src="$expr"` (instead of the bare `src="$expr"`)
/// builds without error yet emits a literal `:src` attribute, so the real `src`
/// is never set and the asset silently breaks.
pub const BadDirectiveAttr = struct {
    /// The offending attribute name, e.g. ":src".
    name: []const u8,
    /// Byte offset of the attribute name in `Template.src` (for line/col).
    offset: usize,
};

fn isKnownDirective(name: []const u8) bool {
    // SuperHTML's `:` directives plus the Zigapagos `<island :props=...>` one.
    const known = [_][]const u8{ ":if", ":loop", ":else", ":text", ":html", ":props" };
    for (known) |k| if (std.mem.eql(u8, name, k)) return true;
    return false;
}

/// Scan the template for `:`-prefixed attributes that are not recognized
/// directives and append each to `out`. Only meaningful on a well-formed tree
/// (`html_ast.errors.len == 0`); the caller guards on that.
pub fn lintDirectiveAttrs(
    t: *const Template,
    gpa: Allocator,
    out: *std.ArrayListUnmanaged(BadDirectiveAttr),
) Allocator.Error!void {
    for (t.html_ast.nodes) |node| {
        if (!node.kind.isElement()) continue;
        var it = node.startTagIterator(t.src, t.html_ast.language);
        while (it.next(t.src)) |attr| {
            const name = attr.name.slice(t.src);
            if (name.len < 2 or name[0] != ':') continue;
            if (isKnownDirective(name)) continue;
            try out.append(gpa, .{ .name = name, .offset = attr.name.start });
        }
    }
}

/// A `:` directive that SuperHTML accepts at parse time and then either never
/// evaluates or evaluates into corrupt output. Both variants are fatal because
/// no correct program can contain them (see the per-kind notes).
pub const InertDirective = struct {
    kind: Kind,
    /// The offending attribute name, ":else" / ":if" / ":loop".
    /// Borrows `Template.src`.
    name: []const u8,
    /// The element's tag name, e.g. "img". Borrows `Template.src`.
    tag: []const u8,
    /// True when the element is an HTML void element, false when it is an
    /// `.xml` self-closing element. Only meaningful for
    /// `.branching_without_end_tag`; it selects one clause of the message.
    void_element: bool,
    /// Byte offset of the attribute name in `Template.src` (for line/col).
    offset: usize,

    pub const Kind = enum {
        /// `:else` — parse-validated by SuperHTML (it must be the first
        /// attribute and must be value-less) and then NEVER read at render
        /// time: the semantic switch has `.@":else" => unreachable` and the
        /// evaluator has no case for it, so it falls through to the shared
        /// special-attribute path, which does `attr.value.?` on a directive
        /// that is mandatorily value-less. That is a null unwrap: it panics
        /// the renderer in a debug build and is safety-off UB in a release
        /// build. No template using `:else` has ever rendered.
        else_directive,
        /// `:if` / `:loop` on an element with no end tag (an HTML void
        /// element, or a self-closing element in an `.xml` layout).
        /// SuperHTML's skip_body path sets `print_cursor = elem.close.start`,
        /// which is 0 for such an element: the renderer rewinds to byte 0 and
        /// re-emits the whole template source into the page with exit code 0
        /// (falsy `:if`, empty `:loop`), or slices backwards and panics
        /// (non-empty `:loop`). The only non-broken outcome — a truthy `:if` —
        /// is byte-identical to omitting the directive, so the rule has no
        /// false positives.
        branching_without_end_tag,
    };
};

/// Scan the template for `:` directives that SuperHTML parses and then cannot
/// honour, appending each to `out`. Only meaningful on a well-formed tree
/// (`html_ast.errors.len == 0`); the caller guards on that, and the guard is
/// load-bearing: on a broken tree `close.start == 0` also means "unclosed
/// element", which SuperHTML already reports as `missing end tag`.
///
/// NO_SLOP §2.2a contract 2 (owned-result): the only allocation is growth of
/// `out`, which the caller owns and deinits. `name` and `tag` borrow
/// `Template.src` and are never freed.
pub fn lintInertDirectives(
    t: *const Template,
    gpa: Allocator,
    out: *std.ArrayListUnmanaged(InertDirective),
) Allocator.Error!void {
    for (t.html_ast.nodes) |node| {
        if (!node.kind.isElement()) continue;
        // <extend> and <super> are void nodes that already reject every stray
        // attribute in SuperHTML's own analysis (`super_wants_no_attributes`),
        // so linting them would only add a second, worse-worded message.
        if (node.kind == .extend or node.kind == .super) continue;

        var it = node.startTagIterator(t.src, t.html_ast.language);
        const tag = it.name_span.slice(t.src);
        // This is *literally* the value the buggy renderer reads. Do not
        // substitute `node.kind.isVoid()`: that misses the `.xml`
        // self-closing case, which corrupts output the same way.
        const no_end_tag = node.close.start == 0;

        while (it.next(t.src)) |attr| {
            const name = attr.name.slice(t.src);
            if (std.mem.eql(u8, name, ":else")) {
                try out.append(gpa, .{
                    .kind = .else_directive,
                    .name = name,
                    .tag = tag,
                    .void_element = false,
                    .offset = attr.name.start,
                });
            } else if (no_end_tag and (std.mem.eql(u8, name, ":if") or
                std.mem.eql(u8, name, ":loop")))
            {
                try out.append(gpa, .{
                    .kind = .branching_without_end_tag,
                    .name = name,
                    .tag = tag,
                    .void_element = node.kind.isVoid(),
                    .offset = attr.name.start,
                });
            }
        }
    }
}

pub const LineCol = struct { line: usize, col: usize };

/// 1-based line and byte-column of `offset` within `src`.
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing.
pub fn lineCol(src: []const u8, offset: usize) LineCol {
    var line: usize = 1;
    var col: usize = 1;
    for (src[0..offset]) |ch| {
        if (ch == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .col = col };
}

pub fn parse(
    t: *Template,
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    build: *const Build,
    pn: PathName,
) void {
    const zone = tracy.trace(@src());
    defer zone.end();

    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    const path = try std.fmt.allocPrint(arena, "{f}", .{
        pn.fmt(&build.st, &build.pt, null, "/"),
    });

    const max = std.math.maxInt(u32);
    const src = build.layouts_dir.readFileAlloc(
        io,
        path,
        gpa,
        .limited(max),
    ) catch |err| fatal.file(path, err);

    t.src = src;

    t.html_ast = try .init(
        gpa,
        src,
        if (std.mem.endsWith(u8, path, ".xml")) .xml else .superhtml,
        false,
    );
    if (t.html_ast.errors.len > 0) return;

    t.ast = try .init(gpa, t.html_ast, src);

    if (t.ast.errors.len == 0 and t.ast.extends_idx != 0) {
        const parent_name = t.ast.nodes[t.ast.extends_idx].templateValue().span.slice(src);
        const parent_path = try root.join(arena, &.{ "templates", parent_name }, '/');
        const parent_pn = PathName.get(&build.st, &build.pt, parent_path) orelse {
            t.missing_parent = true;
            return;
        };
        if (!build.templates.contains(parent_pn)) {
            t.missing_parent = true;
            return;
        }
    }
}

// The lint tests below build a `Template` by hand: `lintInertDirectives` reads
// only `src` and `html_ast`, so `ast` (the semantic tree) is never touched and
// `parse` -- which needs a Build, an Io and a layouts dir -- is not involved.
// `std.testing.allocator` is used directly: wrapping it in an ArenaAllocator
// would disable Zig's leak detector and require a row in
// scripts/allocator-allowlist.txt.

/// NO_SLOP §2.2a contract 2 (owned-result): the returned Ast owns its nodes and
/// the caller deinits it.
fn testAst(
    gpa: Allocator,
    src: []const u8,
    language: superhtml.Language,
) !superhtml.html.Ast {
    const html_ast: superhtml.html.Ast = try .init(gpa, src, language, false);
    errdefer {
        var a = html_ast;
        a.deinit(gpa);
    }
    // A dirty tree makes `close.start == 0` ambiguous (there it also means
    // "unclosed element"), which is exactly why the production caller guards on
    // this. Assert it so a fixture that stops being well-formed fails loudly
    // instead of silently changing what the test proves.
    try std.testing.expectEqual(@as(usize, 0), html_ast.errors.len);
    return html_ast;
}

test "lintInertDirectives flags :else on an element and on <ctx>" {
    const gpa = std.testing.allocator;
    const src =
        \\<div>
        \\  <ctx :if="$page.title">A</ctx>
        \\  <div :else>B</div>
        \\  <ctx :else>C</ctx>
        \\</div>
    ;
    var html_ast = try testAst(gpa, src, .superhtml);
    defer html_ast.deinit(gpa);

    const t: Template = .{ .src = src, .html_ast = html_ast, .layout = true };
    var out: std.ArrayListUnmanaged(InertDirective) = .empty;
    defer out.deinit(gpa);
    try t.lintInertDirectives(gpa, &out);

    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(InertDirective.Kind.else_directive, out.items[0].kind);
    try std.testing.expectEqualStrings("div", out.items[0].tag);
    try std.testing.expectEqual(InertDirective.Kind.else_directive, out.items[1].kind);
    try std.testing.expectEqualStrings("ctx", out.items[1].tag);
}

test "lintInertDirectives flags :if on a void element" {
    const gpa = std.testing.allocator;
    const src =
        \\<div><img src="/a.png" :if="$page.title"></div>
    ;
    var html_ast = try testAst(gpa, src, .superhtml);
    defer html_ast.deinit(gpa);

    const t: Template = .{ .src = src, .html_ast = html_ast, .layout = true };
    var out: std.ArrayListUnmanaged(InertDirective) = .empty;
    defer out.deinit(gpa);
    try t.lintInertDirectives(gpa, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(
        InertDirective.Kind.branching_without_end_tag,
        out.items[0].kind,
    );
    try std.testing.expectEqualStrings(":if", out.items[0].name);
    try std.testing.expectEqualStrings("img", out.items[0].tag);
    try std.testing.expect(out.items[0].void_element);
}

test "lintInertDirectives flags :loop on a void element" {
    const gpa = std.testing.allocator;
    const src =
        \\<div><br :loop="$page.subpages()"></div>
    ;
    var html_ast = try testAst(gpa, src, .superhtml);
    defer html_ast.deinit(gpa);

    const t: Template = .{ .src = src, .html_ast = html_ast, .layout = true };
    var out: std.ArrayListUnmanaged(InertDirective) = .empty;
    defer out.deinit(gpa);
    try t.lintInertDirectives(gpa, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(
        InertDirective.Kind.branching_without_end_tag,
        out.items[0].kind,
    );
    try std.testing.expectEqualStrings(":loop", out.items[0].name);
    try std.testing.expectEqualStrings("br", out.items[0].tag);
    try std.testing.expect(out.items[0].void_element);
}

test "lintInertDirectives flags :if on an XML self-closing element" {
    // The `.xml` arm is why the lint keys off `close.start == 0` rather than
    // `kind.isVoid()`: a self-closing <item/> in an alternative feed layout is
    // not a void element but has no end tag either, and corrupts the emitted
    // feed.xml the same way. SuperHTML rejects self-closing tags outright in
    // `.superhtml`, so this shape only ever reaches an `.xml` layout -- which
    // makes this the ONLY coverage for that arm.
    const gpa = std.testing.allocator;
    const src =
        \\<rss><channel><item :if="$page.title"/></channel></rss>
    ;
    var html_ast = try testAst(gpa, src, .xml);
    defer html_ast.deinit(gpa);

    const t: Template = .{ .src = src, .html_ast = html_ast, .layout = true };
    var out: std.ArrayListUnmanaged(InertDirective) = .empty;
    defer out.deinit(gpa);
    try t.lintInertDirectives(gpa, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(
        InertDirective.Kind.branching_without_end_tag,
        out.items[0].kind,
    );
    try std.testing.expectEqualStrings("item", out.items[0].tag);
    try std.testing.expect(!out.items[0].void_element);
}

test "lintInertDirectives ignores :if and :loop on a closed element" {
    // `<div :if="$x">body</div>` is the legitimate keep-the-element /
    // conditional-body pattern, used by the `zigapagos init` scaffold
    // (src/cli/init/layouts/post.shtml) and by tests/rendering/multi. Linting
    // it would be a breaking change; this test pins that we do not.
    const gpa = std.testing.allocator;
    const src =
        \\<div :if="$page.prevPage?()">prev</div>
        \\<ul :loop="$page.subpages()"><li :text="$loop.it.title"></li></ul>
    ;
    var html_ast = try testAst(gpa, src, .superhtml);
    defer html_ast.deinit(gpa);

    const t: Template = .{ .src = src, .html_ast = html_ast, .layout = true };
    var out: std.ArrayListUnmanaged(InertDirective) = .empty;
    defer out.deinit(gpa);
    try t.lintInertDirectives(gpa, &out);

    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "lintInertDirectives ignores <extend> and <super>" {
    // Both are void nodes, so `close.start == 0` holds, but SuperHTML's own
    // analysis already rejects every stray attribute on them
    // (`super_wants_no_attributes`). Reporting them here would only produce a
    // second, worse-worded message for the same defect.
    const gpa = std.testing.allocator;
    const src =
        \\<extend template="base.shtml" :if="$page.title">
        \\<div id="content"><super :loop="$page.subpages()"></div>
    ;
    var html_ast = try testAst(gpa, src, .superhtml);
    defer html_ast.deinit(gpa);

    const t: Template = .{ .src = src, .html_ast = html_ast, .layout = true };
    var out: std.ArrayListUnmanaged(InertDirective) = .empty;
    defer out.deinit(gpa);
    try t.lintInertDirectives(gpa, &out);

    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "lineCol is 1-based over lines and byte columns" {
    const src = "ab\ncde\n";
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 1 }, lineCol(src, 0));
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 3 }, lineCol(src, 2));
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 1 }, lineCol(src, 3));
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 3 }, lineCol(src, 5));
    try std.testing.expectEqual(LineCol{ .line = 3, .col = 1 }, lineCol(src, 7));
}
