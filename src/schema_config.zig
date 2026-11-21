// The checker binds the schema root to the document Config actually reads,
// rather than to Config's custom runtime wrapper.
pub const Document = @import("root.zig").Config.Document;
