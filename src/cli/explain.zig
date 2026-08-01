//! `zigapagos explain <route> [OPTIONS]` -- resolves one output route to its
//! content source, layout chain, effective frontmatter, islands, page assets
//! and EMITTED PATHS (issue #47). Runs the SAME kind of in-memory build as
//! `zigapagos validate` (see validate.zig's module doc for why it's a FULL
//! memory build, not a truncated one), with the island sidecar deliberately
//! left unconfigured so the raw `<island>`/`<z-island>` markup survives into
//! `page._render.out` for Bun-free enumeration (see
//! `root.Options.island_sidecar_optional`).
//!
//! Content routes only: a memory build never prerenders, and neither
//! `validate` nor `explain` pass `--spa=` specs, so SPA routes, `_shell.html`,
//! routing manifests and the site-wide `404.html` are invisible here -- a
//! miss says so and points at the routing manifests.
//!
//! The "emitted paths" section is the highest-risk part of this command: a
//! naive re-derivation from frontmatter strings (e.g. assuming
//! `url_path_prefix` belongs in a disk path) reproduces the exact defect
//! issue #47 exists to fix. See worker.zig's `pageDir`/`mainOutputPath`/
//! `suffixedOutputPath` -- the SAME functions `renderPage`'s disk-mode emit
//! path calls -- and `printReport`'s "emitted paths" block below for how the
//! SET of what's emitted is cross-checked against `Variant.urls` (the
//! authoritative registration), with the actual disk-path STRINGS computed by
//! those same worker.zig functions rather than re-derived here.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const fatal = @import("../fatal.zig");
const root = @import("../root.zig");
const worker = @import("../worker.zig");
const context = @import("../context.zig");
const Page = context.Page;
const Variant = @import("../Variant.zig");
const PathTable = @import("../PathTable.zig");
const PathName = PathTable.PathName;
const StringTable = @import("../StringTable.zig");
const Build = @import("../Build.zig");
const islands = @import("../islands/pass.zig");
const sidecar = @import("../islands/sidecar.zig");
const RenderArena = @import("../islands/render_arena.zig").RenderArena;
const Allocator = std.mem.Allocator;
const BuildAsset = root.BuildAsset;
const diag = @import("../diag.zig");

/// NO_SLOP.md §2.2a contract 1 (self-freeing): every allocation made here is
/// freed before return -- `cmd` by its `deinit`, and `resolveRoute` /
/// `printReport` are themselves contract 1, so this function hands them `gpa`
/// directly rather than an arena that would paper over a missing free in
/// either. `build`'s teardown mirrors `validate.zig`'s (Debug-only, see its
/// doc comment for why).
pub fn explain(
    io: Io,
    gpa: Allocator,
    args: []const []const u8,
) bool {
    var cmd: Command = Command.parse(gpa, args) catch fatal.oom();
    defer cmd.deinit(gpa);

    const cfg, const base_dir_path = root.Config.load(io, gpa);

    worker.start(io);
    defer if (builtin.mode == .Debug) worker.stopWaitAndDeinit(io);

    // DELIBERATELY NOT FACTORED into a shared helper with validate.zig's
    // identical-looking preamble -- see validate.zig's `validate` doc comment
    // for why (a `Build`'s `cfg` pointer would dangle out of a by-value
    // helper return, since `cfg` is a local in the CALLER's frame).
    const build = root.run(io, gpa, &cfg, .{
        .base_dir_path = base_dir_path,
        .build_assets = &cmd.build_assets,
        .drafts = cmd.drafts,
        .mode = .memory,
        .allow_missing_pages = cmd.allow_missing_pages,
        .island_sidecar_optional = true,
    }) catch fatal.oom();
    defer if (builtin.mode == .Debug) build.deinit(io, gpa);

    if (build.any_prerendering_error) {
        std.debug.print(
            "explain: the site failed to build (pre-render errors) — see the diagnostics above\n" ++
                "note: run `zigapagos validate` for the full diagnostic list\n",
            .{},
        );
        return true;
    }

    const m = (resolveRoute(gpa, &build, cmd.route) catch fatal.oom()) orelse return true;

    var out_buf: [8 * 1024]u8 = undefined;
    const stdout = Io.File.stdout();
    // `writerStreaming`, not `writer`: `Io.File.writer` defaults to POSITIONAL
    // writes, which track their own offset and ignore the file's shared one.
    // With `cmd >f 2>&1` both descriptors point at ONE open file description,
    // and stderr's `std.debug.print` has already advanced its offset by the
    // time this buffered report flushes -- so a positional flush from offset
    // zero overwrites what stderr committed, silently corrupting anything that
    // parses the merged stream (issue #78). Streaming (positionless, appending)
    // writes advance the shared offset instead. On a pipe or a tty the
    // positional writer already fell back to streaming, so this changes
    // behaviour in exactly the broken case and nowhere else.
    var fw = stdout.writerStreaming(io, &out_buf);
    const w = &fw.interface;

    // `printReport` fails for two unrelated reasons and they must not be
    // reported as one: a stdout write error (`error.WriteFailed` out of the
    // writer) versus a failure to BUILD the report at all (`error.OutOfMemory`
    // from a report allocation, `error.MissingLayout` from the layout-chain
    // walk, an island-tokenizer error out of `islands.process`). Labelling the
    // second kind "error writing to stdout" sends a reader looking at their
    // terminal instead of at their site.
    const broken = printReport(w, gpa, &build, cmd.route, m) catch |err| switch (err) {
        error.WriteFailed => fatal.msg("error writing the explain report to stdout: {t}\n", .{err}),
        else => fatal.msg("error building the explain report: {t}\n", .{err}),
    };

    // This one really is a write: everything was built, only the flush failed.
    w.flush() catch |err| fatal.msg("error writing the explain report to stdout: {t}\n", .{err});

    return broken;
}

