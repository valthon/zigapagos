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
