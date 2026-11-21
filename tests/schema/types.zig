const ziggy = @import("ziggy");

pub const Record = struct {
    required: i64,
    choice: Choice,
    members: Members,
    ratio: f64,
    optional: ?i64 = null,
    defaulted: bool = false,
    nested: struct { label: []const u8 },
    list: []const i64 = &.{},
    dictionary: ziggy.Dictionary(i64) = .empty,
    hidden: bool = false,

    pub const ziggy_options: ziggy.Options(@This()) = .{ .skip_fields = &.{.hidden} };
};
pub const Choice = union(enum) {
    payload: i64,
    empty,
    nullable: ?i64,
};
pub const Members = enum { first, second };

pub const Document = Record;
