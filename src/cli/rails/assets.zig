//! The asset inventory: for every `inventory.Entry` of `Kind.asset`, whether
//! its eventual public URL can be derived WITHOUT running Ruby, and what
//! that URL is when it can. std-only, see the note in detect.zig.
//!
//! The honesty rule this file exists to enforce: `deterministic: false` plus
//! a blocker naming the real reason beats a guessed `public_url` that 404s
//! in production. Every `app/assets/`-rooted asset's URL is read verbatim
//! from the pipeline's OWN compiled manifest -- Propshaft's `.manifest.json`
//! or Sprockets' `manifest-*.json` / `.sprockets-manifest-*.json`, both under
//! `public/assets/` -- never
//! derived by re-implementing a digest scheme this stage cannot verify
//! against the real gem (fix round 1: an earlier version computed a SHA-256
//! digest and called that "Propshaft's URL"; nothing here had ever checked
//! that against a real Propshaft app, so a wrong assumption about the
//! algorithm would have silently 404'd every emitted URL). A plain
//! `public/`-relative path (no pipeline involved at all) is the other
//! derivable case; anything else -- an unknown pipeline, a missing or
//! unusable compiled manifest, an asset absent from a manifest that DOES
//! exist -- is reported as exactly that, never smoothed over into a
//! plausible-looking `false` that hides which of those it actually was.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const blockers = @import("blockers.zig");
const detect = @import("detect.zig");
const inventory = @import("inventory.zig");

/// The two asset-pipeline gems the spec's manifest distinguishes. An app
/// declaring neither, or both, has no single active pipeline this stage can
/// name -- see `detectPipeline`'s doc -- so this type has no third variant
/// for "unknown"; that case is `Asset.pipeline == null` instead.
pub const Pipeline = enum { propshaft, sprockets };

pub const Asset = struct {
    /// App-relative path, gpa-owned (duped from the `inventory.Entry` this
    /// came from, which does not outlive `rails.zig`'s `discover`).
    source: []const u8,
    /// The URL this asset is served at once built, or `null` when
    /// `deterministic` is `false` -- see that field's doc. gpa-owned when
    /// present.
    public_url: ?[]const u8,
    /// The pipeline that processed this asset, or `null` when either the
    /// active pipeline itself could not be determined (`detectPipeline`
    /// returned no verdict) or this asset bypasses the pipeline entirely
    /// (a `public/`-rooted file -- see `scan`'s doc). Distinct from
    /// `deterministic == false`, which can also fire with a KNOWN pipeline
    /// (an asset absent from an otherwise-present, otherwise-usable
    /// compiled manifest, for instance).
    pipeline: ?Pipeline,
    /// Whether `public_url` was derived by a rule guaranteed to reproduce
    /// the SAME url for the SAME input, on every machine, every run --
    /// never a guess. `false` means `public_url` is `null` and a blocker on
    /// `source`'s path (see `scan`'s per-case doc comments) names the real
    /// reason it could not be derived.
    deterministic: bool,
};

/// Contract 2 counterpart to `Asset`: releases `source` and (when present)
/// `public_url`. `pipeline`/`deterministic` are plain values with nothing to
/// free.
fn freeAsset(gpa: Allocator, a: Asset) void {
    gpa.free(a.source);
    if (a.public_url) |u| gpa.free(u);
}

/// Contract 2 counterpart to `scan`: releases every `Asset`'s owned strings
/// plus the slice itself.
pub fn freeAssets(gpa: Allocator, items: []Asset) void {
    for (items) |a| freeAsset(gpa, a);
    gpa.free(items);
}

/// `detectPipeline`'s result. `unknown_reason` is set only when `pipeline`
/// is `null`, and distinguishes "neither gem declared" from "both declared"
/// for the blocker `scan` appends on each affected asset -- one code
/// (`RAILS_ASSET_PIPELINE_UNKNOWN`), two honest reasons, the same pattern
/// `inventory.appendUnsupportedEngineBlockers` already uses for Haml vs.
/// Slim.
const PipelineDetection = struct {
    pipeline: ?Pipeline,
    unknown_reason: ?[]const u8 = null,
};

/// Pure decision over the Gemfile's own declared gems (via
/// `detect.gemfileDeclares`, the same substring-safe scanner
/// `integrations.zig` uses). Contract 3 (caller-buffer): allocates nothing,
/// `unknown_reason` (when set) always points at a static string literal.
///
/// An app declaring BOTH `propshaft` and `sprockets-rails` is a real,
/// if unusual, case -- typically a mid-migration Gemfile with the old gem
/// not yet removed. Rails resolves that ambiguity at BOOT time (whichever
/// railtie initializes last effectively wins, and that depends on gem load
/// order this stage has no static access to), so guessing one over the
/// other would be exactly the false confidence this whole file exists to
/// avoid; both-declared gets the same `null` verdict as neither-declared,
/// with a reason that says which of the two it was.
fn detectPipeline(gemfile: ?[]const u8) PipelineDetection {
    const g = gemfile orelse return .{
        .pipeline = null,
        .unknown_reason = "no Gemfile was available to read",
    };
    const has_propshaft = detect.gemfileDeclares(g, "propshaft");
    const has_sprockets = detect.gemfileDeclares(g, "sprockets-rails");
    if (has_propshaft and has_sprockets) return .{
        .pipeline = null,
        .unknown_reason = "Gemfile declares both propshaft and sprockets-rails; the active asset pipeline cannot be determined statically",
    };
    if (has_propshaft) return .{ .pipeline = .propshaft };
    if (has_sprockets) return .{ .pipeline = .sprockets };
    return .{
        .pipeline = null,
        .unknown_reason = "Gemfile declares neither propshaft nor sprockets-rails",
    };
}

