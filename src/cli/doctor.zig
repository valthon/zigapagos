//! `zigapagos doctor [DIR]` — audits a BUILT output tree for authoring
//! mistakes that are only visible in the emitted HTML. It never builds a
//! site and never reads site source; it opens `DIR` (default `public`,
//! matching `zigapagos release`'s default `--output`) read-only and inspects
//! whatever HTML landed there.
//!
//! This is deliberately narrow: issues #21-#25 are shipping inline
//! build-time diagnostics in sibling changes, so doctor's job is only the
//! class of mistake that build-time diagnostics structurally cannot see —
//! the FINAL emitted markup, after every render pass has had its say.
//!
//! Two checks ship (see `checks` below): `abs-url-meta` (a root-relative
//! Open Graph / Twitter / canonical URL — `err`, because crawlers can't
//! resolve it) and `dangling-internal-link` (a root-relative href/src with
//! no file behind it in the tree — `warn`, because a client-routed SPA route
//! legitimately has no file and would otherwise force a false positive).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fatal = @import("../fatal.zig");
const superhtml = @import("superhtml");

/// Contract 1 (self-freeing, NO_SLOP.md §2.2a): every allocation (the
/// `.html` path list, one file's source, one file's Ast) is freed before
/// `doctor` returns; nothing escapes to the caller.
pub fn doctor(io: Io, gpa: Allocator, args: []const []const u8) bool {
    const cmd: Command = .parse(args);

    var root_dir = Io.Dir.cwd().openDir(io, cmd.dir, .{ .iterate = true }) catch |err| {
        fatal.usageError(
            "error: cannot open site tree '{s}': {t}\n\n" ++
                "zigapagos doctor audits a BUILT site tree; run 'zigapagos release --output={s}' first\n",
            .{ cmd.dir, err, cmd.dir },
        );
    };
    defer root_dir.close(io);

    // Collect every `.html` path first (rather than auditing during the
    // walk) so the report order can be sorted — see below.
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    {
        var walker = root_dir.walk(gpa) catch fatal.oom();
        defer walker.deinit();
        while (walker.next(io) catch |err| {
            // A walk error yields a PARTIAL file list. Reporting whatever we
            // saw as "clean" would be worse than reporting nothing — same
            // reasoning as the zero-`.html`-files rule below: a gate that
            // audited only part of the tree must not report success.
            std.debug.print(
                "doctor: could not finish scanning '{s}': {t}\n",
                .{ cmd.dir, err },
            );
            return true;
        }) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".html")) continue;
            // `entry.path` is reused by the walker on the next `next()`
            // call, so it must be duplicated before it outlives this
            // iteration (same pattern as dev.zig's `relPagePath`).
            const dup = gpa.dupe(u8, entry.path) catch fatal.oom();
            paths.append(gpa, dup) catch fatal.oom();
        }
    }

    // A gate that audits nothing must not report success: a wrong DIR (a
    // typo, or a source tree instead of a built one) would otherwise pass
    // forever.
    if (paths.items.len == 0) {
        fatal.usageError(
            "error: no .html files under '{s}' — is this a built site tree?\n",
            .{cmd.dir},
        );
    }

    // Stable output order regardless of readdir order — load-bearing for the
    // shell tests, which grep exact line order.
    std.mem.sortUnstable([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var out_buf: [8 * 1024]u8 = undefined;
    const stdout = Io.File.stdout();
    var fw = stdout.writer(io, &out_buf);
    var ctx: Ctx = .{
        .io = io,
        .w = &fw.interface,
        .root_dir = root_dir,
        .url_prefix = cmd.url_prefix,
    };

    for (paths.items) |path| {
        const src = root_dir.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
            // A file doctor could not read must not be silently treated as
            // clean: it counts toward `skipped`, which forces a non-zero
            // exit below.
            std.debug.print("doctor: skipped '{s}': {t}\n", .{ path, err });
            ctx.skipped += 1;
            continue;
        };
        defer gpa.free(src);

        // `syntax_only = true`: `Ast.init` in this mode only returns
        // `error{OutOfMemory}` — a syntax error just sets
        // `has_syntax_errors` and leaves whatever nodes it managed to
        // produce. Best-effort on malformed input is the right call here:
        // doctor audits arbitrary built trees, and refusing to scan a file
        // over a stray '<' would cost real coverage for no benefit —
        // reporting HTML syntax errors is superhtml's own linter's job, not
        // doctor's.
        var ast = superhtml.html.Ast.init(gpa, src, .html, true) catch fatal.oom();
        defer ast.deinit(gpa);

        const doc: Doc = .{ .path = path, .src = src, .ast = ast };
        ctx.files += 1;
        for (checks) |check| {
            check.run(&ctx, doc) catch |err| fatal.msg(
                "error writing doctor report to stdout: {t}\n",
                .{err},
            );
        }
    }

    // The summary always prints, even on a completely clean tree — that is
    // the only output a clean run produces, and grep-ability of "doctor: 0
    // error" is the contract.
    fw.interface.print(
        "doctor: {d} error{s}, {d} warning{s} across {d} file{s}",
        .{
            ctx.errors,   plural(ctx.errors),
            ctx.warnings, plural(ctx.warnings),
            ctx.files,    plural(ctx.files),
        },
    ) catch |err| fatal.msg("error writing doctor report to stdout: {t}\n", .{err});
    if (ctx.skipped > 0) {
        fw.interface.print(", {d} file{s} skipped", .{ ctx.skipped, plural(ctx.skipped) }) catch |err|
            fatal.msg("error writing doctor report to stdout: {t}\n", .{err});
    }
    fw.interface.writeAll("\n") catch |err|
        fatal.msg("error writing doctor report to stdout: {t}\n", .{err});

    // A write failure (EPIPE, ENOSPC) mid-report must not exit 0: exiting 0
    // after a truncated report would mean "clean" to a caller that only
    // checks the exit code (same rationale `migrate --doctor` documents for
    // its own flush).
    fw.interface.flush() catch |err|
        fatal.msg("error writing doctor report to stdout: {t}\n", .{err});

    return ctx.errors > 0 or ctx.skipped > 0 or (cmd.strict and ctx.warnings > 0);
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

pub const Command = struct {
    dir: []const u8 = "public",
    url_prefix: []const u8 = "",
    strict: bool = false,

    /// Contract 1 (self-freeing, trivially: nothing here allocates at all).
    /// Every field is either a literal or slices into `args`, which the
    /// caller (main.zig's arena-backed argv) owns for the process lifetime.
    pub fn parse(args: []const []const u8) Command {
        var dir: []const u8 = "public";
        var url_prefix: []const u8 = "";
        var strict = false;
        var have_dir = false;

        const eql = std.mem.eql;
        const startsWith = std.mem.startsWith;
        for (args) |arg| {
            if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
                fatal.usage(help_message, .{});
            } else if (startsWith(u8, arg, "--url-prefix=")) {
                url_prefix = normalizeUrlPrefix(arg["--url-prefix=".len..]);
            } else if (eql(u8, arg, "--strict")) {
                strict = true;
            } else if (startsWith(u8, arg, "-")) {
                fatal.usageError("error: unknown flag '{s}'\n\n{s}", .{ arg, help_message });
            } else if (!have_dir) {
                dir = arg;
                have_dir = true;
            } else {
                fatal.usageError(
                    "error: unexpected extra argument '{s}' (doctor takes at most one DIR)\n\n{s}",
                    .{ arg, help_message },
                );
            }
        }

        return .{ .dir = dir, .url_prefix = url_prefix, .strict = strict };
    }
};

