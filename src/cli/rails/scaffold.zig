//! Writes the target tree a Rails migration produces, and reports what each
//! route actually became.
//!
//! This is the only file in `src/cli/rails/` that touches the filesystem for
//! WRITING. Everything it emits is a pure function of the `Discovery` and the
//! operator's `decisions` it is handed -- no timestamps, no absolute paths, no
//! ambient state -- so two runs over the same app produce byte-identical
//! trees (plan, Global Constraints). Where an input slice's order is not
//! promised (the route table comes off a Ruby sidecar, the asset table off a
//! directory walk), this file sorts it before reading it, rather than
//! inheriting an order nothing guarantees.
//!
//! **Nothing here fatals.** A write that cannot be made returns
//! `error.TargetWrite` with the offending path in the caller's
//! `last_error_path`; `migrate.zig` turns that into `fatal.file`. A SOURCE
//! read that fails (an asset that vanished or is unreadable) returns
//! `error.SourceRead` the same way -- a distinct error because the fix is
//! different (a permission in the Rails app, not in the target).
//!
//! **Every write is exclusive-create** (`.{ .exclusive = true }`, parents
//! created). A pre-existing file is a hard failure, not an overwrite: the
//! target may only pre-exist to carry `MIGRATION.decisions.json` forward
//! across a decide-and-re-run loop (plan, Global Constraints), so anything
//! else already there means the operator is writing into a tree they have not
//! wiped, and silently clobbering it would destroy hand edits.
//!
//! **Status is the CONVERSION's verdict, not discovery's.** `Discovery`'s
//! `classification` says what the Rails route looked like; `RouteOutcome.
//! status` says what came out the other end, and where they disagree the
//! conversion wins (spec, "Conversion: what a route becomes"). A `content`
//! route whose view holds an unknown helper is `open`; an `unresolved` one
//! whose only blemish has a defined conversion is `migrated`.
//!
//! Four things make a route NOT `migrated`, and all four are checked:
//!
//! 1. a finding id left open on the view, its layout, or any partial inlined
//!    into either;
//! 2. an `<!-- rails:unmapped ... -->` region in the converted bytes, which
//!    carries NO finding id at all (`convert.zig`'s module doc; Stage 2 plan
//!    ruling S6). Since ruling S12 gave every fragment kind the converter
//!    treats as a finding its own derivation row, this fires only for a
//!    genuinely unmapped construct (a partial cycle, an unbound local) -- but
//!    it stays, because a placeholder with no id is precisely the case that
//!    an empty `open_finding_ids` cannot see;
//! 3. a template `convert` refused outright (`error.Unconvertible`: a parse
//!    error or a file the templates op never read);
//! 4. anything else the conversion could not finish, recorded through
//!    `Outcome.addOpenNote` -- a route with no view, a layout that would not
//!    convert, a content path another route already claimed, a `spa` decision
//!    with nowhere to mount.
//!
//! An operator decision of `retain`/`blocked` on any open finding turns that
//! into an acknowledged status; `island`/`backend` are recorded but leave the
//! route `open` with a note, because Stage 2 cannot produce the artifact
//! either choice promises (plan, Global Constraints).
//!
//! Ruling S20: an acknowledged route writes NO `content/**/index.smd` and no
//! `layouts/<viewStem>.shtml`. `retained` says the page stays on Rails, so
//! this target must not answer that URL; `blocked` says it does not ship.
//! Writing the converted page anyway made `blocked` a relabelling and nothing
//! else -- the built site served a blank `<main>` for a route the handoff
//! called blocked, which is worse than a 404 because it looks deliberate. The
//! handoff row is the record of what happened; the target holds only what the
//! site serves. An `open` route (including an `island`/`backend` deferral)
//! still gets its page: it is a page with a gap in it, not an absent one.
//! `layouts/templates/<layout>.shtml` is unaffected -- a layout is shared
//! chrome, written once per layout rather than per route.
//!
//! Ruling S19: that acknowledgement is read BEFORE reason 2, not after.
//! `retain` means the page stays on Rails and this target never serves it and
//! `blocked` means it does not ship, so a region the converter could not map
//! changes nothing about either answer -- while checking S6 first made a route
//! carrying one permanently uncompletable, whatever the operator said. Reason
//! 2 keeps its force for the route nobody answered: it has no finding id, so
//! nobody can be asked about it, and it must not reach `migrated` on the
//! strength of an empty `open_finding_ids`. A route with an unmapped region
//! and NO finding at all therefore still cannot be completed -- a documented
//! converter gap (`convert.zig` should inline or drop an unbound local rather
//! than leave a placeholder), not something a decision file can answer.
//!
//! `RouteOutcome.note` also carries the conversion's own `Output.dropped`
//! notes, joined with `"; "` -- `MIGRATION.md` is the only place an operator
//! ever learns what the conversion removed. Ruling S15 splits them: a csrf
//! tag, a JS entry helper and a `<title>` suffix each name a construct with a
//! DEFINED conversion, lose nothing, and stay informational; a `content_for`
//! naming a block the layout does not declare loses the author's own markup
//! and is reason 4 above. `foldDropped` is where that line is drawn.
//!
//! **One view converts once per LAYOUT, and the first route owns the file**
//! (ruling S16). A view's bytes depend on the layout it extends, and the
//! target has one `layouts/<viewStem>.shtml`, so a second route reaching the
//! same view under a different layout is reported (`open`, naming both) rather
//! than served a page whose `<extend>` points at the wrong parent.
//!
//! std-only, like every file in `src/cli/rails/`. The handful of small
//! emitters below (`zigapagos.ziggy`, `build.sh`, `package.json`,
//! `tsconfig.json`, `.gitignore`) are DUPLICATED from `src/cli/migrate.zig`'s
//! `emitTarget*`/`target_*` rather than imported: `migrate.zig` lives outside
//! this module and importing it would break the std-only boundary (and its
//! versions call `fatal.oom()`, which this file must not). The byte shapes
//! are meant to stay identical; each emitter names its counterpart so a
//! future edit to one is findable from the other.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const asset_mod = @import("assets.zig");
const classify = @import("classify.zig");
const convert = @import("convert.zig");
const decisions = @import("decisions.zig");
const findings = @import("findings.zig");
const fragments = @import("fragments.zig");
const rails = @import("rails.zig");
const resolve = @import("resolve.zig");
const route_mod = @import("routes.zig");

/// What one route became. `route_index` indexes `Input.discovery.routes`, so
/// a consumer can recover the verb/path/source without this struct carrying
/// a second copy of them.
///
/// Contract 2 (owned-result): `artifacts`, `open_finding_ids`, `decision_id`
/// and `note` are fresh `gpa` allocations; released by `freeResult`.
pub const RouteOutcome = struct {
    route_index: usize,
    status: Status,
    /// Target-relative paths written FOR this route, sorted. A file shared
    /// with another route (a layout, a view two routes both render, a SPA
    /// entry) is listed on every route that reaches it, and written once.
    artifacts: [][]const u8,
    /// Finding ids still open on this route, sorted and deduped. Non-empty
    /// with a `retained`/`blocked` status too: the findings did not go away,
    /// they were acknowledged.
    open_finding_ids: [][]const u8,
    /// The decision that produced a non-`open` status, when one did.
    decision_id: ?[]const u8,
    /// Why this route is not `migrated`, when the finding ids alone do not
    /// say -- an unmapped region, a missing view, a deferred choice.
    note: ?[]const u8,
};

/// `migrated` -- a real page was written and nothing is left open.
/// `open` -- something is unresolved and nobody has said what to do.
/// `blocked`/`retained` -- an operator decision acknowledged it.
/// `backend` -- not a page at all (a non-GET route, or one discovery
/// classified `backend`); Stage 3 maps it to an endpoint.
/// `redirect` -- the host config owns it; see `Result.redirects`.
pub const Status = enum { migrated, open, blocked, retained, backend, redirect };

/// One copied asset. `rails_url` is what Rails served it at (`null` when the
/// pipeline could not be pinned down), `target_url` what the built site
/// serves it at.
pub const AssetOutcome = struct {
    source: []const u8,
    rails_url: ?[]const u8,
    target_url: []const u8,
};

/// A route the static tree cannot express. `to` is always `null` in Stage 2:
/// discovery recovers that a controller action redirects, not where to --
/// extracting the `redirect_to` target is Stage 3's job.
pub const Redirect = struct { from: []const u8, to: ?[]const u8 };

/// Contract 2 (owned-result): released by `freeResult`.
pub const Result = struct {
    /// One entry per `Discovery.routes` entry, in this file's own sorted
    /// route order (see `routeLessThan`) rather than discovery's -- the
    /// caller reads `route_index`, and a stable order here keeps the whole
    /// result byte-reproducible.
    routes: []RouteOutcome,
    assets: []AssetOutcome,
    redirects: []Redirect,
    /// Target-relative `.spa.tsx` paths written, sorted.
    spa_files: [][]const u8,
};

pub const WriteError = error{
    /// A file in the target could not be created or written. The path is in
    /// the caller's `last_error_path`.
    TargetWrite,
    /// A file in the SOURCE app could not be read (only assets are read
    /// here). The path is in `last_error_path`.
    ///
    /// Not folded into `TargetWrite` because the two send an operator to
    /// different places, and not swallowed because an asset silently missing
    /// from the built site is exactly the kind of "looks migrated, isn't"
    /// outcome the whole findings mechanism exists to prevent.
    SourceRead,
} || Allocator.Error;

pub const Input = struct {
    discovery: *const rails.Discovery,
    decisions: decisions.Parsed,
    /// The Rails app root, for READING assets. `write` never writes through
    /// it -- the source tree is never touched.
    source_root: Io.Dir,
    /// Target directory, relative to the process cwd (like `migrate.zig`'s
    /// own `writeTargetFile`). Created if missing.
    target: []const u8,
    app_name: []const u8,
    /// `file:` path for `@z/runtime` in a generated `package.json`. Only read
    /// when a SPA is scaffolded.
    runtime_path: ?[]const u8,
    /// `AGENTS.md`/`CLAUDE.md` bytes. Passed in rather than `@embedFile`d
    /// because those files live in `src/cli/init/`, outside this module.
    agents_md: []const u8,
    claude_md: []const u8,
};

/// Contract 2 counterpart to `write`.
pub fn freeResult(gpa: Allocator, r: Result) void {
    for (r.routes) |o| {
        freeStrings(gpa, o.artifacts);
        freeStrings(gpa, o.open_finding_ids);
        if (o.decision_id) |d| gpa.free(d);
        if (o.note) |n| gpa.free(n);
    }
    gpa.free(r.routes);
    for (r.assets) |a| {
        gpa.free(a.source);
        if (a.rails_url) |u| gpa.free(u);
        gpa.free(a.target_url);
    }
    gpa.free(r.assets);
    for (r.redirects) |x| {
        gpa.free(x.from);
        if (x.to) |t| gpa.free(t);
    }
    gpa.free(r.redirects);
    freeStrings(gpa, r.spa_files);
}

fn freeStrings(gpa: Allocator, list: [][]const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

// ---- the write itself ----------------------------------------------------

/// Writes the whole target tree and reports what every route became.
///
/// `last_error_path` is set (to a fresh `gpa` allocation the CALLER frees)
/// only on `TargetWrite`/`SourceRead`, and is left untouched otherwise. It
/// can still be `null` after such an error, in the one case where duping the
/// path itself ran out of memory -- the error is still the honest one, and a
/// message without a path beats losing the failure.
///
/// `last_error` carries the OS error that actually happened, alongside the
/// path (ruling S14). Without it `TargetWrite` collapses every cause into one
/// word, and the two an operator most needs to tell apart -- a target that
/// already has the file (`PathAlreadyExists`: wipe it and re-run) and a
/// directory they cannot write (`AccessDenied`: fix the permission) -- read
/// identically. `migrate.zig` puts it in the fatal message.
///
/// Contract 2 (owned-result): the returned `Result` owns every string in it
/// and is released with `freeResult`. On any error nothing escapes: every
/// partial result is freed before returning.
pub fn write(
    io: Io,
    gpa: Allocator,
    in: Input,
    last_error_path: *?[]const u8,
    last_error: *?anyerror,
) WriteError!Result {
    var ctx: Ctx = .{
        .io = io,
        .gpa = gpa,
        .in = in,
        .last_error_path = last_error_path,
        .last_error = last_error,
    };

    var acc: Acc = .{};
    errdefer acc.deinit(gpa);

    try run(&ctx, &acc);

    const route_outcomes = try acc.routes.toOwnedSlice(gpa);
    errdefer {
        for (route_outcomes) |o| {
            freeStrings(gpa, o.artifacts);
            freeStrings(gpa, o.open_finding_ids);
            if (o.decision_id) |d| gpa.free(d);
            if (o.note) |n| gpa.free(n);
        }
        gpa.free(route_outcomes);
    }
    const asset_outcomes = try acc.assets.toOwnedSlice(gpa);
    errdefer {
        for (asset_outcomes) |a| {
            gpa.free(a.source);
            if (a.rails_url) |u| gpa.free(u);
            gpa.free(a.target_url);
        }
        gpa.free(asset_outcomes);
    }
    const redirect_list = try acc.redirects.toOwnedSlice(gpa);
    errdefer {
        for (redirect_list) |x| {
            gpa.free(x.from);
            if (x.to) |t| gpa.free(t);
        }
        gpa.free(redirect_list);
    }
    const spa_list = try acc.spa_files.toOwnedSlice(gpa);

    return .{
        .routes = route_outcomes,
        .assets = asset_outcomes,
        .redirects = redirect_list,
        .spa_files = spa_list,
    };
}

/// Everything `write` accumulates, in one place so a failure anywhere can
/// release all of it through one `deinit`.
const Acc = struct {
    routes: std.ArrayListUnmanaged(RouteOutcome) = .empty,
    assets: std.ArrayListUnmanaged(AssetOutcome) = .empty,
    redirects: std.ArrayListUnmanaged(Redirect) = .empty,
    spa_files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Acc, gpa: Allocator) void {
        for (self.routes.items) |o| {
            freeStrings(gpa, o.artifacts);
            freeStrings(gpa, o.open_finding_ids);
            if (o.decision_id) |d| gpa.free(d);
            if (o.note) |n| gpa.free(n);
        }
        self.routes.deinit(gpa);
        for (self.assets.items) |a| {
            gpa.free(a.source);
            if (a.rails_url) |u| gpa.free(u);
            gpa.free(a.target_url);
        }
        self.assets.deinit(gpa);
        for (self.redirects.items) |x| {
            gpa.free(x.from);
            if (x.to) |t| gpa.free(t);
        }
        self.redirects.deinit(gpa);
        for (self.spa_files.items) |s| gpa.free(s);
        self.spa_files.deinit(gpa);
    }
};

/// The filesystem half of `write`, split out so every helper below can take
/// one parameter instead of four.
const Ctx = struct {
    io: Io,
    gpa: Allocator,
    in: Input,
    last_error_path: *?[]const u8,
    last_error: *?anyerror,

    /// Records `path` and the underlying OS error, and returns this file's
    /// own error. An OOM duping the path leaves `last_error_path` null rather
    /// than replacing the real failure with `OutOfMemory` -- see `write`'s
    /// doc. `last_error` is recorded either way, so the cause survives even
    /// when the path does not.
    ///
    /// `which` is a comptime enum literal rather than an `anyerror` value so
    /// the return type stays the two-member set `WriteError` accepts; an
    /// `anyerror` parameter would widen every caller to the global set.
    /// `cause` IS an `anyerror` -- it is data being recorded, not a value
    /// being returned.
    fn fail(
        self: *Ctx,
        comptime which: enum { target, source },
        path: []const u8,
        cause: anyerror,
    ) error{ TargetWrite, SourceRead } {
        if (self.last_error_path.* == null) {
            self.last_error_path.* = self.gpa.dupe(u8, path) catch null;
            self.last_error.* = cause;
        }
        return switch (which) {
            .target => error.TargetWrite,
            .source => error.SourceRead,
        };
    }

    /// Exclusive-create `<target>/<relative>`, parents included. See the
    /// module doc for why exclusive.
    fn writeFile(self: *Ctx, relative: []const u8, bytes: []const u8) WriteError!void {
        const full = try std.fs.path.join(self.gpa, &.{ self.in.target, relative });
        defer self.gpa.free(full);
        if (std.fs.path.dirname(full)) |parent| {
            Io.Dir.cwd().createDirPath(self.io, parent) catch |err|
                return self.fail(.target, parent, err);
        }
        const file = Io.Dir.cwd().createFile(self.io, full, .{ .exclusive = true }) catch |err|
            return self.fail(.target, full, err);
        defer file.close(self.io);
        // Unbuffered (`&.{}`), exactly like `migrate.zig`'s `writeTargetFile`:
        // one `writeAll` per file, so there is no buffer left to flush.
        var w = file.writer(self.io, &.{});
        w.interface.writeAll(bytes) catch |err| return self.fail(.target, full, err);
    }
};

/// The pass order, and why:
///
/// 1. assets -- independent of everything else, and the only pass that READS
///    the source tree.
/// 2. routes -- converts and writes layouts, views and content pages, and
///    collects the SPA candidates a decision approved.
/// 3. SPA files -- needs pass 2 finished, because one `.spa.tsx` lists every
///    decided route under its first path segment.
/// 4. the project files -- `zigapagos.ziggy` needs to know whether pass 1
///    copied anything, and `build.sh` needs pass 3's file list.
fn run(ctx: *Ctx, acc: *Acc) WriteError!void {
    try writeAssets(ctx, acc);

    var layouts: LayoutCache = .{};
    defer layouts.deinit(ctx.gpa);
    var views: ViewCache = .{};
    defer views.deinit(ctx.gpa);
    var spa_routes: std.ArrayListUnmanaged(SpaRoute) = .empty;
    defer {
        for (spa_routes.items) |s| ctx.gpa.free(s.segment);
        spa_routes.deinit(ctx.gpa);
    }

    try writeRoutes(ctx, acc, &layouts, &views, &spa_routes);
    try writeSpas(ctx, acc, spa_routes.items);
    try writeProjectFiles(ctx, acc);
}

