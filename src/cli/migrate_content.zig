//! Deterministic Markdown-content conversion for non-JavaScript migration
//! sources. The IO/CLI shell lives in migrate.zig; this module is pure so the
//! frontmatter and output-path contracts can be tested without filesystem IO.

const std = @import("std");
const fatal = @import("../fatal.zig");
const Allocator = std.mem.Allocator;

pub const Source = enum { hugo, jekyll, eleventy, hexo };

const Fields = struct {
    title: ?[]const u8 = null,
    date: ?[]const u8 = null,
    description: ?[]const u8 = null,
    draft: bool = false,
    raw_frontmatter: ?[]const u8 = null,
    has_unconverted: bool = false,
    body: []const u8,
};

pub const Rendered = struct {
    bytes: []const u8,
    has_unconverted_frontmatter: bool,
    invalid_date: bool,
};

fn scalar(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len >= 2 and
        ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')))
    {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn simpleScalar(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len == 0) return true;
    if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
        (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')) return true;
    return trimmed[0] != '[' and trimmed[0] != '{' and
        !std.mem.eql(u8, trimmed, "|") and !std.mem.eql(u8, trimmed, ">");
}

fn parseFields(src: []const u8) Fields {
    var result: Fields = .{ .body = src };
    const fence: []const u8 = if (std.mem.startsWith(u8, src, "---\n") or std.mem.startsWith(u8, src, "---\r\n"))
        "---"
    else if (std.mem.startsWith(u8, src, "+++\n") or std.mem.startsWith(u8, src, "+++\r\n"))
        "+++"
    else
        return result;

    const opening_end = fence.len + if (src[fence.len] == '\r') @as(usize, 2) else 1;
    var cursor = opening_end;
    var closing_start: ?usize = null;
    while (cursor <= src.len) {
        const line_end = std.mem.indexOfScalarPos(u8, src, cursor, '\n') orelse src.len;
        const line = std.mem.trimEnd(u8, src[cursor..line_end], "\r");
        if (std.mem.eql(u8, line, fence)) {
            closing_start = cursor;
            result.body = if (line_end < src.len) src[line_end + 1 ..] else "";
            break;
        }
        cursor = if (line_end < src.len) line_end + 1 else src.len + 1;
    }
    const frontmatter_end = closing_start orelse return .{ .body = src };
    result.raw_frontmatter = src[opening_end..frontmatter_end];

    var lines = std.mem.splitScalar(u8, src[opening_end..frontmatter_end], '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const equals = std.mem.indexOfScalar(u8, line, '=');
        const sep = if (colon) |c| if (equals) |e| @min(c, e) else c else equals orelse {
            result.has_unconverted = true;
            continue;
        };
        const key = std.mem.trim(u8, line[0..sep], " \t");
        const raw_value = line[sep + 1 ..];
        const value = scalar(raw_value);
        if (std.mem.eql(u8, key, "title")) {
            if (simpleScalar(raw_value)) result.title = value else result.has_unconverted = true;
        } else if (std.mem.eql(u8, key, "date")) {
            if (simpleScalar(raw_value)) result.date = value else result.has_unconverted = true;
        } else if (std.mem.eql(u8, key, "description")) {
            if (simpleScalar(raw_value)) result.description = value else result.has_unconverted = true;
        } else if (std.mem.eql(u8, key, "draft")) {
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
                result.draft = std.mem.eql(u8, value, "true");
            } else {
                result.has_unconverted = true;
            }
        } else if (std.mem.eql(u8, key, "published")) {
            if (std.mem.eql(u8, value, "false")) {
                result.draft = true;
            } else if (!std.mem.eql(u8, value, "true")) {
                result.has_unconverted = true;
            }
        } else {
            result.has_unconverted = true;
        }
    }
    return result;
}

fn fallbackTitle(source_path: []const u8) []const u8 {
    var name = std.fs.path.basename(source_path);
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[0..dot];
    if (name.len > 11 and name[4] == '-' and name[7] == '-' and name[10] == '-') name = name[11..];
    if (std.mem.eql(u8, name, "_index") or std.mem.eql(u8, name, "index")) {
        const parent = std.fs.path.dirname(source_path) orelse return "Home";
        const parent_name = std.fs.path.basename(parent);
        if (parent_name.len > 0 and !std.mem.eql(u8, parent_name, "content")) return parent_name;
        return "Home";
    }
    return name;
}

fn writeString(w: anytype, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn digits(value: []const u8) ?u32 {
    var out: u32 = 0;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
        out = out * 10 + (c - '0');
    }
    return out;
}

fn validDate(value: []const u8) bool {
    if (value.len < 10) return false;
    const separator = value[4];
    if ((separator != '-' and separator != '/') or value[7] != separator) return false;
    const year = digits(value[0..4]) orelse return false;
    const month = digits(value[5..7]) orelse return false;
    const day = digits(value[8..10]) orelse return false;
    if (month == 0 or month > 12 or day == 0) return false;
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const month_days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > month_days[month - 1]) return false;
    if (value.len >= 19 and (value[10] == 'T' or value[10] == ' ')) {
        if (value[13] != ':' or value[16] != ':') return false;
        const hour = digits(value[11..13]) orelse return false;
        const minute = digits(value[14..16]) orelse return false;
        const second = digits(value[17..19]) orelse return false;
        if (hour > 23 or minute > 59 or second > 59) return false;
    }
    return true;
}

