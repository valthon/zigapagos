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

/// PNG's 8-byte magic signature. Exported (not inlined into `eligible`)
/// because `derive.zig` needs the SAME check to pick lossless-vs-lossy WebP
/// encoding: `variantBasename` below hashes SOURCE BYTES, not the source's
/// on-disk filename, so the encode choice has to be made the same way —
/// from bytes, never from a `.png`/`.jpg` extension — or two byte-identical
/// sources under different filenames could hash to the SAME cache basename
/// while encoding differently (#132 task-7 review finding).
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing.
pub fn isPng(bytes: []const u8) bool {
    return bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });
}

/// Still-raster gate: JPEG, PNG, still WebP. GIF (animation-ambiguous,
/// palette output would need quantization) and everything else pass
/// through as plain <img> — spec §1.
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing.
pub fn eligible(bytes: []const u8) bool {
    if (bytes.len < 16) return false;
    if (bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return true; // JPEG
    if (isPng(bytes)) return true;
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
    var hex: [hash_hex_len]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{digest[0 .. hash_hex_len / 2]}) catch unreachable;

    const ext = std.fs.path.extension(source_basename);
    const stem = source_basename[0 .. source_basename.len - ext.len];
    return std.fmt.allocPrint(gpa, "{s}.{s}.{d}.{s}", .{
        stem, &hex, width, @tagName(codec),
    });
}

/// Hex digits in a variant basename's hash component, above — 4 raw hash
/// bytes formatted as hex. Named (rather than a bare `8` there) so
/// `max_basename_growth` below can't drift from the format it's bounding.
pub const hash_hex_len: usize = 8;

/// Longest `Codec` tag name, computed once at comptime so a future codec
/// (PR B's AVIF hatch) that widens `variantBasename`'s output moves this
/// bound too, instead of quietly falsifying it.
pub const max_codec_name_len: usize = blk: {
    var max: usize = 0;
    for (std.enums.values(Codec)) |c| max = @max(max, @tagName(c).len);
    break :blk max;
};

/// A variant's `width` is a `u32`; its longest decimal form is 10 digits
/// (4294967295).
pub const max_width_digits: usize = 10;

/// Worst-case bytes `variantBasename` can add BEYOND `source_basename`'s own
/// length — i.e. an upper bound on `variantBasename(...).len -
/// source_basename.len`, maximized over every possible `source_basename`.
/// The bound is largest when the source has NO extension: `variantBasename`
/// strips whatever extension there was (into `ext`, dropped) before
/// appending `.<hash_hex_len hex>.<width digits>.<codec>`, so a longer
/// source extension only ever makes the actual growth SMALLER than this,
/// never larger.
///
/// A caller sizing a stack buffer for a variant's DESTINATION path — the
/// source's own directory plus this basename, instead of the source's own
/// name — needs this added on top of whatever already bounded the source
/// path itself (`derive.zig`'s `dest_buf`, mirroring the same
/// over-provisioning `root.zig`'s fingerprinted-asset install path does
/// with `fingerprint.hash_len`).
pub const max_basename_growth: usize = 1 + hash_hex_len + 1 + max_width_digits + 1 + max_codec_name_len;
