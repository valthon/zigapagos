//! Turns the node streams `fragments.discoverTemplates` recovered (plus
//! `controllers.zig`'s layout facts) into `Finding`s: questions FOR THE
//! OPERATOR, each with a fixed, static set of answers (`choices`) rather
//! than a fact discovery itself already settled. That is the line that
//! separates this file from `blockers.zig`: a blocker is a statement about
//! what discovery could or couldn't establish (a Gemfile it couldn't read,
//! a route it couldn't resolve); a finding is a per-fragment decision this
//! run cannot make on the operator's behalf (keep this ERB helper as an
//! island, retire it, block the route). `RAILS_TEMPLATE_UNREADABLE` stays a
//! blocker (from the transitive scan) precisely because "the scan could not
//! read this file" has no choice to offer -- the route's true shape is
//! unknown until the read failure is fixed, so there is nothing to decide.
//!
//! **`fragments.Template.unreadable` is a different fact, and it IS a
//! finding** (R15). It means the TEMPLATES op refused a file the transitive
//! scan had already read successfully -- a symlink resolving outside the app
//! root, a permission the sidecar's own `File.read` hit, a non-string path.
//! No `RAILS_TEMPLATE_UNREADABLE` blocker exists for it (the scan follows
//! symlinks and was perfectly happy), and it contributes neither nodes nor a
//! parse error, so before `RAILS_TEMPLATE_UNSCANNED` such a view produced
//! literally nothing anywhere in the manifest -- a template silently exempt
//! from the presentation analysis, indistinguishable from a clean one. The
//! operator has a real choice here, which is what makes it a finding rather
//! than a blocker: retain the view as-is, or block the migration on it.
//!
//! **Ids, not array positions.** Task 11 (the manifest writer) needs to
//! reconcile a finding against a PREVIOUS run's recorded operator decision
//! even after the message text was reworded or nodes were re-ordered by a
//! template edit elsewhere in the file. `findingId` borrows rails2zb's own
//! reversible `%`/`.` escaping (`%` -> `%25`, then `.` -> `%2E`, in that
//! order so a literal `%25` in the input can never be mistaken for an
//! escaped `.`) so `<code>.<path>.<loc>` decodes unambiguously even though
//! `path` routinely contains `.` (`index.html.erb`) and, in principle,
//! `%`. `loc` folds line+col for a node (`"L3C5"`) or just line for a
//! parse error/layout (`"L4""`) into the same id shape, so every finding
//! kind still fits the one 3-part scheme.
//!
//! **The derivation table is the single source of truth.** `derive` is a
//! table-driven walk (`table.zig`-style would be a separate file; this one
//! is small enough to live as a `switch` per source -- nodes, then parse
//! errors, then layouts -- rather than a hand-duplicated `append` call per
//! `Kind`), so a code/severity/choices tuple is written once and read from
//! one place instead of drifting between a table comment and a switch body.

const std = @import("std");
const Allocator = std.mem.Allocator;
const blockers = @import("blockers.zig");
const fragments = @import("fragments.zig");
const controllers = @import("controllers.zig");

pub const Severity = blockers.Severity;

/// A per-fragment (or per-layout, or per-template) decision this run
/// surfaces to the operator rather than settling itself. See the module
/// doc for how this differs from `blockers.Blocker`.
///
/// Contract 2 (owned-result): `id`, `path`, and `message` are fresh `gpa`
/// allocations; `route_id` is a fresh allocation when non-null. `code` and
/// every `choices` slice are static string literals, never freed. Released
/// by `free`.
pub const Finding = struct {
    /// `<code>.<path>.<loc>` with `%`/`.` escaped; see `findingId`. Stable
    /// across a reworded `message` or a template edit elsewhere in the
    /// file, so Task 11 can reconcile against a prior recorded decision.
    id: []const u8,
    /// Stable, machine-greppable code from the derivation table. Always a
    /// static string literal -- never freed by `free`.
    code: []const u8,
    severity: Severity,
    /// Root-relative source path the finding concerns.
    path: []const u8,
    /// 1-based source line, when the trigger has one. Every Stage 1 row
    /// does (a node, a parse error, a layout declaration all carry a
    /// line), but the field stays optional because `lessThan`'s tie-break
    /// order treats "no line" as sorting first (`orelse 0`) and a future
    /// finding kind may not have one.
    line: ?u64,
    /// Owned when non-null. `null` for every Stage 1 finding: these are
    /// all template- or controller-scoped rather than tied to one route.
    route_id: ?[]const u8,
    /// Human detail, e.g. the helper/route-helper name. NOT part of `id`
    /// -- see the module doc -- so rewording this never invalidates a
    /// recorded decision.
    message: []const u8,
    /// The fixed set of answers an operator may record against this
    /// finding. Always a static string literal slice, never freed.
    choices: []const []const u8,
    /// Whether resolving this finding requires generating an artifact
    /// (e.g. an island component) rather than just recording a choice.
    /// `false` for every Stage 1 finding.
    requires_artifact: bool,
};

