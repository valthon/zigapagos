//! Stage 5 parity evidence derived from discovery facts and scaffold outcomes.
//! The fixed runners consume these rows; this module contains no runner code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const backend = @import("backend.zig");
const convert = @import("convert.zig");
const decisions = @import("decisions.zig");
const findings = @import("findings.zig");
const fragments = @import("fragments.zig");
const handoff = @import("handoff.zig");
const rails = @import("rails.zig");
const resolve = @import("resolve.zig");
const scaffold = @import("scaffold.zig");

pub const Result = struct { entries: []handoff.ParityEntry };

fn freeStrings(gpa: Allocator, values: []const []const u8) void {
    for (values) |value| gpa.free(value);
    gpa.free(values);
}

fn freeFields(gpa: Allocator, values: []const handoff.RequestField) void {
    for (values) |value| {
        gpa.free(value.name);
        gpa.free(value.value);
        if (value.invalid_value) |invalid| gpa.free(invalid);
    }
    gpa.free(values);
}

fn freeEntry(gpa: Allocator, entry: handoff.ParityEntry) void {
    switch (entry) {
        .navigate => |row| {
            gpa.free(row.id);
            gpa.free(row.url);
            if (row.expect.title) |title| gpa.free(title);
            if (row.expect.h1) |h1| gpa.free(h1);
            freeStrings(gpa, row.expect.links);
        },
        .asset => |row| {
            gpa.free(row.id);
            gpa.free(row.url);
            gpa.free(row.expect.content_type);
            if (row.expect.rails_url) |url| gpa.free(url);
        },
        .signup => |row| {
            gpa.free(row.id);
            gpa.free(row.url);
            gpa.free(row.expect.collection);
            gpa.free(row.expect.page_url);
        },
        .signin => |row| {
            gpa.free(row.id);
            gpa.free(row.url);
            gpa.free(row.expect.collection);
            gpa.free(row.expect.page_url);
        },
        .submit_allowed => |row| {
            gpa.free(row.id);
            gpa.free(row.url);
            gpa.free(row.expect.operation_id);
            gpa.free(row.expect.method);
            if (row.expect.collection) |collection| gpa.free(collection);
            gpa.free(row.expect.page_url);
            freeFields(gpa, row.expect.fields);
        },
        .submit_denied => |row| {
            gpa.free(row.id);
            gpa.free(row.url);
            gpa.free(row.expect.statuses);
            gpa.free(row.expect.operation_id);
            gpa.free(row.expect.method);
            if (row.expect.collection) |collection| gpa.free(collection);
            freeFields(gpa, row.expect.fields);
        },
        .validation_error => |row| {
            gpa.free(row.id);
            gpa.free(row.url);
            gpa.free(row.expect.operation_id);
            gpa.free(row.expect.method);
            if (row.expect.collection) |collection| gpa.free(collection);
            gpa.free(row.expect.page_url);
            gpa.free(row.expect.field);
            freeFields(gpa, row.expect.fields);
        },
    }
}

pub fn free(gpa: Allocator, result: Result) void {
    for (result.entries) |entry| freeEntry(gpa, entry);
    gpa.free(result.entries);
}

fn findTemplate(list: []const fragments.Template, path: []const u8) ?fragments.Template {
    for (list) |template| if (std.mem.eql(u8, template.path, path)) return template;
    return null;
}

