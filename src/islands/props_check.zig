const std = @import("std");
const Io = std.Io;
const RenderArena = @import("render_arena.zig").RenderArena;

const log = std.log.scoped(.island_props);

pub const Mode = enum { off, warn, err };

pub fn parseMode(s: []const u8) ?Mode {
    if (std.mem.eql(u8, s, "off")) return .off;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "error")) return .err;
    return null;
}

/// One rendered island instance's resolved props, recorded for the contract check.
/// All fields are owned by whatever allocator the collector duped them with.
pub const PropsCheck = struct {
    src: []const u8, // relative, e.g. "components/Hero.island.tsx"
    props_json: []const u8, // resolved, script-escaped JSON
    page_url: []const u8, // e.g. "/about/" — for the diagnostic
    island_id: []const u8, // "z-island-3" — for the diagnostic
};

/// Lightweight text scan for an EXPORTED `Props` symbol (the contract convention,
/// matching `zigapagos migrate` output and the canonical islands). Mirrors the no-npm
/// lint's text-scan approach — deliberately avoids pulling in the TS compiler API.
pub fn hasExportedProps(source: []const u8) bool {
    if (std.mem.indexOf(u8, source, "export interface Props") != null) return true;
    if (std.mem.indexOf(u8, source, "export type Props") != null) return true;
    // `export { ... Props ... }` re-export form.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "export {")) |open| {
        const close = std.mem.indexOfScalarPos(u8, source, open, '}') orelse break;
        const list = source[open + "export {".len .. close];
        var it = std.mem.tokenizeAny(u8, list, " ,\t\r\n");
        while (it.next()) |tok| if (std.mem.eql(u8, tok, "Props")) return true;
        i = close + 1;
    }
    return false;
}

pub const Program = struct {
    source: []const u8,
    /// `line_to_check[n]` (0-based n -> 1-based line n+1) is the deduped-check
    /// index whose `const` occupies that generated line, or null otherwise.
    line_to_check: []const ?usize,
};

/// Build the single synthetic TS program. `abs_srcs[k]` is the resolved absolute
/// path for `checks[k].src`. Dedups: one `import type { Props as Pk }` per unique
/// abs_src, one `const _N: Pk = <json>;` per unique (abs_src, props_json) pair.
///
/// NO_SLOP.md §2.2a contract 4 (`RenderArena`): a `Program` is two allocations
/// (`source` is an ArrayList's items, `line_to_check` a parallel array) with no
/// `deinit`, and building it leaves five more live containers behind — the alias
/// table, the seen-pair set and its composite keys, and the two fragment buffers
/// `source` is assembled from (1). Freeing those individually would mean
/// deiniting five collections whose contents are all dead the moment `source` is
/// concatenated (2), and the whole thing dies with the props-check run that owns
/// the arena in `run` (3).
pub fn generateProgram(
    arena: RenderArena,
    abs_srcs: []const []const u8,
    checks: []const PropsCheck,
) !Program {
    std.debug.assert(abs_srcs.len == checks.len);

    // Unique abs_src -> alias index.
    var alias_of: std.StringArrayHashMapUnmanaged(usize) = .empty;
    // Unique "abs_src\x00props_json" -> already-emitted (so dedup const lines).
    var seen_pair: std.StringHashMapUnmanaged(void) = .empty;

    var imports: std.ArrayListUnmanaged(u8) = .empty;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    // Each emitted const remembers which `checks` index it represents.
    var const_check_idx: std.ArrayListUnmanaged(usize) = .empty;

    for (abs_srcs, checks, 0..) |abs, chk, idx| {
        const gop = try alias_of.getOrPut(arena.a, abs);
        if (!gop.found_existing) {
            gop.value_ptr.* = alias_of.count() - 1;
            try imports.print(arena.a, "import type {{ Props as P{d} }} from \"{s}\";\n", .{ gop.value_ptr.*, abs });
        }
        const alias = gop.value_ptr.*;

        const pair_key = try std.fmt.allocPrint(arena.a, "{s}\x00{s}", .{ abs, chk.props_json });
        if (try seen_pair.fetchPut(arena.a, pair_key, {}) != null) continue; // dup pair

        const n = const_check_idx.items.len;
        try body.print(arena.a, "const _{d}: P{d} = {s};\n", .{ n, alias, chk.props_json });
        try const_check_idx.append(arena.a, idx);
    }

    // Layout: imports block, blank line, then one const per line. Track lines.
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(arena.a, imports.items);
    try source.append(arena.a, '\n');
    const body_first_line = std.mem.count(u8, source.items, "\n") + 1; // 1-based line of first const

    try source.appendSlice(arena.a, body.items);

    const total_lines = std.mem.count(u8, source.items, "\n");
    const map = try arena.a.alloc(?usize, total_lines);
    @memset(map, null);
    for (const_check_idx.items, 0..) |chk_idx, n| {
        map[body_first_line - 1 + n] = chk_idx;
    }

    return .{ .source = source.items, .line_to_check = map };
}