const choices_retain_blocked = [_][]const u8{ "retain", "blocked" };
const choices_island_retain_blocked = [_][]const u8{ "island", "retain", "blocked" };
const choices_island_spa_retain_blocked = [_][]const u8{ "island", "spa", "retain", "blocked" };
const choices_full = [_][]const u8{ "island", "spa", "backend", "retain", "blocked" };

/// Contract 1 (self-freeing): the only allocation is the returned buffer,
/// which escapes to the caller; nothing else is retained. Maps `%` to
/// `%25` and then `.` to `%2E` (in that order -- doing `.` first would let
/// the `%` an escaped-`.` introduces be mistaken for the start of a
/// SECOND escape sequence on a later pass), which is what makes the
/// mapping reversible: a decoder can undo `%2E` -> `.` and then
/// `%25` -> `%` and land exactly back on `part`.
pub fn escapePart(gpa: Allocator, part: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (part) |c| {
        switch (c) {
            '%' => try out.appendSlice(gpa, "%25"),
            '.' => try out.appendSlice(gpa, "%2E"),
            else => try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Contract 1 (self-freeing): every intermediate `escapePart` result is
/// freed before returning; only the joined buffer escapes.
pub fn findingId(gpa: Allocator, code: []const u8, path: []const u8, loc: []const u8) Allocator.Error![]u8 {
    const code_esc = try escapePart(gpa, code);
    defer gpa.free(code_esc);
    const path_esc = try escapePart(gpa, path);
    defer gpa.free(path_esc);
    const loc_esc = try escapePart(gpa, loc);
    defer gpa.free(loc_esc);
    return std.fmt.allocPrint(gpa, "{s}.{s}.{s}", .{ code_esc, path_esc, loc_esc });
}

/// Total order over `(code, path, line orelse 0, id)`. `id` is the key that
/// makes the tuple total, and it is unique because `loc` is:
///
/// - A node finding's `loc` is `L<line>C<col>`, where `col` is the fragment's
///   TRUE 1-based source column -- `templates.rb`'s `col_map` maps Prism's
///   generated-program column back through the compiled program (ruling
///   R17). Two distinct fragments cannot begin at the same byte of the same
///   line, so two node findings on one line always differ in `col`.
/// - A parse-error, layout or unscanned-template finding's `loc` is
///   `L<line>` or `"unscanned"`, and each of those sources yields at most
///   one finding per (code, path, line) by construction: one parse error per
///   template, one `layout` declaration per controller line, one
///   `fragments.Template` per path.
///
/// That is what this comparator needs, and why it needs no fifth key:
/// `std.mem.sort` is not guaranteed stable, so two distinct elements it
/// considers equal would order either way between runs. It is not a
/// hypothetical -- before R17 a tag holding several statements gave every
/// statement after the first `col: 0`, and
/// `<% number_to_currency(1); pluralize(2) %>` produced exactly that pair.
///
/// Contract 3 (caller-buffer): takes no allocator and allocates nothing.
pub fn lessThan(_: void, a: Finding, b: Finding) bool {
    const code_order = std.mem.order(u8, a.code, b.code);
    if (code_order != .eq) return code_order == .lt;
    const path_order = std.mem.order(u8, a.path, b.path);
    if (path_order != .eq) return path_order == .lt;
    const a_line = a.line orelse 0;
    const b_line = b.line orelse 0;
    if (a_line != b_line) return a_line < b_line;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// Contract 2 counterpart to `derive`: releases `id`/`path`/`message` and
/// (when non-null) `route_id` on every finding plus the slice itself. Does
/// not free `code` or `choices` -- both point at static literals owned by
/// the derivation table, never duplicated.
pub fn free(gpa: Allocator, list: []Finding) void {
    for (list) |f| {
        gpa.free(f.id);
        gpa.free(f.path);
        gpa.free(f.message);
        if (f.route_id) |rid| gpa.free(rid);
    }
    gpa.free(list);
}

pub const ControllerFile = struct { controller: []const u8, path: []const u8 };

pub const DeriveInput = struct {
    templates: []const fragments.Template,
    layouts: []const controllers.LayoutInfo,
    /// `{controller, path}` pairs from the inventory, consulted only for
    /// `RAILS_LAYOUT_DYNAMIC`'s `path` -- a `LayoutInfo` names its
    /// controller, not the file it came from.
    controller_files: []const ControllerFile,
    /// Names of `certain` routes (Stage 4's route classification), used to
    /// decide whether a `.route_helper`/`.link_to` node's `name` matches a
    /// route this run actually resolved.
    route_names: []const []const u8,
    /// The I18n locale `fragments.discoverTemplates` loaded (its `Result.
    /// locale`), threaded through only for `RAILS_I18N_UNRESOLVED`'s
    /// message. `null` when the sidecar could not determine one, in which
    /// case the parenthetical is simply omitted.
    locale: ?[]const u8,
    /// R16: the `config/locales/**` files that failed to load this run
    /// (`fragments.Result.i18n_errors`' paths). Non-empty means the
    /// translation table is empty or partial through no fault of any
    /// template, so every `RAILS_I18N_UNRESOLVED` message says so -- see
    /// `deriveNode`'s `.i18n` arm. Defaulted empty because that is the
    /// ordinary case AND the safe one: a caller that forgets it gets the
    /// pre-R16 message, never a wrong claim about a locale file.
    i18n_error_paths: []const []const u8 = &.{},
};

/// True when `name` is not present in `route_names` -- a linear scan, not a
/// set, because `route_names` is the size of one app's route table (tens
/// to low hundreds of entries), scanned once per route-helper/link_to node
/// in one discovery run. Building a hash set for that would trade a
/// negligible constant-time win for an allocation this function would then
/// have to own and free.
fn routeNameUnknown(route_names: []const []const u8, name: []const u8) bool {
    for (route_names) |rn| {
        if (std.mem.eql(u8, rn, name)) return false;
    }
    return true;
}

/// Builds one `Finding`: computes `id` via `findingId`, dupes `path` and
/// the already-formatted `message`, and appends. Every derivation-table row
/// funnels through this one function so `id` construction and the
/// owned/static split (`code`/`choices` are never dupe'd; `path`/`message`
/// always are) is written once.
///
/// Contract 2 (owned-result), inherited from `derive`: on `OutOfMemory`,
/// every allocation this call made is freed via `errdefer` before
/// propagating, so a failed `appendFinding` never leaves `list` holding a
/// half-built entry.
fn appendFinding(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Finding),
    code: []const u8,
    severity: Severity,
    path: []const u8,
    line: ?u64,
    loc: []const u8,
    message: []const u8,
    choices: []const []const u8,
) Allocator.Error!void {
    const id = try findingId(gpa, code, path, loc);
    errdefer gpa.free(id);
    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);
    const message_copy = try gpa.dupe(u8, message);
    errdefer gpa.free(message_copy);
    try list.append(gpa, .{
        .id = id,
        .code = code,
        .severity = severity,
        .path = path_copy,
        .line = line,
        .route_id = null,
        .message = message_copy,
        .choices = choices,
        .requires_artifact = false,
    });
}

/// Formats `"L<line>C<col>"` for a node loc, or `"L<line>"` for a parse
/// error/layout loc.
///
/// Contract 1 (self-freeing): the only allocation is the returned buffer.
fn nodeLoc(gpa: Allocator, line: u64, col: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "L{d}C{d}", .{ line, col });
}

fn lineLoc(gpa: Allocator, line: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "L{d}", .{line});
}

