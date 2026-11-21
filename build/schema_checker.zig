//! Root-driven, fail-closed agreement with the complete pinned Ziggy grammar.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ziggy = @import("ziggy");
const types = @import("types");
const Tokenizer = ziggy.schema.Tokenizer;
const Token = Tokenizer.Token;
const Ast = ziggy.schema.Ast;

/// Process-arena CLI: the source and parsed schema die with the process.
pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 2) {
        std.debug.print("usage: check-schema <schema-path>\n", .{});
        return 1;
    }
    const path = args[1];
    const src = try std.Io.Dir.cwd().readFileAllocOptions(init.io, path, gpa, .limited(ziggy.max_size), .@"1", 0);
    // The tokenizer treats NUL as EOF. Never let a file hide a suffix behind it.
    if (std.mem.indexOfScalar(u8, src, 0) != null) {
        std.debug.print("{s}: schema not checked: embedded NUL\n", .{path});
        return 1;
    }
    var lexer: Tokenizer = .init;
    while (true) {
        const token = lexer.next(src);
        if (token.tag == .invalid or (token.tag == .eof and lexer.idx != src.len)) {
            std.debug.print("{s}: schema not checked: invalid or unparsed input at byte {d}\n", .{ path, token.loc.start });
            return 1;
        }
        if (token.tag == .eof) break;
    }
    const ast = try Ast.init(gpa, src);
    defer ast.deinit(gpa);
    if (ast.has_syntax_errors or ast.errors.len != 0) {
        for (ast.errors) |e| {
            const pos = e.main_location.getSelection(src).start;
            std.debug.print("{s}:{d}:{d}: schema not checked: {f}\n", .{ path, pos.line, pos.col, e.tag });
        }
        return 1;
    }
    if (ast.nodes.len < 3 or ast.nodes[0].tag != .root or
        ast.nodes[1].tag != .root_expr or ast.nodes[2].tag != .type_expr)
    {
        std.debug.print("{s}: schema not checked: missing document-root expression\n", .{path});
        return 1;
    }
    var check = try Check.init(gpa, path, src, ast);
    defer check.deinit();
    check.checked[0] = true;
    check.checked[1] = true;
    // The module explicitly identifies the document type. Public helper types
    // are not alternate roots and cannot make unreachable schema nodes pass.
    try check.expression(types.Document, 0, 2, false);
    if (!check.failed) {
        for (check.checked, 0..) |checked, idx| {
            if (checked) continue;
            check.fail(@intCast(idx), "schema construct not checked: {t} (unreferenced declaration or expression)", .{ast.nodes[idx].tag});
            break;
        }
    }
    return @intFromBool(check.failed);
}

