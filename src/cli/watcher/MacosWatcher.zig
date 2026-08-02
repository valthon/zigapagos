const MacosWatcher = @This();

const std = @import("std");
const Io = std.Io;
const fatal = @import("../../fatal.zig");
const Debouncer = @import("../watcher.zig").Debouncer;

// const c = @cImport({
//     @cInclude("CoreServices/CoreServices.h");
// });
// const c = @import("c");
const c = @import("../../hacks/CoreFoundation.h.zig");

const log = std.log.scoped(.watcher);

io: Io,
gpa: std.mem.Allocator,
debouncer: *Debouncer,
dir_paths: []const [:0]const u8,

pub fn init(
    io: Io,
    gpa: std.mem.Allocator,
    debouncer: *Debouncer,
    dir_paths: []const [:0]const u8,
) MacosWatcher {
    return .{
        .io = io,
        .gpa = gpa,
        .debouncer = debouncer,
        .dir_paths = dir_paths,
    };
}

pub fn start(watcher: *MacosWatcher) !void {
    const t = try std.Thread.spawn(.{}, MacosWatcher.listen, .{watcher});
    t.detach();
}

pub fn listen(watcher: *MacosWatcher) void {
    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    const macos_paths = try watcher.gpa.alloc(
        c.CFStringRef,
        watcher.dir_paths.len,
    );
    defer watcher.gpa.free(macos_paths);

    for (watcher.dir_paths, macos_paths) |str, *ref| {
        // Returns null when `str` is not valid UTF-8 (e.g. a non-UTF-8 byte in a
        // path on an exFAT/SMB/NFS volume). A null element would propagate into
        // CFArrayCreate/FSEventStreamCreate and crash the watcher thread, so
        // fail cleanly here.
        ref.* = c.CFStringCreateWithCString(
            null,
            str.ptr,
            c.kCFStringEncodingUTF8,
        ) orelse fatal.msg(
            "error: unable to encode watched path as a CFString (not valid UTF-8?): {s}",
            .{str},
        );
    }
    defer for (macos_paths) |path| c.CFRelease(path);

    const paths_to_watch: c.CFArrayRef = c.CFArrayCreate(
        null,
        @ptrCast(macos_paths.ptr),
        @intCast(macos_paths.len),
        null,
    ) orelse fatal.msg("error: macos watcher unable to create the watch-paths array", .{});

    var stream_context: c.FSEventStreamContext = .{ .info = watcher };
    const stream: c.FSEventStreamRef = c.FSEventStreamCreate(
        null,
        &macosCallback,
        &stream_context,
        paths_to_watch,
        c.kFSEventStreamEventIdSinceNow,
        0.05,
        c.kFSEventStreamCreateFlagFileEvents,
    ) orelse fatal.msg("error: macos watcher unable to create the FSEventStream", .{});

    c.FSEventStreamScheduleWithRunLoop(
        stream,
        c.CFRunLoopGetCurrent(),
        c.kCFRunLoopDefaultMode,
    );

    if (c.FSEventStreamStart(stream) == 0) {
        fatal.msg("error: macos watcher FSEventStreamStart failed", .{});
    }

    c.CFRunLoopRun();

    c.FSEventStreamStop(stream);
    c.FSEventStreamInvalidate(stream);
    c.FSEventStreamRelease(stream);

    c.CFRelease(paths_to_watch);
}

pub fn macosCallback(
    streamRef: c.ConstFSEventStreamRef,
    clientCallBackInfo: ?*anyopaque,
    numEvents: usize,
    eventPaths: ?*anyopaque,
    eventFlags: ?[*]const c.FSEventStreamEventFlags,
    eventIds: ?[*]const c.FSEventStreamEventId,
) callconv(.c) void {
    _ = eventIds;
    _ = eventFlags;
    _ = streamRef;
    const info = clientCallBackInfo orelse return;
    const watcher: *MacosWatcher = @ptrCast(@alignCast(info));

    if (numEvents == 0) return;
    const raw_paths = eventPaths orelse return;
    const paths: [*][*:0]u8 = @ptrCast(@alignCast(raw_paths));
    for (paths[0..numEvents]) |p| {
        const path = std.mem.span(p);
        log.debug("Changed: {s}\n", .{path});

        // const basename = std.fs.path.basename(path);
        // var base_path = path[0 .. path.len - basename.len];
        // if (std.mem.endsWith(u8, base_path, "/"))
        //     base_path = base_path[0 .. base_path.len - 1];
        watcher.debouncer.newEvent();
    }
}
