const std = @import("std");
const Io = std.Io;
const RenderArena = @import("render_arena.zig").RenderArena;

pub const Sidecar = struct {
    io: Io,
    child: std.process.Child,
    mutex: std.Io.Mutex = .init,
    next_id: u64 = 1,
    // Process CWD, resolved once in `spawn` (it is fixed for the whole build).
    // Cached so `absSrc` needs neither a getcwd syscall nor an allocation per
    // render, and so it can run outside the serialized critical section (AUD-026).
    cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,

    /// Spawn `bun <sidecar_script>` with piped stdin/stdout. The process stays
    /// alive (warm module cache) until `deinit`.
    ///
    /// `project_root` is passed as the child process CWD so Bun resolves the
    /// consumer island's `@z/runtime` import and the preact JSX transform from
    /// the correct `node_modules` (e.g. `"runtime"` for the built-in test
    /// fixtures, or the consumer site's project root in production).
    ///
    /// `sidecar_script` is resolved to an absolute path before being passed to
    /// Bun so it can always be found regardless of the chosen cwd.
    pub fn spawn(io: Io, bun_path: []const u8, sidecar_script: []const u8, project_root: []const u8) !Sidecar {
        // Resolve sidecar_script to absolute (requires the file to exist on disk).
        var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(io, sidecar_script, &abs_buf);
        const abs_script = abs_buf[0..n];

        const child = try std.process.spawn(io, .{
            .argv = &.{ bun_path, abs_script },
            .stdin = .pipe,
            .stdout = .pipe,
            // stderr inherits parent so Bun errors are visible in the build log.
            .cwd = .{ .path = project_root }, // Bun resolves island @z/runtime + JSX from here
        });
        var self: Sidecar = .{ .io = io, .child = child };
        // Snapshot the process CWD once — it is fixed for the whole build, so
        // every relative island `src` resolves against the same base (AUD-026).
        self.cwd_len = try std.process.currentPath(io, &self.cwd_buf);
        return self;
    }

    /// Resolve `src` to an absolute path so bun can import it regardless of
    /// its own CWD. `src` may already be absolute, in which case it is
    /// returned unchanged. Uses the CWD snapshotted at `spawn` — no syscall.
    fn absSrc(self: *const Sidecar, arena: RenderArena, src: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(src)) return src;
        return try std.fs.path.resolve(arena.a, &.{ self.cwd_buf[0..self.cwd_len], src });
    }

    /// Write `bytes` to the child's stdin and flush. Callers hold `mutex`.
    fn writeAll(self: *Sidecar, bytes: []const u8) !void {
        var wbuf: [4096]u8 = undefined;
        var fw = self.child.stdin.?.writer(self.io, &wbuf);
        const w = &fw.interface;
        try w.writeAll(bytes);
        try w.flush();
    }

    /// Read one newline-delimited line from the child's stdout (unbounded:
    /// island HTML can be large). Callers hold `mutex`.
    fn readLine(self: *Sidecar, arena: RenderArena) ![]const u8 {
        var rbuf: [4096]u8 = undefined;
        var fr = self.child.stdout.?.reader(self.io, &rbuf);
        const r = &fr.interface;
        var line_aw: std.Io.Writer.Allocating = .init(arena.a);
        _ = try r.streamDelimiter(&line_aw.writer, '\n');
        return line_aw.written();
    }

    /// Build one NDJSON render-request line:
    /// `{"id":N,"src":<str>,"props":<json>[,"slots":<json>],"pathname":<str>[,"prefix":<str>]}\n`.
    /// Pure request-line assembly, factored out of `renderPrefixed` so the wire
    /// format is unit-testable without a live Bun process — `render`/
    /// `renderPrefixed` write straight into the child's stdin pipe, which a
    /// test can't intercept without standing up a stub subprocess.
    ///
    /// `url_prefix` is emitted as `"prefix"`, immediately after `"pathname"`,
    /// ONLY when non-empty — see `renderPrefixed`'s doc for why an empty
    /// prefix must be a byte-for-byte no-op.
    ///
    /// NO_SLOP.md §2.2a contract 1: every write lands straight in the
    /// `Allocating` writer's own buffer; `toOwnedSlice` hands that buffer to
    /// the caller and resets the writer to empty, so there is nothing left to
    /// free on this side.
    fn buildRenderRequest(
        alloc: std.mem.Allocator,
        id: u64,
        abs_src: []const u8,
        props_json: []const u8,
        slots_json: []const u8,
        pathname: []const u8,
        url_prefix: []const u8,
    ) ![]const u8 {
        var req_aw: std.Io.Writer.Allocating = .init(alloc);
        const rw = &req_aw.writer;
        try rw.print("{{\"id\":{d},\"src\":", .{id});
        try std.json.Stringify.value(abs_src, .{}, rw);
        try rw.writeAll(",\"props\":");
        try rw.writeAll(props_json);
        if (slots_json.len > 0 and !std.mem.eql(u8, slots_json, "{}")) {
            try rw.writeAll(",\"slots\":");
            try rw.writeAll(slots_json);
        }
        try rw.writeAll(",\"pathname\":");
        try std.json.Stringify.value(pathname, .{}, rw);
        if (url_prefix.len != 0) {
            try rw.writeAll(",\"prefix\":");
            try std.json.Stringify.value(url_prefix, .{}, rw);
        }
        try rw.writeAll("}\n");
        return req_aw.toOwnedSlice();
    }

    /// One render: write the NDJSON request, read the response line, parse it.
    /// Serialized by `mutex` because the Bun process is sequential-only.
    ///
    /// NO_SLOP.md §2.2a contract 4 (`RenderArena`): the returned HTML is not an
    /// allocation of its own — it is a SLICE INTO the arena-owned response line,
    /// produced by `parseFromSliceLeaky`, and so are `err_out`'s strings (1).
    /// Freeing the pieces individually is impossible without invalidating the
    /// return value (2), and they die with the page render that asked for them
    /// (3). This is also the shape of the duck-typed `renderer` interface
    /// `islands/pass.zig`'s `process`/`rewrite` call, so its test stubs take a
    /// `RenderArena` too.
    ///
    /// `src` may be relative to the process CWD; it is resolved to an absolute
    /// path before being sent so bun can import it regardless of its own CWD.
    ///
    /// `err_out`, when non-null, receives the sidecar's STRUCTURED render error
    /// (JS `message` + source-mapped `stack`) if the render throws,
    /// so the caller can surface it — attributed to the failing page/route —
    /// instead of collapsing to the bare `error.SidecarRenderFailed` name. The
    /// written strings are owned by `arena`. Untouched on success or on a
    /// non-render error (bad response / IO); the returned error still
    /// distinguishes those.
    ///
    /// Thin `url_prefix = ""` delegate to `renderPrefixed` (below) — see that
    /// function's doc for why the split exists. Everything documented above
    /// (the contract, `src` resolution, `err_out`) applies identically here.
    pub fn render(
        self: *Sidecar,
        arena: RenderArena,
        src: []const u8,
        props_json: []const u8,
        slots_json: []const u8,
        pathname: []const u8,
        err_out: ?*RenderError,
    ) ![]const u8 {
        return self.renderPrefixed(arena, src, props_json, slots_json, pathname, "", err_out);
    }

    /// `render`, plus `url_prefix` carried over the wire as a `"prefix"` field
    /// (issue #26) — the site's normalized `url_path_prefix` ("" or
    /// "/myrepo"). `runtime/sidecar/render.ts` hands this to the SPA Router so
    /// its `base` composes exactly what a real browser sees at that path,
    /// agreeing byte-for-byte with the prerendered `<a href>`s `src/spa.zig`
    /// bakes into the shell (AUDF-005's sibling defect: one `base` literal
    /// can't satisfy both an unprefixed SSR simulation and a prefixed real
    /// deploy). Emitted only when non-empty (`buildRenderRequest`), so an
    /// unprefixed site's request line stays byte-identical to one built
    /// before this field existed.
    ///
    /// Split out from `render` rather than widening it because `render`'s
    /// exact signature IS the duck-typed `renderer` interface
    /// `islands/pass.zig`'s `process`/`rewrite` call (and three test stubs
    /// there implement) — an island's SSR pathname is never routed, so
    /// threading a prefix through every island call site for a value only
    /// the SPA prerender pass (`src/spa.zig`, this function's only caller)
    /// needs would be pure churn. Do not fold this back into `render` "to
    /// clean it up" — that reintroduces exactly the churn this split avoids.
    pub fn renderPrefixed(
        self: *Sidecar,
        arena: RenderArena,
        src: []const u8,
        props_json: []const u8,
        slots_json: []const u8,
        pathname: []const u8,
        url_prefix: []const u8,
        err_out: ?*RenderError,
    ) ![]const u8 {
        // Resolve outside the lock: the CWD is fixed and `absSrc` touches no
        // shared state, so this stays out of the serialized critical section.
        const abs_src = try self.absSrc(arena, src);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = self.next_id;
        self.next_id += 1;

        const req_line = try buildRenderRequest(arena.a, id, abs_src, props_json, slots_json, pathname, url_prefix);
        try self.writeAll(req_line);

        // --- read one response line and parse
        // {"id":N,"html":"…"} | {"id":N,"error":"…","stack":"…"}
        const line = try self.readLine(arena);
        const Resp = struct {
            id: u64,
            html: ?[]const u8 = null,
            @"error": ?[]const u8 = null,
            // The sidecar's `err.stack` (source-mapped by Bun when a map is
            // available) — carried so the build can point at source lines.
            stack: ?[]const u8 = null,
        };
        const resp = try std.json.parseFromSliceLeaky(Resp, arena.a, line, .{ .ignore_unknown_fields = true });
        // The correlation id is the protocol's only integrity check: a stray
        // non-JSON line (e.g. a console.log from island code in dev) desyncs the
        // pipe and every later read is off by one. A mismatch means this line
        // belongs to a different request — fail loudly instead of attributing
        // one island's HTML to another (AUD-020).
        if (resp.id != id) return error.SidecarDesync;
        if (resp.@"error") |msg| {
            // Loud-fail via the returned error, but first hand the caller the
            // structured message + stack so it is surfaced with page/route
            // context rather than swallowed. (The Bun error text is
            // also on the sidecar's inherited stderr.) `msg`/`resp.stack` are
            // slices into the arena-owned `line`, valid for the caller's arena.
            if (err_out) |eo| eo.* = .{ .message = msg, .stack = resp.stack };
            return error.SidecarRenderFailed;
        }
        return resp.html orelse error.SidecarBadResponse;
    }

    /// Ask the sidecar to import `src` and return its `spa` + `routes`
    /// exports (metadata only, no rendering). Same request/response framing
    /// as `render` — and the same contract 4 (`RenderArena`) reason: every
    /// string in the returned `SpaDescribe` (and every `RouteMeta` in it) is a
    /// slice into the leak-parsed response line, not an owned buffer.
    pub fn describe(self: *Sidecar, arena: RenderArena, src: []const u8) !SpaDescribe {
        const abs_src = try self.absSrc(arena, src);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = self.next_id;
        self.next_id += 1;

        var req_aw: std.Io.Writer.Allocating = .init(arena.a);
        try std.json.Stringify.value(.{
            .id = id,
            .src = abs_src,
            .describe = true,
        }, .{}, &req_aw.writer);
        try req_aw.writer.writeAll("\n");
        try self.writeAll(req_aw.written());

        const line = try self.readLine(arena);
        const Resp = struct {
            id: u64,
            spa: ?SpaMeta = null,
            routes: ?[]const RouteMeta = null,
            @"error": ?[]const u8 = null,
        };
        const resp = try std.json.parseFromSliceLeaky(Resp, arena.a, line, .{ .ignore_unknown_fields = true });
        // A desynced pipe would parse a stale render response (no `spa`/`routes`)
        // as an all-null describe success → silently empty SPA metadata. Reject a
        // mismatched id instead of trusting the wrong line (AUD-020).
        if (resp.id != id) return error.SidecarDesync;
        if (resp.@"error") |e| {
            std.log.err("spa describe failed for {s}: {s}", .{ src, e });
            return error.SidecarDescribeFailed;
        }
        return .{ .spa = resp.spa orelse .{}, .routes = resp.routes orelse &.{} };
    }

    /// Kill the Bun process and reclaim resources. Idempotent.
    pub fn deinit(self: *Sidecar) void {
        self.child.kill(self.io);
    }
};

