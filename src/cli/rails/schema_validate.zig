//! Stage 4 Phase 2 fix round, item 1: a minimal, dependency-free JSON
//! Schema INSTANCE validator, and the `rails_manifest_validate` CLI that
//! wires it into `tests/migrate/rails.sh`.
//!
//! ## Why this exists at all
//!
//! `schema_gen.zig`'s own tests only prove the generator is SELF-consistent
//! (it produces well-formed JSON, its own re-derivation is byte-stable,
//! ...). `manifestGoldenBytes` (`manifest.zig`) only proves one HAND-BUILT
//! instance with `"assets": []` matches the emitter's own output -- and
//! that instance structurally cannot contain the one field the branch's
//! shipping defect (phase-2-review.md F1: `nullableOf` widening `type` but
//! not the sibling `enum`) broke on. Neither check ever asks the
//! consumer-side question this file answers: does a REAL manifest, from
//! the REAL fixture, actually validate against the schema this tool
//! publishes? "We already validate somewhere" turned out to be false in
//! the way that mattered (Ruling 17, progress.md) -- a validator that never
//! sees the shape is not coverage.
//!
//! ## Why hand-rolled rather than a real JSON Schema library
//!
//! `mise.toml` pins zig and bun ONLY (CLAUDE.md: "the single source of
//! truth"); this repo's CI job for `tests/migrate/rails.sh` installs
//! neither Python nor a JS package manager step for it. A dependency on
//! `pip install jsonschema` (or an npm `ajv`) would be invisible in this
//! file and this directory's std-only constraint, but it would still be a
//! new toolchain dependency this project has been deliberately unwilling
//! to add elsewhere (see CLAUDE.md's mise.toml section) -- and worse, a
//! SILENT one: if that install step were ever skipped or the package
//! unavailable, the "validation" would either fail the whole build for an
//! unrelated reason or (if written defensively) skip quietly, which is
//! exactly the "asserting conformance you cannot test" failure mode this
//! file exists to close, not reproduce.
//!
//! This validator is therefore scoped EXACTLY to the JSON Schema keyword
//! subset `schema_gen.zig` ever emits -- `type` (a string or an array of
//! strings), `enum`, and for objects `properties` + `required` +
//! `additionalProperties: false`, and for arrays `items` -- nothing more.
//! It is not a general-purpose JSON Schema engine (no `$ref`, no `anyOf`,
//! no `minimum`/`maxLength`/pattern keywords), because the schema it
//! validates against never emits those either; growing either file to use
//! a keyword the other doesn't handle is meant to be a visible, deliberate
//! change to both, not a silent gap. It is written independently of
//! `schemaFor`/`nullableOf`'s own logic (reads the schema as plain JSON
//! data, the same way a real external validator would), so it is not
//! merely proving the generator agrees with itself.
//!
//! std-only, like every file in `src/cli/rails/` (see `manifest.zig`'s
//! module doc): no `@import` here escapes this directory.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Contract 2 (owned-result): every string in the returned slice is a
/// fresh `gpa` allocation (built via `std.fmt.allocPrint`); the slice
/// itself is also `gpa`-owned. Release both with `freeErrors`. An empty
/// slice means `instance` validates against `schema`.
///
/// `path` accumulates the current JSON-Pointer-shaped location
/// (`/assets/2/pipeline`) across the recursion below; passed in empty by
/// callers, since the root instance has no name of its own.
pub fn validate(gpa: Allocator, schema: std.json.Value, instance: std.json.Value) Allocator.Error![]const []const u8 {
    var errors: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (errors.items) |e| gpa.free(e);
        errors.deinit(gpa);
    }
    var path: std.ArrayListUnmanaged(u8) = .empty;
    defer path.deinit(gpa);

    try validateNode(gpa, schema, instance, &path, &errors);
    return try errors.toOwnedSlice(gpa);
}

pub fn freeErrors(gpa: Allocator, errs: []const []const u8) void {
    for (errs) |e| gpa.free(e);
    gpa.free(errs);
}

