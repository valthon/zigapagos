const std = @import("std");
const Io = std.Io;
const fatal = @import("../fatal.zig");
const detect = @import("migrate_detect.zig");
const content_convert = @import("migrate_content.zig");
const Allocator = std.mem.Allocator;

const Role = detect.Role;

const Source = enum {
    astro,
    nextjs,
    gatsby,
    nuxt,
    hugo,
    jekyll,
    eleventy,
    hexo,

    fn parse(value: []const u8) ?Source {
        if (std.mem.eql(u8, value, "astro")) return .astro;
        if (std.mem.eql(u8, value, "next") or std.mem.eql(u8, value, "nextjs") or std.mem.eql(u8, value, "next.js")) return .nextjs;
        if (std.mem.eql(u8, value, "gatsby")) return .gatsby;
        if (std.mem.eql(u8, value, "nuxt") or std.mem.eql(u8, value, "vue")) return .nuxt;
        if (std.mem.eql(u8, value, "hugo")) return .hugo;
        if (std.mem.eql(u8, value, "jekyll")) return .jekyll;
        if (std.mem.eql(u8, value, "eleventy") or std.mem.eql(u8, value, "11ty")) return .eleventy;
        if (std.mem.eql(u8, value, "hexo")) return .hexo;
        return null;
    }

    fn name(source: Source) []const u8 {
        return switch (source) {
            .astro => "Astro",
            .nextjs => "Next.js",
            .gatsby => "Gatsby",
            .nuxt => "Nuxt/Vue",
            .hugo => "Hugo",
            .jekyll => "Jekyll",
            .eleventy => "Eleventy (11ty)",
            .hexo => "Hexo",
        };
    }

    fn supportsScaffold(source: Source) bool {
        return source == .astro or source == .nextjs or source == .gatsby;
    }

    fn contentSource(source: Source) ?content_convert.Source {
        return switch (source) {
            .hugo => .hugo,
            .jekyll => .jekyll,
            .eleventy => .eleventy,
            .hexo => .hexo,
            else => null,
        };
    }
};

const usage =
    \\Usage: zigapagos migrate <project-dir> [OPTIONS]
    \\
    \\Scans an Astro, Next.js, Gatsby, Nuxt/Vue, Hugo, Jekyll, Eleventy, or
    \\Hexo project and
    \\writes MIGRATION.md: a source-specific worklist mapping files to their
    \\Zigapagos targets. The source is auto-detected or selected with --from.
    \\
    \\Source files are read-only. The command always writes a MIGRATION.md
    \\worklist. With --scaffold it also performs the deterministic React part of
    \\the port into a separate directory: starter islands, React imports rewritten
    \\to @z/runtime, and ambiguous npm imports marked for review. Pages, layouts,
    \\data loaders, plugins, and framework config remain explicit worklist items.
    \\
    \\Options:
    \\  --from SOURCE         astro|next|gatsby|nuxt|vue|hugo|jekyll|11ty|hexo
    \\                        (default: auto; use when detection is ambiguous)
    \\  -o, --output PATH      Report path (default: MIGRATION.md)
    \\  --target DIR           Assemble a minimal Zigapagos project in a missing
    \\                         or empty directory. Runs every deterministic step
    \\                         supported for the detected source: content
    \\                         conversion, React island scaffolding, and fixed-URL
    \\                         asset copying. Writes the worklist to DIR/MIGRATION.md.
    \\                         Mutually exclusive with --output, --scaffold,
    \\                         --convert-content, and --copy-assets.
    \\  --runtime-path PATH    With --target and React island candidates, set the
    \\                         local @z/runtime package path. Otherwise the emitted
    \\                         package.json contains a visible TODO placeholder.
    \\  --scaffold DIR         Write a starter TSX island per island into DIR.
    \\                         Supported for Astro, Next.js, and Gatsby React
    \\                         sources only.
    \\                         Attempts a real port: rewrites React imports to
    \\                         `@z/runtime` and flags any bare npm imports for
    \\                         review (NO-NPM-GUARDRAIL). Falls back to a TSX
    \\                         skeleton when the source has no default export.
    \\                         Emits `<Name>.island.tsx`. Never clobbers: an
    \\                         existing target goes to `<Name>.island.tsx.new`,
    \\                         and an existing `.new` (your in-progress port) to
    \\                         `.new.2`, `.new.3`, …
    \\                         An island whose source cannot be read is reported
    \\                         and skipped — no stub is written for it.
    \\                         Props are re-emitted verbatim from the source's
    \\                         `interface Props` when found.
    \\  --convert-content DIR  Convert Hugo/Jekyll/Eleventy/Hexo Markdown into a separate
    \\                         Zigapagos content tree. Recognized frontmatter is
    \\                         normalized to Ziggy; Markdown bodies are preserved.
    \\                         Existing outputs are never clobbered.
    \\  --copy-assets DIR      Copy conventional public/static asset trees into
    \\                         a separate Zigapagos assets directory, preserving
    \\                         public URL paths. Existing files are versioned as
    \\                         `.new*`; source files are never modified.
    \\  --doctor PATH          Analyse a single island file: check its imports
    \\                         against the no-npm guardrail, enumerate the React
    \\                         hooks used, and list any host-binding smells.
    \\                         Non-mutating (reads only). Exits non-zero when any
    \\                         guardrail violation is found. Mutually exclusive
    \\                         with --scaffold and --convert-content.
    \\  --json                 With --doctor: emit JSON instead of the human
    \\                         Markdown checklist (pipeable to jq etc.).
    \\  -h, --help             Show this help
    \\
;

pub const Kind = enum {
    page, // src/pages/*  -> content/*.smd
    layout, // src/layouts/* -> layouts/*.shtml
    component, // src/components/* -> components/*.island.tsx (island) or partial
    config, // astro.config.* -> zigapagos.ziggy + build.sh
    other,
};

pub const Entry = struct {
    path: []const u8, // relative to the astro dir
    kind: Kind,
    /// For `kind == .component`: how it maps. Decided in a second pass once the
    /// full set of `client:*`-used component names is known. Always `.plain`
    /// for non-component kinds (unused there).
    role: Role = .plain,
    /// True when this component is an island (`role == .island`).
    is_island: bool = false,
    /// A page/layout/component whose source references a `client:*` directive.
    uses_islands: bool = false,
    /// For `kind == .page`: set when this is a `src/pages/**/[page].astro` or
    /// `[...page].astro` route whose frontmatter calls `paginate()`.
    /// `PaginateSpec.section` slices THIS entry's own `path` field (not the
    /// scanned file content, which `scanFile` frees before returning) — so it
    /// needs no separate free in `freeScanResult`; freeing `path` covers it.
    paginate: ?detect.PaginateSpec = null,
};

pub const ScanResult = struct {
    entries: []Entry,
    island_names: std.StringHashMapUnmanaged(void),
    has_config: bool,
    /// True when `package.json` at the project root mentions
    /// `@astrojs/sitemap` (issue #150). Astro's sitemap integration has a
    /// direct mapping now that zigapagos generates its own -- flagged in
    /// MIGRATION.md as a worklist item rather than silently dropped, the
    /// way it was before this field existed.
    has_astro_sitemap: bool,
};

/// Run the two-pass Astro scan over `root` and return the results.
/// `entries` and `island_names` are gpa-owned; call `freeScanResult` when done.
pub fn scan(io: Io, gpa: Allocator, root: Io.Dir) ScanResult {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var island_names: std.StringHashMapUnmanaged(void) = .empty;

    // Pass 1: collect entries + the client:* usage set.
    scanDir(io, gpa, root, "src/pages", .page, &entries, &island_names);
    scanDir(io, gpa, root, "src/layouts", .layout, &entries, &island_names);
    scanDir(io, gpa, root, "src/components", .component, &entries, &island_names);
    scanDir(io, gpa, root, "src/content", .page, &entries, &island_names);

    // Pass 2: classify each component now that the usage set is complete.
    for (entries.items) |*e| {
        if (e.kind != .component) continue;
        e.role = detect.componentRole(e.path, &island_names);
        e.is_island = e.role == .island;
    }

    var has_config = false;
    for ([_][]const u8{ "astro.config.mjs", "astro.config.ts", "astro.config.js", "astro.config.json" }) |cfg| {
        if (fileExists(io, root, cfg)) {
            has_config = true;
            break;
        }
    }

    // A plain substring scan of package.json, not a JSON parse: this
    // importer converts nothing (see the CLI's own usage text), so a
    // dependency name is all the signal a worklist entry needs, and a
    // full parse would be new machinery to detect one string. A false
    // positive (the substring appearing in an unrelated key/comment) just
    // adds one extra worklist line for a human to dismiss; a false
    // negative silently repeats the exact defect this field exists to fix
    // (see the doc comment on `ScanResult.has_astro_sitemap`), so the scan
    // is deliberately loose rather than strict.
    var has_astro_sitemap = false;
    if (root.readFileAlloc(io, "package.json", gpa, .limited(16 * 1024 * 1024))) |content| {
        defer gpa.free(content);
        has_astro_sitemap = std.mem.indexOf(u8, content, "@astrojs/sitemap") != null;
    } else |_| {}

    return .{
        .entries = entries.toOwnedSlice(gpa) catch fatal.oom(),
        .island_names = island_names,
        .has_config = has_config,
        .has_astro_sitemap = has_astro_sitemap,
    };
}

/// Free all gpa-owned memory in a `ScanResult`.
pub fn freeScanResult(gpa: Allocator, res: *ScanResult) void {
    for (res.entries) |e| gpa.free(e.path);
    gpa.free(res.entries);
    var it = res.island_names.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    res.island_names.deinit(gpa);
}

fn packageDeclares(io: Io, gpa: Allocator, root: Io.Dir, dependency: []const u8) bool {
    const package = readFileContent(io, gpa, root, "package.json") catch return false;
    defer gpa.free(package);
    const quoted = std.fmt.allocPrint(gpa, "\"{s}\"", .{dependency}) catch fatal.oom();
    defer gpa.free(quoted);
    return std.mem.indexOf(u8, package, quoted) != null;
}

fn configMarker(io: Io, root: Io.Dir, source: Source) bool {
    const markers: []const []const u8 = switch (source) {
        .astro => &.{ "astro.config.mjs", "astro.config.ts", "astro.config.js", "astro.config.json" },
        .nextjs => &.{ "next.config.js", "next.config.mjs", "next.config.ts" },
        .gatsby => &.{ "gatsby-config.js", "gatsby-config.ts", "gatsby-config.mjs" },
        .nuxt => &.{ "nuxt.config.js", "nuxt.config.ts", "nuxt.config.mjs" },
        .hugo => &.{ "hugo.toml", "hugo.yaml", "hugo.yml", "hugo.json" },
        .jekyll => if ((fileExists(io, root, "Gemfile") or dirExists(io, root, "_posts") or
            dirExists(io, root, "_layouts") or dirExists(io, root, "_includes")) and
            !(dirExists(io, root, "source") and dirExists(io, root, "themes")))
            &.{ "_config.yml", "_config.yaml" }
        else
            &.{},
        .eleventy => &.{ ".eleventy.js", ".eleventy.cjs", ".eleventy.mjs", "eleventy.config.js", "eleventy.config.cjs", "eleventy.config.mjs" },
        .hexo => if (dirExists(io, root, "source") and dirExists(io, root, "themes")) &.{ "_config.yml", "_config.yaml" } else &.{},
    };
    for (markers) |marker| if (fileExists(io, root, marker)) return true;
    if (source == .hugo and dirExists(io, root, "content") and dirExists(io, root, "layouts")) {
        for ([_][]const u8{ "config.toml", "config.yaml", "config.yml" }) |marker| {
            if (fileExists(io, root, marker)) return true;
        }
    }
    return false;
}

fn sourceMarker(io: Io, gpa: Allocator, root: Io.Dir, source: Source) bool {
    if (configMarker(io, root, source)) return true;
    return switch (source) {
        .astro => packageDeclares(io, gpa, root, "astro"),
        .nextjs => packageDeclares(io, gpa, root, "next"),
        .gatsby => packageDeclares(io, gpa, root, "gatsby"),
        .nuxt => packageDeclares(io, gpa, root, "nuxt") or packageDeclares(io, gpa, root, "vue"),
        .hugo, .jekyll => false,
        .eleventy => packageDeclares(io, gpa, root, "@11ty/eleventy"),
        .hexo => packageDeclares(io, gpa, root, "hexo"),
    };
}

