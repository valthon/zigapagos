//! Read-only, raw-byte inventory of emitted HTML/CSS/JS and HTML references.
//! Inventory totals include unused and lazy files, but never external resources.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fatal = @import("../fatal.zig");
const diag = @import("../diag.zig");
const superhtml = @import("superhtml");
const html = @import("output_html.zig");
const page_output = @import("output_page.zig");
const attribute = html.attribute;
const urlScope = html.urlScope;
const scriptIsJavaScript = html.scriptIsJavaScript;

const Kind = enum { html, css, js };
const Totals = struct { html: u64 = 0, css: u64 = 0, js: u64 = 0 };
const Budgets = struct { html: ?u64 = null, css: ?u64 = null, js: ?u64 = null };
const Command = struct {
    dir: []const u8 = "public",
    format: diag.Format = .text,
    budgets: Budgets = .{},
    page: ?[]const u8 = null,
    page_options: page_output.Options = .{},

    // Borrowed argv fields; no allocation.
    fn parse(args: []const []const u8) Command {
        var cmd: Command = .{};
        var have_dir = false;
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) fatal.usage(help, .{});
            if (std.mem.startsWith(u8, arg, "--format=")) {
                cmd.format = diag.parseFormat(arg[9..]) orelse fatal.usageError("error: expected --format=text|json\n", .{});
            } else if (std.mem.startsWith(u8, arg, "--page=")) {
                const path = arg["--page=".len..];
                if (!page_output.validPagePath(path)) fatal.usageError("error: --page needs an emitted HTML path relative to DIR, e.g. docs/index.html\n", .{});
                cmd.page = path;
            } else if (std.mem.startsWith(u8, arg, "--url-prefix=")) {
                const prefix = std.mem.trim(u8, arg["--url-prefix=".len..], "/");
                if (!page_output.validPrefix(prefix)) fatal.usageError("error: --url-prefix needs a plain URL path, e.g. project/docs\n", .{});
                cmd.page_options.url_prefix = prefix;
            } else if (std.mem.startsWith(u8, arg, "--max-page-js-bytes=")) {
                cmd.page_options.max_js_bytes = parseBudget(arg["--max-page-js-bytes=".len..]);
            } else if (std.mem.startsWith(u8, arg, "--max-page-css-bytes=")) {
                cmd.page_options.max_css_bytes = parseBudget(arg["--max-page-css-bytes=".len..]);
            } else if (std.mem.startsWith(u8, arg, "--max-html-bytes=")) {
                cmd.budgets.html = parseBudget(arg[17..]);
            } else if (std.mem.startsWith(u8, arg, "--max-css-bytes=")) {
                cmd.budgets.css = parseBudget(arg[16..]);
            } else if (std.mem.startsWith(u8, arg, "--max-js-bytes=")) {
                cmd.budgets.js = parseBudget(arg[15..]);
            } else if (std.mem.startsWith(u8, arg, "-")) {
                fatal.usageError("error: unknown inspect-output option '{s}'\n", .{arg});
            } else {
                if (have_dir) fatal.usageError("error: inspect-output accepts one output directory\n", .{});
                have_dir = true;
                cmd.dir = arg;
            }
        }
        if (cmd.page == null and (cmd.page_options.max_js_bytes != null or cmd.page_options.max_css_bytes != null or cmd.page_options.url_prefix.len > 0))
            fatal.usageError("error: page budgets and --url-prefix require --page=EMITTED_PATH\n", .{});
        return cmd;
    }
};

fn parseBudget(value: []const u8) u64 {
    if (value.len == 0) fatal.usageError("error: byte budgets require a nonnegative decimal integer\n", .{});
    for (value) |c| if (!std.ascii.isDigit(c)) fatal.usageError("error: byte budgets require a nonnegative decimal integer\n", .{});
    return std.fmt.parseInt(u64, value, 10) catch fatal.usageError("error: byte budget is too large\n", .{});
}

