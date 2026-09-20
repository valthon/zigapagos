//! Direct resource accounting, not an import graph or browser transfer estimate.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const superhtml = @import("superhtml");
const diag = @import("../diag.zig");
const html = @import("output_html.zig");
const paths = @import("doctor.zig");

pub const Options = struct {
    url_prefix: []const u8 = "",
    max_js_bytes: ?u64 = null,
    max_css_bytes: ?u64 = null,
};
const Kind = enum { js, css };
const Bytes = struct { js: u64 = 0, css: u64 = 0 };
const Counts = struct { js: usize = 0, css: usize = 0 };
const State = struct {
    local: Bytes = .{},
    inline_bytes: Bytes = .{},
    files: Counts = .{},
    unresolved: usize = 0,
    complete: bool,
    // Owned keys, one bit per resource kind. The same physical file counts
    // once per role, even when several URL spellings or elements name it.
    seen: std.StringHashMapUnmanaged(u8) = .empty,
};

pub fn validPagePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\?#") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn validPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (!validPagePath(prefix)) return false;
    for (prefix) |c| if (c <= ' ' or c == '%' or c == '&' or c == ':' or c == 127) return false;
    return true;
}

/// Self-freeing: all deduplication keys and map storage are released here.
/// Only direct references are resolved; bytes from unknown resources stay
/// unknown, and any requested page budget fails if coverage is incomplete.
pub fn report(io: Io, gpa: Allocator, root: Io.Dir, w: *Io.Writer, format: diag.Format, page: []const u8, source: []const u8, ast: superhtml.html.Ast, parsed: bool, options: Options) !usize {
    var state: State = .{ .complete = parsed };
    defer {
        var keys = state.seen.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        state.seen.deinit(gpa);
    }
    var has_base = false;
    for (ast.nodes) |node| {
        if (node.kind == .base and html.attribute(node, source, ast, "href") != null) has_base = true;
    }
    if (has_base) state.complete = false;
    if (!parsed or has_base) {
        try emitCoverage(w, format, page, if (has_base) "base_href_unsupported" else "partial_html_reference_coverage");
    }
    for (ast.nodes) |node| {
        if (!node.kind.isElement()) continue;
        if (node.kind == .script) {
            const type_attr = html.attribute(node, source, ast, "type");
            const script_type = type_attr orelse "";
            const language = if (type_attr == null) html.attribute(node, source, ast, "language") orelse "" else "";
            if (std.mem.indexOfScalar(u8, script_type, '&') != null or std.mem.indexOfScalar(u8, language, '&') != null) {
                state.complete = false;
                try emitCoverage(w, format, page, "encoded_script_type_unsupported");
            } else if (html.scriptIsJavaScript(script_type, language)) {
                if (html.attribute(node, source, ast, "src")) |url| {
                    try resource(io, gpa, root, w, format, page, url, "script_src", .js, has_base, options.url_prefix, &state);
                } else try addInline(node, .js, &state);
            }
        }
        if (node.kind == .style) {
            const style_type = html.attribute(node, source, ast, "type") orelse "";
            if (std.mem.indexOfScalar(u8, style_type, '&') != null) {
                state.complete = false;
                try emitCoverage(w, format, page, "encoded_style_type_unsupported");
            } else if (style_type.len == 0 or std.ascii.eqlIgnoreCase(std.mem.trim(u8, style_type, " \t\r\n\x0c"), "text/css")) try addInline(node, .css, &state);
        }
        if (html.attribute(node, source, ast, "data-z-module")) |url| {
            try resource(io, gpa, root, w, format, page, url, "island_module", .js, has_base, options.url_prefix, &state);
        }
        if (node.kind == .link) {
            const rel = html.attribute(node, source, ast, "rel") orelse continue;
            if (std.mem.indexOfScalar(u8, rel, '&') != null) {
                state.complete = false;
                try emitCoverage(w, format, page, "encoded_link_rel_unsupported");
                continue;
            }
            const url = html.attribute(node, source, ast, "href") orelse continue;
            var tokens = std.mem.tokenizeAny(u8, rel, " \t\r\n\x0c");
            var stylesheet = false;
            var modulepreload = false;
            while (tokens.next()) |token| {
                if (std.ascii.eqlIgnoreCase(token, "stylesheet")) stylesheet = true;
                if (std.ascii.eqlIgnoreCase(token, "modulepreload")) modulepreload = true;
            }
            if (stylesheet) try resource(io, gpa, root, w, format, page, url, "stylesheet", .css, has_base, options.url_prefix, &state);
            if (modulepreload) try resource(io, gpa, root, w, format, page, url, "modulepreload", .js, has_base, options.url_prefix, &state);
        }
    }
    const total: Bytes = .{
        .js = try std.math.add(u64, state.local.js, state.inline_bytes.js),
        .css = try std.math.add(u64, state.local.css, state.inline_bytes.css),
    };
    if (format == .json) {
        try emit(w, .{
            .type = "page_resources",
            .page = page,
            .metric = "direct_reference_raw_bytes",
            .raw_bytes = total,
            .local_file_bytes = state.local,
            .inline_body_bytes = state.inline_bytes,
            .unique_local_files = state.files,
            .unresolved_references = state.unresolved,
            .coverage_complete = state.complete,
            .has_base_href = has_base,
            .import_graph_measured = false,
            .transfer_bytes_measured = false,
        });
    } else try w.print("page resources {s}: JS {d}, CSS {d} direct raw bytes (inline bodies: JS {d}, CSS {d}); {s}\n", .{ page, total.js, total.css, state.inline_bytes.js, state.inline_bytes.css, if (state.complete) "direct coverage complete; import graphs and transfer bytes unmeasured" else "incomplete coverage: known bytes are a lower bound" });
    var failed: usize = 0;
    inline for (.{ Kind.js, Kind.css }) |kind| {
        const limit = if (kind == .js) options.max_js_bytes else options.max_css_bytes;
        if (limit) |max_bytes| {
            const bytes = @field(total, @tagName(kind));
            const passed = state.complete and bytes <= max_bytes;
            if (!passed) failed += 1;
            if (format == .json) {
                try emit(w, .{ .type = "page_budget", .page = page, .kind = @tagName(kind), .metric = "direct_reference_raw_bytes", .raw_bytes = bytes, .max_bytes = max_bytes, .coverage_complete = state.complete, .passed = passed });
            } else try w.print("page budget {s}: {d}/{d} bytes — {s}\n", .{ @tagName(kind), bytes, max_bytes, if (!state.complete) "failed: incomplete direct-reference coverage" else if (passed) "pass" else "exceeded" });
        }
    }
    return failed;
}