/// Structured detail of a failed island/SPA SSR render, filled by
/// `Sidecar.render` via its `err_out` param. Carried out of the Zig↔Bun NDJSON
/// boundary so the build can surface the JS message + (source-mapped) stack and
/// attribute them to the failing page/route — instead of collapsing to a bare
/// `error.SidecarRenderFailed`. Both strings are owned by the arena passed to
/// `render`.
pub const RenderError = struct {
    /// The sidecar's `err.message` (empty only when a non-render error, e.g. a
    /// malformed response, left `err_out` untouched — see `render`).
    message: []const u8 = "",
    /// The sidecar's `err.stack`, source-mapped by Bun when a map is available
    /// so line numbers point at source; null when the sidecar sent none.
    stack: ?[]const u8 = null,
};

/// `spa` config exported by a `.spa.tsx` module (see Task 3).
pub const SpaMeta = struct {
    base: ?[]const u8 = null,
    title: ?[]const u8 = null,
    noindex: ?bool = null,
    /// Structured `<link>` head-assets hook: each entry is one
    /// `<link>` tag's attribute map, lowered into every shell's `<head>` by
    /// `src/spa.zig`'s `renderHeadLinks`. `std.json.ArrayHashMap` (a thin
    /// wrapper over `StringArrayHashMapUnmanaged`) preserves the JSON key
    /// order within each entry, so a `{"rel":..,"href":..}` object renders
    /// its attributes in the order the site author wrote them. `describe`
    /// (`runtime/sidecar/render.ts`) passes `mod.spa` through verbatim, so
    /// no protocol change was needed beyond this field.
    head: ?[]const std.json.ArrayHashMap([]const u8) = null,
    /// Build-time feature-flag defaults: `export const spa =
    /// { flags: { bookAsGuest: true } }`. `src/spa.zig` snapshots these into
    /// every shell as a `data-z-flags` JSON data block so `useFlag`'s first
    /// client render is the declared default (no false-while-loading window).
    /// `std.json.ArrayHashMap` preserves the author's declaration order, so
    /// the emitted snapshot is deterministic. `describe`
    /// (`runtime/sidecar/render.ts`) validates values are booleans and passes
    /// `mod.spa` through verbatim — no protocol change beyond this field.
    flags: ?std.json.ArrayHashMap(bool) = null,
};