fn detectSource(io: Io, gpa: Allocator, root: Io.Dir) Source {
    var found: ?Source = null;
    for ([_]Source{ .astro, .nextjs, .gatsby, .nuxt, .hugo, .jekyll, .eleventy, .hexo }) |candidate| {
        if (!configMarker(io, root, candidate)) continue;
        if (found != null) fatal.usageError(
            "error: multiple source frameworks detected ({s} and {s}); select one with --from\n\n" ++ usage,
            .{ found.?.name(), candidate.name() },
        );
        found = candidate;
    }
    if (found) |source| return source;

    for ([_]Source{ .astro, .nextjs, .gatsby, .nuxt, .eleventy, .hexo }) |candidate| {
        if (!sourceMarker(io, gpa, root, candidate)) continue;
        if (found != null) fatal.usageError(
            "error: multiple source frameworks detected ({s} and {s}); select one with --from\n\n" ++ usage,
            .{ found.?.name(), candidate.name() },
        );
        found = candidate;
    }
    return found orelse fatal.usageError(
        "error: could not confidently detect a supported source framework; ask the project owner or pass --from astro|next|gatsby|nuxt|vue|hugo|jekyll|11ty|hexo\n\n" ++ usage,
        .{},
    );
}

fn hasAnyExtension(path: []const u8, extensions: []const []const u8) bool {
    for (extensions) |extension| if (std.mem.endsWith(u8, path, extension)) return true;
    return false;
}

fn sourceFile(source: Source, path: []const u8) bool {
    return switch (source) {
        .astro => true,
        .nextjs, .gatsby => hasAnyExtension(path, &.{ ".js", ".jsx", ".ts", ".tsx", ".md", ".mdx" }),
        .nuxt => hasAnyExtension(path, &.{".vue"}),
        .hugo => hasAnyExtension(path, &.{ ".md", ".html", ".gohtml" }),
        .jekyll => hasAnyExtension(path, &.{ ".md", ".markdown", ".html", ".liquid" }),
        .eleventy => hasAnyExtension(path, &.{ ".md", ".markdown", ".html", ".liquid", ".njk", ".11ty.js" }),
        .hexo => hasAnyExtension(path, &.{ ".md", ".markdown", ".html", ".ejs", ".swig", ".njk" }),
    };
}

fn sourceEntry(source: Source, entry: Entry) bool {
    if (source == .eleventy) return switch (entry.kind) {
        .page, .layout, .component => hasAnyExtension(entry.path, &.{ ".md", ".markdown", ".html", ".liquid", ".njk", ".11ty.js" }),
        .other => hasAnyExtension(entry.path, &.{ ".json", ".json5", ".js", ".cjs", ".mjs", ".yaml", ".yml" }),
        else => false,
    };
    if (source == .hexo and entry.kind == .other) return hasAnyExtension(entry.path, &.{ ".js", ".cjs", ".mjs" });
    return sourceFile(source, entry.path);
}

fn scanTopLevelFiles(
    io: Io,
    gpa: Allocator,
    base: Io.Dir,
    kind: Kind,
    out: *std.ArrayListUnmanaged(Entry),
    island_names: *std.StringHashMapUnmanaged(void),
) void {
    var dir = base.openDir(io, ".", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterateAssumeFirstIteration();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory or entry.name.len == 0 or entry.name[0] == '.') continue;
        if (entry.name[0] == '_' or std.ascii.eqlIgnoreCase(entry.name, "README.md")) continue;
        const path = gpa.dupe(u8, entry.name) catch fatal.oom();
        scanFile(io, gpa, base, path, kind, out, island_names);
    }
}

fn eleventyPagePath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/_includes/") == null and
        std.mem.indexOf(u8, path, "/_layouts/") == null and
        std.mem.indexOf(u8, path, "/_data/") == null and
        !std.mem.startsWith(u8, path, "_includes/") and
        !std.mem.startsWith(u8, path, "_layouts/") and
        !std.mem.startsWith(u8, path, "_data/");
}

fn nextAppRouteModule(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "app/") and
        !std.mem.startsWith(u8, path, "src/app/")) return false;

    const basename = std.fs.path.basename(path);
    const stem = std.fs.path.stem(basename);
    for ([_][]const u8{
        "page",
        "route",
        "layout",
        "template",
        "default",
        "loading",
        "error",
        "global-error",
        "not-found",
        "forbidden",
        "unauthorized",
    }) |reserved| {
        if (std.mem.eql(u8, stem, reserved)) return true;
    }
    return false;
}

fn scanOther(io: Io, gpa: Allocator, root: Io.Dir, source: Source) ScanResult {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var names: std.StringHashMapUnmanaged(void) = .empty;

    switch (source) {
        .astro => unreachable,
        .nextjs => {
            scanDir(io, gpa, root, "app", .page, &entries, &names);
            scanDir(io, gpa, root, "pages", .page, &entries, &names);
            scanDir(io, gpa, root, "src/app", .page, &entries, &names);
            scanDir(io, gpa, root, "src/pages", .page, &entries, &names);
            scanDir(io, gpa, root, "components", .component, &entries, &names);
            scanDir(io, gpa, root, "src/components", .component, &entries, &names);
        },
        .gatsby => {
            scanDir(io, gpa, root, "src/pages", .page, &entries, &names);
            scanDir(io, gpa, root, "src/templates", .layout, &entries, &names);
            scanDir(io, gpa, root, "src/components", .component, &entries, &names);
        },
        .nuxt => {
            const is_nuxt = configMarker(io, root, .nuxt) or packageDeclares(io, gpa, root, "nuxt");
            if (is_nuxt) {
                scanDir(io, gpa, root, "pages", .page, &entries, &names);
                scanDir(io, gpa, root, "layouts", .layout, &entries, &names);
                scanDir(io, gpa, root, "components", .component, &entries, &names);
                scanDir(io, gpa, root, "src/pages", .page, &entries, &names);
                scanDir(io, gpa, root, "src/views", .page, &entries, &names);
                scanDir(io, gpa, root, "src/layouts", .layout, &entries, &names);
                scanDir(io, gpa, root, "src/components", .component, &entries, &names);
            } else {
                // Plain Vue applications do not have Nuxt's directory roles.
                // Inventory the complete SFC tree once so root-level App.vue
                // and project-specific groupings are not silently missed.
                scanDir(io, gpa, root, "src", .component, &entries, &names);
            }
        },
        .hugo => {
            scanDir(io, gpa, root, "content", .page, &entries, &names);
            scanDir(io, gpa, root, "layouts", .layout, &entries, &names);
        },
        .jekyll => {
            scanTopLevelFiles(io, gpa, root, .page, &entries, &names);
            scanDir(io, gpa, root, "_posts", .page, &entries, &names);
            scanDir(io, gpa, root, "_pages", .page, &entries, &names);
            scanDir(io, gpa, root, "_layouts", .layout, &entries, &names);
            scanDir(io, gpa, root, "_includes", .component, &entries, &names);
        },
        .eleventy => {
            scanTopLevelFiles(io, gpa, root, .page, &entries, &names);
            scanDir(io, gpa, root, "src", .page, &entries, &names);
            scanDir(io, gpa, root, "content", .page, &entries, &names);
            scanDir(io, gpa, root, "_layouts", .layout, &entries, &names);
            scanDir(io, gpa, root, "_includes", .component, &entries, &names);
            scanDir(io, gpa, root, "src/_layouts", .layout, &entries, &names);
            scanDir(io, gpa, root, "src/_includes", .component, &entries, &names);
            scanDir(io, gpa, root, "_data", .other, &entries, &names);
            scanDir(io, gpa, root, "src/_data", .other, &entries, &names);
        },
        .hexo => {
            scanDir(io, gpa, root, "source", .page, &entries, &names);
            scanDir(io, gpa, root, "themes", .layout, &entries, &names);
            scanDir(io, gpa, root, "scripts", .other, &entries, &names);
        },
    }

    var kept: usize = 0;
    for (entries.items) |entry| {
        if (sourceEntry(source, entry) and
            !(source == .eleventy and entry.kind == .page and !eleventyPagePath(entry.path)))
        {
            entries.items[kept] = entry;
            kept += 1;
        } else {
            gpa.free(entry.path);
        }
    }
    entries.shrinkRetainingCapacity(kept);

    for (entries.items) |*entry| {
        if (source == .nextjs and entry.kind == .page) {
            const basename = std.fs.path.basename(entry.path);
            if (std.mem.startsWith(u8, basename, "layout.") or
                std.mem.startsWith(u8, basename, "_app.") or
                std.mem.startsWith(u8, basename, "_document."))
            {
                entry.kind = .layout;
            } else {
                const is_client = blk: {
                    const content = readFileContent(io, gpa, root, entry.path) catch break :blk false;
                    defer gpa.free(content);
                    break :blk std.mem.indexOf(u8, content, "\"use client\"") != null or
                        std.mem.indexOf(u8, content, "'use client'") != null;
                };
                // A `use client` directive controls the rendering boundary; it
                // does not stop reserved App Router modules from being routes.
                // Only colocated, non-route modules become island candidates.
                if (is_client and !nextAppRouteModule(entry.path) and
                    (std.mem.startsWith(u8, entry.path, "app/") or
                        std.mem.startsWith(u8, entry.path, "src/app/")))
                {
                    entry.kind = .component;
                }
            }
        }
        if (entry.kind != .component) continue;
        switch (source) {
            .nextjs, .gatsby => {
                const react = std.mem.endsWith(u8, entry.path, ".tsx") or
                    std.mem.endsWith(u8, entry.path, ".jsx") or
                    std.mem.endsWith(u8, entry.path, ".js");
                entry.role = if (react) .island else .plain;
                entry.is_island = react;
            },
            .nuxt => entry.role = .plain,
            .jekyll => entry.role = .partial,
            .eleventy, .hexo => entry.role = .partial,
            else => {},
        }
    }

    return .{
        .entries = entries.toOwnedSlice(gpa) catch fatal.oom(),
        .island_names = names,
        .has_config = sourceMarker(io, gpa, root, source),
        .has_astro_sitemap = false,
    };
}

pub fn migrate(io: Io, gpa: Allocator, args: []const []const u8) bool {
    var project_dir: ?[]const u8 = null;
    var requested_source: ?Source = null;
    var out_path: []const u8 = "MIGRATION.md";
    var scaffold_dir: ?[]const u8 = null;
    var content_dir: ?[]const u8 = null;
    var assets_dir: ?[]const u8 = null;
    var target_dir: ?[]const u8 = null;
    var runtime_path: ?[]const u8 = null;
    var output_set = false;
    var doctor_path: ?[]const u8 = null;
    var json: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            fatal.usage(usage, .{});
        } else if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --from needs a source framework\n\n" ++ usage, .{});
            requested_source = Source.parse(args[i]) orelse fatal.usageError("error: unsupported --from source: {s}\n\n" ++ usage, .{args[i]});
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --output needs a path\n\n" ++ usage, .{});
            out_path = args[i];
            output_set = true;
        } else if (std.mem.eql(u8, a, "--target")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --target needs a directory path\n\n" ++ usage, .{});
            target_dir = args[i];
        } else if (std.mem.eql(u8, a, "--runtime-path")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --runtime-path needs a path\n\n" ++ usage, .{});
            runtime_path = args[i];
        } else if (std.mem.eql(u8, a, "--scaffold")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --scaffold needs a directory path\n\n" ++ usage, .{});
            scaffold_dir = args[i];
        } else if (std.mem.eql(u8, a, "--convert-content")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --convert-content needs a directory path\n\n" ++ usage, .{});
            content_dir = args[i];
        } else if (std.mem.eql(u8, a, "--copy-assets")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --copy-assets needs a directory path\n\n" ++ usage, .{});
            assets_dir = args[i];
        } else if (std.mem.eql(u8, a, "--doctor")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --doctor needs a path\n\n" ++ usage, .{});
            doctor_path = args[i];
        } else if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (a.len > 0 and a[0] != '-') {
            project_dir = a;
        } else {
            fatal.usageError("error: unknown option: {s}\n\n" ++ usage, .{a});
        }
    }

    if (doctor_path != null and (scaffold_dir != null or content_dir != null or assets_dir != null or target_dir != null)) {
        fatal.usageError("error: --doctor is mutually exclusive with --target, --scaffold, --convert-content, and --copy-assets\n\n" ++ usage, .{});
    }
    if (target_dir != null and (output_set or scaffold_dir != null or content_dir != null or assets_dir != null)) fatal.usageError(
        "error: --target is mutually exclusive with --output, --scaffold, --convert-content, and --copy-assets\n\n" ++ usage,
        .{},
    );
    if (runtime_path != null and target_dir == null) fatal.usageError(
        "error: --runtime-path is only valid with --target\n\n" ++ usage,
        .{},
    );
    if (runtime_path) |path| if (!runtimePathIsJsonSafe(path)) fatal.usageError(
        "error: --runtime-path may not contain quotes, backslashes, or control characters\n\n" ++ usage,
        .{},
    );
    if (doctor_path) |dp| return doctor(io, gpa, dp, json);

    const dir_path = project_dir orelse fatal.usageError("error: missing <project-dir>\n\n" ++ usage, .{});

    const root = Io.Dir.cwd().openDir(io, dir_path, .{}) catch |err|
        fatal.dir(dir_path, err);
    defer root.close(io);

    const source = requested_source orelse detectSource(io, gpa, root);
    if (scaffold_dir != null and !source.supportsScaffold()) fatal.usageError(
        "error: --scaffold supports Astro, Next.js, and Gatsby React sources; {s} requires a template/component port\n\n" ++ usage,
        .{source.name()},
    );
    if (content_dir != null and source.contentSource() == null) fatal.usageError(
        "error: --convert-content supports Hugo, Jekyll, Eleventy, and Hexo Markdown sources; got {s}\n\n" ++ usage,
        .{source.name()},
    );
    var res = if (source == .astro) scan(io, gpa, root) else scanOther(io, gpa, root, source);
    defer freeScanResult(gpa, &res);

    if (target_dir) |target| return assembleTarget(io, gpa, root, dir_path, target, runtime_path, source, res);

    const report = if (source == .astro)
        buildReport(gpa, dir_path, res.entries, res.has_config, scaffold_dir != null, res.has_astro_sitemap, assets_dir != null, null)
    else
        buildOtherReport(gpa, source, dir_path, res.entries, scaffold_dir != null, content_dir != null, assets_dir != null, null);
    defer gpa.free(report);

    const f = Io.Dir.cwd().createFile(io, out_path, .{}) catch |err|
        fatal.file(out_path, err);
    defer f.close(io);
    var fw = f.writer(io, &.{});
    fw.interface.writeAll(report) catch |err| fatal.file(out_path, err);

    var islands: usize = 0;
    var partials: usize = 0;
    for (res.entries) |e| {
        switch (e.role) {
            .island => islands += 1,
            .partial => partials += 1,
            .plain => {},
        }
    }
    std.debug.print(
        "Wrote {s}: {s}, {d} source file(s), {d} island candidate(s), {d} static partial(s).\n" ++
            "Next: follow MIGRATION.md and {s}.\n",
        .{ out_path, source.name(), res.entries.len, islands, partials, if (source == .astro) "docs/migration/astro-to-zigapagos.md" else "docs/migration/other-frameworks.md" },
    );

    // Scaffold skeletons if requested. The migrate command never clobbers an
    // existing island `.tsx` (force = false → collisions land in `.new`, and a
    // `.new` that is itself taken in `.new.2`, `.new.3`, …).
    if (scaffold_dir) |sdir| {
        scaffoldIslands(io, gpa, root, sdir, res.entries, false);
    }
    if (content_dir) |cdir| convertContent(io, gpa, root, cdir, source.contentSource().?, res.entries);
    if (assets_dir) |adir| copyAssets(io, gpa, root, adir, source);

    return false;
}