fn appendUniqueOwned(gpa: Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) Allocator.Error!void {
    for (list.items) |have| if (std.mem.eql(u8, have, value)) return;
    const copy = try gpa.dupe(u8, value);
    errdefer gpa.free(copy);
    try list.append(gpa, copy);
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn blockEnd(nodes: []const fragments.Node, open: usize) ?usize {
    var depth: usize = 0;
    for (nodes[open..], open..) |node, i| {
        if (node.text == null and convert.opensBlock(node)) depth += 1;
        if (node.text == null and node.kind == .block_end) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn literalTitle(template: fragments.Template) ?[]const u8 {
    for (template.nodes, 0..) |node, i| {
        if (node.text != null or node.kind != .content_for) continue;
        if (!std.mem.eql(u8, node.name orelse "", "title")) continue;
        if (node.value) |value| return value;
        const end = blockEnd(template.nodes, i) orelse continue;
        var found: ?[]const u8 = null;
        for (template.nodes[i + 1 .. end]) |child| {
            const value = if (child.text) |text|
                std.mem.trim(u8, text, " \t\r\n")
            else switch (child.kind) {
                .literal => child.value orelse return null,
                .i18n => if (child.missing) return null else child.value orelse return null,
                else => return null,
            };
            if (value.len == 0) continue;
            if (found != null) return null;
            found = value;
        }
        return found;
    }
    return null;
}

const Presentation = struct {
    title: ?[]const u8,
    h1: ?[]const u8,
    links: [][]const u8,
};

fn decisionReplacesRegion(discovery: *const rails.Discovery, template: fragments.Template, node: fragments.Node) bool {
    if (!convert.opensBlock(node)) return false;
    switch (node.kind) {
        .request_state, .ivar, .errors, .form, .component_root => {},
        else => return false,
    }
    const finding_id = convert.findingIdFor(discovery.findings, template.path, node.line, node.col) orelse return false;
    const decision = decisions.lookup(discovery.decisions, finding_id) orelse return false;
    return !std.mem.eql(u8, decision.choice, "retain") and
        !std.mem.eql(u8, decision.choice, "blocked") and
        !std.mem.eql(u8, decision.choice, "inline");
}

fn nodeIsSuppressed(discovery: *const rails.Discovery, template: fragments.Template, target: usize) bool {
    if (target >= template.nodes.len) return true;
    var suppressed_depth: usize = 0;
    for (template.nodes, 0..) |node, i| {
        if (suppressed_depth > 0) {
            if (i == target) return true;
            if (node.text == null and convert.opensBlock(node)) suppressed_depth += 1;
            if (node.text == null and node.kind == .block_end) suppressed_depth -= 1;
            continue;
        }
        if (decisionReplacesRegion(discovery, template, node)) {
            if (i == target) return true;
            suppressed_depth = 1;
        }
    }
    return false;
}

fn hasReplacedRegion(discovery: *const rails.Discovery, template: fragments.Template) bool {
    for (template.nodes) |node| if (decisionReplacesRegion(discovery, template, node)) return true;
    return false;
}

fn factIsWritten(discovery: *const rails.Discovery, template: fragments.Template, node_index: ?usize) bool {
    if (node_index) |index| return !nodeIsSuppressed(discovery, template, index);
    // Older sidecars did not position presentation facts. They remain safe
    // only when no decision replaces any region in this template.
    return !hasReplacedRegion(discovery, template);
}

fn presentationFor(gpa: Allocator, discovery: *const rails.Discovery, route_index: usize) Allocator.Error!Presentation {
    var links: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (links.items) |link| gpa.free(link);
        links.deinit(gpa);
    }
    var h1_src: ?[]const u8 = null;
    var title_src: ?[]const u8 = null;
    if (route_index < discovery.route_templates.len) {
        const rt = discovery.route_templates[route_index];
        const route = discovery.routes[route_index];
        const view_path = resolve.viewFor(rt.templates, route.controller, route.action);
        if (view_path) |path| if (findTemplate(discovery.fragments, path)) |view| {
            if (factIsWritten(discovery, view, view.parity_h1_node)) h1_src = view.parity_h1;
            title_src = literalTitle(view) orelse h1_src;
        };

        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer paths.deinit(gpa);
        try paths.appendSlice(gpa, rt.templates);
        if (rt.layout) |layout| try paths.append(gpa, layout);
        for (paths.items) |path| {
            const template = findTemplate(discovery.fragments, path) orelse continue;
            if (h1_src == null and factIsWritten(discovery, template, template.parity_h1_node)) h1_src = template.parity_h1;
            for (template.parity_links, 0..) |link, i| {
                const node_index: ?usize = if (i < template.parity_link_nodes.len) template.parity_link_nodes[i] else null;
                if (factIsWritten(discovery, template, node_index)) try appendUniqueOwned(gpa, &links, link);
            }
            var suppressed_depth: usize = 0;
            for (template.nodes) |node| {
                if (suppressed_depth > 0) {
                    if (node.text == null and convert.opensBlock(node)) suppressed_depth += 1;
                    if (node.text == null and node.kind == .block_end) suppressed_depth -= 1;
                    continue;
                }
                if (decisionReplacesRegion(discovery, template, node)) {
                    suppressed_depth = 1;
                    continue;
                }
                if (node.text != null or node.kind != .link_to) continue;
                if (node.name) |stem| {
                    const args = if (node.args.len > 0) node.args[1..] else &.{};
                    const url = try resolve.routeUrl(gpa, discovery.routes, stem, args) orelse continue;
                    defer gpa.free(url);
                    try appendUniqueOwned(gpa, &links, url);
                } else if (node.args.len > 1) {
                    try appendUniqueOwned(gpa, &links, node.args[1]);
                }
            }
        }
    }
    std.mem.sort([]const u8, links.items, {}, lessString);
    const owned_links = try links.toOwnedSlice(gpa);
    errdefer freeStrings(gpa, owned_links);
    const title = if (title_src) |value| try gpa.dupe(u8, value) else null;
    errdefer if (title) |value| gpa.free(value);
    const h1 = if (h1_src) |value| try gpa.dupe(u8, value) else null;
    return .{ .title = title, .h1 = h1, .links = owned_links };
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm")) return "text/html";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/vnd.microsoft.icon";
    if (std.mem.endsWith(u8, path, ".bmp")) return "image/bmp";
    if (std.mem.endsWith(u8, path, ".tif") or std.mem.endsWith(u8, path, ".tiff")) return "image/tiff";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    if (std.mem.endsWith(u8, path, ".woff")) return "font/woff";
    if (std.mem.endsWith(u8, path, ".ttf")) return "font/ttf";
    if (std.mem.endsWith(u8, path, ".otf")) return "font/otf";
    if (std.mem.endsWith(u8, path, ".eot")) return "application/vnd.ms-fontobject";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".xml")) return "application/xml";
    if (std.mem.endsWith(u8, path, ".pdf")) return "application/pdf";
    if (std.mem.endsWith(u8, path, ".csv")) return "text/csv";
    if (std.mem.endsWith(u8, path, ".txt")) return "text/plain";
    return "application/octet-stream";
}

