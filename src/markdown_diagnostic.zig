//! SuperMD wording with bounded primary and related-source previews.
//! The dependency's Error.fmt calls unchecked linePreview/Range.span and
//! passes "test" as the HTML source; neither is safe for container ranges.
const std = @import("std");
const supermd = @import("supermd");
const diag = @import("diag.zig");
const Diagnostic = @This();

err: supermd.Ast.Error,
src: []const u8,
path: []const u8,
fm_lines: usize,
html_src: []const u8 = "",

pub fn preview(d: Diagnostic) diag.MarkdownPreview {
    return .init(d.src, d.err.main, d.err.kind != .html);
}

pub fn range(d: Diagnostic) supermd.Range {
    const p = d.preview();
    var result = d.err.main;
    result.start = .{ .row = @intCast(p.row), .col = @intCast(p.col) };
    return result;
}

pub fn format(d: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const p = d.preview();
    try w.print("{s}:{}:{}: ", .{ d.path, d.fm_lines + p.row, p.col });
    switch (d.err.kind) {
        .scripty => |sy| try w.print("[scripty] {s}", .{sy.err}),
        .html => |h| {
            try w.writeAll("[html] error: ");
            switch (h.tag) {
                .invalid_nesting => |nest| {
                    // HTML locations index the container-stripped fence literal,
                    // not the Markdown source. Never slice an unchecked Loc.
                    const start = @min(nest.loc.start, d.html_src.len);
                    const end = std.math.clamp(nest.loc.end, start, d.html_src.len);
                    try w.writeAll("invalid nesting");
                    if (end > start) try w.print(" under <{s}>", .{d.html_src[start..end]});
                    if (nest.reason.len > 0) try w.print(": {s}", .{nest.reason});
                },
                else => try w.print("{f}", .{h.tag.fmt(d.html_src)}),
            }
        },
        .duplicate_id => |dup| try w.print("error: duplicate id '{s}'", .{dup.id}),
        .inline_html => try w.writeAll("error: markdown inline html syntax is forbidden"),
        .heading_link_sibling => try w.writeAll("error: block/section heading with text outside of inner link"),
        .heading_section_missing_id => try w.writeAll("error: missing section id"),
        .invalid_ref => try w.writeAll("error: unknown ref"),
        .no_alt_in_links => try w.writeAll("error: vanilla alt text in scripted link syntax"),
        .expression_in_image_syntax => try w.writeAll("error: scripty expression in image syntax"),
        .empty_expression => try w.writeAll("error: link syntax without link or scripty expression"),
        .heading_skip => try w.writeAll("error: skipped heading level"),
    }
    try w.print("\n{f}\n", .{p});
    switch (d.err.kind) {
        .duplicate_id => |dup| {
            const original = diag.MarkdownPreview.init(d.src, dup.original.range(), true);
            try w.print("| -- note: first definition was on line {} col {}:\n{f}\n", .{
                d.fm_lines + original.row, original.col, original,
            });
        },
        .heading_skip => |gap| {
            if (gap.last) |last| {
                const previous = diag.MarkdownPreview.init(d.src, last.range(), true);
                try w.print("| -- note: previous heading (level {}):\n{f}\n", .{ last.headingLevel(), previous });
            } else {
                try w.writeAll(
                    "| -- note: supermd documents start at heading level 1 ('#')\n" ++
                        "| -- note: if your intent is to start the content at '<h2>', you\n" ++
                        "|          can change how headings render in html in zigapagos.ziggy\n",
                );
            }
        },
        .inline_html => try w.writeAll("| -- note: superhtml supports `=html` code blocks as an alternative\n"),
        .heading_link_sibling => try w.writeAll("| -- note: all text must be inside the inner link\n"),
        .heading_section_missing_id => try w.writeAll("| -- note: all heading sections must have an id\n"),
        .no_alt_in_links => try w.writeAll("| -- note: use `.alt()` to provide alt text\n"),
        .expression_in_image_syntax => try w.writeAll("| -- note: scripty expressions go in link syntax, remove the '!'\n"),
        .scripty, .html, .invalid_ref, .empty_expression => {},
    }
}

/// Caller-buffer lookup: borrow the original fence literal for HTML tag
/// explanations whose related locations refer to it, not to Markdown bytes.
pub fn htmlSource(ast: *const supermd.Ast, err: supermd.Ast.Error) []const u8 {
    if (err.kind != .html or err.kind.html.tag != .invalid_nesting) return "";
    var current = ast.md.root.firstChild();
    while (current) |node| : (current = nextNode(node, ast.md.root)) {
        if (node.nodeType() != .CODE_BLOCK) continue;
        const fence = node.fenceInfo() orelse continue;
        if (!std.mem.startsWith(u8, fence, "=html")) continue;
        const block_range = node.range();
        if (err.main.start.row >= block_range.start.row and err.main.start.row <= block_range.end.row +| 1)
            return node.literal() orelse "";
    }
    return "";
}

