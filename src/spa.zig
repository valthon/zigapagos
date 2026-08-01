//! Release-time SPA prerender pass.
//!
//! For each declared SPA (`build.spas`, threaded from `build.zig`'s
//! `Options.spas`), this:
//!   1. Asks the render sidecar (`Sidecar.describe`) for the SPA's `spa`
//!      metadata and its declared `routes`.
//!   2. SSRs each route's loading skeleton via the sidecar (`Sidecar.render`
//!      with empty props/slots), wraps it in a static HTML shell that boots
//!      the client router (`@z/runtime`'s `mountSpa`), and writes it to disk:
//!        - static routes  -> `<base>/<route>/index.html`
//!        - dynamic routes -> one `<base>/<pattern-dir>/_shell.html`
//!   3. Writes a per-namespace `<base>/routing-manifest.json` describing the
//!      static/dynamic route map for the host's routing layer (zigbase by
//!      default; see `Site.deploy_target`).
//!   4. Writes a single site-wide `404.html`, reusing the 404-owner SPA's
//!      `/` shell HTML (captured in memory during the loop — no disk
//!      read-back). The owner is the SPA named by `build.zig`'s
//!      `Options.not_found` (threaded through `--spa-not-found=<name>`,
//!      the 404 owner), defaulting to the FIRST declared SPA.
const std = @import("std");
const Build = @import("Build.zig");
const root = @import("root.zig");
const pass = @import("islands/pass.zig");
const sidecar = @import("islands/sidecar.zig");
const fatal = @import("fatal.zig");
const PathName = @import("PathTable.zig").PathName;
const RenderArena = @import("islands/render_arena.zig").RenderArena;
const BuildSummary = @import("summary.zig").Summary;

const log = std.log.scoped(.islands);

/// SSR one SPA route skeleton (props = `{}`, no slots), surfacing the sidecar's
/// STRUCTURED error (JS message + source-mapped stack) attributed to the SPA
/// `src` and route `pathname` before the error propagates. SPA
/// prerender is release-only, so a failure fatals upstream — but now with the
/// real cause in the build log, not a bare `error.SidecarRenderFailed` name.
/// Contract 4 (`RenderArena`, NO_SLOP.md §2.2a): a pass-through of
/// `Sidecar.renderPrefixed`, whose result is a slice into the arena-owned,
/// leak-parsed response line rather than an allocation the caller could free.
///
/// `pathname` must already carry the site's `url_path_prefix` (every caller
/// builds it via `pass.prefixed`) — this is what the sidecar's SSR pass
/// simulates as `location.pathname`. `url_prefix` is the SEPARATE normalized
/// prefix ("" or "/myrepo") threaded to `Sidecar.renderPrefixed`'s `"prefix"`
/// wire field, which composes the client Router's `base` (issue #26). The two
/// must agree — see `prerenderAll`'s `norm_prefix` doc comment.
fn renderSkeleton(
    sc: *sidecar.Sidecar,
    arena: RenderArena,
    src: []const u8,
    pathname: []const u8,
    url_prefix: []const u8,
) ![]const u8 {
    var rerr: sidecar.RenderError = .{};
    return sc.renderPrefixed(arena, src, "{}", "", pathname, url_prefix, &rerr) catch |err| {
        log.err(
            "SPA skeleton SSR failed: {s} (route {s}): {s}\n{s}",
            .{ src, pathname, rerr.message, rerr.stack orelse "(no stack)" },
        );
        return err;
    };
}

/// A resolved route ready to prerender.
const PlannedRoute = struct {
    /// SSR pathname handed to the sidecar (dynamic params replaced with "_").
    ssr_pathname: []const u8,
    /// Output file path relative to the output dir.
    out_path: []const u8,
    /// Manifest URL (static routes) — null for dynamic patterns.
    static_url: ?[]const u8,
    /// Manifest pattern + shell (dynamic) — null for static routes.
    dynamic: ?DynamicEntry,
};

const DynamicEntry = struct { pattern: []const u8, shell: []const u8 };

/// A prerendered route that is backed by a lazily-loaded chunk: its manifest
/// URL and the chunk's URL (`/spa/<chunk>`), recorded for the manifest's
/// per-route `chunks` map.
const ChunkEntry = struct { url: []const u8, chunk: []const u8 };

/// Shape of the driver's `spa-chunks.json` (see `bundle-island.ts` `bundleSpa`).
/// `routeChunks` maps a route's in-app full path (`/heavy`, `/dash/overview`) to
/// the content-hashed chunk file that backs its lazy component. The file's other
/// keys (`entry`, `chunks`) are not read here — the parse sets
/// `ignore_unknown_fields`, so they need no placeholder fields.
const ChunksJson = struct {
    routeChunks: std.json.ArrayHashMap([]const u8) = .{},
};

/// Shape of the per-SPA runtime slice manifest (see `build-spa-runtime.ts`).
/// `runtime` is the sliced runtime URL (`/spa/<name>-runtime.js`) when this SPA
/// got a per-deployable sliced runtime; `fallback` is true when the slicer bailed
/// to the shared `/zigapagos-runtime.js`. When the manifest is absent entirely
/// (hand-written CLI, no slicing), the SPA also uses the shared runtime.
/// The manifest's other keys (e.g. `members`) are not read here — the parse
/// sets `ignore_unknown_fields`, so they need no placeholder fields.
const SliceJson = struct {
    runtime: ?[]const u8 = null,
    fallback: bool = false,
};

/// The runtime URL a SPA's shells should load: the sliced `/spa/<name>-runtime.js`
/// when its slice manifest names one, else the shared runtime.
/// Contract 4 (`RenderArena`): the returned URL is either a static constant or a
/// slice into the leak-parsed slice manifest — never an owned buffer.
fn resolveRuntimeUrl(
    io: std.Io,
    arena: RenderArena,
    slice_json: ?[]const u8,
) ![]const u8 {
    const sj_path = slice_json orelse return pass.shared_runtime_url;
    const data = std.Io.Dir.cwd().readFileAlloc(io, sj_path, arena.a, .limited(1024 * 1024)) catch |err| fatal.file(sj_path, err);
    const parsed = std.json.parseFromSliceLeaky(SliceJson, arena.a, data, .{ .ignore_unknown_fields = true }) catch |err| fatal.msg(
        "error: malformed spa slice manifest '{s}': {s}\n",
        .{ sj_path, @errorName(err) },
    );
    return parsed.runtime orelse pass.shared_runtime_url;
}

/// Delete a stale `spa/<name>-runtime.js` left over from a PREVIOUS build in
/// which this SPA had a per-deployable sliced runtime, now that the
/// CURRENT build's slice decision has flipped to `fallback` (shared runtime).
/// The release step never clears extraneous files (`addInstallDirectory` only
/// copies), so without this the stale sliced bundle would linger in the
/// output dir — missing the compat surface the current shell's import map
/// expects, and a hazard for deploys that sync without deleting first.
/// A no-op when `fallback` is false (still sliced: the file is current, not
/// stale). `error.FileNotFound` (no stale file existed) is not an error;
/// callers only invoke this when a slice manifest WAS provided, so any other
/// failure indicates a real filesystem problem worth failing loudly on.
///
/// A slice built with source maps (`build-spa-runtime.ts --sourcemap`, the
/// release `source_maps` opt-in) installs `<name>-runtime.js.map` alongside the
/// `.js`; on a slice→fallback flip that map is orphaned too, so it is pruned
/// with the same `FileNotFound`-is-success semantics (AUDF-015). A slice built
/// without source maps has no map — hence the missing-file tolerance.
/// NO_SLOP.md §2.2a contract 1: allocates two path strings, frees both, returns
/// nothing — correct under any allocator (its caller happens to pass the
/// prerender arena).
fn deleteStaleSlicedRuntime(io: std.Io, alloc: std.mem.Allocator, out_dir: std.Io.Dir, name: []const u8, fallback: bool) !void {
    if (!fallback) return;
    const rel_paths = [_][]const u8{
        try std.fmt.allocPrint(alloc, "spa/{s}-runtime.js", .{name}),
        try std.fmt.allocPrint(alloc, "spa/{s}-runtime.js.map", .{name}),
    };
    defer for (rel_paths) |rel_path| alloc.free(rel_path);
    for (rel_paths) |rel_path| {
        out_dir.deleteFile(io, rel_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => fatal.msg("error: could not delete stale sliced runtime '{s}': {t}\n", .{ rel_path, err }),
        };
    }
}

