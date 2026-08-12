//! The derive job (#132): cache-or-compute each planned variant.
//!
//! Cache protocol: `.zigapagos-cache/images/<variant-basename>` — the name
//! is param-addressed (plan.variantBasename), so existence IS validity and
//! there is no invalidation logic to get wrong. Writes go through a
//! `.tmp.<job-id>.<basename>` sibling + rename so a killed build can never
//! leave a half-written file under a valid name. No eviction in v1
//! (documented).
//!
//! Failure policy (spec §7): by now the render pass has already emitted
//! URLs for these variants, so any failure is a broken <picture> in
//! shipped HTML — fatal, never silent. (Contrast src/wuffs.zig's probe.)
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fatal = @import("../fatal.zig");
// NOTE: this file is imported ONLY from worker.zig/root.zig (exe graph);
// it is not part of the test-images module root (src/image/tests.zig never
// imports it), so the upward imports of fatal.zig/Build.zig/PathTable.zig
// below are legal here — the standalone suite covers decode/resample/plan,
// and tests/images/*.sh covers this orchestration end-to-end.
const Build = @import("../Build.zig");
const PathTable = @import("../PathTable.zig");
const PathName = PathTable.PathName;
const Path = PathTable.Path;
const StringTable = @import("../StringTable.zig");
const plan = @import("plan.zig");
const decode = @import("decode.zig");
const resample = @import("resample.zig");
const webp = @import("webp.zig");
const png = @import("png.zig");

/// Payload for `worker.Job.image_derive`, named here rather than inline in
/// the union so `run`'s signature below can be a concrete type instead of
/// `anytype`.
pub const Job = struct {
    progress: std.Progress.Node,
    build: *const Build,
    ref: plan.SourceRef,
    planned: *const plan.Planned,
    cache_dir: Io.Dir,
    /// Where finished variants land: `site_assets_install_dir` for `.site`
    /// refs, `build.mode.disk.output_dir` for `.page` refs — decided by the
    /// scheduling loop in root.zig, which already has both computed.
    output_dir: Io.Dir,
};

