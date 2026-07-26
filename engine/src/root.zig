const std = @import("std");

// Public surface (modules added in later tasks are re-exported here).
pub const vdom = @import("vdom.zig");
pub const escape = @import("escape.zig");
pub const backend = @import("backend.zig");
pub const recording_backend = @import("recording_backend.zig");
pub const ssr = @import("ssr.zig");
pub const reconciler = @import("reconciler.zig");
pub const component = @import("component.zig");

test {
    std.testing.refAllDecls(@This());
    _ = vdom;
    _ = escape;
    _ = backend;
    _ = recording_backend;
    _ = ssr;
    _ = reconciler;
    _ = component;
}

test "root aggregates module tests" {
    try std.testing.expect(true);
}