/// `collect` is the optional `--summary` inventory (issue #42): non-null only
/// for a `zigapagos release --summary`, and written to beside each `writeFile`
/// below so the report cannot drift from what this pass actually wrote. It is
/// a parameter rather than a field on `*Build` because `root.run` returns its
/// `Build` by value and the collector lives on that function's frame.
pub fn prerenderAll(
    io: std.Io,
    gpa: std.mem.Allocator,
    build: *Build,
    cfg: *const root.Config,
    collect: ?*BuildSummary,
) !void {
    const spa_specs = build.spas;
    if (spa_specs.len == 0) return;
    const sc = &(build.island_sidecar orelse return error.SpaNeedsSidecar);
    const out_dir = build.mode.disk.output_dir;
    const deploy_target = cfg.deployTarget();

    // The universal 404.html reuses the 404-owner SPA's "/" shell HTML,
    // captured in memory while rendering that SPA's routes (documented v1
    // limitation: multi-SPA sites only get ONE 404 fallback). The owner is
    // the SPA named by `--spa-not-found=<name>` — build.zig's
    // `.not_found` option, already validated at configure time; re-checked
    // here so a hand-written CLI invocation fails just as loudly — or the
    // first declared SPA when no name was given (the historical default).
    // `zigapagos release --spa=…` is a first-class entry point, not only
    // `build.zig`'s callee, so the spec-level invariants `build.zig`'s
    // `validateSpas` enforces at CONFIGURE time are re-checked here — the same
    // principle as the `--spa-not-found` re-check just below, so a hand-written
    // CLI invocation fails just as loudly. Two SPAs with overlapping bases
    // write into one namespace (the second's shells AND its
    // routing-manifest.json silently overwrite the first's, since
    // `static_seen`/`out_path_seen` are per-SPA); two SPAs whose `spaName`
    // basenames collide share one `/spa/<name>.js` bundle URL.
    if (findSpecViolation(spa_specs)) |v| switch (v.reason) {
        .base_overlap => fatal.msg(
            "error: spas '{s}' and '{s}' declare overlapping bases ('{s}' and '{s}') — " ++
                "one SPA's namespace must not contain another's, or their shells and " ++
                "routing-manifest.json overwrite each other\n",
            .{ v.first_src, v.second_src, v.first_detail, v.second_detail },
        ),
        .name_collision => fatal.msg(
            "error: spas '{s}' and '{s}' share basename '{s}' — their bundles would collide " ++
                "at /spa/{s}.js. Give them distinct file basenames.\n",
            .{ v.first_src, v.second_src, v.second_detail, v.second_detail },
        ),
    };

    const owner_idx = notFoundOwnerIndex(spa_specs, build.spa_not_found) orelse {
        fatal.msg(
            "error: --spa-not-found names '{s}' but no declared SPA has that " ++
                "name — an SPA's name is its file basename sans .spa.tsx " ++
                "(build.zig: `.not_found` must match one of `.spas`)\n",
            .{build.spa_not_found.?},
        );
    };
    var owner_root_shell: ?[]const u8 = null;

    // The site's `url_path_prefix` (a GitHub project-pages subpath like
    // "myrepo") prefixes every root-relative asset URL the shells bake — the
    // runtime, entry bundle, import map, and lazy chunks — so they resolve under
    // the deployed subpath instead of 404'ing at the domain root (AUDF-005).
    // This is the SPA-shell sibling of the island pass's module-URL prefixing
    // (see `pass.prefixed` / `pass.process`'s `url_prefix`). Multilingual sites
    // don't carry a `url_path_prefix`, so it's empty there (and `prefixed`
    // returns the URL unchanged, keeping non-prefixed output byte-identical).
    const url_path_prefix = switch (cfg.*) {
        .Site => |s| s.url_path_prefix,
        .Multilingual => "",
    };

    for (spa_specs, 0..) |spec, spec_idx| {
        const src = spec.src;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        // This loop body IS the arena-scoped boundary NO_SLOP.md §2.2a contract 4
        // describes: `describe`/`renderSkeleton`/`planRoute` hand back graphs and
        // views that only this arena can reclaim, and it drops per SPA. The
        // contract-1 helpers below (`renderShell`, `renderManifest`, `diskJoin`,
        // …) are reached through `arena.a` and would be correct under any
        // allocator; they simply have no reason to free here.
        const arena = RenderArena.from(&arena_state);

        // Router-base prefix (issue #26): the normalized form of
        // `url_path_prefix` ("" or "/myrepo") that TWO channels must agree on
        // byte-for-byte — the SSR pass, which prefixes each route's
        // `ssr_pathname` below before it reaches the sidecar (so the simulated
        // `location.pathname` matches what a real browser sees under the
        // prefix), and the client Router, which reads the same value back out
        // of `renderShell`'s `data-z-prefix` attribute. `pass.prefixed(.., "")`
        // is the same normalization `bundle_url`/`runtime_url` above already
        // apply to a URL; called on "" it yields exactly the composed base
        // value ("" unprefixed, else a leading-slash, no-trailing-slash form).
        const norm_prefix = try pass.prefixed(arena.a, url_path_prefix, "");

        const desc = try sc.describe(arena, src);
        // Declarative redirects: every `redirect` target must
        // match a route in THIS SPA's table — a miss fails the build here,
        // naming the SPA and entry.
        validateRedirectsOrFatal(src, desc.routes);
        const base = std.mem.trimEnd(u8, desc.spa.base orelse try defaultBase(arena.a, src), "/");
        // Every `base`/route `path` byte below flows into an ON-DISK path
        // (`patternDir`/`joinUrl` → `diskJoin` → `writeFile`'s
        // `createDirPathOpen`), which resolves a `..` segment relative to the
        // output dir — so an unvalidated `..` (e.g. a route path built from
        // data: `"/docs/" ++ slug` with a `../..` slug, or `spa.base =
        // "/../evil"`) writes OUTSIDE the output tree. `staticPaths` entries
        // were already held to this rule (`validateConcretePath`); the declared
        // paths they come from were not.
        validateRoutePathsOrFatal(src, base, desc.routes);
        // Declared-vs-exported base agreement: `spec.base` is the base
        // restated in the consumer's `build.zig` (`Spa.base`), threaded
        // through `--spa=<src>|<base>`; `base` (above) is derived from the
        // module's own `export const spa.base` and is what ACTUALLY drives
        // prerender output below. When a non-empty declared base was
        // provided (an empty one means the `--spa=` value carried no '|' —
        // e.g. a hand-written CLI invocation — so there's nothing to check
        // against), the two must agree or the site's `build.zig` and the
        // SPA's own source have drifted; fail loudly rather than silently
        // prerendering under a base the site author didn't declare.
        if (spec.base.len != 0) {
            const declared = std.mem.trimEnd(u8, spec.base, "/");
            if (!std.mem.eql(u8, declared, base)) fatal.msg(
                "error: spa '{s}' declares base '{s}' in build.zig but exports " ++
                    "spa.base '{s}' — the two must agree.\n",
                .{ src, spec.base, if (base.len == 0) "/" else base },
            );
        }
        // `base` (above) is the trailing-slash-trimmed mount namespace used to
        // build URLs (joinUrl/substituteParams/patternDir all correctly treat
        // "" as "root-mounted", producing single, not doubled, leading
        // slashes). It must NOT be used for on-disk paths: for a root-mounted
        // SPA (declared base "/" or "") it's "", and naively prefixing a
        // disk-relative path with "<base>/" would yield a LEADING "/" (e.g.
        // "/routing-manifest.json"), which `writeFile`'s
        // `createDirPathOpen(io, "/", .{})` resolves from the filesystem
        // root, escaping the output dir. `url_base`/`disk_prefix` below are
        // the two normalized forms each call site actually wants.
        const url_base = if (base.len == 0) "/" else base; // manifest JSON "base" field only
        const disk_prefix = std.mem.trimStart(u8, base, "/"); // "" (root) or e.g. "app"
        const title = desc.spa.title orelse "App";
        const noindex = desc.spa.noindex orelse true;
        const bundle_url = try pass.prefixed(arena.a, url_path_prefix, try std.fmt.allocPrint(arena.a, "/spa/{s}.js", .{spaName(src)}));
        // The runtime this SPA's shells load: its per-deployable sliced runtime
        // when the slice manifest names one, else the shared runtime. The
        // fallback decision is taken on the RAW (un-prefixed) URL — that's the
        // form `resolveRuntimeUrl` compares against `shared_runtime_url` — and
        // the prefix is applied afterwards, so the deletion check below stays
        // correct while the shells still bake the prefixed URL (AUDF-005).
        const runtime_url_raw = try resolveRuntimeUrl(io, arena, spec.slice_json);
        const runtime_is_fallback = std.mem.eql(u8, runtime_url_raw, pass.shared_runtime_url);
        const runtime_url = try pass.prefixed(arena.a, url_path_prefix, runtime_url_raw);
        // Symptom B: when a slice manifest WAS provided but resolved
        // to the shared runtime (the slicer bailed to fallback), any sliced
        // runtime installed by a PREVIOUS build under this SPA's name is now
        // stale — remove it. Runs before this build's install steps, which
        // install nothing under this name when the decision is fallback, so
        // the deletion sticks. A manifest-less invocation (`slice_json ==
        // null`, e.g. hand-written CLI) never had a sliced runtime to begin
        // with, so there's nothing to clean up.
        if (spec.slice_json != null) {
            try deleteStaleSlicedRuntime(io, arena.a, out_dir, spaName(src), runtime_is_fallback);
        }

        // Lazy-route → chunk map from the driver's spa-chunks.json (if any). Used
        // to preload each lazy route's chunk in its shell + list it in the
        // manifest. Absent for hand-written CLI invocations (no chunk map).
        const route_chunks: ?std.json.ArrayHashMap([]const u8) = if (spec.chunks_json) |cj_path| blk: {
            const data = std.Io.Dir.cwd().readFileAlloc(io, cj_path, arena.a, .limited(4 * 1024 * 1024)) catch |err| fatal.file(cj_path, err);
            const parsed = std.json.parseFromSliceLeaky(ChunksJson, arena.a, data, .{ .ignore_unknown_fields = true }) catch |err| fatal.msg(
                "error: malformed spa-chunks.json '{s}': {s}\n",
                .{ cj_path, @errorName(err) },
            );
            break :blk parsed.routeChunks;
        } else null;

        // The `spa.head` hook is shared across every route of
        // this SPA, so validate it once here rather than per-route in `renderShell`
        // — this is the one place with both the offending attribute name AND the
        // SPA's `src`, so it can fatal with a message the site author can act on.
        // `renderHeadLinks`/`renderShell` still re-validate (see their doc
        // comments) as a defense-in-depth, testable error path.
        //
        // The `spa.head` entries this SPA's shells actually render. Identical
        // to `desc.spa.head` unless `asset_fingerprint` is on AND some href
        // names a fingerprinted site asset, in which case that entry's href is
        // rewritten to the installed (hashed) name below — a shell linking
        // `/site.css` while the install pass wrote `/site.a1b2c3d4.css` is the
        // same silent-404 the surrounding staging check exists to prevent.
        // Rebound rather than mutated in place so a build with the feature off
        // reuses the parsed slice untouched and emits byte-identical shells.
        var head_for_shell = desc.spa.head;

        if (desc.spa.head) |head| {
            // Local head assets: a root-relative `href` (e.g.
            // "/site.css") that nothing installs is a silent-404 foot-gun —
            // the shell links it, the build succeeds, the page renders
            // unstyled. So, per entry: (1) a matching file in the assets dir
            // is STAGED automatically (same mechanics as a `static_assets`
            // entry — rc > 0 makes the install phase, which runs after this
            // pass, copy it); (2) a declared build asset installing that path
            // is rc'd for the same reason; (3) otherwise the build FAILS,
            // naming the SPA and the href. External/relative hrefs are
            // skipped (`headHrefAssetPath` returns null), and a site's
            // `url_path_prefix` (hoisted above the SPA loop) is stripped from
            // prefixed hrefs first.
            // Allocated (and `head_for_shell` repointed at it) only on the
            // first entry that actually needs a rewritten href, so the common
            // case costs nothing.
            var rewritten: ?[]std.json.ArrayHashMap([]const u8) = null;

            for (head, 0..) |entry, entry_idx| {
                var it = entry.map.iterator();
                while (it.next()) |kv| {
                    if (!isValidHeadAttrName(kv.key_ptr.*)) fatal.msg(
                        "error: spa '{s}' exports a spa.head entry with an invalid attribute " ++
                            "name '{s}' (must match [a-zA-Z][a-zA-Z0-9-]*)\n",
                        .{ src, kv.key_ptr.* },
                    );
                }

                const href = entry.map.get("href") orelse continue;
                const rel_path = headHrefAssetPath(href, url_path_prefix) orelse continue;
                if (PathName.get(&build.st, &build.pt, rel_path)) |pn| {
                    if (build.site_assets.getPtr(pn)) |rc| {
                        _ = rc.fetchAdd(1, .acq_rel);
                        if (build.asset_fingerprints.get(pn)) |hashed| {
                            const slice = rewritten orelse blk: {
                                const s = try arena.a.dupe(std.json.ArrayHashMap([]const u8), head);
                                rewritten = s;
                                head_for_shell = s;
                                break :blk s;
                            };
                            // Clone the entry's map before touching it: the
                            // parsed `desc` is shared with the manifest/serve
                            // paths, and mutating it in place would leak a
                            // release-only rewrite into them.
                            var map = try entry.map.clone(arena.a);
                            try map.put(
                                arena.a,
                                "href",
                                try fingerprintedHref(arena.a, href, hashed),
                            );
                            slice[entry_idx] = .{ .map = map };
                        }
                        continue;
                    }
                }
                if (findBuildAssetByInstallPath(build.build_assets, rel_path)) |ba| {
                    _ = ba.rc.fetchAdd(1, .acq_rel);
                    continue;
                }
                fatal.msg(
                    "error: spa '{s}' head references '{s}' but nothing installs it — " ++
                        "no file '{s}' in the assets dir and no build asset with that " ++
                        "install path. Add the file under the assets dir (spa.head stages " ++
                        "it automatically) or declare a build asset installing '{s}'.\n",
                    .{ src, href, rel_path, rel_path },
                );
            }
        } else {
            // issue #24: a SPA shell's <head> is fixed (import map,
            // modulepreloads, boot script) — site stylesheets are NOT
            // inherited, and `spa.head` is the documented, build-checked way
            // to add one. `head: []` (this branch requires `head == null`, so
            // an explicit empty slice never lands here) is the self-documenting
            // opt-out for a SPA that legitimately styles itself another way
            // (inline styles / CSS-in-JS — NOT CSS-in-bundle: `bundle-island.ts`
            // writes only the entry chunk, so a `.css` import's output is
            // dropped). Only worth the noise when the site actually HAS a
            // stylesheet for this SPA to be missing.
            var css_paths: std.ArrayList([]const u8) = .empty;
            var asset_it = build.site_assets.iterator();
            var asset_name_buf: [std.fs.max_path_bytes]u8 = undefined;
            while (asset_it.next()) |asset_entry| {
                const asset_path = std.fmt.bufPrint(&asset_name_buf, "{f}", .{
                    asset_entry.key_ptr.fmt(&build.st, &build.pt, null, "/"),
                }) catch continue;
                if (std.mem.endsWith(u8, asset_path, ".css")) {
                    try css_paths.append(arena.a, try arena.a.dupe(u8, asset_path));
                }
            }
            if (spaHeadWarningAsset(desc.spa.head, css_paths.items)) |example| {
                std.debug.print(
                    "warning: spa '{s}' declares no spa.head, but the site has stylesheet assets " ++
                        "(e.g. '/{s}') — SPA shells have a fixed <head> and do not inherit site " ++
                        "styles, so this SPA's routes will render unstyled. Add a stylesheet to " ++
                        "`export const spa` (head: [{{ rel: \"stylesheet\", href: \"/{s}\" }}]), " ++
                        "or set head: [] to declare the SPA intentionally loads no head links.\n",
                    .{ src, example, example },
                );
            }
        }

        var static_urls: std.ArrayList([]const u8) = .empty;
        var dynamics: std.ArrayList(DynamicEntry) = .empty;
        var chunk_entries: std.ArrayList(ChunkEntry) = .empty;
        // Per-SPA dedup/collision check: every static_url planned
        // below (declared static route or staticPaths concrete entry) is
        // claimed here first, so a duplicate/collision fatals loudly instead
        // of silently double-writing the same output file.
        var static_seen: StaticUrlSeen = .empty;
        // Per-SPA dedup/collision check over the OUTPUT FILE each route writes
        // — the disk-space counterpart of `static_seen`'s URL space. Two
        // dynamic routes sharing a static prefix ("/club/:id" and
        // "/club/:id/details") plan the SAME `_shell.html`; see
        // `claimOutPathOrFatal`.
        var out_path_seen: OutPathSeen = .empty;
        // Whether some route actually wrote `<base>/index.html` — the file the
        // manifest's `fallback` points at. Tracked (rather than assumed) so the
        // manifest can never name a file this pass did not write; see
        // `chooseFallback`.
        const root_index_path = try diskJoin(arena.a, disk_prefix, "index.html");
        var has_root_index = false;

        for (desc.routes) |rt| {
            const planned = try planRoute(arena, base, rt);
            if (std.mem.eql(u8, planned.out_path, root_index_path)) has_root_index = true;
            // A lazy route's chunk URL (`/spa/<chunk>`), matched by the route's
            // in-app full path — preloaded in the shell so it fetches alongside.
            const chunk_url: ?[]const u8 = if (route_chunks) |rc|
                (if (rc.map.get(rt.path)) |c| try pass.prefixed(arena.a, url_path_prefix, try std.fmt.allocPrint(arena.a, "/spa/{s}", .{c})) else null)
            else
                null;
            if (planned.static_url) |u| try claimStaticUrlOrFatal(arena.a, &static_seen, src, u, rt.path);
            try claimOutPathOrFatal(arena.a, &out_path_seen, src, planned.out_path, rt.path);
            // SSR the skeleton via the shared sidecar (props = {}, no slots).
            // The pathname handed to the sidecar carries the prefix (matching a
            // real browser's location.pathname); norm_prefix is the separate
            // value the client Router composes its base from (issue #26).
            const prefixed_pathname = try pass.prefixed(arena.a, url_path_prefix, planned.ssr_pathname);
            const skeleton = try renderSkeleton(sc, arena, src, prefixed_pathname, norm_prefix);
            const html = try renderShell(arena.a, title, noindex, bundle_url, runtime_url, chunk_url, norm_prefix, head_for_shell, desc.spa.flags, skeleton);
            try writeFile(io, out_dir, planned.out_path, html);
            if (collect) |sm| try sm.add(gpa, .spa_shell, planned.out_path);
            if (planned.static_url) |u| {
                try static_urls.append(arena.a, u);
                if (chunk_url) |cu| try chunk_entries.append(arena.a, .{ .url = u, .chunk = cu });
            }
            if (planned.dynamic) |d| try dynamics.append(arena.a, d);

            if (spec_idx == owner_idx and owner_root_shell == null and std.mem.eql(u8, rt.path, "/")) {
                owner_root_shell = try gpa.dupe(u8, html);
            }

            // staticPaths (Astro getStaticPaths parity): each enumerated
            // concrete path prerenders as a REAL static page, planned by the
            // same planRoute path as a hand-declared static route — the
            // pattern's _shell.html (written above) stays the fallback for
            // every non-enumerated param. Exact-match static entries are
            // listed in the manifest's `static` array, which every deploy
            // target consults before the dynamic pattern list.
            if (rt.staticPaths) |concrete_paths| {
                for (concrete_paths) |cp| {
                    if (!validateConcretePath(cp)) fatal.msg(
                        "error: spa '{s}' route '{s}' staticPaths produced an invalid concrete path '{s}'\n",
                        .{ src, rt.path, cp },
                    );
                    const planned_c = try planRoute(arena, base, .{ .path = cp, .dynamic = false, .hasSkeleton = rt.hasSkeleton });
                    const u = planned_c.static_url.?;
                    try claimStaticUrlOrFatal(arena.a, &static_seen, src, u, rt.path);
                    try claimOutPathOrFatal(arena.a, &out_path_seen, src, planned_c.out_path, rt.path);
                    if (std.mem.eql(u8, planned_c.out_path, root_index_path)) has_root_index = true;
                    const prefixed_pathname_c = try pass.prefixed(arena.a, url_path_prefix, planned_c.ssr_pathname);
                    const skeleton_c = try renderSkeleton(sc, arena, src, prefixed_pathname_c, norm_prefix);
                    const html_c = try renderShell(arena.a, title, noindex, bundle_url, runtime_url, chunk_url, norm_prefix, head_for_shell, desc.spa.flags, skeleton_c);
                    try writeFile(io, out_dir, planned_c.out_path, html_c);
                    if (collect) |sm| try sm.add(gpa, .spa_shell, planned_c.out_path);
                    try static_urls.append(arena.a, u);
                    // A lazy pattern route's chunk backs its concrete pages too.
                    if (chunk_url) |cu| try chunk_entries.append(arena.a, .{ .url = u, .chunk = cu });
                }
            }
        }

        // fallback = the namespace shell (the "/" route's index.html) — but
        // only when a route actually produced it; see `chooseFallback` for why
        // naming a missing file is worse than a 404.
        const fallback = (try chooseFallback(arena.a, base, has_root_index, dynamics.items)) orelse fatal.msg(
            "error: spa '{s}' declares neither a \"/\" route nor any dynamic route, so nothing " ++
                "prerenders a shell for an unmatched URL — its routing manifest would name a " ++
                "'fallback' file that does not exist ('{s}/index.html'), which a host turns into " ++
                "a server error rather than a 404 (nginx `try_files` with a missing final " ++
                "argument returns 500). Declare a \"/\" route (or a catch-all '/*' route).\n",
            .{ src, base },
        );

        const manifest = try renderManifest(arena.a, url_base, static_urls.items, dynamics.items, chunk_entries.items, fallback, bundle_url, deploy_target, norm_prefix);
        const manifest_path = try diskJoin(arena.a, disk_prefix, "routing-manifest.json");
        try writeFile(io, out_dir, manifest_path, manifest);
        if (collect) |sm| try sm.add(gpa, .spa_manifest, manifest_path);
    }

    // Universal 404 fallback = the 404-owner SPA's "/" shell, captured above
    // (no disk read-back needed).
    if (owner_root_shell) |shell| {
        defer gpa.free(shell);
        try writeFile(io, out_dir, "404.html", shell);
        if (collect) |sm| try sm.add(gpa, .spa_fallback, "404.html");
    } else {
        std.log.warn(
            "spa: skipping 404.html — the 404-owner SPA ({s}) has no \"/\" route",
            .{spa_specs[owner_idx].src},
        );
    }
}

/// Index (into `specs`) of the SPA whose "/" shell backs the universal
/// 404.html: the one named by `not_found` — matched against
/// `spaName(src)`, the same name that keys `/spa/<name>.js` — or the FIRST
/// declared SPA when `not_found` is null (the historical default). Returns
/// null when a non-null name matches no spec; the caller turns that into a
/// site-author-actionable fatal error (same plain-helper/fatal-caller split
/// as `claimStaticUrl` below).
fn notFoundOwnerIndex(specs: []const root.SpaSpec, not_found: ?[]const u8) ?usize {
    const name = not_found orelse return 0;
    for (specs, 0..) |s, i| {
        if (std.mem.eql(u8, spaName(s.src), name)) return i;
    }
    return null;
}

/// A pair of declared SPAs that cannot coexist in one build: their bases
/// overlap (one namespace contains the other) or their `spaName` basenames
/// collide. `first_detail`/`second_detail` are the two offending bases, or —
/// for a name collision — the shared basename in both.
const SpecViolation = struct {
    first_src: []const u8,
    second_src: []const u8,
    first_detail: []const u8,
    second_detail: []const u8,
    reason: enum { base_overlap, name_collision },
};

/// Scan declared SPA specs for the FIRST pair that cannot coexist, or null
/// when they are all disjoint. Mirrors `build.zig`'s configure-time
/// `validateSpas` (the two checks that survive into the CLI: base overlap and
/// basename collision) so `zigapagos release --spa=…` rejects what `build.zig`
/// rejects. A plain unit-testable helper — the caller adds the fatal message
/// (same split as `claimStaticUrl`/`findRedirectViolation`).
///
/// Bases here are the DECLARED ones (`--spa=<src>|<base>`). A spec whose
/// `--spa=` value carried no '|' has an empty declared base — "unknown", not
/// "root" — and is skipped by the overlap check; its exported base is still
/// checked for traversal (`validateRoutePathsOrFatal`) and, when a base WAS
/// declared, for agreement with it.
fn findSpecViolation(specs: []const root.SpaSpec) ?SpecViolation {
    for (specs, 0..) |s, i| {
        for (specs[0..i]) |p| {
            if (s.base.len == 0 or p.base.len == 0) continue;
            if (basesOverlap(std.mem.trimEnd(u8, s.base, "/"), std.mem.trimEnd(u8, p.base, "/"))) return .{
                .first_src = p.src,
                .second_src = s.src,
                .first_detail = p.base,
                .second_detail = s.base,
                .reason = .base_overlap,
            };
        }
        const name = spaName(s.src);
        for (specs[0..i]) |p| {
            if (std.mem.eql(u8, spaName(p.src), name)) return .{
                .first_src = p.src,
                .second_src = s.src,
                .first_detail = name,
                .second_detail = name,
                .reason = .name_collision,
            };
        }
    }
    return null;
}

/// True when two trailing-slash-trimmed SPA bases claim overlapping URL space:
/// equal, or one a path-segment prefix of the other (`/app` vs `/app/admin`).
/// A root-mounted base trims to "" and owns every path, so it overlaps every
/// other absolute base — which falls out of the segment-prefix test, since a
/// non-empty base starts with '/'.
fn basesOverlap(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (a.len > b.len and std.mem.startsWith(u8, a, b) and a[b.len] == '/') return true;
    if (b.len > a.len and std.mem.startsWith(u8, b, a) and b[a.len] == '/') return true;
    return false;
}