// ---- pass 1: assets ------------------------------------------------------

/// Copies every asset whose URL discovery could pin down.
///
/// `deterministic == true` means `public_url` was derived by a rule that
/// reproduces on every machine; `pipeline == null` is the `public/` case,
/// which bypasses the pipeline entirely and is deterministic by
/// construction. An asset that is neither is one discovery could not place,
/// and copying it would put a file in the target under a name nothing
/// references.
///
/// Contract 2 (owned-result), inherited from `write`: everything appended to
/// `acc` is owned by the eventual `Result`.
fn writeAssets(ctx: *Ctx, acc: *Acc) WriteError!void {
    const gpa = ctx.gpa;
    const list = ctx.in.discovery.assets;

    // `assets.scan` documents its output as path-ordered, but this pass sorts
    // an index copy anyway rather than trusting a promise made two modules
    // away: the copy order decides `Result.assets`' order, which reaches a
    // committed artifact.
    const order = try gpa.alloc(usize, list.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, list, assetIndexLessThan);

    for (order) |i| {
        const a = list[i];
        if (!a.deterministic and a.pipeline != null) continue;
        if (isPipelineOutput(a.source)) continue;

        const rel = try resolve.assetTargetPath(gpa, a.source);
        defer gpa.free(rel);
        const dest = try std.fs.path.join(gpa, &.{ "assets", rel });
        defer gpa.free(dest);

        // 64 MiB: larger than any web asset this converter has a use for,
        // and a bound rather than `.unlimited` so a pathological file in the
        // source tree fails loudly instead of exhausting the process.
        const bytes = ctx.in.source_root.readFileAlloc(ctx.io, a.source, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.fail(.source, a.source, err),
        };
        defer gpa.free(bytes);
        try ctx.writeFile(dest, bytes);

        const source_copy = try gpa.dupe(u8, a.source);
        errdefer gpa.free(source_copy);
        const rails_url = if (a.public_url) |u| try gpa.dupe(u8, u) else null;
        errdefer if (rails_url) |u| gpa.free(u);
        const target_url = try std.fmt.allocPrint(gpa, "/{s}", .{rel});
        errdefer gpa.free(target_url);
        try acc.assets.append(gpa, .{
            .source = source_copy,
            .rails_url = rails_url,
            .target_url = target_url,
        });
    }
}

fn assetIndexLessThan(list: []const asset_mod.Asset, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, list[a].source, list[b].source);
}

/// Ruling S17: `public/assets/**` is the asset pipeline's compiled OUTPUT --
/// Propshaft's `.manifest.json`, Sprockets' `manifest-*.json`, and one
/// digested copy of every `app/assets/` source. None of it belongs in the
/// target: the sources themselves are copied from `app/assets/` (their
/// target path comes from `resolve.assetTargetPath`, their Rails URL from
/// the very manifest sitting here), so copying this directory too would ship
/// each asset twice -- once under `assets/images/logo.png` and once under
/// `assets/assets/logo-abc123.png` -- plus a Rails bookkeeping file at
/// `assets/assets/.manifest.json` that nothing in a Zigapagos site reads.
///
/// Filtered HERE and not in `assets.zig`: discovery's job is to inventory
/// what the Rails app serves, and it does serve these files. Which of them a
/// converted site should CARRY is a conversion question, and this is the
/// conversion.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn isPipelineOutput(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "public/assets/");
}

// ---- pass 2: routes ------------------------------------------------------

/// One converted layout, kept so a layout shared by twenty routes is
/// converted and written once. Every string is `gpa`-owned.
const Layout = struct {
    /// The Rails path (`app/views/layouts/marketing.html.erb`), the cache key.
    source: []const u8,
    /// `resolve.layoutStem`, i.e. the `layouts/templates/<stem>.shtml` name.
    stem: []const u8,
    /// Target-relative path written.
    artifact: []const u8,
    open_ids: [][]const u8,
    /// This layout's `convert.Output.block_ids`: every id it declares a
    /// `<super>` under, which is exactly what a view extending it must fill.
    /// Fed straight to `convert.Context.layout_blocks` in `ensureView`.
    ///
    /// Read off the converter's own report rather than sniffed out of the
    /// emitted bytes. Both directions are fatal in SuperHTML -- a block with
    /// no `<super>` is `UNBOUND TOP-LEVEL BLOCK`, a `<super>` with no block
    /// is `MISSING TOP-LEVEL BLOCK` -- so a `yield :sidebar` the scaffolder
    /// failed to notice would produce a site that does not build.
    block_ids: [][]const u8,
    /// Human notes from the layout's conversion ("csrf_meta_tags dropped").
    dropped: [][]const u8,
    /// The first `<!-- rails:unmapped <kind> -->` in the layout, if any.
    unmapped_kind: ?[]const u8,
};

const LayoutCache = struct {
    items: std.ArrayListUnmanaged(Layout) = .empty,

    fn deinit(self: *LayoutCache, gpa: Allocator) void {
        for (self.items.items) |l| freeLayout(gpa, l);
        self.items.deinit(gpa);
    }

    fn find(self: *const LayoutCache, source: []const u8) ?usize {
        for (self.items.items, 0..) |l, i| {
            if (std.mem.eql(u8, l.source, source)) return i;
        }
        return null;
    }
};

fn freeLayout(gpa: Allocator, l: Layout) void {
    gpa.free(l.source);
    gpa.free(l.stem);
    gpa.free(l.artifact);
    freeStrings(gpa, l.open_ids);
    freeStrings(gpa, l.block_ids);
    freeStrings(gpa, l.dropped);
    if (l.unmapped_kind) |k| gpa.free(k);
}

/// One converted view, cached for the same reason as `Layout`: two routes
/// routinely render one view (`root "pages#about"` alongside
/// `get "/about"`), and `layouts/<viewStem>.shtml` may only be written once.
const View = struct {
    source: []const u8,
    /// The layout this conversion was made against (an index into the layout
    /// cache; `null` for a standalone view). Part of the cache KEY, not just
    /// a record: a view's bytes are a function of its layout -- the
    /// `<extend template=...>` names it, and `layout_blocks` decides which
    /// blocks the view emits -- so a conversion made under one layout is not
    /// reusable under another. See `ViewCache.find` (ruling S16).
    layout_index: ?usize,
    artifact: []const u8,
    /// The converted bytes, held rather than written on the spot: ruling S20
    /// means a route acknowledged `retained`/`blocked` writes NO page and no
    /// view file, and whether that applies is only known after the view has
    /// been converted (its findings are what the operator answered). See
    /// `materializeView`.
    bytes: []const u8,
    /// Whether `artifact` is on disk yet. The cache is keyed by
    /// (view, layout) and a view can serve several routes, so the FIRST route
    /// that actually needs the file writes it and the rest reuse it -- which
    /// is also why the skip is "do not write yet" rather than "do not
    /// convert": a later route sharing this view may well need it.
    written: bool,
    /// The `.layout` value a content page points at.
    layout_value: []const u8,
    title: ?[]const u8,
    description: ?[]const u8,
    open_ids: [][]const u8,
    unmapped_kind: ?[]const u8,
    /// Human notes from the view's conversion. Includes, since ruling S9, a
    /// `content_for` naming a block the layout does not declare -- the
    /// converter drops it (it would be an `UNBOUND TOP-LEVEL BLOCK`) and says
    /// so here, which is the only place that loss is visible.
    dropped: [][]const u8,
};

const ViewCache = struct {
    items: std.ArrayListUnmanaged(View) = .empty,

    fn deinit(self: *ViewCache, gpa: Allocator) void {
        for (self.items.items) |v| freeView(gpa, v);
        self.items.deinit(gpa);
    }

    /// The cached conversion of `source` made against `layout_index`, or
    /// null. BOTH halves are the key (ruling S16): reusing a conversion made
    /// under a different layout would give the route an `<extend>` naming the
    /// wrong parent and a block set the wrong layout declares -- which
    /// SuperHTML rejects outright, so the generated site would not build.
    fn find(self: *const ViewCache, source: []const u8, layout_index: ?usize) ?usize {
        for (self.items.items, 0..) |v, i| {
            if (!std.mem.eql(u8, v.source, source)) continue;
            if (v.layout_index == null and layout_index == null) return i;
            const a = v.layout_index orelse continue;
            const b = layout_index orelse continue;
            if (a == b) return i;
        }
        return null;
    }

    /// The FIRST cached conversion of `source` under any layout. Used only to
    /// report the clash: the target has one `layouts/<viewStem>.shtml`, so
    /// when the key misses but this hits, the view is already owned by an
    /// earlier route under a different layout.
    fn findAnyLayout(self: *const ViewCache, source: []const u8) ?usize {
        for (self.items.items, 0..) |v, i| {
            if (std.mem.eql(u8, v.source, source)) return i;
        }
        return null;
    }
};

fn freeView(gpa: Allocator, v: View) void {
    gpa.free(v.source);
    gpa.free(v.artifact);
    gpa.free(v.bytes);
    gpa.free(v.layout_value);
    if (v.title) |t| gpa.free(t);
    if (v.description) |d| gpa.free(d);
    freeStrings(gpa, v.open_ids);
    freeStrings(gpa, v.dropped);
    if (v.unmapped_kind) |k| gpa.free(k);
}

/// A dynamic route an operator answered `spa`, waiting for pass 3.
const SpaRoute = struct {
    /// First path segment, owned; names the `.spa.tsx` this route lands in.
    segment: []const u8,
    /// Position in `acc.routes`, so pass 3 can append the artifact.
    outcome_index: usize,
    /// Position in `Discovery.routes`.
    route_index: usize,
};