/// The `loc` for a finding whose trigger has no source position at all: the
/// templates op never read the file, so there is no line and no column to
/// name. A word rather than an `L<n>` because every `L<n>` in an id is a
/// promise that someone can open the file at that line -- see the R15 row in
/// `derive`.
const unscanned_loc = "unscanned";

/// Handles the node-triggered rows of the derivation table for one
/// template. Split out of `derive` because it is the one source with
/// several codes keyed off `Kind`, so this is where the table's node rows
/// live as a `switch` rather than duplicated across `derive`'s body.
///
/// Contract 2 (owned-result), inherited from `derive`.
fn deriveNode(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Finding),
    path: []const u8,
    node: fragments.Node,
    route_names: []const []const u8,
    locale: ?[]const u8,
    in_i18n_error_paths: []const []const u8,
) Allocator.Error!void {
    // A text run (`node.text != null`) is never a finding candidate: per
    // `fragments.zig`'s `Node` doc, a text run's `kind` is always `.unknown`
    // as a side effect of the wire decode (there is no real `Kind` for
    // literal template output), not because the sidecar recognised and then
    // failed to classify a helper call. Dispatching on `kind` alone would
    // fire `RAILS_HELPER_UNKNOWN` for the plain HTML between ERB tags --
    // the majority of nodes in any real template.
    if (node.text != null) return;
    switch (node.kind) {
        .unknown => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "unknown helper `{s}`", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_HELPER_UNKNOWN", .warn, path, node.line, loc, message, &choices_island_retain_blocked);
        },
        .request_state, .ivar => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "request-time state `{s}`", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_REQUEST_TIME_STATE", .warn, path, node.line, loc, message, &choices_full);
        },
        .i18n => {
            if (!node.missing) return;
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const key = node.name orelse "";
            const base = if (locale) |l|
                try std.fmt.allocPrint(gpa, "missing translation `{s}` (locale {s})", .{ key, l })
            else
                try std.fmt.allocPrint(gpa, "missing translation `{s}`", .{key});
            defer gpa.free(base);
            // R16: with a locale file broken, `missing` says far less than it
            // normally does -- the table it was looked up in is empty or
            // partial. Still the same code and the same choices (the key
            // genuinely does not resolve, and the operator still has to
            // answer); what changes is that the message stops implying the
            // template is at fault. Only the FIRST path is named: this is one
            // sentence of context on a per-key finding, not the locale
            // report, and the blockers carry every file individually.
            const message = if (in_i18n_error_paths.len > 0)
                try std.fmt.allocPrint(gpa, "{s} — a locale file failed to load: {s}", .{ base, in_i18n_error_paths[0] })
            else
                try gpa.dupe(u8, base);
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_I18N_UNRESOLVED", .warn, path, node.line, loc, message, &choices_retain_blocked);
        },
        .raw => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            try appendFinding(gpa, list, "RAILS_RAW_OUTPUT", .warn, path, node.line, loc, "unescaped output", &choices_island_retain_blocked);
        },
        .render_dynamic => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "dynamic render target `{s}`", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_PARTIAL_DYNAMIC", .warn, path, node.line, loc, message, &choices_island_spa_retain_blocked);
        },
        .route_helper_dynamic => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "route helper `{s}` has non-literal arguments", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_ROUTE_HELPER_DYNAMIC", .warn, path, node.line, loc, message, &choices_island_spa_retain_blocked);
        },
        .route_helper, .link_to => {
            const name = node.name orelse return;
            if (!routeNameUnknown(route_names, name)) return;
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const message = try std.fmt.allocPrint(gpa, "route helper `{s}` matches no certain named route", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_ROUTE_HELPER_UNKNOWN", .warn, path, node.line, loc, message, &choices_retain_blocked);
        },
        .control => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "control flow `{s}`", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_TEMPLATE_CONTROL_FLOW", .warn, path, node.line, loc, message, &choices_island_spa_retain_blocked);
        },
        else => {},
    }
}

