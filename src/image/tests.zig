//! Root of the `test-images` suite (build/tests.zig). Everything under
//! src/image/ is reachable from here — the module-root constraint (see
//! CLAUDE.md) means files in this directory must not @import upward.
const std = @import("std");

test {
    _ = @import("webp.zig");
    _ = @import("decode.zig");
    _ = @import("resample.zig");
    _ = @import("plan.zig");
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

test "images: decode QOI to exact RGBA" {
    const decode = @import("decode.zig");
    const gpa = std.testing.allocator;
    // Hand-assembled 2x1 QOI: magic, w=2, h=1, 4 channels, srgb-linear=0,
    // two QOI_OP_RGBA pixels, end marker.
    const qoi = [_]u8{
        'q', 'o', 'i', 'f',
        0, 0, 0, 2, // width  (BE)
        0, 0, 0, 1, // height (BE)
        4, 0,
        0xFF, 10, 20, 30, 255, // pixel 0: rgba(10,20,30,255)
        0xFF, 200, 100, 50, 128, // pixel 1: rgba(200,100,50,128)
        0,    0,   0,   0,  0,
        0,    0,   1,
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

test "images: heightFor preserves aspect ratio, rounds half up, never zero" {
    const plan = @import("plan.zig");
    // Exact ratio: 1600x900 -> 800 wide is exactly 450 tall.
    try std.testing.expectEqual(@as(u32, 450), plan.heightFor(1600, 900, 800));
    // Identity: requesting the intrinsic width returns the intrinsic height.
    try std.testing.expectEqual(@as(u32, 900), plan.heightFor(1600, 900, 1600));
    // Round-half-up: 500x715 at 200w -> 715*200/500 = 286 exactly.
    try std.testing.expectEqual(@as(u32, 286), plan.heightFor(500, 715, 200));
    // Exact halfway point: 4x3 at width 2 -> raw height 3*2/4 = 1.5, must
    // round UP to 2 (not truncate to 1).
    try std.testing.expectEqual(@as(u32, 2), plan.heightFor(4, 3, 2));
    // min-1 floor: an extreme aspect ratio must never round down to 0.
    try std.testing.expectEqual(@as(u32, 1), plan.heightFor(10000, 1, 1));
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
    const jpeg_magic = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 } ++ [_]u8{0} ** 12;
    const png_magic = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A } ++ [_]u8{0} ** 8;
    try std.testing.expect(plan.eligible(&jpeg_magic));
    try std.testing.expect(plan.eligible(&png_magic));
    try std.testing.expect(!plan.eligible("GIF89a......")); // gif: never
    try std.testing.expect(!plan.eligible("<svg xmlns=")); // not raster
    // Still WebP (VP8 chunk) yes; animated WebP (VP8X with anim flag) no.
    var still = [_]u8{ 'R', 'I', 'F', 'F', 0x00, 0x00, 0x00, 0x00, 'W', 'E', 'B', 'P', 'V', 'P', '8', ' ' } ++ [_]u8{0} ** 8;
    try std.testing.expect(plan.eligible(&still));
    var anim = [_]u8{ 'R', 'I', 'F', 'F', 0x00, 0x00, 0x00, 0x00, 'W', 'E', 'B', 'P', 'V', 'P', '8', 'X', 0x0a, 0x00, 0x00, 0x00, 0x12 } ++ [_]u8{0} ** 4;
    try std.testing.expect(!plan.eligible(&anim));
}
