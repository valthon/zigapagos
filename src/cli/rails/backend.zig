//! Stage 3, the backend boundary: read the ZigBase OpenAPI document that
//! `--backend FILE` names, and rank its operations for one operator
//! question.
//!
//! ## What this file is a reader OF
//!
//! `zigbase openapi` (see `~/nothlav/zigbase`, `src/openapi.zig` and
//! `docs/openapi.md`) writes a deterministic OpenAPI 3.1.2 document
//! describing exactly two things: live non-system collection CRUD, and the
//! consumer routes a framework binary declares. It deliberately does NOT
//! describe admin management, realtime, file bytes, or the built-in auth
//! methods -- the root `x-zigbase-coverage` object says so field by field,
//! and `allAuthMethods` is always `false`. That last one is why
//! `authWithPassword`/`logout` can never appear here as operation ids: the
//! auth-journey scaffold names those `CollectionService` methods itself
//! and only needs the COLLECTION from this document.
//!
//! Two documents must both parse, and they are years apart in shape:
//!
//!  * the in-repo `contract/zigbase.openapi.json` -- OpenAPI **3.0.3**,
//!    `x-zigbase-contract-version: "2026-06-27.1"`, three hand-written
//!    consumer routes, no `x-zigbase-coverage`, no collections;
//!  * what today's `zigbase openapi` emits -- **3.1.2**, no contract
//!    version (so `info.version` stands in), a coverage object, and the
//!    `/api/collections/<name>/records[/{id}]` CRUD block per collection.
//!
//! So every field this file reads is optional except `openapi` and
//! `paths`, and every key it does not know is ignored. The document is
//! ZigBase's, not the operator's: an unrecognised extension is a newer
//! ZigBase, not a mistake to report.
//!
//! ## What "an auth collection" means here
//!
//! Nothing in the document says "this collection is an auth collection".
//! The only observable difference is that an auth collection's
//! `<Base>Create` schema carries the write-only `password` and
//! `passwordConfirm` properties (`openapi.zig:209`), so that pair -- and
//! not a name heuristic like `users` -- is the test. It matters because
//! `RAILS_AUTH_JOURNEY`'s answer is a collection name, and validating it
//! against a guess would reject a correct answer on an app whose auth
//! collection is called `members`.
//!
//! ## Ownership
//!
//! `parse` returns an owned graph (contract 2) released by `free`.
//! `choicesFor` is contract 1 and the ONE place that needs saying twice:
//! the slice it returns is the only allocation, and its ELEMENTS are
//! borrowed -- either `doc`'s own `operation_id` strings or the static
//! `"retain"`/`"blocked"` literals. A caller frees the slice and nothing
//! else, and must not outlive the `Document` it asked about.
//!
//! std-only, like every file in `src/cli/rails/` (see `manifest.zig`'s
//! module doc): no `@import` here escapes this directory.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How ZigBase gates an operation. The first three come from
/// `x-zigbase-access` on collection operations (`@public` / a rule
/// expression / `null`); the next three from `x-zigbase-auth` on consumer
/// routes, whose `path-secret` spelling is hyphenated in the document.
/// `unknown` covers both "neither extension present" (the 3.0.3 contract
/// document has neither) and a value a future ZigBase adds.
pub const Access = enum { public, locked, conditional, authenticated, superuser, path_secret, unknown };

/// The CRUD slot a collection path + verb occupies. Everything that is not
/// a `/api/collections/<name>/records[/{id}]` operation is `custom`, and so
/// is an unexpected verb on a collection path (`PUT` on `.../records`):
/// this file reports the shape it can prove, never a guess.
pub const Kind = enum { list, create, view, update, delete, custom };

pub const Operation = struct {
    operation_id: []const u8,
    /// Upper-case (`"POST"`), whatever case the document's key had.
    verb: []const u8,
    /// As written in the document, `{id}` template and all.
    path: []const u8,
    /// The `<name>` of `/api/collections/<name>/records[/{id}]`, else null.
    collection: ?[]const u8,
    kind: Kind,
    access: Access,
};

pub const Document = struct {
    /// Basename of the file `--backend` named, for the handoff's
    /// `backend.file`. A basename, not the path, because the handoff is a
    /// committed artifact and must not carry the operator's directory
    /// layout (Global Constraints: no absolute paths in any artifact).
    file: []const u8,
    contract_version: []const u8,
    consumer_routes: bool,
    /// Sorted by (path, verb).
    operations: []Operation,
    /// Sorted. A collection appears here at most once (only its single
    /// create operation can nominate it).
    auth_collections: [][]const u8,
};

pub const ParseError = error{ InvalidJson, NotOpenApi3, NoPaths } || Allocator.Error;

/// Every method key OpenAPI defines. Anything else under a path item
/// (`parameters`, `summary`, `$ref`, a vendor extension) is not an
/// operation and is skipped.
const http_methods = [_][]const u8{ "get", "put", "post", "delete", "options", "head", "patch", "trace" };

const collection_prefix = "/api/collections/";
const records_segment = "/records";
const id_suffix = "/{id}";

