const std = @import("std");
const Io = std.Io;
const fatal = @import("../fatal.zig");
const detect = @import("migrate_detect.zig");
const Allocator = std.mem.Allocator;

const Role = detect.Role;

const usage =
    \\Usage: zigapagos migrate <astro-dir> [OPTIONS]
    \\
    \\Scans an Astro project and writes MIGRATION.md: a worklist mapping each
    \\Astro source file to its Zigapagos target, the islands to port, and the
    \\standard migration procedure. Follow docs/migration/astro-to-zigapagos.md.
    \\
    \\IT CONVERTS NOTHING. <astro-dir> is read, never written. No .astro page
    \\becomes an .smd, no layout becomes an .shtml, no astro.config becomes a
    \\zigapagos.ziggy. The port is yours to carry out (or your agent's);
    \\MIGRATION.md is the worklist for it and the guide above is the mapping
    \\spec it follows. The one exception is --scaffold, which writes a STARTER
    \\island per detected island into a separate directory you name -- a head
    \\start on one step of that worklist, not a finished port.
    \\
    \\Options:
    \\  -o, --output PATH      Report path (default: MIGRATION.md)
    \\  --scaffold DIR         Write a starter TSX island per island into DIR.
    \\                         Attempts a real port: rewrites React imports to
    \\                         `@z/runtime` and flags any bare npm imports for
    \\                         review (NO-NPM-GUARDRAIL). Falls back to a TSX
    \\                         skeleton when the source has no default export.
    \\                         Emits `<Name>.island.tsx`. Never clobbers: an
    \\                         existing target goes to `<Name>.island.tsx.new`,
    \\                         and an existing `.new` (your in-progress port) to
    \\                         `.new.2`, `.new.3`, …
    \\                         An island whose source cannot be read is reported
    \\                         and skipped — no stub is written for it.
    \\                         Props are re-emitted verbatim from the source's
    \\                         `interface Props` when found.
    \\  --doctor PATH          Analyse a single island file: check its imports
    \\                         against the no-npm guardrail, enumerate the React
    \\                         hooks used, and list any host-binding smells.
    \\                         Non-mutating (reads only). Exits non-zero when any
    \\                         guardrail violation is found. Mutually exclusive
    \\                         with --scaffold.
    \\  --json                 With --doctor: emit JSON instead of the human
    \\                         Markdown checklist (pipeable to jq etc.).
    \\  -h, --help             Show this help
    \\
;

pub const Kind = enum {
    page, // src/pages/*  -> content/*.smd
    layout, // src/layouts/* -> layouts/*.shtml
    component, // src/components/* -> components/*.island.tsx (island) or partial
    config, // astro.config.* -> zigapagos.ziggy + build.zig
    other,
};

pub const Entry = struct {
    path: []const u8, // relative to the astro dir
    kind: Kind,
    /// For `kind == .component`: how it maps. Decided in a second pass once the
    /// full set of `client:*`-used component names is known. Always `.plain`
    /// for non-component kinds (unused there).
    role: Role = .plain,
    /// True when this component is an island (`role == .island`).
    is_island: bool = false,
    /// A page/layout/component whose source references a `client:*` directive.
    uses_islands: bool = false,
};

pub const ScanResult = struct {
    entries: []Entry,
    island_names: std.StringHashMapUnmanaged(void),
    has_config: bool,
};

/// Run the two-pass Astro scan over `root` and return the results.
/// `entries` and `island_names` are gpa-owned; call `freeScanResult` when done.
pub fn scan(io: Io, gpa: Allocator, root: Io.Dir) ScanResult {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var island_names: std.StringHashMapUnmanaged(void) = .empty;

    // Pass 1: collect entries + the client:* usage set.
    scanDir(io, gpa, root, "src/pages", .page, &entries, &island_names);
    scanDir(io, gpa, root, "src/layouts", .layout, &entries, &island_names);
    scanDir(io, gpa, root, "src/components", .component, &entries, &island_names);
    scanDir(io, gpa, root, "src/content", .page, &entries, &island_names);

    // Pass 2: classify each component now that the usage set is complete.
    for (entries.items) |*e| {
        if (e.kind != .component) continue;
        e.role = detect.componentRole(e.path, &island_names);
        e.is_island = e.role == .island;
    }

    var has_config = false;
    for ([_][]const u8{ "astro.config.mjs", "astro.config.ts", "astro.config.js", "astro.config.json" }) |cfg| {
        if (fileExists(io, root, cfg)) {
            has_config = true;
            break;
        }
    }

    return .{
        .entries = entries.toOwnedSlice(gpa) catch fatal.oom(),
        .island_names = island_names,
        .has_config = has_config,
    };
}

/// Free all gpa-owned memory in a `ScanResult`.
pub fn freeScanResult(gpa: Allocator, res: *ScanResult) void {
    for (res.entries) |e| gpa.free(e.path);
    gpa.free(res.entries);
    var it = res.island_names.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    res.island_names.deinit(gpa);
}

pub fn migrate(io: Io, gpa: Allocator, args: []const []const u8) bool {
    var astro_dir: ?[]const u8 = null;
    var out_path: []const u8 = "MIGRATION.md";
    var scaffold_dir: ?[]const u8 = null;
    var doctor_path: ?[]const u8 = null;
    var json: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            fatal.usage(usage, .{});
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --output needs a path\n\n" ++ usage, .{});
            out_path = args[i];
        } else if (std.mem.eql(u8, a, "--scaffold")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --scaffold needs a directory path\n\n" ++ usage, .{});
            scaffold_dir = args[i];
        } else if (std.mem.eql(u8, a, "--doctor")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --doctor needs a path\n\n" ++ usage, .{});
            doctor_path = args[i];
        } else if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (a.len > 0 and a[0] != '-') {
            astro_dir = a;
        }
    }

    if (doctor_path != null and scaffold_dir != null) {
        fatal.usageError("error: --doctor and --scaffold are mutually exclusive\n\n" ++ usage, .{});
    }
    if (doctor_path) |dp| return doctor(io, gpa, dp, json);

    const dir_path = astro_dir orelse fatal.usageError("error: missing <astro-dir>\n\n" ++ usage, .{});

    const root = Io.Dir.cwd().openDir(io, dir_path, .{}) catch |err|
        fatal.dir(dir_path, err);

    const res = scan(io, gpa, root);

    const report = buildReport(gpa, dir_path, res.entries, res.has_config, scaffold_dir != null);

    const f = Io.Dir.cwd().createFile(io, out_path, .{}) catch |err|
        fatal.file(out_path, err);
    var fw = f.writer(io, &.{});
    fw.interface.writeAll(report) catch |err| fatal.file(out_path, err);

    var islands: usize = 0;
    var partials: usize = 0;
    for (res.entries) |e| {
        switch (e.role) {
            .island => islands += 1,
            .partial => partials += 1,
            .plain => {},
        }
    }
    std.debug.print(
        "Wrote {s}: {d} source file(s), {d} island(s) to port, {d} static partial(s).\n" ++
            "Islands are components used with a `client:*` directive; everything else\n" ++
            "(static .astro components, transitive children) maps to a partial or is\n" ++
            "ported only if an island needs it. Next: follow MIGRATION.md and\n" ++
            "docs/migration/astro-to-zigapagos.md.\n",
        .{ out_path, res.entries.len, islands, partials },
    );

    // Scaffold skeletons if requested. The migrate command never clobbers an
    // existing island `.tsx` (force = false → collisions land in `.new`, and a
    // `.new` that is itself taken in `.new.2`, `.new.3`, …).
    if (scaffold_dir) |sdir| {
        scaffoldIslands(io, gpa, root, sdir, res.entries, false);
    }

    return false;
}