/// The manifest's `fallback`: the file a host serves for any in-namespace URL
/// that matches no static page or dynamic pattern. It MUST be a file this pass
/// actually wrote — a manifest naming a missing file is worse than a 404: with
/// `deploy_target = nginx` it becomes `try_files $uri $uri/ <missing>`, and
/// nginx answers an unmatched URL with a 500 internal error.
///
/// So: the "/" route's `<base>/index.html` when some route produced it
/// (`has_root_index`), else the FIRST dynamic route's `_shell.html` — a real
/// file that boots the same SPA, whose client router then renders the actual
/// route (a momentarily wrong loading skeleton, versus a 500). Null when the
/// SPA has neither, which the caller turns into a build error: nothing this
/// pass wrote can serve an unmatched URL.
/// Contract 1: both non-null returns are owned (the dynamic case dupes
/// `dynamics[0].shell` rather than borrowing it), so a caller frees either
/// unconditionally.
fn chooseFallback(
    alloc: std.mem.Allocator,
    base: []const u8,
    has_root_index: bool,
    dynamics: []const DynamicEntry,
) !?[]const u8 {
    if (has_root_index) return try std.fmt.allocPrint(alloc, "{s}/index.html", .{base});
    if (dynamics.len != 0) return try alloc.dupe(u8, dynamics[0].shell);
    return null;
}

/// Join a disk-relative mount prefix (never starting with "/"; "" means
/// "output dir root") with a relative path, inserting a "/" separator only
/// when the prefix is non-empty. Keeps on-disk output paths from ever
/// starting with "/" — which `writeFile` would otherwise resolve from the
/// filesystem root via `createDirPathOpen`, escaping the output dir.
/// Contract 1: always an owned buffer — the empty-prefix case dupes `rest`
/// instead of borrowing it, so the caller frees unconditionally.
fn diskJoin(alloc: std.mem.Allocator, prefix: []const u8, rest: []const u8) ![]const u8 {
    if (prefix.len == 0) return alloc.dupe(u8, rest);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, rest });
}

/// NO_SLOP.md §2.2a contract 4 (`RenderArena`): a `PlannedRoute` is four or five
/// separate string allocations with no `deinit`, and they are not independent —
/// `out_path` is derived from `dir`, `static_url` is retained in the manifest's
/// `static` array and in `chunk_entries` (1). Freeing them one route at a time
/// is impossible anyway: every field stays
/// live until the manifest is serialized at the end of the SPA's pass (2), which
/// is exactly when the arena drops (3).
fn planRoute(arena: RenderArena, base: []const u8, rt: sidecar.RouteMeta) !PlannedRoute {
    // Build the SSR pathname: base + route.path with :seg / * replaced by "_".
    // `substituteParams`/`joinUrl`/`patternDir`/`diskJoin` are contract 1, reached
    // through `.a`; this function is what makes their results a graph.
    const ssr = try substituteParams(arena.a, base, rt.path);
    if (!rt.dynamic) {
        const url = try joinUrl(arena.a, base, rt.path, true); // trailing slash
        const out_path = try std.fmt.allocPrint(arena.a, "{s}index.html", .{std.mem.trimStart(u8, url, "/")});
        return .{ .ssr_pathname = ssr, .out_path = out_path, .static_url = url, .dynamic = null };
    }
    // dynamic: one _shell.html at the pattern's static prefix dir.
    const dir = try patternDir(arena.a, base, rt.path); // e.g. "/app/club" for "/club/:id"
    const shell = try std.fmt.allocPrint(arena.a, "{s}/_shell.html", .{dir});
    // On-disk path is `dir` minus its leading "/". For a root-mounted SPA whose
    // first route segment is dynamic (`/:x`, `/*`), `patternDir` returns "" —
    // the disk path must then be the bare "_shell.html" with NO leading slash;
    // `"{s}/_shell.html"` on an empty prefix would yield "/_shell.html", which
    // `writeFile`'s `createDirPathOpen(io, "/", …)` resolves from the filesystem
    // root, escaping the output dir (AUDF-001). `diskJoin` inserts the "/"
    // separator only when the prefix is non-empty.
    const out_path = try diskJoin(arena.a, std.mem.trimStart(u8, dir, "/"), "_shell.html");
    const pattern = try std.fmt.allocPrint(arena.a, "{s}{s}", .{ base, rt.path });
    return .{ .ssr_pathname = ssr, .out_path = out_path, .static_url = null, .dynamic = .{ .pattern = pattern, .shell = shell } };
}

/// Render the `data-z-flags` JSON data block: the SPA's declared
/// build-time flag defaults, shaped exactly like the /api/flags/state payload
/// (`{"flags":{…},"experiments":{}}`) so the runtime seeds its flags store
/// from it verbatim before hydration (`seedFlagsFromShell`). Returns "" when
/// the SPA declares no flags (or an empty map) — the shell stays
/// byte-identical to one built before flag defaults existed.
///
/// A `type="application/json"` script is a DATA BLOCK, never executed, so it
/// needs no strict-CSP `script-src` hash — emit-host-config's
/// `isHashableInlineScript` already excludes it, exactly like the existing
/// `data-z-props`/`data-z-slots` blocks. Flag names are JSON-encoded and `</`
/// is escaped to `<\/` (`pass.escapeScriptContent`) so a pathological name
/// can't close the script element early. Emission follows the author's
/// declaration order (`std.json.ArrayHashMap` preserves JSON key order), so
/// shell bytes stay deterministic.
/// Contract 1: the raw JSON and the escaped copy are freed here; exactly one
/// buffer escapes (or `""`, a zero-length free).
fn renderFlagsSnapshot(alloc: std.mem.Allocator, flags: ?std.json.ArrayHashMap(bool)) ![]const u8 {
    const f = flags orelse return "";
    if (f.map.count() == 0) return "";
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"flags\":{");
    var it = f.map.iterator();
    var i: usize = 0;
    while (it.next()) |kv| : (i += 1) {
        if (i != 0) try w.writeAll(",");
        try std.json.Stringify.value(kv.key_ptr.*, .{}, w);
        try w.writeAll(if (kv.value_ptr.*) ":true" else ":false");
    }
    try w.writeAll("},\"experiments\":{}}");
    const json = try pass.escapeScriptContent(alloc, aw.written());
    defer alloc.free(json);
    return std.fmt.allocPrint(alloc, "<script type=\"application/json\" data-z-flags>{s}</script>", .{json});
}

/// NO_SLOP.md §2.2a contract 1: every fragment below is scratch that is copied
/// into the final `allocPrint` and then freed here, so exactly one allocation
/// escapes and this is correct under any allocator — the prerender arena its
/// callers pass is a convenience, not a requirement. (`""` fragments are
/// zero-length, which `Allocator.free` short-circuits, so the optional ones need
/// no branch.) `robots` is a static literal and is never freed.
fn renderShell(alloc: std.mem.Allocator, title: []const u8, noindex: bool, bundle_url: []const u8, runtime_url: []const u8, chunk_url: ?[]const u8, url_prefix: []const u8, head: ?[]const std.json.ArrayHashMap([]const u8), flags: ?std.json.ArrayHashMap(bool), skeleton: []const u8) ![]u8 {
    const robots = if (noindex) "<meta name=\"robots\" content=\"noindex\">" else "";
    const escaped_title = try escapeHtml(alloc, title);
    defer alloc.free(escaped_title);
    // A lazy route's chunk preloads right after the entry bundle so it fetches
    // in parallel with the shell (the router loads it post-hydration). Empty for
    // routes with no lazy chunk.
    const chunk_preload = if (chunk_url) |cu|
        try std.fmt.allocPrint(alloc, "<link rel=\"modulepreload\" href=\"{s}\">", .{cu})
    else
        "";
    defer alloc.free(chunk_preload);
    // Router base prefix (issue #26): `url_prefix` is the same normalized
    // value ("" or "/myrepo") baked into `bundle_url`/`runtime_url` above and
    // sent to the sidecar as the SSR pass's `"prefix"` field — carried here so
    // `@z/runtime`'s `mountSpa` (see runtime/src/router.ts) composes the SAME
    // Router `base` a real browser would see under the prefix. Preact's
    // `hydrate()` does not diff element attributes, so a wrong `<a href>`
    // baked at SSR time sticks in the DOM forever — the client and the SSR
    // pass must agree byte-for-byte, and this attribute is how they do.
    // "" (the common case) emits nothing: an unprefixed shell must stay
    // byte-identical to one built before this field existed.
    const prefix_attr = if (url_prefix.len != 0) blk: {
        const escaped_prefix = try escapeHtml(alloc, url_prefix);
        defer alloc.free(escaped_prefix);
        break :blk try std.fmt.allocPrint(alloc, " data-z-prefix=\"{s}\"", .{escaped_prefix});
    } else "";
    defer alloc.free(prefix_attr);
    // The runtime tags (preload/import-map/script) point at `runtime_url` — the
    // shared /zigapagos-runtime.js by default, or this SPA's per-deployable sliced
    // runtime. For the shared URL these reproduce pass's constants exactly.
    const rt_preload = try pass.runtimePreloadFor(alloc, runtime_url);
    defer alloc.free(rt_preload);
    const rt_import_map = try pass.importMapFor(alloc, runtime_url);
    defer alloc.free(rt_import_map);
    const rt_script = try pass.runtimeScriptFor(alloc, runtime_url);
    defer alloc.free(rt_script);
    // The site author's `spa.head` hook: "" when absent/empty, so
    // this changes not one byte of a shell that doesn't use it.
    const head_links = try renderHeadLinks(alloc, head);
    defer alloc.free(head_links);
    // Baked flag defaults: "" when the SPA declares no flags.
    const flags_snapshot = try renderFlagsSnapshot(alloc, flags);
    defer alloc.free(flags_snapshot);
    // Per the import-maps spec, a map is only processed if it appears before
    // any module loading starts, and a <link rel="modulepreload"> (or a module
    // <script>) starts one — so `import_map` must precede every preload/script
    // tag below. A later map is silently disregarded by the browser (cache-state
    // flaky: a cold cache usually loses the race, a warm one wins it and breaks).
    // `head_links` rides right after the map for the same reason: it may itself
    // contain a stylesheet/preconnect `<link>`, which the spec treats the same way.
    return std.fmt.allocPrint(alloc, "<!DOCTYPE html><html><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<title>{[title]s}</title>{[robots]s}" ++
        "{[import_map]s}" ++
        "{[head_links]s}" ++ // spa.head hook (empty when absent)
        "{[flags_snapshot]s}" ++ // data-z-flags baked defaults (empty when absent)
        "{[rt_preload]s}" ++
        "<link rel=\"modulepreload\" href=\"{[bundle]s}\">" ++
        "{[chunk_preload]s}" ++ // per-route lazy chunk preload (may be empty)
        "{[rt_script]s}" ++
        "<script type=\"module\">import*as m from\"{[bundle]s}\";import{{mountSpa}}from\"@z/runtime\";mountSpa(m.default,\"#z-spa-root\",m);</script>" ++
        "</head><body><div id=\"z-spa-root\" data-z-spa{[prefix_attr]s}>{[skeleton]s}</div></body></html>", .{
        .title = escaped_title,
        .robots = robots,
        .rt_preload = rt_preload,
        .bundle = bundle_url,
        .chunk_preload = chunk_preload,
        .import_map = rt_import_map,
        .head_links = head_links,
        .flags_snapshot = flags_snapshot,
        .rt_script = rt_script,
        .prefix_attr = prefix_attr,
        .skeleton = skeleton,
    });
}

/// A literal HTML attribute name: `[a-zA-Z][a-zA-Z0-9-]*`. Kept as a plain
/// predicate (rather than folded into `renderHeadLinks`'s error path) so it's
/// directly unit-testable without exercising `fatal.msg`, which exits the
/// process and can't run inside a test.
fn isValidHeadAttrName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

/// Render a SPA's `spa.head` entries as `<link>` tags, one per
/// entry, in declaration order — `std.json.ArrayHashMap` preserves the
/// attribute order within each entry too. Attribute values are HTML-escaped
/// with `escapeHtml`. Absent or empty `head` renders as "" (byte-identical
/// shell to a SPA with no `head` field at all).
///
/// Attribute NAMES are validated with `isValidHeadAttrName`; an invalid one
/// returns `error.InvalidHeadAttrName` rather than emitting broken markup.
/// This function stays a plain error-returning helper (not a `fatal.msg`
/// call) so it's unit-testable — `prerenderAll`, which knows the offending
/// SPA's `src`, turns this into a site-author-actionable fatal error.
/// Contract 1: each escaped attribute value is copied in and freed, and the one
/// escaping allocation is the returned tag block (`""` when there is no `head`).
fn renderHeadLinks(alloc: std.mem.Allocator, head: ?[]const std.json.ArrayHashMap([]const u8)) ![]const u8 {
    const entries = head orelse return "";
    if (entries.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (entries) |entry| {
        try out.appendSlice(alloc, "<link");
        var it = entry.map.iterator();
        while (it.next()) |kv| {
            if (!isValidHeadAttrName(kv.key_ptr.*)) return error.InvalidHeadAttrName;
            try out.appendSlice(alloc, " ");
            try out.appendSlice(alloc, kv.key_ptr.*);
            try out.appendSlice(alloc, "=\"");
            const escaped = try escapeHtml(alloc, kv.value_ptr.*);
            defer alloc.free(escaped);
            try out.appendSlice(alloc, escaped);
            try out.appendSlice(alloc, "\"");
        }
        try out.appendSlice(alloc, ">");
    }
    return out.toOwnedSlice(alloc);
}

/// Map a `spa.head` entry's `href` to its assets-dir-relative path (issue
/// or null when the href names no local file: external (`https://…`),
/// protocol-relative (`//…`), relative (`site.css` — spa.head hrefs are
/// URL paths, not file paths), bare `/`, or empty. A query/fragment is not
/// part of the on-disk path and is stripped.
///
/// `url_path_prefix` (zigapagos.ziggy) is stripped when the href carries it,
/// at a segment boundary: on a prefixed site (e.g. a GitHub Pages project
/// site served under `/zigapagos/`) the correct served URL for an asset
/// installed at the output root is `/<prefix>/<asset>`. The returned slice
/// aliases `href` — no allocation.
fn headHrefAssetPath(href: []const u8, url_path_prefix: []const u8) ?[]const u8 {
    if (href.len < 2 or href[0] != '/') return null;
    if (href[1] == '/') return null; // protocol-relative → external
    var rest = href[1..];
    if (std.mem.indexOfAny(u8, rest, "?#")) |i| rest = rest[0..i];
    const prefix = std.mem.trim(u8, url_path_prefix, "/");
    if (prefix.len != 0 and std.mem.startsWith(u8, rest, prefix)) {
        if (rest.len == prefix.len) return null; // href IS the prefix dir
        if (rest[prefix.len] == '/') rest = rest[prefix.len + 1 ..];
    }
    if (rest.len == 0) return null;
    return rest;
}

/// Rewrite a `spa.head` href so its final path segment is `hashed` — the
/// content-fingerprinted basename the install pass will actually write (issue
/// #53). `/css/site.css` + `site.a1b2c3d4.css` → `/css/site.a1b2c3d4.css`.
///
/// Operates on the href rather than rebuilding one from the `PathName`,
/// because the href carries two things the `PathName` does not: the site's
/// `url_path_prefix` (which `headHrefAssetPath` strips before the lookup) and
/// any `?query`/`#fragment` the author wrote. Both have to survive, so the
/// substitution is scoped to the last segment of the path portion only.
///
/// `href` always starts with `/` here (`headHrefAssetPath` returned non-null
/// for it, and that requires a leading slash), so the `lastIndexOfScalar`
/// below cannot fail; the `orelse 0` is a belt-and-braces fallback rather than
/// a reachable branch.
///
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1). One
/// allocation, and it is the return value.
fn fingerprintedHref(
    alloc: std.mem.Allocator,
    href: []const u8,
    hashed: []const u8,
) ![]const u8 {
    const cut = std.mem.indexOfAny(u8, href, "?#") orelse href.len;
    const path = href[0..cut];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
        path[0 .. slash + 1],
        hashed,
        href[cut..],
    });
}

/// Find a declared build asset whose `install_path` claims `rel_path`
/// (leading-slash-insensitively — `build.zig` authors spell install paths
/// both ways, and the installer trims the leading "/" before writing).
/// Returns a mutable pointer so the caller can rc the asset: build assets
/// only install when referenced, and a `spa.head` href IS a reference.
fn findBuildAssetByInstallPath(
    build_assets: *const std.StringArrayHashMapUnmanaged(root.BuildAsset),
    rel_path: []const u8,
) ?*root.BuildAsset {
    for (build_assets.values()) |*ba| {
        const install = ba.install_path orelse continue;
        if (std.mem.eql(u8, std.mem.trimStart(u8, install, "/"), rel_path)) return ba;
    }
    return null;
}

/// Decide whether `prerenderAll` should print the "no spa.head but the site
/// has stylesheets" warning (issue #24) for one SPA, and, if so, which asset
/// path to cite as the actionable `e.g.` example.
///
/// Gated on BOTH: `head` is absent entirely (`null`) — `head: []` (the
/// documented opt-out for a SPA that styles itself another way) and any
/// non-empty `head` (even preconnect-only: the author clearly knows the hook)
/// stay silent; AND `asset_paths` (already-formatted site-asset path strings —
/// see the call site's `PathName.fmt`, matching `src/root.zig`'s convention)
/// contains at least one path ending in ".css" — a CSS-less site has nothing
/// for this SPA to be missing.
///
/// The cited example is the LEXICOGRAPHICALLY SMALLEST ".css" path in
/// `asset_paths`. `build.site_assets` is a hash map, so as-found iteration
/// order is arbitrary; naming the "first found" file would make the warning
/// text vary between two otherwise-identical builds, which this repo does not
/// accept from build output (see the snapshot tests). Lexicographic order is a
/// total order over the same input regardless of hash-map iteration, so the
/// pick is deterministic.
///
/// Takes a plain slice rather than `*const Build` on purpose: a helper that
/// needs a whole `Build` to construct is a helper that can't be unit-tested
/// without one. This one takes only the two pieces of a `Build` it actually
/// reads, so the gating matrix (head null/[]/non-empty × css present/absent)
/// and the lexicographic pick are both directly testable.
///
/// NO_SLOP.md §2.2a contract 3 (caller-buffer): reads `asset_paths`,
/// allocates nothing; the returned slice aliases one of its entries.
fn spaHeadWarningAsset(head: ?[]const std.json.ArrayHashMap([]const u8), asset_paths: []const []const u8) ?[]const u8 {
    if (head != null) return null; // explicit `head: []` opt-out, or a real head
    var best: ?[]const u8 = null;
    for (asset_paths) |p| {
        if (!std.mem.endsWith(u8, p, ".css")) continue;
        if (best == null or std.mem.lessThan(u8, p, best.?)) best = p;
    }
    return best;
}

