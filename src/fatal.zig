const std = @import("std");
const main = @import("main.zig");
const builtin = @import("builtin");
const diag = @import("diag.zig");

/// A fatal error. Text mode: print the message and, in a Debug build, panic
/// with a stack trace (surfaces an internal Zigapagos bug loudly to a human).
/// JSON mode (`--format=json`): emit ONE `ZP_FATAL` NDJSON line and exit 1 --
/// deliberately WITHOUT the debug panic. In text mode the panic exists to
/// surface an internal bug with a trace; in JSON mode the consumer is a
/// machine, a stack trace is unparseable noise on the same stream, and
/// panicking turns a clean exit 1 into SIGABRT (134) under the Debug build
/// every shell test drives (`zig build` defaults to Debug). Text-mode
/// behaviour below this branch is byte-for-byte unchanged.
pub fn msg(comptime fmt: []const u8, args: anytype) noreturn {
    if (diag.format == .json) {
        diag.emitFatal(fmt, args);
        std.process.exit(1);
    }
    std.debug.print(fmt, args);
    if (builtin.mode == .Debug) std.debug.panic("\n\n(Zigapagos debug stack trace)\n", .{});
    std.process.exit(1);
}

/// Print an explicitly-requested help/usage message and exit successfully.
///
/// Use this for `--help`/`-h`, where showing usage is the intended outcome.
/// Unlike `msg`, this never panics in debug builds and exits 0: a user asking
/// for help did not make an error. (`msg` is for errors — it panics under a
/// debug build and exits 1.)
pub fn usage(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(0);
}

/// Print a user-facing CLI usage error and exit non-zero WITHOUT a debug stack
/// trace. Unlike `msg` — which panics in debug builds to surface internal Zigapagos
/// bugs with a trace — a usage error (missing/invalid argument) is the caller's
/// input mistake, not a Zigapagos bug, so a stack trace is noise. Use for argument
/// validation in CLI commands.
pub fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    if (diag.format == .json) {
        diag.emitFatal(fmt, args);
        std.process.exit(1);
    }
    std.debug.print(fmt, args);
    std.process.exit(1);
}

pub fn oom() noreturn {
    msg("oom\n", .{});
}

pub fn dir(path: []const u8, err: anyerror) noreturn {
    msg("error accessing dir '{s}': {t}\n", .{ path, err });
}

pub fn file(path: []const u8, err: anyerror) noreturn {
    msg("error accessing file '{s}': {t}\n", .{ path, err });
}

const help_menu =
    \\Usage: zigapagos [COMMAND] [OPTIONS]
    \\
    \\Commands:
    \\  dev               Build the site, serve it with the STOCK ZigBase
    \\                    binary, and rebuild on source changes
    \\  doctor [DIR]      Audit a BUILT site tree (default 'public') for
    \\                    root-relative social-meta URLs and dangling links
    \\  init              Initialize a Zigapagos site in the current directory
    \\  migrate <dir>     Scan an Astro project and write a MIGRATION.md worklist
    \\  release           Create a release of a Zigapagos site
    \\  validate          Parse + analyze the site WITHOUT bundling islands,
    \\                    running Bun, or writing output (a fast subset of
    \\                    `release`'s checks; see `zigapagos validate --help`)
    \\  explain <route>   Report the content file, layout chain, frontmatter,
    \\                    islands, assets and EMITTED PATHS behind one output
    \\                    route
    \\  e2e               Serve a built site with ZigBase and run an e2e command
    \\  languages         List code-fence languages registered for highlighting
    \\  explain-code      Print the long-form explanation for a diagnostic CODE
    \\    [CODE]          (or list every code with no argument); see
    \\                    'release --format=json'
    \\  help              Show this menu and exit
    \\  version           Print the Zigapagos version and exit
    \\  serve             Start the bundled preview server: builds the site in
    \\                    memory, serves it, rebuilds and reloads the browser
    \\                    on change. Needs nothing but this binary. Same as
    \\                    running zigapagos with no command at all. Reach for
    \\                    'zigapagos dev' once the site has a backend -- it
    \\                    serves the real release tree from ZigBase, so /api is
    \\                    same-origin instead of proxied
    \\
    \\General Options:
    \\  --drafts          Enable draft pages
    \\  --allow-missing-pages  Tolerate a dangling $link.page/$site.page
    \\                    reference to a page that doesn't exist YET (emits its
    \\                    would-be href + a build-log warning instead of
    \\                    failing the build). Accepted by 'release' and by the
    \\                    live server; for 'dev', set it in your build.zig
    \\                    (zigapagos.Options.allow_missing_pages) instead --
    \\                    'dev' re-runs your rebuild command rather than
    \\                    building the site itself
    \\  --help, -h        Print command specific usage and extra options
    \\
    \\Dev loop (zigapagos dev [OPTIONS] [-- REBUILD-CMD [ARGS...]]):
    \\  Runs the rebuild command (default 'zig build'), boots the STOCK
    \\  zigbase binary over the built site, watches the site's inputs, and
    \\  re-runs the rebuild command on change. The browser live-reloads after
    \\  each rebuild (on by default); pass --no-live-reload for
    \\  release-fidelity bundles.
    \\  --site=DIR        Built site tree to serve (required)
    \\  --data-dir=DIR    ZigBase data dir (default '.zigbase' at the site
    \\                    root; PERSISTENT across dev sessions — gitignore it)
    \\  --zigbase=PATH    ZigBase binary (default: PATH, then the pinned cache)
    \\  --download-zigbase  If none is found, fetch the pinned release into the
    \\                      cache (SHA256-verified); never done without this flag
    \\  --zigbase-arg=A   Override the serve invocation (repeatable; default:
    \\                    serve --http-host {{host}} --http-port {{port}}
    \\                          --data-dir {{data}} --serve-static {{site}}
    \\                          --insecure-cookies)
    \\  --host=IP         Listening address (default 127.0.0.1)
    \\  --port=N          Listening port (default 1990; 0 = pick a free port)
    \\  --ready-path=P    Readiness probe path (default '/')
    \\  --timeout-ms=N    Readiness budget in ms (default 120000)
    \\  --debounce=MS     Quiet window before a rebuild (default 25)
    \\  --no-live-reload  Disable browser live reload (release-fidelity)
    \\  --reload-port=N   SSE reload-server port (default 0 = pick a free port)
    \\  --watch-dir=DIR   Watch an extra directory (repeatable)
    \\
    \\Preview server (zigapagos serve, or no command at all):
    \\  --host HOST       Listening host (default 'localhost')
    \\  --port PORT       Listening port (default 1990)
    \\  --debounce <ms>   Rebuild delay after a file change (default 25)
    \\
    \\End-to-end testing (zigapagos e2e ... -- CMD [ARGS...]):
    \\  Boots the STOCK zigbase binary over the built site on a free port,
    \\  waits until 'GET ready-path' returns 200, runs CMD with
    \\  ZIGAPAGOS_ORIGIN set to the server origin, tears zigbase down, and
    \\  exits with CMD's exit code.
    \\  --site=DIR        Built site tree to serve (required)
    \\  --data-dir=DIR    ZigBase data dir (default: fresh temp dir per run)
    \\  --zigbase=PATH    ZigBase binary (default: PATH, then the pinned cache)
    \\  --download-zigbase  If none is found, fetch the pinned release into the
    \\                      cache (SHA256-verified); never done without this flag
    \\  --zigbase-arg=A   Override the serve invocation (repeatable; default:
    \\                    serve --http-host {{host}} --http-port {{port}}
    \\                          --data-dir {{data}} --serve-static {{site}};
    \\                    e2e substitutes 127.0.0.1 for {{host}})
    \\  --ready-path=P    Readiness probe path (default '/')
    \\  --timeout-ms=N    Readiness budget in ms (default 120000)
    \\
    \\
