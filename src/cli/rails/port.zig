//! The three PURE analyses #167 Stage 4 needs before it can offer `island`
//! on a Stimulus controller, a React root or an `ivar`-shaped record region,
//! plus the ERB-region -> JS string-templating port those islands render
//! with.
//!
//! **This module never touches the filesystem.** Every input is bytes or a
//! path the caller already read (`JsSource`, `fragments.Node`,
//! `convert.Context`); every output is a value. `scaffold.zig` owns the
//! reading and the writing, `findings.zig`/`decisions.zig` own the
//! questions, and this file owns only the question "what does this source
//! say, and can it be followed?". That boundary is what lets the whole file
//! be tested from string literals with no tmpdir, and it is deliberate:
//! Stage 3 learned that an analysis which reads its own files cannot be
//! swept with a `FailingAllocator` without a directory fixture per case.
//!
//! Nothing here claims behavioural parity (plan assumption B1). The Stimulus
//! port is STRUCTURAL: names, targets, values, classes and the shape of each
//! `data-action` descriptor. Method bodies are carried across as quoted
//! source for a human to finish, and this module hands the caller the exact
//! slices to quote. Arrow-function class fields (`go = (event) => { … }`) are
//! not method declarations and are a documented limit of that structural read.

const std = @import("std");
const Allocator = std.mem.Allocator;

const convert = @import("convert.zig");
const fragments = @import("fragments.zig");
const resolve = @import("resolve.zig");
const routes_mod = @import("routes.zig");

/// One JavaScript/TypeScript file the caller has already read, keyed by its
/// APP-RELATIVE path (`app/javascript/controllers/reveal_controller.js`).
/// Both fields are BORROWED and must outlive every result derived from them:
/// `Controller.methods[i].source` and `Import.spec` are sub-slices of
/// `bytes`, not copies. Copying them would double the peak memory of a scan
/// whose whole point is to quote source back into a scaffold.
pub const JsSource = struct {
    path: []const u8,
    bytes: []const u8,
};

// ---- (a) Stimulus controller ---------------------------------------------

/// The five types Stimulus's own `values` reference defines (Array, Boolean,
/// Number, Object, String -- verified against
/// https://stimulus.hotwired.dev/reference/values). Spelled lower-case here
/// because the enum is a Zig tag, not the JS identifier; `valueType` maps the
/// source spelling in.
pub const ValueType = enum { string, number, boolean, array, object };

/// One entry of `static values`. Named rather than anonymous (the plan's
/// interface sketch wrote it inline) so `scaffold.zig` can declare a
/// variable of it; the fields are the sketch's, unchanged.
pub const Value = struct {
    name: []const u8,
    kind: ValueType,
};

/// One method declared at class-body depth 1. `source` is the header through
/// the matching `}`, borrowed from the file -- assumption B1's quoted body.
pub const Method = struct {
    name: []const u8,
    source: []const u8,
};

pub const Controller = struct {
    identifier: []const u8,
    path: []const u8,
    targets: []const []const u8,
    values: []const Value,
    classes: []const []const u8,
    methods: []const Method,
    /// The lifecycle callbacks the file DOES define, in source order:
    /// `constructor`, `initialize`, `connect`, `disconnect` and any
    /// `*TargetConnected`/`*TargetDisconnected`/`*ValueChanged`. They are
    /// excluded from `methods` because binding a `data-action` to one would
    /// be wrong, but assumption B1 requires the generated island's header
    /// comment to NAME them ("their presence is noted in the header
    /// comment"), which is impossible if the scan drops them silently.
    lifecycle: []const []const u8,
    /// `null` when the port follows the file; else why it cannot, in a
    /// sentence fit for a finding message.
    unsupported: ?[]const u8,
};

/// Contract 3 (caller-buffer): allocates nothing; the result is a sub-slice
/// of `buf`.
///
/// `reveal` -> `app/javascript/controllers/reveal_controller`;
/// `admin--users` -> `app/javascript/controllers/admin/users_controller`
/// (Stimulus's own `--` namespace separator); a `-` INSIDE a segment ->
/// `_` (`date-picker` -> `date_picker_controller`).
///
/// Returns an EMPTY slice for an identifier that cannot fit in `buf` (the
/// prefix and suffix cost 38 bytes, so that means an identifier over ~470
/// characters) or for an empty one. `stimulusSource` reads an empty stem as
/// "no such controller" and answers `null`; a panic or a truncated path
/// would either crash a build or silently name the wrong file.
/// Degenerate identifiers such as `--` or one ending in `-` are mapped
/// mechanically; their odd paths simply match no source entry.
pub fn controllerStem(buf: *[512]u8, identifier: []const u8) []const u8 {
    const prefix = "app/javascript/controllers/";
    const suffix = "_controller";
    if (identifier.len == 0) return buf[0..0];
    if (prefix.len + identifier.len + suffix.len > buf.len) return buf[0..0];

    @memcpy(buf[0..prefix.len], prefix);
    var n: usize = prefix.len;
    var i: usize = 0;
    while (i < identifier.len) {
        if (i + 1 < identifier.len and identifier[i] == '-' and identifier[i + 1] == '-') {
            buf[n] = '/';
            n += 1;
            i += 2;
            continue;
        }
        buf[n] = if (identifier[i] == '-') '_' else identifier[i];
        n += 1;
        i += 1;
    }
    @memcpy(buf[n..][0..suffix.len], suffix);
    return buf[0 .. n + suffix.len];
}

/// The extensions tried against `controllerStem`, in the order the plan
/// fixes: the first one present in `sources` wins, so a `.js` controller
/// beside a stale `.ts` one is read.
const controller_exts = [_][]const u8{ ".js", ".ts", ".jsx", ".tsx" };

/// Contract 2 (owned-result), released with `freeController`: the five
/// slices and `unsupported` are fresh `gpa` allocations, but every STRING
/// inside them borrows the matched `JsSource.bytes` (`Method.source` is the
/// method's own source text, which assumption B1 quotes into the island).
/// `sources` must therefore outlive the result.
///
/// `null` -- distinct from a `Controller` carrying `unsupported` -- means no
/// entry of `sources` is this identifier's controller file at all. The
/// caller's two questions are different: "there is no such controller" is a
/// missing source, "there is one and it cannot be followed" is a refusal
/// with a reason, and Task 3 phrases a different message for each.
///
/// `sources` must be sorted by the caller for deterministic results when two
/// entries share a candidate path prefix.
pub fn stimulusSource(
    gpa: Allocator,
    identifier: []const u8,
    sources: []const JsSource,
) Allocator.Error!?Controller {
    var stem_buf: [512]u8 = undefined;
    const stem = controllerStem(&stem_buf, identifier);
    if (stem.len == 0) return null;

    var found: ?JsSource = null;
    ext: for (controller_exts) |ext| {
        for (sources) |s| {
            if (s.path.len != stem.len + ext.len) continue;
            if (!std.mem.startsWith(u8, s.path, stem)) continue;
            if (!std.mem.eql(u8, s.path[stem.len..], ext)) continue;
            found = s;
            break :ext;
        }
    }
    const src = found orelse return null;

    var scan: Scan = .{ .gpa = gpa, .src = src.bytes };
    errdefer scan.deinit();
    try scan.run();

    if (scan.bad != null) {
        // Partial results are NOT handed back beside a refusal: every caller
        // of this function treats `unsupported != null` as "do not offer
        // `island`", and a half-read target list is a fact about the
        // scanner's failure point, not about the controller.
        const why = scan.bad.?;
        scan.bad = null;
        scan.deinit();
        return .{
            .identifier = identifier,
            .path = src.path,
            .targets = &.{},
            .values = &.{},
            .classes = &.{},
            .methods = &.{},
            .lifecycle = &.{},
            .unsupported = why,
        };
    }

    // One `toOwnedSlice` per line with its own `errdefer`: a bare struct
    // literal of five `try`s leaks every slice that was handed over before
    // the one that failed, because `scan.deinit` sees those lists already
    // emptied.
    const targets = try scan.targets.toOwnedSlice(gpa);
    errdefer gpa.free(targets);
    const values = try scan.values.toOwnedSlice(gpa);
    errdefer gpa.free(values);
    const classes = try scan.classes.toOwnedSlice(gpa);
    errdefer gpa.free(classes);
    const methods = try scan.methods.toOwnedSlice(gpa);
    errdefer gpa.free(methods);
    const lifecycle = try scan.lifecycle.toOwnedSlice(gpa);
    errdefer gpa.free(lifecycle);

    return .{
        .identifier = identifier,
        .path = src.path,
        .targets = targets,
        .values = values,
        .classes = classes,
        .methods = methods,
        .lifecycle = lifecycle,
        .unsupported = null,
    };
}

pub fn freeController(gpa: Allocator, c: Controller) void {
    gpa.free(c.targets);
    gpa.free(c.values);
    gpa.free(c.classes);
    gpa.free(c.methods);
    gpa.free(c.lifecycle);
    if (c.unsupported) |u| gpa.free(u);
}

// ---- the lexical scan (a) and (d) share ----------------------------------
//
// Both analyses read JavaScript WITHOUT parsing it, which the plan states
// outright ("lexical, and the plan says so"). The one thing a lexical reader
// must get right is which bytes are code: `skipLexical` steps over a `//`
// line comment, a `/* */` block comment and a `'`/`"`/backtick string so a
// brace, a `#` or the word `import` inside one is never read as syntax.
//
// The Stimulus scan deliberately does NOT consume a REGEX literal. `/{/`
// therefore leaves an unmatched `{` and is refused, which is the documented
// limit pinned below. It recognises regex POSITION only far enough to refuse
// contents that would otherwise masquerade as strings/comments and hide a
// method. `reactImports` can skip safe runs because it does not count braces;
// both refuse when the lexical structure cannot be followed.

/// Contract 3 (caller-buffer): allocates nothing. Returns the index just
/// past the comment or string starting at `i`, or `i` when nothing there
/// opens one. An unterminated string/template consumes the rest of `src` and
/// reports through `unterminated` when the caller needs a lexical refusal.
fn skipLexical(src: []const u8, i: usize, unterminated: ?*bool) usize {
    if (i >= src.len) return i;
    switch (src[i]) {
        '/' => return skipComment(src, i),
        '"', '\'' => {
            const q = src[i];
            var j = i + 1;
            while (j < src.len) : (j += 1) {
                if (src[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (src[j] == q) return j + 1;
            }
            if (unterminated) |u| u.* = true;
            return src.len;
        },
        '`' => {
            // A template literal's `${ … }` holds real code, but nothing
            // either analysis reads can live inside one -- so the whole
            // literal is skipped, with substitutions depth-counted so a `}`
            // inside one cannot close a class body.
            var j = i + 1;
            var depth: usize = 0;
            while (j < src.len) : (j += 1) {
                if (src[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (depth == 0 and src[j] == '`') return j + 1;
                if (src[j] == '$' and j + 1 < src.len and src[j + 1] == '{') {
                    depth += 1;
                    j += 1;
                    continue;
                }
                if (depth > 0 and src[j] == '}') depth -= 1;
            }
            if (unterminated) |u| u.* = true;
            return src.len;
        },
        else => return i,
    }
}

const RegexRun = struct {
    end: usize,
    dangerous: bool,
    unterminated: bool,
};

/// A deliberately narrow regex-position heuristic. The structural scanner
/// does not otherwise consume regexes (so its pinned `/{/` refusal remains),
/// but it must identify a prospective run before a quote inside it can be
/// mistaken for a JS string and silently hide methods or imports.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn regexRun(src: []const u8, at: usize) ?RegexRun {
    if (at >= src.len or src[at] != '/' or !isRegexPosition(src, at)) return null;
    if (at + 1 < src.len and (src[at + 1] == '/' or src[at + 1] == '*')) return null;

    var dangerous = false;
    var in_class = false;
    var i = at + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\') {
            if (i + 1 < src.len and (src[i + 1] == '\'' or src[i + 1] == '"' or src[i + 1] == '`')) {
                dangerous = true;
            }
            i += 1;
            continue;
        }
        if (src[i] == '\'' or src[i] == '"' or src[i] == '`') dangerous = true;
        if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '*') dangerous = true;
        if (src[i] == '[') in_class = true;
        if (src[i] == ']') in_class = false;
        if (src[i] == '/' and !in_class) {
            i += 1;
            while (i < src.len and std.ascii.isAlphabetic(src[i])) i += 1;
            return .{ .end = i, .dangerous = dangerous, .unterminated = false };
        }
        if (src[i] == '\n' or src[i] == '\r') break;
    }
    return .{ .end = src.len, .dangerous = dangerous, .unterminated = true };
}

/// Contract 3 (caller-buffer): allocates nothing.
fn isRegexPosition(src: []const u8, at: usize) bool {
    // `</name>` is a JSX close tag, not a regex after the `<` operator.
    if (at > 0 and at + 1 < src.len and src[at - 1] == '<' and std.ascii.isAlphabetic(src[at + 1])) return false;
    var i = at;
    while (i > 0) {
        i -= 1;
        if (std.ascii.isWhitespace(src[i])) continue;
        if (std.mem.indexOfScalar(u8, "=([{,:;!&|?+-*%^~<>", src[i]) != null) return true;
        if (!isIdentChar(src[i])) return false;
        const end = i + 1;
        while (i > 0 and isIdentChar(src[i - 1])) i -= 1;
        const word = src[i..end];
        inline for (.{ "return", "throw", "case", "delete", "typeof", "void", "new", "in", "instanceof", "yield", "await" }) |keyword| {
            if (std.mem.eql(u8, word, keyword)) return true;
        }
        return false;
    }
    return true;
}

/// The first regex run that can derail the lexical read. Safe runs are only
/// stepped over for this audit; the structural parser still sees their bytes.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn badRegex(src: []const u8) ?RegexRun {
    var i: usize = 0;
    while (i < src.len) {
        const lexical = skipLexical(src, i, null);
        if (lexical != i) {
            i = lexical;
            continue;
        }
        if (regexRun(src, i)) |run| {
            if (run.dangerous or run.unterminated) return run;
            i = run.end;
            continue;
        }
        i += 1;
    }
    return null;
}

