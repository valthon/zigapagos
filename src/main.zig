const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const tracy = @import("tracy");
const fatal = @import("fatal.zig");
const worker = @import("worker.zig");
const root = @import("root.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .log_level = .err,
    .log_scope_levels = options.log_scope_levels,
};

const Command = enum {
    init,
    migrate,
    doctor,
    validate,
    release,
    debug,
    e2e,
    languages,
    help,
    @"-h",
    @"--help",
    version,
    @"-v",
    @"--version",
    // Because other ssgs have them:
    serve,
    server,
    dev,
    develop,
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
pub const gpa = if (builtin.single_threaded)
    debug_allocator.allocator()
else
    std.heap.smp_allocator;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;

    errdefer |err| switch (err) {
        error.OutOfMemory, error.Unexpected => fatal.oom(),
    };

    root.progress = std.Progress.start(io, .{ .draw_buffer = &root.progress_buf });
    defer root.progress.end();

    if (builtin.mode == .Debug) {
        std.debug.print(
            \\*-----------------------------------------------*
            \\|  WARNING: THIS IS A DEBUG BUILD OF ZIGAPAGOS  |
            \\|-----------------------------------------------|
            \\| Debug builds enable expensive sanity checks   |
            \\| that reduce performance.                      |
            \\|                                               |
            \\| To create a release build, run:               |
            \\|                                               |
            \\|           zig build --release=fast            |
            \\|                                               |
            \\| If you're investigating a bug in Zigapagos,   |
            \\| then a debug build might turn confusing       |
            \\| behavior into a crash.                        |
            \\|                                               |
            \\| To disable all forms of concurrency, you can  |
            \\| add the following flag to your build command: |
            \\|                                               |
            \\|              -Dsingle-threaded                |
            \\|                                               |
            \\*-----------------------------------------------*
            \\
            \\
        , .{});
    }
    if (tracy.enable) {
        std.debug.print(
            \\*-----------------------------------------------*
            \\|            WARNING: TRACING ENABLED           |
            \\|-----------------------------------------------|
            \\| Tracing introduces a significant performance  |
            \\| overhead.                                     |
            \\|                                               |
            \\| If you're not interested in tracing Zigapagos,|
            \\| remove `-Dtracy` when building again.         |
            \\*-----------------------------------------------*
            \\
            \\
        , .{});
    }

    if (options.tsan) {
        std.debug.print(
            \\*-----------------------------------------------*
            \\|             WARNING: TSAN ENABLED             |
            \\|-----------------------------------------------|
            \\| Thread sanitizer introduces a significant     |
            \\| performance overhead.                         |
            \\|                                               |
            \\| If you're not interested in debugging         |
            \\| concurrency bugs in Zigapagos, remove         |
            \\| `-Dtsan` when building again.                 |
            \\*-----------------------------------------------*
            \\
            \\
        , .{});
    }

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const cmd = blk: {
        if (args.len >= 2) {
            if (std.meta.stringToEnum(Command, args[1])) |cmd| {
                break :blk cmd;
            }
        }

        @import("cli/serve.zig").serve(io, gpa, args[1..]) catch fatal.oom();
    };

    const any_error = switch (cmd) {
        .init => @import("cli/init.zig").init(io, gpa, args[2..]),
        .migrate => @import("cli/migrate.zig").migrate(io, gpa, args[2..]),
        .doctor => @import("cli/doctor.zig").doctor(io, gpa, args[2..]),
        .validate => @import("cli/validate.zig").validate(io, gpa, args[2..]),
        .release => @import("cli/release.zig").release(io, gpa, args[2..], init.environ_map),
        .debug => @import("cli/debug.zig").debug(io, gpa, args[2..]),
        .e2e => @import("cli/e2e.zig").e2e(io, gpa, args[2..], init.environ_map) catch fatal.oom(),
        .languages => @import("cli/languages.zig").languages(args[2..]),
        .dev, .develop => @import("cli/dev.zig").dev(io, gpa, args[2..], init.environ_map) catch fatal.oom(),
        .help, .@"-h", .@"--help" => fatal.help(),
        .version, .@"-v", .@"--version" => printVersion(),
        .serve, .server => {
            std.debug.print(
                "error: run zigapagos without any subcommand to start the deprecated live server,\n" ++
                    "or use 'zigapagos dev' to serve the release output with the stock ZigBase binary\n\n",
                .{},
            );
            fatal.helpError();
        },
    };

    return @intFromBool(any_error);
}