fn operationFor(doc: ?backend.Document, operation_id: []const u8) ?backend.Operation {
    const value = doc orelse return null;
    for (value.operations) |operation| if (std.mem.eql(u8, operation.operation_id, operation_id)) return operation;
    return null;
}

fn findingForEndpoint(discovery: *const rails.Discovery, operation_id: []const u8) ?findings.Finding {
    var best: ?findings.Finding = null;
    for (discovery.findings) |finding| {
        if (!std.mem.eql(u8, finding.code, findings.code_backend_endpoint)) continue;
        const decision = decisions.lookup(discovery.decisions, finding.id) orelse continue;
        if (!std.mem.eql(u8, decision.choice, operation_id) and
            !(std.mem.eql(u8, operation_id, "custom") and std.mem.startsWith(u8, decision.choice, "custom:"))) continue;
        if (best == null or std.mem.lessThan(u8, finding.id, best.?.id)) best = finding;
    }
    return best;
}

fn attrTrue(attrs: []const fragments.Attr, name: []const u8) bool {
    for (attrs) |attr| if (std.mem.eql(u8, attr.key, name)) {
        return attr.value.len == 0 or std.ascii.eqlIgnoreCase(attr.value, "true") or std.ascii.eqlIgnoreCase(attr.value, name);
    };
    return false;
}

fn fieldValue(helper: []const u8, name: []const u8) []const u8 {
    if (std.mem.eql(u8, helper, "email_field") or std.mem.indexOf(u8, name, "email") != null) return "parity@example.invalid";
    if (std.mem.eql(u8, helper, "password_field") or std.mem.indexOf(u8, name, "password") != null) return "zigapagos-parity-password";
    if (std.mem.eql(u8, helper, "check_box")) return "true";
    return "zigapagos parity";
}

fn fieldsForEndpoint(gpa: Allocator, discovery: *const rails.Discovery, operation_id: []const u8) Allocator.Error![]handoff.RequestField {
    const finding = findingForEndpoint(discovery, operation_id) orelse return try gpa.alloc(handoff.RequestField, 0);
    const template = findTemplate(discovery.fragments, finding.path) orelse return try gpa.alloc(handoff.RequestField, 0);
    var open: ?usize = null;
    for (template.nodes, 0..) |node, i| {
        if (node.text != null or node.kind != .form) continue;
        const node_id = convert.findingIdFor(discovery.findings, template.path, node.line, node.col) orelse continue;
        if (std.mem.eql(u8, node_id, finding.id)) {
            open = i;
            break;
        }
    }
    const start = open orelse return try gpa.alloc(handoff.RequestField, 0);
    const end = blockEnd(template.nodes, start) orelse template.nodes.len;

    const Temp = struct { name: []const u8, helper: []const u8, required: bool };
    var temp: std.ArrayListUnmanaged(Temp) = .empty;
    defer temp.deinit(gpa);
    for (template.nodes[start + 1 .. end]) |node| {
        if (node.text != null or node.kind != .form_field) continue;
        const helper = node.name orelse continue;
        if (std.mem.eql(u8, helper, "label") or std.mem.eql(u8, helper, "submit") or
            std.mem.eql(u8, helper, "button") or node.args.len == 0 or node.args[0].len == 0) continue;
        const name = node.args[0];
        var duplicate = false;
        for (temp.items) |have| if (std.mem.eql(u8, have.name, name)) {
            duplicate = true;
            break;
        };
        if (!duplicate) try temp.append(gpa, .{ .name = name, .helper = helper, .required = attrTrue(node.attrs, "required") });
    }

    var required_index: ?usize = null;
    for (temp.items, 0..) |field, i| if (field.required) {
        required_index = i;
        break;
    };
    const out = try gpa.alloc(handoff.RequestField, temp.items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |value| {
            gpa.free(value.name);
            gpa.free(value.value);
            if (value.invalid_value) |invalid| gpa.free(invalid);
        }
        gpa.free(out);
    }
    for (temp.items, 0..) |field, i| {
        const name = try gpa.dupe(u8, field.name);
        errdefer gpa.free(name);
        const value = try gpa.dupe(u8, fieldValue(field.helper, field.name));
        errdefer gpa.free(value);
        const invalid = if (required_index != null and required_index.? == i) try gpa.dupe(u8, "") else null;
        out[i] = .{ .name = name, .value = value, .invalid_value = invalid };
        filled = i + 1;
    }
    return out;
}