/// Contract 3 (caller-buffer): allocates nothing. Split out of `skipLexical`
/// because whitespace-and-comments is TRIVIA between tokens while a string
/// is a token: `skipTrivia` must step over the first and stop at the second.
fn skipComment(src: []const u8, i: usize) usize {
    if (i + 1 >= src.len or src[i] != '/') return i;
    if (src[i + 1] == '/') {
        var j = i + 2;
        while (j < src.len and src[j] != '\n') j += 1;
        return j;
    }
    if (src[i + 1] == '*') {
        var j = i + 2;
        while (j + 1 < src.len) : (j += 1) {
            if (src[j] == '*' and src[j + 1] == '/') return j + 2;
        }
        return src.len;
    }
    return i;
}

/// Contract 3 (caller-buffer): allocates nothing.
fn skipTrivia(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len) {
        if (std.ascii.isWhitespace(src[i])) {
            i += 1;
            continue;
        }
        const j = skipComment(src, i);
        if (j != i) {
            i = j;
            continue;
        }
        break;
    }
    return i;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c == '#';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '#';
}

/// Contract 3 (caller-buffer): allocates nothing. The index just past the
/// identifier at `i`, or `i` when there is none.
fn identEnd(src: []const u8, i: usize) usize {
    if (i >= src.len or !isIdentStart(src[i])) return i;
    var j = i + 1;
    while (j < src.len and isIdentChar(src[j])) j += 1;
    return j;
}

/// The index just past the `close` that matches the `open` at `from`, or
/// null when the source runs out first. Strings and comments are skipped, so
/// a brace in either cannot close a block; a regex literal is not (see the
/// section header).
///
/// Contract 3 (caller-buffer): allocates nothing.
fn matchDelimiter(src: []const u8, from: usize, open: u8, close: u8) ?usize {
    if (from >= src.len or src[from] != open) return null;
    var depth: usize = 0;
    var i = from;
    while (i < src.len) {
        const j = skipLexical(src, i, null);
        if (j != i) {
            i = j;
            continue;
        }
        if (src[i] == open) depth += 1;
        if (src[i] == close) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
        i += 1;
    }
    return null;
}

/// The lexical read of one `export default class … { … }`.
const Scan = struct {
    gpa: Allocator,
    src: []const u8,
    targets: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList(Value) = .empty,
    classes: std.ArrayList([]const u8) = .empty,
    methods: std.ArrayList(Method) = .empty,
    lifecycle: std.ArrayList([]const u8) = .empty,
    /// The FIRST refusal, owned by this scan until `stimulusSource` takes it.
    bad: ?[]const u8 = null,

    fn deinit(s: *Scan) void {
        s.targets.deinit(s.gpa);
        s.values.deinit(s.gpa);
        s.classes.deinit(s.gpa);
        s.methods.deinit(s.gpa);
        s.lifecycle.deinit(s.gpa);
        if (s.bad) |b| s.gpa.free(b);
    }

    /// The message is formatted into a LOCAL before it is stored. Assigning
    /// `s.bad = try allocPrint(…)` instead lets Zig's result location write
    /// the optional in place and a failing `try` leave it half-written --
    /// which `deinit` then frees, faulting on a pointer that was never
    /// allocated. Cheap to write, ugly to debug.
    fn fail(s: *Scan, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        if (s.bad != null) return;
        const why = try std.fmt.allocPrint(s.gpa, fmt, args);
        s.bad = why;
    }

    fn run(s: *Scan) Allocator.Error!void {
        if (badRegex(s.src) != null) return s.fail(
            "a regex literal whose contents this lexical port cannot follow safely",
            .{},
        );
        const open = s.classBodyOpen() orelse
            return s.fail("the controller file is not an `export default class`", .{});
        try s.members(open + 1);
    }

    /// The index of the `{` that opens the exported class's body.
    ///
    /// The plan words this as "the first `{` after `extends Controller` (or
    /// `extends` anything)"; what is actually searched for is the first `{`
    /// after the `class` keyword at paren/bracket depth 0, which is the same
    /// brace whenever an `extends` clause is present and still finds the
    /// body of a controller written without one.
    fn classBodyOpen(s: *Scan) ?usize {
        var i: usize = 0;
        while (i < s.src.len) {
            const j = skipLexical(s.src, i, null);
            if (j != i) {
                i = j;
                continue;
            }
            const end = identEnd(s.src, i);
            if (end == i) {
                i += 1;
                continue;
            }
            if (!std.mem.eql(u8, s.src[i..end], "export")) {
                i = end;
                continue;
            }
            const d = skipTrivia(s.src, end);
            const d_end = identEnd(s.src, d);
            if (d_end == d or !std.mem.eql(u8, s.src[d..d_end], "default")) {
                i = end;
                continue;
            }
            const c = skipTrivia(s.src, d_end);
            const c_end = identEnd(s.src, c);
            if (c_end == c or !std.mem.eql(u8, s.src[c..c_end], "class")) {
                i = end;
                continue;
            }
            return s.headerBrace(c_end);
        }
        return null;
    }

    fn headerBrace(s: *Scan, from: usize) ?usize {
        var depth: usize = 0;
        var i = from;
        while (i < s.src.len) {
            const j = skipLexical(s.src, i, null);
            if (j != i) {
                i = j;
                continue;
            }
            switch (s.src[i]) {
                '(', '[' => depth += 1,
                ')', ']' => if (depth > 0) {
                    depth -= 1;
                },
                '{' => if (depth == 0) return i,
                ';' => return null,
                else => {},
            }
            i += 1;
        }
        return null;
    }

    /// The class body, one member per iteration, at depth 1.
    fn members(s: *Scan, from: usize) Allocator.Error!void {
        var i = from;
        while (true) {
            if (s.bad != null) return;
            i = skipTrivia(s.src, i);
            if (i >= s.src.len) return s.fail(
                "the controller's class body never closes (unbalanced braces -- a regex literal holding `{{` is the known cause)",
                .{},
            );
            switch (s.src[i]) {
                '}' => return,
                ';' => {
                    i += 1;
                    continue;
                },
                '[' => return s.fail("a computed member key at class-body level", .{}),
                else => {},
            }

            var is_static = false;
            // `static` is a modifier only when something follows it; `static
            // () {}` would be a method whose name is `static`.
            const st_end = identEnd(s.src, i);
            if (st_end != i and std.mem.eql(u8, s.src[i..st_end], "static")) {
                const after = skipTrivia(s.src, st_end);
                if (after < s.src.len and (isIdentStart(s.src[after]) or s.src[after] == '{' or
                    s.src[after] == '[' or s.src[after] == '*' or s.src[after] == '"' or s.src[after] == '\''))
                {
                    is_static = true;
                    i = after;
                    if (s.src[i] == '{') {
                        // A `static { … }` initialisation block declares no
                        // member; skip it whole.
                        i = matchDelimiter(s.src, i, '{', '}') orelse
                            return s.fail("a `static` block that never closes", .{});
                        continue;
                    }
                    if (s.src[i] == '[') return s.fail("a computed member key at class-body level", .{});
                }
            }

            // Everything from here is the member's own source, which is what
            // `Method.source` quotes: `async` included, `static` excluded
            // (a static method is never an action handler).
            const member_start = i;

            const w_end = identEnd(s.src, i);
            if (w_end != i) {
                const w = s.src[i..w_end];
                const after = skipTrivia(s.src, w_end);
                const names_something = after < s.src.len and
                    (isIdentStart(s.src[after]) or s.src[after] == '[' or s.src[after] == '*' or
                        s.src[after] == '"' or s.src[after] == '\'');
                if (names_something and (std.mem.eql(u8, w, "get") or std.mem.eql(u8, w, "set"))) {
                    const n_end = identEnd(s.src, after);
                    const label = if (n_end != after) s.src[after..n_end] else "<computed>";
                    return s.fail("an accessor (`{s} {s}`), which has no `data-action` form", .{ w, label });
                }
                if (names_something and std.mem.eql(u8, w, "async")) i = after;
            }

            if (i < s.src.len and s.src[i] == '*') i = skipTrivia(s.src, i + 1);
            if (i < s.src.len and s.src[i] == '[') return s.fail("a computed member key at class-body level", .{});

            var name: []const u8 = "";
            if (i < s.src.len and (s.src[i] == '"' or s.src[i] == '\'')) {
                const e = skipLexical(s.src, i, null);
                name = if (e > i + 1) s.src[i + 1 .. e - 1] else "";
                i = e;
            } else {
                const e = identEnd(s.src, i);
                if (e == i) return s.fail("a class member this port cannot read", .{});
                name = s.src[i..e];
                i = e;
            }

            var at = skipTrivia(s.src, i);
            // A TypeScript annotation (`targets: string[] = [...]`) sits
            // between the name and the `=`; step over it to the initialiser.
            if (at < s.src.len and s.src[at] == ':') at = s.skipAnnotation(at + 1);

            if (at < s.src.len and s.src[at] == '(') {
                i = try s.method(member_start, name, is_static, at);
                continue;
            }
            if (at < s.src.len and s.src[at] == '=' and (at + 1 >= s.src.len or s.src[at + 1] != '=')) {
                i = try s.field(name, is_static, skipTrivia(s.src, at + 1));
                continue;
            }
            // A bare field declaration (`count;`).
            i = s.skipToStatementEnd(at);
        }
    }

    /// Past a TypeScript type annotation: to the `=` that starts the
    /// initialiser, or to the declaration's end when there is none.
    fn skipAnnotation(s: *Scan, from: usize) usize {
        var depth: usize = 0;
        var i = from;
        while (i < s.src.len) {
            const j = skipLexical(s.src, i, null);
            if (j != i) {
                i = j;
                continue;
            }
            switch (s.src[i]) {
                '(', '[', '{' => depth += 1,
                ')', ']' => if (depth > 0) {
                    depth -= 1;
                },
                '}' => {
                    if (depth == 0) return i;
                    depth -= 1;
                },
                '=' => if (depth == 0) return i,
                ';', '\n' => if (depth == 0) return i,
                else => {},
            }
            i += 1;
        }
        return s.src.len;
    }

    /// A return type ends at the method body's first `{` at depth zero, not
    /// at `=`/newline like a field annotation. Keeping the two scans separate
    /// prevents `): void {` from swallowing the body opener as type syntax.
    fn skipReturnAnnotation(s: *Scan, from: usize) usize {
        var depth: usize = 0;
        var i = from;
        while (i < s.src.len) {
            const j = skipLexical(s.src, i, null);
            if (j != i) {
                i = j;
                continue;
            }
            switch (s.src[i]) {
                '(', '[', '<' => depth += 1,
                ')', ']', '>' => if (depth > 0) {
                    depth -= 1;
                },
                '{' => if (depth == 0) return i,
                ';' => if (depth == 0) return i,
                else => {},
            }
            i += 1;
        }
        return s.src.len;
    }

    /// Past a member's initialiser: the next `;` or newline at depth 0.
    fn skipToStatementEnd(s: *Scan, from: usize) usize {
        var depth: usize = 0;
        var i = from;
        while (i < s.src.len) {
            const j = skipLexical(s.src, i, null);
            if (j != i) {
                i = j;
                continue;
            }
            switch (s.src[i]) {
                '(', '[', '{' => depth += 1,
                ')', ']' => if (depth > 0) {
                    depth -= 1;
                },
                '}' => {
                    if (depth == 0) return i;
                    depth -= 1;
                },
                ';' => if (depth == 0) return i + 1,
                '\n' => if (depth == 0) return i + 1,
                else => {},
            }
            i += 1;
        }
        return s.src.len;
    }

    fn method(s: *Scan, member_start: usize, name: []const u8, is_static: bool, paren: usize) Allocator.Error!usize {
        const after_params = matchDelimiter(s.src, paren, '(', ')') orelse {
            try s.fail("the parameter list of `{s}` never closes", .{name});
            return s.src.len;
        };
        var b = skipTrivia(s.src, after_params);
        // A TypeScript return annotation (`): void {`) sits here.
        if (b < s.src.len and s.src[b] == ':') b = skipTrivia(s.src, s.skipReturnAnnotation(b + 1));
        if (b >= s.src.len or s.src[b] != '{') {
            try s.fail("`{s}` has no method body this port can read", .{name});
            return s.src.len;
        }
        const close = matchDelimiter(s.src, b, '{', '}') orelse {
            try s.fail(
                "the body of `{s}` never closes (unbalanced braces -- a regex literal holding `{{` is the known cause)",
                .{name},
            );
            return s.src.len;
        };
        // A static method is class-level, so no `data-action` can reach it
        // and no lifecycle hook is spelled that way: it is neither reported
        // nor quoted.
        if (!is_static) {
            if (isLifecycle(name)) {
                try s.lifecycle.append(s.gpa, name);
            } else {
                try s.methods.append(s.gpa, .{ .name = name, .source = s.src[member_start..close] });
            }
        }
        return close;
    }

    fn field(s: *Scan, name: []const u8, is_static: bool, value_at: usize) Allocator.Error!usize {
        if (!is_static) return s.skipToStatementEnd(value_at);
        if (std.mem.eql(u8, name, "outlets")) {
            try s.fail("`static outlets`, which this port has no island form for", .{});
            return s.src.len;
        }
        if (std.mem.eql(u8, name, "targets")) return s.stringArray(&s.targets, "targets", value_at);
        if (std.mem.eql(u8, name, "classes")) return s.stringArray(&s.classes, "classes", value_at);
        if (std.mem.eql(u8, name, "values")) return s.valueObject(value_at);
        return s.skipToStatementEnd(value_at);
    }

    fn stringArray(s: *Scan, into: *std.ArrayList([]const u8), what: []const u8, at: usize) Allocator.Error!usize {
        if (at >= s.src.len or s.src[at] != '[') {
            try s.fail("`static {s}` is not an array literal", .{what});
            return s.src.len;
        }
        const close = matchDelimiter(s.src, at, '[', ']') orelse {
            try s.fail("`static {s}` never closes", .{what});
            return s.src.len;
        };
        var i = at + 1;
        while (i < close - 1) {
            i = skipTrivia(s.src, i);
            if (i >= close - 1) break;
            if (s.src[i] == ',') {
                i += 1;
                continue;
            }
            if (s.src[i] != '"' and s.src[i] != '\'') {
                try s.fail("`static {s}` holds an entry that is not a string literal", .{what});
                return s.src.len;
            }
            const e = skipLexical(s.src, i, null);
            try into.append(s.gpa, if (e > i + 1) s.src[i + 1 .. e - 1] else "");
            i = e;
        }
        return close;
    }

    fn valueObject(s: *Scan, at: usize) Allocator.Error!usize {
        if (at >= s.src.len or s.src[at] != '{') {
            try s.fail("`static values` is not an object literal", .{});
            return s.src.len;
        }
        const close = matchDelimiter(s.src, at, '{', '}') orelse {
            try s.fail("`static values` never closes", .{});
            return s.src.len;
        };
        var i = at + 1;
        while (i < close - 1) {
            i = skipTrivia(s.src, i);
            if (i >= close - 1) break;
            if (s.src[i] == ',') {
                i += 1;
                continue;
            }
            var key: []const u8 = "";
            if (s.src[i] == '"' or s.src[i] == '\'') {
                const e = skipLexical(s.src, i, null);
                key = if (e > i + 1) s.src[i + 1 .. e - 1] else "";
                i = e;
            } else {
                const e = identEnd(s.src, i);
                if (e == i) {
                    try s.fail("`static values` has a key this port cannot read", .{});
                    return s.src.len;
                }
                key = s.src[i..e];
                i = e;
            }
            i = skipTrivia(s.src, i);
            if (i >= close - 1 or s.src[i] != ':') {
                try s.fail("`static values.{s}` has no type", .{key});
                return s.src.len;
            }
            i = skipTrivia(s.src, i + 1);
            if (i < close - 1 and s.src[i] == '{') {
                // The expanded form, `{ type: String, default: … }`.
                const inner = matchDelimiter(s.src, i, '{', '}') orelse {
                    try s.fail("`static values.{s}` never closes", .{key});
                    return s.src.len;
                };
                const t = s.typeInObject(i + 1, inner - 1) orelse {
                    try s.fail("`static values.{s}` declares no `type:`", .{key});
                    return s.src.len;
                };
                const kind = valueType(t) orelse {
                    try s.fail("`static values.{s}` names the type `{s}`, which Stimulus does not define", .{ key, t });
                    return s.src.len;
                };
                try s.values.append(s.gpa, .{ .name = key, .kind = kind });
                i = inner;
                continue;
            }
            const e = identEnd(s.src, i);
            if (e == i) {
                try s.fail("`static values.{s}` has a type this port cannot read", .{key});
                return s.src.len;
            }
            const kind = valueType(s.src[i..e]) orelse {
                try s.fail(
                    "`static values.{s}` names the type `{s}`, which Stimulus does not define",
                    .{ key, s.src[i..e] },
                );
                return s.src.len;
            };
            try s.values.append(s.gpa, .{ .name = key, .kind = kind });
            i = e;
        }
        return close;
    }

    /// The word after `type:` at depth 0 of `[from, to)`.
    fn typeInObject(s: *Scan, from: usize, to: usize) ?[]const u8 {
        var depth: usize = 0;
        var i = from;
        while (i < to) {
            const j = skipLexical(s.src, i, null);
            if (j != i) {
                i = @min(j, to);
                continue;
            }
            switch (s.src[i]) {
                '(', '[', '{' => {
                    depth += 1;
                    i += 1;
                    continue;
                },
                ')', ']', '}' => {
                    if (depth > 0) depth -= 1;
                    i += 1;
                    continue;
                },
                else => {},
            }
            const e = identEnd(s.src, i);
            if (e == i) {
                i += 1;
                continue;
            }
            if (depth == 0 and std.mem.eql(u8, s.src[i..e], "type")) {
                const c = skipTrivia(s.src, e);
                if (c < to and s.src[c] == ':') {
                    const v = skipTrivia(s.src, c + 1);
                    const v_end = identEnd(s.src, v);
                    if (v_end != v) return s.src[v..v_end];
                }
            }
            i = e;
        }
        return null;
    }
};

