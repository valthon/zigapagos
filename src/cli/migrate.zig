const std = @import("std");
const Io = std.Io;
const fatal = @import("../fatal.zig");
const detect = @import("migrate_detect.zig");
const content_convert = @import("migrate_content.zig");
const rails = @import("rails/rails.zig");
const options = @import("options");
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
    rails,

    fn parse(value: []const u8) ?Source {
        if (std.mem.eql(u8, value, "astro")) return .astro;
        if (std.mem.eql(u8, value, "next") or std.mem.eql(u8, value, "nextjs") or std.mem.eql(u8, value, "next.js")) return .nextjs;
        if (std.mem.eql(u8, value, "gatsby")) return .gatsby;
        if (std.mem.eql(u8, value, "nuxt") or std.mem.eql(u8, value, "vue")) return .nuxt;
        if (std.mem.eql(u8, value, "hugo")) return .hugo;
        if (std.mem.eql(u8, value, "jekyll")) return .jekyll;
        if (std.mem.eql(u8, value, "eleventy") or std.mem.eql(u8, value, "11ty")) return .eleventy;
        if (std.mem.eql(u8, value, "hexo")) return .hexo;
        if (std.mem.eql(u8, value, "rails")) return .rails;
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
            .rails => "Rails",
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
    \\Scans an Astro, Next.js, Gatsby, Nuxt/Vue, Hugo, Jekyll, Eleventy, Hexo, or
    \\Rails project and writes MIGRATION.md: a source-specific worklist mapping
    \\files to their Zigapagos targets. The source is auto-detected or selected
    \\with --from.
    \\
    \\Rails discovery inventories the presentation layer and the recovered
    \\route graph (routes come from a static AST walk of config/routes.rb,
    \\never by booting the app). --scaffold, --copy-assets and
    \\--convert-content are all rejected for it -- those are React/Markdown
    \\ports with no Rails equivalent.
    \\
    \\With --target, Rails ALSO assembles a real Zigapagos project: every
    \\provably static route becomes a layout plus a .smd page, deterministic
    \\assets are copied, and DIR/MIGRATION.handoff.json records what each
    \\route became. A route nobody has decided about leaves the run
    \\incomplete (exit 3); answer its findings in DIR/MIGRATION.decisions.json
    \\(see --decisions) and re-run until it exits 0.
    \\
    \\Source files are read-only. The command always writes a MIGRATION.md
    \\worklist. With --scaffold it also performs the deterministic React part of
    \\the port into a separate directory: starter islands, React imports rewritten
    \\to @z/runtime, and ambiguous npm imports marked for review. Pages, layouts,
    \\data loaders, plugins, and framework config remain explicit worklist items.
    \\
    \\Options:
    \\  --from SOURCE         astro|next|gatsby|nuxt|vue|hugo|jekyll|11ty|hexo|rails
    \\                        (default: auto; use when detection is ambiguous)
    \\  -o, --output PATH      Report path (default: MIGRATION.md)
    \\  --target DIR           Assemble a minimal Zigapagos project in a missing
    \\                         or empty directory. Runs every deterministic step
    \\                         supported for the detected source: content
    \\                         conversion, React island scaffolding, and fixed-URL
    \\                         asset copying. Writes the worklist to DIR/MIGRATION.md.
    \\                         For Rails it converts every provably static
    \\                         route into a layout and a .smd page, copies
    \\                         deterministic assets, and writes three artifacts
    \\                         into DIR -- MIGRATION.md,
    \\                         MIGRATION.manifest.json and
    \\                         MIGRATION.handoff.json -- beside the project
    \\                         tree itself (zigapagos.ziggy, build.sh,
    \\                         content/, layouts/, assets/).
    \\                         DIR must be missing or empty -- except that a
    \\                         Rails DIR may already hold
    \\                         MIGRATION.decisions.json and nothing else, so
    \\                         the decide-and-re-run loop can wipe its output
    \\                         without losing the answers. Mutually exclusive
    \\                         with --output, --scaffold, --convert-content,
    \\                         and --copy-assets.
    \\  --decisions FILE       Rails only: the operator's answers to this app's
    \\                         findings (schema zigapagos.rails-decisions/1).
    \\                         Defaults to DIR/MIGRATION.decisions.json when
    \\                         --target is given and that file exists. A choice
    \\                         the finding does not offer, a missing rationale
    \\                         or a duplicate entry is fatal, with every
    \\                         offending entry named. An id matching no finding
    \\                         in this run is NOT fatal: it is reported as a
    \\                         RAILS_DECISION_STALE blocker and the exit code
    \\                         is unaffected, because fixing the template you
    \\                         were asked about is what makes its id disappear.
    \\  --backend FILE         Rails only: the ZigBase OpenAPI document this
    \\                         app's mutations should bind to, as written by
    \\                         `zigbase openapi`. Its operations become the
    \\                         choices a RAILS_BACKEND_ENDPOINT finding offers
    \\                         and a RAILS_AUTH_JOURNEY answer's auth
    \\                         collection is validated against it; an answered
    \\                         finding then becomes a real client call in a
    \\                         generated island. Without it those findings
    \\                         offer only retain/blocked, so a backend route
    \\                         can be acknowledged but not bound.
    \\                         There is NO default location: a document the
    \\                         operator did not name is a document this run
    \\                         does not have. A FILE that cannot be read, or
    \\                         that is not an OpenAPI 3.x document with a
    \\                         paths object, is fatal (exit 1) -- an operator
    \\                         who passed --backend meant it, and silently
    \\                         degrading to retain/blocked would look like the
    \\                         document simply had no matching operation.
    \\  --runtime-path PATH    With --target, set the local @z/runtime package
    \\                         path in the generated package.json. Written only
    \\                         when the target has JS to install: React island
    \\                         scaffolds, or -- for Rails -- the .spa.tsx a
    \\                         `spa` decision produced AND every island a
    \\                         backend answer binds (the form island of a bound
    \\                         form, the click island of a bound link, and the
    \\                         AuthForm/AuthStatus pair an auth-journey
    \\                         `island` answer produces). That is the ordinary
    \\                         outcome of an answered Rails run, not a rare one.
    \\                         Falls back to ZIGAPAGOS_RUNTIME_DIR when that is
    \\                         set (#179); this flag wins over it, because a
    \\                         flag is an explicit answer and the variable an
    \\                         ambient one. With neither, the dependency is a
    \\                         visible file:TODO-SET-RUNTIME-PATH placeholder
    \\                         and the target's own build.sh cannot install it.
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
    \\  --strict               Rails only: exit non-zero if the manifest records
    \\                         ANY blocker, regardless of severity. Report and
    \\                         manifest are unaffected -- only the exit code
    \\                         changes. For an agent loop or a CI gate that
    \\                         wants a clean discovery or none.
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

fn configMarker(io: Io, gpa: Allocator, root: Io.Dir, source: Source) bool {
    // Rails detection is evidence-based, not marker-file-based: one of its two
    // conclusive branches has no marker file to test for, so routing it through
    // the `markers` loop below would silently defeat that branch.
    if (source == .rails) {
        const v = rails.detect.verdict(rails.detect.collect(io, gpa, root) catch |err| switch (err) {
            error.OutOfMemory => fatal.oom(),
        });
        // `.indeterminate` (structural evidence Rails-shaped, but a piece
        // needed to confirm it was unreadable rather than absent) counts as
        // Rails for auto-detection too: routing it through discovery is what
        // lets `RAILS_GEMFILE_UNREADABLE` (or the analogous inventory
        // blocker) actually surface, instead of the unreadable evidence
        // silently sinking this candidate and auto-detection falling
        // through to "could not confidently detect a source framework".
        return v == .rails or v == .indeterminate;
    }
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
        .rails => &.{},
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
    if (configMarker(io, gpa, root, source)) return true;
    return switch (source) {
        .astro => packageDeclares(io, gpa, root, "astro"),
        .nextjs => packageDeclares(io, gpa, root, "next"),
        .gatsby => packageDeclares(io, gpa, root, "gatsby"),
        .nuxt => packageDeclares(io, gpa, root, "nuxt") or packageDeclares(io, gpa, root, "vue"),
        .hugo, .jekyll => false,
        .eleventy => packageDeclares(io, gpa, root, "@11ty/eleventy"),
        .hexo => packageDeclares(io, gpa, root, "hexo"),
        .rails => false,
    };
}

fn detectSource(io: Io, gpa: Allocator, root: Io.Dir) Source {
    var found: ?Source = null;
    for ([_]Source{ .astro, .nextjs, .gatsby, .nuxt, .hugo, .jekyll, .eleventy, .hexo, .rails }) |candidate| {
        if (!configMarker(io, gpa, root, candidate)) continue;
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
        "error: could not confidently detect a supported source framework; ask the project owner or pass --from astro|next|gatsby|nuxt|vue|hugo|jekyll|11ty|hexo|rails\n\n" ++ usage,
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
        // Rails never reaches scanOther: `migrate()` dispatches `source ==
        // .rails` straight to `rails.discover` and returns before the
        // scan/scanOther split below. This arm exists only because the
        // switch on `Source` must be exhaustive.
        .rails => false,
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
            const is_nuxt = configMarker(io, gpa, root, .nuxt) or packageDeclares(io, gpa, root, "nuxt");
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
        // Inventory *is* implemented for Rails (src/cli/rails/inventory.zig)
        // -- but `migrate()` dispatches `source == .rails` to
        // `rails.discover` and returns before ever calling `scanOther`, so
        // this arm is unreachable in practice. Kept as a loud `fatal` rather
        // than `unreachable` because, unlike `.astro` (whose `unreachable`
        // is safe under the `source == .astro` guard at the call site),
        // Rails has no such guard here: if the dispatch in `migrate()` were
        // ever moved or removed, both `--from rails` and successful
        // auto-detection would flow straight to this line, and a silent
        // trap is worse than a clear error.
        .rails => fatal.usageError(
            "internal error: Rails is dispatched before scanOther; reaching here means the dispatch in migrate() was moved or removed\n\n" ++ usage,
            .{},
        ),
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

/// Rails' exit-code contract for `migrate()`'s bool return (`main.zig`:
/// `@intFromBool(any_error)`). An integrity blocker means the report/
/// manifest's own counts can't be trusted -- that is always a hard failure,
/// `--strict` or not. `--strict` (Stage 4 Task 11, design spec: "`--strict`
/// exits non-zero when any blocker exists") widens the failure set to ANY
/// blocker, deliberately severity-blind (`blockers.Blocker.severity`'s own
/// doc: "do not wire this field into an exit code") -- this reads only the
/// plain count, never `severity`/`integrity` per-entry.
///
/// A pure function on purpose: the discriminating property (task-11-brief.md)
/// is that `--strict` changes ONLY the exit code, never the report or
/// manifest bytes written above it -- keeping the decision in one function
/// with no I/O of its own is what makes that easy to verify without
/// spinning up a fixture.
fn railsExitError(strict: bool, integrity_blocker_count: usize, blocker_count: usize) bool {
    return integrity_blocker_count > 0 or (strict and blocker_count > 0);
}

test "railsExitError: --strict fails on any blocker, not just integrity ones" {
    // Non-strict: a purely descriptive (non-integrity) blocker never fails
    // the run -- this is the "warn" side of severity, and severity does not
    // gate the exit code at all (see the function's own doc).
    try std.testing.expect(!railsExitError(false, 0, 0));
    try std.testing.expect(!railsExitError(false, 0, 3));
    // An integrity blocker always fails, strict or not -- unaffected by
    // this task, pinned here so a future refactor can't silently drop it.
    try std.testing.expect(railsExitError(false, 1, 1));
    try std.testing.expect(railsExitError(true, 1, 1));
    // Strict: a clean discovery (no blockers at all) still exits 0 --
    // `--strict` gates on blocker PRESENCE, not on being asked for at all.
    try std.testing.expect(!railsExitError(true, 0, 0));
    // The discriminating case: strict fails on a blocker set that is
    // ENTIRELY non-integrity (e.g. warn-severity findings only) -- an
    // implementation that read `integrity_blocker_count` instead of the
    // plain `blocker_count` would wrongly pass this.
    try std.testing.expect(railsExitError(true, 0, 3));
}

/// The one file a Rails `--target DIR` may already contain (ruling S3), and
/// the default `--decisions` location. Named once: the guard that tolerates
/// it, the default-path join and the exit-3 instruction must all mean the same
/// file, and three literals would eventually not.
const rails_decisions_basename = "MIGRATION.decisions.json";

/// #179 option 1: the environment variable `scaffold.Input.runtime_dir_env`
/// is filled from. Spelled here rather than imported from `release.zig`'s own
/// `pub const runtime_dir_env` because `src/cli/rails/` is std-only and
/// cannot reach a file that pulls in the wired build (the reason
/// `routes.zig:184` gives for its own copy).
///
/// There are FIVE copies of this literal, not the three an earlier version
/// of this comment claimed: `release.zig:587` (the public one),
/// `rails/routes.zig:184`, `rails/controllers.zig:237`,
/// `rails/fragments.zig:279`, and this one. They must stay in lockstep --
/// `git grep 'const runtime_dir_env'` is the whole list, and this sentence
/// is the tripwire that says so.
const runtime_dir_env = "ZIGAPAGOS_RUNTIME_DIR";

/// Rails' exit code, the whole mapping in one pure function.
///
/// `1` first: an integrity blocker (or `--strict` with any blocker) means the
/// artifacts this run wrote cannot be trusted, and reporting the migration
/// merely "incomplete" would understate that -- `railsExitError`'s own
/// conditions have not changed, they are just no longer the only way to fail.
///
/// `3` is the new outcome (#167 Stage 2): everything was written and read
/// correctly, and at least one user-facing route is still unanswered. It has
/// to be distinct from `1`, because the decide-and-re-run loop is a script
/// that must tell "keep going, here are the questions" apart from "this run
/// is broken, stop".
///
/// `complete` is `null` for a run with no `--target`: there is no scaffold, so
/// there is no handoff and no completion question to answer. Such a run
/// therefore never exits 3, which is why the parameter is an optional rather
/// than a bool defaulting to true -- "no verdict" and "a verdict of complete"
/// are different facts and only one of them is true here.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn railsExitCode(strict: bool, integrity_blocker_count: usize, blocker_count: usize, complete: ?bool) u8 {
    if (railsExitError(strict, integrity_blocker_count, blocker_count)) return 1;
    if (complete) |c| if (!c) return 3;
    return 0;
}

test "railsExitCode: an incomplete handoff exits 3, and a hard failure still outranks it" {
    // No target: no completion verdict, so the pre-existing two-way mapping
    // is unchanged. This is the assertion that stops a future refactor from
    // making a plain `-o` Rails run start exiting 3.
    try std.testing.expectEqual(@as(u8, 0), railsExitCode(false, 0, 0, null));
    try std.testing.expectEqual(@as(u8, 0), railsExitCode(false, 0, 3, null));
    try std.testing.expectEqual(@as(u8, 1), railsExitCode(false, 1, 1, null));
    try std.testing.expectEqual(@as(u8, 1), railsExitCode(true, 0, 3, null));

    // With a target: complete is 0, incomplete is 3.
    try std.testing.expectEqual(@as(u8, 0), railsExitCode(false, 0, 0, true));
    try std.testing.expectEqual(@as(u8, 3), railsExitCode(false, 0, 0, false));
    // Blockers that do not fail the run do not upgrade 3 into 1 either --
    // a warn-severity blocker is normal on an incomplete migration.
    try std.testing.expectEqual(@as(u8, 3), railsExitCode(false, 0, 5, false));

    // The discriminating case, and the reason the order inside the function
    // matters: a run that is BOTH broken and incomplete reports broken. An
    // implementation that checked `complete` first would return 3 here and
    // send a CI loop off answering findings for a discovery it cannot trust.
    try std.testing.expectEqual(@as(u8, 1), railsExitCode(false, 2, 2, false));
    try std.testing.expectEqual(@as(u8, 1), railsExitCode(true, 0, 1, false));
    // ... and 1 also wins over a COMPLETE migration: the artifacts are still
    // the untrustworthy ones.
    try std.testing.expectEqual(@as(u8, 1), railsExitCode(false, 1, 1, true));
}

/// `targetHasEntries`, with one basename tolerated. Split out rather than
/// given a `?[]const u8` parameter on `targetHasEntries` itself so the eight
/// non-Rails sources keep the plain empty-or-missing rule at their call site,
/// visibly: this exception is Rails' alone (ruling S3).
fn targetHasEntriesExcept(io: Io, path: []const u8, allowed: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => fatal.dir(path, err),
    };
    defer dir.close(io);
    var it = dir.iterateAssumeFirstIteration();
    while (it.next(io) catch |err| fatal.dir(path, err)) |entry| {
        // Name AND kind: a DIRECTORY called MIGRATION.decisions.json is not
        // the answers file, and letting it through would hand the scaffold a
        // target it cannot write into for reasons the error would not explain.
        if (entry.kind == .file and std.mem.eql(u8, entry.name, allowed)) continue;
        return true;
    }
    return false;
}

/// Truncate-or-create write of one regenerated Rails artifact. The two call
/// sites had identical five-line bodies differing only in the path; the
/// duplication is what let the report and the manifest drift into being
/// written in a fixed order that #167 Stage 2 then had to swap.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn writeRailsArtifact(io: Io, path: []const u8, bytes: []const u8) void {
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch |err| fatal.file(path, err);
    defer f.close(io);
    var fw = f.writer(io, &.{});
    fw.interface.writeAll(bytes) catch |err| fatal.file(path, err);
}

/// The generated site's title and package name (`scaffold.Input.app_name`).
///
/// The SOURCE directory's basename, not the target's: the site being migrated
/// is the Rails app, and `migrate ./blog --target out` should produce a site
/// called `blog`, not one called `out`. Falls back to the target's basename
/// when the source path names no directory of its own (`.`, `..`, a trailing
/// slash), and to a fixed string when neither does -- `assembleTarget`'s
/// `targetProjectName` makes the same last-resort choice.
///
/// Contract 3 (caller-buffer): returns a borrowed slice of its arguments or a
/// literal; allocates nothing.
fn railsAppName(source_path: []const u8, target: []const u8) []const u8 {
    if (usableBasename(source_path)) |b| return b;
    if (usableBasename(target)) |b| return b;
    return "migrated_site";
}

fn usableBasename(path: []const u8) ?[]const u8 {
    const b = std.fs.path.basename(path);
    if (b.len == 0) return null;
    if (std.mem.eql(u8, b, ".") or std.mem.eql(u8, b, "..")) return null;
    return b;
}

test "railsAppName: the site is named after the Rails app, not the output directory" {
    try std.testing.expectEqualStrings("blog", railsAppName("./blog", "out"));
    try std.testing.expectEqualStrings("blog", railsAppName("/srv/apps/blog/", "out"));
    // The fallbacks, in order: a source path naming no directory hands over
    // to the target, and only a pair that names neither reaches the literal.
    try std.testing.expectEqualStrings("out", railsAppName(".", "out"));
    try std.testing.expectEqualStrings("out", railsAppName("..", "./out"));
    try std.testing.expectEqualStrings("migrated_site", railsAppName(".", "."));
}

/// Distinct `content/` pages the scaffold wrote, for the CLI summary line.
///
/// Distinct, not summed: `RouteOutcome.artifacts` lists every file a route
/// reached, and a page shared by two routes appears on both. Counting
/// occurrences would report more pages than exist on disk. O(n^2) over a
/// handful of routes, which is cheaper than the allocation a set would need.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn railsPageCount(result: rails.scaffold.Result) usize {
    var n: usize = 0;
    for (result.routes, 0..) |o, ri| {
        for (o.artifacts) |a| {
            if (!std.mem.startsWith(u8, a, "content/")) continue;
            var seen = false;
            for (result.routes[0..ri]) |prev| {
                for (prev.artifacts) |pa| {
                    if (std.mem.eql(u8, pa, a)) {
                        seen = true;
                        break;
                    }
                }
                if (seen) break;
            }
            if (!seen) n += 1;
        }
    }
    return n;
}