/// One entry of a `.spa.tsx` module's `routes` export, classified by the
/// sidecar (`dynamic` = has a `:param` or `*` segment; `hasSkeleton` = the
/// route provides a `skeleton` component).
pub const RouteMeta = struct {
    path: []const u8,
    dynamic: bool,
    hasSkeleton: bool,
    /// Concrete in-app paths enumerated by the route's `staticPaths` hook
    /// (describe resolves the hook; see runtime/src/router.ts
    /// `describeRoutes`). Only ever set on dynamic routes.
    staticPaths: ?[]const []const u8 = null,
    /// Declarative redirect target: the BASE-RELATIVE in-app path
    /// this route replace-navigates to instead of rendering a component.
    /// `src/spa.zig` validates every target against the same SPA's route
    /// table at build time — an unmatched target fails the build.
    redirect: ?[]const u8 = null,
};

/// Result of `Sidecar.describe`.
pub const SpaDescribe = struct {
    spa: SpaMeta,
    routes: []const RouteMeta,
};

test "buildRenderRequest emits \"prefix\" only when url_prefix is non-empty" {
    // Pins the wire format issue #26 adds — no live Bun process needed, since
    // `buildRenderRequest` is the pure seam factored out of `renderPrefixed`
    // precisely so this is testable at all.
    const gpa = std.testing.allocator;

    const with_prefix = try Sidecar.buildRenderRequest(gpa, 1, "/abs/App.island.tsx", "{}", "", "/myrepo/about", "/myrepo");
    defer gpa.free(with_prefix);
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"src\":\"/abs/App.island.tsx\",\"props\":{},\"pathname\":\"/myrepo/about\",\"prefix\":\"/myrepo\"}\n",
        with_prefix,
    );

    // Empty prefix: the field is absent entirely, not emitted as `"prefix":""`
    // — the no-op an unprefixed site's request line depends on.
    const without_prefix = try Sidecar.buildRenderRequest(gpa, 1, "/abs/App.island.tsx", "{}", "", "/about", "");
    defer gpa.free(without_prefix);
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"src\":\"/abs/App.island.tsx\",\"props\":{},\"pathname\":\"/about\"}\n",
        without_prefix,
    );

    // A non-empty slots payload still sits ahead of pathname/prefix, exactly
    // as it did before this field existed.
    const with_slots_and_prefix = try Sidecar.buildRenderRequest(gpa, 7, "/abs/Panel.island.tsx", "{}", "{\"default\":\"<p>x</p>\"}", "/myrepo/faq", "/myrepo");
    defer gpa.free(with_slots_and_prefix);
    try std.testing.expectEqualStrings(
        "{\"id\":7,\"src\":\"/abs/Panel.island.tsx\",\"props\":{},\"slots\":{\"default\":\"<p>x</p>\"},\"pathname\":\"/myrepo/faq\",\"prefix\":\"/myrepo\"}\n",
        with_slots_and_prefix,
    );
}