/// The five type names Stimulus's `values` reference defines. Anything else
/// is a refusal rather than a guess: a value whose type this port invented
/// would decode the wrong way in the generated island.
fn valueType(word: []const u8) ?ValueType {
    if (std.mem.eql(u8, word, "String")) return .string;
    if (std.mem.eql(u8, word, "Number")) return .number;
    if (std.mem.eql(u8, word, "Boolean")) return .boolean;
    if (std.mem.eql(u8, word, "Array")) return .array;
    if (std.mem.eql(u8, word, "Object")) return .object;
    return null;
}

/// Stimulus's own lifecycle callbacks: the four class-level ones plus the
/// per-target and per-value hooks. Binding a `data-action` to one of these
/// would be wrong (Stimulus calls them itself), so they are kept apart from
/// `methods` -- but NAMED, because assumption B1's header comment has to say
/// the controller had them.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn isLifecycle(name: []const u8) bool {
    const exact = [_][]const u8{ "constructor", "initialize", "connect", "disconnect" };
    for (exact) |e| {
        if (std.mem.eql(u8, name, e)) return true;
    }
    const suffixes = [_][]const u8{ "TargetConnected", "TargetDisconnected", "ValueChanged" };
    for (suffixes) |suf| {
        if (name.len > suf.len and std.mem.endsWith(u8, name, suf)) return true;
    }
    return false;
}

// ---- (b) `data-action` descriptors ---------------------------------------

pub const Descriptor = struct {
    event: []const u8,
    identifier: []const u8,
    method: []const u8,
    prevent: bool,
    stop: bool,
    selector_index: usize,
};

/// Named (the plan sketched it as an anonymous return struct) so a caller can
/// declare a variable of it.
pub const Actions = struct {
    list: []Descriptor,
    unsupported: ?[]const u8,
};

/// Contract 1 (self-freeing), NOT the plan sketch's contract 2: exactly one
/// allocation escapes (`list`), every string in it borrows `text` or is a
/// static literal, and there is no graph to own -- so `gpa.free(r.list)` is
/// the whole release and contract 2's `freeActions` would be a function that
/// calls `free` once. NO_SLOP §2.2a asks the label to be TRUE before it asks
/// it to match a sketch.
///
/// Every `data-action` attribute in `text` is read, on every tag, the
/// element's own opener included -- a Stimulus controller's actions are
/// declared throughout its scope, not on the controller element. Each
/// whitespace-separated token is
/// `(event->)?identifier#method(:prevent|:stop)*`; a token naming a
/// DIFFERENT controller is skipped in silence (one element routinely serves
/// several controllers), and `unsupported` carries the first token this port
/// cannot express: a global target (`@window`/`@document`), a keyboard
/// filter (`keydown.esc`), any option beyond `:prevent`/`:stop`, or a token
/// that is not a descriptor at all.
///
/// `selector_index` counts the tags that CARRY `data-action`, in source
/// order, so several descriptors on one tag share an index and the island
/// can address the tag by it. The count includes the extent's opening tag,
/// which `querySelectorAll` never returns; the consumer must use
/// `[root, ...root.querySelectorAll(…)]`, filtered by
/// `matches("[data-action]")`, to preserve these indexes.
pub fn actionDescriptors(
    gpa: Allocator,
    text: []const u8,
    identifier: []const u8,
) Allocator.Error!Actions {
    var list: std.ArrayList(Descriptor) = .empty;
    errdefer list.deinit(gpa);
    var unsupported: ?[]const u8 = null;
    var selector_index: usize = 0;

    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "<!--")) {
            // A commented-out element declares nothing, exactly as the
            // sidecar's own element scan (assumption B11) treats it.
            i = if (std.mem.indexOfPos(u8, text, i + 4, "-->")) |e| e + 3 else text.len;
            continue;
        }
        if (text[i] != '<' or i + 1 >= text.len or !std.ascii.isAlphabetic(text[i + 1])) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '-')) j += 1;
        const tag = text[i + 1 .. j];

        var action: ?[]const u8 = null;
        var input_type: ?[]const u8 = null;
        while (j < text.len and text[j] != '>') {
            if (std.ascii.isWhitespace(text[j]) or text[j] == '/') {
                j += 1;
                continue;
            }
            const name_start = j;
            while (j < text.len and !std.ascii.isWhitespace(text[j]) and
                text[j] != '=' and text[j] != '>' and text[j] != '/') j += 1;
            const name = text[name_start..j];
            if (name.len == 0) {
                j += 1;
                continue;
            }
            var value: []const u8 = "";
            var k = j;
            while (k < text.len and std.ascii.isWhitespace(text[k])) k += 1;
            if (k < text.len and text[k] == '=') {
                k += 1;
                while (k < text.len and std.ascii.isWhitespace(text[k])) k += 1;
                if (k < text.len and (text[k] == '"' or text[k] == '\'')) {
                    const q = text[k];
                    const start = k + 1;
                    const end = std.mem.indexOfScalarPos(u8, text, start, q) orelse text.len;
                    value = text[start..end];
                    k = @min(end + 1, text.len);
                } else {
                    const start = k;
                    while (k < text.len and !std.ascii.isWhitespace(text[k]) and text[k] != '>') k += 1;
                    value = text[start..k];
                }
                j = k;
            }
            if (std.ascii.eqlIgnoreCase(name, "data-action")) action = value;
            if (std.ascii.eqlIgnoreCase(name, "type")) input_type = value;
        }
        if (j < text.len) j += 1;
        i = if (isRawTextTag(tag)) rawTextEnd(text, j, tag) else j;

        const raw = action orelse continue;
        const index = selector_index;
        selector_index += 1;
        const default_event = defaultEvent(tag, input_type);

        var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n");
        while (tokens.next()) |token| {
            switch (parseDescriptor(token, identifier, default_event, index)) {
                .skip => {},
                .bad => if (unsupported == null) {
                    unsupported = token;
                },
                .ok => |d| try list.append(gpa, d),
            }
        }
    }

    return .{ .list = try list.toOwnedSlice(gpa), .unsupported = unsupported };
}

/// Stimulus's default-event table: `<a>`/`<button>` click, `<form>` submit,
/// `<input>`/`<textarea>` input, `<select>` change and `<details>` toggle.
/// Ruling B15 follows Stimulus's own `src/core/action.ts` over the plan's
/// tag-only table: `<input type="submit">` defaults to `click`.
///
/// Contract 3 (caller-buffer): allocates nothing; the result is a static
/// literal.
fn defaultEvent(tag: []const u8, input_type: ?[]const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(tag, "form")) return "submit";
    if (std.ascii.eqlIgnoreCase(tag, "input")) {
        if (input_type) |kind| {
            if (std.ascii.eqlIgnoreCase(kind, "submit")) return "click";
        }
        return "input";
    }
    if (std.ascii.eqlIgnoreCase(tag, "textarea")) return "input";
    if (std.ascii.eqlIgnoreCase(tag, "select")) return "change";
    if (std.ascii.eqlIgnoreCase(tag, "details")) return "toggle";
    return "click";
}

/// The four raw-text-like regions the Rails-port scan must treat as opaque.
/// `pre` is included because authored examples commonly contain ghost markup
/// even though the HTML tokenizer itself does parse elements there.
/// Contract 3 (caller-buffer): allocates nothing.
fn isRawTextTag(tag: []const u8) bool {
    inline for (.{ "script", "style", "textarea", "pre" }) |name| {
        if (std.ascii.eqlIgnoreCase(tag, name)) return true;
    }
    return false;
}

/// Just past the matching close tag, or EOF when malformed. Raw content is
/// opaque, so the first case-insensitive `</tag` is the only delimiter.
/// Contract 3 (caller-buffer): allocates nothing.
fn rawTextEnd(text: []const u8, from: usize, tag: []const u8) usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |lt| {
        const name_at = lt + 2;
        if (lt + 1 < text.len and text[lt + 1] == '/' and
            name_at + tag.len <= text.len and
            std.ascii.eqlIgnoreCase(text[name_at .. name_at + tag.len], tag))
        {
            const after = name_at + tag.len;
            if (after == text.len or std.ascii.isWhitespace(text[after]) or text[after] == '>') {
                const close = std.mem.indexOfScalarPos(u8, text, after, '>') orelse return text.len;
                return close + 1;
            }
        }
        i = lt + 1;
    }
    return text.len;
}

const ParsedDescriptor = union(enum) {
    /// The token names another controller.
    skip,
    /// The token is a descriptor this port cannot express.
    bad,
    ok: Descriptor,
};

/// Contract 3 (caller-buffer): allocates nothing; every string in the result
/// borrows `token` or is a static literal.
fn parseDescriptor(
    token: []const u8,
    identifier: []const u8,
    default_event: []const u8,
    index: usize,
) ParsedDescriptor {
    var event = default_event;
    var rest = token;
    if (std.mem.indexOf(u8, token, "->")) |arrow| {
        event = token[0..arrow];
        rest = token[arrow + 2 ..];
    }
    const hash = std.mem.indexOfScalar(u8, rest, '#') orelse return .bad;
    const who = rest[0..hash];
    const tail = rest[hash + 1 ..];
    if (who.len == 0 or tail.len == 0) return .bad;
    // Ordered so a `click@window->modal#x` on an element this controller
    // shares is SKIPPED rather than refused: an option we cannot express on
    // another controller's action is not our problem.
    if (!std.mem.eql(u8, who, identifier)) return .skip;

    // `@window`/`@document` and a `keydown.esc` filter both live in the
    // event half and both change WHERE or WHEN the listener fires, which the
    // generated island binds by element.
    if (event.len == 0) return .bad;
    if (std.mem.indexOfAny(u8, event, "@.") != null) return .bad;

    var options = std.mem.splitScalar(u8, tail, ':');
    const method = options.first();
    if (method.len == 0 or !isJsIdent(method)) return .bad;
    var prevent = false;
    var stop = false;
    while (options.next()) |opt| {
        if (std.mem.eql(u8, opt, "prevent")) {
            prevent = true;
        } else if (std.mem.eql(u8, opt, "stop")) {
            stop = true;
        } else return .bad;
    }
    return .{ .ok = .{
        .event = event,
        .identifier = identifier,
        .method = method,
        .prevent = prevent,
        .stop = stop,
        .selector_index = index,
    } };
}

