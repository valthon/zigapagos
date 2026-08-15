const std = @import("std");
const Io = std.Io;
const fatal = @import("../fatal.zig");
const migrate = @import("migrate.zig");
const detect = @import("migrate_detect.zig");
const Allocator = std.mem.Allocator;

const usage_text =
    \\Usage: zigapagos init --from-astro <astro-dir> [OPTIONS]
    \\
    \\Scaffold a Zigapagos site from an existing Astro project directory.
    \\The Astro project is read but not modified. The scaffolded site is
    \\written to --out (default: ./<astro-basename>-tsx).
    \\
    \\Options:
    \\  --from-astro DIR       Path to the Astro project (required)
    \\  -o, --out DIR          Output directory (default: ./<astro-basename>-tsx)
    \\  --runtime-path PATH    Override the @z/runtime package path
    \\  --site-title STR       Site title to embed in zigapagos.ziggy (default: "<basename>")
    \\  --host-url URL         Canonical host URL for zigapagos.ziggy
    \\  --no-islands           Skip island scaffolding (static site only)
    \\  --force                Overwrite existing files in the output directory
    \\  -h, --help             Show this help
    \\
    \\
;

pub const Options = struct {
    astro_dir: []const u8,
    out: ?[]const u8 = null,
    runtime_path: ?[]const u8 = null,
    site_title: ?[]const u8 = null,
    host_url: ?[]const u8 = null,
    no_islands: bool = false,
    force: bool = false,
};

pub fn parseArgs(args: []const []const u8) Options {
    var astro_dir: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var runtime_path: ?[]const u8 = null;
    var site_title: ?[]const u8 = null;
    var host_url: ?[]const u8 = null;
    var no_islands: bool = false;
    var force: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            fatal.usage(usage_text, .{});
        } else if (std.mem.eql(u8, a, "--from-astro")) {
            i += 1;
            if (i >= args.len) fatal.msg("error: --from-astro needs a directory path\n\n" ++ usage_text, .{});
            astro_dir = args[i];
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) fatal.msg("error: --out needs a directory path\n\n" ++ usage_text, .{});
            out = args[i];
        } else if (std.mem.eql(u8, a, "--runtime-path")) {
            i += 1;
            if (i >= args.len) fatal.msg("error: --runtime-path needs a path\n\n" ++ usage_text, .{});
            runtime_path = args[i];
        } else if (std.mem.eql(u8, a, "--site-title")) {
            i += 1;
            if (i >= args.len) fatal.msg("error: --site-title needs a string\n\n" ++ usage_text, .{});
            site_title = args[i];
        } else if (std.mem.eql(u8, a, "--host-url")) {
            i += 1;
            if (i >= args.len) fatal.msg("error: --host-url needs a URL\n\n" ++ usage_text, .{});
            host_url = args[i];
        } else if (std.mem.eql(u8, a, "--no-islands")) {
            no_islands = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (a.len > 0 and a[0] == '-') {
            fatal.msg("error: unknown flag: {s}\n\n" ++ usage_text, .{a});
        }
    }

    if (astro_dir == null) {
        fatal.msg("error: missing --from-astro <astro-dir>\n\n" ++ usage_text, .{});
    }

    return .{
        .astro_dir = astro_dir.?,
        .out = out,
        .runtime_path = runtime_path,
        .site_title = site_title,
        .host_url = host_url,
        .no_islands = no_islands,
        .force = force,
    };
}

fn defaultOut(gpa: Allocator, astro_dir: []const u8) []const u8 {
    const base = std.fs.path.basename(astro_dir);
    return std.fmt.allocPrint(gpa, "./{s}-tsx", .{base}) catch fatal.oom();
}

// ---------------------------------------------------------------------------
// Non-clobber file writer
// ---------------------------------------------------------------------------

pub const WriteOutcome = enum { written, skipped_wrote_new };

/// Write `bytes` to `<out_dir>/<rel>`.
///
/// - Creates any missing parent directories under `out_dir`.
/// - If `rel` already exists and `force` is false, writes `<rel>.new` instead
///   and returns `.skipped_wrote_new`.
/// - If `force` is true (or the file is new), writes `rel` and returns
///   `.written`.
/// - Real I/O errors (not PathAlreadyExists) call fatal.file / fatal.dir and
///   do not return.
pub fn writeFile(
    io: Io,
    out_dir: Io.Dir,
    rel: []const u8,
    bytes: []const u8,
    force: bool,
) WriteOutcome {
    const dirname = std.fs.path.dirnamePosix(rel);
    const basename_str = std.fs.path.basenamePosix(rel);

    // Create (and open) any intermediate directories relative to out_dir.
    const base_dir = if (dirname) |dn|
        out_dir.createDirPathOpen(io, dn, .{}) catch |err| fatal.dir(dn, err)
    else
        out_dir;

    // Force-overwrite path: create-or-truncate.
    if (force) {
        const f = base_dir.createFile(io, basename_str, .{ .exclusive = false }) catch |err|
            fatal.file(rel, err);
        var w = f.writer(io, &.{});
        w.interface.writeAll(bytes) catch |err| fatal.file(rel, err);
        return .written;
    }

    // Normal (non-clobber) path: exclusive create; on collision write .new.
    const f = base_dir.createFile(io, basename_str, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            var new_name_buf: [4096]u8 = undefined;
            const new_name = std.fmt.bufPrint(&new_name_buf, "{s}.new", .{basename_str}) catch
                fatal.msg("path too long for .new suffix: {s}\n", .{rel});
            const nf = base_dir.createFile(io, new_name, .{ .exclusive = false }) catch |e|
                fatal.file(new_name, e);
            var nw = nf.writer(io, &.{});
            nw.interface.writeAll(bytes) catch |e| fatal.file(new_name, e);
            return .skipped_wrote_new;
        },
        else => fatal.file(rel, err),
    };
    var w = f.writer(io, &.{});
    w.interface.writeAll(bytes) catch |err| fatal.file(rel, err);
    return .written;
}

// ---------------------------------------------------------------------------
// Plumbing-file emitters
// ---------------------------------------------------------------------------