/// Not an independent contract-1/2/3/4 surface (NO_SLOP.md §2.2a): this and
/// `validateNode` below are `validate`'s own private implementation, always
/// called with `validate`'s own `gpa` and `validate`'s own `errors`/`path`
/// -- the same relationship `schema_gen.zig`'s `simpleType` doc describes
/// between itself and `generate`. Every allocation either function causes
/// (a path-segment append, an owned error string) becomes part of
/// `validate`'s Contract 2 result or is cleaned up by `validate`'s own
/// `errdefer`/`defer`; neither function frees or returns anything on its
/// own account.
fn addError(
    gpa: Allocator,
    errors: *std.ArrayListUnmanaged([]const u8),
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const shown_path = if (path.len == 0) "/" else path;
    const msg = try std.fmt.allocPrint(gpa, "{s}: " ++ fmt, .{shown_path} ++ args);
    try errors.append(gpa, msg);
}

/// `validate`'s private implementation (see `addError`'s doc, just above,
/// for the ownership relationship both share). Recurses through
/// `schema`/`instance` in lockstep, appending one owned string per
/// violation found to `errors` and one path segment at a time to `path`
/// (restored to its entry length before returning from each frame, so
/// sibling calls never see a stale suffix).
fn validateNode(
    gpa: Allocator,
    schema: std.json.Value,
    instance: std.json.Value,
    path: *std.ArrayListUnmanaged(u8),
    errors: *std.ArrayListUnmanaged([]const u8),
) Allocator.Error!void {
    const s = schema.object;

    if (s.get("type")) |type_val| {
        if (!typeMatches(type_val, instance)) {
            try addError(gpa, errors, path.items, "expected type {s}, got {s}", .{ typeDesc(type_val), instanceTypeName(instance) });
            // No point checking `enum`/`properties`/`items` against a value
            // that is already the wrong shape.
            return;
        }
    }

    if (s.get("enum")) |enum_val| {
        var found = false;
        for (enum_val.array.items) |member| {
            if (jsonEql(member, instance)) {
                found = true;
                break;
            }
        }
        if (!found) try addError(gpa, errors, path.items, "value not in enum", .{});
    }

    switch (instance) {
        .object => |obj| {
            const props: ?std.json.ObjectMap = if (s.get("properties")) |p| p.object else null;
            const additional_ok = if (s.get("additionalProperties")) |ap| !(ap == .bool and !ap.bool) else true;

            var it = obj.iterator();
            while (it.next()) |kv| {
                const before = path.items.len;
                try path.appendSlice(gpa, "/");
                try path.appendSlice(gpa, kv.key_ptr.*);

                if (props != null and props.?.get(kv.key_ptr.*) != null) {
                    try validateNode(gpa, props.?.get(kv.key_ptr.*).?, kv.value_ptr.*, path, errors);
                } else if (!additional_ok) {
                    try addError(gpa, errors, path.items, "additional property not allowed", .{});
                }

                path.shrinkRetainingCapacity(before);
            }

            if (s.get("required")) |req_val| {
                for (req_val.array.items) |r| {
                    if (!obj.contains(r.string)) {
                        try addError(gpa, errors, path.items, "missing required property '{s}'", .{r.string});
                    }
                }
            }
        },
        .array => |arr| {
            if (s.get("items")) |items_schema| {
                for (arr.items, 0..) |item, idx| {
                    const before = path.items.len;
                    var idx_buf: [32]u8 = undefined;
                    const idx_str = std.fmt.bufPrint(&idx_buf, "/{d}", .{idx}) catch unreachable;
                    try path.appendSlice(gpa, idx_str);
                    try validateNode(gpa, items_schema, item, path, errors);
                    path.shrinkRetainingCapacity(before);
                }
            }
        },
        else => {},
    }
}

fn typeMatches(type_val: std.json.Value, instance: std.json.Value) bool {
    return switch (type_val) {
        .string => |t| oneTypeMatches(t, instance),
        .array => |arr| for (arr.items) |t| {
            if (oneTypeMatches(t.string, instance)) break true;
        } else false,
        else => false,
    };
}