/// Contract 3 (caller-buffer): allocates nothing.
fn isJsIdent(s: []const u8) bool {
    if (s.len == 0 or !isIdentStart(s[0])) return false;
    for (s[1..]) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

// ---- (c) record body -----------------------------------------------------

pub const Alias = struct {
    ruby: []const u8,
    js: []const u8,
};

pub const Unportable = struct {
    kind: fragments.Kind,
    line: u64,
    col: u64,
    why: []const u8,
};

pub const Body = struct {
    js: []u8,
    unportable: ?Unportable,
};

/// The one runtime helper a generated body assumes is in scope. Published
/// here so `scaffold.zig` writes the same bytes the goldens in this file
/// were computed against -- two spellings of an HTML escaper would be two
/// escaping tables, and the mismatch would only show as a wrong character on
/// a rendered page.
///
/// `recordBody` itself emits NO wrapper: the caller supplies the function,
/// the `let h = ""`, this helper and the `return h`.
pub const esc_helper =
    "const esc = (s: string) => s.replace(/[&<>\"']/g, c => " ++
    "({\"&\":\"&amp;\",\"<\":\"&lt;\",\">\":\"&gt;\",'\"':\"&quot;\",\"'\":\"&#39;\"}[c]!));";

/// Contract 2 (owned-result), released with `freeBody`: `js` and, when set,
/// `unportable.why` are fresh `gpa` allocations.
///
/// Emits `h += "…";` statements, one per node, under the rules the plan
/// fixes. On the FIRST node it cannot follow it stops: `js` is then empty
/// and meaningless, `unportable` says which node and why, and the caller
/// offers no island. Stopping rather than skipping is the point -- a body
/// that silently dropped the one `<%= post.author.name %>` it could not
/// express would render a card with a missing byline and nothing would say
/// so.
pub fn recordBody(
    gpa: Allocator,
    ctx: convert.Context,
    path: []const u8,
    nodes: []const fragments.Node,
    aliases: []const Alias,
) Allocator.Error!Body {
    var r: Rec = .{ .gpa = gpa, .ctx = ctx };
    defer r.deinit();
    try r.exprs.append(gpa, .{});
    try r.stack.append(gpa, path);
    try r.walk(path, nodes, aliases);

    if (r.bad == null and r.ctrls.items.len != 0) {
        const c = r.ctrls.items[r.ctrls.items.len - 1];
        const why = try std.fmt.allocPrint(gpa, "`{s}` is never closed in this region", .{c.cond});
        r.bad = .{ .kind = .control, .line = c.line, .col = c.col, .why = why };
    }

    if (r.bad != null) {
        // Ownership of `why` moves to the caller here; `Rec.deinit` frees it
        // only while `r.bad` still holds it, so an OOM in the line below
        // cannot leak it either. `u` is taken as an explicit copy rather
        // than through an `if (r.bad) |u|` capture, so clearing `r.bad`
        // cannot disturb it.
        const u = r.bad.?;
        r.bad = null;
        errdefer gpa.free(u.why);
        return .{ .js = try gpa.alloc(u8, 0), .unportable = u };
    }
    return .{ .js = try r.out.toOwnedSlice(gpa), .unportable = null };
}

pub fn freeBody(gpa: Allocator, b: Body) void {
    gpa.free(b.js);
    if (b.unportable) |u| gpa.free(u.why);
}

/// One JS expression under construction. String runs COALESCE (`"<h2>"` and
/// an escaped literal next to each other are one JS string), so the emitted
/// body reads like the template it came from instead of like a chain of
/// one-character concatenations.
const Expr = struct {
    buf: std.ArrayList(u8) = .empty,
    /// A `"` has been written and not yet closed.
    open: bool = false,
    /// Anything at all has been written, so the next part needs a ` + `.
    any: bool = false,

    /// Contract 2 (owned-result), applied to the caller-owned `buf`: any
    /// growth becomes part of `Expr`, whose owner deinitializes it.
    fn text(e: *Expr, gpa: Allocator, s: []const u8) Allocator.Error!void {
        if (s.len == 0) return;
        if (!e.open) {
            if (e.any) try e.buf.appendSlice(gpa, " + ");
            try e.buf.append(gpa, '"');
            e.open = true;
            e.any = true;
        }
        try appendJsEscaped(gpa, &e.buf, s);
    }

    /// Contract 2 (owned-result), applied to the caller-owned `buf`: any
    /// growth becomes part of `Expr`, whose owner deinitializes it.
    fn code(e: *Expr, gpa: Allocator, js: []const u8) Allocator.Error!void {
        if (e.open) {
            try e.buf.append(gpa, '"');
            e.open = false;
        }
        if (e.any) try e.buf.appendSlice(gpa, " + ");
        try e.buf.appendSlice(gpa, js);
        e.any = true;
    }

    /// Contract 2 (owned-result): the returned expression is the caller's.
    /// An expression with nothing in it is the empty JS string, not an empty
    /// slice -- a branch that renders nothing still has to be a value.
    fn finish(e: *Expr, gpa: Allocator) Allocator.Error![]u8 {
        if (e.open) {
            try e.buf.append(gpa, '"');
            e.open = false;
        }
        if (!e.any) return gpa.dupe(u8, "\"\"");
        return e.buf.toOwnedSlice(gpa);
    }
};

/// One `<% if … %>` under construction. `cond` is the JS predicate; the
/// branch bodies accumulate as `Expr`s on `Rec.exprs`.
const Ctrl = struct {
    cond: []u8,
    /// Set when the `block_else` arrives; null while the `then` arm is still
    /// the one being written.
    then_expr: ?[]u8,
    line: u64,
    col: u64,
};

const Rec = struct {
    gpa: Allocator,
    ctx: convert.Context,
    out: std.ArrayList(u8) = .empty,
    exprs: std.ArrayList(Expr) = .empty,
    ctrls: std.ArrayList(Ctrl) = .empty,
    /// The partial-inlining stack, seeded with the caller's own `path`, so a
    /// partial that renders itself is refused instead of looping.
    stack: std.ArrayList([]const u8) = .empty,
    bad: ?Unportable = null,

    fn deinit(r: *Rec) void {
        r.out.deinit(r.gpa);
        for (r.exprs.items) |*e| e.buf.deinit(r.gpa);
        r.exprs.deinit(r.gpa);
        for (r.ctrls.items) |c| {
            r.gpa.free(c.cond);
            if (c.then_expr) |t| r.gpa.free(t);
        }
        r.ctrls.deinit(r.gpa);
        r.stack.deinit(r.gpa);
        if (r.bad) |u| r.gpa.free(u.why);
    }

    fn top(r: *Rec) *Expr {
        return &r.exprs.items[r.exprs.items.len - 1];
    }

    /// The message is formatted into a LOCAL first; see `Scan.fail` for why
    /// `r.bad = .{ … .why = try … }` is not the same thing.
    fn fail(r: *Rec, n: fragments.Node, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        if (r.bad != null) return;
        const why = try std.fmt.allocPrint(r.gpa, fmt, args);
        r.bad = .{ .kind = n.kind, .line = n.line, .col = n.col, .why = why };
    }

    /// Closes the current statement. Only at depth 0: inside a `<% if %>`
    /// the parts belong to a branch expression, not to `h`.
    fn flush(r: *Rec) Allocator.Error!void {
        if (r.ctrls.items.len != 0) return;
        const e = r.top();
        if (!e.any) return;
        const s = try e.finish(r.gpa);
        defer r.gpa.free(s);
        e.* = .{};
        try r.out.appendSlice(r.gpa, "h += ");
        try r.out.appendSlice(r.gpa, s);
        try r.out.appendSlice(r.gpa, ";\n");
    }

    /// MARKUP this converter writes itself -- an `<a>` opener, an attribute
    /// separator, a closing tag. It goes out verbatim (JS-escaped only, so
    /// the string literal stays a string literal).
    ///
    /// Kept apart from `html` on purpose: passing a tag through the HTML
    /// escaper renders `&lt;a href=&quot;…` on the page, which is exactly
    /// what the first draft of this file did.
    fn markup(r: *Rec, s: []const u8) Allocator.Error!void {
        try r.top().text(r.gpa, s);
    }

    /// A VALUE out of the Rails app -- a literal, a translation, a resolved
    /// URL, an attribute the author wrote -- HTML-escaped ONCE, at build
    /// time. The runtime `esc` is for values the browser computes; applying
    /// both would double-escape.
    fn html(r: *Rec, s: []const u8) Allocator.Error!void {
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(r.gpa);
        try appendHtmlEscaped(r.gpa, &tmp, s);
        try r.top().text(r.gpa, tmp.items);
    }

    fn walk(r: *Rec, path: []const u8, nodes: []const fragments.Node, aliases: []const Alias) Allocator.Error!void {
        for (nodes) |n| {
            if (r.bad != null) return;
            try r.node(path, n, aliases);
        }
    }

    fn node(r: *Rec, path: []const u8, n: fragments.Node, aliases: []const Alias) Allocator.Error!void {
        if (n.text) |t| {
            try r.top().text(r.gpa, t);
            return r.flush();
        }
        switch (n.kind) {
            .literal => {
                if (!n.output) return;
                try r.html(n.value orelse "");
                return r.flush();
            },
            .i18n => {
                if (n.missing) return r.fail(n, "the i18n key `{s}` resolved to no translation", .{n.name orelse ""});
                try r.html(n.value orelse "");
                return r.flush();
            },
            .route_helper => {
                const stem = n.name orelse return r.fail(n, "a route helper with no name", .{});
                const url = try resolve.routeUrl(r.gpa, r.ctx.routes, stem, n.args) orelse
                    return r.fail(n, "no certain route named `{s}` takes {d} literal argument(s)", .{ stem, n.args.len });
                defer r.gpa.free(url);
                try r.html(url);
                return r.flush();
            },
            .link_to => return r.linkTo(n),
            .asset => return r.asset(n),
            // Both have a static equivalent that is NOT markup: `convert`
            // drops them from a converted page for the same reasons (the
            // Rails JS entry is replaced by `@z/runtime`, the CSRF token by
            // the ZigBase cookie boundary), and an island body has even less
            // use for them.
            .importmap, .csrf => return,
            .local, .ivar => {
                if (!n.output) return r.fail(
                    n,
                    "`{s}` is a statement, not an output tag; a record body renders values",
                    .{std.mem.trim(u8, n.code, " \t\r\n")},
                );
                const ref = aliasRef(aliases, n.code) orelse return r.fail(
                    n,
                    "`{s}` is not a field of the record this island renders",
                    .{std.mem.trim(u8, n.code, " \t\r\n")},
                );
                const access = try accessExpr(r.gpa, ref);
                defer r.gpa.free(access);
                const js = try std.fmt.allocPrint(r.gpa, "esc(String({s} ?? \"\"))", .{access});
                defer r.gpa.free(js);
                try r.top().code(r.gpa, js);
                return r.flush();
            },
            .route_helper_dynamic => return r.dynamicRoute(n, aliases),
            .render_partial, .render_partial_locals => return r.inlinePartial(path, n, aliases),
            .render_dynamic => return r.inlineDynamic(path, n, aliases),
            .control => return r.openControl(n, aliases),
            .block_else => return r.elseArm(n),
            .block_end => return r.endArm(),
            else => return r.fail(
                n,
                "a `{s}` fragment (`{s}`) has no record-body form",
                .{ @tagName(n.kind), std.mem.trim(u8, n.code, " \t\r\n") },
            ),
        }
    }

    /// `link_to "Home", root_path` -- both operands literal, so the whole
    /// anchor is static text, exactly as `convert.emitLink` writes it.
    fn linkTo(r: *Rec, n: fragments.Node) Allocator.Error!void {
        const text = if (n.args.len > 0) n.args[0] else "";
        var owned: ?[]const u8 = null;
        defer if (owned) |o| r.gpa.free(o);
        const href: []const u8 = blk: {
            if (n.name) |stem| {
                const rest: []const []const u8 = if (n.args.len > 1) n.args[1..] else &.{};
                const url = try resolve.routeUrl(r.gpa, r.ctx.routes, stem, rest);
                owned = url;
                break :blk url orelse "";
            }
            break :blk if (n.args.len > 1) n.args[1] else "";
        };
        if (href.len == 0) return r.fail(n, "`link_to` names no URL this run can resolve", .{});
        try r.markup("<a href=\"");
        try r.html(href);
        try r.markup("\"");
        try r.attrs(n.attrs, true);
        try r.markup(">");
        try r.html(text);
        try r.markup("</a>");
        return r.flush();
    }

    /// The literal attributes on a helper's tag, in source order.
    ///
    /// Unlike `convert.emitAttrs` this does NOT neutralise a leading `$`:
    /// that rule exists because SuperHTML reads a `$`-leading attribute value
    /// as a Scripty expression, and an island body is plain JS building plain
    /// HTML, where `$` is just a character. Writing `&#36;` here would put
    /// the entity on the page.
    fn attrs(r: *Rec, list: []const fragments.Attr, drop_method: bool) Allocator.Error!void {
        for (list) |a| {
            if (std.mem.eql(u8, a.value, convert.nested_hash_sentinel)) continue;
            if (drop_method and std.mem.eql(u8, a.key, "method")) continue;
            try r.markup(" ");
            try r.html(a.key);
            try r.markup("=\"");
            try r.html(a.value);
            try r.markup("\"");
        }
    }

    fn asset(r: *Rec, n: fragments.Node) Allocator.Error!void {
        const helper = n.name orelse return r.fail(n, "an asset helper with no name", .{});
        // The same two helpers `convert` drops: the target has no Rails JS
        // entry and no favicon pipeline to point at.
        if (std.mem.eql(u8, helper, "javascript_include_tag") or std.mem.eql(u8, helper, "favicon_link_tag")) return;
        const args: []const []const u8 = if (n.args.len > 0) n.args else &.{""};
        for (args) |literal| {
            if (resolve.isAbsoluteAssetLiteral(literal)) continue;
            const found = resolve.assetFor(r.ctx.assets, helper, literal) orelse
                return r.fail(n, "the asset `{s}` resolves to no file this run scanned", .{literal});
            if (!found.deterministic) return r.fail(
                n,
                "the asset `{s}` has no deterministic target URL",
                .{literal},
            );
        }
        for (args) |literal| {
            var url: ?[]const u8 = null;
            defer if (url) |u| r.gpa.free(u);
            if (!resolve.isAbsoluteAssetLiteral(literal)) {
                const found = resolve.assetFor(r.ctx.assets, helper, literal).?;
                const rel = try resolve.assetTargetPath(r.gpa, found.source);
                defer r.gpa.free(rel);
                // `/{rel}` is the same URL `scaffold.zig` records as the
                // asset's `target_url`; `$site.asset(…)`, which `convert`
                // emits into SuperHTML, means nothing inside a JS string.
                url = try std.fmt.allocPrint(r.gpa, "/{s}", .{rel});
            }
            const href = url orelse literal;
            if (std.mem.eql(u8, helper, "image_tag")) {
                try r.markup("<img src=\"");
                try r.html(href);
                try r.markup("\"");
                try r.attrs(n.attrs, false);
                try r.markup(">");
                continue;
            }
            if (std.mem.eql(u8, helper, "stylesheet_link_tag")) {
                try r.markup("<link rel=\"stylesheet\" href=\"");
                try r.html(href);
                try r.markup("\">");
                continue;
            }
            try r.html(href);
        }
        return r.flush();
    }

    /// `post_path(post)` and the `link_to post.title, post_path(post)` form:
    /// the route's literal segments stay text, each `:param` becomes an
    /// `encodeURIComponent(String(…))` splice.
    fn dynamicRoute(r: *Rec, n: fragments.Node, aliases: []const Alias) Allocator.Error!void {
        const stem = n.name orelse return r.fail(n, "a route helper with no name", .{});
        if (std.mem.eql(u8, stem, "link_to")) return r.fail(
            n,
            "this `link_to` names no route this run can resolve",
            .{},
        );
        const route = routeFor(r.ctx.routes, stem, n.args.len) orelse return r.fail(
            n,
            "no certain route named `{s}` takes {d} dynamic segment(s)",
            .{ stem, n.args.len },
        );

        // The link text first, so a `link_to` whose text is unportable is
        // refused before any markup is written.
        var text_access: ?[]u8 = null;
        defer if (text_access) |t| r.gpa.free(t);
        if (n.value) |v| {
            const ref = aliasRef(aliases, v) orelse return r.fail(
                n,
                "the link text `{s}` is not a field of the record this island renders",
                .{v},
            );
            if (ref.field == null) return r.fail(
                n,
                "the link text `{s}` names the whole record, not one of its fields",
                .{v},
            );
            text_access = try accessExpr(r.gpa, ref);
        }

        if (text_access != null) try r.markup("<a href=\"");

        var next_arg: usize = 0;
        var it = std.mem.splitScalar(u8, trimTrailingSlash(route.path), '/');
        var wrote_segment = false;
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            wrote_segment = true;
            try r.markup("/");
            if (!isPlaceholder(seg)) {
                try r.html(seg);
                continue;
            }
            const arg = n.args[next_arg];
            next_arg += 1;
            const ref = aliasRef(aliases, arg) orelse return r.fail(
                n,
                "the route argument `{s}` is not a field of the record this island renders",
                .{arg},
            );
            // A bare alias fills the segment with the record's `id`, which is
            // what `post_path(post)` means in Rails (`to_param` defaults to
            // the id).
            const access = if (ref.field != null)
                try accessExpr(r.gpa, ref)
            else
                try std.fmt.allocPrint(r.gpa, "{s}.id", .{ref.js});
            defer r.gpa.free(access);
            const js = try std.fmt.allocPrint(r.gpa, "encodeURIComponent(String({s} ?? \"\"))", .{access});
            defer r.gpa.free(js);
            try r.top().code(r.gpa, js);
        }
        if (!wrote_segment) try r.markup("/");

        if (text_access) |t| {
            try r.markup("\">");
            const js = try std.fmt.allocPrint(r.gpa, "esc(String({s} ?? \"\"))", .{t});
            defer r.gpa.free(js);
            try r.top().code(r.gpa, js);
            try r.markup("</a>");
        }
        return r.flush();
    }

    fn openControl(r: *Rec, n: fragments.Node, aliases: []const Alias) Allocator.Error!void {
        const code = std.mem.trim(u8, n.code, " \t\r\n");
        var negate = false;
        var rest: []const u8 = undefined;
        if (startsWithWord(code, "if")) {
            rest = code[2..];
        } else if (startsWithWord(code, "unless")) {
            negate = true;
            rest = code[6..];
        } else return r.fail(n, "`{s}` is not a single-field predicate", .{code});

        const ref = aliasRef(aliases, rest) orelse return r.fail(
            n,
            "`{s}` is not a single-field predicate on the record this island renders",
            .{code},
        );
        const access = try accessExpr(r.gpa, ref);
        defer r.gpa.free(access);
        const cond = if (ref.predicate)
            try std.fmt.allocPrint(r.gpa, "{s}{s}", .{ if (negate) "!" else "", access })
        else if (negate)
            try std.fmt.allocPrint(
                r.gpa,
                "!({s} !== null && {s} !== undefined && {s} !== false)",
                .{ access, access, access },
            )
        else
            try std.fmt.allocPrint(
                r.gpa,
                "{s} !== null && {s} !== undefined && {s} !== false",
                .{ access, access, access },
            );
        errdefer r.gpa.free(cond);
        try r.ctrls.append(r.gpa, .{ .cond = cond, .then_expr = null, .line = n.line, .col = n.col });
        errdefer _ = r.ctrls.pop();
        try r.exprs.append(r.gpa, .{});
    }

    fn elseArm(r: *Rec, n: fragments.Node) Allocator.Error!void {
        // A `block_else` with no control open belongs to a region the caller
        // handed in whole; see `endArm`.
        if (r.ctrls.items.len == 0) return;
        if (r.ctrls.items[r.ctrls.items.len - 1].then_expr != null) return r.fail(
            n,
            "an `elsif`/`when` chain has no ternary form this port emits",
            .{},
        );
        var e = r.exprs.pop().?;
        defer e.buf.deinit(r.gpa);
        const s = try e.finish(r.gpa);
        errdefer r.gpa.free(s);
        try r.exprs.append(r.gpa, .{});
        r.ctrls.items[r.ctrls.items.len - 1].then_expr = s;
    }

    fn endArm(r: *Rec) Allocator.Error!void {
        // A `block_end` with no control open closes the REGION itself: the
        // caller hands in the span of an `@posts.each do |post| … end` and
        // its own `end` rides along. Ignoring it here is what lets the
        // caller pass a span rather than having to trim it.
        if (r.ctrls.items.len == 0) return;
        var e = r.exprs.pop().?;
        defer e.buf.deinit(r.gpa);
        const arm = try e.finish(r.gpa);
        defer r.gpa.free(arm);
        const c = r.ctrls.pop().?;
        defer {
            r.gpa.free(c.cond);
            if (c.then_expr) |t| r.gpa.free(t);
        }
        const then_arm = c.then_expr orelse arm;
        const else_arm = if (c.then_expr != null) arm else "\"\"";
        const s = try std.fmt.allocPrint(r.gpa, "({s} ? {s} : {s})", .{ c.cond, then_arm, else_arm });
        defer r.gpa.free(s);
        try r.top().code(r.gpa, s);
        return r.flush();
    }

    fn inlinePartial(r: *Rec, path: []const u8, n: fragments.Node, aliases: []const Alias) Allocator.Error!void {
        var sub: std.ArrayList(Alias) = .empty;
        defer sub.deinit(r.gpa);
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |o| r.gpa.free(o);
            owned.deinit(r.gpa);
        }
        if (n.kind == .render_partial_locals) {
            for (n.attrs) |a| {
                const lit = try jsStringLiteral(r.gpa, a.value);
                errdefer r.gpa.free(lit);
                try owned.append(r.gpa, lit);
                try sub.append(r.gpa, .{ .ruby = a.key, .js = lit });
            }
        }
        try r.inlineInto(path, n, aliases, &sub);
    }

    fn inlineDynamic(r: *Rec, path: []const u8, n: fragments.Node, aliases: []const Alias) Allocator.Error!void {
        if (n.attrs.len == 0) return r.fail(
            n,
            "`render {s}` names its partial or its locals at request time",
            .{n.name orelse ""},
        );
        var sub: std.ArrayList(Alias) = .empty;
        defer sub.deinit(r.gpa);
        for (n.attrs) |a| {
            const ref = aliasRef(aliases, a.value) orelse return r.fail(
                n,
                "the local `{s}: {s}` is not a field of the record this island renders",
                .{ a.key, a.value },
            );
            if (ref.field != null) return r.fail(
                n,
                "the local `{s}: {s}` is a field, not the record itself",
                .{ a.key, a.value },
            );
            try sub.append(r.gpa, .{ .ruby = a.key, .js = ref.js });
        }
        try r.inlineInto(path, n, aliases, &sub);
    }

    /// The shared half of both render arms: resolve the partial, guard the
    /// cycle, and walk its nodes under `sub`.
    fn inlineInto(
        r: *Rec,
        path: []const u8,
        n: fragments.Node,
        aliases: []const Alias,
        sub: *std.ArrayList(Alias),
    ) Allocator.Error!void {
        const target = n.name orelse return r.fail(n, "a render with no partial name", .{});
        const p = convert.partialPathIn(r.ctx.fragments, path, target) orelse return r.fail(
            n,
            "the partial `{s}` is not among the templates this run read",
            .{target},
        );
        for (r.stack.items) |s| {
            if (std.mem.eql(u8, s, p)) return r.fail(n, "the partial `{s}` renders itself", .{p});
        }
        const tpl = templateFor(r.ctx.fragments, p) orelse return r.fail(
            n,
            "the partial `{s}` is not among the templates this run read",
            .{target},
        );
        if (tpl.error_message != null or tpl.unreadable != null) return r.fail(
            n,
            "the partial `{s}` did not parse",
            .{p},
        );
        // Rails gives a partial its locals and the request's instance
        // variables, and nothing else -- so the renderer's own LOCALS do not
        // carry across, while an `@ivar` alias does.
        for (aliases) |a| {
            if (a.ruby.len > 0 and a.ruby[0] == '@') try sub.append(r.gpa, a);
        }
        try r.stack.append(r.gpa, p);
        defer _ = r.stack.pop();
        try r.walk(p, tpl.nodes, sub.items);
    }
};

