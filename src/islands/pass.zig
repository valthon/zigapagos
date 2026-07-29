const std = @import("std");
const builtin = @import("builtin");
const props = @import("props.zig");
const sidecar = @import("sidecar.zig");
const RenderArena = @import("render_arena.zig").RenderArena;

// --- public types ---

/// A named slot's already-rendered inner HTML, partitioned out of an island's
/// children by `collectSlots`. (Was `zigapagos.ssr.Slot` when islands rendered
/// in-process; now islands render via the Bun sidecar, so this is a local type.)
pub const Slot = struct { name: []const u8, html: []const u8 };

pub const IslandInstance = struct {
    id: []const u8,
    src: []const u8,
    client: []const u8,
    props_json: []const u8,
    module_url: []const u8,
};

/// The import map injected into the `<head>` of any page that contains islands,
/// mapping bare specifiers used by island modules. Must precede any module script.
/// The `react`/`react-dom` entries back the opt-in npm-compat bridge: an
/// allowlisted npm React component's `import … from "react"` is kept external in
/// the island/SPA bundle and resolves here to the shared runtime (full
/// preact/compat surface) — ONE Preact. Entries are inert unless such a bundle
/// actually imports them.
pub const import_map =
    "<script type=\"importmap\">{\"imports\":{\"@z/runtime\":\"/zigapagos-runtime.js\",\"@z/runtime/jsx-runtime\":\"/zigapagos-runtime.js\",\"@z/runtime/jsx-dev-runtime\":\"/zigapagos-runtime.js\",\"@z/runtime/compat\":\"/zigapagos-runtime.js\",\"@z/runtime/compat/client\":\"/zigapagos-runtime.js\",\"react\":\"/zigapagos-runtime.js\",\"react-dom\":\"/zigapagos-runtime.js\",\"react-dom/client\":\"/zigapagos-runtime.js\",\"react/jsx-runtime\":\"/zigapagos-runtime.js\",\"react/jsx-dev-runtime\":\"/zigapagos-runtime.js\"}}</script>";

/// The `<script>` injected into the `<head>` of any page that contains islands,
/// loading the client hydration runtime. Injected before `</head>`.
pub const runtime_script = "<script type=\"module\" src=\"/zigapagos-runtime.js\"></script>";

/// The `<link rel="modulepreload">` injected into the `<head>` of any page that
/// contains islands, hinting the browser to fetch the shared runtime in parallel
/// with HTML parse. Placed AFTER the import map: a modulepreload starts module
/// loading, and the import-maps spec only honors a map that precedes that.
pub const runtime_preload = "<link rel=\"modulepreload\" href=\"/zigapagos-runtime.js\">";

/// The shared runtime URL that the constants above hard-code. A SPA whose runtime
/// is SLICED points its shell at `/spa/<name>-runtime.js` instead
/// via the `*For` generators below; islands + fallback SPAs keep this one.
pub const shared_runtime_url = "/zigapagos-runtime.js";

/// The page import map, but pointing every `@z/runtime`/`react` specifier at
/// `runtime_url`. For `shared_runtime_url` this reproduces `import_map`
/// byte-for-byte (asserted by a test below); a per-SPA sliced runtime passes its
/// own `/spa/<name>-runtime.js`. The specifier set/order matches `import_map`.
///
/// NO_SLOP.md §2.2a contract 1 (so: plain `Allocator`, not `RenderArena`) — one
/// `allocPrint` escapes and nothing else is allocated. Arena-scoped callers reach
/// it through `RenderArena.a`.
pub fn importMapFor(alloc: std.mem.Allocator, runtime_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "<script type=\"importmap\">{{\"imports\":{{" ++
            "\"@z/runtime\":\"{[u]s}\"," ++
            "\"@z/runtime/jsx-runtime\":\"{[u]s}\"," ++
            "\"@z/runtime/jsx-dev-runtime\":\"{[u]s}\"," ++
            "\"@z/runtime/compat\":\"{[u]s}\"," ++
            "\"@z/runtime/compat/client\":\"{[u]s}\"," ++
            "\"react\":\"{[u]s}\"," ++
            "\"react-dom\":\"{[u]s}\"," ++
            "\"react-dom/client\":\"{[u]s}\"," ++
            "\"react/jsx-runtime\":\"{[u]s}\"," ++
            "\"react/jsx-dev-runtime\":\"{[u]s}\"" ++
            "}}}}</script>",
        .{ .u = runtime_url },
    );
}

/// `runtime_script`, but for an arbitrary runtime URL (see `importMapFor`).
/// Contract 1.
pub fn runtimeScriptFor(alloc: std.mem.Allocator, runtime_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "<script type=\"module\" src=\"{s}\"></script>", .{runtime_url});
}

/// `runtime_preload`, but for an arbitrary runtime URL (see `importMapFor`).
/// Contract 1.
pub fn runtimePreloadFor(alloc: std.mem.Allocator, runtime_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "<link rel=\"modulepreload\" href=\"{s}\">", .{runtime_url});
}

/// One failed island SSR render, recorded into the caller-owned
/// `ProcessOptions.render_errors` sink so the caller can surface it — at .err,
/// attributed to the page — with the failing component, its route, and the JS
/// message + source-mapped stack. All string fields are owned by the `arena`
/// passed to `process` (the caller reads them before that arena is freed).
pub const RenderErrorReport = struct {
    /// The failing island's `src` attribute (e.g. "components/Widget.island.tsx").
    src: []const u8,
    /// The page/route being rendered when it failed (the `page_url`).
    route: []const u8,
    /// The sidecar's `err.message`.
    message: []const u8,
    /// The sidecar's `err.stack`, source-mapped when a map is available.
    stack: ?[]const u8,
};

/// How the island pass reacts when an island's SSR render throws.
/// The build picks the policy by mode: a release/deploy build FAILS so broken
/// output never ships; a dev build keeps going with a visible placeholder so
/// the author sees which island broke without the whole page collapsing.
pub const OnRenderError = enum {
    /// Propagate the error so the caller fails the build (release/deploy_target).
    fail,
    /// Emit a visible inline placeholder carrying the error and CONTINUE the
    /// page render (dev serve) — a warning, not a hard failure.
    placeholder,
};

/// Options threaded through `process` for a single page render.
pub const ProcessOptions = struct {
    /// The site's `url_path_prefix` (see `root.Site.url_path_prefix`), e.g.
    /// "zigapagos" when the site is served from a GitHub Pages project path
    /// (`https://<user>.github.io/zigapagos/`). Empty (the default) means the
    /// site is served from the host root, and `process`'s output is
    /// byte-identical to the pre-prefix behavior (see `prefixed`).
    url_prefix: []const u8 = "",
    /// What to do when an island's SSR render throws. Defaults to
    /// `.fail` — the safe release behavior — so callers that don't opt into the
    /// dev placeholder path (and every existing test) keep loud-failing.
    on_render_error: OnRenderError = .fail,
    /// Optional caller-owned sink for structured render errors.
    /// When set, `process` appends one `RenderErrorReport` per failed island —
    /// for BOTH policies — so the caller surfaces the JS message + stack (at
    /// .err, with page context) instead of pass.zig logging directly. Appended
    /// with `gpa`; string fields are owned by the `arena` passed to `process`.
    render_errors: ?*std.ArrayListUnmanaged(RenderErrorReport) = null,
};

/// Prepend `/` + `prefix` to `url` (e.g. `prefixed(alloc, "zigapagos", "/foo.js")`
/// -> `"/zigapagos/foo.js"`). `prefix` is trimmed of leading/trailing '/' first
/// (the site's `url_path_prefix` legitimately permits a trailing slash — see
/// `root.validatePath` — and `serve.zig` strips it the same way), so
/// "zigapagos/", "/zigapagos", and "zigapagos" all join identically, and "/"
/// normalizes to empty. An empty trimmed `prefix` yields `url`'s BYTES
/// unchanged, which is what keeps the empty-prefix path byte-identical to the
/// pre-`ProcessOptions` output.
///
/// NO_SLOP.md §2.2a contract 1: the return is always an owned allocation — the
/// empty-prefix case dupes rather than borrowing `url`, so a caller can free the
/// result unconditionally instead of having to know which branch ran. (It used
/// to borrow, which is only sound when nobody ever frees — i.e. it silently
/// required an arena. One small dupe per island module URL buys a signature that
/// is true under any allocator.)
pub fn prefixed(alloc: std.mem.Allocator, prefix: []const u8, url: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, prefix, "/");
    if (trimmed.len == 0) return alloc.dupe(u8, url);
    return std.fmt.allocPrint(alloc, "/{s}{s}", .{ trimmed, url });
}

test "importMapFor/runtimeScriptFor/runtimePreloadFor reproduce the shared constants byte-for-byte" {
    // Contract-1 helpers, so: raw testing allocator, leak detection ON.
    const gpa = std.testing.allocator;
    const map = try importMapFor(gpa, shared_runtime_url);
    defer gpa.free(map);
    const script = try runtimeScriptFor(gpa, shared_runtime_url);
    defer gpa.free(script);
    const preload = try runtimePreloadFor(gpa, shared_runtime_url);
    defer gpa.free(preload);
    try std.testing.expectEqualStrings(import_map, map);
    try std.testing.expectEqualStrings(runtime_script, script);
    try std.testing.expectEqualStrings(runtime_preload, preload);
}

test "importMapFor points every specifier at a sliced runtime URL" {
    const gpa = std.testing.allocator;
    const map = try importMapFor(gpa, "/spa/public-runtime.js");
    defer gpa.free(map);
    // no residual shared-runtime target, and @z/runtime routes to the slice
    try std.testing.expect(std.mem.indexOf(u8, map, shared_runtime_url) == null);
    try std.testing.expect(std.mem.indexOf(u8, map, "\"@z/runtime\":\"/spa/public-runtime.js\"") != null);
}

/// Build the modulepreload <link> block for a page's islands: the shared runtime
/// first, then one link per UNIQUE island module_url (first-seen order). Returns ""
/// when there are no islands. Deduped so two instances of the same component emit
/// one link; client:only modules are included (imported at mount).
///
/// NO_SLOP.md §2.2a contract 1: the dedup set and the prefixed-URL scratch are
/// freed here and exactly one allocation escapes (`""` for the no-island case is
/// a zero-length free, which `Allocator.free` short-circuits), so this is correct
/// under any allocator — not just under the pass arena its caller passes.
fn preloadLinks(alloc: std.mem.Allocator, instances: []const IslandInstance, url_prefix: []const u8) ![]u8 {
    if (instances.len == 0) return "";
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    // Fast path: with no prefix, use the precomputed constant (byte-identical
    // to the pre-`ProcessOptions` output).
    if (url_prefix.len == 0) {
        try out.appendSlice(alloc, runtime_preload);
    } else {
        const runtime_url = try prefixed(alloc, url_prefix, shared_runtime_url);
        defer alloc.free(runtime_url);
        const link = try runtimePreloadFor(alloc, runtime_url);
        defer alloc.free(link);
        try out.appendSlice(alloc, link);
    }
    for (instances) |inst| {
        const gop = try seen.getOrPut(alloc, inst.module_url);
        if (gop.found_existing) continue;
        try out.print(alloc, "<link rel=\"modulepreload\" href=\"{s}\">", .{inst.module_url});
    }
    return out.toOwnedSlice(alloc);
}