/// Normalises a `--url-prefix=` value to a bare path segment: strip leading
/// and trailing '/'. Empty after stripping means "no prefix", the same as
/// not passing the flag — `--url-prefix=/` and `--url-prefix=` are
/// equivalent to omitting it.
fn normalizeUrlPrefix(raw: []const u8) []const u8 {
    var p = raw;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    while (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    return p;
}

const help_message =
    \\Usage: zigapagos doctor [DIR] [OPTIONS]
    \\
    \\Audit a BUILT site tree (default 'public') and report authoring mistakes that
    \\are only visible in the emitted HTML. Reads only: never builds, never writes.
    \\
    \\Command specific options:
    \\  --url-prefix=P    The site's url_path_prefix (e.g. 'zigapagos' for a GitHub
    \\                    Pages project site): root-relative links are expected to
    \\                    start with '/P/'
    \\  --strict          Exit non-zero on warnings too (errors always exit non-zero)
    \\  --help, -h        Show this help menu
    \\
    \\
;

const Severity = enum { err, warn };

/// What a check may fail with: a write to the report stream, and nothing
/// else. Deliberately NOT `anyerror` (NO_SLOP.md §2.3), and deliberately not
/// widened "in case a future check allocates" either: both checks work from
/// the driver's already-parsed `Doc` and caller-supplied stack buffers, so a
/// wider set would be an error the driver must handle and can never see —
/// and its one handler below reports every failure as a write failure, which
/// an allocation failure is not. A check that genuinely needs to allocate
/// widens this then, with a handler that says so.
const CheckError = std.Io.Writer.Error;