/// JSON Schema's two numeric types are NOT the same test, and collapsing them
/// is how a validator silently accepts what it exists to reject:
///
///   `number`  -- any JSON number.
///   `integer` -- a number with ZERO fractional part. Note 1.0 IS a valid
///                integer per draft 2020-12; the type is about the value, not
///                about how it was spelled.
///
/// Every other type name is an exact match against `instanceTypeName`.
fn oneTypeMatches(want: []const u8, instance: std.json.Value) bool {
    if (std.mem.eql(u8, want, "number")) return isNumber(instance);
    if (std.mem.eql(u8, want, "integer")) return isIntegral(instance);
    return std.mem.eql(u8, want, instanceTypeName(instance));
}

fn isNumber(v: std.json.Value) bool {
    return switch (v) {
        .integer, .float, .number_string => true,
        else => false,
    };
}

fn isIntegral(v: std.json.Value) bool {
    return switch (v) {
        .integer => true,
        .float => |f| std.math.isFinite(f) and @floor(f) == f,
        // A number too large or too precise for f64 round-tripping is preserved
        // verbatim by std.json. Parse it as an integer: success means it had no
        // fractional part; failure is treated as non-integral rather than
        // guessed at.
        .number_string => |t| blk: {
            _ = std.fmt.parseInt(i64, t, 10) catch break :blk false;
            break :blk true;
        },
        else => false,
    };
}

fn typeDesc(type_val: std.json.Value) []const u8 {
    return switch (type_val) {
        .string => |t| t,
        .array => "one of the declared types", // multi-value case: the
        // per-error message already names what the instance actually was,
        // and the schema's own `type` array is visible in the committed
        // file next to whichever field failed -- spelling out every member
        // here would need an allocation this function deliberately avoids.
        else => "<unknown>",
    };
}

fn instanceTypeName(v: std.json.Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "boolean",
        .integer => "integer",
        // Reported as "number", not "integer": this name appears in the error
        // message a human reads, and calling 1.5 an integer there would be the
        // same lie the type check used to tell.
        .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |av| b == .bool and b.bool == av,
        .integer => |av| b == .integer and b.integer == av,
        .float => |av| b == .float and b.float == av,
        .number_string => |av| b == .number_string and std.mem.eql(u8, av, b.number_string),
        .string => |av| b == .string and std.mem.eql(u8, av, b.string),
        .array, .object => false, // never emitted as an enum member here.
    };
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

/// The `rails_manifest_validate` CLI: `<schema.json> <instance.json>`,
/// silent exit 0 when `instance` validates, one line per violation on
/// stderr and exit 1 otherwise. `tests/migrate/rails.sh` runs this against
/// the COMMITTED schema and the fixture manifest it already generates --
/// see this file's module doc for why that closes a real gap `rails-check`
/// (schema-vs-schema) and `manifestGoldenBytes` (a hand-built, empty-
/// `assets` instance) cannot.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) fatal(
        "usage: rails_manifest_validate <schema.json> <instance.json>\n",
        .{},
    );
    const schema_path = args[1];
    const instance_path = args[2];

    // `arena`, not a `testing.allocator`-style leak-checked allocator: this
    // is a short-lived CLI process (mirrors `schema_gen.zig`'s `main`,
    // whose own comment explains why passing the process arena as `gpa`
    // here is an ordinary CLI-main choice, not the "arena wraps testing.
    // allocator" pattern `scripts/check-allocator-contracts.sh` flags).
    const schema_bytes = Io.Dir.cwd().readFileAlloc(io, schema_path, arena, .limited(4 * 1024 * 1024)) catch |err| fatal(
        "error reading '{s}': {t}\n",
        .{ schema_path, err },
    );
    const instance_bytes = Io.Dir.cwd().readFileAlloc(io, instance_path, arena, .limited(16 * 1024 * 1024)) catch |err| fatal(
        "error reading '{s}': {t}\n",
        .{ instance_path, err },
    );

    const schema_parsed = std.json.parseFromSlice(std.json.Value, arena, schema_bytes, .{}) catch |err| fatal(
        "error parsing '{s}' as JSON: {t}\n",
        .{ schema_path, err },
    );
    const instance_parsed = std.json.parseFromSlice(std.json.Value, arena, instance_bytes, .{}) catch |err| fatal(
        "error parsing '{s}' as JSON: {t}\n",
        .{ instance_path, err },
    );

    const errors = try validate(arena, schema_parsed.value, instance_parsed.value);
    if (errors.len > 0) {
        for (errors) |e| std.debug.print("{s}\n", .{e});
        std.process.exit(1);
    }
}