/// `scaffold.Status` -> `handoff.Status`. An explicit exhaustive switch rather
/// than `@enumFromInt`/`stringToEnum`: the two enums are declared in different
/// files for good reasons (one is a conversion outcome, one is a wire value),
/// and a rename or a new member on either side must break the build here
/// instead of silently re-mapping a route's status.
fn railsHandoffStatus(s: rails.scaffold.Status) rails.handoff.Status {
    return switch (s) {
        .migrated => .migrated,
        .open => .open,
        .blocked => .blocked,
        .retained => .retained,
        .backend => .backend,
        .redirect => .redirect,
    };
}

/// `scaffold.Result.routes` -> `handoff.RouteRow[]` (ruling S5: `handoff.zig`
/// takes its own input rows so it could be built in parallel with the
/// scaffold, and this is the adapter that ruling promised).
///
/// Every string is BORROWED from `result` and `parsed`, both of which outlive
/// the `handoff.build` call this feeds. `RouteRow.decision` is looked up by
/// `decision_id` rather than carried by the scaffold, because the handoff
/// echoes the operator's `choice`/`rationale` and only the decisions file has
/// those. Note that `decision_id != null` does NOT mean the route was
/// acknowledged: an `island`/`backend` choice, or a `spa` refused for a
/// dynamic first segment, records the decision and leaves the route `open`
/// (task-4-report.md, item 4). The status is copied across verbatim, so that
/// distinction survives.
///
/// Contract 1 (self-freeing): the returned slice is the single allocation and
/// is `gpa.free`d by the caller; nothing inside it is owned.
fn railsHandoffRoutes(
    gpa: Allocator,
    result: rails.scaffold.Result,
    parsed: rails.decisions.Parsed,
) []rails.handoff.RouteRow {
    const rows = gpa.alloc(rails.handoff.RouteRow, result.routes.len) catch fatal.oom();
    for (result.routes, 0..) |o, i| {
        var decision: ?rails.handoff.DecisionRef = null;
        if (o.decision_id) |id| {
            if (rails.decisions.lookup(parsed, id)) |d| {
                decision = .{ .id = d.id, .choice = d.choice, .rationale = d.rationale };
            }
        }
        rows[i] = .{
            .route_index = o.route_index,
            .status = railsHandoffStatus(o.status),
            .artifacts = o.artifacts,
            // #167 Stage 3. Field by field rather than a struct copy: the two
            // `Endpoint` types are declared separately for the same reason
            // the row types are (`scaffold.Endpoint` is a conversion outcome,
            // `handoff.Endpoint` a wire shape whose field ORDER is a
            // contract), so a reorder on either side has to be written out
            // here rather than being absorbed silently.
            .endpoint = if (o.endpoint) |e| .{
                .operation_id = e.operation_id,
                .verb = e.verb,
                .path = e.path,
            } else null,
            .decision = decision,
            .findings = o.open_finding_ids,
            .note = o.note,
        };
    }
    return rows;
}