/// Minimal HTML-escaping for developer-authored text inserted into element
/// content (here: `<title>`). Not a security boundary (values come from
/// `.spa.tsx` source, not untrusted input) — just robustness so a `title`
/// containing `&`/`<`/`>`/`"` can't produce malformed HTML.
/// Contract 1: one owned buffer out, nothing else allocated.
fn escapeHtml(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '"' => try out.appendSlice(alloc, "&quot;"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Contract 1: one owned JSON buffer escapes; the writer's storage IS that
/// buffer (`toOwnedSlice`), so nothing is left behind.
fn renderManifest(
    alloc: std.mem.Allocator,
    // `base` is the manifest's URL-form base — must already be normalized
    // (never empty; "/" for a root-mounted SPA). See `prerenderAll`'s
    // `url_base`.
    base: []const u8,
    statics: []const []const u8,
    dynamics: []const DynamicEntry,
    chunks: []const ChunkEntry,
    fallback: []const u8,
    bundle: []const u8,
    deploy_target: []const u8,
    // The site's normalized `url_path_prefix` ("" or "/myrepo"): where a host
    // MOUNTS this tree, delivered as its own field rather than folded into the
    // route values above. Emitted only when non-empty, so an unprefixed site's
    // manifest stays byte-identical. See the key-order comment below for why
    // the split exists.
    url_path_prefix: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    // Each string VALUE goes through std.json.Stringify.value (the same
    // convention islands/sidecar.zig uses for its NDJSON request lines) so a
    // "\"" or "\\" in a developer-authored base/path/bundle can't break the
    // JSON. Key set/order is unchanged from the hand-concatenated version.
    try w.writeAll("{\"base\":");
    try std.json.Stringify.value(base, .{}, w);
    try w.writeAll(",\"deploy_target\":");
    try std.json.Stringify.value(deploy_target, .{}, w);
    // `url_path_prefix` — present ONLY when non-empty, which is what keeps an
    // unprefixed site's manifest byte-identical to one built before this field
    // existed.
    //
    // Why it is a separate field instead of being baked into the route values:
    // every route value here (`base`, `static`, `dynamic.pattern`,
    // `dynamic.shell`, `fallback`, and the `chunks` KEYS) is a position inside
    // the built output TREE, and the tree has no prefix directory — the prefix
    // says where a host mounts that tree. The three emitters then need
    // different things from it, so a pre-baked prefix would have to be stripped
    // back off by two of them:
    //   - nginx wants it on `location` and on the `try_files` internal-redirect
    //     targets (request paths);
    //   - Apache must NOT have it on its patterns (a per-directory `.htaccess`
    //     matches with that prefix already stripped) and takes it as
    //     `RewriteBase` instead;
    //   - ZigBase wants it on `.match` but NOT on `.serve`, which
    //     `static_files.zig`'s `validateRouteTargetsDir` resolves as
    //     `root ++ "/" ++ trimStart(serve, "/")` — a prefixed `.serve` names a
    //     file that does not exist.
    // `runtime/scripts/emit-host-config.ts` is the manifest's only consumer, so
    // this stays an internal build contract rather than a published shape.
    //
    // NOT the same convention as `bundle` (and the `chunks` VALUES) below,
    // which are already-prefixed URLs because they are baked verbatim into
    // shell `<script>`/`modulepreload` tags by `renderShell`. Two conventions in
    // one document is a wart; it is called out here rather than left to be
    // rediscovered.
    if (url_path_prefix.len != 0) {
        try w.writeAll(",\"url_path_prefix\":");
        try std.json.Stringify.value(url_path_prefix, .{}, w);
    }
    try w.writeAll(",\"static\":[");
    for (statics, 0..) |u, i| {
        if (i != 0) try w.writeAll(",");
        try std.json.Stringify.value(u, .{}, w);
    }
    try w.writeAll("],\"dynamic\":[");
    for (dynamics, 0..) |d, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"pattern\":");
        try std.json.Stringify.value(d.pattern, .{}, w);
        try w.writeAll(",\"shell\":");
        try std.json.Stringify.value(d.shell, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("],\"chunks\":{");
    for (chunks, 0..) |c, i| {
        if (i != 0) try w.writeAll(",");
        try std.json.Stringify.value(c.url, .{}, w); // key: route URL
        try w.writeAll(":");
        try std.json.Stringify.value(c.chunk, .{}, w); // value: /spa/<chunk>
    }
    try w.writeAll("},\"fallback\":");
    try std.json.Stringify.value(fallback, .{}, w);
    try w.writeAll(",\"bundle\":");
    try std.json.Stringify.value(bundle, .{}, w);
    try w.writeAll("}");
    return aw.toOwnedSlice();
}

fn writeFile(io: std.Io, out_dir: std.Io.Dir, rel_path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |d| {
        var dir = try out_dir.createDirPathOpen(io, d, .{});
        defer dir.close(io);
        var f = try dir.createFile(io, std.fs.path.basename(rel_path), .{});
        defer f.close(io);
        var fw = f.writer(io, &.{});
        try fw.interface.writeAll(contents);
    } else {
        var f = try out_dir.createFile(io, rel_path, .{});
        defer f.close(io);
        var fw = f.writer(io, &.{});
        try fw.interface.writeAll(contents);
    }
}

/// "app/App.spa.tsx" -> "App". Mirrors `build.zig`'s `spaName`: strips a
/// trailing `.spa.tsx` off the basename, else falls back to stripping just
/// the final extension. `pub` so callers outside this file derive the
/// `/spa/<name>.js` bundle name identically.
pub fn spaName(src: []const u8) []const u8 {
    const base = std.fs.path.basename(src);
    if (std.mem.endsWith(u8, base, ".spa.tsx")) {
        return base[0 .. base.len - ".spa.tsx".len];
    }
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

/// Derive `/name` from `spaName` when `export const spa.base` is absent.
/// "app/App.spa.tsx" -> "/App".
/// Contract 1.
fn defaultBase(alloc: std.mem.Allocator, src: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "/{s}", .{spaName(src)});
}

/// Join `base` + `path`, replacing each `:seg` param with `_` and a trailing
/// `*` wildcard segment with `_`, producing a leading-slash absolute pathname
/// suitable for the sidecar's SSR `pathname` argument.
///
/// Examples (base = "/app"):
///   path "/club/:id" -> "/app/club/_"
///   path "/"         -> "/app/" (root path contributes no extra segment)
///   path "/admin/*"  -> "/app/admin/_"
/// Contract 1.
fn substituteParams(alloc: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, base);
    if (std.mem.eql(u8, path, "/")) {
        try out.append(alloc, '/');
        return out.toOwnedSlice(alloc);
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        try out.append(alloc, '/');
        if (seg[0] == ':' or std.mem.eql(u8, seg, "*")) {
            try out.append(alloc, '_');
        } else {
            try out.appendSlice(alloc, seg);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Join `base` + `path` into a manifest URL. Optionally trailing-slash it
/// (static prerendered routes always want a trailing slash so `index.html`
/// resolves via directory listing conventions).
///
/// Examples (base = "/app"):
///   path "/booking" -> "/app/booking/"
///   path "/"        -> "/app/"
/// Contract 1.
fn joinUrl(alloc: std.mem.Allocator, base: []const u8, path: []const u8, trailing: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, base);
    if (!std.mem.eql(u8, path, "/")) {
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            try out.append(alloc, '/');
            try out.appendSlice(alloc, seg);
        }
    }
    if (trailing and (out.items.len == 0 or out.items[out.items.len - 1] != '/')) {
        try out.append(alloc, '/');
    }
    return out.toOwnedSlice(alloc);
}

/// A staticPaths concrete entry must be an absolute in-app path with every
/// dynamic segment resolved and no `.`/`..` traversal segment. describeRoutes
/// already substitutes, rejects `.`/`..`/empty/non-URL-safe values, and throws
/// on missing params, so a violation here means a hand-crafted/buggy sidecar
/// response — fail the build rather than writing a file literally named ":id"
/// or letting a `..` segment climb out of (or clobber the shell above) the
/// output dir (`/club/..` -> `app/club/../index.html`).
fn validateConcretePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (seg[0] == ':' or std.mem.eql(u8, seg, "*")) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// A single path segment safe to turn into a directory name on disk and into a
/// URL segment in the manifest: non-empty, not `.`/`..` (traversal), and
/// URL-safe in the same sense the sidecar holds `staticPaths` values to —
/// percent-encoding-stable, i.e. exactly JavaScript's `encodeURIComponent`
/// unreserved set (`A-Za-z0-9` plus ``-_.!~*'()``). An encoded segment like
/// `a%20b` is written encoded to disk but a host that decodes the request path
/// before matching (nginx `try_files`) never serves it, so it is rejected
/// rather than silently emitted (see `runtime/src/router.ts`'s
/// `assertSafeStaticSegment`, which this mirrors).
fn isSafePathSegment(seg: []const u8) bool {
    if (seg.len == 0) return false;
    if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    for (seg) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (std.mem.indexOfScalar(u8, "-_.!~*'()", c) != null) continue;
        return false;
    }
    return true;
}

/// A DECLARED route `path` (the leaf full path the describe pass ships) must be
/// an absolute in-app path whose every segment is either a safe literal
/// (`isSafePathSegment`) or a pattern segment — `:param` (with a safe param
/// name) or the bare `*` catch-all.
///
/// This is `validateConcretePath`'s sibling for the paths that were never
/// checked: `validateConcretePath` guards `staticPaths` ENTRIES, but the route
/// paths themselves flow unchecked from `describe` into `patternDir`/`joinUrl`
/// → `diskJoin` → `writeFile`'s `createDirPathOpen`, which resolves a `..`
/// segment relative to the output dir — so `{ path: "/docs/" + slug }` with a
/// `../../etc` slug writes outside the output tree.
///
/// Empty segments (`//`, a trailing `/`) are SKIPPED, not rejected: the router,
/// `joinUrl`, `substituteParams` and `patternDir` all skip them too, so they
/// cannot reach a disk path — rejecting them would fail builds that work today
/// for no safety gain.
fn validateRoutePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "*")) continue; // catch-all
        if (seg[0] == ':') {
            if (!isSafePathSegment(seg[1..])) return false; // `:param` name
            continue;
        }
        if (!isSafePathSegment(seg)) return false;
    }
    return true;
}

/// A SPA's mount `base`, trailing-slash-trimmed as `prerenderAll` computes
/// it: "" (root-mounted) or an absolute path
/// of safe LITERAL segments. Unlike a route path, a base admits no `:param`/`*`
/// — it is a fixed namespace, and `patternDir`/`joinUrl` copy it verbatim into
/// both the URL and (via `disk_prefix`) the on-disk path, so `spa.base =
/// "/../evil"` would climb out of the output dir.
fn validateSpaBase(base: []const u8) bool {
    if (base.len == 0) return true; // root-mounted
    if (base[0] != '/') return false;
    var it = std.mem.splitScalar(u8, base, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (!isSafePathSegment(seg)) return false;
    }
    return true;
}

/// `validateSpaBase` + `validateRoutePath` over one describe'd SPA, fataling
/// with a site-author-actionable message naming the offending value.
fn validateRoutePathsOrFatal(src: []const u8, base: []const u8, routes: []const sidecar.RouteMeta) void {
    if (!validateSpaBase(base)) fatal.msg(
        "error: spa '{s}' exports an invalid spa.base '{s}' — a base must be '/' or an absolute " ++
            "path of URL-safe segments (no '.'/'..' traversal, no ':param'/'*')\n",
        .{ src, if (base.len == 0) "/" else base },
    );
    for (routes) |rt| {
        if (!validateRoutePath(rt.path)) fatal.msg(
            "error: spa '{s}' declares an invalid route path '{s}' — a route path must be absolute " ++
                "and every segment either URL-safe (no '.'/'..' traversal, no percent-encoding) or a " ++
                "':param'/'*' pattern segment\n",
            .{ src, rt.path },
        );
    }
}

// --- Declarative redirect validation ---------------------------------------
// The describe pass ships each route's `redirect` target (see
// `sidecar.RouteMeta.redirect`); a target that matches no route in the same
// SPA is a BUILD error naming the SPA and entry, caught here — long before a
// visitor hits the runtime's notFound fallback. Shaped for extension: the
// planned dead-`<a href>` scan (the issue's follow-up) can reuse
// `routePatternMatches` against the same route table.

/// True when the concrete in-app path `target` is matched by the route
/// pattern `pattern` (both leaf full-paths, as describe ships them): a
/// literal segment must be equal, a `:param` consumes exactly one segment,
/// and a trailing `*` consumes the rest (ZERO or more — mirroring the client
/// router's catch-all arity). Empty segments (doubled/trailing slashes) are
/// skipped on both sides, matching the router's segment splitting.
fn routePatternMatches(pattern: []const u8, target: []const u8) bool {
    var pit = std.mem.splitScalar(u8, pattern, '/');
    var tit = std.mem.splitScalar(u8, target, '/');
    while (true) {
        const ps = nextSeg(&pit) orelse return nextSeg(&tit) == null;
        if (std.mem.eql(u8, ps, "*")) return true; // catch-all: zero-or-more rest
        const ts = nextSeg(&tit) orelse return false;
        if (ps[0] == ':') continue; // :param consumes one segment
        if (!std.mem.eql(u8, ps, ts)) return false;
    }
}

/// Next NON-EMPTY segment of a '/'-split iterator, or null when exhausted.
fn nextSeg(it: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (it.next()) |seg| {
        if (seg.len != 0) return seg;
    }
    return null;
}

/// A declarative `redirect` entry that fails validation: the route that
/// declares the offending target, the target, and why.
const RedirectViolation = struct {
    route_path: []const u8,
    target: []const u8,
    reason: enum {
        /// Not a concrete root-relative pathname (missing leading '/', a
        /// `:param`/`*`/`.`/`..` segment, or a query/hash). describeRoutes
        /// (runtime/src/router.ts) already rejects these, so hitting this
        /// means a hand-crafted/buggy sidecar response — fail the build.
        not_concrete,
        /// The target matches no route in this SPA's route table.
        no_match,
        /// The redirect chain starting at this route never reaches a
        /// concrete (non-redirect) route — a cycle of any length (self,
        /// 2-node, n-node). At runtime the client router would give up
        /// after its hop cap and render notFound; catch it at build time.
        cycle,
    },
};

/// Scan a describe'd SPA's route table for the FIRST invalid `redirect`
/// entry, or null when they all check out. Each redirect's chain is FOLLOWED
/// (targets may land on other redirect routes) and must terminate at a
/// concrete non-redirect route:
///   - a non-concrete or unmatched target anywhere along the chain is
///     reported against the route that DECLARED it (the entry the author
///     must fix);
///   - a chain that revisits a route — detected via the pigeonhole bound (a
///     terminating chain can hop through at most `routes.len` redirect
///     routes) — is a `cycle`, reported against the validated entry.
/// Matching is first-match in table order, mirroring the client router.
/// A plain unit-testable helper (not a `fatal.msg` call) — see
/// `claimStaticUrl` below for the split rationale;
/// `validateRedirectsOrFatal` adds the SPA's `src`.
fn findRedirectViolation(routes: []const sidecar.RouteMeta) ?RedirectViolation {
    outer: for (routes, 0..) |rt, start| {
        var target = rt.redirect orelse continue;
        var at = start; // index of the route that declared `target`
        var hops: usize = 0;
        while (true) {
            const decl = routes[at];
            if (!validateConcretePath(target) or std.mem.indexOfAny(u8, target, "?#") != null) {
                return .{ .route_path = decl.path, .target = target, .reason = .not_concrete };
            }
            // First route in table order matching the target (the client
            // router is first-match-wins too, so build and runtime agree).
            const next_idx = for (routes, 0..) |cand, j| {
                if (routePatternMatches(cand.path, target)) break j;
            } else return .{ .route_path = decl.path, .target = target, .reason = .no_match };
            const next_target = routes[next_idx].redirect orelse
                continue :outer; // terminates at a concrete route: valid
            hops += 1;
            if (hops >= routes.len) {
                // Pigeonhole: more redirect hops than routes ⇒ some route
                // was revisited ⇒ the chain cycles and never terminates.
                return .{ .route_path = rt.path, .target = rt.redirect.?, .reason = .cycle };
            }
            at = next_idx;
            target = next_target;
        }
    }
    return null;
}