/// The html field is gpa-owned. All IslandInstance fields (id, src, client,
/// props_json) and the instances slice itself are arena-owned and live as long
/// as the `arena` passed to `process`. They are independent of the input `html`
/// slice and of each other.
pub const Result = struct {
    html: []u8,
    instances: []IslandInstance,
};

/// Build a VISIBLE inline placeholder for an island whose SSR render threw —
/// dev serve only (`OnRenderError.placeholder`). Shows the failing island's
/// `src` and the sidecar's JS message in place, so the author sees exactly what
/// broke instead of the content being silently omitted. The full
/// stack goes to the build log; the placeholder stays compact. Returns gpa-owned
/// HTML (freed by the caller like a normal SSR result).
fn renderErrorPlaceholder(gpa: std.mem.Allocator, src: []const u8, rerr: sidecar.RenderError) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "<div data-z-island-error role=\"alert\" style=\"" ++
        "border:2px solid #c00;background:#fff5f5;color:#900;" ++
        "padding:.75rem 1rem;margin:.5rem 0;font:13px/1.5 ui-monospace,monospace\">" ++
        "<strong>Island failed to render:</strong> ");
    try appendHtmlEscaped(gpa, &out, src);
    try out.appendSlice(gpa, "<br>");
    try appendHtmlEscaped(gpa, &out, if (rerr.message.len > 0) rerr.message else "(no message)");
    try out.appendSlice(gpa, "</div>");
    return out.toOwnedSlice(gpa);
}

/// Append `s` to `out` with the HTML-special chars escaped, so a JS error
/// message (untrusted-ish, may contain `<`/`>`/`&`/`"`) can't break out of the
/// placeholder markup.
fn appendHtmlEscaped(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        else => try out.append(gpa, c),
    };
}

// --- implementation ---

/// Rewrite every <island ...>...</island> (or self-closing <island ... />) in
/// `html` to the ratified placeholder markup with SSR'd component HTML and a
/// JSON props script. `renderer` is any value with a
/// `pub fn render(self, arena, src, props_json, slots_json, pathname, err_out) ![]const u8` method
/// (the real `Sidecar`, or a test stub). `dispatch`/`dispatchProps` and the
/// comptime registry are gone; props are resolved type-erased via
/// `props.resolveToJson`.
///
/// Props-quoting contract: `src` and other simple attributes use double-quote
/// delimiters (`attr="value"`). The `:props` attribute uses SINGLE-quote
/// delimiters (`:props='...'`) so that inner double-quotes in Ziggy struct
/// literals (e.g. `{ .label = "hi" }`) do not terminate the attribute early.
///
/// Lifetime: `result.instances` and all their string fields are arena-owned and
/// live as long as the `arena` passed in. They are independent of the input
/// `html` slice and of `result.html` (which is gpa-owned).
///
/// NO_SLOP.md §2.2a: TWO allocators, two contracts, on purpose. `result.html` is
/// contract 1 over `gpa` — one owned buffer the caller frees. `arena` is contract
/// 4 (`RenderArena`): `result.instances` is an interlinked graph — a slice of
/// `IslandInstance`s whose every field is a separate allocation, several of them
/// (`props_json`) built by `props.resolveToJson` on top of leak-parsed trees with
/// no `deinit` (1); freeing it would mean walking the slice to free five fields
/// each, plus the parse trees that cannot be freed at all (2); and it dies with
/// the page render, which is exactly when the caller stops reading it (3).
pub fn process(
    gpa: std.mem.Allocator,
    arena: RenderArena,
    html: []const u8,
    /// The URL path of the page being rendered (e.g. "/", "/about/"). Exposed to
    /// islands during SSR via `z.host.pathname()` so path-aware components render
    /// the same on the server as they will on the client (`window.location`).
    page_url: []const u8,
    renderer: anytype,
    opts: ProcessOptions,
) !Result {
    var instances: std.ArrayListUnmanaged(IslandInstance) = .empty;
    // instances items are arena-owned; the slice itself is too
    errdefer instances.deinit(arena.a);

    var counter: usize = 0;
    var body = try rewrite(gpa, arena, html, renderer, page_url, &instances, &counter, opts.url_prefix, opts.on_render_error, opts.render_errors);

    // If the page has islands, inject the hydration runtime <script> before
    // </head> (build-output injection: the static output is self-contained).
    if (instances.items.len > 0) {
        if (std.mem.indexOf(u8, body, "</head>")) |head_end| {
            var injected: std.ArrayListUnmanaged(u8) = .empty;
            errdefer injected.deinit(gpa);
            try injected.appendSlice(gpa, body[0..head_end]);
            // The import map must be emitted before ANY modulepreload: per the
            // import-maps spec, a map is only processed if it appears before any
            // module loading starts, and a <link rel="modulepreload"> starts one.
            // A later map is silently disregarded by the browser — cache-state
            // flaky, since a cold cache usually loses the race to parse the map
            // first while a warm one wins it and breaks.
            // Fast path: with no prefix, use the precomputed constants so the
            // output is byte-identical to the pre-`ProcessOptions` behavior.
            if (opts.url_prefix.len == 0) {
                try injected.appendSlice(gpa, import_map);
                // `preloadLinks`/`importMapFor`/`runtimeScriptFor`/`prefixed` are
                // contract 1, reached through `arena.a` — the sanctioned bridge.
                // Their results are copied into `injected` and then dead; this
                // function is contract 4, so the arena drop reclaims them.
                try injected.appendSlice(gpa, try preloadLinks(arena.a, instances.items, opts.url_prefix));
                try injected.appendSlice(gpa, runtime_script);
            } else {
                const runtime_url = try prefixed(arena.a, opts.url_prefix, shared_runtime_url);
                try injected.appendSlice(gpa, try importMapFor(arena.a, runtime_url));
                try injected.appendSlice(gpa, try preloadLinks(arena.a, instances.items, opts.url_prefix));
                try injected.appendSlice(gpa, try runtimeScriptFor(arena.a, runtime_url));
            }
            try injected.appendSlice(gpa, body[head_end..]);
            gpa.free(body);
            body = try injected.toOwnedSlice(gpa);
        }
    }

    return .{
        .html = body,
        .instances = try instances.toOwnedSlice(arena.a),
    };
}