/// `scaffold.Result.assets` -> `handoff.AssetRow[]`. The two structs carry the
/// same three fields; they are separate types because one is a conversion
/// outcome and the other is an input to a wire format whose field ORDER is a
/// contract. Contract 1, as `railsHandoffRoutes`.
fn railsHandoffAssets(gpa: Allocator, result: rails.scaffold.Result) []rails.handoff.AssetRow {
    const rows = gpa.alloc(rails.handoff.AssetRow, result.assets.len) catch fatal.oom();
    for (result.assets, 0..) |a, i| {
        rows[i] = .{ .source = a.source, .rails_url = a.rails_url, .target_url = a.target_url };
    }
    return rows;
}

/// `scaffold.Result.redirects` -> `handoff.Redirect[]`. `to` is always null in
/// Stage 2 (discovery recovers that an action redirects, not where to), and
/// both types already allow that. Contract 1, as `railsHandoffRoutes`.
fn railsHandoffRedirects(gpa: Allocator, result: rails.scaffold.Result) []rails.handoff.Redirect {
    const rows = gpa.alloc(rails.handoff.Redirect, result.redirects.len) catch fatal.oom();
    for (result.redirects, 0..) |r, i| {
        rows[i] = .{ .from = r.from, .to = r.to };
    }
    return rows;
}

/// Slots `railsRootEvidence` needs: one per positive-evidence field
/// `detect.Evidence` declares (`has_application_rb`, `has_routes_rb`,
/// `has_app_views`, `gemfile_declares_rails`) -- `has_jekyll_config` and the
/// `*_unreadable` companions are never rendered here (see that function's
/// own doc), so this is not `@typeInfo(Evidence).@"struct".fields.len`.
const max_root_evidence = 4;

/// Renders `evidence`'s positive probes as `manifest.SourceInfo.
/// root_evidence` entries (design spec, "The manifest": `["Gemfile",
/// "config/application.rb", "app/views"]`), in `rails.detect.Evidence`'s own
/// field declaration order -- a fixed, deterministic order, not a choice
/// made here. Only POSITIVE evidence is rendered: an `*_unreadable` probe is
/// a fact this run could not confirm, already surfaced as its own blocker
/// (`RAILS_GEMFILE_UNREADABLE` etc. -- see `Evidence`'s own doc on the
/// `unreadable` vs. genuinely-absent distinction), not evidence FOR Rails.
/// `has_jekyll_config` is the veto `verdict` already applies before this
/// function is ever reached (a Jekyll-shaped tree never gets here) and
/// carries no meaning as positive Rails evidence, so it is not rendered.
///
/// Contract 3 (caller-buffer): allocates nothing; `buf` must hold at least
/// `max_root_evidence` slots, and the returned slice borrows it.
fn railsRootEvidence(evidence: rails.detect.Evidence, buf: *[max_root_evidence][]const u8) []const []const u8 {
    var n: usize = 0;
    if (evidence.has_application_rb) {
        buf[n] = "config/application.rb";
        n += 1;
    }
    if (evidence.has_routes_rb) {
        buf[n] = "config/routes.rb";
        n += 1;
    }
    if (evidence.has_app_views) {
        buf[n] = "app/views";
        n += 1;
    }
    if (evidence.gemfile_declares_rails) {
        buf[n] = "Gemfile";
        n += 1;
    }
    return buf[0..n];
}

test "railsRootEvidence: only positive evidence, in Evidence's own field order" {
    var buf: [max_root_evidence][]const u8 = undefined;
    const got = railsRootEvidence(.{
        .has_routes_rb = true,
        .has_app_views = true,
        .gemfile_declares_rails = true,
        // `has_application_rb` deliberately left false -- branch B evidence
        // (routes.rb + app/views + a rails gem) without branch A's marker,
        // the same shape `sourceMarker`'s doc calls "the OTHER conclusive
        // detection branch".
    }, &buf);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("config/routes.rb", got[0]);
    try std.testing.expectEqualStrings("app/views", got[1]);
    try std.testing.expectEqualStrings("Gemfile", got[2]);
}

test "railsRootEvidence: an unreadable probe is not rendered as evidence" {
    // `gemfile_unreadable` is a DIFFERENT fact from `gemfile_declares_rails`
    // (Evidence's own doc: "never when it came back .unreadable") -- this
    // pins that a probe this run could not confirm never masquerades as
    // supporting evidence just because SOME `*_unreadable` companion is set.
    var buf: [max_root_evidence][]const u8 = undefined;
    const got = railsRootEvidence(.{
        .has_application_rb = true,
        .gemfile_unreadable = true,
    }, &buf);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("config/application.rb", got[0]);
}