/// Total order over routes: `(path, verb, controller, action)`. Mirrors
/// `report.routeLessThan` (this file cannot import `report.zig` without
/// pulling a report emitter into a scaffolder, and the order is three
/// comparisons). It decides the order files are WRITTEN in, which is what
/// makes an exclusive-create collision reproducible rather than dependent on
/// the sidecar's emission order.
fn routeLessThan(list: []const route_mod.Route, ai: usize, bi: usize) bool {
    const a = list[ai];
    const b = list[bi];
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (std.mem.order(u8, a.verb, b.verb)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (orderOptional(a.controller, b.controller)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return orderOptional(a.action, b.action) == .lt;
}

fn orderOptional(a: ?[]const u8, b: ?[]const u8) std.math.Order {
    if (a == null and b == null) return .eq;
    if (a == null) return .lt;
    if (b == null) return .gt;
    return std.mem.order(u8, a.?, b.?);
}

/// What one route's arm builds before it becomes a `RouteOutcome`. Every
/// owned field is handed straight to the outcome, so nothing here is freed
/// on the success path.
const Outcome = struct {
    status: Status = .open,
    artifacts: std.ArrayListUnmanaged([]const u8) = .empty,
    open_ids: std.ArrayListUnmanaged([]const u8) = .empty,
    decision_id: ?[]const u8 = null,
    /// Everything worth telling the operator about this route, joined with
    /// `"; "`. Two KINDS of thing land here and they must not be confused:
    /// a reason the route is not finished (`addOpenNote`) and an
    /// informational note about what the conversion dropped along the way
    /// (`addNote`, fed from `convert.Output.dropped`). Only the first kind
    /// may keep a route out of `migrated` -- `csrf_meta_tags dropped` is a
    /// fact about a helper with a defined conversion, and letting it block
    /// the status would mean no route with a layout ever migrated.
    note: ?[]const u8 = null,
    /// Set by `addOpenNote`: something named in `note` means this route is
    /// not finished, over and above whatever `open_ids` says.
    unfinished: bool = false,

    fn deinit(self: *Outcome, gpa: Allocator) void {
        for (self.artifacts.items) |s| gpa.free(s);
        self.artifacts.deinit(gpa);
        for (self.open_ids.items) |s| gpa.free(s);
        self.open_ids.deinit(gpa);
        if (self.decision_id) |d| gpa.free(d);
        if (self.note) |n| gpa.free(n);
    }

    /// Appends an informational note. Never changes the status.
    fn addNote(self: *Outcome, gpa: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const text = if (self.note) |old|
            try std.fmt.allocPrint(gpa, "{s}; " ++ fmt, .{old} ++ args)
        else
            try std.fmt.allocPrint(gpa, fmt, args);
        if (self.note) |old| gpa.free(old);
        self.note = text;
    }

    /// Appends a note AND marks the route unfinished.
    fn addOpenNote(self: *Outcome, gpa: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.addNote(gpa, fmt, args);
        self.unfinished = true;
    }
};

/// A content path already written, and the route that claimed it. Ruling
/// S14's second half: two routes CAN map to one `content/<...>/index.smd`
/// (`/about` and `/about/` are one path after `resolve.contentPath`
/// normalises the trailing slash, and a Rails app can declare both), and the
/// second write would then hit the exclusive-create guard and abort the whole
/// migration over a duplicate route declaration. That is a route-level
/// problem with a route-level answer, so it becomes a route-level outcome.
const ContentClaim = struct {
    /// Target-relative `content/...` path, owned by `writeRoutes`.
    path: []const u8,
    /// `<verb> <path>` of the route that got there first, owned likewise.
    route_id: []const u8,
};

fn writeRoutes(
    ctx: *Ctx,
    acc: *Acc,
    layouts: *LayoutCache,
    views: *ViewCache,
    spa_routes: *std.ArrayListUnmanaged(SpaRoute),
) WriteError!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;

    const order = try gpa.alloc(usize, d.routes.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, d.routes, routeLessThan);

    var claims: std.ArrayListUnmanaged(ContentClaim) = .empty;
    defer {
        for (claims.items) |c| {
            gpa.free(c.path);
            gpa.free(c.route_id);
        }
        claims.deinit(gpa);
    }

    for (order) |i| {
        var out: Outcome = .{};
        errdefer out.deinit(gpa);

        try routeOutcome(ctx, acc, layouts, views, spa_routes, i, &out, acc.routes.items.len, &claims);

        // Sorted so the artifact list is a set, not a history of the order
        // this function happened to append in.
        std.mem.sort([]const u8, out.artifacts.items, {}, lessThanStr);
        std.mem.sort([]const u8, out.open_ids.items, {}, lessThanStr);

        const artifacts = try out.artifacts.toOwnedSlice(gpa);
        errdefer freeStrings(gpa, artifacts);
        const open_ids = try out.open_ids.toOwnedSlice(gpa);
        errdefer freeStrings(gpa, open_ids);
        try acc.routes.append(gpa, .{
            .route_index = i,
            .status = out.status,
            .artifacts = artifacts,
            .open_finding_ids = open_ids,
            .decision_id = out.decision_id,
            .note = out.note,
        });
    }
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The per-route decision tree, in the order the cases exclude each other.
fn routeOutcome(
    ctx: *Ctx,
    acc: *Acc,
    layouts: *LayoutCache,
    views: *ViewCache,
    spa_routes: *std.ArrayListUnmanaged(SpaRoute),
    route_index: usize,
    out: *Outcome,
    outcome_index: usize,
    claims: *std.ArrayListUnmanaged(ContentClaim),
) WriteError!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;
    const r = d.routes[route_index];
    const class: ?classify.Class = if (route_index < d.classifications.len)
        d.classifications[route_index].class
    else
        null;

    // A redirect is answered by the host config, not by a page, whatever its
    // verb or path shape. Its finding exists so the operator can acknowledge
    // that; the status stays `redirect` either way, because `redirect` is
    // already a complete answer (spec: `complete` accepts it).
    if (class == classify.Class.redirect) {
        out.status = .redirect;
        try attachRouteFinding(ctx, out, findings.code_redirect_host_config, r.source.line);
        // The status stays `redirect` whatever the operator answered -- a
        // redirect IS a complete answer -- but the decision is recorded so
        // the handoff can show it was acknowledged rather than ignored.
        if (pickDecision(ctx.in.decisions, out.open_ids.items)) |dec| {
            out.decision_id = try gpa.dupe(u8, dec.id);
        }
        const from = try gpa.dupe(u8, r.path);
        errdefer gpa.free(from);
        try acc.redirects.append(gpa, .{ .from = from, .to = null });
        return;
    }

    // `backend` by classification, or by verb: a POST/PATCH/DELETE route has
    // no page to migrate at all, and calling it anything else would put a
    // route in the handoff that `complete` then has to special-case.
    const is_get = std.mem.eql(u8, r.verb, "GET") or std.mem.eql(u8, r.verb, "HEAD");
    if (class == classify.Class.backend or !is_get) {
        out.status = .backend;
        return;
    }

    if (findings.isDynamicRoutePath(r.path)) {
        try dynamicRoute(ctx, out, spa_routes, route_index, outcome_index, r);
        return;
    }

    const content_path = try resolve.contentPath(gpa, r.path);
    defer if (content_path) |c| gpa.free(c);
    if (content_path == null) {
        // Not dynamic and still no content path: `resolve.contentPath` also
        // refuses route syntax this stage does not interpret (`(.:format)`).
        // No finding covers that -- it is a gap in the route parser, not a
        // decision -- so the route stays open with the reason named.
        try out.addOpenNote(gpa, "route path contains syntax this stage does not interpret", .{});
        return;
    }

    // Ruling S14: a content path is claimed by exactly one route. Checked
    // BEFORE any conversion so the loser costs nothing and, more importantly,
    // so the exclusive-create guard never sees the collision -- that guard's
    // job is to protect a target the operator did not wipe, and letting a
    // duplicate route declaration trip it would abort the whole migration
    // with a filesystem error instead of naming the two routes involved.
    for (claims.items) |c| {
        if (!std.mem.eql(u8, c.path, content_path.?)) continue;
        try out.addOpenNote(gpa, "content path collision with {s}", .{c.route_id});
        return;
    }

    try contentRoute(ctx, layouts, views, route_index, out, content_path.?);

    // Claimed only once the page is actually on disk: a route that returned
    // early (no view, an unconvertible template) wrote nothing, so the next
    // route mapping here should get a real attempt rather than inherit a
    // collision with a page that does not exist.
    if (out.artifacts.items.len > 0) {
        const path_copy = try gpa.dupe(u8, content_path.?);
        errdefer gpa.free(path_copy);
        const id_copy = try std.fmt.allocPrint(gpa, "{s} {s}", .{ r.verb, r.path });
        errdefer gpa.free(id_copy);
        try claims.append(gpa, .{ .path = path_copy, .route_id = id_copy });
    }
}

/// Records the ROUTE-scoped finding for `code` on `out`. The id is
/// recomputed with
/// `findings.routeFindingId` rather than searched for by `route_id`: one
/// `routes.rb` declaration can produce several routes, so `route_id` names
/// only one of them (see `findings.deriveRouteFindings`).
fn attachRouteFinding(ctx: *Ctx, out: *Outcome, code: []const u8, line: u64) WriteError!void {
    const gpa = ctx.gpa;
    const id = try findings.routeFindingId(gpa, code, line);
    errdefer gpa.free(id);
    try out.open_ids.append(gpa, id);
}

fn dynamicRoute(
    ctx: *Ctx,
    out: *Outcome,
    spa_routes: *std.ArrayListUnmanaged(SpaRoute),
    route_index: usize,
    outcome_index: usize,
    r: route_mod.Route,
) WriteError!void {
    const gpa = ctx.gpa;
    try attachRouteFinding(ctx, out, findings.code_route_dynamic_segment, r.source.line);
    const id = out.open_ids.items[out.open_ids.items.len - 1];

    const decision = decisions.lookup(ctx.in.decisions, id) orelse {
        try out.addOpenNote(gpa, "dynamic route segment: undecided", .{});
        return;
    };
    out.decision_id = try gpa.dupe(u8, decision.id);

    if (std.mem.eql(u8, decision.choice, "spa")) {
        const seg = resolve.spaSegment(r.path);
        // Ruling S13: `spa` is only APPLIED when the first segment is static.
        // A top-level dynamic route (`get "/:slug"`) has `:slug` as its first
        // segment, and honouring the decision would scaffold
        // `spa/:slug.spa.tsx` with `export const spa = { base: "/:slug" }` --
        // a filename with a colon in it, and a mount base that is a pattern
        // rather than a path. Nothing downstream can build that. There is no
        // segment to mount a SPA at, so the decision cannot be carried out
        // and the route stays open saying exactly that, rather than
        // producing an artifact that fails at build time.
        if (seg.len == 0 or seg[0] == ':' or seg[0] == '*') {
            try out.addOpenNote(gpa, "spa needs a static first segment", .{});
            return;
        }
        const segment = try gpa.dupe(u8, seg);
        errdefer gpa.free(segment);
        try spa_routes.append(gpa, .{
            .segment = segment,
            .outcome_index = outcome_index,
            .route_index = route_index,
        });
        // Minor C: with no `--runtime-path`, the generated `package.json`
        // carries a placeholder `file:` dependency that `bun install` cannot
        // resolve. The route is still `migrated` -- the conversion IS done --
        // but the operator has one edit left, and nothing else would say so.
        if (ctx.in.runtime_path == null) {
            try out.addNote(gpa, "set dependencies.@z/runtime in package.json", .{});
        }
        // `migrated` here and not after pass 3: the `.spa.tsx` is written
        // unconditionally for every collected route, so the only way this is
        // wrong is a write failure, which aborts the whole run.
        out.status = .migrated;
        return;
    }
    try applyAcknowledgement(ctx, out, decision.choice);
}

/// Turns a `retain`/`blocked`/`island`/`backend` choice into a status.
///
/// `island` and `backend` are ACCEPTED by `decisions.zig` (they are in the
/// findings' `choices`) but Stage 2 cannot produce the island component or
/// the endpoint binding either one promises. Recording them as `migrated`
/// would claim work that does not exist, so they leave the route `open` with
/// the deferral named (plan, Global Constraints).
fn applyAcknowledgement(ctx: *Ctx, out: *Outcome, choice: []const u8) WriteError!void {
    const gpa = ctx.gpa;
    if (std.mem.eql(u8, choice, "retain")) {
        out.status = .retained;
    } else if (std.mem.eql(u8, choice, "blocked")) {
        out.status = .blocked;
    } else if (std.mem.eql(u8, choice, "island")) {
        try out.addOpenNote(gpa, "choice island deferred to Stage 4", .{});
    } else if (std.mem.eql(u8, choice, "backend")) {
        try out.addOpenNote(gpa, "choice backend deferred to Stage 3", .{});
    } else {
        // Unreachable through `decisions.parse`, which validates every choice
        // against its finding's fixed list. Named rather than asserted so a
        // future choice added to the vocabulary but not here is visible in
        // the handoff instead of silently behaving like `retain`.
        try out.addOpenNote(gpa, "choice {s} is not implemented by this stage", .{choice});
    }
}

// ---- pass 2a: a route that becomes a page --------------------------------

fn contentRoute(
    ctx: *Ctx,
    layouts: *LayoutCache,
    views: *ViewCache,
    route_index: usize,
    out: *Outcome,
    content_path: []const u8,
) WriteError!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;
    const r = d.routes[route_index];
    const rt: rails.RouteTemplates = if (route_index < d.route_templates.len)
        d.route_templates[route_index]
    else
        .{ .templates = &.{}, .layout = null };

    const view_path = pickView(rt.templates, r) orelse {
        try out.addOpenNote(gpa, "no view template resolved for this route", .{});
        // Ruling S22. The note above was the whole report until now, and it
        // carries no id -- so an app with one `def other; render :about; end`
        // and no `other.html.erb` could never reach `complete` by any answer
        // at all. `findings.derive` raises `RAILS_NO_TEMPLATE` on this route's
        // `routes.rb` line for exactly the routes that reach here (see
        // `findings.routeHasNoView`, which mirrors this file's dispatch), and
        // the id is recomputed rather than searched for because one
        // declaration can produce several routes. The guard keeps the two
        // mirrors agreeing on the one input they could disagree on: a
        // discovery that carries no template list for this route says
        // nothing about its view, and `routeHasNoView` derives nothing for
        // it, so attaching an id here would point at a finding nobody raised.
        if (route_index < d.route_templates.len)
            try attachRouteFinding(ctx, out, findings.code_no_template, r.source.line);
        if (pickDecision(ctx.in.decisions, out.open_ids.items)) |dec| {
            out.decision_id = try gpa.dupe(u8, dec.id);
            try applyAcknowledgement(ctx, out, dec.choice);
        }
        return;
    };

    const layout_index: ?usize = if (rt.layout) |lp| try ensureLayout(ctx, layouts, lp) else null;
    if (rt.layout != null and layout_index == null) {
        // The layout was resolved by discovery but could not be converted
        // (an unsupported engine, a parse error, a file the templates op
        // refused). The page is emitted standalone rather than dropped, and
        // stays open: it is missing its chrome, and nothing else says so.
        try out.addOpenNote(gpa, "layout {s} could not be converted; the view is emitted standalone", .{rt.layout.?});
        // Ruling S21. The note alone made the route UNANSWERABLE: it carries
        // no id, so no line in the decisions file could ever name it, and
        // `complete` was unreachable for every route under a Haml layout --
        // the same hole ruling S18 closed for a Haml VIEW, reopened one level
        // up in the graph. The layout's own Stage 1 findings (its
        // `RAILS_TEMPLATE_ENGINE_UNSUPPORTED`, or a parse error, or an
        // unscanned-template row) are exactly the question, and they are
        // SHARED: one `retain`/`blocked` answer on the layout settles every
        // route that declares it, rather than one answer per page.
        try collectTemplateFindings(ctx, out, rt.layout.?);
    }

    // Ruling S16. The target has ONE `layouts/<viewStem>.shtml`, and its bytes
    // depend on the layout it was converted against. A second route reaching
    // the same view under a DIFFERENT layout therefore cannot be served: it
    // has no file of its own, and the existing one extends the wrong parent.
    // The first route in this file's route order owns the view; this one says
    // what happened and writes nothing, rather than emitting a page that
    // fails at build time.
    if (views.find(view_path, layout_index) == null) {
        if (views.findAnyLayout(view_path)) |owner| {
            try out.addOpenNote(gpa, "view shared across layouts: {s} vs {s}", .{
                layoutStemOf(layouts, views.items.items[owner].layout_index),
                layoutStemOf(layouts, layout_index),
            });
            return;
        }
    }

    const view_index = ensureView(ctx, layouts, views, view_path, layout_index) catch |err| switch (err) {
        error.Unconvertible => {
            // Three shapes reach here, and each carries its own finding on
            // this same path: a template with a parse error
            // (`RAILS_TEMPLATE_PARSE_ERROR`), one the templates op refused
            // (`RAILS_TEMPLATE_UNSCANNED`), and one with no fragment stream at
            // all because its ENGINE is unreadable -- Haml/Slim, whose
            // `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` finding is ruling S18's.
            try out.addOpenNote(gpa, "view {s} was not converted", .{view_path});
            try collectTemplateFindings(ctx, out, view_path);
            // And the decision on one of those findings is what acknowledges
            // the route. Without this the ids were collected and then
            // ignored: a Haml or unparsable view could be answered `blocked`
            // in the decisions file and the route still came back `open`,
            // making `complete` unreachable by any answer at all -- the very
            // hole rulings S12/S18 exist to close, reopened one layer down.
            if (pickDecision(ctx.in.decisions, out.open_ids.items)) |dec| {
                out.decision_id = try gpa.dupe(u8, dec.id);
                try applyAcknowledgement(ctx, out, dec.choice);
            }
            return;
        },
        else => |e| return e,
    };
    const v = views.items.items[view_index];

    // The route's open findings are the view's plus its layout's: a helper
    // nobody has decided about leaves the PAGE unfinished wherever in the
    // graph it sits.
    try appendUnique(gpa, &out.open_ids, v.open_ids);
    if (layout_index) |li| try appendUnique(gpa, &out.open_ids, layouts.items.items[li].open_ids);

    // `convert.Output.dropped`, folded into the note rather than discarded
    // because `MIGRATION.md` is the only place an operator ever learns what
    // the conversion removed.
    //
    // Ruling S15 splits them in two. A `csrf_meta_tags` drop, a JS-entry drop
    // and a `<title>` suffix drop each remove a construct with a DEFINED
    // conversion -- nothing an operator has to act on, so they are footnotes
    // and the route can still be `migrated`. A dropped `content_for` is the
    // opposite: its body is markup the author wrote and the target does not
    // have (see `convert.dropped_content_for_prefix`), so the route is not
    // finished and says why.
    for (v.dropped) |note| try foldDropped(gpa, out, note);
    if (layout_index) |li| {
        for (layouts.items.items[li].dropped) |note| try foldDropped(gpa, out, note);
    }

    // Ruling S6: an unmapped region has NO finding id, so an empty
    // `open_finding_ids` is not proof of a finished page.
    const unmapped = v.unmapped_kind orelse
        (if (layout_index) |li| layouts.items.items[li].unmapped_kind else null);

    // Ruling S19: the ACKNOWLEDGEMENT is read first. An operator who answered
    // `retain` said the page stays on Rails and this target does not serve it;
    // `blocked` said the route does not ship at all. Either way what the
    // converter could not map is moot, and reporting the route `open` on
    // account of it left the run permanently incomplete -- the fixture's
    // `/registration/new` (a form with an unbound block local in its errors
    // loop) could not be finished by any answer at all, which is the same
    // hole rulings S12/S18 close one layer up.
    if (pickDecision(ctx.in.decisions, out.open_ids.items)) |dec| {
        out.decision_id = try gpa.dupe(u8, dec.id);
        try applyAcknowledgement(ctx, out, dec.choice);
        // `island`/`backend` leave the status `open` (Stage 3/4 owns them),
        // and those routes fall through to the S6 net below so the note names
        // BOTH reasons rather than only the deferral.
        if (out.status != .open) {
            // Ruling S20: an acknowledged route writes NO page and no view
            // file, so this returns BEFORE the write below. `retained` means
            // the page stays on Rails and this target must not answer that
            // URL at all; `blocked` means it does not ship. Emitting the
            // converted page anyway made `blocked` a relabelling and nothing
            // more -- the built site served a blank `<main>` for a route the
            // handoff called blocked, which is worse than a 404 because it
            // looks deliberate. The handoff row is the record of what
            // happened; the target holds only what the site serves.
            //
            // The conversion is NOT skipped, only the write: its findings are
            // what the operator answered, and a later route sharing this view
            // may still need the file (see `materializeView`).
            //
            // The note still names any `rails:unmapped` region, as a footnote
            // (`addNote`, which cannot change the status back): the converted
            // bytes really do carry the placeholder, even unwritten, and
            // MIGRATION.md is the only place anyone learns that.
            if (unmapped) |kind| try out.addNote(gpa, "{s} left unmapped", .{kind});
            return;
        }
    }

    // Nobody settled this route, so the target serves it: an `open` page is a
    // page with a gap in it, not an absent page, and an `island`/`backend`
    // deferral is a route Stage 3/4 will finish from what is emitted here.
    try materializeView(ctx, views, view_index);
    // The content page. Written per route (two routes rendering one view
    // still have two URLs), unlike the view and layout files.
    const page = try emitContentPage(ctx, r, v, view_path);
    defer gpa.free(page);
    try ctx.writeFile(content_path, page);

    try appendOwned(gpa, &out.artifacts, content_path);
    try appendOwned(gpa, &out.artifacts, v.artifact);
    if (layout_index) |li| try appendOwned(gpa, &out.artifacts, layouts.items.items[li].artifact);

    if (unmapped) |kind| {
        // Ruling S6's net, now the LAST word rather than the first: an
        // unmapped region has no finding id, so nobody can be asked about it,
        // and a route nobody answered at all must not reach `migrated` on the
        // strength of an empty `open_finding_ids`.
        try out.addOpenNote(gpa, "{s}: {s}", .{ kind, unmappedReason(kind) });
        out.status = .open;
        return;
    }

    if (out.open_ids.items.len == 0 and !out.unfinished) out.status = .migrated;
}

/// The decision that decides a route with several open findings.
///
/// Highest `rank` wins, ties broken by the smallest finding id. `blocked`
/// beats `retain` because it is the stronger statement -- an operator who
/// blocked the route on ONE of its gaps has not agreed to ship it because
/// another gap was marked `retain` -- and both beat a deferred `island`/
/// `backend`, which leaves the route open anyway. Without a fixed rank the
/// status would depend on which id happened to sort first, i.e. on a file
/// name rather than on what the operator said.
/// Takes the parsed answers rather than the `Ctx` that holds them so the
/// precedence below is unit-testable without a target directory: the rule is
/// pure, and a test that has to build a whole `write` run to reach it stops
/// pinning the rule and starts pinning the run.
///
/// Contract 3 (caller-buffer): allocates nothing; the result borrows
/// `parsed`.
fn pickDecision(parsed: decisions.Parsed, ids: []const []const u8) ?decisions.Decision {
    var best: ?decisions.Decision = null;
    for (ids) |id| {
        const dec = decisions.lookup(parsed, id) orelse continue;
        const b = best orelse {
            best = dec;
            continue;
        };
        const r = rank(dec.choice);
        const br = rank(b.choice);
        if (r > br or (r == br and std.mem.order(u8, dec.id, b.id) == .lt)) best = dec;
    }
    return best;
}

fn rank(choice: []const u8) u8 {
    if (std.mem.eql(u8, choice, "blocked")) return 3;
    if (std.mem.eql(u8, choice, "retain")) return 2;
    return 1;
}

/// Appends one `convert.Output.dropped` note, as a reason or as a footnote
/// (ruling S15; see the fold in `contentRoute` for which is which).
///
/// Contract 2 (owned-result), inherited from `write`: it allocates nothing of
/// its own and grows `out`'s note, which the eventual `Result` owns.
fn foldDropped(gpa: Allocator, out: *Outcome, note: []const u8) Allocator.Error!void {
    if (std.mem.startsWith(u8, note, convert.dropped_content_for_prefix)) {
        try out.addOpenNote(gpa, "{s}", .{note});
    } else {
        try out.addNote(gpa, "{s}", .{note});
    }
}

/// Why a fragment kind `convert.zig` left unmapped is unmapped -- the whole
/// tail of the note, not just a stage number, because the two answers are
/// different KINDS of answer.
///
/// The form family is Stage 3 (it needs the backend boundary) and the
/// Turbo/component family is Stage 4 (it needs islands): both are work a
/// later stage of this migration owns, and saying so tells an operator to
/// wait.
///
/// Everything else is not. `link_to`, `content_for`, `local` and
/// `render_partial` reach a placeholder because THIS stage's converter could
/// not finish them -- a route helper called with the wrong arity, a
/// `content_for :title` whose body is not a literal, a block local nothing
/// bound, a partial that resolves nowhere. No stage owns those; they are
/// converter gaps, tracked as issue #181, and telling an operator they are
/// "deferred to a later stage" sends them away to wait for a release that
/// will never mention them. The honest label says the tool fell short.
fn unmappedReason(kind: []const u8) []const u8 {
    const stage3 = [_][]const u8{ "form", "form_field", "errors" };
    for (stage3) |k| if (std.mem.eql(u8, kind, k)) return "deferred to Stage 3";
    const stage4 = [_][]const u8{ "turbo_frame", "turbo_stream", "component_root" };
    for (stage4) |k| if (std.mem.eql(u8, kind, k)) return "deferred to Stage 4";
    return "converter gap (see #181)";
}

