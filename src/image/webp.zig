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
