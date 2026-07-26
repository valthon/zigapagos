const std = @import("std");
const backend_mod = @import("backend.zig");

pub const RecordingBackend = struct {
    gpa: std.mem.Allocator,
    ops: std.ArrayList(Op) = .empty,
    next: backend_mod.Handle = 0,

    pub const Op = union(enum) {
        create_element: struct { handle: backend_mod.Handle, tag: []const u8 },
        create_text: struct { handle: backend_mod.Handle, data: []const u8 },
        set_text: struct { node: backend_mod.Handle, data: []const u8 },
        set_attribute: struct { node: backend_mod.Handle, name: []const u8, value: []const u8 },
        remove_attribute: struct { node: backend_mod.Handle, name: []const u8 },
        append_child: struct { parent: backend_mod.Handle, child: backend_mod.Handle },
        insert_before: struct { parent: backend_mod.Handle, child: backend_mod.Handle, ref: backend_mod.Handle },
        remove_child: struct { parent: backend_mod.Handle, child: backend_mod.Handle },
    };

    pub fn init(gpa: std.mem.Allocator) RecordingBackend {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *RecordingBackend) void {
        self.ops.deinit(self.gpa);
    }
    pub fn backend(self: *RecordingBackend) backend_mod.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn record(self: *RecordingBackend, op: Op) void {
        self.ops.append(self.gpa, op) catch @panic("OOM in RecordingBackend");
    }
    fn alloc(self: *RecordingBackend) backend_mod.Handle {
        self.next += 1;
        return self.next;
    }

    fn createElement(ctx: *anyopaque, tag: []const u8) backend_mod.Handle {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx));
        const h = self.alloc();
        self.record(.{ .create_element = .{ .handle = h, .tag = tag } });
        return h;
    }
    fn createText(ctx: *anyopaque, data: []const u8) backend_mod.Handle {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx));
        const h = self.alloc();
        self.record(.{ .create_text = .{ .handle = h, .data = data } });
        return h;
    }
    fn setText(ctx: *anyopaque, node: backend_mod.Handle, data: []const u8) void {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx));
        self.record(.{ .set_text = .{ .node = node, .data = data } });
    }
    fn setAttribute(ctx: *anyopaque, node: backend_mod.Handle, name: []const u8, value: []const u8) void {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx));
        self.record(.{ .set_attribute = .{ .node = node, .name = name, .value = value } });
    }
    fn removeAttribute(ctx: *anyopaque, node: backend_mod.Handle, name: []const u8) void {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx));
        self.record(.{ .remove_attribute = .{ .node = node, .name = name } });
    }
    fn appendChild(ctx: *anyopaque, parent: backend_mod.Handle, child: backend_mod.Handle) void {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx));
        self.record(.{ .append_child = .{ .parent = parent, .child = child } });
    }
    fn insertBefore(ctx: *anyopaque, parent: backend_mod.Handle, child: backend_mod.Handle, ref: backend_mod.Handle) void {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx));
        self.record(.{ .insert_before = .{ .parent = parent, .child = child, .ref = ref } });
    }
    fn removeChild(ctx: *anyopaque, parent: backend_mod.Handle, child: backend_mod.Handle) void {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx));
        self.record(.{ .remove_child = .{ .parent = parent, .child = child } });
    }

    const vtable = backend_mod.Backend.VTable{
        .createElement = createElement,
        .createText = createText,
        .setText = setText,
        .setAttribute = setAttribute,
        .removeAttribute = removeAttribute,
        .appendChild = appendChild,
        .insertBefore = insertBefore,
        .removeChild = removeChild,
    };
};

test "recording backend captures ops in order" {
    var rec = RecordingBackend.init(std.testing.allocator);
    defer rec.deinit();
    const b = rec.backend();

    const div = b.createElement("div");
    const t = b.createText("hi");
    b.appendChild(div, t);
    b.setAttribute(div, "class", "card");

    try std.testing.expectEqual(@as(usize, 4), rec.ops.items.len);
    try std.testing.expectEqual(@as(backend_mod.Handle, 1), div);
    try std.testing.expectEqual(@as(backend_mod.Handle, 2), t);
    try std.testing.expectEqualStrings("div", rec.ops.items[0].create_element.tag);
    try std.testing.expectEqualStrings("card", rec.ops.items[3].set_attribute.value);
}