/// Walks `in.templates` (node findings, then a parse-error finding per
/// broken template) and then `in.layouts` (`RAILS_LAYOUT_DYNAMIC`),
/// appending in that order; `std.mem.sort` with `lessThan` at the end is
/// what actually fixes the final order, so the walk order here only needs
/// to be complete, not sorted.
///
/// Contract 2 (owned-result): the returned slice and every finding's owned
/// fields are released by `free`. `OutOfMemory` propagates from any inner
/// `try` -- `list.deinit` on the way out is unnecessary because every
/// element already in `list` at that point was built by `appendFinding`,
/// which itself cleans up its own partial allocation via `errdefer` before
/// ever reaching `list.append`; the ArrayList's backing buffer is
/// `Allocator.Error`-safe to simply abandon (the GPA -- or the
/// `FailingAllocator` wrapping it in tests -- reclaims it, same as any
/// other still-live allocation an aborted function leaves behind).
pub fn derive(gpa: Allocator, in: DeriveInput) Allocator.Error![]Finding {
    var list: std.ArrayListUnmanaged(Finding) = .empty;
    errdefer {
        for (list.items) |f| {
            gpa.free(f.id);
            gpa.free(f.path);
            gpa.free(f.message);
            if (f.route_id) |rid| gpa.free(rid);
        }
        list.deinit(gpa);
    }

    for (in.templates) |tpl| {
        for (tpl.nodes) |node| {
            try deriveNode(gpa, &list, tpl.path, node, in.route_names, in.locale, in.i18n_error_paths);
        }
        if (tpl.error_message) |em| {
            const line = tpl.error_line orelse 0;
            const loc = try lineLoc(gpa, line);
            defer gpa.free(loc);
            const message = try std.fmt.allocPrint(gpa, "template does not parse: {s}", .{em});
            defer gpa.free(message);
            try appendFinding(gpa, &list, "RAILS_TEMPLATE_PARSE_ERROR", .@"error", tpl.path, tpl.error_line, loc, message, &choices_retain_blocked);
        }
        // R15: the templates op refused this file outright (see the module
        // doc). `line` is null and `loc` is a word rather than an `L<n>`
        // because nothing here HAS a line -- the file was never parsed, and a
        // stand-in `L1` would point someone at the first line of a file that
        // was never read. `unscanned` still keeps the id's three-part shape,
        // and one template yields at most one of these, so it is unique per
        // (code, path) the way every other `loc` is.
        if (tpl.unreadable) |why| {
            const message = try std.fmt.allocPrint(gpa, "template was not analysed: {s}", .{why});
            defer gpa.free(message);
            try appendFinding(gpa, &list, "RAILS_TEMPLATE_UNSCANNED", .warn, tpl.path, null, unscanned_loc, message, &choices_retain_blocked);
        }
    }

    for (in.layouts) |layout| {
        if (!layout.dynamic) continue;
        var path: []const u8 = layout.controller;
        for (in.controller_files) |cf| {
            if (std.mem.eql(u8, cf.controller, layout.controller)) {
                path = cf.path;
                break;
            }
        }
        const loc = try lineLoc(gpa, layout.line);
        defer gpa.free(loc);
        try appendFinding(gpa, &list, "RAILS_LAYOUT_DYNAMIC", .warn, path, layout.line, loc, "controller declares a dynamic layout", &choices_retain_blocked);
    }

    const out = try list.toOwnedSlice(gpa);
    std.mem.sort(Finding, out, {}, lessThan);
    return out;
}

