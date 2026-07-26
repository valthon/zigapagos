const std = @import("std");
const vdom = @import("vdom.zig");

test "render nested elements with escaping, void elements, fragments, handlers" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var z = vdom.Z.init(arena.allocator());

    const tree = z.el("div", &.{.{ .name = "class", .value = .{ .string = "a&b" } }}, &.{
        z.el("img", &.{.{ .name = "src", .value = .{ .string = "x.png" } }}, &.{}),
        z.el("p", &.{}, &.{z.text("1 < 2")}),
        z.el("button", &.{.{ .name = "onClick", .value = .{ .handler = 3 } }}, &.{z.text("go")}),
    });

    const html = try renderToString(a, tree);
    defer a.free(html);
    try std.testing.expectEqualStrings(
        "<div class=\"a&amp;b\"><img src=\"x.png\"><p>1 &lt; 2</p>" ++
            "<button data-z-on:click=\"3\">go</button></div>",
        html,
    );
}

test "flag=true renders bare attribute; flag=false is omitted" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var z = vdom.Z.init(arena.allocator());

    // flag=true: bare attribute present (e.g. <input disabled>)
    const with_flag = z.el("input", &.{.{ .name = "disabled", .value = .{ .flag = true } }}, &.{});
    const html_on = try renderToString(a, with_flag);
    defer a.free(html_on);
    try std.testing.expectEqualStrings("<input disabled>", html_on);

    // flag=false: attribute omitted entirely (e.g. <input>)
    const without_flag = z.el("input", &.{.{ .name = "disabled", .value = .{ .flag = false } }}, &.{});
    const html_off = try renderToString(a, without_flag);
    defer a.free(html_off);
    try std.testing.expectEqualStrings("<input>", html_off);
}

test "handler=0 is omitted; nonzero handler renders data-z-on attribute" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var z = vdom.Z.init(arena.allocator());

    // handler=0: no data-z-on attribute emitted
    const zero_handler = z.el("button", &.{.{ .name = "onClick", .value = .{ .handler = 0 } }}, &.{z.text("click")});
    const html_zero = try renderToString(a, zero_handler);
    defer a.free(html_zero);
    try std.testing.expectEqualStrings("<button>click</button>", html_zero);

    // handler=nonzero: data-z-on:event="id" rendered
    const nonzero_handler = z.el("button", &.{.{ .name = "onClick", .value = .{ .handler = 5 } }}, &.{z.text("click")});
    const html_nonzero = try renderToString(a, nonzero_handler);
    defer a.free(html_nonzero);
    try std.testing.expectEqualStrings("<button data-z-on:click=\"5\">click</button>", html_nonzero);
}

test "fragment has no wrapper" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var z = vdom.Z.init(arena.allocator());
    const frag = z.fragment(&.{ z.text("a"), z.el("b", &.{}, &.{z.text("c")}) });
    const html = try renderToString(a, frag);
    defer a.free(html);
    try std.testing.expectEqualStrings("a<b>c</b>", html);
}

const escape = @import("escape.zig");

pub fn renderToString(gpa: std.mem.Allocator, root: vdom.VNode) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeNode(&aw.writer, root);
    return gpa.dupe(u8, aw.written());
}

fn writeNode(w: *std.Io.Writer, node: vdom.VNode) !void {
    switch (node) {
        .text => |s| try escape.writeText(w, s),
        .fragment => |children| for (children) |c| try writeNode(w, c),
        .element => |el| {
            try w.writeByte('<');
            try w.writeAll(el.tag);
            for (el.attrs) |attr| try writeAttr(w, attr);
            try w.writeByte('>');
            if (isVoidElement(el.tag)) return;
            for (el.children) |c| try writeNode(w, c);
            try w.writeAll("</");
            try w.writeAll(el.tag);
            try w.writeByte('>');
        },
    }
}

fn writeAttr(w: *std.Io.Writer, attr: vdom.Attr) !void {
    switch (attr.value) {
        .string => |s| {
            try w.writeByte(' ');
            try w.writeAll(attr.name);
            try w.writeAll("=\"");
            try escape.writeAttr(w, s);
            try w.writeByte('"');
        },
        .flag => |on| if (on) {
            try w.writeByte(' ');
            try w.writeAll(attr.name);
        },
        .handler => |id| if (id != 0) {
            const event = eventName(attr.name);
            try w.writeAll(" data-z-on:");
            try w.writeAll(event);
            try w.print("=\"{d}\"", .{id});
        },
    }
}

/// "onClick" -> "click"; "onmouseover" -> "mouseover"; anything without an
/// "on"/"On" prefix is lowercased as-is.
fn eventName(name: []const u8) []const u8 {
    if (name.len > 2 and (name[0] == 'o' or name[0] == 'O') and (name[1] == 'n' or name[1] == 'N')) {
        return lowerAscii(name[2..]);
    }
    return lowerAscii(name);
}

var lower_buf: [64]u8 = undefined;
fn lowerAscii(s: []const u8) []const u8 {
    const n = @min(s.len, lower_buf.len);
    for (s[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    return lower_buf[0..n];
}

pub fn isVoidElement(tag: []const u8) bool {
    const voids = [_][]const u8{
        "area", "base", "br",   "col",   "embed",  "hr",    "img",  "input",
        "link", "meta", "source", "track", "wbr",
    };
    for (voids) |v| if (std.mem.eql(u8, v, tag)) return true;
    return false;
}
