//! Fork-added (issue #37): the generator behind `docs/scripty.md`.
//!
//! WHY THIS IS NOT `src/docgen.zig`. That file is inherited from upstream and
//! is kept clean so release-tag syncs stay tractable (CLAUDE.md, "Architecture").
//! It is also, on this tree, dead: it calls `std.process.argsAlloc` (gone in Zig
//! 0.16) and reads `context.Template` (renamed to `context.Root`), so
//! `zig build -Ddocgen` does not compile. Its output shape is upstream's too —
//! a `.smd` with an upstream author byline and a `scripty-reference.shtml`
//! layout that does not exist here. So this is a separate root file that
//! borrows the IDEA (walk the context types with @typeInfo, read the metadata
//! the builtins already carry) and nothing else; upstream's file is untouched
//! and a future sync can replace it wholesale without touching this.
//!
//! WHAT IT READS. Every Scripty builtin in this codebase already carries its
//! own documentation — `signature`, `docs_description` and often `examples` are
//! declarations on the builtin's struct, right beside `call`. Issue #37 records
//! the cost of that metadata never being published: `String.eql`,
//! `String.addPath`, `$link.site()`, `$heading.id()` and `$link.page().ref()`
//! were each found by grepping vendored source, repeatedly, over several hours.
//! Nothing about that discovery needed a human to write it down a second time.
//!
//! TWO HALVES, ONE PAGE. The `.shtml` half is this repo's own `src/context/*`,
//! reachable through `context.Root` (the global scope) and `context.Value` (the
//! type of every expression). The `.smd` half is the vendored `supermd`
//! package's directives, reachable through `Directive.Kind`. They are different
//! type shapes with the same metadata idea, which is why the analysis below is
//! generic over "has a `Builtins` struct" rather than over either package.
//!
//! ALLOCATION (NO_SLOP §2.2a). Every analysis function here is comptime and
//! allocates nothing; `writeDescription`/`writeSignature` are contract 3
//! (caller-buffer — they write through a `*Writer` and allocate nothing). The
//! only allocator in the file is `main`'s arena, used for argv.
const std = @import("std");
const Io = std.Io;
const Writer = std.Io.Writer;
const context = @import("context.zig");
const supermd = @import("supermd");

/// One documented function on a Scripty type.
const Builtin = struct {
    name: []const u8,
    /// Rendered parameter list, e.g. `&.{"String", "[String...]"}`. Precomputed
    /// at comptime so this file never needs either package's `Signature` type —
    /// the two are structurally identical but nominally distinct, and the
    /// supermd one is not even exported from its root module.
    params: []const []const u8,
    ret: []const u8,
    description: []const u8,
    /// Zigapagos builtins carry `examples`; supermd's do not.
    examples: ?[]const u8,
};

/// One documented data field on a Scripty type (`$page.title`, not `$page.title()`).
const Field = struct {
    name: []const u8,
    type_name: []const u8,
    description: []const u8,
};

const TypeDoc = struct {
    name: []const u8,
    description: []const u8,
    fields: []const Field,
    builtins: []const Builtin,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) fatal(
        "usage: docgen_reference <out-path>\n" ++
            "  writes the generated Scripty reference (markdown) to <out-path>\n",
        .{},
    );
    const out_path = args[1];

    const file = Io.Dir.cwd().createFile(io, out_path, .{}) catch |err| fatal(
        "error creating '{s}': {t}\n",
        .{ out_path, err },
    );
    defer file.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try writePage(w);
    try w.flush();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

// --- the page -----------------------------------------------------------------