const Check = struct {
    id: []const u8,
    severity: Severity,
    run: *const fn (*Ctx, Doc) CheckError!void,
};

const check_abs_url_meta: Check = .{
    .id = "abs-url-meta",
    .severity = .err,
    .run = checkAbsUrlMeta,
};
const check_dangling_internal_link: Check = .{
    .id = "dangling-internal-link",
    .severity = .warn,
    .run = checkDanglingInternalLink,
};

const checks: []const Check = &.{
    check_abs_url_meta,
    check_dangling_internal_link,
};

/// One parsed `.html` file, produced ONCE by the driver and fanned to every
/// check in `checks` — checks must not re-parse.
const Doc = struct {
    /// Tree-relative slash path, e.g. "guides/index.html".
    path: []const u8,
    src: []const u8,
    ast: superhtml.html.Ast,
};

const Ctx = struct {
    io: Io,
    w: *std.Io.Writer,
    root_dir: Io.Dir,
    /// Normalised (no leading/trailing '/'); empty means "no prefix".
    url_prefix: []const u8,
    errors: usize = 0,
    warnings: usize = 0,
    files: usize = 0,
    skipped: usize = 0,
};

/// Prints one finding as "<severity-word> <id>: <path>: <fmt>\n" to the
/// report stream and bumps the matching counter. `<severity-word>` is the
/// literal text "error"/"warn" (not the Zig `error` keyword).
fn report(
    ctx: *Ctx,
    check: Check,
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) std.Io.Writer.Error!void {
    const word: []const u8 = switch (check.severity) {
        .err => "error",
        .warn => "warn",
    };
    try ctx.w.print("{s} {s}: {s}: " ++ fmt ++ "\n", .{ word, check.id, path } ++ args);
    switch (check.severity) {
        .err => ctx.errors += 1,
        .warn => ctx.warnings += 1,
    }
}

/// URL-valued Open Graph / Twitter / Twitter-card / canonical keys — an
/// ALLOWLIST on purpose. `og:title`/`og:description`/`twitter:card` etc. are
/// free text, and a value that happens to start with '/' there (e.g. a title
/// beginning "/dev/null explained") is not a URL mistake. Flagging those too
/// would make the `err` severity above unsafe.
const url_meta_keys = std.StaticStringMap(void).initComptime(.{
    .{ "og:url", {} },
    .{ "og:image", {} },
    .{ "og:image:url", {} },
    .{ "og:image:secure_url", {} },
    .{ "og:video", {} },
    .{ "og:video:url", {} },
    .{ "og:video:secure_url", {} },
    .{ "og:audio", {} },
    .{ "og:audio:url", {} },
    .{ "og:audio:secure_url", {} },
    .{ "twitter:url", {} },
    .{ "twitter:image", {} },
    .{ "twitter:image:src", {} },
    .{ "twitter:player", {} },
    .{ "twitter:player:stream", {} },
});

fn isUrlValuedMetaKey(key: []const u8) bool {
    // Meta keys are case-insensitive in HTML ("OG:Image" is legal); the
    // allowlist is written lowercase, so lowercase-compare rather than
    // requiring an exact spelling match.
    var buf: [64]u8 = undefined;
    if (key.len > buf.len) return false;
    return url_meta_keys.has(std.ascii.lowerString(buf[0..key.len], key));
}

