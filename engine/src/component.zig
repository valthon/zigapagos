const std = @import("std");
const vdom = @import("vdom.zig");
const backend = @import("backend.zig");
const RecordingBackend = @import("recording_backend.zig").RecordingBackend;
const reconciler = @import("reconciler.zig");

/// Deep-copy a VNode into `arena` so that slices (children, attrs) live in
/// the arena rather than on the render function's stack frame, which would
/// become dangling after render() returns.
fn copyVNode(arena: std.mem.Allocator, node: vdom.VNode) std.mem.Allocator.Error!vdom.VNode {
    switch (node) {
        .text => return node, // text is a literal or arena-allocated string — safe as-is
        .fragment => |children| {
            const new_children = try arena.alloc(vdom.VNode, children.len);
            for (children, 0..) |child, i| {
                new_children[i] = try copyVNode(arena, child);
            }
            return .{ .fragment = new_children };
        },
        .element => |el| {
            const new_children = try arena.alloc(vdom.VNode, el.children.len);
            for (el.children, 0..) |child, i| {
                new_children[i] = try copyVNode(arena, child);
            }
            const new_attrs = try arena.dupe(vdom.Attr, el.attrs);
            return .{ .element = .{
                .tag = el.tag,
                .key = el.key,
                .attrs = new_attrs,
                .children = new_children,
            } };
        },
    }
}

pub fn Component(comptime Impl: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        impl_state: Impl,
        backend_: backend.Backend = undefined,
        parent: backend.Handle = backend.null_handle,
        // persistent: holds the Mounted tree and children lists for the whole
        // component lifetime. Passed as the arena to reconcile(). Never reset
        // during update — only freed in deinit().
        // TODO(islands): persistent arena does not reclaim dropped Mounted nodes — see KNOWN_LIMITATIONS.md
        persistent: std.heap.ArenaAllocator,
        // render_arenas: double buffer for per-render VNode trees (Z allocations
        // + copyVNode output). render_arenas[cur] holds the CURRENT render's
        // VNode memory (borrowed by the live Mounted tree via attrs/text slices).
        // render_arenas[1-cur] is the PREVIOUS render's arena, reset at the end
        // of the previous update and ready for the next render.
        render_arenas: [2]std.heap.ArenaAllocator,
        cur: usize = 0,
        tree: ?*reconciler.Mounted = null,

        pub fn init(gpa: std.mem.Allocator, props: Impl.Props) Self {
            return .{
                .gpa = gpa,
                .impl_state = Impl.init(props),
                .persistent = std.heap.ArenaAllocator.init(gpa),
                .render_arenas = .{
                    std.heap.ArenaAllocator.init(gpa),
                    std.heap.ArenaAllocator.init(gpa),
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.persistent.deinit();
            self.render_arenas[0].deinit();
            self.render_arenas[1].deinit();
        }

        pub fn impl(self: *Self) *Impl {
            return &self.impl_state;
        }

        pub fn mount(self: *Self, b: backend.Backend, parent: backend.Handle) !void {
            self.backend_ = b;
            self.parent = parent;
            const render_alloc = self.render_arenas[self.cur].allocator();
            var z = vdom.Z.init(render_alloc);
            // render() may return a VNode whose children slice is on render's stack.
            // Deep-copy it into the render arena so it outlives the render call.
            const vnode = try copyVNode(render_alloc, self.impl_state.render(&z));
            // Mounted structs and children lists are allocated from persistent.
            self.tree = try reconciler.reconcile(
                self.persistent.allocator(),
                b,
                parent,
                null,
                vnode,
                backend.null_handle,
            );
        }

        pub fn update(self: *Self) !void {
            std.debug.assert(self.tree != null);
            // Render into the OTHER render arena (the one that was reset at the
            // end of the previous update — so it's fresh).
            const next = 1 - self.cur;
            const render_alloc = self.render_arenas[next].allocator();
            var z = vdom.Z.init(render_alloc);
            // Deep-copy ensures the VNode tree is fully arena-owned (no dangling
            // stack refs).
            const vnode = try copyVNode(render_alloc, self.impl_state.render(&z));
            // reconcile allocates new Mounted structs into persistent (which is
            // never reset). For reused nodes it patches in place and borrows slices
            // from the new VNode (render_arenas[next]).
            self.tree = try reconciler.reconcile(
                self.persistent.allocator(),
                self.backend_,
                self.parent,
                self.tree,
                vnode,
                backend.null_handle,
            );
            // Now that reconcile is done, render_arenas[cur] (the PREVIOUS render's
            // VNode memory) is no longer borrowed by anyone: the Mounted tree now
            // borrows render_arenas[next]. Safe to reset.
            _ = self.render_arenas[self.cur].reset(.retain_capacity);
            self.cur = next;
        }
    };
}

test "mount then update produces minimal patch (only the text changes)" {
    const Counter = struct {
        pub const Props = struct { start: i64 = 0 };
        count: i64,
        pub fn init(p: @This().Props) @This() {
            return .{ .count = p.start };
        }
        pub fn render(self: *@This(), z: *vdom.Z) vdom.VNode {
            return z.el("button", &.{}, &.{ z.text("count: "), z.int(self.count) });
        }
    };

    const a = std.testing.allocator;
    var rec = RecordingBackend.init(a);
    defer rec.deinit();

    var c = Component(Counter).init(a, .{ .start = 1 });
    defer c.deinit();

    try c.mount(rec.backend(), 100);
    // mount: create button(1), create_text "count: "(2), append, create_text "1"(3), append, append button
    try std.testing.expect(rec.ops.items.len > 0);
    rec.ops.clearRetainingCapacity();

    c.impl().count = 2;
    try c.update();

    // only the integer text node changes -> exactly one set_text "2"
    try std.testing.expectEqual(@as(usize, 1), rec.ops.items.len);
    try std.testing.expectEqualStrings("2", rec.ops.items[0].set_text.data);
}

test "multiple sequential updates produce correct minimal patches (lifetime regression)" {
    const Counter = struct {
        pub const Props = struct { start: i64 = 0 };
        count: i64,
        pub fn init(p: @This().Props) @This() {
            return .{ .count = p.start };
        }
        pub fn render(self: *@This(), z: *vdom.Z) vdom.VNode {
            return z.el("button", &.{}, &.{ z.text("count: "), z.int(self.count) });
        }
    };

    const a = std.testing.allocator;
    var rec = RecordingBackend.init(a);
    defer rec.deinit();

    var c = Component(Counter).init(a, .{ .start = 1 });
    defer c.deinit();

    try c.mount(rec.backend(), 100);
    try std.testing.expect(rec.ops.items.len > 0);
    rec.ops.clearRetainingCapacity();

    // Update 1: count 1 -> 2
    c.impl().count = 2;
    try c.update();
    try std.testing.expectEqual(@as(usize, 1), rec.ops.items.len);
    try std.testing.expectEqualStrings("2", rec.ops.items[0].set_text.data);
    rec.ops.clearRetainingCapacity();

    // Update 2: count 2 -> 3  (this is the one the old design would get wrong)
    c.impl().count = 3;
    try c.update();
    try std.testing.expectEqual(@as(usize, 1), rec.ops.items.len);
    try std.testing.expectEqualStrings("3", rec.ops.items[0].set_text.data);
    rec.ops.clearRetainingCapacity();

    // Update 3: count 3 -> 10
    c.impl().count = 10;
    try c.update();
    try std.testing.expectEqual(@as(usize, 1), rec.ops.items.len);
    try std.testing.expectEqualStrings("10", rec.ops.items[0].set_text.data);
}
