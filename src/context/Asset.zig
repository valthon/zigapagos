const Asset = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const _ziggy = @import("ziggy");
const scripty = @import("scripty");
const utils = @import("utils.zig");
const log = utils.log;
const fatal = @import("../fatal.zig");
const context = @import("../context.zig");
const Value = context.Value;
const Int = context.Int;
const PathTable = @import("../PathTable.zig");
const PathName = PathTable.PathName;
const html = @import("../render/html.zig");
const fingerprint = @import("../fingerprint.zig");
const join = @import("../root.zig").join;
const Signature = @import("doctypes.zig").Signature;

_meta: struct {
    ref: []const u8,
    // full path to the asset
    url: PathName,
    kind: context.AssetKindUnion,
},

pub const Kind = enum {
    /// An asset inside of `assets_dir_path`
    site,
    /// An asset inside of `content_dir_path`, placed next to a content page.
    page,
    /// A build-time asset, stored inside the cache.
    build,
};

pub fn init(ref: []const u8, path: []const u8, kind: context.AssetKindUnion) Value {
    return .{
        .asset = .{
            ._meta = .{
                .ref = ref,
                .path = path,
                .kind = kind,
            },
        },
    };
}

pub const docs_description = "Represents an asset.";
pub const Dot = true;

/// Shared body of `link()` and `absLink()`. This is the ONLY place that
/// bumps an asset's install refcount (`page_asset`/`site_assets`/
/// `build_assets` counters) — a forked copy of this logic drifting between
/// the two builtins is exactly the silent-asset-pruning trap issue #25
/// documents: a builtin whose refcount bump falls out of sync with the
/// other would let an asset referenced only through it be pruned from the
/// output tree while still looking like a normal reference at the call
/// site. `force_host_url` selects which of the two builtins this call is:
/// `false` for `link()` (root-relative unless already off-page), `true`
/// for `absLink()` (always absolute — required for URLs consumed outside
/// the page itself, e.g. `og:image`, canonical links, feeds).
///
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1). All
/// scratch state lives in `buf`, a `Writer.Allocating` freed via
/// `errdefer` on every error path; only the final `Value.from` allocation
/// escapes to the caller. Correct under any allocator.
fn linkImpl(
    asset: Asset,
    gpa: Allocator,
    ctx: *const context.Root,
    force_host_url: bool,
) context.CallError!Value {
    var buf: Writer.Allocating = .init(gpa);
    errdefer buf.deinit();

    const w = &buf.writer;
    switch (asset._meta.kind) {
        .page => |variant_id| {
            // `printLinkPrefix` handles `force_host_url` in every case but
            // ONE, and that one cell is what this block fills in.
            //
            // Its `.multi` arm honours the flag only INSIDE
            // `if (other_variant_id != our_variant_id)` (`Root.zig`). A
            // `.page` asset usually IS in the page's own variant, so on a
            // multilingual site the flag never fired and `absLink()` handed
            // back a root-relative URL — the exact defect issue #25 exists to
            // fix. But "usually" is not "always": `$page.locale(…)` and
            // `translation()` return the OTHER variant's Page, and `.asset()`
            // stamps that page's `variant_id` (see `Page.zig`), so a `.page`
            // asset can be cross-variant. There `printLinkPrefix` does print
            // the host, and printing it here too yielded a doubled
            // `https://it.example.comhttps://it.example.com/…`.
            //
            // Hence `handled`: print the host ourselves ONLY in the cell
            // `printLinkPrefix` ignores (multilingual, same variant), and keep
            // passing the flag through so its own `force or hosts-differ`
            // short-circuit covers everything else — every cross-variant case
            // and the simple-site case, including two locales whose override
            // strings are equal but not pointer-equal.
            //
            // Not hoisting the flag out of that inherited guard is deliberate:
            // `printUrl`'s call sites in `render/html.zig` pass
            // `page != ctx.page`, so there the flag doubles as "this is a
            // cross-page reference" — and `page != ctx.page` with the SAME
            // variant is reachable via embedded content — so hoisting would
            // change `$link` output for every multilingual site.
            //
            // `sites[variant_id].host_url` is the same value that arm reads as
            // `other_host_url`: `host_url_override orelse host_url` per locale
            // (see `root.zig`'s sites map).
            const site = ctx._meta.sites.entries.items(.value)[variant_id];
            const handled = switch (site._meta.kind) {
                .simple => true,
                .multi => variant_id != ctx.page._scan.variant_id,
            };
            if (force_host_url and !handled) {
                w.print("{s}", .{site.host_url}) catch return error.OutOfMemory;
            }
            ctx.printLinkPrefix(
                w,
                variant_id,
                force_host_url,
            ) catch return error.OutOfMemory;
            const v = ctx._meta.build.variants[variant_id];
            const hint = v.urls.getPtr(asset._meta.url).?;
            assert(hint.kind == .page_asset);
            _ = hint.kind.page_asset.fetchAdd(1, .acq_rel);

            const st = &v.string_table;
            const pt = &v.path_table;
            w.print("{f}", .{
                asset._meta.url.fmt(st, pt, null, "/"),
            }) catch return error.OutOfMemory;
        },
        .site => {
            html.printAssetUrlPrefix(ctx, ctx.page, w, force_host_url) catch return error.OutOfMemory;
            const rc = ctx._meta.build.site_assets.getPtr(asset._meta.url).?;
            _ = rc.fetchAdd(1, .acq_rel);

            // `fingerprint.fmtUrl`, not `PathName.fmt`: with
            // `asset_fingerprint` on, this asset is INSTALLED under a
            // content-hashed basename (issue #53) and a link printed from the
            // verbatim name would 404. The map is empty on every other build,
            // in which case this is byte-identical to the plain formatter.
            const st = &ctx._meta.build.st;
            const pt = &ctx._meta.build.pt;
            w.print("{f}", .{fingerprint.fmtUrl(
                asset._meta.url,
                st,
                pt,
                &ctx._meta.build.asset_fingerprints,
            )}) catch return error.OutOfMemory;
        },
        .build => {
            html.printAssetUrlPrefix(ctx, ctx.page, w, force_host_url) catch return error.OutOfMemory;
            const ba = ctx._meta.build.build_assets.getPtr(
                asset._meta.ref,
            ).?;

            // Bump rc only after confirming an install path exists: a
            // no-install asset must not be marked for install (which
            // would later unwrap a null install_path). The missing-path
            // case is a graceful page error, not an install.
            const op = ba.install_path orelse return Value.errFmt(
                gpa,
                "unable to install build asset '{s}' as it does not specify an install path",
                .{asset._meta.ref},
            );
            _ = ba.rc.fetchAdd(1, .acq_rel);
            w.print("{s}", .{op}) catch return error.OutOfMemory;
        },
    }

    return Value.from(gpa, buf.written());
}

