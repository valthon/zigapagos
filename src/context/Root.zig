const Root = @This();

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const superhtml = @import("superhtml");
const Ctx = superhtml.utils.Ctx;
const scripty = @import("scripty");
const ziggy = @import("ziggy");
const ZigapagosBuild = @import("../Build.zig");
const context = @import("../context.zig");
const Value = context.Value;
const Site = context.Site;
const Page = context.Page;
const Build = context.Build;
const Map = context.Map;
const Iterator = context.Iterator;
const Optional = context.Optional;

site: *const Site,
page: *const Page,
build: Build,
i18n: Map.ZiggyMap,

_meta: struct {
    io: Io,
    build: *const ZigapagosBuild,
    // Indexed by language code, empty when building a simple site
    // Get by key when you have a language code, get by idx when you
    // have a variant_id.
    sites: *const std.StringArrayHashMapUnmanaged(Site),
},

/// Per-RENDER pagination state — lives here and not on Page because the
/// same *Page is read concurrently by its .main job and every
/// .alternative/.pagination job on other worker threads. Root is a stack
/// local built fresh per job in renderPage, so this is naturally per-job.
/// Set only for .main/.pagination renders of a paginated section index;
/// null for alternatives (RSS must see the full list) and everything else.
_pagination: ?PaginationState = null,

// Globals specific to SuperHTML
ctx: Ctx(Value) = .{},
loop: ?*Iterator = null,
@"if": ?*const Optional = null,

pub const PaginationState = struct {
    current: usize, // 1-based
    total_pages: usize,
    page_size: usize,
    total_items: usize,
};

/// Writes the `.simple`-site (non-multilingual) absolute/relative URL
/// prefix: `host_url` (only when `force_host_url`) followed by the
/// `url_path_prefix` segment, or a bare "/" when there is none.
///
/// Factored out of `printLinkPrefix` below so `src/sitemap.zig`'s emitter —
/// which composes URLs from a post-build pass with no per-render `Root` Ctx
/// to call `printLinkPrefix` through — shares this ONE chokepoint instead of
/// growing a second, driftable copy of the same three lines (issue #150's
/// design caveat: "do not invent a second composition").
///
/// `host_url` may carry exactly one trailing '/' -- `Config.validate`
/// (root.zig) explicitly allows a `host_url` whose URI path is exactly "/"
/// (the percent-encoded-path carve-out next to its "must not contain a
/// path" check), and stores it untrimmed: `$site.host_url` has to keep
/// reading back what the author wrote. Every consumer of THIS function
/// unconditionally appends its own leading '/' next (either the
/// `url_path_prefix` branch or the bare "/" below), so printing `host_url`
/// verbatim doubles that slash -- "https://example.com/" + "/" ->
/// "https://example.com//" -- in every absolute URL this chokepoint
/// composes: sitemap `<loc>` entries (always `force_host_url`),
/// `$page.absLink()`, `Asset.absLink()`. Trimmed HERE, not at config load
/// (that would change the value `$site.host_url` itself reads back as) and
/// not per call site (every one of them would need the same fix).
pub fn printSimplePrefix(
    w: *Writer,
    host_url: []const u8,
    url_path_prefix: []const u8,
    force_host_url: bool,
) error{WriteFailed}!void {
    if (force_host_url) {
        const trimmed = if (std.mem.endsWith(u8, host_url, "/"))
            host_url[0 .. host_url.len - 1]
        else
            host_url;
        try w.print("{s}", .{trimmed});
    }
    if (url_path_prefix.len > 0) {
        try w.print("/{s}/", .{url_path_prefix});
    } else {
        try w.writeAll("/");
    }
}

pub fn printLinkPrefix(
    ctx: *const Root,
    w: *Writer,
    other_variant_id: u32,
    /// When set to true the full host url will be always printed
    /// otherwise it will only be added in multilingual websites when
    /// linking to content across variants that have different host url
    /// overrides.
    force_host_url: bool,
) error{ OutOfMemory, WriteFailed }!void {
    const other_site = ctx._meta.sites.entries.items(.value)[other_variant_id];
    switch (other_site._meta.kind) {
        .simple => |url_path_prefix| {
            try printSimplePrefix(w, ctx._meta.build.cfg.Site.host_url, url_path_prefix, force_host_url);
        },
        .multi => |loc| {
            const our_variant_id = ctx.page._scan.variant_id;
            if (other_variant_id != our_variant_id) {
                const sites = ctx._meta.sites.entries.items(.value);
                const our_host_url = sites[our_variant_id].host_url;
                const other_host_url = sites[other_variant_id].host_url;
                if (force_host_url or our_host_url.ptr != other_host_url.ptr) {
                    try w.print("{s}", .{other_host_url});
                }
            }
            try w.writeAll("/");
            const path_prefix = loc.output_prefix_override orelse loc.code;
            if (path_prefix.len > 0) try w.print("{s}/", .{path_prefix});
        },
    }
}