/// Recursively collect non-hidden files under `rel` (relative to `base`).
/// A missing directory is silently skipped. Every file is read once: its
/// content feeds both the `client:*` usage set and the per-file `uses_islands`
/// flag. Island classification itself happens in a later pass.
fn scanDir(
    io: Io,
    gpa: Allocator,
    base: Io.Dir,
    rel: []const u8,
    kind: Kind,
    out: *std.ArrayListUnmanaged(Entry),
    island_names: *std.StringHashMapUnmanaged(void),
) void {
    var dir = base.openDir(io, rel, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterateAssumeFirstIteration();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const child = std.fs.path.join(gpa, &.{ rel, entry.name }) catch fatal.oom();
        switch (entry.kind) {
            .directory => scanDir(io, gpa, base, child, kind, out, island_names),
            else => scanFile(io, gpa, base, child, kind, out, island_names),
        }
    }
}

fn scanFile(
    io: Io,
    gpa: Allocator,
    base: Io.Dir,
    path: []const u8,
    kind: Kind,
    out: *std.ArrayListUnmanaged(Entry),
    island_names: *std.StringHashMapUnmanaged(void),
) void {
    // An unreadable source still belongs in the worklist (the porter has to
    // deal with it), but it contributes no `client:*` call sites — say so
    // rather than letting it look like a scanned-and-clean file.
    const content = readFileContent(io, gpa, base, path) catch |err| blk: {
        std.debug.print(
            "warning: cannot read {s}: {t} — listed in the worklist but scanned as empty\n",
            .{ path, err },
        );
        break :blk "";
    };
    defer gpa.free(content);
    // Any source file may host a `<Component client:*>` call site.
    detect.collectClientUsages(gpa, content, island_names) catch fatal.oom();
    const uses = std.mem.indexOf(u8, content, "client:") != null;
    out.append(gpa, .{ .path = path, .kind = kind, .uses_islands = uses }) catch fatal.oom();
}

fn fileExists(io: Io, base: Io.Dir, path: []const u8) bool {
    const f = base.openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// Everything `readFileContent` can fail with, i.e. exactly "this path could
/// not be read": the open and read errors, and nothing else. `OutOfMemory` and
/// the 16 MiB cap are handled in place with `fatal.*` (neither is recoverable
/// per-entry), so they are deliberately absent from this set.
const ReadSourceError = Io.File.OpenError || Io.File.Reader.Error;

/// Read an entire source file into a freshly gpa-allocated slice (caller owns
/// it and must free). A source larger than the 16 MiB cap fails loudly rather
/// than being silently truncated — truncation would drop `client:*` island call
/// sites and emit uncompilable scaffolded `.tsx`.
///
/// An unreadable path (missing, a directory, no read permission, a dangling
/// symlink, I/O error) returns the underlying error. It must NOT be flattened
/// into an empty slice: "" is a legitimate source content that the scaffolder
/// reads as "nothing to port, emit a TODO stub", so conflating the two makes
/// `--scaffold` claim it ported a file it never managed to open.
fn readFileContent(io: Io, gpa: Allocator, base: Io.Dir, path: []const u8) ReadSourceError![]const u8 {
    return base.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
        error.StreamTooLong => fatal.msg(
            "source file exceeds the 16 MiB migration read cap: {s}\n",
            .{path},
        ),
        else => |e| e,
    };
}