const PathShape = struct {
    collection: []const u8,
    /// `true` for `.../records/{id}`, `false` for `.../records`.
    item: bool,
};

/// The only path shape ZigBase generates per collection
/// (`openapi.zig:411`). A `<name>` containing a `/` is not one -- that
/// would be a deeper custom route that merely starts with the same prefix.
fn collectionShape(path: []const u8) ?PathShape {
    if (!std.mem.startsWith(u8, path, collection_prefix)) return null;
    var rest = path[collection_prefix.len..];
    const item = std.mem.endsWith(u8, rest, records_segment ++ id_suffix);
    if (item) {
        rest = rest[0 .. rest.len - (records_segment ++ id_suffix).len];
    } else if (std.mem.endsWith(u8, rest, records_segment)) {
        rest = rest[0 .. rest.len - records_segment.len];
    } else return null;
    if (rest.len == 0) return null;
    if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    return .{ .collection = rest, .item = item };
}

fn kindFor(shape: ?PathShape, verb: []const u8) Kind {
    const s = shape orelse return .custom;
    if (s.item) {
        if (std.mem.eql(u8, verb, "GET")) return .view;
        if (std.mem.eql(u8, verb, "PATCH")) return .update;
        if (std.mem.eql(u8, verb, "DELETE")) return .delete;
        return .custom;
    }
    if (std.mem.eql(u8, verb, "GET")) return .list;
    if (std.mem.eql(u8, verb, "POST")) return .create;
    return .custom;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn objectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

/// `x-zigbase-access` (collection operations) wins over `x-zigbase-auth`
/// (consumer routes); a document that carries neither -- or a spelling
/// this reader has not met -- is `unknown` rather than an error.
fn accessOf(op: std.json.ObjectMap) Access {
    if (stringField(op, "x-zigbase-access")) |a| {
        if (std.mem.eql(u8, a, "public")) return .public;
        if (std.mem.eql(u8, a, "locked")) return .locked;
        if (std.mem.eql(u8, a, "conditional")) return .conditional;
        return .unknown;
    }
    if (stringField(op, "x-zigbase-auth")) |a| {
        if (std.mem.eql(u8, a, "public")) return .public;
        if (std.mem.eql(u8, a, "authenticated")) return .authenticated;
        if (std.mem.eql(u8, a, "superuser")) return .superuser;
        // Hyphenated in the document (`openapi.zig:603`), underscored in
        // the enum: Zig has no hyphen in an identifier.
        if (std.mem.eql(u8, a, "path-secret")) return .path_secret;
        return .unknown;
    }
    return .unknown;
}

/// The JSON-body schema of an operation's request, resolved one hop
/// through `$ref` into `components.schemas`. One hop is all `zigbase
/// openapi` ever emits (`requestBody` always points straight at a named
/// component), and a chase loop would need cycle detection to be safe.
fn requestSchema(root: std.json.ObjectMap, op: std.json.ObjectMap) ?std.json.ObjectMap {
    const body = objectField(op, "requestBody") orelse return null;
    const content = objectField(body, "content") orelse return null;
    const media = objectField(content, "application/json") orelse return null;
    const schema = objectField(media, "schema") orelse return null;
    const ref = stringField(schema, "$ref") orelse return schema;
    const marker = "#/components/schemas/";
    if (!std.mem.startsWith(u8, ref, marker)) return null;
    const components = objectField(root, "components") orelse return null;
    const schemas = objectField(components, "schemas") orelse return null;
    return objectField(schemas, ref[marker.len..]);
}

fn isAuthCreateSchema(schema: std.json.ObjectMap) bool {
    const props = objectField(schema, "properties") orelse return false;
    return props.contains("password") and props.contains("passwordConfirm");
}

/// Contract 2's release half for one `Operation` -- the four strings
/// `makeOperation` allocated.
fn freeOperation(gpa: Allocator, op: Operation) void {
    gpa.free(op.operation_id);
    gpa.free(op.verb);
    gpa.free(op.path);
    if (op.collection) |c| gpa.free(c);
}

fn lessByPathThenVerb(_: void, a: Operation, b: Operation) bool {
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.verb, b.verb) == .lt,
    };
}

