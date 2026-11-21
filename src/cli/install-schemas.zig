const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const fatal = @import("../fatal.zig");

pub const config_schema = @embedFile("../schemas/zigapagos.ziggy-schema");
pub const page_schema = @embedFile("../schemas/page.ziggy-schema");

/// Contract 1: all config scratch is freed with this command's arena.
pub fn run(io: Io, gpa: Allocator, args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: zigapagos install-schemas\nWrites Ziggy LSP schemas beside the config and in each content directory.\n", .{});
            return false;
        }
        fatal.usageError("unexpected install-schemas argument '{s}'", .{arg});
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const cfg, const base_path = root.Config.load(io, arena_state.allocator());
    const base = Io.Dir.cwd().openDir(io, base_path, .{}) catch |err| fatal.dir(base_path, err);
    defer base.close(io);
    install(io, base, &cfg);
    return false;
}

pub fn install(io: Io, base: Io.Dir, cfg: *const root.Config) void {
    write(io, base, ".zigapagos.ziggy-schema", config_schema);
    switch (cfg.*) {
        .Site => |site| content(io, base, site.content_dir_path),
        .Multilingual => |site| for (site.locales) |locale| content(io, base, locale.content_dir_path),
    }
}

fn content(io: Io, base: Io.Dir, path: []const u8) void {
    const dir = base.createDirPathOpen(io, path, .{}) catch |err| fatal.dir(path, err);
    defer dir.close(io);
    write(io, dir, ".smd.ziggy-schema", page_schema);
}

fn write(io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8) void {
    dir.writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| fatal.file(path, err);
}