// ---------------------------------------------------------------------------
// TSX island scaffold
// ---------------------------------------------------------------------------

/// One output line of the real-port path, plus who owns its bytes.
const OutLine = struct {
    text: []const u8,
    /// True when `text` is a fresh gpa allocation the caller must free; false
    /// when it borrows the caller's `src_content`.
    owned: bool,
};

/// Process one line of a TSX/JSX source file for the real-port path:
///   - Lines importing from React packages → rewrite specifier to "@z/runtime"
///   - Lines with only a default/namespace React import (no named imports) → drop
///   - Lines importing from bare npm packages → keep but append specifier to `flagged`
/// Returns the (possibly rewritten) line, or null to drop the line entirely.
/// Rewritten lines and the `flagged` specifiers are gpa-allocated; the caller
/// frees both (see `writeIslandSkeleton`).
///
/// NOTE: only SINGLE-LINE imports are inspected. A multi-line import where
/// `} from "react";` appears on its own line is left as-is — the porter must
/// check and rewrite those manually.
fn processImportLine(
    gpa: Allocator,
    line: []const u8,
    flagged: *std.ArrayListUnmanaged([]const u8),
) ?OutLine {
    const verbatim: OutLine = .{ .text = line, .owned = false };
    const trimmed = std.mem.trimStart(u8, line, " \t");

    // Must start with "import" to be an ES import statement.
    if (!std.mem.startsWith(u8, trimmed, "import ") and
        !std.mem.startsWith(u8, trimmed, "import{"))
        return verbatim;

    // Locate " from " to extract the module specifier.
    const from_pos = std.mem.indexOf(u8, line, " from ") orelse return verbatim;
    const after_from = from_pos + " from ".len; // points at the opening quote
    if (after_from >= line.len) return verbatim;

    const q = line[after_from]; // '"' or '\''
    if (q != '"' and q != '\'') return verbatim;

    const spec_start = after_from + 1;
    const spec_end = std.mem.indexOfScalarPos(u8, line, spec_start, q) orelse return verbatim;
    const specifier = line[spec_start..spec_end];

    switch (detect.classifyImport(specifier)) {
        .react_rewrite => {
            // A pure default or namespace import (no `{` before `from`) carries no
            // named exports that can survive the rewrite → drop the whole line.
            // e.g. `import React from "react"` or `import * as React from "react"`.
            const before_from = line[0..from_pos];
            const brace_pos = std.mem.indexOf(u8, before_from, "{") orelse {
                return null; // drop: only a default/namespace binding, nothing useful remains
            };
            // A mixed import like `import React, { useState } from "react"` has both
            // a default binding and named imports. Strip the default binding: @z/runtime
            // has no default export and keeping `React` causes an ESM link error
            // ("does not provide an export named 'default'").
            const indent_len = before_from.len - std.mem.trimStart(u8, before_from, " \t").len;
            const named_part = before_from[brace_pos..]; // "{ useState }" etc.
            const has_default_binding = brace_pos > indent_len + "import ".len;
            if (has_default_binding) {
                // Strip the default binding; keep only the named imports block.
                return .{ .text = std.fmt.allocPrint(
                    gpa,
                    "{s}import {s} from \"@z/runtime\"{s}",
                    .{ before_from[0..indent_len], named_part, line[spec_end + 1 ..] },
                ) catch fatal.oom(), .owned = true };
            }
            // No default binding — just rewrite the specifier to @z/runtime.
            return .{ .text = std.fmt.allocPrint(
                gpa,
                "{s}\"@z/runtime\"{s}",
                .{ line[0..after_from], line[spec_end + 1 ..] },
            ) catch fatal.oom(), .owned = true };
        },
        .runtime_ok, .first_party_ok, .relative_ok => return verbatim,
        .legacy_shared_map, .forbidden_npm => {
            flagged.append(gpa, gpa.dupe(u8, specifier) catch fatal.oom()) catch fatal.oom();
            return verbatim;
        },
    }
}