test "detectPipeline: propshaft alone" {
    const d = detectPipeline("gem \"propshaft\"\n");
    try std.testing.expectEqual(Pipeline.propshaft, d.pipeline.?);
    try std.testing.expectEqual(@as(?[]const u8, null), d.unknown_reason);
}

test "detectPipeline: sprockets-rails alone" {
    const d = detectPipeline("gem \"sprockets-rails\"\n");
    try std.testing.expectEqual(Pipeline.sprockets, d.pipeline.?);
}

test "detectPipeline: a commented-out gem does not count" {
    const d = detectPipeline("# gem \"propshaft\"\n");
    try std.testing.expectEqual(@as(?Pipeline, null), d.pipeline);
    try std.testing.expect(std.mem.indexOf(u8, d.unknown_reason.?, "neither") != null);
}

test "detectPipeline: neither gem declared names 'neither' in the reason" {
    const d = detectPipeline("gem \"rails\"\n");
    try std.testing.expectEqual(@as(?Pipeline, null), d.pipeline);
    try std.testing.expect(std.mem.indexOf(u8, d.unknown_reason.?, "neither") != null);
}

test "detectPipeline: both gems declared names 'both' in the reason, not 'neither'" {
    const d = detectPipeline("gem \"propshaft\"\ngem \"sprockets-rails\"\n");
    try std.testing.expectEqual(@as(?Pipeline, null), d.pipeline);
    try std.testing.expect(std.mem.indexOf(u8, d.unknown_reason.?, "both") != null);
}

test "detectPipeline: no Gemfile at all" {
    const d = detectPipeline(null);
    try std.testing.expectEqual(@as(?Pipeline, null), d.pipeline);
    try std.testing.expect(d.unknown_reason != null);
}

