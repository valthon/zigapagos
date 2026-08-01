//! Content-hashed site-asset filenames (issue #53 / DX-34).
//!
//! A static site is the one kind of deployment where the whole output tree
//! *should* be cached aggressively, and the one thing standing in the way is
//! that `assets/style.css` is emitted at `/style.css` on every build: a CDN or
//! GitHub Pages can hand a returning visitor a stale stylesheet against fresh
//! HTML. The fix is the standard one — put the content hash in the filename
//! (`/style.a1b2c3d4.css`) so a changed file is a changed URL and the old URL
//! can be cached forever.
//!
//! This module is only the naming + URL-printing half. The map is built once
//! per build in `root.zig` (`computeAssetFingerprints`) and is READ-ONLY for
//! the rest of the build, which is what makes it safe to consult from the
//! multithreaded render pass without a lock.
//!
//! Scope, and why it is this narrow:
//!
//!  * **Site assets only** (files under `assets_dir_path`). Every URL for one
//!    is printed through exactly three seams — `context/Asset.zig`'s
//!    `linkImpl` (`$site.asset(…).link()`), `render/html.zig`'s `.site_asset`
//!    arm (a SuperMD `![](…)` directive) and `spa.zig`'s `spa.head` hrefs —
//!    all of which go through `fmtUrl` below.
//!  * **Not build assets.** Their install paths are declared by the author on
//!    the command line (so the author can already hash there), and the generated
//!    ones — `zigapagos-runtime.js`, `spa/<name>.js`, `islands/<name>.js` —
//!    have their URLs baked into import maps, routing manifests and the
//!    hydration bootstrap by literal path in a dozen places.
//!  * **Not page assets.** They are installed next to the page that owns them
//!    by the per-variant install jobs, and a page's own assets are invalidated
//!    by the same deploy that rewrites the page.
//!  * **Not `static_assets` entries.** `favicon.ico`, `CNAME`, `robots.txt`
//!    are installed unconditionally *precisely because* something outside the
//!    build looks them up at a fixed path; hashing those would break them.
//!    `root.zig` enforces this by skipping any asset whose refcount is already
//!    non-zero when the map is built — at that point in the pass order a
//!    non-zero refcount can only have come from the `static_assets` expansion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const Blake3 = std.crypto.hash.Blake3;
const PathTable = @import("PathTable.zig");
const PathName = PathTable.PathName;
const StringTable = @import("StringTable.zig");

/// Hex digits of the content hash spliced into a filename. 8 hex digits = 32
/// bits, which is ample here: two site assets can only collide if they share a
/// directory *and* a basename, and a `PathName` is unique on exactly that
/// pair — so a collision would require a file to collide with itself.
pub const hash_len = 8;

/// Site asset (`PathName`, as keyed in `Build.site_assets`) → its
/// fingerprinted BASENAME (`style.a1b2c3d4.css`). Values are gpa-owned; the
/// map is built in `root.zig` and freed in `Build.deinit`.
///
/// An asset ABSENT from the map keeps its verbatim name — that covers the
/// whole build when the feature is off, plus `static_assets` entries and every
/// in-memory build when it is on. Every consumer therefore has to treat
/// "no entry" as "use the plain name", which is what `fmtUrl` does.
pub const Map = std.AutoHashMapUnmanaged(PathName, []const u8);

/// Build `<stem>.<hash>.<ext>` for `basename` over `bytes`.
///
/// The hash goes BEFORE the extension, not after, because the extension is
/// load-bearing for everything downstream of the build: a web server picks the
/// `Content-Type` from it, `shouldMinifyCss` in `root.zig` gates on `.css`,
/// and a browser refuses a stylesheet served as `text/plain`. `style.css` →
/// `style.a1b2c3d4.css`; an extension-less `CNAME` → `CNAME.a1b2c3d4`.
/// The split is on the LAST dot, so `archive.tar.gz` → `archive.tar.<h>.gz`.
///
/// A leading-dot name (`.htaccess`) is treated as all-stem, not as an empty
/// stem with a `.htaccess` extension — `std.fs.path.extension` already has
/// that rule and this defers to it.
///
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1). One
/// allocation, and it is the return value.
pub fn hashName(gpa: Allocator, basename: []const u8, bytes: []const u8) Allocator.Error![]u8 {
    var digest: [Blake3.digest_length]u8 = undefined;
    Blake3.hash(bytes, &digest, .{});
    return nameFromDigest(gpa, basename, digest);
}

/// Bytes read per `readSliceShort` call in `hashFile`. Two buffers of this size
/// live on the stack for the duration of one call (the file reader's own, and
/// the chunk hashed out of it), so it is sized for a comfortable read syscall
/// rather than for throughput records.
const chunk_len = 32 * 1024;

/// Everything `hashFile` can fail with: opening the file, reading it, or
/// allocating the one string it returns.
pub const HashFileError = Io.File.OpenError || Io.Reader.ShortError || Allocator.Error;

