const std = @import("std");

pub const Handler = u32;

pub const Attr = struct {
    name: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        flag: bool,
        handler: Handler,
    };
};

pub const VNode = union(enum) {
    text: []const u8,
    element: Element,
    fragment: []const VNode,

    pub const Element = struct {
        tag: []const u8,
        key: ?[]const u8 = null,
        attrs: []const Attr = &.{},
        children: []const VNode = &.{},
    };
};

pub const Z = struct {
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) Z {
        return .{ .arena = arena };
    }

    pub fn el(self: *Z, tag: []const u8, attrs: []const Attr, children: []const VNode) VNode {
        _ = self;
        return .{ .element = .{ .tag = tag, .attrs = attrs, .children = children } };
    }

    pub fn elKeyed(self: *Z, tag: []const u8, key: []const u8, attrs: []const Attr, children: []const VNode) VNode {
        _ = self;
        return .{ .element = .{ .tag = tag, .key = key, .attrs = attrs, .children = children } };
    }

    pub fn text(self: *Z, s: []const u8) VNode {
        _ = self;
        return .{ .text = s };
    }

    pub fn int(self: *Z, n: i64) VNode {
        const s = std.fmt.allocPrint(self.arena, "{d}", .{n}) catch @panic("OOM in Z.int");
        return .{ .text = s };
    }

    pub fn fragment(self: *Z, children: []const VNode) VNode {
        _ = self;
        return .{ .fragment = children };
    }
};

test "build a small tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var z = Z.init(arena.allocator());

    const tree = z.el("div", &.{.{ .name = "class", .value = .{ .string = "card" } }}, &.{
        z.el("h1", &.{}, &.{z.text("Title")}),
        z.el("p", &.{}, &.{ z.text("count: "), z.int(42) }),
    });

    try std.testing.expectEqualStrings("div", tree.element.tag);
    try std.testing.expectEqual(@as(usize, 1), tree.element.attrs.len);
    try std.testing.expectEqualStrings("card", tree.element.attrs[0].value.string);
    try std.testing.expectEqual(@as(usize, 2), tree.element.children.len);
    try std.testing.expectEqualStrings("Title", tree.element.children[0].element.children[0].text);
    try std.testing.expectEqualStrings("42", tree.element.children[1].element.children[1].text);
}