/// A resolved route: which variant it landed in, and the `Variant.urls` hint
/// that matched. `hint.id` is the page index for `.page_main`/`.page_alias`/
/// `.page_alternative`; for `.page_asset` it's the OWNING page (the index
/// page of the asset's directory -- see `Variant.zig`'s `page_assets_owner`).
const Match = struct {
    variant: *Variant,
    hint: Variant.LocationHint,
};

/// Resolves `route_in` (a request-style path, e.g. "/docs/overview/") to a
/// page: strip the site's `url_path_prefix`, append `index.html` on a trailing
/// slash, then per variant strip `output_path_prefix` and look the result up in
/// `Variant.urls` -- the same derivation a static host performs on the emitted
/// tree. Prints its own diagnostic and returns null on a miss (a usage-level
/// malformed route is a hard `fatal.usageError` instead, matching `(H4)`: never
/// `fatal.msg` -- that panics in Debug).
///
/// One deliberate ADDITION over what a host does: an extensionless route with
/// NO trailing slash (e.g. `/docs/overview`, as typed on a command line) also
/// gets a second attempt as a directory index (`/docs/overview/index.html`). A
/// browser navigates to an explicit URL; a CLI argument benefits from the
/// convenience.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing): the one scratch buffer
/// `routeCandidates` writes into is freed before return, and the returned
/// `Match` borrows nothing from it (it is a `*Variant` plus a by-value
/// `LocationHint`, both owned by `build`). Nothing escapes, so this is correct
/// under ANY allocator rather than only under a caller-supplied arena.
fn resolveRoute(alloc: Allocator, build: *const Build, route_in: []const u8) !?Match {
    if (route_in.len == 0 or route_in[0] != '/') {
        fatal.usageError("error: route must start with '/' (got '{s}')\n", .{route_in});
    }
    if (hasTraversalSegment(route_in)) {
        fatal.usageError("error: route '{s}' contains a '.'/'..' path segment\n", .{route_in});
    }

    var route: []const u8 = route_in;
    switch (build.cfg.*) {
        .Site => |s| {
            if (s.url_path_prefix.len > 0) {
                route = stripPathPrefix(route, s.url_path_prefix) orelse {
                    std.debug.print(
                        "explain: route '{s}' is outside the site's url_path_prefix ('{s}')\n" ++
                            "note: this site is served under '/{s}/'; try 'zigapagos explain /{s}{s}'\n",
                        .{ route_in, s.url_path_prefix, s.url_path_prefix, s.url_path_prefix, route_in },
                    );
                    return null;
                };
                if (route.len == 0) route = "/";
            }
        },
        .Multilingual => {},
    }

    // One scratch buffer is enough: `routeCandidates` builds AT MOST one new
    // string, and the longest it can be is `route` + "/index.html".
    var cand_buf: [2]Candidate = undefined;
    const scratch = try alloc.alloc(u8, route.len + "/index.html".len);
    defer alloc.free(scratch);
    const candidates = cand_buf[0..routeCandidates(scratch, route, &cand_buf)];

    for (candidates) |c| {
        if (tryVariants(build, c.path, c.ends_with_slash)) |m| return m;
    }

    std.debug.print(
        "explain: no route matches '{s}'\n" ++
            "note: only CONTENT routes are covered here — a client-routed SPA\n" ++
            "      route (from a `.spa.tsx`) is not; check that SPA's routing\n" ++
            "      manifest instead (a memory build never prerenders SPAs)\n",
        .{route_in},
    );
    return null;
}

/// True if any path segment of `path` is exactly `.` or `..`. Split on both
/// `/` and `\`: backslash isn't a separator on our Linux/macOS targets (it's
/// a legal filename byte), but the file-system APIs on other platforms honor
/// it, so a separator-correct guard rejects `..\` traversal defensively too.
///
/// `explain` takes a route from a command line and turns it into an output
/// path, so an unguarded `..` would walk the resolver out of the output tree.
/// Substring matches are deliberately allowed: `photo..jpg` and `x..y` are
/// legitimate filenames, and rejecting them would be a false positive
/// (AUD-014).
fn hasTraversalSegment(path: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return true;
    }
    return false;
}