const Io = std.Io;
const testing = std.testing;

test "numeric types: `integer` rejects a fractional number, `number` accepts both" {
    const gpa = std.testing.allocator;

    // The defect this pins: mapping every JSON number to "integer" made 1.5
    // satisfy {"type":"integer"} AND skip every deeper check, because the type
    // gate returns early once it believes the shape is right. Both directions
    // are asserted -- a test that only rejected 1.5 would pass against a
    // validator that rejects every number, and one that only accepted 3 would
    // pass against the original defect.
    const cases = [_]struct { schema: []const u8, doc: []const u8, valid: bool }{
        .{ .schema = "{\"type\":\"integer\"}", .doc = "3", .valid = true },
        .{ .schema = "{\"type\":\"integer\"}", .doc = "1.5", .valid = false },
        // 1.0 has no fractional part, so it IS an integer per draft 2020-12 --
        // the type is about the value, not how it was spelled.
        .{ .schema = "{\"type\":\"integer\"}", .doc = "1.0", .valid = true },
        .{ .schema = "{\"type\":\"number\"}", .doc = "1.5", .valid = true },
        .{ .schema = "{\"type\":\"number\"}", .doc = "3", .valid = true },
        .{ .schema = "{\"type\":\"number\"}", .doc = "\"3\"", .valid = false },
        .{ .schema = "{\"type\":\"integer\"}", .doc = "\"3\"", .valid = false },
    };

    for (cases) |c| {
        var schema = try std.json.parseFromSlice(std.json.Value, gpa, c.schema, .{});
        defer schema.deinit();
        var doc = try std.json.parseFromSlice(std.json.Value, gpa, c.doc, .{});
        defer doc.deinit();

        const errs = try validate(gpa, schema.value, doc.value);
        defer {
            for (errs) |e| gpa.free(e);
            gpa.free(errs);
        }
        const ok = errs.len == 0;
        if (ok != c.valid) {
            std.debug.print("\n{s} against {s}: expected valid={}, got valid={}\n", .{ c.doc, c.schema, c.valid, ok });
            return error.TestUnexpectedResult;
        }
    }
}

test "validate: the REAL fixture manifest validates against the generated schema (F1's actual shape, not the golden's empty assets[])" {
    // phase-2-review.md F1 / Ruling 17: `manifestGoldenBytes` pins a
    // hand-built manifest with `"assets": []`, so it structurally cannot
    // contain `assets[].pipeline` -- the exact `?enum` field the shipped
    // defect broke on. This builds a manifest from the REAL fixture
    // instead (same pipeline `tests/migrate/rails.sh` and `manifest.zig`'s
    // own two-directory determinism test exercise), which DOES populate
    // `assets[].pipeline` with both a real enum value and `null` (the
    // `public/`-relative entries) -- see `assets.scan`'s doc.
    //
    // Needs `ruby` on PATH + ZIGAPAGOS_RUNTIME_DIR; skips rather than
    // fails when the toolchain genuinely isn't available, same as every
    // other real-sidecar test in this directory.
    const schema_gen = @import("schema_gen.zig");
    const manifest = @import("manifest.zig");
    const rails = @import("rails.zig");

    const gpa = testing.allocator;
    const io = std.testing.io;

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("ZIGAPAGOS_RUNTIME_DIR", "runtime");

    const d = try rails.discover(io, gpa, app_dir, "tests/migrate/rails-sample", &env_map, .{});
    defer rails.freeDiscovery(gpa, d);

    if (!std.mem.eql(u8, d.route_mode, "static_ast")) return error.SkipZigTest;

    const evidence = [_][]const u8{ "Gemfile", "config/application.rb", "app/views" };
    const manifest_bytes = try manifest.build(gpa, .{ .generator_version = "0.0.0-test", .root_evidence = &evidence, .discovery = &d });
    defer gpa.free(manifest_bytes);

    const schema_bytes = try schema_gen.generate(gpa);
    defer gpa.free(schema_bytes);

    var schema_parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_bytes, .{});
    defer schema_parsed.deinit();
    var instance_parsed = try std.json.parseFromSlice(std.json.Value, gpa, manifest_bytes, .{});
    defer instance_parsed.deinit();

    // Sanity that this test actually exercised the field F1 broke on, not
    // an accidentally-empty assets[] that would trivially pass too.
    try testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"pipeline\": null") != null);

    const errors = try validate(gpa, schema_parsed.value, instance_parsed.value);
    defer freeErrors(gpa, errors);
    for (errors) |e| std.debug.print("unexpected: {s}\n", .{e});
    try testing.expectEqual(@as(usize, 0), errors.len);
}