/// True when `name` is a file this stage recognizes as a compiled Sprockets
/// manifest: the modern defaults (`manifest-<hex>.json` and
/// `.sprockets-manifest-<hex>.json`), the simple `manifest.json` some apps pin
/// via `config.assets.manifest`, or the legacy `.sprockets-manifest.json` name
/// from Sprockets 2. Contract 3: allocates nothing.
fn isManifestCandidateName(name: []const u8) bool {
    if (std.mem.eql(u8, name, ".sprockets-manifest.json")) return true;
    if (std.mem.eql(u8, name, "manifest.json")) return true;
    const has_json_suffix = std.mem.endsWith(u8, name, ".json");
    if (!has_json_suffix) return false;
    if (std.mem.startsWith(u8, name, "manifest-")) return true;

    const hidden_prefix = ".sprockets-manifest-";
    if (!std.mem.startsWith(u8, name, hidden_prefix)) return false;
    const digest = name[hidden_prefix.len .. name.len - ".json".len];
    if (digest.len == 0) return false;
    for (digest) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

test "isManifestCandidateName only accepts digest-suffixed hidden manifests" {
    try std.testing.expect(isManifestCandidateName(".sprockets-manifest-0123456789abcdef.json"));
    try std.testing.expect(isManifestCandidateName(".sprockets-manifest-ABCDEF.json"));
    try std.testing.expect(!isManifestCandidateName(".sprockets-manifest-.json"));
    try std.testing.expect(!isManifestCandidateName(".sprockets-manifest-backup.json"));
    try std.testing.expect(!isManifestCandidateName(".sprockets-manifest-0123.json.bak"));
}

/// Finds the compiled Sprockets manifest under `public/assets/`, if any.
/// When more than one candidate exists (stale manifests from a previous
/// precompile left behind is a real occurrence), the lexicographically
/// smallest NAME wins -- an arbitrary but total, and therefore
/// deterministic, tiebreak; directory-iteration order is not something this
/// code controls or should depend on.
///
/// `null` when `public/assets/` is absent, unreadable, or contains no
/// candidate -- every one of those degrades identically to "no manifest
/// usable", which `scan`'s caller reports as `RAILS_ASSET_MANIFEST_MISSING`.
/// A read/iteration error partway through the listing is treated the same
/// way (best-effort discovery, not itself an integrity concern -- what
/// matters downstream is only whether a usable manifest was found, and
/// "found none" is already the honest, reported outcome for that case).
///
/// Contract 1 (self-freeing) -- relabeled, fix round 2 (phase-1-review.md
/// F10 / phase-1-fixes.md 1c): every intermediate `dup` this loop produces
/// (a candidate that was later beaten by a lexicographically smaller name)
/// is freed before this returns, and `best`'s own final allocation is
/// consumed to build the ONE allocation that escapes -- the
/// `"public/assets/{name}"`-formatted path below, itself a fresh
/// allocation, not `best` renamed. There is no `deinit` counterpart to call:
/// the caller releases the returned path with a plain `gpa.free`, same as
/// `scan` already does. This was mislabeled "Contract 2 (owned-result)"
/// despite matching contract 1 exactly -- the same mislabel this branch
/// already found and fixed once, in `sidecar_client.zig` (see that file's
/// module doc).
fn findSprocketsManifestPath(io: Io, gpa: Allocator, root: Io.Dir) Allocator.Error!?[]u8 {
    var dir = root.openDir(io, "public/assets", .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var best: ?[]u8 = null;
    errdefer if (best) |b| gpa.free(b);

    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch break;
        const e = entry orelse break;
        if (e.kind != .file) continue;
        if (!isManifestCandidateName(e.name)) continue;
        if (best == null or std.mem.lessThan(u8, e.name, best.?)) {
            const dup = try gpa.dupe(u8, e.name);
            if (best) |b| gpa.free(b);
            best = dup;
        }
    }

    if (best) |name| {
        // Fix round 2 (phase-1-review.md F2 / phase-1-fixes.md 1b): `name`
        // and `best` are the SAME pointer -- `best = null` here transfers
        // ownership out of `best` (so the `errdefer` above sees `null` and
        // does nothing) BEFORE the fallible `allocPrint` below runs. Without
        // this, an OOM from `allocPrint` let the inner `defer gpa.free
        // (name)` free the block, and the still-armed outer `errdefer` free
        // the SAME pointer again on the way out -- reproduced as a
        // segfault/ABRT under a `FailingAllocator` at `fail_index=1` (the
        // reviewer's repro; see the sweep test below, added alongside this
        // fix -- this file had none before, which is why two prior reviews
        // missed it).
        best = null;
        defer gpa.free(name);
        return try std.fmt.allocPrint(gpa, "public/assets/{s}", .{name});
    }
    return null;
}

/// Looks `path` (an `app/assets/`-rooted asset) up in a parsed, compiled
/// asset-pipeline manifest -- Propshaft's flat `{logical_path: digested_path}`
/// object at the manifest's TOP level (`nested_key == null`), or Sprockets'
/// `"assets"` object carrying the same shape one level down (`nested_key ==
/// "assets"`, alongside the more detailed `"files"` object this stage does
/// not need). One lookup function for both: the manifest IS the ground
/// truth for either pipeline, and the only difference between them is where
/// in the JSON tree that mapping lives.
///
/// Two candidate keys are tried, in order: `path` with the `"app/assets/"`
/// prefix stripped (e.g. `"images/admin/logo.png"`), then that same string
/// with its OWN first path segment ALSO stripped (`"admin/logo.png"`) --
/// real Sprockets configurations differ on whether `app/assets/images` etc.
/// are registered as their OWN load paths (dropping exactly that one
/// subdirectory from the logical path, but keeping everything past it) or
/// `app/assets` alone is (keeping the full relative path), and this stage
/// has no access to `config.assets.paths` to tell which; Propshaft's
/// simpler, single-load-path convention makes the first key the expected
/// hit. EITHER hit is read verbatim from a real, compiled manifest, never
/// synthesized. Returns `null` (not a guess) when neither key is present --
/// `scan`'s caller reports that as `RAILS_ASSET_DIGEST_UNAVAILABLE`.
///
/// Fix round 2 (phase-1-review.md F1 / phase-1-fixes.md 1a): this used to
/// fall back to `path`'s BARE basename instead of the load-path-relative
/// second key above. That is a materially different (and wrong) key: with
/// two assets sharing a basename in different subdirectories --
/// `app/assets/images/logo.png` and `app/assets/images/admin/logo.png`, a
/// manifest listing both `"logo.png"` and `"admin/logo.png"` as DISTINCT
/// entries -- the second asset's real key (`"admin/logo.png"`) was never
/// tried, and the basename fallback silently matched the FIRST asset's
/// entry instead, publishing its URL as the second asset's own
/// `deterministic: true` fact. The load-path-relative key above is what a
/// real Sprockets/Propshaft config can actually produce; a bare basename
/// collapsing two distinct assets to the same lookup key is not a
/// configuration this stage should ever emulate, so that fallback is gone,
/// not merely reordered.
///
/// Contract 3 (caller-buffer): allocates nothing; the returned string (when
/// non-null) BORROWS from `manifest`'s own parsed tree, valid only as long
/// as that tree is.
fn manifestLookup(manifest: std.json.Value, nested_key: ?[]const u8, path: []const u8) ?[]const u8 {
    var obj = manifest;
    if (nested_key) |k| {
        if (manifest != .object) return null;
        obj = manifest.object.get(k) orelse return null;
    }
    if (obj != .object) return null;

    const prefix = "app/assets/";
    std.debug.assert(std.mem.startsWith(u8, path, prefix));
    const rel = path[prefix.len..];

    if (obj.object.get(rel)) |v| {
        if (v == .string) return v.string;
    }
    // Only tried when `rel` actually HAS a subdirectory to strip -- a
    // top-level `app/assets/logo.png` has no first segment to drop, and
    // stripping one would silently fall through to `obj.object.get("")`
    // (or worse, an out-of-range slice) rather than a real second key.
    if (std.mem.indexOfScalar(u8, rel, '/')) |slash| {
        const load_path_relative = rel[slash + 1 ..];
        if (obj.object.get(load_path_relative)) |v| {
            if (v == .string) return v.string;
        }
    }
    return null;
}

/// Resolves one `app/assets/`-rooted asset against the pipeline's compiled
/// manifest -- the shared tail end of `buildAsset` for BOTH `Pipeline`
/// variants, differing only in `nested_key` (`manifestLookup`'s doc) and the
/// pipeline-named wording of the two blockers this can append. `source` is
/// already an owned `gpa` allocation the caller (`buildAsset`) duped and
/// will free via its own `errdefer` if this returns an error before handing
/// ownership off in the returned `Asset`.
///
/// - Manifest present and lists `e_path` -> the digested path read verbatim
///   from it, `deterministic: true`. A fact, not a guess.
/// - Manifest present but does not list `e_path` -> `RAILS_ASSET_DIGEST_
///   UNAVAILABLE` (the manifest IS usable evidence; this one asset just
///   isn't in it -- a legitimate finding, e.g. the file postdates the last
///   precompile).
/// - Manifest absent, unreadable, or unparseable -> `RAILS_ASSET_MANIFEST_
///   MISSING`, with `manifest_unusable_reason` (set by `scan`) distinguishing
///   "unreadable"/"unparseable" from the default "not found" wording when
///   set.
///
/// Contract 2 (owned-result), fix round 2 (phase-1-review.md F11 /
/// phase-1-fixes.md 1c): TAKES OWNERSHIP of `source` on entry rather than
/// borrowing it -- every returned `Asset` embeds the exact `source` value
/// passed in (never re-duped), so on a successful (non-error) return
/// ownership has moved into the result the caller releases via `freeAsset`.
/// On an `Allocator.Error` return, `source` is NOT freed here: ownership
/// reverts to `buildAsset`, whose own `errdefer gpa.free(source)` covers
/// exactly that case (this function is buildAsset's tail call, so any error
/// it returns propagates as buildAsset's own return value and arms that
/// errdefer). `public_url`, when present, is a fresh allocation this
/// function makes and also hands off inside the returned `Asset`.
fn resolveViaManifest(
    gpa: Allocator,
    source: []const u8,
    e_path: []const u8,
    pipeline: Pipeline,
    nested_key: ?[]const u8,
    manifest: ?std.json.Value,
    manifest_unusable_reason: ?[]const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error!Asset {
    if (manifest) |mv| {
        if (manifestLookup(mv, nested_key, e_path)) |digested| {
            const url = try std.fmt.allocPrint(gpa, "/assets/{s}", .{digested});
            return .{ .source = source, .public_url = url, .pipeline = pipeline, .deterministic = true };
        }
        var buf: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "asset is not listed in the compiled {s} manifest", .{@tagName(pipeline)}) catch
            "asset is not listed in the compiled manifest";
        try blockers.append(gpa, blocker_list, "RAILS_ASSET_DIGEST_UNAVAILABLE", e_path, detail, false, .warn, null, null);
        return .{ .source = source, .public_url = null, .pipeline = pipeline, .deterministic = false };
    }
    var buf: [96]u8 = undefined;
    const detail = manifest_unusable_reason orelse
        (std.fmt.bufPrint(&buf, "no compiled {s} manifest was found under public/assets/", .{@tagName(pipeline)}) catch
            "no compiled manifest was found under public/assets/");
    try blockers.append(gpa, blocker_list, "RAILS_ASSET_MANIFEST_MISSING", e_path, detail, false, .warn, null, null);
    return .{ .source = source, .public_url = null, .pipeline = pipeline, .deterministic = false };
}

/// One asset's verdict. `manifest`/`manifest_unusable_reason` describe the
/// SAME state `scan` resolved once for the whole run (see its doc) --
/// threaded in rather than re-derived per asset, since finding and reading
/// the manifest is a per-RUN cost, not a per-file one.
///
/// Contract 2 (owned-result), fix round 2 (phase-1-review.md F11 /
/// phase-1-fixes.md 1c): dupes `e.path` into its own fresh `source`
/// allocation (does NOT borrow or take ownership of anything from the
/// caller); the returned `Asset` -- `source` plus, on the deterministic
/// paths, a freshly allocated `public_url` -- is released via `freeAsset`.
fn buildAsset(
    gpa: Allocator,
    e: inventory.Entry,
    detection: PipelineDetection,
    manifest: ?std.json.Value,
    manifest_unusable_reason: ?[]const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error!Asset {
    const source = try gpa.dupe(u8, e.path);
    errdefer gpa.free(source);

    // `public/` bypasses the asset pipeline entirely: Rails (or whatever
    // serves the built site) serves these files directly at the SAME
    // relative path, no digesting or pipeline gem involved. `pipeline` is
    // `null` here on purpose, not `detection.pipeline` -- reporting a
    // pipeline for a file that pipeline never touched would be exactly the
    // "confident but wrong" story this file exists to avoid, even though a
    // pipeline gem may well be declared for the REST of the app's assets.
    if (std.mem.startsWith(u8, e.path, "public/")) {
        const url = try std.fmt.allocPrint(gpa, "/{s}", .{e.path["public/".len..]});
        return .{ .source = source, .public_url = url, .pipeline = null, .deterministic = true };
    }

    // Everything else `inventory.classify` puts in `Kind.asset` is rooted at
    // `app/assets/` (the only other rule `classify` has for this kind) --
    // asserted by every helper above rather than re-checked per call site.
    std.debug.assert(std.mem.startsWith(u8, e.path, "app/assets/"));

    if (detection.pipeline == null) {
        try blockers.append(gpa, blocker_list, "RAILS_ASSET_PIPELINE_UNKNOWN", e.path, detection.unknown_reason.?, false, .warn, null, null);
        return .{ .source = source, .public_url = null, .pipeline = null, .deterministic = false };
    }

    // Both pipelines resolve identically from here: read the compiled
    // manifest, which is ground truth, or say honestly that it couldn't be
    // consulted. Fix round 1: this used to special-case `.erb`-suffixed
    // sources (ERB preprocessing means the digest isn't known without
    // running Ruby) by short-circuiting BEFORE the pipeline switch below,
    // computing nothing for them. That special case is gone along with the
    // digest computation it was protecting: the manifest is the only source
    // of truth now, for every extension alike, and an ERB-sourced asset
    // simply won't appear under its own (pre-ERB) filename in a real
    // manifest -- `resolveViaManifest`'s "not listed" branch reports that
    // exact honest fact without needing a dedicated rule to know why.
    return switch (detection.pipeline.?) {
        .propshaft => resolveViaManifest(gpa, source, e.path, .propshaft, null, manifest, manifest_unusable_reason, blocker_list),
        .sprockets => resolveViaManifest(gpa, source, e.path, .sprockets, "assets", manifest, manifest_unusable_reason, blocker_list),
    };
}

/// Reads and parses the compiled manifest at `path`, if it exists. Shared by
/// both pipelines (`scan` calls this once, with each pipeline's own path --
/// Propshaft's fixed `public/assets/.manifest.json`, or the Sprockets
/// candidate `findSprocketsManifestPath` found).
///
/// Three outcomes, all silent about WHICH one occurred except through the
/// out-parameters: absent (`error.FileNotFound`/`NotDir`) leaves both
/// out-parameters untouched -- `resolveViaManifest`'s caller falls back to
/// its own default "not found" wording in that case; unreadable or
/// unparseable sets `unusable_reason.*` to a specific, honest explanation;
/// success sets both `parsed.*` (kept alive by the caller for the rest of
/// the run) and `value.*` (the same tree's root, for convenient reading).
/// `error.OutOfMemory` always propagates.
///
/// Contract 2 (owned-result), via an out-parameter rather than the return
/// value, fix round 2 (phase-1-review.md F11 / phase-1-fixes.md 1c): on the
/// success path, `parsed.*` receives a `std.json.Parsed(std.json.Value)`
/// that the CALLER must `.deinit()` -- this function never calls `deinit`
/// on it itself, since `value.*` (and everything `scan`/`buildAsset` read
/// out of it afterward) borrows from that same tree. `scan`'s `defer if
/// (manifest_parsed) |m| m.deinit();` is that release. `src` (the raw file
/// bytes) is this function's own scratch and is always freed here, on
/// every path, before returning -- it never escapes.
fn loadManifest(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    path: []const u8,
    parsed: *?std.json.Parsed(std.json.Value),
    value: *?std.json.Value,
    unusable_reason: *?[]const u8,
) Allocator.Error!void {
    const src = root.readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir => return,
        else => {
            unusable_reason.* = "the compiled asset manifest exists but could not be read";
            return;
        },
    };
    defer gpa.free(src);

    if (std.json.parseFromSlice(std.json.Value, gpa, src, .{})) |p| {
        parsed.* = p;
        value.* = p.value;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unusable_reason.* = "the compiled asset manifest exists but could not be parsed as JSON",
    }
}

/// Contract 2 (owned-result): every `Asset` (and its owned strings) in the
/// returned slice escapes; release with `freeAssets`. Every intermediate
/// (the found manifest path, its parsed JSON tree, per-file read buffers) is
/// released before this returns. `error.OutOfMemory` always propagates
/// without partially leaking.
///
/// One `Asset` per `entries` element with `kind == .asset`, in `entries`'
/// own order -- `inventory.walk` already sorts `entries` by path, and a
/// stable filter over a sorted sequence stays sorted, so the manifest's
/// "assets sorted by path" determinism rule (spec, "Determinism") holds
/// without a second sort here.
///
/// The active pipeline's compiled manifest is found and parsed ONCE for the
/// whole run, not once per asset -- see `loadManifest`'s doc for why a
/// missing/unreadable/malformed manifest all collapse to the same "no
/// manifest usable" story for every asset under that pipeline in this run.
/// Propshaft's manifest lives at a FIXED name (`public/assets/.manifest.json`)
/// so no search is needed; Sprockets embeds a hash in its manifest's own
/// filename, so `findSprocketsManifestPath` locates it first.
pub fn scan(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    entries: []const inventory.Entry,
    gemfile: ?[]const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error![]Asset {
    var list: std.ArrayListUnmanaged(Asset) = .empty;
    errdefer {
        for (list.items) |a| freeAsset(gpa, a);
        list.deinit(gpa);
    }

    const detection = detectPipeline(gemfile);

    var manifest_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (manifest_parsed) |m| m.deinit();
    var manifest_value: ?std.json.Value = null;
    var manifest_unusable_reason: ?[]const u8 = null;

    if (detection.pipeline) |p| switch (p) {
        .propshaft => try loadManifest(io, gpa, root, "public/assets/.manifest.json", &manifest_parsed, &manifest_value, &manifest_unusable_reason),
        .sprockets => {
            if (try findSprocketsManifestPath(io, gpa, root)) |mpath| {
                defer gpa.free(mpath);
                try loadManifest(io, gpa, root, mpath, &manifest_parsed, &manifest_value, &manifest_unusable_reason);
            }
        },
    };

    for (entries) |e| {
        if (e.kind != .asset) continue;
        const asset = try buildAsset(gpa, e, detection, manifest_value, manifest_unusable_reason, blocker_list);
        errdefer freeAsset(gpa, asset);
        try list.append(gpa, asset);
    }
    return list.toOwnedSlice(gpa);
}

fn testScan(
    tmp_dir: Io.Dir,
    entries: []const inventory.Entry,
    gemfile: ?[]const u8,
) !struct { assets: []Asset, blockers: []blockers.Blocker } {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    const items = try scan(io, gpa, tmp_dir, entries, gemfile, &blocker_list);
    return .{ .assets = items, .blockers = try blocker_list.toOwnedSlice(gpa) };
}

test "a public/ asset is always deterministic, even with no pipeline evidence at all" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "favicon.ico", .data = "ico bytes" });

    const entries = [_]inventory.Entry{
        .{ .path = "public/favicon.ico", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, null);
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 1), r.assets.len);
    try std.testing.expectEqualStrings("public/favicon.ico", r.assets[0].source);
    try std.testing.expectEqualStrings("/favicon.ico", r.assets[0].public_url.?);
    try std.testing.expectEqual(@as(?Pipeline, null), r.assets[0].pipeline);
    try std.testing.expect(r.assets[0].deterministic);
    // No pipeline evidence at all, yet no blocker: this asset never needed
    // to know the pipeline in the first place.
    try std.testing.expectEqual(@as(usize, 0), r.blockers.len);
}