/// The generated tsconfig: extends the website tsconfig (so jsxImportSource +
/// moduleResolution match how the islands already typecheck), restricts the
/// program to our generated file, and turns on the options the check needs.
/// Contract 1: one `allocPrint` out, nothing else allocated.
pub fn generateTsconfig(
    alloc: std.mem.Allocator,
    base_tsconfig_abs: []const u8,
    program_abs: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "extends": "{s}",
        \\  "compilerOptions": {{
        \\    "noEmit": true,
        \\    "skipLibCheck": true,
        \\    "allowImportingTsExtensions": true,
        \\    "module": "esnext"
        \\  }},
        \\  "include": ["{s}"]
        \\}}
        \\
    , .{ base_tsconfig_abs, program_abs });
}

pub const Diag = struct { line: usize, col: usize, code: []const u8, message: []const u8 };

/// Parse `--pretty false` tsc stdout, keeping only error lines for our program.
/// Format: `<basename>(L,C): error TSxxxx: message`. (Subsequent indented lines
/// of a multi-line message are ignored in v1; the TSxxxx headline is sufficient.)
/// NO_SLOP.md §2.2a contract 4 (`RenderArena`): the returned slice owns a duped
/// `code` and `message` per diagnostic with no `deinit` (1); every one of them is
/// read once, in the loop that formats the mismatch messages, so per-field frees
/// would be bookkeeping (2) and they die with the props-check run (3).
pub fn parseDiagnostics(
    arena: RenderArena,
    stdout: []const u8,
    program_basename: []const u8,
) ![]const Diag {
    var diags: std.ArrayListUnmanaged(Diag) = .empty;
    const prefix = try std.fmt.allocPrint(arena.a, "{s}(", .{program_basename});
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const lparen = prefix.len; // first char after "basename("
        const comma = std.mem.indexOfScalarPos(u8, line, lparen, ',') orelse continue;
        const rparen = std.mem.indexOfScalarPos(u8, line, comma, ')') orelse continue;
        const ln = std.fmt.parseInt(usize, line[lparen..comma], 10) catch continue;
        const col = std.fmt.parseInt(usize, line[comma + 1 .. rparen], 10) catch continue;
        // After "): " expect "error TSxxxx: msg".
        const tail = line[rparen + 1 ..];
        const err_kw = std.mem.indexOf(u8, tail, "error TS") orelse continue;
        const code_start = err_kw + "error ".len;
        const colon = std.mem.indexOfScalarPos(u8, tail, code_start, ':') orelse continue;
        const code = tail[code_start..colon];
        const message = std.mem.trim(u8, tail[colon + 1 ..], " \t\r");
        try diags.append(arena.a, .{ .line = ln, .col = col, .code = try arena.a.dupe(u8, code), .message = try arena.a.dupe(u8, message) });
    }
    return diags.toOwnedSlice(arena.a);
}

/// Contract 1: one `allocPrint` out.
pub fn formatDiagnostic(alloc: std.mem.Allocator, diag: Diag, check: PropsCheck) ![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "props mismatch on {s}  <island src=\"{s}\" id=\"{s}\">\n" ++
            "  resolved props: {s}\n" ++
            "  {s} ({s})",
        .{ check.page_url, check.src, check.island_id, check.props_json, diag.message, diag.code },
    );
}

pub const RunResult = struct { checked: usize, skipped_no_props: usize, mismatches: usize };

pub const RunOptions = struct {
    mode: Mode,
    bun_path: []const u8,
    website_root: []const u8,
};