/// The one patch `printLinkPrefix` above cannot provide on its own (issue
/// #151 review -- extracted here after `Asset.linkImpl` and `Page.linkImpl`
/// were caught carrying verbatim-identical copies of it, each with its own
/// long comment restating the same reasoning). Call this INSTEAD of
/// `printLinkPrefix` whenever the caller wants an absolute URL
/// (`force_host_url=true` in `Asset`/`Page`'s `absLink()` family); for the
/// relative case call `printLinkPrefix(w, variant_id, false)` directly --
/// there is no patch to apply there, and skipping this function is what
/// keeps the relative hot path (`link()`) from computing (and discarding)
/// the site/`handled` lookup below on every call.
///
/// The gap: `printLinkPrefix`'s `.multi` arm only ever prints a host INSIDE
/// `if (other_variant_id != our_variant_id)`, i.e. only cross-variant. A
/// same-variant target on a multilingual site -- the common case, since the
/// target is usually the page currently rendering -- falls through that
/// guard and comes back root-relative even when the caller asked for an
/// absolute URL. Hence `handled`: this function prints the host itself ONLY
/// in the cell `printLinkPrefix` ignores (multilingual, same variant), then
/// defers to `printLinkPrefix(force_host_url=true)` for everything else --
/// every cross-variant case (which already prints on its own whenever the
/// two hosts differ) and the simple-site case.
///
/// The patch lives HERE, wrapped around `printLinkPrefix`, rather than
/// inside it, because `printLinkPrefix`'s `force_host_url` parameter is not
/// exclusively "give me an absolute URL": `render/html.zig`'s `printUrl`
/// call sites pass `page != ctx.page`, reusing the same parameter as "this
/// is a cross-page reference" -- and `page != ctx.page` with the SAME
/// variant is reachable via embedded content. Making `printLinkPrefix`
/// itself always print a same-variant host under that flag would change
/// `$link` output on every multilingual site that embeds content across
/// pages. This function is additive on top instead: a second, narrower call
/// that only ever runs where `Asset.absLink()`/`Page.absLink()` route
/// through it.
///
/// This is the SINGLE home for this patch and its reasoning -- do not
/// duplicate it back into `Asset.linkImpl`/`Page.linkImpl`, and do not add a
/// third composition path elsewhere (e.g. hand-composing
/// `$site.host_url.addPath(...)`, the doctor-recommended workaround
/// `Page.absLink()` replaced): `printLinkPrefix` plus this one patched cell
/// is the WHOLE story for how an absolute link is built.
pub fn printAbsLinkPrefix(
    ctx: *const Root,
    w: *Writer,
    variant_id: u32,
) error{ OutOfMemory, WriteFailed }!void {
    const site = ctx._meta.sites.entries.items(.value)[variant_id];
    const handled = switch (site._meta.kind) {
        .simple => true,
        .multi => variant_id != ctx.page._scan.variant_id,
    };
    if (!handled) try w.print("{s}", .{site.host_url});
    try ctx.printLinkPrefix(w, variant_id, true);
}

pub const docs_description = "";
pub const Fields = struct {
    pub const site =
        \\The current website. In a multilingual website,
        \\each locale will have its own separate instance of $site
    ;

    pub const page =
        \\The page being currently rendered.
    ;

    pub const i18n =
        \\In a multilingual website it contains the translations 
        \\defined in the corresponding i18n file.
        \\
        \\See the i18n docs for more info.
    ;

    pub const build =
        \\Gives you access to build-time assets (i.e. assets built
        \\ via the Zig build system) alongside other information
        \\relative to the current build.
    ;

    pub const ctx =
        \\A key-value mapping that contains data defined in `<ctx>`
        \\nodes.
    ;

    pub const loop =
        \\The current iterator, only available within elements
        \\that have a `loop` attribute.
    ;

    pub const @"if" =
        \\The current branching variable, only available within elements
        \\that have an `if` attribute used to unwrap an optional value.
    ;
};

pub const Dot = true;
pub const Builtins = struct {};