test "a propshaft asset listed in its compiled manifest is a fact, not a guess" {
    // Fix round 1: an earlier version of this file computed a SHA-256
    // digest here and called that Propshaft's URL -- verified as a correct
    // SHA-256 (via `sha256sum` independently of this code), but never
    // verified as what Propshaft actually does, because Propshaft was not
    // installed to check against. That derivation is gone; this is now the
    // SAME manifest-read story the sprockets tests below already prove.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "a placeholder logo\n" });
    var man_dir = try tmp.dir.createDirPathOpen(io, "public/assets", .{});
    man_dir.close(io);
    // Propshaft's manifest is a FLAT {logical_path: digested_path} object at
    // the top level -- no "assets"/"files" nesting, unlike Sprockets'.
    try tmp.dir.writeFile(io, .{
        .sub_path = "public/assets/.manifest.json",
        .data =
        \\{"images/logo.png":"images/logo-9f86d081.png"}
        ,
    });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"propshaft\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 1), r.assets.len);
    try std.testing.expectEqualStrings("/assets/images/logo-9f86d081.png", r.assets[0].public_url.?);
    try std.testing.expectEqual(Pipeline.propshaft, r.assets[0].pipeline.?);
    try std.testing.expect(r.assets[0].deterministic);
    try std.testing.expectEqual(@as(usize, 0), r.blockers.len);
}