test "sidecar renders a TSX island to SSR HTML over NDJSON" {
    // Requires `bun` on PATH (mise) and `runtime/`'s deps installed
    // (`cd runtime && bun install`). Skips cleanly if bun is absent.
    const gpa = std.testing.allocator;
    // In test context, io is obtained via std.testing.io (not std.process.Init,
    // which is the main() entry-point struct). Both provide the same std.Io value.
    const io = std.testing.io;

    var sidecar = Sidecar.spawn(io, "bun", "runtime/sidecar/render.ts", "runtime") catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.SkipZigTest, // bun not installed
        else => return err,
    };
    defer sidecar.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const html = try sidecar.render(
        arena,
        "runtime/test/fixtures/Counter.island.tsx",
        "{\"start\":2,\"label\":\"hi\"}",
        "",
        "/",
        null,
    );
    try std.testing.expectEqualStrings("<button>hi: 2</button>", html);
}

test "sidecar surfaces a render error loudly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sidecar = Sidecar.spawn(io, "bun", "runtime/sidecar/render.ts", "runtime") catch return error.SkipZigTest;
    defer sidecar.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    // A non-existent island file -> the sidecar's import throws -> {error}.
    try std.testing.expectError(
        error.SidecarRenderFailed,
        sidecar.render(arena, "runtime/test/fixtures/does-not-exist.island.tsx", "{}", "", "/", null),
    );
}

