//! Shared raw HTML attribute inspection; no allocations or entity decoding.
const std = @import("std");
const superhtml = @import("superhtml");

pub fn attribute(node: superhtml.html.Ast.Node, source: []const u8, ast: superhtml.html.Ast, name: []const u8) ?[]const u8 {
    var it = node.startTagIterator(source, ast.language);
    while (it.next(source)) |attr| {
        if (!std.ascii.eqlIgnoreCase(attr.name.slice(source), name)) continue;
        return if (attr.value) |value| value.span.slice(source) else "";
    }
    return null;
}

// Classification only: a base href may change the origin of a local-looking URL.
pub fn urlScope(raw: []const u8) []const u8 {
    const url = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (std.mem.indexOfAny(u8, url, "\\&\t\r\n") != null) return "unclassified";
    if (std.mem.startsWith(u8, url, "//")) return "nonlocal_url";
    if (url.len == 0) return "local_url";
    if (std.ascii.isAlphabetic(url[0])) {
        for (url[1..]) |c| {
            if (c == ':') return "nonlocal_url";
            if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') break;
        }
    }
    return "local_url";
}

pub fn scriptIsJavaScript(script_type: []const u8, language: []const u8) bool {
    var language_buf: [128]u8 = undefined;
    const effective = if (script_type.len == 0 and language.len != 0)
        std.fmt.bufPrint(&language_buf, "text/{s}", .{language}) catch return false
    else
        script_type;
    const trimmed = std.mem.trim(u8, effective, " \t\r\n\x0c");
    if (trimmed.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "module")) return true;
    for ([_][]const u8{ "application/javascript", "application/ecmascript", "application/x-javascript", "application/x-ecmascript", "text/javascript", "text/ecmascript", "text/javascript1.0", "text/javascript1.1", "text/javascript1.2", "text/javascript1.3", "text/javascript1.4", "text/javascript1.5", "text/jscript", "text/livescript", "text/x-javascript", "text/x-ecmascript" }) |mime| {
        if (std.ascii.eqlIgnoreCase(trimmed, mime)) return true;
    }
    return false;
}
