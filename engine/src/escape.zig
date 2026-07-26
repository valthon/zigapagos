const std = @import("std");

pub fn writeText(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

pub fn writeAttr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

test "escape text and attribute" {
    const a = std.testing.allocator;

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try writeText(&aw.writer, "a < b && c > d");
    try std.testing.expectEqualStrings("a &lt; b &amp;&amp; c &gt; d", aw.written());

    var aw2: std.Io.Writer.Allocating = .init(a);
    defer aw2.deinit();
    try writeAttr(&aw2.writer, "say \"hi\" & <go>");
    try std.testing.expectEqualStrings("say &quot;hi&quot; &amp; &lt;go&gt;", aw2.written());
}