/// Emit a `package.json` with exactly one dependency: `@z/runtime` at the
/// given `runtime_path` (e.g. `"../zigapagos/runtime"`).
///
/// Pass `"TODO-SET-RUNTIME-PATH"` when the path is not yet known; the caller
/// is responsible for resolving `Options.runtime_path ?? placeholder`.
pub fn emitPackageJson(gpa: Allocator, name: []const u8, runtime_path: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "name": "{s}",
        \\  "private": true,
        \\  "type": "module",
        \\  "dependencies": {{ "@z/runtime": "file:{s}" }}
        \\}}
        \\
    , .{ name, runtime_path }) catch fatal.oom();
}

/// Emit the verbatim one-Preact tsconfig.json contract:
///   jsx=react-jsx, jsxImportSource=@z/runtime, moduleResolution=bundler.
/// This is a comptime constant — no allocation.
pub fn emitTsconfig() []const u8 {
    return
    \\{
    \\  "compilerOptions": {
    \\    "jsx": "react-jsx",
    \\    "jsxImportSource": "@z/runtime",
    \\    "moduleResolution": "bundler",
    \\    "strict": true,
    \\    "skipLibCheck": true
    \\  }
    \\}
    \\
    ;
}

/// Emit a `mise.toml` that pins Bun 1.2.
///
/// No `zig` entry: a scaffolded project builds with the standalone `zigapagos`
/// binary, and pinning a Zig toolchain it never invokes would say the opposite.
/// This is a comptime constant — no allocation.
pub fn emitMiseToml() []const u8 {
    return
    \\[tools]
    \\bun = "1.2"
    \\
    ;
}

/// Emit a `.gitignore` with the three standard Zigapagos ignores.
/// This is a comptime constant — no allocation.
pub fn emitGitignore() []const u8 {
    return
    \\node_modules/
    \\zig-out/
    \\.zigapagos-cache/
    \\
    ;
}

/// Derive a project name from the output directory path.
///
/// The returned identifier is zon-safe (lowercased alnum + `_` only):
///   - Valid as a Zig enum-literal: `.name = .<result>`
///   - Valid as an npm package name (zig idents are a strict subset of npm names)
///
/// Example: `"My-Site"` → `"my_site"`, `"astro-blog-tsx"` → `"astro_blog_tsx"`.
pub fn projectName(gpa: Allocator, out_dir_path: []const u8) []const u8 {
    const base = std.fs.path.basename(out_dir_path);
    if (base.len == 0) return gpa.dupe(u8, "site") catch fatal.oom();
    const result = gpa.alloc(u8, base.len) catch fatal.oom();
    for (base, 0..) |c, i| {
        result[i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '_';
    }
    if (result.len > 0 and std.ascii.isDigit(result[0])) result[0] = '_';
    return result;
}

// ---------------------------------------------------------------------------
// Island validation + build.zig emitter
// ---------------------------------------------------------------------------

/// Error set for `checkIslands`. Both cases produce output that is broken in a
/// way the build itself cannot report, so they are rejected before anything is
/// written.
pub const IslandCheckError = error{ BadSrcChar, BasenameCollision };

/// Validate the detected island set BEFORE writing build.sh.
///
/// Two cases are rejected:
///
///   • A `detect.moduleName` result that contains `"` or `\` would break the
///     generated shell word → `error.BadSrcChar`.
///   • Two islands whose basenames (`detect.moduleName`) collide → their
///     bundled .js files would silently overwrite each other at
///     `/islands/<name>.js` → `error.BasenameCollision`.
///
/// OOM calls `fatal.oom()` (noreturn) — the function never returns
/// `OutOfMemory`.
pub fn checkIslands(gpa: Allocator, islands: []const migrate.Entry) IslandCheckError!void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    for (islands) |e| {
        const name = detect.moduleName(e.path);
        // Reject names containing chars that would break a Zig string literal.
        if (std.mem.indexOfAny(u8, name, "\"\\") != null) return error.BadSrcChar;
        // Reject duplicate basenames (colliding /islands/<name>.js bundles).
        const gop = seen.getOrPut(gpa, name) catch fatal.oom();
        if (gop.found_existing) return error.BasenameCollision;
    }
}

/// Emit the project's `build.sh`: the one `zigapagos release` invocation that
/// builds this site, with one `--island=` per detected island.
///
/// A SCRIPT, NOT A `build.zig`. `zigapagos` is a standalone executable and
/// `zig build` builds zigapagos, not a website — a scaffolded project must not
/// need a Zig toolchain, a package graph or a `.path` dependency to render its
/// own content. The invocation is a file rather than a line in MIGRATION.md so
/// that the project has ONE place its entries are declared, which the test
/// scripts below call instead of restating the flags.
///
/// The generated island `src` path is `components/<Name>.island.tsx` where
/// `<Name>` is `detect.moduleName(e.path)` — byte-identical to the path the
/// layout emitter writes into the .shtml `<island src>` attribute, so the SSR
/// props pipeline can match them.
///
/// Islands are enumerated rather than left to `zigapagos release`'s discovery
/// scan even though the scan would find the same set: the importer already
/// knows them exactly, and a listed entry is one an author can delete.
///
/// OOM calls `fatal.oom()` (noreturn) — the function never returns an error.
pub fn emitBuildSh(gpa: Allocator, islands: []const migrate.Entry) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    buf.appendSlice(gpa,
        \\#!/usr/bin/env bash
        \\# Build this site.
        \\#
        \\# `zigapagos` is a standalone executable: this needs the binary and bun,
        \\# and no Zig toolchain. `npx zigapagos` provides both halves; set
        \\# ZIGAPAGOS_BIN to use a binary you installed some other way.
        \\set -euo pipefail
        \\cd "$(dirname "$0")"
        \\
        \\ZIGAPAGOS="${ZIGAPAGOS_BIN:-zigapagos}"
        \\
        \\bun install --frozen-lockfile 2>/dev/null || bun install
        \\
        \\exec "$ZIGAPAGOS" release \
        \\  --force \
        \\  --output=zig-out/site \
        \\  --island-props-check=error \
    ) catch fatal.oom();

    if (islands.len == 0) {
        buf.appendSlice(gpa, "\n  # No islands were detected. Add one --island=<path> line per island\n" ++
            "  # component you write, so its browser bundle is built and installed.\n") catch fatal.oom();
    } else {
        buf.appendSlice(gpa, "\n") catch fatal.oom();
        for (islands) |e| {
            const name = detect.moduleName(e.path);
            const line = std.fmt.allocPrint(
                gpa,
                "  --island=components/{s}.island.tsx \\\n",
                .{name},
            ) catch fatal.oom();
            defer gpa.free(line);
            buf.appendSlice(gpa, line) catch fatal.oom();
        }
    }

    // Trailing "$@" so an author can pass one-off flags (--drafts, a different
    // --output) without editing the file.
    buf.appendSlice(gpa, "  \"$@\"\n") catch fatal.oom();

    return buf.toOwnedSlice(gpa) catch fatal.oom();
}

