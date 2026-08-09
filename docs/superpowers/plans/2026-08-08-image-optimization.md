# Build-Time Image Optimization (#132) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `image_optimize` site config makes every decodable content image emit a `<picture>` with resampled WebP variants (srcset in PR B, plus an opt-in external-AVIF hatch), riding the existing refcount/fingerprint machinery and a new content-addressed cache.

**Architecture:** wuffs (already vendored, decode-only) hands us RGBA pixels; a first-party linear-light Lanczos3 resampler produces variants; vendored libwebp (hand-written externs, no translate-c) encodes. Variant *names* are pure functions of `(source bytes, params)`, computed by a single-threaded planner before the render pass (same write-once/lock-free-read discipline as `asset_fingerprints`), so render never waits on pixels; the pixel work runs as worker jobs in the asset-install phase, backed by `.zigapagos-cache/images/`.

**Tech Stack:** Zig 0.16 (released, no nightlies), wuffs 0.4 (existing pin + checked-in `src/hacks/` shims), libwebp (new tarball dep, compiled by us), Blake3 (`std.crypto`), bash e2e under `tests/images/`.

**Spec:** `docs/superpowers/specs/2026-08-08-image-optimization-design.md`. Read it first.

## Global Constraints

- `zig version` must be **0.16.0** (mise resolves it); dependency-graph errors at configure time are version skew, not code defects.
- `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check` must pass before every push. Never reformat `zig-pkg/` (gitignored materialized deps).
- `zig build check` and `zig build check -Dsingle-threaded` must stay green after every task. A test that reaches `std.Thread.spawn` needs `if (comptime !builtin.single_threaded)` pruning — a runtime skip does NOT help.
- Every allocator-taking function states its NO_SLOP §2.2a contract (1 self-freeing / 2 owned-result / 3 caller-buffer / 4 arena-scoped) in its doc comment. Run `bash scripts/check-allocator-contracts.sh` after Zig tasks. No new `scripts/allocator-allowlist.txt` rows are expected.
- `zsh` facts: `cmd | tail` reports tail's exit code — run unpiped and check `$?`; unquoted `$VAR` does not word-split. Shell *scripts* here use `#!/usr/bin/env bash` + `set -euo pipefail` (crib `tests/assets/fingerprint.sh`).
- Regression tests must be **verified to fail without the fix** (revert the impl hunk, run, watch it fail, restore).
- Commit messages explain defect/reasoning, cite issue **#132**. Never push to `main`; `gh pr create` needs `--repo valthon/zigapagos`; `gh issue view`/`gh pr edit` are broken here — use `gh api` REST.
- Feature default is **OFF** (`image_optimize = null`): with the config absent, every build's output must be byte-identical to today (snapshot suites `zig build test` pin this for free).
- Delivery: Tasks 1–9 are **PR A** (branch `feature/132-image-optimization`); Tasks 10–13 are **PR B** stacked on A. Run the `tell-a-git-story` skill before opening each PR.

---

### Task 1: Config surface — `image_optimize` on `Site`/`Multilingual`

**Files:**
- Modify: `src/root.zig` (Site struct ~`:86-134`, Multilingual struct ~`:136-217`, Config accessors ~`:549-569`, `Config.validate` — grep `fn validate` for the deploy_target check to extend)
- Modify: `docs/superpowers/specs/2026-08-08-image-optimization-design.md` (spec amendment, step 1)
- Test: config validation exercised via `zig build check` + Task 9's e2e control run; the struct itself is exercised by every later task.

**Interfaces:**
- Produces: `pub const ImageOptimize` (in `src/root.zig`, next to `BuildAsset`), field `image_optimize: ?ImageOptimize = null` on both `Site` and `Multilingual`, and `Config.getImageOptimize(c: *const Config) ?ImageOptimize`.

- [ ] **Step 1: Amend the spec.** During planning we found build-asset images (`$image.buildAsset(...)`) conflict with the feature: their install paths are author-declared on the CLI (`--install=`), so the build cannot mint content-addressed sibling names without trespassing on paths the author owns — the exact reason `docs/assets.md` excludes build assets from fingerprinting. Add to the spec's "Out of scope" list: `- Build-asset images ($image.buildAsset) — their install paths are CLI-declared (see docs/assets.md's fingerprint exclusions); they keep today's plain <img>. Revisit on demand.` Commit: `git commit -m "spec(#132): exclude build-asset images, mirroring the fingerprint exclusion rationale" -- docs/superpowers/specs/2026-08-08-image-optimization-design.md`

- [ ] **Step 2: Add the struct + fields.** In `src/root.zig`, immediately after the `speculation_rules` field of `Site` (`:133`), add:

```zig
    /// Build-time image optimization (issue #132). When set, every content
    /// `$image` whose source is a decodable still raster (JPEG, PNG, WebP)
    /// is resampled to WebP variants and emitted inside a `<picture>` with
    /// the untouched original as the `<img>` fallback. Null (the default)
    /// means OFF: output is byte-identical to a build without the feature.
    ///
    /// Disk (release) builds only, like `asset_fingerprint`: an in-memory
    /// build writes no output tree, so there is nothing to derive — dev/serve
    /// show the original images.
    image_optimize: ?ImageOptimize = null,
```

Add the same field (same doc comment, plus "See the field of the same name on a single-locale `Site`.") after `speculation_rules` on `Multilingual` (`:216`). Then next to `pub const BuildAsset` (`:597`) add:

```zig
/// The `image_optimize` config block (issue #132). Field defaults are the
/// site-wide policy a bare `.image_optimize = .{}` opts into.
pub const ImageOptimize = struct {
    /// Variant widths (CSS px). Filtered per image to <= intrinsic width —
    /// never upscaled. PR A generates only the largest surviving width;
    /// the full srcset ships in PR B.
    widths: []const i64 = &.{ 480, 800, 1200, 1920 },
    /// WebP lossy quality (0-100) for JPEG sources. PNG sources always use
    /// lossless WebP, ignoring this.
    quality: i64 = 75,
    /// Emitted verbatim as the `sizes` attribute (required by the HTML spec
    /// whenever `srcset` uses `w` descriptors; unused until PR B).
    sizes: []const u8 = "100vw",
    /// Opt-in AVIF: name (PATH-resolved) or path of an avifenc-compatible
    /// binary. Null = no AVIF output. Unused until PR B.
    avif_encoder: ?[]const u8 = null,
};
```

- [ ] **Step 3: Add the accessor.** After `getSpeculationRules` (`src/root.zig:569`):

```zig
    /// `image_optimize` (issue #132) — build-time image optimization.
    pub fn getImageOptimize(c: *const Config) ?ImageOptimize {
        return switch (c.*) {
            .Site => |s| s.image_optimize,
            .Multilingual => |m| m.image_optimize,
        };
    }
```

- [ ] **Step 4: Validate.** Find `Config.validate` (grep `deploy_target` in `src/root.zig` for the enforcement site) and add, following its existing error-reporting idiom exactly: `quality` outside `0…100` → error naming the field and the accepted range; any `widths` entry `<= 0` → error; empty `widths` → error. Copy the phrasing style of the deploy_target message.

- [ ] **Step 5: Compile + gates.** Run `zig build check` then `zig build check -Dsingle-threaded`. Expected: both pass. Run `zig build test` (snapshots) — expected: unchanged, since the field defaults to null.

- [ ] **Step 6: Commit.** `git commit -m $'Add image_optimize config surface (#132)\n\nNullable struct like asset_fingerprint/speculation_rules: null = feature\noff = byte-identical output. Validation rejects out-of-range quality and\nnon-positive widths at config load, not mid-derive.' -- src/root.zig`

---

### Task 2: Vendored libwebp + extern bindings + `test-images` suite bootstrap

**Files:**
- Modify: `build.zig.zon` (new `libwebp` dependency)
- Modify: `build/exe.zig` (new `pub fn addWebpLib`, called beside `addWuffsImports` at `:97`)
- Modify: `build/release.zig:172` region (same pairing — grep `addWuffsImports` for every call site and add `addWebpLib` beside each)
- Modify: `build/tests.zig` (new `Standalone` field `image_deps: bool` + suite entry `test-images`)
- Create: `src/image/webp.zig`, `src/image/tests.zig`
- Modify: `.github/workflows/ci.yml` (add `test-images` to the explicit `zig build test-…` list), `CLAUDE.md` (same list in Commands)

**Interfaces:**
- Produces: module `src/image/webp.zig` with `pub extern fn WebPEncodeRGBA(...)`, `WebPEncodeLosslessRGBA(...)`, `WebPFree(...)`, `WebPGetEncoderVersion()`; build helper `pub fn addWebpLib(zb: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void`; `zig build test-images` step whose root is `src/image/tests.zig`.

- [ ] **Step 1: Pin the dependency.** Pick the newest libwebp release tag: `git ls-remote --tags https://github.com/webmproject/libwebp | grep -v '\^{}' | tail -5` (expect `v1.6.0` or later; use the newest stable `vX.Y.Z`). Then `zig fetch --save=libwebp https://github.com/webmproject/libwebp/archive/refs/tags/<TAG>.tar.gz` — this writes the url+hash into `build.zig.zon`. This is a plain source tarball (no build.zig); we compile it ourselves.

- [ ] **Step 2: Write the bindings.** Create `src/image/webp.zig`:

```zig
//! Hand-written externs for libwebp's simple encode API (issue #132).
//!
//! Deliberately NOT translate-c: released Zig 0.16.0 crashes translating
//! large C headers for aarch64 (the reason src/hacks/ exists for wuffs).
//! Six declarations need no translation and no per-target shims.
//! The C library itself is compiled from source by `build/exe.zig`'s
//! `addWebpLib` — same everywhere the wuffs impl is wired.

/// Returns the encoded size, 0 on error. `output` receives a malloc'd
/// buffer that MUST be released with `WebPFree`.
pub extern fn WebPEncodeRGBA(
    rgba: [*]const u8,
    width: c_int,
    height: c_int,
    stride: c_int,
    quality_factor: f32,
    output: *?[*]u8,
) usize;

pub extern fn WebPEncodeLosslessRGBA(
    rgba: [*]const u8,
    width: c_int,
    height: c_int,
    stride: c_int,
    output: *?[*]u8,
) usize;

pub extern fn WebPFree(ptr: ?*anyopaque) void;

/// (major << 16 | minor << 8 | patch) — baked into variant names so a
/// libwebp upgrade moves every derived URL (docs/assets.md's minified-CSS
/// caveat, fixed rather than inherited).
pub extern fn WebPGetEncoderVersion() c_int;
```

- [ ] **Step 3: Compile the C library.** In `build/exe.zig`, after `addWuffsImports` (`:134`), add:

```zig
/// Compile libwebp's encoder from the vendored source tarball and link it
/// into `module`. Compiled (not prebuilt) so `zig cc` cross-compiles it for
/// every release target exactly like the wuffs impl. Paired with
/// `addWuffsImports` at every call site — decode and encode travel together.
pub fn addWebpLib(
    zb: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const dep = zb.dependency("libwebp", .{});
    const lib = zb.addLibrary(.{
        .name = "webp",
        .linkage = .static,
        .root_module = zb.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addIncludePath(dep.path(""));
    lib.root_module.addIncludePath(dep.path("src"));
    lib.root_module.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &webp_sources,
        .flags = &.{ "-DWEBP_DISABLE_STATS", "-fno-sanitize=undefined" },
    });
    module.linkLibrary(lib);
}
```