fn replayUrl(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    return std.mem.replaceOwned(u8, gpa, path, "{id}", "parity-record");
}

fn dupeFields(gpa: Allocator, fields: []const handoff.RequestField) Allocator.Error![]handoff.RequestField {
    const out = try gpa.alloc(handoff.RequestField, fields.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |value| {
            gpa.free(value.name);
            gpa.free(value.value);
            if (value.invalid_value) |invalid| gpa.free(invalid);
        }
        gpa.free(out);
    }
    for (fields, 0..) |field, i| {
        const name = try gpa.dupe(u8, field.name);
        errdefer gpa.free(name);
        const value = try gpa.dupe(u8, field.value);
        errdefer gpa.free(value);
        const invalid = if (field.invalid_value) |v| try gpa.dupe(u8, v) else null;
        out[i] = .{ .name = name, .value = value, .invalid_value = invalid };
        filled = i + 1;
    }
    return out;
}

fn migratedOutcome(result: scaffold.Result, route_index: usize) bool {
    for (result.routes) |outcome| if (outcome.route_index == route_index) return outcome.status == .migrated;
    return false;
}

fn pageForEndpoint(discovery: *const rails.Discovery, result: scaffold.Result, operation_id: []const u8) ?[]const u8 {
    const finding = findingForEndpoint(discovery, operation_id) orelse return null;
    var page: ?[]const u8 = null;
    for (result.routes) |outcome| {
        if (outcome.status != .migrated) continue;
        const route = discovery.routes[outcome.route_index];
        if (!std.mem.eql(u8, route.verb, "GET")) continue;
        if (outcome.route_index >= discovery.route_templates.len) continue;
        const rt = discovery.route_templates[outcome.route_index];
        var renders_form = false;
        for (rt.templates) |path| if (std.mem.eql(u8, path, finding.path)) {
            renders_form = true;
            break;
        };
        if (!renders_form) continue;
        if (page == null or std.mem.lessThan(u8, route.path, page.?)) page = route.path;
    }
    return page;
}

fn appendAuth(gpa: Allocator, entries: *std.ArrayListUnmanaged(handoff.ParityEntry), discovery: *const rails.Discovery, scaffold_result: scaffold.Result) Allocator.Error!void {
    var collection: ?[]const u8 = null;
    for (discovery.findings) |finding| {
        if (!std.mem.eql(u8, finding.code, findings.code_auth_journey)) continue;
        const decision = decisions.lookup(discovery.decisions, finding.id) orelse continue;
        if (!std.mem.eql(u8, decision.choice, "island")) continue;
        collection = decision.artifact;
        break;
    }
    const name = collection orelse return;
    var signin_page: ?[]const u8 = null;
    var signup_page: ?[]const u8 = null;
    for (discovery.routes, 0..) |route, route_index| {
        if (!migratedOutcome(scaffold_result, route_index)) continue;
        if (!std.mem.eql(u8, route.verb, "GET")) continue;
        const action = route.action orelse continue;
        if (!std.mem.eql(u8, action, "new")) continue;
        const controller = route.controller orelse continue;
        if (std.mem.endsWith(u8, controller, "sessions") and (signin_page == null or std.mem.lessThan(u8, route.path, signin_page.?))) signin_page = route.path;
        if (std.mem.endsWith(u8, controller, "registrations") and (signup_page == null or std.mem.lessThan(u8, route.path, signup_page.?))) signup_page = route.path;
    }
    if (signup_page) |page| {
        const id = try std.fmt.allocPrint(gpa, "signup:{s}", .{name});
        errdefer gpa.free(id);
        const url = try std.fmt.allocPrint(gpa, "/api/collections/{s}/records", .{name});
        errdefer gpa.free(url);
        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);
        const owned_page = try gpa.dupe(u8, page);
        errdefer gpa.free(owned_page);
        try entries.append(gpa, .{ .signup = .{ .id = id, .url = url, .expect = .{ .status = 201, .collection = owned_name, .page_url = owned_page } } });
    }
    if (signin_page) |page| {
        const id = try std.fmt.allocPrint(gpa, "signin:{s}", .{name});
        errdefer gpa.free(id);
        const url = try std.fmt.allocPrint(gpa, "/api/collections/{s}/auth-with-password", .{name});
        errdefer gpa.free(url);
        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);
        const owned_page = try gpa.dupe(u8, page);
        errdefer gpa.free(owned_page);
        try entries.append(gpa, .{ .signin = .{ .id = id, .url = url, .expect = .{ .status = 200, .collection = owned_name, .page_url = owned_page } } });
    }
}

