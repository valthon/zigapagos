//! Dev-only browser live-reload for `zigapagos dev`.
//!
//! Since the serving pivot (memory: zigbase-serving-pivot) the STOCK ZigBase
//! binary serves the built tree and zigapagos owns no request path into the
//! browser. Live-reload therefore runs as a SIDE CHANNEL owned by the dev loop:
//!
//!   * a tiny Server-Sent-Events (SSE) endpoint on its OWN port (`Server`
//!     here), which holds every browser connection open and broadcasts one
//!     "reload" event whenever a rebuild completes, and
//!   * a small inline `<script>` injected into every `.html` in the SERVED
//!     tree after each build (`injectTree`), which opens an `EventSource` to
//!     that endpoint and calls `location.reload()` on the event.
//!
//! DEV-ONLY: the snippet is injected by the dev loop into the *installed* tree
//! post-build; a plain `zig build` / `zigapagos release` never runs this code,
//! so release output is never touched (proven by tests/dev/dev.sh). SSE (not
//! WebSocket) keeps the server tiny and the client a one-liner, and
//! `EventSource` auto-reconnects — so the reconnect after the reload it just
//! triggered is automatic, with no bookkeeping here.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Marker embedded in the injected snippet. Doubles as the injected-already
/// guard (`injectFile` skips a file that already contains it) — though a
/// rebuild rewrites files fresh, so injection normally starts from clean HTML.
pub const marker = "zigapagos:live-reload";

/// The injected snippet. `{d}` is the SSE port; `location.hostname` (not a
/// baked-in host) makes it work whether the browser reached the site via
/// `localhost` or `127.0.0.1`. Braces are doubled for `std.fmt`.
///
/// The stream carries one of two payloads (see `Server.handle`):
///   * `data: reload`                                  → full-page reload, OR
///   * `data: {"kind":"island","modules":[…]}` (JSON)  → island hot-swap.
/// An island message is handed to `@z/runtime`'s HMR global
/// (`window.__zigapagos_hmr.applyIsland`, hmr.ts); if the runtime isn't present
/// or a swap can't be applied cleanly it resolves false and we fall back to a
/// full reload. Every full reload first dispatches `zigapagos:beforereload` so
/// `useRestorableState` can persist its value across the reload.
const snippet_fmt =
    "<!-- " ++ marker ++ " (dev only) -->" ++
    "<script data-zigapagos-live-reload>" ++
    "(function(){{" ++
    "function full(){{try{{window.dispatchEvent(new CustomEvent('zigapagos:beforereload'));}}catch(e){{}}location.reload();}}" ++
    "try{{" ++
    "var es=new EventSource(\"http://\"+location.hostname+\":{d}/\");" ++
    "es.onmessage=function(ev){{" ++
    "var m=null;try{{m=JSON.parse(ev.data);}}catch(e){{}}" ++
    "if(m&&m.kind==='island'&&window.__zigapagos_hmr){{" ++
    "window.__zigapagos_hmr.applyIsland(m.modules).then(function(ok){{if(!ok)full();}},full);" ++
    "return;" ++
    "}}" ++
    "full();" ++
    "}};" ++
    "}}catch(e){{}}" ++
    "}})();" ++
    "</script>";