/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1) — source
/// bytes, decoded image data, resampled image, WebP-encoded output, and (for
/// AVIF variants) the interchange PNG bytes and its temp file are all
/// freed/deleted within the call. The AVIF temp file spawned through the
/// external encoder is not freed but consumed: it's renamed straight into
/// the cache as the derived variant, the same way `writeCacheAtomic`'s own
/// tmp file becomes the WebP cache entry rather than being deleted after.
/// Writes derived variant files as a side effect.
pub fn run(io: Io, gpa: Allocator, d: Job) void {
    const build = d.build;

    // Resolve source dir + relative path — shared with planImageVariants via
    // `Build.resolveImageSourceRef` (#147: this used to be a copy-pasted
    // `switch (d.ref.kind)`, a "must-agree pair that nothing pins" — see
    // that method's doc comment for why a divergence here is dangerous).
    const resolved = build.resolveImageSourceRef(d.ref);
    const dir: Io.Dir = resolved.dir;
    const st: *const StringTable = resolved.st;
    const pt: *const PathTable = resolved.pt;
    const pn: PathName = .{
        .path = @enumFromInt(d.ref.path),
        .name = @enumFromInt(d.ref.name),
    };
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = std.fmt.bufPrint(&path_buf, "{f}", .{
        pn.fmt(st, pt, null, "/"),
    }) catch unreachable;

    // Locale prefix for page assets on a multilingual site — mirrors
    // `Variant.installAssets` and the `--summary` collector block in
    // root.zig (`{s}{s}{f}` with `output_path_prefix` first). Site assets
    // carry no such per-file prefix: the multilingual `assets_prefix_path`
    // is instead baked into `d.output_dir` itself by the scheduling loop.
    const output_path_prefix: []const u8 = switch (d.ref.kind) {
        .site => "",
        .page => build.variants[d.ref.variant_id].output_path_prefix,
    };

    // Destination path inside the output tree: the source's own directory
    // (locale-prefixed for page assets) with the basename swapped for the
    // variant's param-addressed name. Computed fresh per variant below.
    //
    // Wider than `max_path_bytes` by exactly what a variant basename adds
    // over the ORIGINAL basename it replaces (`plan.max_basename_growth`;
    // mirrors `root.zig`'s own `max_path_bytes + 1 + fingerprint.hash_len`
    // sizing for its fingerprinted-asset dest buffer, one screen away from
    // that file's install phase). `prefix + directory + ORIGINAL name`
    // already fits `max_path_bytes` — see `Variant.installAssets`'s own
    // identically-sized `buf`, whose `catch unreachable` this bound keeps
    // sound by construction rather than by coincidence — so swapping the
    // original name for a PROVABLY LONGER variant basename can only push
    // the total past that bound by `max_basename_growth`, never more.
    var dest_buf: [std.fs.max_path_bytes + plan.max_basename_growth]u8 = undefined;

    const Decoded = struct {
        img: decode.Decoded,
        /// Whether `img` came from a PNG source, decided from the SOURCE
        /// BYTES' magic number (`plan.isPng`) — never from `rel`'s
        /// extension. `variantBasename` hashes bytes, not filenames, so a
        /// filename-derived choice here could pick a DIFFERENT encode for
        /// two byte-identical sources filed under different extensions,
        /// even though they share one cache basename (#132 task-7 review
        /// finding — see `writeCacheAtomic`'s doc comment for why the
        /// shared-basename race depends on the encode being a pure
        /// function of bytes+params).
        lossless: bool,
    };
    var decoded: ?Decoded = null;
    defer if (decoded) |ds| ds.img.deinit(gpa);

    // Lazily resolved on the first AVIF miss and reused for the rest of
    // this job — see the `cache_dir_abs == null` check in the `.avif` arm
    // below for why (#147, Task 12 follow-up).
    var cache_dir_abs: ?[]const u8 = null;
    var cache_dir_abs_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Variants are grouped ADJACENT per width — webp, then an optional avif
    // at the SAME width (`plan.Planned.variants`' doc comment commits to
    // this order, and `planImageVariants` builds it that way on purpose).
    // A single forward scan can therefore find each width's run and
    // resample ONCE per run, feeding whichever codecs in it are cache
    // misses (Task 12: before AVIF, one variant WAS one codec at one width,
    // so resample-per-variant and resample-per-width were the same thing;
    // now they're not, and re-resampling per codec would silently double
    // the resample cost the moment avif_encoder is set).
    var i: usize = 0;
    while (i < d.planned.variants.len) {
        const width = d.planned.variants[i].width;
        var j = i;
        while (j < d.planned.variants.len and d.planned.variants[j].width == width) : (j += 1) {}
        const group = d.planned.variants[i..j];
        i = j;

        var resampled: ?[]u8 = null;
        defer if (resampled) |r| gpa.free(r);

        for (group) |variant| {
            const dest = destPath(&dest_buf, output_path_prefix, st, pt, pn.path, variant.basename);

            // Cache hit: stat-compare copy into the output tree and move on.
            // `updateFile` opens `variant.basename` in `d.cache_dir` first, so
            // a miss surfaces as `error.FileNotFound` from that open — the
            // same error a genuinely-missing dest directory could never
            // produce here (updateFile creates dest dirs as needed), so the
            // switch below is unambiguous.
            if (d.cache_dir.updateFile(io, variant.basename, d.output_dir, dest, .{})) |_| {
                continue;
            } else |err| switch (err) {
                error.FileNotFound => {}, // miss: fall through and compute
                // Name the SOURCE (`rel`), not `variant.basename` — the
                // param-addressed cache key is meaningless to the author who
                // wrote `rel`, and spec §7 asks failures to name what they
                // know about (#147; matches this function's own source-read
                // failure a few lines below, and root.zig's, both keyed on
                // `rel`).
                else => fatal.file(rel, err),
            }

            // Miss: decode the source once for all missed variants in this job.
            if (decoded == null) {
                const bytes = dir.readFileAlloc(io, rel, gpa, plan.max_source_bytes) catch |err|
                    fatal.msg("error: image_optimize: cannot read '{s}': {s}\n", .{ rel, @errorName(err) });
                defer gpa.free(bytes);
                // Decided from BYTES before they're freed, not from `rel`'s
                // extension — see the `Decoded.lossless` field doc comment.
                const lossless = plan.isPng(bytes);
                const img = decode.decode(gpa, bytes) catch |err|
                    fatal.msg("error: image_optimize: cannot decode '{s}': {s}\n", .{ rel, @errorName(err) });
                decoded = .{ .img = img, .lossless = lossless };
            }
            const state = decoded.?;
            const img = state.img;

            // Miss on THIS width: resample once, shared by every codec in
            // `group` that turns out to be a miss too.
            if (resampled == null) {
                // 1:1 short-circuit (#147): when no configured width
                // survives `plan.pickWidths`, it falls back to the source's
                // own intrinsic width — the COMMON case for anything
                // narrower than the smallest configured width, and more so
                // now that AVIF can double the work per width. Even at true
                // 1:1 scale, `resample.resize` is NOT a lossless identity:
                // it premultiplies by alpha and un-premultiplies on the way
                // out, a round trip `resample.zig`'s own identity-case unit
                // test documents as ±1-per-channel lossy (see its "Opaque
                // alpha so premultiply round-trip is exact" comment — the
                // test only uses opaque pixels BECAUSE non-opaque ones
                // aren't exact); and it hard-zeroes RGB wherever alpha
                // rounds to 0 (`if (a <= 0.0) @memset(out[dp..dp+4], 0)`),
                // which discards whatever RGB the source actually stored
                // under full transparency. Copying the decoded pixels
                // straight through instead reproduces the source EXACTLY in
                // both respects — no quantization loss, and no zeroing of
                // "invisible" RGB — so this is strictly MORE faithful to
                // the source than the path it replaces, not merely cheaper.
                // Nothing pins the resulting bytes (checked: no snapshot or
                // e2e compares them, only structural/magic-byte/name-shape
                // properties), and on the two fixtures this was verified
                // against — including one with varied alpha — the change
                // happened to compare identical AS ENCODED (WebP lossless
                // encoding normalizes RGB under transparent pixels by
                // default, which is why an encoded-bytes comparison can't
                // observe the very case this short-circuit fixes; it does
                // not mean the two pixel buffers were pixel-identical
                // inputs to the encoder). The cache basename is unaffected
                // either way — it hashes source bytes and transform
                // PARAMETERS (`plan.variantBasename`), never the encoder's
                // output.
                resampled = if (variant.width == img.w and variant.height == img.h)
                    gpa.dupe(u8, img.rgba) catch fatal.oom()
                else
                    resample.resize(gpa, img.w, img.h, img.rgba, variant.width, variant.height) catch fatal.oom();
            }
            const small = resampled.?;

            switch (variant.codec) {
                .webp => {
                    // PNG sources -> lossless; photographic -> lossy at cfg quality.
                    var out: ?[*]u8 = null;
                    defer webp.WebPFree(out);
                    const n = if (state.lossless)
                        webp.WebPEncodeLosslessRGBA(small.ptr, @intCast(variant.width), @intCast(variant.height), @intCast(variant.width * 4), &out)
                    else
                        webp.WebPEncodeRGBA(small.ptr, @intCast(variant.width), @intCast(variant.height), @intCast(variant.width * 4), quality(build), &out);
                    if (n == 0) fatal.msg("error: image_optimize: WebP encode failed for '{s}' at {d}px\n", .{ rel, variant.width });

                    writeCacheAtomic(io, d.cache_dir, d.ref, variant.basename, out.?[0..n]) catch |err|
                        fatal.msg("error: image_optimize: cannot write cache entry '{s}': {s}\n", .{ variant.basename, @errorName(err) });
                },
                .avif => {
                    // planImageVariants only mints `.avif` variants when this
                    // is set — see its `has_avif` gate — so `.?` here can
                    // never actually fire.
                    const avif_encoder = build.cfg.getImageOptimize().?.avif_encoder.?;
                    // Resolve the cache dir to absolute at most ONCE PER
                    // JOB, not once per AVIF variant (#147): a job with
                    // several missed widths used to re-resolve it on every
                    // one, even though it is per-job invariant — this makes
                    // encodeAvif's own "resolve once" comment literally
                    // true instead of aspirational.
                    if (cache_dir_abs == null) {
                        const n = d.cache_dir.realPathFile(io, ".", &cache_dir_abs_buf) catch |err|
                            fatal.msg("error: image_optimize: cannot resolve the image cache dir: {s}\n", .{@errorName(err)});
                        cache_dir_abs = cache_dir_abs_buf[0..n];
                    }
                    encodeAvif(io, gpa, d.cache_dir, cache_dir_abs.?, d.ref, rel, variant, small, avif_encoder);
                },
            }
            // Same naming rationale as the cache-hit copy above (#147):
            // name the source, not the internal cache key.
            _ = d.cache_dir.updateFile(io, variant.basename, d.output_dir, dest, .{}) catch |err|
                fatal.file(rel, err);
        }
    }
}