fn lessByBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Contract 2 (owned-result): the returned `Document` owns every string
/// and slice reachable from it; release it with `free`.
///
/// `file_label` is the path `--backend` named; only its basename is kept
/// (see `Document.file`).
pub fn parse(gpa: Allocator, bytes: []const u8, file_label: []const u8) ParseError!Document {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotOpenApi3,
    };

    const version = stringField(root, "openapi") orelse return error.NotOpenApi3;
    if (!std.mem.startsWith(u8, version, "3.")) return error.NotOpenApi3;

    const paths = objectField(root, "paths") orelse return error.NoPaths;

    var ops: std.ArrayListUnmanaged(Operation) = .empty;
    errdefer {
        for (ops.items) |op| freeOperation(gpa, op);
        ops.deinit(gpa);
    }
    var auth: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (auth.items) |name| gpa.free(name);
        auth.deinit(gpa);
    }

    var path_it = paths.iterator();
    while (path_it.next()) |path_entry| {
        const path = path_entry.key_ptr.*;
        const item = switch (path_entry.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };
        const shape = collectionShape(path);

        for (http_methods) |method| {
            const op_obj = objectField(item, method) orelse continue;
            // An operation with no id cannot be named in an answer, so it
            // cannot be a choice and is not carried.
            const id = stringField(op_obj, "operationId") orelse continue;

            var verb_buf: [8]u8 = undefined;
            const verb = std.ascii.upperString(verb_buf[0..method.len], method);
            const kind = kindFor(shape, verb);

            const op = try makeOperation(gpa, id, verb, path, shape, kind, accessOf(op_obj));
            // Not an `errdefer`: the moment `append` succeeds, `op` is
            // owned by `ops` and the loop-scoped errdefer would hand the
            // block errdefer above a second free of the same strings on a
            // LATER failure in this iteration. The FailingAllocator sweep
            // below segfaulted on exactly that.
            ops.append(gpa, op) catch |err| {
                freeOperation(gpa, op);
                return err;
            };

            if (kind == .create) {
                if (requestSchema(root, op_obj)) |schema| {
                    if (isAuthCreateSchema(schema)) {
                        const name = try gpa.dupe(u8, shape.?.collection);
                        auth.append(gpa, name) catch |err| {
                            gpa.free(name);
                            return err;
                        };
                    }
                }
            }
        }
    }

    std.mem.sort(Operation, ops.items, {}, lessByPathThenVerb);
    // No dedupe needed: a JSON object cannot repeat a path key and each
    // collection path has exactly one `post`, so a collection can be
    // nominated at most once.
    std.mem.sort([]const u8, auth.items, {}, lessByBytes);

    var any_custom = false;
    for (ops.items) |op| {
        if (op.kind == .custom) any_custom = true;
    }

    const contract_version = stringField(root, "x-zigbase-contract-version") orelse
        if (objectField(root, "info")) |info| stringField(info, "version") orelse "" else "";

    const consumer_routes = blk: {
        const coverage = objectField(root, "x-zigbase-coverage") orelse break :blk any_custom;
        const flag = coverage.get("consumerRoutes") orelse break :blk any_custom;
        break :blk switch (flag) {
            .bool => |b| b,
            else => any_custom,
        };
    };

    const file = try gpa.dupe(u8, std.fs.path.basename(file_label));
    errdefer gpa.free(file);
    const version_owned = try gpa.dupe(u8, contract_version);
    errdefer gpa.free(version_owned);

    // Each `toOwnedSlice` empties its list, so the block errdefers above
    // become no-ops as ownership moves -- which is why the last fallible
    // call needs no errdefer of its own.
    const ops_owned = try ops.toOwnedSlice(gpa);
    errdefer {
        for (ops_owned) |op| freeOperation(gpa, op);
        gpa.free(ops_owned);
    }
    const auth_owned = try auth.toOwnedSlice(gpa);

    return .{
        .file = file,
        .contract_version = version_owned,
        .consumer_routes = consumer_routes,
        .operations = ops_owned,
        .auth_collections = auth_owned,
    };
}

/// Contract 2 (owned-result): the returned `Operation` owns its four
/// strings; `freeOperation` is its release half. On `OutOfMemory` the
/// errdefers below unwind every dupe made so far, so a failed call leaks
/// nothing and the caller has nothing to release.
fn makeOperation(
    gpa: Allocator,
    id: []const u8,
    verb: []const u8,
    path: []const u8,
    shape: ?PathShape,
    kind: Kind,
    access: Access,
) Allocator.Error!Operation {
    const id_owned = try gpa.dupe(u8, id);
    errdefer gpa.free(id_owned);
    const verb_owned = try gpa.dupe(u8, verb);
    errdefer gpa.free(verb_owned);
    const path_owned = try gpa.dupe(u8, path);
    errdefer gpa.free(path_owned);
    const collection: ?[]const u8 = if (shape) |s| try gpa.dupe(u8, s.collection) else null;
    return .{
        .operation_id = id_owned,
        .verb = verb_owned,
        .path = path_owned,
        .collection = collection,
        .kind = kind,
        .access = access,
    };
}

/// Contract 2's release half.
pub fn free(gpa: Allocator, doc: Document) void {
    for (doc.operations) |op| freeOperation(gpa, op);
    gpa.free(doc.operations);
    for (doc.auth_collections) |name| gpa.free(name);
    gpa.free(doc.auth_collections);
    gpa.free(doc.contract_version);
    gpa.free(doc.file);
}