/// SSE broadcast server. One instance per dev session: `start` spawns the
/// accept thread (which spawns one thread per connection); `notify` wakes every
/// connected browser. Threads live for the whole dev session — no teardown.
pub const Server = struct {
    io: Io,
    gpa: Allocator,
    address: Io.net.IpAddress,

    /// Live SSE connections, each pinned to its own thread parked forever in
    /// `handle`. Bounded by `max_connections`: the endpoint answers
    /// `access-control-allow-origin: *` (the cross-origin `EventSource` needs
    /// it), so ANY page the developer has open can hold an `EventSource` here,
    /// and nothing else caps the thread count. Only ever touched through
    /// `reserveSlot`/`releaseSlot`.
    connections: std.atomic.Value(u32) = .init(0),

    /// Generation counter: every connection thread blocks until it changes,
    /// then emits one SSE "reload" event. Guarded by `mutex`; `cond` wakes the
    /// waiters on `notify`.
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    generation: u64 = 0,
    /// The SSE `data:` value broadcast for the CURRENT generation, gpa-owned and
    /// guarded by `mutex`. `null` means the default full-reload signal
    /// (`data: reload`); `notifyIslands` sets a JSON payload for a hot-swap.
    /// Persists until the next `notify*` replaces it (so every waiter that wakes
    /// on one generation reads the same value).
    payload: ?[]u8 = null,

    /// Hard cap on simultaneously-served `EventSource` streams. One dev browser
    /// needs one; a few tabs plus a stale window need a handful. 32 leaves ample
    /// headroom while bounding the parked-thread count no matter how many pages
    /// point an `EventSource` at this port.
    pub const max_connections: u32 = 32;

    pub fn init(io: Io, gpa: Allocator, address: Io.net.IpAddress) Server {
        return .{ .io = io, .gpa = gpa, .address = address };
    }

    /// Claims one of the `max_connections` slots. False means the cap is
    /// reached and the caller must refuse the connection; no slot is consumed
    /// in that case.
    fn reserveSlot(s: *Server) bool {
        const before = s.connections.fetchAdd(1, .monotonic);
        if (before < max_connections) return true;
        _ = s.connections.fetchSub(1, .monotonic);
        return false;
    }

    /// Returns a slot claimed by `reserveSlot`.
    fn releaseSlot(s: *Server) void {
        _ = s.connections.fetchSub(1, .monotonic);
    }

    /// Spawns the (detached) accept thread. Returns once it is listening-or-
    /// failed; a bind failure is reported on the thread, not fatal to the loop.
    pub fn start(s: *Server) std.Thread.SpawnError!void {
        const t = try std.Thread.spawn(.{}, accept, .{s});
        t.detach();
    }

    /// Broadcast a full-page reload to every connected browser. Call after a
    /// good build when the change can't be hot-swapped (the safe default).
    pub fn notify(s: *Server) void {
        s.mutex.lock(s.io) catch return;
        if (s.payload) |p| {
            s.gpa.free(p);
            s.payload = null;
        }
        s.generation +%= 1;
        s.mutex.unlock(s.io);
        s.cond.broadcast(s.io);
    }

    /// Broadcast an island hot-swap: the connected browsers re-import and
    /// re-render just `modules` (the changed `data-z-module` URLs) in place,
    /// preserving component state, instead of a full reload. The build side (the
    /// dev loop's change detection) calls this when it knows ONLY island bundles
    /// changed; anything else stays `notify()`. On OOM we fall back to a full
    /// reload rather than dropping the rebuild signal.
    pub fn notifyIslands(s: *Server, modules: []const []const u8) void {
        const json = buildIslandPayload(s.gpa, modules) catch return s.notify();
        s.mutex.lock(s.io) catch {
            s.gpa.free(json);
            return;
        };
        if (s.payload) |p| s.gpa.free(p);
        s.payload = json;
        s.generation +%= 1;
        s.mutex.unlock(s.io);
        s.cond.broadcast(s.io);
    }

    fn accept(s: *Server) void {
        var srv = s.address.listen(s.io, .{ .reuse_address = true }) catch |err| {
            std.debug.print(
                "dev: live-reload: unable to bind the reload port ({any}): {s} — reload disabled\n",
                .{ s.address, @errorName(err) },
            );
            return;
        };
        defer srv.deinit(s.io);

        while (true) {
            const stream = srv.accept(s.io) catch |err| switch (err) {
                error.ConnectionAborted, error.NetworkDown => continue,
                else => return, // listener is gone; stop accepting
            };
            // Refuse past the cap instead of spawning an unbounded number of
            // forever-parked threads. Dropping the connection is the refusal:
            // `EventSource` retries on its own, so a slot freed later is picked
            // up without any bookkeeping here.
            if (!s.reserveSlot()) {
                std.debug.print(
                    "dev: live-reload: refusing a connection ({d} already open) — close some tabs\n",
                    .{max_connections},
                );
                stream.close(s.io);
                continue;
            }
            const t = std.Thread.spawn(.{}, handle, .{ s, stream }) catch {
                s.releaseSlot();
                stream.close(s.io);
                continue;
            };
            t.detach();
        }
    }

    /// Serves one browser: reply with SSE headers, then block on `generation`
    /// and emit `data: reload` on each build. A write failure means the browser
    /// went away → drop the connection (EventSource will reconnect if it comes
    /// back).
    fn handle(s: *Server, stream: Io.net.Stream) void {
        defer stream.close(s.io);
        // The slot `accept` reserved for this connection; every exit path from
        // here (there are many `catch return`s) must give it back.
        defer s.releaseSlot();

        var bufin: [4096]u8 = undefined;
        var in = stream.reader(s.io, &bufin);
        var bufout: [1024]u8 = undefined;
        var out = stream.writer(s.io, &bufout);
        var http = std.http.Server.init(&in.interface, &out.interface);

        // One request per connection is all EventSource makes (a single GET).
        var req = http.receiveHead() catch return;

        var resp_buf: [1024]u8 = undefined;
        var body = req.respondStreaming(&resp_buf, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/event-stream" },
                    .{ .name = "cache-control", .value = "no-cache, no-transform" },
                    // The page is served from ZigBase's port — a DIFFERENT origin —
                    // so the cross-origin EventSource needs CORS to read the stream.
                    .{ .name = "access-control-allow-origin", .value = "*" },
                    // Defeat proxy/response buffering so events arrive live.
                    .{ .name = "x-accel-buffering", .value = "no" },
                },
            },
        }) catch return;

        // Greeting: set the client's reconnect delay and confirm the stream is
        // open (tests poll for `: connected`).
        body.writer.writeAll("retry: 1000\n: connected\n\n") catch return;
        flush(&body) catch return;

        var seen: u64 = blk: {
            s.mutex.lock(s.io) catch return;
            defer s.mutex.unlock(s.io);
            break :blk s.generation;
        };
        while (true) {
            // Copy the current generation's payload WHILE holding the lock — a
            // later notify* may free/replace it the moment we release.
            const line: []u8 = blk: {
                s.mutex.lock(s.io) catch return;
                defer s.mutex.unlock(s.io);
                while (s.generation == seen) s.cond.waitUncancelable(s.io, &s.mutex);
                seen = s.generation;
                break :blk s.gpa.dupe(u8, s.payload orelse "reload") catch return;
            };
            defer s.gpa.free(line);

            // SSE frame: `data: <payload>\n\n`. Payloads are single-line (plain
            // "reload" or one-line JSON), so no `data:` re-framing is needed.
            body.writer.writeAll("data: ") catch return;
            body.writer.writeAll(line) catch return;
            body.writer.writeAll("\n\n") catch return;
            flush(&body) catch return;
        }
    }

    /// Two-layer flush so each SSE event reaches the socket immediately: drain
    /// the body buffer through the chunked framing, then push it to the socket.
    fn flush(body: *std.http.BodyWriter) !void {
        try body.writer.flush();
        try body.flush();
    }
};