/// Encode one AVIF variant by shelling out to the external encoder the site
/// opted into (`ImageOptimize.avif_encoder`; #132 Task 12 — the one path in
/// this pipeline that isn't in-process, which is exactly why it's opt-in).
///
/// Writes the resampled pixels as an interchange PNG (`png.zig`) — the
/// encoder shells out and reads a file path, so the pixels need a
/// container, not a codec choice — spawns
/// `<avif_encoder> <tmp.png> <tmp.avif>`, and renames the encoder's output
/// straight into the cache under `variant.basename`. That rename IS the
/// atomic cache write (no separate `writeCacheAtomic` round trip reading the
/// bytes back into memory first): the bytes are already sitting in a file
/// inside `cache_dir` under a job-unique tmp name, so renaming it onto the
/// param-addressed basename is exactly as atomic as `writeCacheAtomic`'s own
/// tmp+rename, just without the redundant read.
///
/// Failure policy (spec §6): the user explicitly opted in by naming a
/// binary, so a missing binary or a nonzero exit is `fatal.msg` — never a
/// silent fall-back to webp-only — naming the binary, the source, and (for
/// a nonzero exit) the exit code.
///
/// NO_SLOP §2.2a contract 1 (self-freeing): the encoded PNG bytes and both
/// temp files are gone before returning; the only thing that escapes is the
/// renamed-into-place cache entry itself.
fn encodeAvif(
    io: Io,
    gpa: Allocator,
    cache_dir: Io.Dir,
    // Cache dir, pre-resolved to an absolute path by the caller (#147: used
    // to be re-resolved via `realPathFile` on every call — once per AVIF
    // variant — even though it is invariant for the whole job; the caller
    // now resolves it at most once per job and passes it in). Borrowed, not
    // owned: this function's own allocator contract (below) is unaffected.
    cache_dir_abs: []const u8,
    ref: plan.SourceRef,
    rel: []const u8,
    variant: plan.Variant,
    pixels: []const u8,
    avif_encoder: []const u8,
) void {
    const png_bytes = png.write(gpa, variant.width, variant.height, pixels) catch fatal.oom();
    defer gpa.free(png_bytes);

    // Tmp names unique PER JOB (ref-keyed), mirroring `writeCacheAtomic`'s
    // own tmp-naming discipline below — see its doc comment for why two
    // concurrent jobs whose bytes+params coincide must never share a tmp
    // inode even though they may both rename onto the same final cache
    // entry.
    var tmp_png_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_png = tmpName(&tmp_png_buf, ref, variant.basename, ".png");
    var tmp_avif_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_avif = tmpName(&tmp_avif_buf, ref, variant.basename, ".avif");

    {
        const f = cache_dir.createFile(io, tmp_png, .{}) catch |err|
            fatal.msg("error: image_optimize: cannot write AVIF temp input for '{s}': {s}\n", .{ rel, @errorName(err) });
        defer f.close(io);
        var fw = f.writer(io, &.{});
        fw.interface.writeAll(png_bytes) catch |err|
            fatal.msg("error: image_optimize: cannot write AVIF temp input for '{s}': {s}\n", .{ rel, @errorName(err) });
    }
    // Best-effort cleanup: a failed delete (already gone, permissions) just
    // leaves an inert `.tmp.*` file — nothing ever reads one, so this is the
    // same class of harmless leftover docs/images.md's Cache section
    // documents for the `fatal.msg`-mid-encode case (a `noreturn` fatal
    // skips `defer`s entirely, which is the more common way a `.tmp.*` file
    // survives), not a real bug to surface (#147).
    defer cache_dir.deleteFile(io, tmp_png) catch {};

    const png_abs = std.fs.path.join(gpa, &.{ cache_dir_abs, tmp_png }) catch fatal.oom();
    defer gpa.free(png_abs);
    const avif_abs = std.fs.path.join(gpa, &.{ cache_dir_abs, tmp_avif }) catch fatal.oom();
    defer gpa.free(avif_abs);

    var child = std.process.spawn(io, .{
        .argv = &.{ avif_encoder, png_abs, avif_abs },
        .stderr = .inherit, // surface the encoder's own diagnostics in the build log
    }) catch |err| fatal.msg(
        "error: image_optimize: failed to spawn AVIF encoder '{s}' for '{s}': {s}\n" ++
            "note: ensure the binary named in avif_encoder is installed and on PATH (or set it to an explicit path)\n",
        .{ avif_encoder, rel, @errorName(err) },
    );

    const term = child.wait(io) catch |err| fatal.msg(
        "error: image_optimize: AVIF encoder '{s}' for '{s}' failed: {s}\n",
        .{ avif_encoder, rel, @errorName(err) },
    );
    switch (term) {
        .exited => |code| if (code != 0) fatal.msg(
            "error: image_optimize: AVIF encoder '{s}' for '{s}' exited with code {d}\n",
            .{ avif_encoder, rel, code },
        ),
        else => fatal.msg(
            "error: image_optimize: AVIF encoder '{s}' for '{s}' terminated abnormally\n",
            .{ avif_encoder, rel },
        ),
    }

    // A zero exit does not prove the encoder wrote anything: a wrapper script
    // with its arguments reversed, or one that writes to a path of its own
    // choosing, exits 0 and leaves `tmp_avif` absent. That surfaces here as a
    // bare `FileNotFound` naming a cache entry the user never heard of, so
    // this arm says what actually went wrong instead.
    cache_dir.rename(tmp_avif, cache_dir, variant.basename, io) catch |err| switch (err) {
        error.FileNotFound => fatal.msg(
            "error: image_optimize: AVIF encoder '{s}' exited 0 without writing its output file for '{s}'\n" ++
                "note: zigapagos invokes it as `{s} <input.png> <output.avif>`; it must write the second argument\n",
            .{ avif_encoder, rel, avif_encoder },
        ),
        else => fatal.msg(
            "error: image_optimize: cannot install AVIF cache entry '{s}' for '{s}': {s}\n",
            .{ variant.basename, rel, @errorName(err) },
        ),
    };
}