/// `findRedirectViolation`, fataling with a site-author-actionable message
/// naming the SPA and the offending entry.
fn validateRedirectsOrFatal(src: []const u8, routes: []const sidecar.RouteMeta) void {
    const v = findRedirectViolation(routes) orelse return;
    switch (v.reason) {
        .not_concrete => fatal.msg(
            "error: spa '{s}' route '{s}' declares redirect target '{s}' — a redirect target " ++
                "must be a concrete base-relative pathname (leading '/', no ':param'/'*'/'.'/'..' " ++
                "segment, no query/hash)\n",
            .{ src, v.route_path, v.target },
        ),
        .no_match => fatal.msg(
            "error: spa '{s}' route '{s}' redirects to '{s}', which matches no route in this SPA\n",
            .{ src, v.route_path, v.target },
        ),
        .cycle => fatal.msg(
            "error: spa '{s}' route '{s}' (redirect target '{s}') starts a redirect CYCLE — " ++
                "the chain never reaches a concrete (non-redirect) route\n",
            .{ src, v.route_path, v.target },
        ),
    }
}

/// Per-SPA set of static URLs already planned in one prerender/serve pass
/// keyed on the post-`planRoute` `static_url` (so different
/// spellings that plan to the same output collide correctly), valued on the
/// route pattern that first claimed it. Populated by `claimStaticUrl` as
/// declared static routes and `staticPaths` concrete entries are planned.
const StaticUrlSeen = std.StringHashMapUnmanaged([]const u8);

/// A static URL claimed by two routes within the same SPA: `first_pattern`
/// claimed `url` first, `second_pattern` tried to claim it again. Equal
/// patterns mean a duplicate `staticPaths` entry on the same route; different
/// patterns mean a genuine cross-route collision (e.g. a `staticPaths` entry
/// landing on a declared static route's URL).
const StaticUrlCollision = struct {
    url: []const u8,
    first_pattern: []const u8,
    second_pattern: []const u8,
};

/// Record `url` (about to be written for `route_pattern`) into `seen`.
/// Returns the collision info when `url` was already claimed by a prior
/// route/entry in this SPA, or `null` when it is newly claimed. A plain
/// error-returning helper (not a `fatal.msg` call) so it's directly
/// unit-testable — the caller, which alone knows the offending SPA's `src`,
/// turns a non-null return into a site-author-actionable fatal error. See
/// `renderHeadLinks`/`isValidHeadAttrName` above for the same split.
/// NO_SLOP.md §2.2a: allocates only into the CALLER-OWNED `seen` table (keys are
/// borrowed, never duped), so the caller's `seen.deinit(alloc)` reclaims
/// everything — a plain `Allocator`, not a `RenderArena`.
fn claimStaticUrl(alloc: std.mem.Allocator, seen: *StaticUrlSeen, url: []const u8, route_pattern: []const u8) !?StaticUrlCollision {
    const gop = try seen.getOrPut(alloc, url);
    if (gop.found_existing) {
        return .{ .url = url, .first_pattern = gop.value_ptr.*, .second_pattern = route_pattern };
    }
    gop.value_ptr.* = route_pattern;
    return null;
}

/// `claimStaticUrl`, fataling with a site-author-actionable message on a
/// collision: declared static routes and `staticPaths` concrete entries are
/// planned the same way, so both must reject the same duplicates/collisions.
fn claimStaticUrlOrFatal(alloc: std.mem.Allocator, seen: *StaticUrlSeen, src: []const u8, url: []const u8, route_pattern: []const u8) !void {
    const collision = (try claimStaticUrl(alloc, seen, url, route_pattern)) orelse return;
    if (std.mem.eql(u8, collision.first_pattern, collision.second_pattern)) fatal.msg(
        "error: spa '{s}' route '{s}' has a duplicate staticPaths entry — '{s}' is planned more than once\n",
        .{ src, collision.first_pattern, collision.url },
    );
    fatal.msg(
        "error: spa '{s}' routes '{s}' and '{s}' both produce static URL '{s}' — staticPaths entries and " ++
            "declared static routes must not collide\n",
        .{ src, collision.first_pattern, collision.second_pattern, collision.url },
    );
}

/// Per-SPA set of OUTPUT FILE paths already planned in one prerender/serve
/// pass, keyed on `PlannedRoute.out_path` and valued on the route pattern that
/// first claimed it. Same shape (and same `claimStaticUrl` claim logic) as
/// `StaticUrlSeen`, over the on-disk namespace instead of the URL one.
const OutPathSeen = StaticUrlSeen;

/// `claimStaticUrl` over a route's OUTPUT FILE path, fataling on a repeat.
///
/// `static_seen` guards the manifest's URL space; nothing guarded the disk one.
/// `patternDir` stops at a pattern's FIRST `:param`/`*` segment, so two dynamic
/// routes sharing a static prefix — "/club/:id" and "/club/:id/details", the
/// nested-leaf shape docs/spa.md describes — both plan
/// `<base>/club/_shell.html`: the second silently overwrote the first's
/// prerendered skeleton, and BOTH still shipped in the manifest's `dynamic`
/// list, where `runtime/scripts/emit-host-config.ts` keys each nginx `location`
/// block on that same static prefix dir — emitting two identical
/// `location <base>/club/` blocks, which nginx REFUSES to load. Failing the
/// build beats shipping a config the host won't start with.
///
/// A static route and a dynamic one can never collide here (`index.html` vs
/// `_shell.html`), and two static routes that collide are caught first by
/// `claimStaticUrlOrFatal`'s more specific message, so this fires only on the
/// shared-shell case.
fn claimOutPathOrFatal(alloc: std.mem.Allocator, seen: *OutPathSeen, src: []const u8, out_path: []const u8, route_pattern: []const u8) !void {
    const collision = (try claimStaticUrl(alloc, seen, out_path, route_pattern)) orelse return;
    fatal.msg(
        "error: spa '{s}' routes '{s}' and '{s}' both prerender the same file '{s}' — two dynamic " ++
            "routes may not share a static prefix directory: they collapse onto one _shell.html and " ++
            "emit duplicate nginx 'location' blocks. Give one of them a distinct static prefix " ++
            "segment (e.g. '/club/:id/details' -> '/club-details/:id').\n",
        .{ src, collision.first_pattern, collision.second_pattern, collision.url },
    );
}

/// The static prefix directory before the first `:param`/`*` segment of a
/// dynamic route pattern: base "/app", path "/club/:id" -> "/app/club".
/// Contract 1.
fn patternDir(alloc: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, base);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (seg[0] == ':' or std.mem.eql(u8, seg, "*")) break;
        try out.append(alloc, '/');
        try out.appendSlice(alloc, seg);
    }
    return out.toOwnedSlice(alloc);
}

test "spa notFoundOwnerIndex defaults to the first declared SPA" {
    const specs = [_]root.SpaSpec{
        .{ .src = "app/app.spa.tsx", .base = "/app" },
        .{ .src = "admin/admin.spa.tsx", .base = "/admin" },
    };
    try std.testing.expectEqual(@as(?usize, 0), notFoundOwnerIndex(&specs, null));
}

test "spa notFoundOwnerIndex selects the named SPA by its spaName basename" {
    const specs = [_]root.SpaSpec{
        .{ .src = "app/app.spa.tsx", .base = "/app" },
        .{ .src = "admin/admin.spa.tsx", .base = "/admin" },
        .{ .src = "slices/booking.spa.tsx", .base = "/booking" },
    };
    try std.testing.expectEqual(@as(?usize, 1), notFoundOwnerIndex(&specs, "admin"));
    try std.testing.expectEqual(@as(?usize, 2), notFoundOwnerIndex(&specs, "booking"));
    try std.testing.expectEqual(@as(?usize, 0), notFoundOwnerIndex(&specs, "app"));
}

test "spa notFoundOwnerIndex returns null for a name matching no declared SPA" {
    const specs = [_]root.SpaSpec{
        .{ .src = "app/app.spa.tsx", .base = "/app" },
    };
    try std.testing.expectEqual(@as(?usize, null), notFoundOwnerIndex(&specs, "booking"));
    // A base URL or src path is NOT a name; only the spaName basename matches.
    try std.testing.expectEqual(@as(?usize, null), notFoundOwnerIndex(&specs, "/app"));
    try std.testing.expectEqual(@as(?usize, null), notFoundOwnerIndex(&specs, "app/app.spa.tsx"));
}

test "spaName strips trailing .spa.tsx" {
    try std.testing.expectEqualStrings("App", spaName("app/App.spa.tsx"));
    try std.testing.expectEqualStrings("App", spaName("App.spa.tsx"));
}

test "defaultBase derives /name from src" {
    // Contract-1 helper: raw testing allocator, leak detection ON.
    const gpa = std.testing.allocator;
    const base = try defaultBase(gpa, "app/App.spa.tsx");
    defer gpa.free(base);
    try std.testing.expectEqualStrings("/App", base);
}

test "substituteParams replaces dynamic segments with _" {
    const gpa = std.testing.allocator;
    const param = try substituteParams(gpa, "/app", "/club/:id");
    defer gpa.free(param);
    const root_path = try substituteParams(gpa, "/app", "/");
    defer gpa.free(root_path);
    const wildcard = try substituteParams(gpa, "/app", "/admin/*");
    defer gpa.free(wildcard);
    try std.testing.expectEqualStrings("/app/club/_", param);
    try std.testing.expectEqualStrings("/app/", root_path);
    try std.testing.expectEqualStrings("/app/admin/_", wildcard);
}

test "joinUrl produces trailing-slash manifest URLs" {
    const gpa = std.testing.allocator;
    const booking = try joinUrl(gpa, "/app", "/booking", true);
    defer gpa.free(booking);
    const root_url = try joinUrl(gpa, "/app", "/", true);
    defer gpa.free(root_url);
    try std.testing.expectEqualStrings("/app/booking/", booking);
    try std.testing.expectEqualStrings("/app/", root_url);
}

test "patternDir stops at the first dynamic segment" {
    const gpa = std.testing.allocator;
    const dir = try patternDir(gpa, "/app", "/club/:id");
    defer gpa.free(dir);
    try std.testing.expectEqualStrings("/app/club", dir);
}

test "planRoute builds static and dynamic output paths" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const root_route = try planRoute(arena, "/app", .{ .path = "/", .dynamic = false, .hasSkeleton = false });
    try std.testing.expectEqualStrings("app/index.html", root_route.out_path);
    try std.testing.expectEqualStrings("/app/", root_route.static_url.?);

    const booking = try planRoute(arena, "/app", .{ .path = "/booking", .dynamic = false, .hasSkeleton = false });
    try std.testing.expectEqualStrings("app/booking/index.html", booking.out_path);

    const admin_users = try planRoute(arena, "/app", .{ .path = "/admin/users", .dynamic = false, .hasSkeleton = false });
    try std.testing.expectEqualStrings("app/admin/users/index.html", admin_users.out_path);

    const club = try planRoute(arena, "/app", .{ .path = "/club/:id", .dynamic = true, .hasSkeleton = false });
    try std.testing.expectEqualStrings("app/club/_shell.html", club.out_path);
    try std.testing.expectEqualStrings("/club/:id", club.dynamic.?.pattern["/app".len..]);
    try std.testing.expectEqualStrings("/app/club/_shell.html", club.dynamic.?.shell);
}

// --- Fix 1 regression tests: a root-mounted SPA (`base "/"` or `""`, which
// `prerenderAll` trims to `""` before calling `planRoute`/`diskJoin`) must
// never produce a disk path starting with "/" — that would make `writeFile`
// resolve from the filesystem root instead of the output dir. ---

test "planRoute at a root-mounted base (\"\") never produces a leading-slash disk path" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const root_route = try planRoute(arena, "", .{ .path = "/", .dynamic = false, .hasSkeleton = false });
    try std.testing.expectEqualStrings("index.html", root_route.out_path);
    try std.testing.expectEqualStrings("/", root_route.static_url.?);

    const booking = try planRoute(arena, "", .{ .path = "/booking", .dynamic = false, .hasSkeleton = false });
    try std.testing.expectEqualStrings("booking/index.html", booking.out_path);
    try std.testing.expectEqualStrings("/booking/", booking.static_url.?);

    const club = try planRoute(arena, "", .{ .path = "/club/:id", .dynamic = true, .hasSkeleton = false });
    try std.testing.expectEqualStrings("club/_shell.html", club.out_path);
    try std.testing.expectEqualStrings("/club/:id", club.dynamic.?.pattern);
    try std.testing.expectEqualStrings("/club/_shell.html", club.dynamic.?.shell);
}

// AUDF-001 regression: a root-mounted SPA (`base ""`) whose FIRST route segment
// is dynamic (`/:x`, top-level `/*`) makes `patternDir` return "" — the disk
// `out_path` must then be the bare "_shell.html", NOT "/_shell.html", which
// `writeFile`'s `createDirPathOpen(io, "/", …)` would resolve from the
// filesystem root (build abort / output-tree escape). The manifest `shell`
// field stays "/_shell.html" (a URL served from the site root — leading slash
// correct there, matching the "/club/_shell.html" form above).
test "planRoute at a root-mounted base with a leading dynamic segment writes _shell.html with no leading slash" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const user = try planRoute(arena, "", .{ .path = "/:username", .dynamic = true, .hasSkeleton = false });
    try std.testing.expectEqualStrings("_shell.html", user.out_path);
    try std.testing.expectEqualStrings("/:username", user.dynamic.?.pattern);
    try std.testing.expectEqualStrings("/_shell.html", user.dynamic.?.shell);

    const catch_all = try planRoute(arena, "", .{ .path = "/*", .dynamic = true, .hasSkeleton = false });
    try std.testing.expectEqualStrings("_shell.html", catch_all.out_path);
    try std.testing.expectEqualStrings("/*", catch_all.dynamic.?.pattern);
    try std.testing.expectEqualStrings("/_shell.html", catch_all.dynamic.?.shell);
}

test "diskJoin never produces a leading slash for a root (empty) disk-prefix" {
    const gpa = std.testing.allocator;

    // Root-mounted SPA: no separator inserted, output-dir-relative.
    const rooted = try diskJoin(gpa, "", "routing-manifest.json");
    defer gpa.free(rooted);
    try std.testing.expectEqualStrings("routing-manifest.json", rooted);
    // Regression: the pre-existing "/app" case stays byte-identical.
    const mounted = try diskJoin(gpa, "app", "routing-manifest.json");
    defer gpa.free(mounted);
    try std.testing.expectEqualStrings("app/routing-manifest.json", mounted);
}

test "renderManifest normalizes a root base to \"/\" and produces valid, escaped JSON" {
    // Contract 1 all the way down: raw testing allocator, leak detection ON.
    const gpa = std.testing.allocator;

    const statics = [_][]const u8{"/"};
    const dynamics = [_]DynamicEntry{.{ .pattern = "/club/:id", .shell = "/club/_shell.html" }};
    const manifest = try renderManifest(gpa, "/", &statics, &dynamics, &.{}, "/index.html", "/spa/App.js", "zigbase", "");
    defer gpa.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"base\":\"/\"") != null);

    const Parsed = struct {
        base: []const u8,
        deploy_target: []const u8,
        static: []const []const u8,
        dynamic: []const struct { pattern: []const u8, shell: []const u8 },
        fallback: []const u8,
        bundle: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Parsed, gpa, manifest, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/", parsed.value.base);
    try std.testing.expectEqualStrings("/", parsed.value.static[0]);
    try std.testing.expectEqualStrings("/club/:id", parsed.value.dynamic[0].pattern);
    try std.testing.expectEqualStrings("/index.html", parsed.value.fallback);
}

test "renderManifest carries url_path_prefix as its own field, and omits it entirely when empty" {
    // The prefix reaches the host-config emitters as a SEPARATE field rather
    // than baked into the route values, because the three emitters need
    // different things from it (nginx wants it on `location`, Apache must not
    // have it on a per-directory pattern, ZigBase wants it on `.match` but not
    // on `.serve`). See `renderManifest`'s own comment for the full reasoning.
    const gpa = std.testing.allocator;

    const statics = [_][]const u8{"/app/"};
    const dynamics = [_]DynamicEntry{.{ .pattern = "/app/club/:id", .shell = "/app/club/_shell.html" }};

    const prefixed_manifest = try renderManifest(gpa, "/app", &statics, &dynamics, &.{}, "/app/index.html", "/myrepo/spa/App.js", "nginx", "/myrepo");
    defer gpa.free(prefixed_manifest);
    try std.testing.expect(std.mem.indexOf(u8, prefixed_manifest, "\"url_path_prefix\":\"/myrepo\"") != null);
    // The route values stay TREE-RELATIVE — they name positions inside the
    // built output tree, which has no prefix directory. Asserting the prefix
    // field alone would pass just as well if they had ALSO been prefixed, which
    // is the bug this design exists to avoid.
    try std.testing.expect(std.mem.indexOf(u8, prefixed_manifest, "\"base\":\"/app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefixed_manifest, "\"fallback\":\"/app/index.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefixed_manifest, "\"pattern\":\"/app/club/:id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefixed_manifest, "\"shell\":\"/app/club/_shell.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefixed_manifest, "\"/myrepo/app") == null);
    // `bundle` is the deliberate exception: it is baked verbatim into shell
    // script tags, so it arrives already prefixed.
    try std.testing.expect(std.mem.indexOf(u8, prefixed_manifest, "\"bundle\":\"/myrepo/spa/App.js\"") != null);

    // Empty prefix: the key is absent ENTIRELY, not emitted as "". This is what
    // keeps an unprefixed site's manifest byte-identical to one built before
    // the field existed.
    const bare = try renderManifest(gpa, "/app", &statics, &dynamics, &.{}, "/app/index.html", "/spa/App.js", "nginx", "");
    defer gpa.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "url_path_prefix") == null);
}