/// Write a TSX island file into the already-created `out_file` (`out_path` is
/// carried only for diagnostics). The caller owns `out_file` and closes it.
///
/// **Real-port path** (when `src_content` has a default export): copies the
/// original source with React → `@z/runtime` import rewrites, drops bare React
/// default imports, and appends a NO-NPM-GUARDRAIL block for any remaining bare
/// npm imports the porter must resolve.
///
/// **Skeleton fallback** (when `src_content` is empty or has no default export):
/// emits a minimal TSX stub with `import { useState } from "@z/runtime"`, the
/// inferred `interface Props` verbatim (or an empty stub), and a `TODO` body.
/// `src_content` being empty means the source genuinely *is* empty — an
/// unreadable source never reaches here (see `readFileContent`).
fn writeIslandSkeleton(
    io: Io,
    gpa: Allocator,
    out_file: Io.File,
    out_path: []const u8,
    name: []const u8,
    astro_src_rel: []const u8,
    src_content: []const u8,
) void {
    var buf: [8 * 1024]u8 = undefined;
    var fw = out_file.writer(io, &buf);
    const w = &fw.interface;

    const has_default_export = std.mem.indexOf(u8, src_content, "export default") != null;

    if (src_content.len > 0 and has_default_export) {
        // Real port: rewrite React imports → @z/runtime, flag other npm imports.
        w.print(
            "// Auto-ported by `zigapagos migrate` from {s}\n" ++
                "// Review against docs/migration/recipes.md before use.\n\n",
            .{astro_src_rel},
        ) catch |err| fatal.file(out_path, err);

        var flagged: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (flagged.items) |spec| gpa.free(spec);
            flagged.deinit(gpa);
        }
        var lines_it = std.mem.splitScalar(u8, src_content, '\n');
        while (lines_it.next()) |line| {
            if (processImportLine(gpa, line, &flagged)) |out_line| {
                defer if (out_line.owned) gpa.free(out_line.text);
                w.print("{s}\n", .{out_line.text}) catch |err| fatal.file(out_path, err);
            }
            // null → line dropped (pure default/namespace React import)
        }

        if (flagged.items.len > 0) {
            w.writeAll(
                "\n// !! NO-NPM-GUARDRAIL: the following imports are not allowed in islands.\n" ++
                    "// Replace each with @z/runtime bindings, @your-org/shared-lite, or a relative\n" ++
                    "// import. See docs/migration/recipes.md (no-npm-guardrail) for guidance.\n" ++
                    "// Flagged specifiers:\n",
            ) catch |err| fatal.file(out_path, err);
            for (flagged.items) |spec| {
                w.print("//   \"{s}\"\n", .{spec}) catch |err| fatal.file(out_path, err);
            }
        }
    } else {
        // TSX skeleton fallback: header + @z/runtime import + verbatim Props + stub.
        w.print(
            "// Scaffolded by `zigapagos migrate` — port the body from {s}\n" ++
                "// Review against docs/migration/recipes.md before use.\n\n" ++
                "import {{ useState }} from \"@z/runtime\";\n\n",
            .{astro_src_rel},
        ) catch |err| fatal.file(out_path, err);

        // Re-emit Props verbatim when available; otherwise emit an empty stub.
        if (detect.findPropsSpan(src_content)) |span| {
            w.print("export {s}\n\n", .{span}) catch |err| fatal.file(out_path, err);
        } else {
            w.print(
                "export interface Props {{\n" ++
                    "  // TODO: add props (source: {s})\n" ++
                    "}}\n\n",
                .{astro_src_rel},
            ) catch |err| fatal.file(out_path, err);
        }

        w.print(
            "export default function {s}(props: Props) {{\n" ++
                "  // TODO: port the body from {s}\n" ++
                "  return <div />;\n" ++
                "}}\n",
            .{ name, astro_src_rel },
        ) catch |err| fatal.file(out_path, err);
    }

    // Buffered: without this the tail of the island is silently dropped.
    w.flush() catch |err| fatal.file(out_path, err);
}

/// How many `<name>.island.tsx.new`, `.new.2`, … siblings `openIslandOutput`
/// probes before refusing to scaffold at all.
const max_new_versions: u32 = 99;

/// An island output file that has been created without destroying anything.
const IslandOutput = struct {
    file: Io.File,
    /// The path actually opened.
    path: []const u8,
    /// True when `path` is a fresh gpa allocation the caller must free.
    path_owned: bool,
    /// True when `out_path` was taken and the output landed on a `.new*` sibling.
    collided: bool,
};

/// Create the island output file for `out_path` without ever truncating work
/// the developer may have done.
///
/// `force = true` (documented `--force` semantics): create-or-truncate
/// `out_path`. The user asked for the overwrite.
///
/// `force = false`: EXCLUSIVE-create `out_path`; on `PathAlreadyExists` fall
/// back to `<out_path>.new`, then `.new.2`, `.new.3`, … — each also
/// exclusive-created. This is load-bearing: a `.new` file is exactly where the
/// developer's hand-porting lives (that is what this tool exists to
/// bootstrap), so a plain create-or-truncate on the fallback path silently
/// destroys it on the next run. When every candidate is taken we refuse rather
/// than pick a victim.
///
/// Exclusive create rather than "stat, then create" on purpose: the check-then-
/// write pair is a TOCTOU window, and the kernel already offers the atomic
/// primitive (O_CREAT|O_EXCL).
fn openIslandOutput(io: Io, gpa: Allocator, out_path: []const u8, force: bool) IslandOutput {
    if (force) {
        const f = Io.Dir.cwd().createFile(io, out_path, .{ .exclusive = false }) catch |err|
            fatal.file(out_path, err);
        return .{ .file = f, .path = out_path, .path_owned = false, .collided = false };
    }

    if (Io.Dir.cwd().createFile(io, out_path, .{ .exclusive = true })) |f| {
        return .{ .file = f, .path = out_path, .path_owned = false, .collided = false };
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => fatal.file(out_path, err),
    }

    var n: u32 = 1;
    while (n <= max_new_versions) : (n += 1) {
        const candidate = if (n == 1)
            std.fmt.allocPrint(gpa, "{s}.new", .{out_path}) catch fatal.oom()
        else
            std.fmt.allocPrint(gpa, "{s}.new.{d}", .{ out_path, n }) catch fatal.oom();
        if (Io.Dir.cwd().createFile(io, candidate, .{ .exclusive = true })) |f| {
            return .{ .file = f, .path = candidate, .path_owned = true, .collided = true };
        } else |err| switch (err) {
            // Taken — try the next version. (fatal.* is noreturn, so the
            // candidate allocated on the failing branch never outlives us.)
            error.PathAlreadyExists => gpa.free(candidate),
            else => fatal.file(candidate, err),
        }
    }

    fatal.msg(
        "refusing to scaffold {s}: it and {s}.new … {s}.new.{d} all exist.\n" ++
            "Merge or delete the stale .new files (they hold your in-progress port) and re-run.\n",
        .{ out_path, out_path, out_path, max_new_versions },
    );
}

