//! Fork-added (`--allow-missing-pages`, issue #27 / DX-8). The `Value` arm
//! `$site.page(ref)` resolves to when the flag is set and `ref` doesn't
//! resolve to an existing page, instead of the ordinary `Value.err` that
//! aborts the render.
//!
//! A missing page's metadata cannot be honestly fabricated -- there is no
//! title, no content, nothing to render for a page that hasn't been written
//! yet -- so the ONLY thing you can do with one is ask where it WILL live:
//! `.link()`. Every other field access or builtin call is a precise error
//! naming the ref, via `dynamicDot`/`fallbackCall` below, rather than
//! scripty's generic "type has no fields" / "builtin function not found".
const MissingPage = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const context = @import("../context.zig");
const Value = context.Value;
const String = context.String;
const Signature = @import("doctypes.zig").Signature;

/// Which site (locale/variant) `ref` was resolved against. Not necessarily
/// `ctx.site`: `$site.locale('x').page('y')` looks `ref` up against a
/// different variant than the page currently rendering, so `.link()` must use
/// THIS site's prefix.
site: *const context.Site,
/// The literal `ref` argument to the `$site.page(ref)` call that produced
/// this value. Borrowed -- safely, unlike `Warnings.seen`'s dedup key (see
/// that field's doc comment): `ref` can be a template-source literal OR a
/// string computed at render time (e.g. `$site.page($page.author.lower())`,
/// which `context/String.zig`'s `lower` allocates from the VM's `gpa`, the
/// per-render-job arena -- see `worker.zig`'s `SuperVM.init(arena.a, ...)`).
/// Either way this `MissingPage` value and its `ref` are consumed within the
/// SAME render job that produced them and never outlive it, so the borrow is
/// sound regardless of which case produced the slice. `Warnings.seen` is
/// different only because IT is build-lifetime, not job-lifetime.
ref: []const u8,

pub const docs_description =
    \\A page reference that doesn't resolve to an existing page, returned by
    \\`$site.page(...)` only when the site is built with `--allow-missing-pages`
    \\(an ordinary lookup miss is a hard build error otherwise -- this type
    \\exists so an "under construction" nav link doesn't have to block every
    \\other page from building).
    \\
    \\A missing page has no title, no content, nothing else that could be
    \\honestly returned -- so the only available operation is `.link()`, which
    \\returns the URL the page WILL have once it's written. That URL is a 404
    \\until then; that is what "missing" means.
;

pub const Builtins = struct {
    pub const link = struct {
        pub const signature: Signature = .{ .ret = .String };
        pub const docs_description =
            \\Returns the URL the missing page will have once it exists.
        ;
        pub const examples =
            \\$site.page('coming-soon').link()
        ;
        /// NO_SLOP.md §2.2a contract 1 (self-freeing): the only allocation is
        /// the returned `String`'s backing bytes. That means `toOwnedSlice`,
        /// not `written()`: `Writer.Allocating.written()` returns a slice into
        /// a buffer that may be LARGER than the slice, so a caller handed it
        /// cannot `free` it (wrong length/base) -- contract 1 promises an
        /// allocation a caller can free under ANY allocator, and `written()`
        /// breaks that even though nothing breaks TODAY (every caller in this
        /// codebase happens to be arena-backed). This is a deliberate
        /// divergence from the neighbouring, shape-identical builtins --
        /// `context/Page.zig`'s `link` and `context/Array.zig`'s `toJson` both
        /// return `written()` -- but those are inherited upstream code with no
        /// contract label; this one is fork-added and carries one, so the
        /// label has to actually hold.
        pub fn call(
            mp: MissingPage,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            if (args.len != 0) return .{ .err = "expected 0 arguments" };

            var aw: Writer.Allocating = .init(gpa);
            writeLink(&aw.writer, ctx, mp.site, mp.ref) catch return error.OutOfMemory;
            const url = aw.toOwnedSlice() catch return error.OutOfMemory;
            return String.init(url);
        }
    };
};