/// Contract 1 (self-freeing): exactly one allocation escapes -- the
/// returned slice. Its elements are BORROWED (see the module doc): they
/// point into `doc`'s operation ids or at static literals, so the caller
/// frees the slice alone and must drop it before `free(gpa, doc)`.
///
/// `verb` is the HTTP method the Rails side is asking about and `resource`
/// the Rails resource/controller name (`posts`) or null. Only operations
/// with that verb are ever offered -- answering a form's `POST` with a
/// `GET` operation is not a choice the operator should have to reject --
/// and the resource's own collection operations come first because the
/// standard `resources :posts` mapping is the answer nine times in ten.
pub fn choicesFor(gpa: Allocator, doc: ?Document, verb: []const u8, resource: ?[]const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);

    if (doc) |d| {
        try out.ensureUnusedCapacity(gpa, d.operations.len + 2);
        for (d.operations) |op| {
            if (!std.ascii.eqlIgnoreCase(op.verb, verb)) continue;
            if (matchesResource(op, resource)) out.appendAssumeCapacity(op.operation_id);
        }
        const split = out.items.len;
        for (d.operations) |op| {
            if (!std.ascii.eqlIgnoreCase(op.verb, verb)) continue;
            if (!matchesResource(op, resource)) out.appendAssumeCapacity(op.operation_id);
        }
        // Each group is ordered by operation id so the choice list -- which
        // is written into the manifest -- does not depend on the document's
        // key order.
        std.mem.sort([]const u8, out.items[0..split], {}, lessByBytes);
        std.mem.sort([]const u8, out.items[split..], {}, lessByBytes);
    }

    try out.append(gpa, "retain");
    try out.append(gpa, "blocked");
    return out.toOwnedSlice(gpa);
}

fn matchesResource(op: Operation, resource: ?[]const u8) bool {
    const want = resource orelse return false;
    const have = op.collection orelse return false;
    return std.mem.eql(u8, have, want);
}

