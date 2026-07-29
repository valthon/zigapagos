const std = @import("std");
const fatal = @import("../fatal.zig");
const diag = @import("../diag.zig");

/// `zigapagos explain-code [CODE]` (issue #46 / DX-27): print the long-form
/// explanation for a diagnostic code, or list every registered code with its
/// one-line summary when called with no argument.
///
/// **Why not `explain`.** Issue #46 spells the long form as a `--explain
/// <CODE>` FLAG on `release`; this branch made it a subcommand instead
/// (mirrors `zigapagos languages`, needs no `io`/`gpa`, and a flag on
/// `release` would have to short-circuit an actual build). Issue #47 then
/// shipped `zigapagos explain <route>` -- route introspection -- in
/// `explain.zig`, which is a different noun with a different argument
/// grammar, so this one takes the adjacent `explain-code` name rather than
/// contending for `explain`.
///
/// The two are NOT merged into one dispatching command even though their
/// argument grammars happen to be disjoint (a route must start with `/`; a
/// code is a member of a closed, gated enum). Overloading one verb on the
/// SHAPE of its argument means `explain --help` has to document two unrelated
/// commands, and the no-argument forms disagree about what to do -- route
/// mode has nothing to list. `explain.zig`'s route-miss path points here when
/// the argument parses as a diagnostic code, which is the discoverability
/// that unification would have bought.
///
/// No test blocks here on purpose, same reason as `languages.zig`: this file
/// only formats output; the logic worth testing (`diag.info`'s exhaustive
/// switch, the frozen-registry checks) is tested in `src/diag.zig`.
///
/// Takes no `io`/`gpa`: like `languages`, this neither touches the
/// filesystem nor allocates.
///
/// Output goes to STDERR (`std.debug.print`), not stdout -- same stream as
/// the NDJSON diagnostics this explains, and the same convention as
/// `languages.zig`. Review of PR #73 correctly noted stdout would pipe
/// better; `docs/diagnostics.md`'s Scope item 11 says why that is a CLI-wide
/// follow-up rather than a change to this one command.
pub fn explainCode(args: []const []const u8) bool {
    var code_arg: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            fatal.usage(help_message, .{});
        }
        if (code_arg != null) {
            fatal.usageError("error: unexpected extra argument '{s}'\n", .{arg});
        }
        code_arg = arg;
    }

    const code_str = code_arg orelse {
        listAll();
        return false;
    };

    const code = std.meta.stringToEnum(diag.Code, code_str) orelse {
        fatal.usageError(
            "error: unknown diagnostic code '{s}'\n\n" ++
                "run 'zigapagos explain-code' with no argument to list every code\n",
            .{code_str},
        );
    };

    const i = diag.info(code);
    std.debug.print("{s}\n{s}\n\n{s}\n", .{ @tagName(code), i.summary, i.explanation });
    return false;
}

fn listAll() void {
    inline for (@typeInfo(diag.Code).@"enum".fields) |field| {
        const code: diag.Code = @enumFromInt(field.value);
        const i = diag.info(code);
        std.debug.print("{s}  {s}\n", .{ field.name, i.summary });
    }
}

const help_message =
    \\Usage: zigapagos explain-code [CODE]
    \\
    \\Print the long-form explanation for a machine-readable diagnostic code
    \\(see 'zigapagos release --format=json'). With no CODE, list every
    \\registered code and its one-line summary instead.
    \\
    \\Issue #46 refers to this as '--explain <CODE>'; that is spelled
    \\'zigapagos explain-code <CODE>' here. To introspect a ROUTE rather than
    \\a diagnostic code, see 'zigapagos explain <route>'.
    \\
    \\Output is written to stderr, the same stream as the JSON diagnostics,
    \\so redirect with 2>&1 to pipe it.
    \\
    \\Command specific options:
    \\  --help, -h   Show this help menu
    \\
    \\
;