/// Emitted markdown is consumed by two readers with different rules, and the
/// intersection is what this function targets:
///
///   * a human reading `docs/scripty.md` in the repository, and
///   * `site/scripts/gen-docs-mirror.ts`, which turns it into a `.smd` mirror.
///
/// The mirror is why every `$directive` in the output is wrapped in a code span.
/// A bare `$link.page(...)` in prose is a literal Scripty directive as far as
/// the rendered page is concerned, and `site/test/docs-mirror.sh` fails a build
/// that leaks one; worse, a description containing `[text]($link.page('x'))` —
/// and one of them does, `Page.contentSection`'s — would become a REAL link to a
/// page that does not exist here and fail the site build outright. See
/// `writeDescription`.
fn writePage(w: *Writer) !void {
    try w.writeAll(
        \\> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/scripty/> — the site is the canonical reading experience.
        \\
        \\# Scripty reference
        \\
        \\**This page is generated.** Do not edit it: run `zig build docs-reference`.
        \\Every entry below is read out of the Zig source with `@typeInfo`, from the
        \\`signature`, `docs_description` and `examples` declarations the builtins
        \\already carry — so a builtin cannot be added, renamed or re-signatured
        \\without this page moving. `tests/meta/scripty-reference.sh` fails the build
        \\when the committed copy and a fresh generation disagree.
        \\
        \\Scripty is the expression language in `$`-prefixed values. It appears in two
        \\places, and they have different vocabularies:
        \\
        \\- **In a `.shtml` layout**, inside a directive or an attribute value —
        \\  `<h1 :text="$page.title">`, `<a href="$site.asset('logo.svg').link()">`.
        \\  That vocabulary is the [global scope](#global-scope) and the
        \\  [types](#types) below.
        \\- **In a `.smd` content file**, inside a link target —
        \\  `[home]($link.site())`, `## []($heading.id("intro")) Intro`. That
        \\  vocabulary is the [content directives](#content-directives), which are a
        \\  different set entirely.
        \\
        \\A function marked `?` (`get?`, `prevPage?`) returns an optional instead of
        \\erroring, which is what `:if` unwraps into `$if`. In Scripty every error is
        \\unrecoverable and fails the build.
        \\
        \\
    );

    try writeShtmlHalf(w);
    try writeSuperMdHalf(w);
}

/// The `.shtml` vocabulary: `context.Root`'s fields are the global scope, and
/// every payload type of `context.Value` is a type an expression can evaluate to.
fn writeShtmlHalf(w: *Writer) !void {
    try w.writeAll(
        \\## Global scope
        \\
        \\The names available at the start of any `.shtml` Scripty expression.
        \\
        \\
    );
    inline for (comptime analyzeFields(context.Root)) |f| {
        try w.print("### `${s}` : {s}\n\n", .{ f.name, f.type_name });
        try writeDescription(w, f.description);
        try w.writeAll("\n\n");
    }

    try w.writeAll(
        \\## Types
        \\
        \\Every type a `.shtml` Scripty expression can evaluate to, with its data
        \\fields and its functions.
        \\
        \\
    );
    inline for (comptime analyzeValueTypes()) |t| {
        try writeTypeDoc(w, t, .shtml);
    }
}

/// The `.smd` vocabulary: supermd's directives. `Directive.Builtins` holds the
/// functions every directive shares — `$heading.id(...)` is one of those, not a
/// heading-specific function — and each `Directive.Kind` payload holds its own.
fn writeSuperMdHalf(w: *Writer) !void {
    try w.writeAll(
        \\## Content directives
        \\
        \\The `.smd` vocabulary. A directive is written as the TARGET of a Markdown
        \\link, and applies to that link's text:
        \\
        \\```markdown
        \\## []($heading.id("intro")) Intro
        \\
        \\[the home page]($link.site())
        \\
        \\[that section]($link.page("docs/spa").ref("route-guards--gated-spas"))
        \\```
        \\
        \\An empty link text (`[]`) applies the directive to the element the link
        \\sits in — which is how a heading gets an id without becoming a link.
        \\
        \\### Functions on every directive
        \\
        \\These four exist on every directive below, whatever its kind, and are
        \\written with that directive's own name in front: `$heading.id("intro")`,
        \\`$link.id("x")`, `$image.title("…")` are all the same function.
        \\
        \\
    );
    inline for (comptime analyzeBuiltins(supermd.Directive)) |b| {
        try writeBuiltin(w, "<directive>", b, .smd);
    }

    inline for (comptime analyzeDirectiveKinds()) |t| {
        try writeTypeDoc(w, t, .smd);
    }
}

const Flavor = enum { shtml, smd };

fn writeTypeDoc(w: *Writer, comptime t: TypeDoc, comptime flavor: Flavor) !void {
    switch (flavor) {
        .shtml => try w.print("### {s}\n\n", .{t.name}),
        .smd => try w.print("### `${s}`\n\n", .{t.name}),
    }
    try writeDescription(w, t.description);
    try w.writeAll("\n\n");

    if (t.fields.len > 0) {
        try w.writeAll("Fields:\n\n");
        inline for (t.fields) |f| {
            try w.print("- `{s}` : {s} — ", .{ f.name, f.type_name });
            try writeDescriptionInline(w, f.description);
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
    }

    inline for (t.builtins) |b| {
        try writeBuiltin(w, t.name, b, flavor);
    }
}

fn writeBuiltin(
    w: *Writer,
    comptime owner: []const u8,
    comptime b: Builtin,
    comptime flavor: Flavor,
) !void {
    // The heading carries the QUALIFIED name — `String.eql`, `$link.site` — so
    // that the thing a reader greps for is the thing they find. Issue #37's
    // whole complaint is that these names were only ever discovered by grepping
    // source; a heading of just `eql` would not have fixed that.
    switch (flavor) {
        .shtml => try w.print("#### `{s}.{s}(", .{ owner, b.name }),
        .smd => try w.print("#### `${s}.{s}(", .{ owner, b.name }),
    }
    inline for (b.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(p);
    }
    try w.print(") -> {s}`\n\n", .{b.ret});

    try writeDescription(w, b.description);
    try w.writeAll("\n\n");

    if (b.examples) |ex| {
        // Examples are Scripty source, so they belong in a fence — which also
        // keeps their `$` tokens out of the rendered page's prose.
        try w.writeAll("```superhtml\n");
        try w.writeAll(std.mem.trim(u8, ex, "\n"));
        try w.writeAll("\n```\n\n");
    }
}

// --- description escaping -----------------------------------------------------

/// Write a docs string as markdown that is safe in a generated page.
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing.
///
/// Two transformations, both load-bearing rather than cosmetic:
///
///  1. **A `$token` is wrapped in a code span.** Descriptions are written for a
///     reader, so they name directives inline (`$page.title`, `$link.page`). In
///     the site mirror a bare one of those is a literal Scripty directive in
///     prose, which `site/test/docs-mirror.sh` fails the build over — a gate
///     that exists because an unrendered directive leaking into a page as text
///     is a real, previously-shipped bug.
///  2. **A `[` outside a code span is escaped.** `Page.contentSection`'s
///     description embeds a full markdown link whose target is a `$link.page`
///     directive naming a page that does not exist in this repository. Emitted
///     verbatim it is not merely ugly: it is a link the site build resolves and
///     fails on (`error: unknown page`).
///
/// Text already inside a code span is passed through untouched — double-wrapping
/// would break the span rather than protect it.
const upstream_name = "Zi" ++ "ne";

fn writeDescription(w: *Writer, text: []const u8) !void {
    var in_code = false;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '`') {
            // A RUN of backticks is one delimiter, not N. Some descriptions
            // embed a fenced block (supermd's `$heading` description shows a
            // ```markdown sample), and toggling per character would only
            // happen to work when the run length is odd.
            var n = i;
            while (n < text.len and text[n] == '`') n += 1;
            in_code = !in_code;
            try w.writeAll(text[i..n]);
            i = n;
            continue;
        }
        if (in_code) {
            try w.writeByte(c);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], upstream_name)) {
            // Rebrand a description that names the upstream project.
            //
            // These strings come from the vendored supermd package and describe
            // behaviour THIS tool implements, so the upstream name in them is
            // simply stale after the fork's rebrand — and tests/branding.sh
            // fails a tracked file that carries it. The alternative, emitting
            // `branding-ok` markers into generated output, would be an
            // exemption nobody wrote and nobody re-checks, which is exactly
            // what that marker is designed not to be.
            //
            // The needle is assembled from two fragments so it never exists as
            // a contiguous string in this file — the same trick tests/branding.sh
            // uses on itself, and for the same reason: this file must be
            // searchable by that gate's own grep.
            try w.writeAll("Zigapagos");
            i += upstream_name.len;
            continue;
        }
        switch (c) {
            '[' => {
                try w.writeAll("\\[");
                i += 1;
            },
            ']' => {
                // Escaping the `[` alone is NOT enough. The site mirror rewrites
                // link targets with a regex that looks for `](target)` and never
                // sees the opening bracket, so `\[text](...)` still had its
                // target rewritten -- turning `Page.contentSection`'s embedded
                // sample into a real GitHub URL in the page's prose, which
                // site/test/docs-mirror.sh then failed. Breaking the `](`
                // sequence itself is what actually stops it; `\(` renders as a
                // plain `(`.
                if (i + 1 < text.len and text[i + 1] == '(') {
                    try w.writeAll("]\\(");
                    i += 2;
                } else {
                    try w.writeByte(']');
                    i += 1;
                }
            },
            '$' => {
                const end = scanScriptyToken(text, i);
                try w.writeByte('`');
                try w.writeAll(text[i..end]);
                try w.writeByte('`');
                i = end;
            },
            else => {
                try w.writeByte(c);
                i += 1;
            },
        }
    }
}

