pub const Handle = usize;
pub const null_handle: Handle = 0;

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createElement: *const fn (*anyopaque, tag: []const u8) Handle,
        createText: *const fn (*anyopaque, data: []const u8) Handle,
        setText: *const fn (*anyopaque, node: Handle, data: []const u8) void,
        setAttribute: *const fn (*anyopaque, node: Handle, name: []const u8, value: []const u8) void,
        removeAttribute: *const fn (*anyopaque, node: Handle, name: []const u8) void,
        appendChild: *const fn (*anyopaque, parent: Handle, child: Handle) void,
        insertBefore: *const fn (*anyopaque, parent: Handle, child: Handle, ref: Handle) void,
        removeChild: *const fn (*anyopaque, parent: Handle, child: Handle) void,
    };

    pub fn createElement(self: Backend, tag: []const u8) Handle {
        return self.vtable.createElement(self.ptr, tag);
    }
    pub fn createText(self: Backend, data: []const u8) Handle {
        return self.vtable.createText(self.ptr, data);
    }
    pub fn setText(self: Backend, node: Handle, data: []const u8) void {
        self.vtable.setText(self.ptr, node, data);
    }
    pub fn setAttribute(self: Backend, node: Handle, name: []const u8, value: []const u8) void {
        self.vtable.setAttribute(self.ptr, node, name, value);
    }
    pub fn removeAttribute(self: Backend, node: Handle, name: []const u8) void {
        self.vtable.removeAttribute(self.ptr, node, name);
    }
    pub fn appendChild(self: Backend, parent: Handle, child: Handle) void {
        self.vtable.appendChild(self.ptr, parent, child);
    }
    pub fn insertBefore(self: Backend, parent: Handle, child: Handle, ref: Handle) void {
        self.vtable.insertBefore(self.ptr, parent, child, ref);
    }
    pub fn removeChild(self: Backend, parent: Handle, child: Handle) void {
        self.vtable.removeChild(self.ptr, parent, child);
    }
};