/// One resolved reference into the record an island renders: which JS
/// binding, and which field of it (null for the record itself).
const Ref = struct {
    js: []const u8,
    field: ?[]const u8,
    predicate: bool,
};

/// `post` / `post.title` / `post.published?` / `@post.title` against the
/// aliases in scope. A second hop (`post.author.name`), an operator, a call
/// with arguments -- anything that is not exactly one optional field access
/// -- is a miss, and every caller turns a miss into an `unportable`.
///
/// Contract 3 (caller-buffer): allocates nothing; the result borrows
/// `aliases` and `code`.
fn aliasRef(aliases: []const Alias, code: []const u8) ?Ref {
    const c = std.mem.trim(u8, code, " \t\r\n");
    if (c.len == 0) return null;
    const dot = std.mem.indexOfScalar(u8, c, '.');
    const head = if (dot) |d| c[0..d] else c;
    var field: ?[]const u8 = null;
    var predicate = false;
    if (dot) |d| {
        var f = c[d + 1 ..];
        // Ruby's predicate suffix: `published?` is the reader `published`.
        if (f.len > 0 and f[f.len - 1] == '?') {
            f = f[0 .. f.len - 1];
            predicate = true;
        }
        if (!isRubyIdent(f)) return null;
        field = f;
    }
    for (aliases) |a| {
        if (std.mem.eql(u8, a.ruby, head)) return .{ .js = a.js, .field = field, .predicate = predicate };
    }
    return null;
}

/// Contract 1 (self-freeing): the returned `rec` / `rec.title` is the only
/// allocation and is the caller's to free.
fn accessExpr(gpa: Allocator, ref: Ref) Allocator.Error![]u8 {
    if (ref.field) |f| return std.fmt.allocPrint(gpa, "{s}.{s}", .{ ref.js, f });
    return gpa.dupe(u8, ref.js);
}

/// `[a-z_][a-z0-9_]*`, the plan's spelling of a Rails attribute reader.
/// Contract 3 (caller-buffer): allocates nothing.
fn isRubyIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isLower(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    }
    return true;
}

/// Whether `code` begins with `word` followed by a word boundary, so
/// `unlessness` is not read as `unless`.
/// Contract 3 (caller-buffer): allocates nothing.
fn startsWithWord(code: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, code, word)) return false;
    if (code.len == word.len) return false;
    return std.ascii.isWhitespace(code[word.len]) or code[word.len] == '(';
}

/// Contract 3 (caller-buffer): allocates nothing; the result borrows `list`.
fn templateFor(list: []const fragments.Template, path: []const u8) ?fragments.Template {
    for (list) |t| {
        if (std.mem.eql(u8, t.path, path)) return t;
    }
    return null;
}

/// `resolve.routeUrl`'s candidate rule, applied to the route's PATH rather
/// than to a URL built from literals: the same `certain`/name/arity filter
/// and the same "a GET candidate wins" tie-break, so a body's `href` and a
/// converted page's `href` name the same route.
///
/// Not a call into `resolve`: `routeUrl` percent-encodes literal arguments
/// into the URL, and this port needs the placeholders left standing so it
/// can splice a JS expression into each one. `resolve`'s own
/// `isPlaceholder`/`segments` helpers are file-private, so the two-line
/// walk is repeated here rather than widening that file's surface.
///
/// Contract 3 (caller-buffer): allocates nothing; the result borrows `all`.
fn routeFor(all: []const routes_mod.Route, stem: []const u8, arity: usize) ?routes_mod.Route {
    var best: ?routes_mod.Route = null;
    for (all) |route| {
        if (!route.certain) continue;
        const name = route.name orelse continue;
        if (!std.mem.eql(u8, name, stem)) continue;
        var placeholders: usize = 0;
        var bad = false;
        var it = std.mem.splitScalar(u8, trimTrailingSlash(route.path), '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (std.mem.indexOfAny(u8, seg, "()") != null) bad = true;
            if (isPlaceholder(seg)) placeholders += 1;
        }
        if (bad or placeholders != arity) continue;
        if (best) |b| {
            if (std.mem.eql(u8, b.verb, "GET")) continue;
        }
        best = route;
    }
    return best;
}

fn isPlaceholder(segment: []const u8) bool {
    return segment.len > 1 and (segment[0] == ':' or segment[0] == '*');
}

fn trimTrailingSlash(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

/// The four-character escaping `convert.escapeInto` applies, repeated because
/// that function is file-private. This text is escaped once at build time into
/// a JS string literal; the five-character runtime `esc` helper has a separate
/// quote rule because it handles interpolated record values in the browser.
///
/// Contract 2 (owned-result), applied to caller-owned `out`: any growth stays
/// in that buffer and its owner releases it.
fn appendHtmlEscaped(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |ch| switch (ch) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        else => try out.append(gpa, ch),
    };
}