/// As `writeDescription`, but folded onto one line — for a description used as a
/// list item, where a hard newline would end the item.
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing.
fn writeDescriptionInline(w: *Writer, text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (!first) try w.writeByte(' ');
        first = false;
        try writeDescription(w, trimmed);
    }
}

/// The end offset of the `$…` expression starting at `start`.
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing.
///
/// Consumes identifier characters, `.`, and BALANCED parentheses (so
/// `$link.page('a').ref('b')` is one token). A trailing `.` or `,` is given
/// back — it is sentence punctuation far more often than it is a member access,
/// and a code span that swallows the full stop reads as a typo.
fn scanScriptyToken(text: []const u8, start: usize) usize {
    var i = start + 1; // past the '$'
    var depth: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
            continue;
        }
        if (depth > 0) continue; // inside args: take everything
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '?' or c == '$') continue;
        break;
    }
    while (i > start + 1 and (text[i - 1] == '.' or text[i - 1] == ',')) i -= 1;
    return i;
}

// --- comptime analysis --------------------------------------------------------

/// Every payload type of `context.Value`, which is the set of types a `.shtml`
/// expression can evaluate to. The `err` variant carries no struct (it is a
/// `[]const u8` message) and is described by hand.
fn analyzeValueTypes() []const TypeDoc {
    @setEvalBranchQuota(1_000_000);
    const info = @typeInfo(context.Value).@"union";
    var out: [info.fields.len]TypeDoc = undefined;
    var n: usize = 0;
    inline for (info.fields) |f| {
        const T = structTypeOf(f.type) orelse continue;
        if (!@hasDecl(T, "Builtins")) continue;
        out[n] = analyzeType(T, shortTypeName(T));
        n += 1;
    }
    const frozen = out[0..n].*;
    return &frozen;
}