test "discriminate: within ONE scan, a propshaft asset listed in the manifest is deterministic and an unlisted sibling under the SAME pipeline is not" {
    // The brief's own required property: a fixture (here, a single scan
    // call) that contains BOTH outcomes. This would fail against an
    // implementation that hardcodes `deterministic = true` (the unlisted
    // asset would wrongly read true) AND against one that hardcodes `false`
    // (the listed asset would wrongly read false) -- only a real per-asset
    // manifest lookup passes both halves.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    idir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "a placeholder logo\n" });
    var sdir = try tmp.dir.createDirPathOpen(io, "app/assets/stylesheets", .{});
    sdir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/stylesheets/application.css.erb", .data = ".logo { background: url(<%= asset_path('logo.png') %>); }\n" });
    var man_dir = try tmp.dir.createDirPathOpen(io, "public/assets", .{});
    man_dir.close(io);
    // Only logo.png is listed -- application.css.erb legitimately never
    // appears under its own (pre-ERB) source filename in a real compiled
    // manifest, so this is also the realistic shape of that case, not just
    // a convenient test fixture.
    try tmp.dir.writeFile(io, .{
        .sub_path = "public/assets/.manifest.json",
        .data =
        \\{"images/logo.png":"images/logo-9f86d081.png"}
        ,
    });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
        .{ .path = "app/assets/stylesheets/application.css.erb", .kind = .asset, .engine = .erb },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"propshaft\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 2), r.assets.len);
    try std.testing.expect(r.assets[0].deterministic);
    try std.testing.expectEqualStrings("/assets/images/logo-9f86d081.png", r.assets[0].public_url.?);
    try std.testing.expect(!r.assets[1].deterministic);
    try std.testing.expectEqual(@as(?[]const u8, null), r.assets[1].public_url);
    // Both still carry the SAME known pipeline -- the unlisted asset's
    // non-determinism is about the manifest not naming it, not about
    // pipeline detection.
    try std.testing.expectEqual(Pipeline.propshaft, r.assets[1].pipeline.?);

    try std.testing.expectEqual(@as(usize, 1), r.blockers.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_DIGEST_UNAVAILABLE", r.blockers[0].code);
    try std.testing.expectEqualStrings("app/assets/stylesheets/application.css.erb", r.blockers[0].path);
    try std.testing.expect(!r.blockers[0].integrity);
    try std.testing.expectEqual(blockers.Severity.warn, r.blockers[0].severity);
    try std.testing.expect(std.mem.indexOf(u8, r.blockers[0].detail, "not listed") != null);
}

test "propshaft pipeline with no compiled manifest present: RAILS_ASSET_MANIFEST_MISSING" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "x" });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"propshaft\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 1), r.assets.len);
    try std.testing.expect(!r.assets[0].deterministic);
    try std.testing.expectEqual(@as(?[]const u8, null), r.assets[0].public_url);
    try std.testing.expectEqual(Pipeline.propshaft, r.assets[0].pipeline.?);
    try std.testing.expectEqual(@as(usize, 1), r.blockers.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_MANIFEST_MISSING", r.blockers[0].code);
}