/// Derives the manifest's sibling path from the report's own `out_path`
/// (design spec, "The manifest": "written beside the report"). Strips
/// `out_path`'s own extension via `std.fs.path.stem` (default `MIGRATION.md`
/// -> `MIGRATION.manifest.json`) rather than a fixed sibling name: `tests/
/// migrate/rails.sh` writes many differently-`-o`'d reports into the SAME
/// directory across one run (`one.md`, `degraded.md`, `empty-routes.md`,
/// ...), and a fixed name would make each report's manifest overwrite the
/// last one written -- exactly the silent-clobber failure mode `--target`'s
/// own doc (`DIR produces both`) is not exempt from: Rails' `--target DIR`
/// (Stage 5) calls this same function with `DIR/MIGRATION.md`, so this
/// derivation is also what keeps its manifest inside DIR rather than
/// alongside whatever the default `out_path` would have been.
///
/// Contract 1 (self-freeing): the one allocation that escapes is the
/// returned path; the intermediate `name` formatting is freed before
/// returning.
fn railsManifestPath(gpa: Allocator, out_path: []const u8) []const u8 {
    const dir = std.fs.path.dirname(out_path);
    const stem = std.fs.path.stem(std.fs.path.basename(out_path));
    const name = std.fmt.allocPrint(gpa, "{s}.manifest.json", .{stem}) catch fatal.oom();
    defer gpa.free(name);
    if (dir) |d| return std.fs.path.join(gpa, &.{ d, name }) catch fatal.oom();
    return gpa.dupe(u8, name) catch fatal.oom();
}

test "railsManifestPath: beside the report, extension replaced, directory preserved" {
    const gpa = std.testing.allocator;
    const default_path = railsManifestPath(gpa, "MIGRATION.md");
    defer gpa.free(default_path);
    try std.testing.expectEqualStrings("MIGRATION.manifest.json", default_path);

    const nested_path = railsManifestPath(gpa, "/tmp/work/one.md");
    defer gpa.free(nested_path);
    try std.testing.expectEqualStrings("/tmp/work/one.manifest.json", nested_path);
}