// ---------------------------------------------------------------------------
// astro.config site: parser
// ---------------------------------------------------------------------------

/// Best-effort extraction of the `site:` URL from astro.config.* text.
///
/// Scans for the token `site` that appears as an object key:
///   - preceded (immediately, ignoring nothing) by `{`, `,`, or ASCII whitespace
///   - followed (skipping optional ASCII whitespace) by `:`
///   - followed (skipping optional ASCII whitespace including newlines) by a
///     `"`- or `'`-delimited string
///
/// Returns a slice into `config_src` pointing at the inner URL (caller dupes
/// if storage is needed beyond the lifetime of config_src). Returns null when
/// no matching `site:` string is found — the caller should fall back and emit
/// a TODO.
///
/// Best-effort: does not crash on malformed input; a missed parse is silent.
pub fn parseAstroSite(config_src: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 4 <= config_src.len) {
        // Locate the next occurrence of "site".
        const rel = std.mem.indexOf(u8, config_src[i..], "site") orelse break;
        const site_pos = i + rel;

        // Advance past this occurrence so the next iteration doesn't re-examine it.
        i = site_pos + 4;

        // The character immediately before "site" must be a key-separator:
        // '{', ',', or ASCII whitespace (space, tab, newline, CR, …).
        if (site_pos > 0) {
            const before = config_src[site_pos - 1];
            if (before != '{' and before != ',' and !std.ascii.isWhitespace(before)) continue;
        }

        // After "site", skip optional whitespace and expect ':'.
        var j: usize = site_pos + 4;
        while (j < config_src.len and std.ascii.isWhitespace(config_src[j])) j += 1;
        if (j >= config_src.len or config_src[j] != ':') continue;
        j += 1; // consume ':'

        // Skip optional whitespace (including newlines) before the quote.
        while (j < config_src.len and std.ascii.isWhitespace(config_src[j])) j += 1;

        // Expect a quote character (either " or ').
        if (j >= config_src.len) break;
        const quote = config_src[j];
        if (quote != '"' and quote != '\'') continue;
        j += 1; // consume opening quote

        // Scan for closing quote.
        const url_start = j;
        while (j < config_src.len and config_src[j] != quote) j += 1;
        if (j >= config_src.len) break;

        return config_src[url_start..j];
    }
    return null;
}

// ---------------------------------------------------------------------------
// zigapagos.ziggy emitter
// ---------------------------------------------------------------------------

/// Escape `"` and `\` in a Ziggy string value so the emitted file stays valid.
/// Returns a freshly-allocated copy; the caller is responsible for freeing it
/// (or using an arena).
fn escapeZiggyStr(gpa: Allocator, s: []const u8) []const u8 {
    // Count characters that need escaping.
    var extras: usize = 0;
    for (s) |c| {
        if (c == '"' or c == '\\') extras += 1;
    }
    if (extras == 0) return gpa.dupe(u8, s) catch fatal.oom();

    const buf = gpa.alloc(u8, s.len + extras) catch fatal.oom();
    var out: usize = 0;
    for (s) |c| {
        if (c == '"' or c == '\\') {
            buf[out] = '\\';
            out += 1;
        }
        buf[out] = c;
        out += 1;
    }
    return buf;
}

/// Emit a `zigapagos.ziggy` Site block with the given title and host_url and the
/// fixed content/layouts/assets dir paths that Zigapagos expects.
///
/// `title` and `host_url` are already-resolved by the caller (Task 8/9
/// applies the override > parse > TODO-fallback precedence).  Any `"` or `\`
/// inside either value is escaped to keep the emitted Ziggy file valid.
///
/// Returns an owned slice allocated with `gpa`; caller must free (or use an
/// arena).  OOM calls `fatal.oom()` (noreturn).
pub fn emitZigapagosZiggy(gpa: Allocator, title: []const u8, host_url: []const u8) []const u8 {
    const safe_title = escapeZiggyStr(gpa, title);
    defer gpa.free(safe_title);
    const safe_host = escapeZiggyStr(gpa, host_url);
    defer gpa.free(safe_host);

    return std.fmt.allocPrint(gpa,
        \\Site {{
        \\    .title = "{s}",
        \\    .host_url = "{s}",
        \\    .content_dir_path = "content",
        \\    .layouts_dir_path = "layouts",
        \\    .assets_dir_path = "assets",
        \\}}
        \\
    , .{ safe_title, safe_host }) catch fatal.oom();
}

// ---------------------------------------------------------------------------
// Static-layer emitters (content/*.smd + layouts/*.shtml)
// ---------------------------------------------------------------------------

/// Emit a `content/<name>.smd` stub.
///
/// Frontmatter fields follow the golden `examples/tsx-site/content/index.smd`:
///   `.title`, `.date = @date("1970-01-01T00:00:00")` (placeholder), `.layout`,
///   `.draft = false`.
/// The body is plain SuperMD text — SuperMD forbids raw HTML (`html_is_forbidden`),
/// so we must NOT embed the original Astro markup in an HTML comment.
///
/// `orig_astro_markup` is accepted for API compatibility but is ignored; it is the
/// caller's responsibility to save a copy of the Astro source for manual reference.
///
/// OOM calls `fatal.oom()` (noreturn).
pub fn emitContentStub(gpa: Allocator, name: []const u8, orig_astro_markup: []const u8) []const u8 {
    _ = orig_astro_markup; // SuperMD forbids raw HTML; see docs/migration/recipes.md

    const safe_name = escapeZiggyStr(gpa, name);
    defer gpa.free(safe_name);

    return std.fmt.allocPrint(gpa,
        \\---
        \\.title = "{s}",
        \\.date = @date("1970-01-01T00:00:00"),
        \\.layout = "index.shtml",
        \\.draft = false,
        \\---
        \\
        \\TODO: port page content from the original Astro source.
        \\
    , .{safe_name}) catch fatal.oom();
}

