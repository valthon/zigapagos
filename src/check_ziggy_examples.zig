//! Documentation-only syntax/schema check using the same pinned Ziggy package.
const std = @import("std");
const ziggy = @import("ziggy");
pub const std_options: std.Options = .{ .log_level = .err };

/// Process-arena CLI: argv, source and parser graphs die with this process.
pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var failed = false;
    for (args[1..]) |path| {
        const src = try std.Io.Dir.cwd().readFileAllocOptions(init.io, path, arena, .limited(1024 * 1024), .@"1", 0);
        var meta: ziggy.Deserializer.Meta = .init;
        _ = ziggy.deserializeLeaky(ziggy.Dynamic, arena, src, &meta, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            std.debug.print("{f}\n", .{meta.reportErrorsFmt(arena, .{}, path, src, err)});
            failed = true;
            continue;
        };
        const schema_src = if (std.mem.endsWith(u8, path, "-config.ziggy"))
            @embedFile("schemas/zigapagos.ziggy-schema")
        else
            @embedFile("schemas/page.ziggy-schema");
        const schema = try ziggy.schema.Ast.init(arena, schema_src);
        const doc = try ziggy.Ast.init(arena, src, .{});
        const errors = try schema.validate(arena, schema_src, doc, src);
        if (errors.len != 0) {
            std.debug.print("{s}: {} schema validation error(s)\n", .{ path, errors.len });
            failed = true;
        }
    }
    if (!failed) std.debug.print("Parsed {} complete Ziggy documentation examples\n", .{args.len - 1});
    return @intFromBool(failed);
}