/// Strips a leading `/` plus `prefix` from an origin-form `path`, at a SEGMENT
/// boundary. Returns "" when `path` is exactly the prefix, otherwise a slice
/// that starts with '/'. Returns null when `path` is NOT under `prefix`.
///
/// The point is the segment boundary. Slicing at the prefix's BYTE length —
/// what this replaces — accepted "/docs../foo" for prefix "docs" and handed the
/// caller "../foo", a traversal that `hasTraversalSegment` above had already
/// cleared and does not re-run. An empty prefix matches everything and strips
/// only the leading '/' (the single-variant case).
fn stripPathPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    const body = path[1..];
    if (!std.mem.startsWith(u8, body, prefix)) return null;

    var len = prefix.len;
    if (len > 0 and prefix[len - 1] == '/') len -= 1;
    const rest = body[len..];
    // The byte after the prefix must end the path or start a new segment.
    if (len != 0 and rest.len != 0 and rest[0] != '/') return null;
    return rest;
}

/// One output-relative path to try, plus the `ends_with_slash` flag
/// `tryVariants` needs for its `output_path_prefix` offset.
const Candidate = struct { path: []const u8, ends_with_slash: bool };

/// Normalizes a request-style route into the 1-2 output paths worth trying, in
/// order. Extracted from `resolveRoute` so the normalization is unit-testable
/// on its own: everything else in resolution needs a whole `Build`, and this
/// part -- the part with the actual branching -- does not.
///
///   "/docs/overview/"           -> "/docs/overview/index.html"   (dir)
///   "/docs/overview"            -> "/docs/overview", then
///                                  "/docs/overview/index.html"   (dir retry)
///   "/docs/overview/index.html" -> "/docs/overview/index.html"   (as given)
///
/// The second candidate exists because a browser navigates to an explicit URL
/// but a route typed on a command line is usually written without the trailing
/// slash, and answering "no route matches" to `/docs/overview` when
/// `/docs/overview/` exists would be obtuse.
///
/// NO_SLOP.md §2.2a contract 3 (caller-buffer): allocates nothing. At most one
/// candidate string is constructed, into `scratch`; the other candidate (and
/// the single-candidate cases that need no rewriting) BORROWS `route`. Callers
/// must therefore keep both `scratch` and `route` alive while using the result.
/// `scratch` must be at least `route.len + "/index.html".len` bytes.
fn routeCandidates(scratch: []u8, route: []const u8, out: *[2]Candidate) usize {
    if (std.mem.endsWith(u8, route, "/")) {
        // A directory route maps to that directory's index.html and nothing
        // else -- there is no second spelling worth trying.
        const p = std.fmt.bufPrint(scratch, "{s}index.html", .{route}) catch unreachable;
        out[0] = .{ .path = p, .ends_with_slash = true };
        return 1;
    }

    out[0] = .{ .path = route, .ends_with_slash = false };
    // A route that already names a file (".html", ".xml", ".svg") is taken at
    // face value: retrying it as a directory would be nonsense.
    if (std.fs.path.extension(route).len != 0) return 1;

    const p = std.fmt.bufPrint(scratch, "{s}/index.html", .{route}) catch unreachable;
    out[1] = .{ .path = p, .ends_with_slash = true };
    return 2;
}

/// The per-variant matching core, mirroring a static host's own lookup loop
/// byte-for-byte (including the `@intFromBool` offset -- `PathName.get`
/// normalizes a leading '/' away via `dirnamePosix`/`basenamePosix` in most
/// shapes, but this is inherited resolution logic and copying it verbatim
/// costs nothing and removes all doubt).
fn tryVariants(build: *const Build, path: []const u8, path_ends_with_slash: bool) ?Match {
    for (build.variants) |*v| {
        const after_prefix = stripPathPrefix(path, v.output_path_prefix) orelse continue;
        const subpath = after_prefix[@intFromBool(v.output_path_prefix.len > 0 and path_ends_with_slash)..];
        const pn = PathName.get(&v.string_table, &v.path_table, subpath) orelse continue;
        const hint = v.urls.get(pn) orelse continue;
        return .{ .variant = v, .hint = hint };
    }
    return null;
}