pub fn run(io: Io, gpa: std.mem.Allocator, checks: []const PropsCheck, opts: RunOptions) !RunResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // The props-check run is one arena-scoped pass (NO_SLOP.md §2.2a): the
    // generated program and the parsed diagnostics are graphs it reclaims whole.
    const arena = RenderArena.from(&arena_state);

    if (checks.len == 0) return .{ .checked = 0, .skipped_no_props = 0, .mismatches = 0 };

    // Resolve website_root to absolute (tsconfig + src imports must be absolute).
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n_root = try std.Io.Dir.cwd().realPathFile(io, opts.website_root, &root_buf);
    const root_abs = root_buf[0..n_root];

    // Resolve each src to absolute; cache per-src "has exported Props".
    var props_ok: std.StringHashMapUnmanaged(bool) = .empty;
    var abs_srcs: std.ArrayListUnmanaged([]const u8) = .empty;
    var kept: std.ArrayListUnmanaged(PropsCheck) = .empty;
    var skipped: usize = 0;

    for (checks) |chk| {
        const abs = try std.fs.path.resolve(arena.a, &.{ root_abs, chk.src });
        const gop = try props_ok.getOrPut(arena.a, abs);
        if (!gop.found_existing) {
            const source = std.Io.Dir.cwd().readFileAlloc(io, abs, arena.a, .limited(1 << 20)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => "",
            };
            gop.value_ptr.* = hasExportedProps(source);
            if (!gop.value_ptr.*) log.warn("island {s} has no exported Props type; props unchecked", .{chk.src});
        }
        if (!gop.value_ptr.*) {
            skipped += 1;
            continue;
        }
        try abs_srcs.append(arena.a, abs);
        try kept.append(arena.a, chk);
    }

    if (kept.items.len == 0) return .{ .checked = 0, .skipped_no_props = skipped, .mismatches = 0 };

    const program = try generateProgram(arena, abs_srcs.items, kept.items);

    // Write program + tsconfig under <root>/.zigapagos-cache/props-check/.
    const tmp_rel = ".zigapagos-cache/props-check";
    const tmp_dir_abs = try std.fs.path.join(arena.a, &.{ root_abs, tmp_rel });
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir_abs);

    const program_basename = "__island_props_check.tsx";
    // tsc outputs paths relative to its cwd (website_root), so the prefix in its
    // output will be "<tmp_rel>/<program_basename>", not just the basename.
    const program_rel = try std.fs.path.join(arena.a, &.{ tmp_rel, program_basename });
    const program_abs = try std.fs.path.join(arena.a, &.{ tmp_dir_abs, program_basename });
    const tsconfig_abs = try std.fs.path.join(arena.a, &.{ tmp_dir_abs, "tsconfig.props-check.json" });
    const base_tsconfig_abs = try std.fs.path.join(arena.a, &.{ root_abs, "tsconfig.json" });

    try writeFileAbs(io, program_abs, program.source);
    try writeFileAbs(io, tsconfig_abs, try generateTsconfig(arena.a, base_tsconfig_abs, program_abs));

    // Spawn `<bun> x tsc -p <tsconfig> --pretty false` with cwd = website_root.
    var child = try std.process.spawn(io, .{
        .argv = &.{ opts.bun_path, "x", "tsc", "-p", tsconfig_abs, "--pretty", "false" },
        .stdin = .ignore,
        .stdout = .pipe,
        .cwd = .{ .path = root_abs },
    });

    // Read stdout to EOF.
    var rbuf: [4096]u8 = undefined;
    var fr = child.stdout.?.reader(io, &rbuf);
    var out_aw: std.Io.Writer.Allocating = .init(arena.a);
    _ = fr.interface.streamRemaining(&out_aw.writer) catch {};
    const stdout = out_aw.written();
    // Capture tsc exit status; treat wait errors and non-exited terms as anomalous.
    const tsc_exit: ?u8 = if (child.wait(io)) |term| switch (term) {
        .exited => |code| code,
        else => null,
    } else |_| null;

    const diags = try parseDiagnostics(arena, stdout, program_rel);

    var mismatches: usize = 0;
    for (diags) |d| {
        const check_idx = if (d.line >= 1 and d.line <= program.line_to_check.len)
            program.line_to_check[d.line - 1]
        else
            null;
        if (check_idx) |ci| {
            const msg = try formatDiagnostic(arena.a, d, kept.items[ci]);
            switch (opts.mode) {
                .err => log.err("{s}", .{msg}),
                .warn => log.warn("{s}", .{msg}),
                .off => unreachable,
            }
            mismatches += 1;
        } else {
            // A diagnostic not on a const line (e.g. a program/import error). Surface raw.
            switch (opts.mode) {
                .err => log.err("props-check program error: {s}({d},{d}): {s} ({s})", .{ program_rel, d.line, d.col, d.message, d.code }),
                .warn => log.warn("props-check program error: {s}({d},{d}): {s} ({s})", .{ program_rel, d.line, d.col, d.message, d.code }),
                .off => unreachable,
            }
            mismatches += 1;
        }
    }

    // Anomaly guard: tsc is unhappy but nothing mapped to a known island.
    // Only treat as a true anomaly when stdout contains NO recognizable tsc diagnostic
    // lines at all (pattern "): error TS"). Pre-existing errors in imported source files
    // produce tsc-format lines but not from our synthetic program — those are NOT an
    // anomaly since our check was clean. The guard catches crashes, tsconfig parse
    // errors, launcher failures, and completely unexpected output formats.
    if (mismatches == 0 and (tsc_exit == null or tsc_exit.? != 0)) {
        const has_any_tsc_diag = std.mem.indexOf(u8, stdout, "): error TS") != null;
        if (!has_any_tsc_diag) {
            const exit_repr: u8 = tsc_exit orelse 255; // 255 = signal/wait-error sentinel
            const snippet_len = @min(500, stdout.len);
            switch (opts.mode) {
                .err => {
                    log.err(
                        "props-check: tsc exited non-zero ({d}) but no diagnostics mapped to a known island — " ++
                            "its output format may have changed or the program failed to compile\nstdout: {s}",
                        .{ exit_repr, stdout[0..snippet_len] },
                    );
                    mismatches += 1;
                },
                .warn => log.warn(
                    "props-check: tsc exited non-zero ({d}) but no diagnostics mapped to a known island — " ++
                        "its output format may have changed or the program failed to compile\nstdout: {s}",
                    .{ exit_repr, stdout[0..snippet_len] },
                ),
                .off => unreachable,
            }
        }
    }

    return .{ .checked = kept.items.len, .skipped_no_props = skipped, .mismatches = mismatches };
}

