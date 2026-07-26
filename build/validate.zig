//! Configure-time validation of a site's island/SPA declarations, plus the two
//! name-derivation helpers those checks (and the bundlers) agree on.
//!
//! Every failure here is a `std.debug.panic` at CONFIGURE time: these are
//! authoring mistakes that would otherwise surface as broken generated code,
//! silently clobbered assets, or a corrupted `--spa=<src>|<base>` split.

const std = @import("std");
const api = @import("api.zig");

const Island = api.Island;
const Spa = api.Spa;

/// "components/Hero.island.tsx" -> "Hero.island", "components/Counter.zig" -> "Counter".
/// Strips only the final extension (lastIndexOf '.') so multi-dot basenames like
/// "Hero.island.tsx" become "Hero.island" — matching pass.zig's `moduleUrl`.
pub fn islandName(src: []const u8) []const u8 {
    var name = src;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[0..dot];
    return name;
}

/// "app/App.spa.tsx" -> "App". Falls back to stripping just the final
/// extension (matching `islandName`) if the file doesn't end in `.spa.tsx`.
pub fn spaName(src: []const u8) []const u8 {
    if (std.mem.endsWith(u8, src, ".spa.tsx")) {
        const base = std.fs.path.basename(src);
        return base[0 .. base.len - ".spa.tsx".len];
    }
    return islandName(std.fs.path.basename(src)); // fallback: strip final ext
}

/// Fail the build (at configure time) on island specs that would produce broken
/// generated code or silently-clobbered assets, with a message a site author can act on.
pub fn validateIslands(islands: []const Island) void {
    for (islands, 0..) |isl, i| {
        // `src` is emitted into a generated Zig string literal; a quote or
        // backslash would break the generated source. (Real `<island src>` paths never
        // contain these.)
        if (std.mem.indexOfAny(u8, isl.src, "\"\\") != null) std.debug.panic(
            "island src \"{s}\" must not contain '\"' or '\\\\'.",
            .{isl.src},
        );
        // The js URL is derived from the basename, so basenames must be unique
        // or one island's module would silently overwrite another's.
        const name = islandName(isl.src);
        for (islands[0..i]) |prev| {
            if (std.mem.eql(u8, islandName(prev.src), name)) std.debug.panic(
                "islands \"{s}\" and \"{s}\" share basename \"{s}\"; their .js would " ++
                    "collide at /islands/{s}.js. Give them distinct file basenames.",
                .{ prev.src, isl.src, name, name },
            );
        }
    }
}

/// Fail the build (at configure time) on SPA specs with an unsafe `src`,
/// overlapping `base` URL namespaces (one SPA nested under another), or a
/// `spaName(src)` basename collision (two SPAs would clobber the same
/// `spa/<name>.js` bundle / `spa_<name>` build-asset registration).
pub fn validateSpas(spas: []const Spa) void {
    for (spas, 0..) |s, i| {
        // `src` is also emitted into `--spa=<src>|<base>` (split on the
        // FIRST '|' by release.zig), so — in addition to the generated-code
        // concern below — a `src` containing '|' would corrupt that split.
        if (std.mem.indexOfAny(u8, s.src, "\"\\|") != null)
            std.debug.panic("spa src must not contain quotes, backslashes, or '|': {s}", .{s.src});
        if (s.base.len == 0 or s.base[0] != '/')
            std.debug.panic("spa base must start with '/': {s}", .{s.base});
        const bi = std.mem.trimEnd(u8, s.base, "/");
        for (spas[0..i]) |p| {
            const bp = std.mem.trimEnd(u8, p.base, "/");
            // reject exact-equal or prefix-overlap bases (one SPA nested under another)
            if (std.mem.eql(u8, bi, bp) or
                (std.mem.startsWith(u8, bi, bp) and bi.len > bp.len and bi[bp.len] == '/') or
                (std.mem.startsWith(u8, bp, bi) and bp.len > bi.len and bp[bi.len] == '/'))
                std.debug.panic("spa bases overlap: '{s}' and '{s}'", .{ p.base, s.base });
        }
        // The js URL/build-asset name is derived from the basename (mirrors
        // validateIslands's analogous check), so basenames must be unique or
        // one SPA's bundle/registration would silently clobber another's.
        const name = spaName(s.src);
        for (spas[0..i]) |prev| {
            if (std.mem.eql(u8, spaName(prev.src), name)) std.debug.panic(
                "spas \"{s}\" and \"{s}\" share basename \"{s}\"; their .js would " ++
                    "collide at /spa/{s}.js. Give them distinct file basenames.",
                .{ prev.src, s.src, name, name },
            );
        }
    }
}

/// Fail the build (at configure time) when `Options.not_found`
/// names no declared SPA. The name is matched against `spaName(src)` — the
/// same basename that keys `spa/<name>.js` — never against `base` or the full
/// `src` path. A null `not_found` is always fine (the 404 owner defaults to
/// the first declared SPA).
pub fn validateNotFound(spas: []const Spa, not_found: ?[]const u8) void {
    const name = not_found orelse return;
    for (spas) |s| {
        if (std.mem.eql(u8, spaName(s.src), name)) return;
    }
    std.debug.panic(
        "not_found = \"{s}\" names no declared SPA — an SPA's name is its " ++
            "file basename sans .spa.tsx (e.g. \"booking\" for app/booking.spa.tsx); " ++
            "declare the SPA in `spas` or fix the name.",
        .{name},
    );
}