/// Every Stage 1 finding raised against `path`. Used only when `convert`
/// refused the template outright, in which case its findings never reached
/// `Output.open_finding_ids`.
fn collectTemplateFindings(ctx: *Ctx, out: *Outcome, path: []const u8) WriteError!void {
    const gpa = ctx.gpa;
    for (ctx.in.discovery.findings) |f| {
        if (!std.mem.eql(u8, f.path, path)) continue;
        try appendOwned(gpa, &out.open_ids, f.id);
    }
}

/// Appends a COPY of `value`. Written as a helper rather than inline because
/// `list.append(gpa, try gpa.dupe(u8, v))` leaks the copy whenever the append
/// itself fails -- the dupe is then the only reference and it has already
/// been dropped. The FailingAllocator sweep at the bottom of this file caught
/// exactly that, four times over.
///
/// Contract 2 (owned-result), inherited: grows the caller's list, and the
/// copy it appends is owned by whoever owns that list. On failure nothing is
/// added and nothing is leaked.
fn appendOwned(gpa: Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) Allocator.Error!void {
    const copy = try gpa.dupe(u8, value);
    errdefer gpa.free(copy);
    try list.append(gpa, copy);
}

/// `appendOwned` for a whole slice, skipping values the list already holds.
///
/// Contract 2 (owned-result), inherited: grows the caller's list; every
/// string appended is a copy that list then owns.
fn appendUnique(gpa: Allocator, list: *std.ArrayListUnmanaged([]const u8), items: []const []const u8) Allocator.Error!void {
    outer: for (items) |s| {
        for (list.items) |have| {
            if (std.mem.eql(u8, have, s)) continue :outer;
        }
        try appendOwned(gpa, list, s);
    }
}

/// A layout's `layouts/templates/<stem>.shtml` name, or `(none)` for a
/// standalone view. Only for the ruling-S16 clash message, where naming both
/// sides is the whole point -- "this view is already converted" without
/// saying against WHAT sends the reader hunting through two controllers.
///
/// Contract 3 (caller-buffer): allocates nothing; the result borrows the
/// layout cache (or is a literal).
fn layoutStemOf(layouts: *const LayoutCache, layout_index: ?usize) []const u8 {
    const li = layout_index orelse return "(none)";
    return layouts.items.items[li].stem;
}

/// The view template among a route's scanned templates: the one at
/// `app/views/<controller>/<action>.*`, off a `routes.Route`.
///
/// The lookup itself is `resolve.viewFor` -- moved there for ruling S22, so
/// `findings.zig` can decide whether to derive `RAILS_NO_TEMPLATE` from the
/// same answer this file acts on. This wrapper is the route-typed call this
/// file makes; keeping it saves repeating the two optional unwraps at each
/// site and keeps the name the tests below use.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn pickView(templates: []const []const u8, r: route_mod.Route) ?[]const u8 {
    return resolve.viewFor(templates, r.controller, r.action);
}

fn findTemplate(list: []const fragments.Template, path: []const u8) ?fragments.Template {
    for (list) |t| {
        if (std.mem.eql(u8, t.path, path)) return t;
    }
    return null;
}

/// Converts and writes `layouts/templates/<stem>.shtml` once per distinct
/// layout. Returns its index in the cache, or `null` when the layout has no
/// analysed fragment stream (unsupported engine, unreadable) or does not
/// convert.
fn ensureLayout(ctx: *Ctx, cache: *LayoutCache, layout_path: []const u8) WriteError!?usize {
    const gpa = ctx.gpa;
    if (cache.find(layout_path)) |i| return i;

    const tpl = findTemplate(ctx.in.discovery.fragments, layout_path) orelse return null;
    const output = convert.convert(gpa, .{
        .routes = ctx.in.discovery.routes,
        .assets = ctx.in.discovery.assets,
        .fragments = ctx.in.discovery.fragments,
        .findings = ctx.in.discovery.findings,
        .layout_stem = null,
    }, tpl, .layout) catch |err| switch (err) {
        error.Unconvertible => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer convert.freeOutput(gpa, output);

    const stem = try gpa.dupe(u8, resolve.layoutStem(layout_path));
    errdefer gpa.free(stem);
    const artifact = try std.fmt.allocPrint(gpa, "layouts/templates/{s}.shtml", .{stem});
    errdefer gpa.free(artifact);
    try ctx.writeFile(artifact, output.bytes);

    const source = try gpa.dupe(u8, layout_path);
    errdefer gpa.free(source);
    const ids = try dupeStrings(gpa, output.open_finding_ids);
    errdefer freeStrings(gpa, ids);
    const blocks = try dupeStrings(gpa, output.block_ids);
    errdefer freeStrings(gpa, blocks);
    const dropped = try dupeStrings(gpa, output.dropped);
    errdefer freeStrings(gpa, dropped);
    const unmapped = try firstUnmappedKind(gpa, output.bytes);
    errdefer if (unmapped) |u| gpa.free(u);

    try cache.items.append(gpa, .{
        .source = source,
        .stem = stem,
        .artifact = artifact,
        .open_ids = ids,
        .block_ids = blocks,
        .dropped = dropped,
        .unmapped_kind = unmapped,
    });
    return cache.items.items.len - 1;
}

/// Converts and writes `layouts/<viewStem>.shtml` once per distinct view.
///
/// Two routes routinely render one view, and the target has ONE file per
/// view -- so the second route reuses this cache entry rather than hitting
/// the exclusive-create guard.
///
/// **`ensureLayout` must have run for this view's layout first.** That is a
/// correctness requirement, not a convenience: the view's conversion is
/// parameterised by `Context.layout_blocks`, which only exists once the
/// layout has been converted. Converting the view first would emit the two
/// blocks a converted layout always declares (`head`, `main`) and NONE of its
/// named yields, so a layout with `yield :sidebar` would carry a `<super>`
/// nothing fills -- `MISSING TOP-LEVEL BLOCK`, a site that does not build.
/// `contentRoute` therefore calls `ensureLayout` before this, and passes the
/// resulting index down.
fn ensureView(
    ctx: *Ctx,
    layouts: *LayoutCache,
    cache: *ViewCache,
    view_path: []const u8,
    layout_index: ?usize,
) (error{Unconvertible} || WriteError)!usize {
    const gpa = ctx.gpa;
    if (cache.find(view_path, layout_index)) |i| return i;

    const tpl = findTemplate(ctx.in.discovery.fragments, view_path) orelse return error.Unconvertible;
    const layout_stem: ?[]const u8 = if (layout_index) |li| layouts.items.items[li].stem else null;
    // Rulings S7/S9: the view fills EXACTLY the blocks its layout declares.
    // `convert.zig` emits an empty block for each one the view has no
    // `content_for` for, and drops a `content_for` naming an id the layout
    // does not declare (reporting it in `Output.dropped`, which this file
    // folds into the route's note). Both halves matter, because SuperHTML
    // fatals in both directions.
    const layout_blocks: []const []const u8 =
        if (layout_index) |li| layouts.items.items[li].block_ids else &.{};
    const output = try convert.convert(gpa, .{
        .routes = ctx.in.discovery.routes,
        .assets = ctx.in.discovery.assets,
        .fragments = ctx.in.discovery.fragments,
        .findings = ctx.in.discovery.findings,
        .layout_stem = layout_stem,
        .layout_blocks = layout_blocks,
    }, tpl, .view);
    defer convert.freeOutput(gpa, output);

    const bytes: []const u8 = output.bytes;
    const stem = resolve.viewStem(view_path);
    const artifact = try std.fmt.allocPrint(gpa, "layouts/{s}.shtml", .{stem});
    errdefer gpa.free(artifact);
    // NOT written here (ruling S20): whether this view is written at all
    // depends on what the operator decided about the findings this very
    // conversion just produced. `contentRoute` calls `materializeView` for
    // every route that still needs a page.
    const bytes_owned = try gpa.dupe(u8, bytes);
    errdefer gpa.free(bytes_owned);

    const source = try gpa.dupe(u8, view_path);
    errdefer gpa.free(source);
    const layout_value = try std.fmt.allocPrint(gpa, "{s}.shtml", .{stem});
    errdefer gpa.free(layout_value);
    const title = if (output.title) |t| try gpa.dupe(u8, t) else null;
    errdefer if (title) |t| gpa.free(t);
    const description = if (output.description) |x| try gpa.dupe(u8, x) else null;
    errdefer if (description) |x| gpa.free(x);
    const ids = try dupeStrings(gpa, output.open_finding_ids);
    errdefer freeStrings(gpa, ids);
    const dropped = try dupeStrings(gpa, output.dropped);
    errdefer freeStrings(gpa, dropped);
    const unmapped = try firstUnmappedKind(gpa, bytes);
    errdefer if (unmapped) |u| gpa.free(u);

    try cache.items.append(gpa, .{
        .source = source,
        .layout_index = layout_index,
        .artifact = artifact,
        .bytes = bytes_owned,
        .written = false,
        .layout_value = layout_value,
        .title = title,
        .description = description,
        .open_ids = ids,
        .unmapped_kind = unmapped,
        .dropped = dropped,
    });
    return cache.items.items.len - 1;
}

/// Writes a converted view's `layouts/<viewStem>.shtml`, once (ruling S20).
///
/// The write moved out of `ensureView` because the two questions are
/// different: "what does this view convert to" is answered before any
/// decision is read (its findings ARE the question the operator answers),
/// while "does this target serve it" is answered after. A view converted for
/// a route that turned out `retained`/`blocked` stays in the cache unwritten,
/// and the next route rendering it -- if there is one, and if it needs a page
/// -- writes it then. Skipping the CONVERSION instead would lose the findings
/// that justify the decision and would strand any such later route.
///
/// Contract 1 (self-freeing): the joined path `writeFile` builds is freed
/// before returning; the bytes written are the cache's, not a new allocation.
fn materializeView(ctx: *Ctx, views: *ViewCache, index: usize) WriteError!void {
    const v = &views.items.items[index];
    if (v.written) return;
    try ctx.writeFile(v.artifact, v.bytes);
    v.written = true;
}

/// A deep copy of a string slice.
///
/// Contract 2 (owned-result): the returned slice AND every string in it are
/// fresh allocations the caller owns; release with `freeStrings`. On failure
/// the partial copy is released here and nothing escapes.
fn dupeStrings(gpa: Allocator, list: []const []const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (list) |s| try appendOwned(gpa, &out, s);
    return out.toOwnedSlice(gpa);
}

/// The kind named by the FIRST `<!-- rails:unmapped <kind> ... -->` in
/// `bytes`, or null. Ruling S6's detector: such a region is an open item that
/// carries no finding id, so nothing else in the pipeline can see it.
///
/// Contract 1 (self-freeing): the returned kind is the only allocation.
fn firstUnmappedKind(gpa: Allocator, bytes: []const u8) Allocator.Error!?[]const u8 {
    const marker = "<!-- rails:unmapped ";
    const at = std.mem.indexOf(u8, bytes, marker) orelse return null;
    const rest = bytes[at + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, " -") orelse rest.len;
    return try gpa.dupe(u8, rest[0..end]);
}

// ---- the content page ----------------------------------------------------

/// The `.smd`: frontmatter and nothing else. The view's markup lives in
/// `layouts/<viewStem>.shtml`, because SuperMD forbids raw HTML (spec,
/// "Conversion: what a route becomes").
///
/// Only `.title` and `.layout` are required by `Page`; `.date`/`.draft` are
/// deliberately omitted rather than stamped with a placeholder epoch, since
/// a Rails route carries neither and inventing one would put a fact in the
/// frontmatter that no source supports.
///
/// Contract 1 (self-freeing): all scratch is released; the returned bytes are
/// the only escaping allocation.
fn emitContentPage(ctx: *Ctx, r: route_mod.Route, v: View, view_path: []const u8) Allocator.Error![]u8 {
    const gpa = ctx.gpa;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "---\n");

    try out.appendSlice(gpa, ".title = \"");
    if (v.title) |t| {
        try appendZiggyEscaped(gpa, &out, t);
    } else if (r.controller != null and r.action != null) {
        // The spec's fallback. Two words rather than "Untitled": it names the
        // Rails action a reader can go read, which "Untitled" does not.
        try appendZiggyEscaped(gpa, &out, r.controller.?);
        try out.append(gpa, ' ');
        try appendZiggyEscaped(gpa, &out, r.action.?);
    } else {
        try appendZiggyEscaped(gpa, &out, r.path);
    }
    try out.appendSlice(gpa, "\",\n");

    if (v.description) |desc| {
        try out.appendSlice(gpa, ".description = \"");
        try appendZiggyEscaped(gpa, &out, desc);
        try out.appendSlice(gpa, "\",\n");
    }

    try out.appendSlice(gpa, ".layout = \"");
    try appendZiggyEscaped(gpa, &out, v.layout_value);
    try out.appendSlice(gpa, "\",\n");

    // Provenance, so `$page.custom.rails` can be inspected from a layout and
    // the mapping survives hand edits to either side (spec).
    try out.appendSlice(gpa, ".custom = {\n    .rails = {\n        .route = \"");
    try appendZiggyEscaped(gpa, &out, r.verb);
    try out.append(gpa, ' ');
    try appendZiggyEscaped(gpa, &out, r.path);
    try out.appendSlice(gpa, "\",\n        .controller = \"");
    try appendZiggyEscaped(gpa, &out, r.controller orelse "");
    try out.appendSlice(gpa, "\",\n        .action = \"");
    try appendZiggyEscaped(gpa, &out, r.action orelse "");
    try out.appendSlice(gpa, "\",\n        .source = \"");
    try appendZiggyEscaped(gpa, &out, view_path);
    try out.appendSlice(gpa, "\",\n    },\n},\n");

    try out.appendSlice(gpa, "---\n");
    return out.toOwnedSlice(gpa);
}

/// The escaping a Ziggy double-quoted string needs. Mirrors
/// `migrate.zig`'s `configEscape` (see the module doc on duplication):
/// the two quote characters plus the three whitespace escapes, because a raw
/// newline inside a Ziggy string is a parse error, not a line break.
///
/// Contract 2 (owned-result), inherited: grows the caller's buffer and
/// allocates nothing else.
fn appendZiggyEscaped(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) Allocator.Error!void {
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => try out.append(gpa, c),
    };
}

// ---- pass 3: the SPA scaffolds -------------------------------------------

/// One `.spa.tsx` per first path segment, listing every route under it an
/// operator answered `spa`.
///
/// One file per SEGMENT rather than per route because that is what a client
/// router is: `/posts/:id` and `/posts/:id/edit` are two routes of one SPA
/// mounted at `/posts`, not two SPAs.
fn writeSpas(ctx: *Ctx, acc: *Acc, list: []const SpaRoute) WriteError!void {
    const gpa = ctx.gpa;
    if (list.len == 0) return;

    const order = try gpa.alloc(usize, list.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, SpaSortCtx{ .list = list, .routes = ctx.in.discovery.routes }, spaLessThan);

    var i: usize = 0;
    while (i < order.len) {
        const segment = list[order[i]].segment;
        var j = i + 1;
        while (j < order.len and std.mem.eql(u8, list[order[j]].segment, segment)) j += 1;

        const path = try std.fmt.allocPrint(gpa, "spa/{s}.spa.tsx", .{segment});
        errdefer gpa.free(path);
        const source = try emitSpa(ctx, segment, list, order[i..j]);
        defer gpa.free(source);
        try ctx.writeFile(path, source);

        for (order[i..j]) |k| {
            const oc = &acc.routes.items[list[k].outcome_index];
            // The copy is made BEFORE the grow: a `realloc` that succeeds
            // followed by a `dupe` that fails would leave the outcome holding
            // one uninitialised element that `freeResult` would then try to
            // free. Growing second means every element is always valid.
            const copy = try gpa.dupe(u8, path);
            errdefer gpa.free(copy);
            const artifacts = try gpa.realloc(oc.artifacts, oc.artifacts.len + 1);
            oc.artifacts = artifacts;
            artifacts[artifacts.len - 1] = copy;
            std.mem.sort([]const u8, artifacts, {}, lessThanStr);
        }
        try acc.spa_files.append(gpa, path);
        i = j;
    }
}

const SpaSortCtx = struct { list: []const SpaRoute, routes: []const route_mod.Route };