/// Prints the full report for a resolved route. Returns true when the
/// resolved page is in an error state (mirrors the release build's own
/// per-page checks: `!_parse.active`, `_parse.status != .parsed`,
/// `_analysis.frontmatter.items.len > 0`, `PageAnalysisError.anyError`,
/// `_render.errors.len > 0`) -- the error IS the explanation, so everything
/// that CAN be printed is printed before bailing.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing): every allocation below is freed
/// before return and nothing escapes -- the report is written straight to `w`.
/// It deliberately does NOT take a `RenderArena`: contract 4 has to be earned,
/// and the first of its three conditions (the result is a graph of interlinked
/// allocations) plainly fails for a function whose result is a `bool`. Each
/// piece of scratch here is a standalone buffer with a `defer` beside it, so
/// the function is correct under any allocator -- which is why the caller now
/// hands it `gpa` rather than a CLI arena that would hide a missing free.
fn printReport(
    w: *std.Io.Writer,
    alloc: Allocator,
    build: *const Build,
    route_in: []const u8,
    m: Match,
) !bool {
    const v = m.variant;

    if (m.hint.kind == .page_asset) {
        // No `route:` line here -- the standard report header below prints it.
        // Printing it twice for asset routes was a real wart in the first cut.
        try w.print(
            "note: this route serves a PAGE ASSET, owned by the page below (see\n" ++
                "      Variant.zig's page_assets_owner) -- explaining the owning page:\n\n",
            .{},
        );
    }

    const page_index = m.hint.id;
    const page = &v.pages.items[page_index];

    try w.print("route:  {s}\n", .{route_in});
    try w.print("source: {f}\n", .{page._scan.file.fmt(&v.string_table, &v.path_table, v.content_dir_path, "")});

    // Page-state checks, mirroring the release build's own policy (see this
    // function's doc comment). Structurally, most of these can only be false
    // by the time we're here (a `.memory` build's aggregate gate already
    // caught frontmatter/analysis errors ANYWHERE and aborted the whole
    // build before this point -- see `explain()`'s `any_prerendering_error`
    // check), but keeping the full set makes this correct even if that
    // gate's scope ever narrows, and it's what makes the render-error case
    // (which genuinely IS page-specific -- see below) fall out of the same
    // code path instead of a bespoke one.
    if (!page._parse.active) {
        try w.print("\nerror: this page is not active\n", .{});
        return true;
    }
    if (page._parse.status != .parsed) {
        try w.print("\nerror: this page failed to parse\n", .{});
        return true;
    }
    if (page._analysis.frontmatter.items.len > 0) {
        try w.print("\nerror: this page has frontmatter errors — run `zigapagos validate` for detail\n", .{});
        return true;
    }
    if (Page.PageAnalysisError.anyError(page._analysis.page.items)) {
        try w.print("\nerror: this page contains SuperMD errors — run `zigapagos validate` for detail\n", .{});
        return true;
    }

    // layout chain.
    //
    // A route that resolved to an ALTERNATIVE is rendered through that
    // alternative's OWN layout (`Alternative.layout`), not the page's.
    // Reporting `page.layout` for `/docs/overview/index.xml` when the build
    // renders it through `rss.shtml` would be this PR's own defect class in
    // miniature: a report describing something the build does not do (#47).
    // The alternative is matched by NAME because that is what the
    // `Variant.urls` hint carries.
    const layout = layout: {
        const alt_name = switch (m.hint.kind) {
            .page_alternative => |n| n,
            else => break :layout page.layout,
        };
        for (page.alternatives) |alt| {
            if (!std.mem.eql(u8, alt.name, alt_name)) continue;
            try w.print(
                "note: this route is the '{s}' alternative, rendered through its OWN layout\n",
                .{alt_name},
            );
            break :layout alt.layout;
        }
        // Defensive only: `.page_alternative` hints are registered FROM
        // `page.alternatives`, so a hint whose name has no entry cannot
        // survive a successful build. Say so rather than quietly reporting
        // the page's layout as if it were this route's.
        try w.print(
            "note: this route registered as the '{s}' alternative but the page declares no such entry" ++
                " — please report this; the layout below is the PAGE's, not this route's\n",
            .{alt_name},
        );
        break :layout page.layout;
    };
    try w.print("layout: {s}\n", .{layout});
    {
        var depth: usize = 0;
        const max_depth = 32;
        var t = build.templates.get(PathName.get(&build.st, &build.pt, layout) orelse return error.MissingLayout).?;
        while (t.ast.errors.len == 0 and t.ast.extends_idx != 0) : (depth += 1) {
            if (depth >= max_depth) {
                try w.print("        … extends chain exceeds {d} levels, stopping\n", .{max_depth});
                break;
            }
            const parent_name = t.ast.nodes[t.ast.extends_idx].templateValue().span.slice(t.src);
            // Freed at the end of every iteration (and on `break`): `PathName.get`
            // interns into `build`'s tables and `templates.get` returns a
            // build-owned template, so nothing below borrows `parent_path`.
            const parent_path = try root.join(alloc, &.{ "templates", parent_name }, '/');
            defer alloc.free(parent_path);
            try w.print("        extends {s}\n", .{parent_path});
            const parent_pn = PathName.get(&build.st, &build.pt, parent_path) orelse break;
            t = build.templates.get(parent_pn) orelse break;
        }
    }

    // frontmatter after schema defaults
    try w.print("frontmatter (after schema defaults):\n", .{});
    try w.print("  .title        = \"{s}\"\n", .{page.title});
    try w.print("  .description  = \"{s}\"\n", .{page.description});
    try w.print("  .author       = \"{s}\"\n", .{page.author});
    try w.print("  .date         = ", .{});
    page.date._inst.time().gofmt(w, "2006-01-02T15:04:05Z07:00") catch try w.print("<unformattable>", .{});
    try w.print("\n", .{});
    try w.print("  .layout       = \"{s}\"\n", .{page.layout});
    try w.print("  .draft        = {}\n", .{page.draft});
    try w.print("  .tags         = [", .{});
    for (page.tags, 0..) |tag, i| {
        if (i > 0) try w.print(", ", .{});
        try w.print("\"{s}\"", .{tag});
    }
    try w.print("]\n", .{});
    try w.print("  .aliases      = [", .{});
    for (page.aliases, 0..) |a, i| {
        if (i > 0) try w.print(", ", .{});
        try w.print("\"{s}\"", .{a});
    }
    try w.print("]\n", .{});
    try w.print("  .alternatives = [", .{});
    for (page.alternatives, 0..) |alt, i| {
        if (i > 0) try w.print(", ", .{});
        try w.print("{s} -> {s}", .{ alt.name, alt.output });
    }
    try w.print("]\n", .{});
    try w.print("  .skip_subdirs = {}\n", .{page.skip_subdirs});
    if (page.translation_key) |tk| {
        try w.print("  .translation_key = \"{s}\"\n", .{tk});
    } else {
        try w.print("  .translation_key = null\n", .{});
    }
    switch (page.custom) {
        .kv => |kv| {
            try w.print("  .custom       = {{", .{});
            for (kv.fields.keys(), 0..) |k, i| {
                if (i > 0) try w.print(", ", .{});
                try w.print("{s}", .{k});
            }
            try w.print("}}\n", .{});
        },
        else => try w.print("  .custom       = <non-map value>\n", .{}),
    }

    // islands
    try w.print("islands:\n", .{});
    {
        var stub: StubRenderer = .{};
        var render_arena_state = std.heap.ArenaAllocator.init(alloc);
        defer render_arena_state.deinit();
        const render_arena = RenderArena.from(&render_arena_state);
        const result = try islands.process(alloc, render_arena, page._render.out, route_in, &stub, .{});
        defer alloc.free(result.html);
        if (result.instances.len == 0) {
            try w.print("  (none)\n", .{});
        } else {
            for (result.instances) |inst| {
                try w.print("  {s}  ({s})\n", .{ inst.src, inst.client });
            }
        }
    }

    // page assets
    try w.print("page assets:\n", .{});
    {
        var any = false;
        var it = v.urls.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.kind != .page_asset) continue;
            if (kv.value_ptr.id != page_index) continue;
            any = true;
            const referenced = kv.value_ptr.kind.page_asset.load(.acquire) > 0;
            try w.print("  {f}   {s}\n", .{
                kv.key_ptr.fmt(&v.string_table, &v.path_table, null, ""),
                if (referenced) "referenced" else "NOT referenced (pruned from the output tree)",
            });
        }
        if (!any) try w.print("  (none)\n", .{});
    }

    // emitted paths -- see this file's module doc comment (H7).
    try w.print("emitted paths (relative to the output directory):\n", .{});
    {
        var has_main = false;
        var alias_count: usize = 0;
        var alt_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer alt_names.deinit(alloc);
        var it2 = v.urls.iterator();
        while (it2.next()) |kv| {
            if (kv.value_ptr.id != page_index) continue;
            switch (kv.value_ptr.kind) {
                .page_main => has_main = true,
                .page_alias => alias_count += 1,
                .page_alternative => |name| try alt_names.append(alloc, name),
                .page_asset => {},
            }
        }

        if (has_main) {
            // worker.zig's three path helpers are §2.2a contract 1: the result
            // is always a fresh allocation, so every one of them is freed here.
            const p = try worker.mainOutputPath(alloc, build.cfg, v, page);
            defer alloc.free(p);
            try w.print("  {s}   main output\n", .{p});
        }
        var printed_aliases: usize = 0;
        for (page.aliases) |a| {
            if (!worker.validOutputPath(a)) continue;
            const p = try worker.suffixedOutputPath(alloc, build.cfg, v, page, a);
            defer alloc.free(p);
            try w.print("  {s}   page alias\n", .{p});
            printed_aliases += 1;
        }
        if (printed_aliases != alias_count) {
            // Defensive only: root.zig's collision gate aborts the whole
            // build before this point on any URL collision, so a successful
            // build's registered alias count and its valid-alias-text count
            // should always agree. Surface a mismatch rather than silently
            // under/over-reporting.
            try w.print(
                "  (note: {d} alias hint(s) registered in Variant.urls but {d} valid alias string(s) found — please report this)\n",
                .{ alias_count, printed_aliases },
            );
        }
        for (page.alternatives) |alt| {
            var owned = false;
            for (alt_names.items) |n| {
                if (std.mem.eql(u8, n, alt.name)) {
                    owned = true;
                    break;
                }
            }
            if (!owned) continue;
            if (!worker.validOutputPath(alt.output)) continue;
            const p = try worker.suffixedOutputPath(alloc, build.cfg, v, page, alt.output);
            defer alloc.free(p);
            try w.print("  {s}   page alternative '{s}'\n", .{ p, alt.name });
        }
    }

    if (page._render.errors.len > 0) {
        try w.print("\nerror: this page has render errors:\n{s}\n", .{page._render.errors});
        return true;
    }

    return false;
}

