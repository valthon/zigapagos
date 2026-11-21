const ziggy = @import("ziggy");

pub const Containers = struct {
    list: ?[]const i64 = null,
    dictionary: ?ziggy.Dictionary(i64) = null,
    custom_list: ?ziggy.ArrayList(i64) = null,
    nested: ?struct { label: []const u8 } = null,
};

pub const Document = Containers;