/// The operation an answered choice names, or null for the answers that
/// name none: `retain`, `blocked`, and `custom:/<path>`.
///
/// The returned `Operation` is a copy of the struct but NOT of its
/// strings: every slice in it points into `doc` and dies with
/// `free(gpa, doc)`. A caller that parks it somewhere longer-lived -- the
/// handoff's `endpoint`, say -- must dupe the fields it keeps.
///
/// Two shapes worth knowing, neither reachable from a document `zigbase
/// openapi` writes:
///
///  * the three reserved answers shadow operation ids, so an operation
///    literally called `retain`, `blocked` or `custom:x` would be
///    unanswerable. ZigBase derives ids as `<verb><Base>`, so it cannot
///    mint one;
///  * if a document ever repeated an operation id across two paths, the
///    first in `operations` order -- (path, verb) -- wins, and the choice
///    list would offer the same word twice. Again `<verb><Base>` over
///    distinct collection names cannot collide.
pub fn operationFor(doc: Document, choice: []const u8) ?Operation {
    if (std.mem.eql(u8, choice, "retain")) return null;
    if (std.mem.eql(u8, choice, "blocked")) return null;
    if (std.mem.startsWith(u8, choice, "custom:")) return null;
    for (doc.operations) |op| {
        if (std.mem.eql(u8, op.operation_id, choice)) return op;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Io = std.Io;

/// Shaped like `zigbase openapi` output for a data dir holding the auth
/// collection `users` and the base collection `posts`: trimmed to the keys
/// this reader looks at, plus enough of the surrounding shape (`security`,
/// `x-zigbase-rule`, `requestBody`, `components.schemas`) to prove the
/// reader ignores what it does not know.
///
/// It is NOT a copy of `tests/migrate/rails-presentation/backend/
/// openapi.json`, and the two are independent BY DESIGN. That file is
/// whatever the real generator writes for the fixture's collection rules
/// (`listPosts` public, `createPosts` conditional); this one assigns the
/// access values that give every `x-zigbase-access` spelling a test
/// (`listPosts` conditional, `createPosts` locked, `viewPosts` public).
/// Nothing in this file depends on which rule a collection happens to
/// carry, so DO NOT "fix" either fixture to match the other -- doing so
/// would cost the `conditional` or the `locked` case its only coverage.
const fixture_document =
    \\{
    \\  "openapi": "3.1.2",
    \\  "info": { "title": "ZigBase API", "version": "1.0.0" },
    \\  "x-zigbase-coverage": {
    \\    "collections": true, "consumerRoutes": false, "admin": false,
    \\    "realtime": false, "fileBytes": false, "allAuthMethods": false
    \\  },
    \\  "paths": {
    \\    "/api/collections/posts/records": {
    \\      "get": {
    \\        "operationId": "listPosts",
    \\        "x-zigbase-access": "conditional",
    \\        "x-zigbase-rule": "published = true"
    \\      },
    \\      "post": {
    \\        "operationId": "createPosts",
    \\        "requestBody": { "required": true, "content": { "application/json": {
    \\          "schema": { "$ref": "#/components/schemas/PostsCreate" } } } },
    \\        "x-zigbase-access": "locked"
    \\      }
    \\    },
    \\    "/api/collections/posts/records/{id}": {
    \\      "get": { "operationId": "viewPosts", "security": [], "x-zigbase-access": "public" },
    \\      "patch": { "operationId": "updatePosts", "x-zigbase-access": "locked" },
    \\      "delete": { "operationId": "deletePosts", "x-zigbase-access": "locked" }
    \\    },
    \\    "/api/collections/users/records": {
    \\      "get": { "operationId": "listUsers", "x-zigbase-access": "locked" },
    \\      "post": {
    \\        "operationId": "createUsers",
    \\        "security": [],
    \\        "requestBody": { "required": true, "content": { "application/json": {
    \\          "schema": { "$ref": "#/components/schemas/UsersCreate" } } } },
    \\        "x-zigbase-access": "public"
    \\      }
    \\    },
    \\    "/api/collections/users/records/{id}": {
    \\      "get": { "operationId": "viewUsers", "x-zigbase-access": "locked" },
    \\      "patch": { "operationId": "updateUsers", "x-zigbase-access": "locked" },
    \\      "delete": { "operationId": "deleteUsers", "x-zigbase-access": "locked" }
    \\    }
    \\  },
    \\  "components": { "schemas": {
    \\    "PostsCreate": { "type": "object", "required": ["title"], "properties": {
    \\      "title": { "type": "string" }, "body": { "type": "string" } } },
    \\    "UsersCreate": { "type": "object", "required": ["email", "password", "passwordConfirm"],
    \\      "properties": {
    \\        "email": { "type": "string" },
    \\        "password": { "type": "string", "writeOnly": true },
    \\        "passwordConfirm": { "type": "string", "writeOnly": true } } }
    \\  } }
    \\}
;

fn findOp(doc: Document, id: []const u8) Operation {
    for (doc.operations) |op| {
        if (std.mem.eql(u8, op.operation_id, id)) return op;
    }
    unreachable;
}

fn expectChoices(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try std.testing.expectEqualStrings(e, a);
}

// The document this repo already ships is the OLD shape: 3.0.3, three
// consumer routes, an explicit contract version and no coverage object. It
// is checked in, so this test reads the real bytes rather than a copy that
// could drift away from them. `build/tests.zig` gives `test-rails`
// `repo_root_cwd = true`, so the relative path resolves.
test "parse: the shipped 3.0.3 contract document is three custom operations" {
    const gpa = std.testing.allocator;
    const bytes = try Io.Dir.cwd().readFileAlloc(std.testing.io, "contract/zigbase.openapi.json", gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);

    const doc = try parse(gpa, bytes, "contract/zigbase.openapi.json");
    defer free(gpa, doc);

    try std.testing.expectEqualStrings("zigbase.openapi.json", doc.file);
    try std.testing.expectEqualStrings("2026-06-27.1", doc.contract_version);
    // No `x-zigbase-coverage` in this document, and it is all custom
    // routes, so the fallback has to say `true`.
    try std.testing.expect(doc.consumer_routes);
    try std.testing.expectEqual(@as(usize, 0), doc.auth_collections.len);

    try std.testing.expectEqual(@as(usize, 3), doc.operations.len);
    for (doc.operations) |op| {
        try std.testing.expectEqual(Kind.custom, op.kind);
        try std.testing.expectEqual(Access.unknown, op.access);
        try std.testing.expectEqual(@as(?[]const u8, null), op.collection);
    }
    // Sorted by (path, verb): /api/club/login < /api/contact < /api/flags/state.
    try std.testing.expectEqualStrings("clubLogin", doc.operations[0].operation_id);
    try std.testing.expectEqualStrings("POST", doc.operations[0].verb);
    try std.testing.expectEqualStrings("/api/club/login", doc.operations[0].path);
    try std.testing.expectEqualStrings("submitContact", doc.operations[1].operation_id);
    try std.testing.expectEqualStrings("getFlagsState", doc.operations[2].operation_id);
    try std.testing.expectEqualStrings("GET", doc.operations[2].verb);
}

test "parse: collection paths become list/create/view/update/delete on their collection" {
    const gpa = std.testing.allocator;
    const doc = try parse(gpa, fixture_document, "backend/openapi.json");
    defer free(gpa, doc);

    try std.testing.expectEqual(@as(usize, 10), doc.operations.len);

    const create_users = findOp(doc, "createUsers");
    try std.testing.expectEqual(Kind.create, create_users.kind);
    try std.testing.expectEqualStrings("users", create_users.collection.?);
    try std.testing.expectEqualStrings("POST", create_users.verb);
    try std.testing.expectEqualStrings("/api/collections/users/records", create_users.path);
    try std.testing.expectEqual(Access.public, create_users.access);

    try std.testing.expectEqual(Kind.list, findOp(doc, "listPosts").kind);
    try std.testing.expectEqual(Access.conditional, findOp(doc, "listPosts").access);
    try std.testing.expectEqual(Kind.view, findOp(doc, "viewPosts").kind);
    try std.testing.expectEqual(Access.public, findOp(doc, "viewPosts").access);
    try std.testing.expectEqual(Kind.update, findOp(doc, "updatePosts").kind);
    try std.testing.expectEqualStrings("PATCH", findOp(doc, "updatePosts").verb);
    try std.testing.expectEqual(Kind.delete, findOp(doc, "deletePosts").kind);
    try std.testing.expectEqual(Access.locked, findOp(doc, "deletePosts").access);
    try std.testing.expectEqualStrings("posts", findOp(doc, "deletePosts").collection.?);
}

test "parse: an auth collection is one whose create schema carries password and passwordConfirm" {
    const gpa = std.testing.allocator;
    const doc = try parse(gpa, fixture_document, "openapi.json");
    defer free(gpa, doc);

    try std.testing.expectEqual(@as(usize, 1), doc.auth_collections.len);
    try std.testing.expectEqualStrings("users", doc.auth_collections[0]);
    // `x-zigbase-coverage.consumerRoutes` is false here and so is the
    // fallback (no custom operations), so this line does NOT pin which of
    // the two was read -- the test below does that, both ways.
    try std.testing.expect(!doc.consumer_routes);
    // No `x-zigbase-contract-version`: `info.version` stands in.
    try std.testing.expectEqualStrings("1.0.0", doc.contract_version);
    try std.testing.expectEqualStrings("openapi.json", doc.file);
}

// The marker is a CONJUNCTION, and `fixture_document` alone cannot show
// that: its one auth collection has both properties and its one base
// collection has neither, so dropping either half of the `and` leaves the
// suite green. These two documents separate the halves.
test "parse: half the password pair is not an auth collection" {
    const gpa = std.testing.allocator;
    const password_only =
        \\{"openapi":"3.1.2","paths":{
        \\ "/api/collections/vaults/records":{"post":{"operationId":"createVaults",
        \\   "requestBody":{"content":{"application/json":{
        \\     "schema":{"$ref":"#/components/schemas/VaultsCreate"}}}}}}},
        \\ "components":{"schemas":{
        \\   "VaultsCreate":{"type":"object","properties":{"password":{"type":"string"}}}}}}
    ;
    const confirm_only =
        \\{"openapi":"3.1.2","paths":{
        \\ "/api/collections/vaults/records":{"post":{"operationId":"createVaults",
        \\   "requestBody":{"content":{"application/json":{
        \\     "schema":{"$ref":"#/components/schemas/VaultsCreate"}}}}}}},
        \\ "components":{"schemas":{
        \\   "VaultsCreate":{"type":"object","properties":{"passwordConfirm":{"type":"string"}}}}}}
    ;

    // A `password` field is ordinary on a non-auth collection (a secrets
    // vault, an integration credential); only the write-only PAIR that
    // ZigBase's auth create schema adds identifies an auth collection.
    const a = try parse(gpa, password_only, "a.json");
    defer free(gpa, a);
    try std.testing.expectEqual(@as(usize, 0), a.auth_collections.len);
    try std.testing.expectEqual(Kind.create, findOp(a, "createVaults").kind);

    const b = try parse(gpa, confirm_only, "b.json");
    defer free(gpa, b);
    try std.testing.expectEqual(@as(usize, 0), b.auth_collections.len);
}

// `x-zigbase-coverage.consumerRoutes` is the document TELLING us whether
// custom routes are described; the "any custom operation" fallback is a
// guess for the older documents that carry no coverage object. Every other
// fixture has the two agreeing, so this is the only place that proves the
// stated precedence -- and it has to prove it in both directions, or a
// mutation that always returns the fallback survives half of it.
test "parse: x-zigbase-coverage.consumerRoutes beats the any-custom fallback both ways" {
    const gpa = std.testing.allocator;

    // `true` with nothing custom in `paths`: the fallback would say false.
    const declared_true =
        \\{"openapi":"3.1.2","x-zigbase-coverage":{"consumerRoutes":true},"paths":{
        \\ "/api/collections/posts/records":{"get":{"operationId":"listPosts"}}}}
    ;
    const a = try parse(gpa, declared_true, "a.json");
    defer free(gpa, a);
    try std.testing.expect(a.consumer_routes);

    // `false` with a custom operation: the fallback would say true.
    const declared_false =
        \\{"openapi":"3.1.2","x-zigbase-coverage":{"consumerRoutes":false},"paths":{
        \\ "/api/contact":{"post":{"operationId":"submitContact"}}}}
    ;
    const b = try parse(gpa, declared_false, "b.json");
    defer free(gpa, b);
    try std.testing.expect(!b.consumer_routes);

    // A non-boolean `consumerRoutes` is not a claim; the fallback stands.
    const declared_junk =
        \\{"openapi":"3.1.2","x-zigbase-coverage":{"consumerRoutes":"yes"},"paths":{
        \\ "/api/contact":{"post":{"operationId":"submitContact"}}}}
    ;
    const c = try parse(gpa, declared_junk, "c.json");
    defer free(gpa, c);
    try std.testing.expect(c.consumer_routes);
}

test "parse: access falls back from x-zigbase-access to x-zigbase-auth to unknown" {
    const gpa = std.testing.allocator;
    const bytes =
        \\{"openapi":"3.1.2","info":{"version":"9"},"paths":{
        \\  "/api/deploy/{secret}": {"post":{"operationId":"deploy","x-zigbase-auth":"path-secret"}},
        \\  "/api/jobs": {"post":{"operationId":"createJob","x-zigbase-auth":"authenticated"}},
        \\  "/api/purge": {"delete":{"operationId":"purge","x-zigbase-auth":"superuser"}},
        \\  "/api/ping": {"get":{"operationId":"ping","x-zigbase-auth":"public"}},
        \\  "/api/raw": {"get":{"operationId":"raw","x-zigbase-untyped":true}},
        \\  "/api/odd": {"get":{"operationId":"odd","x-zigbase-auth":"telepathy"}},
        \\  "/api/collections/notes/records": {
        \\    "post":{"operationId":"createNotes","x-zigbase-access":"locked","x-zigbase-auth":"public"},
        \\    "put":{"operationId":"putNotes"}},
        \\  "/api/collections/notes/records/{id}/thumb": {"get":{"operationId":"thumb"}},
        \\  "/api/collections/deep/nested/records": {"get":{"operationId":"deepNested"}},
        \\  "/api/nameless": {"get":{"summary":"no operationId"}}
        \\}}
    ;
    const doc = try parse(gpa, bytes, "x.json");
    defer free(gpa, doc);

    try std.testing.expectEqual(Access.path_secret, findOp(doc, "deploy").access);
    try std.testing.expectEqual(Access.authenticated, findOp(doc, "createJob").access);
    try std.testing.expectEqual(Access.superuser, findOp(doc, "purge").access);
    try std.testing.expectEqual(Access.public, findOp(doc, "ping").access);
    try std.testing.expectEqual(Access.unknown, findOp(doc, "raw").access);
    // A value from a ZigBase newer than this reader is `unknown`, not a
    // parse failure: the document is ZigBase's, not the operator's.
    try std.testing.expectEqual(Access.unknown, findOp(doc, "odd").access);
    // `x-zigbase-access` wins when both are present.
    try std.testing.expectEqual(Access.locked, findOp(doc, "createNotes").access);
    // A `{secret}` template outside the collection shape is still custom.
    try std.testing.expectEqual(Kind.custom, findOp(doc, "deploy").kind);

    // Path-shape edges. A verb ZigBase never emits on a collection path is
    // reported as `custom` rather than guessed into a CRUD slot, but the
    // collection is a fact of the path and is still carried -- so the
    // operation still ranks first for its own resource.
    try std.testing.expectEqual(Kind.custom, findOp(doc, "putNotes").kind);
    try std.testing.expectEqualStrings("notes", findOp(doc, "putNotes").collection.?);
    // Anything deeper or shallower than `<name>/records[/{id}]` is a
    // custom route that merely shares the prefix.
    try std.testing.expectEqual(@as(?[]const u8, null), findOp(doc, "thumb").collection);
    try std.testing.expectEqual(Kind.custom, findOp(doc, "thumb").kind);
    try std.testing.expectEqual(@as(?[]const u8, null), findOp(doc, "deepNested").collection);

    // An operation with no `operationId` cannot be named in an answer, so
    // it is not carried at all.
    // The ten named operations above; `/api/nameless` contributes none.
    try std.testing.expectEqual(@as(usize, 10), doc.operations.len);
    for (doc.operations) |op| try std.testing.expect(op.operation_id.len > 0);
}

test "parse: operations are sorted by (path, verb) and identical bytes give an identical order" {
    const gpa = std.testing.allocator;
    const first = try parse(gpa, fixture_document, "a.json");
    defer free(gpa, first);
    const second = try parse(gpa, fixture_document, "a.json");
    defer free(gpa, second);

    try std.testing.expectEqual(first.operations.len, second.operations.len);
    for (first.operations, second.operations) |a, b| {
        try std.testing.expectEqualStrings(a.operation_id, b.operation_id);
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expectEqualStrings(a.verb, b.verb);
    }

    var i: usize = 1;
    while (i < first.operations.len) : (i += 1) {
        const prev = first.operations[i - 1];
        const cur = first.operations[i];
        const by_path = std.mem.order(u8, prev.path, cur.path);
        try std.testing.expect(by_path == .lt or
            (by_path == .eq and std.mem.order(u8, prev.verb, cur.verb) == .lt));
    }
}

test "parse: rejects a document that is not OpenAPI 3.x or has no paths" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotOpenApi3, parse(gpa, "{\"swagger\":\"2.0\",\"paths\":{}}", "f"));
    try std.testing.expectError(error.NotOpenApi3, parse(gpa, "{\"openapi\":\"2.0\",\"paths\":{}}", "f"));
    try std.testing.expectError(error.NotOpenApi3, parse(gpa, "[]", "f"));
    try std.testing.expectError(error.NoPaths, parse(gpa, "{\"openapi\":\"3.1.2\"}", "f"));
    try std.testing.expectError(error.NoPaths, parse(gpa, "{\"openapi\":\"3.0.3\",\"paths\":[]}", "f"));
    try std.testing.expectError(error.InvalidJson, parse(gpa, "source \"rubygems\"\n", "Gemfile"));
    try std.testing.expectError(error.InvalidJson, parse(gpa, "", "empty"));
}