/// A no-op island renderer for `explain`'s Bun-free enumeration. With
/// `island_sidecar_optional = true`, `page._render.out` still holds the raw,
/// un-SSR'd `<island>`/`<z-island>` markup (see worker.zig's null-sidecar
/// branch), and `explain` re-runs `islands.process` over it purely to
/// ENUMERATE the islands -- it reads `result.instances` and discards
/// `result.html`.
///
/// `process` does call `render`, once per non-`client:only` island (pass.zig's
/// `html_out` site), so this must be a real renderer and not a never-invoked
/// placeholder: returning an empty string yields empty island placeholders in
/// HTML that is then thrown away, which is exactly what `explain` wants and
/// costs no Bun. Mirrors `pass.zig`'s own test-only `StubRenderer` (private to
/// that file, hence this small duplicate rather than exporting theirs).
const StubRenderer = struct {
    pub fn render(
        _: *StubRenderer,
        render_arena: RenderArena,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: ?*sidecar.RenderError,
    ) ![]const u8 {
        return render_arena.a.dupe(u8, "");
    }
};

pub const Command = struct {
    route: []const u8,
    build_assets: std.StringArrayHashMapUnmanaged(BuildAsset),
    drafts: bool,
    allow_missing_pages: bool,

    /// NO_SLOP.md §2.2a contract 2 (owned-result): the caller `deinit`s.
    pub fn deinit(co: *const Command, gpa: Allocator) void {
        var ba = co.build_assets;
        ba.deinit(gpa);
    }

    pub fn parse(gpa: Allocator, args: []const []const u8) !Command {
        var build_assets: std.StringArrayHashMapUnmanaged(BuildAsset) = .empty;
        var drafts = false;
        var allow_missing_pages = false;
        var route: ?[]const u8 = null;

        const eql = std.mem.eql;
        const startsWith = std.mem.startsWith;
        var idx: usize = 0;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
                fatal.usage(help_message, .{});
            } else if (startsWith(u8, arg, "--build-asset=")) {
                const name = arg["--build-asset=".len..];

                idx += 1;
                if (idx >= args.len) fatal.usageError(
                    "error: missing build asset sub-argument for '{s}'\n",
                    .{name},
                );

                const input_path = args[idx];

                idx += 1;
                var install_path: ?[]const u8 = null;
                var install_always = false;
                if (idx < args.len) {
                    const next = args[idx];
                    if (startsWith(u8, next, "--install=")) {
                        install_path = next["--install=".len..];
                    } else if (startsWith(u8, next, "--install-always=")) {
                        install_always = true;
                        install_path = next["--install-always=".len..];
                    } else {
                        idx -= 1;
                    }
                }

                const gop = try build_assets.getOrPut(gpa, name);
                if (gop.found_existing) fatal.usageError(
                    "error: duplicate build asset name '{s}'\n",
                    .{name},
                );

                gop.value_ptr.* = .{
                    .input_path = input_path,
                    .install_path = install_path,
                    .install_always = install_always,
                    .rc = .{ .raw = @intFromBool(install_always) },
                };
            } else if (eql(u8, arg, "--drafts")) {
                drafts = true;
            } else if (eql(u8, arg, "--allow-missing-pages")) {
                allow_missing_pages = true;
            } else if (startsWith(u8, arg, "-")) {
                fatal.usageError("error: unexpected cli argument '{s}'\n", .{arg});
            } else if (route == null) {
                // `zigapagos explain <route>` (issue #47) and `zigapagos
                // explain-code <CODE>` (issue #46) are adjacent commands with
                // DISJOINT argument grammars -- a route must start with '/', a
                // code is a member of a closed, gated enum -- so an argument
                // that IS a registered code is unambiguously someone who
                // reached for the wrong one of the two.
                //
                // Checked HERE and not at `resolveRoute`'s route guard, which
                // is the natural-looking home: `explain` loads the site config
                // and runs a whole in-memory build before it resolves a route,
                // so outside a site directory the wrong-command user gets
                // `Config.load`'s usage MENU and never reaches the guard.
                // Argument parsing is the last point that runs unconditionally.
                if (std.meta.stringToEnum(diag.Code, arg) != null) fatal.usageError(
                    "error: '{s}' is a diagnostic code, not a route\n" ++
                        "note: run 'zigapagos explain-code {s}' for its long-form explanation\n",
                    .{ arg, arg },
                );
                route = arg;
            } else {
                fatal.usageError("error: unexpected second positional argument '{s}' (route is already '{s}')\n", .{ arg, route.? });
            }
        }

        const r = route orelse fatal.usageError("error: 'zigapagos explain' needs exactly one route argument, e.g. 'zigapagos explain /docs/overview/'\n", .{});

        return .{
            .route = r,
            .build_assets = build_assets,
            .drafts = drafts,
            .allow_missing_pages = allow_missing_pages,
        };
    }
};