/// Rewrite every `<island>` in `html` to its placeholder markup, recursing into
/// slot content so nested islands are also rewritten/SSR'd/hydrated. Appends each
/// island (outer and nested) to `instances` and advances the shared `counter`
/// (which assigns the unique `z-island-N` ids). Returns gpa-owned html. The
/// runtime-script injection happens once in `process`, not here.
///
/// Regions where the HTML tokenizer does not parse markup — comments and
/// raw-text elements — are skipped by `nextIslandStart` and copied through
/// VERBATIM, so a commented-out island is not SSR'd, not bundled, and does not
/// mark the page as having islands (which is what keeps the "no island on the
/// page? zero JavaScript shipped" guarantee true).
fn rewrite(
    gpa: std.mem.Allocator,
    arena: RenderArena,
    html: []const u8,
    renderer: anytype,
    page_url: []const u8,
    instances: *std.ArrayListUnmanaged(IslandInstance),
    counter: *usize,
    url_prefix: []const u8,
    on_render_error: OnRenderError,
    render_errors: ?*std.ArrayListUnmanaged(RenderErrorReport),
) anyerror![]u8 {
    // anyerror: this function is recursive (slot content is re-processed), which
    // rules out an inferred error set; the union of renderer/print/ziggy errors is
    // wide, and `process`'s callers already handle errors generically.

    // The pathname an island's SSR sees (`host.pathname()` / `useLocation()`).
    // It must be the pathname a REAL BROWSER reports, which on a site with a
    // `url_path_prefix` carries that prefix — the same parity the SPA route
    // pass already has (src/spa.zig prefixes its `ssr_pathname`). Without this
    // an island on a prefixed site server-rendered against "/guides" while the
    // browser reported "/myrepo/guides", so any island branching on the path
    // (active-nav highlighting, breadcrumbs) rendered one thing at build time
    // and another after hydration — and Preact's hydrate() does not repair a
    // mismatched attribute.
    //
    // Derived from the UNPREFIXED `page_url` rather than reassigning it,
    // because this function recurses for slot content and passes `page_url`
    // down: prefixing in place would double-prefix at every nested level.
    // `prefixed` with an empty prefix returns the path unchanged, so an
    // unprefixed site is byte-for-byte unaffected.
    const ssr_pathname = try prefixed(arena.a, url_prefix, page_url);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (nextIslandStart(html, i)) |start| {
        // Copy everything before this island tag — including any comment or
        // raw-text region the scan stepped over, which passes through unmodified.
        try out.appendSlice(gpa, html[i..start]);

        // Find the end of the opening tag's '>' (quote-aware, so a `>` inside a
        // quoted attribute value like `:props='{ .x = "a > b" }'` doesn't end it).
        // Note: a single-quoted `:props` value cannot itself contain a literal `'`.
        const open_end = tagEnd(html, start) orelse return error.MalformedIsland;
        const tag_text = html[start .. open_end + 1];
        const self_closing = open_end > 0 and html[open_end - 1] == '/';

        // Capture the inner HTML (already rendered by SuperHTML) as slot content,
        // matching the `</island>` that closes THIS tag (skipping nested islands).
        var consume_end: usize = open_end + 1;
        var slot_html: []const u8 = "";
        if (!self_closing) {
            const close = matchingClose(html, open_end + 1) orelse return error.MalformedIsland;
            slot_html = std.mem.trim(u8, html[open_end + 1 .. close], " \t\r\n");
            consume_end = close + "</island>".len;
        }

        // Extract attributes.
        // attrDouble/attrSingle return slices into tag_text (which aliases html);
        // we arena-dupe them below so every IslandInstance field is arena-owned
        // and independent of the input html slice.
        const src_raw = (attrDouble(tag_text, "src")) orelse return error.IslandMissingSrc;
        const cd = clientDirective(tag_text) orelse Client{ .name = "" };
        try validateClientDirective(cd);
        // :props uses single-quote delimiters to allow inner double-quotes.
        const props_src = attrSingle(tag_text, ":props") orelse "";

        const id = try std.fmt.allocPrint(arena.a, "z-island-{d}", .{counter.*});
        counter.* += 1;

        // Arena-dupe src and client so all IslandInstance fields are arena-owned.
        const src = try arena.a.dupe(u8, src_raw);
        const client = try arena.a.dupe(u8, cd.name);
        // `moduleUrl`/`prefixed` are contract 1, reached through `.a`.
        const module_url = try prefixed(arena.a, url_prefix, try moduleUrl(arena.a, src));
        const is_only = std.mem.eql(u8, cd.name, "only");

        // Recurse into the slot content so any nested `<island>` is rewritten to
        // its placeholder + SSR'd + counted (sharing this counter/instances). The
        // rewritten slot is what goes into the slots_json / the sidecar slots
        // argument; the runtime hydrates the nested island independently.
        const slot_rewritten = if (slot_html.len > 0)
            try rewrite(gpa, arena, slot_html, renderer, page_url, instances, counter, url_prefix, on_render_error, render_errors)
        else
            try gpa.dupe(u8, "");
        defer gpa.free(slot_rewritten);

        // Partition slot content into named and default slots for the sidecar slots argument.
        const slots = try collectSlots(arena, slot_rewritten);
        // Dynamic props: prop-NAME="value" attrs (SuperHTML already evaluated any
        // $scripty values), coerced to the Props field types, override :props.
        const dyn = try collectDynProps(arena, tag_text);

        // Resolve props ONCE (type-erased) — used for both the SSR call and the
        // client <script>.
        const props_json = try props.resolveToJson(arena, props_src, dyn);

        // client:only is NOT server-rendered (placeholder starts empty; the
        // component mounts fresh on the client). All other directives SSR the
        // component so content is present without JS. props are always emitted.
        const slots_json = try slotsToJson(arena.a, slots);
        const rendered = if (is_only)
            try gpa.dupe(u8, "")
        else blk: {
            // Capture the sidecar's structured error (message + source-mapped
            // stack) so a failed render is surfaced with context, not
            // swallowed. `renderer` is duck-typed, but every real renderer
            // fills `err_out` on `error.SidecarRenderFailed`; stubs ignore it.
            var rerr: sidecar.RenderError = .{};
            const html_out = renderer.render(arena, src, props_json, slots_json, ssr_pathname, &rerr) catch |err| {
                // Record which island/route broke, with the JS message + stack,
                // into the caller-owned sink. The CALLER logs it (at .err, with
                // page-path context) — pass.zig deliberately does not log here so
                // the error paths stay unit-testable without tripping the test
                // runner's logged-error check.
                if (render_errors) |sink| try sink.append(gpa, .{
                    .src = src,
                    .route = page_url,
                    .message = rerr.message,
                    .stack = rerr.stack,
                });
                switch (on_render_error) {
                    // release/deploy: fail the build (caller sets any_rendering_error).
                    .fail => return err,
                    // dev serve: keep going with a visible placeholder so the
                    // author sees the broken island instead of blank output.
                    .placeholder => break :blk try renderErrorPlaceholder(gpa, src, rerr),
                }
            };
            break :blk try gpa.dupe(u8, html_out); // match the existing gpa-owned contract
        };
        defer gpa.free(rendered);

        // client:media carries a query, emitted as data-z-media for the runtime.
        const media_attr = if (cd.value) |v|
            try std.fmt.allocPrint(arena.a, " data-z-media=\"{s}\"", .{v})
        else
            "";

        // The sidecar has already woven slot HTML into the SSR output (rendered);
        // pass.zig no longer appends manual <z-slot> wrappers (that was the double-wrap).
        // Instead, emit a data-z-slots JSON script when slots are present so the
        // client runtime can adopt slot content on hydration. client:only also gets
        // the script — the client needs slot HTML for the fresh mount.
        try out.print(
            gpa,
            "<div data-z-island id=\"{s}\" data-z-src=\"{s}\" data-z-client=\"{s}\"{s} data-z-module=\"{s}\">{s}</div>" ++
                "<script type=\"application/json\" data-z-props=\"{s}\">{s}</script>",
            .{ id, src, client, media_attr, module_url, rendered, id, props_json },
        );
        if (slots.len > 0) {
            try out.print(
                gpa,
                "<script type=\"application/json\" data-z-slots=\"{s}\">{s}</script>",
                .{ id, slots_json },
            );
        }

        try instances.append(arena.a, .{
            .id = id,
            .src = src,
            .client = client,
            .props_json = props_json,
            .module_url = module_url,
        });
        i = consume_end;
    }
    // Copy any trailing HTML after the last island.
    try out.appendSlice(gpa, html[i..]);

    return out.toOwnedSlice(gpa);
}

/// True when `c` terminates an HTML tag name. This is the word-boundary check
/// that stops `<islandfoo>` from matching `<island` (and `<scripts>` from
/// matching `<script`).
fn isTagNameBoundary(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '>', '/' => true,
        else => false,
    };
}

/// Element names whose content the HTML tokenizer does NOT parse as markup:
/// `script`/`style` are raw text and `textarea`/`title` are escapable raw text
/// (HTML spec §13.2.5). An `<island` inside one of these is text, not a tag.
const raw_text_tags = [_][]const u8{ "script", "style", "textarea", "title" };

/// Index of the next REAL `<island` open tag at or after `from`, or null if
/// there is none. Regions where an `<island` is not markup are stepped over:
///
///   * HTML comments — `<!-- <island … /> -->` must ship no JavaScript.
///   * raw-text elements (`raw_text_tags`) — `<script>"<island …>"</script>`.
///
/// The caller copies everything between its cursor and the returned index
/// verbatim, so skipped regions survive byte-for-byte (this pass runs on
/// already-rendered SuperHTML output, where byte parity matters).
///
/// Unterminated input (a comment with no `-->`, a `<script>` with no
/// `</script>`) is treated as extending to end-of-input: the function returns
/// null, the caller copies the remainder unchanged, and no bytes are lost. That
/// is deliberately not an error — this pass rewrites islands, it does not
/// validate the document, and a malformed region must not fail a build over
/// markup that contains no island at all.
fn nextIslandStart(html: []const u8, from: usize) ?usize {
    var p = from;
    while (std.mem.indexOfScalarPos(u8, html, p, '<')) |lt| {
        if (std.mem.startsWith(u8, html[lt..], "<!--")) {
            p = commentEnd(html, lt) orelse return null; // always > lt
            continue;
        }
        if (rawTextEnd(html, lt)) |end| {
            p = end; // always > lt, so the scan makes progress
            continue;
        }
        if (std.mem.startsWith(u8, html[lt..], "<island")) {
            const word_end = lt + "<island".len;
            if (word_end < html.len and isTagNameBoundary(html[word_end])) return lt;
            p = word_end; // truncated `<island` at EOF, or a false match like `<islandish>`
            continue;
        }
        p = lt + 1;
    }
    return null;
}

/// Index just past the end of the HTML comment starting at `lt` (which the
/// caller has checked begins with `<!--`), or null when it is never closed.
///
/// All the terminators a browser honors are recognized, not just `-->`: the
/// abrupt-closing empty comments `<!-->` / `<!--->` and the `--!>` end-bang form
/// (HTML spec §13.2.5.43-51). Getting these wrong would be a NEW way to lose an
/// island — everything after a comment the browser considers closed would stop
/// being scanned, silently shipping a page whose islands never hydrate.
fn commentEnd(html: []const u8, lt: usize) ?usize {
    var p = lt + "<!--".len;
    if (p < html.len and html[p] == '>') return p + 1; // <!-->
    if (p + 1 < html.len and html[p] == '-' and html[p + 1] == '>') return p + 2; // <!--->
    while (std.mem.indexOfPos(u8, html, p, "--")) |dashes| {
        const after = dashes + 2;
        if (after < html.len and html[after] == '>') return after + 1; // -->
        if (after + 1 < html.len and html[after] == '!' and html[after + 1] == '>') return after + 2; // --!>
        p = dashes + 1; // so `--->` is found by the second dash pair
    }
    return null;
}

/// If `lt` (the index of a '<') opens a raw-text element, return the index just
/// past that element's close tag; `html.len` when it is never closed (see
/// `nextIslandStart`'s unterminated-input contract). Returns null when `lt` does
/// not open such an element. Tag names are matched ASCII-case-insensitively,
/// since HTML tag names are.
fn rawTextEnd(html: []const u8, lt: usize) ?usize {
    for (raw_text_tags) |name| {
        const name_end = lt + 1 + name.len;
        if (name_end > html.len) continue;
        if (!std.ascii.eqlIgnoreCase(html[lt + 1 .. name_end], name)) continue;
        // `name_end == html.len` is a truncated open tag: nothing follows it.
        if (name_end < html.len and !isTagNameBoundary(html[name_end])) continue;
        const open_end = tagEnd(html, lt) orelse return html.len;
        return closeTagEnd(html, open_end + 1, name);
    }
    return null;
}

/// Index just past the `</name…>` that closes a raw-text element whose content
/// begins at `from`, or `html.len` when there is none.
fn closeTagEnd(html: []const u8, from: usize, name: []const u8) usize {
    var p = from;
    while (std.mem.indexOfScalarPos(u8, html, p, '<')) |lt| {
        const name_start = lt + 2;
        const name_end = name_start + name.len;
        if (name_end <= html.len and html[lt + 1] == '/' and
            std.ascii.eqlIgnoreCase(html[name_start..name_end], name) and
            (name_end == html.len or isTagNameBoundary(html[name_end])))
        {
            const gt = std.mem.indexOfScalarPos(u8, html, name_end, '>') orelse return html.len;
            return gt + 1;
        }
        p = lt + 1;
    }
    return html.len;
}

/// Quote-aware index of the '>' that ends the tag starting at `start`. Quotes
/// (single or double) are skipped so a `>` inside an attribute value doesn't end
/// the tag early. Returns null if there is no closing '>'.
fn tagEnd(html: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < html.len) : (pos += 1) {
        const ch = html[pos];
        if (ch == '>') return pos;
        if (ch == '\'' or ch == '"') {
            pos += 1;
            while (pos < html.len and html[pos] != ch) : (pos += 1) {}
        }
    }
    return null;
}

