const std = @import("std");
const ziggy = @import("ziggy");
const RenderArena = @import("render_arena.zig").RenderArena;

/// A dynamic `prop-NAME="value"` override (value already Scripty-evaluated by
/// SuperHTML). Type-erased: merged into the JSON object in Task 2.
pub const Pair = struct { name: []const u8, value: []const u8 };

/// Resolve a `:props` Ziggy literal (no comptime type) + `prop-NAME` overrides
/// into script-safe JSON for a TSX island. Arena-owned result.
///
/// NO_SLOP.md §2.2a contract 4 (`RenderArena`). The escaping return value is a
/// single buffer, but everything this builds on the way there is not: `ziggy`
/// exposes ONLY `parseLeaky` (see its `src/root.zig` — there is no non-leaky
/// parse and therefore no `deinit`), so the untyped `dynamic.Value` tree and the
/// `std.json.Value` tree walked out of it are interlinked graphs with no owner
/// (1). Freeing them would mean re-walking two recursive trees to release nodes
/// that are dead the moment the JSON is stringified — pointer-chasing for no
/// benefit (2) — and they die with the page render that resolved the props (3).
pub fn resolveToJson(arena: RenderArena, props_src: []const u8, dyn: []const Pair) ![]u8 {
    const src = if (props_src.len == 0) "{}" else props_src;
    const code = try arena.a.dupeZ(u8, src);
    const dynamic = try ziggy.parseLeaky(ziggy.dynamic.Value, arena.a, code, .{});
    var root = try dynamicToJson(arena, dynamic);
    // `:props` must be a struct/map at the top level.
    if (root != .object) return error.PropsNotAnObject;
    try applyOverrides(arena, &root.object, dyn); // no-op when dyn is empty (Task 2)

    var raw_aw: std.Io.Writer.Allocating = .init(arena.a);
    try std.json.Stringify.value(root, .{}, &raw_aw.writer);
    // `escapeForScript` is contract 1, hence `.a` (NO_SLOP.md §2.2a): its result
    // is this function's single escaping allocation.
    return escapeForScript(arena.a, raw_aw.written());
}

/// Walk an untyped Ziggy value into a std.json.Value. Contract 4
/// (`RenderArena`): the returned `std.json.Value` is the interlinked tree
/// `resolveToJson`'s justification describes — object maps and arrays with no
/// `deinit`, reclaimed with the render pass.
fn dynamicToJson(arena: RenderArena, v: ziggy.dynamic.Value) !std.json.Value {
    return switch (v) {
        .kv => |map| blk: {
            var obj: std.json.ObjectMap = .empty;
            var it = map.fields.iterator();
            while (it.next()) |entry| {
                try obj.put(arena.a, entry.key_ptr.*, try dynamicToJson(arena, entry.value_ptr.*));
            }
            break :blk .{ .object = obj };
        },
        .array => |items| blk: {
            var arr = std.json.Array.init(arena.a);
            for (items) |item| try arr.append(try dynamicToJson(arena, item));
            break :blk .{ .array = arr };
        },
        .bytes => |s| .{ .string = s },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .bool => |b| .{ .bool = b },
        .null => .null,
        // A Ziggy tag (@date("..."), etc.) has no JSON analogue — fail loudly.
        .tag => error.UnsupportedPropTag,
    };
}

/// Merge `prop-NAME` overrides into the object. The override string is the final
/// Scripty value: parse it as JSON if it is valid JSON (numbers, booleans,
/// null, arrays, objects, or a quoted string), otherwise treat the raw text as
/// a JSON string (the `$page.title` -> "My Title" case). The destination TSX
/// island validates the shape (loud-fail) — this layer is type-erased.
/// Contract 4 (`RenderArena`): each override is `parseFromSliceLeaky`-parsed
/// straight into the caller's json tree, so it inherits that tree's ownership.
fn applyOverrides(arena: RenderArena, obj: *std.json.ObjectMap, dyn: []const Pair) !void {
    for (dyn) |pair| {
        // Parse the override as JSON; ONLY a parse/validation failure means
        // "not JSON -> treat the raw text as a string". OutOfMemory must
        // propagate (loud-fail constraint), never fall back to a default.
        const value: std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, arena.a, pair.value, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .string = pair.value },
        };
        // std.json.ObjectMap is unmanaged on 0.16: put takes the allocator.
        try obj.put(arena.a, pair.name, value);
    }
}