/// Recursively collect non-hidden files under `rel` (relative to `base`).
/// A missing directory is silently skipped. Every file is read once: its
/// content feeds both the `client:*` usage set and the per-file `uses_islands`
/// flag. Island classification itself happens in a later pass.
fn scanDir(
    io: Io,
    gpa: Allocator,
    base: Io.Dir,
    rel: []const u8,
    kind: Kind,
    out: *std.ArrayListUnmanaged(Entry),
    island_names: *std.StringHashMapUnmanaged(void),
) void {
    var dir = base.openDir(io, rel, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterateAssumeFirstIteration();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const child = std.fs.path.join(gpa, &.{ rel, entry.name }) catch fatal.oom();
        switch (entry.kind) {
            // `scanFile` takes ownership of `child` (stored verbatim as
            // `Entry.path`, freed by `freeScanResult`). A directory has no
            // such sink — `scanDir` only ever uses `child` as the `rel` for
            // its own recursive walk — so it must free it once that walk
            // returns, or every directory level leaks one join() alloc.
            .directory => {
                scanDir(io, gpa, base, child, kind, out, island_names);
                gpa.free(child);
            },
            else => scanFile(io, gpa, base, child, kind, out, island_names),
        }
    }
}

fn scanFile(
    io: Io,
    gpa: Allocator,
    base: Io.Dir,
    path: []const u8,
    kind: Kind,
    out: *std.ArrayListUnmanaged(Entry),
    island_names: *std.StringHashMapUnmanaged(void),
) void {
    // An unreadable source still belongs in the worklist (the porter has to
    // deal with it), but it contributes no `client:*` call sites — say so
    // rather than letting it look like a scanned-and-clean file.
    const content = readFileContent(io, gpa, base, path) catch |err| blk: {
        std.debug.print(
            "warning: cannot read {s}: {t} — listed in the worklist but scanned as empty\n",
            .{ path, err },
        );
        break :blk "";
    };
    defer gpa.free(content);
    // Any source file may host a `<Component client:*>` call site.
    detect.collectClientUsages(gpa, content, island_names) catch fatal.oom();
    const uses = std.mem.indexOf(u8, content, "client:") != null;
    const paginate = if (kind == .page) detect.detectPaginate(path, content) else null;
    out.append(gpa, .{ .path = path, .kind = kind, .uses_islands = uses, .paginate = paginate }) catch fatal.oom();
}

fn fileExists(io: Io, base: Io.Dir, path: []const u8) bool {
    const f = base.openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn dirExists(io: Io, base: Io.Dir, path: []const u8) bool {
    const dir = base.openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Everything `readFileContent` can fail with, i.e. exactly "this path could
/// not be read": the open and read errors, and nothing else. `OutOfMemory` and
/// the 16 MiB cap are handled in place with `fatal.*` (neither is recoverable
/// per-entry), so they are deliberately absent from this set.
const ReadSourceError = Io.File.OpenError || Io.File.Reader.Error;

/// Read an entire source file into a freshly gpa-allocated slice (caller owns
/// it and must free). A source larger than the 16 MiB cap fails loudly rather
/// than being silently truncated — truncation would drop `client:*` island call
/// sites and emit uncompilable scaffolded `.tsx`.
///
/// An unreadable path (missing, a directory, no read permission, a dangling
/// symlink, I/O error) returns the underlying error. It must NOT be flattened
/// into an empty slice: "" is a legitimate source content that the scaffolder
/// reads as "nothing to port, emit a TODO stub", so conflating the two makes
/// `--scaffold` claim it ported a file it never managed to open.
fn readFileContent(io: Io, gpa: Allocator, base: Io.Dir, path: []const u8) ReadSourceError![]const u8 {
    return base.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
        error.StreamTooLong => fatal.msg(
            "source file exceeds the 16 MiB migration read cap: {s}\n",
            .{path},
        ),
        else => |e| e,
    };
}

// ---------------------------------------------------------------------------
// TSX island scaffold
// ---------------------------------------------------------------------------

/// One output line of the real-port path, plus who owns its bytes.
const OutLine = struct {
    text: []const u8,
    /// True when `text` is a fresh gpa allocation the caller must free; false
    /// when it borrows the caller's `src_content`.
    owned: bool,
};

/// Process one line of a TSX/JSX source file for the real-port path:
///   - Lines importing from React packages → rewrite specifier to "@z/runtime"
///   - Lines with only a default/namespace React import (no named imports) → drop
///   - Lines importing from bare npm packages → keep but append specifier to `flagged`
/// Returns the (possibly rewritten) line, or null to drop the line entirely.
/// Rewritten lines and the `flagged` specifiers are gpa-allocated; the caller
/// frees both (see `writeIslandSkeleton`).
///
/// NOTE: only SINGLE-LINE imports are inspected. A multi-line import where
/// `} from "react";` appears on its own line is left as-is — the porter must
/// check and rewrite those manually.
fn processImportLine(
    gpa: Allocator,
    line: []const u8,
    flagged: *std.ArrayListUnmanaged([]const u8),
) ?OutLine {
    const verbatim: OutLine = .{ .text = line, .owned = false };
    const trimmed = std.mem.trimStart(u8, line, " \t");

    // Must start with "import" to be an ES import statement.
    if (!std.mem.startsWith(u8, trimmed, "import ") and
        !std.mem.startsWith(u8, trimmed, "import{"))
        return verbatim;

    // Locate " from " to extract the module specifier.
    const from_pos = std.mem.indexOf(u8, line, " from ") orelse return verbatim;
    const after_from = from_pos + " from ".len; // points at the opening quote
    if (after_from >= line.len) return verbatim;

    const q = line[after_from]; // '"' or '\''
    if (q != '"' and q != '\'') return verbatim;

    const spec_start = after_from + 1;
    const spec_end = std.mem.indexOfScalarPos(u8, line, spec_start, q) orelse return verbatim;
    const specifier = line[spec_start..spec_end];

    switch (detect.classifyImport(specifier)) {
        .react_rewrite => {
            // A pure default or namespace import (no `{` before `from`) carries no
            // named exports that can survive the rewrite → drop the whole line.
            // e.g. `import React from "react"` or `import * as React from "react"`.
            const before_from = line[0..from_pos];
            const brace_pos = std.mem.indexOf(u8, before_from, "{") orelse {
                return null; // drop: only a default/namespace binding, nothing useful remains
            };
            // A mixed import like `import React, { useState } from "react"` has both
            // a default binding and named imports. Strip the default binding: @z/runtime
            // has no default export and keeping `React` causes an ESM link error
            // ("does not provide an export named 'default'").
            const indent_len = before_from.len - std.mem.trimStart(u8, before_from, " \t").len;
            const named_part = before_from[brace_pos..]; // "{ useState }" etc.
            const has_default_binding = brace_pos > indent_len + "import ".len;
            if (has_default_binding) {
                // Strip the default binding; keep only the named imports block.
                return .{ .text = std.fmt.allocPrint(
                    gpa,
                    "{s}import {s} from \"@z/runtime\"{s}",
                    .{ before_from[0..indent_len], named_part, line[spec_end + 1 ..] },
                ) catch fatal.oom(), .owned = true };
            }
            // No default binding — just rewrite the specifier to @z/runtime.
            return .{ .text = std.fmt.allocPrint(
                gpa,
                "{s}\"@z/runtime\"{s}",
                .{ line[0..after_from], line[spec_end + 1 ..] },
            ) catch fatal.oom(), .owned = true };
        },
        .runtime_ok, .first_party_ok, .relative_ok => return verbatim,
        .legacy_shared_map, .forbidden_npm => {
            flagged.append(gpa, gpa.dupe(u8, specifier) catch fatal.oom()) catch fatal.oom();
            return verbatim;
        },
    }
}

/// Write a TSX island file into the already-created `out_file` (`out_path` is
/// carried only for diagnostics). The caller owns `out_file` and closes it.
///
/// **Real-port path** (when `src_content` has a default export): copies the
/// original source with React → `@z/runtime` import rewrites, drops bare React
/// default imports, and appends a NO-NPM-GUARDRAIL block for any remaining bare
/// npm imports the porter must resolve.
///
/// **Skeleton fallback** (when `src_content` is empty or has no default export):
/// emits a minimal TSX stub with `import { useState } from "@z/runtime"`, the
/// inferred `interface Props` verbatim (or an empty stub), and a `TODO` body.
/// `src_content` being empty means the source genuinely *is* empty — an
/// unreadable source never reaches here (see `readFileContent`).
fn writeIslandSkeleton(
    io: Io,
    gpa: Allocator,
    out_file: Io.File,
    out_path: []const u8,
    name: []const u8,
    astro_src_rel: []const u8,
    src_content: []const u8,
) void {
    var buf: [8 * 1024]u8 = undefined;
    var fw = out_file.writer(io, &buf);
    const w = &fw.interface;

    const has_default_export = std.mem.indexOf(u8, src_content, "export default") != null;

    if (src_content.len > 0 and has_default_export) {
        // Real port: rewrite React imports → @z/runtime, flag other npm imports.
        w.print(
            "// Auto-ported by `zigapagos migrate` from {s}\n" ++
                "// Review against docs/migration/recipes.md before use.\n\n",
            .{astro_src_rel},
        ) catch |err| fatal.file(out_path, err);

        var flagged: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (flagged.items) |spec| gpa.free(spec);
            flagged.deinit(gpa);
        }
        var lines_it = std.mem.splitScalar(u8, src_content, '\n');
        while (lines_it.next()) |line| {
            if (processImportLine(gpa, line, &flagged)) |out_line| {
                defer if (out_line.owned) gpa.free(out_line.text);
                w.print("{s}\n", .{out_line.text}) catch |err| fatal.file(out_path, err);
            }
            // null → line dropped (pure default/namespace React import)
        }

        if (flagged.items.len > 0) {
            w.writeAll(
                "\n// !! NO-NPM-GUARDRAIL: the following imports are not allowed in islands.\n" ++
                    "// Replace each with @z/runtime bindings, @your-org/shared-lite, or a relative\n" ++
                    "// import. See docs/migration/recipes.md (no-npm-guardrail) for guidance.\n" ++
                    "// Flagged specifiers:\n",
            ) catch |err| fatal.file(out_path, err);
            for (flagged.items) |spec| {
                w.print("//   \"{s}\"\n", .{spec}) catch |err| fatal.file(out_path, err);
            }
        }
    } else {
        // TSX skeleton fallback: header + @z/runtime import + verbatim Props + stub.
        w.print(
            "// Scaffolded by `zigapagos migrate` — port the body from {s}\n" ++
                "// Review against docs/migration/recipes.md before use.\n\n" ++
                "import {{ useState }} from \"@z/runtime\";\n\n",
            .{astro_src_rel},
        ) catch |err| fatal.file(out_path, err);

        // Re-emit Props verbatim when available; otherwise emit an empty stub.
        if (detect.findPropsSpan(src_content)) |span| {
            w.print("export {s}\n\n", .{span}) catch |err| fatal.file(out_path, err);
        } else {
            w.print(
                "export interface Props {{\n" ++
                    "  // TODO: add props (source: {s})\n" ++
                    "}}\n\n",
                .{astro_src_rel},
            ) catch |err| fatal.file(out_path, err);
        }

        w.print(
            "export default function {s}(props: Props) {{\n" ++
                "  // TODO: port the body from {s}\n" ++
                "  return <div />;\n" ++
                "}}\n",
            .{ name, astro_src_rel },
        ) catch |err| fatal.file(out_path, err);
    }

    // Buffered: without this the tail of the island is silently dropped.
    w.flush() catch |err| fatal.file(out_path, err);
}