/// Index of the `</island>` that matches an `<island>` whose content begins at
/// `from`, skipping balanced nested islands. Self-closing nested islands don't
/// nest. Returns null if no matching close exists. ("</island>" never matches the
/// "<island" open-tag needle, since the char after '<' is '/', not 'i'.)
fn matchingClose(html: []const u8, from: usize) ?usize {
    var depth: usize = 0;
    var p = from;
    while (p < html.len) {
        const close = std.mem.indexOfPos(u8, html, p, "</island>") orelse return null;
        // Find the first *real* nested `<island ...>` opening before this close.
        var nested: ?usize = null;
        var scan = p;
        while (std.mem.indexOfPos(u8, html, scan, "<island")) |o| {
            if (o >= close) break;
            const we = o + "<island".len;
            const is_tag = we < html.len and switch (html[we]) {
                ' ', '\t', '\n', '\r', '>', '/' => true,
                else => false,
            };
            if (is_tag) {
                nested = o;
                break;
            }
            scan = we; // false match (e.g. <islandish>); keep looking before close
        }
        if (nested) |o| {
            const oe = tagEnd(html, o) orelse return null;
            if (!(oe > 0 and html[oe - 1] == '/')) depth += 1; // self-closing doesn't nest
            p = oe + 1;
        } else if (depth == 0) {
            return close;
        } else {
            depth -= 1;
            p = close + "</island>".len;
        }
    }
    return null;
}

/// Map a component `src` to the URL of its bundled JS module.
/// "components/Hero.island.tsx" -> "/islands/Hero.island.js". Contract 1.
fn moduleUrl(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var name = src;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[0..dot]; // strip final ext
    return std.fmt.allocPrint(alloc, "/islands/{s}.js", .{name});
}

/// Collect `prop-NAME="value"` attributes from the island open tag.
///
/// NO_SLOP.md §2.2a contract 4 (`RenderArena`): the result is a slice of `Pair`s
/// each owning two more allocations, with no `deinit` (1); the pairs are consumed
/// by `props.resolveToJson` a few lines after they are built and then dead, so
/// per-pair frees would be bookkeeping only (2), and they die with the page
/// render (3).
fn collectDynProps(arena: RenderArena, tag_text: []const u8) ![]const props.Pair {
    var pairs: std.ArrayListUnmanaged(props.Pair) = .empty;
    const marker = " prop-";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag_text, i, marker)) |p| {
        const name_start = p + marker.len;
        const eq = std.mem.indexOfScalarPos(u8, tag_text, name_start, '=') orelse break;
        const name = tag_text[name_start..eq];
        if (eq + 1 >= tag_text.len or tag_text[eq + 1] != '"') {
            i = eq + 1;
            continue;
        }
        const vstart = eq + 2;
        const vend = std.mem.indexOfScalarPos(u8, tag_text, vstart, '"') orelse break;
        try pairs.append(arena.a, .{
            .name = try arena.a.dupe(u8, name),
            // SuperHTML HTML-escapes attribute values (& > < ' "), so the raw
            // attribute text is entity-encoded. Decode it back to the real bytes
            // the island's Props expect — essential for structured `prop-`
            // values produced by `.toJson()` (whose `"` become `&quot;`), and
            // also correct for any scalar string prop containing `&`/`<`/`"`.
            .value = try htmlUnescapeAttr(arena.a, tag_text[vstart..vend]),
        });
        i = vend + 1;
    }
    return pairs.toOwnedSlice(arena.a);
}

/// Decode the HTML entities SuperHTML emits when escaping a double-quoted
/// attribute value (`&amp; &gt; &lt; &apos; &quot;`, plus the numeric `&#39;`/
/// `&#34;`).
///
/// Contract 1: always returns an owned buffer — the no-entity fast path dupes
/// instead of borrowing `s`, so the caller can free unconditionally without
/// knowing which path ran.
fn htmlUnescapeAttr(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return alloc.dupe(u8, s);

    const entities = .{
        .{ "&amp;", "&" },
        .{ "&gt;", ">" },
        .{ "&lt;", "<" },
        .{ "&quot;", "\"" },
        .{ "&apos;", "'" },
        .{ "&#39;", "'" },
        .{ "&#34;", "\"" },
    };

    // Unescaping only shrinks, so the input length is a sufficient capacity.
    var out: std.ArrayListUnmanaged(u8) = try .initCapacity(alloc, s.len);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    outer: while (i < s.len) {
        if (s[i] == '&') {
            inline for (entities) |e| {
                if (std.mem.startsWith(u8, s[i..], e[0])) {
                    out.appendSliceAssumeCapacity(e[1]);
                    i += e[0].len;
                    continue :outer;
                }
            }
        }
        out.appendAssumeCapacity(s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Serialize a `[]const Slot` into a compact JSON object string suitable for
/// the `slots_json` arg of `Sidecar.render`. Returns `""` when there are no slots.
/// Each slot name and HTML value are properly JSON-encoded (escaping quotes etc.).
/// `</` sequences are further escaped to `<\/` so that embedding the JSON in a
/// `<script>` tag is safe: the browser HTML parser will not see `</script>` inside
/// the string values and prematurely close the script element. JSON `\/` is a valid
/// escape for `/` and decodes identically — both the sidecar and bootIsland JSON.parse
/// round-trip correctly. See: HTML spec §13.2.5.1 "Script data state".
fn slotsToJson(alloc: std.mem.Allocator, slots: []const Slot) ![]const u8 {
    if (slots.len == 0) return "";
    var aw: std.Io.Writer.Allocating = .init(alloc);
    // Contract 1: the unescaped JSON is scratch — `escapeScriptContent` returns a
    // fresh buffer — so it is freed here whatever happens.
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{");
    for (slots, 0..) |slot, i| {
        if (i > 0) try w.writeAll(",");
        try std.json.Stringify.value(slot.name, .{}, w);
        try w.writeAll(":");
        try std.json.Stringify.value(slot.html, .{}, w);
    }
    try w.writeAll("}");
    const raw = aw.written();
    return escapeScriptContent(alloc, raw);
}

/// Replace `</` with `<\/` so the JSON is safe to embed inside a `<script>` tag.
/// `\/` is a valid JSON escape for `/` (RFC 8259 §7); JSON.parse decodes it back.
/// `pub`: `src/spa.zig` reuses this for the `data-z-flags` snapshot data block.
///
/// Contract 1: always returns an owned buffer — the nothing-to-escape fast path
/// dupes rather than borrowing `input`, so callers free unconditionally.
pub fn escapeScriptContent(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    const needle = "</";
    // Count occurrences to pre-size the output buffer.
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, input, pos, needle)) |found| {
        count += 1;
        pos = found + needle.len;
    }
    if (count == 0) return alloc.dupe(u8, input);
    // Each "</" (2 bytes) → "<\/" (3 bytes); output grows by count bytes.
    const out = try alloc.alloc(u8, input.len + count);
    _ = std.mem.replace(u8, input, needle, "<\\/", out);
    return out;
}

/// Partition island inner HTML into named slots and a default slot.
/// `<template slot="NAME">…</template>` blocks become named slots; everything
/// else becomes the `default` slot (if non-empty after trimming). The slot
/// attribute must be the template's first attribute (`<template slot="NAME">`).
///
/// NO_SLOP.md §2.2a contract 4 (`RenderArena`): the returned slice and the
/// default-slot buffer are two allocations pointing at each other — the default
/// `Slot.html` is a trimmed VIEW into `default_buf`, while named slots borrow
/// `inner` — so which of the returned slices is owned is not visible to the
/// caller and it cannot free them (1, 2). They die with the page render (3).
fn collectSlots(arena: RenderArena, inner: []const u8) ![]const Slot {
    var slots: std.ArrayListUnmanaged(Slot) = .empty;
    var default_buf: std.ArrayListUnmanaged(u8) = .empty;
    const marker = "<template slot=\"";

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, inner, i, marker)) |t| {
        try default_buf.appendSlice(arena.a, inner[i..t]);
        const name_start = t + marker.len;
        const name_end = std.mem.indexOfScalarPos(u8, inner, name_start, '"') orelse break;
        const name = inner[name_start..name_end];
        const open_end = std.mem.indexOfScalarPos(u8, inner, name_end, '>') orelse break;
        const close = std.mem.indexOfPos(u8, inner, open_end + 1, "</template>") orelse break;
        try slots.append(arena.a, .{ .name = name, .html = inner[open_end + 1 .. close] });
        i = close + "</template>".len;
    }
    try default_buf.appendSlice(arena.a, inner[i..]);

    const default_html = std.mem.trim(u8, default_buf.items, " \t\r\n");
    if (default_html.len > 0) {
        try slots.append(arena.a, .{ .name = "default", .html = default_html });
    }
    return slots.toOwnedSlice(arena.a);
}

/// One attribute of an open tag, as produced by `AttrIterator`. All slices point
/// into the original `tag_text`.
const Attr = struct {
    name: []const u8,
    /// The value content (between the quotes / up to whitespace); null for a
    /// value-less attribute like `client:load`.
    value: ?[]const u8,
    /// The quote byte delimiting `value`: `'"'`, `'\''`, or 0 for an unquoted or
    /// value-less attribute.
    quote: u8,
};

/// Walk the attributes of an open tag left to right, tracking quoted values so a
/// needle like `src="` inside a `prop-src="…"` value or a `client:` inside a
/// quoted `:props` literal is never mistaken for a real attribute (AUD-005).
const AttrIterator = struct {
    tag: []const u8,
    pos: usize,

    fn init(tag_text: []const u8) AttrIterator {
        // Skip the leading '<' and the tag name so iteration begins at the first
        // attribute. The tag name runs until whitespace or a tag terminator.
        var p: usize = 0;
        if (p < tag_text.len and tag_text[p] == '<') p += 1;
        while (p < tag_text.len) : (p += 1) switch (tag_text[p]) {
            ' ', '\t', '\n', '\r', '>', '/' => break,
            else => {},
        };
        return .{ .tag = tag_text, .pos = p };
    }

    fn next(self: *AttrIterator) ?Attr {
        const t = self.tag;
        var p = self.pos;
        // Skip inter-attribute whitespace and stray '/' (self-closing slash).
        while (p < t.len) : (p += 1) switch (t[p]) {
            ' ', '\t', '\n', '\r', '/' => {},
            else => break,
        };
        if (p >= t.len or t[p] == '>') {
            self.pos = p;
            return null;
        }
        // Attribute name: up to whitespace, '=', or a tag terminator.
        const nstart = p;
        while (p < t.len) : (p += 1) switch (t[p]) {
            ' ', '\t', '\n', '\r', '=', '>', '/' => break,
            else => {},
        };
        const name = t[nstart..p];
        if (p < t.len and t[p] == '=') {
            p += 1;
            if (p < t.len and (t[p] == '"' or t[p] == '\'')) {
                const q = t[p];
                p += 1;
                const vstart = p;
                while (p < t.len and t[p] != q) : (p += 1) {}
                const value = t[vstart..p];
                if (p < t.len) p += 1; // consume the closing quote
                self.pos = p;
                return .{ .name = name, .value = value, .quote = q };
            }
            // Unquoted value: up to whitespace or a tag terminator.
            const vstart = p;
            while (p < t.len) : (p += 1) switch (t[p]) {
                ' ', '\t', '\n', '\r', '>' => break,
                else => {},
            };
            self.pos = p;
            return .{ .name = name, .value = t[vstart..p], .quote = 0 };
        }
        self.pos = p;
        return .{ .name = name, .value = null, .quote = 0 };
    }
};