/// Record that a build-time READ builtin consumed this site asset's bytes.
///
/// `bytes()`, `size()`, `sriHash()` and `ziggy()` inline an asset into the
/// page (or into a hash) instead of publishing it, so — unlike `linkImpl` —
/// they must NOT bump the install refcount: an asset the build read is an
/// asset the deploy has no reason to carry.
///
/// They are still a real use, though, and that is what this counter is for.
/// Issue #54's pruned-asset report keys off the install refcount alone, so
/// without it a legitimately inlined `$site.asset('data.ziggy').ziggy()` gets
/// named on EVERY build as "not installed because nothing references them",
/// with two suggested remedies that are both wrong — the `static_assets` one
/// would publish a private data file. A warning that fires on correct code is
/// the failure mode that report already exists to avoid.
///
/// Site assets only: the report is site-asset-only, and page/build assets have
/// their own install rules (a build asset with no `install_path` is explicitly
/// a read-only asset, see `installBuildAssets`).
///
/// NO_SLOP.md §2.2a contract 3 (caller-buffer): allocates nothing.
fn markSiteRead(ctx: *const context.Root, url: PathName) void {
    // The key set is frozen when `Build.scanSiteAssets` returns — every
    // `site_assets` key is inserted into `site_asset_reads` in the same
    // statement — so this lookup cannot miss for an asset that resolved to
    // `.site`. It stays an `if` rather than an `.?` because failing to record
    // a read must never crash a build; the worst case is one spurious line in
    // a warning.
    if (ctx._meta.build.site_asset_reads.getPtr(url)) |reads| {
        _ = reads.fetchAdd(1, .acq_rel);
    }
}

