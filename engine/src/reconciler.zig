const std = @import("std");
const vdom = @import("vdom.zig");
const backend = @import("backend.zig");
const RecordingBackend = @import("recording_backend.zig").RecordingBackend;

test "mount creates element + attrs and appends to parent" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rec = RecordingBackend.init(a);
    defer rec.deinit();
    var z = vdom.Z.init(arena.allocator());

    const v = z.el("div", &.{.{ .name = "id", .value = .{ .string = "x" } }}, &.{});
    const m = try reconcile(arena.allocator(), rec.backend(), 100, null, v, backend.null_handle);

    try std.testing.expect(m != null);
    // ops: create_element(div)->1, set_attribute(1,id,x), append_child(100,1)
    try std.testing.expectEqual(@as(usize, 3), rec.ops.items.len);
    try std.testing.expectEqualStrings("div", rec.ops.items[0].create_element.tag);
    try std.testing.expectEqualStrings("x", rec.ops.items[1].set_attribute.value);
    try std.testing.expectEqual(@as(backend.Handle, 100), rec.ops.items[2].append_child.parent);
}

test "update changes attr value and removes a dropped attr; no recreation" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rec = RecordingBackend.init(a);
    defer rec.deinit();
    var z = vdom.Z.init(arena.allocator());

    const v1 = z.el("div", &.{
        .{ .name = "id", .value = .{ .string = "x" } },
        .{ .name = "title", .value = .{ .string = "t" } },
    }, &.{});
    const m1 = try reconcile(arena.allocator(), rec.backend(), 100, null, v1, backend.null_handle);
    rec.ops.clearRetainingCapacity();

    const v2 = z.el("div", &.{.{ .name = "id", .value = .{ .string = "y" } }}, &.{});
    const m2 = try reconcile(arena.allocator(), rec.backend(), 100, m1, v2, backend.null_handle);

    try std.testing.expectEqual(m1.?.handle, m2.?.handle); // reused, not recreated
    // ops: set_attribute(id,y), remove_attribute(title)
    try std.testing.expectEqual(@as(usize, 2), rec.ops.items.len);
    try std.testing.expectEqualStrings("y", rec.ops.items[0].set_attribute.value);
    try std.testing.expectEqualStrings("title", rec.ops.items[1].remove_attribute.name);
}

test "text node update" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rec = RecordingBackend.init(a);
    defer rec.deinit();
    var z = vdom.Z.init(arena.allocator());

    const m1 = try reconcile(arena.allocator(), rec.backend(), 100, null, z.text("hi"), backend.null_handle);
    rec.ops.clearRetainingCapacity();
    const m2 = try reconcile(arena.allocator(), rec.backend(), 100, m1, z.text("bye"), backend.null_handle);

    try std.testing.expectEqual(m1.?.handle, m2.?.handle);
    try std.testing.expectEqual(@as(usize, 1), rec.ops.items.len);
    try std.testing.expectEqualStrings("bye", rec.ops.items[0].set_text.data);
}

pub const Mounted = struct {
    handle: backend.Handle,
    tag: []const u8, // "" => text node
    text: []const u8 = "",
    attrs: []const vdom.Attr = &.{},
    key: ?[]const u8 = null,
    children: std.ArrayList(*Mounted) = .empty,
};

fn isText(m: *const Mounted) bool {
    return m.tag.len == 0;
}

/// Render a brand-new VNode subtree into the backend and return its Mounted.
/// (Fragments are not yet supported as a node here; Task 7 handles children,
/// and fragments are flattened by the caller in the component harness/Task 8.)
fn mount(arena: std.mem.Allocator, b: backend.Backend, node: vdom.VNode) std.mem.Allocator.Error!*Mounted {
    const m = try arena.create(Mounted);
    switch (node) {
        .text => |s| {
            m.* = .{ .handle = b.createText(s), .tag = "", .text = s };
        },
        .element => |el| {
            const h = b.createElement(el.tag);
            for (el.attrs) |attr| applyAttr(b, h, attr);
            m.* = .{ .handle = h, .tag = el.tag, .attrs = el.attrs, .key = el.key };
            for (el.children) |child| {
                const cm = try mount(arena, b, child);
                b.appendChild(h, cm.handle);
                try m.children.append(arena, cm);
            }
        },
        .fragment => unreachable, // flattened before reaching mount (Task 8)
    }
    return m;
}