/// `hashName`, but over a file read in fixed-size chunks instead of one the
/// caller has already slurped into memory.
///
/// This exists because the caller used to `readFileAlloc(…, .unlimited)` first:
/// naming a 2 GiB video under `assets/` allocated 2 GiB, and the whole point of
/// the pass is that it touches EVERY non-`static_assets` file whether the site
/// links it or not. Worse than the peak RSS is the failure mode — the caller
/// treats an unreadable asset as "leave it unfingerprinted and carry on", so an
/// allocation failure would silently hand the site's largest files their old
/// unversioned names, i.e. exactly the ones immutable caching is worth most
/// for. BLAKE3 is a streaming hash; buffering the file was never necessary.
///
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1). The chunk
/// buffers are stack-resident; the single allocation is the return value.
pub fn hashFile(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    basename: []const u8,
) HashFileError![]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [chunk_len]u8 = undefined;
    var fr = file.reader(io, &read_buf);

    var hasher: Blake3 = .init(.{});
    var chunk: [chunk_len]u8 = undefined;
    while (true) {
        // Short read == end of stream (see `Io.Reader.readSliceShort`), so a
        // partial chunk is hashed and then the loop ends.
        const n = try fr.interface.readSliceShort(&chunk);
        if (n == 0) break;
        hasher.update(chunk[0..n]);
        if (n < chunk.len) break;
    }

    var digest: [Blake3.digest_length]u8 = undefined;
    hasher.final(&digest);
    return nameFromDigest(gpa, basename, digest);
}

/// Splice `hash_len` hex digits of `digest` into `basename`. Shared by
/// `hashName` and `hashFile` so the two can never disagree about the name for
/// the same bytes — the property the whole module exists to guarantee.
///
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1). One
/// allocation, and it is the return value.
fn nameFromDigest(
    gpa: Allocator,
    basename: []const u8,
    digest: [Blake3.digest_length]u8,
) Allocator.Error![]u8 {
    var hex: [hash_len]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{digest[0 .. hash_len / 2]}) catch unreachable;

    const ext = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext.len];
    return std.fmt.allocPrint(gpa, "{s}.{s}{s}", .{ stem, &hex, ext });
}

/// Print the install-relative URL/path of a site asset, substituting the
/// fingerprinted basename when `map` has one.
///
/// This is ONE formatter rather than an `if` at each call site for the same
/// reason `linkImpl` is one function shared by `link()`/`absLink()`: the three
/// places that print a site-asset URL and the one place that writes the file
/// must agree on the name, and a forked copy that drifts produces a page
/// pointing at a file the install pass never wrote — a 404 that only shows up
/// in a deployed build.
///
/// The output has the same shape as `PathName.fmt(st, pt, null, "/")`: no
/// leading slash (callers prepend the host/prefix via `printAssetUrlPrefix`),
/// `/`-separated, directory components first.
pub fn fmtUrl(
    pn: PathName,
    st: *const StringTable,
    pt: *const PathTable,
    map: *const Map,
) UrlFormatter {
    return .{ .pn = pn, .st = st, .pt = pt, .map = map };
}

pub const UrlFormatter = struct {
    pn: PathName,
    st: *const StringTable,
    pt: *const PathTable,
    map: *const Map,

    pub fn format(f: UrlFormatter, w: *Writer) Writer.Error!void {
        for (f.pn.path.slice(f.pt)) |c| {
            try w.writeAll(c.slice(f.st));
            try w.writeAll("/");
        }
        try w.writeAll(f.map.get(f.pn) orelse f.pn.name.slice(f.st));
    }
};

// ---------------------------------------------------------------------------
// Tests. Named `assets: …` so they land in the `test-assets` suite, which is
// the `filters = &.{"assets:"}` slice of the exe test binary (build/tests.zig).
// ---------------------------------------------------------------------------

test "assets: fingerprint hashName splices the hash before the extension" {
    const gpa = std.testing.allocator;

    const css = try hashName(gpa, "style.css", "body{}");
    defer gpa.free(css);
    try std.testing.expect(std.mem.startsWith(u8, css, "style."));
    try std.testing.expect(std.mem.endsWith(u8, css, ".css"));
    // stem + '.' + 8 hex + ".css"
    try std.testing.expectEqual(@as(usize, "style".len + 1 + hash_len + ".css".len), css.len);
    for (css["style.".len..][0..hash_len]) |c| {
        try std.testing.expect(std.ascii.isHex(c));
    }
}