/// Main entry point for the `--scaffold` step.
///
/// `force` controls collision handling: when false (the `zigapagos migrate`
/// command) an existing island `.tsx` is preserved and the regenerated stub is
/// written alongside as `<Name>.island.tsx.new` (or `.new.2`, … if that is
/// taken too), so neither hand-migrated island code nor a partly-ported `.new`
/// is ever clobbered. When true (`zigapagos init --from-astro --force`) an
/// existing island `.tsx` is overwritten in place, matching the documented
/// `--force` semantics for every other scaffolded file.
///
/// An island whose source cannot be read is reported and SKIPPED — emitting a
/// TODO stub for it would be indistinguishable from a successful scaffold of an
/// empty component, and the developer would believe it had been ported.
pub fn scaffoldIslands(io: Io, gpa: Allocator, astro_root: Io.Dir, scaffold_dir: []const u8, entries: []const Entry, force: bool) void {
    // Ensure the output directory exists (best-effort mkdir, no-op if already there).
    _ = Io.Dir.cwd().createDirPathOpen(io, scaffold_dir, .{}) catch {};

    var scaffolded: usize = 0;
    var skipped: usize = 0;
    var unreadable: usize = 0;

    for (entries) |e| {
        if (!e.is_island) continue;
        const name = detect.moduleName(e.path);

        // Read the source for import rewriting / Props inference. An unreadable
        // source is NOT an empty source: never fall through to the TODO stub.
        const src = readFileContent(io, gpa, astro_root, e.path) catch |err| {
            std.debug.print(
                "  ERROR cannot read {s}: {t} — NOT scaffolded (no stub written)\n",
                .{ e.path, err },
            );
            unreadable += 1;
            continue;
        };
        defer gpa.free(src);

        const base_name = std.fmt.allocPrint(gpa, "{s}.island.tsx", .{name}) catch fatal.oom();
        defer gpa.free(base_name);
        const out_path = std.fs.path.join(gpa, &.{ scaffold_dir, base_name }) catch fatal.oom();
        defer gpa.free(out_path);

        const out = openIslandOutput(io, gpa, out_path, force);
        defer out.file.close(io);
        defer if (out.path_owned) gpa.free(out.path);

        if (out.collided) {
            std.debug.print(
                "  skip (exists) {s} -> wrote {s} instead\n",
                .{ out_path, out.path },
            );
            skipped += 1;
        } else {
            std.debug.print("  scaffold -> {s}\n", .{out.path});
            scaffolded += 1;
        }

        writeIslandSkeleton(io, gpa, out.file, out.path, name, e.path, src);
    }

    if (unreadable > 0) {
        std.debug.print(
            "Scaffold: {d} island source(s) could not be read and were skipped — port them by hand.\n",
            .{unreadable},
        );
    }
    std.debug.print(
        "Scaffold: {d} written, {d} skipped (already existed -> .new).\n",
        .{ scaffolded, skipped },
    );
}

pub fn buildReport(gpa: Allocator, dir_path: []const u8, entries: []const Entry, has_config: bool, has_scaffold: bool) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;

    w.print(
        \\# Migration worklist: {s} → Zigapagos
        \\
        \\Generated by `zigapagos migrate`. Follow this top-to-bottom. The full mapping is in
        \\`docs/migration/astro-to-zigapagos.md`; island recipes in `docs/migration/recipes.md`.
        \\
        \\## 1. Scaffold the target
        \\
        \\- [ ] `zigapagos.ziggy` (begins with `Site {{`), `content/`, `layouts/`, `assets/`, `components/`, `build.zig`/`build.zig.zon`
        \\{s}
    , .{ dir_path, if (has_config) "- [ ] Port `astro.config.*` → `zigapagos.ziggy` (site/host) + `build.zig` (islands)\n" else "" }) catch fatal.oom();

    buildWiringSection(w, entries, has_scaffold);

    w.writeAll(
        \\
        \\## 2. Static layer (mechanical)
        \\
    ) catch fatal.oom();

    section(w, entries, .page, "Pages → `content/**/*.smd` (frontmatter §4, body Markdown)");
    section(w, entries, .layout, "Layouts → `layouts/**/*.shtml` (SuperHTML §5)");
    partialSection(w, entries);

    w.writeAll(
        \\
        \\## 3. Islands (port as TSX — see docs/migration/recipes.md)
        \\
        \\Each component below is used at a call site with a `client:*` directive, so it
        \\is a real island: port it as `components/<Name>.island.tsx` importing from
        \\`@z/runtime`, register it in `build.zig`, and replace `<Component client:… />`
        \\with `<island src="components/<Name>.island.tsx" client:… prop-NAME="$expr">`.
        \\Run `zigapagos migrate <astro-dir> --scaffold <out-dir>` to auto-port the imports.
        \\
    ) catch fatal.oom();
    islandSection(w, entries);
    plainComponentNote(w, entries);

    w.writeAll(
        \\
        \\## 4. Translate per construct
        \\
        \\- [ ] Directives `client:load|idle|visible|media|only` map 1:1.
        \\- [ ] Props: `count={5}` → `prop-count="5"` (static) or `prop-count="$expr"` (dynamic Scripty).
        \\- [ ] Default slot: pass markup as **children** — TSX islands receive slot content via `props.children`.
        \\- [ ] Build + fix diagnostics until clean; verify each island hydrates.
        \\
        // §5 lives in migrate_detect.zig (the unit-tested module) with a drift
        // guard so it can't re-list a shipped capability as a gap (the F3 bug).
    ++ detect.capabilities_section) catch fatal.oom();

    return aw.written();
}