/// Inject the live-reload snippet into every `.html` under `site_abs`. Called
/// after each successful build. Best-effort: a file that can't be read/written
/// is skipped with a debug note; the loop keeps going.
///
/// `since_ns` (AUD-028): when non-null, only `.html` files touched at/after this
/// wall-clock nanosecond are read and injected — an incremental rebuild re-emits
/// just the changed pages, so the unchanged 99% keep their existing snippet and
/// are skipped after a single cheap `stat` instead of a full read. Pass null
/// after a full rebuild (every page was re-emitted from clean HTML).
pub fn injectTree(io: Io, gpa: Allocator, site_abs: []const u8, port: u16, since_ns: ?i128) void {
    var dir = Io.Dir.cwd().openDir(io, site_abs, .{ .iterate = true }) catch |err| {
        std.debug.print(
            "dev: live-reload: cannot open the served tree '{s}': {s} — pages will not auto-reload\n",
            .{ site_abs, @errorName(err) },
        );
        return;
    };
    defer dir.close(io);
    injectDir(io, gpa, dir, port, since_ns);
}

fn injectDir(io: Io, gpa: Allocator, dir: Io.Dir, port: u16, since_ns: ?i128) void {
    var it = dir.iterateAssumeFirstIteration();
    while (it.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                injectDir(io, gpa, sub, port, since_ns);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".html")) continue;
                injectFile(io, gpa, dir, entry.name, port, since_ns);
            },
            else => {},
        }
    }
}