fn writeDate(w: anytype, raw: ?[]const u8) !void {
    const value = raw orelse {
        try w.writeAll("1970-01-01T00:00:00");
        return;
    };
    if (validDate(value)) {
        try w.writeAll(value[0..4]);
        try w.writeByte('-');
        try w.writeAll(value[5..7]);
        try w.writeByte('-');
        try w.writeAll(value[8..10]);
        if (value.len >= 19 and (value[10] == 'T' or value[10] == ' ')) {
            try w.writeByte('T');
            try w.writeAll(value[11..19]);
        } else {
            try w.writeAll("T00:00:00");
        }
        return;
    }
    try w.writeAll("1970-01-01T00:00:00");
}

fn fenceMarker(line: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3 or (trimmed[0] != '`' and trimmed[0] != '~')) return null;
    if (trimmed[1] != trimmed[0] or trimmed[2] != trimmed[0]) return null;
    return trimmed[0];
}

/// NO_SLOP.md section 2.2a contract 1 (self-freeing): one normalized body
/// allocation escapes. Hexo's excerpt marker has no target rendering meaning,
/// and its common simple blockquote form has an exact Markdown equivalent.
fn normalizeHexoBody(gpa: Allocator, body: []const u8) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    var fence: ?u8 = null;
    var blockquote = false;
    while (lines.next()) |line| {
        if (!first) w.writeByte('\n') catch fatal.oom();
        first = false;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (fenceMarker(line)) |marker| {
            if (fence == null) fence = marker else if (fence.? == marker) fence = null;
            w.writeAll(line) catch fatal.oom();
            continue;
        }
        if (fence != null) {
            w.writeAll(line) catch fatal.oom();
            continue;
        }
        if (std.mem.eql(u8, trimmed, "<!-- more -->")) continue;
        if (std.mem.eql(u8, trimmed, "<blockquote>")) {
            blockquote = true;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "</blockquote>")) {
            blockquote = false;
            continue;
        }
        if (blockquote) {
            w.writeAll(">") catch fatal.oom();
            if (trimmed.len > 0) w.writeByte(' ') catch fatal.oom();
            if (std.mem.startsWith(u8, trimmed, "<footer") and std.mem.endsWith(u8, trimmed, "</footer>")) {
                const open_end = std.mem.indexOfScalar(u8, trimmed, '>') orelse 0;
                const close_start = std.mem.lastIndexOf(u8, trimmed, "</footer>") orelse trimmed.len;
                if (open_end < close_start) w.writeAll(std.mem.trim(u8, trimmed[open_end + 1 .. close_start], " \t")) catch fatal.oom();
            } else {
                w.writeAll(trimmed) catch fatal.oom();
            }
            continue;
        }
        w.writeAll(line) catch fatal.oom();
    }
    return aw.toOwnedSlice() catch fatal.oom();
}

/// Jekyll's highlight tag is a deterministic code-fence equivalent. Rewriting
/// it keeps examples (including raw HTML examples) intact while producing
/// SuperMD that does not interpret the example as page markup.
fn normalizeJekyllBody(gpa: Allocator, body: []const u8) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    var source_fence: ?u8 = null;
    var highlight = false;
    while (lines.next()) |line| {
        if (!first) w.writeByte('\n') catch fatal.oom();
        first = false;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!highlight) {
            if (fenceMarker(line)) |marker| {
                if (source_fence == null) source_fence = marker else if (source_fence.? == marker) source_fence = null;
                w.writeAll(line) catch fatal.oom();
                continue;
            }
            if (source_fence == null and std.mem.startsWith(u8, trimmed, "{% highlight ") and std.mem.endsWith(u8, trimmed, "%}")) {
                const options = std.mem.trim(u8, trimmed["{% highlight ".len .. trimmed.len - "%}".len], " \t");
                const language_end = std.mem.indexOfAny(u8, options, " \t") orelse options.len;
                w.writeAll("```") catch fatal.oom();
                w.writeAll(options[0..language_end]) catch fatal.oom();
                highlight = true;
                continue;
            }
        } else if (std.mem.eql(u8, trimmed, "{% endhighlight %}")) {
            w.writeAll("```") catch fatal.oom();
            highlight = false;
            continue;
        }
        w.writeAll(line) catch fatal.oom();
    }
    return aw.toOwnedSlice() catch fatal.oom();
}