/// Emit copy-paste-ready `build.zig` + `build.zig.zon`, with every detected island
/// pre-wired into a single `zigapagos.website(.islands = …)` call.
fn buildWiringSection(w: anytype, entries: []const Entry, has_scaffold: bool) void {
    w.writeAll(
        \\
        \\## 1b. Build wiring (paste into the target)
        \\
        \\One `zigapagos.website(.islands = …)` call builds Zigapagos from source with your islands
        \\server-rendered via the Bun sidecar, bundles each to an ES module, and stages
        \\the `@z/runtime` import map.
        \\
    ) catch fatal.oom();

    if (has_scaffold) {
        w.writeAll(
            \\> **Tip:** run `zigapagos migrate <astro-dir> --scaffold <out-dir>` to generate a
            \\> starter TSX island per detected island (React imports rewritten to
            \\> `@z/runtime`, bare npm imports flagged as NO-NPM-GUARDRAIL). Re-running
            \\> is safe — existing files are skipped; `<Name>.island.tsx.new` is written
            \\> instead, and an existing `.new` you have already started porting is
            \\> itself preserved (the stub goes to `.new.2`, `.new.3`, …).
            \\
            \\
        ) catch fatal.oom();
    } else {
        w.writeAll(
            \\> **Tip:** re-run with `--scaffold <out-dir>` to generate a starter TSX
            \\> island per island (React imports rewritten to `@z/runtime`, bare npm
            \\> imports flagged). Re-running is safe — existing files are never clobbered.
            \\
            \\
        ) catch fatal.oom();
    }

    w.writeAll(
        \\`build.zig`:
        \\
        \\```zig
        \\const std = @import("std");
        \\const zigapagos = @import("zigapagos");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const site = zigapagos.website(b, .{
        \\        .islands = &.{
        \\
    ) catch fatal.oom();

    var any = false;
    for (entries) |e| {
        if (!e.is_island) continue;
        const name = detect.moduleName(e.path);
        // `src` must equal the `<island src="...">` string used in your layouts.
        w.print(
            "            .{{ .root = b.path(\"components/{s}.island.tsx\"), .src = \"components/{s}.island.tsx\" }},\n",
            .{ name, name },
        ) catch fatal.oom();
        any = true;
    }
    if (!any) w.writeAll(
        "            // no islands detected; e.g. .{ .root = b.path(\"components/Hero.island.tsx\"), .src = \"components/Hero.island.tsx\" }\n",
    ) catch fatal.oom();

    w.writeAll(
        \\        },
        \\        .output_path = "site",
        \\    });
        \\    b.getInstallStep().dependOn(&site.step);
        \\}
        \\```
        \\
        \\`build.zig.zon` (depend on Zigapagos under the name `zigapagos`):
        \\
        \\```zig
        \\.{
        \\    .name = .my_site,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x0, // run `zig build` once; it prints the value to use
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{
        \\        .zigapagos = .{ .path = "../zigapagos" }, // or a git+https URL + .hash
        \\    },
        \\    .paths = .{"."},
        \\}
        \\```
        \\
    ) catch fatal.oom();
}

fn section(w: anytype, entries: []const Entry, kind: Kind, title: []const u8) void {
    w.print("\n### {s}\n\n", .{title}) catch fatal.oom();
    var any = false;
    for (entries) |e| {
        if (e.kind == kind) {
            const note = if (e.uses_islands) "  — contains `client:` usage; translate the island sites" else "";
            w.print("- [ ] `{s}`{s}\n", .{ e.path, note }) catch fatal.oom();
            any = true;
        }
    }
    if (!any) w.writeAll("- (none found)\n") catch fatal.oom();
}

/// Static `.astro` components (no `client:*` usage) → SuperHTML partials.
fn partialSection(w: anytype, entries: []const Entry) void {
    var any = false;
    for (entries) |e| {
        if (e.role == .partial) {
            if (!any) w.writeAll("\n### Static components → `layouts/templates/**/*.shtml` (partials)\n\n") catch fatal.oom();
            w.print("- [ ] `{s}` — no `client:*` usage; convert to a SuperHTML partial, not an island\n", .{e.path}) catch fatal.oom();
            any = true;
        }
    }
}

fn islandSection(w: anytype, entries: []const Entry) void {
    var any = false;
    for (entries) |e| {
        if (e.is_island) {
            w.print("- [ ] `{s}`\n", .{e.path}) catch fatal.oom();
            any = true;
        }
    }
    if (!any) w.writeAll("- (no islands detected — no component is used with a `client:*` directive)\n") catch fatal.oom();
}