/// Extract the value of a double-quoted attribute: `name="value"`.
/// Only a real attribute (at an attribute-name boundary) matches — a substring
/// match inside another attribute's name or value is ignored (AUD-005).
/// Returns a slice into `tag_text` (not heap-allocated).
fn attrDouble(tag_text: []const u8, name: []const u8) ?[]const u8 {
    var it = AttrIterator.init(tag_text);
    while (it.next()) |attr| {
        if (attr.quote == '"' and std.mem.eql(u8, attr.name, name)) return attr.value;
    }
    return null;
}

/// Extract the value of a single-quoted attribute: `name='value'`.
/// Used for `:props` so that inner double-quotes in Ziggy literals are safe.
/// Attribute-boundary aware (AUD-005). Returns a slice into `tag_text`.
fn attrSingle(tag_text: []const u8, name: []const u8) ?[]const u8 {
    var it = AttrIterator.init(tag_text);
    while (it.next()) |attr| {
        if (attr.quote == '\'' and std.mem.eql(u8, attr.name, name)) return attr.value;
    }
    return null;
}

pub const Client = struct {
    /// Directive name: "load" | "idle" | "visible" | "media" | "only".
    name: []const u8,
    /// Optional directive value (the media query for `client:media="(...)"`).
    value: ?[]const u8 = null,
};

/// Parse a `client:NAME` (optionally `client:NAME="value"`) directive from the
/// open tag. Only a real `client:` attribute matches — a `client:` substring
/// inside another attribute's quoted value (e.g. `prop-text="client: acme"`) is
/// ignored, so it can never shadow the real directive (AUD-005). Returns slices
/// into `tag_text`.
fn clientDirective(tag_text: []const u8) ?Client {
    var it = AttrIterator.init(tag_text);
    while (it.next()) |attr| {
        if (std.mem.startsWith(u8, attr.name, "client:")) {
            return .{
                .name = attr.name["client:".len..],
                .value = attr.value,
            };
        }
    }
    return null;
}

/// Validate a parsed client directive against the set the runtime actually
/// schedules (islands.ts: load | idle | visible | media | only). An unknown
/// name (e.g. a typo like `client:visable`) or a value on a non-media
/// directive (e.g. Astro's `client:only="react"`) previously slipped through
/// silently — the island would never hydrate, or the value leaked out as a
/// stray data-z-media attribute. Fail the build instead; worker.zig's handler
/// (`log.err("island rendering error on {s}: {s}", ...)` at src/worker.zig:1084)
/// adds the page path, while the logs here carry the offending directive text —
/// on a page with several islands the error name alone doesn't say which one.
/// The logs are gated on `!builtin.is_test` because Zig's test runner fails the
/// whole test step on any `.err`-level log, even when every test's assertions
/// pass — the error-path tests below would turn a green suite red.
fn validateClientDirective(cd: Client) error{ UnknownClientDirective, UnexpectedClientDirectiveValue, MissingMediaQuery }!void {
    if (cd.name.len == 0) return; // no client:* attribute: SSR-only island
    const known = [_][]const u8{ "load", "idle", "visible", "media", "only" };
    for (known) |k| {
        if (std.mem.eql(u8, cd.name, k)) break;
    } else {
        if (!builtin.is_test) std.log.err("unknown island directive 'client:{s}' (expected load|idle|visible|media|only)", .{cd.name});
        return error.UnknownClientDirective;
    }
    if (std.mem.eql(u8, cd.name, "media")) {
        // client:media with no query — or an empty one (`client:media=""`) —
        // would never mount client-side (islands.ts's media case has no query
        // to match) — a silent-never-hydrate trap.
        if (cd.value == null or cd.value.?.len == 0) {
            if (!builtin.is_test) std.log.err("'client:media' requires a media query value, e.g. client:media=\"(min-width: 600px)\"", .{});
            return error.MissingMediaQuery;
        }
    } else if (cd.value != null) {
        // e.g. Astro's client:only="react": the value is meaningless here since
        // there is exactly one runtime, so reject it loudly instead of letting it
        // leak out as a stray data-z-media attribute.
        if (!builtin.is_test) std.log.err("'client:{s}' takes no value (got \"{s}\"); Astro's client:only=\"framework\" is just `client:only` here — there is one runtime", .{ cd.name, cd.value.? });
        return error.UnexpectedClientDirectiveValue;
    }
}

// --- tests ---

// A fake island renderer for pass.zig unit tests: returns deterministic HTML
// per src + echoes the resolved props, so the tokenizer/placeholder/slot tests
// don't need a real Bun sidecar. Mirrors the Sidecar.render method shape.
const StubRenderer = struct {
    /// Captures the last slots_json arg passed to render so slot tests can assert
    /// that the correct JSON map reached the renderer. Empty when no slots present.
    last_slots_json: []const u8 = "",

    pub fn render(self: *StubRenderer, arena: RenderArena, src: []const u8, props_json: []const u8, slots_json: []const u8, pathname: []const u8, err_out: ?*sidecar.RenderError) ![]const u8 {
        _ = pathname;
        _ = err_out;
        self.last_slots_json = slots_json;
        // Echo enough to assert against: the src basename and the props JSON.
        var name = src;
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |s| name = name[s + 1 ..];
        return std.fmt.allocPrint(arena.a, "<stub data-src=\"{s}\">{s}</stub>", .{ name, props_json });
    }
};

test "structured prop-NAME (HTML-escaped JSON) deserializes into a typed collection and SSRs" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // This is exactly what SuperHTML emits for
    //   prop-items="$page.custom.get('faq').toJson()"
    // — a JSON array of structs with its double-quotes HTML-escaped to &quot;.
    const input =
        "<island src=\"components/Faq.zig\" client:load " ++
        "prop-items=\"[{&quot;q&quot;:&quot;Q1&quot;,&quot;a&quot;:&quot;A1&quot;}," ++
        "{&quot;q&quot;:&quot;Q2&quot;,&quot;a&quot;:&quot;A2&quot;}]\"></island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // SSR stub echoes the resolved props JSON.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<stub data-src=\"Faq.zig\">{\"items\":[{\"q\":\"Q1\",\"a\":\"A1\"},{\"q\":\"Q2\",\"a\":\"A2\"}]}</stub>") != null);
    // The client props JSON carries the structured data too (quotes intact).
    try std.testing.expect(std.mem.indexOf(u8, result.html, "{\"items\":[{\"q\":\"Q1\",\"a\":\"A1\"},{\"q\":\"Q2\",\"a\":\"A2\"}]}") != null);
}

test "process forwards page_url to the renderer as pathname" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // A local renderer that echoes the pathname so we can assert it was forwarded.
    const PathnameStub = struct {
        pub fn render(_: *@This(), ra: RenderArena, src: []const u8, props_json: []const u8, slots_json: []const u8, pathname: []const u8, err_out: ?*sidecar.RenderError) ![]const u8 {
            _ = src;
            _ = props_json;
            _ = slots_json;
            _ = err_out;
            return std.fmt.allocPrint(ra.a, "<p>path: {s}</p>", .{pathname});
        }
    };

    const input = "<main><island src=\"components/Location.zig\" client:load :props='{}'></island></main>";
    var ps: PathnameStub = .{};
    const result = try process(gpa, arena, input, "/booking/", &ps, .{});
    defer gpa.free(result.html);

    // page_url "/booking/" reached the renderer's pathname arg.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "path: /booking/") != null);
}

test "process forwards the URL-PREFIXED page_url as the island's SSR pathname" {
    // Island/browser pathname parity on a `url_path_prefix` site: the SSR pass
    // must simulate the pathname a real browser reports, or an island that
    // branches on the path (active-nav highlighting, breadcrumbs) renders one
    // thing at build time and another after hydration — and hydrate() does not
    // repair a mismatched attribute. This is the island-side counterpart of the
    // SPA route pass's prefixed `ssr_pathname` (src/spa.zig).
    const gpa = std.testing.allocator;

    const PathnameStub = struct {
        pub fn render(_: *@This(), ra: RenderArena, src: []const u8, props_json: []const u8, slots_json: []const u8, pathname: []const u8, err_out: ?*sidecar.RenderError) ![]const u8 {
            _ = src;
            _ = props_json;
            _ = slots_json;
            _ = err_out;
            return std.fmt.allocPrint(ra.a, "<p>path: {s}</p>", .{pathname});
        }
    };
    const input = "<main><island src=\"components/Location.zig\" client:load :props='{}'></island></main>";

    // ONE arena for both cases (NO_SLOP.md §2.2a): `RenderArena.forTest` was
    // tried first, as that section asks, and `process` is genuinely contract 4
    // — under the raw testing allocator it leaks 22 allocations, the
    // interlinked instance/props/slot graph that only dropping the arena can
    // reclaim. So a real arena it is, and a single one rather than one per
    // case, to add the fewest possible leak-detector-disabled sites.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    {
        var ps: PathnameStub = .{};
        const result = try process(gpa, arena, input, "/guides/", &ps, .{ .url_prefix = "myrepo" });
        defer gpa.free(result.html);
        try std.testing.expect(std.mem.indexOf(u8, result.html, "path: /myrepo/guides/") != null);
        // The bare form must NOT survive: asserting only the presence of the
        // prefixed string would also pass if BOTH were emitted somewhere.
        try std.testing.expect(std.mem.indexOf(u8, result.html, "path: /guides/") == null);
    }

    {
        // The no-op that keeps every unprefixed site unaffected.
        var ps: PathnameStub = .{};
        const result = try process(gpa, arena, input, "/guides/", &ps, .{ .url_prefix = "" });
        defer gpa.free(result.html);
        try std.testing.expect(std.mem.indexOf(u8, result.html, "path: /guides/") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.html, "/myrepo") == null);
    }
}

test "process replaces an island with SSR markup + props script" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // Props use single-quote delimiters so inner double-quotes are safe.
    const input =
        "<main><island src=\"components/Counter.island.tsx\" client:load " ++
        ":props='{ .start = 2, .label = \"hi\" }'></island></main>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    try std.testing.expectEqual(@as(usize, 1), result.instances.len);
    try std.testing.expectEqualStrings("z-island-0", result.instances[0].id);
    // SSR'd placeholder wrapper present:
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<div data-z-island id=\"z-island-0\" data-z-src=\"components/Counter.island.tsx\" data-z-client=\"load\" data-z-module=\"/islands/Counter.island.js\">") != null);
    try std.testing.expectEqualStrings("/islands/Counter.island.js", result.instances[0].module_url);
    // Stub SSR output with echoed props JSON:
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<stub data-src=\"Counter.island.tsx\">{\"start\":2,\"label\":\"hi\"}</stub>") != null);
    // Props script:
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script type=\"application/json\" data-z-props=\"z-island-0\">{\"start\":2,\"label\":\"hi\"}</script>") != null);
    // surrounding HTML preserved:
    try std.testing.expect(std.mem.startsWith(u8, result.html, "<main>"));
    try std.testing.expect(std.mem.endsWith(u8, result.html, "</main>"));
}