test "an unreadable propshaft manifest degrades to non-deterministic with a blocker, not a build failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "x" });
    // A directory named exactly like the manifest file forces a read
    // failure deterministically (same trick detect.zig's own "unreadable
    // Gemfile" test uses), instead of relying on platform permission-bit
    // enforcement -- this exercises `loadManifest`'s "could not be read"
    // branch, distinct from "absent" (tested above) and "malformed"
    // (already covered on the sprockets side, same shared function).
    var man_dir = try tmp.dir.createDirPathOpen(io, "public/assets/.manifest.json", .{});
    man_dir.close(io);

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"propshaft\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 1), r.assets.len);
    try std.testing.expect(!r.assets[0].deterministic);
    try std.testing.expectEqual(@as(?[]const u8, null), r.assets[0].public_url);
    try std.testing.expectEqual(@as(usize, 1), r.blockers.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_MANIFEST_MISSING", r.blockers[0].code);
    try std.testing.expect(std.mem.indexOf(u8, r.blockers[0].detail, "could not be read") != null);
}

test "no pipeline gem declared: every app/assets entry is non-deterministic with RAILS_ASSET_PIPELINE_UNKNOWN, detail says 'neither'" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "x" });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"rails\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 1), r.assets.len);
    try std.testing.expect(!r.assets[0].deterministic);
    try std.testing.expectEqual(@as(?Pipeline, null), r.assets[0].pipeline);
    try std.testing.expectEqual(@as(usize, 1), r.blockers.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_PIPELINE_UNKNOWN", r.blockers[0].code);
    try std.testing.expect(std.mem.indexOf(u8, r.blockers[0].detail, "neither") != null);
}

test "both propshaft and sprockets-rails declared: the SAME RAILS_ASSET_PIPELINE_UNKNOWN code fires, detail says 'both'" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "x" });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"propshaft\"\ngem \"sprockets-rails\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 1), r.blockers.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_PIPELINE_UNKNOWN", r.blockers[0].code);
    try std.testing.expect(std.mem.indexOf(u8, r.blockers[0].detail, "both") != null);
}

test "sprockets pipeline with no compiled manifest present: RAILS_ASSET_MANIFEST_MISSING" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "x" });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"sprockets-rails\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 1), r.assets.len);
    try std.testing.expect(!r.assets[0].deterministic);
    try std.testing.expectEqual(Pipeline.sprockets, r.assets[0].pipeline.?);
    try std.testing.expectEqual(@as(usize, 1), r.blockers.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_MANIFEST_MISSING", r.blockers[0].code);
}