/// Emit JSON with `<`,`>`,`&` as \uXXXX so it is safe between
/// <script type="application/json"> … </script>. (Same scheme as render.zig.)
///
/// NO_SLOP.md §2.2a contract 1: exactly one allocation escapes (the returned
/// buffer, always owned — a dupe when nothing needed escaping), so this is
/// correct under any allocator even though its caller is arena-scoped.
fn escapeForScript(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var needs = false;
    for (raw) |b| {
        if (b == '<' or b == '>' or b == '&') {
            needs = true;
            break;
        }
    }
    if (!needs) return try alloc.dupe(u8, raw);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (raw) |b| switch (b) {
        '<' => try out.writer.writeAll("\\u003C"),
        '>' => try out.writer.writeAll("\\u003E"),
        '&' => try out.writer.writeAll("\\u0026"),
        else => try out.writer.writeByte(b),
    };
    return out.toOwnedSlice();
}

test "resolveToJson: empty props_src -> empty object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    const json = try resolveToJson(arena, "", &.{});
    try std.testing.expectEqualStrings("{}", json);
}

test "resolveToJson: scalar fields keep source order and JSON types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    const json = try resolveToJson(arena, "{ .start = 5, .label = \"hi\", .open = true }", &.{});
    try std.testing.expectEqualStrings("{\"start\":5,\"label\":\"hi\",\"open\":true}", json);
}

test "resolveToJson: nested array-of-structs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    const json = try resolveToJson(arena, "{ .items = [ { .q = \"Q1\", .a = \"A1\" }, { .q = \"Q2\", .a = \"A2\" } ] }", &.{});
    try std.testing.expectEqualStrings("{\"items\":[{\"q\":\"Q1\",\"a\":\"A1\"},{\"q\":\"Q2\",\"a\":\"A2\"}]}", json);
}

// --- Task 2: prop-NAME overrides ---

test "resolveToJson: prop-NAME override, scalar coerced via JSON-validity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    // "9" is valid JSON (number); "from-page" is not (-> string). Override wins.
    const json = try resolveToJson(arena, "{ .start = 1, .label = \"base\" }", &.{
        .{ .name = "start", .value = "9" },
        .{ .name = "label", .value = "from-page" },
    });
    try std.testing.expectEqualStrings("{\"start\":9,\"label\":\"from-page\"}", json);
}

test "resolveToJson: structured prop-NAME override (a JSON string from .toJson())" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    const json = try resolveToJson(arena, "{}", &.{
        .{ .name = "items", .value = "[{\"q\":\"X\",\"a\":\"Y\"}]" },
    });
    try std.testing.expectEqualStrings("{\"items\":[{\"q\":\"X\",\"a\":\"Y\"}]}", json);
}

test "resolveToJson: escapes </script> breakout in a string value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    const json = try resolveToJson(arena, "{ .label = \"</script><x>&\" }", &.{});
    try std.testing.expect(std.mem.indexOf(u8, json, "</script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\u003C") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\u003E") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\u0026") != null);
}

test "resolveToJson: malformed :props is a loud error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    try std.testing.expectError(error.Syntax, resolveToJson(arena, "{ .x = ", &.{}));
}

// --- Task 1 review: additional error-path tests ---

test "resolveToJson: non-object top-level :props is a loud error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    // A bare array at the top level is not a valid props object.
    try std.testing.expectError(error.PropsNotAnObject, resolveToJson(arena, "[1, 2, 3]", &.{}));
}

test "resolveToJson: a Ziggy tag value is a loud error (no JSON analogue)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    // @date(...) is a Ziggy tag; dynamicToJson must reject it, not emit garbage.
    try std.testing.expectError(error.UnsupportedPropTag, resolveToJson(arena, "{ .at = @date(\"2020-01-01\") }", &.{}));
}

test "resolveToJson: float field round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    const json = try resolveToJson(arena, "{ .ratio = 1.5 }", &.{});
    try std.testing.expectEqualStrings("{\"ratio\":1.5}", json);
}