/// "Root-relative": starts with exactly one '/' (not '//'). A `//host/path`
/// is scheme-relative — browsers/crawlers resolve it against the current
/// scheme, not the site root — so flagging it as root-relative would print a
/// false statement about what's wrong with it.
fn isRootRelative(v: []const u8) bool {
    return v.len > 0 and v[0] == '/' and !(v.len > 1 and v[1] == '/');
}

/// Attribute values are NOT entity-decoded here: superhtml's
/// `Attr.Value.unescape` is an upstream TODO stub that just returns the raw
/// slice. That's acceptable for doctor's purposes — entities inside the URLs
/// this tool inspects are vanishingly rare, and `dangling-internal-link`
/// strips query/fragment before ever resolving one — but say so, so a future
/// reader doesn't assume decoding happened.
fn attrValue(attr: superhtml.html.Tokenizer.Attr, src: []const u8) ?[]const u8 {
    const v = attr.value orelse return null;
    return v.span.slice(src);
}

/// Fires on a URL-valued social/canonical meta whose value is root-relative.
/// Not restricted to `<head>`: a root-relative `og:image` is wrong wherever
/// it sits in the document, and requiring an ancestor walk to reach it would
/// only add false negatives for no benefit.
fn checkAbsUrlMeta(ctx: *Ctx, doc: Doc) CheckError!void {
    for (doc.ast.nodes) |node| {
        switch (node.kind) {
            .meta => {
                var key: ?[]const u8 = null;
                var content: ?[]const u8 = null;
                var it = node.startTagIterator(doc.src, doc.ast.language);
                while (it.next(doc.src)) |attr| {
                    const name = attr.name.slice(doc.src);
                    // Either spelling names the meta — generators emit
                    // `property=` for Open Graph and `name=` for Twitter, and
                    // both are seen for both. Whichever appears FIRST wins;
                    // HTML gives no precedence rule, and a `<meta>` carrying
                    // both with different values is malformed either way.
                    if (key == null and std.ascii.eqlIgnoreCase(name, "property")) {
                        key = attrValue(attr, doc.src);
                    } else if (key == null and std.ascii.eqlIgnoreCase(name, "name")) {
                        key = attrValue(attr, doc.src);
                    } else if (std.ascii.eqlIgnoreCase(name, "content")) {
                        content = attrValue(attr, doc.src);
                    }
                }
                const k = key orelse continue;
                const v = content orelse continue;
                if (!isUrlValuedMetaKey(k)) continue;
                if (!isRootRelative(v)) continue;
                try report(
                    ctx,
                    check_abs_url_meta,
                    doc.path,
                    "{s} is root-relative ('{s}'); Open Graph and Twitter card metadata " ++
                        "require an absolute URL — build one from $site.host_url (e.g. " ++
                        "$site.host_url.addPath($site.asset('og.png').link()))",
                    .{ k, v },
                );
            },
            .link => {
                var rel: ?[]const u8 = null;
                var href: ?[]const u8 = null;
                var it = node.startTagIterator(doc.src, doc.ast.language);
                while (it.next(doc.src)) |attr| {
                    const name = attr.name.slice(doc.src);
                    if (std.ascii.eqlIgnoreCase(name, "rel")) rel = attrValue(attr, doc.src);
                    if (std.ascii.eqlIgnoreCase(name, "href")) href = attrValue(attr, doc.src);
                }
                const r = rel orelse continue;
                const h = href orelse continue;
                if (!hasRelToken(r, "canonical")) continue;
                if (!isRootRelative(h)) continue;
                try report(
                    ctx,
                    check_abs_url_meta,
                    doc.path,
                    "rel=canonical is root-relative ('{s}'); a canonical URL must be " ++
                        "absolute — build one from $site.host_url",
                    .{h},
                );
            },
            else => {},
        }
    }
}

/// `rel` is a space-separated, multi-valued attribute (`rel="canonical
/// alternate"` must fire) — tokenise on ASCII whitespace and compare
/// case-insensitively (HTML tokens compare case-insensitively per spec).
fn hasRelToken(rel: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, rel, " \t\n\r\x0c");
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, token)) return true;
    }
    return false;
}