test "sprockets pipeline with a compiled manifest present: the asset's real digested path is read, not guessed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "x" });
    var man_dir = try tmp.dir.createDirPathOpen(io, "public/assets", .{});
    man_dir.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "public/assets/manifest-abc123.json",
        .data =
        \\{"files":{},"assets":{"images/logo.png":"images/logo-deadbeef1234.png"}}
        ,
    });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"sprockets-rails\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 1), r.assets.len);
    try std.testing.expect(r.assets[0].deterministic);
    try std.testing.expectEqualStrings("/assets/images/logo-deadbeef1234.png", r.assets[0].public_url.?);
    try std.testing.expectEqual(@as(usize, 0), r.blockers.len);
}

test "a digest-suffixed hidden sprockets manifest is discovered and classified deterministically" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_dir = try tmp.dir.createDirPathOpen(io, "app/assets/stylesheets", .{});
    source_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/stylesheets/application.css", .data = "body {}\n" });
    var public_dir = try tmp.dir.createDirPathOpen(io, "public/assets", .{});
    public_dir.close(io);
    // A stale, lexicographically later candidate must not make discovery
    // depend on directory iteration order. Create it first so a regressed
    // "first candidate wins" implementation cannot pass on creation-ordered
    // filesystems by accident.
    try tmp.dir.writeFile(io, .{
        .sub_path = "public/assets/.sprockets-manifest-fedcba9876543210.json",
        .data =
        \\{"files":{},"assets":{"application.css":"application-stale.css"}}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "public/assets/.sprockets-manifest-0123456789abcdef.json",
        .data =
        \\{"files":{},"assets":{"application.css":"application-0123456789abcdef.css"}}
        ,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "public/assets/application-0123456789abcdef.css", .data = "body {}\n" });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/stylesheets/application.css", .kind = .asset, .engine = .none },
        .{ .path = "public/assets/.sprockets-manifest-0123456789abcdef.json", .kind = .asset, .engine = .none },
        .{ .path = "public/assets/application-0123456789abcdef.css", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"sprockets-rails\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 3), r.assets.len);
    try std.testing.expectEqual(@as(usize, 0), r.blockers.len);

    try std.testing.expect(r.assets[0].deterministic);
    try std.testing.expectEqual(Pipeline.sprockets, r.assets[0].pipeline.?);
    try std.testing.expectEqualStrings("/assets/application-0123456789abcdef.css", r.assets[0].public_url.?);

    try std.testing.expect(r.assets[1].deterministic);
    try std.testing.expectEqual(@as(?Pipeline, null), r.assets[1].pipeline);
    try std.testing.expectEqualStrings("/assets/.sprockets-manifest-0123456789abcdef.json", r.assets[1].public_url.?);

    try std.testing.expect(r.assets[2].deterministic);
    try std.testing.expectEqual(@as(?Pipeline, null), r.assets[2].pipeline);
    try std.testing.expectEqualStrings("/assets/application-0123456789abcdef.css", r.assets[2].public_url.?);
}

test "sprockets manifest present but this asset is not listed in it: RAILS_ASSET_DIGEST_UNAVAILABLE, not a false MANIFEST_MISSING" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/new-icon.png", .data = "x" });
    var man_dir = try tmp.dir.createDirPathOpen(io, "public/assets", .{});
    man_dir.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "public/assets/manifest-abc123.json",
        .data =
        \\{"files":{},"assets":{"images/logo.png":"images/logo-deadbeef1234.png"}}
        ,
    });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/new-icon.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"sprockets-rails\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 1), r.assets.len);
    try std.testing.expect(!r.assets[0].deterministic);
    try std.testing.expectEqual(@as(usize, 1), r.blockers.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_DIGEST_UNAVAILABLE", r.blockers[0].code);
    try std.testing.expect(std.mem.indexOf(u8, r.blockers[0].detail, "not listed") != null);
}

test "sprockets manifest lookup falls back to the load-path-relative key when the app/assets/-relative one is absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "x" });
    var man_dir = try tmp.dir.createDirPathOpen(io, "public/assets", .{});
    man_dir.close(io);
    // Only the load-path-relative key is present (`"logo.png"`, not
    // `"images/logo.png"`) -- the convention where app/assets/images/ is
    // its own registered load path. For a single-subdirectory asset like
    // this one, that key happens to equal the bare basename too -- see the
    // sibling discriminating test below for the case that tells the two
    // apart.
    try tmp.dir.writeFile(io, .{
        .sub_path = "public/assets/manifest-abc123.json",
        .data =
        \\{"files":{},"assets":{"logo.png":"logo-cafef00d.png"}}
        ,
    });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"sprockets-rails\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expect(r.assets[0].deterministic);
    try std.testing.expectEqualStrings("/assets/logo-cafef00d.png", r.assets[0].public_url.?);
}