fn applyAttr(b: backend.Backend, h: backend.Handle, attr: vdom.Attr) void {
    switch (attr.value) {
        .string => |s| b.setAttribute(h, attr.name, s),
        .flag => |on| if (on) b.setAttribute(h, attr.name, "") else b.removeAttribute(h, attr.name),
        .handler => {}, // event wiring handled by the live backend in a later plan
    }
}

fn findAttr(attrs: []const vdom.Attr, name: []const u8) ?vdom.Attr {
    for (attrs) |a| if (std.mem.eql(u8, a.name, name)) return a;
    return null;
}

fn attrEql(a: vdom.Attr, b_: vdom.Attr) bool {
    if (std.meta.activeTag(a.value) != std.meta.activeTag(b_.value)) return false;
    return switch (a.value) {
        .string => |s| std.mem.eql(u8, s, b_.value.string),
        .flag => |f| f == b_.value.flag,
        .handler => |h| h == b_.value.handler,
    };
}

fn diffAttrs(b: backend.Backend, h: backend.Handle, old: []const vdom.Attr, new: []const vdom.Attr) void {
    // Add or update.
    for (new) |na| {
        if (findAttr(old, na.name)) |oa| {
            if (!attrEql(oa, na)) applyAttr(b, h, na);
        } else {
            applyAttr(b, h, na);
        }
    }
    // Remove dropped.
    for (old) |oa| {
        if (findAttr(new, oa.name) == null) b.removeAttribute(h, oa.name);
    }
}

pub fn reconcile(
    arena: std.mem.Allocator,
    b: backend.Backend,
    parent: backend.Handle,
    old: ?*Mounted,
    new: ?vdom.VNode,
    before: backend.Handle,
) std.mem.Allocator.Error!?*Mounted {
    // Unmount.
    if (new == null) {
        if (old) |o| b.removeChild(parent, o.handle);
        return null;
    }
    const nv = new.?;

    // Fresh mount.
    if (old == null) {
        const m = try mount(arena, b, nv);
        if (before == backend.null_handle) {
            b.appendChild(parent, m.handle);
        } else {
            b.insertBefore(parent, m.handle, before);
        }
        return m;
    }
    const o = old.?;

    // Type/tag mismatch => replace.
    const new_is_text = (nv == .text);
    if (new_is_text != isText(o) or (!new_is_text and !std.mem.eql(u8, o.tag, nv.element.tag))) {
        const m = try mount(arena, b, nv);
        b.insertBefore(parent, m.handle, o.handle);
        b.removeChild(parent, o.handle);
        return m;
    }

    // Same kind => patch in place.
    if (new_is_text) {
        if (!std.mem.eql(u8, o.text, nv.text)) {
            b.setText(o.handle, nv.text);
            o.text = nv.text;
        }
        return o;
    }

    const el = nv.element;
    diffAttrs(b, o.handle, o.attrs, el.attrs);
    o.attrs = el.attrs;
    o.key = el.key;
    try reconcileChildren(arena, b, o.handle, &o.children, el.children);
    return o;
}

fn allKeyed(children: []const vdom.VNode) bool {
    if (children.len == 0) return false;
    for (children) |c| {
        if (c != .element) return false;
        if (c.element.key == null) return false;
    }
    return true;
}

/// Reconcile a parent's children list against a new set of VNodes.
///
/// Keyed reconciliation requires ALL siblings to be keyed elements. A list
/// mixing keyed and unkeyed children (e.g. keyed <li> elements plus a trailing
/// text node) falls back to positional (index-based) diffing, which does NOT
/// preserve node identity across reorders.
/// TODO(islands): implement keyed diffing that tolerates interspersed unkeyed nodes.
pub fn reconcileChildren(
    arena: std.mem.Allocator,
    b: backend.Backend,
    parent: backend.Handle,
    old_children: *std.ArrayList(*Mounted),
    new_children: []const vdom.VNode,
) std.mem.Allocator.Error!void {
    if (allKeyed(new_children)) {
        try reconcileKeyed(arena, b, parent, old_children, new_children);
        return;
    }

    // Positional (index-based) diff.
    var result: std.ArrayList(*Mounted) = .empty;
    var i: usize = 0;
    while (i < new_children.len) : (i += 1) {
        const old: ?*Mounted = if (i < old_children.items.len) old_children.items[i] else null;
        const m = try reconcile(arena, b, parent, old, new_children[i], backend.null_handle);
        if (m) |mm| try result.append(arena, mm);
    }
    // Remove leftover old children.
    var j: usize = new_children.len;
    while (j < old_children.items.len) : (j += 1) {
        b.removeChild(parent, old_children.items[j].handle);
    }
    old_children.* = result;
}