test "html without islands is returned unchanged" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    const input = "<p>no islands here</p>";
    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);
    try std.testing.expectEqualStrings(input, result.html);
    try std.testing.expectEqual(@as(usize, 0), result.instances.len);
}

test "quote-aware tag scan: > inside :props value does not truncate the tag" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // The label contains > and < which would trip a naive indexOfScalar('>') scan.
    const input =
        "<main><island src=\"components/Counter.zig\" client:load " ++
        ":props='{ .start = 1, .label = \"a > b < c\" }'></island></main>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    try std.testing.expectEqual(@as(usize, 1), result.instances.len);
    // Stub SSR output is present.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<stub data-src=\"Counter.zig\">") != null);
    // The props JSON must have the escaped label (< and > escaped via \uXXXX).
    try std.testing.expect(std.mem.indexOf(u8, result.html, "\\u003E") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "\\u003C") != null);
    // Surrounding HTML preserved.
    try std.testing.expect(std.mem.startsWith(u8, result.html, "<main>"));
    try std.testing.expect(std.mem.endsWith(u8, result.html, "</main>"));
}

test "head injection: import map + runtime module script when islands present" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    var stub: StubRenderer = .{};
    const input =
        "<html><head><title>t</title></head><body>" ++
        "<island src=\"components/Counter.island.tsx\" client:load :props='{}'></island>" ++
        "</body></html>";
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script type=\"importmap\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "\"@z/runtime\":\"/zigapagos-runtime.js\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script type=\"module\" src=\"/zigapagos-runtime.js\">") != null);
    // both injected before </head>:
    const head_end = std.mem.indexOf(u8, result.html, "</head>").?;
    try std.testing.expect(std.mem.indexOf(u8, result.html, "importmap").? < head_end);
}

test "no runtime script injected when page has no islands" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    const input = "<html><head></head><body><p>hi</p></body></html>";
    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);
    try std.testing.expectEqualStrings(input, result.html);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "zigapagos-runtime.js") == null);
}

test "default slot: slots_json forwarded to renderer; data-z-slots script emitted; no z-slot wrapper" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<island src=\"components/Card.zig\" client:load :props='{ .title = \"Hi\" }'>" ++
        "<p>slotted body</p></island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // (a) The slots_json captured by the renderer contains the "default" key.
    try std.testing.expect(std.mem.indexOf(u8, stub.last_slots_json, "\"default\"") != null);
    // The slot body text appears in the JSON value (not escaped by JSON, since "slotted body" is plain text).
    try std.testing.expect(std.mem.indexOf(u8, stub.last_slots_json, "slotted body") != null);
    // (b) The emitted markup contains the data-z-slots script for this island id.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script type=\"application/json\" data-z-slots=\"z-island-0\">") != null);
    // The slot text appears somewhere in the output (inside the JSON script).
    try std.testing.expect(std.mem.indexOf(u8, result.html, "slotted body") != null);
    // (c) pass.zig no longer appends manual <z-slot> wrappers — double-wrap is gone.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<z-slot") == null);
}

test "named slots: <template slot> routes to the named slot; both keys in slots_json; data-z-slots script emitted" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<island src=\"components/Panel.zig\" client:load :props='{}'>" ++
        "<template slot=\"title\"><h3>T</h3></template>" ++
        "<p>body</p></island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // (a) slots_json passed to the renderer contains both "title" and "default" keys.
    try std.testing.expect(std.mem.indexOf(u8, stub.last_slots_json, "\"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.last_slots_json, "\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.last_slots_json, "body") != null);
    // (b) data-z-slots script emitted in the output.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script type=\"application/json\" data-z-slots=\"z-island-0\">") != null);
    // (c) No manual <z-slot> wrappers — the double-wrap is gone.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<z-slot") == null);
}

test "nested island in slot content: both rewritten; nested id appears inside outer's slots_json" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // A Counter nested inside a Card's default slot.
    const input =
        "<main><island src=\"components/Card.zig\" client:load :props='{ .title = \"Outer\" }'>" ++
        "<island src=\"components/Counter.zig\" client:load :props='{ .start = 7, .label = \"n\" }'></island>" ++
        "</island></main>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // Both islands were rewritten; outer is z-island-0, nested z-island-1.
    try std.testing.expectEqual(@as(usize, 2), result.instances.len);
    // (d) The outer's slots_json (last render call) contains the nested island's id.
    //     The Counter placeholder HTML is JSON-encoded inside the default slot value.
    try std.testing.expect(std.mem.indexOf(u8, stub.last_slots_json, "z-island-1") != null);
    // (b) The outer's data-z-slots script is present and encodes the nested id.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script type=\"application/json\" data-z-slots=\"z-island-0\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "z-island-1") != null);
    // (c) No manual <z-slot> wrappers anywhere in the output.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<z-slot") == null);
    // The outer placeholder's id and src are present; surrounding HTML preserved.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "id=\"z-island-0\" data-z-src=\"components/Card.zig\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, result.html, "<main>"));
    try std.testing.expect(std.mem.endsWith(u8, result.html, "</main>"));
}

test "client:only with slots: empty div but data-z-slots script still emitted" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<island src=\"components/Card.zig\" client:only :props='{}'>" ++
        "<p>client slot</p></island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // (e) client:only: renderer is not called, so placeholder is empty.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<stub") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "data-z-client=\"only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "></div>") != null);
    // Props script still emitted.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script type=\"application/json\" data-z-props=\"z-island-0\">") != null);
    // (e) data-z-slots script ALSO emitted for client:only when slots are present —
    //     the client needs slot HTML to build children for the fresh mount.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script type=\"application/json\" data-z-slots=\"z-island-0\">") != null);
    // Slot content text is present inside the JSON script.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "client slot") != null);
    // (c) No manual <z-slot> wrapper.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<z-slot") == null);
}

test "leaf island: no data-z-slots script emitted (byte-identical regression guard)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<island src=\"components/Counter.zig\" client:load :props='{ .start = 0, .label = \"x\" }'></island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // (f) No data-z-slots script for a leaf island (no slot content at all).
    try std.testing.expect(std.mem.indexOf(u8, result.html, "data-z-slots") == null);
    // Props script is still emitted.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "data-z-props") != null);
}

test "island following a nested island gets the next id (counter shared through recursion)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<island src=\"components/Card.zig\" client:load :props='{ .title = \"O\" }'>" ++
        "<island src=\"components/Counter.zig\" client:load :props='{ .start = 1, .label = \"a\" }'></island>" ++
        "</island>" ++
        "<island src=\"components/Counter.zig\" client:load :props='{ .start = 2, .label = \"b\" }'></island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // Outer Card = 0, nested Counter = 1, the following top-level Counter = 2.
    try std.testing.expectEqual(@as(usize, 3), result.instances.len);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "id=\"z-island-2\" data-z-src=\"components/Counter.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<stub data-src=\"Counter.zig\">{\"start\":2,\"label\":\"b\"}</stub>") != null);
}

test "client:media emits data-z-media with the query" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<island src=\"components/Counter.zig\" client:media=\"(min-width: 600px)\" " ++
        ":props='{ .start = 0, .label = \"x\" }'></island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    try std.testing.expectEqualStrings("media", result.instances[0].client);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "data-z-client=\"media\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "data-z-media=\"(min-width: 600px)\"") != null);
    // media islands are still SSR'd (content present without JS):
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<stub data-src=\"Counter.zig\">{\"start\":0,\"label\":\"x\"}</stub>") != null);
}

test "dynamic props: prop-NAME attrs override :props and are coerced to field types" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<island src=\"components/Counter.zig\" client:load " ++
        ":props='{ .start = 0, .label = \"base\" }' prop-label=\"Hello\" prop-start=\"3\"></island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // Stub output reflects the resolved (overridden) props.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<stub data-src=\"Counter.zig\">{\"start\":3,\"label\":\"Hello\"}</stub>") != null);
    // Embedded props JSON is the resolved value (start coerced from "3" to 3).
    try std.testing.expect(std.mem.indexOf(u8, result.html, "{\"start\":3,\"label\":\"Hello\"}") != null);
}

test "client:only is not server-rendered (empty placeholder) but keeps props" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<island src=\"components/Counter.zig\" client:only " ++
        ":props='{ .start = 9, .label = \"y\" }'></island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    try std.testing.expectEqualStrings("only", result.instances[0].client);
    // No SSR'd stub output inside the placeholder.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<stub") == null);
    // Empty placeholder div present.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "data-z-client=\"only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "></div>") != null);
    // Props still emitted for the client mount.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script type=\"application/json\" data-z-props=\"z-island-0\">{\"start\":9,\"label\":\"y\"}</script>") != null);
}

test "preloadLinks: runtime link first, island modules deduped, client:only included" {
    // Contract 1: the dedup set is freed inside, one buffer escapes — so this
    // runs on the raw testing allocator with leak detection ON.
    const gpa = std.testing.allocator;

    const insts = [_]IslandInstance{
        .{ .id = "z-island-0", .src = "components/Hero.island.tsx", .client = "load", .props_json = "{}", .module_url = "/islands/Hero.island.js" },
        .{ .id = "z-island-1", .src = "components/Counter.island.tsx", .client = "only", .props_json = "{}", .module_url = "/islands/Counter.island.js" },
        .{ .id = "z-island-2", .src = "components/Hero.island.tsx", .client = "load", .props_json = "{}", .module_url = "/islands/Hero.island.js" }, // dup module
    };
    const links = try preloadLinks(gpa, &insts, "");
    defer gpa.free(links);
    // runtime link present and FIRST.
    try std.testing.expect(std.mem.startsWith(u8, links, "<link rel=\"modulepreload\" href=\"/zigapagos-runtime.js\">"));
    // Hero module appears exactly once (deduped) despite two instances.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, links, "href=\"/islands/Hero.island.js\""));
    // client:only Counter module IS included.
    try std.testing.expect(std.mem.indexOf(u8, links, "href=\"/islands/Counter.island.js\"") != null);
}

test "preloadLinks: empty instances -> empty string" {
    const gpa = std.testing.allocator;
    const links = try preloadLinks(gpa, &.{}, "");
    defer gpa.free(links); // zero-length: `Allocator.free` short-circuits
    try std.testing.expectEqualStrings("", links);
}