test "discriminate: two assets sharing a basename in different subdirectories resolve to their OWN distinct manifest entries, never a sibling's" {
    // phase-1-review.md F1's exact reproduction: a basename-only fallback
    // would silently match `admin/logo.png` to `logo.png`'s manifest entry
    // (or vice versa) because both files share the basename "logo.png".
    // The correct key for EACH asset is present in the SAME manifest under
    // its own load-path-relative name; a wrong implementation here (a bare
    // basename fallback, or any lookup that ignores the subdirectory past
    // the first) makes both assets resolve to the SAME url, deterministic
    // true, with no blocker -- a fact-shaped value that is simply wrong for
    // one of the two files.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    idir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "top-level logo" });
    var adir = try tmp.dir.createDirPathOpen(io, "app/assets/images/admin", .{});
    adir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/admin/logo.png", .data = "admin logo" });
    var man_dir = try tmp.dir.createDirPathOpen(io, "public/assets", .{});
    man_dir.close(io);
    // Both real, load-path-relative keys present, as a genuine compiled
    // manifest would have after `images/` is registered as its own load
    // path: the top-level asset drops "images/" and keeps nothing else
    // ("logo.png"); the nested one drops "images/" and keeps "admin/"
    // ("admin/logo.png"). Neither is the other's basename-only key.
    try tmp.dir.writeFile(io, .{
        .sub_path = "public/assets/manifest-abc123.json",
        .data =
        \\{"files":{},"assets":{"logo.png":"logo-AAAAAAAAAAAA.png","admin/logo.png":"admin/logo-BBBBBBBBBBBB.png"}}
        ,
    });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/admin/logo.png", .kind = .asset, .engine = .none },
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"sprockets-rails\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 2), r.assets.len);
    for (r.assets) |a| {
        try std.testing.expect(a.deterministic);
        if (std.mem.eql(u8, a.source, "app/assets/images/admin/logo.png")) {
            try std.testing.expectEqualStrings("/assets/admin/logo-BBBBBBBBBBBB.png", a.public_url.?);
        } else if (std.mem.eql(u8, a.source, "app/assets/images/logo.png")) {
            try std.testing.expectEqualStrings("/assets/logo-AAAAAAAAAAAA.png", a.public_url.?);
        } else {
            return error.UnexpectedAssetSource;
        }
    }
    // Every asset resolved from a real manifest entry -- no blocker on
    // either.
    try std.testing.expectEqual(@as(usize, 0), r.blockers.len);
}

test "a malformed sprockets manifest degrades to RAILS_ASSET_MANIFEST_MISSING with a parse-specific reason, not a crash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "x" });
    var man_dir = try tmp.dir.createDirPathOpen(io, "public/assets", .{});
    man_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "public/assets/manifest-abc123.json", .data = "{not valid json" });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"sprockets-rails\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expect(!r.assets[0].deterministic);
    try std.testing.expectEqual(@as(usize, 1), r.blockers.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_MANIFEST_MISSING", r.blockers[0].code);
    try std.testing.expect(std.mem.indexOf(u8, r.blockers[0].detail, "parsed") != null);
}

test "non-.asset entries are skipped entirely -- scan is not a second inventory walk" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]inventory.Entry{
        .{ .path = "app/controllers/posts_controller.rb", .kind = .controller, .engine = .none },
        .{ .path = "app/views/posts/show.html.erb", .kind = .view, .engine = .erb },
    };
    const r = try testScan(tmp.dir, &entries, "gem \"propshaft\"\n");
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 0), r.assets.len);
    try std.testing.expectEqual(@as(usize, 0), r.blockers.len);
}

test "scan preserves entries' own (already-sorted) order -- assets sorted by path per the manifest's determinism rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "public", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "public/a.ico", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "public/z.ico", .data = "z" });

    // Deliberately pre-sorted, matching what `inventory.walk` guarantees --
    // this test is about `scan` preserving order, not re-sorting it.
    const entries = [_]inventory.Entry{
        .{ .path = "public/a.ico", .kind = .asset, .engine = .none },
        .{ .path = "public/z.ico", .kind = .asset, .engine = .none },
    };
    const r = try testScan(tmp.dir, &entries, null);
    defer freeAssets(gpa, r.assets);
    defer blockers.free(gpa, r.blockers);

    try std.testing.expectEqual(@as(usize, 2), r.assets.len);
    try std.testing.expectEqualStrings("public/a.ico", r.assets[0].source);
    try std.testing.expectEqualStrings("public/z.ico", r.assets[1].source);
}

test "scan: an OOM at any point (including inside findSprocketsManifestPath) leaks nothing and never double-frees" {
    // Fix round 2 (phase-1-review.md F2 / F14 / phase-1-fixes.md 1b): this
    // file shipped with no FailingAllocator sweep at all -- unlike every
    // OTHER new file on this branch (`rails.zig`'s `classifyRoutes`/
    // `transitiveScan` sweep, `controllers.zig`'s `decodeResponse` sweep) --
    // which is exactly why the double free in `findSprocketsManifestPath`
    // (fixed above) survived two per-task reviews. One Sprockets manifest
    // candidate, matching the reviewer's own repro exactly (a
    // `FailingAllocator` at `fail_index=1` against a directory containing a
    // single `public/assets/manifest-abc123.json` segfaulted before the
    // fix): `zig build test-rails` under this sweep is what would have
    // caught it as a hard crash rather than a leak report, since a
    // double-free is undefined behavior, not a Zig-detected leak.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "app/assets/images", .{});
    dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/assets/images/logo.png", .data = "x" });
    var man_dir = try tmp.dir.createDirPathOpen(io, "public/assets", .{});
    man_dir.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "public/assets/manifest-abc123.json",
        .data =
        \\{"files":{},"assets":{"images/logo.png":"images/logo-deadbeef1234.png"}}
        ,
    });

    const entries = [_]inventory.Entry{
        .{ .path = "app/assets/images/logo.png", .kind = .asset, .engine = .none },
    };

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();

        var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
        defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

        if (scan(io, gpa, tmp.dir, &entries, "gem \"sprockets-rails\"\n", &blocker_list)) |result| {
            // Freed via `std.testing.allocator` directly, not `gpa` (the
            // FailingAllocator wrapper) -- same reasoning as the sibling
            // sweep tests in `rails.zig`/`controllers.zig`: by the time
            // this branch runs, `fail_index` is past every allocation this
            // call makes.
            defer freeAssets(std.testing.allocator, result);
            try std.testing.expectEqual(@as(usize, 1), result.len);
            try std.testing.expect(result[0].deterministic);
            try std.testing.expectEqualStrings("/assets/images/logo-deadbeef1234.png", result[0].public_url.?);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