/// A field access (`$site.page('x').title`, no parens) has no honest answer
/// -- see `docs_description` -- so name the missing page and point at the one
/// thing that DOES work, instead of scripty's generic "type has no fields".
pub fn dynamicDot(
    mp: MissingPage,
    gpa: Allocator,
    component: []const u8,
) context.CallError!Value {
    return Value.errFmt(
        gpa,
        "'.{s}': page '{s}' does not exist yet (built with --allow-missing-pages) -- the only thing available on a missing page is .link()",
        .{ component, mp.ref },
    );
}

/// An unknown builtin CALL (`$site.page('x').title()`) -- same reasoning as
/// `dynamicDot`, for the call path instead of the dot path. `.link()` itself
/// is dispatched by `Builtins.link` above and never reaches this.
pub fn fallbackCall(
    mp: MissingPage,
    gpa: Allocator,
    ctx: *const context.Root,
    fn_name: []const u8,
    args: []const Value,
) context.CallError!Value {
    _ = ctx;
    _ = args;
    return Value.errFmt(
        gpa,
        "'.{s}()': page '{s}' does not exist yet (built with --allow-missing-pages) -- the only thing available on a missing page is .link()",
        .{ fn_name, mp.ref },
    );
}

/// NO_SLOP.md §2.2a contract 3 (caller-buffer): allocates nothing, writes
/// through the caller's writer. Shared by `Builtins.link` (arena-backed, via
/// `Writer.Allocating`) and `Warnings.warn` below (a stack `Writer.fixed`, no
/// allocator at all) so the URL rule lives in exactly one place. Mirrors
/// `context/Root.zig`'s `printLinkPrefix` + a bare `ref` (there is no
/// resolved `Path` to format component-by-component the way a real page's
/// link is -- `ref` IS the path, verbatim, because nothing ever validated it
/// against the path table).
fn writeLink(
    w: *Writer,
    ctx: *const context.Root,
    site: *const context.Site,
    ref: []const u8,
) error{ OutOfMemory, WriteFailed }!void {
    try ctx.printLinkPrefix(w, site._meta.variant_id, false);

    // No `std.mem.trimStart(ref, "/")` here: `ref` can never start with '/'
    // by the time it reaches this function. Every call path (`Builtins.link`,
    // `Warnings.warn`, both via `tolerate`) carries a `ref` that already
    // passed `Site.page`'s `root.validatePathMessage(ref, .{ .empty = true })`
    // gate, and `validatePath` rejects a leading '/' with `error.AbsolutePath`
    // before `Site.page` ever reaches the "not found" arms that call
    // `tolerate`.
    //
    // Belt-and-braces guard, not a live bug: `ref == ""` (the homepage) is
    // the one case that gate DOES allow through, and `printLinkPrefix` above
    // always ends in '/' -- writing an empty `ref` plus a second '/' would
    // collapse into a bare "//". In practice this never fires: the root
    // `index.smd` is mandatory (`root.zig` fatals with "No content found" if
    // a variant has none), so `Site.page('')`'s lookup always resolves to a
    // real `page_main` hint and never falls through to `tolerate` at all.
    // The guard costs nothing and removes the need to keep re-proving that
    // invariant every time this function is touched.
    if (ref.len > 0) {
        try w.writeAll(ref);
        try w.writeAll("/");
    }
}

/// Builds the tolerated `.missing_page` Value for `Site.page`'s two
/// "not found" sites, warning once per distinct `ref` on the way. Takes no
/// `Allocator` (so NO_SLOP.md §2.2a doesn't apply): the warning path below
/// allocates nothing but map-bucket storage on its own `Warnings.gpa` (see
/// that struct's contract note), and the returned `Value` borrows
/// `site`/`ref` rather than owning anything new.
pub fn tolerate(
    ctx: *const context.Root,
    site: *const context.Site,
    ref: []const u8,
) Value {
    ctx._meta.build.missing_page_warnings.warn(ctx, site, ref);
    return .{ .missing_page = .{ .site = site, .ref = ref } };
}