/// NO_SLOP.md section 2.2a contract 1 (self-freeing): all scratch is borrowed;
/// the returned rendered document is the one allocation that escapes.
pub fn render(gpa: Allocator, source: Source, source_path: []const u8, src: []const u8) Rendered {
    const fields = parseFields(src);
    const invalid_date = if (fields.date) |date| !validDate(date) else false;
    const draft = fields.draft or (source == .hexo and std.mem.startsWith(u8, source_path, "source/_drafts/"));
    const normalized_body: ?[]const u8 = switch (source) {
        .hexo => normalizeHexoBody(gpa, fields.body),
        .jekyll => normalizeJekyllBody(gpa, fields.body),
        else => null,
    };
    defer if (normalized_body) |body| gpa.free(body);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    w.writeAll("---\n.title = ") catch fatal.oom();
    writeString(w, fields.title orelse fallbackTitle(source_path)) catch fatal.oom();
    w.writeAll(",\n.date = @date(\"") catch fatal.oom();
    writeDate(w, fields.date) catch fatal.oom();
    w.writeAll("\"),\n") catch fatal.oom();
    if (fields.description) |description| {
        w.writeAll(".description = ") catch fatal.oom();
        writeString(w, description) catch fatal.oom();
        w.writeAll(",\n") catch fatal.oom();
    }
    w.writeAll(".layout = \"index.shtml\",\n.draft = ") catch fatal.oom();
    w.writeAll(if (draft) "true" else "false") catch fatal.oom();
    w.writeAll(",\n.custom = { .migration_source = ") catch fatal.oom();
    writeString(w, source_path) catch fatal.oom();
    w.writeAll(", .migration_framework = ") catch fatal.oom();
    writeString(w, @tagName(source)) catch fatal.oom();
    w.writeAll(", .migration_review = true") catch fatal.oom();
    if (fields.has_unconverted) {
        w.writeAll(", .migration_frontmatter = ") catch fatal.oom();
        writeString(w, fields.raw_frontmatter.?) catch fatal.oom();
    }
    if (invalid_date) {
        w.writeAll(", .migration_invalid_date = ") catch fatal.oom();
        writeString(w, fields.date.?) catch fatal.oom();
    }
    w.writeAll(" },\n---\n\n") catch fatal.oom();
    w.writeAll(normalized_body orelse fields.body) catch fatal.oom();
    return .{
        .bytes = aw.toOwnedSlice() catch fatal.oom(),
        .has_unconverted_frontmatter = fields.has_unconverted,
        .invalid_date = invalid_date,
    };
}

fn replaceExtension(gpa: Allocator, path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    return std.fmt.allocPrint(gpa, "{s}.smd", .{path[0..dot]}) catch fatal.oom();
}

/// NO_SLOP.md section 2.2a contract 1 (self-freeing): returns one owned path
/// allocation, or null when the source is not Markdown.
pub fn outputPath(gpa: Allocator, source: Source, source_path: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, source_path, ".md") and !std.mem.endsWith(u8, source_path, ".markdown")) return null;
    var relative = source_path;
    switch (source) {
        .hugo => {
            if (std.mem.startsWith(u8, relative, "content/")) relative = relative["content/".len..];
        },
        .jekyll => {
            if (std.mem.startsWith(u8, relative, "_pages/")) relative = relative["_pages/".len..];
            if (std.mem.startsWith(u8, relative, "_posts/")) relative = relative[1..];
        },
        .eleventy => {
            if (std.mem.startsWith(u8, relative, "src/")) relative = relative["src/".len..];
            if (std.mem.startsWith(u8, relative, "content/")) relative = relative["content/".len..];
        },
        .hexo => {
            if (std.mem.startsWith(u8, relative, "source/_posts/")) relative = relative["source/_".len..];
            if (std.mem.startsWith(u8, relative, "source/_drafts/")) relative = relative["source/_".len..];
            if (std.mem.startsWith(u8, relative, "source/")) relative = relative["source/".len..];
        },
    }
    const replaced = replaceExtension(gpa, relative);
    if (std.mem.endsWith(u8, replaced, "/_index.smd")) {
        const fixed = std.fmt.allocPrint(gpa, "{s}/index.smd", .{replaced[0 .. replaced.len - "/_index.smd".len]}) catch fatal.oom();
        gpa.free(replaced);
        return fixed;
    }
    if (std.mem.eql(u8, replaced, "_index.smd")) {
        gpa.free(replaced);
        return gpa.dupe(u8, "index.smd") catch fatal.oom();
    }
    return replaced;
}