test "renderManifest escapes a quote inside a string value" {
    const gpa = std.testing.allocator;

    // Not a realistic base, but proves a raw '"' can't break the JSON.
    const statics = [_][]const u8{"/weird\"quote/"};
    const manifest = try renderManifest(gpa, "/app", &statics, &.{}, &.{}, "/app/index.html", "/spa/App.js", "zigbase", "");
    defer gpa.free(manifest);

    // The raw JSON must contain an escaped quote, not a bare one that would
    // terminate the string value early.
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\\\"quote") != null);

    const Parsed = struct { static: []const []const u8 };
    const parsed = try std.json.parseFromSlice(Parsed, gpa, manifest, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/weird\"quote/", parsed.value.static[0]);
}

test "renderShell HTML-escapes the title and reuses the shared runtime constants" {
    // `renderShell` is contract 1 — every fragment it builds is freed inside and
    // one buffer escapes — so the shell tests run on the raw testing allocator
    // with leak detection ON (NO_SLOP.md §2.2a).
    const gpa = std.testing.allocator;

    const html = try renderShell(gpa, "A & B <script> \"x\"", true, "/spa/App.js", pass.shared_runtime_url, null, "", null, null, "<div>skeleton</div>");
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<title>A &amp; B &lt;script&gt; &quot;x&quot;</title>") != null);
    // The raw, unescaped title text must not appear anywhere in the shell.
    try std.testing.expect(std.mem.indexOf(u8, html, "A & B <script>") == null);

    // Fix 3 (DRY): the runtime preload/script tags are the exact shared
    // constants from islands/pass.zig, not hand-duplicated literals.
    try std.testing.expect(std.mem.indexOf(u8, html, pass.runtime_preload) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, pass.runtime_script) != null);
}

test "renderShell emits a modulepreload for a lazy route's chunk (and none without one)" {
    const gpa = std.testing.allocator;

    const with = try renderShell(gpa, "App", true, "/spa/app.js", pass.shared_runtime_url, "/spa/Heavy-abc123.js", "", null, null, "<div>sk</div>");
    defer gpa.free(with);
    try std.testing.expect(std.mem.indexOf(u8, with, "<link rel=\"modulepreload\" href=\"/spa/Heavy-abc123.js\">") != null);
    // the entry bundle is still preloaded too
    try std.testing.expect(std.mem.indexOf(u8, with, "<link rel=\"modulepreload\" href=\"/spa/app.js\">") != null);

    const without = try renderShell(gpa, "App", true, "/spa/app.js", pass.shared_runtime_url, null, "", null, null, "<div>sk</div>");
    defer gpa.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "Heavy-") == null);
    // the chunk preload adds exactly one modulepreload over the no-chunk shell
    // (which already has the runtime + entry preloads).
    try std.testing.expect(std.mem.count(u8, with, "rel=\"modulepreload\"") ==
        std.mem.count(u8, without, "rel=\"modulepreload\"") + 1);
}

// AUDF-005 regression: on a `url_path_prefix` (GitHub project-pages) deploy the
// shells' runtime/bundle/import-map/chunk URLs must carry the prefix — the exact
// composition `prerenderAll` applies via `pass.prefixed` before `renderShell` —
// or the module graph 404s at the domain root and the SPA renders blank. Mirrors
// the island pass's module-URL prefixing (AUD-021). The empty-prefix path stays
// byte-identical (`pass.prefixed` dupes the URL unchanged).
test "renderShell under a url_path_prefix bakes prefixed runtime/bundle/chunk URLs" {
    const gpa = std.testing.allocator;

    const prefix = "myrepo";
    // The three asset URLs exactly as prerenderAll now builds them.
    const bundle_url = try pass.prefixed(gpa, prefix, "/spa/App.js");
    defer gpa.free(bundle_url);
    const runtime_url = try pass.prefixed(gpa, prefix, pass.shared_runtime_url);
    defer gpa.free(runtime_url);
    const chunk_url = try pass.prefixed(gpa, prefix, "/spa/Heavy-abc123.js");
    defer gpa.free(chunk_url);
    try std.testing.expectEqualStrings("/myrepo/spa/App.js", bundle_url);
    try std.testing.expectEqualStrings("/myrepo/zigapagos-runtime.js", runtime_url);
    try std.testing.expectEqualStrings("/myrepo/spa/Heavy-abc123.js", chunk_url);

    const html = try renderShell(gpa, "App", true, bundle_url, runtime_url, chunk_url, "", null, null, "<div>sk</div>");
    defer gpa.free(html);
    // Entry bundle, lazy chunk, and the module bootstrap all reference the
    // prefixed URLs.
    try std.testing.expect(std.mem.indexOf(u8, html, "<link rel=\"modulepreload\" href=\"/myrepo/spa/App.js\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<link rel=\"modulepreload\" href=\"/myrepo/spa/Heavy-abc123.js\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "import*as m from\"/myrepo/spa/App.js\"") != null);
    // The import map routes @z/runtime at the prefixed runtime URL.
    try std.testing.expect(std.mem.indexOf(u8, html, "/myrepo/zigapagos-runtime.js") != null);
    // No bare (unprefixed) asset URL leaks into the shell.
    try std.testing.expect(std.mem.indexOf(u8, html, "\"/spa/App.js\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "\"/zigapagos-runtime.js\"") == null);

    // Empty prefix: byte-identical to the pre-prefix shell.
    const bare_bundle = try pass.prefixed(gpa, "", "/spa/App.js");
    defer gpa.free(bare_bundle);
    const bare_runtime = try pass.prefixed(gpa, "", pass.shared_runtime_url);
    defer gpa.free(bare_runtime);
    const bare = try renderShell(gpa, "App", true, bare_bundle, bare_runtime, null, "", null, null, "<div>sk</div>");
    defer gpa.free(bare);
    const golden = try renderShell(gpa, "App", true, "/spa/App.js", pass.shared_runtime_url, null, "", null, null, "<div>sk</div>");
    defer gpa.free(golden);
    try std.testing.expectEqualStrings(golden, bare);
}

// Issue #26: the client Router's `base` and the SSR pass's simulated
// `location.pathname` must agree byte-for-byte, or a prerendered `<a href>`
// is wrong and — because Preact's `hydrate()` never diffs element attributes
// — stays wrong forever. `data-z-prefix` on `#z-spa-root` is how `renderShell`
// hands the client the same normalized prefix the SSR pass composed its
// pathname with.
test "renderShell under a url_path_prefix emits data-z-prefix on #z-spa-root, and omits it entirely when unprefixed" {
    const gpa = std.testing.allocator;

    const prefix = "myrepo"; // pass.prefixed normalizes this to "/myrepo"
    const bundle_url = try pass.prefixed(gpa, prefix, "/spa/App.js");
    defer gpa.free(bundle_url);
    const runtime_url = try pass.prefixed(gpa, prefix, pass.shared_runtime_url);
    defer gpa.free(runtime_url);

    const html = try renderShell(gpa, "App", true, bundle_url, runtime_url, null, "/myrepo", null, null, "<div>sk</div>");
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div id=\"z-spa-root\" data-z-spa data-z-prefix=\"/myrepo\">") != null);
    // Still carries the prefixed asset URLs (AUDF-005) alongside the new
    // attribute — the two prefixing mechanisms compose, they don't collide.
    try std.testing.expect(std.mem.indexOf(u8, html, "/myrepo/spa/App.js") != null);

    // Empty prefix (the common case): no attribute at all, not
    // `data-z-prefix=""` — an unprefixed shell must stay byte-identical to
    // one built before this field existed.
    const bare = try renderShell(gpa, "App", true, "/spa/App.js", pass.shared_runtime_url, null, "", null, null, "<div>sk</div>");
    defer gpa.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "data-z-prefix") == null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "<div id=\"z-spa-root\" data-z-spa>") != null);
}

test "renderShell HTML-escapes the url_prefix attribute value" {
    const gpa = std.testing.allocator;

    // Not a realistic `url_path_prefix` (that's validated elsewhere), but
    // `renderShell` must not trust it blind — an unescaped `"` would break
    // out of the attribute.
    const html = try renderShell(gpa, "App", true, "/spa/App.js", pass.shared_runtime_url, null, "/a\"b", null, null, "<div>sk</div>");
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-z-prefix=\"/a&quot;b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-z-prefix=\"/a\"b\"") == null);
}

test "renderShell emits the import map before any modulepreload or module script" {
    const gpa = std.testing.allocator;

    const html = try renderShell(gpa, "App", true, "/spa/app.js", pass.shared_runtime_url, "/spa/Heavy-abc123.js", "", null, null, "<div>sk</div>");
    defer gpa.free(html);
    // Per the import-maps spec, a map is only processed if it appears before
    // any module loading starts, and a <link rel="modulepreload"> (or a
    // module <script>) starts one — so the map must come first.
    const im = std.mem.indexOf(u8, html, "importmap").?;
    const mp = std.mem.indexOf(u8, html, "modulepreload").?;
    const mod_script = std.mem.indexOf(u8, html, "<script type=\"module\"").?;
    try std.testing.expect(im < mp);
    try std.testing.expect(im < mod_script);
}

// --- Structured `spa.head` hook — entries render as
// `<link>` tags between the import map and the first modulepreload. ---

test "renderShell with no head matches the golden minimal shell byte-for-byte" {
    const gpa = std.testing.allocator;

    const html = try renderShell(gpa, "App", true, "/spa/app.js", pass.shared_runtime_url, null, "", null, null, "<div>sk</div>");
    defer gpa.free(html);
    // The golden minimal shell — proves absent `head`/`flags` add not one
    // byte, and pins the bootstrap: a namespace import of the SPA bundle
    // whose module object is passed to mountSpa, so an optional clientInit
    // export is reachable without an ESM link error when absent.
    const expected = "<!DOCTYPE html><html><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<title>App</title><meta name=\"robots\" content=\"noindex\">" ++
        pass.import_map ++
        pass.runtime_preload ++
        "<link rel=\"modulepreload\" href=\"/spa/app.js\">" ++
        pass.runtime_script ++
        "<script type=\"module\">import*as m from\"/spa/app.js\";import{mountSpa}from\"@z/runtime\";mountSpa(m.default,\"#z-spa-root\",m);</script>" ++
        "</head><body><div id=\"z-spa-root\" data-z-spa><div>sk</div></div></body></html>";
    try std.testing.expectEqualStrings(expected, html);

    // An empty head slice must be indistinguishable from an absent one.
    const html_empty_slice = try renderShell(gpa, "App", true, "/spa/app.js", pass.shared_runtime_url, null, "", &.{}, null, "<div>sk</div>");
    defer gpa.free(html_empty_slice);
    try std.testing.expectEqualStrings(html, html_empty_slice);
}

// --- Baked flag defaults — the `data-z-flags` snapshot data block. ----------

test "renderFlagsSnapshot emits the ResolvedState-shaped data block in declaration order" {
    const gpa = std.testing.allocator;

    var flags: std.json.ArrayHashMap(bool) = .{};
    defer flags.map.deinit(gpa); // names/values are borrowed literals; the table allocates
    try flags.map.put(gpa, "bookAsGuest", true);
    try flags.map.put(gpa, "promoBanner", false);

    const snapshot = try renderFlagsSnapshot(gpa, flags);
    defer gpa.free(snapshot);
    try std.testing.expectEqualStrings(
        "<script type=\"application/json\" data-z-flags>" ++
            "{\"flags\":{\"bookAsGuest\":true,\"promoBanner\":false},\"experiments\":{}}" ++
            "</script>",
        snapshot,
    );

    // Absent or empty flags render as "" — a flag-less shell is byte-identical.
    try std.testing.expectEqualStrings("", try renderFlagsSnapshot(gpa, null));
    const empty: std.json.ArrayHashMap(bool) = .{};
    try std.testing.expectEqualStrings("", try renderFlagsSnapshot(gpa, empty));
}

test "renderFlagsSnapshot escapes </ in a flag name so it cannot close the script element" {
    const gpa = std.testing.allocator;

    var flags: std.json.ArrayHashMap(bool) = .{};
    defer flags.map.deinit(gpa);
    try flags.map.put(gpa, "a</script>b", true);

    const snapshot = try renderFlagsSnapshot(gpa, flags);
    defer gpa.free(snapshot);
    // The literal `</script>` may appear exactly once: the real closing tag.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, snapshot, "</script>"));
    // The flag name's `</` is escaped to the JSON-valid `<\/`.
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "a<\\/script>b") != null);
}

test "renderShell embeds the flags snapshot and stays byte-identical without one" {
    const gpa = std.testing.allocator;

    var flags: std.json.ArrayHashMap(bool) = .{};
    defer flags.map.deinit(gpa);
    try flags.map.put(gpa, "bookAsGuest", true);

    const with = try renderShell(gpa, "App", true, "/spa/app.js", pass.shared_runtime_url, null, "", null, flags, "<div>sk</div>");
    defer gpa.free(with);
    const block = "<script type=\"application/json\" data-z-flags>{\"flags\":{\"bookAsGuest\":true},\"experiments\":{}}</script>";
    const at = std.mem.indexOf(u8, with, block).?;
    // The data block sits in <head>, before the runtime preload/bootstrap.
    try std.testing.expect(at < std.mem.indexOf(u8, with, "rel=\"modulepreload\"").?);
    // Import-map-first invariant is unaffected (a data block loads no modules).
    try std.testing.expect(std.mem.indexOf(u8, with, "importmap").? < at);

    // No flags and empty flags are both byte-identical to each other.
    const without = try renderShell(gpa, "App", true, "/spa/app.js", pass.shared_runtime_url, null, "", null, null, "<div>sk</div>");
    defer gpa.free(without);
    const empty: std.json.ArrayHashMap(bool) = .{};
    const with_empty = try renderShell(gpa, "App", true, "/spa/app.js", pass.shared_runtime_url, null, "", null, empty, "<div>sk</div>");
    defer gpa.free(with_empty);
    try std.testing.expectEqualStrings(without, with_empty);
    try std.testing.expect(std.mem.indexOf(u8, without, "data-z-flags") == null);
}

test "renderShell renders head entries as ordered <link> tags between the import map and the first modulepreload" {
    const gpa = std.testing.allocator;

    var e1: std.json.ArrayHashMap([]const u8) = .{};
    defer e1.map.deinit(gpa);
    try e1.map.put(gpa, "rel", "stylesheet");
    try e1.map.put(gpa, "href", "/styles.css");
    var e2: std.json.ArrayHashMap([]const u8) = .{};
    defer e2.map.deinit(gpa);
    try e2.map.put(gpa, "rel", "preconnect");
    try e2.map.put(gpa, "href", "https://fonts.example.com");
    const head = [_]std.json.ArrayHashMap([]const u8){ e1, e2 };

    const html = try renderShell(gpa, "App", true, "/spa/app.js", pass.shared_runtime_url, null, "", &head, null, "<div>sk</div>");
    defer gpa.free(html);

    const link1 = std.mem.indexOf(u8, html, "<link rel=\"stylesheet\" href=\"/styles.css\">").?;
    const link2 = std.mem.indexOf(u8, html, "<link rel=\"preconnect\" href=\"https://fonts.example.com\">").?;
    const im = std.mem.indexOf(u8, html, "importmap").?;
    const first_modulepreload = std.mem.indexOf(u8, html, "rel=\"modulepreload\"").?;

    try std.testing.expect(link1 < link2); // declaration order preserved
    try std.testing.expect(im < link1); // after the import map
    try std.testing.expect(link2 < first_modulepreload); // before any modulepreload
}

test "renderShell HTML-escapes head attribute values" {
    const gpa = std.testing.allocator;

    var e: std.json.ArrayHashMap([]const u8) = .{};
    defer e.map.deinit(gpa);
    try e.map.put(gpa, "rel", "stylesheet");
    try e.map.put(gpa, "href", "/a&b\".css");
    const head = [_]std.json.ArrayHashMap([]const u8){e};

    const html = try renderShell(gpa, "App", true, "/spa/app.js", pass.shared_runtime_url, null, "", &head, null, "<div>sk</div>");
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/a&amp;b&quot;.css\"") != null);
    // the raw, unescaped value must not appear anywhere in the shell.
    try std.testing.expect(std.mem.indexOf(u8, html, "/a&b\".css") == null);
}

test "renderHeadLinks rejects an invalid attribute name" {
    const gpa = std.testing.allocator;

    var bad: std.json.ArrayHashMap([]const u8) = .{};
    defer bad.map.deinit(gpa);
    try bad.map.put(gpa, "data attr", "x"); // a space is not a valid attribute name char
    const head = [_]std.json.ArrayHashMap([]const u8){bad};

    // The error path must not leak the partially built tag block either — this
    // test now proves that, because `renderHeadLinks` runs on the raw testing
    // allocator (its `errdefer`, not an arena, is what makes it true).
    try std.testing.expectError(error.InvalidHeadAttrName, renderHeadLinks(gpa, &head));

    // A leading-digit name is also invalid (must start [a-zA-Z]).
    var bad2: std.json.ArrayHashMap([]const u8) = .{};
    defer bad2.map.deinit(gpa);
    try bad2.map.put(gpa, "1rel", "x");
    const head2 = [_]std.json.ArrayHashMap([]const u8){bad2};
    try std.testing.expectError(error.InvalidHeadAttrName, renderHeadLinks(gpa, &head2));

    // A hyphenated data-* attribute name is valid.
    var ok: std.json.ArrayHashMap([]const u8) = .{};
    defer ok.map.deinit(gpa);
    try ok.map.put(gpa, "data-x", "x");
    const head3 = [_]std.json.ArrayHashMap([]const u8){ok};
    const links = try renderHeadLinks(gpa, &head3);
    defer gpa.free(links);
    try std.testing.expectEqualStrings("<link data-x=\"x\">", links);
}