/// `(segment, route path, verb)`: groups a segment's routes contiguously and
/// fixes their order inside the emitted file.
fn spaLessThan(c: SpaSortCtx, a: usize, b: usize) bool {
    switch (std.mem.order(u8, c.list[a].segment, c.list[b].segment)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    const ra = c.routes[c.list[a].route_index];
    const rb = c.routes[c.list[b].route_index];
    switch (std.mem.order(u8, ra.path, rb.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return std.mem.order(u8, ra.verb, rb.verb) == .lt;
}

/// Contract 1 (self-freeing): the returned source is the only escaping
/// allocation.
fn emitSpa(ctx: *Ctx, segment: []const u8, list: []const SpaRoute, group: []const usize) Allocator.Error![]u8 {
    const gpa = ctx.gpa;
    const routes_all = ctx.in.discovery.routes;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    for (group) |k| {
        const name = try componentName(gpa, routes_all[list[k].route_index], names.items);
        errdefer gpa.free(name);
        try names.append(gpa, name);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa,
        \\// Generated by `zigapagos migrate --from rails`. Every component below is a
        \\// placeholder: the Rails view it names still has to be ported by hand.
        \\import { Router } from "@z/runtime";
        \\
        \\
    );
    try out.appendSlice(gpa, "export const spa = { base: \"/");
    try out.appendSlice(gpa, segment);
    try out.appendSlice(gpa, "\" };\n\n");

    for (group, names.items) |k, name| {
        const r = routes_all[list[k].route_index];
        try out.appendSlice(gpa, "function ");
        try out.appendSlice(gpa, name);
        try out.appendSlice(gpa, "() {\n  return <p>{\"TODO: port ");
        // A JS string literal, not JSX text: a route path or controller name
        // is not markup, and `{`/`<` in one would otherwise be parsed as JSX.
        try appendJsEscaped(gpa, &out, r.verb);
        try out.append(gpa, ' ');
        try appendJsEscaped(gpa, &out, r.path);
        if (r.controller) |c| {
            try out.appendSlice(gpa, " (");
            try appendJsEscaped(gpa, &out, c);
            try out.append(gpa, '#');
            try appendJsEscaped(gpa, &out, r.action orelse "");
            try out.append(gpa, ')');
        }
        try out.appendSlice(gpa, "\"}</p>;\n}\n\n");
    }

    try out.appendSlice(gpa, "export const routes = [\n");
    for (group, names.items) |k, name| {
        const r = routes_all[list[k].route_index];
        const rest = spaRoutePath(r.path, segment);
        try out.appendSlice(gpa, "  { path: \"");
        try appendJsEscaped(gpa, &out, rest);
        try out.appendSlice(gpa, "\", component: ");
        try out.appendSlice(gpa, name);
        // `skeleton: false`: this stage knows the route SHAPE and nothing
        // about the data behind it, so there is nothing to prerender.
        //
        // `staticPaths` is emitted only for an entry whose OWN path is
        // dynamic. `runtime/src/router.ts:698` throws "staticPaths declared
        // on static route" otherwise -- and a static entry does occur here,
        // because the SPA is grouped by first segment: `/posts/:id` and
        // `/posts/new` can share one `.spa.tsx`, and the second one's entry
        // path (`/new`) has no param to enumerate.
        try out.appendSlice(gpa, ", skeleton: false");
        if (findings.isDynamicRoutePath(rest)) {
            try out.appendSlice(gpa, ", staticPaths: []");
        }
        try out.appendSlice(gpa, " },\n");
    }
    try out.appendSlice(gpa, "];\n\nexport default function App() {\n  return <Router base={spa.base} routes={routes} />;\n}\n");

    return out.toOwnedSlice(gpa);
}

/// The route path relative to the SPA's base: `/posts/:id` under `posts`
/// becomes `/:id`, and a route that IS the base becomes `/`.
fn spaRoutePath(route_path: []const u8, segment: []const u8) []const u8 {
    const prefix_len = 1 + segment.len;
    if (route_path.len <= prefix_len) return "/";
    return route_path[prefix_len..];
}

/// A JSX identifier for one route's placeholder component: `posts#show`
/// becomes `PostsShow`. Falls back to the path when the route names no
/// controller/action, and appends `_2`, `_3`, … on a collision within the
/// same file (two routes CAN share a controller#action pair).
///
/// Contract 1 (self-freeing): the returned name is the only allocation.
fn componentName(gpa: Allocator, r: route_mod.Route, taken: []const []const u8) Allocator.Error![]u8 {
    var base: std.ArrayListUnmanaged(u8) = .empty;
    defer base.deinit(gpa);
    if (r.controller) |c| {
        try appendPascal(gpa, &base, c);
        try appendPascal(gpa, &base, r.action orelse "");
    } else {
        try appendPascal(gpa, &base, r.path);
    }
    if (base.items.len == 0) try base.appendSlice(gpa, "Route");

    var candidate = try gpa.dupe(u8, base.items);
    errdefer gpa.free(candidate);
    var n: usize = 2;
    while (contains(taken, candidate)) {
        gpa.free(candidate);
        candidate = try std.fmt.allocPrint(gpa, "{s}_{d}", .{ base.items, n });
        n += 1;
    }
    return candidate;
}

fn contains(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// Appends `value` as a PascalCase identifier fragment: every run of
/// alphanumerics is capitalised, everything else (including a `:param`'s
/// colon) is a separator and is dropped. A leading digit is dropped too --
/// a JS identifier cannot start with one.
///
/// Contract 2 (owned-result), inherited: grows the caller's buffer and
/// allocates nothing else.
fn appendPascal(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) Allocator.Error!void {
    var start_of_word = true;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            start_of_word = true;
            continue;
        }
        if (out.items.len == 0 and std.ascii.isDigit(c)) continue;
        if (start_of_word) {
            try out.append(gpa, std.ascii.toUpper(c));
            start_of_word = false;
        } else {
            try out.append(gpa, c);
        }
    }
}

/// The escaping a JS double-quoted string literal needs, for the values the
/// generated `.spa.tsx` embeds.
///
/// Contract 2 (owned-result), inherited: grows the caller's buffer and
/// allocates nothing else.
fn appendJsEscaped(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) Allocator.Error!void {
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        else => try out.append(gpa, c),
    };
}

// ---- pass 4: the project files -------------------------------------------

/// Duplicated from `migrate.zig`'s `target_gitignore` / `target_tsconfig` --
/// see the module doc for why this file cannot import them.
const target_gitignore =
    \\node_modules/
    \\zig-out/
    \\.zigapagos-cache/
    \\
;

const target_tsconfig =
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

fn writeProjectFiles(ctx: *Ctx, acc: *Acc) WriteError!void {
    const gpa = ctx.gpa;

    const config = try emitConfig(gpa, ctx.in.app_name, acc.assets.items.len > 0);
    defer gpa.free(config);
    try ctx.writeFile("zigapagos.ziggy", config);

    const build_sh = try emitBuildSh(gpa, acc.spa_files.items);
    defer gpa.free(build_sh);
    try ctx.writeFile("build.sh", build_sh);

    try ctx.writeFile(".gitignore", target_gitignore);
    try ctx.writeFile("AGENTS.md", ctx.in.agents_md);
    try ctx.writeFile("CLAUDE.md", ctx.in.claude_md);

    // Only a SPA needs a bundler at all: a pure content target builds with
    // the binary and nothing else, and emitting a `package.json` that nothing
    // installs would invite `bun install` into a project with no JS.
    if (acc.spa_files.items.len > 0) {
        const pkg = try emitPackage(gpa, ctx.in.app_name, ctx.in.runtime_path);
        defer gpa.free(pkg);
        try ctx.writeFile("package.json", pkg);
        try ctx.writeFile("tsconfig.json", target_tsconfig);
    }
}

/// Duplicated from `migrate.zig`'s `emitTargetConfig`, minus the Hexo-only
/// `url_path_prefix`: a Rails migration has no source for one.
/// `host_url` is a placeholder the operator edits -- Rails' own config knows
/// the production host, but this stage does not read it, and inventing one
/// would be worse than an obvious stand-in.
///
/// Contract 1 (self-freeing).
fn emitConfig(gpa: Allocator, app_name: []const u8, with_assets: bool) Allocator.Error![]u8 {
    var title: std.ArrayListUnmanaged(u8) = .empty;
    defer title.deinit(gpa);
    try appendZiggyEscaped(gpa, &title, app_name);
    return std.fmt.allocPrint(gpa,
        \\Site {{
        \\    .title = "{s}",
        \\    .host_url = "https://example.com",
        \\    .content_dir_path = "content",
        \\    .layouts_dir_path = "layouts",
        \\    .assets_dir_path = "assets",
        \\{s}}}
        \\
    , .{ title.items, if (with_assets) "    .static_assets = [\"**\"],\n" else "" });
}

/// Duplicated from `migrate.zig`'s `emitTargetBuildSh`, extended with one
/// `--spa=` per scaffolded SPA. The `bun install` line appears only when
/// there is a `package.json` for it to install.
///
/// Each `--spa=` carries its base: `--spa=spa/<seg>.spa.tsx|/<seg>`. The
/// two-part form is not decoration -- `src/spa.zig` skips BOTH of its
/// cross-checks on a spec with no declared base: the agreement check that the
/// file's own `export const spa.base` matches what the command line asked
/// for (`spa.zig:267`), and the overlap check that two SPAs are not mounted
/// inside one another (`findSpecViolation`, `spa.zig:611`). Since this file
/// generates both halves, restating the base is free and turns both checks
/// back on -- so a later hand edit to either side is caught at build time
/// rather than producing a site with two SPAs fighting over one prefix.
///
/// Contract 1 (self-freeing).
fn emitBuildSh(gpa: Allocator, spa_files: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\cd "$(dirname "$0")"
        \\
    );
    if (spa_files.len > 0) {
        try out.appendSlice(gpa, "bun install --frozen-lockfile 2>/dev/null || bun install\n");
    }
    try out.appendSlice(gpa, "exec \"${ZIGAPAGOS_BIN:-zigapagos}\" release --force --output=zig-out/site");
    for (spa_files) |f| {
        // SINGLE-QUOTED, and that is not a style choice. `|` is a pipeline
        // separator, so an unquoted `--spa=spa/posts.spa.tsx|/posts` makes
        // bash read the rest of the line as a second command named `/posts`:
        // exit 127, no argument ever reaching the binary, and a generated
        // project that cannot build at all. The line stays SYNTACTICALLY
        // valid -- `bash -n` is happy with it -- which is why only actually
        // running it catches this; see the replay test at the bottom of this
        // file. Every hand-written invocation in the repo quotes it the same
        // way (`examples/tsx-site/build.sh`, `site/build.sh`, `docs/spa.md`).
        //
        // Single quotes need no escaping analysis here: the whole value is a
        // path this file just built out of one route path segment
        // (`resolve.spaSegment`), so it can hold no quote to close them early.
        try out.appendSlice(gpa, " --spa='");
        try out.appendSlice(gpa, f);
        // The declared base, recovered from the file's own name: every path
        // in `spa_files` is `spa/<segment>.spa.tsx`, written by `writeSpas`
        // for a SPA whose `export const spa = { base: "/<segment>" }`. Same
        // string, one source.
        try out.appendSlice(gpa, "|/");
        try out.appendSlice(gpa, spaFileSegment(f));
        try out.append(gpa, '\'');
    }
    try out.appendSlice(gpa, " \"$@\"\n");
    return out.toOwnedSlice(gpa);
}

/// Duplicated from `migrate.zig`'s `emitTargetPackage` + `targetProjectName`
/// + `runtimePathIsJsonSafe`. The one behavioural difference is the last of
/// those: `migrate.zig` asserts a JSON-safe runtime path, which is right for
/// a path it derived itself; here the path comes from a CLI flag, so an
/// unusable one falls back to the same visible placeholder an ABSENT path
/// gets, rather than tripping an assertion in a release build.
///
/// Contract 1 (self-freeing).
fn emitPackage(gpa: Allocator, app_name: []const u8, runtime_path: ?[]const u8) Allocator.Error![]u8 {
    var name: std.ArrayListUnmanaged(u8) = .empty;
    defer name.deinit(gpa);
    for (app_name) |c| {
        try name.append(gpa, if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '_');
    }
    if (name.items.len == 0) try name.appendSlice(gpa, "migrated_site");
    if (std.ascii.isDigit(name.items[0])) name.items[0] = '_';

    const placeholder = "TODO-SET-RUNTIME-PATH";
    const path = if (runtime_path) |p| (if (jsonSafe(p)) p else placeholder) else placeholder;

    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "name": "{s}",
        \\  "private": true,
        \\  "type": "module",
        \\  "dependencies": {{ "@z/runtime": "file:{s}" }}
        \\}}
        \\
    , .{ name.items, path });
}

/// `spa/posts.spa.tsx` -> `posts`. The inverse of the one place that builds
/// the name (`writeSpas`), kept next to its only caller so the two forms
/// cannot drift apart unnoticed. Contract 3 (caller-buffer): returns a
/// sub-slice of `path`.
fn spaFileSegment(path: []const u8) []const u8 {
    const prefix = "spa/";
    const suffix = ".spa.tsx";
    var s = path;
    if (std.mem.startsWith(u8, s, prefix)) s = s[prefix.len..];
    if (std.mem.endsWith(u8, s, suffix)) s = s[0 .. s.len - suffix.len];
    return s;
}

fn jsonSafe(value: []const u8) bool {
    for (value) |c| {
        if (c == '"' or c == '\\' or c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

/// Modelled on `manifest.zig`'s `emptyDiscovery`: `Discovery` declares no
/// field defaults on purpose, so a test helper spells every one out and a
/// newly-added escaping field forces a deliberate edit here.
fn emptyDiscovery() rails.Discovery {
    return .{
        .report = "",
        .integrity_blocker_count = 0,
        .route_count = 0,
        .route_mode = "none",
        .route_blocker = false,
        .severity_error_count = 0,
        .severity_warn_count = 0,
        .ruby = .{ .available = false },
        .route_templates = &.{},
        .templates = &.{},
        .assets = &.{},
        .version = .{},
        .routes = &.{},
        .classifications = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .fragments = &.{},
        .findings = &.{},
        .i18n_locale = null,
        .decisions = .empty,
    };
}

fn tRoute(verb: []const u8, path: []const u8, controller: ?[]const u8, action: ?[]const u8, line: u64) route_mod.Route {
    return .{
        .verb = verb,
        .path = path,
        .controller = controller,
        .action = action,
        .name = null,
        .certain = true,
        .origin = .static_ast,
        .source = .{ .file = "config/routes.rb", .line = line },
    };
}

fn tVerdict(class: classify.Class) classify.Verdict {
    return .{ .class = class, .reason = "test", .candidates = &.{} };
}

fn tText(text: []const u8, line: u64) fragments.Node {
    return .{ .text = text, .kind = .unknown, .line = line, .col = 1, .output = false, .code = "", .name = null, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}

fn tNode(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8) fragments.Node {
    return .{ .text = null, .kind = kind, .line = line, .col = col, .output = false, .code = "", .name = name, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}

/// A block-opening node (`content_for :head do`): non-empty `code` and
/// `output == false` is what `convert.zig` reads as "this is a block".
fn tOpen(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8, code: []const u8) fragments.Node {
    var n = tNode(kind, line, col, name);
    n.code = code;
    return n;
}

fn tEnd(line: u64, col: u64) fragments.Node {
    var n = tNode(.block_end, line, col, null);
    n.code = "end";
    return n;
}

fn tTemplate(path: []const u8, nodes: []const fragments.Node) fragments.Template {
    return .{ .path = path, .nodes = @constCast(nodes), .error_message = null, .error_line = null, .unreadable = null };
}

/// The target path a test writes into: cwd-relative, like production's.
fn tmpTarget(gpa: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
}

fn readTarget(gpa: Allocator, tmp: *std.testing.TmpDir, relative: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(gpa, "out/{s}", .{relative});
    defer gpa.free(p);
    return tmp.dir.readFileAlloc(std.testing.io, p, gpa, .limited(1024 * 1024));
}

fn targetHas(tmp: *std.testing.TmpDir, relative: []const u8) bool {
    const gpa = testing.allocator;
    const p = std.fmt.allocPrint(gpa, "out/{s}", .{relative}) catch return false;
    defer gpa.free(p);
    tmp.dir.access(std.testing.io, p, .{}) catch return false;
    return true;
}

test "write: a static content route becomes a layout, a view and a content page" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.yield, 1, 13, null),
        tText("</body></html>", 1),
    };
    const view_nodes = [_]fragments.Node{tText("<h1>About us</h1>", 1)};
    const frags = [_]fragments.Template{
        tTemplate("app/views/layouts/marketing.html.erb", &layout_nodes),
        tTemplate("app/views/pages/about.html.erb", &view_nodes),
    };
    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = "app/views/layouts/marketing.html.erb" }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;

    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "agents\n",
        .claude_md = "claude\n",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 1), res.routes.len);
    try testing.expectEqual(Status.migrated, res.routes[0].status);
    try testing.expectEqual(@as(usize, 0), res.routes[0].open_finding_ids.len);
    try testing.expectEqual(@as(usize, 3), res.routes[0].artifacts.len);

    const page = try readTarget(gpa, &tmp, "content/about/index.smd");
    defer gpa.free(page);
    try testing.expectEqualStrings(
        \\---
        \\.title = "About us",
        \\.layout = "pages/about.shtml",
        \\.custom = {
        \\    .rails = {
        \\        .route = "GET /about",
        \\        .controller = "pages",
        \\        .action = "about",
        \\        .source = "app/views/pages/about.html.erb",
        \\    },
        \\},
        \\---
        \\
    , page);

    const view = try readTarget(gpa, &tmp, "layouts/pages/about.shtml");
    defer gpa.free(view);
    // The empty `<head id="head">` is not noise: a converted layout ALWAYS
    // declares `head` and `main` (ruling S9), and a `<super>` with no block
    // to fill it is a `MISSING TOP-LEVEL BLOCK` that stops the generated site
    // from building. So a view with nothing to put in the head still has to
    // say so.
    try testing.expectEqualStrings(
        \\<extend template="marketing.shtml">
        \\<head id="head"></head>
        \\<div id="main">
        \\<h1>About us</h1>
        \\</div>
        \\
    , view);

    try testing.expect(targetHas(&tmp, "layouts/templates/marketing.shtml"));

    // No assets copied, so no `.static_assets` line; no SPA, so no
    // `package.json` and no `bun install` in build.sh.
    const config = try readTarget(gpa, &tmp, "zigapagos.ziggy");
    defer gpa.free(config);
    try testing.expect(std.mem.indexOf(u8, config, ".title = \"Blog\"") != null);
    try testing.expect(std.mem.indexOf(u8, config, "static_assets") == null);
    const build_sh = try readTarget(gpa, &tmp, "build.sh");
    defer gpa.free(build_sh);
    try testing.expect(std.mem.indexOf(u8, build_sh, "bun install") == null);
    try testing.expect(std.mem.indexOf(u8, build_sh, "--spa=") == null);
    try testing.expect(!targetHas(&tmp, "package.json"));
    try testing.expect(targetHas(&tmp, "AGENTS.md"));
    try testing.expect(targetHas(&tmp, "CLAUDE.md"));
    try testing.expect(targetHas(&tmp, ".gitignore"));
    try testing.expect(err_path == null);
}