/// How many `.new`, `.new.2`, … siblings `openMigrationOutput` probes before
/// refusing to generate a migration output at all.
const max_new_versions: u32 = 99;

/// A generated migration output file created without destroying anything.
const MigrationOutput = struct {
    file: Io.File,
    /// The path actually opened.
    path: []const u8,
    /// True when `path` is a fresh gpa allocation the caller must free.
    path_owned: bool,
    /// True when `out_path` was taken and the output landed on a `.new*` sibling.
    collided: bool,
};

/// Create the island output file for `out_path` without ever truncating work
/// the developer may have done.
///
/// `force = true` (documented `--force` semantics): create-or-truncate
/// `out_path`. The user asked for the overwrite.
///
/// `force = false`: EXCLUSIVE-create `out_path`; on `PathAlreadyExists` fall
/// back to `<out_path>.new`, then `.new.2`, `.new.3`, … — each also
/// exclusive-created. This is load-bearing: a `.new` file is exactly where the
/// developer's hand-porting lives (that is what this tool exists to
/// bootstrap), so a plain create-or-truncate on the fallback path silently
/// destroys it on the next run. When every candidate is taken we refuse rather
/// than pick a victim.
///
/// Exclusive create rather than "stat, then create" on purpose: the check-then-
/// write pair is a TOCTOU window, and the kernel already offers the atomic
/// primitive (O_CREAT|O_EXCL).
fn openMigrationOutput(io: Io, gpa: Allocator, out_path: []const u8, force: bool) MigrationOutput {
    if (force) {
        const f = Io.Dir.cwd().createFile(io, out_path, .{ .exclusive = false }) catch |err|
            fatal.file(out_path, err);
        return .{ .file = f, .path = out_path, .path_owned = false, .collided = false };
    }

    if (Io.Dir.cwd().createFile(io, out_path, .{ .exclusive = true })) |f| {
        return .{ .file = f, .path = out_path, .path_owned = false, .collided = false };
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => fatal.file(out_path, err),
    }

    var n: u32 = 1;
    while (n <= max_new_versions) : (n += 1) {
        const candidate = if (n == 1)
            std.fmt.allocPrint(gpa, "{s}.new", .{out_path}) catch fatal.oom()
        else
            std.fmt.allocPrint(gpa, "{s}.new.{d}", .{ out_path, n }) catch fatal.oom();
        if (Io.Dir.cwd().createFile(io, candidate, .{ .exclusive = true })) |f| {
            return .{ .file = f, .path = candidate, .path_owned = true, .collided = true };
        } else |err| switch (err) {
            // Taken — try the next version. (fatal.* is noreturn, so the
            // candidate allocated on the failing branch never outlives us.)
            error.PathAlreadyExists => gpa.free(candidate),
            else => fatal.file(candidate, err),
        }
    }

    fatal.msg(
        "refusing to generate {s}: it and {s}.new … {s}.new.{d} all exist.\n" ++
            "Merge or delete the stale .new files (they hold your in-progress port) and re-run.\n",
        .{ out_path, out_path, out_path, max_new_versions },
    );
}

/// Main entry point for the `--scaffold` step.
///
/// `force` controls collision handling: when false (the `zigapagos migrate`
/// command) an existing island `.tsx` is preserved and the regenerated stub is
/// written alongside as `<Name>.island.tsx.new` (or `.new.2`, … if that is
/// taken too), so neither hand-migrated island code nor a partly-ported `.new`
/// is ever clobbered. When true (`zigapagos init --from-astro --force`) an
/// existing island `.tsx` is overwritten in place, matching the documented
/// `--force` semantics for every other scaffolded file.
///
/// An island whose source cannot be read is reported and SKIPPED — emitting a
/// TODO stub for it would be indistinguishable from a successful scaffold of an
/// empty component, and the developer would believe it had been ported.
pub fn scaffoldIslands(io: Io, gpa: Allocator, astro_root: Io.Dir, scaffold_dir: []const u8, entries: []const Entry, force: bool) void {
    // Ensure the output directory exists (best-effort mkdir, no-op if already there).
    _ = Io.Dir.cwd().createDirPathOpen(io, scaffold_dir, .{}) catch {};

    var scaffolded: usize = 0;
    var skipped: usize = 0;
    var unreadable: usize = 0;

    for (entries) |e| {
        if (!e.is_island) continue;
        const name = detect.moduleName(e.path);

        // Read the source for import rewriting / Props inference. An unreadable
        // source is NOT an empty source: never fall through to the TODO stub.
        const src = readFileContent(io, gpa, astro_root, e.path) catch |err| {
            std.debug.print(
                "  ERROR cannot read {s}: {t} — NOT scaffolded (no stub written)\n",
                .{ e.path, err },
            );
            unreadable += 1;
            continue;
        };
        defer gpa.free(src);

        const base_name = std.fmt.allocPrint(gpa, "{s}.island.tsx", .{name}) catch fatal.oom();
        defer gpa.free(base_name);
        const out_path = std.fs.path.join(gpa, &.{ scaffold_dir, base_name }) catch fatal.oom();
        defer gpa.free(out_path);

        const out = openMigrationOutput(io, gpa, out_path, force);
        defer out.file.close(io);
        defer if (out.path_owned) gpa.free(out.path);

        if (out.collided) {
            std.debug.print(
                "  skip (exists) {s} -> wrote {s} instead\n",
                .{ out_path, out.path },
            );
            skipped += 1;
        } else {
            std.debug.print("  scaffold -> {s}\n", .{out.path});
            scaffolded += 1;
        }

        writeIslandSkeleton(io, gpa, out.file, out.path, name, e.path, src);
    }

    if (unreadable > 0) {
        std.debug.print(
            "Scaffold: {d} island source(s) could not be read and were skipped — port them by hand.\n",
            .{unreadable},
        );
    }
    std.debug.print(
        "Scaffold: {d} written, {d} skipped (already existed -> .new).\n",
        .{ scaffolded, skipped },
    );
}

/// Convert the deterministic portion of Hugo/Jekyll/Eleventy/Hexo Markdown
/// into a separate Zigapagos content tree. Source files are never opened for
/// writing and output collisions use the same exclusive-create + `.new*`
/// contract as islands.
const ContentOutcome = enum { converted, collision, non_markdown, unreadable };

/// NO_SLOP.md section 2.2a contract 1 (self-freeing): every allocation and file
/// opened for one source entry is released before the outcome returns.
fn convertOneContent(
    io: Io,
    gpa: Allocator,
    source_root: Io.Dir,
    out_root: []const u8,
    source: content_convert.Source,
    entry: Entry,
) ContentOutcome {
    const relative = content_convert.outputPath(gpa, source, entry.path) orelse return .non_markdown;
    defer gpa.free(relative);
    const src = readFileContent(io, gpa, source_root, entry.path) catch |err| {
        std.debug.print("  ERROR cannot read {s}: {t} — content not converted\n", .{ entry.path, err });
        return .unreadable;
    };
    defer gpa.free(src);
    const rendered = content_convert.render(gpa, source, entry.path, src);
    defer gpa.free(rendered.bytes);
    const out_path = std.fs.path.join(gpa, &.{ out_root, relative }) catch fatal.oom();
    defer gpa.free(out_path);
    if (std.fs.path.dirname(out_path)) |parent| {
        var parent_dir = Io.Dir.cwd().createDirPathOpen(io, parent, .{}) catch |err|
            fatal.dir(parent, err);
        parent_dir.close(io);
    }
    const out = openMigrationOutput(io, gpa, out_path, false);
    defer out.file.close(io);
    defer if (out.path_owned) gpa.free(out.path);
    var writer = out.file.writer(io, &.{});
    writer.interface.writeAll(rendered.bytes) catch |err| fatal.file(out.path, err);
    if (rendered.has_unconverted_frontmatter) {
        std.debug.print("  REVIEW {s}: unconverted frontmatter preserved in custom.migration_frontmatter\n", .{entry.path});
    }
    if (rendered.invalid_date) {
        std.debug.print("  REVIEW {s}: invalid date preserved in custom.migration_invalid_date; target date uses 1970 placeholder\n", .{entry.path});
    }
    if (out.collided) {
        std.debug.print("  preserve {s} -> wrote {s} instead\n", .{ out_path, out.path });
        return .collision;
    }
    std.debug.print("  content -> {s}\n", .{out.path});
    return .converted;
}

const ContentSummary = struct {
    converted: usize = 0,
    collisions: usize = 0,
    non_markdown: usize = 0,
    unreadable: usize = 0,
};

fn convertContentSummary(
    io: Io,
    gpa: Allocator,
    source_root: Io.Dir,
    out_root: []const u8,
    source: content_convert.Source,
    entries: []const Entry,
) ContentSummary {
    var out_dir = Io.Dir.cwd().createDirPathOpen(io, out_root, .{}) catch |err|
        fatal.dir(out_root, err);
    out_dir.close(io);

    var converted: usize = 0;
    var collisions: usize = 0;
    var non_markdown: usize = 0;
    var unreadable: usize = 0;
    for (entries) |entry| {
        if (entry.kind != .page) continue;
        switch (convertOneContent(io, gpa, source_root, out_root, source, entry)) {
            .converted => converted += 1,
            .collision => collisions += 1,
            .non_markdown => non_markdown += 1,
            .unreadable => unreadable += 1,
        }
    }
    std.debug.print(
        "Content conversion: {d} written, {d} collision version(s), {d} non-Markdown skipped, {d} unreadable.\n",
        .{ converted, collisions, non_markdown, unreadable },
    );
    return .{
        .converted = converted,
        .collisions = collisions,
        .non_markdown = non_markdown,
        .unreadable = unreadable,
    };
}

fn convertContent(
    io: Io,
    gpa: Allocator,
    source_root: Io.Dir,
    out_root: []const u8,
    source: content_convert.Source,
    entries: []const Entry,
) void {
    _ = convertContentSummary(io, gpa, source_root, out_root, source, entries);
}

const AssetFilter = enum { all, jekyll_static, hexo_static };

const AssetRoot = struct {
    source_path: []const u8,
    target_prefix: []const u8,
    filter: AssetFilter = .all,
};

fn assetRoots(source: Source) []const AssetRoot {
    return switch (source) {
        .astro, .nextjs => &.{.{ .source_path = "public", .target_prefix = "" }},
        .gatsby => &.{.{ .source_path = "static", .target_prefix = "" }},
        .nuxt => &.{
            .{ .source_path = "public", .target_prefix = "" },
            .{ .source_path = "static", .target_prefix = "" },
        },
        .hugo => &.{.{ .source_path = "static", .target_prefix = "" }},
        .jekyll => &.{
            .{ .source_path = "assets", .target_prefix = "assets", .filter = .jekyll_static },
            .{ .source_path = "images", .target_prefix = "images" },
            .{ .source_path = "css", .target_prefix = "css" },
            .{ .source_path = "js", .target_prefix = "js" },
            .{ .source_path = "fonts", .target_prefix = "fonts" },
        },
        .eleventy => &.{
            .{ .source_path = "public", .target_prefix = "" },
            .{ .source_path = "assets", .target_prefix = "assets" },
        },
        .hexo => &.{.{ .source_path = "source", .target_prefix = "", .filter = .hexo_static }},
    };
}