fn reconcileKeyed(
    arena: std.mem.Allocator,
    b: backend.Backend,
    parent: backend.Handle,
    old_children: *std.ArrayList(*Mounted),
    new_children: []const vdom.VNode,
) std.mem.Allocator.Error!void {
    // Map old keys -> Mounted.
    var by_key = std.StringHashMap(*Mounted).init(arena);
    defer by_key.deinit();
    for (old_children.items) |om| {
        if (om.key) |k| try by_key.put(k, om);
    }

    var result: std.ArrayList(*Mounted) = .empty;
    // Walk new children; reuse by key (reordering via appendChild), else mount.
    for (new_children) |nv| {
        const key = nv.element.key.?;
        if (by_key.fetchRemove(key)) |entry| {
            const om = entry.value;
            // Patch in place (attrs/children/text) by reconciling against itself.
            const m = try reconcile(arena, b, parent, om, nv, backend.null_handle);
            // Re-append to enforce new order (append moves the existing node to the end in DOM semantics).
            // TODO(islands): keyed reorder is non-minimal — see KNOWN_LIMITATIONS.md
            b.appendChild(parent, m.?.handle);
            try result.append(arena, m.?);
        } else {
            const m = try mount(arena, b, nv);
            b.appendChild(parent, m.handle);
            try result.append(arena, m);
        }
    }
    // Remove old children whose keys are gone.
    var it = by_key.iterator();
    while (it.next()) |kv| {
        b.removeChild(parent, kv.value_ptr.*.handle);
    }
    old_children.* = result;
}

test "replace path: text-to-element swap emits insert_before then remove_child" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rec = RecordingBackend.init(a);
    defer rec.deinit();
    var z = vdom.Z.init(arena.allocator());

    // Mount a text node.
    const m1 = try reconcile(arena.allocator(), rec.backend(), 100, null, z.text("hello"), backend.null_handle);
    const old_handle = m1.?.handle;
    rec.ops.clearRetainingCapacity();

    // Replace with an element: type mismatch triggers insert_before(new) then remove_child(old).
    _ = try reconcile(arena.allocator(), rec.backend(), 100, m1, z.el("span", &.{}, &.{}), backend.null_handle);

    // Expect: insert_before(parent=100, new_node, ref=old_handle) followed by remove_child(parent=100, old_handle).
    var saw_insert_before = false;
    var saw_remove_child = false;
    for (rec.ops.items) |op| switch (op) {
        .insert_before => |ib| {
            try std.testing.expectEqual(@as(backend.Handle, 100), ib.parent);
            try std.testing.expectEqual(old_handle, ib.ref);
            saw_insert_before = true;
        },
        .remove_child => |rc| {
            try std.testing.expectEqual(@as(backend.Handle, 100), rc.parent);
            try std.testing.expectEqual(old_handle, rc.child);
            saw_remove_child = true;
        },
        else => {},
    };
    try std.testing.expect(saw_insert_before);
    try std.testing.expect(saw_remove_child);

    // insert_before must come BEFORE remove_child in the op sequence.
    var insert_idx: usize = 0;
    var remove_idx: usize = 0;
    for (rec.ops.items, 0..) |op, i| switch (op) {
        .insert_before => insert_idx = i,
        .remove_child => remove_idx = i,
        else => {},
    };
    try std.testing.expect(insert_idx < remove_idx);
}

test "child append, remove, and in-place update" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rec = RecordingBackend.init(a);
    defer rec.deinit();
    var z = vdom.Z.init(arena.allocator());

    const v1 = z.el("ul", &.{}, &.{ z.el("li", &.{}, &.{z.text("a")}) });
    const m1 = try reconcile(arena.allocator(), rec.backend(), 100, null, v1, backend.null_handle);
    rec.ops.clearRetainingCapacity();

    // add a second li, change first li's text
    const v2 = z.el("ul", &.{}, &.{
        z.el("li", &.{}, &.{z.text("A")}),
        z.el("li", &.{}, &.{z.text("b")}),
    });
    _ = try reconcile(arena.allocator(), rec.backend(), 100, m1, v2, backend.null_handle);

    // expect a set_text("A") for the reused first child and creation+append of the new li
    var saw_set_text_A = false;
    var saw_append = false;
    for (rec.ops.items) |op| switch (op) {
        .set_text => |st| if (std.mem.eql(u8, st.data, "A")) {
            saw_set_text_A = true;
        },
        .append_child => saw_append = true,
        else => {},
    };
    try std.testing.expect(saw_set_text_A);
    try std.testing.expect(saw_append);
}