const help_message =
    \\Usage: zigapagos explain <route> [OPTIONS]
    \\
    \\Resolves one output ROUTE (e.g. '/docs/overview/') to its content
    \\source, layout chain, effective frontmatter, islands, page assets and
    \\EMITTED PATHS. Builds the whole site in memory to do it (the URL/link
    \\tables must be whole anyway).
    \\
    \\CONTENT ROUTES ONLY: a memory build never prerenders SPAs, and this
    \\command passes no `--spa=` specs, so a client-routed SPA route is not
    \\covered — on a miss, check that SPA's routing manifest instead.
    \\
    \\PAGE-OWNED ASSETS ONLY: site-asset refcounts are global, so the "page
    \\assets" section means "referenced by this build", not "by this page"
    \\specifically for anything other than the page's own bundle assets.
    \\
    \\The island list is what the markup DECLARES, not what SSR'd
    \\successfully — no sidecar runs, so a component that would throw at
    \\render time is still listed.
    \\
    \\No percent-decoding is performed on ROUTE.
    \\
    \\Options:
    \\  --drafts               Include draft pages
    \\  --allow-missing-pages  Tolerate a dangling $link.page/$site.page
    \\                         reference (same semantics as `zigapagos release`)
    \\  --build-asset=NAME PATH [--install=P | --install-always=P]
    \\                         Declare a build asset (see `zigapagos validate
    \\                         --help` for why this is needed)
    \\  --help, -h             Show this help menu
    \\
    \\Exit code: 0 when the route resolved to a working page, 1 on a resolution
    \\miss or a page-level error (the error IS printed as the explanation).
    \\
    \\
