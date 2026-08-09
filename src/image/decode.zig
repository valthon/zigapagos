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

/// 16k x 16k RGBA is 1 GiB; anything bigger is a config error, not a photo.
/// `root.zig`'s `planImageVariants` must reject the same bound BEFORE
/// planning a variant, so an oversized source lands in the documented
/// silent-passthrough bucket (spec §7's "filtered out... never fatal")
/// instead of promising a name this decoder then refuses to fulfil — the
/// two gates share this constant so they can't drift apart again (#132
/// final review, Fix 1).
pub const max_dimension: u32 = 16384;

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
    if (w == 0 or h == 0 or w > max_dimension or h > max_dimension) return error.TooLarge;

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

const max_align: std.mem.Alignment = .of(std.c.max_align_t);
fn allocDecoder(
    gpa: Allocator,
    comptime name: []const u8,
) !struct { []align(max_align.toByteUnits()) u8, *wuffs.wuffs_base__image_decoder } {
    const size = @field(wuffs, "sizeof__wuffs_" ++
        name ++ "__decoder")();
    const init_fn = @field(wuffs, "wuffs_" ++
        name ++ "__decoder__initialize");
    const upcast_fn = @field(wuffs, "wuffs_" ++
        name ++ "__decoder__upcast_as__wuffs_base__image_decoder");

    const decoder_raw = try gpa.alignedAlloc(u8, max_align, size);
    errdefer gpa.free(decoder_raw);
    for (decoder_raw) |*byte| byte.* = 0;

    try wrapErr(init_fn(
        @ptrCast(decoder_raw),
        size,
        wuffs.WUFFS_VERSION,
        wuffs.WUFFS_INITIALIZE__ALREADY_ZEROED,
    ));

    const upcasted = upcast_fn(@ptrCast(decoder_raw)).?;
    return .{ decoder_raw, upcasted };
}

fn wrapErr(status: wuffs.wuffs_base__status) !void {
    if (wuffs.wuffs_base__status__message(&status)) |x| {
        _ = x;
        return error.WuffsError;
    }
}