/// Root-relative `href`/`src` that resolves to no file in the tree. No tag
/// allowlist — every element node's `href`/`src` is inspected, catching
/// `<a>`, `<link>`, `<script>`, `<img>`, `<iframe>`, `<source>`, `<use>`
/// alike; a tag allowlist would just be more surface for false negatives.
///
/// Severity `warn`, not `err`: a client-routed SPA URL has no file behind
/// it — the route is served by the SPA shell + runtime router — and
/// legitimately warns here. That's an accepted, known false-positive class,
/// not a defect in this check.
fn checkDanglingInternalLink(ctx: *Ctx, doc: Doc) CheckError!void {
    for (doc.ast.nodes) |node| {
        if (!node.kind.isElement()) continue;
        var it = node.startTagIterator(doc.src, doc.ast.language);
        while (it.next(doc.src)) |attr| {
            const name = attr.name.slice(doc.src);
            const is_href = std.ascii.eqlIgnoreCase(name, "href");
            const is_src = std.ascii.eqlIgnoreCase(name, "src");
            if (!is_href and !is_src) continue;
            const value = attrValue(attr, doc.src) orelse continue;
            try checkOneLink(ctx, doc, if (is_href) "href" else "src", value);
        }
    }
}

fn checkOneLink(
    ctx: *Ctx,
    doc: Doc,
    attr_name: []const u8,
    original: []const u8,
) CheckError!void {
    // Excludes #frag, ?q, mailto:, tel:, data:, absolute (https://…) and
    // relative (relative.html) targets in one rule, plus scheme-relative
    // (//cdn/x.js) alongside them.
    if (!isRootRelative(original)) return;

    var stripped = original;
    if (std.mem.indexOfAny(u8, stripped, "#?")) |i| stripped = stripped[0..i];

    var decode_buf: [std.fs.max_path_bytes]u8 = undefined;
    // A malformed escape means doctor cannot know what file the author
    // meant — skip the link rather than guess.
    const decoded = percentDecode(&decode_buf, stripped) orelse return;

    // `decoded` still starts with '/' (isRootRelative guarantees the first
    // byte; stripping #/? and percent-decoding never touch it).
    const bare = decoded[1..];

    var matched = true;
    var remainder: []const u8 = bare;
    if (ctx.url_prefix.len > 0) {
        if (stripUrlPrefix(decoded, ctx.url_prefix)) |r| {
            remainder = r;
        } else {
            matched = false;
        }
    }

    var norm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const norm = normalizeLexical(&norm_buf, remainder);

    if (matched) {
        const n = norm orelse {
            try report(
                ctx,
                check_dangling_internal_link,
                doc.path,
                "{s} '{s}' escapes the site root",
                .{ attr_name, original },
            );
            return;
        };
        if (resolves(ctx, n)) return;
        try report(
            ctx,
            check_dangling_internal_link,
            doc.path,
            "{s} '{s}' resolves to no file in the tree",
            .{ attr_name, original },
        );
        return;
    }

    // `--url-prefix` is set and this link does not start with it: it 404s in
    // production (the host serves the tree at /<prefix>/, not at /) no
    // matter what physically lives in the output tree — a finding
    // unconditionally. If the AUTHOR-INTENDED prefixed form would have
    // resolved, say so: that's the shipped symptom this flag exists to
    // catch (href="/guides" instead of "/zigapagos/guides" hard-404ing
    // under a project-pages prefix). Prefixing the URL and then stripping
    // that same prefix again cancels out, so "does the prefixed form
    // resolve" reduces to "does `norm` of the un-prefixed remainder
    // resolve" — no second normalisation pass needed.
    if (norm) |n| {
        if (resolves(ctx, n)) {
            var suggest_buf: [std.fs.max_path_bytes]u8 = undefined;
            const suggested = if (n.len == 0)
                std.fmt.bufPrint(&suggest_buf, "/{s}", .{ctx.url_prefix}) catch null
            else
                std.fmt.bufPrint(&suggest_buf, "/{s}/{s}", .{ ctx.url_prefix, n }) catch null;
            if (suggested) |s| {
                try report(
                    ctx,
                    check_dangling_internal_link,
                    doc.path,
                    "{s} '{s}' resolves to no file in the tree (did you mean '{s}'?)",
                    .{ attr_name, original, s },
                );
                return;
            }
        }
    }
    try report(
        ctx,
        check_dangling_internal_link,
        doc.path,
        "{s} '{s}' resolves to no file in the tree",
        .{ attr_name, original },
    );
}

