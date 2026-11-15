//! Caller-buffer CSP source validation: no allocation, run before any output writes.
const std = @import("std");

pub const ExtraSources = struct {
    directive: []const u8,
    sources: []const []const u8,
};

pub fn validDirective(value: []const u8) bool {
    for ([_][]const u8{ "default-src", "script-src", "frame-src", "connect-src", "img-src", "style-src", "style-src-elem", "style-src-attr", "font-src", "object-src", "base-uri" }) |name| {
        if (std.mem.eql(u8, value, name)) return true;
    }
    return false;
}

fn scheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "+-.", c) == null) return false;
    return true;
}

fn base64(value: []const u8) bool {
    const data = std.mem.trimEnd(u8, value, "=");
    if (data.len == 0 or value.len - data.len > 2) return false;
    for (data) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "+/-_", c) == null) return false;
    return true;
}

/// CSP source-expression grammar (keywords, nonce/hash, scheme, wildcard, host/path).
/// A source is one token, never a header fragment or a URL with query/fragment.
pub fn validSource(value: []const u8) bool {
    if (value.len == 0) return false;
    for ([_][]const u8{ "'self'", "'none'", "'unsafe-inline'", "'unsafe-eval'", "'wasm-unsafe-eval'", "'strict-dynamic'", "'unsafe-hashes'", "'report-sample'", "'inline-speculation-rules'", "'trusted-types-eval'" }) |keyword| {
        if (std.mem.eql(u8, value, keyword)) return true;
    }
    for ([_][]const u8{ "'nonce-", "'sha256-", "'sha384-", "'sha512-" }) |prefix| {
        if (std.mem.startsWith(u8, value, prefix) and std.mem.endsWith(u8, value, "'")) return base64(value[prefix.len .. value.len - 1]);
    }
    if (std.mem.endsWith(u8, value, ":") and scheme(value[0 .. value.len - 1])) return true;
    var host_path = value;
    if (std.mem.indexOf(u8, value, "://")) |pos| {
        if (!scheme(value[0..pos])) return false;
        host_path = value[pos + 3 ..];
    }
    const slash = std.mem.indexOfScalar(u8, host_path, '/') orelse host_path.len;
    var host = host_path[0..slash];
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| {
        const port = host[colon + 1 ..];
        if (!std.mem.eql(u8, port, "*")) {
            if (port.len == 0) return false;
            for (port) |c| if (!std.ascii.isDigit(c)) return false;
        }
        host = host[0..colon];
    }
    if (!std.mem.eql(u8, host, "*")) {
        if (std.mem.startsWith(u8, host, "*.")) host = host[2..];
        var labels = std.mem.splitScalar(u8, host, '.');
        while (labels.next()) |label| {
            if (label.len == 0) return false;
            for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
        }
    }
    var i = slash;
    while (i < host_path.len) : (i += 1) {
        const c = host_path[i];
        if (c == '%') {
            if (i + 2 >= host_path.len or !std.ascii.isHex(host_path[i + 1]) or !std.ascii.isHex(host_path[i + 2])) return false;
            i += 2;
        } else if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/-._~!$&()*+,=:@", c) == null) return false;
    }
    return true;
}

test "validate CSP source expressions" {
    for ([_][]const u8{ "'self'", "'sha256-YWJj'", "'nonce-YWJj=='", "data:", "*", "https://*.example.com:*/path%20name/", "example.com:443" }) |source| try std.testing.expect(validSource(source));
    for ([_][]const u8{ "", "https://", "https://example.com;img-src", "https://example.com/\n", "https://example.com/?q", "https://example.com/#f", "'sha256-!!!'", "https://example.com/%GG", "https://example.com:abc", "https://user@example.com", "'made-up'" }) |source| try std.testing.expect(!validSource(source));
    try std.testing.expect(validDirective("frame-src"));
    try std.testing.expect(!validDirective("scripts-src"));
}