fn quality(build: *const Build) f32 {
    return @floatFromInt(build.cfg.getImageOptimize().?.quality);
}

/// Format the tmp-sibling name for one cache write: `.tmp.<kind>.<variant_id>
/// .<path>.<name>.<basename><ext>`. Extracted from three inline
/// `std.fmt.bufPrint` call sites that all built this exact shape by hand
/// (#147) — `writeCacheAtomic`'s own tmp (no `ext`) and `encodeAvif`'s two
/// interchange files (`.png`, `.avif`), which don't go through
/// `writeCacheAtomic` because they rename via the external encoder's own
/// output rather than a bytes-in-hand write. Unique PER JOB (`ref`'s
/// kind+variant_id+path+name), not merely per basename — see
/// `writeCacheAtomic`'s doc comment for why that matters.
///
/// Bound: `buf` is sized `std.fs.max_path_bytes` (4096 on every platform
/// this repo builds for) at every call site. The formatted name is `.tmp.`
/// (5 bytes) + four decimal `u32`s (<=10 digits each = 40) + 4 `.`
/// separators + `basename` (itself bounded well under 4096 — it is one
/// filesystem entry name, capped by the OS's `NAME_MAX`, typically 255) +
/// `ext` (<=5 bytes, `".avif"` being the longest). The sum has no realistic
/// path to `max_path_bytes`, which is why `catch unreachable` below is
/// sound rather than merely convenient.
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing, formats
/// into the caller's `buf`.
fn tmpName(buf: []u8, ref: plan.SourceRef, basename: []const u8, ext: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".tmp.{d}.{d}.{d}.{d}.{s}{s}", .{
        @intFromEnum(ref.kind),
        ref.variant_id,
        ref.path,
        ref.name,
        basename,
        ext,
    }) catch unreachable;
}