test "write: two routes rendering one view share its files and get their own pages" {
    // `root "pages#about"` alongside `get "/about"` is the fixture shape.
    // Writing `layouts/pages/about.shtml` twice would hit the exclusive-create
    // guard, so the dedupe is load-bearing, not an optimisation.
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const view_nodes = [_]fragments.Node{tText("<p>x</p>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{
        tRoute("GET", "/", "pages", "about", 1),
        tRoute("GET", "/about", "pages", "about", 2),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls, .layout = null },
        .{ .templates = &tpls, .layout = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 2), res.routes.len);
    for (res.routes) |o| try testing.expectEqual(Status.migrated, o.status);
    try testing.expect(targetHas(&tmp, "content/index.smd"));
    try testing.expect(targetHas(&tmp, "content/about/index.smd"));
    try testing.expect(targetHas(&tmp, "layouts/pages/about.shtml"));
}

test "write: a route whose view cannot be converted is acknowledged by a decision on that view's finding" {
    // The Haml route in `tests/migrate/rails-presentation`: the view is a real
    // file the inventory listed, but no fragment stream exists for it (the
    // templates op never scans an engine it cannot parse), so `ensureView`
    // refuses it. The route can never be `migrated` -- but ruling S18 gives
    // the view a `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` finding, and a decision
    // on it has to actually land, or `complete` is unreachable for any app
    // holding one Haml view.
    const gpa = testing.allocator;
    var rs = [_]route_mod.Route{tRoute("GET", "/posts/legacy", "posts", "legacy", 3)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/posts/legacy.html.haml"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .unsupported_templates = &[_]findings.UnsupportedTemplate{
            .{ .path = "app/views/posts/legacy.html.haml", .label = "Haml" },
        },
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    // Undecided: open, but carrying the id the operator has to answer.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
        try testing.expect(res.routes[0].decision_id == null);
        // Nothing was written: there is no converted view to write.
        try testing.expect(!targetHas(&tmp, "content/posts/legacy/index.smd"));
    }

    // Decided `blocked`.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "blocked",
            .rationale = "no Haml converter",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.blocked, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
    }
}

test "write: an undecided finding leaves the route open, and a blocked decision acknowledges it" {
    const gpa = testing.allocator;

    const view_nodes = [_]fragments.Node{
        tText("<p>", 1),
        tNode(.unknown, 1, 4, "number_to_currency"),
        tText("</p>", 1),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    // Undecided.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
        try testing.expect(res.routes[0].decision_id == null);
        // The page is still written: an open route is a page with a gap in
        // it, not an absent page.
        try testing.expect(targetHas(&tmp, "content/about/index.smd"));
    }

    // Decided `blocked`.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "blocked",
            .rationale = "needs a currency island",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.blocked, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
        // Acknowledged, not resolved: the finding is still listed.
        try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
    }

    // Decided `island` -- accepted, recorded, and still open.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "island",
            .rationale = "port it",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqualStrings("choice island deferred to Stage 4", res.routes[0].note.?);
    }
}

test "write: an unmapped region keeps the route open even with no finding ids" {
    // Ruling S6, and the discriminating case for it: a `form` block derives
    // NO Stage 1 finding, so `open_finding_ids` is empty and only the
    // converted bytes say the page is unfinished.
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const view_nodes = [_]fragments.Node{
        tNode(.form, 1, 1, null),
        tText("<input>", 2),
        tNode(.block_end, 3, 1, null),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/new.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tRoute("GET", "/new", "pages", "new", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/new.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 0), res.routes[0].open_finding_ids.len);
    try testing.expectEqual(Status.open, res.routes[0].status);
    try testing.expectEqualStrings("form: deferred to Stage 3", res.routes[0].note.?);
}

test "write: an acknowledged route writes no page and no view file (ruling S20)" {
    // `blocked` used to be a relabelling: the page was written before the
    // decision was read, so the built site served a blank `<main>` for a
    // route the handoff called blocked -- worse than a 404, because it looks
    // deliberate. The handoff row is the record; the target holds only what
    // the site serves.
    const gpa = testing.allocator;

    const view_nodes = [_]fragments.Node{
        tText("<p>", 1),
        tNode(.unknown, 1, 4, "number_to_currency"),
        tText("</p>", 1),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/help.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tRoute("GET", "/help", "pages", "help", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/help.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    // Undecided: the page and the view file ARE written. This half is the
    // discriminator -- without it the assertions below would pass just as
    // well against a converter that writes nothing at all.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expect(targetHas(&tmp, "content/help/index.smd"));
        try testing.expect(targetHas(&tmp, "layouts/pages/help.shtml"));
        try testing.expectEqual(@as(usize, 2), res.routes[0].artifacts.len);
    }

    // Decided `blocked`: neither file exists, and the row claims no artifact.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "blocked",
            .rationale = "no static equivalent",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.blocked, res.routes[0].status);
        try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
        try testing.expect(!targetHas(&tmp, "content/help/index.smd"));
        try testing.expect(!targetHas(&tmp, "layouts/pages/help.shtml"));
    }

    // Decided `retain`: the same, for the same reason -- the page stays on
    // Rails, so this target must not answer that URL either.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "retain",
            .rationale = "stays on Rails",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.retained, res.routes[0].status);
        try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
        try testing.expect(!targetHas(&tmp, "content/help/index.smd"));
        try testing.expect(!targetHas(&tmp, "layouts/pages/help.shtml"));
    }
}

test "write: a shared view is written once, by the first route that needs it (ruling S20)" {
    // The ViewCache is keyed by (view, layout) and a view serves several
    // routes, so S20's skip has to be "do not write YET", not "do not
    // convert": the file belongs to the first route that actually needs it.
    // Constructed directly here because the two routes cannot disagree
    // through the decisions file -- routes sharing a view under one layout
    // have identical `open_finding_ids`, so one answer settles both -- and a
    // future finding that is per-route rather than per-template would make
    // this reachable without touching this file.
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const view_nodes = [_]fragments.Node{tText("<h1>Shared</h1>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{
        tRoute("GET", "/", "pages", "about", 1),
        tRoute("GET", "/about", "pages", "about", 2),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls, .layout = null },
        .{ .templates = &tpls, .layout = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // Two routes, two pages, ONE view file -- written once, by whichever
    // route got there first, and never re-written (the exclusive-create guard
    // would have turned a second write into `error.TargetWrite`).
    for (res.routes) |o| try testing.expectEqual(Status.migrated, o.status);
    try testing.expect(targetHas(&tmp, "content/index.smd"));
    try testing.expect(targetHas(&tmp, "content/about/index.smd"));
    try testing.expect(targetHas(&tmp, "layouts/pages/about.shtml"));
}

test "write: an acknowledged route is acknowledged even when a region stayed unmapped (ruling S19)" {
    // The fixture's `/registration/new`: a form (which DOES derive a finding)
    // beside an unbound block local (which derives none and converts to
    // `<!-- rails:unmapped local -->`). Ruling S6 kept such a route `open`
    // whatever the operator answered, so the route could never complete. S19:
    // an acknowledgement settles it -- `retain` means the page stays on Rails
    // and this target does not serve it, so what the converter could not map
    // is moot. The S6 net still catches the route nobody answered.
    const gpa = testing.allocator;

    const view_nodes = [_]fragments.Node{
        tText("<p>", 1),
        tNode(.unknown, 1, 4, "number_to_currency"),
        // No `locals` at a view's render site, so this one cannot be
        // substituted: `convert.zig` emits the unmapped marker for it.
        tNode(.local, 1, 30, "m"),
        tText("</p>", 1),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/new.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tRoute("GET", "/new", "pages", "new", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/new.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    });
    defer findings.free(gpa, finding_list);
    // One finding for the helper; the local raises none -- which is the whole
    // reason ruling S6 exists and the whole reason S19 has to override it.
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    // Undecided: ruling S6 still holds, and says which construct it is.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expect(std.mem.indexOf(u8, res.routes[0].note.?, "local: converter gap (see #181)") != null);
    }

    // Answered `retain`: retained, and the note still names what was dropped.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "retain",
            .rationale = "stays on Rails for now",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.retained, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
        // The placeholder is still in the emitted bytes, so it is still
        // reported -- as a footnote, which cannot change the status back.
        try testing.expect(std.mem.indexOf(u8, res.routes[0].note.?, "local left unmapped") != null);
    }

    // Answered `island`: still open (Stage 4 owns it), and BOTH reasons are
    // recorded -- the deferral and the unmapped region.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var deferred = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "island",
            .rationale = "a currency island, later",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &deferred, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expect(std.mem.indexOf(u8, res.routes[0].note.?, "choice island deferred") != null);
        try testing.expect(std.mem.indexOf(u8, res.routes[0].note.?, "local: converter gap (see #181)") != null);
    }
}

test "write: a dynamic route is open until a spa decision scaffolds one .spa.tsx per segment" {
    const gpa = testing.allocator;

    var rs = [_]route_mod.Route{
        tRoute("GET", "/posts/:id", "posts", "show", 3),
        tRoute("GET", "/posts/:id/edit", "posts", "edit", 3),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    // Undecided.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        for (res.routes) |o| {
            try testing.expectEqual(Status.open, o.status);
            try testing.expectEqualStrings(finding_list[0].id, o.open_finding_ids[0]);
        }
        try testing.expectEqual(@as(usize, 0), res.spa_files.len);
    }

    // Decided `spa`: ONE file, both routes in it, both migrated.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "spa",
            .rationale = "client-routed",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = "../runtime",
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);

        try testing.expectEqual(@as(usize, 1), res.spa_files.len);
        try testing.expectEqualStrings("spa/posts.spa.tsx", res.spa_files[0]);
        for (res.routes) |o| {
            try testing.expectEqual(Status.migrated, o.status);
            try testing.expectEqual(@as(usize, 1), o.artifacts.len);
            try testing.expectEqualStrings("spa/posts.spa.tsx", o.artifacts[0]);
        }

        const spa_src = try readTarget(gpa, &tmp, "spa/posts.spa.tsx");
        defer gpa.free(spa_src);
        try testing.expectEqualStrings(
            \\// Generated by `zigapagos migrate --from rails`. Every component below is a
            \\// placeholder: the Rails view it names still has to be ported by hand.
            \\import { Router } from "@z/runtime";
            \\
            \\export const spa = { base: "/posts" };
            \\
            \\function PostsShow() {
            \\  return <p>{"TODO: port GET /posts/:id (posts#show)"}</p>;
            \\}
            \\
            \\function PostsEdit() {
            \\  return <p>{"TODO: port GET /posts/:id/edit (posts#edit)"}</p>;
            \\}
            \\
            \\export const routes = [
            \\  { path: "/:id", component: PostsShow, skeleton: false, staticPaths: [] },
            \\  { path: "/:id/edit", component: PostsEdit, skeleton: false, staticPaths: [] },
            \\];
            \\
            \\export default function App() {
            \\  return <Router base={spa.base} routes={routes} />;
            \\}
            \\
        , spa_src);

        const build_sh = try readTarget(gpa, &tmp, "build.sh");
        defer gpa.free(build_sh);
        try testing.expectEqualStrings(
            \\#!/usr/bin/env bash
            \\set -euo pipefail
            \\cd "$(dirname "$0")"
            \\bun install --frozen-lockfile 2>/dev/null || bun install
            \\exec "${ZIGAPAGOS_BIN:-zigapagos}" release --force --output=zig-out/site --spa='spa/posts.spa.tsx|/posts' "$@"
            \\
        , build_sh);

        const pkg = try readTarget(gpa, &tmp, "package.json");
        defer gpa.free(pkg);
        try testing.expect(std.mem.indexOf(u8, pkg, "\"file:../runtime\"") != null);
        try testing.expect(targetHas(&tmp, "tsconfig.json"));
    }
}

test "write: backend and redirect routes produce no page, and a redirect is reported" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rs = [_]route_mod.Route{
        tRoute("POST", "/posts", "posts", "create", 3),
        tRoute("GET", "/posts/old", "posts", "old", 5),
    };
    var vs = [_]classify.Verdict{ tVerdict(.backend), tVerdict(.redirect) };
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // Sorted by path: `/posts` then `/posts/old`.
    try testing.expectEqual(Status.backend, res.routes[0].status);
    try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
    try testing.expectEqual(Status.redirect, res.routes[1].status);
    try testing.expectEqual(@as(usize, 1), res.redirects.len);
    try testing.expectEqualStrings("/posts/old", res.redirects[0].from);
    try testing.expect(res.redirects[0].to == null);
    // The redirect route carries the finding an operator acknowledges it by.
    try testing.expectEqualStrings(
        "RAILS_REDIRECT_HOST_CONFIG.config/routes%2Erb.L5",
        res.routes[1].open_finding_ids[0],
    );
}

test "write: a deterministic asset is copied, and the config then declares static_assets" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var img_dir = try tmp.dir.createDirPathOpen(std.testing.io, "app/assets/images", .{});
    img_dir.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/assets/images/logo.png", .data = "png bytes" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "robots.txt", .data = "User-agent: *\n" });

    var asset_list = [_]asset_mod.Asset{
        .{ .source = "app/assets/images/logo.png", .public_url = "/assets/logo-abc.png", .pipeline = .propshaft, .deterministic = true },
        // `public/`: no pipeline, deterministic by construction. The fixture
        // file above sits at the tmp root because `assetTargetPath` strips
        // the `public/` prefix -- so the SOURCE read uses the recorded path.
        .{ .source = "robots.txt", .public_url = "/robots.txt", .pipeline = null, .deterministic = true },
        // Not deterministic and pipeline known: discovery could not place it,
        // so it is not copied.
        .{ .source = "app/assets/images/ghost.png", .public_url = null, .pipeline = .propshaft, .deterministic = false },
    };
    var d = emptyDiscovery();
    d.assets = &asset_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 2), res.assets.len);
    try testing.expectEqualStrings("app/assets/images/logo.png", res.assets[0].source);
    try testing.expectEqualStrings("/assets/logo-abc.png", res.assets[0].rails_url.?);
    try testing.expectEqualStrings("/images/logo.png", res.assets[0].target_url);
    try testing.expectEqualStrings("robots.txt", res.assets[1].source);
    try testing.expectEqualStrings("/robots.txt", res.assets[1].target_url);

    const copied = try readTarget(gpa, &tmp, "assets/images/logo.png");
    defer gpa.free(copied);
    try testing.expectEqualStrings("png bytes", copied);
    try testing.expect(!targetHas(&tmp, "assets/images/ghost.png"));

    const config = try readTarget(gpa, &tmp, "zigapagos.ziggy");
    defer gpa.free(config);
    try testing.expect(std.mem.indexOf(u8, config, ".static_assets = [\"**\"],") != null);
}

test "write: the compiled pipeline output under public/assets is never copied (ruling S17)" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var man_dir = try tmp.dir.createDirPathOpen(std.testing.io, "public/assets", .{});
    man_dir.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "public/assets/.manifest.json", .data = "{}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "public/assets/logo-abc123.png", .data = "digested png" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "robots.txt", .data = "User-agent: *\n" });

    var asset_list = [_]asset_mod.Asset{
        // Both of these are real files the inventory lists and `assets.scan`
        // places deterministically -- they are served by the Rails app. They
        // are still build OUTPUT: the digested copy duplicates an
        // `app/assets/` source that is copied on its own, and the manifest is
        // the pipeline's bookkeeping. Copying either would ship
        // `assets/assets/...` in the target.
        .{ .source = "public/assets/.manifest.json", .public_url = "/assets/.manifest.json", .pipeline = null, .deterministic = true },
        .{ .source = "public/assets/logo-abc123.png", .public_url = "/assets/logo-abc123.png", .pipeline = null, .deterministic = true },
        .{ .source = "robots.txt", .public_url = "/robots.txt", .pipeline = null, .deterministic = true },
    };
    var d = emptyDiscovery();
    d.assets = &asset_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 1), res.assets.len);
    try testing.expectEqualStrings("robots.txt", res.assets[0].source);
    try testing.expect(!targetHas(&tmp, "assets/assets/.manifest.json"));
    try testing.expect(!targetHas(&tmp, "assets/assets/logo-abc123.png"));
    try testing.expect(targetHas(&tmp, "assets/robots.txt"));
}

test "write: an asset the source cannot read is SourceRead, naming the source path" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var asset_list = [_]asset_mod.Asset{
        .{ .source = "public/gone.png", .public_url = "/gone.png", .pipeline = null, .deterministic = true },
    };
    var d = emptyDiscovery();
    d.assets = &asset_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    try testing.expectError(error.SourceRead, write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause));
    try testing.expectEqualStrings("public/gone.png", err_path.?);
}