test "assets: fingerprint hashName is deterministic and content-sensitive" {
    const gpa = std.testing.allocator;

    const a = try hashName(gpa, "style.css", "body{color:red}");
    defer gpa.free(a);
    const b = try hashName(gpa, "style.css", "body{color:red}");
    defer gpa.free(b);
    const c = try hashName(gpa, "style.css", "body{color:blue}");
    defer gpa.free(c);

    // Same bytes ⇒ same URL, or a rebuild of an unchanged site would churn
    // every asset URL and defeat the caching this exists to enable.
    try std.testing.expectEqualStrings(a, b);
    // Different bytes ⇒ different URL, which is the whole point.
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "assets: fingerprint hashName handles multi-dot and extension-less names" {
    const gpa = std.testing.allocator;

    // Only the LAST extension moves: a server keys `Content-Encoding` off `.gz`.
    const gz = try hashName(gpa, "archive.tar.gz", "x");
    defer gpa.free(gz);
    try std.testing.expect(std.mem.startsWith(u8, gz, "archive.tar."));
    try std.testing.expect(std.mem.endsWith(u8, gz, ".gz"));

    // No extension ⇒ the hash is simply appended.
    const plain = try hashName(gpa, "CNAME", "x");
    defer gpa.free(plain);
    try std.testing.expect(std.mem.startsWith(u8, plain, "CNAME."));
    try std.testing.expectEqual(@as(usize, "CNAME".len + 1 + hash_len), plain.len);

    // A dotfile is all stem (std.fs.path.extension's rule), so the hash lands
    // at the end rather than turning `.htaccess` into `.<hash>.htaccess`.
    const dot = try hashName(gpa, ".htaccess", "x");
    defer gpa.free(dot);
    try std.testing.expect(std.mem.startsWith(u8, dot, ".htaccess."));
}

test "assets: fingerprint fmtUrl substitutes only mapped assets" {
    const gpa = std.testing.allocator;

    var st: StringTable = .empty;
    defer st.deinit(gpa);
    var pt: PathTable = .empty;
    defer pt.deinit(gpa);

    // The empty-string/empty-path sentinels the tables are built around.
    _ = try st.intern(gpa, "");
    _ = try pt.internPath(gpa, &st, "");

    const plain: PathName = .{
        .path = try pt.internPath(gpa, &st, "css"),
        .name = try st.intern(gpa, "print.css"),
    };
    const hashed: PathName = .{
        .path = try pt.internPath(gpa, &st, "css"),
        .name = try st.intern(gpa, "site.css"),
    };

    var map: Map = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, hashed, "site.deadbeef.css");

    var buf: [128]u8 = undefined;

    // Mapped ⇒ the fingerprinted basename, directory prefix preserved.
    try std.testing.expectEqualStrings(
        "css/site.deadbeef.css",
        try std.fmt.bufPrint(&buf, "{f}", .{fmtUrl(hashed, &st, &pt, &map)}),
    );
    // Unmapped ⇒ byte-identical to what `PathName.fmt` would have printed.
    // This is the case that covers every build with the feature switched off
    // and every `static_assets` entry when it is on, so it is the one that
    // pins "no config change ⇒ no output change".
    var expected_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected_buf, "{f}", .{plain.fmt(&st, &pt, null, "/")}),
        try std.fmt.bufPrint(&buf, "{f}", .{fmtUrl(plain, &st, &pt, &map)}),
    );
}

test "assets: fingerprint hashFile agrees with hashName across chunk boundaries" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Sizes chosen around `chunk_len`, because the streaming loop is the only
    // thing here that can go wrong: a boundary bug drops or double-hashes a
    // chunk and produces a name that disagrees with the whole-buffer hash.
    // `chunk_len` exactly is the case where the loop reads a FULL chunk and
    // then has to notice EOF on the next call.
    const sizes = [_]usize{ 0, 1, chunk_len - 1, chunk_len, chunk_len + 1, 3 * chunk_len + 7 };
    for (sizes, 0..) |size, i| {
        const bytes = try gpa.alloc(u8, size);
        defer gpa.free(bytes);
        // Position-dependent content: a loop that hashed the same chunk twice,
        // or skipped one, would still match under a uniform fill.
        for (bytes, 0..) |*b, j| b.* = @truncate(j *% 31 +% i);

        var name_buf: [32]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&name_buf, "asset-{d}.css", .{i});
        {
            const f = try tmp.dir.createFile(testing_io, file_name, .{});
            defer f.close(testing_io);
            var w = f.writer(testing_io, &.{});
            try w.interface.writeAll(bytes);
        }

        const streamed = try hashFile(gpa, testing_io, tmp.dir, file_name, "style.css");
        defer gpa.free(streamed);
        const buffered = try hashName(gpa, "style.css", bytes);
        defer gpa.free(buffered);
        try std.testing.expectEqualStrings(buffered, streamed);
    }
}

test "assets: fingerprint hashFile reports an unreadable path instead of naming it" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `computeAssetFingerprints` turns this into "leave the asset
    // unfingerprinted and carry on", which is only correct as long as the
    // error actually surfaces rather than being papered over with a name
    // computed from zero bytes — that would be a name that changes the moment
    // the file becomes readable.
    try std.testing.expectError(
        error.FileNotFound,
        hashFile(gpa, testing_io, tmp.dir, "nope.css", "nope.css"),
    );
}