const Check = struct {
    gpa: Allocator,
    path: []const u8,
    src: [:0]const u8,
    ast: Ast,
    checked: []bool,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    failed: bool = false,

    /// Owned-result: owns coverage bits and visited-pair keys; caller deinits.
    fn init(gpa: Allocator, path: []const u8, src: [:0]const u8, ast: Ast) !Check {
        const checked = try gpa.alloc(bool, ast.nodes.len);
        @memset(checked, false);
        return .{ .gpa = gpa, .path = path, .src = src, .ast = ast, .checked = checked };
    }

    fn deinit(c: *Check) void {
        var keys = c.seen.keyIterator();
        while (keys.next()) |key| c.gpa.free(key.*);
        c.seen.deinit(c.gpa);
        c.gpa.free(c.checked);
    }

    fn fail(c: *Check, idx: u32, comptime fmt: []const u8, args: anytype) void {
        c.failed = true;
        const pos = c.ast.nodes[idx].loc.getSelection(c.src).start;
        std.debug.print("{s}:{d}:{d}: ", .{ c.path, pos.line, pos.col });
        std.debug.print(fmt ++ "\n", args);
    }

    fn mismatch(c: *Check, comptime T: type, idx: u32) void {
        c.fail(idx, "Zig type '{s}' disagrees with schema '{s}'", .{ @typeName(T), c.ast.nodes[idx].loc.slice(c.src) });
    }

    /// Owned-result: recursive comparisons add keys to Check's visited graph.
    fn expression(c: *Check, comptime T: type, scope: u32, idx: u32, has_default: bool) Allocator.Error!void {
        c.checked[idx] = true;
        var it: Tokenizer = .initFrom(c.ast.nodes[idx].loc.start);
        const first = it.next(c.src);
        try c.match(T, scope, idx, &it, first, has_default);
        if (it.idx != c.ast.nodes[idx].loc.end)
            c.fail(idx, "schema construct not checked: unconsumed type-expression suffix", .{});
    }

    /// Owned-result: recursive comparisons add keys to Check's visited graph.
    fn match(c: *Check, comptime T: type, scope: u32, idx: u32, it: *Tokenizer, token: Token, has_default: bool) Allocator.Error!void {
        const info = @typeInfo(T);
        if (isOptional(token.tag)) {
            var required = token;
            required.tag = requiredTag(token.tag);
            required.loc.start += 1;
            if (info == .optional) return c.match(info.optional.child, scope, idx, it, required, false);
            if (has_default) return c.match(T, scope, idx, it, required, false);
            c.mismatch(T, idx);
            return;
        }
        if (info == .pointer and info.pointer.size == .one)
            return c.match(info.pointer.child, scope, idx, it, token, has_default);

        if (ziggy.getOptions(T)) |opts| {
            if (opts.roles == .any) {
                // Preserve Ziggy's wrapping contract explicitly: Dynamic can
                // represent dict/list wrappers, but their leaves must remain
                // unconstrained. Never skip a typed leaf or named declaration.
                switch (token.tag) {
                    .any_kw => return,
                    .dict_sigil, .slice_sigil => return c.match(T, scope, idx, it, it.next(c.src), false),
                    else => {
                        c.fail(idx, "schema construct not checked: unrestricted dynamic type requires terminal any", .{});
                        return;
                    },
                }
            }
        }
        switch (token.tag) {
            .slice_sigil => {
                if (ziggy.getOptions(T)) |opts| {
                    if (opts.roles == .container) if (opts.roles.container.slice) |Child|
                        return c.match(Child, scope, idx, it, it.next(c.src), false);
                }
                // Ziggy treats byte slices as bytes, never as integer lists.
                if (info == .pointer and info.pointer.size == .slice and info.pointer.child != u8)
                    return c.match(info.pointer.child, scope, idx, it, it.next(c.src), false);
            },
            .dict_sigil => {
                if (ziggy.getOptions(T)) |opts| {
                    if (opts.roles == .container) if (opts.roles.container.dict) |Child|
                        return c.match(Child, scope, idx, it, it.next(c.src), false);
                }
            },
            .identifier => {
                const target = c.ast.findContainerType(scope, token.loc.slice(c.src)) orelse {
                    c.fail(idx, "schema construct not checked: unknown type reference '{s}'", .{token.loc.slice(c.src)});
                    return;
                };
                return c.container(T, target);
            },
            .bytes_kw => if (info == .pointer and info.pointer.size == .slice and info.pointer.child == u8) return,
            .int_kw => if (info == .int) return,
            .float_kw => if (info == .float) return,
            .bool_kw => if (T == bool) return,
            .any_kw => {}, // Concrete types cannot represent an unrestricted any.
            else => {
                c.fail(idx, "schema construct not checked: token {t}", .{token.tag});
                return;
            },
        }
        c.mismatch(T, idx);
    }

    /// Owned-result: pair keys are owned by Check until deinit, including errors.
    fn container(c: *Check, comptime T: type, idx: u32) Allocator.Error!void {
        if (ziggy.getOptions(T)) |opts| {
            switch (opts.roles) {
                .any => {
                    c.fail(idx, "schema construct not checked: unrestricted dynamic type requires terminal any", .{});
                    return;
                },
                .container => |roles| {
                    if (roles.@"union") |U| {
                        if (U == T) {
                            c.fail(idx, "schema construct not checked: self-referential custom union metadata", .{});
                            return;
                        }
                        return c.container(U, idx);
                    }
                    c.fail(idx, "schema construct not checked: custom list/dictionary requires its collection expression", .{});
                    return;
                },
                .none => if (opts.deserialize != null) {
                    c.fail(idx, "schema construct not checked: custom deserializer has no representation metadata", .{});
                    return;
                },
            }
        }
        const info = @typeInfo(T);
        const kind = c.ast.nodes[idx].tag;
        switch (info) {
            .@"struct" => if (kind != .@"struct") {
                c.mismatch(T, idx);
                return;
            },
            .@"union" => |un| {
                if (kind != .@"union" or un.tag_type == null) {
                    c.mismatch(T, idx);
                    return;
                }
            },
            .@"enum" => if (kind != .@"union") {
                c.mismatch(T, idx);
                return;
            },
            else => {
                c.mismatch(T, idx);
                return;
            },
        }
        const name = try c.gpa.print("{s}:{}", .{ @typeName(T), idx });
        const pair = c.seen.getOrPut(c.gpa, name) catch |err| {
            c.gpa.free(name);
            return err;
        };
        if (pair.found_existing) {
            c.gpa.free(name);
            return;
        }
        c.checked[idx] = true;
        const fields = c.ast.scopes.get(idx).?.fields;
        const skip = if (ziggy.getOptions(T)) |opts| opts.skip_fields else &.{};
        inline for (comptime fieldNames(T), 0..) |field_name, slot| field_block: {
            @setEvalBranchQuota(100_000);
            if (info == .@"struct" and comptime std.mem.indexOfScalar(std.meta.FieldEnum(T), skip, std.meta.stringToEnum(std.meta.FieldEnum(T), field_name).?) != null) {
                if (fields.contains(field_name)) c.fail(idx, "field '{s}' is skipped by Ziggy options but present in schema", .{field_name});
                break :field_block;
            }
            if (fields.get(field_name)) |field| {
                c.checked[field.idx] = true;
                const expr = c.ast.fieldTypeExpr(field.idx);
                if (info == .@"enum") {
                    if (expr != null) c.fail(field.idx, "schema enum member has a payload", .{});
                } else {
                    const Child = switch (info) {
                        .@"struct" => |s| s.field_types[slot],
                        .@"union" => |u| u.field_types[slot],
                        else => unreachable, // comptime-pruned enum branch above
                    };
                    if (expr) |value| {
                        if (Child == void) {
                            c.fail(field.idx, "schema case has a payload but Zig case is payloadless", .{});
                            break :field_block;
                        }
                        var has_default = false;
                        if (info == .@"struct") {
                            has_default = info.@"struct".field_attrs[slot].default_value_ptr != null;
                            var it: Tokenizer = .initFrom(value.loc.start);
                            const tag = it.next(c.src).tag;
                            if ((isOptional(tag) or tag == .dict_sigil) and !has_default)
                                c.fail(field.idx, "optional/dictionary schema field requires a Zig default", .{});
                        }
                        try c.expression(Child, idx, field.idx + 1, has_default);
                    } else if (Child != void) {
                        c.fail(field.idx, "Zig case has a payload but schema case is payloadless", .{});
                    }
                }
            } else c.fail(idx, "Zig field or case '{s}' is missing from schema", .{field_name});
        }
        const names: std.StaticStringMap(std.meta.FieldEnum(T)) = .initEnum();
        for (fields.keys()) |field_name| {
            if (!names.has(field_name)) c.fail(idx, "schema field or case '{s}' is missing from Zig type", .{field_name});
        }
    }
};

fn isOptional(tag: Token.Tag) bool {
    return switch (tag) {
        .opt_slice_sigil, .opt_dict_sigil, .opt_identifier, .opt_int_kw, .opt_float_kw, .opt_bool_kw, .opt_bytes_kw => true,
        else => false,
    };
}

fn requiredTag(tag: Token.Tag) Token.Tag {
    return switch (tag) {
        .opt_slice_sigil => .slice_sigil,
        .opt_dict_sigil => .dict_sigil,
        .opt_identifier => .identifier,
        .opt_int_kw => .int_kw,
        .opt_float_kw => .float_kw,
        .opt_bool_kw => .bool_kw,
        .opt_bytes_kw => .bytes_kw,
        else => tag,
    };
}

fn fieldNames(comptime T: type) []const []const u8 {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_names,
        .@"union" => |u| u.field_names,
        .@"enum" => |e| e.field_names,
        else => unreachable,
    };
}