test "sidecar captures the structured render error (message + stack) via err_out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sidecar = Sidecar.spawn(io, "bun", "runtime/sidecar/render.ts", "runtime") catch return error.SkipZigTest;
    defer sidecar.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // A non-existent island file -> the sidecar's import throws. `err_out` must
    // receive the JS message (and, for a real thrown Error, a stack) instead of
    // the caller only seeing the bare error name.
    var rerr: RenderError = .{};
    try std.testing.expectError(
        error.SidecarRenderFailed,
        sidecar.render(arena, "runtime/test/fixtures/does-not-exist.island.tsx", "{}", "", "/", &rerr),
    );
    // The message is populated and non-empty (its exact text is Bun's import
    // error, which we don't pin); the stack, when present, is a real trace.
    try std.testing.expect(rerr.message.len > 0);
    if (rerr.stack) |s| try std.testing.expect(s.len > 0);
}

test "SpaMeta JSON parse: a describe-shaped payload with head parses, preserving per-entry key order" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Same response shape `Sidecar.describe` parses (id/spa/routes/error), with
    // a `spa.head` of two <link> entries — the second's keys deliberately out
    // of "natural" order to prove ArrayHashMap preserves JSON source order,
    // not some canonical ordering.
    const payload =
        \\{"id":1,"spa":{"base":"/app","title":"T","noindex":true,"head":[{"rel":"stylesheet","href":"/a.css"},{"crossorigin":"","rel":"preconnect","href":"https://fonts.example.com"}]},"routes":[]}
    ;
    const Resp = struct {
        id: u64,
        spa: ?SpaMeta = null,
        routes: ?[]const RouteMeta = null,
        @"error": ?[]const u8 = null,
    };
    const resp = try std.json.parseFromSliceLeaky(Resp, arena, payload, .{ .ignore_unknown_fields = true });
    const head = resp.spa.?.head.?;
    try std.testing.expectEqual(@as(usize, 2), head.len);

    try std.testing.expectEqualStrings("stylesheet", head[0].map.get("rel").?);
    try std.testing.expectEqualStrings("/a.css", head[0].map.get("href").?);

    // Entry 2's keys were written crossorigin, rel, href — the iterator must
    // yield them in that exact source order.
    var it = head[1].map.iterator();
    const k1 = it.next().?;
    try std.testing.expectEqualStrings("crossorigin", k1.key_ptr.*);
    const k2 = it.next().?;
    try std.testing.expectEqualStrings("rel", k2.key_ptr.*);
    const k3 = it.next().?;
    try std.testing.expectEqualStrings("href", k3.key_ptr.*);
    try std.testing.expect(it.next() == null);
}