/// The inside of a double-quoted JS string. A raw newline or an unescaped
/// quote would not merely look wrong -- it would be a syntax error in the
/// generated island, which is a build failure with no obvious cause.
///
/// Contract 2 (owned-result), applied to caller-owned `out`: any growth stays
/// in that buffer and its owner releases it.
fn appendJsEscaped(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |ch| switch (ch) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '"' => try out.appendSlice(gpa, "\\\""),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0...8, 11, 12, 14...31, 127 => {
            var buf: [6]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
            try out.appendSlice(gpa, s);
        },
        else => try out.append(gpa, ch),
    };
}

/// Contract 1 (self-freeing): the returned `"…"` is the only allocation.
fn jsStringLiteral(gpa: Allocator, value: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.append(gpa, '"');
    try appendJsEscaped(gpa, &out, value);
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

// ---- (d) React imports ---------------------------------------------------

pub const Import = struct {
    spec: []const u8,
    relative: bool,
};

pub const Imports = struct {
    list: []Import,
    unsupported: ?[]const u8,
};

/// The bare specifiers the React compat bridge already answers through its
/// `resolve` map (`docs/migration/react-spa-bridge.md`'s defaults, which the
/// framework applies whenever `firstParty` or `npmCompat` is non-empty).
///
/// Published so Task 3 asks THIS list rather than restating it: assumption
/// B9 divides bare specifiers into "the bridge resolves it", "the Rails
/// `package.json` pins it, so it becomes an `npmCompat` entry and a target
/// dependency" and "the root is not offered `island`", and a second copy of
/// the first set is a second thing to keep in step with the bridge doc.
pub const bridge_resolved = [_][]const u8{
    "react",
    "react-dom",
    "react-dom/client",
    "react/jsx-runtime",
    "react/jsx-dev-runtime",
};

/// Contract 3 (caller-buffer): allocates nothing.
pub fn isBridgeResolved(spec: []const u8) bool {
    for (bridge_resolved) |k| {
        // The bridge matches the EXACT specifier only (no subpaths), so
        // `react-dom/server` is not covered by `react-dom`.
        if (std.mem.eql(u8, k, spec)) return true;
    }
    return false;
}

/// Contract 1 (self-freeing), NOT the plan sketch's contract 2, for the same
/// reason `actionDescriptors` is: one allocation escapes (`list`), every
/// `Import.spec` borrows `bytes`, `unsupported` is a static literal, and
/// `gpa.free(r.list)` is the whole release.
///
/// The ESM declaration forms with a string-literal specifier, in source
/// order: `import "x"`, `import <clause> from "x"`, `export * from "x"`,
/// `export * as ns from "x"`, `export { … } from "x"`. `import.meta` is not
/// one of them. `require(` and a dynamic `import(` anywhere in the file set
/// `unsupported`: assumption B9 calls both "cannot follow", because the copy
/// closure this feeds has to be decidable statically and neither is.
/// Unterminated strings/templates/regexes, and regex contents that can derail
/// this lexical scan, produce the same refusal instead of an empty closure.
///
/// `relative` is the specifier's own shape (`./x`, `../x`), not a
/// resolution: whether such a path lands on a real file under
/// `app/javascript/` is a filesystem question, and this module has no
/// filesystem. A CSS or JSON specifier is LISTED here for the same reason --
/// naming what the file imports is this function's job; refusing the
/// unfollowable ones is Task 3's.
pub fn reactImports(gpa: Allocator, bytes: []const u8) Allocator.Error!Imports {
    var list: std.ArrayList(Import) = .empty;
    errdefer list.deinit(gpa);
    var unsupported: ?[]const u8 = null;

    var i: usize = 0;
    while (i < bytes.len) {
        var unterminated = false;
        const j = skipLexical(bytes, i, &unterminated);
        if (j != i) {
            if (unterminated and unsupported == null) {
                unsupported = "this file's lexical structure could not be followed";
            }
            i = j;
            continue;
        }
        if (regexRun(bytes, i)) |run| {
            if ((run.dangerous or run.unterminated) and unsupported == null) {
                unsupported = "this file's lexical structure could not be followed";
            }
            i = run.end;
            continue;
        }
        const end = identEnd(bytes, i);
        if (end == i) {
            i += 1;
            continue;
        }
        const word = bytes[i..end];
        // `obj.import` / `obj.require` are property reads, not declarations.
        if (isMemberAccess(bytes, i)) {
            i = end;
            continue;
        }
        if (std.mem.eql(u8, word, "require")) {
            const k = skipTrivia(bytes, end);
            if (k < bytes.len and bytes[k] == '(' and unsupported == null) {
                unsupported = "a `require(…)` call, which is CommonJS and cannot be followed statically";
            }
            i = end;
            continue;
        }
        if (std.mem.eql(u8, word, "import")) {
            const k = skipTrivia(bytes, end);
            if (k < bytes.len and bytes[k] == '(') {
                if (unsupported == null) {
                    unsupported = "a dynamic `import(…)`, whose specifier is not known until it runs";
                }
                i = k + 1;
                continue;
            }
            if (k < bytes.len and bytes[k] == '.') {
                i = k + 1;
                continue;
            }
            if (!isStatementPosition(bytes, i)) {
                i = end;
                continue;
            }
            if (k < bytes.len and (bytes[k] == '"' or bytes[k] == '\'')) {
                var string_unterminated = false;
                const e = skipLexical(bytes, k, &string_unterminated);
                if (string_unterminated) {
                    if (unsupported == null) unsupported = "this file's lexical structure could not be followed";
                    i = e;
                    continue;
                }
                try appendSpec(gpa, &list, bytes, k, e);
                i = e;
                continue;
            }
            if (clauseSpecifier(bytes, k)) |hit| {
                if (hit.unterminated) {
                    if (unsupported == null) unsupported = "this file's lexical structure could not be followed";
                    i = hit.end;
                    continue;
                }
                try appendSpec(gpa, &list, bytes, hit.quote, hit.end);
                i = hit.end;
                continue;
            }
            i = end;
            continue;
        }
        if (std.mem.eql(u8, word, "export")) {
            const k = skipTrivia(bytes, end);
            // Only `export *` and `export { … }` can carry a `from`; every
            // other form (`export const`, `export default`, `export
            // function`) declares rather than re-exports.
            if (k < bytes.len and (bytes[k] == '*' or bytes[k] == '{')) {
                if (clauseSpecifier(bytes, k)) |hit| {
                    if (hit.unterminated) {
                        if (unsupported == null) unsupported = "this file's lexical structure could not be followed";
                        i = hit.end;
                        continue;
                    }
                    try appendSpec(gpa, &list, bytes, hit.quote, hit.end);
                    i = hit.end;
                    continue;
                }
            }
            i = end;
            continue;
        }
        i = end;
    }

    return .{ .list = try list.toOwnedSlice(gpa), .unsupported = unsupported };
}

/// Contract 2 (owned-result), applied to a caller-owned collection: the
/// entry is appended into `list`, which the caller already owns; `spec`
/// borrows `bytes`.
fn appendSpec(
    gpa: Allocator,
    list: *std.ArrayList(Import),
    bytes: []const u8,
    quote: usize,
    end: usize,
) Allocator.Error!void {
    const spec = if (end > quote + 1) bytes[quote + 1 .. end - 1] else "";
    try list.append(gpa, .{ .spec = spec, .relative = spec.len > 0 and spec[0] == '.' });
}

/// The `from "x"` at the end of an import/export clause starting at `from`:
/// binding names, `as`, `,`, `*` and a whole `{ … }` group are consumed
/// until the identifier `from`, whose string literal is the specifier.
/// Anything else (a `;`, a `(`, an `=`, the end of the file) means this
/// declaration has no specifier.
///
/// Skipping the `{ … }` group WHOLE is what makes `import { from } from "x"`
/// read correctly: the binding named `from` is inside the group and never
/// reaches the comparison.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn clauseSpecifier(bytes: []const u8, from: usize) ?struct { quote: usize, end: usize, unterminated: bool } {
    var i = skipTrivia(bytes, from);
    while (i < bytes.len) {
        switch (bytes[i]) {
            '{' => {
                i = matchDelimiter(bytes, i, '{', '}') orelse return null;
                i = skipTrivia(bytes, i);
                continue;
            },
            '*', ',' => {
                i = skipTrivia(bytes, i + 1);
                continue;
            },
            else => {},
        }
        const end = identEnd(bytes, i);
        if (end == i) return null;
        if (std.mem.eql(u8, bytes[i..end], "from")) {
            const q = skipTrivia(bytes, end);
            if (q >= bytes.len or (bytes[q] != '"' and bytes[q] != '\'')) return null;
            var unterminated = false;
            const string_end = skipLexical(bytes, q, &unterminated);
            return .{ .quote = q, .end = string_end, .unterminated = unterminated };
        }
        i = skipTrivia(bytes, end);
    }
    return null;
}

/// A static `import` declaration starts a statement. This excludes prose and
/// JSX text while retaining declarations after a newline, `;`, `}`, or
/// block-comment trivia that follows one of those positions.
/// Contract 3 (caller-buffer): allocates nothing.
fn isStatementPosition(bytes: []const u8, at: usize) bool {
    var i = at;
    while (i > 0) {
        i -= 1;
        if (bytes[i] == ' ' or bytes[i] == '\t' or bytes[i] == '\r') continue;
        if (bytes[i] == '/' and i > 0 and bytes[i - 1] == '*') {
            var comment_start = i - 1;
            while (comment_start > 0) {
                comment_start -= 1;
                if (bytes[comment_start] == '/' and bytes[comment_start + 1] == '*') {
                    i = comment_start;
                    break;
                }
            } else return false;
            continue;
        }
        return bytes[i] == '\n' or bytes[i] == ';' or bytes[i] == '}';
    }
    return true;
}

/// Whether the identifier at `i` is the property half of a `.` access.
/// Contract 3 (caller-buffer): allocates nothing.
fn isMemberAccess(bytes: []const u8, i: usize) bool {
    var k = i;
    while (k > 0) {
        k -= 1;
        if (std.ascii.isWhitespace(bytes[k])) continue;
        return bytes[k] == '.';
    }
    return false;
}

// ---- tests ---------------------------------------------------------------

fn tNode(text: []const u8, line: u64) fragments.Node {
    return .{
        .text = text,
        .kind = .unknown,
        .line = line,
        .col = 0,
        .output = false,
        .code = "",
        .name = null,
        .value = null,
        .args = &.{},
        .attrs = &.{},
        .missing = false,
        .dynamic = false,
    };
}

fn cNode(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8, code: []const u8) fragments.Node {
    return .{
        .text = null,
        .kind = kind,
        .line = line,
        .col = col,
        .output = true,
        .code = code,
        .name = name,
        .value = null,
        .args = &.{},
        .attrs = &.{},
        .missing = false,
        .dynamic = false,
    };
}

fn openNode(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8, code: []const u8) fragments.Node {
    var n = cNode(kind, line, col, name, code);
    n.output = false;
    return n;
}

fn endNode(line: u64, col: u64) fragments.Node {
    return openNode(.block_end, line, col, null, "end");
}

fn mkRoute(verb: []const u8, path: []const u8, name: ?[]const u8) routes_mod.Route {
    return .{
        .verb = verb,
        .path = path,
        .controller = "posts",
        .action = "show",
        .name = name,
        .certain = true,
        .origin = .static_ast,
    };
}

const post_routes = [_]routes_mod.Route{
    mkRoute("GET", "/posts", "posts"),
    mkRoute("GET", "/posts/:id", "post"),
};

/// The Stage 4 fixture controller (Task 7 writes the same bytes to
/// `app/javascript/controllers/reveal_controller.js`).
const reveal_js =
    \\import { Controller } from "@hotwired/stimulus"
    \\
    \\export default class extends Controller {
    \\  static targets = ["details"]
    \\  static values = { open: Boolean }
    \\
    \\  connect() {
    \\    this.detailsTarget.hidden = !this.openValue
    \\  }
    \\
    \\  toggle(event) {
    \\    event.preventDefault()
    \\    this.openValue = !this.openValue
    \\    this.detailsTarget.hidden = !this.openValue
    \\  }
    \\}
    \\
;

const reveal_toggle_source =
    \\toggle(event) {
    \\    event.preventDefault()
    \\    this.openValue = !this.openValue
    \\    this.detailsTarget.hidden = !this.openValue
    \\  }
;

test "controllerStem: the Stimulus identifier grammar maps to a controller path" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "app/javascript/controllers/reveal_controller",
        controllerStem(&buf, "reveal"),
    );
    try std.testing.expectEqualStrings(
        "app/javascript/controllers/admin/users_controller",
        controllerStem(&buf, "admin--users"),
    );
    try std.testing.expectEqualStrings(
        "app/javascript/controllers/date_picker_controller",
        controllerStem(&buf, "date-picker"),
    );
}

test "stimulusSource: the fixture controller's targets, values and one action method" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/reveal_controller.js", .bytes = reveal_js },
    };
    const got = (try stimulusSource(gpa, "reveal", &sources)).?;
    defer freeController(gpa, got);

    try std.testing.expectEqual(@as(?[]const u8, null), got.unsupported);
    try std.testing.expectEqualStrings("app/javascript/controllers/reveal_controller.js", got.path);
    try std.testing.expectEqual(@as(usize, 1), got.targets.len);
    try std.testing.expectEqualStrings("details", got.targets[0]);
    try std.testing.expectEqual(@as(usize, 1), got.values.len);
    try std.testing.expectEqualStrings("open", got.values[0].name);
    try std.testing.expectEqual(ValueType.boolean, got.values[0].kind);
    try std.testing.expectEqual(@as(usize, 0), got.classes.len);
    try std.testing.expectEqual(@as(usize, 1), got.methods.len);
    try std.testing.expectEqualStrings("toggle", got.methods[0].name);
    try std.testing.expectEqualStrings(reveal_toggle_source, got.methods[0].source);
    try std.testing.expectEqual(@as(usize, 1), got.lifecycle.len);
    try std.testing.expectEqualStrings("connect", got.lifecycle[0]);
}