/// The output-tree destination for one variant: `path`'s directory
/// (locale-`prefix`-ed, mirroring `Variant.installAssets` /
/// `root.zig`'s `--summary` collector block) with the original basename
/// swapped for the variant's param-addressed one.
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing, formats
/// into the caller's `buf`.
fn destPath(
    buf: []u8,
    prefix: []const u8,
    st: *const StringTable,
    pt: *const PathTable,
    path: Path,
    basename: []const u8,
) []const u8 {
    return std.fmt.bufPrint(buf, "{f}{s}", .{
        path.fmt(st, pt, prefix, true),
        basename,
    }) catch unreachable;
}

/// tmp + rename so a killed build never leaves a torn file under a valid
/// (param-addressed) cache name.
///
/// The tmp name is unique PER JOB (`ref`'s kind+variant_id+path+name), not
/// merely per basename: two different `SourceRef`s whose bytes and
/// transform params happen to coincide — the same image duplicated under
/// two locales, or under `assets/` and beside a page — hash to the
/// IDENTICAL variant basename (carried finding from the task-6 review), so
/// their derive jobs can run concurrently and both target the same final
/// cache entry. Keying the tmp name off `ref` keeps those two writers from
/// ever touching the same inode mid-write. The final `rename` still targets
/// a name the other job may also rename onto — that part is safe BY
/// CONSTRUCTION rather than by locking, and only because the ENCODE itself
/// is now a pure function of exactly the inputs the basename hashes over:
/// source bytes, width, codec, quality, encoder version (`variantBasename`'s
/// own parameter list) — same bytes, same params, same output, full stop.
/// For `.webp` that purity is ours to guarantee (libwebp, in-process). For
/// `.avif` (Task 12's `encodeAvif`, which mirrors this function's tmp-naming
/// discipline but does its own rename rather than calling through here) it
/// is a TRUST, not a guarantee: the property only holds if the configured
/// `avif_encoder` binary is itself deterministic for identical input bytes.
/// That's why `Decoded.lossless` above is decided from the source bytes'
/// magic number (`plan.isPng`) rather than from `rel`'s filename extension:
/// a filename-derived choice would let two byte-identical sources filed
/// under different extensions share one cache basename while encoding
/// differently, which breaks this exact guarantee (the #132 task-7 review
/// finding this comment now accounts for). With that closed, whichever
/// rename lands last still writes bytes identical to what was already
/// there.
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): the only allocation-shaped
/// thing here is the caller-provided stack buffer for the tmp name.
fn writeCacheAtomic(
    io: Io,
    cache_dir: Io.Dir,
    ref: plan.SourceRef,
    basename: []const u8,
    bytes: []const u8,
) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = tmpName(&tmp_buf, ref, basename, "");
    {
        const f = try cache_dir.createFile(io, tmp, .{});
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.writeAll(bytes);
    }
    try cache_dir.rename(tmp, cache_dir, basename, io);
}