test "SpaMeta JSON parse: spa.flags parses as an order-preserving name→bool map" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const payload =
        \\{"id":1,"spa":{"base":"/app","flags":{"bookAsGuest":true,"promoBanner":false}},"routes":[]}
    ;
    const Resp = struct {
        id: u64,
        spa: ?SpaMeta = null,
        routes: ?[]const RouteMeta = null,
        @"error": ?[]const u8 = null,
    };
    const resp = try std.json.parseFromSliceLeaky(Resp, arena, payload, .{ .ignore_unknown_fields = true });
    const flags = resp.spa.?.flags.?;
    try std.testing.expectEqual(@as(usize, 2), flags.map.count());
    try std.testing.expectEqual(true, flags.map.get("bookAsGuest").?);
    try std.testing.expectEqual(false, flags.map.get("promoBanner").?);
    // Declaration order is preserved (the snapshot emitter depends on it for
    // deterministic shell bytes).
    var it = flags.map.iterator();
    try std.testing.expectEqualStrings("bookAsGuest", it.next().?.key_ptr.*);
    try std.testing.expectEqualStrings("promoBanner", it.next().?.key_ptr.*);
    try std.testing.expect(it.next() == null);
}

test "concurrent renders against one Sidecar stay correct (mutex serializes)" {
    // Drives render() from 8 OS threads against ONE shared Sidecar to empirically
    // prove that std.Io.Mutex serializes access across std.Thread-spawned OS threads —
    // the real zigapagos build model (thread-pool of page renderers, one shared Sidecar).
    // Under -Dsingle-threaded there are no OS threads to race (and Thread.spawn
    // is a compile error), so skip — the property being proven cannot exist.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const io = std.testing.io;

    var sidecar = Sidecar.spawn(io, "bun", "runtime/sidecar/render.ts", "runtime") catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.SkipZigTest, // bun not installed
        else => return err,
    };
    defer sidecar.deinit();

    const Worker = struct {
        fn run(sc: *Sidecar, n: usize, ok: *std.atomic.Value(usize)) void {
            var buf: [64]u8 = undefined;
            // Each thread gets its own arena; the Sidecar itself is shared.
            var a_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer a_state.deinit();
            const arena = RenderArena.from(&a_state);
            const props = std.fmt.bufPrint(&buf, "{{\"start\":{d},\"label\":\"t\"}}", .{n}) catch return;
            const html = sc.render(arena, "runtime/test/fixtures/Counter.island.tsx", props, "", "/", null) catch return;
            const want = std.fmt.allocPrint(arena.a, "<button>t: {d}</button>", .{n}) catch return;
            if (std.mem.eql(u8, html, want)) _ = ok.fetchAdd(1, .monotonic);
        }
    };

    var ok = std.atomic.Value(usize).init(0);
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |t| t.join();
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &sidecar, i, &ok });
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();
    spawned = 0; // disarm: all joined; errdefer must not join them again
    try std.testing.expectEqual(@as(usize, 8), ok.load(.monotonic));
}