// Iterative traversal avoids a new allocation or recursion in diagnostics.
fn nextNode(node: supermd.Node, root: supermd.Node) ?supermd.Node {
    if (node.firstChild()) |child| return child;
    var cursor = node;
    while (cursor.n != root.n) {
        if (cursor.nextSibling()) |sibling| return sibling;
        cursor = cursor.parent() orelse return null;
    }
    return null;
}

test "validate: every Markdown diagnostic bounds primary and related ranges" {
    const gpa = std.testing.allocator;
    supermd.c.cmark_gfm_core_extensions_ensure_registered();
    const cmark = supermd.Ast.CmarkParser.default();
    defer supermd.c.cmark_parser_free(cmark.parser);
    const ast = try supermd.Ast.init(gpa, "\n\n# First\n\n[original]($text.id('same'))\n", cmark, .{});
    defer ast.deinit(gpa);
    const original = ast.ids.get("same").?;
    const first = ast.md.root.firstChild().?;
    const kinds: []const supermd.Ast.Error.Kind = &.{
        .inline_html,
        .heading_link_sibling,
        .heading_section_missing_id,
        .invalid_ref,
        .no_alt_in_links,
        .expression_in_image_syntax,
        .empty_expression,
        .{ .duplicate_id = .{ .id = "same", .original = original } },
        .{ .scripty = .{ .len = 0, .span = .{ .start = 999, .end = 0 }, .err = "bad expression" } },
        .{ .html = .{ .tag = .invalid_html_tag_name, .node_idx = 0, .main_location = .{ .start = 0, .end = 0 } } },
        .{ .heading_skip = .{ .have = 3, .last = first } },
    };
    // Adding a dependency error kind must extend this coverage table too.
    try std.testing.expectEqual(@typeInfo(supermd.Ast.Error.Kind).@"union".field_names.len, kinds.len);
    const max = std.math.maxInt(u32);
    const ranges: []const supermd.Range = &.{
        .{ .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .{ .start = .{ .row = 1, .col = 1 }, .end = .{ .row = 1, .col = max } },
        .{ .start = .{ .row = 1, .col = max }, .end = .{ .row = 1, .col = 0 } },
        .{ .start = .{ .row = 1, .col = 1 }, .end = .{ .row = max, .col = 0 } },
        .{ .start = .{ .row = max, .col = max }, .end = .{ .row = 0, .col = 0 } },
    };
    for (kinds) |kind| {
        for (ranges) |main| {
            // Empty/whitespace lines, indentation exceeding visible text,
            // truncated input and EOF without a newline exercise every kind.
            for ([_][]const u8{ "", "\n", "    \n   ", "    > x", "x", "first\nlast" }) |src| {
                const d: Diagnostic = .{ .err = .{ .kind = kind, .main = main }, .src = src, .path = "index.smd", .fm_lines = 4 };
                const rendered = try std.fmt.allocPrint(gpa, "{f}", .{d});
                defer gpa.free(rendered);
                try std.testing.expect(rendered.len < 4096);
                const p = d.preview();
                try std.testing.expect(p.row >= 1 and p.row <= std.mem.count(u8, src, "\n") + 1);
                try std.testing.expect(p.col >= 1 and p.carets >= 1 and p.spaces + p.carets <= 1024);
            }
        }
    }
    const long_line: [4096]u8 = @splat('x');
    const long: Diagnostic = .{
        .err = .{ .main = ranges[2], .kind = .invalid_ref },
        .src = &long_line,
        .path = "index.smd",
        .fm_lines = 4,
    };
    try std.testing.expectEqual(4096, long.preview().col);
    try std.testing.expectEqual(1024, long.preview().spaces + long.preview().carets);
    const baseline: @import("context/Page.zig").HeadingBaselineError = .{ .heading = first, .first = first };
    for ([_][]const u8{ "", "    \n", "last" }) |src| {
        const text = try std.fmt.allocPrint(gpa, "{f}", .{baseline.fmt(4, src, "index.smd")});
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "first heading") != null);
    }
    const nesting: Diagnostic = .{
        .err = .{ .main = ranges[0], .kind = .{ .html = .{
            .tag = .{ .invalid_nesting = .{ .loc = .{ .start = max, .end = 0 }, .reason = "bad nesting" } },
            .main_location = .{ .start = 0, .end = max },
            .node_idx = 0,
        } } },
        .src = "",
        .html_src = "<span>",
        .path = "index.smd",
        .fm_lines = 4,
    };
    const rendered = try std.fmt.allocPrint(gpa, "{f}", .{nesting});
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "invalid nesting: bad nesting") != null);
    const no_previous: Diagnostic = .{
        .err = .{ .main = ranges[4], .kind = .{ .heading_skip = .{ .have = 3, .last = null } } },
        .src = "",
        .path = "index.smd",
        .fm_lines = 4,
    };
    const heading = try std.fmt.allocPrint(gpa, "{f}", .{no_previous});
    defer gpa.free(heading);
    try std.testing.expect(std.mem.indexOf(u8, heading, "start at heading level 1") != null);
}