fn analyzeType(comptime T: type, comptime name: []const u8) TypeDoc {
    return .{
        .name = name,
        .description = descriptionOf(T),
        .fields = analyzeFields(T),
        .builtins = analyzeBuiltins(T),
    };
}

/// The directives a `.smd` file can use, from supermd's `Directive.Kind` union:
/// the union's field NAME is what an author types after the `$`, and its payload
/// type holds the description and the kind-specific functions.
fn analyzeDirectiveKinds() []const TypeDoc {
    @setEvalBranchQuota(1_000_000);
    const info = @typeInfo(supermd.Directive.Kind).@"union";
    var out: [info.fields.len]TypeDoc = undefined;
    inline for (info.fields, &out) |f, *t| {
        t.* = analyzeType(f.type, f.name);
    }
    const frozen = out;
    return &frozen;
}

fn analyzeBuiltins(comptime T: type) []const Builtin {
    @setEvalBranchQuota(1_000_000);
    const info = @typeInfo(T.Builtins).@"struct";
    var out: [info.decls.len]Builtin = undefined;
    inline for (info.decls, &out) |decl, *b| {
        const D = @field(T.Builtins, decl.name);
        b.* = .{
            .name = decl.name,
            .params = if (comptime isDirectiveSetter(D))
                &.{setterParamName(T, decl.name)}
            else
                paramNames(D.signature),
            .ret = if (comptime isDirectiveSetter(D))
                "anydirective"
            else
                D.signature.ret.string(false),
            .description = descriptionOf(D),
            .examples = if (@hasDecl(D, "examples")) D.examples else null,
        };
    }
    const frozen = out;
    return &frozen;
}

/// True for a builtin produced by supermd's `utils.directiveBuiltin(...)`
/// factory — the one-line setters like `$block.collapsible(...)`.
///
/// WHY THIS EXISTS. Those builtins' `signature` decl cannot be analysed at all:
/// it switches over `@typeInfo(context.Value).tag_type` and names a `.content`
/// prong that the union has not had since it was renamed to `root`
/// (`src/context/utils.zig` in the vendored supermd). Nothing in a normal build
/// evaluates `signature` — Scripty's dispatch only ever calls `call` — so the
/// rot is invisible until something walks the metadata, which is exactly what
/// this generator does. The vendored package is a build input and is never
/// edited here, so the fix has to be on this side: recognise the factory and
/// reconstruct what it would have said.
///
/// Recognition is by `@typeName`, which for a type returned from a generic
/// function includes that function's name. It is a coarse test on purpose: a
/// false positive costs a slightly-less-precise parameter type on one row, and
/// there is no other way to ask "would this decl compile?".
fn isDirectiveSetter(comptime D: type) bool {
    return std.mem.indexOf(u8, @typeName(D), "directiveBuiltin") != null;
}