test "YAML frontmatter and Markdown body convert to Ziggy" {
    const gpa = std.testing.allocator;
    const result = render(gpa, .jekyll, "_posts/2026-08-15-hello.md",
        \\---
        \\title: "Hello world"
        \\date: 2026-08-15
        \\published: false
        \\tags: [news]
        \\---
        \\# Body
        \\
    );
    const got = result.bytes;
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, ".title = \"Hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "@date(\"2026-08-15T00:00:00\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, ".draft = true") != null);
    try std.testing.expect(result.has_unconverted_frontmatter);
    try std.testing.expect(std.mem.indexOf(u8, got, ".migration_frontmatter = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "tags: [news]") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, "# Body\n"));
}

test "TOML frontmatter and fallback title convert" {
    const gpa = std.testing.allocator;
    const result = render(gpa, .hugo, "content/guides/_index.md",
        \\+++
        \\description = 'Guide index'
        \\+++
        \\Welcome.
        \\
    );
    const got = result.bytes;
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, ".title = \"guides\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, ".description = \"Guide index\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, "Welcome.\n"));
}

test "invalid source date falls back to a valid reviewable placeholder" {
    const gpa = std.testing.allocator;
    const result = render(gpa, .hugo, "content/bad.md", "---\ndate: 2026-02-30\n---\nBody\n");
    const got = result.bytes;
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "@date(\"1970-01-01T00:00:00\")") != null);
    try std.testing.expect(result.invalid_date);
    try std.testing.expect(std.mem.indexOf(u8, got, ".migration_invalid_date = \"2026-02-30\"") != null);
}

test "Hexo slash-form date normalizes to Ziggy ISO form" {
    const gpa = std.testing.allocator;
    const result = render(gpa, .hexo, "source/_posts/hello.md", "---\ndate: 2016/08/19\n---\nBody\n");
    defer gpa.free(result.bytes);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "@date(\"2016-08-19T00:00:00\")") != null);
    try std.testing.expect(!result.invalid_date);
}

test "non-scalar recognized fields retain the complete source frontmatter" {
    const gpa = std.testing.allocator;
    const result = render(gpa, .hugo, "content/complex.md", "---\ntitle: >\n  A multiline title\ndraft: yes\n---\nBody\n");
    defer gpa.free(result.bytes);
    try std.testing.expect(result.has_unconverted_frontmatter);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "title: >\\n  A multiline title\\ndraft: yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, ".title = \"complex\"") != null);
}

test "output paths preserve reviewable source structure" {
    const gpa = std.testing.allocator;
    const hugo = outputPath(gpa, .hugo, "content/blog/_index.md").?;
    defer gpa.free(hugo);
    try std.testing.expectEqualStrings("blog/index.smd", hugo);
    const post = outputPath(gpa, .jekyll, "_posts/2026-08-15-hello.markdown").?;
    defer gpa.free(post);
    try std.testing.expectEqualStrings("posts/2026-08-15-hello.smd", post);
    const eleventy = outputPath(gpa, .eleventy, "src/writing/hello.md").?;
    defer gpa.free(eleventy);
    try std.testing.expectEqualStrings("writing/hello.smd", eleventy);
    const hexo = outputPath(gpa, .hexo, "source/_posts/hello.md").?;
    defer gpa.free(hexo);
    try std.testing.expectEqualStrings("posts/hello.smd", hexo);
    try std.testing.expectEqual(null, outputPath(gpa, .hugo, "layouts/index.html"));
}

test "Hexo drafts are marked draft from their source directory" {
    const gpa = std.testing.allocator;
    const result = render(gpa, .hexo, "source/_drafts/idea.md", "---\ntitle: Idea\n---\nBody\n");
    defer gpa.free(result.bytes);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, ".draft = true") != null);
}

test "Hexo excerpt markers and simple blockquotes normalize outside code fences" {
    const gpa = std.testing.allocator;
    const result = render(gpa, .hexo, "source/_posts/post.md", "---\ntitle: Post\n---\nIntro\n<!-- more -->\n<blockquote>\n  Quoted\n  <footer>--Author</footer>\n</blockquote>\n```html\n<!-- more -->\n```\n");
    defer gpa.free(result.bytes);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "\n<!-- more -->\n<blockquote>") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "> Quoted\n> --Author") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "```html\n<!-- more -->\n```") != null);
}

test "Jekyll highlight tags become fenced code blocks" {
    const gpa = std.testing.allocator;
    const result = render(gpa, .jekyll, "_posts/example.md", "{% highlight html linenos %}\n<html>\n{% endhighlight %}\n");
    defer gpa.free(result.bytes);
    try std.testing.expect(std.mem.endsWith(u8, result.bytes, "```html\n<html>\n```\n"));
}