test "railsManifestPath: two different -o STEMS in the same directory never collide" {
    // F7 (phase-2-review.md): the collision domain is the STEM
    // (`std.fs.path.stem` strips the extension before this function ever
    // sees it), not the basename -- `-o a.md` and `-o a.txt` in the SAME
    // directory both produce `a.manifest.json` and DO collide. This test
    // (and its name) previously claimed "basenames", which is broader than
    // what the function actually guarantees; narrowed to what it proves.
    const gpa = std.testing.allocator;
    const a = railsManifestPath(gpa, "/tmp/work/one.md");
    defer gpa.free(a);
    const b = railsManifestPath(gpa, "/tmp/work/degraded.md");
    defer gpa.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

/// Returns the process exit code directly (`main.zig` passes it through) rather
/// than the `any_error` bool every other command returns. #167 Stage 2 needs a
/// THIRD outcome that the bool cannot express: `0` success, `1` the pre-existing
/// hard failure (an integrity blocker, or `--strict` with any blocker), and `3`
/// "the run worked, wrote everything, and the migration is not finished yet"
/// -- a Rails `--target` whose handoff says `complete: false`. Collapsing 3
/// into 1 would make a CI loop unable to tell a broken discovery from an
/// unanswered question, which is the whole point of the decide-and-re-run
/// loop. See `railsExitCode`.
pub fn migrate(io: Io, gpa: Allocator, args: []const []const u8, environ_map: *const std.process.Environ.Map) u8 {
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
    var strict: bool = false;
    var decisions_path: ?[]const u8 = null;
    var backend_path: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, a, "--decisions")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --decisions needs a file path\n\n" ++ usage, .{});
            decisions_path = args[i];
        } else if (std.mem.eql(u8, a, "--backend")) {
            i += 1;
            if (i >= args.len) fatal.usageError("error: --backend needs a file path\n\n" ++ usage, .{});
            backend_path = args[i];
        } else if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
        } else if (a.len > 0 and a[0] != '-') {
            project_dir = a;
        } else {
            fatal.usageError("error: unknown option: {s}\n\n" ++ usage, .{a});
        }
    }

    if (doctor_path != null and (scaffold_dir != null or content_dir != null or assets_dir != null or target_dir != null or decisions_path != null or backend_path != null)) {
        fatal.usageError("error: --doctor is mutually exclusive with --target, --decisions, --backend, --scaffold, --convert-content, and --copy-assets\n\n" ++ usage, .{});
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
    if (doctor_path) |dp| return @intFromBool(doctor(io, gpa, dp, json));

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
    // `--strict` reads `rails.Discovery.blockers`, a concept only the Rails
    // adapter produces -- every other source always returns success (see
    // the bottom of the non-Rails path below, an unconditional `return
    // false`). Rejecting rather than silently accepting a no-op flag
    // matches this function's existing cross-flag checks (--scaffold,
    // --convert-content above; --target/--copy-assets inside the Rails
    // block below) -- "report, never omit silently" applies to a flag with
    // no defined effect just as much as to a construct discovery can't
    // resolve.
    if (strict and source != .rails) fatal.usageError(
        "error: --strict only applies to Rails sources; {s} has no blocker concept yet\n\n" ++ usage,
        .{source.name()},
    );
    // Same reasoning as `--strict` directly above: findings and the decisions
    // that answer them are a Rails-adapter concept, so the flag has no
    // defined effect anywhere else and is rejected rather than silently
    // ignored ("report, never omit silently"). Unlike `--runtime-path`,
    // `--decisions` is NOT gated on `--target`: without a target it still
    // validates the file against this run's findings and reports stale
    // answers as blockers, which is a useful check on its own.
    if (decisions_path != null and source != .rails) fatal.usageError(
        "error: --decisions only applies to Rails sources; {s} raises no findings to decide\n\n" ++ usage,
        .{source.name()},
    );
    // #167 Stage 3, and gated exactly as `--decisions` is: the backend
    // boundary is a Rails-adapter concept (no other importer derives a
    // finding an operation id could answer), and, like `--decisions`, it is
    // NOT gated on `--target` -- without one it still widens the `choices`
    // the manifest publishes, which is what an operator reads before writing
    // any answers at all.
    if (backend_path != null and source != .rails) fatal.usageError(
        "error: --backend only applies to Rails sources; {s} binds nothing to a ZigBase operation\n\n" ++ usage,
        .{source.name()},
    );
    if (source == .rails) {
        // scanOther is Astro-shaped (it walks and classifies content dirs
        // that don't exist in a Rails tree) and must never see a Rails
        // project, so this stage's whole dispatch lives here, before it.
        //
        // Asset copying runs downstream of the scan/scanOther split this
        // dispatch preempts, so a Rails source hitting it here would
        // otherwise silently produce a MIGRATION.md and a no-op instead of
        // an error -- reject it before doing any Rails work, per the
        // "report, never omit silently" rule. `--target` is NOT rejected: it
        // is how Rails assembles a project at all (#167 Stage 2), and the
        // spec's `--target DIR` contract ("produces both in DIR") covers the
        // discovery artifacts that go with it -- see the `target_dir`
        // handling below, right before they are written.
        if (assets_dir != null) fatal.usageError(
            "error: --copy-assets is not yet supported for Rails sources; asset copying lands in a later stage\n\n" ++ usage,
            .{},
        );

        // `--from rails` bypasses `detectSource` (and therefore the
        // `verdict` check `configMarker` runs for auto-detection), so an
        // explicit request against a non-Rails tree would otherwise reach
        // `rails.discover` unchecked and write a confident-looking, entirely
        // empty report ("Blockers: None.") for a directory that isn't a
        // Rails app at all -- the exact silent-success failure mode this
        // adapter exists to prevent. Gated on `requested_source` rather than
        // re-running the check unconditionally: the auto-detected path
        // already validated this via `detectSource` -> `configMarker`.
        //
        // Only `.not_rails` is fatal here. `.indeterminate` (structural
        // evidence Rails-shaped, but a piece needed to confirm it was
        // unreadable rather than absent -- e.g. routes.rb + app/views
        // present with an unreadable Gemfile) proceeds on purpose: an
        // explicit `--from rails` should let discovery run and report the
        // unreadable evidence as an integrity blocker
        // (`RAILS_GEMFILE_UNREADABLE`), which fails the run via a non-zero
        // exit anyway -- rejecting it here instead would hide *why* with a
        // usage error the operator can't act on.
        // Collected once, unconditionally (not just under `requested_source
        // == .rails` below), because Stage 4 Task 8's manifest needs it too
        // (`manifest.SourceInfo.root_evidence`) -- see `railsRootEvidence`'s
        // doc for why the CALLER supplies this rather than `manifest.build`
        // re-probing the filesystem itself.
        const evidence = rails.detect.collect(io, gpa, root) catch |err| switch (err) {
            error.OutOfMemory => fatal.oom(),
        };

        if (requested_source == .rails) {
            const v = rails.detect.verdict(evidence);
            if (v == .not_rails) fatal.usageError(
                "error: --from rails but {s} is not a Rails app (no config/application.rb, or no routes.rb + app/views + a rails gem)\n\n" ++ usage,
                .{dir_path},
            );
        }

        // #167 Stage 3: the ZigBase contract. Read BEFORE `discover` for the
        // same reason the decisions file is -- `findings.derive` turns its
        // operations into a finding's `choices`, and `decisions.parse`
        // validates an auth-collection artifact against it, and both run
        // inside `discover`.
        //
        // Read via `Io.Dir.cwd()`, not through `root`: the document is the
        // ZigBase side of the migration and lives wherever the operator ran
        // `zigbase openapi`, which is emphatically NOT inside the Rails app
        // being read.
        var backend_doc: ?rails.backend.Document = null;
        defer if (backend_doc) |doc| rails.backend.free(gpa, doc);
        if (backend_path) |p| {
            const bytes = readRailsInput(io, gpa, "--backend", p, 16 * 1024 * 1024) orelse return 1;
            defer gpa.free(bytes);
            backend_doc = rails.backend.parse(gpa, bytes, p) catch |err| switch (err) {
                error.OutOfMemory => fatal.oom(),
                // Exit 1 with the error NAMED, printed here rather than
                // through `fatal.*`, exactly like the decisions-file branch
                // below: the three cases send an operator to three different
                // fixes (`InvalidJson` -- a truncated or hand-edited file;
                // `NotOpenApi3` -- the wrong file entirely, a Gemfile or a
                // package.json; `NoPaths` -- a document generated against an
                // empty data dir), and collapsing them into "could not read"
                // would cost the only clue. The full path, not the basename:
                // this is stderr advice, not an artifact.
                error.InvalidJson, error.NotOpenApi3, error.NoPaths => {
                    std.debug.print(
                        "error: {s} is not a ZigBase OpenAPI document: {t}\n",
                        .{ p, err },
                    );
                    return 1;
                },
            };
        }

        // #167 Stage 2: the operator's answers. Read BEFORE `discover`,
        // because `discover` is what validates them -- an answer is checked
        // against the findings this run derives, which do not exist until it
        // has run (see `rails.DecisionsInput`). The default location is
        // inside the target, which is where the decide-and-re-run loop leaves
        // it and the one file a pre-existing Rails target may contain.
        var default_decisions_buf: ?[]u8 = null;
        defer if (default_decisions_buf) |p| gpa.free(p);
        const effective_decisions_path: ?[]const u8 = if (decisions_path) |p| p else blk: {
            const target = target_dir orelse break :blk null;
            const joined = std.fs.path.join(gpa, &.{ target, rails_decisions_basename }) catch fatal.oom();
            // Existence-gated, not read-gated: the FIRST run of every
            // migration has no answers file, and that is the normal state,
            // not a failure. An explicit --decisions is held to a higher
            // standard below, because the operator named it.
            if (!targetPathExists(io, joined)) {
                gpa.free(joined);
                break :blk null;
            }
            default_decisions_buf = joined;
            break :blk joined;
        };
        const decisions_bytes: ?[]const u8 = if (effective_decisions_path) |p|
            readRailsInput(io, gpa, "--decisions", p, 4 * 1024 * 1024) orelse return 1
        else
            null;
        defer if (decisions_bytes) |b| gpa.free(b);
        // The path a RAILS_DECISION_STALE blocker names, and therefore a
        // string that lands in MIGRATION.manifest.json. ALWAYS the basename:
        // "no absolute paths in any artifact" is a hard determinism rule (two
        // operators running the same command from different checkouts must
        // produce the same manifest bytes), and a relative path is no safer
        // than an absolute one -- `--decisions ../answers/x.json` or the
        // default `out/MIGRATION.decisions.json` both encode where the
        // operator happened to stand when they ran the command, so two runs
        // of the same migration from different directories would differ in
        // the manifest. The basename still points at the right file, and the
        // stderr messages (which are not artifacts) print the full path.
        const decisions_label: []const u8 = if (effective_decisions_path) |p|
            std.fs.path.basename(p)
        else
            rails_decisions_basename;

        var decision_problems: std.ArrayListUnmanaged(rails.decisions.Problem) = .empty;
        defer rails.decisions.freeProblems(gpa, &decision_problems);
        // Resolve the source once, up front. The report titles itself by the
        // source's basename and the scaffold names the site by it, and `.`
        // or `./` has no basename until it is resolved -- so both consumers
        // read the real path and cannot disagree (#178).
        const source_real = Io.Dir.cwd().realPathFileAlloc(io, dir_path, gpa) catch |err| fatal.dir(dir_path, err);
        defer gpa.free(source_real);

        const discovery = rails.discover(io, gpa, root, source_real, environ_map, .{
            .bytes = decisions_bytes,
            .path = decisions_label,
            .problems = &decision_problems,
            .backend = backend_doc,
        }) catch |err| switch (err) {
            error.OutOfMemory => fatal.oom(),
            // EVERY complaint, not just the first. A hand-written answers
            // file usually has more than one fault, and `decisions.parse`
            // accumulates rather than short-circuiting precisely so the
            // operator fixes them in one pass instead of re-running per typo.
            // Exit 1, not 3: the file the operator wrote is wrong, which is a
            // failure of this invocation, not an unfinished migration.
            error.InvalidJson, error.WrongSchema, error.Invalid => {
                std.debug.print(
                    "error: {s} is not a usable decisions file:\n",
                    .{effective_decisions_path orelse rails_decisions_basename},
                );
                for (decision_problems.items) |p| {
                    if (p.id) |id| {
                        std.debug.print("  entry {d} (`{s}`): {s}\n", .{ p.index, id, p.message });
                    } else {
                        std.debug.print("  {s}\n", .{p.message});
                    }
                }
                return 1;
            },
        };
        // Stage 4 Task 4 widened `Discovery` to own the template graph
        // (`route_templates`/`templates`) alongside `report` -- a bare
        // `gpa.free(discovery.report)` would now leak both. `freeDiscovery`
        // is `rails.Discovery`'s own paired release.
        defer rails.freeDiscovery(gpa, discovery);

        // `--target DIR`: reuses `assembleTarget`'s own nested/non-empty
        // guards (`pathIsInside`/`targetHasEntries`/`canonicalTargetPath`) so
        // a Rails target is rejected on the same conditions every other
        // source rejects it on, and `createDirPathOpen` so a missing DIR is
        // created the same way. Computed AFTER `discover()` runs (not before)
        // to match every other source, where the scan also happens
        // unconditionally ahead of `assembleTarget`'s own validation.
        var target_out_path_buf: ?[]u8 = null;
        defer if (target_out_path_buf) |p| gpa.free(p);
        const effective_out_path: []const u8 = if (target_dir) |target| blk: {
            const source_abs = source_real;
            const cwd_abs = Io.Dir.cwd().realPathFileAlloc(io, ".", gpa) catch |err| fatal.dir(".", err);
            defer gpa.free(cwd_abs);
            const target_abs = canonicalTargetPath(io, gpa, cwd_abs, target);
            defer gpa.free(target_abs);
            if (pathIsInside(source_abs, target_abs)) {
                std.debug.print("error: migration target '{s}' must not be inside source '{s}'.\n", .{ target, dir_path });
                return 1;
            }
            // #167 Stage 2 (ruling S3): the ONE exception to "missing or
            // empty". The loop is: run, read the handoff, write answers into
            // DIR/MIGRATION.decisions.json, delete the generated tree, re-run.
            // Deleting the answers along with the output would make the loop
            // lose its own state, so that one basename is tolerated -- and
            // only that one, so an operator who forgot to wipe the previous
            // target still gets told rather than getting a half-overwritten
            // tree. Rails-only: every other source's `assembleTarget` keeps
            // the plain empty-or-missing rule.
            if (targetHasEntriesExcept(io, target, rails_decisions_basename)) {
                std.debug.print(
                    "error: migration target '{s}' already exists and is non-empty (only {s} may be kept between runs).\n",
                    .{ target, rails_decisions_basename },
                );
                return 1;
            }
            var target_root = Io.Dir.cwd().createDirPathOpen(io, target, .{}) catch |err| fatal.dir(target, err);
            target_root.close(io);
            const joined = std.fs.path.join(gpa, &.{ target, "MIGRATION.md" }) catch fatal.oom();
            target_out_path_buf = joined;
            break :blk joined;
        } else out_path;

        // The manifest: "the deliverable; MIGRATION.md is a rendering of
        // it" (design spec, "The manifest"), "written beside the report".
        // `createFile(..., .{})` truncates-or-creates -- this is regenerated
        // output, not hand-edited, so it follows the report's own
        // overwrite-in-place behavior rather than the `--scaffold`/
        // `--copy-assets` `.new*` rule (see `tests/migrate/rails.sh`'s
        // "repeat run overwrites the report" case, which this manifest write
        // is covered by too). Derived from `effective_out_path`, not
        // `out_path`, so `--target DIR` produces `DIR/MIGRATION.manifest.json`
        // beside `DIR/MIGRATION.md` and nothing outside DIR.
        //
        // #167 Stage 2 moved this AHEAD of the report write. The manifest is
        // discovery's verdict and knows nothing about the conversion, so it
        // must stay byte-identical between a `-o` run and a `--target` run
        // (`tests/migrate/rails.sh` pins exactly that); the report now carries
        // a Handoff section that only exists once the scaffold has run, so it
        // has to be written last. Writing them in artifact order rather than
        // in two different orders per branch keeps one code path.
        var evidence_buf: [max_root_evidence][]const u8 = undefined;
        const root_evidence = railsRootEvidence(evidence, &evidence_buf);
        const manifest_bytes = rails.manifest.build(gpa, .{
            .generator_version = options.version,
            .root_evidence = root_evidence,
            .discovery = &discovery,
        }) catch |err| switch (err) {
            error.OutOfMemory => fatal.oom(),
        };
        defer gpa.free(manifest_bytes);

        const manifest_path = railsManifestPath(gpa, effective_out_path);
        defer gpa.free(manifest_path);
        writeRailsArtifact(io, manifest_path, manifest_bytes);

        // #167 Stage 2: the conversion. Only with `--target` -- without one
        // there is nowhere to put a project, and a handoff describing a
        // scaffold that was never written would be a document about nothing.
        var handoff_summary: ?rails.report.HandoffSummary = null;
        if (target_dir) |target| {
            var last_error_path: ?[]const u8 = null;
            defer if (last_error_path) |p| gpa.free(p);
            var last_error: ?anyerror = null;
            const app_name = railsAppName(source_real, target);
            const result = rails.scaffold.write(io, gpa, .{
                .discovery = &discovery,
                .decisions = discovery.decisions,
                .source_root = root,
                .target = target,
                .app_name = app_name,
                .runtime_path = runtime_path,
                // #179 option 1. Stage 3 emits a `package.json` on every
                // bound form, not only for a `spa` decision, so the
                // `file:TODO-SET-RUNTIME-PATH` placeholder went from a rare
                // annoyance to the ordinary outcome of a successful
                // migration. `ZIGAPAGOS_RUNTIME_DIR` is already how
                // `site/build.sh` and `examples/tsx-site/build.sh` point at a
                // checkout's runtime, so honouring it makes the generated
                // target installable in the same shell that generated it.
                // `--runtime-path` still wins (`scaffold.runtimePath`): a
                // flag is an explicit answer, the variable an ambient one.
                .runtime_dir_env = environ_map.get(runtime_dir_env),
                .backend = backend_doc,
                // `scaffold.zig` lives in the std-only `rails/` directory and
                // cannot `@embedFile` across it, so the bytes are passed in --
                // the same two files `assembleTarget` writes for every other
                // source, from the same place.
                .agents_md = @embedFile("init/AGENTS.md"),
                .claude_md = @embedFile("init/CLAUDE.md"),
            }, &last_error_path, &last_error) catch |err| switch (err) {
                error.OutOfMemory => fatal.oom(),
                // Both members render through `fatal.file`, which is the one
                // call that prints "path: reason". Which filesystem the path
                // is on is already legible from the path itself, and
                // `last_error` carries the OS cause that would otherwise
                // collapse into the error name (ruling S14) -- the difference
                // between "wipe the target and re-run" and "fix a permission".
                error.TargetWrite, error.SourceRead => fatal.file(
                    last_error_path orelse target,
                    last_error orelse err,
                ),
            };
            defer rails.scaffold.freeResult(gpa, result);

            const route_rows = railsHandoffRoutes(gpa, result, discovery.decisions);
            defer gpa.free(route_rows);
            const asset_rows = railsHandoffAssets(gpa, result);
            defer gpa.free(asset_rows);
            const redirect_rows = railsHandoffRedirects(gpa, result);
            defer gpa.free(redirect_rows);
            const parity_result = rails.parity.build(gpa, &discovery, result, backend_doc) catch |err| switch (err) {
                error.OutOfMemory => fatal.oom(),
            };
            defer rails.parity.free(gpa, parity_result);
            rails.scaffold.writeParityRunners(io, gpa, target, parity_result.entries.len > 0, &last_error_path, &last_error) catch |err| switch (err) {
                error.OutOfMemory => fatal.oom(),
                error.TargetWrite, error.SourceRead => fatal.file(
                    last_error_path orelse target,
                    last_error orelse err,
                ),
            };

            const handoff_bytes = rails.handoff.build(gpa, .{
                .generator_version = options.version,
                .discovery = &discovery,
                .routes = route_rows,
                .assets = asset_rows,
                .redirects = redirect_rows,
                // `Document.file` is already a basename (task-1-report.md),
                // so the operator's directory layout cannot reach this
                // committed artifact.
                .backend = if (backend_doc) |doc| .{
                    .file = doc.file,
                    .contract_version = doc.contract_version,
                } else null,
                .parity = parity_result.entries,
            }) catch |err| switch (err) {
                error.OutOfMemory => fatal.oom(),
            };
            defer gpa.free(handoff_bytes);
            // Exclusive-create, like every other file in the target: a
            // handoff already sitting in a directory this run believes it
            // just created means the guard above was wrong, and overwriting
            // would hide that.
            writeTargetFile(io, gpa, target, "MIGRATION.handoff.json", handoff_bytes);

            // Recomputed here rather than parsed back out of the bytes, but
            // from the SAME rows `build` embedded its own `complete` from --
            // `isComplete` is a pure function of them, so the report, the
            // JSON and the exit code cannot disagree.
            var summary: rails.report.HandoffSummary = .{
                .complete = rails.handoff.isComplete(&discovery, route_rows),
                .backend_doc = if (backend_doc) |doc| .{
                    .file = doc.file,
                    .contract_version = doc.contract_version,
                } else null,
            };
            // Counted over the OUTCOMES, not over `route_rows`, for the same
            // reason the status tally beside it is: one function's own
            // result, so the report cannot disagree with the JSON built from
            // the rows those outcomes produced.
            //
            // The assert is the invariant `report.handoffSection` renders
            // against -- it prints "endpoints: N of the M `backend` route(s)"
            // and that sentence is a lie unless every endpoint sits on a
            // `backend` row (M-2). `scaffold.zig` guarantees it structurally:
            // `out.endpoint` is assigned in exactly one place, inside the
            // `out.status = .backend` branch that returns at its end. A
            // `std.debug.assert` rather than a degradation, because a
            // violation would be an internal scaffolder bug and `fatal.msg`'s
            // own reasoning applies -- that is precisely the case a Debug
            // stack trace exists for.
            for (result.routes) |o| {
                if (o.endpoint != null) {
                    std.debug.assert(o.status == .backend);
                    summary.endpoints += 1;
                }
            }
            for (result.routes) |o| switch (o.status) {
                .migrated => summary.migrated += 1,
                .open => summary.open += 1,
                .blocked => summary.blocked += 1,
                .retained => summary.retained += 1,
                .backend => summary.backend += 1,
                .redirect => summary.redirect += 1,
            };
            handoff_summary = summary;

            std.debug.print(
                "Assembled {s}: {d} page(s), {d} asset(s), {d} route(s) open.\n",
                .{ target, railsPageCount(result), result.assets.len, summary.open },
            );
        }

        // The report, written LAST: with `--target` it carries a Handoff
        // section describing a scaffold that does not exist until the block
        // above has run. Without one it is `discovery.report` unchanged, so
        // the no-target path is byte-for-byte what it always was.
        const report_bytes: []const u8 = if (handoff_summary) |s| blk: {
            const tail = rails.report.handoffSection(gpa, s) catch |err| switch (err) {
                error.OutOfMemory => fatal.oom(),
            };
            defer gpa.free(tail);
            break :blk std.mem.concat(gpa, u8, &.{ discovery.report, tail }) catch fatal.oom();
        } else discovery.report;
        defer if (handoff_summary != null) gpa.free(report_bytes);
        writeRailsArtifact(io, effective_out_path, report_bytes);

        // Mirrors report.zig's own three-way Routes-section conclusion
        // exactly (same predicate: `route_mode == "static_ast"` and no
        // route-related blocker means config/routes.rb genuinely declares
        // no routes) so this one-line CLI summary and the report a user
        // opens right after never disagree about why zero routes were
        // recovered. See rails.Discovery's `route_mode`/`route_blocker` doc.
        if (discovery.route_count > 0) {
            std.debug.print(
                "Wrote {s}: Rails, inventory plus {d} recovered route(s).\n" ++
                    "Next: follow MIGRATION.md.\n",
                .{ effective_out_path, discovery.route_count },
            );
        } else if (!std.mem.eql(u8, discovery.route_mode, "static_ast") or discovery.route_blocker) {
            std.debug.print(
                "Wrote {s}: Rails, inventory only (no routes recovered -- see Blockers in the report).\n" ++
                    "Next: follow MIGRATION.md.\n",
                .{effective_out_path},
            );
        } else {
            std.debug.print(
                "Wrote {s}: Rails, inventory only (config/routes.rb declares no routes).\n" ++
                    "Next: follow MIGRATION.md.\n",
                .{effective_out_path},
            );
        }

        // An integrity blocker (an unreadable/truncated inventory root, an
        // unreadable Gemfile or package.json) means the report was written
        // -- "report, never omit silently" -- but its counts can't be
        // trusted. Say so on stderr and signal failure via the exit code
        // separately from the report itself, so a script driving this
        // command doesn't have to grep MIGRATION.md to notice.
        if (discovery.integrity_blocker_count > 0) {
            std.debug.print(
                "warning: {s} was written, but {d} part(s) of the Rails inventory could not be read; treat its counts as incomplete.\n",
                .{ effective_out_path, discovery.integrity_blocker_count },
            );
        }

        const complete: ?bool = if (handoff_summary) |s| s.complete else null;
        const code = railsExitCode(strict, discovery.integrity_blocker_count, discovery.blockers.len, complete);
        // Only on 3, and only when nothing worse happened: an operator whose
        // run also failed for an integrity reason is told about THAT, and a
        // second "here is what to do next" line under it would be advice they
        // cannot act on yet.
        if (code == 3) {
            // The path the operator actually has to edit, not the basename:
            // this line is stderr advice, not an artifact, so the determinism
            // rule that reduces `decisions_label` does not apply -- and
            // telling someone who ran `--decisions answers/prod.json` to edit
            // "MIGRATION.decisions.json" points them at a file that may not
            // exist. Falls back to the basename only when there is no
            // effective path at all, i.e. the first run of a migration, where
            // the name IS the instruction.
            std.debug.print(
                "{d} route(s) open -- answer the findings in MIGRATION.handoff.json via {s} and re-run.\n",
                .{ handoff_summary.?.open, effective_decisions_path orelse rails_decisions_basename },
            );
        }
        return code;
    }

    var res = if (source == .astro) scan(io, gpa, root) else scanOther(io, gpa, root, source);
    defer freeScanResult(gpa, &res);

    if (target_dir) |target| return @intFromBool(assembleTarget(io, gpa, root, dir_path, target, runtime_path, source, res));

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

    return 0;
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

const AssetFilter = enum { all, vue_public, jekyll_static, hexo_static, hexo_theme_static };

const AssetRoot = struct {
    source_path: []const u8,
    target_prefix: []const u8,
    filter: AssetFilter = .all,
};

const HexoSettings = struct {
    title: ?[]const u8 = null,
    url: ?[]const u8 = null,
    root: ?[]const u8 = null,
    theme: ?[]const u8 = null,
};

fn yamlScalar(value: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, value, " \t\r");
    var quote: ?u8 = null;
    var escaped = false;
    for (trimmed, 0..) |c, i| {
        if (quote) |active| {
            if (active == '"' and c == '\\' and !escaped) {
                escaped = true;
                continue;
            }
            if (c == active and !escaped) quote = null;
            escaped = false;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#' and (i == 0 or trimmed[i - 1] == ' ' or trimmed[i - 1] == '\t')) {
            trimmed = std.mem.trimEnd(u8, trimmed[0..i], " \t");
            break;
        }
    }
    if (trimmed.len >= 2 and
        ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')))
    {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

/// Parse only Hexo's deterministic top-level scalar site settings. Nested YAML,
/// aliases, and computed values remain migration review items.
fn parseHexoSettings(src: []const u8) HexoSettings {
    var result: HexoSettings = .{};
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len == 0 or raw_line[0] == ' ' or raw_line[0] == '\t' or raw_line[0] == '#') continue;
        const separator = std.mem.indexOfScalar(u8, raw_line, ':') orelse continue;
        const key = std.mem.trim(u8, raw_line[0..separator], " \t\r");
        const value = yamlScalar(raw_line[separator + 1 ..]);
        if (value.len == 0) continue;
        if (std.mem.eql(u8, key, "title")) result.title = value else if (std.mem.eql(u8, key, "url")) result.url = value else if (std.mem.eql(u8, key, "root")) result.root = value else if (std.mem.eql(u8, key, "theme")) result.theme = value;
    }
    return result;
}

/// NO_SLOP.md section 2.2a contract 2 (owned-result): the returned theme path,
/// when present, belongs to the caller.
fn hexoThemeSource(io: Io, gpa: Allocator, source_root: Io.Dir, theme: []const u8) ?[]const u8 {
    var themes = source_root.openDir(io, "themes", .{ .iterate = true }) catch return null;
    defer themes.close(io);
    var it = themes.iterateAssumeFirstIteration();
    while (it.next(io) catch return null) |entry| {
        if (entry.kind != .directory or !std.ascii.eqlIgnoreCase(entry.name, theme)) continue;
        return std.fs.path.join(gpa, &.{ "themes", entry.name, "source" }) catch fatal.oom();
    }
    return null;
}

fn assetRoots(source: Source) []const AssetRoot {
    return switch (source) {
        .astro, .nextjs => &.{.{ .source_path = "public", .target_prefix = "" }},
        .gatsby => &.{.{ .source_path = "static", .target_prefix = "" }},
        .nuxt => &.{
            .{ .source_path = "public", .target_prefix = "", .filter = .vue_public },
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
            .{ .source_path = "img", .target_prefix = "img" },
            .{ .source_path = "images", .target_prefix = "images" },
        },
        .hexo => &.{.{ .source_path = "source", .target_prefix = "", .filter = .hexo_static }},
        // `--copy-assets` is rejected outright for Rails sources (see the
        // dispatch in `migrate()`), so this table is never consulted for
        // `.rails`; asset-root conventions for Rails land in a later stage
        // alongside `--target` assembly.
        .rails => &.{},
    };
}

fn renderableAssetSource(path: []const u8) bool {
    return hasAnyExtension(path, &.{ ".md", ".markdown", ".html", ".htm", ".ejs", ".njk", ".swig", ".pug" });
}

fn skipAssetSource(filter: AssetFilter, path: []const u8) bool {
    return switch (filter) {
        .all => false,
        .vue_public => std.mem.eql(u8, path, "index.html"),
        .jekyll_static => hasAnyExtension(path, &.{ ".scss", ".sass", ".coffee" }),
        .hexo_static => renderableAssetSource(path),
        .hexo_theme_static => renderableAssetSource(path) or hasAnyExtension(path, &.{ ".scss", ".sass", ".styl", ".less", ".coffee" }),
    };
}

const AssetSummary = struct {
    copied: usize = 0,
    collisions: usize = 0,
    skipped: usize = 0,
    roots_found: usize = 0,
};

/// NO_SLOP.md section 2.2a contract 1 (self-freeing): all walker and joined
/// path allocations are released before return; only the pointed-to counters
/// are updated.
fn copyAssetRoot(io: Io, gpa: Allocator, source_root: Io.Dir, out_root: []const u8, source: Source, asset_root: AssetRoot, summary: *AssetSummary) void {
    var dir = source_root.openDir(io, asset_root.source_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => fatal.dir(asset_root.source_path, err),
    };
    defer dir.close(io);
    summary.roots_found += 1;
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
            if (entry.kind != .directory) summary.skipped += 1;
            continue;
        }
        if (source == .hexo and asset_root.filter == .hexo_static and
            (std.mem.startsWith(u8, entry.path, "_posts/") or
                std.mem.startsWith(u8, entry.path, "_drafts/")))
        {
            // Hexo post-asset folders are relocated according to permalink
            // and post_asset_folder configuration; copying them under
            // /_posts or /_drafts would assert a URL we cannot infer.
            continue;
        }
        if (skipAssetSource(asset_root.filter, entry.path)) {
            if (asset_root.filter == .vue_public and std.mem.eql(u8, entry.path, "index.html")) std.debug.print(
                "  REVIEW public/index.html is a framework HTML template and was not copied over the Zigapagos root page; port its head metadata manually.\n",
                .{},
            );
            continue;
        }

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
            summary.collisions += 1;
            std.debug.print("  preserve {s} -> copied asset to {s}\n", .{ out_path, output.path });
        } else {
            summary.copied += 1;
            std.debug.print("  asset -> {s}\n", .{output.path});
        }
    }
}