test "mixed keyed+unkeyed children fall back to positional diffing (documented limitation)" {
    // This test pins the CURRENT behavior, not ideal behavior.
    // A list that mixes keyed elements with an unkeyed node (here: a trailing text node)
    // does NOT satisfy allKeyed(), so reconcileChildren uses positional (index) diffing.
    // Positional diffing matches children by index: on reorder the keyed <li> handles are
    // patched in-place by index (set_text overwrites content), no key-based identity move.
    // See the doc comment on reconcileChildren for the deferred TODO.
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rec = RecordingBackend.init(a);
    defer rec.deinit();
    var z = vdom.Z.init(arena.allocator());

    // Initial render: keyed li "a", keyed li "b", unkeyed trailing text.
    const v1 = z.el("ul", &.{}, &.{
        z.elKeyed("li", "a", &.{}, &.{z.text("one")}),
        z.elKeyed("li", "b", &.{}, &.{z.text("two")}),
        z.text("footer"),
    });
    const m1 = try reconcile(arena.allocator(), rec.backend(), 100, null, v1, backend.null_handle);
    // Record the handles assigned to the two keyed li nodes.
    const li_a_handle = m1.?.children.items[0].handle;
    const li_b_handle = m1.?.children.items[1].handle;
    rec.ops.clearRetainingCapacity();

    // Reorder: swap the two keyed lis; trailing text unchanged.
    const v2 = z.el("ul", &.{}, &.{
        z.elKeyed("li", "b", &.{}, &.{z.text("two")}),
        z.elKeyed("li", "a", &.{}, &.{z.text("one")}),
        z.text("footer"),
    });
    const m2 = try reconcile(arena.allocator(), rec.backend(), 100, m1, v2, backend.null_handle);

    // CURRENT behavior (positional path): handles are reused in-place by index.
    // Index 0 old was li_a (content "one"), new is li_b (content "two") -> set_text("two")
    // Index 1 old was li_b (content "two"), new is li_a (content "one") -> set_text("one")
    // The same DOM node at index 0 now has "two" content — no key-based move occurred.
    try std.testing.expectEqual(li_a_handle, m2.?.children.items[0].handle); // NOT moved by key
    try std.testing.expectEqual(li_b_handle, m2.?.children.items[1].handle); // NOT moved by key

    // No create_element should occur (same tags matched positionally).
    for (rec.ops.items) |op| try std.testing.expect(op != .create_element);

    // set_text ops should be seen (index-wise content overwrite).
    var set_text_count: usize = 0;
    for (rec.ops.items) |op| if (op == .set_text) { set_text_count += 1; };
    try std.testing.expect(set_text_count >= 2);
}

test "keyed reorder reuses nodes (no recreation)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rec = RecordingBackend.init(a);
    defer rec.deinit();
    var z = vdom.Z.init(arena.allocator());

    const v1 = z.el("ul", &.{}, &.{
        z.elKeyed("li", "1", &.{}, &.{z.text("one")}),
        z.elKeyed("li", "2", &.{}, &.{z.text("two")}),
    });
    const m1 = try reconcile(arena.allocator(), rec.backend(), 100, null, v1, backend.null_handle);
    const created = rec.ops.items.len;
    rec.ops.clearRetainingCapacity();

    // swap order
    const v2 = z.el("ul", &.{}, &.{
        z.elKeyed("li", "2", &.{}, &.{z.text("two")}),
        z.elKeyed("li", "1", &.{}, &.{z.text("one")}),
    });
    _ = try reconcile(arena.allocator(), rec.backend(), 100, m1, v2, backend.null_handle);

    // No new element creation on reorder.
    for (rec.ops.items) |op| try std.testing.expect(op != .create_element);
    try std.testing.expect(created > 0);
}
