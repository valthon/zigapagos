const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const tracy = @import("tracy");
const fatal = @import("fatal.zig");
const worker = @import("worker.zig");
const root = @import("root.zig");
const diag = @import("diag.zig");
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
    explain,
    release,
    debug,
    e2e,
    languages,
    @"explain-code",
    help,
    @"-h",
    @"--help",
    version,
    @"-v",
    @"--version",
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

    // Bound before std.Progress.start (moved up from below the banners, where
    // it originally sat) because scanArgv below needs it, and scanArgv must
    // run before Progress and the Debug/tracy/tsan banners -- all three write
    // to stderr and would interleave with the NDJSON stream otherwise. The
    // errdefer above still covers this call (error.OutOfMemory,
    // error.Unexpected), unchanged by the move.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Diagnostic format is decided before std.Progress and before the
    // Debug/tracy/tsan banners below, because all three write to stderr and
    // would interleave with the NDJSON stream. Argv is scanned directly
    // rather than waiting for the command's own parser, which runs far too
    // late (release.zig re-affirms the assignment and owns the error message
    // for a bad --format value; this pre-scan is purely a stderr-suppression
    // optimisation).
    //
    // Gated to the commands that ACCEPT `--format` (see docs/diagnostics.md's
    // scope section) -- today `release`, `validate`, and `doctor`. An ungated
    // pre-scan reads argv that belongs to some OTHER command's parser:
    // `zigapagos dev --format=json` would flip the global format and then
    // answer with an NDJSON `ZP_FATAL` complaining about a flag `dev` does
    // not have. A command may only appear in this list in the same change
    // that teaches its own parser the flag. src/root.zig's `.memory`-mode
    // comment (a memory build never emits JSON) no longer holds for
    // validate, which is exactly why validate is in this list.
    if (args.len >= 2 and
        (std.mem.eql(u8, args[1], "release") or
            std.mem.eql(u8, args[1], "validate") or
            std.mem.eql(u8, args[1], "doctor")))
    {
        if (diag.scanArgv(args[2..])) |f| diag.format = f;
    }

    root.progress = std.Progress.start(io, .{
        .draw_buffer = &root.progress_buf,
        // In JSON mode stderr carries the NDJSON diagnostic stream; a
        // progress bar interleaved into it would be unparseable noise (and
        // on a non-tty stderr, std.Progress already draws nothing -- this
        // only matters when stderr is a tty, e.g. an interactive agent or a
        // PTY-allocating test harness).
        .disable_printing = diag.format == .json,
    });
    defer root.progress.end();

    // The Debug/tracy/tsan warning banners are text-mode noise: in JSON mode
    // they would be the first (unparseable) lines on the NDJSON stream.
    if (diag.format == .text) {
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
    }

    // `zigapagos` is a standalone binary with no default action: run bare it
    // prints its help and succeeds (exit 0), which is what a user typing the
    // name of an unfamiliar command expects and what `npx zigapagos` must do.
    // An argument that is not a command is a mistake, so it gets a diagnostic
    // and a NON-zero exit -- the two cases share a help menu but must not
    // share an exit status, or a typo'd command in a script passes silently.
    if (args.len < 2) fatal.help();

    const cmd = std.meta.stringToEnum(Command, args[1]) orelse {
        std.debug.print("error: unknown command '{s}'\n\n", .{args[1]});
        fatal.helpError();
    };

    const any_error = switch (cmd) {
        .init => @import("cli/init.zig").init(io, gpa, args[2..]),
        .migrate => @import("cli/migrate.zig").migrate(io, gpa, args[2..]),
        .doctor => @import("cli/doctor.zig").doctor(io, gpa, args[2..]),
        .validate => @import("cli/validate.zig").validate(io, gpa, args[2..]),
        .explain => @import("cli/explain.zig").explain(io, gpa, args[2..]),
        .release => @import("cli/release.zig").release(io, gpa, args[2..], init.environ_map),
        .debug => @import("cli/debug.zig").debug(io, gpa, args[2..]),
        .e2e => @import("cli/e2e.zig").e2e(io, gpa, args[2..], init.environ_map) catch fatal.oom(),
        .languages => @import("cli/languages.zig").languages(args[2..]),
        .@"explain-code" => @import("cli/explain_code.zig").explainCode(args[2..]),
        .dev, .develop => @import("cli/dev.zig").dev(io, gpa, args[2..], init.environ_map) catch fatal.oom(),
        .help, .@"-h", .@"--help" => fatal.help(),
        .version, .@"-v", .@"--version" => printVersion(),
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

test "debug: cli" {
    _ = @import("cli/debug.zig");
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

// Pull e2e.zig AND zigbase.zig into the test compilation unit for
// `zig build test-e2e`. e2e.zig is only @import-ed from inside main()'s function
// body (the `zigapagos e2e` dispatch), so — same as the anchors above — Zig's
// lazy analysis skips its test blocks unless something forces eager inclusion.
// `test-e2e` filters on "e2e", which matches this anchor AND every
// `test "e2e …"` block in e2e.zig/zigbase.zig.
//
// zigbase.zig needs its OWN line here. It was previously left to e2e.zig's
// top-level `const zigbase = @import("zigbase.zig")`, on the assumption that
// importing e2e.zig drags it in — the same assumption build/tests.zig's
// `test-assets` comment already records as false: a top-level `const` is
// analyzed only when analyzed code references it, and in a FILTERED compile the
// only analyzed code is the matching tests. Nothing in e2e.zig's own `test
// "e2e …"` blocks touches `zigbase`, so all four `test "e2e zigbase: …"` blocks
// went unanalyzed and `test-e2e` reported success without running them — an
// assertion made deliberately impossible still passed. Adding a suite whose
// filter matches an anchor is not enough; every FILE the suite is meant to
// cover has to be reachable from the anchor's body.
test "e2e" {
    _ = @import("cli/e2e.zig");
    _ = @import("cli/zigbase.zig");
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

// Pull explain.zig into the test compilation unit for `zig build test-explain`.
// (same lazy-analysis reason as the anchors above -- explain.zig is only
// @import-ed from inside main()'s body)
test "explain: cli" {
    _ = @import("cli/explain.zig");
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

// Pull root.zig and fingerprint.zig into the test compilation unit for
// `zig build test-assets`.
//
// This anchor is NOT redundant with main.zig's top-level `const root =
// @import("root.zig")`. Under a `--test-filter` (and `filters` is a
// COMPILE-time option in Zig 0.16, see build/tests.zig) the compiler analyzes
// only the test decls whose name MATCHES, and a top-level `const` is analyzed
// only when something already-analyzed references it. `root` is referenced
// from `main()`'s body, which a test build never analyzes — so with no
// matching anchor here, nothing pulled root.zig in, `test-assets` compiled
// ZERO tests, and the step still exited 0. It was a green gate pinning
// nothing: inverting an assertion in `test "assets: shouldMinifyCss …"` left
// it passing. Hence the anchor's own name has to match the "assets:" filter.
//
// fingerprint.zig needs its own line for the same reason one hop further out:
// root.zig imports it at the top level, but root.zig's own `assets:` tests
// never reference that `const`, so it too stayed unanalyzed — which also kept
// it out of the UNFILTERED `checked` suite, i.e. out of
// `check -Dsingle-threaded`.
test "assets: unit-test anchor" {
    _ = @import("root.zig");
    _ = @import("fingerprint.zig");
}