fn addInline(node: superhtml.html.Ast.Node, kind: Kind, state: *State) !void {
    if (node.close.start < node.open.end) {
        state.complete = false;
        return;
    }
    const bytes: u64 = node.close.start - node.open.end;
    switch (kind) {
        inline else => |k| @field(state.inline_bytes, @tagName(k)) = try std.math.add(u64, @field(state.inline_bytes, @tagName(k)), bytes),
    }
}

fn resource(io: Io, gpa: Allocator, root: Io.Dir, w: *Io.Writer, format: diag.Format, page: []const u8, url: []const u8, reference_kind: []const u8, kind: Kind, has_base: bool, prefix: []const u8, state: *State) !void {
    if (has_base) {
        state.unresolved += 1;
        try emitResource(w, format, page, reference_kind, url, null, null, "base_href_unsupported");
        return;
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const normalized = resolve(&buf, page, prefix, url) catch |err| {
        state.complete = false;
        state.unresolved += 1;
        try emitResource(w, format, page, reference_kind, url, null, null, @errorName(err));
        return;
    };
    // No symlink component may resolve outside the supplied tree. The inventory
    // rejects symlinks too; this protects lookups of paths omitted from inventory.
    const size = regularFileSize(io, root, normalized) catch |err| {
        state.complete = false;
        state.unresolved += 1;
        try emitResource(w, format, page, reference_kind, url, normalized, null, @errorName(err));
        return;
    };
    const bit: u8 = if (kind == .js) 1 else 2;
    var counted = true;
    if (state.seen.getPtr(normalized)) |flags| {
        counted = flags.* & bit == 0;
        flags.* |= bit;
    } else {
        const owned = try gpa.dupe(u8, normalized);
        errdefer gpa.free(owned);
        try state.seen.put(gpa, owned, bit);
    }
    if (counted) switch (kind) {
        inline else => |k| {
            @field(state.local, @tagName(k)) = try std.math.add(u64, @field(state.local, @tagName(k)), size);
            @field(state.files, @tagName(k)) += 1;
        },
    };
    try emitResource(w, format, page, reference_kind, url, normalized, size, if (counted) "measured" else "duplicate");
}

fn regularFileSize(io: Io, root: Io.Dir, path: []const u8) !u64 {
    for (path, 0..) |c, i| {
        if (c != '/' or i == 0) continue;
        const st = try root.statFile(io, path[0..i], .{ .follow_symlinks = false });
        if (st.kind != .directory) return error.UnsupportedPathComponent;
    }
    const st = try root.statFile(io, path, .{ .follow_symlinks = false });
    if (st.kind != .file) return error.NotARegularFile;
    return st.size;
}

const ResolveError = error{ EmptyUrl, NonlocalUrl, UnsupportedUrlEncoding, OutsideDeployment, MalformedEscape, TooLong, EscapesRoot };

/// Caller-buffer contract. Resolve in host URL space before removing the
/// deployment prefix; never pass unchecked parent segments to the filesystem.
fn resolve(buf: []u8, page: []const u8, prefix: []const u8, raw: []const u8) ResolveError![]const u8 {
    const url = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (url.len == 0) return error.EmptyUrl;
    var path = url;
    if (std.mem.indexOfAny(u8, path, "?#")) |i| path = path[0..i];
    if (path.len > 0 and !paths.isLocalLink(path)) return error.NonlocalUrl;
    if (std.mem.indexOfAny(u8, path, "\\&") != null) return error.UnsupportedUrlEncoding;
    var decoded_buf: [std.fs.max_path_bytes]u8 = undefined;
    const decoded = try paths.percentDecode(&decoded_buf, path);
    for (decoded) |c| if (c < ' ' or c == '\\' or c == 127) return error.UnsupportedUrlEncoding;
    if (std.mem.count(u8, decoded, "/") != std.mem.count(u8, path, "/")) return error.UnsupportedUrlEncoding;
    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const normalized = if (path.len == 0)
        try paths.localUrlPath(&normalized_buf, "index.html", prefix, page)
    else
        try paths.localUrlPath(&normalized_buf, page, prefix, decoded);
    var local = normalized;
    if (prefix.len > 0) {
        if (!std.mem.startsWith(u8, normalized, prefix) or normalized.len <= prefix.len or normalized[prefix.len] != '/') return error.OutsideDeployment;
        local = normalized[prefix.len + 1 ..];
    }
    if (local.len > buf.len) return error.TooLong;
    @memcpy(buf[0..local.len], local);
    return buf[0..local.len];
}

fn emit(w: *Io.Writer, value: anytype) Io.Writer.Error!void {
    try std.json.Stringify.value(value, .{}, w);
    try w.writeByte('\n');
}

fn emitCoverage(w: *Io.Writer, format: diag.Format, page: []const u8, reason: []const u8) Io.Writer.Error!void {
    if (format == .json) try emit(w, .{ .type = "page_coverage", .page = page, .reason = reason }) else try w.print("page {s}: incomplete direct coverage ({s})\n", .{ page, reason });
}

fn emitResource(w: *Io.Writer, format: diag.Format, page: []const u8, kind: []const u8, url: []const u8, path: ?[]const u8, bytes: ?u64, status: []const u8) Io.Writer.Error!void {
    if (format == .json) {
        try emit(w, .{ .type = "page_resource", .page = page, .kind = kind, .url = url, .path = path, .raw_bytes = bytes, .status = status });
    } else if (bytes) |n| {
        try w.print("  {s} {s}: {d} bytes ({s}, {s})\n", .{ kind, url, n, status, path.? });
    } else try w.print("  {s} {s}: unknown bytes ({s})\n", .{ kind, url, status });
}

test "assets: page resources normalize URL aliases and deployment paths" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("app.js", try resolve(&buf, "docs/index.html", "project", "../app.js?q=1&amp;v=2#x"));
    try std.testing.expectEqualStrings("app.js", try resolve(&buf, "docs/index.html", "project", "/project/assets/../app.js"));
    try std.testing.expectEqualStrings("my app.js", try resolve(&buf, "index.html", "", "my%20app.js"));
    try std.testing.expectEqualStrings("docs/index.html", try resolve(&buf, "docs/index.html", "project", "?v=1"));
    try std.testing.expectError(error.OutsideDeployment, resolve(&buf, "docs/index.html", "project", "../../app.js"));
    try std.testing.expectError(error.EscapesRoot, resolve(&buf, "index.html", "", "../app.js"));
    try std.testing.expectError(error.NonlocalUrl, resolve(&buf, "index.html", "", "https://cdn/app.js"));
    try std.testing.expectError(error.UnsupportedUrlEncoding, resolve(&buf, "index.html", "", "%2fapp.js"));
    try std.testing.expectError(error.UnsupportedUrlEncoding, resolve(&buf, "index.html", "", "a&amp;b.js"));
}
