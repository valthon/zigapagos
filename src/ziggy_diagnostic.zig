//! Shared Ziggy error reporting, including the site's upgrade instructions.
const std = @import("std");
const ziggy = @import("ziggy");

path: ?[]const u8 = null,
meta: ziggy.Deserializer.Meta = .init,
opts: ziggy.Deserializer.Options = .{},
err: ?ziggy.Deserializer.Error = null,
/// Caller-buffer constructor. The formatter borrows the reporting allocator;
/// parsing arenas may have moved since this diagnostic was recorded.
pub fn fmt(d: @This(), allocator: std.mem.Allocator, src: [:0]const u8) Fmt {
    return .{ .diag = d, .src = src, .allocator = allocator };
}

pub const Fmt = struct {
    diag: @import("ziggy_diagnostic.zig"),
    src: [:0]const u8,
    allocator: std.mem.Allocator,

    pub fn format(f: Fmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const d = f.diag;
        const src = if (d.opts.delimiter == .none) f.src else f.src[0..(std.mem.findPos(u8, f.src, @min(3, f.src.len), "\n---") orelse f.src.len)];
        if (std.mem.findScalar(u8, src, '\r') != null) {
            try w.print("{s}: error: Ziggy 0.3.0 rejects carriage returns; run `python3 scripts/upgrade-ziggy.py .` to convert config and frontmatter to LF\n", .{d.path orelse "<stdin>"});
            return;
        }
        if (oldSyntax(d, f.src)) {
            try w.print("{s}: error: old Ziggy syntax; run `python3 scripts/upgrade-ziggy.py .`, then `zigapagos install-schemas` (see docs/migration/ziggy-0.3.md)\n", .{d.path orelse "<stdin>"});
            return;
        }
        try w.print("{f}", .{d.meta.reportErrorsFmt(f.allocator, d.opts, d.path, f.src, d.err.?)});
    }
};

fn oldSyntax(d: @import("ziggy_diagnostic.zig"), src: [:0]const u8) bool {
    if (d.err.? == error.UnknownField and std.mem.eql(u8, d.meta.error_loc.slice(src), ".author")) return true;
    // Use the tokenizer so old spellings inside strings/comments do not turn
    // an unrelated syntax error into misleading upgrade advice.
    var tokenizer = ziggy.Tokenizer.init(d.opts.delimiter);
    var bare_brace = false;
    var depth: usize = 0;
    var top_depth: usize = 0;
    var first = true;
    var date_field = false;
    var date_equals = false;
    while (true) {
        const token = tokenizer.next(src, true);
        if (token.tag == .eof or token.tag == .eod) return false;
        if (first) {
            top_depth = if (token.tag == .dotlb) 1 else 0;
            first = false;
        }
        if (d.opts.delimiter != .none) {
            if (date_equals and (token.tag == .bytes_no_escapes or token.tag == .bytes_escapes_or_invalid or token.tag == .bytes_line)) return true;
            date_equals = date_field and token.tag == .eql;
            date_field = depth == top_depth and token.tag == .identifier and std.mem.eql(u8, token.loc.slice(src), ".date");
        }
        switch (token.tag) {
            .lb, .dotlb, .lsb => depth += 1,
            .rb, .rsb => depth -|= 1,
            else => {},
        }
        if (bare_brace and token.tag == .identifier) return true;
        bare_brace = token.tag == .lb;
        if (token.tag != .invalid) continue;
        const rest = src[token.loc.start..];
        inline for (.{ "Site", "Multilingual" }) |name| {
            if (std.mem.startsWith(u8, rest, name) and
                std.mem.startsWith(u8, std.mem.trimStart(u8, rest[name.len..], " \t\n"), "{")) return true;
        }
        if (std.mem.startsWith(u8, rest, "@date") and
            std.mem.startsWith(u8, std.mem.trimStart(u8, rest[5..], " \t\n"), "(")) return true;
    }
}