fn renderableAssetSource(path: []const u8) bool {
    return hasAnyExtension(path, &.{ ".md", ".markdown", ".html", ".htm", ".ejs", ".njk", ".swig", ".pug" });
}

fn skipAssetSource(filter: AssetFilter, path: []const u8) bool {
    return switch (filter) {
        .all => false,
        .jekyll_static => hasAnyExtension(path, &.{ ".scss", ".sass", ".coffee" }),
        .hexo_static => renderableAssetSource(path),
    };
}

/// Copy conventional source asset trees into a separate target. NO_SLOP.md
/// section 2.2a contract 1 (self-freeing): all joined paths are released in
/// the same iteration; no allocation escapes.
const AssetSummary = struct {
    copied: usize = 0,
    collisions: usize = 0,
    skipped: usize = 0,
    roots_found: usize = 0,
};

fn copyAssetsSummary(io: Io, gpa: Allocator, source_root: Io.Dir, out_root: []const u8, source: Source) AssetSummary {
    var target = Io.Dir.cwd().createDirPathOpen(io, out_root, .{}) catch |err| fatal.dir(out_root, err);
    target.close(io);

    var copied: usize = 0;
    var collisions: usize = 0;
    var skipped: usize = 0;
    var roots_found: usize = 0;
    for (assetRoots(source)) |asset_root| {
        var dir = source_root.openDir(io, asset_root.source_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => fatal.dir(asset_root.source_path, err),
        };
        defer dir.close(io);
        roots_found += 1;
        var walker = dir.walk(gpa) catch |err| {
            if (err == error.OutOfMemory) fatal.oom();
            fatal.msg("error: unable to walk asset tree {s}: {t}\n", .{ asset_root.source_path, err });
        };
        defer walker.deinit();
        while (walker.next(io) catch |err| fatal.msg(
            "error: failed scanning asset tree {s}: {t}\n",
            .{ asset_root.source_path, err },
        )) |entry| {
            if (entry.kind != .file) {
                if (entry.kind != .directory) skipped += 1;
                continue;
            }
            if (source == .hexo and
                (std.mem.startsWith(u8, entry.path, "_posts/") or
                    std.mem.startsWith(u8, entry.path, "_drafts/")))
            {
                // Hexo post-asset folders are relocated according to permalink
                // and post_asset_folder configuration; copying them under
                // /_posts or /_drafts would assert a URL we cannot infer.
                continue;
            }
            if (skipAssetSource(asset_root.filter, entry.path)) continue;

            const relative = if (asset_root.target_prefix.len == 0)
                gpa.dupe(u8, entry.path) catch fatal.oom()
            else
                std.fs.path.join(gpa, &.{ asset_root.target_prefix, entry.path }) catch fatal.oom();
            defer gpa.free(relative);
            const out_path = std.fs.path.join(gpa, &.{ out_root, relative }) catch fatal.oom();
            defer gpa.free(out_path);
            if (std.fs.path.dirname(out_path)) |parent| Io.Dir.cwd().createDirPath(io, parent) catch |err| fatal.dir(parent, err);

            const input = entry.dir.openFile(io, entry.basename, .{}) catch |err| fatal.file(entry.path, err);
            defer input.close(io);
            var output = openMigrationOutput(io, gpa, out_path, false);
            defer {
                output.file.close(io);
                if (output.path_owned) gpa.free(output.path);
            }
            var read_buf: [64 * 1024]u8 = undefined;
            var reader = input.reader(io, &read_buf);
            var writer = output.file.writer(io, &.{});
            _ = reader.interface.streamRemaining(&writer.interface) catch |err| fatal.file(entry.path, err);
            writer.interface.flush() catch |err| fatal.file(output.path, err);
            if (output.collided) {
                collisions += 1;
                std.debug.print("  preserve {s} -> copied asset to {s}\n", .{ out_path, output.path });
            } else {
                copied += 1;
                std.debug.print("  asset -> {s}\n", .{output.path});
            }
        }
    }
    std.debug.print(
        "Asset copy: {d} written, {d} collision version(s), {d} non-file entry(s) skipped, {d} conventional root(s) found.\n",
        .{ copied, collisions, skipped, roots_found },
    );
    if (roots_found == 0) std.debug.print(
        "  REVIEW no conventional public/static asset root was found; inspect framework config and copy its declared passthrough/static sources manually.\n",
        .{},
    );
    return .{
        .copied = copied,
        .collisions = collisions,
        .skipped = skipped,
        .roots_found = roots_found,
    };
}

fn copyAssets(io: Io, gpa: Allocator, source_root: Io.Dir, out_root: []const u8, source: Source) void {
    _ = copyAssetsSummary(io, gpa, source_root, out_root, source);
}

const target_layout =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\  <head>
    \\    <meta charset="UTF-8">
    \\    <meta name="viewport" content="width=device-width, initial-scale=1">
    \\    <title :text="$page.title"></title>
    \\  </head>
    \\  <body>
    \\    <main>
    \\      <h1 :text="$page.title"></h1>
    \\      <div :html="$page.content()"></div>
    \\    </main>
    \\  </body>
    \\</html>
    \\
;

const target_placeholder =
    \\---
    \\.title = "Migration placeholder",
    \\.date = @date("1970-01-01T00:00:00"),
    \\.layout = "index.shtml",
    \\.draft = false,
    \\---
    \\The source routes need a semantic port. Start with `MIGRATION.md`.
    \\
;

const target_tsconfig =
    \\{
    \\  "compilerOptions": {
    \\    "jsx": "react-jsx",
    \\    "jsxImportSource": "@z/runtime",
    \\    "moduleResolution": "bundler",
    \\    "strict": true,
    \\    "skipLibCheck": true
    \\  }
    \\}
    \\
;

const target_gitignore =
    \\node_modules/
    \\zig-out/
    \\.zigapagos-cache/
    \\
;

/// True when `child` is `parent` or is below it at a path-component boundary.
fn pathIsInside(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (!std.mem.startsWith(u8, child, parent) or child.len <= parent.len) return false;
    return std.fs.path.isSep(child[parent.len]);
}

fn targetHasEntries(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => fatal.dir(path, err),
    };
    defer dir.close(io);
    var it = dir.iterateAssumeFirstIteration();
    return (it.next(io) catch |err| fatal.dir(path, err)) != null;
}

fn targetPathExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Canonicalize the deepest existing ancestor, then append the still-missing
/// suffix. This catches a target reached through a symlink even before the
/// final directory exists. NO_SLOP.md section 2.2a contract 2 (owned-result):
/// the returned slice is `gpa`-owned; all non-result scratch is freed here.
fn canonicalTargetPath(io: Io, gpa: Allocator, cwd_abs: []const u8, target: []const u8) []const u8 {
    const target_abs = std.fs.path.resolve(gpa, &.{ cwd_abs, target }) catch fatal.oom();
    var ancestor: []const u8 = target_abs;
    while (true) {
        if (Io.Dir.cwd().realPathFileAlloc(io, ancestor, gpa)) |real_ancestor| {
            const suffix_with_sep = target_abs[ancestor.len..];
            var suffix_start: usize = 0;
            while (suffix_start < suffix_with_sep.len and std.fs.path.isSep(suffix_with_sep[suffix_start])) suffix_start += 1;
            const suffix = suffix_with_sep[suffix_start..];
            if (suffix.len == 0) {
                gpa.free(target_abs);
                return real_ancestor;
            }
            const result = std.fs.path.resolve(gpa, &.{ real_ancestor, suffix }) catch fatal.oom();
            gpa.free(real_ancestor);
            gpa.free(target_abs);
            return result;
        } else |err| switch (err) {
            error.FileNotFound => {},
            error.OutOfMemory => fatal.oom(),
            else => fatal.file(ancestor, err),
        }
        ancestor = std.fs.path.dirname(ancestor) orelse return target_abs;
    }
}

/// NO_SLOP.md section 2.2a contract 1 (self-freeing): `full` is temporary and
/// released before return; `bytes` remains caller-owned.
fn writeTargetFile(io: Io, gpa: Allocator, target: []const u8, relative: []const u8, bytes: []const u8) void {
    const full = std.fs.path.join(gpa, &.{ target, relative }) catch fatal.oom();
    defer gpa.free(full);
    if (std.fs.path.dirname(full)) |parent| Io.Dir.cwd().createDirPath(io, parent) catch |err| fatal.dir(parent, err);
    const file = Io.Dir.cwd().createFile(io, full, .{ .exclusive = true }) catch |err| fatal.file(full, err);
    defer file.close(io);
    var writer = file.writer(io, &.{});
    writer.interface.writeAll(bytes) catch |err| fatal.file(full, err);
}

fn targetProjectName(gpa: Allocator, target: []const u8) []const u8 {
    const base = std.fs.path.basename(target);
    if (base.len == 0) return gpa.dupe(u8, "migrated_site") catch fatal.oom();
    const result = gpa.alloc(u8, base.len) catch fatal.oom();
    for (base, 0..) |c, i| result[i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '_';
    if (std.ascii.isDigit(result[0])) result[0] = '_';
    return result;
}

fn emitTargetConfig(gpa: Allocator, with_assets: bool) []const u8 {
    return std.fmt.allocPrint(gpa,
        \\Site {{
        \\    .title = "Migrated site",
        \\    .host_url = "https://example.com",
        \\    .content_dir_path = "content",
        \\    .layouts_dir_path = "layouts",
        \\    .assets_dir_path = "assets",
        \\{s}}}
        \\
    , .{if (with_assets) "    .static_assets = [\"**\"],\n" else ""}) catch fatal.oom();
}

fn emitTargetBuildSh(gpa: Allocator, has_islands: bool) []const u8 {
    return std.fmt.allocPrint(gpa,
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\cd "$(dirname "$0")"
        \\{s}exec "${{ZIGAPAGOS_BIN:-zigapagos}}" release --force --output=zig-out/site "$@"
        \\
    , .{if (has_islands) "bun install --frozen-lockfile 2>/dev/null || bun install\n" else ""}) catch fatal.oom();
}

fn runtimePathIsJsonSafe(runtime_path: []const u8) bool {
    for (runtime_path) |c| if (c == '"' or c == '\\' or c < 0x20 or c == 0x7f) return false;
    return true;
}

fn emitTargetPackage(gpa: Allocator, name: []const u8, runtime_path: []const u8) []const u8 {
    std.debug.assert(runtimePathIsJsonSafe(runtime_path));
    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "name": "{s}",
        \\  "private": true,
        \\  "type": "module",
        \\  "dependencies": {{ "@z/runtime": "file:{s}" }}
        \\}}
        \\
    , .{ name, runtime_path }) catch fatal.oom();
}

/// Assemble a new target from deterministic transforms only. All generated
/// strings and paths are arena-owned and released together on return.
fn assembleTarget(
    io: Io,
    gpa: Allocator,
    source_root: Io.Dir,
    source_path: []const u8,
    target: []const u8,
    runtime_path: ?[]const u8,
    source: Source,
    res: ScanResult,
) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const source_abs = Io.Dir.cwd().realPathFileAlloc(io, source_path, a) catch |err| fatal.dir(source_path, err);
    const cwd_abs = Io.Dir.cwd().realPathFileAlloc(io, ".", a) catch |err| fatal.dir(".", err);
    const target_abs = canonicalTargetPath(io, a, cwd_abs, target);
    if (pathIsInside(source_abs, target_abs)) {
        std.debug.print("error: migration target '{s}' must not be inside source '{s}'.\n", .{ target, source_path });
        return true;
    }
    if (targetHasEntries(io, target)) {
        std.debug.print("error: migration target '{s}' already exists and is non-empty.\n", .{target});
        return true;
    }

    var target_root = Io.Dir.cwd().createDirPathOpen(io, target, .{}) catch |err| fatal.dir(target, err);
    target_root.close(io);
    for ([_][]const u8{ "assets", "components", "content", "layouts" }) |dir_name| {
        const path = std.fs.path.join(a, &.{ target, dir_name }) catch fatal.oom();
        Io.Dir.cwd().createDirPath(io, path) catch |err| fatal.dir(path, err);
    }

    const components = std.fs.path.join(a, &.{ target, "components" }) catch fatal.oom();
    const content = std.fs.path.join(a, &.{ target, "content" }) catch fatal.oom();
    const assets = std.fs.path.join(a, &.{ target, "assets" }) catch fatal.oom();
    if (source.supportsScaffold()) scaffoldIslands(io, gpa, source_root, components, res.entries, false);
    const content_summary = if (source.contentSource()) |content_source|
        convertContentSummary(io, gpa, source_root, content, content_source, res.entries)
    else
        ContentSummary{};
    const asset_summary = copyAssetsSummary(io, gpa, source_root, assets, source);

    var island_count: usize = 0;
    for (res.entries) |entry| if (entry.is_island) {
        island_count += 1;
    };
    const root_content = std.fs.path.join(a, &.{ content, "index.smd" }) catch fatal.oom();
    if (!targetPathExists(io, root_content)) writeTargetFile(io, gpa, target, "content/index.smd", target_placeholder);
    if (asset_summary.copied == 0) writeTargetFile(io, gpa, target, "assets/.gitkeep", "");
    writeTargetFile(io, gpa, target, "layouts/index.shtml", target_layout);
    writeTargetFile(io, gpa, target, ".gitignore", target_gitignore);
    writeTargetFile(io, gpa, target, "AGENTS.md", @embedFile("init/AGENTS.md"));
    writeTargetFile(io, gpa, target, "CLAUDE.md", @embedFile("init/CLAUDE.md"));
    writeTargetFile(io, gpa, target, "zigapagos.ziggy", emitTargetConfig(a, asset_summary.copied > 0));
    writeTargetFile(io, gpa, target, "build.sh", emitTargetBuildSh(a, island_count > 0));
    if (island_count > 0) {
        const project_name = targetProjectName(a, target);
        writeTargetFile(io, gpa, target, "package.json", emitTargetPackage(a, project_name, runtime_path orelse "TODO-SET-RUNTIME-PATH"));
        writeTargetFile(io, gpa, target, "tsconfig.json", target_tsconfig);
    }

    const report = if (source == .astro)
        buildReport(gpa, source_path, res.entries, res.has_config, island_count > 0, res.has_astro_sitemap, asset_summary.copied > 0, target)
    else
        buildOtherReport(gpa, source, source_path, res.entries, island_count > 0, content_summary.converted > 0, asset_summary.copied > 0, target);
    defer gpa.free(report);
    writeTargetFile(io, gpa, target, "MIGRATION.md", report);

    std.debug.print(
        "Assembled {s} from {s}: {d} converted content file(s), {d} island candidate(s), {d} copied asset(s).\nNext: cd {s} && zigapagos validate\n",
        .{ target, source.name(), content_summary.converted, island_count, asset_summary.copied, target },
    );
    if (island_count > 0 and runtime_path == null) std.debug.print(
        "  REVIEW set dependencies.@z/runtime in {s}/package.json before building island bundles.\n",
        .{target},
    );
    return false;
}