// --- Local spa.head assets — a root-relative href must map to an
// assets-dir-relative path (auto-staged when the file exists) and the build
// must fail when nothing installs that path. ---

test "spa headHrefAssetPath maps root-relative hrefs to assets-relative paths" {
    // Plain root-relative hrefs (no url_path_prefix).
    try std.testing.expectEqualStrings("site.css", headHrefAssetPath("/site.css", "").?);
    try std.testing.expectEqualStrings("css/site.css", headHrefAssetPath("/css/site.css", "").?);
    // Query/fragment are not part of the on-disk path.
    try std.testing.expectEqualStrings("site.css", headHrefAssetPath("/site.css?v=2#top", "").?);

    // Non-local hrefs contribute nothing: external, protocol-relative,
    // relative, bare "/", empty.
    try std.testing.expect(headHrefAssetPath("https://fonts.googleapis.com/css2?family=Inter", "") == null);
    try std.testing.expect(headHrefAssetPath("//cdn.example.com/x.css", "") == null);
    try std.testing.expect(headHrefAssetPath("site.css", "") == null);
    try std.testing.expect(headHrefAssetPath("/", "") == null);
    try std.testing.expect(headHrefAssetPath("", "") == null);
}

test "spa fingerprintedHref replaces only the last path segment" {
    const gpa = std.testing.allocator;

    const flat = try fingerprintedHref(gpa, "/site.css", "site.a1b2c3d4.css");
    defer gpa.free(flat);
    try std.testing.expectEqualStrings("/site.a1b2c3d4.css", flat);

    // Directory components survive.
    const nested = try fingerprintedHref(gpa, "/css/site.css", "site.a1b2c3d4.css");
    defer gpa.free(nested);
    try std.testing.expectEqualStrings("/css/site.a1b2c3d4.css", nested);

    // So does a url_path_prefix: `headHrefAssetPath` strips it to find the
    // file, but the SERVED url still needs it, so the rewrite must not eat it.
    const prefixed = try fingerprintedHref(gpa, "/zigapagos/site.css", "site.a1b2c3d4.css");
    defer gpa.free(prefixed);
    try std.testing.expectEqualStrings("/zigapagos/site.a1b2c3d4.css", prefixed);
}

test "spa fingerprintedHref preserves a query or fragment suffix" {
    const gpa = std.testing.allocator;

    // A hand-written `?v=2` is redundant once the hash is in the name, but
    // silently dropping something the author wrote is a worse outcome than a
    // belt-and-braces cache buster.
    const q = try fingerprintedHref(gpa, "/site.css?v=2", "site.a1b2c3d4.css");
    defer gpa.free(q);
    try std.testing.expectEqualStrings("/site.a1b2c3d4.css?v=2", q);

    const f = try fingerprintedHref(gpa, "/css/site.css#top", "site.a1b2c3d4.css");
    defer gpa.free(f);
    try std.testing.expectEqualStrings("/css/site.a1b2c3d4.css#top", f);

    const both = try fingerprintedHref(gpa, "/site.css?v=2#top", "site.a1b2c3d4.css");
    defer gpa.free(both);
    try std.testing.expectEqualStrings("/site.a1b2c3d4.css?v=2#top", both);
}

test "spa headHrefAssetPath strips a matching url_path_prefix at a segment boundary" {
    // A prefixed site's correct href is "/<prefix>/<asset>" — the prefix is
    // stripped to find the file in the assets dir.
    try std.testing.expectEqualStrings("site.css", headHrefAssetPath("/zigapagos/site.css", "zigapagos").?);
    // Prefix spelled with slashes in zigapagos.ziggy normalizes the same way.
    try std.testing.expectEqualStrings("site.css", headHrefAssetPath("/zigapagos/site.css", "/zigapagos/").?);
    // Segment boundary: "/zigapagosx/…" does NOT match prefix "zigapagos".
    try std.testing.expectEqualStrings("zigapagosx/site.css", headHrefAssetPath("/zigapagosx/site.css", "zigapagos").?);
    // An unprefixed href on a prefixed site still maps as-is.
    try std.testing.expectEqualStrings("site.css", headHrefAssetPath("/site.css", "zigapagos").?);
    // The bare prefix dir names no asset.
    try std.testing.expect(headHrefAssetPath("/zigapagos", "zigapagos") == null);
    try std.testing.expect(headHrefAssetPath("/zigapagos/", "zigapagos") == null);
}

// --- Issue #24: warn when a SPA declares no spa.head on a site with
// stylesheets — the gating matrix (head null/[]/non-empty × css present/
// absent) and the deterministic (lexicographically smallest) asset pick. ---

test "spaHeadWarningAsset stays silent when head is present (empty or not), regardless of css assets" {
    const css = [_][]const u8{"site.css"};

    // head: [] — the documented opt-out — is silent even with css assets.
    const empty_head = [_]std.json.ArrayHashMap([]const u8){};
    try std.testing.expect(spaHeadWarningAsset(&empty_head, &css) == null);

    // A real (non-empty) head is silent too, even preconnect-only (no
    // stylesheet entry) — the author has clearly used the hook.
    var e: std.json.ArrayHashMap([]const u8) = .{};
    defer e.map.deinit(std.testing.allocator);
    try e.map.put(std.testing.allocator, "rel", "preconnect");
    const head = [_]std.json.ArrayHashMap([]const u8){e};
    try std.testing.expect(spaHeadWarningAsset(&head, &css) == null);
}

test "spaHeadWarningAsset stays silent when head is absent but the site has no css assets" {
    const no_css = [_][]const u8{ "logo.png", "site.js" };
    try std.testing.expect(spaHeadWarningAsset(null, &no_css) == null);
    try std.testing.expect(spaHeadWarningAsset(null, &.{}) == null);
}

test "spaHeadWarningAsset fires when head is absent and the site has a css asset, naming it" {
    const css = [_][]const u8{"site.css"};
    try std.testing.expectEqualStrings("site.css", spaHeadWarningAsset(null, &css).?);
}

test "spaHeadWarningAsset picks the lexicographically smallest .css path, deterministically" {
    // Deliberately NOT already sorted, and mixed with non-css assets — the
    // pick must be stable regardless of input order (as a hash map iteration
    // would produce) and must skip non-.css entries.
    const assets = [_][]const u8{ "zzz.css", "logo.png", "css/a.css", "app.css" };
    try std.testing.expectEqualStrings("app.css", spaHeadWarningAsset(null, &assets).?);

    // A different presentation order of the same set picks the same file.
    const assets_reordered = [_][]const u8{ "app.css", "css/a.css", "zzz.css", "logo.png" };
    try std.testing.expectEqualStrings("app.css", spaHeadWarningAsset(null, &assets_reordered).?);
}

test "spa findBuildAssetByInstallPath matches install paths leading-slash-insensitively" {
    const gpa = std.testing.allocator;

    var map: std.StringArrayHashMapUnmanaged(root.BuildAsset) = .empty;
    defer map.deinit(gpa); // keys and paths are borrowed literals; only the table allocates
    try map.put(gpa, "runtime", .{
        .input_path = "zig-out/zigapagos-runtime.js",
        .install_path = "/zigapagos-runtime.js",
        .rc = .init(0),
    });
    try map.put(gpa, "styles", .{
        .input_path = "gen/styles.css",
        .install_path = "css/site.css", // no leading slash — both spellings install the same path
        .rc = .init(0),
    });

    const rt = findBuildAssetByInstallPath(&map, "zigapagos-runtime.js").?;
    try std.testing.expectEqualStrings("zig-out/zigapagos-runtime.js", rt.input_path);
    const css = findBuildAssetByInstallPath(&map, "css/site.css").?;
    try std.testing.expectEqualStrings("gen/styles.css", css.input_path);
    // rc is bumpable through the returned pointer (the caller stages it).
    _ = css.rc.fetchAdd(1, .acq_rel);
    try std.testing.expect(map.get("styles").?.rc.raw == 1);

    try std.testing.expect(findBuildAssetByInstallPath(&map, "missing.css") == null);
}

test "renderManifest emits a per-route chunks map" {
    const gpa = std.testing.allocator;

    const statics = [_][]const u8{ "/app/", "/app/heavy/" };
    const chunks = [_]ChunkEntry{.{ .url = "/app/heavy/", .chunk = "/spa/Heavy-abc123.js" }};
    const manifest = try renderManifest(gpa, "/app", &statics, &.{}, &chunks, "/app/index.html", "/spa/app.js", "zigbase", "");
    defer gpa.free(manifest);

    const Parsed = struct {
        chunks: std.json.ArrayHashMap([]const u8),
        static: []const []const u8,
    };
    const parsed = try std.json.parseFromSlice(Parsed, gpa, manifest, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/spa/Heavy-abc123.js", parsed.value.chunks.map.get("/app/heavy/").?);
    try std.testing.expect(parsed.value.chunks.map.get("/app/") == null); // only lazy routes listed
}

// --- Symptom B regression tests: a stale spa/<name>-runtime.js from
// a previous sliced build must be removed once the slice decision flips to
// fallback (shared runtime), and left alone while still sliced. ---

test "deleteStaleSlicedRuntime removes the stale runtime file on a fallback decision" {
    // Contract 1 (it frees the two path strings it builds): raw testing
    // allocator, leak detection ON.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var spa_dir = try tmp.dir.createDirPathOpen(io, "spa", .{});
    defer spa_dir.close(io);
    var f = try spa_dir.createFile(io, "App-runtime.js", .{});
    f.close(io);

    try deleteStaleSlicedRuntime(io, gpa, tmp.dir, "App", true);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "spa/App-runtime.js", .{}));
}

// AUDF-015 regression: a slice built with source maps installs both
// `<name>-runtime.js` and `<name>-runtime.js.map`; a slice→fallback flip must
// prune BOTH, or the orphaned map lingers in a reused/sync-without-delete
// output tree.
test "deleteStaleSlicedRuntime also removes the orphaned .js.map on a fallback decision" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var spa_dir = try tmp.dir.createDirPathOpen(io, "spa", .{});
    defer spa_dir.close(io);
    var js = try spa_dir.createFile(io, "App-runtime.js", .{});
    js.close(io);
    var map = try spa_dir.createFile(io, "App-runtime.js.map", .{});
    map.close(io);

    try deleteStaleSlicedRuntime(io, gpa, tmp.dir, "App", true);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "spa/App-runtime.js", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "spa/App-runtime.js.map", .{}));
}

test "deleteStaleSlicedRuntime is a no-op when the file is already gone (FileNotFound is not an error)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No spa/App-runtime.js exists at all — must not error.
    try deleteStaleSlicedRuntime(io, gpa, tmp.dir, "App", true);
}

test "validateConcretePath accepts clean absolute paths and rejects residual patterns" {
    try std.testing.expect(validateConcretePath("/club/1"));
    try std.testing.expect(validateConcretePath("/docs/guide/intro"));
    try std.testing.expect(!validateConcretePath("club/1")); // must be absolute
    try std.testing.expect(!validateConcretePath("/club/:id")); // unresolved param
    try std.testing.expect(!validateConcretePath("/docs/*")); // unresolved catch-all
    try std.testing.expect(!validateConcretePath("")); // empty
    try std.testing.expect(!validateConcretePath("/club/..")); // ".." traversal segment
    try std.testing.expect(!validateConcretePath("/club/.")); // "." current-dir segment
}

// --- Declarative redirect entries validated against the route
// table at build time — an unmatched or non-concrete target is a build error
// naming the SPA and entry (see validateRedirectsOrFatal). ---

test "spa routePatternMatches: literal, :param, and zero-or-more * arities" {
    // literal segments
    try std.testing.expect(routePatternMatches("/dashboard", "/dashboard"));
    try std.testing.expect(routePatternMatches("/", "/"));
    try std.testing.expect(!routePatternMatches("/dashboard", "/dash"));
    try std.testing.expect(!routePatternMatches("/dashboard", "/dashboard/extra"));
    // trailing-slash spellings collapse (segment split skips empties)
    try std.testing.expect(routePatternMatches("/dashboard", "/dashboard/"));
    // :param consumes exactly one segment
    try std.testing.expect(routePatternMatches("/club/:id", "/club/42"));
    try std.testing.expect(!routePatternMatches("/club/:id", "/club"));
    try std.testing.expect(!routePatternMatches("/club/:id", "/club/42/tab"));
    // nested full-path leaves (describe ships joined paths)
    try std.testing.expect(routePatternMatches("/dash/overview", "/dash/overview"));
    // * matches ZERO or more trailing segments (client-router arity)
    try std.testing.expect(routePatternMatches("/docs/*", "/docs"));
    try std.testing.expect(routePatternMatches("/docs/*", "/docs/guide/intro"));
    try std.testing.expect(!routePatternMatches("/docs/*", "/blog/x"));
}

test "spa findRedirectViolation: valid targets (static, :param, *, chained redirect) pass" {
    const routes = [_]sidecar.RouteMeta{
        .{ .path = "/", .dynamic = false, .hasSkeleton = false, .redirect = "/dashboard" },
        .{ .path = "/legacy", .dynamic = false, .hasSkeleton = false, .redirect = "/" }, // chain onto another redirect
        .{ .path = "/dashboard", .dynamic = false, .hasSkeleton = false },
        .{ .path = "/old-club", .dynamic = false, .hasSkeleton = false, .redirect = "/club/1" },
        .{ .path = "/club/:id", .dynamic = true, .hasSkeleton = true },
        .{ .path = "/old-docs", .dynamic = false, .hasSkeleton = false, .redirect = "/docs/guide" },
        .{ .path = "/docs/*", .dynamic = true, .hasSkeleton = false },
    };
    try std.testing.expect(findRedirectViolation(&routes) == null);
}

test "spa findRedirectViolation: an unmatched target is flagged with the offending entry" {
    const routes = [_]sidecar.RouteMeta{
        .{ .path = "/", .dynamic = false, .hasSkeleton = false, .redirect = "/nowhere" },
        .{ .path = "/dashboard", .dynamic = false, .hasSkeleton = false },
    };
    const v = findRedirectViolation(&routes).?;
    try std.testing.expect(v.reason == .no_match);
    try std.testing.expectEqualStrings("/", v.route_path);
    try std.testing.expectEqualStrings("/nowhere", v.target);
}

test "spa findRedirectViolation: a non-concrete target (:param, relative, query/hash) is flagged" {
    const cases = [_][]const u8{ "/club/:id", "dashboard", "/dash?tab=1", "/dash#top", "/club/..", "" };
    for (cases) |bad| {
        const routes = [_]sidecar.RouteMeta{
            .{ .path = "/", .dynamic = false, .hasSkeleton = false, .redirect = bad },
            .{ .path = "/dashboard", .dynamic = false, .hasSkeleton = false },
            .{ .path = "/club/:id", .dynamic = true, .hasSkeleton = false },
        };
        const v = findRedirectViolation(&routes).?;
        try std.testing.expect(v.reason == .not_concrete);
        try std.testing.expectEqualStrings(bad, v.target);
    }
}

test "spa findRedirectViolation: a self-redirect is a cycle" {
    const routes = [_]sidecar.RouteMeta{
        .{ .path = "/loop", .dynamic = false, .hasSkeleton = false, .redirect = "/loop" },
        .{ .path = "/dashboard", .dynamic = false, .hasSkeleton = false },
    };
    const v = findRedirectViolation(&routes).?;
    try std.testing.expect(v.reason == .cycle);
    try std.testing.expectEqualStrings("/loop", v.route_path);
}

test "spa findRedirectViolation: a 2-node redirect cycle is flagged" {
    const routes = [_]sidecar.RouteMeta{
        .{ .path = "/a", .dynamic = false, .hasSkeleton = false, .redirect = "/b" },
        .{ .path = "/b", .dynamic = false, .hasSkeleton = false, .redirect = "/a" },
        .{ .path = "/dashboard", .dynamic = false, .hasSkeleton = false },
    };
    const v = findRedirectViolation(&routes).?;
    try std.testing.expect(v.reason == .cycle);
    try std.testing.expectEqualStrings("/a", v.route_path); // first entry validated names the cycle
    try std.testing.expectEqualStrings("/b", v.target);
}

test "spa findRedirectViolation: a 3-node redirect cycle is flagged" {
    const routes = [_]sidecar.RouteMeta{
        .{ .path = "/a", .dynamic = false, .hasSkeleton = false, .redirect = "/b" },
        .{ .path = "/b", .dynamic = false, .hasSkeleton = false, .redirect = "/c" },
        .{ .path = "/c", .dynamic = false, .hasSkeleton = false, .redirect = "/a" },
        .{ .path = "/dashboard", .dynamic = false, .hasSkeleton = false },
    };
    const v = findRedirectViolation(&routes).?;
    try std.testing.expect(v.reason == .cycle);
    try std.testing.expectEqualStrings("/a", v.route_path);
}

test "spa findRedirectViolation: a chain ending at a concrete route is valid" {
    const routes = [_]sidecar.RouteMeta{
        .{ .path = "/a", .dynamic = false, .hasSkeleton = false, .redirect = "/b" },
        .{ .path = "/b", .dynamic = false, .hasSkeleton = false, .redirect = "/c" },
        .{ .path = "/c", .dynamic = false, .hasSkeleton = false },
    };
    try std.testing.expect(findRedirectViolation(&routes) == null);
}