/// Contract 2 (owned-result): every row and nested string is owned; release
/// with `free`. On error no allocation escapes.
pub fn build(gpa: Allocator, discovery: *const rails.Discovery, scaffold_result: scaffold.Result, backend_doc: ?backend.Document) Allocator.Error!Result {
    var entries: std.ArrayListUnmanaged(handoff.ParityEntry) = .empty;
    errdefer {
        for (entries.items) |entry| freeEntry(gpa, entry);
        entries.deinit(gpa);
    }

    for (scaffold_result.routes) |outcome| {
        const route = discovery.routes[outcome.route_index];
        if (outcome.status == .migrated and (std.mem.eql(u8, route.verb, "GET") or std.mem.eql(u8, route.verb, "HEAD")) and
            std.mem.indexOfAny(u8, route.path, ":*") == null)
        {
            const presentation = try presentationFor(gpa, discovery, outcome.route_index);
            errdefer {
                if (presentation.title) |title| gpa.free(title);
                if (presentation.h1) |h1| gpa.free(h1);
                freeStrings(gpa, presentation.links);
            }
            const route_id = try std.fmt.allocPrint(gpa, "{s} {s}", .{ route.verb, route.path });
            defer gpa.free(route_id);
            const id = try std.fmt.allocPrint(gpa, "navigate:{s}", .{route_id});
            errdefer gpa.free(id);
            const url = try gpa.dupe(u8, route.path);
            errdefer gpa.free(url);
            try entries.append(gpa, .{ .navigate = .{ .id = id, .url = url, .expect = .{
                .status = 200,
                .title = presentation.title,
                .h1 = presentation.h1,
                .links = presentation.links,
            } } });
        }

        const endpoint = outcome.endpoint orelse continue;
        const operation = operationFor(backend_doc, endpoint.operation_id);
        const fields = try fieldsForEndpoint(gpa, discovery, endpoint.operation_id);
        defer freeFields(gpa, fields);
        const page_url = pageForEndpoint(discovery, scaffold_result, endpoint.operation_id);
        const authenticated_allowed = if (operation) |op| switch (op.access) {
            .public, .conditional, .authenticated => true,
            .locked, .superuser, .path_secret, .unknown => false,
        } else false;
        if (fields.len > 0 and authenticated_allowed and page_url != null) {
            const id = try std.fmt.allocPrint(gpa, "submit_allowed:{s}", .{endpoint.operation_id});
            errdefer gpa.free(id);
            const url = try replayUrl(gpa, endpoint.path);
            errdefer gpa.free(url);
            const operation_id = try gpa.dupe(u8, endpoint.operation_id);
            errdefer gpa.free(operation_id);
            const method = try gpa.dupe(u8, endpoint.verb);
            errdefer gpa.free(method);
            const collection = if (operation) |op| if (op.collection) |c| try gpa.dupe(u8, c) else null else null;
            errdefer if (collection) |c| gpa.free(c);
            const owned_page = try gpa.dupe(u8, page_url.?);
            errdefer gpa.free(owned_page);
            const owned_fields = try dupeFields(gpa, fields);
            errdefer freeFields(gpa, owned_fields);
            try entries.append(gpa, .{ .submit_allowed = .{ .id = id, .url = url, .expect = .{
                .status_family = 2,
                .operation_id = operation_id,
                .method = method,
                .collection = collection,
                .page_url = owned_page,
                .fields = owned_fields,
            } } });
        }
        if (operation) |op| if (op.access != .public and op.access != .unknown) {
            const id = try std.fmt.allocPrint(gpa, "submit_denied:{s}", .{endpoint.operation_id});
            errdefer gpa.free(id);
            const url = try replayUrl(gpa, endpoint.path);
            errdefer gpa.free(url);
            const operation_id = try gpa.dupe(u8, endpoint.operation_id);
            errdefer gpa.free(operation_id);
            const method = try gpa.dupe(u8, endpoint.verb);
            errdefer gpa.free(method);
            const collection = if (op.collection) |c| try gpa.dupe(u8, c) else null;
            errdefer if (collection) |c| gpa.free(c);
            const statuses = try gpa.dupe(u16, &.{ 401, 403 });
            errdefer gpa.free(statuses);
            const owned_fields = try dupeFields(gpa, fields);
            errdefer freeFields(gpa, owned_fields);
            try entries.append(gpa, .{ .submit_denied = .{ .id = id, .url = url, .expect = .{
                .statuses = statuses,
                .operation_id = operation_id,
                .method = method,
                .collection = collection,
                .fields = owned_fields,
            } } });
        };
        var invalid_field: ?[]const u8 = null;
        for (fields) |field| if (field.invalid_value != null) {
            invalid_field = field.name;
            break;
        };
        if (invalid_field) |field| if (authenticated_allowed and page_url != null) {
            const id = try std.fmt.allocPrint(gpa, "validation_error:{s}:{s}", .{ endpoint.operation_id, field });
            errdefer gpa.free(id);
            const url = try replayUrl(gpa, endpoint.path);
            errdefer gpa.free(url);
            const operation_id = try gpa.dupe(u8, endpoint.operation_id);
            errdefer gpa.free(operation_id);
            const method = try gpa.dupe(u8, endpoint.verb);
            errdefer gpa.free(method);
            const collection = if (operation) |op| if (op.collection) |c| try gpa.dupe(u8, c) else null else null;
            errdefer if (collection) |c| gpa.free(c);
            const owned_page = try gpa.dupe(u8, page_url.?);
            errdefer gpa.free(owned_page);
            const owned_field = try gpa.dupe(u8, field);
            errdefer gpa.free(owned_field);
            const owned_fields = try dupeFields(gpa, fields);
            errdefer freeFields(gpa, owned_fields);
            try entries.append(gpa, .{ .validation_error = .{ .id = id, .url = url, .expect = .{
                .status = 400,
                .operation_id = operation_id,
                .method = method,
                .collection = collection,
                .page_url = owned_page,
                .field = owned_field,
                .fields = owned_fields,
            } } });
        };
    }

    for (scaffold_result.assets) |asset| {
        const id = try std.fmt.allocPrint(gpa, "asset:{s}", .{asset.target_url});
        errdefer gpa.free(id);
        const url = try gpa.dupe(u8, asset.target_url);
        errdefer gpa.free(url);
        const content_type = try gpa.dupe(u8, contentType(asset.target_url));
        errdefer gpa.free(content_type);
        const rails_url = if (asset.rails_url) |value| try gpa.dupe(u8, value) else null;
        errdefer if (rails_url) |value| gpa.free(value);
        try entries.append(gpa, .{ .asset = .{ .id = id, .url = url, .expect = .{ .status = 200, .content_type = content_type, .rails_url = rails_url } } });
    }
    try appendAuth(gpa, &entries, discovery, scaffold_result);
    return .{ .entries = try entries.toOwnedSlice(gpa) };
}