/// Render the full MIGRATION.md worklist. NO_SLOP.md §2.2a contract 2
/// (owned-result): the returned slice is gpa-owned — the caller frees it.
/// Must return `aw.toOwnedSlice()`, not `aw.written()`: `written()` is a
/// `buffer[0..end]` VIEW into `Allocating`'s internal buffer, which can be
/// larger than `end` after growth — `gpa.free()`ing that shorter view
/// mismatches the allocator's tracked allocation size and panics ("Invalid
/// free") under the debug allocator. No caller freed this before the
/// pagination worklist test did, so the mismatch went unnoticed.
fn buildOtherReport(gpa: Allocator, source: Source, dir_path: []const u8, entries: []const Entry, has_scaffold: bool, converted_content: bool, copied_assets: bool, assembled_target: ?[]const u8) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    const establish_target = if (assembled_target) |target|
        std.fmt.allocPrint(gpa, "- [x] Minimal Zigapagos target assembled in `{s}` by `--target`.\n", .{target}) catch fatal.oom()
    else
        gpa.dupe(u8, "- [ ] Run `zigapagos init` in a separate target directory.\n") catch fatal.oom();
    defer gpa.free(establish_target);

    w.print(
        \\# Migration worklist: {s} ({s}) → Zigapagos
        \\
        \\Generated by `zigapagos migrate`. To bypass auto-detection, select this source with
        \\`--from {s}`. Follow the source-specific mapping in
        \\`docs/migration/other-frameworks.md`, then use `docs/migration/recipes.md` for TSX.
        \\
        \\Source files are read-only. Deterministic conversions assembled by `--target`
        \\or requested with `--scaffold`, `--convert-content`, or `--copy-assets` are called out below; ambiguous framework
        \\semantics stay review items.
        \\
        \\## 1. Establish the target
        \\
        \\{s}
        \\{s}
        \\- [ ] Port the source config to `zigapagos.ziggy` and one `build.sh` invocation.
        \\
    , .{ dir_path, source.name(), switch (source) {
        .nextjs => "next",
        .gatsby => "gatsby",
        .nuxt => "nuxt",
        .hugo => "hugo",
        .jekyll => "jekyll",
        .eleventy => "11ty",
        .hexo => "hexo",
        .astro => unreachable,
    }, establish_target, if (assembled_target != null)
        if (copied_assets)
            "- [x] Conventional fixed-URL assets copied to `assets/`; `zigapagos.ziggy` starts with `static_assets = [\"**\"]`. Review pipeline-managed and config-declared assets."
        else
            "- [ ] No conventional public/static asset files were copied. Review framework config for custom passthrough and pipeline-managed assets."
    else if (copied_assets)
        "- [ ] Conventional public/static asset copy was requested; check the CLI summary for roots/files found. Review pipeline-managed and config-declared assets, then use `static_assets = [\"**\"]` initially if copied fixed URLs must all remain public."
    else
        "- [ ] Copy static assets without changing public URLs, or re-run with `--copy-assets <target-assets-dir>`." }) catch fatal.oom();

    w.writeAll("## 2. Pages and data\n\n") catch fatal.oom();
    if (converted_content) {
        w.writeAll(
            "Converted Markdown was written to the requested content tree; every file carries `migration_review = true`.\n\n",
        ) catch fatal.oom();
    } else if (source.contentSource() != null) {
        w.writeAll(
            "> **Tip:** re-run with `--convert-content <target-content-dir>` to normalize recognized frontmatter and preserve Markdown bodies without clobbering existing files.\n\n",
        ) catch fatal.oom();
    }
    section(w, entries, .page, "Source pages/routes → `content/**/*.smd` or one `.spa.tsx`");
    section(w, entries, .other, "Data files and custom generator scripts → Ziggy inputs or explicit generation steps");
    w.writeAll(
        \\
        \\- [ ] Classify every route as build-time content, a client-routed SPA route, or backend-owned.
        \\- [ ] Move request-time loaders/API routes to the backend; Zigapagos emits a static tree.
        \\- [ ] Preserve redirects, canonical URLs, path prefixes, pagination, and generated routes.
        \\
        \\## 3. Layouts and reusable templates
        \\
    ) catch fatal.oom();
    section(w, entries, .layout, "Layouts/templates → `layouts/**/*.shtml`");
    otherComponentSection(w, entries, source);

    if (source == .nextjs or source == .gatsby) {
        w.writeAll(
            \\
            \\## 4. React island candidates
            \\
            \\The scanner conservatively lists JSX/TSX under conventional component directories
            \\plus colocated Next.js `use client` modules. Keep interactive roots as
            \\`.island.tsx`; fold presentation-only
            \\components into SuperHTML or keep them as relative children of an island.
            \\
        ) catch fatal.oom();
        islandSection(w, entries);
        if (has_scaffold) w.writeAll(
            "\nStarter islands were requested; React imports are rewritten to `@z/runtime`.\n",
        ) catch fatal.oom();
    } else if (source == .nuxt) {
        w.writeAll(
            \\
            \\## 4. Vue components
            \\
            \\Vue SFCs are not mechanically rewritten to TSX. Classify each component: static
            \\markup becomes a SuperHTML partial; interactive roots are re-authored as
            \\`.island.tsx` against `@z/runtime`. Preserve props, emitted events, slots, and
            \\client-only boundaries explicitly.
            \\
        ) catch fatal.oom();
    } else {
        w.writeAll(
            \\
            \\## 4. Template constructs
            \\
            \\- [ ] Translate includes/shortcodes/filters to SuperHTML partials or Scripty.
            \\- [ ] Translate collections, taxonomies, and data files to sections/frontmatter/generated content.
            \\- [ ] Replace plugin-provided output explicitly; do not silently drop generated files.
            \\
        ) catch fatal.oom();
    }

    w.writeAll(
        \\
        \\## 5. Prove parity
        \\
        \\- [ ] `zigapagos validate --format=json`
        \\- [ ] `zigapagos release --format=json --output=public`
        \\- [ ] `zigapagos doctor public --format=json`
        \\- [ ] Compare the old and new route inventories, metadata, assets, and interactive behavior.
        \\
    ) catch fatal.oom();

    return aw.toOwnedSlice() catch fatal.oom();
}

pub fn buildReport(gpa: Allocator, dir_path: []const u8, entries: []const Entry, has_config: bool, has_scaffold: bool, has_astro_sitemap: bool, copied_assets: bool, assembled_target: ?[]const u8) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    const scaffold_target = if (assembled_target) |target|
        std.fmt.allocPrint(gpa, "- [x] Minimal target scaffold assembled in `{s}` by `--target`.\n", .{target}) catch fatal.oom()
    else
        gpa.dupe(u8, "- [ ] `zigapagos.ziggy` (begins with `Site {`), `content/`, `layouts/`, `assets/`, `components/`, `build.sh`\n") catch fatal.oom();
    defer gpa.free(scaffold_target);

    w.print(
        \\# Migration worklist: {s} → Zigapagos
        \\
        \\Generated by `zigapagos migrate`. Follow this top-to-bottom. The full mapping is in
        \\`docs/migration/astro-to-zigapagos.md`; island recipes in `docs/migration/recipes.md`.
        \\
        \\## 1. Scaffold the target
        \\
        \\{s}{s}{s}{s}
    , .{
        dir_path,
        scaffold_target,
        if (has_config) "- [ ] Port `astro.config.*` → `zigapagos.ziggy` (site/host) + `build.sh` (islands)\n" else "",
        if (has_astro_sitemap) "- [ ] `@astrojs/sitemap` detected → mapped: set `sitemap = true` in `zigapagos.ziggy` (requires `host_url`, already required) — zigapagos generates `sitemap.xml` at release time\n" else "",
        if (assembled_target != null)
            if (copied_assets)
                "- [x] `public/` copied to `assets/` and fixed URLs enabled with `static_assets = [\"**\"]`; review pipeline-managed assets\n"
            else
                "- [ ] No `public/` files were copied; review configured and pipeline-managed assets\n"
        else if (copied_assets)
            "- [ ] `public/` asset copy requested; check the CLI summary for roots/files found, then review pipeline-managed assets and preserve copied fixed URLs with `static_assets = [\"**\"]` initially\n"
        else
            "- [ ] Copy `public/` without changing URL paths, or re-run with `--copy-assets <target-assets-dir>`\n",
    }) catch fatal.oom();

    buildWiringSection(w, entries, has_scaffold);

    w.writeAll(
        \\
        \\## 2. Static layer (mechanical)
        \\
    ) catch fatal.oom();

    section(w, entries, .page, "Pages → `content/**/*.smd` (frontmatter §4, body Markdown)");
    section(w, entries, .layout, "Layouts → `layouts/**/*.shtml` (SuperHTML §5)");
    partialSection(w, entries);

    w.writeAll(
        \\
        \\## 3. Islands (port as TSX — see docs/migration/recipes.md)
        \\
        \\Each component below is used at a call site with a `client:*` directive, so it
        \\is a real island: port it as `components/<Name>.island.tsx` importing from
        \\`@z/runtime`, add an `--island=` line for it in `build.sh`, and replace `<Component client:… />`
        \\with `<island src="components/<Name>.island.tsx" client:… prop-NAME="$expr">`.
        \\Run `zigapagos migrate <astro-dir> --scaffold <out-dir>` to auto-port the imports.
        \\
    ) catch fatal.oom();
    islandSection(w, entries);
    plainComponentNote(w, entries);

    w.writeAll(
        \\
        \\## 4. Translate per construct
        \\
        \\- [ ] Directives `client:load|idle|visible|media|only` map 1:1.
        \\- [ ] Props: `count={5}` → `prop-count="5"` (static) or `prop-count="$expr"` (dynamic Scripty).
        \\- [ ] Default slot: pass markup as **children** — TSX islands receive slot content via `props.children`.
        \\- [ ] Build + fix diagnostics until clean; verify each island hydrates.
        \\
        // §5 lives in migrate_detect.zig (the unit-tested module) with a drift
        // guard so it can't re-list a shipped capability as a gap (the F3 bug).
    ++ detect.capabilities_section) catch fatal.oom();

    return aw.toOwnedSlice() catch fatal.oom();
}