/// Strip a trailing `.island` segment from a module name so that
/// `Flagged.island.tsx` displays as `Flagged`, not `Flagged.island`.
/// Only used in the doctor display path — does NOT change the shared
/// `moduleName`, which the scaffold relies on.
fn islandModuleName(path: []const u8) []const u8 {
    var name = detect.moduleName(path);
    if (std.mem.endsWith(u8, name, ".island")) name = name[0 .. name.len - ".island".len];
    return name;
}

/// Analyse a single island file and emit a human or JSON port-doctor report to
/// stdout. Non-mutating: reads only, writes no files. Returns true when at
/// least one guardrail violation is found (causes a non-zero process exit).
///
/// A failure to *write* the report (EPIPE from `… | head -1`, ENOSPC, EIO)
/// aborts non-zero via `fatal`: exiting 0 after a truncated report would mean
/// "no guardrail violations found", and would hand downstream tooling
/// unparseable JSON.
fn doctor(io: Io, gpa: Allocator, path: []const u8, json: bool) bool {
    const src = readFileContent(io, gpa, Io.Dir.cwd(), path) catch |err|
        fatal.file(path, err);
    defer gpa.free(src);
    if (src.len == 0) fatal.msg("island source is empty, nothing to analyse: {s}\n", .{path});
    const rep = detect.analyze(gpa, islandModuleName(path), src) catch fatal.oom();

    const f = Io.File.stdout();
    // Give the writer a real buffer: unbuffered, each of the renderers' ~40
    // `print`/`writeAll` calls would be its own write syscall per report.
    var buf: [8 * 1024]u8 = undefined;
    var fw = f.writer(io, &buf);
    const w = &fw.interface;
    if (json)
        detect.renderDoctorJson(w, rep) catch |err| fatal.msg("error writing doctor report to stdout: {t}\n", .{err})
    else
        detect.renderDoctorHuman(w, rep) catch |err| fatal.msg("error writing doctor report to stdout: {t}\n", .{err});
    w.flush() catch |err| fatal.msg("error writing doctor report to stdout: {t}\n", .{err});
    return rep.violations() > 0;
}

/// Components that are neither islands nor `.astro` partials (e.g. a transitive
/// child of an island, never used with `client:*`). Listed only as a note so
/// they don't get mistaken for islands.
fn plainComponentNote(w: anytype, entries: []const Entry) void {
    var any = false;
    for (entries) |e| {
        if (e.kind == .component and e.role == .plain) {
            if (!any) w.writeAll(
                \\
                \\> **Not islands** (no `client:*` usage anywhere — likely transitive children
                \\> of an island). Port them only as part of the island that uses them:
                \\
            ) catch fatal.oom();
            w.print("> - `{s}`\n", .{e.path}) catch fatal.oom();
            any = true;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "readFileContent reads a source larger than 64 KiB in full (no truncation)" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Content well past the old 64 KiB stack-buffer cap, with a `client:load`
    // island marker placed *after* byte 64K — silent truncation would drop it.
    const big_len = 100 * 1024;
    const content = try gpa.alloc(u8, big_len);
    defer gpa.free(content);
    @memset(content, 'x');
    const marker = "<Widget client:load />";
    @memcpy(content[big_len - marker.len ..], marker);

    {
        const f = try tmp.dir.createFile(testing_io, "big.astro", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll(content);
    }

    const got = try readFileContent(testing_io, gpa, tmp.dir, "big.astro");
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, big_len), got.len);
    // The post-64K marker survives, so island detection sees the whole file.
    try std.testing.expect(std.mem.indexOf(u8, got, "client:load") != null);
}

/// Build a cwd-relative path into a `std.testing.tmpDir`. The scaffold writes
/// through `Io.Dir.cwd()`, so its output directory must be addressable from the
/// process cwd; `tmpDir` places its tree at `.zig-cache/tmp/<sub_path>`.
fn testTmpPath(gpa: Allocator, tmp: *const std.testing.TmpDir, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, rel });
}

test "readFileContent surfaces an unreadable source instead of an empty slice" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // "" is a legitimate file content; a path that cannot be opened is not the
    // same thing and must not be flattened into one. Flattening is what let
    // `--scaffold` emit a TODO stub for a file it never opened and exit 0.
    try std.testing.expectError(
        error.FileNotFound,
        readFileContent(testing_io, gpa, tmp.dir, "does-not-exist.astro"),
    );

    // A genuinely empty file still reads back as an empty slice.
    {
        const f = try tmp.dir.createFile(testing_io, "empty.astro", .{});
        f.close(testing_io);
    }
    const empty = try readFileContent(testing_io, gpa, tmp.dir, "empty.astro");
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "scaffoldIslands skips an unreadable island source instead of emitting a TODO stub" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const scaffold_dir = try testTmpPath(gpa, &tmp, "components");
    defer gpa.free(scaffold_dir);

    // The island is listed in the worklist but its source cannot be read.
    const entries = [_]Entry{.{
        .path = "Ghost.astro",
        .kind = .component,
        .role = .island,
        .is_island = true,
    }};
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, false);

    // No stub may exist: a stub would be indistinguishable from a real port and
    // would make the developer believe Ghost had been migrated.
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(testing_io, "components/Ghost.island.tsx", .{}),
    );
}

