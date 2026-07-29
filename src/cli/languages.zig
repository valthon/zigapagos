const std = @import("std");
const syntax = @import("syntax");
const fatal = @import("../fatal.zig");

/// `zigapagos languages` (issue #31): print every code-fence language
/// flow_syntax registers -- name, extensions, description -- plus the two
/// specials `languageExists` (src/worker.zig) accepts outside that registry,
/// `=html` and `=mathtex`. Exists so a rejected/warned-on fence language has
/// somewhere to look instead of "guess, build, fail, guess again".
///
/// No test blocks here on purpose (see CLAUDE.md's constraint for this file):
/// the one piece of logic worth testing, the did-you-mean matcher, lives in
/// src/languages.zig and is tested there. This file only formats output.
///
/// Takes no `io`/`gpa`: unlike every other CLI command, this one neither
/// touches the filesystem nor allocates, so those parameters (which the
/// dispatch in main.zig would otherwise pass by convention) would be dead.
pub fn languages(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            fatal.usage(help_message, .{});
        }
        fatal.usageError("error: unexpected cli argument '{s}'\n", .{arg});
    }

    for (syntax.FileType.get_all()) |ft| {
        std.debug.print("{s} (", .{ft.name});
        for (ft.extensions, 0..) |ext, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{ext});
        }
        std.debug.print("): {s}\n", .{ft.description});
    }

    std.debug.print("=html (no extensions): raw HTML passthrough, not highlighted\n", .{});
    std.debug.print("=mathtex (no extensions): inline math directive\n", .{});

    return false;
}

const help_message =
    \\Usage: zigapagos languages
    \\
    \\Print every code-fence / $code language registered for syntax
    \\highlighting: its name, its recognized extensions, and a description.
    \\Also lists the two specials, =html and =mathtex, that are accepted
    \\outside that registry.
    \\
    \\Command specific options:
    \\  --help, -h   Show this help menu
    \\
    \\
;