const testing = std.testing;

test "contentType matches stock ZigBase for common Rails web assets" {
    try testing.expectEqualStrings("application/javascript", contentType("/assets/application.js"));
    try testing.expectEqualStrings("application/javascript", contentType("/assets/module.mjs"));
    try testing.expectEqualStrings("font/woff2", contentType("/assets/inter.woff2"));
    try testing.expectEqualStrings("text/html", contentType("/offline.html"));
    try testing.expectEqualStrings("application/octet-stream", contentType("/download.unknown"));
}

fn testRoute(verb: []const u8, path: []const u8, controller: []const u8, action: []const u8, line: u64) @import("routes.zig").Route {
    return .{ .verb = verb, .path = path, .controller = controller, .action = action, .name = null, .certain = true, .origin = .static_ast, .source = .{ .file = "config/routes.rb", .line = line } };
}

fn textNode(text: []const u8, line: u64) fragments.Node {
    return .{ .text = text, .kind = .unknown, .line = line, .col = 1, .output = false, .code = "", .name = null, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}

fn codeNode(kind: fragments.Kind, line: u64, name: ?[]const u8) fragments.Node {
    return .{ .text = null, .kind = kind, .line = line, .col = 1, .output = false, .code = "", .name = name, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}

test "build derives navigation, assets, auth, authorization and validation only from evidence" {
    const gpa = testing.allocator;
    var routes = [_]@import("routes.zig").Route{
        testRoute("GET", "/posts/new", "posts", "new", 1),
        testRoute("POST", "/posts", "posts", "create", 2),
        testRoute("GET", "/sign-in", "sessions", "new", 3),
        testRoute("GET", "/sign-up", "registrations", "new", 4),
    };
    var title = codeNode(.content_for, 1, "title");
    title.code = "content_for :title do";
    var field = codeNode(.form_field, 5, "text_field");
    field.args = &.{"title"};
    field.attrs = &.{.{ .key = "required", .value = "true" }};
    var label = codeNode(.form_field, 5, "label");
    label.args = &.{ "title", "Title" };
    var form = codeNode(.form, 4, "post");
    form.code = "form_with(model: @post) do |f|";
    var link = codeNode(.link_to, 7, null);
    link.args = &.{ "Docs", "/docs" };
    var auth_region = codeNode(.request_state, 8, "current_user");
    auth_region.code = "if current_user";
    var hidden_link = codeNode(.link_to, 9, null);
    hidden_link.args = &.{ "Account", "/account" };
    var nodes = [_]fragments.Node{
        title,
        textNode(" About ", 2),
        codeNode(.block_end, 3, null),
        form,
        label,
        field,
        codeNode(.block_end, 6, null),
        link,
        auth_region,
        hidden_link,
        codeNode(.block_end, 10, null),
    };
    var links = [_][]const u8{ "/literal", "/account" };
    var link_nodes = [_]usize{ 1, 9 };
    var templates = [_]fragments.Template{.{
        .path = "app/views/posts/new.html.erb",
        .nodes = &nodes,
        .error_message = null,
        .error_line = null,
        .unreadable = null,
        .parity_h1 = "New post",
        .parity_h1_node = 1,
        .parity_links = &links,
        .parity_link_nodes = &link_nodes,
    }};
    var view_paths = [_][]const u8{"app/views/posts/new.html.erb"};
    var empty_paths = [_][]const u8{};
    var route_templates = [_]rails.RouteTemplates{
        .{ .templates = &view_paths, .layout = null },
        .{ .templates = &empty_paths, .layout = null },
        .{ .templates = &empty_paths, .layout = null },
        .{ .templates = &empty_paths, .layout = null },
    };
    var finding_rows = [_]findings.Finding{
        .{ .id = "backend.form.L4C1", .code = findings.code_backend_endpoint, .severity = .warn, .path = "app/views/posts/new.html.erb", .line = 4, .route_id = null, .message = "", .choices = &.{"createPosts"}, .requires_artifact = false },
        .{ .id = "auth.journey", .code = findings.code_auth_journey, .severity = .warn, .path = "config/routes.rb", .line = 3, .route_id = null, .message = "", .choices = &.{"island"}, .requires_artifact = false },
        .{ .id = "RAILS_REQUEST_TIME_STATE.app/views/posts/new%2Ehtml%2Eerb.L8C1", .code = "RAILS_REQUEST_TIME_STATE", .severity = .warn, .path = "app/views/posts/new.html.erb", .line = 8, .route_id = null, .message = "", .choices = &.{"island"}, .requires_artifact = false },
    };
    var decision_rows = [_]decisions.Decision{
        .{ .id = "backend.form.L4C1", .choice = "createPosts", .rationale = "test", .artifact = null },
        .{ .id = "auth.journey", .choice = "island", .rationale = "test", .artifact = "users" },
        .{ .id = "RAILS_REQUEST_TIME_STATE.app/views/posts/new%2Ehtml%2Eerb.L8C1", .choice = "island", .rationale = "test", .artifact = null },
    };
    const discovery: rails.Discovery = .{
        .report = "",
        .integrity_blocker_count = 0,
        .route_count = routes.len,
        .route_mode = "static_ast",
        .route_blocker = false,
        .severity_error_count = 0,
        .severity_warn_count = 0,
        .ruby = .{ .available = true },
        .route_templates = &route_templates,
        .templates = &.{},
        .assets = &.{},
        .version = .{},
        .routes = &routes,
        .classifications = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .fragments = &templates,
        .findings = &finding_rows,
        .i18n_locale = null,
        .decisions = .{ .decisions = &decision_rows, .stale = &.{} },
        .actions = &.{},
        .before_actions = &.{},
        .skip_before_actions = &.{},
        .parents = &.{},
    };
    var artifacts = [_][]const u8{"content/posts/new/index.smd"};
    var no_artifacts = [_][]const u8{};
    var outcomes = [_]scaffold.RouteOutcome{
        .{ .route_index = 0, .status = .migrated, .artifacts = &artifacts, .open_finding_ids = &.{}, .decision_id = null, .note = null, .endpoint = null },
        .{ .route_index = 1, .status = .backend, .artifacts = &no_artifacts, .open_finding_ids = &.{}, .decision_id = "backend.form.L4C1", .note = null, .endpoint = .{ .operation_id = "createPosts", .verb = "POST", .path = "/api/collections/posts/records" } },
        .{ .route_index = 2, .status = .migrated, .artifacts = &no_artifacts, .open_finding_ids = &.{}, .decision_id = "auth.journey", .note = null, .endpoint = null },
        .{ .route_index = 3, .status = .migrated, .artifacts = &no_artifacts, .open_finding_ids = &.{}, .decision_id = "auth.journey", .note = null, .endpoint = null },
    };
    var asset_rows = [_]scaffold.AssetOutcome{.{ .source = "app/assets/stylesheets/application.css", .rails_url = "/assets/application.css", .target_url = "/stylesheets/application.css" }};
    const scaffold_result: scaffold.Result = .{ .routes = &outcomes, .assets = &asset_rows, .redirects = &.{}, .spa_files = &.{} };
    var operations = [_]backend.Operation{.{ .operation_id = "createPosts", .verb = "POST", .path = "/api/collections/posts/records", .collection = "posts", .kind = .create, .access = .conditional }};
    var auth_collections = [_][]const u8{"users"};
    const backend_doc: backend.Document = .{ .file = "openapi.json", .contract_version = "1", .consumer_routes = false, .operations = &operations, .auth_collections = &auth_collections };

    const result = try build(gpa, &discovery, scaffold_result, backend_doc);
    defer free(gpa, result);
    try testing.expectEqual(@as(usize, 9), result.entries.len);
    var saw_navigate = false;
    var saw_denied = false;
    var saw_validation = false;
    for (result.entries) |entry| switch (entry) {
        .navigate => |row| {
            if (std.mem.eql(u8, row.url, "/posts/new")) {
                saw_navigate = true;
                try testing.expectEqualStrings("About", row.expect.title.?);
                try testing.expectEqualStrings("New post", row.expect.h1.?);
                try testing.expectEqualStrings("/docs", row.expect.links[0]);
                for (row.expect.links) |actual| try testing.expect(!std.mem.eql(u8, actual, "/account"));
            }
        },
        .submit_denied => |row| {
            saw_denied = true;
            try testing.expectEqualStrings("title", row.expect.fields[0].name);
        },
        .validation_error => |row| {
            saw_validation = true;
            try testing.expectEqualStrings("/posts/new", row.expect.page_url);
            try testing.expectEqualStrings("title", row.expect.field);
        },
        else => {},
    };
    try testing.expect(saw_navigate and saw_denied and saw_validation);

    operations[0].access = .locked;
    const locked = try build(gpa, &discovery, scaffold_result, backend_doc);
    defer free(gpa, locked);
    for (locked.entries) |entry| switch (entry) {
        .submit_allowed, .validation_error => return error.TestUnexpectedResult,
        else => {},
    };

    operations[0].access = .conditional;
    outcomes[0].status = .retained;
    const retained = try build(gpa, &discovery, scaffold_result, backend_doc);
    defer free(gpa, retained);
    for (retained.entries) |entry| switch (entry) {
        .submit_allowed, .validation_error => return error.TestUnexpectedResult,
        else => {},
    };
}

test "build presentation evidence is leak-free under every allocation failure" {
    var routes = [_]@import("routes.zig").Route{testRoute("GET", "/a", "pages", "a", 1)};
    var nodes = [_]fragments.Node{textNode("<h1>A</h1>", 1)};
    var links = [_][]const u8{"/"};
    var templates = [_]fragments.Template{.{ .path = "app/views/pages/a.html.erb", .nodes = &nodes, .error_message = null, .error_line = null, .unreadable = null, .parity_h1 = "A", .parity_links = &links }};
    var paths = [_][]const u8{"app/views/pages/a.html.erb"};
    var route_templates = [_]rails.RouteTemplates{.{ .templates = &paths, .layout = null }};
    var outcomes = [_]scaffold.RouteOutcome{.{ .route_index = 0, .status = .migrated, .artifacts = &.{}, .open_finding_ids = &.{}, .decision_id = null, .note = null, .endpoint = null }};
    const discovery: rails.Discovery = .{
        .report = "",
        .integrity_blocker_count = 0,
        .route_count = 1,
        .route_mode = "static_ast",
        .route_blocker = false,
        .severity_error_count = 0,
        .severity_warn_count = 0,
        .ruby = .{ .available = true },
        .route_templates = &route_templates,
        .templates = &.{},
        .assets = &.{},
        .version = .{},
        .routes = &routes,
        .classifications = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .fragments = &templates,
        .findings = &.{},
        .i18n_locale = null,
        .decisions = .empty,
        .actions = &.{},
        .before_actions = &.{},
        .skip_before_actions = &.{},
        .parents = &.{},
    };
    const scaffold_result: scaffold.Result = .{ .routes = &outcomes, .assets = &.{}, .redirects = &.{}, .spa_files = &.{} };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 1000) return error.SweepNeverReachedSuccess;
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (build(gpa, &discovery, scaffold_result, null)) |result| {
            free(gpa, result);
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
}