;

test "explain: parse accepts exactly one positional route plus the shared flags" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{ "/docs/overview/", "--drafts", "--allow-missing-pages" });
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("/docs/overview/", cmd.route);
    try std.testing.expect(cmd.drafts);
    try std.testing.expect(cmd.allow_missing_pages);
}

test "explain: parse recognizes --build-asset alongside the route" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{ "/", "--build-asset=logo", "assets/logo.svg" });
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("/", cmd.route);
    try std.testing.expectEqualStrings("assets/logo.svg", cmd.build_assets.get("logo").?.input_path);
}

// --- route path guards ---------------------------------------------------

test "explain: hasTraversalSegment rejects . and .. path segments (AUD-013/014)" {
    // Rejected: a `.`/`..` as a whole path segment, at any position.
    try std.testing.expect(hasTraversalSegment("/islands/../../secret/foo.js"));
    try std.testing.expect(hasTraversalSegment("/../etc/passwd"));
    try std.testing.expect(hasTraversalSegment("/a/b/.."));
    try std.testing.expect(hasTraversalSegment(".."));
    try std.testing.expect(hasTraversalSegment("/a/./b")); // a `.` segment too
    // Allowed: `..`/`.` as a SUBSTRING of a real segment is not traversal, so
    // a legitimate filename must not be rejected (no false-positive rejection —
    // AUD-014's `x..y`, `photo..jpg`).
    try std.testing.expect(!hasTraversalSegment("/x..y"));
    try std.testing.expect(!hasTraversalSegment("/img/photo..jpg"));
    try std.testing.expect(!hasTraversalSegment("/islands/Counter.island.js"));
    try std.testing.expect(!hasTraversalSegment("/"));
    try std.testing.expect(!hasTraversalSegment("/a/b/c"));
    // Backslash is also a segment separator for the guard: a `..`/`.` delimited
    // by `\` (which the file-system APIs on non-POSIX platforms honor) must be
    // rejected too, so the guard can't be bypassed with `\`.
    try std.testing.expect(hasTraversalSegment("/islands\\..\\..\\secret.js"));
    try std.testing.expect(hasTraversalSegment("\\..\\etc\\passwd"));
    try std.testing.expect(hasTraversalSegment("/a/b\\.."));
    // …but `..` as a substring of a real segment is still allowed with `\` too.
    try std.testing.expect(!hasTraversalSegment("/img\\photo..jpg"));
}

test "explain: stripPathPrefix only strips at a segment boundary (AUDF: byte-offset rewrite)" {
    // The old `path = path[1 + len ..]` sliced at the prefix's BYTE length, so
    // "/docs../foo" (which has no exact ".." segment, hence passes the traversal
    // guard) was rewritten to "../foo" — a traversal the guard never re-runs on.
    try std.testing.expect(stripPathPrefix("/docs../foo", "docs") == null);
    try std.testing.expect(stripPathPrefix("/docsy/foo", "docs") == null);
    try std.testing.expect(stripPathPrefix("/docs.zip", "docs") == null);

    // Real matches keep their exact previous result.
    try std.testing.expectEqualStrings("/foo", stripPathPrefix("/docs/foo", "docs").?);
    try std.testing.expectEqualStrings("", stripPathPrefix("/docs", "docs").?);
    try std.testing.expectEqualStrings("/", stripPathPrefix("/docs/", "docs").?);
    // A prefix written with a trailing slash strips the same way.
    try std.testing.expectEqualStrings("/foo", stripPathPrefix("/docs/foo", "docs/").?);
    try std.testing.expect(stripPathPrefix("/docs", "docs/") == null);
    // Not under the prefix at all.
    try std.testing.expect(stripPathPrefix("/other/foo", "docs") == null);
    // Empty prefix (the single-variant case) matches everything and only strips
    // the leading '/', exactly like the `path[1..]` it replaces.
    try std.testing.expectEqualStrings("foo/bar", stripPathPrefix("/foo/bar", "").?);
    try std.testing.expectEqualStrings("", stripPathPrefix("/", "").?);
    // A target that is not origin-form has nothing to strip.
    try std.testing.expect(stripPathPrefix("*", "docs") == null);
    try std.testing.expect(stripPathPrefix("", "docs") == null);
}

// --- route normalization (cwd-independent, per (H6): `test-init` runs every
// test reachable from main.zig with cwd = the repo root) -----------------