test "findingId escapes the separator reversibly" {
    const gpa = std.testing.allocator;
    const id = try findingId(gpa, "RAILS_HELPER_UNKNOWN", "app/views/posts/index.html.erb", "L3C5");
    defer gpa.free(id);
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/posts/index%2Ehtml%2Eerb.L3C5", id);
    const pct = try escapePart(gpa, "a%b.c");
    defer gpa.free(pct);
    try std.testing.expectEqualStrings("a%25b%2Ec", pct);
}

test "derive: one finding per triggering node, with code/choices/loc from the table, sorted" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        nodeText("<h1>", 1),
        nodeCode(.request_state, 2, 3, "current_user"),
        nodeCode(.unknown, 1, 9, "number_to_currency"),
        nodeCode(.route_helper, 4, 1, "root"),
        nodeCode(.route_helper, 5, 1, "ghost"),
        nodeCode(.link_to, 6, 1, "posts"),
        nodeCode(.raw, 7, 1, null),
    };
    var missing = nodeCode(.i18n, 8, 1, "posts.index.nope");
    missing.missing = true;
    const all = nodes ++ [_]fragments.Node{missing};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&all), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/posts/broken.html.erb", .nodes = &.{}, .error_message = "unexpected end", .error_line = 4, .unreadable = null },
    };
    const layouts = [_]controllers.LayoutInfo{
        .{ .controller = "posts", .value = null, .disabled = false, .dynamic = true, .line = 2 },
        .{ .controller = "pages", .value = "marketing", .disabled = false, .dynamic = false, .line = 2 },
    };
    const files = [_]ControllerFile{
        .{ .controller = "posts", .path = "app/controllers/posts_controller.rb" },
        .{ .controller = "pages", .path = "app/controllers/pages_controller.rb" },
    };
    const names = [_][]const u8{ "root", "posts" };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &layouts, .controller_files = &files, .route_names = &names, .locale = "en" });
    defer free(gpa, out);

    const expect_codes = [_][]const u8{
        "RAILS_HELPER_UNKNOWN",
        "RAILS_I18N_UNRESOLVED",
        "RAILS_LAYOUT_DYNAMIC",
        "RAILS_RAW_OUTPUT",
        "RAILS_REQUEST_TIME_STATE",
        "RAILS_ROUTE_HELPER_UNKNOWN",
        "RAILS_TEMPLATE_PARSE_ERROR",
    };
    try std.testing.expectEqual(expect_codes.len, out.len);
    for (expect_codes, out) |c, f| try std.testing.expectEqualStrings(c, f.code);

    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/posts/index%2Ehtml%2Eerb.L1C9", out[0].id);
    try std.testing.expectEqualStrings("app/controllers/posts_controller.rb", out[2].path);
    try std.testing.expectEqual(@as(?u64, 2), out[2].line);
    try std.testing.expectEqualStrings("ghost", out[5].message[std.mem.indexOf(u8, out[5].message, "ghost").?..][0..5]);
    try std.testing.expectEqual(blockers.Severity.@"error", out[6].severity);
    try std.testing.expectEqualStrings("retain", out[6].choices[0]);
    try std.testing.expect(out[0].route_id == null);
    try std.testing.expect(!out[0].requires_artifact);
}

