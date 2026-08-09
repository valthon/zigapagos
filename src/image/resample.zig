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