test "process injects the import map before any modulepreload links, only when islands present" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    var stub: StubRenderer = .{};
    const input =
        "<html><head><title>t</title></head><body>" ++
        "<island src=\"components/Counter.island.tsx\" client:load :props='{}'></island>" ++
        "</body></html>";
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);
    // preload link present.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<link rel=\"modulepreload\" href=\"/zigapagos-runtime.js\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<link rel=\"modulepreload\" href=\"/islands/Counter.island.js\">") != null);
    // import map appears BEFORE any modulepreload: per the import-maps spec, a
    // map is only processed if it appears before any module loading starts, and
    // a <link rel="modulepreload"> starts one — so a later map is disregarded.
    const pl = std.mem.indexOf(u8, result.html, "modulepreload").?;
    const im = std.mem.indexOf(u8, result.html, "importmap").?;
    try std.testing.expect(im < pl);
    // all before </head>.
    const head_end = std.mem.indexOf(u8, result.html, "</head>").?;
    try std.testing.expect(im < head_end);
}

test "self-closing island renders correctly" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<header></header>" ++
        "<island src=\"components/Counter.zig\" client:load :props='{ .start = 3, .label = \"x\" }' />" ++
        "<footer></footer>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    try std.testing.expectEqual(@as(usize, 1), result.instances.len);
    try std.testing.expectEqualStrings("z-island-0", result.instances[0].id);
    // Stub SSR output present.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<stub data-src=\"Counter.zig\">{\"start\":3,\"label\":\"x\"}</stub>") != null);
    // Props script present.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script type=\"application/json\"") != null);
    // Surrounding HTML preserved.
    try std.testing.expect(std.mem.startsWith(u8, result.html, "<header></header>"));
    try std.testing.expect(std.mem.endsWith(u8, result.html, "<footer></footer>"));
}

test "process with url_prefix rewrites runtime + island module URLs" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // Same shape as the "head injection" process test: a <head> is needed for
    // the runtime import map/script to be injected at all.
    const input =
        "<html><head><title>t</title></head><body>" ++
        "<island src=\"components/Counter.island.tsx\" client:load " ++
        ":props='{ .start = 2, .label = \"hi\" }'></island>" ++
        "</body></html>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{ .url_prefix = "zigapagos" });
    defer gpa.free(result.html);

    try std.testing.expect(std.mem.indexOf(u8, result.html, "\"/zigapagos/zigapagos-runtime.js\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "/zigapagos/islands/") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "\"/zigapagos-runtime.js\"") == null or
        std.mem.indexOf(u8, result.html, "\"/zigapagos/zigapagos-runtime.js\"") != null);
}

test "process with empty url_prefix is byte-identical to legacy output" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<html><head><title>t</title></head><body>" ++
        "<island src=\"components/Counter.island.tsx\" client:load " ++
        ":props='{ .start = 2, .label = \"hi\" }'></island>" ++
        "</body></html>";

    var stub: StubRenderer = .{};
    const a = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(a.html);
    var stub2: StubRenderer = .{};
    const b = try process(gpa, arena, input, "/", &stub2, .{ .url_prefix = "" });
    defer gpa.free(b.html);
    try std.testing.expectEqualStrings(a.html, b.html);
}

test "process with url_prefix trailing/leading slashes normalizes to the same output as a bare prefix" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<html><head><title>t</title></head><body>" ++
        "<island src=\"components/Counter.island.tsx\" client:load " ++
        ":props='{ .start = 2, .label = \"hi\" }'></island>" ++
        "</body></html>";

    // "zigapagos/" (trailing slash, as validatePath permits and serve.zig strips
    // defensively for the same field) must produce byte-identical output to the
    // bare "zigapagos" prefix — not a malformed "//" join.
    var stub_bare: StubRenderer = .{};
    const bare = try process(gpa, arena, input, "/", &stub_bare, .{ .url_prefix = "zigapagos" });
    defer gpa.free(bare.html);
    var stub_slash: StubRenderer = .{};
    const trailing_slash = try process(gpa, arena, input, "/", &stub_slash, .{ .url_prefix = "zigapagos/" });
    defer gpa.free(trailing_slash.html);
    try std.testing.expectEqualStrings(bare.html, trailing_slash.html);

    // "/" alone (all-slash prefix) must normalize to the same empty-prefix
    // contract as "".
    var stub_empty: StubRenderer = .{};
    const empty = try process(gpa, arena, input, "/", &stub_empty, .{ .url_prefix = "" });
    defer gpa.free(empty.html);
    var stub_root_slash: StubRenderer = .{};
    const root_slash = try process(gpa, arena, input, "/", &stub_root_slash, .{ .url_prefix = "/" });
    defer gpa.free(root_slash.html);
    try std.testing.expectEqualStrings(empty.html, root_slash.html);
}

test "slotsToJson: </script> in slot HTML is escaped to <\\/script> in the data-z-slots script tag" {
    // Regression guard for the e2e-found bug: slot content whose HTML contains a
    // literal </script> sequence would terminate the wrapping
    // <script type="application/json" data-z-slots="..."> element prematurely if
    // slotsToJson did not call escapeScriptContent. escapeScriptContent replaces
    // every "</" with "<\/" so the browser's HTML parser never sees a closing tag
    // inside the script body. JSON.parse decodes "<\/" identically to "</" (RFC 8259
    // §7 permits escaping "/" as "\/" in string values). Mirrors the analogous test
    // in props.zig ("resolveToJson: escapes </script> breakout in a string value").
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // Slot body contains a literal </script> tag (e.g. an inline script in a slot).
    const input =
        "<island src=\"components/Card.zig\" client:load :props='{}'>" ++
        "<p>a</p><script>foo()</script><p>b</p></island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // The data-z-slots script must be present (slot content is non-empty).
    const slots_open = "<script type=\"application/json\" data-z-slots=\"z-island-0\">";
    try std.testing.expect(std.mem.indexOf(u8, result.html, slots_open) != null);

    // Isolate the data-z-slots script content (between the open tag and its </script>).
    const slots_start = std.mem.indexOf(u8, result.html, slots_open).? + slots_open.len;
    const slots_end = std.mem.indexOfPos(u8, result.html, slots_start, "</script>").?;
    const slots_content = result.html[slots_start..slots_end];

    // No raw </script> inside the JSON value — escapeScriptContent must have fired.
    try std.testing.expect(std.mem.indexOf(u8, slots_content, "</script>") == null);
    // The backslash-escaped form <\/ must be present inside the JSON value.
    try std.testing.expect(std.mem.indexOf(u8, slots_content, "<\\/script") != null);
}

test "validateClientDirective accepts the five known directives and absence" {
    try validateClientDirective(.{ .name = "" }); // no client:* attr at all
    try validateClientDirective(.{ .name = "load" });
    try validateClientDirective(.{ .name = "idle" });
    try validateClientDirective(.{ .name = "visible" });
    try validateClientDirective(.{ .name = "only" });
    try validateClientDirective(.{ .name = "media", .value = "(min-width: 600px)" });
}

test "validateClientDirective rejects unknown names, stray values, and a query-less client:media" {
    try std.testing.expectError(error.UnknownClientDirective, validateClientDirective(.{ .name = "visable" }));
    // client:only="framework" (Astro syntax): the value is meaningless here — reject
    // it loudly instead of silently emitting it as a stray data-z-media attribute.
    try std.testing.expectError(error.UnexpectedClientDirectiveValue, validateClientDirective(.{ .name = "only", .value = "react" }));
    try std.testing.expectError(error.UnexpectedClientDirectiveValue, validateClientDirective(.{ .name = "load", .value = "x" }));
    // client:media with no query would never mount client-side (islands.ts's media
    // case has no query to match) — a silent-never-hydrate trap.
    try std.testing.expectError(error.MissingMediaQuery, validateClientDirective(.{ .name = "media" }));
    // An EMPTY query (`client:media=""`) is the same trap as a missing one.
    try std.testing.expectError(error.MissingMediaQuery, validateClientDirective(.{ .name = "media", .value = "" }));
}

test "rewrite fails loudly on an unknown client directive" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    var stub = StubRenderer{};
    var instances: std.ArrayListUnmanaged(IslandInstance) = .empty;
    var counter: usize = 0;
    const html = "<island src=\"components/A.island.tsx\" client:visable></island>";
    try std.testing.expectError(error.UnknownClientDirective, rewrite(gpa, arena, html, &stub, "/", &instances, &counter, "", .fail, null));
}

test "attribute extraction is boundary-aware (AUD-005): prop-src, quoted client:, phantom directive" {
    // prop-src precedes the real src: the needle `src="` occurs inside the
    // prop-NAME attribute name, but only the real `src` attribute must resolve.
    {
        const tag = "<island prop-src=\"/img/x.png\" src=\"components/Img.island.tsx\" client:load>";
        try std.testing.expectEqualStrings("components/Img.island.tsx", attrDouble(tag, "src").?);
    }

    // `client:` appears only inside a single-quoted :props value — it must NOT be
    // read as a directive. With no real directive present, clientDirective is null.
    {
        const tag = "<island src=\"components/A.island.tsx\" :props='{ .url = \"http://client:8080\" }'>";
        try std.testing.expect(clientDirective(tag) == null);
        try std.testing.expectEqualStrings("{ .url = \"http://client:8080\" }", attrSingle(tag, ":props").?);
    }

    // Phantom-directive / never-hydrate case: a prop value containing `client:`
    // must not shadow the real `client:load` attribute.
    {
        const tag = "<island prop-text=\"client: acme\" src=\"components/A.island.tsx\" client:load>";
        const cd = clientDirective(tag).?;
        try std.testing.expectEqualStrings("load", cd.name);
        try std.testing.expect(cd.value == null);
    }

    // client:media with a query still parses through the boundary-aware path.
    {
        const tag = "<island src=\"c/A.island.tsx\" client:media=\"(min-width: 600px)\">";
        const cd = clientDirective(tag).?;
        try std.testing.expectEqualStrings("media", cd.name);
        try std.testing.expectEqualStrings("(min-width: 600px)", cd.value.?);
    }

    // A prop literally named `src` before the real one is a no-op for src lookup.
    {
        const tag = "<island prop-src=\"http://a\" src=\"c/Img.island.tsx\" client:load prop-alt=\"hi\">";
        try std.testing.expectEqualStrings("c/Img.island.tsx", attrDouble(tag, "src").?);
        const cd = clientDirective(tag).?;
        try std.testing.expectEqualStrings("load", cd.name);
    }
}

