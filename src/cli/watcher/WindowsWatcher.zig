const WindowsWatcher = @This();

const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;
const fatal = @import("../../fatal.zig");
const Debouncer = @import("../watcher.zig").Debouncer;

const log = std.log.scoped(.watcher);

// Win32 ABI declarations no longer supplied by std.os.windows.
const OVERLAPPED = extern struct {
    Internal: windows.ULONG_PTR = 0,
    InternalHigh: windows.ULONG_PTR = 0,
    Offset: windows.DWORD = 0,
    OffsetHigh: windows.DWORD = 0,
    hEvent: ?windows.HANDLE = null,
};

// Win32 constants that std.os.windows no longer exports.
const GENERIC_READ: windows.DWORD = 0x80000000;
const FILE_SHARE_READ: windows.DWORD = 0x00000001;
const FILE_SHARE_WRITE: windows.DWORD = 0x00000002;
const FILE_SHARE_DELETE: windows.DWORD = 0x00000004;
const OPEN_EXISTING: windows.DWORD = 3;
const INFINITE: windows.DWORD = 0xFFFFFFFF;

const FILE_ACTION_ADDED: windows.DWORD = 1;
const FILE_ACTION_REMOVED: windows.DWORD = 2;
const FILE_ACTION_MODIFIED: windows.DWORD = 3;
const FILE_ACTION_RENAMED_OLD_NAME: windows.DWORD = 4;
const FILE_ACTION_RENAMED_NEW_NAME: windows.DWORD = 5;
const win32 = struct {
    pub extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
    pub extern "kernel32" fn ReadDirectoryChangesW(
        hDirectory: windows.HANDLE,
        lpBuffer: *anyopaque,
        nBufferLength: windows.DWORD,
        bWatchSubtree: windows.BOOL,
        dwNotifyFilter: windows.DWORD,
        lpBytesReturned: ?*windows.DWORD,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?*anyopaque,
    ) callconv(.winapi) windows.BOOL;
    pub extern "kernel32" fn GetQueuedCompletionStatus(
        CompletionPort: windows.HANDLE,
        lpNumberOfBytesTransferred: *windows.DWORD,
        lpCompletionKey: *windows.ULONG_PTR,
        lpOverlapped: *?*OVERLAPPED,
        dwMilliseconds: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;

    pub extern "kernel32" fn CreateIoCompletionPort(
        FileHandle: windows.HANDLE,
        ExistingCompletionPort: ?windows.HANDLE,
        CompletionKey: windows.ULONG_PTR,
        NumberOfConcurrentThreads: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;
};

const notify_filter: windows.DWORD =
    0x00000001 | // FILE_NOTIFY_CHANGE_FILE_NAME
    0x00000002 | // FILE_NOTIFY_CHANGE_DIR_NAME
    0x00000010; // FILE_NOTIFY_CHANGE_LAST_WRITE

const CompletionKey = usize;
/// Values should be a multiple of `ReadBufferEntrySize`
const ReadBufferIndex = u32;
const ReadBufferEntrySize = 1024;

const WatchEntry = struct {
    dir_path: [:0]const u8,
    dir_handle: windows.HANDLE,

    overlap: OVERLAPPED = std.mem.zeroes(OVERLAPPED),
    buf_idx: ReadBufferIndex,
};

io: Io,
debouncer: *Debouncer,
iocp_port: windows.HANDLE,
entries: std.AutoHashMap(CompletionKey, WatchEntry),
read_buffer: []u8,

pub fn init(
    io: Io,
    gpa: std.mem.Allocator,
    debouncer: *Debouncer,
    dir_paths: []const []const u8,
) WindowsWatcher {
    return initInner(io, gpa, debouncer, dir_paths) catch |err| fatal.msg("error: unable to start the file watcher: {s}", .{
        @errorName(err),
    });
}

fn initInner(
    io: Io,
    gpa: std.mem.Allocator,
    debouncer: *Debouncer,
    dir_paths: []const []const u8,
) !WindowsWatcher {
    var watcher = WindowsWatcher{
        .io = io,
        .debouncer = debouncer,
        .iocp_port = windows.INVALID_HANDLE_VALUE,
        .entries = std.AutoHashMap(CompletionKey, WatchEntry).init(gpa),
        .read_buffer = &.{},
    };
    errdefer {
        if (watcher.read_buffer.len != 0) gpa.free(watcher.read_buffer);
        var iter = watcher.entries.valueIterator();
        while (iter.next()) |entry| {
            _ = win32.CloseHandle(entry.dir_handle);
            gpa.free(entry.dir_path);
        }
        watcher.entries.deinit();
        if (watcher.iocp_port != windows.INVALID_HANDLE_VALUE)
            _ = win32.CloseHandle(watcher.iocp_port);
    }

    // Doubles as the number of WatchEntries
    var comp_key: CompletionKey = 0;

    for (dir_paths) |path| {
        const in_path = try gpa.dupeSentinel(u8, path, 0);
        errdefer gpa.free(in_path);
        const entry = try addPath(in_path, comp_key, &watcher.iocp_port);
        errdefer _ = win32.CloseHandle(entry.dir_handle);
        try watcher.entries.putNoClobber(
            comp_key,
            entry,
        );
        comp_key += 1;
    }

    watcher.read_buffer = try gpa.alloc(u8, ReadBufferEntrySize * comp_key);
    // Zero the buffer so a first-completion overflow (bytes_transferred == 0,
    // handled in `listen`) never exposes uninitialized bytes to the parser.
    @memset(watcher.read_buffer, 0);

    // Here we need pointers to both the read_buffer and entry overlapped structs,
    // which we can only do after setting up everything else.
    watcher.entries.lockPointers();
    for (0..comp_key) |key| {
        const entry = watcher.entries.getPtr(key).?;
        if (win32.ReadDirectoryChangesW(
            entry.dir_handle,
            @ptrCast(@alignCast(&watcher.read_buffer[entry.buf_idx])),
            ReadBufferEntrySize,
            .TRUE,
            notify_filter,
            null,
            &entry.overlap,
            null,
        ) == .FALSE) {
            log.err("ReadDirectoryChanges error: {s}", .{
                @tagName(windows.GetLastError()),
            });
            return error.QueueFailed;
        }
    }
    return watcher;
}

fn addPath(
    path: [:0]const u8,
    /// Assumed to increment by 1 after each invocation, starting at 0.
    key: CompletionKey,
    port: *windows.HANDLE,
) !WatchEntry {
    const dir_handle = CreateFileA(
        path,
        GENERIC_READ, // FILE_LIST_DIRECTORY,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        null,
        OPEN_EXISTING,
        0x02000000 | 0x40000000,
        null,
    );
    if (dir_handle == windows.INVALID_HANDLE_VALUE) {
        log.err(
            "Unable to open directory {s}: {s}",
            .{ path, @tagName(windows.GetLastError()) },
        );
        return error.InvalidHandle;
    }
    errdefer _ = win32.CloseHandle(dir_handle);

    if (port.* == windows.INVALID_HANDLE_VALUE) {
        port.* = win32.CreateIoCompletionPort(dir_handle, null, key, 0) orelse return error.Unexpected;
    } else {
        _ = win32.CreateIoCompletionPort(dir_handle, port.*, key, 0) orelse return error.Unexpected;
    }

    return .{
        .dir_path = path,
        .dir_handle = dir_handle,
        .buf_idx = @intCast(ReadBufferEntrySize * key),
    };
}

pub fn start(watcher: *WindowsWatcher) !void {
    const t = try std.Thread.spawn(.{}, WindowsWatcher.listen, .{watcher});
    t.detach();
}

pub fn listen(watcher: *WindowsWatcher) !void {
    var completion: struct {
        bytes_transferred: windows.DWORD = undefined,
        overlap: ?*OVERLAPPED = undefined,
    } = .{};

    // The name is UTF-16; `FileNameLength` is in bytes (code units * 2). Worst-
    // case UTF-8 expansion is 3 bytes per BMP code unit, and a single record's
    // name cannot exceed one `ReadBufferEntrySize` buffer, so a destination of
    // `ReadBufferEntrySize * 3` bounds every decode (never a fixed MAX_PATH).
    var path_buf: [ReadBufferEntrySize * 3]u8 = undefined;

    var key: CompletionKey = undefined;
    while (true) {
        // Waits here until any of the directory handles associated with the iocp port
        // have been updated.
        const wait_result = win32.GetQueuedCompletionStatus(
            watcher.iocp_port,
            &completion.bytes_transferred,
            &key,
            &completion.overlap,
            INFINITE,
        );
        if (wait_result == .FALSE) {
            log.err("GetQueuedCompletionStatus error: {s}", .{@tagName(windows.GetLastError())});
            return error.WaitFailed;
        }

        const entry = watcher.entries.getPtr(key) orelse @panic("Invalid CompletionKey");

        // A `bytes_transferred` of 0 is a buffer-overflow completion
        // (STATUS_NOTIFY_ENUM_DIR): the change burst exceeded the buffer and its
        // contents are stale/uninitialized. Do not parse it — like the Linux
        // IN_Q_OVERFLOW path, signal a full rebuild and re-queue.
        if (completion.bytes_transferred == 0) {
            watcher.debouncer.newEvent();
        } else {
            var info_iter = windows.FileInformationIterator(FILE_NOTIFY_INFORMATION){
                .buf = watcher.read_buffer[entry.buf_idx..][0..completion.bytes_transferred],
            };
            while (info_iter.next()) |info| {
                const name_units = @as([*]u16, @ptrCast(&info.FileName))[0 .. info.FileNameLength / 2];
                // A change occurred regardless of whether the name decodes, so
                // decoding is best-effort (for the debug log only) and never
                // aborts the watcher thread or overruns `path_buf`.
                const filename: []const u8 = decode: {
                    // Compare via division so an implausibly large FileNameLength
                    // cannot overflow the `* 3` on a 32-bit usize.
                    if (name_units.len > path_buf.len / 3) {
                        log.err("change event filename too long ({d} UTF-16 code units); skipping name decode", .{name_units.len});
                        break :decode "<name too long>";
                    }
                    const n = std.unicode.utf16LeToUtf8(&path_buf, name_units) catch |err| {
                        log.err("invalid UTF-16 in change event filename: {s}", .{@errorName(err)});
                        break :decode "<invalid name>";
                    };
                    break :decode path_buf[0..n];
                };

                const args = .{ entry.dir_path, filename };
                switch (info.Action) {
                    FILE_ACTION_ADDED => log.debug("added  {s}/{s}", args),
                    FILE_ACTION_REMOVED => log.debug("removed  {s}/{s}", args),
                    FILE_ACTION_MODIFIED => log.debug("modified  {s}/{s}", args),
                    FILE_ACTION_RENAMED_OLD_NAME => log.debug("renamed_old_name {s}/{s}", args),
                    FILE_ACTION_RENAMED_NEW_NAME => log.debug("renamed_new_name  {s}/{s}", args),
                    else => log.debug("Unknown Action {s}/{s}", args),
                }

                watcher.debouncer.newEvent();
            }
        }

        // Re-queue the directory entry
        if (win32.ReadDirectoryChangesW(
            entry.dir_handle,
            @ptrCast(@alignCast(&watcher.read_buffer[entry.buf_idx])),
            ReadBufferEntrySize,
            .TRUE,
            notify_filter,
            null,
            &entry.overlap,
            null,
        ) == .FALSE) {
            log.err("ReadDirectoryChanges error: {s}", .{@tagName(windows.GetLastError())});
            return error.QueueFailed;
        }
    }
}

const FILE_NOTIFY_INFORMATION = extern struct {
    NextEntryOffset: windows.DWORD,
    Action: windows.DWORD,
    FileNameLength: windows.DWORD,
    /// Flexible array member
    FileName: windows.WCHAR,
};

extern "kernel32" fn CreateFileA(
    lpFileName: windows.LPCSTR,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;