test "stimulusSource: the extension order picks .js before .ts, and a miss is null" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/reveal_controller.ts", .bytes = "export default class extends Controller {}" },
        .{ .path = "app/javascript/controllers/reveal_controller.js", .bytes = reveal_js },
    };
    const got = (try stimulusSource(gpa, "reveal", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expectEqualStrings("app/javascript/controllers/reveal_controller.js", got.path);

    try std.testing.expectEqual(
        @as(?Controller, null),
        try stimulusSource(gpa, "missing", &sources),
    );
}

test "stimulusSource: an empty controller is FOLLOWED, not unsupported" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/empty_controller.js", .bytes = "export default class extends Controller {}\n" },
    };
    const got = (try stimulusSource(gpa, "empty", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expectEqual(@as(?[]const u8, null), got.unsupported);
    try std.testing.expectEqual(@as(usize, 0), got.targets.len);
    try std.testing.expectEqual(@as(usize, 0), got.values.len);
    try std.testing.expectEqual(@as(usize, 0), got.classes.len);
    try std.testing.expectEqual(@as(usize, 0), got.methods.len);
    try std.testing.expectEqual(@as(usize, 0), got.lifecycle.len);
}

test "stimulusSource: TypeScript controller syntax keeps annotated methods" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/typed_controller.ts", .bytes =
        \\export default class extends Controller<HTMLElement> {
        \\  declare readonly element: HTMLElement
        \\  static values: Record<string, unknown> = { count: Number }
        \\  alone(): void {}
        \\  both(event: Event): Promise<void> { void event }
        \\}
        },
    };
    const got = (try stimulusSource(gpa, "typed", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expectEqual(@as(?[]const u8, null), got.unsupported);
    try std.testing.expectEqual(@as(usize, 1), got.values.len);
    try std.testing.expectEqualStrings("count", got.values[0].name);
    try std.testing.expectEqual(@as(usize, 2), got.methods.len);
    try std.testing.expectEqualStrings("alone", got.methods[0].name);
    try std.testing.expectEqualStrings("both", got.methods[1].name);
}

test "stimulusSource: static classes are retained" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/x_controller.js", .bytes =
        \\export default class extends Controller {
        \\  static classes = ["loading", "ready"]
        \\}
        },
    };
    const got = (try stimulusSource(gpa, "x", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expectEqual(@as(?[]const u8, null), got.unsupported);
    try std.testing.expectEqual(@as(usize, 2), got.classes.len);
    try std.testing.expectEqualStrings("loading", got.classes[0]);
    try std.testing.expectEqualStrings("ready", got.classes[1]);
}

test "stimulusSource: static outlets is unsupported" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/x_controller.js", .bytes =
        \\export default class extends Controller {
        \\  static outlets = ["result"]
        \\}
        },
    };
    const got = (try stimulusSource(gpa, "x", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expect(got.unsupported != null);
    try std.testing.expect(std.mem.indexOf(u8, got.unsupported.?, "outlets") != null);
}

test "stimulusSource: a getter is unsupported" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/x_controller.js", .bytes =
        \\export default class extends Controller {
        \\  get ready() { return true }
        \\}
        },
    };
    const got = (try stimulusSource(gpa, "x", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expect(got.unsupported != null);
    try std.testing.expect(std.mem.indexOf(u8, got.unsupported.?, "ready") != null);
}

test "stimulusSource: a regex literal holding a brace is the documented lexical limit" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/x_controller.js", .bytes =
        \\export default class extends Controller {
        \\  toggle() { this.re = /{/ }
        \\}
        },
    };
    const got = (try stimulusSource(gpa, "x", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expect(got.unsupported != null);
}

test "stimulusSource: a quote-bearing regex refuses instead of hiding methods" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/x_controller.js", .bytes =
        \\export default class extends Controller {
        \\  before() { this.single = /'/ }
        \\  hidden() {}
        \\  after() { this.single = /'/ }
        \\}
        },
    };
    const got = (try stimulusSource(gpa, "x", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expect(got.unsupported != null);
    try std.testing.expect(std.mem.indexOf(u8, got.unsupported.?, "regex") != null);
}

test "stimulusSource: every regex derail token refuses loudly" {
    const gpa = std.testing.allocator;
    const bodies = [_][]const u8{
        "export default class extends Controller { x() { this.r = /\"/ } }",
        "export default class extends Controller { x() { this.r = /`/ } }",
        "export default class extends Controller { x() { this.r = /a/*b/ } }",
    };
    for (bodies) |body| {
        const sources = [_]JsSource{.{
            .path = "app/javascript/controllers/x_controller.js",
            .bytes = body,
        }};
        const got = (try stimulusSource(gpa, "x", &sources)).?;
        defer freeController(gpa, got);
        try std.testing.expect(got.unsupported != null);
        try std.testing.expect(std.mem.indexOf(u8, got.unsupported.?, "regex") != null);
    }
}

test "stimulusSource: balanced regex quantifiers remain followable" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/x_controller.js", .bytes =
        \\export default class extends Controller {
        \\  check() { return /\\d{2,4}/.test(this.element.value) }
        \\}
        },
    };
    const got = (try stimulusSource(gpa, "x", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expectEqual(@as(?[]const u8, null), got.unsupported);
    try std.testing.expectEqual(@as(usize, 1), got.methods.len);
}

test "stimulusSource: template substitutions do not close the method early" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/x_controller.js", .bytes =
        \\export default class extends Controller {
        \\  label() { return `${'`'}` }
        \\  next() {}
        \\}
        },
    };
    const got = (try stimulusSource(gpa, "x", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expectEqual(@as(?[]const u8, null), got.unsupported);
    try std.testing.expectEqual(@as(usize, 2), got.methods.len);
    try std.testing.expectEqualStrings("next", got.methods[1].name);
}

test "stimulusSource: a file that is not an export default class is unsupported" {
    const gpa = std.testing.allocator;
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/x_controller.js", .bytes = "class X extends Controller {}\nexport { X }\n" },
    };
    const got = (try stimulusSource(gpa, "x", &sources)).?;
    defer freeController(gpa, got);
    try std.testing.expect(got.unsupported != null);
}

test "actionDescriptors: an explicit event, and the tag's default event" {
    const gpa = std.testing.allocator;

    const a = try actionDescriptors(gpa, "<button data-action=\"click->reveal#toggle\">x</button>", "reveal");
    defer gpa.free(a.list);
    try std.testing.expectEqual(@as(?[]const u8, null), a.unsupported);
    try std.testing.expectEqual(@as(usize, 1), a.list.len);
    try std.testing.expectEqualStrings("click", a.list[0].event);
    try std.testing.expectEqualStrings("reveal", a.list[0].identifier);
    try std.testing.expectEqualStrings("toggle", a.list[0].method);
    try std.testing.expect(!a.list[0].prevent);
    try std.testing.expect(!a.list[0].stop);
    try std.testing.expectEqual(@as(usize, 0), a.list[0].selector_index);

    const b = try actionDescriptors(gpa, "<button data-action=\"reveal#toggle\">x</button>", "reveal");
    defer gpa.free(b.list);
    try std.testing.expectEqual(@as(usize, 1), b.list.len);
    try std.testing.expectEqualStrings("click", b.list[0].event);

    const c = try actionDescriptors(gpa, "<form data-action=\"reveal#save\"></form>", "reveal");
    defer gpa.free(c.list);
    try std.testing.expectEqual(@as(usize, 1), c.list.len);
    try std.testing.expectEqualStrings("submit", c.list[0].event);
}

test "actionDescriptors: Stimulus default events include submit input and tag rows" {
    const gpa = std.testing.allocator;
    const a = try actionDescriptors(
        gpa,
        "<input type=\"submit\" data-action=\"reveal#submit\">" ++
            "<input data-action=\"reveal#edit\">" ++
            "<select data-action=\"reveal#choose\"></select>" ++
            "<details data-action=\"reveal#toggle\"></details>",
        "reveal",
    );
    defer gpa.free(a.list);
    try std.testing.expectEqual(@as(usize, 4), a.list.len);
    try std.testing.expectEqualStrings("click", a.list[0].event);
    try std.testing.expectEqualStrings("input", a.list[1].event);
    try std.testing.expectEqualStrings("change", a.list[2].event);
    try std.testing.expectEqualStrings("toggle", a.list[3].event);
}

test "actionDescriptors: a token naming another controller is skipped, :prevent is a flag" {
    const gpa = std.testing.allocator;
    const a = try actionDescriptors(
        gpa,
        "<div data-action=\"keydown->reveal#close:prevent modal#x\"></div>",
        "reveal",
    );
    defer gpa.free(a.list);
    try std.testing.expectEqual(@as(?[]const u8, null), a.unsupported);
    try std.testing.expectEqual(@as(usize, 1), a.list.len);
    try std.testing.expectEqualStrings("keydown", a.list[0].event);
    try std.testing.expectEqualStrings("close", a.list[0].method);
    try std.testing.expect(a.list[0].prevent);
}

test "actionDescriptors: a global event target is unsupported" {
    const gpa = std.testing.allocator;
    const a = try actionDescriptors(gpa, "<button data-action=\"click@window->reveal#x\"></button>", "reveal");
    defer gpa.free(a.list);
    try std.testing.expectEqualStrings("click@window->reveal#x", a.unsupported.?);
}

test "actionDescriptors: unsupported names the first bad token" {
    const gpa = std.testing.allocator;
    const a = try actionDescriptors(
        gpa,
        "<button data-action=\"click@window->reveal#first keydown.esc->reveal#second\"></button>",
        "reveal",
    );
    defer gpa.free(a.list);
    try std.testing.expectEqualStrings("click@window->reveal#first", a.unsupported.?);
}

test "actionDescriptors: selector_index counts the tags that carry data-action" {
    const gpa = std.testing.allocator;
    const a = try actionDescriptors(
        gpa,
        "<div data-controller=\"reveal\"><button data-action=\"reveal#a\">1</button>" ++
            "<span>plain</span><button data-action=\"reveal#b\">2</button></div>",
        "reveal",
    );
    defer gpa.free(a.list);
    try std.testing.expectEqual(@as(usize, 2), a.list.len);
    try std.testing.expectEqual(@as(usize, 0), a.list[0].selector_index);
    try std.testing.expectEqualStrings("a", a.list[0].method);
    try std.testing.expectEqual(@as(usize, 1), a.list[1].selector_index);
    try std.testing.expectEqualStrings("b", a.list[1].method);
}

test "actionDescriptors: raw-text ghost tags do not consume selector indexes" {
    const gpa = std.testing.allocator;
    const a = try actionDescriptors(
        gpa,
        "<script>const ghost = '<button data-action=\"reveal#script\">'</script>" ++
            "<style>.x::after { content: '<i data-action=\"reveal#style\">' }</style>" ++
            "<textarea><b data-action=\"reveal#textarea\"></b></textarea>" ++
            "<pre><em data-action=\"reveal#pre\"></em></pre>" ++
            "<button data-action=\"reveal#real\"></button>",
        "reveal",
    );
    defer gpa.free(a.list);
    try std.testing.expectEqual(@as(usize, 1), a.list.len);
    try std.testing.expectEqualStrings("real", a.list[0].method);
    try std.testing.expectEqual(@as(usize, 0), a.list[0].selector_index);
}

test "recordBody: text and a local field reference" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        tNode("<h2>", 1),
        cNode(.local, 1, 5, "post", "post.title"),
        tNode("</h2>", 1),
    };
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/_post.html.erb", &nodes, &aliases);
    defer freeBody(gpa, b);
    try std.testing.expectEqual(@as(?Unportable, null), b.unportable);
    try std.testing.expectEqualStrings(
        \\h += "<h2>";
        \\h += esc(String(rec.title ?? ""));
        \\h += "</h2>";
        \\
    , b.js);
}

test "recordBody: a dynamic link_to becomes an href expression" {
    const gpa = std.testing.allocator;
    var n = cNode(.route_helper_dynamic, 1, 1, "post", "link_to post.title, post_path(post)");
    n.value = "post.title";
    n.args = &.{"post"};
    const nodes = [_]fragments.Node{n};
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/_post.html.erb", &nodes, &aliases);
    defer freeBody(gpa, b);
    try std.testing.expectEqual(@as(?Unportable, null), b.unportable);
    try std.testing.expectEqualStrings(
        "h += \"<a href=\\\"/posts/\" + encodeURIComponent(String(rec.id ?? \"\")) + \"\\\">\"" ++
            " + esc(String(rec.title ?? \"\")) + \"</a>\";\n",
        b.js,
    );
}

test "recordBody: classify_link fallback names an unresolved link_to" {
    const gpa = std.testing.allocator;
    var n = cNode(.route_helper_dynamic, 4, 2, "link_to", "link_to post.title, destination");
    n.value = "post.title";
    n.args = &.{"post"};
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/_post.html.erb", &.{n}, &aliases);
    defer freeBody(gpa, b);
    try std.testing.expect(std.mem.indexOf(u8, b.unportable.?.why, "this `link_to` names no route") != null);
}

test "recordBody: a splat route segment receives its dynamic argument" {
    const gpa = std.testing.allocator;
    const routes = [_]routes_mod.Route{mkRoute("GET", "/files/*path", "file")};
    var n = cNode(.route_helper_dynamic, 1, 1, "file", "file_path(post.slug)");
    n.args = &.{"post.slug"};
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};
    const b = try recordBody(gpa, .{
        .routes = &routes,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/_post.html.erb", &.{n}, &aliases);
    defer freeBody(gpa, b);
    try std.testing.expectEqual(@as(?Unportable, null), b.unportable);
    try std.testing.expectEqualStrings(
        "h += \"/files/\" + encodeURIComponent(String(rec.slug ?? \"\"));\n",
        b.js,
    );
}

test "recordBody: a one-predicate if becomes a ternary" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        openNode(.control, 8, 1, "if", "if post.published?"),
        tNode("<span>Published</span>", 8),
        endNode(8, 40),
    };
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/_post.html.erb", &nodes, &aliases);
    defer freeBody(gpa, b);
    try std.testing.expectEqual(@as(?Unportable, null), b.unportable);
    try std.testing.expectEqualStrings(
        \\h += (rec.published ? "<span>Published</span>" : "");
        \\
    , b.js);
}

test "recordBody: bare predicates preserve Ruby truthiness" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        openNode(.control, 1, 1, "if", "if post.score"),
        tNode("<b>scored</b>", 1),
        endNode(1, 30),
    };
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/_post.html.erb", &nodes, &aliases);
    defer freeBody(gpa, b);
    try std.testing.expectEqualStrings(
        \\h += (rec.score !== null && rec.score !== undefined && rec.score !== false ? "<b>scored</b>" : "");
        \\
    , b.js);
}