const help =
    \\Usage: zigapagos inspect-output [DIR] [OPTIONS]
    \\
    \\Inventory a built output tree (default public), read-only.
    \\Report raw file bytes, not compressed transfer or per-route loading cost.
    \\Default references are literal; --page also resolves direct local JS/CSS files.
    \\
    \\  --format=text|json   Human report (default) or NDJSON on stdout
    \\  --max-html-bytes=N   Fail if aggregate emitted HTML bytes exceed N
    \\  --max-css-bytes=N    Fail if aggregate emitted CSS bytes exceed N
    \\  --max-js-bytes=N     Fail if aggregate emitted JS bytes exceed N
    \\  --page=PATH         Also measure direct resources of one emitted HTML file
    \\  --url-prefix=P      Deployment prefix for that page (e.g. project)
    \\  --max-page-js-bytes=N   Bound direct local JS + inline script-body bytes
    \\  --max-page-css-bytes=N  Bound direct local CSS + inline style-body bytes
    \\                     Page budgets require --page and complete direct coverage
    \\  --help, -h          Show this help
    \\
    \\Aggregate budgets include all inventoried files, even lazy/unreferenced files.
    \\Page budgets include direct local resources and executable inline bodies.
    \\External resources and import graphs are not measured; aggregate inline bytes
    \\remain part of HTML.
    \\Use doctor separately to check local links; no host or browser is exercised.
    \\
;

pub fn inspectOutput(io: Io, gpa: Allocator, args: []const []const u8) bool {
    const cmd = Command.parse(args);
    diag.format = cmd.format;
    return run(io, gpa, cmd) catch |err| fatal.usageError("error: inspect-output could not complete '{s}': {t}\n", .{ cmd.dir, err });
}

const File = struct { path: []const u8, kind: Kind };