test "spa findRedirectViolation: a chain ending at an unmatched target names the hop that declared it" {
    const routes = [_]sidecar.RouteMeta{
        .{ .path = "/a", .dynamic = false, .hasSkeleton = false, .redirect = "/b" },
        .{ .path = "/b", .dynamic = false, .hasSkeleton = false, .redirect = "/nowhere" },
        .{ .path = "/dashboard", .dynamic = false, .hasSkeleton = false },
    };
    const v = findRedirectViolation(&routes).?;
    try std.testing.expect(v.reason == .no_match);
    // The violation is attributed to the route that DECLARED the dead target
    // ("/b"), not the chain's entry point — that's the entry the author fixes.
    try std.testing.expectEqualStrings("/b", v.route_path);
    try std.testing.expectEqualStrings("/nowhere", v.target);
}

test "spa RouteMeta JSON parse: a describe payload with a redirect entry parses" {
    // The test itself leak-parses the describe payload (`parseFromSliceLeaky`
    // returns a graph with no `deinit`), so it needs a real arena and stays on
    // the §2.2a allowlist — nothing under test here is contract 1.
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const payload =
        \\{"id":1,"spa":{"base":"/app"},"routes":[{"path":"/","dynamic":false,"hasSkeleton":false,"redirect":"/dashboard"},{"path":"/dashboard","dynamic":false,"hasSkeleton":false}]}
    ;
    const Resp = struct {
        id: u64,
        spa: ?sidecar.SpaMeta = null,
        routes: ?[]const sidecar.RouteMeta = null,
        @"error": ?[]const u8 = null,
    };
    const resp = try std.json.parseFromSliceLeaky(Resp, arena, payload, .{ .ignore_unknown_fields = true });
    const routes = resp.routes.?;
    try std.testing.expectEqualStrings("/dashboard", routes[0].redirect.?);
    try std.testing.expect(routes[1].redirect == null);
    try std.testing.expect(findRedirectViolation(routes) == null);
}

test "claimStaticUrl accepts distinct URLs and reports a collision on a repeat" {
    // `claimStaticUrl` only allocates into the caller-owned table, so the caller
    // can deinit it: raw testing allocator, leak detection ON.
    const gpa = std.testing.allocator;

    var seen: StaticUrlSeen = .empty;
    defer seen.deinit(gpa); // keys/values are borrowed literals; only the table allocates

    // Two distinct URLs from two different routes: no collision.
    try std.testing.expect(try claimStaticUrl(gpa, &seen, "/app/booking/", "/booking") == null);
    try std.testing.expect(try claimStaticUrl(gpa, &seen, "/app/club/1/", "/club/:id") == null);

    // A different route's staticPaths entry collides with the declared
    // static route above.
    const collision = (try claimStaticUrl(gpa, &seen, "/app/booking/", "/club/:id")).?;
    try std.testing.expectEqualStrings("/app/booking/", collision.url);
    try std.testing.expectEqualStrings("/booking", collision.first_pattern);
    try std.testing.expectEqualStrings("/club/:id", collision.second_pattern);

    // Same route claiming the same URL twice (duplicate staticPaths entry):
    // first_pattern == second_pattern.
    const dup = (try claimStaticUrl(gpa, &seen, "/app/club/1/", "/club/:id")).?;
    try std.testing.expectEqualStrings("/app/club/1/", dup.url);
    try std.testing.expectEqualStrings("/club/:id", dup.first_pattern);
    try std.testing.expectEqualStrings("/club/:id", dup.second_pattern);
}

test "planRoute on a staticPaths concrete entry emits a static page under the pattern dir" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // A concrete entry is planned exactly like a hand-declared static route.
    const p = try planRoute(arena, "/app", .{ .path = "/club/1", .dynamic = false, .hasSkeleton = true });
    try std.testing.expectEqualStrings("app/club/1/index.html", p.out_path);
    try std.testing.expectEqualStrings("/app/club/1/", p.static_url.?);
    try std.testing.expect(p.dynamic == null);
    try std.testing.expectEqualStrings("/app/club/1", p.ssr_pathname);
}

test "deleteStaleSlicedRuntime leaves the runtime file alone on a still-sliced decision" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var spa_dir = try tmp.dir.createDirPathOpen(io, "spa", .{});
    defer spa_dir.close(io);
    var f = try spa_dir.createFile(io, "App-runtime.js", .{});
    f.close(io);

    try deleteStaleSlicedRuntime(io, gpa, tmp.dir, "App", false);
    try tmp.dir.access(io, "spa/App-runtime.js", .{}); // still present
}

// --- Output-path collision regression (two dynamic routes, one _shell.html) --
//
// `patternDir` stops at the first `:param`/`*` segment, so "/club/:id" and
// "/club/:id/details" plan the SAME `<base>/club/_shell.html`. Before the
// `out_path_seen` claim set, the second route silently overwrote the first's
// skeleton AND both shipped in the manifest's `dynamic` list, from which
// `emit-host-config.ts` derives one nginx `location` block PER PATTERN keyed on
// that same static prefix dir — two identical blocks, which nginx refuses to
// load. The pass now fatals on the repeat claim; these tests pin the two halves
// that fatal is built from (a `fatal.msg` call itself exits the process and
// cannot run inside a test).
//
// `planRoute` is contract 4 (`RenderArena`): a `PlannedRoute`'s strings are an
// interlinked graph with no `deinit`. It is exercised here through
// `RenderArena.forTest` over a stack `FixedBufferAllocator` — the pass lifetime
// without wrapping, and thereby DISABLING, the testing allocator's leak detector
// (NO_SLOP §2.2a / scripts/allocator-allowlist.txt).
test "two dynamic routes sharing a static prefix plan the same _shell.html output path" {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = RenderArena.forTest(fba.allocator());

    const club = try planRoute(a, "/app", .{ .path = "/club/:id", .dynamic = true, .hasSkeleton = true });
    const details = try planRoute(a, "/app", .{ .path = "/club/:id/details", .dynamic = true, .hasSkeleton = true });
    try std.testing.expectEqualStrings("app/club/_shell.html", club.out_path);
    // The collision itself: two DIFFERENT patterns, one output file.
    try std.testing.expectEqualStrings(club.out_path, details.out_path);
    try std.testing.expect(!std.mem.eql(u8, club.dynamic.?.pattern, details.dynamic.?.pattern));
}

test "the out-path claim set reports the shared-_shell.html collision with both patterns" {
    const gpa = std.testing.allocator;
    var seen: OutPathSeen = .empty;
    defer seen.deinit(gpa); // keys/values are borrowed literals; only the table allocates

    try std.testing.expect((try claimStaticUrl(gpa, &seen, "app/club/_shell.html", "/club/:id")) == null);
    const collision = (try claimStaticUrl(gpa, &seen, "app/club/_shell.html", "/club/:id/details")).?;
    try std.testing.expectEqualStrings("app/club/_shell.html", collision.url);
    try std.testing.expectEqualStrings("/club/:id", collision.first_pattern);
    try std.testing.expectEqualStrings("/club/:id/details", collision.second_pattern);

    // A dynamic shell and a static page under the same dir never collide.
    try std.testing.expect((try claimStaticUrl(gpa, &seen, "app/club/index.html", "/club")) == null);
}

test "claimOutPathOrFatal claims distinct output paths without colliding" {
    const gpa = std.testing.allocator;
    var seen: OutPathSeen = .empty;
    defer seen.deinit(gpa);

    try claimOutPathOrFatal(gpa, &seen, "app/App.spa.tsx", "app/index.html", "/");
    try claimOutPathOrFatal(gpa, &seen, "app/App.spa.tsx", "app/booking/index.html", "/booking");
    try claimOutPathOrFatal(gpa, &seen, "app/App.spa.tsx", "app/club/_shell.html", "/club/:id");
    try std.testing.expectEqual(@as(u32, 3), seen.count());
}

// --- Route path / base traversal regression ---------------------------------
//
// `rt.path` and `spa.base` flow into `patternDir`/`joinUrl` -> `diskJoin` ->
// `writeFile`'s `createDirPathOpen`, which resolves a `..` segment RELATIVE to
// the output dir — so an unvalidated `..` (a route path built from data, e.g.
// `"/docs/" + slug`, or `spa.base = "/../evil"`) wrote outside the output tree.
// Only `staticPaths` entries were validated before.
test "validateRoutePath rejects traversal and non-URL-safe segments" {
    // The escape the fix exists to stop.
    try std.testing.expect(!validateRoutePath("/docs/../../etc/passwd"));
    try std.testing.expect(!validateRoutePath("/.."));
    try std.testing.expect(!validateRoutePath("/docs/."));
    // Not absolute.
    try std.testing.expect(!validateRoutePath(""));
    try std.testing.expect(!validateRoutePath("docs/intro"));
    // Not percent-encoding-stable: written encoded to disk, never served by a
    // host that decodes before matching (same rule as staticPaths values).
    try std.testing.expect(!validateRoutePath("/docs/a%20b"));
    try std.testing.expect(!validateRoutePath("/docs/a b"));
    try std.testing.expect(!validateRoutePath("/docs/a?b=1"));
    try std.testing.expect(!validateRoutePath("/docs/a\\b"));
    // A ':param' with an unsafe name is still unsafe.
    try std.testing.expect(!validateRoutePath("/club/:.."));

    // Everything the router legitimately ships stays valid.
    try std.testing.expect(validateRoutePath("/"));
    try std.testing.expect(validateRoutePath("/booking"));
    try std.testing.expect(validateRoutePath("/club/:id"));
    try std.testing.expect(validateRoutePath("/club/:id/details"));
    try std.testing.expect(validateRoutePath("/admin/*"));
    try std.testing.expect(validateRoutePath("/a-b_c.d~e!f"));
    // Empty segments are skipped, not rejected: joinUrl/patternDir/the router
    // all skip them, so they can never reach a disk path.
    try std.testing.expect(validateRoutePath("/booking/"));
    try std.testing.expect(validateRoutePath("//booking"));
}

test "validateSpaBase accepts a root/absolute base and rejects traversal" {
    try std.testing.expect(validateSpaBase("")); // root-mounted (base "/" trims to "")
    try std.testing.expect(validateSpaBase("/app"));
    try std.testing.expect(validateSpaBase("/deep/app-2"));

    try std.testing.expect(!validateSpaBase("/../evil"));
    try std.testing.expect(!validateSpaBase("/app/.."));
    try std.testing.expect(!validateSpaBase("app")); // not absolute
    try std.testing.expect(!validateSpaBase("/a b"));
    // A base is a fixed namespace: no pattern segments.
    try std.testing.expect(!validateSpaBase("/:tenant"));
}

// --- Manifest `fallback` regression -----------------------------------------
//
// `fallback` used to be an unconditional "{base}/index.html" even when no route
// produced that file. With deploy_target nginx that emits
// `try_files $uri $uri/ /app/index.html;` naming a file that does not exist,
// and nginx answers EVERY unmatched URL with a 500 — not a 404.
test "chooseFallback names the root index only when a route actually produced it" {
    const gpa = std.testing.allocator;

    const with_root = (try chooseFallback(gpa, "/app", true, &.{})).?;
    defer gpa.free(with_root);
    try std.testing.expectEqualStrings("/app/index.html", with_root);

    // No "/" route: fall back to a shell that EXISTS (the first dynamic
    // pattern's), so an unmatched URL boots the SPA instead of erroring.
    const dynamics = [_]DynamicEntry{
        .{ .pattern = "/app/club/:id", .shell = "/app/club/_shell.html" },
        .{ .pattern = "/app/team/:id", .shell = "/app/team/_shell.html" },
    };
    const from_dynamic = (try chooseFallback(gpa, "/app", false, &dynamics)).?;
    defer gpa.free(from_dynamic);
    try std.testing.expectEqualStrings("/app/club/_shell.html", from_dynamic);

    // Neither: nothing this pass wrote can serve an unmatched URL — the caller
    // turns this null into a build error rather than shipping a dangling name.
    try std.testing.expect((try chooseFallback(gpa, "/app", false, &.{})) == null);
}

test "planRoute's \"/\" route writes exactly the disk path the root-index fallback names" {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = RenderArena.forTest(fba.allocator());

    // The equality `prerenderAll` keys `has_root_index` on, at both mount shapes.
    const mounted_root = try diskJoin(a.a, "app", "index.html");
    const mounted = try planRoute(a, "/app", .{ .path = "/", .dynamic = false, .hasSkeleton = false });
    try std.testing.expectEqualStrings(mounted_root, mounted.out_path);

    const site_root = try diskJoin(a.a, "", "index.html");
    const rooted = try planRoute(a, "", .{ .path = "/", .dynamic = false, .hasSkeleton = false });
    try std.testing.expectEqualStrings(site_root, rooted.out_path);

    // A non-root route must not be mistaken for the fallback's file.
    const booking = try planRoute(a, "/app", .{ .path = "/booking", .dynamic = false, .hasSkeleton = false });
    try std.testing.expect(!std.mem.eql(u8, mounted_root, booking.out_path));
}

// --- Multi-SPA spec validation regression (release CLI path) ----------------
//
// `zigapagos release --spa=a/A.spa.tsx|/app --spa=b/B.spa.tsx|/app` reached
// `prerenderAll` unchecked: `static_seen`/`out_path_seen` are per-SPA, so the
// second SPA overwrote ALL of the first's shells and its routing-manifest.json.
// build.zig's `validateSpas` catches this at configure time; the CLI is a
// first-class entry point and must catch it too.
test "findSpecViolation flags two SPAs mounted at the same base" {
    const specs = [_]root.SpaSpec{
        .{ .src = "a/A.spa.tsx", .base = "/app" },
        .{ .src = "b/B.spa.tsx", .base = "/app" },
    };
    const v = findSpecViolation(&specs).?;
    try std.testing.expect(v.reason == .base_overlap);
    try std.testing.expectEqualStrings("a/A.spa.tsx", v.first_src);
    try std.testing.expectEqualStrings("b/B.spa.tsx", v.second_src);
}

test "findSpecViolation flags a nested base and a root-mounted SPA alongside another" {
    const nested = [_]root.SpaSpec{
        .{ .src = "a/A.spa.tsx", .base = "/app" },
        .{ .src = "b/B.spa.tsx", .base = "/app/admin" },
    };
    try std.testing.expect(findSpecViolation(&nested).?.reason == .base_overlap);

    // A root-mounted SPA owns every path, so it overlaps any other base.
    const rooted = [_]root.SpaSpec{
        .{ .src = "a/A.spa.tsx", .base = "/" },
        .{ .src = "b/B.spa.tsx", .base = "/app" },
    };
    try std.testing.expect(findSpecViolation(&rooted).?.reason == .base_overlap);

    // A trailing slash is not a different namespace.
    const trailing = [_]root.SpaSpec{
        .{ .src = "a/A.spa.tsx", .base = "/app/" },
        .{ .src = "b/B.spa.tsx", .base = "/app" },
    };
    try std.testing.expect(findSpecViolation(&trailing).?.reason == .base_overlap);
}

test "findSpecViolation flags two SPAs whose basenames collide" {
    const specs = [_]root.SpaSpec{
        .{ .src = "a/App.spa.tsx", .base = "/app" },
        .{ .src = "b/App.spa.tsx", .base = "/admin" },
    };
    const v = findSpecViolation(&specs).?;
    try std.testing.expect(v.reason == .name_collision);
    try std.testing.expectEqualStrings("App", v.second_detail);
}

test "findSpecViolation passes disjoint specs and skips an undeclared (empty) base" {
    const ok = [_]root.SpaSpec{
        .{ .src = "a/App.spa.tsx", .base = "/app" },
        .{ .src = "b/Admin.spa.tsx", .base = "/admin" },
        // "/app-2" is not nested under "/app": overlap is per SEGMENT.
        .{ .src = "c/Two.spa.tsx", .base = "/app-2" },
    };
    try std.testing.expect(findSpecViolation(&ok) == null);

    // A hand-written `--spa=<src>` with no '|' carries no declared base
    // ("unknown", not "root"), so it cannot be compared — but its BASENAME
    // still must not collide.
    const unknown_base = [_]root.SpaSpec{
        .{ .src = "a/App.spa.tsx", .base = "" },
        .{ .src = "b/Admin.spa.tsx", .base = "/app" },
    };
    try std.testing.expect(findSpecViolation(&unknown_base) == null);

    const unknown_base_same_name = [_]root.SpaSpec{
        .{ .src = "a/App.spa.tsx", .base = "" },
        .{ .src = "b/App.spa.tsx", .base = "" },
    };
    try std.testing.expect(findSpecViolation(&unknown_base_same_name).?.reason == .name_collision);
}

// The chunk/slice manifest structs declare ONLY the keys this pass reads; both
// parses set `ignore_unknown_fields`, so the driver's other keys (`entry`,
// `chunks`, `members`) need no dead placeholder fields. This pins the parse
// contract that deleting them relies on.
test "spa chunk/slice manifests parse with unread driver keys present" {
    const gpa = std.testing.allocator;

    const chunks_json =
        \\{"entry":"/spa/App.js","chunks":["/spa/Heavy-abc.js"],
        \\ "routeChunks":{"/heavy":"Heavy-abc.js"}}
    ;
    const chunks = try std.json.parseFromSlice(ChunksJson, gpa, chunks_json, .{ .ignore_unknown_fields = true });
    defer chunks.deinit();
    try std.testing.expectEqualStrings("Heavy-abc.js", chunks.value.routeChunks.map.get("/heavy").?);

    const slice_json =
        \\{"runtime":"/spa/App-runtime.js","fallback":false,"members":["router","flags"]}
    ;
    const slice = try std.json.parseFromSlice(SliceJson, gpa, slice_json, .{ .ignore_unknown_fields = true });
    defer slice.deinit();
    try std.testing.expectEqualStrings("/spa/App-runtime.js", slice.value.runtime.?);
}