Generate the source list (after Step 1 has materialized the dep — `zig build --fetch` first if needed; find the hash dir under `zig-pkg/`):

```sh
zig build --fetch
d=$(ls -d zig-pkg/libwebp-*/ | head -1)
(cd "$d" && ls src/enc/*.c src/dec/*.c src/dsp/*.c src/utils/*.c sharpyuv/*.c) | sort
```

Paste the output verbatim as `const webp_sources = [_][]const u8{ "src/enc/alpha_enc.c", … };` above `addWebpLib`. All four dirs + sharpyuv compile as one lib (the cmake/Bazel upstream grouping); dec is included because dsp's decode half references it, and PR-B-free dead code is stripped by static linking. If any file fails to compile under a cross target (SIMD detection), exclude it and note why in a comment — the generic C paths are always present.

- [ ] **Step 4: Wire every exe.** In `addZigapagosExe` after `addWuffsImports(zb, zigapagos_exe.root_module, target, optimize);` (`build/exe.zig:97`) add `addWebpLib(zb, zigapagos_exe.root_module, target, optimize);`. Then `grep -rn addWuffsImports build/` and add the same pairing at each remaining call site (expect `build/release.zig` ~`:172`, possibly `build/docgen.zig`).

- [ ] **Step 5: Bootstrap the `test-images` suite with a failing smoke test.** Create `src/image/tests.zig`:

```zig
//! Root of the `test-images` suite (build/tests.zig). Everything under
//! src/image/ is reachable from here — the module-root constraint (see
//! CLAUDE.md) means files in this directory must not @import upward.
const std = @import("std");

test {
    _ = @import("webp.zig");
}

test "images: libwebp links and reports a version" {
    const webp = @import("webp.zig");
    const v = webp.WebPGetEncoderVersion();
    try std.testing.expect(v > 0);
}

test "images: WebPEncodeRGBA round-trips a solid color" {
    const webp = @import("webp.zig");
    // 8x8 solid red, opaque.
    var rgba: [8 * 8 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        rgba[i] = 255;
        rgba[i + 1] = 0;
        rgba[i + 2] = 0;
        rgba[i + 3] = 255;
    }
    var out: ?[*]u8 = null;
    const n = webp.WebPEncodeRGBA(&rgba, 8, 8, 8 * 4, 80.0, &out);
    defer webp.WebPFree(out);
    try std.testing.expect(n > 0);
    // RIFF container magic: "RIFF" …4 size bytes… "WEBP".
    try std.testing.expectEqualStrings("RIFF", out.?[0..4]);
    try std.testing.expectEqualStrings("WEBP", out.?[8..12]);
}
```

In `build/tests.zig`: add `image_deps: bool = false` to the `Standalone` struct; add the suite entry after `test-summary`:

```zig
    // Build-time image optimization (issue #132): webp bindings, decode,
    // resample, planning. Needs the wuffs shims + the compiled libwebp
    // (`image_deps`), wired the same way the exe gets them so the suite
    // cannot drift from production linkage.
    .{
        .step_name = "test-images",
        .description = "Run image-optimization (decode/resample/encode/plan) unit tests",
        .image_deps = true,
    },
```

and in `setup`'s standalone loop, after the `supermd` clause:

```zig
        if (suite.image_deps) {
            const exe_build = @import("exe.zig");
            exe_build.addWuffsImports(b, tests.root_module, target, cfg.optimize);
            exe_build.addWebpLib(b, tests.root_module, target, cfg.optimize);
        }
```