test "write: a file already in the target is TargetWrite, naming it -- never an overwrite" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_dir = try tmp.dir.createDirPathOpen(std.testing.io, "out", .{});
    out_dir.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "out/zigapagos.ziggy", .data = "hand edited\n" });

    var d = emptyDiscovery();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    try testing.expectError(error.TargetWrite, write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause));
    try testing.expect(std.mem.endsWith(u8, err_path.?, "out/zigapagos.ziggy"));

    // The pre-existing bytes are untouched.
    const kept = try readTarget(gpa, &tmp, "zigapagos.ziggy");
    defer gpa.free(kept);
    try testing.expectEqualStrings("hand edited\n", kept);
}

test "write: two runs of the identical input produce byte-identical trees" {
    const gpa = testing.allocator;

    const layout_nodes = [_]fragments.Node{ tText("<html>", 1), tNode(.yield, 1, 7, null), tText("</html>", 1) };
    const a_nodes = [_]fragments.Node{tText("<h1>A</h1>", 1)};
    const b_nodes = [_]fragments.Node{tText("<h1>B</h1>", 1)};
    const frags = [_]fragments.Template{
        tTemplate("app/views/layouts/application.html.erb", &layout_nodes),
        tTemplate("app/views/pages/a.html.erb", &a_nodes),
        tTemplate("app/views/pages/b.html.erb", &b_nodes),
    };
    var a_tpls = [_][]const u8{"app/views/pages/a.html.erb"};
    var b_tpls = [_][]const u8{"app/views/pages/b.html.erb"};

    // The two runs see the SAME routes in OPPOSITE order: nothing about the
    // emitted tree may depend on the sidecar's emission order.
    var forward = [_]route_mod.Route{
        tRoute("GET", "/a", "pages", "a", 1),
        tRoute("GET", "/b", "pages", "b", 2),
    };
    var reverse = [_]route_mod.Route{
        tRoute("GET", "/b", "pages", "b", 2),
        tRoute("GET", "/a", "pages", "a", 1),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var forward_rts = [_]rails.RouteTemplates{
        .{ .templates = &a_tpls, .layout = "app/views/layouts/application.html.erb" },
        .{ .templates = &b_tpls, .layout = "app/views/layouts/application.html.erb" },
    };
    var reverse_rts = [_]rails.RouteTemplates{
        .{ .templates = &b_tpls, .layout = "app/views/layouts/application.html.erb" },
        .{ .templates = &a_tpls, .layout = "app/views/layouts/application.html.erb" },
    };

    var first: ?[]u8 = null;
    defer if (first) |f| gpa.free(f);

    for ([_]bool{ true, false }) |is_forward| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var d = emptyDiscovery();
        d.routes = if (is_forward) &forward else &reverse;
        d.classifications = &vs;
        d.route_templates = if (is_forward) &forward_rts else &reverse_rts;
        d.fragments = @constCast(&frags);

        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);

        // The outcome list is in this file's own route order, not the input's,
        // so `route_index` is what differs between the runs -- the STATUSES
        // and artifacts must not.
        try testing.expectEqual(@as(usize, 2), res.routes.len);
        for (res.routes) |o| try testing.expectEqual(Status.migrated, o.status);

        const digest = try treeDigest(gpa, &tmp);
        if (first) |f| {
            try testing.expectEqualStrings(f, digest);
            gpa.free(digest);
        } else {
            first = digest;
        }
    }
}

/// Every target file's path and bytes, path-sorted: a whole-tree comparison
/// in one string, so a determinism failure names the file that differs.
fn treeDigest(gpa: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    var dir = try tmp.dir.openDir(std.testing.io, "out", .{ .iterate = true });
    defer dir.close(std.testing.io);

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        try paths.append(gpa, try gpa.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanStr);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (paths.items) |p| {
        try out.appendSlice(gpa, p);
        try out.append(gpa, '\n');
        const bytes = try dir.readFileAlloc(std.testing.io, p, gpa, .limited(1024 * 1024));
        defer gpa.free(bytes);
        try out.appendSlice(gpa, bytes);
        try out.appendSlice(gpa, "\n---\n");
    }
    return out.toOwnedSlice(gpa);
}

test "write: every allocation failure is clean -- no leaks on any OOM path" {
    // The sweep runs the whole `write` under a FailingAllocator that fails at
    // index 0, 1, 2, ... in turn. Any missing `errdefer` shows up as a leak
    // report from `std.testing.allocator` underneath it.
    const gpa = testing.allocator;

    const view_nodes = [_]fragments.Node{tText("<h1>T</h1>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/pages/a.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{
        tRoute("GET", "/a", "pages", "a", 1),
        tRoute("GET", "/p/:id", "posts", "show", 2),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var a_tpls = [_][]const u8{"app/views/pages/a.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &a_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    var asset_list = [_]asset_mod.Asset{
        .{ .source = "robots.txt", .public_url = "/robots.txt", .pipeline = null, .deterministic = true },
    };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.assets = &asset_list;

    // A `spa` decision so the sweep also covers pass 3 (the `.spa.tsx`, the
    // `package.json`, and the artifact-list grow on an already-built
    // outcome). Built with the REAL allocator: it is the test's own input,
    // not part of what is being swept.
    const spa_id = try findings.routeFindingId(gpa, findings.code_route_dynamic_segment, 2);
    defer gpa.free(spa_id);
    var decided = [_]decisions.Decision{.{
        .id = spa_id,
        .choice = "spa",
        .rationale = "client-routed",
        .artifact = null,
    }};

    var fail_index: usize = 0;
    while (fail_index < 400) : (fail_index += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "robots.txt", .data = "ok\n" });

        // The target path is built with the real allocator: it is the test's
        // own scaffolding, not part of what is being swept.
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);

        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| fa.free(p);
        var err_cause: ?anyerror = null;

        if (write(std.testing.io, fa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = "../runtime",
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause)) |res| {
            freeResult(fa, res);
            break; // past the last allocation: the sweep is complete.
        } else |err| switch (err) {
            error.OutOfMemory => {},
            // A partially-written tree from a previous OOM can make the next
            // exclusive-create collide; that is the guard doing its job, not
            // a leak, and the tmp dir is fresh each iteration anyway.
            error.TargetWrite, error.SourceRead => {},
        }
    }
    try testing.expect(fail_index < 400);
}

// ---- rulings S7/S9: the layout/view block interface ----------------------
//
// SuperHTML fatals in BOTH directions -- a block with no matching `<super>`
// is an `UNBOUND TOP-LEVEL BLOCK`, a `<super>` with no matching block is a
// `MISSING TOP-LEVEL BLOCK`. `scaffold.zig`'s only job here is to hand the
// view its layout's `block_ids`; these two tests pin that it does, from the
// outside, on the bytes that reach the target tree.

/// One `GET /about` route rendering `app/views/pages/about.html.erb` under
/// `app/views/layouts/application.html.erb`, converted into a fresh tmp
/// target. Returns the two written `.shtml`s plus the route's outcome note.
const Pair = struct {
    layout: []u8,
    view: []u8,
    status: Status,
    note: ?[]u8,

    fn deinit(self: *Pair, gpa: Allocator) void {
        gpa.free(self.layout);
        gpa.free(self.view);
        if (self.note) |n| gpa.free(n);
    }
};

fn scaffoldPair(
    gpa: Allocator,
    layout_nodes: []const fragments.Node,
    view_nodes: []const fragments.Node,
) !Pair {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const frags = [_]fragments.Template{
        tTemplate("app/views/layouts/application.html.erb", layout_nodes),
        tTemplate("app/views/pages/about.html.erb", view_nodes),
    };
    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = "app/views/layouts/application.html.erb" }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const layout = try readTarget(gpa, &tmp, "layouts/templates/application.shtml");
    errdefer gpa.free(layout);
    const view = try readTarget(gpa, &tmp, "layouts/pages/about.shtml");
    errdefer gpa.free(view);
    const note = if (res.routes[0].note) |n| try gpa.dupe(u8, n) else null;
    return .{ .layout = layout, .view = view, .status = res.routes[0].status, .note = note };
}

test "write: a layout's named yield becomes a block the view fills, empty when it has none" {
    const gpa = testing.allocator;
    // (a) `yield :sidebar` puts a third `<super>` in the layout. The view has
    // no `content_for :sidebar`, so it must still emit an EMPTY
    // `<div id="sidebar">` -- a `<super>` nothing fills is a
    // `MISSING TOP-LEVEL BLOCK` and the generated site would not build. The
    // scaffolder's whole contribution is passing the layout's `block_ids`
    // down; without it the view emits only `head`/`main`.
    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.yield, 1, 13, null),
        tText("<aside>", 2),
        tNode(.yield_named, 2, 8, "sidebar"),
        tText("</aside></body></html>", 2),
    };
    const view_nodes = [_]fragments.Node{tText("<h1>About</h1>", 1)};

    var pair = try scaffoldPair(gpa, &layout_nodes, &view_nodes);
    defer pair.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, pair.layout, "id=\"sidebar\"") != null);
    try testing.expect(std.mem.indexOf(u8, pair.view, "<div id=\"sidebar\"></div>") != null);
    try testing.expect(std.mem.indexOf(u8, pair.view, "<div id=\"main\">") != null);
    try testing.expect(std.mem.indexOf(u8, pair.view, "<h1>About</h1>") != null);
    // An empty block it had nothing to put in is not a defect: nothing was
    // lost, so the route is finished.
    try testing.expectEqual(Status.migrated, pair.status);
    try testing.expect(pair.note == null);
}

test "write: a content_for the layout does not declare is dropped, and the route says so" {
    const gpa = testing.allocator;
    // (b) The mirror image. The layout declares only `head`/`main`, so a
    // view's `content_for :sidebar` has no `<super>` to fill -- emitting it
    // would be an `UNBOUND TOP-LEVEL BLOCK`. `convert.zig` drops it and
    // reports the drop; this file folds `Output.dropped` into the route's
    // note, which is the only place an operator ever learns what went
    // missing.
    //
    // Ruling S15: this drop is NOT informational. `<nav>links</nav>` is
    // markup the author wrote and the target does not have -- unlike a
    // `csrf_meta_tags` drop, which removes a construct with a defined
    // conversion and loses nothing. So the route is `open`, not `migrated`.
    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.yield, 1, 13, null),
        tText("</body></html>", 1),
    };
    const view_nodes = [_]fragments.Node{
        tOpen(.content_for, 1, 1, "sidebar", "content_for :sidebar do"),
        tText("<nav>links</nav>", 1),
        tEnd(1, 40),
        tText("<h1>About</h1>", 2),
    };

    var pair = try scaffoldPair(gpa, &layout_nodes, &view_nodes);
    defer pair.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, pair.layout, "id=\"sidebar\"") == null);
    try testing.expect(std.mem.indexOf(u8, pair.view, "id=\"sidebar\"") == null);
    try testing.expect(std.mem.indexOf(u8, pair.view, "links") == null);
    // The loss is reported, not silent -- and it is reported as a REASON,
    // which is what keeps a human looking at this route.
    try testing.expect(pair.note != null);
    try testing.expect(std.mem.indexOf(u8, pair.note.?, "sidebar") != null);
    try testing.expectEqual(Status.open, pair.status);
}

test "write: a csrf drop stays informational -- the route is still migrated" {
    const gpa = testing.allocator;
    // The other half of ruling S15, and the case that makes it a distinction
    // rather than a blanket rule. `csrf_meta_tags` has a DEFINED conversion
    // (the ZigBase cookie boundary replaces it), so removing it loses
    // nothing an operator has to act on: the note is worth printing in
    // `MIGRATION.md` and worth nothing as a status.
    const layout_nodes = [_]fragments.Node{
        tText("<html><head>", 1),
        tNode(.csrf, 1, 13, "csrf_meta_tags"),
        tText("</head><body>", 1),
        tNode(.yield, 1, 30, null),
        tText("</body></html>", 1),
    };
    const view_nodes = [_]fragments.Node{tText("<h1>About</h1>", 1)};

    var pair = try scaffoldPair(gpa, &layout_nodes, &view_nodes);
    defer pair.deinit(gpa);

    try testing.expect(pair.note != null);
    try testing.expect(std.mem.indexOf(u8, pair.note.?, "csrf_meta_tags dropped") != null);
    try testing.expectEqual(Status.migrated, pair.status);
}

// ---- ruling S13: a SPA needs somewhere to mount --------------------------

test "write: a spa decision on a top-level dynamic route is not applied" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `get "/:slug"`. Honouring `spa` here would write `spa/:slug.spa.tsx`
    // with `base: "/:slug"` -- a filename with a colon and a mount base that
    // is a pattern. Nothing downstream can build it.
    var rs = [_]route_mod.Route{tRoute("GET", "/:slug", "pages", "show", 3)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var rts = [_]rails.RouteTemplates{.{ .templates = &.{}, .layout = null }};
    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    var decided = [_]decisions.Decision{.{
        .id = finding_list[0].id,
        .choice = "spa",
        .rationale = "client-routed",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(Status.open, res.routes[0].status);
    try testing.expectEqualStrings("spa needs a static first segment", res.routes[0].note.?);
    try testing.expectEqual(@as(usize, 0), res.spa_files.len);
    try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
    // The decision IS recorded -- it was made, it just could not be carried
    // out -- so the handoff can show why the route is still open.
    try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
    try testing.expect(!targetHas(&tmp, "package.json"));
}

test "write: staticPaths is emitted only for a spa entry whose own path is dynamic" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Grouping is by FIRST SEGMENT, so a static route can share a `.spa.tsx`
    // with a dynamic one. `runtime/src/router.ts:698` throws "staticPaths
    // declared on static route", so the static entry must not carry the key.
    var rs = [_]route_mod.Route{
        tRoute("GET", "/posts/:id", "posts", "show", 3),
        tRoute("GET", "/posts/new", "posts", "new", 3),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    var decided = [_]decisions.Decision{.{
        .id = finding_list[0].id,
        .choice = "spa",
        .rationale = "client-routed",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const spa_src = try readTarget(gpa, &tmp, "spa/posts.spa.tsx");
    defer gpa.free(spa_src);
    // `/posts/:id` -> `/:id`: dynamic, so it enumerates.
    try testing.expect(std.mem.indexOf(u8, spa_src, "{ path: \"/:id\", component: PostsShow, skeleton: false, staticPaths: [] }") != null);
    // `/posts/new` is NOT dynamic, so it never reached the SPA at all -- it
    // took the content path. Only the dynamic one is here.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, spa_src, "path: \""));

    // The build line restates the base, which turns `src/spa.zig`'s
    // agreement and overlap checks back on.
    const build_sh = try readTarget(gpa, &tmp, "build.sh");
    defer gpa.free(build_sh);
    // Quoted: see `emitBuildSh`. A substring check like this one is what let
    // the unquoted form ship, so it is paired with the replay test at the
    // bottom of this file rather than trusted on its own.
    try testing.expect(std.mem.indexOf(u8, build_sh, "--spa='spa/posts.spa.tsx|/posts'") != null);
}

test "spaRoutePath + isDynamicRoutePath is the gate staticPaths is emitted behind" {
    // The unit-level half of the rule above. There is deliberately no
    // end-to-end case for the OTHER branch, and the reason is worth writing
    // down rather than leaving as an untested line:
    //
    // only a route `findings.isDynamicRoutePath` accepts ever reaches
    // `writeSpas`, and ruling S13 refuses the one shape whose placeholder is
    // the FIRST segment -- so every surviving route has its placeholder
    // somewhere after the segment the SPA is mounted at, and the rest path is
    // always dynamic. The `if` in `emitSpa` is therefore defence in depth
    // against a future change to the grouping (mounting by controller, say,
    // which would put `/posts/new` and `/posts/:id` in one file), not a live
    // branch. Pinning the predicate here keeps that reasoning checkable
    // without inventing an input the production path cannot produce.
    try testing.expectEqualStrings("/:id", spaRoutePath("/posts/:id", "posts"));
    try testing.expectEqualStrings("/:id/edit", spaRoutePath("/posts/:id/edit", "posts"));
    try testing.expectEqualStrings("/new", spaRoutePath("/posts/new", "posts"));
    try testing.expectEqualStrings("/", spaRoutePath("/posts", "posts"));

    try testing.expect(findings.isDynamicRoutePath(spaRoutePath("/posts/:id", "posts")));
    try testing.expect(!findings.isDynamicRoutePath(spaRoutePath("/posts/new", "posts")));
    try testing.expect(!findings.isDynamicRoutePath(spaRoutePath("/posts", "posts")));
}

// A route routinely carries several findings and the operator may answer them
// differently, so which answer decides the ROUTE is a rule and not an
// accident. It was previously observable only through a whole `write` run,
// which meant swapping the two ranks broke no test at all: every case a run
// exercises has one answer.
test "pickDecision: blocked beats retain beats a deferral, ties broken by the smallest id" {
    var answers = [_]decisions.Decision{
        .{ .id = "A", .choice = "island", .rationale = "r", .artifact = null },
        .{ .id = "B", .choice = "retain", .rationale = "r", .artifact = null },
        .{ .id = "C", .choice = "blocked", .rationale = "r", .artifact = null },
        .{ .id = "D", .choice = "blocked", .rationale = "r", .artifact = null },
        .{ .id = "E", .choice = "retain", .rationale = "r", .artifact = null },
        .{ .id = "F", .choice = "backend", .rationale = "r", .artifact = null },
    };
    const parsed: decisions.Parsed = .{ .decisions = &answers, .stale = &.{} };

    // `blocked` is the stronger statement: an operator who blocked the route
    // on one of its gaps has not agreed to ship it because another gap was
    // marked `retain`. Asserted in both input orders, so the winner cannot be
    // "whichever id came first".
    try testing.expectEqualStrings("C", pickDecision(parsed, &.{ "A", "B", "C" }).?.id);
    try testing.expectEqualStrings("C", pickDecision(parsed, &.{ "C", "B", "A" }).?.id);
    // `retain` beats `island`/`backend`, which leave the route open anyway.
    try testing.expectEqualStrings("B", pickDecision(parsed, &.{ "A", "B", "F" }).?.id);
    try testing.expectEqualStrings("B", pickDecision(parsed, &.{ "F", "B", "A" }).?.id);
    // Equal rank: the smallest id, again in both orders.
    try testing.expectEqualStrings("C", pickDecision(parsed, &.{ "D", "C" }).?.id);
    try testing.expectEqualStrings("C", pickDecision(parsed, &.{ "C", "D" }).?.id);
    try testing.expectEqualStrings("B", pickDecision(parsed, &.{ "E", "B" }).?.id);
    // An unanswered id contributes nothing; no answered id at all is `null`,
    // which is what leaves the route `open`.
    try testing.expectEqualStrings("B", pickDecision(parsed, &.{ "ghost", "B" }).?.id);
    try testing.expect(pickDecision(parsed, &.{"ghost"}) == null);
    try testing.expect(pickDecision(parsed, &.{}) == null);
}

// ---- ruling S14: a failure names its cause, a collision is not a failure --

test "write: a target-write failure reports the OS error, not just the path" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_dir = try tmp.dir.createDirPathOpen(std.testing.io, "out", .{});
    out_dir.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "out/zigapagos.ziggy", .data = "hand edited\n" });

    var d = emptyDiscovery();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    try testing.expectError(error.TargetWrite, write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause));
    // Without this the operator cannot tell "wipe the target and re-run" from
    // "fix a permission": `TargetWrite` alone says neither.
    try testing.expectEqual(@as(?anyerror, error.PathAlreadyExists), err_cause);
}