/// Self-freeing: paths, HTML source, and AST storage are reclaimed before return.
fn run(io: Io, gpa: Allocator, cmd: Command) !bool {
    var root = try Io.Dir.cwd().openDir(io, cmd.dir, .{ .iterate = true });
    defer root.close(io);
    var files: std.ArrayList(File) = .empty;
    defer {
        for (files.items) |file| gpa.free(file.path);
        files.deinit(gpa);
    }
    {
        var walker = try root.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            // Never follow links, including symlinked directories. Refuse an
            // incomplete inventory rather than treating unknown bytes as zero.
            if (entry.kind == .sym_link) return error.SymlinkInOutput;
            if (entry.kind != .file) continue;
            const kind = fileKind(entry.path) orelse continue;
            const path = try gpa.dupe(u8, entry.path);
            errdefer gpa.free(path);
            // Canonical report paths use URL separators on every host.
            for (path) |*c| if (std.fs.path.sep == '\\' and c.* == '\\') {
                c.* = '/';
            };
            try files.append(gpa, .{ .path = path, .kind = kind });
        }
    }
    std.mem.sortUnstable(File, files.items, {}, struct {
        fn less(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    var html_files: usize = 0;
    for (files.items) |file| if (file.kind == .html) {
        html_files += 1;
    };
    if (html_files == 0) return error.NoHtmlFiles;

    if (cmd.page) |selected| {
        var found = false;
        for (files.items) |file| if (file.kind == .html and std.mem.eql(u8, selected, file.path)) {
            found = true;
        };
        if (!found) fatal.usageError("error: --page '{s}' is not an emitted HTML file under '{s}'\n", .{ selected, cmd.dir });
    }
    var page_budgets_failed: usize = 0;
    var buffer: [8192]u8 = undefined;
    var output = Io.File.stdout().writerStreaming(io, &buffer);
    const w = &output.interface;
    var totals: Totals = .{};
    var reference_count: usize = 0;
    var partial_reference_pages: usize = 0;
    if (cmd.format == .text) try w.writeAll("Raw output bytes (not transfer bytes). All emitted HTML/CSS/JS, including lazy and unused files.\nReferences are literal HTML attributes; external resources and import graphs are not measured.\n");
    for (files.items) |file| {
        const st = try root.statFile(io, file.path, .{ .follow_symlinks = false });
        if (st.kind != .file) return error.OutputChangedDuringInspection;
        switch (file.kind) {
            inline else => |kind| @field(totals, @tagName(kind)) = try std.math.add(u64, @field(totals, @tagName(kind)), st.size),
        }
        if (cmd.format == .json) {
            try emit(w, .{ .type = "asset", .kind = @tagName(file.kind), .path = file.path, .raw_bytes = st.size });
        } else try w.print("{s} {s}: {d} raw bytes\n", .{ @tagName(file.kind), file.path, st.size });
        if (file.kind != .html) continue;
        const source = try root.readFileAlloc(io, file.path, gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(source);
        var ast = try superhtml.html.Ast.init(gpa, source, .html, true);
        defer ast.deinit(gpa);
        const page = try reportPage(w, cmd.format, file.path, source, ast);
        if (page.partial) partial_reference_pages += 1;
        reference_count += page.references;
        if (cmd.page) |selected| {
            if (std.mem.eql(u8, selected, file.path)) page_budgets_failed += try page_output.report(io, gpa, root, w, cmd.format, file.path, source, ast, !page.partial, cmd.page_options);
        }
    }
    var exceeded: usize = 0;
    inline for (std.meta.fields(Budgets)) |field| {
        if (@field(cmd.budgets, field.name)) |limit| {
            const actual = @field(totals, field.name);
            const passed = actual <= limit;
            if (!passed) exceeded += 1;
            if (cmd.format == .json) {
                try emit(w, .{ .type = "budget", .kind = field.name, .raw_bytes = actual, .max_bytes = limit, .passed = passed });
            } else try w.print("budget {s}: {d}/{d} raw bytes — {s}\n", .{ field.name, actual, limit, if (passed) "pass" else "exceeded" });
        }
    }
    if (cmd.format == .json) {
        try emit(w, .{
            .type = "summary",
            .raw_bytes = totals,
            .files = files.items.len,
            .pages = html_files,
            .references = reference_count,
            .pages_with_partial_references = partial_reference_pages,
            .budgets_exceeded = exceeded,
            .page_budgets_failed = page_budgets_failed,
            .measurement = "raw_file_bytes",
            .scope = "all_emitted_html_css_js",
            .external_resources_measured = false,
            .import_graph_measured = false,
            .references_resolved = false,
            .inline_script_bytes_in = "html",
        });
    } else try w.print("inspect-output: {d} files, {d} pages; HTML {d}, CSS {d}, JS {d} raw bytes; {d} budgets exceeded\n", .{ files.items.len, html_files, totals.html, totals.css, totals.js, exceeded });
    if (cmd.format == .text and partial_reference_pages > 0) try w.print("Reference coverage is partial for {d} pages with HTML parser errors or unsupported attribute encodings; raw file inventory remains complete.\n", .{partial_reference_pages});
    try w.flush();
    return exceeded != 0 or page_budgets_failed != 0;
}

fn fileKind(path: []const u8) ?Kind {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm")) return .html;
    if (std.ascii.eqlIgnoreCase(ext, ".css")) return .css;
    for ([_][]const u8{ ".js", ".mjs", ".cjs" }) |js| if (std.ascii.eqlIgnoreCase(ext, js)) return .js;
    return null;
}

fn emit(w: *Io.Writer, value: anytype) Io.Writer.Error!void {
    try std.json.Stringify.value(value, .{}, w);
    try w.writeByte('\n');
}

const PageCoverage = struct { references: usize, partial: bool };

fn reportPage(w: *Io.Writer, format: diag.Format, path: []const u8, source: []const u8, ast: superhtml.html.Ast) Io.Writer.Error!PageCoverage {
    var refs: usize = 0;
    var inline_js: usize = 0;
    var inline_other: usize = 0;
    var inline_unknown: usize = 0;
    var encoded_classification: usize = 0;
    var has_base = false;
    for (ast.nodes) |node| {
        if (!node.kind.isElement()) continue;
        if (node.kind == .base and attribute(node, source, ast, "href") != null) has_base = true;
        if (node.kind == .script) {
            const type_attr = attribute(node, source, ast, "type");
            const script_type = type_attr orelse "";
            const language = if (type_attr == null) attribute(node, source, ast, "language") orelse "" else "";
            const executable: ?bool = if (std.mem.indexOfScalar(u8, script_type, '&') != null or std.mem.indexOfScalar(u8, language, '&') != null) null else scriptIsJavaScript(script_type, language);
            if (executable == null) encoded_classification += 1;
            if (attribute(node, source, ast, "src")) |url| {
                try reportReference(w, format, path, "script_src", url, script_type);
                refs += 1;
            } else {
                if (executable) |is_js| {
                    if (is_js) inline_js += 1 else inline_other += 1;
                } else inline_unknown += 1;
                if (format == .json) try emit(w, .{ .type = "inline_script", .page = path, .script_type = script_type, .language = language, .javascript = executable });
            }
        }
        if (attribute(node, source, ast, "data-z-module")) |url| {
            try reportReference(w, format, path, "island_module", url, "module");
            refs += 1;
        }
        if (node.kind == .link) {
            const rel = attribute(node, source, ast, "rel") orelse continue;
            if (std.mem.indexOfScalar(u8, rel, '&') != null) {
                encoded_classification += 1;
                if (attribute(node, source, ast, "href")) |url| {
                    try reportReference(w, format, path, "link_href_unclassified", url, "");
                    refs += 1;
                }
                continue;
            }
            var tokens = std.mem.tokenizeAny(u8, rel, " \t\r\n\x0c");
            while (tokens.next()) |token| {
                if (!std.ascii.eqlIgnoreCase(token, "modulepreload")) continue;
                if (attribute(node, source, ast, "href")) |url| {
                    try reportReference(w, format, path, "modulepreload", url, "module");
                    refs += 1;
                }
                break;
            }
        }
    }
    const partial = ast.has_syntax_errors or encoded_classification != 0;
    if (format == .json) {
        try emit(w, .{
            .type = "page",
            .path = path,
            .references = refs,
            .inline_javascript_elements = inline_js,
            .inline_other_script_elements = inline_other,
            .inline_unclassified_script_elements = inline_unknown,
            .encoded_classification_elements = encoded_classification,
            .has_base_href = has_base,
            .reference_coverage = if (partial) @as([]const u8, "partial") else "parsed",
            .html_parser_first_error = if (ast.has_syntax_errors and ast.errors.len > 0) @as(?[]const u8, @tagName(ast.errors[0].tag)) else null,
            .html_parser_first_error_byte = if (ast.has_syntax_errors and ast.errors.len > 0) @as(?u32, ast.errors[0].main_location.start) else null,
        });
    } else try w.print("page {s}: {d} references, {d} inline JavaScript elements, {d} data/other script elements{s}\n", .{ path, refs, inline_js, inline_other, if (has_base) "; base href present (references unresolved)" else "" });
    if (format == .text and ast.has_syntax_errors) try w.writeAll("  HTML parser errors: references are best-effort and may be incomplete.\n");
    if (format == .text and encoded_classification > 0) try w.print("  {d} elements use encoded type/language/rel attributes; {d} inline scripts unclassified. Reference coverage is partial.\n", .{ encoded_classification, inline_unknown });
    return .{ .references = refs, .partial = partial };
}

fn reportReference(w: *Io.Writer, format: diag.Format, page: []const u8, kind: []const u8, url: []const u8, script_type: []const u8) Io.Writer.Error!void {
    if (format == .json) {
        try emit(w, .{ .type = "reference", .page = page, .kind = kind, .url = url, .script_type = script_type, .resolution = "not_resolved", .url_scope = urlScope(url) });
    } else try w.print("  {s}: {s} ({s}, not resolved)\n", .{ kind, url, urlScope(url) });
}

test "assets: inspect-output inventory file kinds and script classification" {
    try std.testing.expectEqual(Kind.js, fileKind("chunks/lazy.MJS").?);
    try std.testing.expectEqual(Kind.html, fileKind("index.HTML").?);
    try std.testing.expectEqual(@as(?Kind, null), fileKind("app.js.map"));
    try std.testing.expect(scriptIsJavaScript("module", ""));
    try std.testing.expect(scriptIsJavaScript("text/javascript", ""));
    try std.testing.expect(scriptIsJavaScript("", ""));
    try std.testing.expect(!scriptIsJavaScript("application/json", ""));
    try std.testing.expect(!scriptIsJavaScript("importmap", ""));
    try std.testing.expect(!scriptIsJavaScript("", "vbscript"));
}

test "assets: inspect-output parses zero and exact byte budgets" {
    const cmd = Command.parse(&.{ "dist", "--format=json", "--max-js-bytes=0", "--max-css-bytes=1024" });
    try std.testing.expectEqualStrings("dist", cmd.dir);
    try std.testing.expectEqual(@as(u64, 0), cmd.budgets.js.?);
    try std.testing.expectEqual(@as(u64, 1024), cmd.budgets.css.?);
    try std.testing.expectEqual(@as(?u64, null), cmd.budgets.html);
}

test "assets: inspect-output URL scopes and legacy script types" {
    try std.testing.expectEqualStrings("nonlocal_url", urlScope("https://cdn.example/app.js"));
    try std.testing.expectEqualStrings("nonlocal_url", urlScope("//cdn.example/app.js"));
    try std.testing.expectEqualStrings("local_url", urlScope("2026:app.js"));
    try std.testing.expectEqualStrings("unclassified", urlScope("a&amp;b.js"));
    try std.testing.expect(scriptIsJavaScript("", "javascript1.2"));
    try std.testing.expect(!scriptIsJavaScript("application/ld+json", "javascript"));
}