(Move the `@import("exe.zig")` to the file's top-level imports next to `deps.zig`.)

- [ ] **Step 6: Run it.** `zig build test-images`. Expected: PASS (2 tests). If the link fails with missing symbols, the source list from Step 3 is incomplete — add the missing file. Then `zig build check -Dsingle-threaded` (the new suite compiles there too).

- [ ] **Step 7: CI + docs of record.** In `.github/workflows/ci.yml`, add `test-images` to the explicit step list (grep `test-doctor` to find it). In `CLAUDE.md`'s Commands section, add `test-images` to the same list. Verify: `grep -c test-images .github/workflows/ci.yml CLAUDE.md` → each ≥ 1.

- [ ] **Step 8: Cross-target proof.** `zig build check` covers the host; prove one cross target compiles the C: `zig build -Dtarget=aarch64-macos --summary all` (configure+compile only; it must not error in libwebp). If `release` has a dedicated step, prefer that.

- [ ] **Step 9: Commit.** `git commit -m $'Vendor libwebp with hand-written externs (#132)\n\nPlain source tarball compiled by our own build code — no translate-c, so\nno src/hacks/ pretranslation (the Zig 0.16 aarch64 crash only bites\ntranslated headers). Paired with addWuffsImports at every call site.\nNew test-images suite pins linkage with an encode round-trip.' -- build.zig.zon build/exe.zig build/release.zig build/tests.zig src/image/webp.zig src/image/tests.zig .github/workflows/ci.yml CLAUDE.md`

---

### Task 3: Decode — wuffs full-frame → RGBA8

**Files:**
- Create: `src/image/decode.zig`
- Modify: `src/image/tests.zig` (add `_ = @import("decode.zig");` to the aggregator test)

**Interfaces:**
- Consumes: the `"wuffs"` module (pretranslated shim; already wired into the suite by Task 2).
- Produces: `pub const Decoded = struct { w: u32, h: u32, rgba: []u8, pub fn deinit(self: Decoded, gpa: Allocator) void }` and `pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Decoded` where `pub const DecodeError = error{ OutOfMemory, UnsupportedImageFormat, WuffsError, TooLarge }`. `rgba` is non-premultiplied RGBA8, row-major, `len == w*h*4`.

- [ ] **Step 1: Verify the shim has the symbols.** All five checked-in shims were generated from the full `wuffs-v0.4.c`, but confirm before writing code:

```sh
for s in wuffs_base__image_decoder__decode_frame \
         wuffs_base__image_decoder__workbuf_len \
         wuffs_base__pixel_config__set \
         wuffs_base__pixel_buffer__set_from_slice \
         wuffs_base__make_slice_u8 \
         WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL; do
  printf '%s: ' "$s"; grep -c "$s" src/hacks/wuffs-temp-x86-linux.h.zig
done
```

Expected: every count ≥ 1. If a symbol is missing, STOP and report — the design assumed presence (survey said decode_frame/swizzler exist); an absent one needs a design conversation, not a workaround.

- [ ] **Step 2: Write the failing test.** QOI is the one wuffs-supported format simple enough to author byte-exact in a test, which pins the whole decode+swizzle path to exact pixel values. Append to `src/image/tests.zig`:

```zig
test "images: decode QOI to exact RGBA" {
    const decode = @import("decode.zig");
    const gpa = std.testing.allocator;
    // Hand-assembled 2x1 QOI: magic, w=2, h=1, 4 channels, srgb-linear=0,
    // two QOI_OP_RGBA pixels, end marker.
    const qoi = [_]u8{
        'q', 'o', 'i', 'f',
        0,   0,   0,   2, // width  (BE)
        0,   0,   0,   1, // height (BE)
        4, 0,
        0xFF, 10,  20,  30,  255, // pixel 0: rgba(10,20,30,255)
        0xFF, 200, 100, 50,  128, // pixel 1: rgba(200,100,50,128)
        0, 0, 0, 0, 0, 0, 0, 1,
    };
    const img = try decode.decode(gpa, &qoi);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), img.w);
    try std.testing.expectEqual(@as(u32, 1), img.h);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 10, 20, 30, 255, 200, 100, 50, 128 },
        img.rgba,
    );
}

test "images: decode rejects garbage" {
    const decode = @import("decode.zig");
    try std.testing.expectError(
        error.UnsupportedImageFormat,
        decode.decode(std.testing.allocator, "not an image"),
    );
}
```

- [ ] **Step 3: Run to verify failure.** `zig build test-images` → FAIL: `decode.zig` not found.

- [ ] **Step 4: Implement.** Create `src/image/decode.zig`. Model the decoder-allocation half on `src/wuffs.zig`'s `parseImageSize`/`allocDecoder` (`src/wuffs.zig:146-215`) — copy `allocDecoder` and `wrapErr` in (this module cannot import `../wuffs.zig`: module-root constraint), with a comment saying which file it mirrors:

```zig
//! Full-frame decode via wuffs → non-premultiplied RGBA8 (issue #132).
//!
//! `src/wuffs.zig` decodes only the CONFIG (dimensions, silent-on-failure —
//! a missing width attribute is cosmetic). This module decodes PIXELS and
//! returns errors: by the time it runs, the planner has already promised a
//! variant name to the render pass, so a failure here must fail the build
//! (spec §7). `allocDecoder`/`wrapErr` are mirrored from src/wuffs.zig
//! because the module-root constraint (test-images roots at
//! src/image/tests.zig) forbids importing upward.
const std = @import("std");
const wuffs = @import("wuffs");
const Allocator = std.mem.Allocator;

pub const DecodeError = error{ OutOfMemory, UnsupportedImageFormat, WuffsError, TooLarge };

pub const Decoded = struct {
    w: u32,
    h: u32,
    /// Non-premultiplied RGBA8, row-major, stride w*4. len == w*h*4.
    rgba: []u8,

    pub fn deinit(self: Decoded, gpa: Allocator) void {
        gpa.free(self.rgba);
    }
};

/// Decode the first frame of `bytes` to RGBA8.
///
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1) — decoder
/// state and workbuf are freed before returning; the one escaping
/// allocation is `Decoded.rgba`, released by `Decoded.deinit`.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Decoded {
    var src = wuffs.wuffs_base__ptr_u8__reader(@constCast(bytes.ptr), bytes.len, true);

    const fourcc = wuffs.wuffs_base__magic_number_guess_fourcc(
        wuffs.wuffs_base__io_buffer__reader_slice(&src),
        src.meta.closed,
    );
    if (fourcc < 0) return error.UnsupportedImageFormat;

    const decoder_raw, const dec = switch (fourcc) {
        wuffs.WUFFS_BASE__FOURCC__JPEG => try allocDecoder(gpa, "jpeg"),
        wuffs.WUFFS_BASE__FOURCC__PNG => try allocDecoder(gpa, "png"),
        wuffs.WUFFS_BASE__FOURCC__WEBP => try allocDecoder(gpa, "webp"),
        wuffs.WUFFS_BASE__FOURCC__QOI => try allocDecoder(gpa, "qoi"),
        else => return error.UnsupportedImageFormat,
    };
    defer gpa.free(decoder_raw);

    var cfg = std.mem.zeroes(wuffs.wuffs_base__image_config);
    try wrapErr(wuffs.wuffs_base__image_decoder__decode_image_config(dec, &cfg, &src));

    const w = wuffs.wuffs_base__pixel_config__width(&cfg.pixcfg);
    const h = wuffs.wuffs_base__pixel_config__height(&cfg.pixcfg);
    // 16k x 16k RGBA is 1 GiB; anything bigger is a config error, not a photo.
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return error.TooLarge;

    // Ask wuffs to swizzle whatever the source format is into interleaved
    // non-premultiplied RGBA8 in OUR buffer.
    wuffs.wuffs_base__pixel_config__set(
        &cfg.pixcfg,
        wuffs.WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
        wuffs.WUFFS_BASE__PIXEL_SUBSAMPLING__NONE,
        w,
        h,
    );

    const rgba = try gpa.alloc(u8, @as(usize, w) * h * 4);
    errdefer gpa.free(rgba);

    var pb = std.mem.zeroes(wuffs.wuffs_base__pixel_buffer);
    try wrapErr(wuffs.wuffs_base__pixel_buffer__set_from_slice(
        &pb,
        &cfg.pixcfg,
        wuffs.wuffs_base__make_slice_u8(rgba.ptr, rgba.len),
    ));

    const workbuf_len = wuffs.wuffs_base__image_decoder__workbuf_len(dec).max_incl;
    const workbuf = try gpa.alloc(u8, @intCast(workbuf_len));
    defer gpa.free(workbuf);

    try wrapErr(wuffs.wuffs_base__image_decoder__decode_frame(
        dec,
        &pb,
        &src,
        wuffs.WUFFS_BASE__PIXEL_BLEND__SRC,
        wuffs.wuffs_base__make_slice_u8(workbuf.ptr, workbuf.len),
        null,
    ));

    return .{ .w = w, .h = h, .rgba = rgba };
}
```

Then paste `allocDecoder` (with `max_align`) and `wrapErr` verbatim from `src/wuffs.zig:190-224`. If a wuffs call's exact Zig-side signature disagrees with the above (translate-c naming/arg quirks), resolve it by grepping the shim (`grep -n 'pub fn wuffs_base__pixel_buffer__set_from_slice' src/hacks/wuffs-temp-x86-linux.h.zig`) — the shim IS the API; adjust the call, not the shim.

- [ ] **Step 5: Run to verify pass.** `zig build test-images` → PASS. Also `zig build check -Dsingle-threaded`.

- [ ] **Step 6: Commit.** `git commit -m $'Decode full frames to RGBA via wuffs (#132)\n\nsrc/wuffs.zig stays config-only/silent (missing width attr is cosmetic);\nthis path returns errors because a decode failure after the planner has\npromised a variant name is a broken <picture> in shipped HTML. QOI test\npins exact pixels through the swizzler.' -- src/image/decode.zig src/image/tests.zig`

---

### Task 4: Resampler — Lanczos3 in linear light

**Files:**
- Create: `src/image/resample.zig`
- Modify: `src/image/tests.zig`

**Interfaces:**
- Consumes: nothing (std-only; operates on raw planes, not `Decoded`).
- Produces: `pub fn resize(gpa: Allocator, src_w: u32, src_h: u32, src_rgba: []const u8, dst_w: u32, dst_h: u32) error{OutOfMemory}![]u8` returning a `dst_w*dst_h*4` non-premultiplied RGBA8 buffer (caller frees).

- [ ] **Step 1: Write the failing tests.** The 2×1 black/white → 1×1 case is the load-bearing one: naive byte-space averaging yields 127–128, linear-light yields sRGB(0.5 linear) = **188**. Append to `src/image/tests.zig`:

```zig
test "images: resample averages in linear light, not byte space" {
    const resample = @import("resample.zig");
    const gpa = std.testing.allocator;
    // 2x1: pure black, pure white, both opaque.
    const src = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 };
    const out = try resample.resize(gpa, 2, 1, &src, 1, 1);
    defer gpa.free(out);
    // sRGB encode of linear 0.5 is ~188. Byte-space (WRONG) gives ~127.
    try std.testing.expectEqual(@as(u8, 255), out[3]);
    for (out[0..3]) |c| {
        try std.testing.expect(c >= 186 and c <= 190);
    }
}

test "images: resample identity returns the same pixels" {
    const resample = @import("resample.zig");
    const gpa = std.testing.allocator;
    var src: [4 * 3 * 4]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(&src);
    // Opaque alpha so premultiply round-trip is exact.
    var i: usize = 3;
    while (i < src.len) : (i += 4) src[i] = 255;
    const out = try resample.resize(gpa, 4, 3, &src, 4, 3);
    defer gpa.free(out);
    // Identity through linear-light round-trip: allow off-by-one from the
    // u8->f32->u8 quantization, nothing more.
    for (src, out) |a, b| {
        const d = if (a > b) a - b else b - a;
        try std.testing.expect(d <= 1);
    }
}

test "images: resample does not bleed transparent-pixel colors" {
    const resample = @import("resample.zig");
    const gpa = std.testing.allocator;
    // 2x1: garbage color at alpha 0, pure white opaque. Premultiplied
    // filtering must make the invisible color contribute NOTHING.
    const src = [_]u8{ 255, 0, 255, 0, 255, 255, 255, 255 };
    const out = try resample.resize(gpa, 2, 1, &src, 1, 1);
    defer gpa.free(out);
    // Un-premultiplied result color must be white (the only visible color).
    try std.testing.expect(out[3] > 100 and out[3] < 155); // ~half coverage
    for (out[0..3]) |c| try std.testing.expect(c >= 250);
}

test "images: resample solid color is exact at any scale" {
    const resample = @import("resample.zig");
    const gpa = std.testing.allocator;
    var src: [16 * 16 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        src[i] = 30;
        src[i + 1] = 180;
        src[i + 2] = 90;
        src[i + 3] = 255;
    }
    const out = try resample.resize(gpa, 16, 16, &src, 5, 3);
    defer gpa.free(out);
    var j: usize = 0;
    while (j < out.len) : (j += 4) {
        // Weights sum to 1, so a constant image stays constant (±1 quantize).
        for (0..3) |k| {
            const d = @max(out[j + k], src[k]) - @min(out[j + k], src[k]);
            try std.testing.expect(d <= 1);
        }
        try std.testing.expectEqual(@as(u8, 255), out[j + 3]);
    }
}
```

Add `_ = @import("resample.zig");` to the aggregator test.

- [ ] **Step 2: Run to verify failure.** `zig build test-images` → FAIL (module missing).

- [ ] **Step 3: Implement.** Create `src/image/resample.zig`:

```zig
//! Lanczos3 resampling in linear light with premultiplied alpha (#132).
//!
//! Both properties are the difference between a toy and a real resampler:
//! filtering sRGB bytes directly darkens every edge (the test suite pins
//! 188-not-127), and filtering straight (non-premultiplied) alpha bleeds
//! invisible colors into visible pixels. Separable: horizontal pass into a
//! f32 intermediate, then vertical.
const std = @import("std");
const Allocator = std.mem.Allocator;

const support = 3.0; // Lanczos3

const srgb_to_linear: [256]f32 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| {
        const c = @as(f32, @floatFromInt(i)) / 255.0;
        v.* = if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
    break :blk t;
};

fn linearToSrgb(l: f32) u8 {
    const c = std.math.clamp(l, 0.0, 1.0);
    const s = if (c <= 0.0031308)
        c * 12.92
    else
        1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(s * 255.0));
}

fn sinc(x: f32) f32 {
    if (@abs(x) < 1e-6) return 1.0;
    const px = std.math.pi * x;
    return @sin(px) / px;
}

fn lanczos(x: f32) f32 {
    if (@abs(x) >= support) return 0.0;
    return sinc(x) * sinc(x / support);
}

/// One output coordinate's window of source taps.
const Taps = struct { start: u32, weights: []f32 };

/// Build per-output-coordinate tap lists for one axis. When downscaling the
/// kernel is widened by the scale factor (standard area-coverage scaling);
/// weights are normalized to sum to 1 so constant images are preserved.
///
/// Allocator contract: owned-result (NO_SLOP §2.2a contract 2) — caller
/// frees `taps[i].weights` and the outer slice; internal scratch is none.
fn buildTaps(gpa: Allocator, src_n: u32, dst_n: u32) Allocator.Error![]Taps {
    const taps = try gpa.alloc(Taps, dst_n);
    errdefer gpa.free(taps);
    const scale = @as(f32, @floatFromInt(src_n)) / @as(f32, @floatFromInt(dst_n));
    const filter_scale = @max(scale, 1.0);
    const radius = support * filter_scale;
    var allocated: usize = 0;
    errdefer for (taps[0..allocated]) |t| gpa.free(t.weights);
    for (taps, 0..) |*t, i| {
        const center = (@as(f32, @floatFromInt(i)) + 0.5) * scale - 0.5;
        const lo: i64 = @intFromFloat(@ceil(center - radius));
        const hi: i64 = @intFromFloat(@floor(center + radius));
        const start: u32 = @intCast(std.math.clamp(lo, 0, @as(i64, src_n - 1)));
        const end: u32 = @intCast(std.math.clamp(hi, 0, @as(i64, src_n - 1)));
        const weights = try gpa.alloc(f32, end - start + 1);
        var sum: f32 = 0;
        for (weights, 0..) |*wp, k| {
            const x = (@as(f32, @floatFromInt(start + @as(u32, @intCast(k)))) - center) / filter_scale;
            wp.* = lanczos(x);
            sum += wp.*;
        }
        for (weights) |*wp| wp.* /= sum;
        t.* = .{ .start = start, .weights = weights };
        allocated += 1;
    }
    return taps;
}

fn freeTaps(gpa: Allocator, taps: []Taps) void {
    for (taps) |t| gpa.free(t.weights);
    gpa.free(taps);
}

/// Resample non-premultiplied sRGB RGBA8 to (dst_w, dst_h).
///
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1) — taps and
/// the f32 planes are freed before returning; the one escaping allocation
/// is the returned RGBA buffer.
pub fn resize(
    gpa: Allocator,
    src_w: u32,
    src_h: u32,
    src_rgba: []const u8,
    dst_w: u32,
    dst_h: u32,
) Allocator.Error![]u8 {
    std.debug.assert(src_rgba.len == @as(usize, src_w) * src_h * 4);
    std.debug.assert(dst_w > 0 and dst_h > 0);

    // Linearize + premultiply into f32.
    const src_f = try gpa.alloc(f32, @as(usize, src_w) * src_h * 4);
    defer gpa.free(src_f);
    for (0..@as(usize, src_w) * src_h) |p| {
        const a = @as(f32, @floatFromInt(src_rgba[p * 4 + 3])) / 255.0;
        src_f[p * 4 + 0] = srgb_to_linear[src_rgba[p * 4 + 0]] * a;
        src_f[p * 4 + 1] = srgb_to_linear[src_rgba[p * 4 + 1]] * a;
        src_f[p * 4 + 2] = srgb_to_linear[src_rgba[p * 4 + 2]] * a;
        src_f[p * 4 + 3] = a;
    }

    const htaps = try buildTaps(gpa, src_w, dst_w);
    defer freeTaps(gpa, htaps);
    const vtaps = try buildTaps(gpa, src_h, dst_h);
    defer freeTaps(gpa, vtaps);

    // Horizontal pass: (src_w x src_h) -> (dst_w x src_h).
    const mid = try gpa.alloc(f32, @as(usize, dst_w) * src_h * 4);
    defer gpa.free(mid);
    for (0..src_h) |y| {
        for (htaps, 0..) |t, x| {
            var acc = [4]f32{ 0, 0, 0, 0 };
            for (t.weights, 0..) |wt, k| {
                const sp = (y * src_w + t.start + k) * 4;
                for (0..4) |c| acc[c] += src_f[sp + c] * wt;
            }
            const dp = (y * dst_w + x) * 4;
            for (0..4) |c| mid[dp + c] = acc[c];
        }
    }

    // Vertical pass + un-premultiply + re-encode.
    const out = try gpa.alloc(u8, @as(usize, dst_w) * dst_h * 4);
    errdefer gpa.free(out);
    for (vtaps, 0..) |t, y| {
        for (0..dst_w) |x| {
            var acc = [4]f32{ 0, 0, 0, 0 };
            for (t.weights, 0..) |wt, k| {
                const sp = ((t.start + k) * dst_w + x) * 4;
                for (0..4) |c| acc[c] += mid[sp + c] * wt;
            }
            const dp = (y * dst_w + x) * 4;
            const a = std.math.clamp(acc[3], 0.0, 1.0);
            if (a <= 0.0) {
                @memset(out[dp .. dp + 4], 0);
            } else {
                for (0..3) |c| out[dp + c] = linearToSrgb(acc[c] / a);
                out[dp + 3] = @intFromFloat(@round(a * 255.0));
            }
        }
    }
    return out;
}
```

- [ ] **Step 4: Run to verify pass.** `zig build test-images` → PASS. If the 188-test lands at 186–190 that's the quantization envelope; if it lands near 127 the linearization got lost — fix, don't widen the assertion.

- [ ] **Step 5: Gates + commit.** `zig fmt` the tree, `bash scripts/check-allocator-contracts.sh`, then `git commit -m $'Add linear-light Lanczos3 resampler (#132)\n\nGamma-naive filtering visibly darkens edges — the suite pins the 2x1\nblack/white average to 188 (linear) not 127 (byte-space) so a future\n"simplification" that drops linearization fails loudly. Premultiplied\nfiltering keeps invisible colors from bleeding (also pinned).' -- src/image/resample.zig src/image/tests.zig`

---

### Task 5: Planning — variant math, naming, format gate

**Files:**
- Create: `src/image/plan.zig`
- Modify: `src/image/tests.zig`

**Interfaces:**
- Consumes: `webp.zig`'s `WebPGetEncoderVersion` (for the name hash).
- Produces (all `pub` in `src/image/plan.zig`):
  - `pub const Codec = enum { webp, avif };`
  - `pub const SourceRef = struct { kind: enum(u8) { site, page }, variant_id: u32, path: u32, name: u32 }` — `path`/`name` are `@intFromEnum` of the interned `Path`/`String` (kept as raw ints so this module stays std-only; hashable with `std.AutoHashMapUnmanaged`). `variant_id` is 0 for `.site`.
  - `pub const Variant = struct { width: u32, height: u32, codec: Codec, basename: []const u8 };`
  - `pub const Planned = struct { intrinsic_w: u32, intrinsic_h: u32, variants: []Variant };`
  - `pub const Map = std.AutoHashMapUnmanaged(SourceRef, Planned);`
  - `pub fn eligible(bytes: []const u8) bool` — JPEG/PNG/still-WebP sniff.
  - `pub fn pickWidths(cfg_widths: []const i64, intrinsic_w: u32, buf: []u32) []u32` — filtered ≤ intrinsic, sorted ascending, deduped; falls back to `{intrinsic_w}` when none survive. **PR A callers use only the LAST element (largest).**
  - `pub fn variantBasename(gpa: Allocator, source_basename: []const u8, source_bytes: []const u8, width: u32, codec: Codec, quality: u8, encoder_version: u32) Allocator.Error![]u8` → `<stem>.<hash8>.<width>.<codec>`.

- [ ] **Step 1: Write the failing tests.** Append to `src/image/tests.zig`:

```zig
test "images: pickWidths filters, sorts, dedupes, never upscales" {
    const plan = @import("plan.zig");
    var buf: [8]u32 = undefined;
    // Config order is not size order; 1920 exceeds intrinsic; 800 repeats.
    const got = plan.pickWidths(&.{ 1200, 480, 800, 1920, 800 }, 1600, &buf);
    try std.testing.expectEqualSlices(u32, &.{ 480, 800, 1200 }, got);
    // Image narrower than every width: single intrinsic-width variant.
    const tiny = plan.pickWidths(&.{ 480, 800 }, 300, &buf);
    try std.testing.expectEqualSlices(u32, &.{300}, tiny);
    // Exact match survives.
    const exact = plan.pickWidths(&.{ 480, 800 }, 800, &buf);
    try std.testing.expectEqualSlices(u32, &.{ 480, 800 }, exact);
}

test "images: variantBasename is param-addressed" {
    const plan = @import("plan.zig");
    const gpa = std.testing.allocator;
    const a = try plan.variantBasename(gpa, "cover.jpg", "BYTES", 800, .webp, 75, 0x10600);
    defer gpa.free(a);
    // <stem>.<8 hex>.<width>.webp
    try std.testing.expect(std.mem.startsWith(u8, a, "cover."));
    try std.testing.expect(std.mem.endsWith(u8, a, ".800.webp"));
    try std.testing.expectEqual("cover.".len + 8 + ".800.webp".len, a.len);

    // Same inputs => same name (idempotent rebuilds).
    const a2 = try plan.variantBasename(gpa, "cover.jpg", "BYTES", 800, .webp, 75, 0x10600);
    defer gpa.free(a2);
    try std.testing.expectEqualStrings(a, a2);

    // ANY param change moves the name — this is the fix for the
    // docs/assets.md minified-CSS caveat (hash-over-source-only).
    const diffs = [_][]const u8{
        try plan.variantBasename(gpa, "cover.jpg", "bytes2", 800, .webp, 75, 0x10600),
        try plan.variantBasename(gpa, "cover.jpg", "BYTES", 480, .webp, 75, 0x10600),
        try plan.variantBasename(gpa, "cover.jpg", "BYTES", 800, .avif, 75, 0x10600),
        try plan.variantBasename(gpa, "cover.jpg", "BYTES", 800, .webp, 60, 0x10600),
        try plan.variantBasename(gpa, "cover.jpg", "BYTES", 800, .webp, 75, 0x10700),
    };
    defer for (diffs) |d| gpa.free(d);
    for (diffs) |d| try std.testing.expect(!std.mem.eql(u8, a, d));
}

test "images: eligible gates on format and animation" {
    const plan = @import("plan.zig");
    const jpeg_magic = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 } ++ [_]u8{0} ** 8;
    const png_magic = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A } ++ [_]u8{0} ** 8;
    try std.testing.expect(plan.eligible(&jpeg_magic));
    try std.testing.expect(plan.eligible(&png_magic));
    try std.testing.expect(!plan.eligible("GIF89a......")); // gif: never
    try std.testing.expect(!plan.eligible("<svg xmlns=")); // not raster
    // Still WebP (VP8 chunk) yes; animated WebP (VP8X with anim flag) no.
    var still = "RIFF\x00\x00\x00\x00WEBPVP8 ".* ++ [_]u8{0} ** 8;
    try std.testing.expect(plan.eligible(&still));
    var anim = "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x12".* ++ [_]u8{0} ** 8;
    try std.testing.expect(!plan.eligible(&anim));
}
```

Add `_ = @import("plan.zig");` to the aggregator.

- [ ] **Step 2: Run to verify failure.** `zig build test-images` → FAIL.

- [ ] **Step 3: Implement** `src/image/plan.zig`:

```zig
//! Variant planning for build-time image optimization (issue #132): which
//! sources are eligible, which widths each gets, and the param-addressed
//! basename every derived file is known by. Deliberately std-only (types
//! use raw interned ints, not PathTable types) so it unit-tests in the
//! test-images suite without dragging in the whole exe graph.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;

pub const Codec = enum { webp, avif };

pub const SourceRef = struct {
    kind: enum(u8) { site, page },
    /// 0 for `.site` (multilingual sites keep one copy of site assets).
    variant_id: u32,
    /// `@intFromEnum` of the interned PathTable.Path / StringTable.String.
    path: u32,
    name: u32,
};

pub const Variant = struct {
    width: u32,
    height: u32,
    codec: Codec,
    /// gpa-owned; freed alongside the Map by Build.deinit.
    basename: []const u8,
};

pub const Planned = struct {
    intrinsic_w: u32,
    intrinsic_h: u32,
    /// gpa-owned slice, ordered ascending by width, webp before avif per width.
    variants: []Variant,
};

/// Written ONCE by root.zig's planImageVariants before the render pass,
/// read lock-free by the render workers — the asset_fingerprints discipline.
pub const Map = std.AutoHashMapUnmanaged(SourceRef, Planned);

/// Still-raster gate: JPEG, PNG, still WebP. GIF (animation-ambiguous,
/// palette output would need quantization) and everything else pass
/// through as plain <img> — spec §1.
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing.
pub fn eligible(bytes: []const u8) bool {
    if (bytes.len < 16) return false;
    if (bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return true; // JPEG
    if (std.mem.eql(u8, bytes[0..8], &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) return true;
    if (std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        // VP8X extended header: byte 20 is the flags byte, bit 1 = animation.
        if (std.mem.eql(u8, bytes[12..16], "VP8X")) {
            return bytes.len > 20 and (bytes[20] & 0x02) == 0;
        }
        return true; // simple VP8/VP8L: always still
    }
    return false;
}

/// Filter config widths to <= intrinsic, sort ascending, dedupe; if none
/// survive, the single intrinsic width. `buf` must hold cfg_widths.len + 1.
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing; the result
/// is a prefix of `buf`.
pub fn pickWidths(cfg_widths: []const i64, intrinsic_w: u32, buf: []u32) []u32 {
    var n: usize = 0;
    for (cfg_widths) |w| {
        if (w <= 0) continue; // Config.validate rejects these; belt+braces.
        const wu: u32 = @intCast(w);
        if (wu <= intrinsic_w) {
            buf[n] = wu;
            n += 1;
        }
    }
    if (n == 0) {
        buf[0] = intrinsic_w;
        return buf[0..1];
    }
    std.mem.sort(u32, buf[0..n], {}, std.sort.asc(u32));
    var out: usize = 1;
    for (buf[1..n]) |w| {
        if (w != buf[out - 1]) {
            buf[out] = w;
            out += 1;
        }
    }
    return buf[0..out];
}

/// Aspect-preserving height for a target width (round half up, min 1).
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing.
pub fn heightFor(intrinsic_w: u32, intrinsic_h: u32, width: u32) u32 {
    const h = (@as(u64, intrinsic_h) * width + intrinsic_w / 2) / intrinsic_w;
    return @intCast(@max(h, 1));
}

/// `<stem>.<hash8>.<width>.<codec>` where hash8 covers source bytes AND
/// every transform parameter, so any change — bytes, width, codec, quality,
/// vendored-encoder version — moves the URL. This deliberately closes the
/// caveat docs/assets.md documents for minified CSS (hash over source only).
///
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1). One
/// allocation, and it is the return value.
pub fn variantBasename(
    gpa: Allocator,
    source_basename: []const u8,
    source_bytes: []const u8,
    width: u32,
    codec: Codec,
    quality: u8,
    encoder_version: u32,
) Allocator.Error![]u8 {
    var hasher: Blake3 = .init(.{});
    hasher.update(source_bytes);
    var params: [64]u8 = undefined;
    hasher.update(std.fmt.bufPrint(
        &params,
        ";v1;w={d};c={s};q={d};ev={d}",
        .{ width, @tagName(codec), quality, encoder_version },
    ) catch unreachable);
    var digest: [Blake3.digest_length]u8 = undefined;
    hasher.final(&digest);
    var hex: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{digest[0..4]}) catch unreachable;

    const ext = std.fs.path.extension(source_basename);
    const stem = source_basename[0 .. source_basename.len - ext.len];
    return std.fmt.allocPrint(gpa, "{s}.{s}.{d}.{s}", .{
        stem, &hex, width, @tagName(codec),
    });
}
```

- [ ] **Step 4: Run to verify pass.** `zig build test-images` → PASS. (Adjust the string-literal test constructions if the compiler balks at the `.*`-concat idiom — keep the byte values, not the style.)

- [ ] **Step 5: Commit.** `git commit -m $'Add image variant planning: eligibility, widths, naming (#132)\n\nNames are param-addressed (source bytes + width + codec + quality +\nencoder version) so no stale cache entry can ever be served under a\ncurrent URL — the sharper form of the minified-CSS naming caveat in\ndocs/assets.md, fixed instead of inherited.' -- src/image/plan.zig src/image/tests.zig`

---

### Task 6: Request collection (analyze pass) + the planner (root.zig)

**Files:**
- Create: `src/image/requests.zig`
- Modify: `src/worker.zig` (page-asset arm `:1021-1030`, site-asset arm `:1067-1076`; NOT the build-asset arm — spec exclusion)
- Modify: `src/root.zig` (planner fn + call before `prerenderAll` at `:2643`; also expose the probe: change `src/wuffs.zig`'s `fn parseImageSize` to `pub fn parseImageSize`)
- Modify: `src/Build.zig` (field + deinit)

**Interfaces:**
- Consumes: `plan.SourceRef`, `plan.Map`, `plan.eligible`, `plan.pickWidths`, `plan.heightFor`, `plan.variantBasename`, `webp.WebPGetEncoderVersion`, `wuffs.parseImageSize`.
- Produces: `src/image/requests.zig` global collector — `pub fn register(ref: SourceRef) error{OutOfMemory}!void`, `pub fn take(gpa: Allocator) []SourceRef` (drains, caller frees); `Build.image_variants: plan.Map = .empty`; `root.zig` fn `planImageVariants(io, gpa, build: *Build, opts: ImageOptimize) void`.

- [ ] **Step 1: The collector.** `page_analyze` jobs carry `build: *const Build` (`src/worker.zig:72-77`), so registration cannot write through Build. Use module-level state, the pattern `worker.zig` itself uses (`pub var started`, threadlocal cmark). Create `src/image/requests.zig`:

```zig
//! Mutex-guarded collection point for image-derivation requests (#132).
//!
//! Registration happens inside `page_analyze` worker jobs, which hold
//! `*const Build` — analysis mutates nothing on Build except atomics, and
//! widening that to `*Build` for one feature would surrender the guarantee
//! for every field. Module-level state instead (the worker.zig pattern):
//! one process = one build (dev re-execs per rebuild), and `take` drains.
const std = @import("std");
const plan = @import("plan.zig");

var mu: std.Thread.Mutex = .{};
var requests: std.AutoArrayHashMapUnmanaged(plan.SourceRef, void) = .empty;
var gpa_used: ?std.mem.Allocator = null;

/// Idempotent per ref (a hundred pages referencing one image is one entry).
/// Thread-safe. Allocator contract: the map is owned here until `take`.
pub fn register(gpa: std.mem.Allocator, ref: plan.SourceRef) error{OutOfMemory}!void {
    mu.lock();
    defer mu.unlock();
    gpa_used = gpa;
    _ = try requests.getOrPut(gpa, ref);
}

/// Drain: returns the deduped refs (caller frees with the same gpa) and
/// resets the collector. Called exactly once per build, single-threaded,
/// after the analyze pass's worker.wait().
pub fn take(gpa: std.mem.Allocator) error{OutOfMemory}![]plan.SourceRef {
    mu.lock();
    defer mu.unlock();
    const out = try gpa.dupe(plan.SourceRef, requests.keys());
    requests.deinit(gpa_used orelse gpa);
    requests = .empty;
    return out;
}
```

(Mutex use is fine under `-Dsingle-threaded` — `std.Thread.Mutex` is a no-op there; it is `spawn` that comptime-errors.)

- [ ] **Step 2: Register at the two analyze arms.** In `src/worker.zig`, the page-asset arm — after the existing autosize block at `:1021-1029`, still before `continue :outer`:

```zig
                                        if (b.cfg.getImageOptimize() != null and directive.kind == .image) {
                                            image_requests.register(gpa, .{
                                                .kind = .page,
                                                .variant_id = variant_id,
                                                .path = @intFromEnum(path),
                                                .name = @intFromEnum(name),
                                            }) catch fatal.oom();
                                        }
```

and the site-asset arm after `:1067-1075`'s autosize block:

```zig
                                    if (b.cfg.getImageOptimize() != null and directive.kind == .image) {
                                        image_requests.register(gpa, .{
                                            .kind = .site,
                                            .variant_id = 0,
                                            .path = @intFromEnum(pn.path),
                                            .name = @intFromEnum(pn.name),
                                        }) catch fatal.oom();
                                    }
```

Add `const image_requests = @import("image/requests.zig");` to worker.zig's imports. Check the surrounding scope for the exact local names (`variant_id` is a field on the job payload — grep the enclosing function's signature; use whatever identifier holds the current variant id at that arm, e.g. `pa.variant_id` or a captured local).

- [ ] **Step 3: The planner.** In `src/root.zig`, add above `computeAssetFingerprints` (`:3184`):

```zig
/// Expand collected image-derivation requests into named variants (#132).
/// Runs ONCE, single-threaded, after the analyze pass and before the render
/// pass — the map is read lock-free by render workers, exactly the
/// asset_fingerprints discipline (see that field's comment in Build.zig).
///
/// Runs on the incremental dev path too, like fingerprinting: names are
/// pure functions of (bytes, params), so recomputing reproduces the URLs
/// the previous full build installed. Derive JOBS are still skipped there
/// (the install phase early-returns), matching site-asset behavior.
///
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1) for scratch;
/// basenames and variant slices stored in `build.image_variants` are
/// gpa-owned by Build and freed in Build.deinit.
fn planImageVariants(io: Io, gpa: Allocator, build: *Build, opts: ImageOptimize) void {
    const image_requests = @import("image/requests.zig");
    const plan = @import("image/plan.zig");
    const webp = @import("image/webp.zig");

    const refs = image_requests.take(gpa) catch fatal.oom();
    defer gpa.free(refs);
    if (refs.len == 0) return;

    var p = progress.start("Plan image variants", refs.len);
    defer p.end();

    const encoder_version: u32 = @intCast(webp.WebPGetEncoderVersion());
    const quality: u8 = @intCast(opts.quality);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (refs) |ref| {
        p.completeOne();
        const dir: Io.Dir, const st, const pt = switch (ref.kind) {
            .site => .{ build.site_assets_dir, &build.st, &build.pt },
            .page => blk: {
                const v = &build.variants[ref.variant_id];
                break :blk .{ v.content_dir, &v.string_table, &v.path_table };
            },
        };
        const pn: PathName = .{
            .path = @enumFromInt(ref.path),
            .name = @enumFromInt(ref.name),
        };
        const rel = std.fmt.bufPrint(&path_buf, "{f}", .{
            pn.fmt(st, pt, null, "/"),
        }) catch continue;

        // Slurp: unlike fingerprinting (which must touch EVERY asset), this
        // only reads images something actually referenced, and the derive
        // job will decode the whole file anyway.
        const bytes = dir.readFileAlloc(io, rel, gpa, .limited(512 * 1024 * 1024)) catch |err| {
            fatal.msg("error: image_optimize: cannot read '{s}': {s}\n", .{ rel, @errorName(err) });
        };
        defer gpa.free(bytes);

        if (!plan.eligible(bytes)) continue; // plain <img>, spec §7

        const size = wuffs.parseImageSize(gpa, bytes) catch continue;
        const iw = std.math.cast(u32, size.w) orelse continue;
        const ih = std.math.cast(u32, size.h) orelse continue;
        if (iw == 0 or ih == 0) continue;

        var widths_buf: [65]u32 = undefined;
        const widths = plan.pickWidths(
            opts.widths[0..@min(opts.widths.len, 64)],
            iw,
            &widths_buf,
        );
        // PR A: single variant — the largest surviving width.
        const chosen = widths[widths.len - 1 ..];

        const basename = pn.name.slice(st);
        const variants = gpa.alloc(plan.Variant, chosen.len) catch fatal.oom();
        for (chosen, variants) |w, *out| {
            out.* = .{
                .width = w,
                .height = plan.heightFor(iw, ih, w),
                .codec = .webp,
                .basename = plan.variantBasename(
                    gpa,
                    basename,
                    bytes,
                    w,
                    .webp,
                    quality,
                    encoder_version,
                ) catch fatal.oom(),
            };
        }
        build.image_variants.putNoClobber(gpa, ref, .{
            .intrinsic_w = iw,
            .intrinsic_h = ih,
            .variants = variants,
        }) catch fatal.oom();
    }
}
```

Call it right before the SPA-prerender block (`src/root.zig:2643`), with a comment mirroring the fingerprint placement comment (`:1070-1088`):

```zig
    // Image-variant planning (#132) sits HERE — after the analyze pass has
    // collected every image reference, before the render pass consults the
    // map lock-free. Disk builds only (fingerprinting's rationale: an
    // in-memory build writes no tree), but INCLUDING incremental ones, so
    // re-rendered pages emit the same param-addressed URLs the previous
    // full build installed.
    if (build.mode == .disk) {
        if (build.cfg.getImageOptimize()) |img_opts| {
            planImageVariants(io, gpa, &build, img_opts);
        }
    }
```

Make `parseImageSize` in `src/wuffs.zig` `pub` (it stays where it is; root.zig already imports the file — grep `@import("wuffs.zig")` in root.zig to confirm the import name and add it if absent).

- [ ] **Step 4: Store + free.** In `src/Build.zig`, after `asset_fingerprints` (`:78`):

```zig
/// Named image variants (#132): filled once by root.zig's planImageVariants
/// before the render pass, read lock-free by the render workers (the
/// asset_fingerprints discipline). Empty unless `image_optimize` is set.
/// Keys' path/name ints are interned in the SourceRef's owning tables
/// (site: Build.st/pt; page: that variant's tables). Values gpa-owned.
image_variants: @import("image/plan.zig").Map = .empty,
```

In `Build.deinit` (`:176`), free it (mirror how `asset_fingerprints` is freed — grep `asset_fingerprints` in `deinit`):

```zig
    {
        var it = b.image_variants.valueIterator();
        while (it.next()) |planned| {
            for (planned.variants) |v| gpa.free(v.basename);
            gpa.free(planned.variants);
        }
        var m = b.image_variants;
        m.deinit(gpa);
    }
```

(Match deinit's existing mutability idiom — it takes `*const Build`, so copy-then-deinit like the other unmanaged maps there; follow the local pattern.)

- [ ] **Step 5: Compile + behavioral no-op check.** `zig build check`, `zig build check -Dsingle-threaded`, `zig build test` (snapshots — must be untouched: feature off ⇒ collector never registers). Run the existing e2e `bash tests/assets/fingerprint.sh` as a canary.

- [ ] **Step 6: Commit.** `git commit -m $'Collect image refs at analyze, plan named variants before render (#132)\n\npage_analyze holds *const Build, so requests go through a mutex-guarded\nmodule-level collector (the worker.zig global pattern) rather than\nwidening analysis to *Build. The planner fills Build.image_variants\nwrite-once/pre-render — the asset_fingerprints lock-free discipline —\nand runs on incremental rebuilds for URL stability, while derive jobs\nstay full-build-only.' -- src/image/requests.zig src/worker.zig src/root.zig src/Build.zig src/wuffs.zig`

---

### Task 7: Derive jobs + `.zigapagos-cache/images/`

**Files:**
- Create: `src/image/derive.zig`
- Modify: `src/worker.zig` (Job union `:44-93`, `runOneJob` `:175+`)
- Modify: `src/root.zig` (schedule jobs in the install phase, `:2959` region)

**Interfaces:**
- Consumes: `decode.decode`, `resample.resize`, `webp.WebPEncodeRGBA`/`WebPEncodeLosslessRGBA`/`WebPFree`, `Build.image_variants`.
- Produces: `worker.Job` variant `image_derive: struct { progress: std.Progress.Node, build: *const Build, ref: plan.SourceRef, planned: *const plan.Planned, cache_dir: Io.Dir, output_dir: Io.Dir }`; `pub fn run(io: Io, gpa: Allocator, job: <that payload type>) void` in `src/image/derive.zig`.

- [ ] **Step 1: The job.** Add to the `Job` union in `src/worker.zig` after `variant_assets_install`:

```zig
    /// One source image: decode once, resample+encode every planned
    /// variant, staging through .zigapagos-cache/images (#132).
    image_derive: struct {
        progress: std.Progress.Node,
        build: *const Build,
        ref: @import("image/plan.zig").SourceRef,
        planned: *const @import("image/plan.zig").Planned,
        cache_dir: Io.Dir,
        output_dir: Io.Dir,
    },
```

and in `runOneJob`'s switch:

```zig
        .image_derive => |d| {
            @import("image/derive.zig").run(io, gpa, d);
            d.progress.completeOne();
        },
```

(Follow the exact completion idiom neighboring arms use — some jobs complete their progress node inside the handler; match `variant_assets_install`.)

- [ ] **Step 2: The worker.** Create `src/image/derive.zig`:

```zig
//! The derive job (#132): cache-or-compute each planned variant.
//!
//! Cache protocol: `.zigapagos-cache/images/<variant-basename>` — the name
//! is param-addressed (plan.variantBasename), so existence IS validity and
//! there is no invalidation logic to get wrong. Writes go through a
//! `.tmp.<basename>` sibling + rename so a killed build can never leave a
//! half-written file under a valid name. No eviction in v1 (documented).
//!
//! Failure policy (spec §7): by now the render pass has already emitted
//! URLs for these variants, so any failure is a broken <picture> in
//! shipped HTML — fatal, never silent. (Contrast src/wuffs.zig's probe.)
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fatal = @import("../fatal.zig");
// NOTE: this file is imported ONLY from worker.zig/root.zig (exe graph);
// it is not part of the test-images module root, so the upward import of
// fatal.zig is legal here — the standalone suite covers decode/resample/
// plan, and tests/images/*.sh covers this orchestration end-to-end.
const plan = @import("plan.zig");
const decode = @import("decode.zig");
const resample = @import("resample.zig");
const webp = @import("webp.zig");
```

Wait — **module-root constraint check**: `derive.zig` lives in `src/image/` and imports `../fatal.zig`, which would poison the `test-images` standalone module if it were reachable from `src/image/tests.zig`. It is not (`tests.zig` never imports it) — keep it that way and say so, as above. Continue the file:

```zig
pub fn run(
    io: Io,
    gpa: Allocator,
    d: anytype, // the worker.Job.image_derive payload
) void {
    const build = d.build;
    // Resolve source dir + relative path exactly like planImageVariants.
    const dir: Io.Dir, const st, const pt = switch (d.ref.kind) {
        .site => .{ build.site_assets_dir, &build.st, &build.pt },
        .page => blk: {
            const v = &build.variants[d.ref.variant_id];
            break :blk .{ v.content_dir, &v.string_table, &v.path_table };
        },
    };
    const pn: @import("../PathTable.zig").PathName = .{
        .path = @enumFromInt(d.ref.path),
        .name = @enumFromInt(d.ref.name),
    };
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = std.fmt.bufPrint(&path_buf, "{f}", .{
        pn.fmt(st, pt, null, "/"),
    }) catch unreachable;

    // Destination directory inside the output tree = the source's own dir
    // (variants sit beside the fallback original).
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;

    var decoded: ?decode.Decoded = null;
    defer if (decoded) |img| img.deinit(gpa);

    for (d.planned.variants) |variant| {
        const dest = std.fmt.bufPrint(&dest_buf, "{f}{s}", .{
            pn.path.fmt(pt, st), variant.basename,
        }) catch unreachable;
        _ = dest; // see Step 3: exact dest formatting

        // Cache hit: stat-compare copy into the output tree and move on.
        if (d.cache_dir.updateFile(io, variant.basename, d.output_dir, dest, .{})) |_| {
            continue;
        } else |err| switch (err) {
            error.FileNotFound => {}, // miss: fall through and compute
            else => fatal.file(variant.basename, err),
        }

        // Miss: decode the source once for all missed variants.
        if (decoded == null) {
            const bytes = dir.readFileAlloc(io, rel, gpa, .limited(512 * 1024 * 1024)) catch |err|
                fatal.msg("error: image_optimize: cannot read '{s}': {s}\n", .{ rel, @errorName(err) });
            defer gpa.free(bytes);
            decoded = decode.decode(gpa, bytes) catch |err|
                fatal.msg("error: image_optimize: cannot decode '{s}': {s}\n", .{ rel, @errorName(err) });
        }
        const img = decoded.?;

        const small = resample.resize(gpa, img.w, img.h, img.rgba, variant.width, variant.height) catch fatal.oom();
        defer gpa.free(small);

        // PNG sources -> lossless; photographic -> lossy at cfg quality.
        const lossless = std.mem.endsWith(u8, rel, ".png") or std.mem.endsWith(u8, rel, ".PNG");
        var out: ?[*]u8 = null;
        defer webp.WebPFree(out);
        const n = if (lossless)
            webp.WebPEncodeLosslessRGBA(small.ptr, @intCast(variant.width), @intCast(variant.height), @intCast(variant.width * 4), &out)
        else
            webp.WebPEncodeRGBA(small.ptr, @intCast(variant.width), @intCast(variant.height), @intCast(variant.width * 4), quality(build), &out);
        if (n == 0) fatal.msg("error: image_optimize: WebP encode failed for '{s}' at {d}px\n", .{ rel, variant.width });

        // Stage into the cache atomically, then install.
        writeCacheAtomic(io, d.cache_dir, variant.basename, out.?[0..n]) catch |err|
            fatal.msg("error: image_optimize: cannot write cache entry '{s}': {s}\n", .{ variant.basename, @errorName(err) });
        _ = d.cache_dir.updateFile(io, variant.basename, d.output_dir, dest, .{}) catch |err|
            fatal.file(variant.basename, err);
    }
}

fn quality(build: anytype) f32 {
    return @floatFromInt(build.cfg.getImageOptimize().?.quality);
}

/// tmp + rename so a killed build never leaves a torn file under a valid
/// (param-addressed) cache name. Contract 3: allocates nothing.
fn writeCacheAtomic(io: Io, cache_dir: Io.Dir, basename: []const u8, bytes: []const u8) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".tmp.{s}", .{basename});
    {
        const f = try cache_dir.createFile(io, tmp, .{});
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.writeAll(bytes);
    }
    try cache_dir.rename(io, tmp, cache_dir, basename);
}
```

**API-truth steps while implementing** (the plan's code is the design; the repo is the authority on exact `Io.Dir` spellings): `grep -n 'updateFile\|createFile\|rename' src/root.zig src/Variant.zig` and copy those call shapes. Two known deltas to resolve the same way: (a) the `dest` path must be the source-relative path with the basename swapped — for page assets prefixed with `v.output_path_prefix` exactly as the summary block at `src/root.zig:3084-3088` formats it; write a small local `fn destPath` mirroring that expression, and delete the placeholder `_ = dest;` line; (b) `pn.path.fmt(...)` arg order — copy from an existing `path.fmt(` call site.

- [ ] **Step 3: Schedule.** In `src/root.zig`'s install phase, right after the `variant_assets_install` scheduling loop (`:2960-2968`), add:

```zig
    // Image derive jobs (#132). Scheduled with the install jobs — the
    // render pass has already emitted the variant URLs; this is where the
    // promised bytes get produced (cache) and placed (output tree). The
    // same worker.wait() below is the barrier.
    if (build.image_variants.count() > 0) {
        const cache_dir = build.base_dir.createDirPathOpen(
            io,
            ".zigapagos-cache/images",
            .{},
        ) catch |err| fatal.dir(".zigapagos-cache/images", err);
        var it = build.image_variants.iterator();
        while (it.next()) |entry| {
            worker.addJob(io, .{ .image_derive = .{
                .progress = progress_install_assets,
                .build = &build,
                .ref = entry.key_ptr.*,
                .planned = entry.value_ptr,
                .cache_dir = cache_dir,
                .output_dir = build.mode.disk.output_dir,
            } });
        }
    }
```

(For multilingual site assets the output dir must be the same `site_assets_install_dir` the install loop computes at `:2972-2990`; hoist that `switch` above both consumers and pass it for `.site` refs — single-locale sites are unaffected since it degenerates to `output_dir`. Keep `.page` refs on `output_dir`.)

- [ ] **Step 4: Compile + gates.** `zig build check`, `zig build check -Dsingle-threaded` (the job handler contains no `std.Thread` use — the pool does), `bash scripts/check-allocator-contracts.sh`.

- [ ] **Step 5: Commit.** `git commit -m $'Derive image variants as worker jobs behind a content-addressed cache (#132)\n\nParam-addressed names mean cache existence IS validity — no invalidation\nlogic to get wrong; tmp+rename keeps a killed build from leaving torn\nbytes under a valid name. Failures are fatal (spec: the render pass\nalready promised these URLs), the opposite of the size probe\'s silence.' -- src/image/derive.zig src/worker.zig src/root.zig`

---

### Task 8: `<picture>` emission

**Files:**
- Modify: `src/render/html.zig` (`.image` arm `:466-503`, plus a `printVariantUrl` helper beside `printUrl` `:623`)

**Interfaces:**
- Consumes: `ctx._meta.build.image_variants`, `plan.SourceRef`, `printLinkPrefix`/`printAssetUrlPrefix` (existing).
- Produces: HTML shape `<picture><source type="image/webp" srcset="…"><img …></picture>` when the map has variants for the directive's source; byte-identical output otherwise.

- [ ] **Step 1: Key lookup helper.** Above the `.image` arm in `src/render/html.zig`:

```zig
/// The image_variants entry for an image directive's source, or null when
/// the feature is off / the source was ineligible / it's a kind we don't
/// optimize (URLs, external, build assets — spec's out-of-scope list).
/// Contract 3: allocates nothing.
fn imageVariantsFor(
    ctx: *const context.Root,
    page: *const context.Page,
    src: supermd.context.Src,
) ?*const @import("../image/plan.zig").Planned {
    const map = &ctx._meta.build.image_variants;
    if (map.count() == 0) return null;
    const ref: @import("../image/plan.zig").SourceRef = switch (src) {
        .page_asset => |pa| .{
            .kind = .page,
            .variant_id = page._scan.variant_id,
            .path = pa.resolved.path,
            .name = pa.resolved.name,
        },
        .site_asset => |sa| .{
            .kind = .site,
            .variant_id = 0,
            .path = sa.resolved.path,
            .name = sa.resolved.name,
        },
        else => return null,
    };
    return map.getPtr(ref);
}
```

- [ ] **Step 2: Variant URL printer.** The URL is the fallback's URL with the basename swapped — mirror the two `printUrl` arms (`:688-726`) exactly:

```zig
/// Print a derived variant's URL: the same prefix + directory the fallback
/// original gets from printUrl, with the variant basename substituted.
/// The basename is already content-addressed, so fingerprint.fmtUrl is
/// deliberately NOT consulted (double-hashing would desync install/link).
fn printVariantUrl(
    ctx: *const context.Root,
    page: *const context.Page,
    src: supermd.context.Src,
    basename: []const u8,
    w: *Writer,
) !void {
    switch (src) {
        .page_asset => |pa| {
            try ctx.printLinkPrefix(w, page._scan.variant_id, page != ctx.page);
            const path: Path = @enumFromInt(pa.resolved.path);
            const v = ctx._meta.build.variants[page._scan.variant_id];
            for (path.slice(&v.path_table)) |c| {
                try w.writeAll(c.slice(&v.string_table));
                try w.writeAll("/");
            }
            try w.writeAll(basename);
        },
        .site_asset => |sa| {
            try printAssetUrlPrefix(ctx, page, w, false);
            const path: Path = @enumFromInt(sa.resolved.path);
            for (path.slice(&ctx._meta.build.pt)) |c| {
                try w.writeAll(c.slice(&ctx._meta.build.st));
                try w.writeAll("/");
            }
            try w.writeAll(basename);
        },
        else => unreachable, // imageVariantsFor filtered these
    }
}
```

(Copy the exact path-components iteration from `fingerprint.UrlFormatter.format` (`src/fingerprint.zig:184-191`) / the `printUrl` arms — if `Path.slice` needs different receivers, follow those call sites.)

- [ ] **Step 3: Wrap the arm.** In the `.image` `.enter` arm (`:467-496`), after the `linked` anchor is opened and before `try w.writeAll("<img");`:

```zig
                const planned = imageVariantsFor(ctx, page, img.src.?);
                if (planned) |p| {
                    try w.writeAll("<picture>");
                    // PR A: one webp variant, single-entry srcset (no `w`
                    // descriptor, so no sizes attribute needed). PR B turns
                    // this into the full width list + sizes.
                    try w.writeAll("<source type=\"image/webp\" srcset=\"");
                    try printVariantUrl(ctx, page, img.src.?, p.variants[0].basename, w);
                    try w.writeAll("\">");
                }
```

and in the `.exit`-side of the enter block, right after the existing `try w.writeAll(">");` that closes the `<img` tag (`:493`), before the `linked` close:

```zig
                if (planned != null) try w.writeAll("</picture>");
```

Note the anchor/figure nesting: `<a>`/`<figure>` wrap the whole `<picture>` — the `<picture>` open must come *after* the `<a href…>` open (it does, per the insertion point) and close before `</a>` (it does).

- [ ] **Step 4: Sanity run.** `zig build check`, `zig build test` (snapshots: unchanged — no fixture sets the config). Real behavior is proven by Task 9's e2e; do not hand-verify by eyeball alone.

- [ ] **Step 5: Commit.** `git commit -m $'Emit <picture> with WebP variant for optimized images (#132)\n\nThe fallback <img> keeps its exact pre-existing URL/attribute path, so\nfeature-off output is byte-identical and no-WebP clients lose nothing\nbut bytes. Variant URLs skip fingerprint.fmtUrl on purpose: the basename\nis already content-addressed and double-hashing would desync link vs\ninstall.' -- src/render/html.zig`

---

### Task 9: e2e proof, docs skeleton, PR A

**Files:**
- Create: `tests/images/optimize.sh`
- Create: `docs/images.md` (skeleton — full version in PR B)
- Modify: `docs/assets.md` (derived-assets note), `changelog.d/` (new entry — copy an existing file's naming pattern)

**Interfaces:** none new — this task proves the pipeline end-to-end.

- [ ] **Step 1: Write the failing e2e.** Create `tests/images/optimize.sh` cribbing `tests/assets/fingerprint.sh`'s scaffold verbatim (shebang, `set -euo pipefail`, `ZIGAPAGOS_BIN` resolution, `mktemp -d` + trap, `fail()`; and its invocation idiom for running a release build — copy the exact command line it uses). Fixture: single-locale site, `image_optimize = .{}` in `zigapagos.ziggy`, one content page whose `index.smd` body contains

```
[A test image.]($image.asset("photo.jpg").alt("test photo"))
```

with `photo.jpg` copied from `$REPO/src/cli/init/content/blog/first-post/retro-cover.jpg` into the page's directory (page asset), and a second `[]($image.siteAsset("art/wide.jpg"))` with the same JPEG copied under `assets/art/`. Checks:

```bash
HTML="$OUT/index.html"
# (1) <picture> shape with a webp source.
grep -q '<picture><source type="image/webp" srcset="' "$HTML" || fail "no <picture> emitted"
# (2) the variant file the HTML references exists and is really WebP.
VAR_URL=$(grep -o 'srcset="[^"]*"' "$HTML" | head -1 | sed 's/srcset="//;s/"$//')
VAR_PATH="$OUT/${VAR_URL#/}"
[[ -f "$VAR_PATH" ]] || fail "srcset points at missing file: $VAR_URL"
head -c 12 "$VAR_PATH" | grep -q 'WEBP' || fail "variant is not a WebP container"
# (3) name shape: <stem>.<8hex>.<width>.webp
basename "$VAR_PATH" | grep -Eq '^photo\.[0-9a-f]{8}\.[0-9]+\.webp$' || fail "bad variant name"
# (4) fallback <img> still points at the untouched original, which exists.
grep -q '<img src="' "$HTML" || fail "fallback <img> missing"
ORIG_URL=$(grep -o '<img src="[^"]*"' "$HTML" | head -1 | sed 's/<img src="//;s/"$//')
[[ -f "$OUT/${ORIG_URL#/}" ]] || fail "fallback original missing"
cmp -s "$OUT/${ORIG_URL#/}" "$WORK/site/content/photo.jpg" || fail "original was modified"
# (5) the site-asset image also got a variant (second URL seam).
grep -c '<picture>' "$HTML" | grep -q '^2$' || fail "expected 2 pictures"
# (6) cache: entry exists; a rebuild does not re-encode (mtime stable).
CACHE=$(ls "$WORK/site/.zigapagos-cache/images/" | head -1)
[[ -n "$CACHE" ]] || fail "cache empty after build"
M1=$(stat -c %Y "$WORK/site/.zigapagos-cache/images/$CACHE")
sleep 1.1
<rebuild command>
M2=$(stat -c %Y "$WORK/site/.zigapagos-cache/images/$CACHE")
[[ "$M1" == "$M2" ]] || fail "rebuild re-encoded a cached variant"
# (7) control: config WITHOUT image_optimize emits no <picture>, no .webp.
<second fixture / rebuild with the field removed>
grep -q '<picture>' "$HTML" && fail "feature off but <picture> emitted"
find "$OUT" -name '*.webp' | grep -q . && fail "feature off but webp emitted"
```

(`<rebuild command>` = the same invocation the script used for the first build; on macOS `stat -f %m` — crib the portability idiom from an existing script if one handles it, otherwise guard with `uname`.)

- [ ] **Step 2: Run to verify it fails.** `bash tests/images/optimize.sh` → FAIL is only meaningful at check (1) *before* Tasks 6–8 are merged; since this task runs after them, instead verify the test pins something: comment out the `planImageVariants` call in `src/root.zig`, run → must FAIL at check (1); restore, run → all checks PASS. This is the mandated fail-without-the-fix proof for the whole pipeline.

- [ ] **Step 3: Docs skeleton + changelog + website.** `docs/images.md`: title, one-paragraph feature summary, the config block with field docs (copy from the spec §1), the `<picture>` shape (spec §2), the cache location + "no eviction in v1" limitation, the out-of-scope list, and a "Full documentation lands with srcset support (PR B)" note. `docs/assets.md`: under the fingerprinting section's exclusion list add a "Derived image variants" paragraph: named by `plan.variantBasename` (source bytes + transform params — contrast the minified-CSS caveat at `:167-173`, which this deliberately fixes), pruned for free (variants derive only from referenced directives). New `changelog.d/` entry per the local naming convention (`ls changelog.d/` and copy the pattern) — **a changelog fragment is a hard pre-PR gate**. **Website:** survey `site/content/` for pages that enumerate features or config (e.g. feature list, docs/config pages — `grep -ril 'speculation_rules\|asset_fingerprint' site/content` finds where sibling config flags are documented) and add `image_optimize` wherever those siblings appear; keep the copy scoped to what PR A ships (single WebP variant, srcset coming in PR B). `bash site/build.sh` must pass afterward.

- [ ] **Step 4: The full gate battery.**

```sh
git ls-files -z '*.zig' | xargs -0 -r zig fmt --check
zig build check
zig build check -Dsingle-threaded
zig build test
zig build test-images test-islands test-props test-migrate test-sidecar test-init test-release test-debug test-spa test-assets test-e2e test-dev test-doctor test-slugs test-validate test-explain test-diag test-summary
bash scripts/check-allocator-contracts.sh
bash tests/images/optimize.sh
bash tests/assets/fingerprint.sh
bash tests/branding.sh
```

Every command unpiped, checking `$?` per the zsh rule. All green.

- [ ] **Step 5: NO_SLOP review gate.** Before any PR is opened, a dedicated whole-branch review against `NO_SLOP.md` (read it first, review second): every allocator-taking function added by PR A verified against its stated §2.2a contract (not just labeled — verified), plus the rest of the NO_SLOP bar (naming, comment density carrying the why, no dead code, no drive-by abstraction). Findings feed the normal fix loop before the PR opens.

- [ ] **Step 6: PR A.** Commit remaining files (`git commit -- tests/images/optimize.sh docs/images.md docs/assets.md changelog.d/<entry> site/<touched files>`), then run the **tell-a-git-story** skill over the branch, then `gh pr create --repo valthon/zigapagos --title "Build-time image optimization: resample + WebP <picture> (#132, PR A)"` with a body summarizing spec §1–§9 PR-A scope and the e2e evidence.

---

### Task 10 (PR B): Full srcset — multi-width variants + `sizes`

**Files:**
- Modify: `src/root.zig` (`planImageVariants`: drop the `chosen = widths[widths.len - 1 ..]` truncation — use all of `widths`)
- Modify: `src/render/html.zig` (multi-entry srcset with `w` descriptors + `sizes`)
- Modify: `tests/images/optimize.sh` (widths checks)

**Interfaces:**
- Consumes: `Planned.variants` now length N (ascending width order — the planner already builds it sorted because `pickWidths` sorts).
- Produces: `<source type="image/webp" srcset="<url> 480w, <url> 800w" sizes="100vw">`.

- [ ] **Step 1: Extend the e2e first.** In `tests/images/optimize.sh`, set `.image_optimize = .{ .widths = .{ 200, 400, 100000 } }` (100000 exceeds any fixture image and must be filtered). New checks: srcset contains exactly `" 200w, "` and `" 400w"` descriptors and no `100000`; `sizes="100vw"` present; both named variant files exist and are WebP; check (3)'s name regex still matches each. Run → FAIL (single-entry srcset).

- [ ] **Step 2: Planner.** In `planImageVariants` replace the two `chosen` lines with `const chosen = widths;` and delete the "PR A: single variant" comment. Multi-width means the `variants` slice grows — no other change; naming/dirs/cache already parameterize on width.

- [ ] **Step 3: Emission.** Replace Task 8's single-entry srcset block:

```zig
                if (planned) |p| {
                    try w.writeAll("<picture>");
                    try w.writeAll("<source type=\"image/webp\" srcset=\"");
                    var first = true;
                    for (p.variants) |variant| {
                        if (variant.codec != .webp) continue;
                        if (!first) try w.writeAll(", ");
                        first = false;
                        try printVariantUrl(ctx, page, img.src.?, variant.basename, w);
                        try w.print(" {d}w", .{variant.width});
                    }
                    try w.writeAll("\" sizes=\"");
                    try w.print("{f}", .{HtmlSafe{ .bytes = ctx._meta.build.cfg.getImageOptimize().?.sizes }});
                    try w.writeAll("\">");
                }
```

(`HtmlSafe` is the escaping formatter already used at `:603` — attribute-escape the config string; check its exact attribute-context suitability by finding how `title` attrs are printed and match.)

- [ ] **Step 4: Run.** `bash tests/images/optimize.sh` → PASS. Snapshot suites unchanged (`zig build test`). Commit: `git commit -m $'Emit full responsive srcset with sizes (#132 PR B)\n\nWidths come from config filtered per-image to <= intrinsic; the single-\nvariant PR A emission was the same machinery truncated, so this is the\ntruncation removed plus w-descriptors — which the HTML spec requires be\naccompanied by sizes, emitted verbatim from config.' -- src/root.zig src/render/html.zig tests/images/optimize.sh`

---

### Task 11 (PR B): Interchange PNG writer

**Files:**
- Create: `src/image/png.zig`
- Modify: `src/image/tests.zig`

**Interfaces:**
- Produces: `pub fn write(gpa: Allocator, w: u32, h: u32, rgba: []const u8) error{OutOfMemory}![]u8` — a valid PNG (8-bit RGBA, stored/uncompressed deflate blocks). Exists solely to hand pixels to the external AVIF encoder; size is irrelevant (temp file).

- [ ] **Step 1: Failing test** — round-trip through Task 3's decoder, which makes wuffs the oracle:

```zig
test "images: png writer round-trips through wuffs" {
    const png = @import("png.zig");
    const decode = @import("decode.zig");
    const gpa = std.testing.allocator;
    var rgba: [3 * 2 * 4]u8 = undefined;
    for (&rgba, 0..) |*b, i| b.* = @truncate(i * 37 + 11);
    const encoded = try png.write(gpa, 3, 2, &rgba);
    defer gpa.free(encoded);
    const back = try decode.decode(gpa, encoded);
    defer back.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 3), back.w);
    try std.testing.expectEqual(@as(u32, 2), back.h);
    try std.testing.expectEqualSlices(u8, &rgba, back.rgba);
}
```

Run → FAIL.

- [ ] **Step 2: Implement.** PNG = 8-byte signature; IHDR (w, h, bit depth 8, color type 6, 0, 0, 0); one IDAT containing a zlib stream (`0x78 0x01` header, stored deflate blocks of ≤ 65535 bytes each wrapping the filtered scanlines — every scanline prefixed with filter byte 0 — then a big-endian Adler-32 of the filtered data); IEND. CRC-32 per chunk over type+data (`std.hash.Crc32`), Adler via `std.hash.Adler32`. Stored deflate block header: `final:u1, type:00, pad to byte, len:u16le, ~len:u16le`. ~60 lines; contract 1 (one escaping allocation). No `std.compress` dependency — stored blocks need none, which is the point (0.16's flate-compression API status is then irrelevant).

- [ ] **Step 3: Run → PASS. Commit** `-- src/image/png.zig src/image/tests.zig` with a message noting it exists as AVIF interchange, stored-deflate on purpose.

---

### Task 12 (PR B): AVIF hatch — external encoder

**Files:**
- Modify: `src/root.zig` (`planImageVariants`: plan `.avif` variants when `opts.avif_encoder != null` — for each chosen width, an avif variant *before* the webp one per spec's best-first `<picture>` order… planning order doesn't matter, emission filters by codec; just append `.avif` variants with `codec = .avif` and basenames from `variantBasename(…, .avif, …)`)
- Modify: `src/image/derive.zig` (encode `.avif` variants by spawning the configured binary)
- Modify: `src/render/html.zig` (an `image/avif` `<source>` line *above* the webp one, same srcset/sizes shape, filtering `codec == .avif`)
- Modify: `tests/images/optimize.sh` (stub-encoder e2e)

**Interfaces:**
- Consumes: `png.write` (temp interchange), `std.process.Child` (grep `src/islands/props_check.zig` or `installMinifiedCss` for the repo's child-spawn idiom under `std.Io` and copy it exactly).
- Produces: for a variant with `codec == .avif`: temp PNG at `.zigapagos-cache/images/.tmp.<basename>.png` → spawn `<avif_encoder> <tmp.png> <tmp.avif>` → rename into cache → install. Binary missing or nonzero exit = `fatal.msg` naming the binary, the source, and the exit code (spec §6: the user opted in; silence would be a lie).

- [ ] **Step 1: e2e with a stub encoder** (hermetic — CI has no avifenc). In the test's `$WORK`, write `avifenc-stub`:

```bash
#!/usr/bin/env bash
# argv: <in.png> <out.avif> — writes a marker so the test can verify the
# pipeline without a real AV1 encoder.
printf 'STUBAVIF' > "$2"
cat "$1" >> "$2"
```

`chmod +x`, set `.avif_encoder = "<abs path to stub>"` in the fixture config. Checks: HTML has `<source type="image/avif"` BEFORE the webp source line; each referenced `.avif` file exists and starts with `STUBAVIF`; and a run with `.avif_encoder = "/nonexistent/avifenc"` FAILS the build with a message naming the binary (assert non-zero exit and `grep` the stderr capture). Run → FAIL (no avif support yet).

- [ ] **Step 2: Implement** planner + derive + emission per the interface block. In `derive.zig`, the avif arm: reuse the already-decoded/resampled pixels (restructure the variant loop: resample once per width, then encode per codec), `png.write` → temp file → spawn → rename → install; delete temps in a `defer`. Emission: a second source-line loop with `codec == .avif`, placed above the webp `<source>`.

- [ ] **Step 3: Run** `bash tests/images/optimize.sh` → PASS, full gate battery green. Commit with the spec-§6 rationale in the message.

---

### Task 13 (PR B): Full docs + migration mapping + PR

**Files:**
- Modify: `docs/images.md` (complete: config reference incl. widths/sizes/avif_encoder, `<picture>` semantics, cache + eviction status, failure policy table (silent-passthrough vs fatal), dev-loop behavior, out-of-scope)
- Modify: `docs/assets.md` (finalize the derived-assets paragraph), `docs/ROADMAP.md` (replace any image line with reality)
- Modify: the Astro-migration mapping — `docs/migration/` AND its mirrored copy under the in-repo skill (`grep -rn 'astro' .claude/skills/ skills/ 2>/dev/null` to locate; the **mirror gate fails if only one side changes** — see the drift gate shipped with #131): add `<Image>`/`astro:assets` → `image_optimize` rows with the semantic deltas (site-wide widths not per-image; no upscaling; AVIF needs an external encoder)
- Modify: `changelog.d/` entry for PR B

**Steps:**

- [ ] **Step 1:** Write the docs above; run `bash tests/branding.sh` and the docs/skills mirror gate (find its script via `grep -rn 'migration' .github/workflows/ci.yml` and run what CI runs).
- [ ] **Step 2:** Full gate battery from Task 9 Step 4, all green.
- [ ] **Step 3:** Commit docs, run **tell-a-git-story** over PR B's commits, `gh pr create --repo valthon/zigapagos` (base: PR A's branch) titled "Image optimization: srcset, sizes, AVIF hatch, docs (#132, PR B)".

---

## Self-Review Notes (already applied)

- **Spec coverage:** §1→T1/T6, §2→T8/T10/T12, §3→T6/T7, §4→T5/T7, §5→T2/T3/T4/T11, §6→T12, §7→T3/T6/T7 (fatal paths) + T5 (silent gate), §8→every task's tests + T9, §9→T9/T13, §10→T9/T13 PR split. Spec amendment (build assets out of scope) is T1 Step 1.
- **Type consistency:** `SourceRef{kind, variant_id, path, name}` is identical in T5 (definition), T6 (register/planner), T7 (job), T8 (lookup). `Planned.variants` ascending-width ordering is asserted by T5's `pickWidths` sort and consumed by T8/T10.
- **Known API-truth points** (each has an explicit grep step, not a guess): `Io.Dir.readFileAlloc`/`createFile`/`rename` spellings (T6/T7), `Path.fmt`/`Path.slice` receivers (T7/T8), child-spawn idiom (T12), `Config.validate` location (T1), analyze-arm local names (T6), progress-completion idiom (T7).