test "choicesFor: the resource's own operations first, then the rest, then retain/blocked" {
    const gpa = std.testing.allocator;
    const doc = try parse(gpa, fixture_document, "openapi.json");
    defer free(gpa, doc);

    const post = try choicesFor(gpa, doc, "POST", "posts");
    defer gpa.free(post);
    try expectChoices(&.{ "createPosts", "createUsers", "retain", "blocked" }, post);

    const get = try choicesFor(gpa, doc, "GET", "posts");
    defer gpa.free(get);
    try expectChoices(&.{ "listPosts", "viewPosts", "listUsers", "viewUsers", "retain", "blocked" }, get);

    // No resource: one flat group, still by operation id.
    const any = try choicesFor(gpa, doc, "DELETE", null);
    defer gpa.free(any);
    try expectChoices(&.{ "deletePosts", "deleteUsers", "retain", "blocked" }, any);

    // A resource with no operations of its own falls through to the rest.
    const other = try choicesFor(gpa, doc, "PATCH", "comments");
    defer gpa.free(other);
    try expectChoices(&.{ "updatePosts", "updateUsers", "retain", "blocked" }, other);

    // Never an operation with a different verb.
    const head = try choicesFor(gpa, doc, "HEAD", "posts");
    defer gpa.free(head);
    try expectChoices(&.{ "retain", "blocked" }, head);
}