/// Emit a copy-paste-ready `build.sh`, with one `--island=` per detected island.
fn buildWiringSection(w: anytype, entries: []const Entry, has_scaffold: bool) void {
    w.writeAll(
        \\
        \\## 1b. Build wiring (paste into the target)
        \\
        \\One `zigapagos release` invocation server-renders your islands via the Bun
        \\sidecar, bundles each to an ES module, and stages the `@z/runtime` import
        \\map. It needs `zigapagos` and `bun` — no Zig toolchain.
        \\
        \\
    ) catch fatal.oom();

    if (has_scaffold) {
        w.writeAll(
            \\> **Tip:** run `zigapagos migrate <astro-dir> --scaffold <out-dir>` to generate a
            \\> starter TSX island per detected island (React imports rewritten to
            \\> `@z/runtime`, bare npm imports flagged as NO-NPM-GUARDRAIL). Re-running
            \\> is safe — existing files are skipped; `<Name>.island.tsx.new` is written
            \\> instead, and an existing `.new` you have already started porting is
            \\> itself preserved (the stub goes to `.new.2`, `.new.3`, …).
            \\
            \\
        ) catch fatal.oom();
    } else {
        w.writeAll(
            \\> **Tip:** re-run with `--scaffold <out-dir>` to generate a starter TSX
            \\> island per island (React imports rewritten to `@z/runtime`, bare npm
            \\> imports flagged). Re-running is safe — existing files are never clobbered.
            \\
            \\
        ) catch fatal.oom();
    }

    w.writeAll(
        \\`build.sh`:
        \\
        \\```sh
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\cd "$(dirname "$0")"
        \\
        \\bun install --frozen-lockfile 2>/dev/null || bun install
        \\
        \\exec zigapagos release \
        \\  --force \
        \\  --output=zig-out/site \
        \\  --island-props-check=error \
        \\
    ) catch fatal.oom();

    var any = false;
    for (entries) |e| {
        if (!e.is_island) continue;
        const name = detect.moduleName(e.path);
        // The value must equal the `<island src="...">` string used in your layouts.
        w.print(
            "  --island=components/{s}.island.tsx \\\n",
            .{name},
        ) catch fatal.oom();
        any = true;
    }
    if (!any) w.writeAll(
        "  # no islands detected; e.g. --island=components/Hero.island.tsx \\\n",
    ) catch fatal.oom();

    w.writeAll(
        \\  "$@"
        \\```
        \\
    ) catch fatal.oom();
}

fn section(w: anytype, entries: []const Entry, kind: Kind, title: []const u8) void {
    w.print("\n### {s}\n\n", .{title}) catch fatal.oom();
    var any = false;
    for (entries) |e| {
        if (e.kind == kind) {
            if (e.paginate) |spec| {
                w.print("- [ ] `{s}` — ", .{e.path}) catch fatal.oom();
                detect.paginateNote(w, spec) catch fatal.oom();
                w.writeAll("\n") catch fatal.oom();
                any = true;
                continue;
            }
            const note = if (e.uses_islands) "  — contains `client:` usage; translate the island sites" else "";
            w.print("- [ ] `{s}`{s}\n", .{ e.path, note }) catch fatal.oom();
            any = true;
        }
    }
    if (!any) w.writeAll("- (none found)\n") catch fatal.oom();
}

/// Static `.astro` components (no `client:*` usage) → SuperHTML partials.
fn partialSection(w: anytype, entries: []const Entry) void {
    var any = false;
    for (entries) |e| {
        if (e.role == .partial) {
            if (!any) w.writeAll("\n### Static components → `layouts/templates/**/*.shtml` (partials)\n\n") catch fatal.oom();
            w.print("- [ ] `{s}` — no `client:*` usage; convert to a SuperHTML partial, not an island\n", .{e.path}) catch fatal.oom();
            any = true;
        }
    }
}

fn otherComponentSection(w: anytype, entries: []const Entry, source: Source) void {
    if (source != .nuxt and source != .jekyll and source != .eleventy) return;
    const title = switch (source) {
        .nuxt => "Vue components → classify as SuperHTML partials or TSX interactive roots",
        .jekyll => "Liquid includes → `layouts/templates/**/*.shtml` partials",
        .eleventy => "Eleventy includes → `layouts/templates/**/*.shtml` partials",
        else => unreachable,
    };
    w.print("\n### {s}\n\n", .{title}) catch fatal.oom();
    var any = false;
    for (entries) |entry| {
        if (entry.kind != .component) continue;
        w.print("- [ ] `{s}`\n", .{entry.path}) catch fatal.oom();
        any = true;
    }
    if (!any) w.writeAll("- (none found)\n") catch fatal.oom();
}

fn islandSection(w: anytype, entries: []const Entry) void {
    var any = false;
    for (entries) |e| {
        if (e.is_island) {
            w.print("- [ ] `{s}`\n", .{e.path}) catch fatal.oom();
            any = true;
        }
    }
    if (!any) w.writeAll("- (no islands detected — no component is used with a `client:*` directive)\n") catch fatal.oom();
}

/// Strip a trailing `.island` segment from a module name so that
/// `Flagged.island.tsx` displays as `Flagged`, not `Flagged.island`.
/// Only used in the doctor display path — does NOT change the shared
/// `moduleName`, which the scaffold relies on.
fn islandModuleName(path: []const u8) []const u8 {
    var name = detect.moduleName(path);
    if (std.mem.endsWith(u8, name, ".island")) name = name[0 .. name.len - ".island".len];
    return name;
}

/// Analyse a single island file and emit a human or JSON port-doctor report to
/// stdout. Non-mutating: reads only, writes no files. Returns true when at
/// least one guardrail violation is found (causes a non-zero process exit).
///
/// A failure to *write* the report (EPIPE from `… | head -1`, ENOSPC, EIO)
/// aborts non-zero via `fatal`: exiting 0 after a truncated report would mean
/// "no guardrail violations found", and would hand downstream tooling
/// unparseable JSON.
fn doctor(io: Io, gpa: Allocator, path: []const u8, json: bool) bool {
    const src = readFileContent(io, gpa, Io.Dir.cwd(), path) catch |err|
        fatal.file(path, err);
    defer gpa.free(src);
    if (src.len == 0) fatal.msg("island source is empty, nothing to analyse: {s}\n", .{path});
    var rep = detect.analyze(gpa, islandModuleName(path), src) catch fatal.oom();
    // Pagination detection needs the real `src/pages/...` path (component is
    // just the module name), so it's wired here rather than inside analyze().
    rep.paginate = detect.detectPaginate(path, src);

    const f = Io.File.stdout();
    // Give the writer a real buffer: unbuffered, each of the renderers' ~40
    // `print`/`writeAll` calls would be its own write syscall per report.
    var buf: [8 * 1024]u8 = undefined;
    // `writerStreaming`, not `writer`: `Io.File.writer` defaults to POSITIONAL
    // writes, which track their own offset and ignore the file's shared one.
    // With `cmd >f 2>&1` both descriptors point at ONE open file description,
    // and stderr's `std.debug.print` has already advanced its offset by the
    // time this buffered report flushes -- so a positional flush from offset
    // zero overwrites what stderr committed, silently corrupting anything that
    // parses the merged stream (issue #78). Streaming (positionless, appending)
    // writes advance the shared offset instead. On a pipe or a tty the
    // positional writer already fell back to streaming, so this changes
    // behaviour in exactly the broken case and nowhere else.
    var fw = f.writerStreaming(io, &buf);
    const w = &fw.interface;
    if (json)
        detect.renderDoctorJson(w, rep) catch |err| fatal.msg("error writing doctor report to stdout: {t}\n", .{err})
    else
        detect.renderDoctorHuman(w, rep) catch |err| fatal.msg("error writing doctor report to stdout: {t}\n", .{err});
    w.flush() catch |err| fatal.msg("error writing doctor report to stdout: {t}\n", .{err});
    return rep.violations() > 0;
}

/// Components that are neither islands nor `.astro` partials (e.g. a transitive
/// child of an island, never used with `client:*`). Listed only as a note so
/// they don't get mistaken for islands.
fn plainComponentNote(w: anytype, entries: []const Entry) void {
    var any = false;
    for (entries) |e| {
        if (e.kind == .component and e.role == .plain) {
            if (!any) w.writeAll(
                \\
                \\> **Not islands** (no `client:*` usage anywhere — likely transitive children
                \\> of an island). Port them only as part of the island that uses them:
                \\
            ) catch fatal.oom();
            w.print("> - `{s}`\n", .{e.path}) catch fatal.oom();
            any = true;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "migration sources parse documented names" {
    try std.testing.expectEqual(Source.astro, Source.parse("astro").?);
    try std.testing.expectEqual(Source.nextjs, Source.parse("next").?);
    try std.testing.expectEqual(Source.nextjs, Source.parse("next.js").?);
    try std.testing.expectEqual(Source.gatsby, Source.parse("gatsby").?);
    try std.testing.expectEqual(Source.nuxt, Source.parse("vue").?);
    try std.testing.expectEqual(Source.hugo, Source.parse("hugo").?);
    try std.testing.expectEqual(Source.jekyll, Source.parse("jekyll").?);
    try std.testing.expectEqual(Source.eleventy, Source.parse("11ty").?);
    try std.testing.expectEqual(Source.eleventy, Source.parse("eleventy").?);
    try std.testing.expectEqual(Source.hexo, Source.parse("hexo").?);
    try std.testing.expectEqual(null, Source.parse("express"));
}

test "source auto-detection reads package dependencies when config is optional" {
    const gpa = std.testing.allocator;
    const testing_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing_io, "package.json", .{});
    try file.writeStreamingAll(testing_io, "{\"dependencies\":{\"next\":\"16.0.0\"}}");
    file.close(testing_io);
    try std.testing.expectEqual(Source.nextjs, detectSource(testing_io, gpa, tmp.dir));
}

test "source config wins over a component-framework package dependency" {
    const gpa = std.testing.allocator;
    const testing_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config = try tmp.dir.createFile(testing_io, "astro.config.mjs", .{});
    config.close(testing_io);
    const package = try tmp.dir.createFile(testing_io, "package.json", .{});
    try package.writeStreamingAll(testing_io, "{\"dependencies\":{\"astro\":\"6.0.0\",\"vue\":\"4.0.0\"}}");
    package.close(testing_io);
    try std.testing.expectEqual(Source.astro, detectSource(testing_io, gpa, tmp.dir));
}

test "Next scanner inventories routes and conservative React island candidates" {
    const gpa = std.testing.allocator;
    const testing_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pages = try tmp.dir.createDirPathOpen(testing_io, "src/pages", .{});
    pages.close(testing_io);
    var components = try tmp.dir.createDirPathOpen(testing_io, "src/components", .{});
    components.close(testing_io);
    var app = try tmp.dir.createDirPathOpen(testing_io, "src/app/dashboard", .{});
    app.close(testing_io);
    const page = try tmp.dir.createFile(testing_io, "src/pages/index.tsx", .{});
    try page.writeStreamingAll(testing_io, "export default function Page(){return <main/>}");
    page.close(testing_io);
    const component = try tmp.dir.createFile(testing_io, "src/components/Counter.tsx", .{});
    try component.writeStreamingAll(testing_io, "export default function Counter(){return <button/>}");
    component.close(testing_io);
    const css = try tmp.dir.createFile(testing_io, "src/components/counter.css", .{});
    try css.writeStreamingAll(testing_io, "button{}");
    css.close(testing_io);
    const client = try tmp.dir.createFile(testing_io, "src/app/dashboard/Chart.tsx", .{});
    try client.writeStreamingAll(testing_io, "\"use client\"; export default function Chart(){return <canvas/>}");
    client.close(testing_io);
    const app_page = try tmp.dir.createFile(testing_io, "src/app/dashboard/page.tsx", .{});
    try app_page.writeStreamingAll(testing_io, "\"use client\"; export default function Dashboard(){return <main/>}");
    app_page.close(testing_io);
    const route = try tmp.dir.createFile(testing_io, "src/app/dashboard/route.ts", .{});
    try route.writeStreamingAll(testing_io, "\"use client\"; export function GET(){}");
    route.close(testing_io);

    var result = scanOther(testing_io, gpa, tmp.dir, .nextjs);
    defer freeScanResult(gpa, &result);
    try std.testing.expectEqual(@as(usize, 5), result.entries.len);
    var found_page = false;
    var found_app_page = false;
    var found_route = false;
    var found_island = false;
    var found_colocated_island = false;
    for (result.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "src/pages/index.tsx")) found_page = entry.kind == .page;
        if (std.mem.eql(u8, entry.path, "src/app/dashboard/page.tsx")) found_app_page = entry.kind == .page;
        if (std.mem.eql(u8, entry.path, "src/app/dashboard/route.ts")) found_route = entry.kind == .page;
        if (std.mem.eql(u8, entry.path, "src/components/Counter.tsx")) found_island = entry.is_island;
        if (std.mem.eql(u8, entry.path, "src/app/dashboard/Chart.tsx")) found_colocated_island = entry.is_island;
    }
    try std.testing.expect(found_page);
    try std.testing.expect(found_app_page);
    try std.testing.expect(found_route);
    try std.testing.expect(found_island);
    try std.testing.expect(found_colocated_island);
}