test "scaffoldIslands never truncates a hand-edited .new file" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No `export default` → the deterministic skeleton-fallback output.
    {
        const f = try tmp.dir.createFile(testing_io, "Counter.astro", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll("<div>counter</div>\n");
    }

    const scaffold_dir = try testTmpPath(gpa, &tmp, "components");
    defer gpa.free(scaffold_dir);

    const entries = [_]Entry{.{
        .path = "Counter.astro",
        .kind = .component,
        .role = .island,
        .is_island = true,
    }};

    // Run 1: fresh scaffold → Counter.island.tsx.
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, false);
    // Run 2: the .tsx is taken → Counter.island.tsx.new.
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, false);

    // The developer now does the actual porting work IN the .new file — that is
    // precisely what this tool exists to bootstrap.
    const ported = "// hand-ported island — losing this loses the migration work\n";
    {
        const f = try tmp.dir.createFile(testing_io, "components/Counter.island.tsx.new", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll(ported);
    }

    // Run 3 previously re-entered the identical branch and TRUNCATED the .new.
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, false);

    const kept = try tmp.dir.readFileAlloc(testing_io, "components/Counter.island.tsx.new", gpa, .limited(64 * 1024));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings(ported, kept);

    // The regenerated stub landed on a versioned sibling, so nothing is lost
    // and the collision is visible on disk.
    const versioned = try tmp.dir.readFileAlloc(testing_io, "components/Counter.island.tsx.new.2", gpa, .limited(64 * 1024));
    defer gpa.free(versioned);
    try std.testing.expect(std.mem.indexOf(u8, versioned, "port the body from Counter.astro") != null);

    // The original island file is untouched by every non-force run.
    const original = try tmp.dir.readFileAlloc(testing_io, "components/Counter.island.tsx", gpa, .limited(64 * 1024));
    defer gpa.free(original);
    try std.testing.expect(std.mem.indexOf(u8, original, "export default function Counter") != null);
}

test "scaffoldIslands honours --force by overwriting the island in place" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(testing_io, "Counter.astro", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll("<div>counter</div>\n");
    }

    const scaffold_dir = try testTmpPath(gpa, &tmp, "components");
    defer gpa.free(scaffold_dir);

    const entries = [_]Entry{.{
        .path = "Counter.astro",
        .kind = .component,
        .role = .island,
        .is_island = true,
    }};

    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, true);
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, true);

    // `--force` still means overwrite in place — no `.new` sibling appears.
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(testing_io, "components/Counter.island.tsx.new", .{}),
    );
    const out = try tmp.dir.readFileAlloc(testing_io, "components/Counter.island.tsx", gpa, .limited(64 * 1024));
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "export default function Counter") != null);
}

test "scaffoldIslands real-port path rewrites React imports and frees its scratch" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(testing_io, "Form.astro", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll(
            \\import React, { useState } from "react";
            \\import Recaptcha from "react-google-recaptcha";
            \\export default function Form() { return <div />; }
            \\
        );
    }

    const scaffold_dir = try testTmpPath(gpa, &tmp, "components");
    defer gpa.free(scaffold_dir);

    const entries = [_]Entry{.{
        .path = "Form.astro",
        .kind = .component,
        .role = .island,
        .is_island = true,
    }};
    // Raw testing.allocator: the rewritten lines and flagged specifiers are
    // gpa-allocated scratch, so a missed free fails this test.
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, false);

    const out = try tmp.dir.readFileAlloc(testing_io, "components/Form.island.tsx", gpa, .limited(64 * 1024));
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "import { useState } from \"@z/runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NO-NPM-GUARDRAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "react-google-recaptcha") != null);
}

test "usage says outright that migrate converts nothing" {
    // Issue #40: this project itself wrote copy claiming `migrate` "applies the
    // mappings" three times before catching it, and a fourth survived into a
    // published page description. The tool's own help is where that belief starts,
    // and it never contradicted it — it described what migrate DOES (scan, write a
    // worklist) and left the reader to infer the much larger set of things it does
    // not. Inference is exactly what went wrong four times.
    //
    // So the disclaimer is load-bearing copy, pinned the way src/fatal.zig pins the
    // live-reload help: a reword may move it, but it may not drop it.
    const usage_text = usage;
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "CONVERTS NOTHING") != null);
    // The three conversions a reader most plausibly assumes happen. Naming the
    // target extensions is what makes the denial concrete rather than a hedge.
    try std.testing.expect(std.mem.indexOf(u8, usage_text, ".smd") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, ".shtml") != null);
    // --scaffold is the single exception, and the denial is false unless it is
    // named as one INSIDE the denial paragraph itself. The search is bounded to
    // that paragraph on purpose: the Options block underneath always lists
    // `--scaffold DIR`, so searching to the end of the usage string would hold
    // even with the exception sentence deleted -- and an assertion that cannot
    // fail pins nothing.
    const nothing_at = std.mem.indexOf(u8, usage_text, "CONVERTS NOTHING").?;
    const after_denial = usage_text[nothing_at..];
    const options_at = std.mem.indexOf(u8, after_denial, "\nOptions:") orelse
        return error.DenialParagraphNoLongerPrecedesOptions;
    try std.testing.expect(std.mem.indexOf(u8, after_denial[0..options_at], "--scaffold") != null);
}