test "recordBody: an if/else fills both arms" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        openNode(.control, 1, 1, "if", "if post.published?"),
        tNode("<b>yes</b>", 1),
        openNode(.block_else, 1, 20, null, "else"),
        tNode("<i>no</i>", 1),
        endNode(1, 40),
    };
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/_post.html.erb", &nodes, &aliases);
    defer freeBody(gpa, b);
    try std.testing.expectEqualStrings(
        \\h += (rec.published ? "<b>yes</b>" : "<i>no</i>");
        \\
    , b.js);
}

test "recordBody: a render with bare-local locals inlines the partial under the alias" {
    const gpa = std.testing.allocator;
    var link = cNode(.route_helper_dynamic, 1, 11, "post", "link_to post.title, post_path(post)");
    link.value = "post.title";
    link.args = &.{"post"};
    var partial_nodes = [_]fragments.Node{
        tNode("<article>", 1),
        link,
        tNode("</article>\n", 1),
        openNode(.control, 8, 1, "if", "if post.published?"),
        tNode("<span>Published</span>", 8),
        endNode(8, 40),
    };
    const frags = [_]fragments.Template{.{
        .path = "app/views/posts/_post.html.erb",
        .nodes = &partial_nodes,
        .error_message = null,
        .error_line = null,
        .unreadable = null,
    }};
    var render = cNode(.render_dynamic, 1, 40, "post", "render partial: \"post\", locals: { post: post }");
    render.attrs = &.{.{ .key = "post", .value = "post" }};
    const nodes = [_]fragments.Node{render};
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &frags,
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/index.html.erb", &nodes, &aliases);
    defer freeBody(gpa, b);
    try std.testing.expectEqual(@as(?Unportable, null), b.unportable);
    try std.testing.expectEqualStrings(
        "h += \"<article>\";\n" ++
            "h += \"<a href=\\\"/posts/\" + encodeURIComponent(String(rec.id ?? \"\")) + \"\\\">\"" ++
            " + esc(String(rec.title ?? \"\")) + \"</a>\";\n" ++
            "h += \"</article>\\n\";\n" ++
            "h += (rec.published ? \"<span>Published</span>\" : \"\");\n",
        b.js,
    );
}

test "recordBody: a partial's literal locals arrive as JS string literals" {
    const gpa = std.testing.allocator;
    var partial_nodes = [_]fragments.Node{
        tNode("<em>", 1),
        cNode(.local, 1, 5, "label", "label"),
        tNode("</em>", 1),
    };
    const frags = [_]fragments.Template{.{
        .path = "app/views/posts/_badge.html.erb",
        .nodes = &partial_nodes,
        .error_message = null,
        .error_line = null,
        .unreadable = null,
    }};
    var render = cNode(.render_partial_locals, 1, 1, "badge", "render partial: \"badge\", locals: { label: \"New\" }");
    render.attrs = &.{.{ .key = "label", .value = "New" }};
    const nodes = [_]fragments.Node{render};
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &frags,
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/index.html.erb", &nodes, &.{});
    defer freeBody(gpa, b);
    try std.testing.expectEqual(@as(?Unportable, null), b.unportable);
    try std.testing.expectEqualStrings(
        \\h += "<em>";
        \\h += esc(String("New" ?? ""));
        \\h += "</em>";
        \\
    , b.js);
}

test "recordBody: the CSRF and importmap fragments are dropped, not refused" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        cNode(.csrf, 1, 1, "csrf_meta_tags", "csrf_meta_tags"),
        tNode("<p>ok</p>", 2),
        cNode(.importmap, 3, 1, "javascript_importmap_tags", "javascript_importmap_tags"),
    };
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/_post.html.erb", &nodes, &.{});
    defer freeBody(gpa, b);
    try std.testing.expectEqual(@as(?Unportable, null), b.unportable);
    try std.testing.expectEqualStrings(
        \\h += "<p>ok</p>";
        \\
    , b.js);
}

test "recordBody: a two-hop field chain stops at its own (line, col)" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        tNode("<p>", 3),
        cNode(.local, 3, 7, "post", "post.author.name"),
    };
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/_post.html.erb", &nodes, &aliases);
    defer freeBody(gpa, b);
    try std.testing.expectEqual(fragments.Kind.local, b.unportable.?.kind);
    try std.testing.expectEqual(@as(u64, 3), b.unportable.?.line);
    try std.testing.expectEqual(@as(u64, 7), b.unportable.?.col);
    try std.testing.expect(std.mem.indexOf(u8, b.unportable.?.why, "post.author.name") != null);
}

test "recordBody: request state is unportable" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{cNode(.request_state, 2, 4, "current_user", "current_user")};
    const b = try recordBody(gpa, .{
        .routes = &post_routes,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, "app/views/posts/_post.html.erb", &nodes, &.{});
    defer freeBody(gpa, b);
    try std.testing.expectEqual(fragments.Kind.request_state, b.unportable.?.kind);
    try std.testing.expectEqual(@as(u64, 2), b.unportable.?.line);
    try std.testing.expectEqual(@as(u64, 4), b.unportable.?.col);
}

test "reactImports: the fixture component's specifiers, in source order" {
    const gpa = std.testing.allocator;
    const src =
        \\import React from "react";
        \\import { format } from "./format";
        \\
        \\export default function Chart({ series }) {
        \\  return <svg data-series={format(series)} />;
        \\}
        \\
    ;
    const r = try reactImports(gpa, src);
    defer gpa.free(r.list);
    try std.testing.expectEqual(@as(?[]const u8, null), r.unsupported);
    try std.testing.expectEqual(@as(usize, 2), r.list.len);
    try std.testing.expectEqualStrings("react", r.list[0].spec);
    try std.testing.expect(!r.list[0].relative);
    try std.testing.expectEqualStrings("./format", r.list[1].spec);
    try std.testing.expect(r.list[1].relative);
}

test "reactImports: a side-effect CSS import is LISTED, not refused here" {
    const gpa = std.testing.allocator;
    const r = try reactImports(gpa, "import \"./x.css\";\nexport const a = 1;\n");
    defer gpa.free(r.list);
    try std.testing.expectEqual(@as(?[]const u8, null), r.unsupported);
    try std.testing.expectEqual(@as(usize, 1), r.list.len);
    try std.testing.expectEqualStrings("./x.css", r.list[0].spec);
    try std.testing.expect(r.list[0].relative);
}

test "reactImports: export-from is a specifier, import.meta is not" {
    const gpa = std.testing.allocator;
    const r = try reactImports(gpa,
        \\export * from "./a";
        \\export { b } from "./b";
        \\export const url = import.meta.url;
        \\
    );
    defer gpa.free(r.list);
    try std.testing.expectEqual(@as(?[]const u8, null), r.unsupported);
    try std.testing.expectEqual(@as(usize, 2), r.list.len);
    try std.testing.expectEqualStrings("./a", r.list[0].spec);
    try std.testing.expectEqualStrings("./b", r.list[1].spec);
}

test "reactImports: require and a dynamic import cannot be followed" {
    const gpa = std.testing.allocator;
    const a = try reactImports(gpa, "const x = require(\"x\");\n");
    defer gpa.free(a.list);
    try std.testing.expect(a.unsupported != null);

    const b = try reactImports(gpa, "const y = await import(\"./y\");\n");
    defer gpa.free(b.list);
    try std.testing.expect(b.unsupported != null);
}

test "isBridgeResolved: the compat bridge's own resolve keys, exact match only" {
    try std.testing.expect(isBridgeResolved("react"));
    try std.testing.expect(isBridgeResolved("react-dom/client"));
    try std.testing.expect(isBridgeResolved("react/jsx-dev-runtime"));
    // The bridge maps exact specifiers, so a subpath it does not name is
    // NOT covered by its parent's entry.
    try std.testing.expect(!isBridgeResolved("react-dom/server"));
    try std.testing.expect(!isBridgeResolved("react-router-dom"));
}

test "reactImports: a property named require or import is not a declaration" {
    const gpa = std.testing.allocator;
    const r = try reactImports(gpa,
        \\import registry from "./registry";
        \\export const a = registry.require("x");
        \\export const b = registry.import;
        \\
    );
    defer gpa.free(r.list);
    try std.testing.expectEqual(@as(?[]const u8, null), r.unsupported);
    try std.testing.expectEqual(@as(usize, 1), r.list.len);
    try std.testing.expectEqualStrings("./registry", r.list[0].spec);
}

test "reactImports: a specifier inside a comment or a string is not an import" {
    const gpa = std.testing.allocator;
    const r = try reactImports(gpa,
        \\// import "./commented";
        \\const s = "import \"./stringy\";";
        \\/* require("nope") */
        \\import a from "./real";
        \\
    );
    defer gpa.free(r.list);
    try std.testing.expectEqual(@as(?[]const u8, null), r.unsupported);
    try std.testing.expectEqual(@as(usize, 1), r.list.len);
    try std.testing.expectEqualStrings("./real", r.list[0].spec);
}

test "reactImports: an import after a same-line block comment is listed" {
    const gpa = std.testing.allocator;
    const r = try reactImports(gpa, "/* c */ import A from \"./a\";");
    defer gpa.free(r.list);
    try std.testing.expectEqual(@as(?[]const u8, null), r.unsupported);
    try std.testing.expectEqual(@as(usize, 1), r.list.len);
    try std.testing.expectEqualStrings("./a", r.list[0].spec);
}

test "reactImports: an import after a multiline block comment ending on its line is listed" {
    const gpa = std.testing.allocator;
    const r = try reactImports(gpa,
        \\/**
        \\ * doc
        \\ */ import A from "./a";
    );
    defer gpa.free(r.list);
    try std.testing.expectEqual(@as(?[]const u8, null), r.unsupported);
    try std.testing.expectEqual(@as(usize, 1), r.list.len);
    try std.testing.expectEqualStrings("./a", r.list[0].spec);
}

test "isStatementPosition: existing statement boundaries remain accepted" {
    const sources = [_][]const u8{
        "\"use client\";\nimport A;",
        "// c\nimport A;",
        "import A; import B;",
        "  import A;",
        "const value = 1\nimport A;",
    };
    for (sources) |source| {
        const at = std.mem.lastIndexOf(u8, source, "import").?;
        try std.testing.expect(isStatementPosition(source, at));
    }

    const unmatched = "*/ import A;";
    try std.testing.expect(!isStatementPosition(unmatched, std.mem.indexOf(u8, unmatched, "import").?));
}

test "reactImports: a derailed regex refuses instead of hiding imports" {
    const gpa = std.testing.allocator;
    const r = try reactImports(gpa,
        \\const apostrophe = /'/;
        \\import Chart from "./Chart";
        \\
    );
    defer gpa.free(r.list);
    try std.testing.expectEqualStrings(
        "this file's lexical structure could not be followed",
        r.unsupported.?,
    );
}

test "reactImports: unterminated lexical tokens refuse" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{
        "const x = \"unterminated",
        "const x = `unterminated",
        "const x = /unterminated",
    };
    for (sources) |source| {
        const r = try reactImports(gpa, source);
        defer gpa.free(r.list);
        try std.testing.expectEqualStrings(
            "this file's lexical structure could not be followed",
            r.unsupported.?,
        );
    }
}

test "reactImports: import prose is not an import declaration" {
    const gpa = std.testing.allocator;
    const r = try reactImports(gpa,
        \\export default () => <p>To import from "nowhere" run npm i</p>
        \\import Chart from "./Chart";
        \\
    );
    defer gpa.free(r.list);
    try std.testing.expectEqual(@as(?[]const u8, null), r.unsupported);
    try std.testing.expectEqual(@as(usize, 1), r.list.len);
    try std.testing.expectEqualStrings("./Chart", r.list[0].spec);
}

test "stimulusSource: FailingAllocator sweep" {
    const sources = [_]JsSource{
        .{ .path = "app/javascript/controllers/reveal_controller.js", .bytes = reveal_js },
    };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (stimulusSource(gpa, "reveal", &sources)) |maybe| {
            const got = maybe.?;
            defer freeController(std.testing.allocator, got);
            try std.testing.expectEqual(@as(usize, 1), got.methods.len);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "actionDescriptors: FailingAllocator sweep" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (actionDescriptors(gpa, "<button data-action=\"click->reveal#a reveal#b:stop\"></button>", "reveal")) |a| {
            defer std.testing.allocator.free(a.list);
            try std.testing.expectEqual(@as(usize, 2), a.list.len);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "recordBody: FailingAllocator sweep" {
    var link = cNode(.route_helper_dynamic, 1, 11, "post", "link_to post.title, post_path(post)");
    link.value = "post.title";
    link.args = &.{"post"};
    var partial_nodes = [_]fragments.Node{
        tNode("<article>", 1),
        link,
        tNode("</article>", 1),
        openNode(.control, 8, 1, "if", "if post.published?"),
        tNode("<span>Published</span>", 8),
        endNode(8, 40),
    };
    const frags = [_]fragments.Template{.{
        .path = "app/views/posts/_post.html.erb",
        .nodes = &partial_nodes,
        .error_message = null,
        .error_line = null,
        .unreadable = null,
    }};
    var render = cNode(.render_dynamic, 1, 40, "post", "render partial: \"post\", locals: { post: post }");
    render.attrs = &.{.{ .key = "post", .value = "post" }};
    const nodes = [_]fragments.Node{render};
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (recordBody(gpa, .{
            .routes = &post_routes,
            .assets = &.{},
            .fragments = &frags,
            .findings = &.{},
            .layout_stem = null,
        }, "app/views/posts/index.html.erb", &nodes, &aliases)) |b| {
            defer freeBody(std.testing.allocator, b);
            try std.testing.expectEqual(@as(?Unportable, null), b.unportable);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "recordBody: FailingAllocator sweep reaching an unportable node" {
    const nodes = [_]fragments.Node{cNode(.local, 3, 7, "post", "post.author.name")};
    const aliases = [_]Alias{.{ .ruby = "post", .js = "rec" }};
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (recordBody(gpa, .{
            .routes = &post_routes,
            .assets = &.{},
            .fragments = &.{},
            .findings = &.{},
            .layout_stem = null,
        }, "app/views/posts/_post.html.erb", &nodes, &aliases)) |b| {
            defer freeBody(std.testing.allocator, b);
            try std.testing.expect(b.unportable != null);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "reactImports: FailingAllocator sweep" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (reactImports(gpa, "import a from \"react\";\nimport \"./b.css\";\nexport * from \"./c\";\n")) |r| {
            defer std.testing.allocator.free(r.list);
            try std.testing.expectEqual(@as(usize, 3), r.list.len);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}