test "non-Astro report names the source and marks ambiguous conversion for review" {
    const gpa = std.testing.allocator;
    const entries = [_]Entry{
        .{ .path = "src/pages/index.tsx", .kind = .page },
        .{ .path = "src/components/Counter.tsx", .kind = .component, .role = .island, .is_island = true },
    };
    const report = buildOtherReport(gpa, .nextjs, "next-site", &entries, true, false, false, null);
    defer gpa.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "Next.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "src/pages/index.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "src/components/Counter.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Generated by `zigapagos migrate`.") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Generated by `zigapagos migrate --from") == null);
    try std.testing.expect(std.mem.indexOf(u8, report, "ambiguous framework") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "semantics stay review items") != null);
}

test "Hugo content conversion writes valid-looking non-clobbering output" {
    const gpa = std.testing.allocator;
    const testing_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var content = try tmp.dir.createDirPathOpen(testing_io, "content/blog", .{});
    content.close(testing_io);
    const source = try tmp.dir.createFile(testing_io, "content/blog/post.md", .{});
    try source.writeStreamingAll(testing_io,
        \\---
        \\title: Post
        \\---
        \\# Preserved body
        \\
    );
    source.close(testing_io);
    const out = try testTmpPath(gpa, &tmp, "converted");
    defer gpa.free(out);
    const entries = [_]Entry{.{ .path = "content/blog/post.md", .kind = .page }};
    convertContent(testing_io, gpa, tmp.dir, out, .hugo, &entries);
    convertContent(testing_io, gpa, tmp.dir, out, .hugo, &entries);

    const first_path = try std.fs.path.join(gpa, &.{ out, "blog/post.smd" });
    defer gpa.free(first_path);
    const first = try Io.Dir.cwd().readFileAlloc(testing_io, first_path, gpa, .limited(64 * 1024));
    defer gpa.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, ".title = \"Post\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, first, "# Preserved body\n"));
    const versioned_path = try std.fs.path.join(gpa, &.{ out, "blog/post.smd.new" });
    defer gpa.free(versioned_path);
    const versioned = try Io.Dir.cwd().readFileAlloc(testing_io, versioned_path, gpa, .limited(64 * 1024));
    defer gpa.free(versioned);
    try std.testing.expectEqualStrings(first, versioned);
}

test "readFileContent reads a source larger than 64 KiB in full (no truncation)" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Content well past the old 64 KiB stack-buffer cap, with a `client:load`
    // island marker placed *after* byte 64K — silent truncation would drop it.
    const big_len = 100 * 1024;
    const content = try gpa.alloc(u8, big_len);
    defer gpa.free(content);
    @memset(content, 'x');
    const marker = "<Widget client:load />";
    @memcpy(content[big_len - marker.len ..], marker);

    {
        const f = try tmp.dir.createFile(testing_io, "big.astro", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll(content);
    }

    const got = try readFileContent(testing_io, gpa, tmp.dir, "big.astro");
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, big_len), got.len);
    // The post-64K marker survives, so island detection sees the whole file.
    try std.testing.expect(std.mem.indexOf(u8, got, "client:load") != null);
}

/// Build a cwd-relative path into a `std.testing.tmpDir`. The scaffold writes
/// through `Io.Dir.cwd()`, so its output directory must be addressable from the
/// process cwd; `tmpDir` places its tree at `.zig-cache/tmp/<sub_path>`.
fn testTmpPath(gpa: Allocator, tmp: *const std.testing.TmpDir, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, rel });
}

test "readFileContent surfaces an unreadable source instead of an empty slice" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // "" is a legitimate file content; a path that cannot be opened is not the
    // same thing and must not be flattened into one. Flattening is what let
    // `--scaffold` emit a TODO stub for a file it never opened and exit 0.
    try std.testing.expectError(
        error.FileNotFound,
        readFileContent(testing_io, gpa, tmp.dir, "does-not-exist.astro"),
    );

    // A genuinely empty file still reads back as an empty slice.
    {
        const f = try tmp.dir.createFile(testing_io, "empty.astro", .{});
        f.close(testing_io);
    }
    const empty = try readFileContent(testing_io, gpa, tmp.dir, "empty.astro");
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "scaffoldIslands skips an unreadable island source instead of emitting a TODO stub" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const scaffold_dir = try testTmpPath(gpa, &tmp, "components");
    defer gpa.free(scaffold_dir);

    // The island is listed in the worklist but its source cannot be read.
    const entries = [_]Entry{.{
        .path = "Ghost.astro",
        .kind = .component,
        .role = .island,
        .is_island = true,
    }};
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, false);

    // No stub may exist: a stub would be indistinguishable from a real port and
    // would make the developer believe Ghost had been migrated.
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(testing_io, "components/Ghost.island.tsx", .{}),
    );
}

test "scaffoldIslands never truncates a hand-edited .new file" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No `export default` → the deterministic skeleton-fallback output.
    {
        const f = try tmp.dir.createFile(testing_io, "Counter.astro", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll("<div>counter</div>\n");
    }

    const scaffold_dir = try testTmpPath(gpa, &tmp, "components");
    defer gpa.free(scaffold_dir);

    const entries = [_]Entry{.{
        .path = "Counter.astro",
        .kind = .component,
        .role = .island,
        .is_island = true,
    }};

    // Run 1: fresh scaffold → Counter.island.tsx.
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, false);
    // Run 2: the .tsx is taken → Counter.island.tsx.new.
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, false);

    // The developer now does the actual porting work IN the .new file — that is
    // precisely what this tool exists to bootstrap.
    const ported = "// hand-ported island — losing this loses the migration work\n";
    {
        const f = try tmp.dir.createFile(testing_io, "components/Counter.island.tsx.new", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll(ported);
    }

    // Run 3 previously re-entered the identical branch and TRUNCATED the .new.
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, false);

    const kept = try tmp.dir.readFileAlloc(testing_io, "components/Counter.island.tsx.new", gpa, .limited(64 * 1024));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings(ported, kept);

    // The regenerated stub landed on a versioned sibling, so nothing is lost
    // and the collision is visible on disk.
    const versioned = try tmp.dir.readFileAlloc(testing_io, "components/Counter.island.tsx.new.2", gpa, .limited(64 * 1024));
    defer gpa.free(versioned);
    try std.testing.expect(std.mem.indexOf(u8, versioned, "port the body from Counter.astro") != null);

    // The original island file is untouched by every non-force run.
    const original = try tmp.dir.readFileAlloc(testing_io, "components/Counter.island.tsx", gpa, .limited(64 * 1024));
    defer gpa.free(original);
    try std.testing.expect(std.mem.indexOf(u8, original, "export default function Counter") != null);
}

test "scaffoldIslands honours --force by overwriting the island in place" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(testing_io, "Counter.astro", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll("<div>counter</div>\n");
    }

    const scaffold_dir = try testTmpPath(gpa, &tmp, "components");
    defer gpa.free(scaffold_dir);

    const entries = [_]Entry{.{
        .path = "Counter.astro",
        .kind = .component,
        .role = .island,
        .is_island = true,
    }};

    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, true);
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, true);

    // `--force` still means overwrite in place — no `.new` sibling appears.
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(testing_io, "components/Counter.island.tsx.new", .{}),
    );
    const out = try tmp.dir.readFileAlloc(testing_io, "components/Counter.island.tsx", gpa, .limited(64 * 1024));
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "export default function Counter") != null);
}

test "scaffoldIslands real-port path rewrites React imports and frees its scratch" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(testing_io, "Form.astro", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll(
            \\import React, { useState } from "react";
            \\import Recaptcha from "react-google-recaptcha";
            \\export default function Form() { return <div />; }
            \\
        );
    }

    const scaffold_dir = try testTmpPath(gpa, &tmp, "components");
    defer gpa.free(scaffold_dir);

    const entries = [_]Entry{.{
        .path = "Form.astro",
        .kind = .component,
        .role = .island,
        .is_island = true,
    }};
    // Raw testing.allocator: the rewritten lines and flagged specifiers are
    // gpa-allocated scratch, so a missed free fails this test.
    scaffoldIslands(testing_io, gpa, tmp.dir, scaffold_dir, &entries, false);

    const out = try tmp.dir.readFileAlloc(testing_io, "components/Form.island.tsx", gpa, .limited(64 * 1024));
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "import { useState } from \"@z/runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NO-NPM-GUARDRAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "react-google-recaptcha") != null);
}

test "paginate: scan flags a paginated route and buildReport prescribes the conversion" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing_io, "src/pages/blog");
    {
        const f = try tmp.dir.createFile(testing_io, "src/pages/blog/[page].astro", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll(
            \\---
            \\import { getCollection } from "astro:content";
            \\export async function getStaticPaths({ paginate }) {
            \\  const posts = await getCollection("blog");
            \\  return paginate(posts, { pageSize: 4 });
            \\}
            \\const { page } = Astro.props;
            \\---
            \\<ul></ul>
            \\
        );
    }

    var res = scan(testing_io, gpa, tmp.dir);
    defer freeScanResult(gpa, &res);

    var found = false;
    for (res.entries) |e| {
        if (!std.mem.eql(u8, e.path, "src/pages/blog/[page].astro")) continue;
        found = true;
        const spec = e.paginate orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("blog", spec.section);
        try std.testing.expectEqual(@as(u32, 4), spec.page_size);
        try std.testing.expectEqual(true, spec.page_size_is_literal);
    }
    try std.testing.expect(found);

    const report = buildReport(gpa, "astro-sample", res.entries, res.has_config, false, res.has_astro_sitemap, false, null);
    defer gpa.free(report);

    try std.testing.expect(std.mem.indexOf(u8, report, "`src/pages/blog/[page].astro`") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "delete the route file") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        report,
        ".pagination = { .page_size = 4, .url_style = \"plain_dir\" }",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "content/blog/index.smd") != null);
}

test "scan detects @astrojs/sitemap in package.json and buildReport flags it in the worklist" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(testing_io, "package.json", .{});
        defer f.close(testing_io);
        var w = f.writer(testing_io, &.{});
        try w.interface.writeAll(
            \\{
            \\  "dependencies": {
            \\    "astro": "^4.0.0",
            \\    "@astrojs/sitemap": "^3.0.0"
            \\  }
            \\}
            \\
        );
    }

    var res = scan(testing_io, gpa, tmp.dir);
    defer freeScanResult(gpa, &res);
    try std.testing.expect(res.has_astro_sitemap);

    const report = buildReport(gpa, "astro-sample", res.entries, res.has_config, false, res.has_astro_sitemap, false, null);
    defer gpa.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "@astrojs/sitemap") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "sitemap = true") != null);
}

test "scan reports no @astrojs/sitemap when package.json is absent or silent about it" {
    const testing_io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No package.json at all: readFileAlloc's error.FileNotFound must fall
    // through to "false", not propagate and abort the whole scan.
    var res = scan(testing_io, gpa, tmp.dir);
    defer freeScanResult(gpa, &res);
    try std.testing.expect(!res.has_astro_sitemap);

    const report = buildReport(gpa, "astro-sample", res.entries, res.has_config, false, res.has_astro_sitemap, false, null);
    defer gpa.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "@astrojs/sitemap") == null);
}

test "usage defines the read-only source and deterministic output contract" {
    const usage_text = usage;
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "Source files are read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "performs the deterministic React part") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "Pages, layouts") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "--scaffold") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "--convert-content") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "--target") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "or empty directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "normalized to Ziggy") != null);
}

test "target containment uses path component boundaries" {
    try std.testing.expect(pathIsInside("/work/source", "/work/source"));
    try std.testing.expect(pathIsInside("/work/source", "/work/source/generated"));
    try std.testing.expect(!pathIsInside("/work/source", "/work/source-copy"));
    try std.testing.expect(!pathIsInside("/work/source", "/work/target"));
}

test "target config publishes copied assets only when the copy wrote files" {
    const gpa = std.testing.allocator;
    const with_assets = emitTargetConfig(gpa, true);
    defer gpa.free(with_assets);
    const without_assets = emitTargetConfig(gpa, false);
    defer gpa.free(without_assets);
    try std.testing.expect(std.mem.indexOf(u8, with_assets, ".static_assets = [\"**\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_assets, ".static_assets") == null);
}

test "runtime paths reject JSON-breaking characters" {
    try std.testing.expect(runtimePathIsJsonSafe("../runtime"));
    try std.testing.expect(!runtimePathIsJsonSafe("bad\"path"));
    try std.testing.expect(!runtimePathIsJsonSafe("bad\\path"));
    try std.testing.expect(!runtimePathIsJsonSafe("bad\npath"));
    try std.testing.expect(!runtimePathIsJsonSafe("bad\tpath"));
    try std.testing.expect(!runtimePathIsJsonSafe(&.{ 'b', 'a', 'd', 0x7f }));
}