/// A section-index stub for a detected Astro paginate() route — the same
/// stub emitContentStub writes, plus the .pagination line. Both Astro
/// filename forms map to .url_style = "plain_dir" (the rest form is exact
/// URL parity; the numbered form differs only at page 1, which Zigapagos
/// always puts at the section URL — MIGRATION.md carries the aliases note
/// via detect.paginateNote).
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing).
pub fn emitSectionIndexStub(
    gpa: Allocator,
    name: []const u8,
    spec: detect.PaginateSpec,
) []const u8 {
    const safe_name = escapeZiggyStr(gpa, name);
    defer gpa.free(safe_name);
    return std.fmt.allocPrint(gpa,
        \\---
        \\.title = "{s}",
        \\.date = @date("1970-01-01T00:00:00"),
        \\.layout = "index.shtml",
        \\.draft = false,
        \\.pagination = {{ .page_size = {d}, .url_style = "plain_dir" }},
        \\---
        \\
        \\TODO: port the paginated listing from the original Astro route
        \\(the layout's `$page.subpages()` loop is windowed automatically).
        \\
    , .{ safe_name, spec.page_size }) catch fatal.oom();
}

/// Emit a `layouts/<name>.shtml` stub.
///
/// Generates a minimal valid SuperHTML document matching the golden
/// `examples/tsx-site/layouts/index.shtml` shape:
///   - `<!DOCTYPE html>` / `<html>` / `<head>` / `<title :text="$page.title">`
///   - `<h1 :text="$page.title">`
///   - One `<island src="components/<Name>.island.tsx" client:load></island>`
///     per island in `islands` (Name = detect.moduleName(e.path))
///   - `<div :html="$page.content()"></div>`
///
/// The island `src` attribute is byte-identical to what `emitBuildSh` emits
/// (`components/<Name>.island.tsx`), so the SSR props pipeline can match them.
///
/// OOM calls `fatal.oom()` (noreturn).
pub fn emitLayoutStub(gpa: Allocator, name: []const u8, islands: []const migrate.Entry) []const u8 {
    _ = name; // reserved for future multi-layout support
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    buf.appendSlice(gpa,
        \\<!DOCTYPE html>
        \\<html>
        \\  <head>
        \\    <title :text="$page.title"></title>
        \\  </head>
        \\  <body>
        \\    <h1 :text="$page.title"></h1>
    ) catch fatal.oom();

    // One <island> per detected island; blank line before each, newline after.
    for (islands) |e| {
        const island_name = detect.moduleName(e.path);
        const line = std.fmt.allocPrint(
            gpa,
            "\n    <island src=\"components/{s}.island.tsx\" client:load></island>\n",
            .{island_name},
        ) catch fatal.oom();
        defer gpa.free(line);
        buf.appendSlice(gpa, line) catch fatal.oom();
    }

    // Blank line before content div, then close body/html.
    buf.appendSlice(gpa, "\n    <div :html=\"$page.content()\"></div>\n" ++
        "  </body>\n" ++
        "</html>\n") catch fatal.oom();

    return buf.toOwnedSlice(gpa) catch fatal.oom();
}

// ---------------------------------------------------------------------------
// Test-harness emitters (de-repo'd)
// ---------------------------------------------------------------------------

/// Emit a `test/ssr.sh` for an external consumer project.
///
/// De-repo'd from `examples/tsx-site/test/ssr.sh`:
///   - DROPPED: `cd ../../runtime && mise exec -- bun install` (repo-internal sidecar path)
///   - DROPPED: `cd - >/dev/null`
///   - DROPPED: `git -C ../.. ls-files --deleted … restore --` (no committed snapshots in external project)
///   - CHANGED: island bundle asserts are generic (loop over `*.island.js`)
///     instead of fixture-specific Hero/Flagged/Panel names.
///   - CHANGED: HTML content grep (`<section><h1>`) replaced by the more
///     universal `data-z-island` marker which is always injected by the pipeline.
///
/// Blank lines in the output script are represented as `\\` with no trailing
/// content in the Zig multiline string (not source-level blank lines, which
/// would terminate the literal).
pub fn emitSsrSh() []const u8 {
    return
    \\#!/usr/bin/env bash
    \\set -euo pipefail
    \\cd "$(dirname "$0")/.."
    \\
    \\# (1) Install project deps — creates node_modules/@z/runtime symlink so
    \\# the island's `import { ... } from "@z/runtime"` resolves when Bun runs the sidecar.
    \\mise exec -- bun install
    \\
    \\# (2) Build the site: zigapagos spawns the Bun sidecar with cwd = project root,
    \\# the island SSRs, and the HTML is written to zig-out/site/index.html.
    \\bash build.sh
    \\
    \\# (3) Assert the island was SSR'd into the output HTML.
    \\OUT="zig-out/site/index.html"
    \\grep -q 'data-z-island' "$OUT" || { echo "FAIL: island placeholder missing"; exit 1; }
    \\grep -q 'data-z-props' "$OUT" || { echo "FAIL: props script missing"; exit 1; }
    \\grep -q 'data-z-module=' "$OUT" || { echo "FAIL: data-z-module missing"; exit 1; }
    \\grep -q '<script type="importmap">' "$OUT" || { echo "FAIL: import map missing"; exit 1; }
    \\
    \\# (4) Assert the shared runtime bundle is present.
    \\test -f zig-out/site/zigapagos-runtime.js || { echo "FAIL: shared runtime bundle missing"; exit 1; }
    \\
    \\# (5) Generic island bundle checks: assert at least one island bundle exists,
    \\# keeps @z/runtime external, and has not inlined Preact internals.
    \\# Island names vary per project so we loop over all *.island.js bundles.
    \\shopt -s nullglob
    \\ISLAND_BUNDLES=( zig-out/site/islands/*.island.js )
    \\[ "${#ISLAND_BUNDLES[@]}" -gt 0 ] || { echo "FAIL: no island bundles found in zig-out/site/islands/"; exit 1; }
    \\for js in "${ISLAND_BUNDLES[@]}"; do
    \\  grep -q '"@z/runtime' "$js" || { echo "FAIL: $js did not keep @z/runtime external"; exit 1; }
    \\  if grep -qE 'preact|__H|hookState' "$js"; then
    \\    echo "FAIL: $js inlined Preact (one-instance invariant broken)"; exit 1
    \\  fi
    \\done
    \\
    \\echo "PASS: TSX island SSR'd via Bun sidecar"
    \\
    ;
}

/// Emit a `test/hydrate.sh` for an external consumer project.
///
/// De-repo'd from `examples/tsx-site/test/hydrate.sh`:
///   - DROPPED: `git -C ../.. ls-files --deleted … restore --` (no committed snapshots).
///
/// The script delegates SSR + asset assertions to `test/ssr.sh` then runs
/// the Playwright driver against the built `zig-out/site`.
pub fn emitHydrateSh() []const u8 {
    return
    \\#!/usr/bin/env bash
    \\set -euo pipefail
    \\cd "$(dirname "$0")/.."
    \\bash test/ssr.sh                 # build the site (asserts SSR + assets)
    \\mise exec -- python3 test/hydrate_playwright.py zig-out/site
    \\
    ;
}

/// Emit a `test/hydrate_playwright.py` for an external consumer project.
///
/// De-repo'd from `examples/tsx-site/test/hydrate_playwright.py`:
///   - DROPPED: Panel composite island section (tsx-site fixture-specific selectors
///     and content strings that don't exist in a generated project).
///   - DROPPED: flags API stub route (Flagged island fixture-specific).
///   - DROPPED: Hero button click / toggle assertions (fixture-specific).
///   - KEPT: server setup, browser launch, favicon suppression, networkidle
///     wait, `[data-z-island][data-z-hydrated]` wait, console-error assert.
///
/// The resulting script is a generic hydration smoke-test that works for any
/// Zigapagos island project. Consumers can add component-specific assertions.
pub fn emitHydratePy() []const u8 {
    return
    \\import sys, http.server, socketserver, threading, functools, os
    \\from playwright.sync_api import sync_playwright
    \\
    \\def serve(directory):
    \\    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
    \\    handler.extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".js": "text/javascript", ".mjs": "text/javascript"}
    \\    httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
    \\    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    \\    return httpd, f"http://127.0.0.1:{httpd.server_address[1]}/"
    \\
    \\def main():
    \\    target = sys.argv[1]
    \\    httpd, base = (serve(target) if os.path.isdir(target) else (None, target))
    \\    with sync_playwright() as p:
    \\        browser = p.chromium.launch(channel="chrome")
    \\        page = browser.new_page()
    \\        errors = []
    \\        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    \\        page.on("pageerror", lambda e: errors.append(str(e)))
    \\        # Suppress favicon 404 (browser logs it as a console error; it is not our asset).
    \\        page.route("**/favicon.ico", lambda route: route.fulfill(status=204))
    \\        page.goto(base, wait_until="networkidle")
    \\        # Hydration completed:
    \\        page.wait_for_selector("[data-z-island][data-z-hydrated]", timeout=5000)
    \\        assert not errors, f"console/page errors: {errors}"
    \\        print("PASS: TSX island hydrated (no console errors)")
    \\        browser.close()
    \\    if httpd: httpd.shutdown()
    \\
    \\main()
    \\
    ;
}

/// Best-effort extraction of the `"name"` field from a package.json source
/// string.  Returns a slice into `json`; caller must not free the slice
/// separately.  Returns null when the field is absent or malformed.
fn parseJsonName(json: []const u8) ?[]const u8 {
    const key = "\"name\"";
    var i: usize = 0;
    while (true) {
        const rel = std.mem.indexOf(u8, json[i..], key) orelse return null;
        i += rel + key.len;
        while (i < json.len and std.ascii.isWhitespace(json[i])) i += 1;
        if (i >= json.len or json[i] != ':') continue;
        i += 1;
        while (i < json.len and std.ascii.isWhitespace(json[i])) i += 1;
        if (i >= json.len or json[i] != '"') continue;
        i += 1;
        const start = i;
        while (i < json.len and json[i] != '"' and json[i] != '\n') i += 1;
        if (i >= json.len or json[i] != '"') return null;
        return if (i > start) json[start..i] else null;
    }
}

fn trackOutcome(written: *usize, outcome: WriteOutcome) void {
    // The CLI's dir-level guard (below) is the sole overwrite policy: it aborts
    // on a non-empty output dir unless --force, and passes force to writeFile
    // otherwise. writeFile therefore always returns `.written` here — its
    // per-file `.new` non-clobber path is a general-helper behavior exercised
    // only by its unit test, never by run().
    if (outcome == .written) written.* += 1;
}

pub fn run(io: Io, gpa: Allocator, args: []const []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const o = parseArgs(args);
    const out_path: []const u8 = o.out orelse defaultOut(a, o.astro_dir);

    // Open the Astro source directory.
    const astro_root = Io.Dir.cwd().openDir(io, o.astro_dir, .{}) catch |err| {
        std.debug.print(
            "error: cannot open Astro directory '{s}': {t}\n" ++
                "  Check that the path exists and is readable.\n",
            .{ o.astro_dir, err },
        );
        return true;
    };
    defer astro_root.close(io);

    // Two-pass scan of the Astro project.
    var res = migrate.scan(io, gpa, astro_root);
    defer migrate.freeScanResult(gpa, &res);

    // Collect the island subset.
    var islands: std.ArrayListUnmanaged(migrate.Entry) = .empty;
    defer islands.deinit(gpa);
    for (res.entries) |e| {
        if (e.is_island) islands.append(gpa, e) catch fatal.oom();
    }

    // When --no-islands, treat the island set as empty for ALL of
    // emitBuildSh/emitLayoutStub/checkIslands/scaffoldIslands so that
    // build.sh --island= flags, layout <island> tags, and scaffolded .tsx
    // files all AGREE: with --no-islands, none of them reference any islands.
    const effective_islands: []const migrate.Entry = if (o.no_islands) &.{} else islands.items;

    // Validate islands BEFORE writing anything (skipped under --no-islands
    // because nothing will be emitted that references them).
    if (!o.no_islands) {
        checkIslands(gpa, islands.items) catch |err| {
            switch (err) {
                error.BasenameCollision => std.debug.print(
                    "error: two detected islands share the same base name and would collide at islands/<Name>.js.\n" ++
                        "  Rename one of the conflicting island files and re-run.\n",
                    .{},
                ),
                error.BadSrcChar => std.debug.print(
                    "error: an island filename contains '\"' or '\\', which would break the generated build.sh.\n" ++
                        "  Rename the file to remove those characters and re-run.\n",
                    .{},
                ),
            }
            return true;
        };
    }

    // Reject a non-empty output directory unless --force.
    {
        const out_exists: bool = blk: {
            const td = Io.Dir.cwd().openDir(io, out_path, .{}) catch break :blk false;
            td.close(io);
            break :blk true;
        };
        if (out_exists and !o.force) {
            var id = Io.Dir.cwd().openDir(io, out_path, .{ .iterate = true }) catch |err|
                fatal.dir(out_path, err);
            defer id.close(io);
            var it = id.iterateAssumeFirstIteration();
            if (it.next(io) catch null) |_| {
                std.debug.print(
                    "error: output directory '{s}' already exists and is non-empty.\n" ++
                        "  Use --force to allow writing into it.\n",
                    .{out_path},
                );
                return true;
            }
        }
    }

    // Create (or reuse) the output directory.
    const out_dir = Io.Dir.cwd().createDirPathOpen(io, out_path, .{}) catch |err|
        fatal.dir(out_path, err);
    defer out_dir.close(io);

    // Read Astro config for site URL and package.json for project name. Read
    // each file whole (arena-owned) rather than into a fixed buffer, so a large
    // config is never silently truncated. A missing file yields "".
    const config_src: []const u8 = blk: {
        for ([_][]const u8{ "astro.config.mjs", "astro.config.ts", "astro.config.js", "astro.config.json" }) |cfg| {
            break :blk astro_root.readFileAlloc(io, cfg, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
                error.OutOfMemory => fatal.oom(),
                else => continue, // missing/unreadable config file: try the next candidate
            };
        }
        break :blk @as([]const u8, "");
    };

    const pkg_src: []const u8 = astro_root.readFileAlloc(io, "package.json", a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
        else => "", // no/unreadable package.json: fall back to defaults
    };

    // Resolve scaffold parameters: Options > parse > fallback.
    const host_url: []const u8 = o.host_url orelse parseAstroSite(config_src) orelse "https://example.com";
    const title: []const u8 = o.site_title orelse parseJsonName(pkg_src) orelse std.fs.path.basename(out_path);
    const runtime_path: []const u8 = o.runtime_path orelse "TODO-SET-RUNTIME-PATH";
    const name: []const u8 = projectName(a, out_path);

    var written: usize = 0;

    trackOutcome(&written, writeFile(io, out_dir, "package.json", emitPackageJson(a, name, runtime_path), o.force));
    trackOutcome(&written, writeFile(io, out_dir, "tsconfig.json", emitTsconfig(), o.force));
    trackOutcome(&written, writeFile(io, out_dir, "mise.toml", emitMiseToml(), o.force));
    trackOutcome(&written, writeFile(io, out_dir, ".gitignore", emitGitignore(), o.force));
    trackOutcome(&written, writeFile(io, out_dir, "build.sh", emitBuildSh(a, effective_islands), o.force));
    trackOutcome(&written, writeFile(io, out_dir, "zigapagos.ziggy", emitZigapagosZiggy(a, title, host_url), o.force));
    trackOutcome(&written, writeFile(io, out_dir, "assets/.gitkeep", "", o.force));
    trackOutcome(&written, writeFile(io, out_dir, "test/ssr.sh", emitSsrSh(), o.force));
    trackOutcome(&written, writeFile(io, out_dir, "test/hydrate.sh", emitHydrateSh(), o.force));
    trackOutcome(&written, writeFile(io, out_dir, "test/hydrate_playwright.py", emitHydratePy(), o.force));
    trackOutcome(&written, writeFile(io, out_dir, "content/index.smd", emitContentStub(a, title, ""), o.force));
    trackOutcome(&written, writeFile(io, out_dir, "layouts/index.shtml", emitLayoutStub(a, "index", effective_islands), o.force));

    // Convert detected paginate() routes: the first per-section files the
    // importer emits. Non-clobber semantics come from writeFile (.new on
    // collision), same as every other scaffolded file.
    for (res.entries) |e| {
        const spec = e.paginate orelse continue;
        if (spec.section.len == 0) continue; // root paginate: content/index.smd already written; MIGRATION.md carries the instruction
        const rel = std.fmt.allocPrint(a, "content/{s}/index.smd", .{spec.section}) catch fatal.oom();
        trackOutcome(&written, writeFile(io, out_dir, rel, emitSectionIndexStub(a, spec.section, spec), o.force));
    }

    // Scaffold island TSX stubs into <out>/components (unless --no-islands).
    if (!o.no_islands) {
        const components_path = std.fs.path.join(a, &.{ out_path, "components" }) catch fatal.oom();
        // Honor --force: overwrite existing island .tsx in place, matching the
        // documented --force semantics for every other scaffolded file.
        migrate.scaffoldIslands(io, gpa, astro_root, components_path, res.entries, o.force);
    }

    // Write MIGRATION.md.
    const report = migrate.buildReport(a, o.astro_dir, res.entries, res.has_config, !o.no_islands, res.has_astro_sitemap, false);
    trackOutcome(&written, writeFile(io, out_dir, "MIGRATION.md", report, o.force));

    // Print summary.
    std.debug.print(
        "\nScaffolded {d} file(s) into '{s}/'\n",
        .{ written, out_path },
    );
    std.debug.print(
        "  Build it with: bash {s}/build.sh  (needs `zigapagos` and `bun`; no Zig toolchain)\n",
        .{out_path},
    );
    if (o.runtime_path == null) std.debug.print(
        "  TODO: set --runtime-path (written as TODO-SET-RUNTIME-PATH in package.json)\n",
        .{},
    );
    std.debug.print(
        "  Static layer is TODO stubs — finish content/ + layouts/, then run test/ssr.sh;\n" ++
            "  astro-tsx-parity-gate is the backstop.\n",
        .{},
    );

    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseArgs: --from-astro required, flags captured, default out" {
    const o = parseArgs(&.{ "--from-astro", "site", "--out", "gen", "--site-title", "Hi", "--no-islands" });
    try std.testing.expectEqualStrings("site", o.astro_dir);
    try std.testing.expectEqualStrings("gen", o.out.?);
    try std.testing.expectEqualStrings("Hi", o.site_title.?);
    try std.testing.expect(o.no_islands);
    try std.testing.expect(!o.force);
}

test "emitTsconfig is the verbatim one-Preact contract" {
    const ts = emitTsconfig();
    try std.testing.expect(std.mem.indexOf(u8, ts, "\"jsx\": \"react-jsx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "\"jsxImportSource\": \"@z/runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "\"moduleResolution\": \"bundler\"") != null);
}

test "emitPackageJson declares exactly one dep @z/runtime at the given path" {
    // Contract-1 emitters (one `allocPrint`/`toOwnedSlice` out, scratch freed
    // inside): raw testing allocator, leak detection ON.
    const gpa = std.testing.allocator;
    const pj = emitPackageJson(gpa, "mysite", "../zigapagos/runtime");
    defer gpa.free(pj);
    try std.testing.expect(std.mem.indexOf(u8, pj, "\"@z/runtime\": \"file:../zigapagos/runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pj, "\"name\": \"mysite\"") != null);
    // exactly one dependency: no comma inside the dependencies object.
    const deps = pj[std.mem.indexOf(u8, pj, "\"dependencies\"").?..];
    const obj = deps[std.mem.indexOf(u8, deps, "{").?..std.mem.indexOf(u8, deps, "}").?];
    try std.testing.expect(std.mem.indexOfScalar(u8, obj, ',') == null);
}

test "writeFile non-clobber: second write produces .new" {
    const testing_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const outcome1 = writeFile(testing_io, tmp.dir, "hello.txt", "hello", false);
    try std.testing.expectEqual(WriteOutcome.written, outcome1);

    const outcome2 = writeFile(testing_io, tmp.dir, "hello.txt", "world", false);
    try std.testing.expectEqual(WriteOutcome.skipped_wrote_new, outcome2);
}

test "projectName: dashes->underscores, no leading digit, non-empty" {
    const gpa = std.testing.allocator;
    const n1 = projectName(gpa, "/home/user/my-site");
    defer gpa.free(n1);
    try std.testing.expectEqualStrings("my_site", n1);
    const n2 = projectName(gpa, "/home/user/123app");
    defer gpa.free(n2);
    try std.testing.expect(n2.len > 0 and !std.ascii.isDigit(n2[0])); // valid zig ident start
    const n3 = projectName(gpa, "/tmp/Foo.Bar");
    defer gpa.free(n3);
    try std.testing.expectEqualStrings("foo_bar", n3);
}

test "emitBuildSh lists one --island= per detected island, src == components path" {
    const gpa = std.testing.allocator;
    const islands = [_]migrate.Entry{
        .{ .path = "src/components/Counter.jsx", .kind = .component, .is_island = true },
        .{ .path = "src/components/ContactForm.tsx", .kind = .component, .is_island = true },
    };
    const sh = emitBuildSh(gpa, &islands);
    defer gpa.free(sh);
    try std.testing.expect(std.mem.indexOf(u8, sh, "--island=components/Counter.island.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, sh, "--island=components/ContactForm.island.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, sh, "release") != null);
    // Nothing about a Zig build graph may reach a scaffolded project.
    try std.testing.expect(std.mem.indexOf(u8, sh, "zig build") == null);
}

test "checkIslands rejects basename collision" {
    const islands = [_]migrate.Entry{
        .{ .path = "src/components/a/Foo.astro", .kind = .component, .is_island = true },
        .{ .path = "src/components/b/Foo.astro", .kind = .component, .is_island = true },
    };
    try std.testing.expectError(error.BasenameCollision, checkIslands(std.testing.allocator, &islands));
}

test "checkIslands rejects bad src char (quote or backslash in basename)" {
    // detect.moduleName strips only the last-slash prefix and the last-dot
    // extension — it does NOT sanitize '"' or '\' in filenames.  Both are
    // reachable (a file named Foo"Bar.tsx → name Foo"Bar → BadSrcChar).
    {
        // Basename contains '"' → moduleName returns `Foo"Bar`.
        const islands = [_]migrate.Entry{
            .{ .path = "src/components/Foo\"Bar.tsx", .kind = .component, .is_island = true },
        };
        try std.testing.expectError(error.BadSrcChar, checkIslands(std.testing.allocator, &islands));
    }
    {
        // Basename contains '\' → moduleName returns `Foo\Bar`.
        const islands = [_]migrate.Entry{
            .{ .path = "src/components/Foo\\Bar.tsx", .kind = .component, .is_island = true },
        };
        try std.testing.expectError(error.BadSrcChar, checkIslands(std.testing.allocator, &islands));
    }
}

test "parseAstroSite pulls the site URL from astro.config text" {
    try std.testing.expectEqualStrings("https://example.com", parseAstroSite("export default defineConfig({ site: \"https://example.com\" });").?);
    try std.testing.expectEqualStrings("https://x.io", parseAstroSite("defineConfig({\n  site: 'https://x.io',\n})").?);
    try std.testing.expect(parseAstroSite("defineConfig({ integrations: [] })") == null);
}

test "parseAstroSite on fixture content (tests/migrate/astro-sample/astro.config.mjs)" {
    // Inline copy of the fixture file content — parseAstroSite takes a slice,
    // no file I/O needed.  Content verified against the on-disk fixture.
    const fixture =
        \\import { defineConfig } from "astro/config";
        \\
        \\export default defineConfig({
        \\  site: "https://example.com",
        \\});
        \\
    ;
    try std.testing.expectEqualStrings("https://example.com", parseAstroSite(fixture).?);
}

test "emitZigapagosZiggy uses overrides and the fixed dir paths" {
    const gpa = std.testing.allocator;
    const z = emitZigapagosZiggy(gpa, "My Site", "https://my.site");
    defer gpa.free(z);
    try std.testing.expect(std.mem.indexOf(u8, z, ".title = \"My Site\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, z, ".host_url = \"https://my.site\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, z, ".content_dir_path = \"content\"") != null);
}

test "emitZigapagosZiggy escapes double-quotes in title and host_url" {
    const gpa = std.testing.allocator;
    const z = emitZigapagosZiggy(gpa, "Site \"X\"", "https://ex.com");
    defer gpa.free(z);
    // The emitted string should have escaped quotes: .title = "Site \"X\""
    try std.testing.expect(std.mem.indexOf(u8, z, ".title = \"Site \\\"X\\\"\"") != null);
}

test "emitLayoutStub pre-wires every detected island with a matching src" {
    const gpa = std.testing.allocator;
    const islands = [_]migrate.Entry{.{ .path = "src/components/Counter.jsx", .kind = .component, .is_island = true }};
    const ly = emitLayoutStub(gpa, "index", &islands);
    defer gpa.free(ly);
    try std.testing.expect(std.mem.indexOf(u8, ly, "<island src=\"components/Counter.island.tsx\" client:load") != null);
    try std.testing.expect(std.mem.indexOf(u8, ly, ":text=\"$page.title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ly, ":html=\"$page.content()\"") != null);
}

test "emitContentStub produces valid frontmatter and a plain SuperMD body" {
    const gpa = std.testing.allocator;
    const c = emitContentStub(gpa, "about", "<h1>About</h1>");
    defer gpa.free(c);
    // Frontmatter fields must be present.
    try std.testing.expect(std.mem.indexOf(u8, c, ".layout =") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, ".title =") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "TODO") != null);
    // SuperMD forbids raw HTML: no HTML comment or inline HTML must appear.
    try std.testing.expect(std.mem.indexOf(u8, c, "<!--") == null);
    try std.testing.expect(std.mem.indexOf(u8, c, "<h1>") == null);
}