/// Copy conventional source asset trees into a separate target. NO_SLOP.md
/// section 2.2a contract 1 (self-freeing): no allocation escapes.
fn copyAssetsSummary(io: Io, gpa: Allocator, source_root: Io.Dir, out_root: []const u8, source: Source) AssetSummary {
    var target = Io.Dir.cwd().createDirPathOpen(io, out_root, .{}) catch |err| fatal.dir(out_root, err);
    target.close(io);

    var summary: AssetSummary = .{};
    for (assetRoots(source)) |asset_root| copyAssetRoot(io, gpa, source_root, out_root, source, asset_root, &summary);
    if (source == .hexo) {
        const config = source_root.readFileAlloc(io, "_config.yml", gpa, .limited(1024 * 1024)) catch null;
        if (config) |bytes| {
            defer gpa.free(bytes);
            if (parseHexoSettings(bytes).theme) |theme| {
                if (hexoThemeSource(io, gpa, source_root, theme)) |theme_source| {
                    defer gpa.free(theme_source);
                    copyAssetRoot(io, gpa, source_root, out_root, source, .{
                        .source_path = theme_source,
                        .target_prefix = "",
                        .filter = .hexo_theme_static,
                    }, &summary);
                } else {
                    std.debug.print("  REVIEW configured Hexo theme '{s}' has no readable source asset tree.\n", .{theme});
                }
            }
        }
    }
    std.debug.print(
        "Asset copy: {d} written, {d} collision version(s), {d} non-file entry(s) skipped, {d} conventional root(s) found.\n",
        .{ summary.copied, summary.collisions, summary.skipped, summary.roots_found },
    );
    if (summary.roots_found == 0) std.debug.print(
        "  REVIEW no conventional public/static asset root was found; inspect framework config and copy its declared passthrough/static sources manually.\n",
        .{},
    );
    return summary;
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

/// Reads a Rails input file the OPERATOR named on the command line
/// (`--backend FILE`, `--decisions FILE`, or the `--target` default the
/// decide-and-re-run loop leaves behind). Returns `null` after printing the
/// reason, in which case the caller must `return 1`.
///
/// Ruling S3-R4: NOT `fatal.file`. That call routes through `fatal.msg`,
/// which panics when `builtin.mode == .Debug` -- and Debug is what `zig
/// build` produces and what every shell e2e drives, so a missing file, an
/// unreadable one (mode 000), a directory passed where a file was meant, and
/// a document over the size cap all arrived as SIGABRT/134 rather than as
/// the exit 1 the CLI contract promises. `fatal.*` is for an internal
/// Zigapagos bug, where a Debug stack trace is the point; a path the
/// operator typed that does not resolve is their input being wrong, which is
/// the same class of failure as an unusable decisions file or an
/// unparseable backend document -- both of which already print and return 1
/// a few lines below.
///
/// The message names the FLAG as well as the path: `--decisions` and
/// `--backend` fail identically at the OS level, and an operator who passed
/// both needs to know which one the kernel refused.
///
/// The full path, not the basename -- this is stderr advice, not an
/// artifact, so the determinism rule that reduces `decisions_label` to a
/// basename does not apply here.
///
/// Contract 1 (self-freeing), not contract 2: the one allocation
/// `readFileAlloc` makes escapes as the return value and there is no scratch
/// to free -- the caller frees a flat slice with `gpa.free`, not a graph with
/// a `deinit`. Contract 2 would promise a result that owns other allocations,
/// and mislabelling that way is how a `deinit` gets looked for and a leak gets
/// argued about. `error.OutOfMemory` is still `fatal.oom()`: an allocator
/// failure is not a statement about the operator's path.
fn readRailsInput(io: Io, gpa: Allocator, flag: []const u8, path: []const u8, limit: usize) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
        else => {
            std.debug.print("error: {s} {s} could not be read: {t}\n", .{ flag, path, err });
            return null;
        },
    };
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