;

/// Show the top-level help menu for an explicit help request and exit 0.
pub fn help() noreturn {
    std.debug.print(help_menu, .{});
    std.process.exit(0);
}

/// Show the top-level help menu after an error and exit 1. Use this on error
/// paths that print a diagnostic and then the menu (a bad invocation is still
/// a failure, even though the menu is helpful).
///
/// Deliberately stays TEXT-ONLY in JSON mode (unlike `msg`/`usageError`): it
/// prints the usage menu, not a diagnostic, and there is no sensible NDJSON
/// shape for "here is the whole command reference." A real consequence: the
/// missing-`zigapagos.ziggy` path (root.zig's config loader, which calls this
/// after `std.debug.print`-ing prose) still prints plain text even under
/// `--format=json` -- see docs/diagnostics.md, which documents this as a
/// known exception rather than a bug.
pub fn helpError() noreturn {
    std.debug.print(help_menu, .{});
    std.process.exit(1);
}

test "serve is a listed command and the help menu deprecates nothing" {
    // Issue #56: `init` told a new user to run the bare command, main.zig called
    // what that starts "the deprecated live server", and the help menu carried a
    // removal notice for it — while `dev`, the thing it pointed at, needs a
    // --site, a rebuild command and a zigbase binary a fresh scaffold has none of.
    // The resolution is that the bundled server is the supported preview, so the
    // menu must list `serve` as a command (docs and this project's own e2e scripts
    // have spelled it that way for a year) and must not carry deprecation copy the
    // tool itself tells people to trigger.
    // Match the COMMANDS-COLUMN ROW, not the bare word. "serve" is a substring of
    // "server", "preview server", "serves" and "--serve-static", all of which this
    // menu contains in prose -- `indexOf(help_menu, "serve")` was already true of
    // the PRE-fix menu ("Start the bundled live server"), so it would have pinned
    // nothing. A line beginning with the two-space command indent and the exact
    // name is the listing itself.
    const serve_row = std.mem.indexOf(u8, help_menu, "\n  serve ") orelse
        return error.ServeIsNotListedAsACommand;
    // ...and it has to be in the Commands block. The word also occurs in the
    // options prose and in the "Preview server (zigapagos serve, ...)" heading
    // further down, neither of which makes it an invocable command.
    try std.testing.expect(serve_row > std.mem.indexOf(u8, help_menu, "Commands:").?);
    try std.testing.expect(serve_row < std.mem.indexOf(u8, help_menu, "General Options:").?);
    try std.testing.expect(std.mem.indexOf(u8, help_menu, "DEPRECATED") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_menu, "Deprecated") == null);
    // The pointer to the full-fidelity loop is the other half of the decision:
    // dropping the warning without saying when to reach for `dev` would just make
    // the menu quieter, not more honest.
    try std.testing.expect(std.mem.indexOf(u8, help_menu, "zigapagos dev") != null);
}

test "help menu describes live reload (on by default) and its opt-out flags" {
    // Live reload is on by default (dev.zig: live_reload = true);
    // the top-level help must not tell users there is "No live reload", and
    // must list the two opt-out flags that dev.zig's own usage carries.
    try std.testing.expect(std.mem.indexOf(u8, help_menu, "No live reload") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_menu, "live-reloads") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_menu, "--no-live-reload") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_menu, "--reload-port=N") != null);
}