test "write: two routes mapping to one content path -- the second is open, not a failure" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `/about` and `/about/` normalise to the same `content/about/index.smd`
    // (`resolve.contentPath` trims the trailing slash), and a Rails app can
    // declare both. Before ruling S14 the second write hit the
    // exclusive-create guard and aborted the WHOLE migration with a
    // filesystem error naming neither route.
    const view_nodes = [_]fragments.Node{tText("<h1>About</h1>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{
        tRoute("GET", "/about", "pages", "about", 2),
        tRoute("GET", "/about/", "pages", "about", 3),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls, .layout = null },
        .{ .templates = &tpls, .layout = null },
    };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // Sorted by path: `/about` wins, `/about/` reports the clash.
    try testing.expectEqual(Status.migrated, res.routes[0].status);
    try testing.expectEqual(Status.open, res.routes[1].status);
    try testing.expectEqualStrings("content path collision with GET /about", res.routes[1].note.?);
    try testing.expect(err_path == null);
    try testing.expect(targetHas(&tmp, "content/about/index.smd"));
}

// ---- the C minors --------------------------------------------------------

test "write: a layout's own open finding leaves an otherwise-clean view open" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The view is spotless; the LAYOUT calls an unknown helper. A route is
    // its whole template graph, so the page is not finished.
    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.unknown, 1, 13, "number_to_currency"),
        tNode(.yield, 1, 40, null),
        tText("</body></html>", 1),
    };
    const view_nodes = [_]fragments.Node{tText("<h1>About</h1>", 1)};
    const frags = [_]fragments.Template{
        tTemplate("app/views/layouts/application.html.erb", &layout_nodes),
        tTemplate("app/views/pages/about.html.erb", &view_nodes),
    };
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = "app/views/layouts/application.html.erb" }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(Status.open, res.routes[0].status);
    try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
    try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
}

// Ruling S22. `pages#other` renders `:about` and has no `other.html.erb`, so
// the route reaches `contentRoute`, resolves no view, and writes nothing. It
// used to say so in a note with no id behind it, which made the whole app
// permanently incomplete: there was no line an operator could put in
// `MIGRATION.decisions.json`. The finding `derive` raises on the route's own
// `routes.rb` line is that line.
test "write: a route whose action resolves no view carries RAILS_NO_TEMPLATE, and an answer settles it (ruling S22)" {
    const gpa = testing.allocator;

    var rs = [_]route_mod.Route{tRoute("GET", "/other", "pages", "other", 3)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    // The route resolved a partial but no `pages/other.*`.
    var tpls = [_][]const u8{"app/views/shared/_nav.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};
    var rt_lists = [_][]const []const u8{&tpls};

    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_templates = &rt_lists,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    try testing.expectEqualStrings("RAILS_NO_TEMPLATE.config/routes%2Erb.L3", finding_list[0].id);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "retain",
            .rationale = "the action renders another template; leave it on Rails",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.retained, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
        try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
    }
}

// Ruling S21. The sibling of the test above, one layer up: ruling S18 gave a
// Haml VIEW an answerable finding, but a Haml LAYOUT left every route under it
// with nothing but an open note -- `complete` unreachable for the whole
// controller by any answer the operator could give. The layout's finding is
// the one question ("this chrome cannot be converted"), so one answer on it
// has to settle every route that declares it.
test "write: a route under an unconvertible layout carries that layout's finding, and one answer settles it (ruling S21)" {
    const gpa = testing.allocator;

    // The layout is Haml: real file, listed by the inventory, but the
    // templates op never scans an engine it cannot parse, so there is no
    // fragment stream for it and `ensureLayout` returns null. The VIEW is
    // ordinary ERB and converts cleanly.
    const view_nodes = [_]fragments.Node{tText("<h1>Lay</h1>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/lay/show.html.erb", &view_nodes)};
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .unsupported_templates = &[_]findings.UnsupportedTemplate{
            .{ .path = "app/views/layouts/legacy.html.haml", .label = "Haml" },
        },
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    try testing.expectEqualStrings(
        "RAILS_TEMPLATE_ENGINE_UNSUPPORTED.app/views/layouts/legacy%2Ehtml%2Ehaml.engine",
        finding_list[0].id,
    );

    var rs = [_]route_mod.Route{tRoute("GET", "/lay", "lay", "show", 3)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/lay/show.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = "app/views/layouts/legacy.html.haml" }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    // Undecided: the standalone page IS still emitted (it is chrome that is
    // missing, not content), and the layout's id is the question.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
        try testing.expect(targetHas(&tmp, "content/lay/index.smd"));
    }

    // Decided `blocked` on the LAYOUT's finding: the route is blocked and,
    // per ruling S20, writes nothing at all.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "blocked",
            .rationale = "no Haml converter for the chrome",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.blocked, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
        try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
        try testing.expect(!targetHas(&tmp, "content/lay/index.smd"));
    }
}

test "write: a finding inside an inlined partial reaches the route" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The view renders `shared/nav`, which is where the unknown helper is.
    // `convert.zig` inlines the partial, so the finding travels with it --
    // and the route must list it, because there is no other artifact the
    // partial's own gaps could be reported against.
    const view_nodes = [_]fragments.Node{
        tNode(.render_partial, 1, 1, "shared/nav"),
        tText("<h1>About</h1>", 2),
    };
    const partial_nodes = [_]fragments.Node{tNode(.unknown, 1, 1, "number_to_currency")};
    const frags = [_]fragments.Template{
        tTemplate("app/views/pages/about.html.erb", &view_nodes),
        tTemplate("app/views/shared/_nav.html.erb", &partial_nodes),
    };
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    try testing.expect(std.mem.indexOf(u8, finding_list[0].id, "_nav") != null);

    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{ "app/views/pages/about.html.erb", "app/views/shared/_nav.html.erb" };
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(Status.open, res.routes[0].status);
    try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
    try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
}

test "write: a description and a quoted title survive into Ziggy frontmatter" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `"` and `\` are the two characters that end a Ziggy string early; an
    // unescaped one makes the whole `.smd` unparseable, and the site fails to
    // build with an error pointing at the frontmatter rather than at the
    // Rails title it came from.
    const view_nodes = [_]fragments.Node{
        tOpen(.content_for, 1, 1, "title", "content_for :title do"),
        tText("The \"best\" C:\\path", 1),
        tEnd(1, 40),
        tText("<meta name=\"description\" content=\"Tea &amp; cake\">", 2),
        tText("<p>Body</p>", 3),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const page = try readTarget(gpa, &tmp, "content/about/index.smd");
    defer gpa.free(page);
    try testing.expect(std.mem.indexOf(u8, page, ".title = \"The \\\"best\\\" C:\\\\path\",") != null);
    // The description is plain text by the time it gets here: the HTML entity
    // is already resolved, and must not be double-unescaped.
    try testing.expect(std.mem.indexOf(u8, page, ".description = \"Tea & cake\",") != null);
}

test "write: a spa scaffolded with no runtime path says the package.json needs an edit" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rs = [_]route_mod.Route{tRoute("GET", "/posts/:id", "posts", "show", 3)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var rts = [_]rails.RouteTemplates{.{ .templates = &.{}, .layout = null }};
    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer findings.free(gpa, finding_list);
    var decided = [_]decisions.Decision{.{
        .id = finding_list[0].id,
        .choice = "spa",
        .rationale = "client-routed",
        .artifact = null,
    }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // Migrated -- the conversion IS done -- with one edit named, because a
    // placeholder `file:` dependency is not something `bun install` can
    // resolve and nothing else in the output says so.
    try testing.expectEqual(Status.migrated, res.routes[0].status);
    try testing.expectEqualStrings("set dependencies.@z/runtime in package.json", res.routes[0].note.?);
    const pkg = try readTarget(gpa, &tmp, "package.json");
    defer gpa.free(pkg);
    try testing.expect(std.mem.indexOf(u8, pkg, "TODO-SET-RUNTIME-PATH") != null);
}

// ---- the generated build.sh has to actually RUN ---------------------------

/// Runs `bash` with `args`, returning its exit code and stdout. Skips the
/// whole test when there is no `bash` to run -- the same shape every other
/// subprocess test in this tree uses (`sidecar.zig`'s bun tests).
///
/// Contract 2 (owned-result): the returned stdout is a fresh `gpa`
/// allocation; stderr is released here.
fn runBash(gpa: Allocator, args: []const []const u8) !struct { code: u8, stdout: []u8 } {
    const r = std.process.run(gpa, std.testing.io, .{ .argv = args }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    gpa.free(r.stderr);
    errdefer gpa.free(r.stdout);
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        // A signal is not an exit code; report something non-zero rather than
        // silently reading it as success.
        else => 255,
    };
    return .{ .code = code, .stdout = r.stdout };
}

test "emitBuildSh: the emitted script parses, and each --spa reaches the binary as ONE argument" {
    const gpa = testing.allocator;
    // The regression this pins: `--spa=<src>|<base>` written UNQUOTED makes
    // the `|` a pipeline separator, so bash reads the line as
    // `... --spa=spa/posts.spa.tsx | /posts "$@"` and tries to execute a
    // command called `/posts`. With `set -o pipefail` (which the emitted
    // script sets) that is exit 127 and NO arguments ever reach the binary --
    // the generated project simply cannot build. A byte-comparison test
    // cannot see this, which is exactly why the previous ones pinned the
    // broken form green: they compared the wrong thing correctly.
    //
    // Every hand-written invocation in this repo quotes it
    // (`examples/tsx-site/build.sh`, `site/build.sh`, `docs/spa.md`).
    const script = try emitBuildSh(gpa, &.{ "spa/posts.spa.tsx", "spa/admin.spa.tsx" });
    defer gpa.free(script);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.sh", .data = script });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/build.sh", .{tmp.sub_path});
    defer gpa.free(path);

    // 1. It is a well-formed shell script at all.
    const syntax = try runBash(gpa, &.{ "bash", "-n", path });
    defer gpa.free(syntax.stdout);
    try testing.expectEqual(@as(u8, 0), syntax.code);

    // 2. The arguments survive word splitting. The `exec` line is replayed
    //    with `printf` standing in for the binary, so what is asserted is the
    //    ARGV the binary would have seen -- not the bytes of the file.
    const exec_line = lastLine(script);
    try testing.expect(std.mem.startsWith(u8, exec_line, "exec \"${ZIGAPAGOS_BIN:-zigapagos}\""));
    const tail = exec_line["exec \"${ZIGAPAGOS_BIN:-zigapagos}\"".len..];
    const program = try std.fmt.allocPrint(gpa, "set -euo pipefail\nprintf '%s\\n'{s}", .{tail});
    defer gpa.free(program);

    const replay = try runBash(gpa, &.{ "bash", "-c", program });
    defer gpa.free(replay.stdout);
    try testing.expectEqual(@as(u8, 0), replay.code);
    try testing.expectEqualStrings(
        \\release
        \\--force
        \\--output=zig-out/site
        \\--spa=spa/posts.spa.tsx|/posts
        \\--spa=spa/admin.spa.tsx|/admin
        \\
    , replay.stdout);
}

/// The last non-empty line of `s`. Contract 3 (caller-buffer): a sub-slice.
fn lastLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, s, "\n");
    const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    return trimmed[nl + 1 ..];
}

// ---- ruling S16: one view, two layouts ------------------------------------

/// Two routes rendering the SAME view, each with its own layout (`null` means
/// no layout). Returns both outcomes plus the written view file.
const SharedView = struct {
    first: Status,
    second: Status,
    first_note: ?[]u8,
    second_note: ?[]u8,
    view: []u8,
    artifact_count: usize,

    fn deinit(self: *SharedView, gpa: Allocator) void {
        if (self.first_note) |n| gpa.free(n);
        if (self.second_note) |n| gpa.free(n);
        gpa.free(self.view);
    }
};

fn scaffoldSharedView(gpa: Allocator, second_layout: ?[]const u8) !SharedView {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.yield, 1, 13, null),
        tText("</body></html>", 1),
    };
    const view_nodes = [_]fragments.Node{tText("<h1>About</h1>", 1)};
    const frags = [_]fragments.Template{
        tTemplate("app/views/layouts/application.html.erb", &layout_nodes),
        tTemplate("app/views/layouts/marketing.html.erb", &layout_nodes),
        tTemplate("app/views/pages/about.html.erb", &view_nodes),
    };
    // Sorted by path, so `/a` is the FIRST route and owns the view file.
    var rs = [_]route_mod.Route{
        tRoute("GET", "/a", "pages", "about", 2),
        tRoute("GET", "/b", "pages", "about", 3),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls, .layout = "app/views/layouts/application.html.erb" },
        .{ .templates = &tpls, .layout = second_layout },
    };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const view = try readTarget(gpa, &tmp, "layouts/pages/about.shtml");
    errdefer gpa.free(view);
    return .{
        .first = res.routes[0].status,
        .second = res.routes[1].status,
        .first_note = if (res.routes[0].note) |n| try gpa.dupe(u8, n) else null,
        .second_note = if (res.routes[1].note) |n| try gpa.dupe(u8, n) else null,
        .view = view,
        .artifact_count = res.routes[1].artifacts.len,
    };
}

test "write: two routes sharing a view under the SAME layout share its file" {
    const gpa = testing.allocator;
    // The ordinary case, unchanged by ruling S16: one view file, two content
    // pages, both finished. Writing `layouts/pages/about.shtml` twice would
    // hit the exclusive-create guard, so the dedupe is load-bearing.
    var r = try scaffoldSharedView(gpa, "app/views/layouts/application.html.erb");
    defer r.deinit(gpa);

    try testing.expectEqual(Status.migrated, r.first);
    try testing.expectEqual(Status.migrated, r.second);
    try testing.expect(r.first_note == null);
    try testing.expect(r.second_note == null);
    try testing.expect(std.mem.indexOf(u8, r.view, "application.shtml") != null);
}

test "write: the same view under a DIFFERENT layout leaves the second route open" {
    const gpa = testing.allocator;
    // Ruling S16, and the bug it closes. A view's conversion is a function of
    // its LAYOUT as well as its own nodes: the `<extend template=...>` names
    // that layout, and `layout_blocks` decides which blocks the view emits.
    // The target has ONE `layouts/pages/about.shtml`, so the second route
    // cannot have its own -- and reusing the first route's would give it an
    // `<extend>` naming the wrong parent and a block set the wrong layout
    // declares, which SuperHTML rejects outright.
    //
    // The keyed cache makes the clash visible instead: the first route (in
    // this file's route order) owns the file, the second is `open` and names
    // both layouts.
    var r = try scaffoldSharedView(gpa, "app/views/layouts/marketing.html.erb");
    defer r.deinit(gpa);

    try testing.expectEqual(Status.migrated, r.first);
    try testing.expectEqual(Status.open, r.second);
    try testing.expect(r.second_note != null);
    try testing.expectEqualStrings(
        "view shared across layouts: application vs marketing",
        r.second_note.?,
    );
    // Nothing written for the loser: no half-page pointing at a layout that
    // does not match it.
    try testing.expectEqual(@as(usize, 0), r.artifact_count);
    // And the file that IS there belongs to the first route.
    try testing.expect(std.mem.indexOf(u8, r.view, "application.shtml") != null);
}

test "write: a view under a layout, then under none, is the same clash" {
    const gpa = testing.allocator;
    // `layout false` in one controller and a layout in another is the same
    // situation with `null` on one side: a standalone view has no `<extend>`
    // at all, so the two conversions are not interchangeable either.
    var r = try scaffoldSharedView(gpa, null);
    defer r.deinit(gpa);

    try testing.expectEqual(Status.migrated, r.first);
    try testing.expectEqual(Status.open, r.second);
    try testing.expectEqualStrings(
        "view shared across layouts: application vs (none)",
        r.second_note.?,
    );
}