const TargetMetadata = struct {
    title: []const u8 = "Migrated site",
    host_url: []const u8 = "https://example.com",
    url_path_prefix: ?[]const u8 = null,
};

/// NO_SLOP.md section 2.2a contract 2 (owned-result): caller frees the escaped
/// string.
fn configEscape(gpa: Allocator, value: []const u8) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    for (value) |c| switch (c) {
        '"' => w.writeAll("\\\"") catch fatal.oom(),
        '\\' => w.writeAll("\\\\") catch fatal.oom(),
        '\n' => w.writeAll("\\n") catch fatal.oom(),
        '\r' => w.writeAll("\\r") catch fatal.oom(),
        '\t' => w.writeAll("\\t") catch fatal.oom(),
        else => w.writeByte(c) catch fatal.oom(),
    };
    return aw.toOwnedSlice() catch fatal.oom();
}

fn urlOrigin(url: []const u8) ?[]const u8 {
    const authority_start = if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else
        return null;
    const tail = url[authority_start..];
    const authority_end = std.mem.indexOfAny(u8, tail, "/?#") orelse tail.len;
    if (authority_end == 0) return null;
    return url[0 .. authority_start + authority_end];
}

fn metadataFromHexoSettings(hexo: HexoSettings) TargetMetadata {
    var result: TargetMetadata = .{};
    if (hexo.title) |title| result.title = title;
    if (hexo.url) |url| if (urlOrigin(url)) |origin| {
        result.host_url = origin;
    };
    if (hexo.root) |root| {
        const prefix = std.mem.trim(u8, root, "/ \t\r");
        if (prefix.len > 0) result.url_path_prefix = prefix;
    }
    return result;
}

