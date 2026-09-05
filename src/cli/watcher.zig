//! File-watching for `zigapagos dev`: the per-OS watcher backend, the change
//! event the loop consumes, and the debouncer that collapses an editor's
//! save-cascade into a single rebuild signal.
//!
//! The three backends live in `watcher/` and import `Debouncer` back from this
//! file, so the whole watch subsystem is one directory with one entry point.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Channel = @import("../channel.zig").Channel;

/// Per-OS file watcher, driven by the `zigapagos dev` loop (dev.zig).
///
/// FreeBSD is routed to the inotify-based `LinuxWatcher`. inotify entered the
/// FreeBSD base system in FreeBSD 15, so live reload requires **FreeBSD 15 or
/// newer**; there is no native kqueue backend. On FreeBSD < 15 the inotify
/// symbols resolve to nothing and the watcher never delivers events.
pub const Watcher = switch (builtin.target.os.tag) {
    .linux => @import("watcher/LinuxWatcher.zig"),
    // Requires FreeBSD 15+ (inotify in base); no kqueue backend.
    .freebsd => @import("watcher/LinuxWatcher.zig"),
    .macos => @import("watcher/MacosWatcher.zig"),
    .windows => @import("watcher/WindowsWatcher.zig"),
    else => @compileError("unsupported platform"),
};

/// What a watcher backend delivers through the `Debouncer`'s channel.
///
/// A single-variant union rather than `void` so the dev loop's `switch` stays
/// exhaustive-by-construction if a second kind of watch event is ever added.
pub const Event = union(enum) {
    change: u64,
};

/// Collapses a cascade of filesystem events into one `.change`.
///
/// Editors, formatters and build tools do not write a file once: they write a
/// temp file, rename it, touch the directory, and a rebuild writing the
/// output tree can emit thousands of events in a burst. Rebuilding per event
/// would thrash; `cascade_window_ms` is the quiet period after the LAST event
/// before the cascade is committed and a single `.change` is published.
pub const Debouncer = struct {
    cascade_window_ms: i64,

    io: Io,
    cascade_mutex: Io.Mutex = .init,
    cascade_condition: Io.Condition = .init,
    cascade_start_ms: i64 = 0,
    channel: *Channel(Event),
    /// Optional dev-control revision, incremented before entering debounce.
    /// Every increment must reach a published change and a consuming rebuild;
    /// filtering events afterward would leave pending true and dev wait stuck.
    activity_counter: ?*std.atomic.Value(u64) = null,

    /// Thread-safe. To be called when a new event comes in
    pub fn newEvent(d: *Debouncer) void {
        {
            d.cascade_mutex.lock(d.io) catch unreachable;
            defer d.cascade_mutex.unlock(d.io);
            if (d.activity_counter) |counter| _ = counter.fetchAdd(1, .monotonic);
            d.cascade_start_ms = Io.Clock.awake.now(d.io).toMilliseconds();
        }
        d.cascade_condition.signal(d.io);
    }

    pub fn start(d: *Debouncer) !void {
        const t = try std.Thread.spawn(.{}, Debouncer.notify, .{d});
        t.detach();
    }

    pub fn notify(d: *Debouncer) !void {
        while (true) {
            try d.cascade_mutex.lock(d.io);
            defer d.cascade_mutex.unlock(d.io);

            while (d.cascade_start_ms == 0) {
                // no active cascade
                try d.cascade_condition.wait(d.io, &d.cascade_mutex);
            }
            // cascade != 0
            while (true) {
                const time_passed = Io.Clock.awake.now(d.io).toMilliseconds() - d.cascade_start_ms;
                if (time_passed >= d.cascade_window_ms) break;
                d.cascade_mutex.unlock(d.io);
                const sleep_ms = d.cascade_window_ms - time_passed;
                try d.io.sleep(.fromMilliseconds(sleep_ms), .awake);
                try d.cascade_mutex.lock(d.io);
            }

            // We have slept enough, "commit" the cascade window and
            // trigger a new build.
            d.cascade_start_ms = 0;
            try d.channel.put(d.io, .{ .change = if (d.activity_counter) |counter| counter.load(.monotonic) else 0 });
        }
    }
};