test "emitContentStub body does not contain raw HTML regardless of orig_astro_markup" {
    const gpa = std.testing.allocator;
    // Even when called with HTML markup, the stub must not embed it (html_is_forbidden).
    const c = emitContentStub(gpa, "x", "<p>a--></p>");
    defer gpa.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "<p>") == null);
    try std.testing.expect(std.mem.indexOf(u8, c, "<!--") == null);
    // The --&gt; escape logic is gone; plain text only.
    try std.testing.expect(std.mem.indexOf(u8, c, "--&gt;") == null);
}

test "emitContentStub escapes double-quotes in title to produce well-formed Ziggy frontmatter" {
    const gpa = std.testing.allocator;
    // A title with embedded quotes (e.g. --site-title 'My "X" Site') must be
    // escaped in the .smd frontmatter so the Ziggy parser doesn't see a broken
    // string literal (.title = "My "X" Site" is invalid Ziggy).
    const c = emitContentStub(gpa, "My \"X\" Site", "");
    defer gpa.free(c);
    // The escaped form \" must appear inside the title string.
    try std.testing.expect(std.mem.indexOf(u8, c, ".title = \"My \\\"X\\\" Site\"") != null);
    // Raw unescaped inner quote must NOT appear (would break the Ziggy string).
    // We check by verifying the title value is not the broken form.
    try std.testing.expect(std.mem.indexOf(u8, c, ".title = \"My \"X\" Site\"") == null);
}