// `fixture_document` cannot show that the two `std.mem.sort` calls in
// `choicesFor` do anything: there, (path, verb) order and operation-id
// order coincide for every operation, so deleting both sorts leaves the
// suite green. This document breaks the coincidence in BOTH groups -- an
// id sorting first while its path sorts last, once inside the resource's
// own operations and once outside them -- so it pins the sorts and the
// group split at the same time.
test "choicesFor: each group is ordered by operation id, not by path" {
    const gpa = std.testing.allocator;
    const mixed =
        \\{"openapi":"3.1.2","paths":{
        \\ "/api/collections/posts/records":{"get":{"operationId":"listPosts"}},
        \\ "/api/collections/posts/records/{id}":{"get":{"operationId":"aardvarkView"}},
        \\ "/api/collections/users/records":{"get":{"operationId":"listUsers"}},
        \\ "/api/zzz/feed":{"get":{"operationId":"aardvarkFeed"}}}}
    ;
    const doc = try parse(gpa, mixed, "m.json");
    defer free(gpa, doc);

    // Document/path order is listPosts, aardvarkView, listUsers,
    // aardvarkFeed; id order within each group inverts both pairs, and the
    // resource's own two still come first.
    const out = try choicesFor(gpa, doc, "GET", "posts");
    defer gpa.free(out);
    try expectChoices(&.{ "aardvarkView", "listPosts", "aardvarkFeed", "listUsers", "retain", "blocked" }, out);
}

