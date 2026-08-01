const Site = @This();

const std = @import("std");
const log = std.log.scoped(.scripty);
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const scripty = @import("scripty");
const utils = @import("utils.zig");
const context = @import("../context.zig");
const Value = context.Value;
const Bool = context.Bool;
const String = context.String;
const Array = context.Array;
const StringTable = @import("../StringTable.zig");
const PathTable = @import("../PathTable.zig");
const PathName = PathTable.PathName;
const root = @import("../root.zig");
const join = root.join;
const Signature = @import("doctypes.zig").Signature;

host_url: []const u8,
title: []const u8,
_meta: struct {
    variant_id: u32,
    kind: union(enum) {
        simple: []const u8, // url_path_prefix
        multi: root.Locale,
    },
},

pub const docs_description =
    \\The global site configuration. The fields come from the call to 
    \\`website` in your `build.zig`.
    \\ 
    \\ Gives you also access to assets and static assets from the directories 
    \\ defined in your site configuration.
;

pub const Dot = true;
pub const PassByRef = true;
pub const Fields = struct {
    pub const host_url =
        \\The host URL, as defined in your `build.zig`.
    ;
    pub const title =
        \\The website title, as defined in your `build.zig`.
    ;
};
pub const Builtins = struct {
    pub const localeCode = struct {
        pub const signature: Signature = .{
            .ret = .String,
        };
        pub const docs_description =
            \\In a multilingual website, returns the locale of the current 
            \\variant as defined in your `build.zig` file. 
        ;
        pub const examples =
            \\<html lang="$site.localeCode()"></html>
        ;
        pub fn call(
            p: *const Site,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) !Value {
            _ = gpa;
            _ = ctx;

            const bad_arg: Value = .{
                .err = "expected 0 arguments",
            };
            if (args.len != 0) return bad_arg;

            return switch (p._meta.kind) {
                .multi => |l| String.init(l.code),
                .simple => .{
                    .err = "only available in a multilingual website",
                },
            };
        }
    };
    pub const localeName = struct {
        pub const signature: Signature = .{
            .ret = .String,
        };
        pub const docs_description =
            \\In a multilingual website, returns the locale name of the current 
            \\variant as defined in your `build.zig` file. 
        ;
        pub const examples =
            \\<span :text="$site.localeName()"></span>
        ;
        pub fn call(
            site: *const Site,
            gpa: Allocator,
            _: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            _ = gpa;
            const bad_arg: Value = .{
                .err = "expected 0 arguments",
            };
            if (args.len != 0) return bad_arg;

            return switch (site._meta.kind) {
                .multi => |l| String.init(l.name),
                .simple => .{
                    .err = "only available in multilingual websites",
                },
            };
        }
    };

    pub const link = struct {
        pub const signature: Signature = .{
            .ret = .String,
        };
        pub const docs_description =
            \\Returns a link to the homepage of the website.
            \\
            \\Correctly links to a subpath when correct to do so in a  
            \\multilingual website.
        ;
        pub const examples =
            \\<a href="$site.link()" :text="$site.title"></a>
        ;
        pub fn call(
            s: *const Site,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            _ = s;
            const bad_arg: Value = .{
                .err = "expected 0 arguments",
            };
            if (args.len != 0) return bad_arg;

            var aw: Writer.Allocating = .init(gpa);
            ctx.printLinkPrefix(
                &aw.writer,
                ctx.site._meta.variant_id,
                false,
            ) catch return error.OutOfMemory;
            return String.init(aw.written());
        }
    };

    pub const asset = struct {
        pub const signature: Signature = .{
            .params = &.{.String},
            .ret = .Asset,
        };
        pub const docs_description =
            \\Retuns an asset by name from inside the assets directory.
        ;
        pub const examples =
            \\<img src="$site.asset('foo.png').link()">
        ;
        pub fn call(
            _: *const Site,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            const bad_arg: Value = .{
                .err = "expected 1 string argument",
            };
            if (args.len != 1) return bad_arg;

            const ref = switch (args[0]) {
                .string => |s| s.value,
                else => return bad_arg,
            };

            if (root.validatePathMessage(ref, .{})) |msg| return .{ .err = msg };

            const st = &ctx._meta.build.st;
            const pt = &ctx._meta.build.pt;
            if (PathName.get(st, pt, ref)) |pn| {
                if (ctx._meta.build.site_assets.contains(pn)) {
                    return .{
                        .asset = .{
                            ._meta = .{
                                .ref = context.stripTrailingSlash(ref),
                                .url = pn,
                                .kind = .site,
                            },
                        },
                    };
                }
            }

            return Value.errFmt(gpa, "missing site asset: '{s}'", .{ref});
        }
    };

    pub const data = struct {
        // `.ret = .Map` does not compile: `ScriptyParam.Map` is a union prong
        // with a `Base` payload, not a bare tag. It went unnoticed because
        // nothing analysed this signature -- Scripty's dispatch only ever calls
        // `call`. The generated Scripty reference (src/docgen_reference.zig,
        // issue #37) reads every `signature` in the tree, which is what turned
        // it into a compile error.
        pub const signature: Signature = .{
            .params = &.{.String},
            .ret = .{ .Map = .any },
        };
        pub const docs_description =
            \\Returns a site-wide global data file as a Ziggy map.
            \\
            \\The argument is the basename (without extension) of a `.ziggy`
            \\file in the site's `data_dir_path` (default `data/`), parsed once
            \\at build time. This is the Zigapagos equivalent of Astro's shared
            \\"content database" singleton (e.g. a `main.json` read by every
            \\page via `getSite()`): one source of truth, many consumers — read
            \\the same data from any layout instead of duplicating it into each
            \\page's frontmatter.
            \\
            \\Index into the returned map with `.get('field')`, chaining for
            \\nested maps.
        ;
        pub const examples =
            \\<span :text="$site.data('site').get('owner').get('name')"></span>
        ;
        pub fn call(
            _: *const Site,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            const bad_arg: Value = .{
                .err = "expected 1 string argument",
            };
            if (args.len != 1) return bad_arg;

            const ref = switch (args[0]) {
                .string => |s| s.value,
                else => return bad_arg,
            };

            if (ctx._meta.build.site_data.get(ref)) |map| {
                return .{ .map = .{ .value = map } };
            }

            return Value.errFmt(
                gpa,
                "missing site data file '{s}.ziggy' in the data directory",
                .{ref},
            );
        }
    };

    pub const page = struct {
        pub const signature: Signature = .{
            .params = &.{.String},
            .ret = .Page,
        };
        pub const docs_description =
            \\Finds a page by path.
            \\
            \\Paths are relative to the content directory and should exclude
            \\the markdown suffix as Zigapagos will automatically infer which file
            \\naming convention is used by the target page.
            \\
            \\For example, the value 'foo/bar' will be automatically
            \\matched by Zigapagos with either:
            \\ - content/foo/bar.smd
            \\ - content/foo/bar/index.smd
            \\
            \\To reference the site homepage, pass an empty string.
        ;
        pub const examples =
            \\<a href="$site.page('downloads').link()">Downloads</a>
        ;
        pub fn call(
            site: *const Site,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            const bad_arg: Value = .{
                .err = "expected 1 string argument",
            };
            if (args.len != 1) return bad_arg;

            const ref = switch (args[0]) {
                .string => |s| s.value,
                else => return bad_arg,
            };

            if (root.validatePathMessage(ref, .{ .empty = true })) |msg| return .{
                .err = msg,
            };

            const variant = &ctx._meta.build.variants[site._meta.variant_id];

            const path = variant.path_table.getPathNoName(
                &variant.string_table,
                &.{},
                ref,
            ) orelse {
                // --allow-missing-pages (issue #27 / DX-8): a page that hasn't
                // been written YET is not the same mistake as a page that will
                // never exist -- tolerate it under the explicit opt-in flag.
                // Only the "not found" case is tolerated; see the strict
                // `hint.kind != .page_main` arm below, which stays an error
                // (a resource-kind mismatch is a real authoring mistake, not
                // an unwritten page).
                if (ctx._meta.build.allow_missing_pages) {
                    return context.MissingPage.tolerate(ctx, site, ref);
                }
                return Value.errFmt(gpa, "missing page '{s}'", .{ref});
            };

            const index_html: StringTable.String = @enumFromInt(11);
            std.debug.assert(variant.string_table.get("index.html") == index_html);
            const pn: PathName = .{
                .path = path,
                .name = index_html,
            };

            const hint = variant.urls.get(pn) orelse {
                // Same tolerance, second "not found" shape: the directory
                // component of `ref` resolved (e.g. a sibling asset already
                // lives there) but no page claims it yet.
                if (ctx._meta.build.allow_missing_pages) {
                    return context.MissingPage.tolerate(ctx, site, ref);
                }
                return Value.errFmt(gpa, "missing page '{s}'", .{ref});
            };

            switch (hint.kind) {
                .page_main => {},
                else => return Value.errFmt(
                    gpa,
                    "missing page '{s}'",
                    .{ref},
                ),
            }

            return .{ .page = &variant.pages.items[hint.id] };
        }
    };

    pub const pages = struct {
        pub const signature: Signature = .{
            .params = &.{.{ .Many = .String }},
            .ret = .{ .Many = .Page },
        };
        pub const docs_description =
            \\Same as `page`, but accepts a variable number of page references and 
            \\loops over them in the provided order. All pages must exist.
            \\
            \\Calling this function with no arguments will loop over all pages
            \\of the site.
            \\
            \\To be used in conjunction with a `loop` attribute.
        ;
        pub const examples =
            \\<ul :loop="$site.pages('a', 'b', 'c')"><li :text="$loop.it.title"></li></ul>
            \\<ul :loop="$site.pages()"><li :text="$loop.it.title"></li></ul>
        ;
        pub fn call(
            site: *const Site,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            const v = &ctx._meta.build.variants[site._meta.variant_id];

            if (args.len == 0) {
                const page_list = try gpa.alloc(Value, v.pages.items.len);
                errdefer gpa.free(page_list);

                var idx: usize = 0;
                if (v.root_index) |rid| {
                    page_list[0] = .{ .page = &v.pages.items[rid] };
                    idx += 1;
                }
                for (v.sections.items[1..]) |*s| {
                    for (s.pages.items) |pid| {
                        page_list[idx] = .{ .page = &v.pages.items[pid] };
                        idx += 1;
                    }
                }

                std.debug.assert(idx == page_list.len);

                return context.Array.init(gpa, Value, page_list);
            }

            const page_list = try gpa.alloc(Value, args.len);
            errdefer gpa.free(page_list);

            for (page_list, args) |*p, arg| {
                const ref = switch (arg) {
                    .string => |s| s.value,
                    else => return .{ .err = "not a string argument" },
                };

                const path = v.path_table.getPathNoName(
                    &v.string_table,
                    &.{},
                    ref,
                ) orelse return Value.errFmt(gpa, "page '{s}' does not exist", .{
                    ref,
                });

                const index_html: StringTable.String = @enumFromInt(11);
                const hint = v.urls.get(.{
                    .path = path,
                    .name = index_html,
                }) orelse return Value.errFmt(gpa, "page '{s}' does not exist", .{
                    ref,
                });

                switch (hint.kind) {
                    .page_main => {},
                    else => return Value.errFmt(gpa, "page '{s}' does not exist", .{
                        ref,
                    }),
                }

                p.* = .{ .page = &v.pages.items[hint.id] };
                if (!p.page._parse.active) return Value.errFmt(
                    gpa,
                    "page '{s}' is a draft",
                    .{ref},
                );
            }

            return context.Array.init(gpa, Value, page_list);
        }
    };
    pub const locale = struct {
        pub const signature: Signature = .{
            .params = &.{.String},
            .ret = .Site,
        };
        pub const docs_description =
            \\Returns the Site corresponding to the provided locale code.
            \\
            \\Only available in multilingual websites.
        ;
        pub const examples =
            \\<a href="$site.locale('en-US').link()">Murica</a>
        ;
        pub fn call(
            _: *const Site,
            gpa: Allocator,
            ctx: *const context.Root,
            args: []const Value,
        ) context.CallError!Value {
            const bad_arg: Value = .{
                .err = "expected 1 string argument",
            };
            if (args.len != 1) return bad_arg;

            const code = switch (args[0]) {
                .string => |s| s.value,
                else => return bad_arg,
            };

            const site = ctx._meta.sites.getPtr(code) orelse return Value.errFmt(
                gpa,
                "unknown language code '{s}'",
                .{code},
            );

            return .{ .site = site };
        }
    };
};