fn writeFileAbs(io: Io, abs_path: []const u8, bytes: []const u8) !void {
    const dir = std.fs.path.dirname(abs_path) orelse "/";
    const base = std.fs.path.basename(abs_path);
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, base, .{});
    defer f.close(io);
    var fw = f.writerStreaming(io, &.{});
    try fw.interface.writeAll(bytes);
}

test "parseMode maps the three CLI values and rejects others" {
    try std.testing.expectEqual(Mode.off, parseMode("off").?);
    try std.testing.expectEqual(Mode.warn, parseMode("warn").?);
    try std.testing.expectEqual(Mode.err, parseMode("error").?);
    try std.testing.expect(parseMode("nope") == null);
}

test "hasExportedProps detects the three contract forms and rejects absence" {
    try std.testing.expect(hasExportedProps("export interface Props { a: string }"));
    try std.testing.expect(hasExportedProps("export type Props = { a: string }"));
    try std.testing.expect(hasExportedProps("type Props = {}; export { Props }"));
    // non-exported, or differently-named, is not a contract:
    try std.testing.expect(!hasExportedProps("interface Props { a: string }"));
    try std.testing.expect(!hasExportedProps("export interface HeroProps { a: string }"));
    try std.testing.expect(!hasExportedProps("export default function X() {}"));
}

test "generateProgram: one import per unique src, one const per unique (src,json), line map points at consts" {
    // `generateProgram` is contract 4, so this test keeps a real arena — see
    // scripts/allocator-allowlist.txt for why.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const abs = [_][]const u8{
        "/w/components/Hero.island.tsx",
        "/w/components/Hero.island.tsx", // dup src, distinct json -> shares import
        "/w/components/Counter.island.tsx",
    };
    const checks = [_]PropsCheck{
        .{ .src = "components/Hero.island.tsx", .props_json = "{\"headline\":\"A\"}", .page_url = "/", .island_id = "z-island-0" },
        .{ .src = "components/Hero.island.tsx", .props_json = "{\"headline\":\"B\"}", .page_url = "/about/", .island_id = "z-island-1" },
        .{ .src = "components/Counter.island.tsx", .props_json = "{\"start\":2}", .page_url = "/", .island_id = "z-island-2" },
    };

    const prog = try generateProgram(arena, &abs, &checks);

    // Two unique srcs -> two `import type` lines (aliased P0, P1).
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, prog.source, "import type {"));
    try std.testing.expect(std.mem.indexOf(u8, prog.source, "from \"/w/components/Hero.island.tsx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog.source, "from \"/w/components/Counter.island.tsx\"") != null);
    // Three unique (src,json) -> three const assignments, each pinned to its alias.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, prog.source, "const _"));
    try std.testing.expect(std.mem.indexOf(u8, prog.source, "= {\"headline\":\"A\"};") != null);
    try std.testing.expect(std.mem.indexOf(u8, prog.source, "= {\"start\":2};") != null);

    // line_to_check: exactly 3 non-null entries, each a valid check index.
    var consts: usize = 0;
    for (prog.line_to_check) |maybe| if (maybe) |idx| {
        try std.testing.expect(idx < checks.len);
        consts += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), consts);
}