test "a commented-out island is not processed and the comment survives byte-identical" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // Commenting an island out is the natural way to disable it temporarily; the
    // markup inside the comment is text, not a tag, so it must not be SSR'd,
    // counted, or bundled.
    const input =
        "<main><!-- <island src=\"components/Old.island.tsx\" client:load :props='{}'></island> -->" ++
        "<p>live</p></main>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    try std.testing.expectEqual(@as(usize, 0), result.instances.len);
    try std.testing.expectEqualStrings(input, result.html);
    // No sidecar RPC happened either (the stub records the slots arg per call).
    try std.testing.expectEqualStrings("", stub.last_slots_json);
}

test "a page whose only island is commented out ships zero JavaScript" {
    // The user-visible guarantee from the README: "No island on the page? Zero
    // JavaScript shipped." A commented-out island used to inject the import map,
    // the modulepreloads and the runtime <script> into a page that hydrates
    // nothing (the spliced markup landed inside the comment).
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<html><head><title>t</title></head><body>" ++
        "<!-- <island src=\"components/Counter.island.tsx\" client:load :props='{}' /> -->" ++
        "</body></html>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    try std.testing.expectEqual(@as(usize, 0), result.instances.len);
    try std.testing.expectEqualStrings(input, result.html);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "zigapagos-runtime.js") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "importmap") == null);
}

test "an island inside raw-text element content is not processed" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // script/style are raw text; textarea/title are escapable raw text. The HTML
    // tokenizer parses no markup in any of them, so neither does this pass.
    const inputs = [_][]const u8{
        "<script>var s = \"<island src=\\\"components/A.island.tsx\\\" client:load />\";</script>",
        "<style>/* <island src=\"components/A.island.tsx\" client:load /> */</style>",
        "<textarea><island src=\"components/A.island.tsx\" client:load /></textarea>",
        "<title><island src=\"components/A.island.tsx\" client:load /></title>",
        // Attributes on the open tag (with a '>' inside a quoted value) don't
        // confuse the raw-text scan.
        "<script type=\"text/plain\" data-x=\"a > b\"><island src=\"components/A.island.tsx\" client:load /></script>",
        // Tag names are case-insensitive in HTML.
        "<SCRIPT><island src=\"components/A.island.tsx\" client:load /></SCRIPT>",
    };
    for (inputs) |input| {
        var stub: StubRenderer = .{};
        const result = try process(gpa, arena, input, "/", &stub, .{});
        defer gpa.free(result.html);
        try std.testing.expectEqual(@as(usize, 0), result.instances.len);
        try std.testing.expectEqualStrings(input, result.html);
    }

    // `<scripty>` is not `<script>`: the boundary check must not swallow the
    // island that follows it.
    {
        const input = "<scripty><island src=\"components/A.island.tsx\" client:load :props='{}'></island></scripty>";
        var stub: StubRenderer = .{};
        const result = try process(gpa, arena, input, "/", &stub, .{});
        defer gpa.free(result.html);
        try std.testing.expectEqual(@as(usize, 1), result.instances.len);
    }
}

test "skipping a comment or raw-text region still processes the islands around it" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input =
        "<main><!-- <island src=\"components/Old.island.tsx\" client:load /> -->" ++
        "<island src=\"components/Counter.island.tsx\" client:load :props='{ .start = 1, .label = \"a\" }'></island>" ++
        "<script>\"<island src=\\\"components/Fake.island.tsx\\\" client:load />\"</script>" ++
        "<island src=\"components/Counter.island.tsx\" client:load :props='{ .start = 2, .label = \"b\" }'></island>" ++
        "</main>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // Exactly the two real islands, with consecutive ids.
    try std.testing.expectEqual(@as(usize, 2), result.instances.len);
    try std.testing.expectEqualStrings("z-island-0", result.instances[0].id);
    try std.testing.expectEqualStrings("z-island-1", result.instances[1].id);
    // The skipped regions are still present, unmodified.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<!-- <island src=\"components/Old.island.tsx\" client:load /> -->") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<script>\"<island src=\\\"components/Fake.island.tsx\\\" client:load />\"</script>") != null);
    // Neither skipped src was SSR'd or bundled.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "Old.island.js") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<stub data-src=\"Fake.island.tsx\">") == null);
}

test "a commented-out island inside another island's slot content is not processed" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // The slot body is re-processed by a recursive `rewrite`, so the skip must
    // hold there too. `matchingClose` still counts the commented-out open/close
    // pair while locating the outer `</island>`; because a commented-out island
    // is balanced markup, the depth accounting cancels out and the OUTER island
    // is closed at the right place — asserted here so the two scans stay in sync.
    const input =
        "<island src=\"components/Card.island.tsx\" client:load :props='{}'>" ++
        "<!-- <island src=\"components/Old.island.tsx\" client:load></island> -->" ++
        "<p>body</p>" ++
        "</island>";

    var stub: StubRenderer = .{};
    const result = try process(gpa, arena, input, "/", &stub, .{});
    defer gpa.free(result.html);

    // Only the outer island exists: the commented-out one is neither counted,
    // SSR'd, nor given a module URL to bundle.
    try std.testing.expectEqual(@as(usize, 1), result.instances.len);
    try std.testing.expectEqualStrings("components/Card.island.tsx", result.instances[0].src);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "Old.island.js") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "z-island-1") == null);
    // The comment reached the slot JSON as ordinary (unrewritten) slot markup:
    // the raw `<island …>` text is still there, with no placeholder wrapper.
    try std.testing.expect(std.mem.indexOf(u8, stub.last_slots_json, "Old.island.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.last_slots_json, "data-z-island") == null);
}

test "every comment terminator a browser honors ends the skip region" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // A comment the browser closes must not swallow the islands after it — that
    // would be a new way to ship a page whose islands never hydrate.
    const prefixes = [_][]const u8{
        "<!-- x -->", // ordinary
        "<!-->", // abrupt close of an empty comment
        "<!--->", // abrupt close, one dash
        "<!-- x --->", // trailing dash before the '>'
        "<!-- x --!>", // end-bang form
    };
    for (prefixes) |prefix| {
        const input = try std.mem.concat(arena.a, u8, &.{
            prefix,
            "<island src=\"components/Counter.island.tsx\" client:load :props='{}'></island>",
        });
        var stub: StubRenderer = .{};
        const result = try process(gpa, arena, input, "/", &stub, .{});
        defer gpa.free(result.html);
        try std.testing.expectEqual(@as(usize, 1), result.instances.len);
        try std.testing.expect(std.mem.startsWith(u8, result.html, prefix));
    }
}

test "unterminated comment / raw-text element copies the remainder through unchanged" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // No crash, no error, and — critically — no silently dropped bytes: an
    // unterminated skip region extends to end-of-input and is copied verbatim.
    const inputs = [_][]const u8{
        "<main><!-- <island src=\"components/A.island.tsx\" client:load />",
        "<main><script><island src=\"components/A.island.tsx\" client:load />",
        "<main><script>", // truncated mid-content
        "<main><script", // truncated mid-open-tag
        "<main><island", // truncated island tag: not a tag, no MalformedIsland
    };
    for (inputs) |input| {
        var stub: StubRenderer = .{};
        const result = try process(gpa, arena, input, "/", &stub, .{});
        defer gpa.free(result.html);
        try std.testing.expectEqual(@as(usize, 0), result.instances.len);
        try std.testing.expectEqualStrings(input, result.html);
    }
}

test "an unterminated real island tag is still a loud MalformedIsland" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // The skip-region scan must not soften this: `<island ` IS a tag start, and
    // a tag with no '>' is malformed input the build should reject.
    var stub: StubRenderer = .{};
    try std.testing.expectError(error.MalformedIsland, process(gpa, arena, "<main><island src=\"components/A.island.tsx\"", "/", &stub, .{}));
    // Likewise an open tag with no `</island>` close.
    try std.testing.expectError(error.MalformedIsland, process(gpa, arena, "<main><island src=\"components/A.island.tsx\" client:load>", "/", &stub, .{}));
}

// A renderer that always throws a sidecar-style render error, filling `err_out`
// with a message + stack the same way the real Sidecar does. Lets the pass tests
// exercise the fail-vs-placeholder policy without a Bun process.
const ErroringRenderer = struct {
    pub fn render(_: *@This(), _: RenderArena, _: []const u8, _: []const u8, _: []const u8, _: []const u8, err_out: ?*sidecar.RenderError) ![]const u8 {
        if (err_out) |eo| eo.* = .{ .message = "boom: undefined is not a function", .stack = "at Widget (Widget.island.tsx:12:7)" };
        return error.SidecarRenderFailed;
    }
};

test "on_render_error=.fail propagates a render error and records the structured detail" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input = "<main><island src=\"components/Widget.island.tsx\" client:load :props='{}'></island></main>";
    var er: ErroringRenderer = .{};
    var reports: std.ArrayListUnmanaged(RenderErrorReport) = .empty;
    defer reports.deinit(gpa);
    // .fail is the default; be explicit here. The error surfaces to the caller,
    // and the sink captured the failing island's src/route/message/stack first
    // (so the caller can log it with page context instead of a bare name).
    try std.testing.expectError(error.SidecarRenderFailed, process(gpa, arena, input, "/booking/", &er, .{
        .on_render_error = .fail,
        .render_errors = &reports,
    }));
    try std.testing.expectEqual(@as(usize, 1), reports.items.len);
    try std.testing.expectEqualStrings("components/Widget.island.tsx", reports.items[0].src);
    try std.testing.expectEqualStrings("/booking/", reports.items[0].route);
    try std.testing.expectEqualStrings("boom: undefined is not a function", reports.items[0].message);
    try std.testing.expectEqualStrings("at Widget (Widget.island.tsx:12:7)", reports.items[0].stack.?);
}

test "on_render_error=.placeholder emits a visible placeholder, records the error, and keeps rendering (dev)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const input = "<main><island src=\"components/Widget.island.tsx\" client:load :props='{}'></island></main>";
    var er: ErroringRenderer = .{};
    var reports: std.ArrayListUnmanaged(RenderErrorReport) = .empty;
    defer reports.deinit(gpa);
    const result = try process(gpa, arena, input, "/", &er, .{
        .on_render_error = .placeholder,
        .render_errors = &reports,
    });
    defer gpa.free(result.html);

    // The page did NOT collapse: surrounding markup is preserved, and a visible
    // placeholder carrying the failing src + JS message replaced the island's SSR.
    try std.testing.expect(std.mem.indexOf(u8, result.html, "<main>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "data-z-island-error") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "components/Widget.island.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.html, "boom: undefined is not a function") != null);
    // The island instance is still registered so the client can hydrate it once fixed.
    try std.testing.expectEqual(@as(usize, 1), result.instances.len);
    // The error is also reported to the caller (for the dev warning log).
    try std.testing.expectEqual(@as(usize, 1), reports.items.len);
    try std.testing.expectEqualStrings("boom: undefined is not a function", reports.items[0].message);
}