/// Dedup state for the `--allow-missing-pages` TEMPLATE-lookup warning. A
/// nav partial's `$site.page('demos')` runs once per page that includes it,
/// so without dedup a single dangling ref would print once per page instead
/// of once per build.
///
/// NO_SLOP.md §2.2a contract 2 (owned-result): `gpa` is the BUILD-lifetime
/// allocator (not the per-render-job arena, which resets after every page
/// and would erase the dedup set) that `seen` grows with; `deinit` frees it.
/// The pointer this lives behind is owned by `Build` -- see that field's doc
/// comment for the full lifetime story.
///
/// A missing-ref warning is emitted once per distinct `ref`, not once per
/// distinct (site, ref) pair: `$site.locale('a').page(r)` and
/// `$site.locale('b').page(r)` reaching the same dangling `r` warn ONCE,
/// showing whichever locale's `.link()` URL happened to render first. That
/// is the agreed "once per distinct ref" design (a build-wide log, not a
/// per-site one), but it means the printed URL is not necessarily every
/// caller's URL -- worth knowing if a report ever looks locale-mismatched.
pub const Warnings = struct {
    gpa: Allocator,
    mutex: std.Io.Mutex = .init,
    /// Keyed on the literal `ref` string. The key MUST be an owned copy, not
    /// a borrow: `ref` can be a string computed at render time (see the doc
    /// comment on `MissingPage.ref` for the mechanism -- `context/String.zig`
    /// builtins like `lower`/`suffix`/`prefix`/`fmt`/`addPath` allocate their
    /// result from the per-render-job arena, which is reset after every job,
    /// while this map is build-lifetime). Storing the borrowed slice would
    /// make every later `getOrPut` hash and compare recycled/freed memory --
    /// a latent use-after-free that happens to read back correctly only
    /// because per-job allocation is deterministic. `warn` below dupes on
    /// insert; `deinit` frees each key alongside the map's own bucket
    /// storage.
    seen: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: Allocator) Warnings {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Warnings) void {
        var it = w.seen.keyIterator();
        while (it.next()) |key| w.gpa.free(key.*);
        w.seen.deinit(w.gpa);
    }

    /// Prints the build-log warning for `ref`, exactly once across the whole
    /// build. `io` (for the mutex lock) comes from `ctx._meta.io`, following
    /// the established pattern in `worker.zig`'s `island_props_checks_mutex`.
    fn warn(
        w: *Warnings,
        ctx: *const context.Root,
        site: *const context.Site,
        ref: []const u8,
    ) void {
        const io = ctx._meta.io;
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);

        const gop = w.seen.getOrPut(w.gpa, ref) catch |err| switch (err) {
            error.OutOfMemory => @import("../fatal.zig").oom(),
        };
        if (gop.found_existing) return;
        // `getOrPut` inserted `ref` itself as the key on the not-found path
        // above; overwrite it with an owned copy before anything can key off
        // the (possibly job-arena-backed) borrow. Same idiom as
        // `cli/dev.zig`'s `islandPagesFromManifest`.
        gop.key_ptr.* = w.gpa.dupe(u8, ref) catch |err| switch (err) {
            error.OutOfMemory => @import("../fatal.zig").oom(),
        };

        // A stack buffer, not the render arena: this runs from inside a
        // scripty builtin call, and failing to format a diagnostic must never
        // itself be a build error. On overflow (a pathological ref/prefix)
        // fall back to a shorter message rather than losing the warning.
        var buf: [1024]u8 = undefined;
        var fw = Writer.fixed(&buf);
        writeLink(&fw, ctx, site, ref) catch {
            std.debug.print(
                "warning: $site.page('{s}'): missing page (--allow-missing-pages)\n",
                .{ref},
            );
            return;
        };
        std.debug.print(
            "warning: $site.page('{s}'): missing page -- .link() resolves to '{s}' (--allow-missing-pages)\n",
            .{ ref, fw.buffered() },
        );
    }
};