test "choicesFor: without a document the only choices are retain and blocked" {
    const gpa = std.testing.allocator;
    const out = try choicesFor(gpa, null, "POST", null);
    defer gpa.free(out);
    try expectChoices(&.{ "retain", "blocked" }, out);

    const with_resource = try choicesFor(gpa, null, "GET", "posts");
    defer gpa.free(with_resource);
    try expectChoices(&.{ "retain", "blocked" }, with_resource);
}

test "operationFor: names an operation, never retain/blocked/custom" {
    const gpa = std.testing.allocator;
    const doc = try parse(gpa, fixture_document, "openapi.json");
    defer free(gpa, doc);

    try std.testing.expectEqualStrings("listPosts", operationFor(doc, "listPosts").?.operation_id);
    try std.testing.expectEqual(Kind.list, operationFor(doc, "listPosts").?.kind);
    try std.testing.expectEqual(@as(?Operation, null), operationFor(doc, "retain"));
    try std.testing.expectEqual(@as(?Operation, null), operationFor(doc, "blocked"));
    try std.testing.expectEqual(@as(?Operation, null), operationFor(doc, "custom:/api/feed"));
    try std.testing.expectEqual(@as(?Operation, null), operationFor(doc, "listComments"));
}

test "parse under a FailingAllocator leaks nothing on any partial allocation" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 5000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (parse(gpa, fixture_document, "openapi.json")) |doc| {
            defer free(gpa, doc);
            try std.testing.expectEqual(@as(usize, 10), doc.operations.len);
            try std.testing.expectEqual(@as(usize, 1), doc.auth_collections.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "choicesFor under a FailingAllocator leaks nothing on any partial allocation" {
    const doc = try parse(std.testing.allocator, fixture_document, "openapi.json");
    defer free(std.testing.allocator, doc);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 100) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (choicesFor(gpa, doc, "GET", "posts")) |out| {
            defer gpa.free(out);
            try std.testing.expectEqual(@as(usize, 6), out.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