test "validate: a nullable enum field set to null passes (F1's exact shape)" {
    const gpa = testing.allocator;
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"type":"object","properties":{"pipeline":{"type":["string","null"],"enum":["propshaft","sprockets",null]}},"required":["pipeline"],"additionalProperties":false}
    , .{});
    defer schema_parsed.deinit();
    var instance_parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"pipeline":null}
    , .{});
    defer instance_parsed.deinit();

    const errors = try validate(gpa, schema_parsed.value, instance_parsed.value);
    defer freeErrors(gpa, errors);
    try testing.expectEqual(@as(usize, 0), errors.len);
}

test "validate: catches a pre-fix nullable enum schema rejecting null (regression pin for F1)" {
    // The EXACT broken shape `nullableOf` produced before the fix: `type`
    // widened, `enum` left untouched. If this ever starts passing again,
    // the validator itself has regressed, not just `nullableOf`.
    const gpa = testing.allocator;
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"type":"object","properties":{"pipeline":{"type":["string","null"],"enum":["propshaft","sprockets"]}},"required":["pipeline"],"additionalProperties":false}
    , .{});
    defer schema_parsed.deinit();
    var instance_parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"pipeline":null}
    , .{});
    defer instance_parsed.deinit();

    const errors = try validate(gpa, schema_parsed.value, instance_parsed.value);
    defer freeErrors(gpa, errors);
    try testing.expectEqual(@as(usize, 1), errors.len);
    try testing.expect(std.mem.indexOf(u8, errors[0], "enum") != null);
}

test "validate: an unknown property is rejected when additionalProperties is false" {
    const gpa = testing.allocator;
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"additionalProperties":false}
    , .{});
    defer schema_parsed.deinit();
    var instance_parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"a":"x","b":"surprise"}
    , .{});
    defer instance_parsed.deinit();

    const errors = try validate(gpa, schema_parsed.value, instance_parsed.value);
    defer freeErrors(gpa, errors);
    try testing.expectEqual(@as(usize, 1), errors.len);
    try testing.expect(std.mem.indexOf(u8, errors[0], "/b") != null);
}

test "validate: a missing required property is reported by name" {
    const gpa = testing.allocator;
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"additionalProperties":false}
    , .{});
    defer schema_parsed.deinit();
    var instance_parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{}
    , .{});
    defer instance_parsed.deinit();

    const errors = try validate(gpa, schema_parsed.value, instance_parsed.value);
    defer freeErrors(gpa, errors);
    try testing.expectEqual(@as(usize, 1), errors.len);
    try testing.expect(std.mem.indexOf(u8, errors[0], "'a'") != null);
}

test "validate: array items are checked by index, one error per bad element" {
    const gpa = testing.allocator;
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"type":"array","items":{"type":"string"}}
    , .{});
    defer schema_parsed.deinit();
    var instance_parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\["ok", 5, "also ok", false]
    , .{});
    defer instance_parsed.deinit();

    const errors = try validate(gpa, schema_parsed.value, instance_parsed.value);
    defer freeErrors(gpa, errors);
    try testing.expectEqual(@as(usize, 2), errors.len);
    try testing.expect(std.mem.indexOf(u8, errors[0], "/1") != null);
    try testing.expect(std.mem.indexOf(u8, errors[1], "/3") != null);
}