/// If `path` (which always starts with '/') is exactly "/" + `prefix` or
/// starts with "/" + `prefix` + "/", returns the physical tree-relative
/// remainder (no leading slash; "" for the prefix root itself). Returns null
/// on anything else, including a path that merely starts with `prefix` as a
/// string but not as a path segment (prefix "docs" must not match
/// "/docs-legacy").
fn stripUrlPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    const after_slash = path[1..];
    if (std.mem.eql(u8, after_slash, prefix)) return "";
    if (std.mem.startsWith(u8, after_slash, prefix) and
        after_slash.len > prefix.len and after_slash[prefix.len] == '/')
    {
        return after_slash[prefix.len + 1 ..];
    }
    return null;
}

/// Does `norm` (a lexically-normalised, tree-relative path with no leading
/// slash — "" means the tree root) resolve to a REGULAR FILE? A directory
/// does NOT count: `/guides` with no `guides/index.html` must still warn, or
/// an author would only find out at request time.
fn resolves(ctx: *Ctx, norm: []const u8) bool {
    if (norm.len == 0) return isRegularFile(ctx, "index.html");
    if (isRegularFile(ctx, norm)) return true;

    var buf1: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrint(&buf1, "{s}/index.html", .{norm})) |p| {
        if (isRegularFile(ctx, p)) return true;
    } else |_| {}

    if (!std.mem.endsWith(u8, norm, ".html")) {
        var buf2: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&buf2, "{s}.html", .{norm})) |p| {
            if (isRegularFile(ctx, p)) return true;
        } else |_| {}
    }
    return false;
}