pub const Builtins = struct {
    pub const link = struct {
        pub const signature: Signature = .{ .ret = .String };
        pub const docs_description =
            \\Returns a link to the asset.
            \\
            \\Calling `link` on an asset will cause it to be installed
            \\under the same relative path into the output directory.
            \\
            \\    `content/post/bar.jpg` -> `public/post/bar.jpg`
            \\  `assets/foo/bar/baz.jpg` -> `public/foo/bar/baz.jpg`
            \\
            \\Build assets will be installed under the path defined in
            \\your `build.zig`.
            \\
            \\The result is root-relative. Use `absLink()` instead for a
            \\URL that is consumed outside the page and therefore has to
            \\be absolute: social metadata, canonical links, feeds.
        ;
        pub const examples =
            \\<img src="$site.asset('logo.jpg').link()">
            \\<img src="$page.asset('profile.jpg').link()">
        ;
        pub fn call(
            asset: Asset,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            const bad_arg: Value = .{ .err = "expected 0 arguments" };
            if (args.len != 0) return bad_arg;

            return linkImpl(asset, gpa, ctx, false);
        }
    };
    pub const absLink = struct {
        pub const signature: Signature = .{ .ret = .String };
        pub const docs_description =
            \\Like `link()`, but always returns an absolute URL
            \\(host_url + url_path_prefix + asset path). Calling it
            \\installs the asset, exactly like `link()`.
            \\
            \\Required for URLs consumed outside the page: `og:*` and
            \\`twitter:*` meta tags, canonical links, feeds. Scrapers do
            \\not resolve root-relative URLs.
        ;
        pub const examples =
            \\<meta property="og:image" content="$site.asset('og.png').absLink()">
        ;
        pub fn call(
            asset: Asset,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            const bad_arg: Value = .{ .err = "expected 0 arguments" };
            if (args.len != 0) return bad_arg;

            return linkImpl(asset, gpa, ctx, true);
        }
    };
    pub const size = struct {
        pub const signature: Signature = .{ .ret = .String };
        pub const docs_description =
            \\Returns the size of an asset file in bytes.
        ;
        pub const examples =
            \\<div :text="$site.asset('foo.json').size()"></div>
        ;
        pub fn call(
            asset: Asset,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            _ = gpa;
            if (args.len != 0) return .{ .err = "expected 0 arguments" };

            var buf: [std.fs.max_path_bytes]u8 = undefined;
            switch (asset._meta.kind) {
                .page => |variant_id| {
                    const v = &ctx._meta.build.variants[variant_id];
                    const path = std.fmt.bufPrint(&buf, "{f}", .{
                        asset._meta.url.fmt(
                            &v.string_table,
                            &v.path_table,
                            null,
                            "",
                        ),
                    }) catch unreachable;

                    const stat = v.content_dir.statFile(ctx._meta.io, path, .{}) catch {
                        return .{ .err = "i/o error while reading asset file" };
                    };
                    return Int.init(@intCast(stat.size));
                },
                .site => {
                    markSiteRead(ctx, asset._meta.url);
                    const path = std.fmt.bufPrint(&buf, "{f}", .{
                        asset._meta.url.fmt(
                            &ctx._meta.build.st,
                            &ctx._meta.build.pt,
                            null,
                            "",
                        ),
                    }) catch unreachable;

                    const stat = ctx._meta.build.site_assets_dir.statFile(ctx._meta.io, path, .{}) catch {
                        return .{ .err = "i/o error while reading asset file" };
                    };
                    return Int.init(@intCast(stat.size));
                },
                .build => {
                    const ba = ctx._meta.build.build_assets.getPtr(
                        asset._meta.ref,
                    ).?;
                    const stat = ctx._meta.build.base_dir.statFile(
                        ctx._meta.io,
                        ba.input_path,
                        .{},
                    ) catch {
                        return .{ .err = "i/o error while reading asset file" };
                    };
                    return Int.init(@intCast(stat.size));
                },
            }
        }
    };
    pub const bytes = struct {
        pub const signature: Signature = .{ .ret = .String };
        pub const docs_description =
            \\Returns the raw contents of an asset.
        ;
        pub const examples =
            \\<div :text="$page.assets.file('foo.json').bytes()"></div>
        ;
        pub fn call(
            asset: Asset,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            if (args.len != 0) return .{ .err = "expected 0 arguments" };

            var buf: [std.fs.max_path_bytes]u8 = undefined;
            switch (asset._meta.kind) {
                .page => |variant_id| {
                    const v = &ctx._meta.build.variants[variant_id];
                    const path = std.fmt.bufPrint(&buf, "{f}", .{
                        asset._meta.url.fmt(
                            &v.string_table,
                            &v.path_table,
                            null,
                            "",
                        ),
                    }) catch unreachable;

                    const data = v.content_dir.readFileAlloc(
                        ctx._meta.io,
                        path,
                        gpa,
                        .unlimited,
                    ) catch {
                        return .{ .err = "i/o error while reading asset file" };
                    };
                    return Value.from(gpa, data);
                },
                .site => {
                    markSiteRead(ctx, asset._meta.url);
                    const path = std.fmt.bufPrint(&buf, "{f}", .{
                        asset._meta.url.fmt(
                            &ctx._meta.build.st,
                            &ctx._meta.build.pt,
                            null,
                            "",
                        ),
                    }) catch unreachable;

                    const data = ctx._meta.build.site_assets_dir.readFileAlloc(
                        ctx._meta.io,
                        path,
                        gpa,
                        .unlimited,
                    ) catch |err| fatal.file(path, err);

                    return Value.from(gpa, data);
                },
                .build => {
                    const ba = ctx._meta.build.build_assets.getPtr(
                        asset._meta.ref,
                    ).?;

                    const data = ctx._meta.build.base_dir.readFileAlloc(
                        ctx._meta.io,
                        ba.input_path,
                        gpa,
                        .unlimited,
                    ) catch |err| fatal.file(ba.input_path, err);

                    return Value.from(gpa, data);
                },
            }
        }
    };
    pub const sriHash = struct {
        pub const signature: Signature = .{ .ret = .String };
        pub const docs_description =
            \\Returns the Base64-encoded SHA384 hash of an asset, prefixed with `sha384-`, for use with Subresource Integrity.
        ;
        pub const examples =
            \\<script src="$site.asset('foo.js').link()" integrity="$site.asset('foo.js').sriHash()"></script>
        ;
        pub fn call(
            asset: Asset,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            if (args.len != 0) return .{ .err = "expected 0 arguments" };

            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const data = switch (asset._meta.kind) {
                .page => |variant_id| blk: {
                    const v = &ctx._meta.build.variants[variant_id];
                    const path = std.fmt.bufPrint(&buf, "{f}", .{
                        asset._meta.url.fmt(
                            &v.string_table,
                            &v.path_table,
                            null,
                            "",
                        ),
                    }) catch unreachable;

                    break :blk v.content_dir.readFileAlloc(
                        ctx._meta.io,
                        path,
                        gpa,
                        .unlimited,
                    ) catch {
                        return .{ .err = "i/o error while reading asset file" };
                    };
                },
                .site => blk: {
                    markSiteRead(ctx, asset._meta.url);
                    const path = std.fmt.bufPrint(&buf, "{f}", .{
                        asset._meta.url.fmt(
                            &ctx._meta.build.st,
                            &ctx._meta.build.pt,
                            null,
                            "",
                        ),
                    }) catch unreachable;

                    break :blk ctx._meta.build.site_assets_dir.readFileAlloc(
                        ctx._meta.io,
                        path,
                        gpa,
                        .unlimited,
                    ) catch {
                        return .{ .err = "i/o error while reading asset file" };
                    };
                },
                .build => blk: {
                    const ba = ctx._meta.build.build_assets.getPtr(
                        asset._meta.ref,
                    ).?;
                    break :blk ctx._meta.build.base_dir.readFileAlloc(
                        ctx._meta.io,
                        ba.input_path,
                        gpa,
                        .unlimited,
                    ) catch {
                        return .{ .err = "i/o error while reading asset file" };
                    };
                },
            };

            const sha384 = std.crypto.hash.sha2.Sha384;
            const base64 = std.base64.standard.Encoder;

            var hashed_data: [sha384.digest_length]u8 = undefined;
            sha384.hash(data, &hashed_data, .{});

            var hashed_encoded_data: [base64.calcSize(hashed_data.len)]u8 = undefined;
            _ = base64.encode(&hashed_encoded_data, &hashed_data);

            const result: []u8 = try gpa.dupe(u8, "sha384-" ++ hashed_encoded_data);
            return Value.from(gpa, result);
        }
    };

    pub const ziggy = struct {
        pub const signature: Signature = .{ .ret = .any };
        pub const docs_description =
            \\Tries to parse the asset as a Ziggy document.
        ;
        pub const examples =
            \\<div :text="$page.assets.file('foo.ziggy').ziggy().get('bar')"></div>
        ;
        pub fn call(
            asset: Asset,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            if (args.len != 0) return .{ .err = "expected 0 arguments" };

            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const data = switch (asset._meta.kind) {
                .page => |variant_id| blk: {
                    const v = &ctx._meta.build.variants[variant_id];
                    const path = std.fmt.bufPrint(&buf, "{f}", .{
                        asset._meta.url.fmt(
                            &v.string_table,
                            &v.path_table,
                            null,
                            "",
                        ),
                    }) catch unreachable;

                    break :blk v.content_dir.readFileAllocOptions(
                        ctx._meta.io,
                        path,
                        gpa,
                        .unlimited,
                        .@"1",
                        0,
                    ) catch {
                        return .{ .err = "i/o error while reading asset file" };
                    };
                },
                .site => blk: {
                    markSiteRead(ctx, asset._meta.url);
                    const path = std.fmt.bufPrint(&buf, "{f}", .{
                        asset._meta.url.fmt(
                            &ctx._meta.build.st,
                            &ctx._meta.build.pt,
                            null,
                            "",
                        ),
                    }) catch unreachable;

                    break :blk ctx._meta.build.site_assets_dir.readFileAllocOptions(
                        ctx._meta.io,
                        path,
                        gpa,
                        .unlimited,
                        .@"1",
                        0,
                    ) catch {
                        return .{ .err = "i/o error while reading asset file" };
                    };
                },
                .build => blk: {
                    const ba = ctx._meta.build.build_assets.getPtr(
                        asset._meta.ref,
                    ).?;
                    break :blk ctx._meta.build.base_dir.readFileAllocOptions(
                        ctx._meta.io,
                        ba.input_path,
                        gpa,
                        .unlimited,
                        .@"1",
                        0,
                    ) catch {
                        return .{ .err = "i/o error while reading asset file" };
                    };
                },
            };

            log.debug("parsing ziggy file: '{s}'", .{data});

            var diag: _ziggy.Diagnostic = .{ .path = asset._meta.ref };
            const parsed = _ziggy.parseLeaky(_ziggy.dynamic.Value, gpa, data, .{
                .diagnostic = &diag,
                .copy_strings = .to_unescape,
            }) catch {
                return Value.errFmt(
                    gpa,
                    "Error while parsing Ziggy file: {}",
                    .{diag},
                );
            };

            return Value.fromZiggy(gpa, parsed);
        }
    };
};