fn printVersion() noreturn {
    std.debug.print("{s}\n", .{options.version});
    std.process.exit(0);
}

// Pull CLI command modules into the test compilation unit.  release.zig is
// only @import-ed from inside main()'s function body, so Zig's lazy analysis
// would skip its test blocks entirely.  This top-level test block forces eager
// inclusion; the filter "parse" matches both this block AND the tests it
// discovers (e.g. "parse recognizes the island sidecar args" in release.zig).
test "parse" {
    _ = @import("cli/release.zig");
}

// Pull init_from_astro.zig into the test compilation unit for `zig build test-init`.
// Its @import("../fatal.zig") crosses the src/cli/ module boundary, so it
// cannot be compiled as a standalone root module in Zig 0.16.  Using the
// fully-wired zigapagos_exe.root_module as the test root and this anchor to force
// eager inclusion is the same pattern used for release.zig above.
test "init-from-astro" {
    _ = @import("cli/init_from_astro.zig");
}

// Pull spa.zig into the test compilation unit for `zig build test-spa`.
// spa.zig is only @import-ed from inside root.zig's run() function body
// (the release-time SPA prerender pass), so — same reason as release.zig
// and init_from_astro.zig above — Zig's lazy analysis skips its test blocks
// unless something forces eager inclusion.
test "spa" {
    _ = @import("spa.zig");
}

// Pull serve.zig into the test compilation unit for `zig build test-serve`.
// serve.zig is only @import-ed from inside main()'s function body (the live
// server entry point), so — same reason as release.zig / spa.zig above —
// Zig's lazy analysis skips its test blocks unless something forces eager
// inclusion. `test-serve` filters on "serve", which matches this anchor AND
// the `test "serve --proxy …"` blocks in serve.zig.
test "serve" {
    _ = @import("cli/serve.zig");
}

// Pull e2e.zig (and, via its top-level import, zigbase.zig) into the test
// compilation unit for `zig build test-e2e`. e2e.zig is only @import-ed from
// inside main()'s function body (the `zigapagos e2e` dispatch), so — same as
// the anchors above — Zig's lazy analysis skips its test blocks unless
// something forces eager inclusion. `test-e2e` filters on "e2e", which
// matches this anchor AND every `test "e2e …"` block in e2e.zig/zigbase.zig.
test "e2e" {
    _ = @import("cli/e2e.zig");
}

// Pull dev.zig into the test compilation unit for `zig build test-dev`.
// dev.zig is only @import-ed from inside main()'s function body (the
// `zigapagos dev` dispatch), so — same as the anchors above — Zig's lazy
// analysis skips its test blocks unless something forces eager inclusion.
// `test-dev` filters on "dev", which matches this anchor AND every
// `test "dev …"` block in dev.zig and its dev-only reload.zig (each named
// `test "dev live-reload: …"`, so the same "dev" filter picks them up).
test "dev" {
    _ = @import("cli/dev.zig");
    _ = @import("cli/reload.zig");
}

// Pull doctor.zig into the test compilation unit for `zig build test-doctor`.
// (same lazy-analysis reason as the anchors above — doctor.zig is only
// @import-ed from inside main()'s body)
test "doctor" {
    _ = @import("cli/doctor.zig");
}

// Pull validate.zig into the test compilation unit for `zig build test-validate`.
// (same lazy-analysis reason as the anchors above -- validate.zig is only
// @import-ed from inside main()'s body)
test "validate: cli" {
    _ = @import("cli/validate.zig");
}

// Pull languages.zig into the test compilation unit for `zig build test-init`
// and `test-spa`. languages.zig is only reached through worker.zig's
// top-level import, and that one level of indirection past main.zig itself
// isn't enough for Zig 0.16 to eagerly analyze its `test` blocks — same
// reason as the anchors above, one hop further out. `test-init`/`test-spa`
// (build/tests.zig) both run with an EMPTY filter, so this anchor's own name
// doesn't need to match anything.
test "languages" {
    _ = @import("languages.zig");
}

// Pull Template.zig into the test compilation unit for `zig build test-init`.
// Template.zig is reached only through root.zig's top-level import, and — same
// as languages.zig above — that one hop past main.zig is not enough for Zig
// 0.16 to eagerly analyze its `test` blocks: without this anchor the
// `lintInertDirectives` tests compile clean and simply never run. `test-init`
// runs with an EMPTY filter, so this anchor's own name need not match anything.
test "templates" {
    _ = @import("Template.zig");
}