fn isRegularFile(ctx: *Ctx, path: []const u8) bool {
    const st = ctx.root_dir.statFile(ctx.io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Percent-decodes `s` into `buf` — NO_SLOP.md §2.2a contract 3
/// (caller-buffer): allocates nothing. Returns null when the decoded form
/// would not fit in `buf`, or an escape is malformed (`%` not followed by
/// two hex digits) — a malformed escape means the target is unknowable, so
/// the caller skips the link rather than guessing.
fn percentDecode(buf: []u8, s: []const u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return null;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return null;
            if (out >= buf.len) return null;
            buf[out] = hi * 16 + lo;
            out += 1;
            i += 3;
        } else {
            if (out >= buf.len) return null;
            buf[out] = s[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

/// Lexically normalises a tree-relative, slash-separated path with no
/// leading slash: resolves "." and ".." segments and collapses empty
/// segments, so a trailing '/' (or a run of "//") simply vanishes — the
/// filesystem resolution step (`resolves`) already tries the `/index.html`
/// and `.html` suffixes regardless, so a bare path and its slash-terminated
/// spelling normalising to the same string is exactly what's wanted, not a
/// loss of information.
///
/// Returns null when a ".." would climb above the tree root. NO_SLOP.md
/// §2.2a contract 3 (caller-buffer): writes into `buf`, allocates nothing.
/// Callers must not `statFile` a path that failed to normalise — an
/// escaping path must never reach the filesystem.
fn normalizeLexical(buf: []u8, path: []const u8) ?[]const u8 {
    // One rollback point (the `out` offset right before a segment plus its
    // preceding separator) per path depth, so ".." can restore `out`
    // exactly rather than re-deriving it. 256 covers every realistic site
    // path; a deeper one is treated as unresolvable rather than truncated
    // silently.
    var bounds: [256]usize = undefined;
    var depth: usize = 0;
    var out: usize = 0;

    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (depth == 0) return null;
            depth -= 1;
            out = bounds[depth];
            continue;
        }
        if (depth >= bounds.len) return null;
        bounds[depth] = out;
        depth += 1;

        if (out > 0) {
            if (out >= buf.len) return null;
            buf[out] = '/';
            out += 1;
        }
        if (out + seg.len > buf.len) return null;
        @memcpy(buf[out .. out + seg.len], seg);
        out += seg.len;
    }
    return buf[0..out];
}

test "doctor: Command.parse defaults dir to 'public', no prefix, not strict" {
    const cmd: Command = .parse(&.{});
    try std.testing.expectEqualStrings("public", cmd.dir);
    try std.testing.expectEqualStrings("", cmd.url_prefix);
    try std.testing.expect(!cmd.strict);
}

test "doctor: Command.parse accepts a positional DIR" {
    const cmd: Command = .parse(&.{"dist"});
    try std.testing.expectEqualStrings("dist", cmd.dir);
}

test "doctor: Command.parse normalises --url-prefix=" {
    try std.testing.expectEqualStrings("p", Command.parse(&.{"--url-prefix=/p/"}).url_prefix);
    try std.testing.expectEqualStrings("p", Command.parse(&.{"--url-prefix=p"}).url_prefix);
    try std.testing.expectEqualStrings("", Command.parse(&.{"--url-prefix=/"}).url_prefix);
    try std.testing.expectEqualStrings("", Command.parse(&.{"--url-prefix="}).url_prefix);
}

test "doctor: Command.parse recognizes --strict" {
    try std.testing.expect(Command.parse(&.{"--strict"}).strict);
}

test "doctor: isRootRelative classifies root-relative vs. everything else" {
    try std.testing.expect(isRootRelative("/x"));
    try std.testing.expect(!isRootRelative("//host/x"));
    try std.testing.expect(!isRootRelative("x"));
    try std.testing.expect(!isRootRelative(""));
}

test "doctor: isUrlValuedMetaKey allowlist" {
    try std.testing.expect(isUrlValuedMetaKey("og:image"));
    try std.testing.expect(isUrlValuedMetaKey("og:image:secure_url"));
    try std.testing.expect(!isUrlValuedMetaKey("og:title"));
    try std.testing.expect(!isUrlValuedMetaKey("twitter:card"));
    try std.testing.expect(isUrlValuedMetaKey("OG:IMAGE"));
}

test "doctor: hasRelToken tokenises rel= case-insensitively" {
    try std.testing.expect(hasRelToken("canonical", "canonical"));
    try std.testing.expect(hasRelToken("canonical alternate", "canonical"));
    try std.testing.expect(hasRelToken("CANONICAL", "canonical"));
    try std.testing.expect(!hasRelToken("canonicalize", "canonical"));
}

test "doctor: percentDecode plain passthrough, %-escapes, and failure modes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/a/b", percentDecode(&buf, "/a/b").?);
    try std.testing.expectEqualStrings("/a b", percentDecode(&buf, "/a%20b").?);
    try std.testing.expect(percentDecode(&buf, "/a%zzb") == null);
    var tiny: [2]u8 = undefined;
    try std.testing.expect(percentDecode(&tiny, "/abc") == null);
}

test "doctor: stripUrlPrefix matches whole path segments only" {
    // The prefix must match a SEGMENT, not a string prefix: with
    // `--url-prefix=docs`, "/docs-legacy/x" is not inside the prefixed site,
    // and treating it as "/x" would resolve it against the wrong tree and
    // silently swallow a genuine 404.
    try std.testing.expectEqualStrings("x", stripUrlPrefix("/docs/x", "docs").?);
    try std.testing.expectEqualStrings("", stripUrlPrefix("/docs", "docs").?);
    try std.testing.expectEqualStrings("", stripUrlPrefix("/docs/", "docs").?);
    try std.testing.expect(stripUrlPrefix("/docs-legacy/x", "docs") == null);
    try std.testing.expect(stripUrlPrefix("/other/x", "docs") == null);
}

test "doctor: normalizeLexical resolves '.'/'..' and detects an escape" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("b", normalizeLexical(&buf, "a/../b").?);
    try std.testing.expectEqualStrings("a/b", normalizeLexical(&buf, "a/./b").?);
    try std.testing.expect(normalizeLexical(&buf, "../x") == null);
}