test "derive: input order does not leak into output -- ids and order are identical either way" {
    const gpa = std.testing.allocator;
    const a_nodes = [_]fragments.Node{ nodeCode(.unknown, 3, 1, "foo"), nodeCode(.raw, 1, 1, null) };
    const b_nodes = [_]fragments.Node{ nodeCode(.raw, 1, 1, null), nodeCode(.unknown, 3, 1, "foo") };
    const tpl_a = [_]fragments.Template{
        .{ .path = "app/views/b.html.erb", .nodes = @constCast(&a_nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/a.html.erb", .nodes = @constCast(&a_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const tpl_b = [_]fragments.Template{
        .{ .path = "app/views/a.html.erb", .nodes = @constCast(&b_nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/b.html.erb", .nodes = @constCast(&b_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out_a = try derive(gpa, .{ .templates = &tpl_a, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out_a);
    const out_b = try derive(gpa, .{ .templates = &tpl_b, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out_b);
    try std.testing.expectEqual(@as(usize, 4), out_a.len);
    try std.testing.expectEqual(out_a.len, out_b.len);
    for (out_a, out_b) |x, y| try std.testing.expectEqualStrings(x.id, y.id);
    // (code, path, line, id): both HELPER_UNKNOWN rows sort before both RAW_OUTPUT rows, a.html before b.html within a code.
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/a%2Ehtml%2Eerb.L3C1", out_a[0].id);
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/b%2Ehtml%2Eerb.L3C1", out_a[1].id);
    try std.testing.expectEqualStrings("RAILS_RAW_OUTPUT.app/views/a%2Ehtml%2Eerb.L1C1", out_a[2].id);
}

// Self-review addition: covers the derivation-table rows the two briefed
// tests above never trigger -- `route_helper_dynamic`, `.control`, a
// template `error_message` with `error_line == null`, and a `link_to`
// with a name absent from `route_names` (the briefed test only exercises
// this branch via `.route_helper`).
test "derive: render_dynamic, route_helper_dynamic, control, link_to-unknown, and a null-line parse error" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        nodeCode(.render_dynamic, 1, 1, "partial_name"),
        nodeCode(.route_helper_dynamic, 2, 1, "posts_path"),
        nodeCode(.control, 3, 1, "if"),
        nodeCode(.link_to, 4, 1, "ghost_path"),
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/x.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/y.html.erb", .nodes = &.{}, .error_message = "premature end of input", .error_line = null, .unreadable = null },
    };
    const names = [_][]const u8{"root"};
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &names, .locale = null });
    defer free(gpa, out);

    const expect_codes = [_][]const u8{
        "RAILS_PARTIAL_DYNAMIC",
        "RAILS_ROUTE_HELPER_DYNAMIC",
        "RAILS_ROUTE_HELPER_UNKNOWN",
        "RAILS_TEMPLATE_CONTROL_FLOW",
        "RAILS_TEMPLATE_PARSE_ERROR",
    };
    try std.testing.expectEqual(expect_codes.len, out.len);
    for (expect_codes, out) |c, f| try std.testing.expectEqualStrings(c, f.code);
    try std.testing.expect(std.mem.indexOf(u8, out[0].message, "partial_name") != null);

    // A null `error_line` still gets a finding, with `line = null` on the
    // `Finding` even though the id's loc folds it to "L0".
    const parse_err = out[4];
    try std.testing.expectEqual(@as(?u64, null), parse_err.line);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_PARSE_ERROR.app/views/y%2Ehtml%2Eerb.L0", parse_err.id);
    try std.testing.expect(std.mem.indexOf(u8, parse_err.message, "premature end of input") != null);
}

// Fix round 1 (Task 9 review, Critical): a real text run decodes with
// `kind = .unknown` (see `fragments.zig`'s `dupeNode`, `is_text` branch,
// and the `Node` doc's "must not be read" note) -- NOT a dedicated
// `.literal` tag the way the brief's own `nodeText` helper used to
// construct it. `deriveNode` dispatching on `node.kind` alone, with no
// `node.text` guard, therefore fired `RAILS_HELPER_UNKNOWN` for every
// plain-HTML text run in every template -- the majority of nodes in any
// real template. This pins the fix: a node shaped exactly like the real
// decode of `<h1>Posts</h1>` must yield zero findings.
test "derive: a real text run (kind .unknown, text set) yields no findings" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        nodeText("<h1>Posts</h1>", 1),
        nodeText("", 2),
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// Mirrors fragments.zig's dupeNode's ACTUAL decode of a wire text run
// (fragments.zig, is_text branch), not an idealised one: kind is
// .unknown there too -- there is no real Kind tag for literal text, so
// the decoder leaves it at the enum's fallback value and the Node doc
// says explicitly that kind "must not be read" when text != null.
// Fix round 1 (Task 9 review, Critical): this helper used to hand-pick
// .literal here, a Kind fragments.zig never actually produces for a
// text run, which is exactly why the RAILS_HELPER_UNKNOWN-on-every-text-
// node defect this helper should have caught went uncaught.
fn nodeText(text: []const u8, line: u64) fragments.Node {
    return .{ .text = text, .kind = .unknown, .line = line, .col = 0, .output = false, .code = "", .name = null, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}
fn nodeCode(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8) fragments.Node {
    return .{ .text = null, .kind = kind, .line = line, .col = col, .output = true, .code = "", .name = name, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}

// Every code the derivation table can produce, in one place, so a future
// row addition without a matching test here is at least visible in a
// diff of this list rather than silently uncovered.
test "lessThan orders ties by id when code/path/line all match" {
    var a = Finding{ .id = "A", .code = "C", .severity = .warn, .path = "p", .line = 1, .route_id = null, .message = "m", .choices = &choices_retain_blocked, .requires_artifact = false };
    var b = a;
    b.id = "B";
    try std.testing.expect(lessThan({}, a, b));
    try std.testing.expect(!lessThan({}, b, a));
    a.line = null;
    b.line = null;
    try std.testing.expect(lessThan({}, a, b));
}

// Ruling R16 (review finding 2): when a locale file failed to load, the
// translation table is empty (or partial) and EVERY `t()` key looks missing.
// The finding is still real -- the key does not resolve, and the operator
// still has to answer retain-or-blocked -- but its message must not read as
// "this key is absent from the translations" when the translations never
// loaded. Same code, same choices, honest reason.
test "derive: a failed locale file qualifies every RAILS_I18N_UNRESOLVED message" {
    const gpa = std.testing.allocator;
    var missing = nodeCode(.i18n, 1, 5, "posts.index.nope");
    missing.missing = true;
    const nodes = [_]fragments.Node{missing};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const broken = [_][]const u8{ "config/locales/en.yml", "config/locales/de.yml" };
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = "en",
        .i18n_error_paths = &broken,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings(
        "missing translation `posts.index.nope` (locale en) — a locale file failed to load: config/locales/en.yml",
        out[0].message,
    );
    // The id is untouched: `message` is prose and deliberately not part of
    // it, so a decision recorded against this finding survives the locale
    // file being fixed.
    try std.testing.expectEqualStrings("RAILS_I18N_UNRESOLVED.app/views/posts/index%2Ehtml%2Eerb.L1C5", out[0].id);
}

// Ruling R15 (review finding 1): a view the templates op REFUSED --
// `unreadable` set, e.g. a symlink resolving outside the app root -- used to
// vanish. It contributes no nodes and no parse error, so `derive` produced
// nothing for it; the transitive scan had already read the same file
// successfully (it follows symlinks), so no `RAILS_TEMPLATE_UNREADABLE`
// blocker fired either. The manifest said nothing at all about a template
// nothing had analysed.
test "derive: a template the templates op refused becomes one RAILS_TEMPLATE_UNSCANNED finding" {
    const gpa = std.testing.allocator;
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/pages/linked.html.erb", .nodes = &.{}, .error_message = null, .error_line = null, .unreadable = "outside root" },
        // A neighbour that scanned fine, so this pins that the row keys off
        // `unreadable` rather than off "this template produced no findings".
        .{ .path = "app/views/pages/ok.html.erb", .nodes = &.{}, .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_UNSCANNED", out[0].code);
    // `loc` is not a line: there is no line to point at, and a fabricated
    // `L1` would send someone to the top of a file that was never read.
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_UNSCANNED.app/views/pages/linked%2Ehtml%2Eerb.unscanned", out[0].id);
    try std.testing.expectEqual(Severity.warn, out[0].severity);
    try std.testing.expectEqual(@as(?u64, null), out[0].line);
    try std.testing.expectEqualStrings("app/views/pages/linked.html.erb", out[0].path);
    // The sidecar's own reason rides through verbatim -- it is the only
    // evidence there is about why nothing was analysed.
    try std.testing.expectEqualStrings("template was not analysed: outside root", out[0].message);
    try std.testing.expectEqual(@as(usize, 2), out[0].choices.len);
    try std.testing.expectEqualStrings("retain", out[0].choices[0]);
    try std.testing.expectEqualStrings("blocked", out[0].choices[1]);
    try std.testing.expect(out[0].route_id == null);
    try std.testing.expect(!out[0].requires_artifact);
}

// Ruling R17 (review finding 3): `lessThan`'s total order rests entirely on
// `id` being unique, and `id` is only as unique as `col`. `templates.rb` used
// to report `col: 0` for every statement in a tag after the first, so
// `<% number_to_currency(1); pluralize(2) %>` arrived here as two nodes at
// (1, 0) and (1, 0) and derived the SAME id -- two distinct elements
// `std.mem.sort` (not guaranteed stable) considers equal, i.e. a manifest
// whose finding order is a coin flip. This pins the property from the
// consumer side; the producer side is pinned in `templates_test.rb`.
test "derive: two nodes on one line with different columns get different ids" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        nodeCode(.unknown, 1, 4, "number_to_currency"),
        nodeCode(.unknown, 1, 27, "pluralize"),
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/x.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    // The tie-break is lexicographic over the whole `id`, not numeric over
    // the column, so `L1C27` sorts before `L1C4`. Deterministic is all the
    // order has to be.
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/x%2Ehtml%2Eerb.L1C27", out[0].id);
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/x%2Ehtml%2Eerb.L1C4", out[1].id);
    // Exactly one of the two directions holds -- what a strict weak ordering
    // requires of two distinct elements, and what a duplicate id destroys.
    try std.testing.expect(lessThan({}, out[0], out[1]) != lessThan({}, out[1], out[0]));
}

test "derive under a FailingAllocator leaks nothing on any partial allocation" {
    const nodes = [_]fragments.Node{
        nodeCode(.unknown, 1, 1, "foo"),
        nodeCode(.raw, 2, 1, null),
    };
    var missing = nodeCode(.i18n, 3, 1, "greeting");
    missing.missing = true;
    const all = nodes ++ [_]fragments.Node{missing};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/x.html.erb", .nodes = @constCast(&all), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/broken.html.erb", .nodes = &.{}, .error_message = "bad", .error_line = 9, .unreadable = null },
        // R15's row allocates a formatted message like every other row, so
        // it belongs in the sweep too.
        .{ .path = "app/views/gone.html.erb", .nodes = &.{}, .error_message = null, .error_line = null, .unreadable = "outside root" },
    };
    const layouts = [_]controllers.LayoutInfo{
        .{ .controller = "posts", .value = null, .disabled = false, .dynamic = true, .line = 5 },
    };
    const files = [_]ControllerFile{
        .{ .controller = "posts", .path = "app/controllers/posts_controller.rb" },
    };

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 1000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (derive(failing.allocator(), .{ .templates = &tpls, .layouts = &layouts, .controller_files = &files, .route_names = &.{}, .locale = "en" })) |out| {
            defer free(std.testing.allocator, out);
            try std.testing.expectEqual(@as(usize, 6), out.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