test "sidecar applies z-runtime.config.json resolve overrides (react -> compat + custom specifier)" {
    // Spawning the sidecar with project_root = a site that declares
    // npmCompat (=> react->@z/runtime/compat DEFAULTS) and a custom `resolve`
    // entry must let an island import bare `react` and `@acme/greeting` with no
    // tsconfig `paths` and no shim symlinks — the ONE-Preact invariant as config.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var sidecar = Sidecar.spawn(
        io,
        "bun",
        "runtime/sidecar/render.ts",
        "runtime/test/fixtures/resolve-site",
    ) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.SkipZigTest, // bun not installed
        else => return err,
    };
    defer sidecar.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const html = try sidecar.render(
        arena,
        "runtime/test/fixtures/resolve-site/ReactCounter.island.tsx",
        "{\"label\":\"hi\"}",
        "",
        "/",
        null,
    );
    try std.testing.expectEqualStrings("<button>hi: 7 (hello-from-override) [cjs-react-ok] [legacy-fn-ok]</button>", html);
}

test "sidecar resolves @z/site-data from the site's z-runtime.config.json data map" {
    // With project_root = a site whose config declares
    // `data: { services: "content/services/*.smd", hours: "content/hours.json" }`,
    // an island's `import site from "@z/site-data"` resolves to a JSON module
    // built from the content pipeline at sidecar startup — no codegen script,
    // no tracked generated file.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var sidecar = Sidecar.spawn(
        io,
        "bun",
        "runtime/sidecar/render.ts",
        "runtime/test/fixtures/data-site",
    ) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.SkipZigTest, // bun not installed
        else => return err,
    };
    defer sidecar.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const html = try sidecar.render(
        arena,
        "runtime/test/fixtures/data-site/SiteData.island.tsx",
        "{}",
        "",
        "/",
        null,
    );
    try std.testing.expectEqualStrings("<p>Alpha Service / mon 9-5 / 2 services</p>", html);
}

test "sidecar weaves slots into Panel island HTML" {
    // Requires `bun` on PATH (mise) and `runtime/`'s deps installed.
    // Skips cleanly if bun is absent.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var sidecar = Sidecar.spawn(io, "bun", "runtime/sidecar/render.ts", "runtime") catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.SkipZigTest, // bun not installed
        else => return err,
    };
    defer sidecar.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // Resolve Panel fixture to absolute path the same way existing tests resolve Counter.
    const cwd_str = try std.process.currentPathAlloc(io, arena.a);
    const panel_abs = try std.fs.path.resolve(arena.a, &.{ cwd_str, "runtime/test/fixtures/Panel.island.tsx" });

    const html = try sidecar.render(
        arena,
        panel_abs,
        "{\"title\":\"FAQ\"}",
        "{\"default\":\"<p>body</p>\",\"heading\":\"<h2>Q</h2>\"}",
        "/",
        null,
    );

    // The bun sidecar (Task 2) weaves slots into z-slot wrapper elements.
    try std.testing.expect(std.mem.indexOf(u8, html, "<z-slot data-z-slot=\"heading\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>Q</h2>") != null);
}
