//! Interchange-only PNG writer (issue #132). This module exists solely to
//! hand resampled RGBA pixels to Task 12's external AVIF encoder as a temp
//! file: the encoder shells out and reads a file path, so the pixels need a
//! container, not a codec choice. Size is irrelevant (the file is deleted
//! once the encoder has read it) and correctness is everything, so this
//! emits stored (uncompressed) deflate blocks — zero dependency on
//! `std.compress`, whose flate-*compression* API status on this toolchain
//! is therefore moot; only decompression is ever exercised here, and that
//! path is wuffs, not std.
//!
//! Correctness is pinned by round-tripping through Task 3's wuffs decoder
//! (see tests.zig) — the strongest oracle available, since wuffs is what
//! every other codepath in this repo trusts to read PNG.
const std = @import("std");
const Allocator = std.mem.Allocator;

const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

/// Stored deflate blocks top out at 65535 bytes of literal data each (the
/// block-length field is u16).
const max_stored_block = 65535;

/// Encode `w x h` non-premultiplied RGBA8 pixels (row-major, stride `w*4`,
/// `rgba.len == w*h*4`) as a minimal 8-bit/RGBA PNG.
///
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1) — the
/// filtered-scanline scratch buffer and the chunk-assembly buffer are both
/// freed before returning; the one escaping allocation is the returned PNG
/// byte slice, freed by the caller.
pub fn write(gpa: Allocator, w: u32, h: u32, rgba: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: truecolor + alpha
    ihdr[10] = 0; // compression method (only value defined)
    ihdr[11] = 0; // filter method (only value defined)
    ihdr[12] = 0; // interlace method: none
    try writeChunk(gpa, &out, "IHDR", &ihdr);

    // Every scanline gets a leading filter-type byte; we always use filter 0
    // (None) since these bytes are never shipped, only round-tripped.
    const stride: usize = @as(usize, w) * 4;
    const filtered_len = @as(usize, h) * (stride + 1);
    const filtered = try gpa.alloc(u8, filtered_len);
    defer gpa.free(filtered);
    var row: u32 = 0;
    var dst: usize = 0;
    while (row < h) : (row += 1) {
        filtered[dst] = 0; // filter type: None
        dst += 1;
        const src_off = @as(usize, row) * stride;
        @memcpy(filtered[dst .. dst + stride], rgba[src_off .. src_off + stride]);
        dst += stride;
    }

    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(gpa);
    try idat.appendSlice(gpa, &.{ 0x78, 0x01 }); // zlib header: deflate, default window, no dict

    var off: usize = 0;
    while (true) {
        const remaining = filtered_len - off;
        const take = @min(remaining, max_stored_block);
        const final = off + take == filtered_len;
        try idat.append(gpa, if (final) 1 else 0); // BFINAL in bit0, BTYPE=00 (stored) in bits1-2
        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, @intCast(take), .little);
        try idat.appendSlice(gpa, &len_bytes);
        var nlen_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &nlen_bytes, ~@as(u16, @intCast(take)), .little);
        try idat.appendSlice(gpa, &nlen_bytes);
        try idat.appendSlice(gpa, filtered[off .. off + take]);
        off += take;
        if (final) break;
    }

    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, std.hash.Adler32.hash(filtered), .big);
    try idat.appendSlice(gpa, &adler_bytes);

    try writeChunk(gpa, &out, "IDAT", idat.items);
    try writeChunk(gpa, &out, "IEND", &.{});

    return out.toOwnedSlice(gpa);
}

fn writeChunk(
    gpa: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    chunk_type: *const [4]u8,
    data: []const u8,
) error{OutOfMemory}!void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len_bytes);
    try out.appendSlice(gpa, chunk_type);
    try out.appendSlice(gpa, data);

    var crc: std.hash.Crc32 = .init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try out.appendSlice(gpa, &crc_bytes);
}