test "paginate: emitSectionIndexStub carries the pagination frontmatter" {
    const spec: detect.PaginateSpec = .{
        .section = "blog",
        .route_form = .rest,
        .page_size = 4,
        .page_size_is_literal = true,
    };
    const out = emitSectionIndexStub(std.testing.allocator, "blog", spec);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ".pagination = { .page_size = 4, .url_style = \"plain_dir\" },") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".layout = \"index.shtml\",") != null);
    try std.testing.expect(std.mem.startsWith(u8, out, "---\n"));
}

test "emitSsrSh is de-repo'd (no ../../runtime, no git restore) and asserts on zig-out/site" {
    const sh = emitSsrSh();
    try std.testing.expect(std.mem.indexOf(u8, sh, "../../runtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, sh, "git -C ../.. ") == null);
    try std.testing.expect(std.mem.indexOf(u8, sh, "zig-out/site") != null);
    try std.testing.expect(std.mem.indexOf(u8, sh, "data-z-island") != null);
}

test "emitSsrSh contains bun install, the build script, and an @z/runtime external check" {
    const sh = emitSsrSh();
    try std.testing.expect(std.mem.indexOf(u8, sh, "bun install") != null);
    try std.testing.expect(std.mem.indexOf(u8, sh, "bash build.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, sh, "@z/runtime") != null);
    // A scaffolded project must never need a Zig toolchain to render itself.
    try std.testing.expect(std.mem.indexOf(u8, sh, "zig build") == null);
}

test "emitHydrateSh is de-repo'd and calls ssr.sh and playwright" {
    const sh = emitHydrateSh();
    try std.testing.expect(std.mem.indexOf(u8, sh, "git -C ../.. ") == null);
    try std.testing.expect(std.mem.indexOf(u8, sh, "test/ssr.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, sh, "hydrate_playwright.py") != null);
}

test "emitBuildSh with empty islands produces island-free build.sh (--no-islands contract)" {
    const gpa = std.testing.allocator;
    const sh = emitBuildSh(gpa, &[_]migrate.Entry{});
    defer gpa.free(sh);
    // No .island.tsx path reference must appear in the generated script.
    try std.testing.expect(std.mem.indexOf(u8, sh, ".island.tsx") == null);
    // ...but it must say how to add one, or an author has no way to find out.
    try std.testing.expect(std.mem.indexOf(u8, sh, "No islands were detected") != null);
    // The file must still be a runnable build (the release invocation survives).
    try std.testing.expect(std.mem.indexOf(u8, sh, "release") != null);
}

test "emitLayoutStub with empty islands produces no <island> tags (--no-islands contract)" {
    const gpa = std.testing.allocator;
    const ly = emitLayoutStub(gpa, "index", &[_]migrate.Entry{});
    defer gpa.free(ly);
    // No <island> element must appear in the generated layout.
    try std.testing.expect(std.mem.indexOf(u8, ly, "<island") == null);
    // The layout must still be a valid SuperHTML stub.
    try std.testing.expect(std.mem.indexOf(u8, ly, ":text=\"$page.title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ly, ":html=\"$page.content()\"") != null);
}