fn injectFile(io: Io, gpa: Allocator, dir: Io.Dir, name: []const u8, port: u16, since_ns: ?i128) void {
    // Skip files the incremental rebuild didn't re-emit: they already carry the
    // snippet from a prior injection (AUD-028). A `stat` is far cheaper than the
    // full read the marker check would otherwise require.
    if (since_ns) |cutoff| {
        const st = dir.statFile(io, name, .{}) catch |err| {
            std.debug.print("dev: live-reload: skipped '{s}' (stat: {s})\n", .{ name, @errorName(err) });
            return;
        };
        if (@as(i128, st.mtime.nanoseconds) < cutoff) return;
    }

    const html = dir.readFileAlloc(io, name, gpa, .unlimited) catch |err| {
        std.debug.print("dev: live-reload: skipped '{s}' (read: {s})\n", .{ name, @errorName(err) });
        return;
    };
    defer gpa.free(html);

    // Defensive: never inject twice (a rebuild rewrites files, so this is only
    // hit if some other pass already added the snippet).
    if (std.mem.indexOf(u8, html, marker) != null) return;

    const snippet = std.fmt.allocPrint(gpa, snippet_fmt, .{port}) catch return;
    defer gpa.free(snippet);

    const at = insertionPoint(html);

    // Write the injected page to a sibling temporary and rename it over the
    // target. Rewriting the served file in place (create → truncate → three
    // writes) is not safe here: zigbase serves this tree concurrently, so a
    // fetch landing mid-write sees a truncated page, and a write that fails
    // part-way (ENOSPC/EIO) leaves a permanently truncated file that carries no
    // marker — so the next `injectTree` would happily inject into the wreckage.
    // `createFileAtomic` + `replace` makes the page swap atomically: readers see
    // either the whole old file or the whole new one, and a failure anywhere in
    // between leaves the original untouched.
    var af = dir.createFileAtomic(io, name, .{ .replace = true }) catch |err| {
        std.debug.print("dev: live-reload: skipped '{s}' (open: {s})\n", .{ name, @errorName(err) });
        return;
    };
    // Also deletes the temporary if we bail out before `replace` succeeds.
    defer af.deinit(io);

    var w = af.file.writer(io, &.{}); // unbuffered: stream the three slices straight through
    for ([_][]const u8{ html[0..at], snippet, html[at..] }) |slice| {
        w.interface.writeAll(slice) catch |err| {
            std.debug.print("dev: live-reload: skipped '{s}' (write: {s})\n", .{ name, @errorName(err) });
            return;
        };
    }
    af.replace(io) catch |err| {
        std.debug.print("dev: live-reload: skipped '{s}' (replace: {s})\n", .{ name, @errorName(err) });
        return;
    };
}

/// Build the island hot-swap SSE payload: `{"kind":"island","modules":[…]}`
/// with each module URL JSON-quoted (only `"`/`\` need escaping — module URLs
/// are `/islands/NAME.js`-shaped, no control chars). gpa-owned; caller frees.
fn buildIslandPayload(gpa: Allocator, modules: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"kind\":\"island\",\"modules\":[");
    for (modules, 0..) |m, i| {
        if (i != 0) try out.append(gpa, ',');
        try out.append(gpa, '"');
        for (m) |c| {
            if (c == '"' or c == '\\') try out.append(gpa, '\\');
            try out.append(gpa, c);
        }
        try out.append(gpa, '"');
    }
    try out.appendSlice(gpa, "]}");
    return out.toOwnedSlice(gpa);
}

/// Byte offset at which to splice the snippet: just before the closing
/// `</body>`, else `</html>`, else the end of the document.
fn insertionPoint(html: []const u8) usize {
    if (lastIndexOfCI(html, "</body>")) |i| return i;
    if (lastIndexOfCI(html, "</html>")) |i| return i;
    return html.len;
}

/// Last occurrence of `needle` in `haystack`, ASCII-case-insensitive.
fn lastIndexOfCI(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = haystack.len - needle.len + 1;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

// --- unit tests (run via `zig build test-dev`; names carry the "dev" anchor
// filter, and dev.zig @imports this file so the blocks are analyzed) ----------

test "dev live-reload: snippet lands before </body>" {
    const gpa = std.testing.allocator;
    const html = "<html><head></head><body><h1>hi</h1></body></html>";
    const at = insertionPoint(html);
    try std.testing.expectEqualStrings("</body></html>", html[at..]);

    const snippet = try std.fmt.allocPrint(gpa, snippet_fmt, .{4321});
    defer gpa.free(snippet);
    // The port and marker are both present in the rendered snippet.
    try std.testing.expect(std.mem.indexOf(u8, snippet, ":4321/") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "data-zigapagos-live-reload") != null);
    // The client actually wires up an EventSource + reload handler.
    try std.testing.expect(std.mem.indexOf(u8, snippet, "new EventSource") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "location.reload()") != null);
    // It routes island messages to the runtime HMR global, dispatches the
    // restorable-state event before a full reload, and JSON-parses the payload.
    try std.testing.expect(std.mem.indexOf(u8, snippet, "JSON.parse(ev.data)") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "__zigapagos_hmr") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "applyIsland(m.modules)") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "zigapagos:beforereload") != null);
}