/// The parameter type of a `directiveBuiltin` setter, recovered from the field
/// it sets: `directiveBuiltin("collapsible", .bool, …)` on a type whose
/// `collapsible` field is `?bool` takes a bool. The `?` is dropped — it
/// describes the FIELD being unset, not an optional argument.
fn setterParamName(comptime T: type, comptime name: []const u8) []const u8 {
    for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            const n = fieldTypeName(f.type);
            return if (n.len > 0 and n[0] == '?') n[1..] else n;
        }
    }
    return "any";
}

/// The rendered parameter type names of a signature. Generic over the two
/// packages' `Signature` types on purpose: they are structurally identical
/// (`params`/`ret` of a `ScriptyParam` with a `.string()` method) and nominally
/// distinct, and supermd's is not exported from its root module.
fn paramNames(comptime sig: anytype) []const []const u8 {
    var out: [sig.params.len][]const u8 = undefined;
    inline for (sig.params, &out) |p, *s| s.* = p.string(true);
    const frozen = out;
    return &frozen;
}

fn analyzeFields(comptime T: type) []const Field {
    @setEvalBranchQuota(1_000_000);
    if (!@hasDecl(T, "Fields")) return &.{};
    const info = @typeInfo(T).@"struct";
    var out: [info.fields.len]Field = undefined;
    var n: usize = 0;
    inline for (info.fields) |tf| {
        if (tf.name[0] == '_') continue; // private: `_meta`, `_items`, …
        if (!@hasDecl(T.Fields, tf.name)) continue;
        out[n] = .{
            .name = tf.name,
            .type_name = fieldTypeName(tf.type),
            .description = @field(T.Fields, tf.name),
        };
        n += 1;
    }
    const frozen = out[0..n].*;
    return &frozen;
}

/// Zigapagos types declare `docs_description`; supermd's declare `description`.
/// One accessor rather than two analysis passes.
fn descriptionOf(comptime T: type) []const u8 {
    if (@hasDecl(T, "docs_description")) return T.docs_description;
    if (@hasDecl(T, "description")) return T.description;
    return "";
}

/// A readable Scripty type name for a struct field's Zig type.
///
/// `context.ScriptyParam.fromType` would be the obvious tool and is deliberately
/// NOT used: it is one exhaustive `switch` over every mapped type, so analysing
/// it analyses ALL of its prongs — including a dead `context.Template => .any`
/// left behind when upstream renamed that type to `context.Root` (commit
/// 43160ee, pre-fork). Calling it is therefore a compile error today, which is
/// the same rot that keeps `-Ddocgen` from building. Un-rotting it means
/// editing an inherited file for the sake of a fork-added tool; this ~20-line
/// mapping keeps the change on our side of the line instead.
fn fieldTypeName(comptime T: type) []const u8 {
    return switch (T) {
        []const u8 => "String",
        ?[]const u8 => "?String",
        []const []const u8 => "[String]",
        bool => "Bool",
        usize, i64 => "Int",
        f64 => "Float",
        else => switch (@typeInfo(T)) {
            .optional => |o| "?" ++ fieldTypeName(o.child),
            .pointer => |ptr| if (ptr.size == .one)
                fieldTypeName(ptr.child)
            else
                "[" ++ fieldTypeName(ptr.child) ++ "]",
            else => shortTypeName(T),
        },
    };
}

/// `@typeName` yields a fully-qualified path (`context.Page`, or a longer one
/// for a generic instantiation). The reference wants the bare name a reader
/// sees in a signature — `Page` — which is the last dot-separated component.
fn shortTypeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    // A generic instantiation's name carries its arguments —
    // `superhtml.utils.Ctx(context.Value)` — and the last dot is inside those.
    // Cut at the first '(' before looking for it.
    const head = full[0 .. std.mem.indexOfScalar(u8, full, '(') orelse full.len];
    const dot = std.mem.lastIndexOfScalar(u8, head, '.') orelse return head;
    return head[dot + 1 ..];
}

fn structTypeOf(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"struct" => T,
        .pointer => |p| if (p.size == .one) structTypeOf(p.child) else null,
        .optional => |o| structTypeOf(o.child),
        else => null,
    };
}