fn expectCandidates(route: []const u8, expected: []const Candidate) !void {
    var buf: [256]u8 = undefined;
    var out: [2]Candidate = undefined;
    const n = routeCandidates(&buf, route, &out);
    try std.testing.expectEqual(expected.len, n);
    for (expected, out[0..n]) |e, got| {
        try std.testing.expectEqualStrings(e.path, got.path);
        try std.testing.expectEqual(e.ends_with_slash, got.ends_with_slash);
    }
}

test "explain: route resolution maps a trailing-slash route to that directory's index.html" {
    try expectCandidates("/docs/overview/", &.{
        .{ .path = "/docs/overview/index.html", .ends_with_slash = true },
    });
    // The site root is the same rule, not a special case.
    try expectCandidates("/", &.{
        .{ .path = "/index.html", .ends_with_slash = true },
    });
}

test "explain: route resolution retries an extensionless route as a directory index" {
    // The literal route first (it may be a real extensionless output), then
    // the directory-index spelling. Order matters: an exact match wins.
    try expectCandidates("/docs/overview", &.{
        .{ .path = "/docs/overview", .ends_with_slash = false },
        .{ .path = "/docs/overview/index.html", .ends_with_slash = true },
    });
}

// --- emitted-path helper ownership -------------------------------------
//
// These live here rather than in worker.zig because they pin the contract
// THIS file depends on: `printReport` frees every path string it gets back,
// which is only sound because all three helpers are §2.2a contract 1
// (always-owned, no scratch left behind). worker.zig is upstream-inherited,
// so the fork keeps its footprint there to the functions themselves.

// `std.testing.allocator` is the entire point of this test. An earlier cut of
// `mainOutputPath`/`suffixedOutputPath` formatted `pageDir`'s *result*, which
// allocated an intermediate directory string and never freed it: invisible
// under the render arena the emit path passes, a leak under anything else,
// and mislabelled "contract 1" in the doc comment. Restoring that shape makes
// this test fail with a leak. The rooted-suffix case additionally pins
// always-owned-ness: before the fix that branch returned a BORROWED subslice
// of `suffix`, so the `free` below would be a free of memory the allocator
// never handed out.
test "explain: worker's emitted-path helpers are always-owned with no leaked scratch" {
    const gpa = std.testing.allocator;

    var st: StringTable = .empty;
    defer st.deinit(gpa);
    _ = try st.intern(gpa, ""); // the empty string is required by PathTable

    var pt: PathTable = .empty;
    defer pt.deinit(gpa);
    const url = try pt.internPath(gpa, &st, "docs/overview");

    // Only the fields the helpers actually read are initialized. The rest of a
    // real `Variant`/`Page` (an open `Io.Dir`, the page graph, the URL map) is
    // irrelevant to a pure path computation and is left `undefined` rather
    // than faked into something a reader might mistake for a fixture.
    var variant: Variant = undefined;
    variant.string_table = st;
    variant.path_table = pt;
    variant.output_path_prefix = "en";

    var page: Page = undefined;
    page._scan.url = url;

    // The payloads are unread: `urlFmt` branches on the TAG alone, and takes
    // the locale prefix from the variant, not the config.
    const site: root.Config = .{ .Site = undefined };
    const multi: root.Config = .{ .Multilingual = undefined };

    {
        const p = try worker.pageDir(gpa, &site, &variant, &page);
        defer gpa.free(p);
        try std.testing.expectEqualStrings("docs/overview/", p);
    }
    {
        // The locale prefix is the only difference between the config shapes.
        const p = try worker.pageDir(gpa, &multi, &variant, &page);
        defer gpa.free(p);
        try std.testing.expectEqualStrings("en/docs/overview/", p);
    }
    {
        const p = try worker.mainOutputPath(gpa, &site, &variant, &page);
        defer gpa.free(p);
        try std.testing.expectEqualStrings("docs/overview/index.html", p);
    }
    {
        // Joined branch: a relative suffix hangs off the page's own directory.
        const p = try worker.suffixedOutputPath(gpa, &site, &variant, &page, "feed.xml");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("docs/overview/feed.xml", p);
    }
    {
        // Rooted branch: owned too, hence the `free`.
        const p = try worker.suffixedOutputPath(gpa, &site, &variant, &page, "/legacy/old.html");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("legacy/old.html", p);
    }
    {
        // A rooted suffix is declared relative to the SITE root, so it does
        // NOT pick up the locale prefix -- the one behavioural rule that
        // branch encodes, and the reason it cannot just be a joined path.
        const p = try worker.suffixedOutputPath(gpa, &multi, &variant, &page, "/legacy/old.html");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("legacy/old.html", p);
    }
}

test "explain: route resolution takes a route that already names a file at face value" {
    // No directory retry -- "/docs/overview/index.html/index.html" is nonsense.
    try expectCandidates("/docs/overview/index.html", &.{
        .{ .path = "/docs/overview/index.html", .ends_with_slash = false },
    });
    try expectCandidates("/overview.html", &.{
        .{ .path = "/overview.html", .ends_with_slash = false },
    });
    // A dot in a DIRECTORY segment is not an extension on the route.
    try expectCandidates("/v1.2/guide", &.{
        .{ .path = "/v1.2/guide", .ends_with_slash = false },
        .{ .path = "/v1.2/guide/index.html", .ends_with_slash = true },
    });
}