test "dev live-reload: island payload is well-formed JSON with escaped modules" {
    const gpa = std.testing.allocator;

    const one = try buildIslandPayload(gpa, &.{"/islands/Counter.island.js"});
    defer gpa.free(one);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"island\",\"modules\":[\"/islands/Counter.island.js\"]}",
        one,
    );

    const many = try buildIslandPayload(gpa, &.{ "/islands/A.js", "/islands/B.js" });
    defer gpa.free(many);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"island\",\"modules\":[\"/islands/A.js\",\"/islands/B.js\"]}",
        many,
    );

    // A stray quote/backslash in a module id is escaped (single-line JSON).
    const odd = try buildIslandPayload(gpa, &.{"/islands/a\"b\\c.js"});
    defer gpa.free(odd);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"island\",\"modules\":[\"/islands/a\\\"b\\\\c.js\"]}",
        odd,
    );

    // Empty list is still valid JSON.
    const none = try buildIslandPayload(gpa, &.{});
    defer gpa.free(none);
    try std.testing.expectEqualStrings("{\"kind\":\"island\",\"modules\":[]}", none);
}

test "dev live-reload: insertion falls back to </html>, then end" {
    // No body → before </html>.
    try std.testing.expectEqualStrings(
        "</HTML>",
        "<html>x</HTML>"[insertionPoint("<html>x</HTML>")..],
    );
    // Neither tag → append at the very end.
    const bare = "just text";
    try std.testing.expectEqual(bare.len, insertionPoint(bare));
}

test "dev live-reload: injectFile swaps the page in atomically, never rewriting it in place" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const original = "<html><body><h1>hi</h1></body></html>";
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = original });
    const before = try tmp.dir.statFile(io, "index.html", .{});

    injectFile(io, gpa, tmp.dir, "index.html", 4321, null);

    // The snippet landed, spliced before </body> and leaving the page intact.
    const html = try tmp.dir.readFileAlloc(io, "index.html", gpa, .unlimited);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, marker) != null);
    try std.testing.expect(std.mem.startsWith(u8, html, "<html><body><h1>hi</h1>"));
    try std.testing.expect(std.mem.endsWith(u8, html, "</body></html>"));

    // …and it landed by renaming a fully-written file over the target, not by
    // truncating and refilling the live one. zigbase serves this tree
    // concurrently, so an in-place rewrite exposes a truncated page to any
    // fetch in the window (and leaves one permanently on a failed write). A
    // rename gives the name a NEW inode; a create-truncate-write keeps the old.
    const after = try tmp.dir.statFile(io, "index.html", .{});
    try std.testing.expect(before.inode != after.inode);

    // The temporary is gone on the success path — only the page remains, so a
    // later injectTree walk has nothing extra to trip over.
    var it = tmp.dir.iterate();
    var entries: usize = 0;
    while (try it.next(io)) |_| entries += 1;
    try std.testing.expectEqual(@as(usize, 1), entries);
}

test "dev live-reload: the SSE server refuses connections past the cap" {
    // Slot accounting touches only the atomic counter, so the io/gpa/address
    // fields are never read here — the cap is exactly what `accept` consults
    // before spawning a per-connection thread.
    var s: Server = .init(undefined, undefined, undefined);

    for (0..Server.max_connections) |i| {
        try std.testing.expect(s.reserveSlot());
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), s.connections.load(.monotonic));
    }

    // At the cap every further EventSource is refused — an unbounded number of
    // them is exactly what any page the developer has open can open, since the
    // endpoint answers `access-control-allow-origin: *`.
    try std.testing.expect(!s.reserveSlot());
    try std.testing.expect(!s.reserveSlot());
    // A refusal must not consume a slot, or the counter would ratchet up and
    // the server would stay closed even after every tab went away.
    try std.testing.expectEqual(Server.max_connections, s.connections.load(.monotonic));

    // One browser going away frees exactly one slot.
    s.releaseSlot();
    try std.testing.expect(s.reserveSlot());
    try std.testing.expect(!s.reserveSlot());
}

test "dev live-reload: closing tags are matched case-insensitively" {
    try std.testing.expect(lastIndexOfCI("aa</BODY>bb", "</body>") != null);
    try std.testing.expect(lastIndexOfCI("no tags here", "</body>") == null);
    // The LAST match wins (defends against `</body>` in stray text).
    try std.testing.expectEqual(
        @as(?usize, 10),
        lastIndexOfCI("</body> x </body>", "</body>"),
    );
}