test "generateProgram: script-escaped props embed verbatim and dedup collapses identical pairs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const abs = [_][]const u8{ "/w/Hero.tsx", "/w/Hero.tsx" };
    const checks = [_]PropsCheck{
        .{ .src = "Hero.tsx", .props_json = "{\"headline\":\"\\u003Cb\\u003E\"}", .page_url = "/", .island_id = "z-island-0" },
        .{ .src = "Hero.tsx", .props_json = "{\"headline\":\"\\u003Cb\\u003E\"}", .page_url = "/x/", .island_id = "z-island-9" },
    };
    const prog = try generateProgram(arena, &abs, &checks);
    // Identical (src,json) on two pages -> a single const, single import.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, prog.source, "const _"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, prog.source, "import type {"));
    // The < escapes survive verbatim into the TS literal.
    try std.testing.expect(std.mem.indexOf(u8, prog.source, "\\u003Cb\\u003E") != null);
}

test "generateTsconfig: extends base, includes the program, sets the required options" {
    // Contract 1: raw testing allocator, leak detection ON.
    const gpa = std.testing.allocator;
    const cfg = try generateTsconfig(gpa, "/w/tsconfig.json", "/tmp/zc/__island_props_check.tsx");
    defer gpa.free(cfg);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"extends\": \"/w/tsconfig.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"noEmit\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"skipLibCheck\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"allowImportingTsExtensions\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "/tmp/zc/__island_props_check.tsx") != null);
}

test "parseDiagnostics extracts only this program's error lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const stdout =
        "__island_props_check.tsx(4,8): error TS2741: Property 'label' is missing in type '{ start: number; }' but required in type 'Props'.\n" ++
        "__island_props_check.tsx(7,8): error TS2322: Type 'number' is not assignable to type 'string'.\n" ++
        "some/other/file.ts(1,1): error TS1005: ';' expected.\n" ++ // different file -> ignored
        "Found 2 errors.\n";

    const diags = try parseDiagnostics(arena, stdout, "__island_props_check.tsx");
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(usize, 4), diags[0].line);
    try std.testing.expectEqual(@as(usize, 8), diags[0].col);
    try std.testing.expectEqualStrings("TS2741", diags[0].code);
    try std.testing.expect(std.mem.indexOf(u8, diags[0].message, "Property 'label' is missing") != null);
    try std.testing.expectEqualStrings("TS2322", diags[1].code);
}

test "formatDiagnostic renders the engine-level message with page+src+id+json" {
    const gpa = std.testing.allocator;
    const diag = Diag{ .line = 4, .col = 8, .code = "TS2741", .message = "Property 'label' is missing in type '{ start: number; }' but required in type 'Props'." };
    const chk = PropsCheck{ .src = "components/Counter.island.tsx", .props_json = "{\"start\":2}", .page_url = "/", .island_id = "z-island-0" };
    const msg = try formatDiagnostic(gpa, diag, chk);
    defer gpa.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "props mismatch on /") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "components/Counter.island.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "z-island-0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "{\"start\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "(TS2741)") != null);
}

test "run: a type-mismatched prop is reported as a mismatch (needs bun+tsc)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // Use the tsx-site fixtures as the island source of truth: Hero.island.tsx
    // declares `export interface Props { headline: string }`.
    const root = "examples/tsx-site";
    // Skip if the fixture's node_modules/typescript isn't installed.
    std.Io.Dir.cwd().access(io, root ++ "/node_modules/typescript", .{}) catch return error.SkipZigTest;

    const checks = [_]PropsCheck{
        // OK: headline is a string.
        .{ .src = "components/Hero.island.tsx", .props_json = "{\"headline\":\"hi\"}", .page_url = "/", .island_id = "z-island-0" },
        // BAD: headline is a number -> TS2322.
        .{ .src = "components/Hero.island.tsx", .props_json = "{\"headline\":5}", .page_url = "/bad/", .island_id = "z-island-1" },
    };

    // Use .warn mode so the mismatch is logged at warn level (log.err in test mode
    // increments the test runner's error counter and causes the binary to exit 1).
    const result = run(io, gpa, &checks, .{ .mode = .warn, .bun_path = "bun", .website_root = root }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.SkipZigTest, // bun absent
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 1), result.mismatches);
}