/// NO_SLOP.md section 2.2a contract 2 (owned-result): caller frees the emitted
/// config. All escaping scratch is self-freed.
fn emitTargetConfig(gpa: Allocator, metadata: TargetMetadata, with_assets: bool) []const u8 {
    const title = configEscape(gpa, metadata.title);
    defer gpa.free(title);
    const host = configEscape(gpa, metadata.host_url);
    defer gpa.free(host);
    const prefix_line = if (metadata.url_path_prefix) |prefix| blk: {
        const safe = configEscape(gpa, prefix);
        defer gpa.free(safe);
        break :blk std.fmt.allocPrint(gpa, "    .url_path_prefix = \"{s}\",\n", .{safe}) catch fatal.oom();
    } else gpa.dupe(u8, "") catch fatal.oom();
    defer gpa.free(prefix_line);
    return std.fmt.allocPrint(gpa,
        \\Site {{
        \\    .title = "{s}",
        \\    .host_url = "{s}",
        \\    .content_dir_path = "content",
        \\    .layouts_dir_path = "layouts",
        \\    .assets_dir_path = "assets",
        \\{s}{s}}}
        \\
    , .{ title, host, prefix_line, if (with_assets) "    .static_assets = [\"**\"],\n" else "" }) catch fatal.oom();
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
    const metadata: TargetMetadata = if (source == .hexo) blk: {
        const config = source_root.readFileAlloc(io, "_config.yml", a, .limited(1024 * 1024)) catch break :blk .{};
        break :blk metadataFromHexoSettings(parseHexoSettings(config));
    } else .{};
    writeTargetFile(io, gpa, target, "zigapagos.ziggy", emitTargetConfig(a, metadata, asset_summary.copied > 0));
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
        .rails => "rails",
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
/// stdout. Non-mutating: reads only, writes no files. Returns true when the
/// command must exit non-zero: either the input could not be read or at least
/// one guardrail violation was found.
///
/// A failure to *write* the report (EPIPE from `… | head -1`, ENOSPC, EIO)
/// aborts non-zero via `fatal`: exiting 0 after a truncated report would mean
/// "no guardrail violations found", and would hand downstream tooling
/// unparseable JSON.
fn doctor(io: Io, gpa: Allocator, path: []const u8, json: bool) bool {
    const src = readFileContent(io, gpa, Io.Dir.cwd(), path) catch |err| {
        std.debug.print("error: --doctor {s} could not be read: {t}\n", .{ path, err });
        return true;
    };
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

test "source auto-detection recognizes a Rails app via application.rb (branch A)" {
    const gpa = std.testing.allocator;
    const testing_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var config_dir = try tmp.dir.createDirPathOpen(testing_io, "config", .{});
    config_dir.close(testing_io);
    const app_rb = try tmp.dir.createFile(testing_io, "config/application.rb", .{});
    app_rb.close(testing_io);
    var views = try tmp.dir.createDirPathOpen(testing_io, "app/views", .{});
    views.close(testing_io);
    try std.testing.expectEqual(Source.rails, detectSource(testing_io, gpa, tmp.dir));
}

test "source auto-detection recognizes a Rails app via routes.rb plus a rails Gemfile (branch B)" {
    const gpa = std.testing.allocator;
    const testing_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var config_dir = try tmp.dir.createDirPathOpen(testing_io, "config", .{});
    config_dir.close(testing_io);
    const routes_rb = try tmp.dir.createFile(testing_io, "config/routes.rb", .{});
    routes_rb.close(testing_io);
    var views = try tmp.dir.createDirPathOpen(testing_io, "app/views", .{});
    views.close(testing_io);
    const gemfile = try tmp.dir.createFile(testing_io, "Gemfile", .{});
    try gemfile.writeStreamingAll(testing_io, "gem \"rails\", \"~> 7.1\"\n");
    gemfile.close(testing_io);
    try std.testing.expectEqual(Source.rails, detectSource(testing_io, gpa, tmp.dir));
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
    const with_assets = emitTargetConfig(gpa, .{}, true);
    defer gpa.free(with_assets);
    const without_assets = emitTargetConfig(gpa, .{}, false);
    defer gpa.free(without_assets);
    try std.testing.expect(std.mem.indexOf(u8, with_assets, ".static_assets = [\"**\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_assets, ".static_assets") == null);
}

test "Hexo top-level settings produce safe target metadata" {
    const settings = parseHexoSettings(
        "title: 'Next Level Developer'\nurl: https://example.com/blog\nroot: /blog/\ntheme: daily # local theme\n",
    );
    try std.testing.expectEqualStrings("Next Level Developer", settings.title.?);
    try std.testing.expectEqualStrings("https://example.com/blog", settings.url.?);
    try std.testing.expectEqualStrings("daily", settings.theme.?);
    try std.testing.expectEqualStrings("https://example.com", urlOrigin(settings.url.?).?);
    const metadata = metadataFromHexoSettings(settings);
    try std.testing.expectEqualStrings("Next Level Developer", metadata.title);
    try std.testing.expectEqualStrings("https://example.com", metadata.host_url);
    try std.testing.expectEqualStrings("blog", metadata.url_path_prefix.?);
    const config = emitTargetConfig(std.testing.allocator, metadata, true);
    defer std.testing.allocator.free(config);
    try std.testing.expect(std.mem.indexOf(u8, config, ".url_path_prefix = \"blog\"") != null);
}

test "Hexo YAML comments respect whitespace and quoted hashes" {
    const settings = parseHexoSettings(
        "theme: # intentionally unset\nroot:\t# also unset\ntitle: \"Hash # inside\" # trailing comment\nurl: https://example.com/#fragment\n",
    );
    try std.testing.expectEqual(null, settings.theme);
    try std.testing.expectEqual(null, settings.root);
    try std.testing.expectEqualStrings("Hash # inside", settings.title.?);
    try std.testing.expectEqualStrings("https://example.com/#fragment", settings.url.?);
}

test "runtime paths reject JSON-breaking characters" {
    try std.testing.expect(runtimePathIsJsonSafe("../runtime"));
    try std.testing.expect(!runtimePathIsJsonSafe("bad\"path"));
    try std.testing.expect(!runtimePathIsJsonSafe("bad\\path"));
    try std.testing.expect(!runtimePathIsJsonSafe("bad\npath"));
    try std.testing.expect(!runtimePathIsJsonSafe("bad\tpath"));
    try std.testing.expect(!runtimePathIsJsonSafe(&.{ 'b', 'a', 'd', 0x7f }));
}
