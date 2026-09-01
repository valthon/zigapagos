//! Writes the target tree a Rails migration produces, and reports what each
//! route actually became.
//!
//! This is the only file in `src/cli/rails/` that touches the filesystem for
//! WRITING. Everything it emits is a pure function of the `Discovery` and the
//! operator's `decisions` it is handed -- no timestamps, no absolute paths, no
//! ambient state -- so two runs over the same app produce byte-identical
//! trees (plan, Global Constraints). Where an input slice's order is not
//! promised (the route table comes off a Ruby sidecar, the asset table off a
//! directory walk), this file sorts it before reading it, rather than
//! inheriting an order nothing guarantees.
//!
//! **Nothing here fatals.** A write that cannot be made returns
//! `error.TargetWrite` with the offending path in the caller's
//! `last_error_path`; `migrate.zig` turns that into `fatal.file`. A SOURCE
//! read that fails (an asset that vanished or is unreadable) returns
//! `error.SourceRead` the same way -- a distinct error because the fix is
//! different (a permission in the Rails app, not in the target).
//!
//! **Every write is exclusive-create** (`.{ .exclusive = true }`, parents
//! created). A pre-existing file is a hard failure, not an overwrite: the
//! target may only pre-exist to carry `MIGRATION.decisions.json` forward
//! across a decide-and-re-run loop (plan, Global Constraints), so anything
//! else already there means the operator is writing into a tree they have not
//! wiped, and silently clobbering it would destroy hand edits.
//!
//! **Status is the CONVERSION's verdict, not discovery's.** `Discovery`'s
//! `classification` says what the Rails route looked like; `RouteOutcome.
//! status` says what came out the other end, and where they disagree the
//! conversion wins (spec, "Conversion: what a route becomes"). A `content`
//! route whose view holds an unknown helper is `open`; an `unresolved` one
//! whose only blemish has a defined conversion is `migrated`.
//!
//! Four things make a route NOT `migrated`, and all four are checked:
//!
//! 1. a finding id left open on the view, its layout, or any partial inlined
//!    into either;
//! 2. an `<!-- rails:unmapped ... -->` region in the converted bytes, which
//!    carries NO finding id at all (`convert.zig`'s module doc; Stage 2 plan
//!    ruling S6). All supported conditional failures now have context-aware
//!    findings too, so this is a defensive discovery/derivation-drift guard;
//!    it stays because a placeholder with no id is precisely the case that an
//!    empty `open_finding_ids` cannot see;
//! 3. a template `convert` refused outright (`error.Unconvertible`: a parse
//!    error or a file the templates op never read);
//! 4. anything else the conversion could not finish, recorded through
//!    `Outcome.addOpenNote` -- a route with no view, a layout that would not
//!    convert, a content path another route already claimed, a `spa` decision
//!    with nowhere to mount.
//!
//! An operator decision of `retain`/`blocked` on any open finding turns that
//! into an acknowledged status; `island`/`backend` are recorded but leave the
//! route `open` with a note, because Stage 2 cannot produce the artifact
//! either choice promises (plan, Global Constraints).
//!
//! Ruling S20: an acknowledged route writes NO `content/**/index.smd` and no
//! `layouts/<viewStem>.shtml`. `retained` says the page stays on Rails, so
//! this target must not answer that URL; `blocked` says it does not ship.
//! Writing the converted page anyway made `blocked` a relabelling and nothing
//! else -- the built site served a blank `<main>` for a route the handoff
//! called blocked, which is worse than a 404 because it looks deliberate. The
//! handoff row is the record of what happened; the target holds only what the
//! site serves. An `open` route (including an `island`/`backend` deferral)
//! still gets its page: it is a page with a gap in it, not an absent one.
//! `layouts/templates/<layout>.shtml` is unaffected -- a layout is shared
//! chrome, written once per layout rather than per route.
//!
//! Ruling S19: that acknowledgement is read BEFORE reason 2, not after.
//! `retain` means the page stays on Rails and this target never serves it and
//! `blocked` means it does not ship, so a region the converter could not map
//! changes nothing about either answer -- while checking S6 first made a route
//! carrying one permanently uncompletable, whatever the operator said. Reason
//! 2 keeps its force for the route nobody answered: it has no finding id, so
//! nobody can be asked about it, and it must not reach `migrated` on the
//! strength of an empty `open_finding_ids`. A route with that defensive marker
//! and no finding therefore still cannot be completed; it indicates discovery
//! and conversion disagreed and should be reported as a converter bug.
//!
//! `RouteOutcome.note` also carries the conversion's own `Output.dropped`
//! notes, joined with `"; "` -- `MIGRATION.md` is the only place an operator
//! ever learns what the conversion removed. Ruling S15 splits them: a csrf
//! tag, a JS entry helper and a `<title>` suffix each name a construct with a
//! DEFINED conversion, lose nothing, and stay informational; a `content_for`
//! naming a block the layout does not declare loses the author's own markup
//! and is reason 4 above. `foldDropped` is where that line is drawn.
//!
//! **One view converts once per LAYOUT, and the first route owns the file**
//! (ruling S16). A view's bytes depend on the layout it extends, and the
//! target has one `layouts/<viewStem>.shtml`, so a second route reaching the
//! same view under a different layout is reported (`open`, naming both) rather
//! than served a page whose `<extend>` points at the wrong parent.
//!
//! std-only, like every file in `src/cli/rails/`. The handful of small
//! emitters below (`zigapagos.ziggy`, `build.sh`, `package.json`,
//! `tsconfig.json`, `.gitignore`) are DUPLICATED from `src/cli/migrate.zig`'s
//! `emitTarget*`/`target_*` rather than imported: `migrate.zig` lives outside
//! this module and importing it would break the std-only boundary (and its
//! versions call `fatal.oom()`, which this file must not). The byte shapes
//! are meant to stay identical; each emitter names its counterpart so a
//! future edit to one is findable from the other.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const asset_mod = @import("assets.zig");
const backend_mod = @import("backend.zig");
const classify = @import("classify.zig");
const controllers = @import("controllers.zig");
const convert = @import("convert.zig");
const decisions = @import("decisions.zig");
const findings = @import("findings.zig");
const fragments = @import("fragments.zig");
const port = @import("port.zig");
const rails = @import("rails.zig");
const resolve = @import("resolve.zig");
const route_mod = @import("routes.zig");

/// What one route became. `route_index` indexes `Input.discovery.routes`, so
/// a consumer can recover the verb/path/source without this struct carrying
/// a second copy of them.
///
/// Contract 2 (owned-result): `artifacts`, `open_finding_ids`, `decision_id`
/// and `note` are fresh `gpa` allocations; released by `freeResult`.
pub const RouteOutcome = struct {
    route_index: usize,
    status: Status,
    /// Target-relative paths written FOR this route, sorted. A file shared
    /// with another route (a layout, a view two routes both render, a SPA
    /// entry) is listed on every route that reaches it, and written once.
    artifacts: [][]const u8,
    /// Finding ids still open on this route, sorted and deduped. Non-empty
    /// with a `retained`/`blocked` status too: the findings did not go away,
    /// they were acknowledged.
    open_finding_ids: [][]const u8,
    /// The decision that produced a non-`open` status, when one did.
    decision_id: ?[]const u8,
    /// Why this route is not `migrated`, when the finding ids alone do not
    /// say -- an unmapped region, a missing view, a deferred choice.
    note: ?[]const u8,
    /// #167 Stage 3: the ZigBase operation this route's traffic becomes.
    /// Non-null only for a route that is API traffic (`status == .backend`)
    /// AND that an operator bound -- through the form whose page route pairs
    /// with it (`registrations#new`'s form answers `registrations#create`,
    /// Rails' own convention), through the bound `link_to`/`button_to` that
    /// submits to it (which names the route outright), or through the route's
    /// OWN `RAILS_BACKEND_ENDPOINT` finding. `null` for every page route: a
    /// page has no endpoint.
    endpoint: ?Endpoint,
};

/// Where a bound route's traffic goes. The same three fields as
/// `handoff.Endpoint`, declared here rather than imported for the reason
/// `handoff.RouteRow` is a separate type from `handoff.RouteEntry`: one is a
/// conversion outcome, the other a wire shape whose FIELD ORDER is a
/// contract, and a scaffolder that imported the wire type would be free to
/// break it by reordering.
///
/// Contract 2 (owned-result): all three strings are fresh `gpa` allocations,
/// released by `freeResult`.
pub const Endpoint = struct {
    /// The ZigBase operation id, or the literal `custom` for a
    /// `custom:/<path>` answer (assumption A3).
    operation_id: []const u8,
    verb: []const u8,
    path: []const u8,
};

/// `migrated` -- a real page was written and nothing is left open.
/// `open` -- something is unresolved and nobody has said what to do.
/// `blocked`/`retained` -- an operator decision acknowledged it.
/// `backend` -- not a page at all (a non-GET route, or one discovery
/// classified `backend`); Stage 3 maps it to an endpoint.
/// `redirect` -- the host config owns it; see `Result.redirects`.
pub const Status = enum { migrated, open, blocked, retained, backend, redirect };

/// One copied asset. `rails_url` is what Rails served it at (`null` when the
/// pipeline could not be pinned down), `target_url` what the built site
/// serves it at.
pub const AssetOutcome = struct {
    source: []const u8,
    rails_url: ?[]const u8,
    target_url: []const u8,
};

/// A route the static tree cannot express. `to` is the resolved target
/// (#167 Stage 3, `resolve.redirectUrl` over the action's own `redirect_to`)
/// and stays `null` only when this run genuinely cannot name one -- a
/// `redirect_to @post`, a `redirect_back`, or a helper that matches no route
/// this run recovered.
pub const Redirect = struct { from: []const u8, to: ?[]const u8 };

/// Contract 2 (owned-result): released by `freeResult`.
pub const Result = struct {
    /// One entry per `Discovery.routes` entry, in this file's own sorted
    /// route order (see `routeLessThan`) rather than discovery's -- the
    /// caller reads `route_index`, and a stable order here keeps the whole
    /// result byte-reproducible.
    routes: []RouteOutcome,
    assets: []AssetOutcome,
    redirects: []Redirect,
    /// Target-relative `.spa.tsx` paths written, sorted.
    spa_files: [][]const u8,
};

pub const WriteError = error{
    /// A file in the target could not be created or written. The path is in
    /// the caller's `last_error_path`.
    TargetWrite,
    /// A file in the SOURCE app could not be read (only assets are read
    /// here). The path is in `last_error_path`.
    ///
    /// Not folded into `TargetWrite` because the two send an operator to
    /// different places, and not swallowed because an asset silently missing
    /// from the built site is exactly the kind of "looks migrated, isn't"
    /// outcome the whole findings mechanism exists to prevent.
    SourceRead,
} || Allocator.Error;

pub const Input = struct {
    discovery: *const rails.Discovery,
    decisions: decisions.Parsed,
    /// The Rails app root, for READING assets. `write` never writes through
    /// it -- the source tree is never touched.
    source_root: Io.Dir,
    /// Target directory, relative to the process cwd (like `migrate.zig`'s
    /// own `writeTargetFile`). Created if missing.
    target: []const u8,
    app_name: []const u8,
    /// `file:` path for `@z/runtime` in a generated `package.json`. Only read
    /// when a SPA or an island is scaffolded.
    runtime_path: ?[]const u8,
    /// #179 option 1: `ZIGAPAGOS_RUNTIME_DIR` as `migrate.zig` read it from
    /// the environment, used when `runtime_path` is absent.
    ///
    /// The placeholder `file:TODO-SET-RUNTIME-PATH` was survivable while only
    /// a `spa` decision produced a `package.json`; Stage 3 emits one on every
    /// bound form, so a target that cannot `bun install` became the ordinary
    /// outcome. That variable is already how `site/build.sh` and
    /// `examples/tsx-site/build.sh` point at a checkout's runtime, so honouring
    /// it here makes the generated project build in exactly the shell that
    /// generated it. `runtime_path` still wins: it is an explicit flag.
    runtime_dir_env: ?[]const u8 = null,
    /// #167 Stage 3: the parsed `--backend` document, for turning an
    /// operation-id answer into the verb/path/collection a client call needs.
    /// BORROWED; nothing in the result points into it.
    ///
    /// `null` disables operation bindings entirely -- a `custom:/<path>`
    /// answer still binds, because it carries its own path and needs no
    /// document to resolve.
    backend: ?backend_mod.Document = null,
    /// `AGENTS.md`/`CLAUDE.md` bytes. Passed in rather than `@embedFile`d
    /// because those files live in `src/cli/init/`, outside this module.
    agents_md: []const u8,
    claude_md: []const u8,
};

/// Contract 2 counterpart to `write`.
pub fn freeResult(gpa: Allocator, r: Result) void {
    for (r.routes) |o| {
        freeStrings(gpa, o.artifacts);
        freeStrings(gpa, o.open_finding_ids);
        if (o.decision_id) |d| gpa.free(d);
        if (o.note) |n| gpa.free(n);
        freeEndpoint(gpa, o.endpoint);
    }
    gpa.free(r.routes);
    for (r.assets) |a| {
        gpa.free(a.source);
        if (a.rails_url) |u| gpa.free(u);
        gpa.free(a.target_url);
    }
    gpa.free(r.assets);
    for (r.redirects) |x| {
        gpa.free(x.from);
        if (x.to) |t| gpa.free(t);
    }
    gpa.free(r.redirects);
    freeStrings(gpa, r.spa_files);
}

fn freeStrings(gpa: Allocator, list: [][]const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

fn freeEndpoint(gpa: Allocator, e: ?Endpoint) void {
    const x = e orelse return;
    gpa.free(x.operation_id);
    gpa.free(x.verb);
    gpa.free(x.path);
}

// ---- the write itself ----------------------------------------------------

/// Writes the whole target tree and reports what every route became.
///
/// `last_error_path` is set (to a fresh `gpa` allocation the CALLER frees)
/// only on `TargetWrite`/`SourceRead`, and is left untouched otherwise. It
/// can still be `null` after such an error, in the one case where duping the
/// path itself ran out of memory -- the error is still the honest one, and a
/// message without a path beats losing the failure.
///
/// `last_error` carries the OS error that actually happened, alongside the
/// path (ruling S14). Without it `TargetWrite` collapses every cause into one
/// word, and the two an operator most needs to tell apart -- a target that
/// already has the file (`PathAlreadyExists`: wipe it and re-run) and a
/// directory they cannot write (`AccessDenied`: fix the permission) -- read
/// identically. `migrate.zig` puts it in the fatal message.
///
/// Contract 2 (owned-result): the returned `Result` owns every string in it
/// and is released with `freeResult`. On any error nothing escapes: every
/// partial result is freed before returning.
pub fn write(
    io: Io,
    gpa: Allocator,
    in: Input,
    last_error_path: *?[]const u8,
    last_error: *?anyerror,
) WriteError!Result {
    var ctx: Ctx = .{
        .io = io,
        .gpa = gpa,
        .in = in,
        .last_error_path = last_error_path,
        .last_error = last_error,
    };

    var acc: Acc = .{};
    errdefer acc.deinit(gpa);

    try run(&ctx, &acc);

    const route_outcomes = try acc.routes.toOwnedSlice(gpa);
    errdefer {
        for (route_outcomes) |o| {
            freeStrings(gpa, o.artifacts);
            freeStrings(gpa, o.open_finding_ids);
            if (o.decision_id) |d| gpa.free(d);
            if (o.note) |n| gpa.free(n);
            freeEndpoint(gpa, o.endpoint);
        }
        gpa.free(route_outcomes);
    }
    const asset_outcomes = try acc.assets.toOwnedSlice(gpa);
    errdefer {
        for (asset_outcomes) |a| {
            gpa.free(a.source);
            if (a.rails_url) |u| gpa.free(u);
            gpa.free(a.target_url);
        }
        gpa.free(asset_outcomes);
    }
    const redirect_list = try acc.redirects.toOwnedSlice(gpa);
    errdefer {
        for (redirect_list) |x| {
            gpa.free(x.from);
            if (x.to) |t| gpa.free(t);
        }
        gpa.free(redirect_list);
    }
    const spa_list = try acc.spa_files.toOwnedSlice(gpa);

    return .{
        .routes = route_outcomes,
        .assets = asset_outcomes,
        .redirects = redirect_list,
        .spa_files = spa_list,
    };
}

pub const parity_runner_path = "test/parity.ts";
pub const journey_runner_path = "test/journey_playwright.py";

/// Fixed Bun parity runner. It contains no route-specific source: every
/// request, replay value, and expectation comes from MIGRATION.handoff.json.
pub const parity_runner_ts =
    \\type Row = { id: string; kind: string; url: string; expect: any };
    \\const handoff = await (globalThis as any).Bun.file(new URL("../MIGRATION.handoff.json", import.meta.url)).json() as { schema_version: number; parity: Row[] };
    \\if (handoff.schema_version !== 1 || !Array.isArray(handoff.parity)) {
    \\  throw new Error(`unsupported migration handoff schema: ${String(handoff.schema_version)}`);
    \\}
    \\const env = (globalThis as any).process.env as Record<string, string | undefined>;
    \\const configuredOrigin = env.ZIGAPAGOS_ORIGIN?.replace(/\/$/, "");
    \\if (!configuredOrigin) throw new Error("ZIGAPAGOS_ORIGIN is required (run through `zigapagos e2e`)");
    \\const origin: string = configuredOrigin;
    \\const railsOrigin = env.RAILS_ORIGIN?.replace(/\/$/, "");
    \\const failures: string[] = [];
    \\const credentials = new Map<string, { email: string; password: string }>();
    \\const clients = new Map<string, any>();
    \\
    \\function fail(row: Row, message: string): void { failures.push(`${row.id}: ${message}`); }
    \\function values(row: Row, invalid = false): Record<string, string> {
    \\  return Object.fromEntries(row.expect.fields.map((field: any) => [field.name,
    \\    invalid && field.invalid_value !== null ? field.invalid_value : field.value]));
    \\}
    \\function decodeHtml(value: string): string {
    \\  return value.replace(/&quot;/g, '"').replace(/&#39;|&#x27;/gi, "'")
    \\    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
    \\}
    \\function visibleText(value: string): string {
    \\  return decodeHtml(value.replace(/<[^>]*>/g, " ")).replace(/\s+/g, " ").trim();
    \\}
    \\function header(res: Response, name: string): string {
    \\  return (res.headers.get(name) ?? "").split(";")[0].trim().toLowerCase();
    \\}
    \\function equalBytes(a: ArrayBuffer, b: ArrayBuffer): boolean {
    \\  const x = new Uint8Array(a), y = new Uint8Array(b);
    \\  return x.length === y.length && x.every((value, index) => value === y[index]);
    \\}
    \\async function client(collection: string): Promise<any> {
    \\  const old = clients.get(collection); if (old) return old;
    \\  const { createClient, MemoryAuthStore } = await import("@zigbase/client");
    \\  const value = createClient(origin, { authStore: new MemoryAuthStore(), authCollection: collection, fetch });
    \\  clients.set(collection, value); return value;
    \\}
    \\function credential(collection: string): { email: string; password: string } {
    \\  const old = credentials.get(collection); if (old) return old;
    \\  const nonce = crypto.randomUUID();
    \\  const value = { email: `parity+${nonce}@example.invalid`, password: `zigapagos-parity-${nonce}` };
    \\  credentials.set(collection, value); return value;
    \\}
    \\async function request(row: Row, body?: unknown, token?: string): Promise<Response> {
    \\  const method = String(row.expect.method ?? "GET").toUpperCase();
    \\  const carriesBody = body !== undefined && method !== "GET" && method !== "HEAD";
    \\  const headers: Record<string, string> = {};
    \\  if (carriesBody) headers["content-type"] = "application/json";
    \\  if (token) headers.authorization = `Bearer ${token}`;
    \\  return fetch(origin + row.url, { method, headers,
    \\    body: carriesBody ? JSON.stringify(body) : undefined });
    \\}
    \\
    \\for (const row of handoff.parity.filter((r) => r.kind === "navigate" || r.kind === "asset")) {
    \\  try {
    \\    const res = await fetch(origin + row.url);
    \\    if (res.status !== row.expect.status) fail(row, `status ${res.status}, expected ${row.expect.status}`);
    \\    if (row.kind === "asset") {
    \\      if (header(res, "content-type") !== row.expect.content_type.toLowerCase())
    \\        fail(row, `content-type ${header(res, "content-type")}, expected ${row.expect.content_type}`);
    \\      if (railsOrigin && row.expect.rails_url) {
    \\        const [targetBytes, railsRes] = await Promise.all([res.arrayBuffer(), fetch(railsOrigin + row.expect.rails_url)]);
    \\        const railsBytes = await railsRes.arrayBuffer();
    \\        if (railsRes.status !== row.expect.status || header(railsRes, "content-type") !== row.expect.content_type.toLowerCase())
    \\          fail(row, "Rails oracle status/content-type differs");
    \\        if (!equalBytes(targetBytes, railsBytes)) fail(row, "Rails oracle bytes differ");
    \\      }
    \\      continue;
    \\    }
    \\    const html = await res.text();
    \\    const title = html.match(/<title\b[^>]*>([\s\S]*?)<\/title\s*>/i);
    \\    const h1 = html.match(/<h1\b[^>]*>([\s\S]*?)<\/h1\s*>/i);
    \\    const actualTitle = title ? visibleText(title[1]) : null;
    \\    const actualH1 = h1 ? visibleText(h1[1]) : null;
    \\    if (row.expect.title !== null && actualTitle !== row.expect.title) fail(row, `title ${JSON.stringify(actualTitle)}, expected ${JSON.stringify(row.expect.title)}`);
    \\    if (row.expect.h1 !== null && actualH1 !== row.expect.h1) fail(row, `h1 ${JSON.stringify(actualH1)}, expected ${JSON.stringify(row.expect.h1)}`);
    \\    const links = new Set(Array.from(html.matchAll(/<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/gi),
    \\      (m) => decodeHtml(m[1] ?? m[2] ?? m[3])));
    \\    for (const link of row.expect.links) if (!links.has(link)) fail(row, `missing link ${link}`);
    \\  } catch (err) { fail(row, String(err)); }
    \\}
    \\
    \\for (const row of handoff.parity.filter((r) => r.kind === "signup")) {
    \\  try {
    \\    const c = await client(row.expect.collection); const cred = credential(row.expect.collection);
    \\    const res = await c.fetch("POST", row.url, { body: { email: cred.email, password: cred.password, passwordConfirm: cred.password } });
    \\    if (res.status !== row.expect.status) fail(row, `status ${res.status}, expected ${row.expect.status}: ${await res.text()}`);
    \\  } catch (err) { fail(row, String(err)); }
    \\}
    \\for (const row of handoff.parity.filter((r) => r.kind === "signin")) {
    \\  try {
    \\    const c = await client(row.expect.collection); const cred = credential(row.expect.collection);
    \\    const res = await c.fetch("POST", row.url, { body: { identity: cred.email, password: cred.password } });
    \\    if (res.status !== row.expect.status) { fail(row, `status ${res.status}, expected ${row.expect.status}: ${await res.text()}`); continue; }
    \\    const auth = await res.json() as any; c.authStore.save(auth.token, auth.record);
    \\  } catch (err) { fail(row, String(err)); }
    \\}
    \\for (const row of handoff.parity.filter((r) => r.kind === "submit_denied")) {
    \\  try {
    \\    const res = await request(row, values(row));
    \\    if (!row.expect.statuses.includes(res.status)) fail(row, `status ${res.status}, expected one of ${row.expect.statuses.join(", ")}`);
    \\  } catch (err) { fail(row, String(err)); }
    \\}
    \\for (const row of handoff.parity.filter((r) => r.kind === "submit_allowed" || r.kind === "validation_error")) {
    \\  try {
    \\    const requiresAuth = handoff.parity.some((candidate) =>
    \\      candidate.kind === "submit_denied" && candidate.expect.operation_id === row.expect.operation_id);
    \\    let token: string | undefined;
    \\    if (requiresAuth) {
    \\      const c = Array.from(clients.values()).find((candidate) => candidate.authStore.isValid);
    \\      if (!c) throw new Error("no authenticated session");
    \\      token = c.authStore.token ?? undefined;
    \\    }
    \\    const res = await request(row, values(row, row.kind === "validation_error"), token);
    \\    if (row.kind === "submit_allowed" && Math.floor(res.status / 100) !== row.expect.status_family)
    \\      fail(row, `status ${res.status}, expected ${row.expect.status_family}xx: ${await res.text()}`);
    \\    if (row.kind === "validation_error" && res.status !== row.expect.status)
    \\      fail(row, `status ${res.status}, expected ${row.expect.status}: ${await res.text()}`);
    \\  } catch (err) { fail(row, String(err)); }
    \\}
    \\if (failures.length) { console.error(failures.join("\n")); (globalThis as any).process.exit(1); }
    \\console.log(`PASS: ${handoff.parity.length} Rails migration parity row(s)`);
    \\
;

/// Fixed Playwright journey runner. Selectors follow the generated AuthForm
/// and bound-form accessibility contract; row data supplies every page/field.
pub const journey_runner_py =
    \\import json, os, sys, uuid
    \\from pathlib import Path
    \\from playwright.sync_api import sync_playwright
    \\
    \\handoff = json.loads((Path(__file__).resolve().parent.parent / "MIGRATION.handoff.json").read_text())
    \\if handoff.get("schema_version") != 1 or not isinstance(handoff.get("parity"), list):
    \\    raise SystemExit(f"unsupported migration handoff schema: {handoff.get('schema_version')}")
    \\origin = os.environ.get("ZIGAPAGOS_ORIGIN", "").rstrip("/")
    \\if not origin:
    \\    raise SystemExit("ZIGAPAGOS_ORIGIN is required (run through `zigapagos e2e`)")
    \\rows = handoff["parity"]
    \\credentials = {}
    \\
    \\def credential(collection):
    \\    if collection not in credentials:
    \\        nonce = uuid.uuid4().hex
    \\        credentials[collection] = (f"parity+{nonce}@example.invalid", f"zigapagos-parity-{nonce}")
    \\    return credentials[collection]
    \\
    \\def wait_island(page):
    \\    page.wait_for_selector("[data-z-island][data-z-hydrated]", timeout=10000)
    \\
    \\def fill_fields(page, row, invalid=False):
    \\    form = page.locator("form").last
    \\    for field in row["expect"]["fields"]:
    \\        value = field.get("invalid_value") if invalid and field["name"] == row["expect"].get("field") else field["value"]
    \\        control = form.locator(f'[name={json.dumps(field["name"])}]')
    \\        if control.get_attribute("type") == "checkbox":
    \\            control.set_checked(str(value).lower() == "true")
    \\        elif control.evaluate("el => el.tagName") == "SELECT":
    \\            control.select_option(str(value))
    \\        else:
    \\            control.fill(str(value))
    \\    return form
    \\def consume_validation_console(errors):
    \\    for index, message in enumerate(errors):
    \\        if message.startswith("Failed to load resource:") and "status of 400" in message:
    \\            errors.pop(index)
    \\            return
    \\
    \\def main():
    \\    with sync_playwright() as p:
    \\        browser = p.chromium.launch(channel="chrome")
    \\        page = browser.new_page()
    \\        errors = []
    \\        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    \\        page.on("pageerror", lambda e: errors.append(str(e)))
    \\        page.route("**/favicon.ico", lambda route: route.fulfill(status=204))
    \\        for row in [r for r in rows if r["kind"] == "signup"]:
    \\            try:
    \\                email, password = credential(row["expect"]["collection"])
    \\                page.goto(origin + row["expect"]["page_url"], wait_until="networkidle")
    \\                wait_island(page)
    \\                page.locator('input[name="email"]').fill(email)
    \\                page.locator('input[name="password"]').fill(password)
    \\                page.locator('input[name="passwordConfirm"]').fill(password)
    \\                with page.expect_navigation(wait_until="networkidle"):
    \\                    page.get_by_role("button", name="Sign up").click()
    \\            except Exception as exc: raise AssertionError(f'{row["id"]}: {exc}') from exc
    \\        for row in [r for r in rows if r["kind"] == "signin"]:
    \\            try:
    \\                email, password = credential(row["expect"]["collection"])
    \\                page.goto(origin + "/", wait_until="networkidle")
    \\                wait_island(page)
    \\                signout = page.get_by_role("button", name="Sign out")
    \\                if signout.count():
    \\                    with page.expect_navigation(wait_until="networkidle"): signout.click()
    \\                page.goto(origin + row["expect"]["page_url"], wait_until="networkidle")
    \\                wait_island(page)
    \\                page.locator('input[name="email"]').fill(email)
    \\                page.locator('input[name="password"]').fill(password)
    \\                with page.expect_navigation(wait_until="networkidle"):
    \\                    page.get_by_role("button", name="Sign in").click()
    \\                page.get_by_role("button", name="Sign out").wait_for(timeout=10000)
    \\            except Exception as exc: raise AssertionError(f'{row["id"]}: {exc}') from exc
    \\        for row in [r for r in rows if r["kind"] == "submit_allowed"]:
    \\            try:
    \\                page.goto(origin + row["expect"]["page_url"], wait_until="networkidle")
    \\                wait_island(page)
    \\                form = fill_fields(page, row)
    \\                form.get_by_role("button").click()
    \\                page.get_by_text("Done.", exact=True).wait_for(timeout=10000)
    \\            except Exception as exc: raise AssertionError(f'{row["id"]}: {exc}') from exc
    \\        for row in [r for r in rows if r["kind"] == "validation_error"]:
    \\            try:
    \\                page.goto(origin + row["expect"]["page_url"], wait_until="networkidle")
    \\                wait_island(page)
    \\                form = fill_fields(page, row, invalid=True)
    \\                form.get_by_role("button").click()
    \\                form.locator(".errors").get_by_text(row["expect"]["field"], exact=False).wait_for(timeout=10000)
    \\                consume_validation_console(errors)
    \\            except Exception as exc: raise AssertionError(f'{row["id"]}: {exc}') from exc
    \\        assert not errors, f"console/page errors: {errors}"
    \\        browser.close()
    \\    print("PASS: Rails migration browser journey")
    \\
    \\main()
    \\
;

fn writeRunnerFile(
    io: Io,
    gpa: Allocator,
    target: []const u8,
    relative: []const u8,
    bytes: []const u8,
    last_error_path: *?[]const u8,
    last_error: *?anyerror,
) WriteError!void {
    const full = try std.fs.path.join(gpa, &.{ target, relative });
    defer gpa.free(full);
    if (std.fs.path.dirname(full)) |parent| Io.Dir.cwd().createDirPath(io, parent) catch |err| {
        if (last_error_path.* == null) last_error_path.* = gpa.dupe(u8, parent) catch null;
        last_error.* = err;
        return error.TargetWrite;
    };
    const file = Io.Dir.cwd().createFile(io, full, .{ .exclusive = true }) catch |err| {
        if (last_error_path.* == null) last_error_path.* = gpa.dupe(u8, full) catch null;
        last_error.* = err;
        return error.TargetWrite;
    };
    defer file.close(io);
    var writer = file.writer(io, &.{});
    writer.interface.writeAll(bytes) catch |err| {
        if (last_error_path.* == null) last_error_path.* = gpa.dupe(u8, full) catch null;
        last_error.* = err;
        return error.TargetWrite;
    };
}

/// Write the two fixed replay programs exactly once when parity evidence
/// exists. Contract 1 (self-freeing): no allocation escapes on success.
pub fn writeParityRunners(
    io: Io,
    gpa: Allocator,
    target: []const u8,
    enabled: bool,
    last_error_path: *?[]const u8,
    last_error: *?anyerror,
) WriteError!void {
    if (!enabled) return;
    try writeRunnerFile(io, gpa, target, parity_runner_path, parity_runner_ts, last_error_path, last_error);
    try writeRunnerFile(io, gpa, target, journey_runner_path, journey_runner_py, last_error_path, last_error);
}

/// Everything `write` accumulates, in one place so a failure anywhere can
/// release all of it through one `deinit`.
const Acc = struct {
    routes: std.ArrayListUnmanaged(RouteOutcome) = .empty,
    assets: std.ArrayListUnmanaged(AssetOutcome) = .empty,
    redirects: std.ArrayListUnmanaged(Redirect) = .empty,
    spa_files: std.ArrayListUnmanaged([]const u8) = .empty,
    /// #167 Stage 3: every `.island.tsx` actually WRITTEN, in write order.
    /// `build.sh` needs one `--island=` per entry and `package.json` needs
    /// `@zigbase/client` exactly when it is non-empty -- both keyed on the
    /// file being on disk rather than on a binding merely existing, because a
    /// binding on a route ruling S20 settled produces no file (see
    /// `materializeView`).
    island_files: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The finding id of every island in `island_files`, in the same write
    /// order -- the key `materializeView`'s write-once skip compares on. Ids
    /// are BORROWED from `Discovery.findings`, which outlives `write`, so
    /// only the list itself is an allocation.
    island_ids: std.ArrayListUnmanaged([]const u8) = .empty,
    spa_uses_client: bool = false,

    fn deinit(self: *Acc, gpa: Allocator) void {
        for (self.routes.items) |o| {
            freeStrings(gpa, o.artifacts);
            freeStrings(gpa, o.open_finding_ids);
            if (o.decision_id) |d| gpa.free(d);
            if (o.note) |n| gpa.free(n);
            freeEndpoint(gpa, o.endpoint);
        }
        self.routes.deinit(gpa);
        for (self.assets.items) |a| {
            gpa.free(a.source);
            if (a.rails_url) |u| gpa.free(u);
            gpa.free(a.target_url);
        }
        self.assets.deinit(gpa);
        for (self.redirects.items) |x| {
            gpa.free(x.from);
            if (x.to) |t| gpa.free(t);
        }
        self.redirects.deinit(gpa);
        for (self.spa_files.items) |s| gpa.free(s);
        self.spa_files.deinit(gpa);
        for (self.island_files.items) |s| gpa.free(s);
        self.island_files.deinit(gpa);
        self.island_ids.deinit(gpa);
    }
};

/// The filesystem half of `write`, split out so every helper below can take
/// one parameter instead of four.
const Ctx = struct {
    io: Io,
    gpa: Allocator,
    in: Input,
    last_error_path: *?[]const u8,
    last_error: *?anyerror,
    /// #167 Stage 3, all three filled by `run` before the route walk and
    /// owned by it (see `Bindings`, and `findings.journeyRouteFlags`).
    bindings: Bindings = .{},
    /// Index-aligned with `Discovery.routes`; empty before `run` fills it.
    journey: []const bool = &.{},
    /// The one `RAILS_AUTH_JOURNEY` finding's id, borrowed from
    /// `Discovery.findings`. `null` when the app has no auth journey.
    journey_id: ?[]const u8 = null,

    /// Records `path` and the underlying OS error, and returns this file's
    /// own error. An OOM duping the path leaves `last_error_path` null rather
    /// than replacing the real failure with `OutOfMemory` -- see `write`'s
    /// doc. `last_error` is recorded either way, so the cause survives even
    /// when the path does not.
    ///
    /// `which` is a comptime enum literal rather than an `anyerror` value so
    /// the return type stays the two-member set `WriteError` accepts; an
    /// `anyerror` parameter would widen every caller to the global set.
    /// `cause` IS an `anyerror` -- it is data being recorded, not a value
    /// being returned.
    fn fail(
        self: *Ctx,
        comptime which: enum { target, source },
        path: []const u8,
        cause: anyerror,
    ) error{ TargetWrite, SourceRead } {
        if (self.last_error_path.* == null) {
            self.last_error_path.* = self.gpa.dupe(u8, path) catch null;
            self.last_error.* = cause;
        }
        return switch (which) {
            .target => error.TargetWrite,
            .source => error.SourceRead,
        };
    }

    /// Exclusive-create `<target>/<relative>`, parents included. See the
    /// module doc for why exclusive.
    fn writeFile(self: *Ctx, relative: []const u8, bytes: []const u8) WriteError!void {
        const full = try std.fs.path.join(self.gpa, &.{ self.in.target, relative });
        defer self.gpa.free(full);
        if (std.fs.path.dirname(full)) |parent| {
            Io.Dir.cwd().createDirPath(self.io, parent) catch |err|
                return self.fail(.target, parent, err);
        }
        const file = Io.Dir.cwd().createFile(self.io, full, .{ .exclusive = true }) catch |err|
            return self.fail(.target, full, err);
        defer file.close(self.io);
        // Unbuffered (`&.{}`), exactly like `migrate.zig`'s `writeTargetFile`:
        // one `writeAll` per file, so there is no buffer left to flush.
        var w = file.writer(self.io, &.{});
        w.interface.writeAll(bytes) catch |err| return self.fail(.target, full, err);
    }
};

/// The pass order, and why:
///
/// 1. assets -- independent of everything else, and the only pass that READS
///    the source tree.
/// 2. routes -- converts and writes layouts, views and content pages, and
///    collects the SPA candidates a decision approved.
/// 3. SPA files -- needs pass 2 finished, because one `.spa.tsx` lists every
///    decided route under its first path segment.
/// 4. the project files -- `zigapagos.ziggy` needs to know whether pass 1
///    copied anything, and `build.sh` needs pass 3's file list.
fn run(ctx: *Ctx, acc: *Acc) WriteError!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;

    // #167 Stage 3, all before pass 2 because every one of them is read by
    // the per-route arms and none of them depends on a route's outcome.
    //
    // The journey flags come FIRST, before `buildBindings`: Task 5's journey
    // pre-pass binds the forms of the journey's own views, so it has to know
    // which routes those are before it can walk anything.
    //
    // The view each route renders, computed exactly as `rails.discover`
    // computes it for `findings.derive` -- assumption A5's journey rule reads
    // it, and a second answer here would put the question on one set of
    // routes and the answer on another.
    const route_views = try gpa.alloc(?[]const u8, d.routes.len);
    defer gpa.free(route_views);
    for (route_views, 0..) |*slot, i| {
        slot.* = if (i < d.route_templates.len)
            pickView(d.route_templates[i].templates, d.routes[i])
        else
            null;
    }
    const journey = try findings.journeyRouteFlags(gpa, d.routes, route_views, d.fragments);
    defer gpa.free(journey);
    ctx.journey = journey;
    ctx.journey_id = firstFindingWithCode(d.findings, findings.code_auth_journey);

    ctx.bindings = try buildBindings(ctx);
    defer ctx.bindings.deinit(gpa);

    try writeAssets(ctx, acc);

    var layouts: LayoutCache = .{};
    defer layouts.deinit(ctx.gpa);
    var views: ViewCache = .{};
    defer views.deinit(ctx.gpa);
    var spa_routes: std.ArrayListUnmanaged(SpaRoute) = .empty;
    defer {
        for (spa_routes.items) |s| {
            ctx.gpa.free(s.segment);
            if (s.port_js) |body| ctx.gpa.free(body);
        }
        spa_routes.deinit(ctx.gpa);
    }

    // `island_files` is `build.sh`'s input and nothing else: unlike
    // `spa_files` it does not become part of the `Result`, because a route
    // already lists its own islands in `artifacts`. So it is released here,
    // on both paths, rather than escaping.
    defer {
        for (acc.island_files.items) |s| gpa.free(s);
        acc.island_files.deinit(gpa);
        acc.island_files = .empty;
        acc.island_ids.deinit(gpa);
        acc.island_ids = .empty;
    }

    try writeRoutes(ctx, acc, &layouts, &views, &spa_routes);
    try writeSpas(ctx, acc, spa_routes.items);
    try writeProjectFiles(ctx, acc);
}

// ---- pass 1: assets ------------------------------------------------------

/// Copies every asset whose URL discovery could pin down.
///
/// `deterministic == true` means `public_url` was derived by a rule that
/// reproduces on every machine; `pipeline == null` is the `public/` case,
/// which bypasses the pipeline entirely and is deterministic by
/// construction. An asset that is neither is one discovery could not place,
/// and copying it would put a file in the target under a name nothing
/// references.
///
/// Contract 2 (owned-result), inherited from `write`: everything appended to
/// `acc` is owned by the eventual `Result`.
fn writeAssets(ctx: *Ctx, acc: *Acc) WriteError!void {
    const gpa = ctx.gpa;
    const list = ctx.in.discovery.assets;

    // `assets.scan` documents its output as path-ordered, but this pass sorts
    // an index copy anyway rather than trusting a promise made two modules
    // away: the copy order decides `Result.assets`' order, which reaches a
    // committed artifact.
    const order = try gpa.alloc(usize, list.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, list, assetIndexLessThan);

    for (order) |i| {
        const a = list[i];
        if (!a.deterministic and a.pipeline != null) continue;
        if (isPipelineOutput(a.source)) continue;

        const rel = try resolve.assetTargetPath(gpa, a.source);
        defer gpa.free(rel);
        const dest = try std.fs.path.join(gpa, &.{ "assets", rel });
        defer gpa.free(dest);

        // 64 MiB: larger than any web asset this converter has a use for,
        // and a bound rather than `.unlimited` so a pathological file in the
        // source tree fails loudly instead of exhausting the process.
        const bytes = ctx.in.source_root.readFileAlloc(ctx.io, a.source, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.fail(.source, a.source, err),
        };
        defer gpa.free(bytes);
        try ctx.writeFile(dest, bytes);

        const source_copy = try gpa.dupe(u8, a.source);
        errdefer gpa.free(source_copy);
        const rails_url = if (a.public_url) |u| try gpa.dupe(u8, u) else null;
        errdefer if (rails_url) |u| gpa.free(u);
        const target_url = try std.fmt.allocPrint(gpa, "/{s}", .{rel});
        errdefer gpa.free(target_url);
        try acc.assets.append(gpa, .{
            .source = source_copy,
            .rails_url = rails_url,
            .target_url = target_url,
        });
    }
}

fn assetIndexLessThan(list: []const asset_mod.Asset, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, list[a].source, list[b].source);
}

/// Ruling S17: `public/assets/**` is the asset pipeline's compiled OUTPUT --
/// Propshaft's `.manifest.json`, Sprockets' `manifest-*.json`, and one
/// digested copy of every `app/assets/` source. None of it belongs in the
/// target: the sources themselves are copied from `app/assets/` (their
/// target path comes from `resolve.assetTargetPath`, their Rails URL from
/// the very manifest sitting here), so copying this directory too would ship
/// each asset twice -- once under `assets/images/logo.png` and once under
/// `assets/assets/logo-abc123.png` -- plus a Rails bookkeeping file at
/// `assets/assets/.manifest.json` that nothing in a Zigapagos site reads.
///
/// Filtered HERE and not in `assets.zig`: discovery's job is to inventory
/// what the Rails app serves, and it does serve these files. Which of them a
/// converted site should CARRY is a conversion question, and this is the
/// conversion.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn isPipelineOutput(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "public/assets/");
}

// ---- pass 2: routes ------------------------------------------------------

/// One converted layout, kept so a layout shared by twenty routes is
/// converted and written once. Every string is `gpa`-owned.
const Layout = struct {
    /// The Rails path (`app/views/layouts/marketing.html.erb`), the cache key.
    source: []const u8,
    /// `resolve.layoutStem`, i.e. the `layouts/templates/<stem>.shtml` name.
    stem: []const u8,
    /// Target-relative path written.
    artifact: []const u8,
    open_ids: [][]const u8,
    /// This layout's `convert.Output.block_ids`: every id it declares a
    /// `<super>` under, which is exactly what a view extending it must fill.
    /// Fed straight to `convert.Context.layout_blocks` in `ensureView`.
    ///
    /// Read off the converter's own report rather than sniffed out of the
    /// emitted bytes. Both directions are fatal in SuperHTML -- a block with
    /// no `<super>` is `UNBOUND TOP-LEVEL BLOCK`, a `<super>` with no block
    /// is `MISSING TOP-LEVEL BLOCK` -- so a `yield :sidebar` the scaffolder
    /// failed to notice would produce a site that does not build.
    block_ids: [][]const u8,
    /// Human notes from the layout's conversion ("csrf_meta_tags dropped").
    dropped: [][]const u8,
    /// The first `<!-- rails:unmapped <kind> -->` in the layout, if any.
    unmapped_kind: ?[]const u8,
    /// #167 Stage 3 Task 5: the ids a binding in THIS layout answered, and the
    /// island files it produced.
    ///
    /// A layout binds at all because the `current_user` region lives in a
    /// `shared/_nav` partial that the LAYOUT renders, not any view -- the
    /// commonest place in Rails to put a sign-in/sign-out control, and the
    /// presentation fixture's own shape. Unlike a view's, these are written on
    /// the spot: `ensureLayout` writes the layout unconditionally (ruling S20
    /// is about PAGES), and an island a written layout mounts must be on disk
    /// beside it.
    bound_ids: [][]const u8,
    /// Ruling S3-R6: which of `bound_ids` were answered by an ENCLOSING
    /// region's binding, and by which. Owned slice of borrowed strings -- see
    /// `convert.Enclosure`.
    enclosed: []convert.Enclosure,
    islands: []IslandFile,
};

const LayoutCache = struct {
    items: std.ArrayListUnmanaged(Layout) = .empty,

    fn deinit(self: *LayoutCache, gpa: Allocator) void {
        for (self.items.items) |l| freeLayout(gpa, l);
        self.items.deinit(gpa);
    }

    fn find(self: *const LayoutCache, source: []const u8) ?usize {
        for (self.items.items, 0..) |l, i| {
            if (std.mem.eql(u8, l.source, source)) return i;
        }
        return null;
    }
};

fn freeLayout(gpa: Allocator, l: Layout) void {
    gpa.free(l.source);
    gpa.free(l.stem);
    gpa.free(l.artifact);
    freeStrings(gpa, l.open_ids);
    freeStrings(gpa, l.block_ids);
    freeStrings(gpa, l.dropped);
    if (l.unmapped_kind) |k| gpa.free(k);
    freeStrings(gpa, l.bound_ids);
    gpa.free(l.enclosed);
    for (l.islands) |f| {
        gpa.free(f.path);
        gpa.free(f.bytes);
    }
    gpa.free(l.islands);
}

/// One converted view, cached for the same reason as `Layout`: two routes
/// routinely render one view (`root "pages#about"` alongside
/// `get "/about"`), and `layouts/<viewStem>.shtml` may only be written once.
const View = struct {
    source: []const u8,
    /// The layout this conversion was made against (an index into the layout
    /// cache; `null` for a standalone view). Part of the cache KEY, not just
    /// a record: a view's bytes are a function of its layout -- the
    /// `<extend template=...>` names it, and `layout_blocks` decides which
    /// blocks the view emits -- so a conversion made under one layout is not
    /// reusable under another. See `ViewCache.find` (ruling S16).
    layout_index: ?usize,
    artifact: []const u8,
    /// The converted bytes, held rather than written on the spot: ruling S20
    /// means a route acknowledged `retained`/`blocked` writes NO page and no
    /// view file, and whether that applies is only known after the view has
    /// been converted (its findings are what the operator answered). See
    /// `materializeView`.
    bytes: []const u8,
    /// Whether `artifact` is on disk yet. The cache is keyed by
    /// (view, layout) and a view can serve several routes, so the FIRST route
    /// that actually needs the file writes it and the rest reuse it -- which
    /// is also why the skip is "do not write yet" rather than "do not
    /// convert": a later route sharing this view may well need it.
    written: bool,
    /// The `.layout` value a content page points at.
    layout_value: []const u8,
    title: ?[]const u8,
    description: ?[]const u8,
    open_ids: [][]const u8,
    unmapped_kind: ?[]const u8,
    /// Human notes from the view's conversion. Includes, since ruling S9, a
    /// `content_for` naming a block the layout does not declare -- the
    /// converter drops it (it would be an `UNBOUND TOP-LEVEL BLOCK`) and says
    /// so here, which is the only place that loss is visible.
    dropped: [][]const u8,
    /// #167 Stage 3: the ids this view's bindings ANSWERED. Not open -- but
    /// still answerable, which is a different thing: an operator who wrote
    /// `retain` against the error summary a bound form absorbed is saying the
    /// page stays on Rails, and that has to outrank the binding (ruling S19,
    /// and the precedence `applyAcknowledgement` documents).
    bound_ids: [][]const u8,
    /// Ruling S3-R6: which of `bound_ids` were answered by an ENCLOSING
    /// region's binding, and by which. Owned slice of borrowed strings -- see
    /// `convert.Enclosure`.
    enclosed: []convert.Enclosure,
    /// #167 Stage 3: the `.island.tsx` files this view's bound regions became,
    /// held rather than written for the same reason `bytes` is (ruling S20) --
    /// a route acknowledged `retained`/`blocked` ships no page, and an island
    /// its page does not reference would be dead source in the target.
    islands: []IslandFile,
};

/// One generated island: where it goes, what is in it, and which answered
/// finding it IS. `path` and `bytes` are owned by the `View` that holds it;
/// `finding_id` is borrowed from `Discovery.findings`, which outlives `write`.
///
/// The id is carried because it, not the path, is this island's identity: two
/// views rendering one shared partial hold the same island under the same
/// path, while two colliding view stems would hold DIFFERENT islands under
/// one path if `uniqueIslandPath` ever stopped de-colliding them. See
/// `materializeView`'s write-once skip.
const IslandFile = struct { path: []const u8, bytes: []const u8, finding_id: []const u8 };

const ViewCache = struct {
    items: std.ArrayListUnmanaged(View) = .empty,

    fn deinit(self: *ViewCache, gpa: Allocator) void {
        for (self.items.items) |v| freeView(gpa, v);
        self.items.deinit(gpa);
    }

    /// The cached conversion of `source` made against `layout_index`, or
    /// null. BOTH halves are the key (ruling S16): reusing a conversion made
    /// under a different layout would give the route an `<extend>` naming the
    /// wrong parent and a block set the wrong layout declares -- which
    /// SuperHTML rejects outright, so the generated site would not build.
    fn find(self: *const ViewCache, source: []const u8, layout_index: ?usize) ?usize {
        for (self.items.items, 0..) |v, i| {
            if (!std.mem.eql(u8, v.source, source)) continue;
            if (v.layout_index == null and layout_index == null) return i;
            const a = v.layout_index orelse continue;
            const b = layout_index orelse continue;
            if (a == b) return i;
        }
        return null;
    }

    /// The FIRST cached conversion of `source` under any layout. Used only to
    /// report the clash: the target has one `layouts/<viewStem>.shtml`, so
    /// when the key misses but this hits, the view is already owned by an
    /// earlier route under a different layout.
    fn findAnyLayout(self: *const ViewCache, source: []const u8) ?usize {
        for (self.items.items, 0..) |v, i| {
            if (std.mem.eql(u8, v.source, source)) return i;
        }
        return null;
    }
};

fn freeView(gpa: Allocator, v: View) void {
    gpa.free(v.source);
    gpa.free(v.artifact);
    gpa.free(v.bytes);
    gpa.free(v.layout_value);
    if (v.title) |t| gpa.free(t);
    if (v.description) |d| gpa.free(d);
    freeStrings(gpa, v.open_ids);
    freeStrings(gpa, v.bound_ids);
    gpa.free(v.enclosed);
    freeStrings(gpa, v.dropped);
    if (v.unmapped_kind) |k| gpa.free(k);
    for (v.islands) |f| {
        gpa.free(f.path);
        gpa.free(f.bytes);
    }
    gpa.free(v.islands);
}

/// A dynamic route an operator answered `spa`, waiting for pass 3.
const SpaRoute = struct {
    /// First path segment, owned; names the `.spa.tsx` this route lands in.
    segment: []const u8,
    /// Position in `acc.routes`, so pass 3 can append the artifact.
    outcome_index: usize,
    /// Position in `Discovery.routes`.
    route_index: usize,
    /// Ported record-view body for a dynamic SPA route; owned when present.
    port_js: ?[]u8 = null,
    collection: ?[]const u8 = null,
    param: ?[]const u8 = null,
};

/// Total order over routes: `(path, verb, controller, action)`. Mirrors
/// `report.routeLessThan` (this file cannot import `report.zig` without
/// pulling a report emitter into a scaffolder, and the order is three
/// comparisons). It decides the order files are WRITTEN in, which is what
/// makes an exclusive-create collision reproducible rather than dependent on
/// the sidecar's emission order.
fn routeLessThan(list: []const route_mod.Route, ai: usize, bi: usize) bool {
    const a = list[ai];
    const b = list[bi];
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (std.mem.order(u8, a.verb, b.verb)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (orderOptional(a.controller, b.controller)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return orderOptional(a.action, b.action) == .lt;
}

fn orderOptional(a: ?[]const u8, b: ?[]const u8) std.math.Order {
    if (a == null and b == null) return .eq;
    if (a == null) return .lt;
    if (b == null) return .gt;
    return std.mem.order(u8, a.?, b.?);
}

/// What one route's arm builds before it becomes a `RouteOutcome`. Every
/// owned field is handed straight to the outcome, so nothing here is freed
/// on the success path.
const Outcome = struct {
    status: Status = .open,
    artifacts: std.ArrayListUnmanaged([]const u8) = .empty,
    open_ids: std.ArrayListUnmanaged([]const u8) = .empty,
    decision_id: ?[]const u8 = null,
    /// Everything worth telling the operator about this route, joined with
    /// `"; "`. Two KINDS of thing land here and they must not be confused:
    /// a reason the route is not finished (`addOpenNote`) and an
    /// informational note about what the conversion dropped along the way
    /// (`addNote`, fed from `convert.Output.dropped`). Only the first kind
    /// may keep a route out of `migrated` -- `csrf_meta_tags dropped` is a
    /// fact about a helper with a defined conversion, and letting it block
    /// the status would mean no route with a layout ever migrated.
    note: ?[]const u8 = null,
    /// Set by `addOpenNote`: something named in `note` means this route is
    /// not finished, over and above whatever `open_ids` says.
    unfinished: bool = false,
    /// #167 Stage 3; handed straight to the `RouteOutcome`.
    endpoint: ?Endpoint = null,

    fn deinit(self: *Outcome, gpa: Allocator) void {
        for (self.artifacts.items) |s| gpa.free(s);
        self.artifacts.deinit(gpa);
        for (self.open_ids.items) |s| gpa.free(s);
        self.open_ids.deinit(gpa);
        if (self.decision_id) |d| gpa.free(d);
        if (self.note) |n| gpa.free(n);
        freeEndpoint(gpa, self.endpoint);
    }

    /// Appends an informational note. Never changes the status.
    fn addNote(self: *Outcome, gpa: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const text = if (self.note) |old|
            try std.fmt.allocPrint(gpa, "{s}; " ++ fmt, .{old} ++ args)
        else
            try std.fmt.allocPrint(gpa, fmt, args);
        if (self.note) |old| gpa.free(old);
        self.note = text;
    }

    /// Appends a note AND marks the route unfinished.
    fn addOpenNote(self: *Outcome, gpa: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.addNote(gpa, fmt, args);
        self.unfinished = true;
    }

    /// Drops one finding id from the open list: the operator's answer did not
    /// merely acknowledge it, it RESOLVED it (#167 Stage 3 -- a form bound to
    /// a backend operation, a guard shipped `public`). Leaving it open would
    /// keep the route out of `migrated` for a question that has been answered
    /// AND acted on, which is the difference between this and `retain`.
    ///
    /// Contract 2 (owned-result), inherited from `write`: it allocates
    /// nothing and FREES the id it removes, which `out.open_ids` owned.
    fn settle(self: *Outcome, gpa: Allocator, id: []const u8) void {
        var i: usize = 0;
        while (i < self.open_ids.items.len) {
            if (std.mem.eql(u8, self.open_ids.items[i], id)) {
                gpa.free(self.open_ids.orderedRemove(i));
                continue;
            }
            i += 1;
        }
    }
};

/// A content path already written, and the route that claimed it. Ruling
/// S14's second half: two routes CAN map to one `content/<...>/index.smd`
/// (`/about` and `/about/` are one path after `resolve.contentPath`
/// normalises the trailing slash, and a Rails app can declare both), and the
/// second write would then hit the exclusive-create guard and abort the whole
/// migration over a duplicate route declaration. That is a route-level
/// problem with a route-level answer, so it becomes a route-level outcome.
const ContentClaim = struct {
    /// Target-relative `content/...` path, owned by `writeRoutes`.
    path: []const u8,
    /// `<verb> <path>` of the route that got there first, owned likewise.
    route_id: []const u8,
};

// ---- #167 Stage 3: the operator's backend answers -------------------------

/// An endpoint while it still borrows the inputs it was read out of (the
/// `--backend` document, the decisions file, a verb this pass allocated into
/// `Bindings.owned`). `routeOutcome` dupes one into the owned `Endpoint` a
/// `RouteOutcome` carries.
const EndpointRef = struct {
    operation_id: []const u8,
    verb: []const u8,
    path: []const u8,
};

/// Every backend answer this run turns into an island, plus the endpoint each
/// one puts on a route.
///
/// Built ONCE, before the route walk, because its two halves sit at opposite
/// ends of that walk: the island belongs to the GET route whose view holds
/// the form, while the endpoint belongs to the non-GET route Rails' own
/// convention pairs with it (`registrations#new`'s form submits to
/// `registrations#create`). The walk visits routes in path order, so whichever
/// of the pair came second would have to reach backwards into an outcome
/// already appended -- and `POST /registration` sorts before
/// `GET /registration/new`, so that is the ordinary case, not the exotic one.
///
/// Contract 2 (owned-result): `all`, `endpoints` and every string in `owned`
/// are fresh allocations released by `deinit`. The strings `all` and
/// `endpoints` point at are a mix of those and of borrows from `Input`
/// (`decisions`, `backend`, the node streams) -- all of which outlive the
/// `write` call by construction.
const Bindings = struct {
    all: []convert.Binding = &.{},
    /// Index-aligned with `Discovery.routes`; `null` for a route no answer
    /// reaches.
    endpoints: []?EndpointRef = &.{},
    owned: [][]const u8 = &.{},
    /// #167 Stage 3 Task 5: the auth journey's answer, or `null` when there is
    /// no journey or the operator did not answer it `island`. Every string in
    /// it borrows `Input`/`owned`.
    scaffold: ?JourneyScaffold = null,
    /// Every ERB region the one `AuthStatus` stands in for, in source order.
    ///
    /// The component is shared, so its header has to name all of them (a
    /// header naming one names whichever page happened to be written first,
    /// which would also make the file's bytes depend on the route table). The
    /// `absorbed` rows are the ones that mount nothing, and are what a route's
    /// note points at so an operator can see why one of two answers produced
    /// no second component.
    ///
    /// The slice is owned; every string in it borrows `Discovery`.
    status_origins: []StatusOrigin = &.{},
    identifier_slices: [][]const []const u8 = &.{},
    stimulus_paths: []InteractionPath = &.{},
    component_paths: []InteractionPath = &.{},
    alias_slices: [][]const port.Alias = &.{},

    fn deinit(self: Bindings, gpa: Allocator) void {
        gpa.free(self.status_origins);
        for (self.identifier_slices) |slice| gpa.free(slice);
        gpa.free(self.identifier_slices);
        gpa.free(self.stimulus_paths);
        gpa.free(self.component_paths);
        for (self.alias_slices) |slice| gpa.free(slice);
        gpa.free(self.alias_slices);
        gpa.free(self.all);
        gpa.free(self.endpoints);
        freeStrings(gpa, self.owned);
    }
};

const InteractionPath = struct { identifier: []const u8, path: []const u8 };

/// Mutable state `buildBindings` and its helpers append into.
const BindingAcc = struct {
    all: std.ArrayListUnmanaged(convert.Binding) = .empty,
    owned: std.ArrayListUnmanaged([]const u8) = .empty,
    endpoints: []?EndpointRef,
    identifier_slices: std.ArrayListUnmanaged([]const []const u8) = .empty,
    stimulus_paths: std.ArrayListUnmanaged(InteractionPath) = .empty,
    component_paths: std.ArrayListUnmanaged(InteractionPath) = .empty,
    alias_slices: std.ArrayListUnmanaged([]const port.Alias) = .empty,

    fn deinit(self: *BindingAcc, gpa: Allocator) void {
        self.all.deinit(gpa);
        for (self.owned.items) |s| gpa.free(s);
        self.owned.deinit(gpa);
        for (self.identifier_slices.items) |slice| gpa.free(slice);
        self.identifier_slices.deinit(gpa);
        self.stimulus_paths.deinit(gpa);
        self.component_paths.deinit(gpa);
        for (self.alias_slices.items) |slice| gpa.free(slice);
        self.alias_slices.deinit(gpa);
    }

    /// Takes ownership of `s` and returns it, so a caller can write
    /// `acc.keep(try …)` and stop tracking the allocation itself.
    ///
    /// Contract 2 (owned-result), inherited from `buildBindings`: `s` becomes
    /// the list's, released by `Bindings.deinit`. On a failure to grow the
    /// list the `errdefer` frees `s` rather than leaking the very allocation
    /// the caller just handed over.
    fn keep(self: *BindingAcc, gpa: Allocator, s: []const u8) Allocator.Error![]const u8 {
        errdefer gpa.free(s);
        try self.owned.append(gpa, s);
        return s;
    }

    fn keepIdentifiers(self: *BindingAcc, gpa: Allocator, names: []const []const u8) Allocator.Error![]const []const u8 {
        const copy = try gpa.dupe([]const u8, names);
        errdefer gpa.free(copy);
        try self.identifier_slices.append(gpa, copy);
        return copy;
    }

    fn keepAliases(self: *BindingAcc, gpa: Allocator, aliases: []const port.Alias) Allocator.Error![]const port.Alias {
        const copy = try gpa.dupe(port.Alias, aliases);
        errdefer gpa.free(copy);
        try self.alias_slices.append(gpa, copy);
        return copy;
    }

    fn stimulusPath(self: *BindingAcc, gpa: Allocator, identifier: []const u8) Allocator.Error![]const u8 {
        for (self.stimulus_paths.items) |item| if (std.mem.eql(u8, item.identifier, identifier)) return item.path;
        var ordinal: usize = 1;
        const path = while (true) : (ordinal += 1) {
            const candidate = try flattenedInteractionPath(gpa, "components/stimulus/", identifier, ordinal);
            var taken = islandTaken(self.all.items, candidate);
            for (self.stimulus_paths.items) |item| if (std.mem.eql(u8, item.path, candidate)) {
                taken = true;
                break;
            };
            if (!taken) break try self.keep(gpa, candidate);
            gpa.free(candidate);
        };
        try self.stimulus_paths.append(gpa, .{ .identifier = identifier, .path = path });
        return path;
    }

    fn componentPath(self: *BindingAcc, gpa: Allocator, name: []const u8) Allocator.Error![]const u8 {
        for (self.component_paths.items) |item| if (std.mem.eql(u8, item.identifier, name)) return item.path;
        var reserved: std.ArrayListUnmanaged([]const u8) = .empty;
        defer reserved.deinit(gpa);
        try reserved.appendSlice(gpa, &.{ "components/AuthForm.island.tsx", "components/AuthStatus.island.tsx", turbo_frame_island_path });
        for (self.stimulus_paths.items) |item| try reserved.append(gpa, item.path);
        for (self.component_paths.items) |item| try reserved.append(gpa, item.path);
        const path = try self.keep(gpa, try uniqueInteractionPath(gpa, self.all.items, "components/", name, reserved.items));
        try self.component_paths.append(gpa, .{ .identifier = name, .path = path });
        return path;
    }
};

/// What one answered choice names on the backend side. `null` for the answers
/// that name no operation at all -- `retain` and `blocked`, which are
/// acknowledgements -- and for an operation id with no `--backend` document
/// to resolve it against.
///
/// Contract 3 (caller-buffer) apart from the verb: every string borrows the
/// document or the decision, and `verb_fallback` is returned as-is.
fn resolveChoice(
    doc: ?backend_mod.Document,
    choice: []const u8,
    verb_fallback: []const u8,
) ?struct { kind: convert.Binding.Kind, operation_id: []const u8, verb: []const u8, path: []const u8, collection: ?[]const u8 } {
    // Assumption A3: `custom:/<path>` is validated for SHAPE by
    // `decisions.parse` and resolves against nothing -- it exists precisely
    // for a route the document does not carry. The verb is the one the Rails
    // control submits with, because the answer supplies none.
    const custom = "custom:";
    if (std.mem.startsWith(u8, choice, custom)) return .{
        .kind = .custom,
        .operation_id = "custom",
        .verb = verb_fallback,
        .path = choice[custom.len..],
        .collection = null,
    };
    const d = doc orelse return null;
    const op = backend_mod.operationFor(d, choice) orelse return null;
    return .{
        .kind = .operation,
        .operation_id = op.operation_id,
        .verb = op.verb,
        .path = op.path,
        .collection = op.collection,
    };
}

/// `app/views/registrations/new.html.erb` + ordinal 1 ->
/// `components/forms/registrations_new.island.tsx`; ordinal 2 ->
/// `…_new_2.island.tsx`.
///
/// The view stem with `/` flattened to `_` rather than a nested directory,
/// because `release`'s `--island=` bundles are named by BASENAME
/// (`/islands/<name>.js`), so `components/forms/posts/new.island.tsx` and
/// `components/forms/pages/new.island.tsx` would collide in the built site
/// while looking distinct in the source tree. `uniqueIslandPath`, not this,
/// is what a caller wants: flattening makes two DISTINCT view stems collide,
/// and only the caller can see the names already claimed.
///
/// Contract 1 (self-freeing): the returned path is the only allocation.
fn islandPath(gpa: Allocator, view_path: []const u8, ordinal: usize) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "components/forms/");
    for (resolve.viewStem(view_path)) |ch| try out.append(gpa, if (ch == '/') '_' else ch);
    if (ordinal > 1) try out.print(gpa, "_{d}", .{ordinal});
    try out.appendSlice(gpa, ".island.tsx");
    return out.toOwnedSlice(gpa);
}

/// Is `path` the island of a binding built already?
fn islandTaken(built: []const convert.Binding, path: []const u8) bool {
    for (built) |b| {
        if (std.mem.eql(u8, b.island, path)) return true;
    }
    return false;
}

/// `islandPath` with the ordinal advanced past every name a binding already
/// holds.
///
/// Flattening `/` to `_` makes distinct view stems collide:
/// `app/views/a_b/new.html.erb` and `app/views/a/b_new.html.erb` both become
/// `components/forms/a_b_new.island.tsx`. That is NOT the shared-partial case
/// `materializeView` deduplicates -- two templates, two findings, two answered
/// endpoints -- so letting the name repeat means one page ships the other
/// page's form under its own layout, silently, with the route still reported
/// `migrated`. The flattening itself cannot be dropped (that is what keeps the
/// built site's `/islands/<name>.js` basenames apart), so the collision is
/// broken with the ordinal `_2` already numbers a second form in one template
/// with: the counter is per NAME, and a name that is taken is a name the next
/// binding skips. Keyed on template identity, since each template is bound
/// exactly once (`buildBindings`'s `seen`), so two distinct templates can
/// never end up on one path.
///
/// Contract 1 (self-freeing): every rejected candidate is freed here, and the
/// returned path is the only allocation that escapes.
fn uniqueIslandPath(
    gpa: Allocator,
    built: []const convert.Binding,
    view_path: []const u8,
    ordinal: usize,
) Allocator.Error![]u8 {
    var n = ordinal;
    while (true) : (n += 1) {
        const candidate = try islandPath(gpa, view_path, n);
        if (!islandTaken(built, candidate)) return candidate;
        gpa.free(candidate);
    }
}

/// The action Rails' own convention pairs a form-bearing page action with:
/// `new` submits to `create`, `edit` to `update`. `null` for anything else --
/// a form on a page that is neither is one this stage cannot pair, and
/// guessing would put an endpoint on a route the app never posts to.
fn pairedAction(action: ?[]const u8) ?[]const u8 {
    const a = action orelse return null;
    if (std.mem.eql(u8, a, "new")) return "create";
    if (std.mem.eql(u8, a, "edit")) return "update";
    return null;
}

/// The non-GET route `pairedAction` names, as an index into
/// `Discovery.routes`.
fn pairedRoute(d: *const rails.Discovery, r: route_mod.Route) ?usize {
    const controller = r.controller orelse return null;
    const want = pairedAction(r.action) orelse return null;
    for (d.routes, 0..) |other, i| {
        if (std.mem.eql(u8, other.verb, "GET") or std.mem.eql(u8, other.verb, "HEAD")) continue;
        const c = other.controller orelse continue;
        const a = other.action orelse continue;
        if (std.mem.eql(u8, c, controller) and std.mem.eql(u8, a, want)) return i;
    }
    return null;
}

/// The route a bound `link_to`/`button_to` submits to, as an index into
/// `Discovery.routes`.
///
/// A link names its own target, so there is no convention to read it through:
/// `button_to "Sign out", session_path, method: :delete` means the `DELETE`
/// route Rails named `session`, and `link_to "x", "/session", method: :delete`
/// means the `DELETE` route at that literal path. Both keys are matched
/// alongside the VERB, because one name and one path each cover several verbs
/// (`session_path` is `GET`, `POST` and `DELETE`) and a single answer cannot
/// stand for all of them.
///
/// `null` when the link's verb was not recovered, or when nothing in the
/// route table matches -- an answer for a route this app does not declare is
/// one the operator still owns on the route's own finding.
///
/// The lookup itself is `findings.linkTargetRoute`, and shared rather than
/// restated: `findings.deriveMutationLink` ranks the link's CHOICES against
/// the resource this route names, and this pass hands the chosen operation's
/// endpoint to the route this returns. Two copies could disagree, and then the
/// operator would be offered one route's operations and see another route
/// bound.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn linkRoute(d: *const rails.Discovery, n: fragments.Node, verb: ?[]const u8) ?usize {
    return findings.linkTargetRoute(d.routes, n, verb);
}

/// Where the paired action sends the browser after a successful mutation.
///
/// The REDIRECT is the paired action's, not this page's: a `new` page does
/// not redirect, its `create` does, and that is the one fact an operator
/// would otherwise have to re-enter by hand for every bound form.
///
/// Contract 1 (self-freeing): the returned URL is the only allocation.
fn pairedRedirect(ctx: *Ctx, r: route_mod.Route) Allocator.Error!?[]const u8 {
    const want = pairedAction(r.action) orelse return null;
    return actionRedirect(ctx, r.controller, want);
}

/// Where one Rails action sends the browser, as a site URL.
///
/// Shared by the form pairing (which asks for the action Rails' convention
/// names) and the link pairing (which asks for the action the link's own
/// target route runs), so the two cannot drift over how a `redirect_to` is
/// resolved.
///
/// Contract 1 (self-freeing): the returned URL is the only allocation.
fn actionRedirect(ctx: *Ctx, controller: ?[]const u8, action_name: []const u8) Allocator.Error!?[]const u8 {
    const d = ctx.in.discovery;
    const c = controller orelse return null;
    const action = controllers.find(d.actions, c, action_name) orelse return null;
    return resolve.redirectUrl(ctx.gpa, d.routes, action.redirects);
}

fn findingById(list: []const findings.Finding, id: []const u8) ?findings.Finding {
    for (list) |f| {
        if (std.mem.eql(u8, f.id, id)) return f;
    }
    return null;
}

/// The id of the first finding carrying `code`, borrowed from `list`.
///
/// Used for the one row whose id NO route can recompute: ruling S22 keys
/// `RAILS_AUTH_JOURNEY` on the smallest `config/routes.rb` line the journey
/// occupies, so `routeFindingId(code, r.source.line)` answers correctly for
/// exactly one of the journey's routes and wrongly for the rest. `findings.
/// derive` emits at most one per app.
fn firstFindingWithCode(list: []const findings.Finding, code: []const u8) ?[]const u8 {
    for (list) |f| {
        if (std.mem.eql(u8, f.code, code)) return f.id;
    }
    return null;
}

// ---- #167 Stage 3 Task 5: the auth journey --------------------------------

/// What one `island` answer on `RAILS_AUTH_JOURNEY` produces.
///
/// Every string BORROWS: `collection` the decision's own `artifact`, the two
/// redirects either a literal or a `BindingAcc.owned` allocation, `signin_url`
/// the route table.
const JourneyScaffold = struct {
    /// The `RAILS_AUTH_JOURNEY` row this answers -- the ONE such row an app
    /// has (assumption A5 folds the whole flow into a single finding).
    ///
    /// Carried on the scaffold rather than re-read from `ctx.journey_id` at
    /// each use because it is what every journey binding's `finding_id` is,
    /// and `writeIslandFiles` keys its write-once skip on that id: both
    /// `AuthForm` bindings share one path, so they must share one id or the
    /// skip's assertion is a lie. A `?[]const u8` re-read per site would let
    /// an `orelse ""` creep back in and make that id empty -- and an empty id
    /// is one every other empty id would then dedupe against.
    finding_id: []const u8,
    /// The write-once key for `AuthStatus`, and the reason it is not
    /// `finding_id`.
    ///
    /// `AuthStatus` is a JOURNEY-level artifact like `AuthForm` -- one file
    /// that renders both the signed-in and the signed-out branch -- but unlike
    /// `AuthForm` it is mounted from a finding of its OWN: every answered
    /// `current_user`/`signed_in?` region gets a binding carrying that
    /// region's id, because that id is what settles the region and what
    /// `convert.zig` joins the `<island>` onto. A nav with both halves
    /// (`<% if current_user %>…<% end %><% unless current_user %>…<% end %>`)
    /// is two such regions, and so is `current_user` in `shared/_nav` plus
    /// `signed_in?` on a page's own view. Keying the write-once skip on those
    /// ids made the second island look unwritten while its path was already on
    /// disk: the assertion fired, and with assertions off `writeFile`'s
    /// exclusive-create guard fataled `PathAlreadyExists` over a half-written
    /// target.
    ///
    /// So the FILE gets one identity and the REGIONS keep theirs. Derived from
    /// the journey's id rather than being a bare literal so it cannot collide
    /// with a real finding id, and so an operator reading a crash can see
    /// which journey it belongs to.
    status_id: []const u8,
    /// The ZigBase auth collection the operator named (`users`).
    collection: []const u8,
    /// Where `sessions#create` sent the browser, `/` when this run cannot
    /// name one -- an auth island that authenticated and then stayed put
    /// would look broken, and `/` is the one destination every site has.
    signin_redirect: []const u8,
    /// The same for `registrations#create`.
    signup_redirect: []const u8,
    /// The journey's `sessions#new` path, for `AuthStatus`'s signed-out link.
    /// `null` for a journey detected ONLY by a password form (A5's second
    /// half): there is no sign-in page to point at, and a link to a route
    /// that does not exist is worse than no link.
    signin_url: ?[]const u8,
};

/// One ERB region the shared `AuthStatus` replaced. Every string borrows
/// `Discovery` (the finding list, and the template's own node stream).
const StatusOrigin = struct {
    path: []const u8,
    line: u64,
    col: u64,
    /// The region's own source, e.g. `if current_user`.
    code: []const u8,
    finding_id: []const u8,
    /// True for the half of a complementary pair that mounts nothing.
    absorbed: bool,
    /// True for a region that lies INSIDE another answered status region --
    /// `<%= current_user.email %>` written inside `<% if signed_in? %>`, which
    /// is how a nav that shows the visitor's address is usually written.
    ///
    /// It mounts nothing for a different reason than `absorbed` does: nothing
    /// folded it, `convert.zig` simply never reaches it. The outer region's
    /// island replaces `nodes[open..end]` wholesale and the walk resumes past
    /// `end`, so the inner region's own answer produces no markup of its own.
    /// Kept apart from `absorbed` because the two need different words: an
    /// operator told a region was "folded into the region above" and then
    /// finding no complementary region above it learns nothing.
    enclosed: bool = false,
};

/// Which way a `request_state` region's branch runs, and on what.
///
/// `null` when the code is not a branch this pass understands -- and an
/// unrecognised code pairs with nothing, which is the safe direction: two
/// mounts render a duplicate control, while a wrong pairing DELETES one.
///
/// Contract 3 (caller-buffer): allocates nothing; `predicate` borrows `code`.
const Branch = struct { predicate: []const u8, positive: bool };

fn regionBranch(code: []const u8) ?Branch {
    var rest = std.mem.trim(u8, code, " \t");
    var positive: bool = undefined;
    if (wordPrefix(rest, "unless")) |tail| {
        positive = false;
        rest = tail;
    } else if (wordPrefix(rest, "if")) |tail| {
        positive = true;
        rest = tail;
    } else return null;

    // `unless !x` is `if x`, and Rails codebases hold every spelling of this.
    while (true) {
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len > 0 and rest[0] == '!') {
            positive = !positive;
            rest = rest[1..];
            continue;
        }
        if (wordPrefix(rest, "not")) |tail| {
            positive = !positive;
            rest = tail;
            continue;
        }
        break;
    }
    rest = std.mem.trim(u8, rest, " \t");
    if (rest.len == 0) return null;
    return .{ .predicate = rest, .positive = positive };
}

/// `s` past `word`, when `s` starts with it AND a word boundary follows.
/// `null` otherwise, so `iffy` is not read as `if`.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn wordPrefix(s: []const u8, word: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, word)) return null;
    const rest = s[word.len..];
    if (rest.len == 0) return null;
    if (std.ascii.isAlphanumeric(rest[0]) or rest[0] == '_' or rest[0] == '?' or rest[0] == '!') return null;
    return rest;
}

/// The four names Rails' own authentication generators and every guide give
/// the "is somebody signed in" helper. A `request_state` region under one of
/// them is what `AuthStatus` replaces; anything else is Stage 4's component
/// port (assumption A6's neighbour), because this island reads a store only
/// an auth journey writes.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn isAuthStatusName(name: ?[]const u8) bool {
    const n = name orelse return false;
    const known = [_][]const u8{ "current_user", "signed_in?", "logged_in?", "user_signed_in?" };
    for (known) |k| {
        if (std.mem.eql(u8, n, k)) return true;
    }
    return false;
}

/// ZigBase's own `<Base>`: the collection name with `_`/`-` removed and each
/// word capitalised (`users` -> `Users`, `blog_users` -> `BlogUsers`), which
/// is how it derives every `<verb><Base>` operation id.
///
/// Re-derived here rather than looked up in the `--backend` document because
/// TWO of the journey's three endpoints are not in that document at all:
/// `x-zigbase-coverage.allAuthMethods` is always `false`, so
/// `auth-with-password` and `auth-logout` have no operation ids to find. A
/// trio where one member came from the document and two were synthesized
/// would disagree with itself the moment the document did; one rule for all
/// three is the only shape that cannot. The test
/// `authBaseName is ZigBase's own <Base> rule...` pins the rule against a real
/// document's own `create<Base>` id.
///
/// Contract 1 (self-freeing): the returned name is the only allocation.
fn authBaseName(gpa: Allocator, collection: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var upper = true;
    for (collection) |ch| {
        if (ch == '_' or ch == '-') {
            upper = true;
            continue;
        }
        try out.append(gpa, if (upper) std.ascii.toUpper(ch) else ch);
        upper = false;
    }
    return out.toOwnedSlice(gpa);
}

/// Where a journey action's own `redirect_to` sent the browser, or `/`.
///
/// Contract 1 (self-freeing) as far as this function is concerned; the
/// allocation it keeps is handed to `acc`, which owns it.
fn journeyRedirect(
    ctx: *Ctx,
    acc: *BindingAcc,
    controller: []const u8,
) Allocator.Error![]const u8 {
    const d = ctx.in.discovery;
    const info = controllers.find(d.actions, controller, "create") orelse return "/";
    const url = try resolve.redirectUrl(ctx.gpa, d.routes, info.redirects) orelse return "/";
    return acc.keep(ctx.gpa, url);
}

/// The `island` answer on `RAILS_AUTH_JOURNEY`, resolved into everything the
/// two scaffolds need. `null` when there is no journey, no answer, a
/// `retain`/`blocked` answer, or an `island` with no artifact -- the last is
/// rejected by `decisions.parse` (assumption A4), and treating it as "no
/// journey" here rather than asserting keeps a hand-written `Parsed` from
/// emitting an island that names no collection.
///
/// Contract 2 (owned-result), inherited from `buildBindings`. All six fields,
/// because a label that covers five is a label a reader has to re-derive:
///
/// - `status_id` -- allocated here, handed straight to `BindingAcc` via `keep`.
/// - `signin_redirect`, `signup_redirect` -- allocated inside
///   `journeyRedirect` and `keep`-ed there.
/// - `finding_id` -- BORROWED, `ctx.journey_id`, which is a `Finding.id` out
///   of `Discovery.findings` and outlives every scaffold built from it.
/// - `collection` -- BORROWED, the decision's own `artifact`.
/// - `signin_url` -- BORROWED, a `Route.path` from the route table.
///
/// So `Bindings.deinit` is the release for the first three and nothing here
/// releases the other three. (`journeyRedirect` can also return the literal
/// `"/"`, which is static and belongs to nobody; `keep` never sees it.)
fn journeyScaffold(ctx: *Ctx, acc: *BindingAcc) Allocator.Error!?JourneyScaffold {
    const gpa = ctx.gpa;
    const jid = ctx.journey_id orelse return null;
    const dec = decisions.lookup(ctx.in.decisions, jid) orelse return null;
    if (!std.mem.eql(u8, dec.choice, "island")) return null;
    const collection = dec.artifact orelse return null;
    if (collection.len == 0) return null;

    var signin_url: ?[]const u8 = null;
    for (ctx.in.discovery.routes, 0..) |r, i| {
        // Out of range is NOT in the journey, which is how `journeyEndpoints`
        // and `buildBindings` both read `ctx.journey`. Spelled
        // `i < len and !flag` this arm said the opposite -- a route past the
        // end of the flag array would have been treated as a journey route --
        // and `Journey.route` is allocated to `routes.len`, so the two
        // readings only ever agree because the array is never short. A guard
        // that is correct by coincidence is one that stops being correct
        // quietly.
        if (i >= ctx.journey.len or !ctx.journey[i]) continue;
        if (!std.mem.eql(u8, r.verb, "GET")) continue;
        if (!std.mem.eql(u8, r.controller orelse "", "sessions")) continue;
        if (!std.mem.eql(u8, r.action orelse "", "new")) continue;
        // The smallest path, not the first in slice order: a route table's
        // order is the sidecar's, and this string reaches a committed file.
        if (signin_url) |u| {
            if (std.mem.order(u8, r.path, u) != .lt) continue;
        }
        signin_url = r.path;
    }

    return .{
        .finding_id = jid,
        .status_id = try acc.keep(gpa, try std.fmt.allocPrint(gpa, "{s}#AuthStatus", .{jid})),
        .collection = collection,
        .signin_redirect = try journeyRedirect(ctx, acc, "sessions"),
        .signup_redirect = try journeyRedirect(ctx, acc, "registrations"),
        .signin_url = signin_url,
    };
}

/// The three endpoints a bound journey puts on its own routes.
///
/// `sessions#create` and `sessions#destroy` name a `CollectionService` METHOD
/// rather than an operation id, because the document carries neither (see
/// `authBaseName`); the handoff says which client call is meant, which is the
/// only thing an operator can act on.
///
/// Contract 2 (owned-result), inherited from `buildBindings`: every path and
/// id it builds goes straight to `BindingAcc` through `keep`, and
/// `Bindings.deinit` is the release. `base` is scratch and is freed here.
fn journeyEndpoints(ctx: *Ctx, acc: *BindingAcc, j: JourneyScaffold) Allocator.Error!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;

    const base = try authBaseName(gpa, j.collection);
    defer gpa.free(base);
    const create_id = try acc.keep(gpa, try std.fmt.allocPrint(gpa, "create{s}", .{base}));
    const auth_path = try acc.keep(gpa, try std.fmt.allocPrint(
        gpa,
        "/api/collections/{s}/auth-with-password",
        .{j.collection},
    ));
    const logout_path = try acc.keep(gpa, try std.fmt.allocPrint(
        gpa,
        "/api/collections/{s}/auth-logout",
        .{j.collection},
    ));
    const records_path = try acc.keep(gpa, try std.fmt.allocPrint(
        gpa,
        "/api/collections/{s}/records",
        .{j.collection},
    ));

    for (d.routes, 0..) |r, i| {
        if (i >= ctx.journey.len or !ctx.journey[i]) continue;
        if (acc.endpoints[i] != null) continue;
        const controller = r.controller orelse continue;
        const action = r.action orelse continue;
        // Every one is a POST whatever verb Rails used: `DELETE /session` is
        // a Rails routing convention, and the ZigBase call behind it is
        // `POST …/auth-logout`.
        if (std.mem.eql(u8, controller, "sessions") and std.mem.eql(u8, action, "create")) {
            acc.endpoints[i] = .{ .operation_id = "authWithPassword", .verb = "POST", .path = auth_path };
        } else if (std.mem.eql(u8, controller, "sessions") and std.mem.eql(u8, action, "destroy")) {
            acc.endpoints[i] = .{ .operation_id = "logout", .verb = "POST", .path = logout_path };
        } else if (std.mem.eql(u8, controller, "registrations") and std.mem.eql(u8, action, "create")) {
            acc.endpoints[i] = .{ .operation_id = create_id, .verb = "POST", .path = records_path };
        }
    }
}

/// Every `form` in a journey view becomes the shared `AuthForm`.
///
/// Two guards decide what a journey form IS, and both are needed:
///
///  - reachability, walked here exactly as `convert.zig` inlines partials, so
///    a `shared/_login_form` a journey view renders is the journey's (ruling
///    S3-R3); and
///  - the ABSENCE of a finding at the node, which is `findings.derive`'s own
///    record that assumption A5 suppressed the form's `RAILS_BACKEND_ENDPOINT`
///    row. That is the authority on the question, so reading it back is what
///    keeps this walk and the derivation from disagreeing about the render
///    depth at which a partial stops being the journey's -- `findings.zig`
///    caps its own walk, and re-implementing that cap here would be a second
///    copy of a rule that has to hold exactly.
///
/// Contract 2 (owned-result), inherited from `buildBindings`: the props
/// literal it formats is handed to `BindingAcc` through `keep`, and
/// `Bindings.deinit` is the release. `seen` grows with BORROWED template paths
/// and is the caller's to `deinit`.
fn bindJourneyTemplate(
    ctx: *Ctx,
    acc: *BindingAcc,
    j: JourneyScaffold,
    controller: []const u8,
    view: []const u8,
    seen: *std.ArrayListUnmanaged([]const u8),
) Allocator.Error!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;
    if (contains(seen.items, view)) return;
    try seen.append(gpa, view);

    const tpl = findTemplate(d.fragments, view) orelse return;
    for (tpl.nodes) |n| {
        if (n.text != null) continue;
        if (n.kind == .render_partial or n.kind == .render_partial_locals) {
            const target = n.name orelse continue;
            const p = convert.partialPathIn(d.fragments, view, target) orelse continue;
            try bindJourneyTemplate(ctx, acc, j, controller, p, seen);
            continue;
        }
        if (n.kind != .form) continue;
        if (convert.findingIdFor(d.findings, view, n.line, n.col) != null) continue;

        // Sign-up when the form asks for the confirmation ZigBase's
        // `<Base>Create` schema requires, or when the view belongs to the
        // controller Rails reserves for it. Either alone is evidence; a
        // `registrations` form without the field is still a registration.
        const signup = std.mem.eql(u8, controller, "registrations") or
            formHasConfirmation(tpl.nodes, n);
        const mode = if (signup) "signup" else "signin";
        const props = try acc.keep(gpa, try std.fmt.allocPrint(
            gpa,
            "{{ .mode = \"{s}\" }}",
            .{mode},
        ));
        try acc.all.append(gpa, .{
            // The journey's own id: shared by both forms, which is why the
            // POSITION is the join key (see `convert.Binding.at`). Carried
            // anyway so `boundBy` can see that the journey answer produced
            // something -- and because `writeIslandFiles` skips on it, which
            // is what makes the two views' ONE `AuthForm` one write.
            .finding_id = j.finding_id,
            .kind = if (signup) .auth_signup else .auth_signin,
            .verb = "POST",
            .path = if (signup) "records" else "auth-with-password",
            .operation_id = if (signup) "create" else "authWithPassword",
            .collection = j.collection,
            .island = auth_form_island_path,
            .redirect_to = if (signup) j.signup_redirect else j.signin_redirect,
            .props = props,
            .at = .{ .path = view, .line = n.line, .col = n.col },
        });
    }
}

/// Whether the form opening at `nodes[…] == open` holds a
/// `password_confirmation` control, i.e. whether it registers rather than
/// signs in.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn formHasConfirmation(nodes: []const fragments.Node, open: fragments.Node) bool {
    var inside = false;
    var depth: usize = 0;
    for (nodes) |n| {
        if (n.text != null) continue;
        if (!inside) {
            if (n.line == open.line and n.col == open.col and n.kind == .form) inside = true;
            continue;
        }
        if (n.kind == .block_end) {
            if (depth == 0) return false;
            depth -= 1;
            continue;
        }
        if (convert.opensBlock(n)) depth += 1;
        if (n.kind != .form_field) continue;
        for (n.args) |a| {
            if (std.mem.eql(u8, a, "password_confirmation")) return true;
        }
    }
    return false;
}

/// The `current_user` region, wherever it is: a view, a partial, or -- the
/// commonest shape by far, and the presentation fixture's -- a partial the
/// LAYOUT renders. So this walks every template rather than the route views,
/// and joins on the finding id like any ordinary binding.
///
/// One binding PER answered region, each carrying that region's own id: that
/// id is what settles the region and what `convert.zig` joins the `<island>`
/// onto, so two answered regions are two references. They all name one FILE,
/// whose own identity is `JourneyScaffold.status_id` -- see `islandIdentity`.
///
/// Contract 2 (owned-result), inherited from `buildBindings`: it allocates
/// nothing of its own. Every string in the bindings it appends is borrowed --
/// the finding id from `Discovery.findings`, `collection` from the scaffold,
/// the rest static -- and the list itself is `Bindings.deinit`'s to release.
fn bindAuthStatus(
    ctx: *Ctx,
    acc: *BindingAcc,
    j: JourneyScaffold,
    origins: *std.ArrayListUnmanaged(StatusOrigin),
) Allocator.Error!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;
    for (d.fragments) |tpl| {
        // Per TEMPLATE: a pair is two halves of one control, and two halves in
        // two different files are not that. `template_start` is where THIS
        // template's origins begin, and the complement search below is a
        // linear scan of `origins.items[template_start..]` -- so a region can
        // only find its partner among regions of the same file, and an
        // earlier template's identically-branched region is out of reach by
        // construction rather than by a filter that could be forgotten.
        const template_start = origins.items.len;
        // Where each accepted region's block CLOSES, in node indices, so a
        // region written inside another one can be recognised. Only the ends
        // are needed: this walk visits nodes in order, so a region reached at
        // `ni` is inside an earlier region exactly when some recorded end is
        // still ahead of it.
        var open_ends: std.ArrayListUnmanaged(usize) = .empty;
        defer open_ends.deinit(gpa);
        for (tpl.nodes, 0..) |n, ni| {
            if (n.text != null or n.kind != .request_state) continue;
            if (!isAuthStatusName(n.name)) continue;
            const id = convert.findingIdFor(d.findings, tpl.path, n.line, n.col) orelse continue;
            const f = findingById(d.findings, id) orelse continue;
            if (!std.mem.eql(u8, f.code, findings.code_request_time_state)) continue;
            const dec = decisions.lookup(ctx.in.decisions, id) orelse continue;
            if (!std.mem.eql(u8, dec.choice, "island")) continue;
            if (boundBy(acc.all.items, id)) continue;

            // `AuthStatus` renders BOTH branches itself, so the two halves of
            // `<% if current_user %>…<% end %><% unless current_user %>…
            // <% end %>` are one control: mounting at each of them puts the
            // whole component on the page twice -- "Sign in" twice in one
            // `<nav>`, or the visitor's email and a Sign-out button twice.
            // The pair mounts once, at the FIRST half, and the second is
            // absorbed.
            //
            // Complementary means the same predicate branched the opposite
            // way, read off the region's own code. Two regions of the SAME
            // polarity are two controls (a nav greeting and a footer
            // call-to-action), and so are two different predicates: guessing
            // that `current_user` and `signed_in?` are complements would start
            // deleting controls that are not branches of each other. An
            // unrecognised code pairs with nothing at all -- two mounts render
            // a duplicate, a wrong pairing deletes something.
            var absorbed = false;
            if (regionBranch(n.code)) |b| {
                for (origins.items[template_start..]) |*o| {
                    if (o.absorbed) continue;
                    const other = regionBranch(o.code) orelse continue;
                    if (other.positive == b.positive) continue;
                    if (!std.mem.eql(u8, other.predicate, b.predicate)) continue;
                    absorbed = true;
                    break;
                }
            }

            // Nesting: `<%= current_user.email %>` inside `<% if signed_in? %>`
            // is two answered regions, and the inner one produces no markup of
            // its own -- `convert.zig` replaces the OUTER region wholesale and
            // resumes past its `block_end`, so it never reaches the inner one.
            // That is the right conversion (the island renders the address
            // itself), but until this flag existed the inner region was listed
            // in the header exactly like a region the island replaced on its
            // own account, and no route note said otherwise: an operator saw
            // two answers, one component, and no explanation for the
            // difference.
            var enclosed = false;
            for (open_ends.items) |end| {
                if (ni <= end) {
                    enclosed = true;
                    break;
                }
            }
            if (convert.matchingEnd(tpl.nodes, ni)) |end| try open_ends.append(gpa, end);

            try acc.all.append(gpa, .{
                .finding_id = f.id,
                .kind = .auth_logout,
                .verb = "POST",
                .path = "auth-logout",
                .operation_id = "logout",
                .collection = j.collection,
                .island = auth_status_island_path,
                .redirect_to = null,
                .absorbed = absorbed,
            });
            try origins.append(gpa, .{
                .path = tpl.path,
                .line = n.line,
                .col = n.col,
                .code = n.code,
                .finding_id = f.id,
                .absorbed = absorbed,
                .enclosed = enclosed,
            });
        }
    }
}

/// Source order for `Bindings.status_origins`: by path, then line, then
/// column. Deterministic and independent of the fragment stream's own order,
/// because these reach a committed file (`AuthStatus`'s header) and a route
/// note.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn statusOriginLessThan(_: void, a: StatusOrigin, b: StatusOrigin) bool {
    const by_path = std.mem.order(u8, a.path, b.path);
    if (by_path != .eq) return by_path == .lt;
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
}

/// The whole pre-pass. See `Bindings` for why it runs before the route walk.
///
/// Contract 2 (owned-result): the returned `Bindings` owns what its doc says
/// it owns; on any error nothing escapes.
fn buildBindings(ctx: *Ctx) Allocator.Error!Bindings {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;

    const endpoints = try gpa.alloc(?EndpointRef, d.routes.len);
    errdefer gpa.free(endpoints);
    @memset(endpoints, null);

    var acc: BindingAcc = .{ .endpoints = endpoints };
    errdefer acc.deinit(gpa);

    // Views in the route walk's own order, so which route a shared view's
    // redirect and pairing come from is decided the same way the walk decides
    // who owns the view (ruling S16's first-route-wins, restated).
    const order = try gpa.alloc(usize, d.routes.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, d.routes, routeLessThan);

    // Every TEMPLATE is bound at most once, not every view: a `_form`
    // partial two views render carries ONE finding, so binding it twice would
    // produce two islands for one answer and two names for one region.
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(gpa);

    // #167 Stage 3 Task 5, BEFORE the ordinary pass and with a `seen` set of
    // ITS OWN.
    //
    // Ruling S3-R3 -- a partial reached from a journey view AND an ordinary
    // one is the journey's -- is already settled upstream: `findings.derive`
    // suppresses that partial's form rows for EVERY view that renders it,
    // because `Journey.isJourneyView` is keyed on the template, not on the
    // route that reached it. So a shared set would add nothing to that rule,
    // and it takes something away: this walk follows `render` edges with no
    // depth cap while `findings.derive`'s stops at
    // `max_journey_render_depth`, so it reaches templates the journey does
    // NOT speak for. It declines to bind their forms (a finding is present,
    // which is the derivation's own record that A5 did not suppress them) --
    // but with one set it had already claimed the template, the ordinary pass
    // never walked it, and the operator's answer to that form produced
    // nothing: no island, no `lib/zb.ts`, and a route left open on a question
    // that had been answered. The two passes cannot collide, because this one
    // binds only nodes with NO finding at them and the other only nodes with
    // an answered one.
    var journey_seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer journey_seen.deinit(gpa);
    var origins: std.ArrayListUnmanaged(StatusOrigin) = .empty;
    errdefer origins.deinit(gpa);
    const journey = try journeyScaffold(ctx, &acc);
    if (journey) |j| {
        try journeyEndpoints(ctx, &acc, j);
        for (order) |i| {
            if (i >= ctx.journey.len or !ctx.journey[i]) continue;
            if (i >= d.route_templates.len) continue;
            const r = d.routes[i];
            const view = pickView(d.route_templates[i].templates, r) orelse continue;
            try bindJourneyTemplate(ctx, &acc, j, r.controller orelse "", view, &journey_seen);
        }
        try bindAuthStatus(ctx, &acc, j, &origins);
    }
    std.mem.sort(StatusOrigin, origins.items, {}, statusOriginLessThan);

    for (order) |i| {
        const r = d.routes[i];
        if (i >= d.route_templates.len) continue;
        const view = pickView(d.route_templates[i].templates, r) orelse continue;
        try bindTemplate(ctx, &acc, i, view, &seen);
    }

    // Ruling S22, narrowed by Task 3's fix rounds: a route-level
    // `RAILS_BACKEND_ENDPOINT` is keyed on `(line, verb, resource)`, not on
    // the line alone -- `resources :posts` puts three verbs on one line and
    // `resources :posts, :comments` puts two resources on one verb, and a
    // single ZigBase operation cannot answer for all of them. Every route
    // sharing that triple shares one answer, and gets the same endpoint.
    for (d.routes, 0..) |r, i| {
        if (acc.endpoints[i] != null) continue;
        const id = try backendRouteId(gpa, r);
        defer gpa.free(id);
        if (findingById(d.findings, id) == null) continue;
        const dec = decisions.lookup(ctx.in.decisions, id) orelse continue;
        const hit = resolveChoice(ctx.in.backend, dec.choice, r.verb) orelse continue;
        acc.endpoints[i] = .{ .operation_id = hit.operation_id, .verb = hit.verb, .path = hit.path };
    }

    // Taken FIRST, and this order is load-bearing: `acc.owned.toOwnedSlice`
    // empties `acc.owned`, so past that point the `errdefer acc.deinit(gpa)`
    // above no longer frees those strings -- only the local `owned` slice
    // does, and an `errdefer gpa.free(owned)` frees the slice while leaking
    // every string in it. Allocating `status_origins` while that window was
    // open leaked eight strings on one FailingAllocator index. Nothing between
    // the two `toOwnedSlice` calls on `acc` may fail, so nothing goes there.
    const identifier_slices = try acc.identifier_slices.toOwnedSlice(gpa);
    errdefer {
        for (identifier_slices) |slice| gpa.free(slice);
        gpa.free(identifier_slices);
    }
    const status_origins = try origins.toOwnedSlice(gpa);
    errdefer gpa.free(status_origins);
    const all = try acc.all.toOwnedSlice(gpa);
    errdefer gpa.free(all);
    const stimulus_paths = try acc.stimulus_paths.toOwnedSlice(gpa);
    errdefer gpa.free(stimulus_paths);
    const component_paths = try acc.component_paths.toOwnedSlice(gpa);
    errdefer gpa.free(component_paths);
    const alias_slices = try acc.alias_slices.toOwnedSlice(gpa);
    errdefer {
        for (alias_slices) |slice| gpa.free(slice);
        gpa.free(alias_slices);
    }
    const owned = try acc.owned.toOwnedSlice(gpa);
    return .{
        .all = all,
        .endpoints = endpoints,
        .owned = owned,
        .scaffold = journey,
        .status_origins = status_origins,
        .identifier_slices = identifier_slices,
        .stimulus_paths = stimulus_paths,
        .component_paths = component_paths,
        .alias_slices = alias_slices,
    };
}

/// One view's answered `RAILS_BACKEND_ENDPOINT` findings, in SOURCE order --
/// the node stream, not the finding list, because the finding list is sorted
/// by id and `L1C10` sorts before `L1C5`, which would number a second form on
/// one line before the first.
///
/// The partial graph is followed, exactly as `convert.zig` inlines it: the
/// commonest shape in Rails is a `new.html.erb` that renders a `_form`
/// partial, so a pre-pass that read only the main view would leave most real
/// forms unbindable.
///
/// Contract 2 (owned-result), inherited from `buildBindings`: every string it
/// allocates is handed straight to `BindingAcc` (through `keep`), and
/// `Bindings.deinit` is the release. `seen` grows with BORROWED template
/// paths and is the caller's to `deinit`.
fn attrEquals(attrs: []const fragments.Attr, key: []const u8, value: []const u8) bool {
    for (attrs) |attr| if (std.mem.eql(u8, attr.key, key) and std.mem.eql(u8, attr.value, value)) return true;
    return false;
}

fn flattenedInteractionPath(gpa: Allocator, prefix: []const u8, name: []const u8, ordinal: usize) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, prefix);
    var previous_separator = false;
    for (name) |ch| {
        const separator = ch == '-' or ch == '/' or ch == ':';
        if (separator) {
            if (!previous_separator) try out.append(gpa, '_');
        } else try out.append(gpa, ch);
        previous_separator = separator;
    }
    if (ordinal > 1) try out.print(gpa, "_{d}", .{ordinal});
    try out.appendSlice(gpa, ".island.tsx");
    return out.toOwnedSlice(gpa);
}

fn uniqueInteractionPath(gpa: Allocator, built: []const convert.Binding, prefix: []const u8, name: []const u8, reserved: []const []const u8) Allocator.Error![]u8 {
    var ordinal: usize = 1;
    while (true) : (ordinal += 1) {
        const candidate = try flattenedInteractionPath(gpa, prefix, name, ordinal);
        var taken = islandTaken(built, candidate);
        for (reserved) |path| {
            if (std.mem.eql(u8, path, candidate)) taken = true;
        }
        if (!taken) return candidate;
        gpa.free(candidate);
    }
}

fn componentProps(gpa: Allocator, attrs: []const fragments.Attr) Allocator.Error![]u8 {
    const sorted = try gpa.dupe(fragments.Attr, attrs);
    defer gpa.free(sorted);
    std.mem.sort(fragments.Attr, sorted, {}, struct {
        fn lessThan(_: void, a: fragments.Attr, b: fragments.Attr) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{");
    var count: usize = 0;
    for (sorted) |attr| {
        if (attr.kind == .null) continue;
        if (count == 0) try out.append(gpa, ' ') else try out.appendSlice(gpa, ", ");
        try out.print(gpa, ".{s} = ", .{attr.key});
        if (attr.kind == .string) {
            try out.append(gpa, '"');
            try appendJsEscaped(gpa, &out, attr.value);
            try out.append(gpa, '"');
        } else try out.appendSlice(gpa, attr.value);
        count += 1;
    }
    if (count > 0) try out.appendSlice(gpa, " }") else try out.append(gpa, '}');
    return out.toOwnedSlice(gpa);
}

fn frameProps(gpa: Allocator, route_list: []const route_mod.Route, node: fragments.Node) Allocator.Error![]u8 {
    var url: ?[]const u8 = null;
    defer if (url) |u| gpa.free(u);
    for (node.attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "src") and std.mem.startsWith(u8, attr.value, "/")) {
            url = try gpa.dupe(u8, attr.value);
            break;
        }
    }
    if (url == null) {
        const stem = node.value orelse "";
        url = try resolve.routeUrl(gpa, route_list, stem, node.args);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{ .id = \"");
    try appendJsEscaped(gpa, &out, node.name orelse "");
    try out.appendSlice(gpa, "\", .src = \"");
    try appendJsEscaped(gpa, &out, url orelse "");
    try out.appendSlice(gpa, "\" }");
    return out.toOwnedSlice(gpa);
}

fn dataIslandPath(gpa: Allocator, built: []const convert.Binding, view_path: []const u8) Allocator.Error![]u8 {
    var ordinal: usize = 1;
    while (true) : (ordinal += 1) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, "components/data/");
        for (resolve.viewStem(view_path)) |ch| try out.append(gpa, if (ch == '/') '_' else ch);
        if (ordinal > 1) try out.print(gpa, "_{d}", .{ordinal});
        try out.appendSlice(gpa, ".island.tsx");
        const candidate = try out.toOwnedSlice(gpa);
        if (!islandTaken(built, candidate)) return candidate;
        gpa.free(candidate);
    }
}

fn dataBlockParam(code: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, code, '|') orelse return null;
    const rest = code[first + 1 ..];
    const last = std.mem.indexOfScalar(u8, rest, '|') orelse return null;
    const value = std.mem.trim(u8, rest[0..last], " \t\r\n");
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, ',') != null) return null;
    return value;
}

/// Builds the Ziggy props carried by a portable Turbo Stream mount. Contract
/// 1 (self-freeing): scratch lives in `out`; the returned slice is the only
/// allocation and escapes to the caller.
fn realtimeProps(gpa: Allocator, stream: []const u8, action: []const u8, target: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{ .stream = \"");
    try appendZiggyEscaped(gpa, &out, stream);
    try out.appendSlice(gpa, "\", .action = \"");
    try appendZiggyEscaped(gpa, &out, action);
    try out.appendSlice(gpa, "\", .target = \"");
    try appendZiggyEscaped(gpa, &out, target);
    try out.appendSlice(gpa, "\" }");
    return out.toOwnedSlice(gpa);
}

fn collectionHasOperation(doc: backend_mod.Document, collection: []const u8, kind: backend_mod.Kind) bool {
    for (doc.operations) |operation| {
        if (operation.kind == kind and operation.collection != null and std.mem.eql(u8, operation.collection.?, collection)) return true;
    }
    return false;
}

fn bindTemplate(
    ctx: *Ctx,
    acc: *BindingAcc,
    route_index: usize,
    view: []const u8,
    seen: *std.ArrayListUnmanaged([]const u8),
) Allocator.Error!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;
    // Doubles as the cycle guard `convert.inlinePartial` takes, for the same
    // reason: Rails renders a self-referential partial until the request dies.
    if (contains(seen.items, view)) return;
    try seen.append(gpa, view);

    const tpl = findTemplate(d.fragments, view) orelse return;
    // Per TEMPLATE, so `_2` numbers a second form in the same file rather than
    // a first form in the next one. It is the STARTING ordinal only:
    // `uniqueIslandPath` advances it further when a template whose stem
    // flattens to the same name got there first.
    var ordinal: usize = 0;
    const r = d.routes[route_index];

    for (tpl.nodes) |n| {
        if (n.text != null) continue;
        switch (n.kind) {
            .render_partial, .render_partial_locals, .render_dynamic => {
                const target = n.name orelse continue;
                const p = convert.partialPathIn(d.fragments, view, target) orelse continue;
                try bindTemplate(ctx, acc, route_index, p, seen);
                continue;
            },
            .stimulus, .turbo_frame, .turbo_stream, .component_root => {
                const id = convert.findingIdFor(d.findings, view, n.line, n.col) orelse continue;
                const dec = decisions.lookup(ctx.in.decisions, id) orelse continue;
                if (n.kind == .stimulus and (std.mem.eql(u8, dec.choice, "island") or std.mem.eql(u8, dec.choice, "drop"))) {
                    var names: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer names.deinit(gpa);
                    var it = std.mem.tokenizeAny(u8, n.name orelse "", " \t\r\n");
                    while (it.next()) |name| try names.append(gpa, name);
                    const identifiers = try acc.keepIdentifiers(gpa, names.items);
                    var island: []const u8 = "";
                    if (std.mem.eql(u8, dec.choice, "island")) for (identifiers, 0..) |identifier, index| {
                        const path = try acc.stimulusPath(gpa, identifier);
                        if (index == 0) island = path;
                    };
                    try acc.all.append(gpa, .{
                        .finding_id = id,
                        .kind = if (std.mem.eql(u8, dec.choice, "drop")) .drop else .stimulus,
                        .verb = "",
                        .path = "",
                        .operation_id = "",
                        .collection = null,
                        .island = island,
                        .redirect_to = null,
                        .wrap = std.mem.eql(u8, dec.choice, "island"),
                        .identifiers = identifiers,
                    });
                    continue;
                }
                if (n.kind == .turbo_frame and (std.mem.eql(u8, dec.choice, "island") or std.mem.eql(u8, dec.choice, "inline"))) {
                    const props = if (std.mem.eql(u8, dec.choice, "island"))
                        try acc.keep(gpa, try frameProps(gpa, d.routes, n))
                    else
                        null;
                    try acc.all.append(gpa, .{
                        .finding_id = id,
                        .kind = if (std.mem.eql(u8, dec.choice, "inline")) .@"inline" else .turbo_frame,
                        .verb = "",
                        .path = "",
                        .operation_id = "",
                        .collection = null,
                        .island = if (std.mem.eql(u8, dec.choice, "island")) turbo_frame_island_path else "",
                        .redirect_to = null,
                        .props = props,
                        .wrap = std.mem.eql(u8, dec.choice, "island"),
                        .directive = if (attrEquals(n.attrs, "loading", "lazy")) "client:visible" else "client:load",
                    });
                    continue;
                }
                if (n.kind == .turbo_stream and std.mem.eql(u8, dec.choice, "island-realtime") and n.name != null and n.value != null and !n.dynamic) {
                    const topic = findings.turboStreamTopic(tpl.nodes, n) orelse continue;
                    const props = try acc.keep(gpa, try realtimeProps(gpa, topic, n.value.?, n.name.?));
                    try acc.all.append(gpa, .{
                        .finding_id = id,
                        .kind = .turbo_stream,
                        .verb = "",
                        .path = "",
                        .operation_id = n.value.?,
                        .collection = topic,
                        .island = turbo_stream_island_path,
                        .redirect_to = null,
                        .props = props,
                    });
                    continue;
                }
                if (n.kind == .component_root and std.mem.eql(u8, dec.choice, "island")) {
                    const name = n.name orelse continue;
                    const island = try acc.componentPath(gpa, name);
                    const props = try acc.keep(gpa, try componentProps(gpa, n.attrs));
                    try acc.all.append(gpa, .{
                        .finding_id = id,
                        .kind = .component,
                        .verb = "",
                        .path = "",
                        .operation_id = "",
                        .collection = null,
                        .island = island,
                        .redirect_to = null,
                        .props = props,
                    });
                    continue;
                }
                continue;
            },
            .ivar => {
                const id = convert.findingIdFor(d.findings, view, n.line, n.col) orelse continue;
                const dec = decisions.lookup(ctx.in.decisions, id) orelse continue;
                if (!std.mem.eql(u8, dec.choice, "island") and !std.mem.eql(u8, dec.choice, "backend")) continue;
                const doc = ctx.in.backend orelse continue;
                const ivar = n.name orelse continue;
                const stem = std.mem.trim(u8, ivar, "@");
                const collection = dec.artifact orelse resolve.collectionFor(doc, stem) orelse continue;
                if (!collectionHasOperation(doc, collection, .list)) continue;
                var aliases_buf: [2]port.Alias = undefined;
                var aliases_len: usize = 0;
                if (dataBlockParam(n.code)) |param| {
                    aliases_buf[aliases_len] = .{ .ruby = param, .js = "rec" };
                    aliases_len += 1;
                }
                aliases_buf[aliases_len] = .{ .ruby = ivar, .js = "rec" };
                aliases_len += 1;
                const aliases = try acc.keepAliases(gpa, aliases_buf[0..aliases_len]);
                const island = try acc.keep(gpa, try dataIslandPath(gpa, acc.all.items, view));
                try acc.all.append(gpa, .{
                    .finding_id = id,
                    .kind = .data_list,
                    .verb = "GET",
                    .path = "",
                    .operation_id = "list",
                    .collection = collection,
                    .island = island,
                    .redirect_to = null,
                    .aliases = aliases,
                });
                continue;
            },
            .form, .form_field, .link_to => {},
            else => continue,
        }
        const id = convert.findingIdFor(d.findings, view, n.line, n.col) orelse continue;
        const f = findingById(d.findings, id) orelse continue;
        if (!std.mem.eql(u8, f.code, findings.code_backend_endpoint)) continue;
        const dec = decisions.lookup(ctx.in.decisions, id) orelse continue;

        // The verb the Rails control submits with, for a `custom:` answer
        // (which carries none) and for nothing else.
        const node_verb = try findings.nodeVerb(gpa, n);
        defer if (node_verb) |v| gpa.free(v);
        const hit = resolveChoice(ctx.in.backend, dec.choice, node_verb orelse "POST") orelse continue;

        ordinal += 1;
        const island = try acc.keep(gpa, try uniqueIslandPath(gpa, acc.all.items, view, ordinal));
        const verb = try acc.keep(gpa, try gpa.dupe(u8, hit.verb));

        // A form on `C#new`/`C#edit` answers for `C#create`/`C#update`; a
        // bound LINK answers for the route it submits to. Both are the same
        // rule -- the answer settles the MUTATION the control performs, not
        // the page the control sits on -- and they differ only in how that
        // route is found: Rails' new/create convention for a form,
        // `link_to`'s own target for a link, which names the route outright
        // and needs no convention at all. An earlier round left the link
        // unpaired on the grounds that the endpoint would be a guess; it is
        // not, and leaving it unpaired made the operator answer the same
        // mutation twice, once on the control and once on its route.
        const paired = if (n.kind == .link_to) linkRoute(d, n, node_verb) else pairedRoute(d, r);

        // The redirect is the MUTATING action's, never this page's: a `new`
        // page does not redirect, its `create` does; a page carrying a
        // `button_to "Sign out"` does not redirect, `sessions#destroy` does.
        const raw_redirect: ?[]const u8 = if (n.kind == .link_to) blk: {
            const pi = paired orelse break :blk null;
            const target = d.routes[pi];
            const a = target.action orelse break :blk null;
            break :blk try actionRedirect(ctx, target.controller, a);
        } else try pairedRedirect(ctx, r);
        const redirect: ?[]const u8 = if (raw_redirect) |u|
            try acc.keep(gpa, u)
        else
            null;

        try acc.all.append(gpa, .{
            .finding_id = f.id,
            .kind = hit.kind,
            .verb = verb,
            .path = hit.path,
            .operation_id = hit.operation_id,
            .collection = hit.collection,
            .island = island,
            .redirect_to = redirect,
        });

        if (paired) |pi| {
            if (acc.endpoints[pi] == null) acc.endpoints[pi] = .{
                .operation_id = hit.operation_id,
                .verb = verb,
                .path = hit.path,
            };
        }
    }
}

/// A borrowed `EndpointRef` (pointing into the `--backend` document, the
/// decisions file, or `Bindings.owned`) becomes the owned `Endpoint` a
/// `RouteOutcome` carries past the end of `write`.
///
/// Contract 2 (owned-result): all three strings are fresh allocations,
/// released by `freeEndpoint`. On a partial failure the `errdefer`s release
/// what was built and nothing escapes.
fn dupeEndpoint(gpa: Allocator, ref: EndpointRef) Allocator.Error!Endpoint {
    const operation_id = try gpa.dupe(u8, ref.operation_id);
    errdefer gpa.free(operation_id);
    const verb = try gpa.dupe(u8, ref.verb);
    errdefer gpa.free(verb);
    const path = try gpa.dupe(u8, ref.path);
    return .{ .operation_id = operation_id, .verb = verb, .path = path };
}

fn writeRoutes(
    ctx: *Ctx,
    acc: *Acc,
    layouts: *LayoutCache,
    views: *ViewCache,
    spa_routes: *std.ArrayListUnmanaged(SpaRoute),
) WriteError!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;

    const order = try gpa.alloc(usize, d.routes.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, d.routes, routeLessThan);

    var claims: std.ArrayListUnmanaged(ContentClaim) = .empty;
    defer {
        for (claims.items) |c| {
            gpa.free(c.path);
            gpa.free(c.route_id);
        }
        claims.deinit(gpa);
    }

    for (order) |i| {
        var out: Outcome = .{};
        errdefer out.deinit(gpa);

        try routeOutcome(ctx, acc, layouts, views, spa_routes, i, &out, acc.routes.items.len, &claims);

        // Sorted so the artifact list is a set, not a history of the order
        // this function happened to append in.
        std.mem.sort([]const u8, out.artifacts.items, {}, lessThanStr);
        std.mem.sort([]const u8, out.open_ids.items, {}, lessThanStr);

        const artifacts = try out.artifacts.toOwnedSlice(gpa);
        errdefer freeStrings(gpa, artifacts);
        const open_ids = try out.open_ids.toOwnedSlice(gpa);
        errdefer freeStrings(gpa, open_ids);
        try acc.routes.append(gpa, .{
            .route_index = i,
            .status = out.status,
            .artifacts = artifacts,
            .open_finding_ids = open_ids,
            .decision_id = out.decision_id,
            .note = out.note,
            .endpoint = out.endpoint,
        });
    }
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The per-route decision tree, in the order the cases exclude each other.
fn routeOutcome(
    ctx: *Ctx,
    acc: *Acc,
    layouts: *LayoutCache,
    views: *ViewCache,
    spa_routes: *std.ArrayListUnmanaged(SpaRoute),
    route_index: usize,
    out: *Outcome,
    outcome_index: usize,
    claims: *std.ArrayListUnmanaged(ContentClaim),
) WriteError!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;
    const r = d.routes[route_index];
    const class: ?classify.Class = if (route_index < d.classifications.len)
        d.classifications[route_index].class
    else
        null;

    // #167 Stage 3, ruling S21's mechanism: `RAILS_AUTH_JOURNEY` is ONE
    // finding for a flow that spans four or five routes, keyed on the
    // smallest `config/routes.rb` line it occupies. Every journey route
    // therefore carries the id -- exactly as a layout's finding rides on
    // every route under it -- because otherwise a `retain` on the journey
    // settles the one route whose own line happens to be that key and leaves
    // the rest permanently open. This is attached before any arm below so it
    // reaches the `backend` half of the journey (`POST /session`) as well as
    // the page half.
    if (route_index < ctx.journey.len and ctx.journey[route_index]) {
        if (ctx.journey_id) |jid| try appendOwned(gpa, &out.open_ids, jid);
    }

    // A redirect is answered by the host config, not by a page, whatever its
    // verb or path shape. Its finding exists so the operator can acknowledge
    // that; the status stays `redirect` either way, because `redirect` is
    // already a complete answer (spec: `complete` accepts it).
    if (class == classify.Class.redirect) {
        out.status = .redirect;
        try attachRouteFinding(ctx, out, findings.code_redirect_host_config, r.source.line);
        // The status stays `redirect` whatever the operator answered -- a
        // redirect IS a complete answer -- but the decision is recorded so
        // the handoff can show it was acknowledged rather than ignored.
        if (pickDecision(ctx.in.decisions, out.open_ids.items)) |dec| {
            out.decision_id = try gpa.dupe(u8, dec.id);
        }
        const from = try gpa.dupe(u8, r.path);
        errdefer gpa.free(from);
        // #167 Stage 3: where the redirect GOES, recovered from the action's
        // own `redirect_to` (`pages#old` -> `/about`). Stage 2 could only say
        // THAT it redirected, so the host-config stanza an operator had to
        // write from this row named a source and no destination.
        const to: ?[]const u8 = blk: {
            const controller = r.controller orelse break :blk null;
            const action = r.action orelse break :blk null;
            const info = controllers.find(d.actions, controller, action) orelse break :blk null;
            break :blk try resolve.redirectUrl(gpa, d.routes, info.redirects);
        };
        errdefer if (to) |t| gpa.free(t);
        if (to == null) try out.addNote(gpa, "redirect target is request-time state; set it by hand", .{});
        try acc.redirects.append(gpa, .{ .from = from, .to = to });
        return;
    }

    // `backend` by classification, or by verb: a POST/PATCH/DELETE route has
    // no page to migrate at all, and calling it anything else would put a
    // route in the handoff that `complete` then has to special-case.
    const is_get = std.mem.eql(u8, r.verb, "GET") or std.mem.eql(u8, r.verb, "HEAD");
    if (class == classify.Class.backend or !is_get) {
        out.status = .backend;
        // #167 Stage 3. The endpoint comes either from the form whose page
        // route pairs with this one, or from this route's OWN route-level
        // `RAILS_BACKEND_ENDPOINT` answer; `buildBindings` resolved both into
        // one slot before the walk started (see `Bindings`).
        if (route_index < ctx.bindings.endpoints.len) {
            if (ctx.bindings.endpoints[route_index]) |ref| out.endpoint = try dupeEndpoint(gpa, ref);
        }
        try attachBackendEndpointIfDerived(ctx, out, r);
        // Recorded, not applied: the status stays `backend` -- an endpoint is
        // not a page and `retain`/`blocked` on it would claim a page decision
        // that was never made -- but the handoff has to show the row was
        // answered, which is what assumption A2 reads.
        if (pickDecision(ctx.in.decisions, out.open_ids.items)) |dec| {
            out.decision_id = try gpa.dupe(u8, dec.id);
            if (out.endpoint != null) out.settle(gpa, dec.id);
        }
        return;
    }

    if (findings.isDynamicRoutePath(r.path)) {
        try dynamicRoute(ctx, out, spa_routes, route_index, outcome_index, r);
        return;
    }

    const content_path = try resolve.contentPath(gpa, r.path);
    defer if (content_path) |c| gpa.free(c);
    if (content_path == null) {
        // Not dynamic and still no content path: `resolve.contentPath` also
        // refuses route syntax this stage does not interpret (`(.:format)`).
        //
        // #182, Stage 3 half: the note used to be the whole report and it
        // carries no id, so no line in the decisions file could name the
        // route and `complete` was unreachable for it by any answer at all.
        // `findings.derive` now raises `RAILS_ROUTE_PATH_UNSUPPORTED` for
        // exactly the routes that reach here (its input is
        // `resolve.contentClaims`, the same walk this arm is a copy of), and
        // the id is looked up rather than assumed so the two mirrors cannot
        // disagree about which routes they cover.
        try attachRouteFindingIfDerived(ctx, out, findings.code_route_path_unsupported, r.source.line);
        try out.addOpenNote(gpa, "route path contains syntax this stage does not interpret", .{});
        try applyAcknowledgements(ctx, out, r, out.open_ids.items, &.{}, &.{});
        return;
    }

    // Ruling S14: a content path is claimed by exactly one route. Checked
    // BEFORE any conversion so the loser costs nothing and, more importantly,
    // so the exclusive-create guard never sees the collision -- that guard's
    // job is to protect a target the operator did not wipe, and letting a
    // duplicate route declaration trip it would abort the whole migration
    // with a filesystem error instead of naming the two routes involved.
    for (claims.items) |c| {
        if (!std.mem.eql(u8, c.path, content_path.?)) continue;
        // #182, same reasoning as the arm above: `RAILS_CONTENT_PATH_COLLISION`
        // is the id that makes this answerable.
        try attachRouteFindingIfDerived(ctx, out, findings.code_content_path_collision, r.source.line);
        try out.addOpenNote(gpa, "content path collision with {s}", .{c.route_id});
        try applyAcknowledgements(ctx, out, r, out.open_ids.items, &.{}, &.{});
        return;
    }

    // Assumption A7: a page whose controller runs an auth `before_action`
    // cannot enforce it once it is a static file. The finding is the
    // question; `public` is the answer that ships it anyway.
    try attachRouteFindingIfDerived(ctx, out, findings.code_route_auth_guard, r.source.line);

    try contentRoute(ctx, acc, layouts, views, route_index, out, content_path.?);

    // Claimed only once the page is actually on disk: a route that returned
    // early (no view, an unconvertible template) wrote nothing, so the next
    // route mapping here should get a real attempt rather than inherit a
    // collision with a page that does not exist.
    if (out.artifacts.items.len > 0) {
        const path_copy = try gpa.dupe(u8, content_path.?);
        errdefer gpa.free(path_copy);
        const id_copy = try std.fmt.allocPrint(gpa, "{s} {s}", .{ r.verb, r.path });
        errdefer gpa.free(id_copy);
        try claims.append(gpa, .{ .path = path_copy, .route_id = id_copy });
    }
}

/// Records the ROUTE-scoped finding for `code` on `out`. The id is
/// recomputed with
/// `findings.routeFindingId` rather than searched for by `route_id`: one
/// `routes.rb` declaration can produce several routes, so `route_id` names
/// only one of them (see `findings.deriveRouteFindings`).
fn attachRouteFinding(ctx: *Ctx, out: *Outcome, code: []const u8, line: u64) WriteError!void {
    const gpa = ctx.gpa;
    const id = try findings.routeFindingId(gpa, code, line);
    errdefer gpa.free(id);
    try out.open_ids.append(gpa, id);
}

/// `attachRouteFinding`, but only when `findings.derive` actually raised the
/// row.
///
/// Every Stage 3 route-level code is CONDITIONAL on something this file does
/// not re-evaluate -- a `--backend` document, an auth `before_action`, the
/// `resolve.contentClaims` walk -- so computing the id unconditionally would
/// put a join key in `open_finding_ids` that matches no finding in the
/// manifest, and an operator answering it would get `RAILS_DECISION_STALE`.
/// The two Stage 2 codes keep the unconditional form: their arms mirror
/// `findings.zig`'s own dispatch exactly (see `attachRouteFinding`'s callers).
///
/// Contract 2 (owned-result), inherited from `write`: the id it appends is
/// owned by `out.open_ids`. When no finding carries that id the allocation is
/// freed here rather than kept -- which is the whole point of this variant.
fn attachRouteFindingIfDerived(ctx: *Ctx, out: *Outcome, code: []const u8, line: u64) WriteError!void {
    const gpa = ctx.gpa;
    const id = try findings.routeFindingId(gpa, code, line);
    errdefer gpa.free(id);
    if (findingById(ctx.in.discovery.findings, id) == null) {
        gpa.free(id);
        return;
    }
    try out.open_ids.append(gpa, id);
}

/// The `RAILS_BACKEND_ENDPOINT` id for one route.
///
/// That row -- and ONLY that row -- is keyed on `(line, verb, resource)`
/// rather than on the line (Task 3's fix rounds I-3 and NEW-2), because one
/// `resources :posts, :comments` declaration is several routes that need
/// several different ZigBase operations. `findings.routeVerbFindingId` is the
/// builder; the resource is the route's own controller, which is what
/// `deriveRouteFindings` groups on.
///
/// Contract 1 (self-freeing): the returned id is the only allocation.
fn backendRouteId(gpa: Allocator, r: route_mod.Route) Allocator.Error![]u8 {
    return findings.routeVerbFindingId(
        gpa,
        findings.code_backend_endpoint,
        r.source.line,
        r.verb,
        r.controller,
    );
}

/// `attachRouteFindingIfDerived` for the one row whose id is not built from
/// the line alone. Kept separate rather than widening that function, so a
/// caller cannot pass a verb to a row that does not key on one.
///
/// Contract 2 (owned-result), inherited from `write`: same ownership as
/// `attachRouteFindingIfDerived`.
fn attachBackendEndpointIfDerived(ctx: *Ctx, out: *Outcome, r: route_mod.Route) WriteError!void {
    const gpa = ctx.gpa;
    const id = try backendRouteId(gpa, r);
    errdefer gpa.free(id);
    if (findingById(ctx.in.discovery.findings, id) == null) {
        gpa.free(id);
        return;
    }
    try out.open_ids.append(gpa, id);
}

fn dynamicRoute(
    ctx: *Ctx,
    out: *Outcome,
    spa_routes: *std.ArrayListUnmanaged(SpaRoute),
    route_index: usize,
    outcome_index: usize,
    r: route_mod.Route,
) WriteError!void {
    const gpa = ctx.gpa;
    try attachRouteFinding(ctx, out, findings.code_route_dynamic_segment, r.source.line);
    const id = out.open_ids.items[out.open_ids.items.len - 1];

    const decision = decisions.lookup(ctx.in.decisions, id) orelse {
        try out.addOpenNote(gpa, "dynamic route segment: undecided", .{});
        return;
    };
    out.decision_id = try gpa.dupe(u8, decision.id);

    if (std.mem.eql(u8, decision.choice, "spa")) {
        const seg = resolve.spaSegment(r.path);
        // Ruling S13: `spa` is only APPLIED when the first segment is static.
        // A top-level dynamic route (`get "/:slug"`) has `:slug` as its first
        // segment, and honouring the decision would scaffold
        // `spa/:slug.spa.tsx` with `export const spa = { base: "/:slug" }` --
        // a filename with a colon in it, and a mount base that is a pattern
        // rather than a path. Nothing downstream can build that. There is no
        // segment to mount a SPA at, so the decision cannot be carried out
        // and the route stays open saying exactly that, rather than
        // producing an artifact that fails at build time.
        if (seg.len == 0 or seg[0] == ':' or seg[0] == '*') {
            try out.addOpenNote(gpa, "spa needs a static first segment", .{});
            return;
        }
        const segment = try gpa.dupe(u8, seg);
        errdefer gpa.free(segment);
        out.status = .migrated;
        out.settle(gpa, id);
        const spa_port = try spaViewPort(ctx, out, route_index);
        errdefer if (spa_port) |p| gpa.free(p.js);
        if (out.status == .retained or out.status == .blocked) {
            if (spa_port) |p| gpa.free(p.js);
            gpa.free(segment);
            return;
        }
        try spa_routes.append(gpa, .{
            .segment = segment,
            .outcome_index = outcome_index,
            .route_index = route_index,
            .port_js = if (spa_port) |p| p.js else null,
            .collection = if (spa_port) |p| p.collection else null,
            .param = if (spa_port) |p| p.param else null,
        });
        // Minor C: with no `--runtime-path`, the generated `package.json`
        // carries a placeholder `file:` dependency that `bun install` cannot
        // resolve. The route is still `migrated` -- the conversion IS done --
        // but the operator has one edit left, and nothing else would say so.
        if (ctx.in.runtime_path == null) {
            try out.addNote(gpa, "set dependencies.@z/runtime in package.json", .{});
        }
        // `migrated` here and not after pass 3: the `.spa.tsx` is written
        // unconditionally for every collected route, so the only way this is
        // wrong is a write failure, which aborts the whole run.
        return;
    }
    try applyAcknowledgement(ctx, out, r, decision, &.{}, &.{});
}

const SpaViewPort = struct {
    js: []u8,
    collection: []const u8,
    param: []const u8,
};

fn soleRouteParam(path: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len < 2 or segment[0] != ':') continue;
        if (found != null) return null;
        found = segment[1..];
    }
    return found;
}

fn spaViewPort(ctx: *Ctx, out: *Outcome, route_index: usize) WriteError!?SpaViewPort {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;
    if (route_index >= d.route_templates.len) return null;
    const route = d.routes[route_index];
    const view = pickView(d.route_templates[route_index].templates, route) orelse return null;
    const tpl = findTemplate(d.fragments, view) orelse return null;
    const param = soleRouteParam(route.path) orelse return null;
    for (tpl.nodes) |node| {
        if (node.text != null or node.kind != .ivar) continue;
        const id = convert.findingIdFor(d.findings, view, node.line, node.col) orelse continue;
        try appendOwnedUnique(gpa, &out.open_ids, id);
        const dec = decisions.lookup(ctx.in.decisions, id) orelse {
            try out.addOpenNote(gpa, "request-time state on SPA route: undecided", .{});
            return null;
        };
        if (!std.mem.eql(u8, dec.choice, "island") and !std.mem.eql(u8, dec.choice, "backend")) {
            if (std.mem.eql(u8, dec.choice, "retain") or std.mem.eql(u8, dec.choice, "blocked")) {
                if (out.decision_id) |old| gpa.free(old);
                out.decision_id = try gpa.dupe(u8, dec.id);
            }
            try applyAcknowledgement(ctx, out, route, dec, &.{}, &.{});
            return null;
        }
        const doc = ctx.in.backend orelse {
            try out.addOpenNote(gpa, "choice {s} on RAILS_REQUEST_TIME_STATE needs a --backend document with a view operation for collection `{s}`", .{ dec.choice, dataCollectionForDecision(ctx, dec) });
            return null;
        };
        const ivar = node.name orelse continue;
        const collection = dec.artifact orelse resolve.collectionFor(doc, std.mem.trim(u8, ivar, "@")) orelse {
            try out.addOpenNote(gpa, "choice {s} on RAILS_REQUEST_TIME_STATE needs a --backend document with a view operation for collection `{s}`", .{ dec.choice, dataCollectionForDecision(ctx, dec) });
            return null;
        };
        if (!collectionHasOperation(doc, collection, .view)) {
            try out.addOpenNote(gpa, "choice {s} on RAILS_REQUEST_TIME_STATE needs a --backend document with a view operation for collection `{s}`", .{ dec.choice, collection });
            return null;
        }
        const aliases = [_]port.Alias{.{ .ruby = ivar, .js = "rec" }};
        const body = try port.recordBody(gpa, .{
            .routes = d.routes,
            .assets = d.assets,
            .fragments = d.fragments,
            .findings = &.{},
            .layout_stem = null,
        }, view, tpl.nodes, &aliases);
        if (body.unportable) |bad| {
            defer port.freeBody(gpa, body);
            try out.addOpenNote(gpa, "choice {s} on RAILS_REQUEST_TIME_STATE: the view is not portable ({s} at L{d}C{d})", .{ dec.choice, bad.why, bad.line, bad.col });
            return null;
        }
        out.settle(gpa, id);
        return .{ .js = body.js, .collection = collection, .param = param };
    }
    return null;
}

/// The issue tracking assumption A6: `backend` is a choice `RAILS_
/// REQUEST_TIME_STATE` still offers and that no stage has a converter for --
/// a data-fetching island for `@posts` is neither in Stage 3's backend
/// boundary nor in Stage 4's component port. Named here rather than inlined
/// so the one place that has to be updated when the issue is filed is
/// greppable.
const a6_issue = 184;

/// Ruling S3-R7: applies EVERY answer the operator gave on this route, not
/// just the one that decides its status.
///
/// `pickDecision` answers "which answer decides the route", and for a long
/// time that was also the only answer that RAN. Those are two different
/// questions, and conflating them dropped answers on the floor: a page can
/// carry several answered findings that are not alternatives at all -- a form
/// bound to a backend operation AND a `RAILS_ROUTE_AUTH_GUARD` shipped
/// `public` is the ordinary shape of a guarded Rails page with a form on it.
/// Both are rank 2, so which one was carried out came down to the tie-break
/// on the finding id, and `RAILS_BACKEND_ENDPOINT...` sorts before
/// `RAILS_ROUTE_AUTH_GUARD...`. The guard's answer was parsed, validated
/// against the finding's choice list, and then silently ignored: its id
/// stayed open, the route came back `open`, and the note said nothing. The
/// operator's only recourse was to answer a finding that was already answered
/// -- which is what made Task 7's Deviation D need five answers to say what
/// two describe.
///
/// So every answered finding settles by its own choice, and the route's
/// status is the strongest outcome by `rank` -- unchanged, which is what
/// keeps rulings S19 and S20 intact: a `retain` anywhere in the set still
/// retains the route and still writes no page, however many bindings the
/// same page carries.
///
/// The answers run in `rank` order, strongest first, ties by the smallest id
/// -- the same total order `pickDecision` maximises. That ordering does three
/// jobs at once: the answer that used to be the only one applied still runs
/// first and its note still leads; the status is the strongest outcome
/// without anything ever comparing two statuses; and an acknowledgement, if
/// there is one, is necessarily the first answer, which is what makes the
/// stop below a stop rather than a rollback.
///
/// `out.decision_id` stays the STRONGEST answer, i.e. exactly what
/// `pickDecision` returned. The handoff has one slot, and the answer that
/// decided the row is the one worth naming in it.
///
/// Not every arm of the walk routes through here. `dynamicRoute` looks its
/// answer up by the one id it just attached rather than picking among the
/// route's, and the `redirect` and `backend` arms record the answer and
/// settle it -- the backend arm calls `out.settle` as soon as the route has
/// an endpoint -- but never let it change the route's status (a redirect and
/// an endpoint are already complete answers; see their comments). Those are
/// unchanged.
///
/// Contract 2 (owned-result), inherited from `write` like every other arm of
/// it: what escapes is growth of `out`, which the `Result` owns. The answer
/// list is scratch and is freed here, and the strings it holds borrow
/// `ctx.in.decisions`.
fn applyAcknowledgements(
    ctx: *Ctx,
    out: *Outcome,
    r: route_mod.Route,
    ids: []const []const u8,
    bound_ids: []const []const u8,
    enclosed: []const convert.Enclosure,
) WriteError!void {
    const gpa = ctx.gpa;
    var answers: std.ArrayListUnmanaged(decisions.Decision) = .empty;
    defer answers.deinit(gpa);
    // Collected in full BEFORE the first one is applied, because callers pass
    // `out.open_ids.items` as `ids` and `Outcome.settle` frees the entries it
    // removes: reading the list while settling it would walk freed strings.
    // The answers themselves borrow `ctx.in.decisions`, which outlives this.
    //
    // Deduplicated here rather than trusted: `out.open_ids` is grown with
    // `appendOwned` at three sites (the journey id, `attachRouteFinding`,
    // `collectTemplateFindings`), so uniqueness is a property of today's call
    // graph and not of the list. `pickDecision` was immune by construction --
    // it returned one answer whatever the list held -- and applying a
    // duplicate would now file its note and its settlement twice.
    for (ids) |id| {
        const dec = decisions.lookup(ctx.in.decisions, id) orelse continue;
        for (answers.items) |seen| {
            if (std.mem.eql(u8, seen.id, dec.id)) break;
        } else try answers.append(gpa, dec);
    }
    if (answers.items.len == 0) return;
    std.mem.sort(decisions.Decision, answers.items, ctx, strongerAnswer);

    out.decision_id = try gpa.dupe(u8, answers.items[0].id);
    const entry_status = out.status;
    for (answers.items) |dec| {
        try applyAcknowledgement(ctx, out, r, dec, bound_ids, enclosed);
        // Rulings S19/S20, unchanged. `retain` and `blocked` acknowledge the
        // ROUTE -- the page stays on Rails, or does not ship at all -- which
        // moots every answer about what is on that page, and they are the two
        // top tiers of `rank`, so one can only appear as the FIRST answer
        // here. Carrying on past it would not change the status (that is what
        // makes it the strongest outcome) but it would file notes about work
        // that is not happening: `public`'s note says a guarded page is
        // shipping, and on a retained route no page ships.
        if (out.status != entry_status) return;
    }
}

/// `pickDecision`'s comparison as an ordering rather than a maximum, so
/// `applyAcknowledgements` runs the same answer first that `pickDecision`
/// would have returned. `std.mem.sort` is stable, but the id tie-break is a
/// total order over ids that are unique within one route, so the result does
/// not depend on that.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn strongerAnswer(ctx: *Ctx, a: decisions.Decision, b: decisions.Decision) bool {
    const ra = rank(a.choice, backendProducesDataIsland(ctx, a));
    const rb = rank(b.choice, backendProducesDataIsland(ctx, b));
    if (ra != rb) return ra > rb;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// Turns one answered decision into a status, a settlement, or a note.
///
/// Precedence, which `applyAcknowledgements` establishes before this is ever
/// called (and `pickDecision` before it, for the two arms that record an
/// answer without applying it):
/// `blocked` > `retain` > an operation/`public`/`island` that produces
/// something > a deferral. `blocked` and `retain` are ACKNOWLEDGEMENTS -- the
/// route does not ship, or stays on Rails -- and everything below them is a
/// claim that the converter did the work, so it must only be made when the
/// work is actually in the target tree.
///
/// Takes the whole `Decision` rather than its `choice` because three of the
/// arms need the id: to settle the finding the answer resolved, and to tell
/// `island` on a journey apart from `island` on a component.
/// `bound_ids` is what the route's own bindings ANSWERED (empty for the arms
/// that run before any conversion). It is the difference between an `island`
/// this stage carried out and one it merely recorded. `enclosed` is the
/// subset of it that some OTHER answer swallowed (ruling S3-R6), which is
/// what turns an accepted-but-redundant answer into a note instead of a
/// second binding nobody built.
fn applyAcknowledgement(
    ctx: *Ctx,
    out: *Outcome,
    r: route_mod.Route,
    dec: decisions.Decision,
    bound_ids: []const []const u8,
    enclosed: []const convert.Enclosure,
) WriteError!void {
    const gpa = ctx.gpa;
    const choice = dec.choice;
    const code: []const u8 = if (findingById(ctx.in.discovery.findings, dec.id)) |f| f.code else "";
    // Ruling S3-R6. An operator reading the handoff sees the ids a region
    // swallowed listed under the route just like any other, and answering one
    // of them is the obvious thing to do -- the presentation fixture's
    // `button_to "Sign out"` inside `<% if current_user %>` is exactly that
    // shape. The answer is ACCEPTED: the enclosing island already performs the
    // mutation, so the route is finished and there is nothing to build. What
    // it must not do is report the route unfinished, which is what happened
    // while the backend arm below asked only `boundBy` -- a `custom:` answer
    // on the nested control failed the run with "needs the --backend document
    // that names it" on a run that HAD been given one.
    const superseded_by: ?[]const u8 = for (enclosed) |e| {
        if (std.mem.eql(u8, e.id, dec.id)) break e.by;
    } else null;

    if (std.mem.eql(u8, choice, "retain")) {
        out.status = .retained;
        return;
    }
    if (std.mem.eql(u8, choice, "blocked")) {
        out.status = .blocked;
        return;
    }
    // Assumption A7. The page IS written and the status is untouched: a
    // static page is public whatever anyone decides, and the decision is the
    // operator saying so out loud. The finding is settled because it has been
    // answered AND acted on -- leaving it open would keep an otherwise
    // finished route out of `migrated` forever.
    if (std.mem.eql(u8, choice, "public")) {
        out.settle(gpa, dec.id);
        // The SAME picker `findings.derive` used to raise the question, not a
        // second one that happens to look at the same filter set: the note and
        // the finding are two rows about one decision, and a chain-order pick
        // here named a different filter than the manifest did whenever a
        // controller ran two auth-looking `before_action`s.
        const guard = controllers.authGuardFor(
            ctx.in.discovery.filterSet(),
            r.controller,
            r.action,
        );
        try out.addNote(gpa, "guarded by before_action :{s}; shipped public by decision", .{
            if (guard) |g| (g.name orelse "?") else "?",
        });
        return;
    }
    // An operation id or a `custom:/<path>` on a backend row. The island (or
    // the endpoint) IS the answer, so there is nothing left to say -- unless
    // the binding never formed, which happens for exactly one reason: an
    // operation id needs the `--backend` document that named it, and this run
    // was given none. Settling it then would report a route as migrated on
    // the strength of an answer nothing acted on.
    if (std.mem.eql(u8, code, findings.code_backend_endpoint)) {
        // Supersession is asked FIRST, ahead of `boundBy`, and that order is
        // the fix for a note that depended on where the nav was written.
        // `bindTemplate` walks a route's own view and the partials it renders
        // and never the layout, so a nav in a VIEW records a `Binding` for the
        // very `button_to` an enclosing island already swallowed -- a binding
        // nothing emits, because `convert` replaced the whole region before it
        // reached the control. Asking `boundBy` first settled on that phantom
        // in silence, so the same two answers explained themselves on a
        // layout-rendered nav and said nothing on a view-rendered one.
        //
        // An answer some other answer swallowed is superseded either way: the
        // enclosure is a fact about the emitted page, and a binding recorded
        // beside it does not make a component appear.
        if (superseded_by) |by| {
            try settleSuperseded(ctx, out, dec, by, bound_ids);
        } else if (boundBy(ctx.bindings.all, dec.id) or out.endpoint != null) {
            out.settle(gpa, dec.id);
        } else {
            try out.addOpenNote(gpa, "choice {s} needs the --backend document that names it", .{choice});
        }
        return;
    }
    if (std.mem.eql(u8, choice, "drop") and (std.mem.eql(u8, code, findings.code_stimulus_controller) or std.mem.eql(u8, code, findings.code_js_entry))) {
        out.settle(gpa, dec.id);
        const finding = findingById(ctx.in.discovery.findings, dec.id).?;
        if (std.mem.eql(u8, code, findings.code_js_entry)) {
            try out.addNote(gpa, "{s} dropped by decision", .{finding.path});
        } else {
            try out.addNote(gpa, "stimulus `{s}` dropped by decision", .{firstBacktickValue(finding.message)});
        }
        return;
    }
    if (std.mem.eql(u8, choice, "inline") and std.mem.eql(u8, code, findings.code_turbo_frame)) {
        out.settle(gpa, dec.id);
        const finding = findingById(ctx.in.discovery.findings, dec.id).?;
        try out.addNote(gpa, "turbo-frame `{s}` inlined", .{firstBacktickValue(finding.message)});
        return;
    }
    if (std.mem.eql(u8, choice, "island-realtime") and std.mem.eql(u8, code, findings.code_turbo_stream)) {
        if (boundBy(ctx.bindings.all, dec.id)) {
            out.settle(gpa, dec.id);
        } else {
            try out.addOpenNote(gpa, "choice island-realtime on RAILS_TURBO_STREAM needs a literal supported stream shape", .{});
        }
        return;
    }
    if (std.mem.eql(u8, choice, "island")) {
        // #167 Stage 3 Task 5. An `island` the converter CARRIED OUT settles,
        // exactly like a bound backend operation: the region is gone from the
        // page and the component is in the target. Three shapes reach here --
        // the journey answer itself (`ctx.bindings.scaffold`, whose forms and
        // endpoints are the answer), an `AuthStatus` binding, and the error
        // summary a bound auth form absorbed (in `bound_ids`, answered
        // `island` because the island is what renders those errors now).
        const journey_done = std.mem.eql(u8, code, findings.code_auth_journey) and
            ctx.bindings.scaffold != null;
        if (journey_done or boundBy(ctx.bindings.all, dec.id) or contains(bound_ids, dec.id)) {
            if (superseded_by) |by| {
                try settleSuperseded(ctx, out, dec, by, bound_ids);
            } else {
                out.settle(gpa, dec.id);
            }
            return;
        }
        // The journey's `island` is Task 5's AuthForm/AuthStatus pair, not
        // Stage 4's component port, so it gets its own note rather than one
        // pointing at the wrong stage.
        if (std.mem.eql(u8, code, findings.code_auth_journey)) {
            try out.addOpenNote(gpa, "choice island on {s} needs the auth scaffolds", .{code});
        } else if (std.mem.eql(u8, code, findings.code_request_time_state) and findingIsIvar(ctx, dec.id)) {
            try out.addOpenNote(gpa, "choice island on RAILS_REQUEST_TIME_STATE needs a --backend document with a list operation for collection `{s}`", .{dataCollectionForDecision(ctx, dec)});
        } else {
            try out.addOpenNote(gpa, "choice island deferred to Stage 4", .{});
        }
        return;
    }
    if (std.mem.eql(u8, choice, "backend")) {
        if (std.mem.eql(u8, code, findings.code_request_time_state) and findingIsIvar(ctx, dec.id)) {
            if (boundBy(ctx.bindings.all, dec.id)) {
                out.settle(gpa, dec.id);
            } else {
                try out.addOpenNote(gpa, "choice backend on RAILS_REQUEST_TIME_STATE needs a --backend document with a list operation for collection `{s}`", .{dataCollectionForDecision(ctx, dec)});
            }
            return;
        }
        // Assumption A6.
        try out.addOpenNote(
            gpa,
            "choice backend on RAILS_REQUEST_TIME_STATE has no converter (see #{d})",
            .{a6_issue},
        );
        return;
    }
    // Unreachable through `decisions.parse`, which validates every choice
    // against its finding's fixed list. Named rather than asserted so a
    // future choice added to the vocabulary but not here is visible in
    // the handoff instead of silently behaving like `retain`.
    try out.addOpenNote(gpa, "choice {s} is not implemented by this stage", .{choice});
}

fn dataCollectionForDecision(ctx: *Ctx, dec: decisions.Decision) []const u8 {
    if (dec.artifact) |artifact| return artifact;
    const finding = findingById(ctx.in.discovery.findings, dec.id) orelse return "?";
    const ivar = firstBacktickValue(finding.message);
    const stem = std.mem.trim(u8, ivar, "@");
    if (ctx.in.backend) |doc| return resolve.collectionFor(doc, stem) orelse stem;
    return stem;
}

fn findingIsIvar(ctx: *Ctx, id: []const u8) bool {
    for (ctx.in.discovery.fragments) |tpl| for (tpl.nodes) |node| {
        if (node.text != null or node.kind != .ivar) continue;
        const node_id = convert.findingIdFor(ctx.in.discovery.findings, tpl.path, node.line, node.col) orelse continue;
        if (std.mem.eql(u8, node_id, id)) return true;
    };
    return false;
}

fn firstBacktickValue(message: []const u8) []const u8 {
    const start = std.mem.indexOfScalar(u8, message, '`') orelse return message;
    const tail = message[start + 1 ..];
    const end = std.mem.indexOfScalar(u8, tail, '`') orelse return tail;
    return tail[0..end];
}

/// Ruling S3-R6: settles an answer that a bigger answer had already covered,
/// and says so -- unless the route note already says it in better words.
///
/// BOTH ids are named because neither alone is actionable. The operator knows
/// which finding they answered; what they cannot see from the target is which
/// other answer made theirs redundant -- and without that they are left
/// looking for a component that was never going to exist. `addNote`, not
/// `addOpenNote`: the question IS answered, twice over, and a route held open
/// on a redundant answer is the defect ruling S3-R6 closes.
///
/// Ruling S3-R7's second half: SILENT for an id `contentRoute`'s status-region
/// walk is already going to report. Once every answer on a route is applied
/// rather than only the strongest, an operator who answered the
/// `<%= current_user.email %>` INSIDE an answered `<% if current_user %>` got
/// the same fact on the same row twice -- this note, and then the walk's
/// "... is inside the region the AuthStatus island replaced, so it mounts
/// nothing of its own". The walk's wording is the one that survives: it names
/// the file and the line the operator actually wrote, it fires
/// whether or not the inner region was ever answered, and it is what ruling
/// S3-R6's own fix round put there. So this note keeps exactly the cases the
/// walk does not cover -- the `button_to` a bound nav region swallowed, and
/// the error summary a bound auth form absorbed, whose superseder is the
/// journey rather than an AuthStatus -- and those are the ones where naming
/// the superseding answer is genuinely new information.
///
/// The SETTLEMENT is unconditional either way. Only the note is at stake here;
/// dropping the settlement would reopen the very route ruling S3-R6 closed.
///
/// Contract 2 (owned-result), inherited from `write`: it allocates nothing of
/// its own and grows `out`'s note and settled set, which the `Result` owns.
fn settleSuperseded(
    ctx: *Ctx,
    out: *Outcome,
    dec: decisions.Decision,
    by: []const u8,
    bound_ids: []const []const u8,
) WriteError!void {
    const gpa = ctx.gpa;
    out.settle(gpa, dec.id);
    if (reportedAsFolded(ctx.bindings.status_origins, bound_ids, dec.id)) return;
    try out.addNote(
        gpa,
        "choice {s} on {s} superseded by the island answering {s}, which replaced the region it sits in",
        .{ dec.choice, dec.id, by },
    );
}

/// Whether `contentRoute`'s status-region walk will report `id` as a region
/// that mounted nothing of its own. The predicate of that loop, lifted into a
/// function so the two cannot drift into saying the same fact twice again --
/// or, worse, into both staying quiet.
///
/// That walk runs AFTER the acknowledgements and only while the route is still
/// `open`, which costs nothing here: the only choices that move the status off
/// `open` are `retain` and `blocked`, they are the top two tiers of `rank`, so
/// `applyAcknowledgements` applies one of them FIRST and returns. An answer
/// that reaches this function is therefore on a route whose walk still runs.
///
/// **Both disjuncts are load-bearing, and only one of them is reachable
/// through the fixtures.** `enclosed` is the ordinary case ruling S3-R7 was
/// written for. `absorbed` needs a region that is a complementary half AND is
/// swallowed by an answered region in ANOTHER template -- `convert`'s
/// `open_ends` are per-template, so nothing inside one template can be both.
/// A nav partial with the complementary pair in it, rendered from inside an
/// answered region of the view that includes it, is that shape; it is legal
/// Rails and nobody has written it here yet.
///
/// Silence is right for it: the walk's absorbed note says
/// "... folded into the AuthStatus island above it", which already tells the
/// operator their answer mounted nothing of its own and names the island that
/// does the work. It does NOT name the outer answer, which is the one thing
/// this function's caller would have added -- and adding it is the second
/// sentence about one row that ruling S3-R7 removed. An operator who wants the
/// outer answer has the region's own line in the note in front of them.
///
/// Takes the origins rather than the whole `Ctx` so the predicate can be
/// tested for what it is: the arms differ only in which flag they read, and a
/// whole `write` cannot reach the second one.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn reportedAsFolded(
    origins: []const StatusOrigin,
    bound_ids: []const []const u8,
    id: []const u8,
) bool {
    if (!contains(bound_ids, id)) return false;
    for (origins) |o| {
        if (!std.mem.eql(u8, o.finding_id, id)) continue;
        if (o.absorbed or o.enclosed) return true;
    }
    return false;
}

test "reportedAsFolded: absorbed and enclosed each silence the note on their own" {
    // The `absorbed` arm has no `write` that reaches it (see the doc above),
    // so it is pinned here or not at all -- and unpinned it was a disjunct
    // that could be deleted with every gate still green.
    const ids = [_][]const u8{ "A", "B", "C", "D" };
    const origins = [_]StatusOrigin{
        .{ .path = "p", .line = 1, .col = 1, .code = "if current_user", .finding_id = "A", .absorbed = true },
        .{ .path = "p", .line = 2, .col = 1, .code = "if current_user", .finding_id = "B", .absorbed = false, .enclosed = true },
        // Answered, walked, and reported by neither note: the walk says
        // nothing about it, so `settleSuperseded` must.
        .{ .path = "p", .line = 3, .col = 1, .code = "if current_user", .finding_id = "C", .absorbed = false },
    };
    try testing.expect(reportedAsFolded(&origins, &ids, "A"));
    try testing.expect(reportedAsFolded(&origins, &ids, "B"));
    try testing.expect(!reportedAsFolded(&origins, &ids, "C"));
    // No origin at all -- the `button_to` a bound nav swallowed, which is the
    // case the note exists for.
    try testing.expect(!reportedAsFolded(&origins, &ids, "D"));
    // An origin the ROUTE did not bind is a region on somebody else's page,
    // and this route's walk will not report it.
    try testing.expect(!reportedAsFolded(&origins, &.{}, "A"));
}

/// Whether an answered finding actually produced a binding.
fn boundBy(all: []const convert.Binding, id: []const u8) bool {
    for (all) |b| {
        if (std.mem.eql(u8, b.finding_id, id)) return true;
    }
    return false;
}

// ---- pass 2a: a route that becomes a page --------------------------------

fn contentRoute(
    ctx: *Ctx,
    acc: *Acc,
    layouts: *LayoutCache,
    views: *ViewCache,
    route_index: usize,
    out: *Outcome,
    content_path: []const u8,
) WriteError!void {
    const gpa = ctx.gpa;
    const d = ctx.in.discovery;
    const r = d.routes[route_index];
    const rt: rails.RouteTemplates = if (route_index < d.route_templates.len)
        d.route_templates[route_index]
    else
        .{ .templates = &.{}, .layout = null };

    const view_path = pickView(rt.templates, r) orelse {
        try out.addOpenNote(gpa, "no view template resolved for this route", .{});
        // Ruling S22. The note above was the whole report until now, and it
        // carries no id -- so an app with one `def other; render :about; end`
        // and no `other.html.erb` could never reach `complete` by any answer
        // at all. `findings.derive` raises `RAILS_NO_TEMPLATE` on this route's
        // `routes.rb` line for exactly the routes that reach here (see
        // `findings.routeHasNoView`, which mirrors this file's dispatch), and
        // the id is recomputed rather than searched for because one
        // declaration can produce several routes. The guard keeps the two
        // mirrors agreeing on the one input they could disagree on: a
        // discovery that carries no template list for this route says
        // nothing about its view, and `routeHasNoView` derives nothing for
        // it, so attaching an id here would point at a finding nobody raised.
        if (route_index < d.route_templates.len)
            try attachRouteFinding(ctx, out, findings.code_no_template, r.source.line);
        try applyAcknowledgements(ctx, out, r, out.open_ids.items, &.{}, &.{});
        return;
    };

    const layout_index: ?usize = if (rt.layout) |lp| try ensureLayout(ctx, acc, layouts, lp) else null;
    if (rt.layout != null and layout_index == null) {
        // The layout was resolved by discovery but could not be converted
        // (an unsupported engine, a parse error, a file the templates op
        // refused). The page is emitted standalone rather than dropped, and
        // stays open: it is missing its chrome, and nothing else says so.
        try out.addOpenNote(gpa, "layout {s} could not be converted; the view is emitted standalone", .{rt.layout.?});
        // Ruling S21. The note alone made the route UNANSWERABLE: it carries
        // no id, so no line in the decisions file could ever name it, and
        // `complete` was unreachable for every route under a Haml layout --
        // the same hole ruling S18 closed for a Haml VIEW, reopened one level
        // up in the graph. The layout's own Stage 1 findings (its
        // `RAILS_TEMPLATE_ENGINE_UNSUPPORTED`, or a parse error, or an
        // unscanned-template row) are exactly the question, and they are
        // SHARED: one `retain`/`blocked` answer on the layout settles every
        // route that declares it, rather than one answer per page.
        try collectTemplateFindings(ctx, out, rt.layout.?);
    }

    // Ruling S16. The target has ONE `layouts/<viewStem>.shtml`, and its bytes
    // depend on the layout it was converted against. A second route reaching
    // the same view under a DIFFERENT layout therefore cannot be served: it
    // has no file of its own, and the existing one extends the wrong parent.
    // The first route in this file's route order owns the view; this one says
    // what happened and writes nothing, rather than emitting a page that
    // fails at build time.
    if (views.find(view_path, layout_index) == null) {
        if (views.findAnyLayout(view_path)) |owner| {
            try out.addOpenNote(gpa, "view shared across layouts: {s} vs {s}", .{
                layoutStemOf(layouts, views.items.items[owner].layout_index),
                layoutStemOf(layouts, layout_index),
            });
            return;
        }
    }

    const view_index = ensureView(ctx, layouts, views, view_path, layout_index) catch |err| switch (err) {
        error.Unconvertible => {
            // Three shapes reach here, and each carries its own finding on
            // this same path: a template with a parse error
            // (`RAILS_TEMPLATE_PARSE_ERROR`), one the templates op refused
            // (`RAILS_TEMPLATE_UNSCANNED`), and one with no fragment stream at
            // all because its ENGINE is unreadable -- Haml/Slim, whose
            // `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` finding is ruling S18's.
            try out.addOpenNote(gpa, "view {s} was not converted", .{view_path});
            try collectTemplateFindings(ctx, out, view_path);
            // And the decision on one of those findings is what acknowledges
            // the route. Without this the ids were collected and then
            // ignored: a Haml or unparsable view could be answered `blocked`
            // in the decisions file and the route still came back `open`,
            // making `complete` unreachable by any answer at all -- the very
            // hole rulings S12/S18 exist to close, reopened one layer down.
            try applyAcknowledgements(ctx, out, r, out.open_ids.items, &.{}, &.{});
            return;
        },
        else => |e| return e,
    };
    const v = views.items.items[view_index];

    // The route's open findings are the view's plus its layout's: a helper
    // nobody has decided about leaves the PAGE unfinished wherever in the
    // graph it sits.
    try appendUnique(gpa, &out.open_ids, v.open_ids);
    if (layout_index) |li| try appendUnique(gpa, &out.open_ids, layouts.items.items[li].open_ids);

    // `convert.Output.dropped`, folded into the note rather than discarded
    // because `MIGRATION.md` is the only place an operator ever learns what
    // the conversion removed.
    //
    // Ruling S15 splits them in two. A `csrf_meta_tags` drop, a JS-entry drop
    // and a `<title>` suffix drop each remove a construct with a DEFINED
    // conversion -- nothing an operator has to act on, so they are footnotes
    // and the route can still be `migrated`. A dropped `content_for` is the
    // opposite: its body is markup the author wrote and the target does not
    // have (see `convert.dropped_content_for_prefix`), so the route is not
    // finished and says why.
    for (v.dropped) |note| try foldDropped(gpa, out, note);
    if (layout_index) |li| {
        for (layouts.items.items[li].dropped) |note| try foldDropped(gpa, out, note);
    }

    // Ruling S6: an unmapped region has NO finding id, so an empty
    // `open_finding_ids` is not proof of a finished page.
    const unmapped = v.unmapped_kind orelse
        (if (layout_index) |li| layouts.items.items[li].unmapped_kind else null);

    // Ruling S19: the ACKNOWLEDGEMENT is read first. An operator who answered
    // `retain` said the page stays on Rails and this target does not serve it;
    // `blocked` said the route does not ship at all. Either way what the
    // converter could not map is moot, and reporting the route `open` on
    // account of it left the run permanently incomplete -- the fixture's
    // `/registration/new` (a form with an unbound block local in its errors
    // loop) could not be finished by any answer at all, which is the same
    // hole rulings S12/S18 close one layer up.
    // The answers are read over the route's whole finding set, the ANSWERED
    // ones included: a binding is not an acknowledgement, and a `retain` on
    // the error summary a bound form absorbed still says this page stays on
    // Rails. Reading only `open_ids` let the island silently outrank it.
    var answerable: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (answerable.items) |x| gpa.free(x);
        answerable.deinit(gpa);
    }
    // Everything this route's bindings ANSWERED, which is what tells an
    // `island` that produced a component apart from one that is still Stage
    // 4's to build (see `applyAcknowledgement`). The layout's are in it since
    // Task 5: the `current_user` region an `AuthStatus` island answers usually
    // lives in a partial the LAYOUT renders.
    var bound_here: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (bound_here.items) |x| gpa.free(x);
        bound_here.deinit(gpa);
    }
    try appendUnique(gpa, &bound_here, v.bound_ids);
    if (layout_index) |li| try appendUnique(gpa, &bound_here, layouts.items.items[li].bound_ids);
    // Ruling S3-R6: the same set again, minus the ids an operator answered
    // DIRECTLY, each paired with the answer that swallowed it. Concatenated
    // rather than merged: both halves borrow `Discovery`, so this owns
    // nothing but the array, and a duplicate could only arise from a view and
    // its layout converting one shared partial -- in which case both entries
    // say the same thing and the lookup below stops at the first.
    var enclosed_here: std.ArrayListUnmanaged(convert.Enclosure) = .empty;
    defer enclosed_here.deinit(gpa);
    try enclosed_here.appendSlice(gpa, v.enclosed);
    if (layout_index) |li| try enclosed_here.appendSlice(gpa, layouts.items.items[li].enclosed);

    try appendUnique(gpa, &answerable, out.open_ids.items);
    try appendUnique(gpa, &answerable, bound_here.items);

    try applyAcknowledgements(ctx, out, r, answerable.items, bound_here.items, enclosed_here.items);
    // `island`/`backend` leave the status `open` (Stage 3/4 owns them), and
    // those routes fall through to the S6 net below so the note names BOTH
    // reasons rather than only the deferral.
    if (out.status != .open) {
        // Ruling S20: an acknowledged route writes NO page and no view file,
        // so this returns BEFORE the write below. `retained` means the page
        // stays on Rails and this target must not answer that URL at all;
        // `blocked` means it does not ship. Emitting the converted page
        // anyway made `blocked` a relabelling and nothing more -- the built
        // site served a blank `<main>` for a route the handoff called
        // blocked, which is worse than a 404 because it looks deliberate. The
        // handoff row is the record of what happened; the target holds only
        // what the site serves.
        //
        // Ruling S3-R7 does not widen this: the status is still the STRONGEST
        // answer's, so a `retain` alongside two bound controls still retains
        // the route, writes no page, and writes no island for it.
        //
        // The conversion is NOT skipped, only the write: its findings are
        // what the operator answered, and a later route sharing this view
        // may still need the file (see `materializeView`).
        //
        // The note still names any `rails:unmapped` region, as a footnote
        // (`addNote`, which cannot change the status back): the converted
        // bytes really do carry the placeholder, even unwritten, and
        // MIGRATION.md is the only place anyone learns that.
        if (unmapped) |kind| try out.addNote(gpa, "{s} left unmapped", .{kind});
        return;
    }

    // #167 Stage 3 Task 5, fix round 2: an answered status region that mounted
    // nothing has to say so -- an operator otherwise sees two answers and one
    // component with no way to tell whether the second was carried out or
    // quietly dropped. Two reasons a region mounts nothing, and they get
    // different words because they are different facts: `absorbed` is a
    // complementary half one `AuthStatus` renders both branches of, `enclosed`
    // is a region written inside another answered one, which the outer
    // island's span swallowed.
    //
    // BELOW the acknowledgement return, by decision rather than by statement
    // position, and for the reason the `unmapped` footnote a few lines up is
    // ABOVE it: that footnote reports what the emitted bytes carry, which is
    // true of a retained route too, while this one reports what the page this
    // route WRITES did with an answer. A `retain`ed route writes no page and
    // mounts no island, so there is no "island above it" for the note to point
    // at -- and it said so anyway, on every retained route sharing a template
    // with a folded region. `addNote` rather than `addOpenNote`: the region IS
    // answered, and this must not keep the route out of `migrated`.
    for (ctx.bindings.status_origins) |o| {
        if (!contains(bound_here.items, o.finding_id)) continue;
        if (o.absorbed) {
            try out.addNote(gpa, "{s}:{d} `{s}` folded into the AuthStatus island above it", .{
                o.path,
                o.line,
                oneLineCode(o.code),
            });
        } else if (o.enclosed) {
            try out.addNote(gpa, "{s}:{d} `{s}` is inside the region the AuthStatus island replaced, so it mounts nothing of its own", .{
                o.path,
                o.line,
                oneLineCode(o.code),
            });
        }
    }

    // Nobody settled this route, so the target serves it: an `open` page is a
    // page with a gap in it, not an absent page, and an `island`/`backend`
    // deferral is a route Stage 3/4 will finish from what is emitted here.
    try materializeView(ctx, acc, views, view_index);
    // The content page. Written per route (two routes rendering one view
    // still have two URLs), unlike the view and layout files.
    const page = try emitContentPage(ctx, r, v, view_path);
    defer gpa.free(page);
    try ctx.writeFile(content_path, page);

    try appendOwned(gpa, &out.artifacts, content_path);
    try appendOwned(gpa, &out.artifacts, v.artifact);
    if (layout_index) |li| try appendOwned(gpa, &out.artifacts, layouts.items.items[li].artifact);
    // #167 Stage 3: a bound route's artifacts include the island files its
    // page mounts and the client `lib/zb.ts` they all import. Listed on every
    // such route, like a shared layout, because that is what the route
    // produced -- an operator reading one row must see the whole set.
    // Unique, like every other entry in this set: `artifacts` is "the files
    // this route produced", and one file mounted twice on a page is still one
    // file. A shared `AuthStatus` is exactly that -- two separate status
    // regions on one page yield two `IslandFile`s under one path -- and
    // listing it twice reads as two components.
    for (v.islands) |f| try appendOwnedUnique(gpa, &out.artifacts, f.path);
    var mounts_client = false;
    var mounts_stimulus = false;
    for (v.islands) |f| {
        mounts_client = mounts_client or islandCallsClient(ctx, f.path);
        mounts_stimulus = mounts_stimulus or std.mem.startsWith(u8, f.path, "components/stimulus/");
    }
    if (layout_index) |li| {
        for (layouts.items.items[li].islands) |f| try appendOwnedUnique(gpa, &out.artifacts, f.path);
        for (layouts.items.items[li].islands) |f| {
            mounts_client = mounts_client or islandCallsClient(ctx, f.path);
            mounts_stimulus = mounts_stimulus or std.mem.startsWith(u8, f.path, "components/stimulus/");
        }
    }
    if (mounts_client) try appendOwned(gpa, &out.artifacts, client_lib_path);
    if (mounts_stimulus) try appendOwned(gpa, &out.artifacts, "lib/stimulus.ts");

    if (unmapped) |kind| {
        // Ruling S6's net, now the LAST word rather than the first: an
        // unmapped region has no finding id, so nobody can be asked about it,
        // and a route nobody answered at all must not reach `migrated` on the
        // strength of an empty `open_finding_ids`.
        try out.addOpenNote(gpa, "{s}: {s}", .{ kind, unmappedReason(kind) });
        out.status = .open;
        return;
    }

    if (out.open_ids.items.len == 0 and !out.unfinished) out.status = .migrated;
}

fn islandCallsClient(ctx: *Ctx, path: []const u8) bool {
    if (std.mem.eql(u8, path, auth_form_island_path) or std.mem.eql(u8, path, auth_status_island_path)) return true;
    for (ctx.bindings.all) |binding| {
        if (!std.mem.eql(u8, binding.island, path)) continue;
        return switch (binding.kind) {
            .operation, .custom, .auth_signin, .auth_signup, .auth_logout, .data_list, .turbo_stream => true,
            .stimulus, .turbo_frame, .component, .@"inline", .drop => false,
        };
    }
    return false;
}

/// The decision that decides a route with several open findings.
///
/// Highest `rank` wins, ties broken by the smallest finding id. `blocked`
/// beats `retain` because it is the stronger statement -- an operator who
/// blocked the route on ONE of its gaps has not agreed to ship it because
/// another gap was marked `retain` -- and both beat every answer below them,
/// because both say the target does not serve this page at all. Without a
/// fixed rank the status would depend on which id happened to sort first,
/// i.e. on a file name rather than on what the operator said.
/// Takes the parsed answers rather than the `Ctx` that holds them so the
/// precedence below is unit-testable without a target directory: the rule is
/// pure, and a test that has to build a whole `write` run to reach it stops
/// pinning the rule and starts pinning the run.
///
/// Contract 3 (caller-buffer): allocates nothing; the result borrows
/// `parsed`.
fn pickDecision(parsed: decisions.Parsed, ids: []const []const u8) ?decisions.Decision {
    var best: ?decisions.Decision = null;
    for (ids) |id| {
        const dec = decisions.lookup(parsed, id) orelse continue;
        const b = best orelse {
            best = dec;
            continue;
        };
        const r = rank(dec.choice, false);
        const br = rank(b.choice, false);
        if (r > br or (r == br and std.mem.order(u8, dec.id, b.id) == .lt)) best = dec;
    }
    return best;
}

/// The four tiers, strongest first: `blocked` > `retain` > an answer that
/// PRODUCES something (an operation id, `custom:/<path>`, `public`, `island`)
/// > a deferral.
///
/// The bottom tier is enumerated rather than the tier above it, because the
/// producing tier cannot be: an operation id is whatever the ZigBase document
/// happens to call an operation. `backend` normally defers, but B7 makes it
/// producing for a portable ivar whose data-island binding exists; the caller
/// supplies that fact because the word alone cannot distinguish the two
/// finding shapes. (`island` defers on a
/// `RAILS_REQUEST_TIME_STATE` and on the journey until Task 5's scaffolds
/// exist, but it produces on every other row, and `rank` sees the choice
/// without its finding. Ranking it as producing is the safe direction: the
/// deferral arm in `applyAcknowledgement` still leaves the route open and
/// still names why, so the worst case is a note naming the deferral rather
/// than a route silently claimed as finished.)
///
/// Contract 3 (caller-buffer): allocates nothing.
fn rank(choice: []const u8, backend_produces: bool) u8 {
    if (std.mem.eql(u8, choice, "blocked")) return 4;
    if (std.mem.eql(u8, choice, "retain")) return 3;
    if (std.mem.eql(u8, choice, "backend")) return if (backend_produces) 2 else 1;
    return 2;
}

/// B7's code-specific rank: only a bound ivar has carried `backend` out.
fn backendProducesDataIsland(ctx: *Ctx, dec: decisions.Decision) bool {
    return std.mem.eql(u8, dec.choice, "backend") and
        findingIsIvar(ctx, dec.id) and
        boundBy(ctx.bindings.all, dec.id);
}

test "rank: backend is producing only for a bound data island" {
    try std.testing.expectEqual(@as(u8, 2), rank("backend", true));
    try std.testing.expectEqual(@as(u8, 1), rank("backend", false));
}

/// Appends one `convert.Output.dropped` note, as a reason or as a footnote
/// (ruling S15; see the fold in `contentRoute` for which is which).
///
/// Contract 2 (owned-result), inherited from `write`: it allocates nothing of
/// its own and grows `out`'s note, which the eventual `Result` owns.
fn foldDropped(gpa: Allocator, out: *Outcome, note: []const u8) Allocator.Error!void {
    if (std.mem.startsWith(u8, note, convert.dropped_content_for_prefix)) {
        try out.addOpenNote(gpa, "{s}", .{note});
    } else {
        try out.addNote(gpa, "{s}", .{note});
    }
}

/// Why a fragment `convert.zig` left unmapped is unmapped. Every supported
/// fragment kind now has a finding in the current vocabulary. Reaching this
/// fallback therefore means discovery and conversion disagreed at the node's
/// exact location, whatever kind the marker names.
fn unmappedReason(_: []const u8) []const u8 {
    return "finding derivation drift";
}

/// Every Stage 1 finding raised against `path`. Used only when `convert`
/// refused the template outright, in which case its findings never reached
/// `Output.open_finding_ids`.
fn collectTemplateFindings(ctx: *Ctx, out: *Outcome, path: []const u8) WriteError!void {
    const gpa = ctx.gpa;
    for (ctx.in.discovery.findings) |f| {
        if (!std.mem.eql(u8, f.path, path)) continue;
        try appendOwned(gpa, &out.open_ids, f.id);
    }
}

/// Appends a COPY of `value`. Written as a helper rather than inline because
/// `list.append(gpa, try gpa.dupe(u8, v))` leaks the copy whenever the append
/// itself fails -- the dupe is then the only reference and it has already
/// been dropped. The FailingAllocator sweep at the bottom of this file caught
/// exactly that, four times over.
///
/// Contract 2 (owned-result), inherited: grows the caller's list, and the
/// copy it appends is owned by whoever owns that list. On failure nothing is
/// added and nothing is leaked.
fn appendOwned(gpa: Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) Allocator.Error!void {
    const copy = try gpa.dupe(u8, value);
    errdefer gpa.free(copy);
    try list.append(gpa, copy);
}

/// `appendOwned` for one value the list may already hold.
///
/// Contract 2 (owned-result), inherited: grows the caller's list; the string
/// appended is a copy that list then owns.
fn appendOwnedUnique(gpa: Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) Allocator.Error!void {
    for (list.items) |have| {
        if (std.mem.eql(u8, have, value)) return;
    }
    try appendOwned(gpa, list, value);
}

/// `appendOwned` for a whole slice, skipping values the list already holds.
///
/// Contract 2 (owned-result), inherited: grows the caller's list; every
/// string appended is a copy that list then owns.
fn appendUnique(gpa: Allocator, list: *std.ArrayListUnmanaged([]const u8), items: []const []const u8) Allocator.Error!void {
    for (items) |s| try appendOwnedUnique(gpa, list, s);
}

/// A layout's `layouts/templates/<stem>.shtml` name, or `(none)` for a
/// standalone view. Only for the ruling-S16 clash message, where naming both
/// sides is the whole point -- "this view is already converted" without
/// saying against WHAT sends the reader hunting through two controllers.
///
/// Contract 3 (caller-buffer): allocates nothing; the result borrows the
/// layout cache (or is a literal).
fn layoutStemOf(layouts: *const LayoutCache, layout_index: ?usize) []const u8 {
    const li = layout_index orelse return "(none)";
    return layouts.items.items[li].stem;
}

/// The view template among a route's scanned templates: the one at
/// `app/views/<controller>/<action>.*`, off a `routes.Route`.
///
/// The lookup itself is `resolve.viewFor` -- moved there for ruling S22, so
/// `findings.zig` can decide whether to derive `RAILS_NO_TEMPLATE` from the
/// same answer this file acts on. This wrapper is the route-typed call this
/// file makes; keeping it saves repeating the two optional unwraps at each
/// site and keeps the name the tests below use.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn pickView(templates: []const []const u8, r: route_mod.Route) ?[]const u8 {
    return resolve.viewFor(templates, r.controller, r.action);
}

fn findTemplate(list: []const fragments.Template, path: []const u8) ?fragments.Template {
    for (list) |t| {
        if (std.mem.eql(u8, t.path, path)) return t;
    }
    return null;
}

fn templateHasImportmap(tpl: fragments.Template) bool {
    for (tpl.nodes) |node| if (node.text == null and node.kind == .importmap) return true;
    return false;
}

fn dupeStringsWith(gpa: Allocator, values: []const []const u8, extra: ?[]const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |item| gpa.free(item);
        out.deinit(gpa);
    }
    for (values) |value| try appendOwnedUnique(gpa, &out, value);
    if (extra) |value| try appendOwnedUnique(gpa, &out, value);
    return out.toOwnedSlice(gpa);
}

/// Converts and writes `layouts/templates/<stem>.shtml` once per distinct
/// layout. Returns its index in the cache, or `null` when the layout has no
/// analysed fragment stream (unsupported engine, unreadable) or does not
/// convert.
fn ensureLayout(ctx: *Ctx, acc: *Acc, cache: *LayoutCache, layout_path: []const u8) WriteError!?usize {
    const gpa = ctx.gpa;
    if (cache.find(layout_path)) |i| return i;

    const tpl = findTemplate(ctx.in.discovery.fragments, layout_path) orelse return null;
    const output = convert.convert(gpa, .{
        .routes = ctx.in.discovery.routes,
        .assets = ctx.in.discovery.assets,
        .fragments = ctx.in.discovery.fragments,
        .findings = ctx.in.discovery.findings,
        .layout_stem = null,
        // #167 Stage 3 Task 5: see `Layout.islands`. A form on a layout is
        // still not bound -- no binding names one -- but the `current_user`
        // region in a layout-rendered partial is.
        .bindings = ctx.bindings.all,
    }, tpl, .layout) catch |err| switch (err) {
        error.Unconvertible => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer convert.freeOutput(gpa, output);

    const stem = try gpa.dupe(u8, resolve.layoutStem(layout_path));
    errdefer gpa.free(stem);
    const artifact = try std.fmt.allocPrint(gpa, "layouts/templates/{s}.shtml", .{stem});
    errdefer gpa.free(artifact);
    try ctx.writeFile(artifact, output.bytes);

    const source = try gpa.dupe(u8, layout_path);
    errdefer gpa.free(source);
    const ids = try dupeStringsWith(gpa, output.open_finding_ids, if (templateHasImportmap(tpl)) firstFindingWithCode(ctx.in.discovery.findings, findings.code_js_entry) else null);
    errdefer freeStrings(gpa, ids);
    const blocks = try dupeStrings(gpa, output.block_ids);
    errdefer freeStrings(gpa, blocks);
    const dropped = try dupeStrings(gpa, output.dropped);
    errdefer freeStrings(gpa, dropped);
    const unmapped = try firstUnmappedKind(gpa, output.bytes);
    errdefer if (unmapped) |u| gpa.free(u);
    const bound_ids = try dupeStrings(gpa, output.bound_finding_ids);
    errdefer freeStrings(gpa, bound_ids);
    const enclosed = try gpa.dupe(convert.Enclosure, output.enclosed);
    errdefer gpa.free(enclosed);
    const island_files = try emitIslands(ctx, output.islands);
    errdefer {
        for (island_files) |f| {
            gpa.free(f.path);
            gpa.free(f.bytes);
        }
        gpa.free(island_files);
    }
    try writeIslandFiles(ctx, acc, island_files);

    try cache.items.append(gpa, .{
        .source = source,
        .stem = stem,
        .artifact = artifact,
        .open_ids = ids,
        .block_ids = blocks,
        .dropped = dropped,
        .unmapped_kind = unmapped,
        .bound_ids = bound_ids,
        .enclosed = enclosed,
        .islands = island_files,
    });
    return cache.items.items.len - 1;
}

/// Converts and writes `layouts/<viewStem>.shtml` once per distinct view.
///
/// Two routes routinely render one view, and the target has ONE file per
/// view -- so the second route reuses this cache entry rather than hitting
/// the exclusive-create guard.
///
/// **`ensureLayout` must have run for this view's layout first.** That is a
/// correctness requirement, not a convenience: the view's conversion is
/// parameterised by `Context.layout_blocks`, which only exists once the
/// layout has been converted. Converting the view first would emit the two
/// blocks a converted layout always declares (`head`, `main`) and NONE of its
/// named yields, so a layout with `yield :sidebar` would carry a `<super>`
/// nothing fills -- `MISSING TOP-LEVEL BLOCK`, a site that does not build.
/// `contentRoute` therefore calls `ensureLayout` before this, and passes the
/// resulting index down.
fn ensureView(
    ctx: *Ctx,
    layouts: *LayoutCache,
    cache: *ViewCache,
    view_path: []const u8,
    layout_index: ?usize,
) (error{Unconvertible} || WriteError)!usize {
    const gpa = ctx.gpa;
    if (cache.find(view_path, layout_index)) |i| return i;

    const tpl = findTemplate(ctx.in.discovery.fragments, view_path) orelse return error.Unconvertible;
    const layout_stem: ?[]const u8 = if (layout_index) |li| layouts.items.items[li].stem else null;
    // Rulings S7/S9: the view fills EXACTLY the blocks its layout declares.
    // `convert.zig` emits an empty block for each one the view has no
    // `content_for` for, and drops a `content_for` naming an id the layout
    // does not declare (reporting it in `Output.dropped`, which this file
    // folds into the route's note). Both halves matter, because SuperHTML
    // fatals in both directions.
    const layout_blocks: []const []const u8 =
        if (layout_index) |li| layouts.items.items[li].block_ids else &.{};
    const output = try convert.convert(gpa, .{
        .routes = ctx.in.discovery.routes,
        .assets = ctx.in.discovery.assets,
        .fragments = ctx.in.discovery.fragments,
        .findings = ctx.in.discovery.findings,
        .layout_stem = layout_stem,
        .layout_blocks = layout_blocks,
        .bindings = ctx.bindings.all,
    }, tpl, .view);
    defer convert.freeOutput(gpa, output);

    const bytes: []const u8 = output.bytes;
    const stem = resolve.viewStem(view_path);
    const artifact = try std.fmt.allocPrint(gpa, "layouts/{s}.shtml", .{stem});
    errdefer gpa.free(artifact);
    // NOT written here (ruling S20): whether this view is written at all
    // depends on what the operator decided about the findings this very
    // conversion just produced. `contentRoute` calls `materializeView` for
    // every route that still needs a page.
    const bytes_owned = try gpa.dupe(u8, bytes);
    errdefer gpa.free(bytes_owned);

    const source = try gpa.dupe(u8, view_path);
    errdefer gpa.free(source);
    const layout_value = try std.fmt.allocPrint(gpa, "{s}.shtml", .{stem});
    errdefer gpa.free(layout_value);
    const title = if (output.title) |t| try gpa.dupe(u8, t) else null;
    errdefer if (title) |t| gpa.free(t);
    const description = if (output.description) |x| try gpa.dupe(u8, x) else null;
    errdefer if (description) |x| gpa.free(x);
    const ids = try dupeStringsWith(gpa, output.open_finding_ids, if (templateHasImportmap(tpl)) firstFindingWithCode(ctx.in.discovery.findings, findings.code_js_entry) else null);
    errdefer freeStrings(gpa, ids);
    const bound_ids = try dupeStrings(gpa, output.bound_finding_ids);
    errdefer freeStrings(gpa, bound_ids);
    const enclosed = try gpa.dupe(convert.Enclosure, output.enclosed);
    errdefer gpa.free(enclosed);
    const dropped = try dupeStrings(gpa, output.dropped);
    errdefer freeStrings(gpa, dropped);
    const unmapped = try firstUnmappedKind(gpa, bytes);
    errdefer if (unmapped) |u| gpa.free(u);
    const island_files = try emitIslands(ctx, output.islands);
    errdefer {
        for (island_files) |f| {
            gpa.free(f.path);
            gpa.free(f.bytes);
        }
        gpa.free(island_files);
    }

    try cache.items.append(gpa, .{
        .source = source,
        .layout_index = layout_index,
        .artifact = artifact,
        .bytes = bytes_owned,
        .written = false,
        .layout_value = layout_value,
        .title = title,
        .description = description,
        .open_ids = ids,
        .bound_ids = bound_ids,
        .enclosed = enclosed,
        .unmapped_kind = unmapped,
        .dropped = dropped,
        .islands = island_files,
    });
    return cache.items.items.len - 1;
}

// ---- #167 Stage 3: the island source -------------------------------------

/// One `.island.tsx` per bound region in `specs`.
///
/// Contract 2 (owned-result): the slice and every element's `path`/`bytes`
/// are fresh allocations; `finding_id` is borrowed from the binding, which
/// borrows `Discovery.findings` (see `IslandFile`). On failure the partial
/// result is released here.
fn emitIslands(
    ctx: *Ctx,
    specs: []const convert.IslandSpec,
) Allocator.Error![]IslandFile {
    const gpa = ctx.gpa;
    var out: std.ArrayListUnmanaged(IslandFile) = .empty;
    errdefer {
        for (out.items) |f| {
            gpa.free(f.path);
            gpa.free(f.bytes);
        }
        out.deinit(gpa);
    }
    for (specs) |spec| {
        if (spec.binding.kind == .turbo_frame) {
            const path = try gpa.dupe(u8, turbo_frame_island_path);
            errdefer gpa.free(path);
            const bytes = try emitFrameIsland(gpa);
            errdefer gpa.free(bytes);
            try out.append(gpa, .{ .path = path, .bytes = bytes, .finding_id = turbo_frame_island_path });
            continue;
        }
        if (spec.binding.kind == .stimulus) {
            for (spec.binding.identifiers, 0..) |identifier, index| {
                const controller = (try port.stimulusSource(gpa, identifier, ctx.in.discovery.js_sources)) orelse continue;
                defer port.freeController(gpa, controller);
                const mounts = try stimulusMounts(gpa, ctx, identifier);
                defer gpa.free(mounts);
                const descriptors = try stimulusDescriptors(gpa, ctx, identifier);
                defer gpa.free(descriptors);
                const mapped = for (ctx.bindings.stimulus_paths) |item| {
                    if (std.mem.eql(u8, item.identifier, identifier)) break item.path;
                } else spec.island;
                const path = if (index == 0) try gpa.dupe(u8, spec.island) else try gpa.dupe(u8, mapped);
                errdefer gpa.free(path);
                const bytes = try emitStimulusIsland(gpa, controller, descriptors, mounts);
                errdefer gpa.free(bytes);
                try out.append(gpa, .{ .path = path, .bytes = bytes, .finding_id = identifier });
            }
            continue;
        }
        const path = try gpa.dupe(u8, spec.island);
        errdefer gpa.free(path);
        const bytes = try emitIslandFor(ctx, spec);
        errdefer gpa.free(bytes);
        try out.append(gpa, .{ .path = path, .bytes = bytes, .finding_id = islandIdentity(ctx, spec) });
    }
    return out.toOwnedSlice(gpa);
}

/// Which ISLAND this spec is, as opposed to which region mounted it -- the key
/// `writeIslandFiles` skips on.
///
/// For a per-region form island the two are the same thing: one answered
/// finding, one file. The auth pair breaks that identity apart, and has to,
/// because both of its components are journey-level artifacts mounted from
/// more than one place: `AuthForm` from `sessions#new` and
/// `registrations#new`, `AuthStatus` from every answered `current_user`
/// region there is. Their bindings keep the region's id -- that is what
/// settles the region and what `convert.zig` joins the `<island>` onto -- and
/// the FILE answers to the journey instead, so "have I written this island"
/// stops depending on which of its mount points asked first.
///
/// The two auth components need DIFFERENT keys from each other or the second
/// would be skipped as already-written; `JourneyScaffold` carries one each.
///
/// Contract 3 (caller-buffer): allocates nothing. Every id it returns is
/// borrowed -- from `Discovery.findings`, or from `Bindings.owned` by way of
/// `JourneyScaffold`.
fn islandIdentity(ctx: *Ctx, spec: convert.IslandSpec) []const u8 {
    if (spec.binding.kind == .component) return spec.binding.island;
    if (spec.binding.kind == .turbo_frame) return turbo_frame_island_path;
    if (spec.binding.kind == .turbo_stream) return turbo_stream_island_path;
    const j = ctx.bindings.scaffold orelse return spec.binding.finding_id;
    return switch (spec.binding.kind) {
        .auth_signin, .auth_signup => j.finding_id,
        .auth_logout => j.status_id,
        .operation, .custom, .stimulus, .turbo_frame, .turbo_stream, .component, .data_list, .@"inline", .drop => spec.binding.finding_id,
    };
}

fn stimulusMounts(gpa: Allocator, ctx: *Ctx, identifier: []const u8) Allocator.Error![]StatusOrigin {
    var out: std.ArrayListUnmanaged(StatusOrigin) = .empty;
    errdefer out.deinit(gpa);
    for (ctx.in.discovery.fragments) |tpl| for (tpl.nodes) |node| {
        if (node.text != null or node.kind != .stimulus) continue;
        var names = std.mem.tokenizeAny(u8, node.name orelse "", " \t\r\n");
        var found = false;
        while (names.next()) |name| if (std.mem.eql(u8, name, identifier)) {
            found = true;
            break;
        };
        if (!found) continue;
        const id = convert.findingIdFor(ctx.in.discovery.findings, tpl.path, node.line, node.col) orelse continue;
        const decision = decisions.lookup(ctx.in.decisions, id) orelse continue;
        if (!std.mem.eql(u8, decision.choice, "island")) continue;
        try out.append(gpa, .{ .path = tpl.path, .line = node.line, .col = node.col, .code = node.code, .finding_id = id, .absorbed = false, .enclosed = false });
    };
    std.mem.sort(StatusOrigin, out.items, {}, struct {
        fn lessThan(_: void, a: StatusOrigin, b: StatusOrigin) bool {
            const order = std.mem.order(u8, a.path, b.path);
            return order == .lt or (order == .eq and a.line < b.line);
        }
    }.lessThan);
    return out.toOwnedSlice(gpa);
}

fn stimulusDescriptors(gpa: Allocator, ctx: *Ctx, identifier: []const u8) Allocator.Error![]port.Descriptor {
    var out: std.ArrayListUnmanaged(port.Descriptor) = .empty;
    errdefer out.deinit(gpa);
    for (ctx.in.discovery.fragments) |tpl| {
        for (tpl.nodes, 0..) |node, i| {
            if (node.text != null or node.kind != .stimulus) continue;
            var names = std.mem.tokenizeAny(u8, node.name orelse "", " \t\r\n");
            var found = false;
            while (names.next()) |name| if (std.mem.eql(u8, name, identifier)) {
                found = true;
                break;
            };
            if (!found) continue;
            var extent: std.ArrayListUnmanaged(u8) = .empty;
            defer extent.deinit(gpa);
            const end = convert.matchingEnd(tpl.nodes, i) orelse i;
            for (tpl.nodes[i .. end + 1]) |part| try extent.appendSlice(gpa, part.text orelse part.code);
            const actions = try port.actionDescriptors(gpa, extent.items, identifier);
            defer gpa.free(actions.list);
            try out.appendSlice(gpa, actions.list);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn emitStimulusIsland(
    gpa: Allocator,
    controller: port.Controller,
    descriptors: []const port.Descriptor,
    mounts: []const StatusOrigin,
) Allocator.Error![]u8 {
    _ = descriptors;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "// Ported STRUCTURALLY from {s} -- targets, values,\n// classes and action bindings are wired; the method bodies are quoted below and NOT translated.\n// Behavioural parity is not claimed. Mounted at: ", .{controller.path});
    for (mounts, 0..) |mount, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.print(gpa, "{s}:{d}", .{ mount.path, mount.line });
    }
    try out.appendSlice(gpa, ".\n");
    if (controller.lifecycle.len > 0) {
        try out.appendSlice(gpa, "// Lifecycle present: ");
        for (controller.lifecycle, 0..) |name, i| {
            if (i > 0) try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, name);
        }
        try out.appendSlice(gpa, "; port them into the effect.\n");
    }
    try out.appendSlice(gpa, "import { useEffect, useRef, type ComponentChildren } from \"@z/runtime\";\nimport { bindActions, targetsOf, valuesOf, classesOf } from \"../../lib/stimulus\";\n\nexport interface Props {}\n\nexport default function ");
    try appendPascal(gpa, &out, controller.identifier);
    try out.appendSlice(gpa, "(props: Props & { children?: ComponentChildren }) {\n  const root = useRef<HTMLDivElement>(null);\n  useEffect(() => {\n    const el = root.current!;\n    const targets = targetsOf(el, \"");
    try appendJsEscaped(gpa, &out, controller.identifier);
    try out.appendSlice(gpa, "\", [");
    for (controller.targets, 0..) |name, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.append(gpa, '"');
        try appendJsEscaped(gpa, &out, name);
        try out.append(gpa, '"');
    }
    try out.appendSlice(gpa, "]);\n    const values = valuesOf(el, \"");
    try appendJsEscaped(gpa, &out, controller.identifier);
    try out.appendSlice(gpa, "\", {");
    for (controller.values, 0..) |value, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        try out.print(gpa, " {s}: \"{s}\"", .{ value.name, @tagName(value.kind) });
    }
    if (controller.values.len > 0) try out.append(gpa, ' ');
    try out.appendSlice(gpa, "});\n    const classes = classesOf(el, \"");
    try appendJsEscaped(gpa, &out, controller.identifier);
    try out.appendSlice(gpa, "\", [");
    for (controller.classes, 0..) |name, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.print(gpa, "\"{s}\"", .{name});
    }
    try out.appendSlice(gpa, "]);\n");
    for (controller.methods) |method| {
        try out.print(gpa, "    // {s} -- original:\n", .{method.name});
        var lines = std.mem.splitScalar(u8, method.source, '\n');
        while (lines.next()) |line| try out.print(gpa, "    //   {s}\n", .{line});
        try out.print(gpa, "    function {s}(event: Event) {{\n      console.warn(\"zigapagos: {s}#{s} is not ported\");\n      // TODO: port the body above using targets, values and classes.\n      void event;\n    }}\n", .{ method.name, controller.identifier, method.name });
    }
    try out.appendSlice(gpa, "    return bindActions(el, \"");
    try appendJsEscaped(gpa, &out, controller.identifier);
    try out.appendSlice(gpa, "\", {");
    for (controller.methods, 0..) |method, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, method.name);
    }
    try out.appendSlice(gpa, "});\n  }, []);\n  return <div ref={root} style=\"display:contents\">{props.children}</div>;\n}\n");
    return out.toOwnedSlice(gpa);
}

/// One island's source: the per-region form emitter, or one of the two
/// journey scaffolds.
///
/// The auth pair is emitted from the JOURNEY rather than from the region,
/// which is what lets two views mount one file (see `writeIslandFiles`). The
/// `auth_logout` shape is the exception that still reads its spec, for the
/// header comment alone -- an operator who finds a component in `components/`
/// has to be able to get back to the ERB it replaced.
///
/// Contract 1 (self-freeing): the returned bytes are the only allocation.
fn emitIslandFor(ctx: *Ctx, spec: convert.IslandSpec) Allocator.Error![]u8 {
    const gpa = ctx.gpa;
    switch (spec.binding.kind) {
        .auth_signin, .auth_signup => {
            // Unreachable with a null scaffold: only `bindJourneyTemplate`
            // makes these bindings, and it runs only inside `if (journey)`.
            const j = ctx.bindings.scaffold orelse return emitIsland(gpa, spec);
            return emitAuthForm(gpa, j);
        },
        .auth_logout => {
            const j = ctx.bindings.scaffold orelse return emitIsland(gpa, spec);
            return emitAuthStatus(gpa, j, ctx.bindings.status_origins);
        },
        // A bound `link_to`/`button_to` is a button, not a form, and only the
        // spec can say which -- both shapes reach here as `.operation`/
        // `.custom`, because the KIND names what the answer resolved to, not
        // what the ERB control was.
        .operation, .custom => {
            if (spec.click) |click| return emitClickIsland(gpa, spec, click);
            return emitIsland(gpa, spec);
        },
        .turbo_frame => return emitFrameIsland(gpa),
        .turbo_stream => return emitStreamIsland(gpa),
        .component => return emitComponentIslandFor(ctx, spec),
        .data_list => return emitDataIsland(gpa, spec),
        // Task 5 replaces these generic compile-time fallbacks with the
        // dedicated Stage 4 emitters. Task 4 produces the specs but no
        // scaffold binding can construct these kinds yet.
        .stimulus, .@"inline", .drop => return emitIsland(gpa, spec),
    }
}

fn emitDataIsland(gpa: Allocator, spec: convert.IslandSpec) Allocator.Error![]u8 {
    const body_js = spec.port orelse "";
    const collection = spec.binding.collection orelse "";
    const name = try islandComponentName(gpa, spec.island);
    defer gpa.free(name);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa,
        \\// Generated by `zigapagos migrate --from rails` from {s}:{d}.
        \\// Replaces: {s}
        \\// Reads collection `{s}` through lib/zb.ts; the collection's list rule decides what a visitor sees.
        \\import {{ useEffect, useState }} from "@z/runtime";
        \\import {{ isZigbaseError }} from "@zigbase/client";
        \\import {{ zb }} from "../../lib/zb";
        \\
        \\export interface Props {{}}
        \\
        \\const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({{ "&": "&amp;", "<": "&lt;", ">": "&gt;", '\"': "&quot;", "'": "&#39;" }})[c]!);
        \\
        \\function body(rec: any): string {{
        \\  let h = "";
        \\
    , .{ spec.source, spec.line, spec.original, collection });
    var lines = std.mem.splitScalar(u8, body_js, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try out.appendSlice(gpa, "  ");
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    try out.print(gpa,
        \\  return h;
        \\}}
        \\
        \\export default function {s}(_props: Props) {{
        \\  const [html, setHtml] = useState<string | null>(null);
        \\  const [error, setError] = useState<string | null>(null);
        \\  useEffect(() => {{
        \\    zb.collection("{s}").getList(1, 50)
        \\      .then((page) => setHtml(page.items.map(body).join("")))
        \\      .catch((err) => setError(isZigbaseError(err) ? err.message : String(err)));
        \\  }}, []);
        \\  if (error !== null) return <p>{{"Could not load {s}: " + error}}</p>;
        \\  if (html === null) return <p>{{"Loading…"}}</p>;
        \\  return <div dangerouslySetInnerHTML={{{{ __html: html }}}} />;
        \\}}
        \\
    , .{ name, collection, collection });
    return out.toOwnedSlice(gpa);
}

fn componentNode(ctx: *Ctx, spec: convert.IslandSpec) ?fragments.Node {
    const tpl = findTemplate(ctx.in.discovery.fragments, spec.source) orelse return null;
    for (tpl.nodes) |node| {
        if (node.text == null and node.kind == .component_root and node.line == spec.line) return node;
    }
    return null;
}

fn componentSource(sources: []const port.JsSource, name: []const u8) ?port.JsSource {
    const exts = [_][]const u8{ ".jsx", ".tsx", ".js", ".ts" };
    for (exts) |ext| for (sources) |source| {
        const prefix = "app/javascript/components/";
        if (!std.mem.startsWith(u8, source.path, prefix)) continue;
        const rel = source.path[prefix.len..];
        if (rel.len == name.len + ext.len and std.mem.startsWith(u8, rel, name) and std.mem.eql(u8, rel[name.len..], ext)) return source;
    };
    return null;
}

fn copiedComponentPath(gpa: Allocator, source_path: []const u8) Allocator.Error![]u8 {
    const component_prefix = "app/javascript/components/";
    const javascript_prefix = "app/javascript/";
    if (std.mem.startsWith(u8, source_path, component_prefix))
        return std.fmt.allocPrint(gpa, "components/react/{s}", .{source_path[component_prefix.len..]});
    if (std.mem.startsWith(u8, source_path, javascript_prefix))
        return std.fmt.allocPrint(gpa, "components/react/_/{s}", .{source_path[javascript_prefix.len..]});
    return gpa.dupe(u8, source_path);
}

fn emitComponentIslandFor(ctx: *Ctx, spec: convert.IslandSpec) Allocator.Error![]u8 {
    const gpa = ctx.gpa;
    const node = componentNode(ctx, spec) orelse return emitIsland(gpa, spec);
    const name = node.name orelse return emitIsland(gpa, spec);
    const source = componentSource(ctx.in.discovery.js_sources, name) orelse return emitIsland(gpa, spec);
    const copied = try copiedComponentPath(gpa, source.path);
    defer gpa.free(copied);
    const import_path = if (std.mem.startsWith(u8, copied, "components/")) copied["components/".len..] else copied;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "// Generated by `zigapagos migrate --from rails` from {s}:{d}.\n// Replaces: {s}\n// The component is {s}, copied unchanged to {s};\n// its `react` imports resolve to the shared runtime through z-runtime.config.json (docs/migration/react-spa-bridge.md).\nimport {s} from \"./{s}\";\n\nexport interface Props {{", .{ spec.source, spec.line, spec.original, source.path, copied, name, import_path });
    const attrs = try gpa.dupe(fragments.Attr, node.attrs);
    defer gpa.free(attrs);
    std.mem.sort(fragments.Attr, attrs, {}, struct {
        fn lessThan(_: void, a: fragments.Attr, b: fragments.Attr) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);
    for (attrs, 0..) |attr, i| {
        if (i > 0) try out.appendSlice(gpa, ";");
        try out.print(gpa, " {s}{s}: {s}", .{ attr.key, if (attr.kind == .null) "?" else "", switch (attr.kind) {
            .string => "string",
            .number => "number",
            .boolean => "boolean",
            .null => "null",
        } });
    }
    if (attrs.len > 0) try out.append(gpa, ' ');
    try out.print(gpa, "}}\n\nexport default function {s}Island(props: Props) {{\n  return <{s} {{...props}} />;\n}}\n", .{ name, name });
    return out.toOwnedSlice(gpa);
}

/// `components/AuthForm.island.tsx`, byte for byte.
///
/// One component for both halves of the journey because assumption A5 folds
/// them into ONE finding with ONE answer: sign-in and sign-up differ by a
/// `create` call and a button label, which is a prop, not a second file. Its
/// bytes therefore depend on the JOURNEY only -- never on which of the two
/// views happened to be converted first -- so the file is identical whichever
/// view writes it.
///
/// Contract 1 (self-freeing): the returned bytes are the only allocation.
fn emitAuthForm(gpa: Allocator, j: JourneyScaffold) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var c: std.ArrayListUnmanaged(u8) = .empty;
    defer c.deinit(gpa);
    try appendJsEscaped(gpa, &c, j.collection);
    var signin: std.ArrayListUnmanaged(u8) = .empty;
    defer signin.deinit(gpa);
    try appendJsEscaped(gpa, &signin, j.signin_redirect);
    var signup: std.ArrayListUnmanaged(u8) = .empty;
    defer signup.deinit(gpa);
    try appendJsEscaped(gpa, &signup, j.signup_redirect);

    try out.print(gpa,
        \\// Generated by `zigapagos migrate --from rails` for the Rails auth journey.
        \\// ONE component for both halves of the flow: assumption A5 folds sign-in and
        \\// sign-up into one finding with one answer, so `mode` is what tells them apart.
        \\// Enforcement stays server-side: this island only presents the form and the backend's
        \\// validation errors; the ZigBase rule on the operation decides who may submit.
        \\import {{ useState }} from "@z/runtime";
        \\import {{ isZigbaseError, type FieldError }} from "@zigbase/client";
        \\import {{ zb }} from "../lib/zb";
        \\
        \\export interface Props {{ mode: "signin" | "signup" }}
        \\
        \\export default function AuthForm(props: Props) {{
        \\  const signup = props.mode === "signup";
        \\  const [email, setEmail] = useState("");
        \\  const [password, setPassword] = useState("");
        \\  const [passwordConfirm, setPasswordConfirm] = useState("");
        \\  const [errors, setErrors] = useState<Record<string, FieldError>>({{}});
        \\  async function onSubmit(e: any) {{
        \\    e.preventDefault();
        \\    setErrors({{}});
        \\    try {{
        \\      if (signup) {{
        \\        await zb.collection("{s}").create({{ email, password, passwordConfirm }});
        \\      }}
        \\      await zb.collection("{s}").authWithPassword(email, password);
        \\      location.assign(signup ? "{s}" : "{s}");
        \\    }} catch (err) {{
        \\      if (isZigbaseError(err)) {{
        \\        setErrors(err.data);
        \\        return;
        \\      }}
        \\      throw err;
        \\    }}
        \\  }}
        \\  return (
        \\    <form onSubmit={{onSubmit}}>
        \\      <ul class="errors">
        \\        {{Object.entries(errors).map(([f, e]) => (
        \\          <li key={{f}}>{{f + ": " + e.message}}</li>
        \\        ))}}
        \\      </ul>
        \\      <label htmlFor="email">{{"Email"}}</label>
        \\      <input id="email" type="email" name="email" value={{email}}
        \\        onInput={{(e: any) => setEmail(String(e.currentTarget.value ?? ""))}} />
        \\      <label htmlFor="password">{{"Password"}}</label>
        \\      <input id="password" type="password" name="password" value={{password}}
        \\        onInput={{(e: any) => setPassword(String(e.currentTarget.value ?? ""))}} />
        \\      {{signup ? <label htmlFor="passwordConfirm">{{"Password confirmation"}}</label> : null}}
        \\      {{signup ? (
        \\        <input id="passwordConfirm" type="password" name="passwordConfirm" value={{passwordConfirm}}
        \\          onInput={{(e: any) => setPasswordConfirm(String(e.currentTarget.value ?? ""))}} />
        \\      ) : null}}
        \\      <button type="submit">{{signup ? "Sign up" : "Sign in"}}</button>
        \\    </form>
        \\  );
        \\}}
        \\
    , .{ c.items, c.items, signup.items, signin.items });
    return out.toOwnedSlice(gpa);
}

/// A region's own source with any newline turned into a space, so a header
/// comment stays a header comment.
///
/// Contract 3 (caller-buffer): allocates nothing -- it returns the input
/// unchanged when there is nothing to fold, and `code` never spans lines in
/// practice (`templates.rb` emits a statement's source as one line). The
/// guard is here because "in practice" is not a guarantee about author text.
fn oneLineCode(code: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, code, "\r\n")) |i| return code[0..i];
    return code;
}

/// `components/AuthStatus.island.tsx`, byte for byte.
///
/// Contract 1 (self-freeing): the returned bytes are the only allocation.
fn emitAuthStatus(
    gpa: Allocator,
    j: JourneyScaffold,
    origins: []const StatusOrigin,
) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var c: std.ArrayListUnmanaged(u8) = .empty;
    defer c.deinit(gpa);
    try appendJsEscaped(gpa, &c, j.collection);

    // EVERY region, not the one that happened to be converted first: this is
    // one component standing in for several, and a header naming one of them
    // is both incomplete and dependent on the order the pages were written.
    // `status_origins` is sorted by (path, line, col) for the same reason.
    try out.appendSlice(gpa, "// Generated by `zigapagos migrate --from rails` for the Rails auth journey.\n");
    try out.appendSlice(gpa, "// Replaces, in source order:\n");
    for (origins) |o| {
        try out.print(gpa, "//   {s}:{d} -- {s}", .{ o.path, o.line, oneLineCode(o.code) });
        // The absorbed half is named as such: it is the region whose answer
        // produced no second component, and an operator looking for it has to
        // be able to find out why.
        if (o.absorbed) try out.appendSlice(gpa, " (folded into the region above)");
        // Likewise for a region written INSIDE another one: it produced no
        // mount of its own either, and for a reason a reader cannot guess from
        // a bare line. Its own words, not the folded half's -- there is no
        // complementary region above it to look for.
        if (o.enclosed) try out.appendSlice(gpa, " (inside the region above, which this replaces)");
        try out.append(gpa, '\n');
    }

    try out.print(gpa,
        \\// Enforcement stays server-side: this island only reports who the browser is
        \\// signed in as; the ZigBase rule on each operation decides what they may do.
        \\import {{ useEffect, useState }} from "@z/runtime";
        \\import {{ zb }} from "../lib/zb";
        \\
        \\export interface Props {{}}
        \\
        \\export default function AuthStatus(_props: Props) {{
        \\  // The session lives in the visitor's own browser, so the prerendered HTML
        \\  // cannot know who is signed in: it renders the signed-out branch, and this
        \\  // flips once the island hydrates. Reading the store during the FIRST render
        \\  // instead would make the server's markup and the client's disagree.
        \\  const [ready, setReady] = useState(false);
        \\  useEffect(() => setReady(true), []);
        \\  async function logout() {{
        \\    await zb.collection("{s}").logout();
        \\    location.reload();
        \\  }}
        \\  if (!ready || !zb.authStore.isValid) {{
        \\
    , .{c.items});

    if (j.signin_url) |url| {
        try out.appendSlice(gpa, "    return <a href=\"");
        try appendJsEscaped(gpa, &out, url);
        try out.appendSlice(gpa, "\">{\"Sign in\"}</a>;\n");
    } else {
        // The plan's "T5 self" row: a journey detected only by a password
        // form (assumption A5's second half) has no `sessions#new` page, so
        // there is nowhere to send a signed-out visitor. A link to a route
        // this migration never produced would be a dangling internal link the
        // built site's own `doctor` would then report.
        try out.appendSlice(gpa,
            \\    // This journey has no `sessions#new` route, so there is nowhere to link.
            \\    return null;
            \\
        );
    }

    try out.appendSlice(gpa,
        \\  }
        \\  return (
        \\    <span>
        \\      {String(zb.authStore.record?.email ?? "")}{" "}
        \\      <button onClick={logout}>{"Sign out"}</button>
        \\    </span>
        \\  );
        \\}
        \\
    );
    return out.toOwnedSlice(gpa);
}

/// `components/forms/registrations_new_2.island.tsx` -> `RegistrationsNew2`.
///
/// Contract 1 (self-freeing): the returned identifier is the only allocation.
fn islandComponentName(gpa: Allocator, island: []const u8) Allocator.Error![]u8 {
    var stem = std.fs.path.basename(island);
    const suffix = ".island.tsx";
    if (std.mem.endsWith(u8, stem, suffix)) stem = stem[0 .. stem.len - suffix.len];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendPascal(gpa, &out, stem);
    // `appendPascal` drops a leading digit and every separator, so a stem of
    // `_1` reduces to nothing. A component with no name is not compilable
    // TSX, and this is the only fallback that keeps the file valid.
    if (out.items.len == 0) try out.appendSlice(gpa, "Form");
    return out.toOwnedSlice(gpa);
}

/// `password_confirmation` -> `Password confirmation`. Rails' own
/// `String#humanize`, minus the `_id` suffix rule (a `_id` field in a
/// converted form is a real field, not an association Rails is hiding).
///
/// Contract 2 (owned-result), inherited: grows the caller's buffer.
fn appendHumanized(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8) Allocator.Error!void {
    for (name, 0..) |ch, i| {
        if (ch == '_') {
            try out.append(gpa, ' ');
        } else if (i == 0) {
            try out.append(gpa, std.ascii.toUpper(ch));
        } else {
            try out.append(gpa, ch);
        }
    }
}

/// The `<input type=…>` a form-builder helper becomes, or `null` for the
/// helpers that are not `<input>`s at all.
fn inputType(helper: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, helper, "email_field")) return "email";
    if (std.mem.eql(u8, helper, "password_field")) return "password";
    if (std.mem.eql(u8, helper, "hidden_field")) return "hidden";
    if (std.mem.eql(u8, helper, "check_box")) return "checkbox";
    if (std.mem.eql(u8, helper, "text_field")) return "text";
    // Every other `f.<x>_field` Rails ships (`number_field`, `date_field`,
    // `url_field`, …) maps to the HTML input type of the same stem, so the
    // helper name is the answer whenever it ends in `_field`.
    if (std.mem.endsWith(u8, helper, "_field")) return helper[0 .. helper.len - "_field".len];
    return null;
}

/// The client call one binding makes, as the TSX expression that performs it.
///
/// The three shapes come from what the ZigBase client actually offers (see
/// `~/nothlav/zigbase/clients/typescript/src/collection.ts`): a collection
/// operation is `create(body)`/`update(id, body)`/`delete(id)`, and anything
/// else -- a consumer route, an `custom:/<path>` answer -- goes through the
/// generic `send(method, path, { body })`. Which one applies is read off the
/// VERB and the collection rather than off a `kind` field, because the
/// document is the authority on both and a fourth field would be a second
/// copy of what they already say.
const CallShape = enum { create, update, delete_, send };

fn callShape(b: convert.Binding) CallShape {
    if (b.collection == null) return .send;
    if (std.mem.eql(u8, b.verb, "POST")) return .create;
    if (std.mem.eql(u8, b.verb, "PATCH") or std.mem.eql(u8, b.verb, "PUT")) return .update;
    if (std.mem.eql(u8, b.verb, "DELETE")) return .delete_;
    return .send;
}

fn hasField(fields: []const convert.Field, name: []const u8) bool {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

/// One bound region's `.island.tsx`.
///
/// The header's second paragraph is not decoration. A Rails form is guarded
/// by the controller it posts to; the converted page has no controller, and
/// an operator reading only this file has to know that the guard now lives in
/// the ZigBase rule on the operation -- otherwise the natural next edit is to
/// "add the check back" in the island, i.e. in code the visitor controls.
///
/// Contract 1 (self-freeing): all scratch is released; the returned bytes are
/// the only allocation that escapes.
fn emitIsland(gpa: Allocator, spec: convert.IslandSpec) Allocator.Error![]u8 {
    const b = spec.binding;
    const name = try islandComponentName(gpa, spec.island);
    defer gpa.free(name);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.print(gpa,
        \\// Generated by `zigapagos migrate --from rails` from {s}:{d}.
        \\// Replaces: {s}
        \\// Enforcement stays server-side: this island only presents the form and the backend's
        \\// validation errors; the ZigBase rule on the operation decides who may submit.
        \\import {{ useState }} from "@z/runtime";
        \\import {{ isZigbaseError, type FieldError }} from "@zigbase/client";
        \\import {{ zb }} from "../../lib/zb";
        \\
        \\export interface Props {{}}
        \\
        \\export default function {s}(_props: Props) {{
        \\
    , .{ spec.source, spec.line, spec.original, name });

    const shape = callShape(b);
    // An `update` and a `delete` BOTH address one record, and a static page
    // has no request to read its id from, so the only honest thing a hidden
    // `id` field cannot supply is a TODO -- rendering the form anyway would
    // produce a control whose submit can only fail at runtime.
    //
    // The `delete` half was missing: `update(values.id, values)` was guarded
    // and `delete(values.id)` was emitted regardless, on the same empty
    // `values`. The click emitter above has guarded both since round 3 and
    // the docs described the guard as covering both, so this arm was the odd
    // one out in three places at once. One message for the two shapes, for
    // the same reason the click island has one: an operator who is told the
    // form "updates a record" while looking at a delete learns the wrong
    // thing about their own template.
    if ((shape == .update or shape == .delete_) and !hasField(spec.fields, "id")) {
        try out.appendSlice(gpa,
            \\  return <p>{"TODO: this form acts on one record; pass its id"}</p>;
            \\}
            \\
        );
        return out.toOwnedSlice(gpa);
    }

    try out.appendSlice(gpa,
        \\  const [values, setValues] = useState<Record<string, string>>({});
        \\  const [errors, setErrors] = useState<Record<string, FieldError>>({});
        \\  const [done, setDone] = useState(false);
        \\  const set = (field: string) => (e: any) =>
        \\    setValues({ ...values, [field]: String(e.currentTarget.value ?? "") });
        \\  async function onSubmit(e: any) {
        \\    e.preventDefault();
        \\    setErrors({});
        \\    try {
        \\
    );
    try out.appendSlice(gpa, "      await ");
    switch (shape) {
        .create => try emitCollectionCall(gpa, &out, b.collection.?, "create(values)"),
        .update => try emitCollectionCall(gpa, &out, b.collection.?, "update(values.id, values)"),
        .delete_ => try emitCollectionCall(gpa, &out, b.collection.?, "delete(values.id)"),
        .send => {
            try out.appendSlice(gpa, "zb.send(\"");
            try appendJsEscaped(gpa, &out, b.verb);
            try out.appendSlice(gpa, "\", \"");
            try appendJsEscaped(gpa, &out, b.path);
            try out.appendSlice(gpa, "\", { body: values });\n");
        },
    }
    if (b.redirect_to) |url| {
        try out.appendSlice(gpa, "      location.assign(\"");
        try appendJsEscaped(gpa, &out, url);
        try out.appendSlice(gpa, "\");\n");
    } else {
        try out.appendSlice(gpa, "      setDone(true);\n");
    }
    try out.appendSlice(gpa,
        \\    } catch (err) {
        \\      if (isZigbaseError(err)) {
        \\        setErrors(err.data);
        \\        return;
        \\      }
        \\      throw err;
        \\    }
        \\  }
        \\  const errorList = (
        \\
    );
    try emitErrorList(gpa, &out, "    ");
    try out.appendSlice(gpa,
        \\  );
        \\  if (done) return <p>{"Done."}</p>;
        \\  return (
        \\    <form onSubmit={onSubmit}>
        \\
    );
    // Ruling: the error summary goes where the ERB put it. A Rails view that
    // rendered `@user.errors` above the form gets the same reading order
    // here; one that rendered none gets the list next to the button that
    // produces the errors, which is the only position the source supports.
    if (spec.errors_model != null) try out.appendSlice(gpa, "      {errorList}\n");
    for (spec.fields) |f| try emitField(gpa, &out, f);
    if (spec.errors_model == null) try out.appendSlice(gpa, "      {errorList}\n");
    try out.appendSlice(gpa, "      <button type=\"submit\">{\"");
    try appendJsEscaped(gpa, &out, spec.submit_label);
    try out.appendSlice(gpa,
        \\"}</button>
        \\    </form>
        \\  );
        \\}
        \\
    );
    return out.toOwnedSlice(gpa);
}

/// One bound `link_to`/`button_to`'s `.island.tsx`: a single button that
/// performs the answered operation on click.
///
/// A separate emitter rather than a branch inside `emitIsland`, because
/// almost nothing carries over. There is no `<form>` and no `values` state --
/// a link submits no fields, so the call's body is empty and the only thing
/// the control collects is the click itself. What DOES carry over is
/// deliberate and shared: the same `callShape`, the same `redirect_to`
/// pairing, and the same `isZigbaseError`/`errorList` rendering, because an
/// operator reading two generated islands should not have to learn two error
/// conventions.
///
/// Contract 1 (self-freeing): all scratch is released; the returned bytes are
/// the only allocation that escapes.
fn emitClickIsland(
    gpa: Allocator,
    spec: convert.IslandSpec,
    click: convert.Click,
) Allocator.Error![]u8 {
    const b = spec.binding;
    const name = try islandComponentName(gpa, spec.island);
    defer gpa.free(name);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.print(gpa,
        \\// Generated by `zigapagos migrate --from rails` from {s}:{d}.
        \\// Replaces: {s}
        \\// Enforcement stays server-side: this island only presents the control and the
        \\// backend's errors; the ZigBase rule on the operation decides who may submit.
        \\import {{ useState }} from "@z/runtime";
        \\import {{ isZigbaseError, type FieldError }} from "@zigbase/client";
        \\import {{ zb }} from "../../lib/zb";
        \\
        \\export interface Props {{}}
        \\
        \\export default function {s}(_props: Props) {{
        \\
    , .{ spec.source, spec.line, spec.original, name });

    const shape = callShape(b);
    // A collection `update`/`delete` addresses ONE record, and a link only
    // carries an id when its route helper was called with a literal one
    // (`post_path(1)`). Without it there is nothing honest to emit -- the same
    // ruling `emitIsland` applies to a form with no `id` field, restated
    // because the id comes from a different place here.
    if ((shape == .update or shape == .delete_) and click.record_id == null) {
        try out.appendSlice(gpa,
            \\  return <p>{"TODO: this control acts on one record; pass its id"}</p>;
            \\}
            \\
        );
        return out.toOwnedSlice(gpa);
    }

    try out.appendSlice(gpa,
        \\  const [errors, setErrors] = useState<Record<string, FieldError>>({});
        \\  const [done, setDone] = useState(false);
        \\  async function onClick() {
        \\
    );
    // Rails put this prompt in front of the request, and a destructive control
    // that stops asking is a behaviour change the migration was not asked to
    // make.
    if (click.confirm) |q| {
        try out.appendSlice(gpa, "    if (!window.confirm(\"");
        try appendJsEscaped(gpa, &out, q);
        try out.appendSlice(gpa, "\")) return;\n");
    }
    try out.appendSlice(gpa,
        \\    setErrors({});
        \\    try {
        \\
    );
    try out.appendSlice(gpa, "      await ");
    switch (shape) {
        .create => try emitCollectionCall(gpa, &out, b.collection.?, "create({})"),
        .update, .delete_ => {
            var call: std.ArrayListUnmanaged(u8) = .empty;
            defer call.deinit(gpa);
            try call.appendSlice(gpa, if (shape == .update) "update(\"" else "delete(\"");
            try appendJsEscaped(gpa, &call, click.record_id.?);
            try call.appendSlice(gpa, if (shape == .update) "\", {})" else "\")");
            try emitCollectionCall(gpa, &out, b.collection.?, call.items);
        },
        // No `body`: a link has no fields, and sending an empty object would
        // claim the control submits something it does not.
        .send => {
            try out.appendSlice(gpa, "zb.send(\"");
            try appendJsEscaped(gpa, &out, b.verb);
            try out.appendSlice(gpa, "\", \"");
            try appendJsEscaped(gpa, &out, b.path);
            try out.appendSlice(gpa, "\");\n");
        },
    }
    if (b.redirect_to) |url| {
        try out.appendSlice(gpa, "      location.assign(\"");
        try appendJsEscaped(gpa, &out, url);
        try out.appendSlice(gpa, "\");\n");
    } else {
        try out.appendSlice(gpa, "      setDone(true);\n");
    }
    try out.appendSlice(gpa,
        \\    } catch (err) {
        \\      if (isZigbaseError(err)) {
        \\        setErrors(err.data);
        \\        return;
        \\      }
        \\      throw err;
        \\    }
        \\  }
        \\  if (done) return <p>{"Done."}</p>;
        \\  return (
        \\    <span>
        \\
    );
    try out.appendSlice(gpa, "      <button type=\"button\" onClick={onClick}>{\"");
    try appendJsEscaped(gpa, &out, spec.submit_label);
    try out.appendSlice(gpa, "\"}</button>\n");
    try emitErrorList(gpa, &out, "      ");
    try out.appendSlice(gpa,
        \\    </span>
        \\  );
        \\}
        \\
    );
    return out.toOwnedSlice(gpa);
}

/// The `<ul class="errors">` a generated island renders the backend's
/// `ZigbaseError.data` into, one `<li>` per field, at `indent`.
///
/// One emitter for the form island and the click island, because the two
/// used to carry the markup twice and an operator reading both generated
/// files should not have to learn two error conventions -- nor should a fix
/// to one (a class name, the `key`) have to be made twice. Only the indent
/// differs: the form island binds it to `errorList` at four spaces and places
/// it where the ERB put the summary; the click island inlines it at six,
/// below its one button. The auth journey's islands (`emitAuthForm`) keep
/// their own copy: they are printed through one format string and are Task
/// 5's to fold.
///
/// Contract 2 (owned-result), inherited from the island emitters: grows the
/// caller's buffer and allocates nothing else.
fn emitErrorList(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), indent: []const u8) Allocator.Error!void {
    const lines = [_][]const u8{
        "<ul class=\"errors\">",
        "  {Object.entries(errors).map(([f, e]) => (",
        "    <li key={f}>{f + \": \" + e.message}</li>",
        "  ))}",
        "</ul>",
    };
    for (lines) |line| {
        try out.appendSlice(gpa, indent);
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
}

/// `zb.collection("<c>").<call>;` -- the one place a collection name is
/// escaped into a JS string literal, so the three call shapes cannot differ
/// over it.
///
/// Contract 2 (owned-result), inherited from `emitIsland`: grows the caller's
/// buffer and allocates nothing else.
fn emitCollectionCall(
    gpa: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    collection: []const u8,
    call: []const u8,
) Allocator.Error!void {
    try out.appendSlice(gpa, "zb.collection(\"");
    try appendJsEscaped(gpa, out, collection);
    try out.appendSlice(gpa, "\").");
    try out.appendSlice(gpa, call);
    try out.appendSlice(gpa, ";\n");
}

/// One control. Everything is indented six spaces: the island's JSX sits
/// inside `return ( <form> … )`.
///
/// Contract 2 (owned-result), inherited from `emitIsland`: grows the caller's
/// buffer and allocates nothing else.
fn emitField(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), f: convert.Field) Allocator.Error!void {
    if (std.mem.eql(u8, f.helper, "label")) {
        try out.appendSlice(gpa, "      <label htmlFor=\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\">{\"");
        if (f.label) |l| try appendJsEscaped(gpa, out, l) else try appendHumanized(gpa, out, f.name);
        try out.appendSlice(gpa, "\"}</label>\n");
        return;
    }
    if (std.mem.eql(u8, f.helper, "text_area")) {
        try out.appendSlice(gpa, "      <textarea id=\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\" name=\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\" value={values[\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\"] ?? \"\"} onInput={set(\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\")} />\n");
        return;
    }
    if (std.mem.eql(u8, f.helper, "select")) {
        try out.appendSlice(gpa, "      <select id=\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\" name=\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\" value={values[\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\"] ?? \"\"} onInput={set(\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\")}>\n");
        for (f.options) |o| {
            try out.appendSlice(gpa, "        <option value=\"");
            try appendJsEscaped(gpa, out, o);
            try out.appendSlice(gpa, "\">{\"");
            try appendJsEscaped(gpa, out, o);
            try out.appendSlice(gpa, "\"}</option>\n");
        }
        try out.appendSlice(gpa, "      </select>\n");
        return;
    }
    const kind = inputType(f.helper) orelse {
        // A helper this stage has no HTML for. A comment rather than a
        // guessed control: an operator can see exactly what was in the ERB,
        // and the island still compiles and still submits its other fields.
        try out.appendSlice(gpa, "      {/* TODO: f.");
        try appendJsEscaped(gpa, out, f.helper);
        try out.appendSlice(gpa, " :");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, " has no static equivalent */}\n");
        return;
    };
    const checkbox = std.mem.eql(u8, kind, "checkbox");
    try out.appendSlice(gpa, "      <input id=\"");
    try appendJsEscaped(gpa, out, f.name);
    try out.appendSlice(gpa, "\" type=\"");
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, "\" name=\"");
    try appendJsEscaped(gpa, out, f.name);
    if (checkbox) {
        // A checkbox has no `value` the user edits, so the shared
        // `Record<string, string>` state holds `"true"`/`""` and the control
        // reads and writes THAT rather than `e.currentTarget.value`, which is
        // the constant `"on"` for every checked box.
        try out.appendSlice(gpa, "\" checked={values[\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\"] === \"true\"} onInput={(e: any) => setValues({ ...values, ");
        try out.appendSlice(gpa, "[\"");
        try appendJsEscaped(gpa, out, f.name);
        try out.appendSlice(gpa, "\"]: e.currentTarget.checked ? \"true\" : \"\" })} />\n");
        return;
    }
    try out.appendSlice(gpa, "\" value={values[\"");
    try appendJsEscaped(gpa, out, f.name);
    try out.appendSlice(gpa, "\"] ?? \"\"} onInput={set(\"");
    try appendJsEscaped(gpa, out, f.name);
    try out.appendSlice(gpa, "\")} />\n");
}

/// Writes a converted view's `layouts/<viewStem>.shtml`, once (ruling S20).
///
/// The write moved out of `ensureView` because the two questions are
/// different: "what does this view convert to" is answered before any
/// decision is read (its findings ARE the question the operator answers),
/// while "does this target serve it" is answered after. A view converted for
/// a route that turned out `retained`/`blocked` stays in the cache unwritten,
/// and the next route rendering it -- if there is one, and if it needs a page
/// -- writes it then. Skipping the CONVERSION instead would lose the findings
/// that justify the decision and would strand any such later route.
///
/// Contract 1 (self-freeing): the joined path `writeFile` builds is freed
/// before returning; the bytes written are the cache's, not a new allocation.
fn materializeView(ctx: *Ctx, acc: *Acc, views: *ViewCache, index: usize) WriteError!void {
    const v = &views.items.items[index];
    if (v.written) return;
    try ctx.writeFile(v.artifact, v.bytes);
    // The islands go out with the page that references them, for the reason
    // `View.islands` gives: an island file in a target whose page was never
    // written is source nothing imports and nothing bundles.
    //
    // ONCE PER BINDING, not once per view. `buildBindings` binds each template
    // once, but `convert.zig` matches a binding by FINDING ID -- so a
    // `shared/_form` partial that two views render is inlined into both node
    // walks and yields the same `IslandSpec`, under the same island path,
    // to both `View`s. Writing it twice hit the exclusive-create guard and
    // aborted the whole migration (`PathAlreadyExists`) after both pages were
    // already on disk. The bytes are identical by construction -- the header
    // names the PARTIAL (`IslandSpec.source`), not the view it was inlined
    // into -- so the second write has nothing to add, and skipping it also
    // keeps `build.sh` from carrying the same `--island=` flag twice. The same
    // skip is also what makes the auth journey's ONE `AuthForm`/`AuthStatus`
    // work: two different views (`sessions#new`, `registrations#new`) mount
    // the same file, distinguished only by a prop, and `emitAuthForm` reads
    // only the journey -- never the region -- so the bytes cannot differ
    // between the two writes.
    try writeIslandFiles(ctx, acc, v.islands);
    v.written = true;
}

/// Writes each island file that is not on disk yet, and records it for
/// `build.sh` and `package.json`.
///
/// ONCE PER BINDING, not once per path, because those two questions come apart
/// the moment two names collide: a path-keyed skip drops a second, genuinely
/// different island on the floor and leaves its page pointing at the first
/// one's endpoint. `uniqueIslandPath` is what makes that impossible for the
/// per-region form islands, and the assertion is where that invariant is
/// stated -- if it ever regresses this aborts rather than shipping the wrong
/// form (and in a build with assertions off, `writeFile`'s exclusive-create
/// guard still fatals rather than silently skipping).
///
/// The auth journey's pair reaches the same conclusion from the other
/// direction, which is why it needs no de-collision of its own. Both of its
/// components are journey-level artifacts deliberately mounted from several
/// places under ONE path each -- that is the whole point of them -- so their
/// identity is the journey's rather than any one region's (`islandIdentity`,
/// and `JourneyScaffold.status_id` for why the two components need one key
/// each). "Same path" and "same island" therefore still answer alike, and the
/// assertion holds for them as it does for a shared `_form` partial.
///
/// The two families cannot collide with each other either, and the reason is
/// the NAMES, not the order the passes run in: `islandPath` always emits a
/// `components/forms/` prefix while the auth pair is flat under
/// `components/`, so no `uniqueIslandPath` candidate can ever be an auth
/// path.
///
/// Contract 2 (owned-result), inherited: what it appends to `acc` is owned by
/// `acc`.
fn writeIslandFiles(ctx: *Ctx, acc: *Acc, list: []const IslandFile) WriteError!void {
    for (list) |f| {
        const written = contains(acc.island_ids.items, f.finding_id);
        std.debug.assert(written == contains(acc.island_files.items, f.path));
        if (written) continue;
        try ctx.writeFile(f.path, f.bytes);
        try appendOwned(ctx.gpa, &acc.island_files, f.path);
        try acc.island_ids.append(ctx.gpa, f.finding_id);
    }
}

/// A deep copy of a string slice.
///
/// Contract 2 (owned-result): the returned slice AND every string in it are
/// fresh allocations the caller owns; release with `freeStrings`. On failure
/// the partial copy is released here and nothing escapes.
fn dupeStrings(gpa: Allocator, list: []const []const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (list) |s| try appendOwned(gpa, &out, s);
    return out.toOwnedSlice(gpa);
}

/// The kind named by the FIRST `<!-- rails:unmapped <kind> ... -->` in
/// `bytes`, or null. Ruling S6's detector: such a region is an open item that
/// carries no finding id, so nothing else in the pipeline can see it.
///
/// Contract 1 (self-freeing): the returned kind is the only allocation.
fn firstUnmappedKind(gpa: Allocator, bytes: []const u8) Allocator.Error!?[]const u8 {
    const marker = "<!-- rails:unmapped ";
    const at = std.mem.indexOf(u8, bytes, marker) orelse return null;
    const rest = bytes[at + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, " -") orelse rest.len;
    return try gpa.dupe(u8, rest[0..end]);
}

// ---- the content page ----------------------------------------------------

/// The `.smd`: frontmatter and nothing else. The view's markup lives in
/// `layouts/<viewStem>.shtml`, because SuperMD forbids raw HTML (spec,
/// "Conversion: what a route becomes").
///
/// Only `.title` and `.layout` are required by `Page`; `.date`/`.draft` are
/// deliberately omitted rather than stamped with a placeholder epoch, since
/// a Rails route carries neither and inventing one would put a fact in the
/// frontmatter that no source supports.
///
/// Contract 1 (self-freeing): all scratch is released; the returned bytes are
/// the only escaping allocation.
fn emitContentPage(ctx: *Ctx, r: route_mod.Route, v: View, view_path: []const u8) Allocator.Error![]u8 {
    const gpa = ctx.gpa;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "---\n");

    try out.appendSlice(gpa, ".title = \"");
    if (v.title) |t| {
        try appendZiggyEscaped(gpa, &out, t);
    } else if (r.controller != null and r.action != null) {
        // The spec's fallback. Two words rather than "Untitled": it names the
        // Rails action a reader can go read, which "Untitled" does not.
        try appendZiggyEscaped(gpa, &out, r.controller.?);
        try out.append(gpa, ' ');
        try appendZiggyEscaped(gpa, &out, r.action.?);
    } else {
        try appendZiggyEscaped(gpa, &out, r.path);
    }
    try out.appendSlice(gpa, "\",\n");

    if (v.description) |desc| {
        try out.appendSlice(gpa, ".description = \"");
        try appendZiggyEscaped(gpa, &out, desc);
        try out.appendSlice(gpa, "\",\n");
    }

    try out.appendSlice(gpa, ".layout = \"");
    try appendZiggyEscaped(gpa, &out, v.layout_value);
    try out.appendSlice(gpa, "\",\n");

    // Provenance, so `$page.custom.rails` can be inspected from a layout and
    // the mapping survives hand edits to either side (spec).
    try out.appendSlice(gpa, ".custom = {\n    .rails = {\n        .route = \"");
    try appendZiggyEscaped(gpa, &out, r.verb);
    try out.append(gpa, ' ');
    try appendZiggyEscaped(gpa, &out, r.path);
    try out.appendSlice(gpa, "\",\n        .controller = \"");
    try appendZiggyEscaped(gpa, &out, r.controller orelse "");
    try out.appendSlice(gpa, "\",\n        .action = \"");
    try appendZiggyEscaped(gpa, &out, r.action orelse "");
    try out.appendSlice(gpa, "\",\n        .source = \"");
    try appendZiggyEscaped(gpa, &out, view_path);
    try out.appendSlice(gpa, "\",\n    },\n},\n");

    try out.appendSlice(gpa, "---\n");
    return out.toOwnedSlice(gpa);
}

/// The escaping a Ziggy double-quoted string needs. Mirrors
/// `migrate.zig`'s `configEscape` (see the module doc on duplication):
/// the two quote characters plus the three whitespace escapes, because a raw
/// newline inside a Ziggy string is a parse error, not a line break.
///
/// Contract 2 (owned-result), inherited: grows the caller's buffer and
/// allocates nothing else.
fn appendZiggyEscaped(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) Allocator.Error!void {
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => try out.append(gpa, c),
    };
}

// ---- pass 3: the SPA scaffolds -------------------------------------------

/// One `.spa.tsx` per first path segment, listing every route under it an
/// operator answered `spa`.
///
/// One file per SEGMENT rather than per route because that is what a client
/// router is: `/posts/:id` and `/posts/:id/edit` are two routes of one SPA
/// mounted at `/posts`, not two SPAs.
fn writeSpas(ctx: *Ctx, acc: *Acc, list: []const SpaRoute) WriteError!void {
    const gpa = ctx.gpa;
    if (list.len == 0) return;

    const order = try gpa.alloc(usize, list.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, SpaSortCtx{ .list = list, .routes = ctx.in.discovery.routes }, spaLessThan);

    var i: usize = 0;
    while (i < order.len) {
        const segment = list[order[i]].segment;
        var j = i + 1;
        while (j < order.len and std.mem.eql(u8, list[order[j]].segment, segment)) j += 1;

        const path = try std.fmt.allocPrint(gpa, "spa/{s}.spa.tsx", .{segment});
        errdefer gpa.free(path);
        const source = try emitSpa(ctx, segment, list, order[i..j]);
        defer gpa.free(source);
        try ctx.writeFile(path, source);
        for (order[i..j]) |k| if (list[k].port_js != null) {
            acc.spa_uses_client = true;
            break;
        };

        for (order[i..j]) |k| {
            const oc = &acc.routes.items[list[k].outcome_index];
            // The copy is made BEFORE the grow: a `realloc` that succeeds
            // followed by a `dupe` that fails would leave the outcome holding
            // one uninitialised element that `freeResult` would then try to
            // free. Growing second means every element is always valid.
            const copy = try gpa.dupe(u8, path);
            errdefer gpa.free(copy);
            const artifacts = try gpa.realloc(oc.artifacts, oc.artifacts.len + 1);
            oc.artifacts = artifacts;
            artifacts[artifacts.len - 1] = copy;
            std.mem.sort([]const u8, artifacts, {}, lessThanStr);
            if (list[k].port_js != null) {
                const client_copy = try gpa.dupe(u8, client_lib_path);
                errdefer gpa.free(client_copy);
                const with_client_artifact = try gpa.realloc(oc.artifacts, oc.artifacts.len + 1);
                oc.artifacts = with_client_artifact;
                with_client_artifact[with_client_artifact.len - 1] = client_copy;
                std.mem.sort([]const u8, with_client_artifact, {}, lessThanStr);
            }
        }
        try acc.spa_files.append(gpa, path);
        i = j;
    }
}

const SpaSortCtx = struct { list: []const SpaRoute, routes: []const route_mod.Route };

/// `(segment, route path, verb)`: groups a segment's routes contiguously and
/// fixes their order inside the emitted file.
fn spaLessThan(c: SpaSortCtx, a: usize, b: usize) bool {
    switch (std.mem.order(u8, c.list[a].segment, c.list[b].segment)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    const ra = c.routes[c.list[a].route_index];
    const rb = c.routes[c.list[b].route_index];
    switch (std.mem.order(u8, ra.path, rb.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return std.mem.order(u8, ra.verb, rb.verb) == .lt;
}

/// Contract 1 (self-freeing): the returned source is the only escaping
/// allocation.
fn emitSpa(ctx: *Ctx, segment: []const u8, list: []const SpaRoute, group: []const usize) Allocator.Error![]u8 {
    const gpa = ctx.gpa;
    const routes_all = ctx.in.discovery.routes;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    for (group) |k| {
        const name = try componentName(gpa, routes_all[list[k].route_index], names.items);
        errdefer gpa.free(name);
        try names.append(gpa, name);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var heads: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (heads.items) |head| gpa.free(head);
        heads.deinit(gpa);
    }
    for (group) |k| {
        const route_index = list[k].route_index;
        if (route_index >= ctx.in.discovery.route_templates.len) continue;
        const layout = ctx.in.discovery.route_templates[route_index].layout orelse continue;
        const tpl = findTemplate(ctx.in.discovery.fragments, layout) orelse continue;
        for (tpl.nodes) |node| {
            if (node.text != null or node.kind != .asset or !std.mem.eql(u8, node.name orelse "", "stylesheet_link_tag")) continue;
            for (node.args) |literal| {
                const asset = resolve.assetFor(ctx.in.discovery.assets, "stylesheet_link_tag", literal) orelse continue;
                if (!asset.deterministic) continue;
                const target = try resolve.assetTargetPath(gpa, asset.source);
                defer gpa.free(target);
                const href = try std.fmt.allocPrint(gpa, "/{s}", .{target});
                errdefer gpa.free(href);
                if (contains(heads.items, href)) {
                    gpa.free(href);
                } else try heads.append(gpa, href);
            }
        }
    }
    std.mem.sort([]const u8, heads.items, {}, lessThanStr);

    var has_port = false;
    for (group) |k| if (list[k].port_js != null) {
        has_port = true;
        break;
    };

    try out.appendSlice(gpa, "// Generated by `zigapagos migrate --from rails`. Unported components below remain placeholders.\n");
    if (has_port) {
        try out.appendSlice(gpa, "import { Router, useParams, useEffect, useState } from \"@z/runtime\";\nimport { isZigbaseError } from \"@zigbase/client\";\nimport { zb } from \"../lib/zb\";\n\n");
    } else try out.appendSlice(gpa, "import { Router } from \"@z/runtime\";\n\n");
    try out.appendSlice(gpa, "export const spa = { base: \"/");
    try out.appendSlice(gpa, segment);
    try out.appendSlice(gpa, "\", head: [");
    for (heads.items, 0..) |href, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, "{ rel: \"stylesheet\", href: \"");
        try appendJsEscaped(gpa, &out, href);
        try out.appendSlice(gpa, "\" }");
    }
    try out.appendSlice(gpa, "] };\n\n");

    if (has_port) try out.appendSlice(gpa, port.esc_helper ++ "\n\n");

    for (group, names.items) |k, name| {
        const r = routes_all[list[k].route_index];
        if (list[k].port_js) |body_js| {
            try out.appendSlice(gpa, "function body");
            try out.appendSlice(gpa, name);
            try out.appendSlice(gpa, "(rec: any): string {\n  let h = \"\";\n");
            var body_lines = std.mem.splitScalar(u8, body_js, '\n');
            while (body_lines.next()) |line| {
                if (line.len == 0) continue;
                try out.appendSlice(gpa, "  ");
                try out.appendSlice(gpa, line);
                try out.append(gpa, '\n');
            }
            try out.appendSlice(gpa, "  return h;\n}\n\nfunction ");
            try out.appendSlice(gpa, name);
            try out.appendSlice(gpa, "() {\n  const params = useParams<{ ");
            try out.appendSlice(gpa, list[k].param.?);
            try out.appendSlice(gpa, ": string }>();\n  const [html, setHtml] = useState<string | null>(null);\n  const [error, setError] = useState<string | null>(null);\n  useEffect(() => {\n    zb.collection(\"");
            try appendJsEscaped(gpa, &out, list[k].collection.?);
            try out.appendSlice(gpa, "\").getOne(params.");
            try out.appendSlice(gpa, list[k].param.?);
            try out.appendSlice(gpa, ")\n      .then((rec) => setHtml(body");
            try out.appendSlice(gpa, name);
            try out.appendSlice(gpa, "(rec)))\n      .catch((err) => setError(isZigbaseError(err) ? err.message : String(err)));\n  }, [params.");
            try out.appendSlice(gpa, list[k].param.?);
            try out.appendSlice(gpa, "]);\n  if (error !== null) return <p>{\"Could not load ");
            try appendJsEscaped(gpa, &out, list[k].collection.?);
            try out.appendSlice(gpa, ": \" + error}</p>;\n  if (html === null) return <p>{\"Loading…\"}</p>;\n  return <div dangerouslySetInnerHTML={{ __html: html }} />;\n}\n\n");
            continue;
        }
        try out.appendSlice(gpa, "function ");
        try out.appendSlice(gpa, name);
        try out.appendSlice(gpa, "() {\n  return <p>{\"TODO: port ");
        // A JS string literal, not JSX text: a route path or controller name
        // is not markup, and `{`/`<` in one would otherwise be parsed as JSX.
        try appendJsEscaped(gpa, &out, r.verb);
        try out.append(gpa, ' ');
        try appendJsEscaped(gpa, &out, r.path);
        if (r.controller) |c| {
            try out.appendSlice(gpa, " (");
            try appendJsEscaped(gpa, &out, c);
            try out.append(gpa, '#');
            try appendJsEscaped(gpa, &out, r.action orelse "");
            try out.append(gpa, ')');
        }
        try out.appendSlice(gpa, "\"}</p>;\n}\n\n");
    }

    try out.appendSlice(gpa, "export const routes = [\n");
    for (group, names.items) |k, name| {
        const r = routes_all[list[k].route_index];
        const rest = spaRoutePath(r.path, segment);
        try out.appendSlice(gpa, "  { path: \"");
        try appendJsEscaped(gpa, &out, rest);
        try out.appendSlice(gpa, "\", component: ");
        try out.appendSlice(gpa, name);
        // `skeleton: false`: this stage knows the route SHAPE and nothing
        // about the data behind it, so there is nothing to prerender.
        //
        // `staticPaths` is emitted only for an entry whose OWN path is
        // dynamic. `runtime/src/router.ts:698` throws "staticPaths declared
        // on static route" otherwise -- and a static entry does occur here,
        // because the SPA is grouped by first segment: `/posts/:id` and
        // `/posts/new` can share one `.spa.tsx`, and the second one's entry
        // path (`/new`) has no param to enumerate.
        try out.appendSlice(gpa, ", skeleton: false as const");
        if (findings.isDynamicRoutePath(rest)) {
            try out.appendSlice(gpa, ", staticPaths: []");
        }
        try out.appendSlice(gpa, " },\n");
    }
    try out.appendSlice(gpa, "];\n\nexport default function App() {\n  return <Router base={spa.base} routes={routes} />;\n}\n");

    return out.toOwnedSlice(gpa);
}

/// The route path relative to the SPA's base: `/posts/:id` under `posts`
/// becomes `/:id`, and a route that IS the base becomes `/`.
fn spaRoutePath(route_path: []const u8, segment: []const u8) []const u8 {
    const prefix_len = 1 + segment.len;
    if (route_path.len <= prefix_len) return "/";
    return route_path[prefix_len..];
}

/// A JSX identifier for one route's placeholder component: `posts#show`
/// becomes `PostsShow`. Falls back to the path when the route names no
/// controller/action, and appends `_2`, `_3`, … on a collision within the
/// same file (two routes CAN share a controller#action pair).
///
/// Contract 1 (self-freeing): the returned name is the only allocation.
fn componentName(gpa: Allocator, r: route_mod.Route, taken: []const []const u8) Allocator.Error![]u8 {
    var base: std.ArrayListUnmanaged(u8) = .empty;
    defer base.deinit(gpa);
    if (r.controller) |c| {
        try appendPascal(gpa, &base, c);
        try appendPascal(gpa, &base, r.action orelse "");
    } else {
        try appendPascal(gpa, &base, r.path);
    }
    if (base.items.len == 0) try base.appendSlice(gpa, "Route");

    var candidate = try gpa.dupe(u8, base.items);
    errdefer gpa.free(candidate);
    var n: usize = 2;
    while (contains(taken, candidate)) {
        gpa.free(candidate);
        candidate = try std.fmt.allocPrint(gpa, "{s}_{d}", .{ base.items, n });
        n += 1;
    }
    return candidate;
}

fn contains(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// Appends `value` as a PascalCase identifier fragment: every run of
/// alphanumerics is capitalised, everything else (including a `:param`'s
/// colon) is a separator and is dropped. A leading digit is dropped too --
/// a JS identifier cannot start with one.
///
/// Contract 2 (owned-result), inherited: grows the caller's buffer and
/// allocates nothing else.
fn appendPascal(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) Allocator.Error!void {
    var start_of_word = true;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            start_of_word = true;
            continue;
        }
        if (out.items.len == 0 and std.ascii.isDigit(c)) continue;
        if (start_of_word) {
            try out.append(gpa, std.ascii.toUpper(c));
            start_of_word = false;
        } else {
            try out.append(gpa, c);
        }
    }
}

/// The escaping a JS double-quoted string literal needs, for the values the
/// generated `.spa.tsx` embeds.
///
/// Contract 2 (owned-result), inherited: grows the caller's buffer and
/// allocates nothing else.
fn appendJsEscaped(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) Allocator.Error!void {
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        else => try out.append(gpa, c),
    };
}

// ---- pass 4: the project files -------------------------------------------

/// Duplicated from `migrate.zig`'s `target_gitignore` / `target_tsconfig` --
/// see the module doc for why this file cannot import them.
const target_gitignore =
    \\node_modules/
    \\zig-out/
    \\.zigapagos-cache/
    \\
;

const target_tsconfig =
    \\{
    \\  "compilerOptions": {
    \\    "jsx": "react-jsx",
    \\    "jsxImportSource": "@z/runtime",
    \\    "module": "ESNext",
    \\    "moduleResolution": "bundler",
    \\    "target": "ESNext",
    \\    "strict": true,
    \\    "skipLibCheck": true,
    \\    "allowJs": true,
    \\    "allowImportingTsExtensions": true,
    \\    "noEmit": true
    \\  }
    \\}
    \\
;

/// Where the one ZigBase client every island imports lives, target-relative.
/// One file and not one per island: `createClient` owns an `AuthStore`, and
/// two clients in one page would be two sessions.
pub const client_lib_path = "lib/zb.ts";

/// The two auth-journey scaffolds, target-relative (#167 Stage 3, Task 5).
///
/// Flat under `components/` rather than beside the generated form islands in
/// `components/forms/`: these are not one-region conversions of one ERB
/// fragment, they are the whole journey's component pair, and every view in
/// the flow mounts the SAME file. One file each, for the same reason
/// `client_lib_path` is one file: `AuthForm` is mounted by both
/// `sessions#new` and `registrations#new`, distinguished only by its `mode`
/// prop, and two copies would be two components to keep in step by hand.
pub const auth_form_island_path = "components/AuthForm.island.tsx";
pub const auth_status_island_path = "components/AuthStatus.island.tsx";
pub const turbo_frame_island_path = "components/TurboFrame.island.tsx";
pub const turbo_stream_island_path = "components/TurboStream.island.tsx";

const stimulus_runtime =
    \\// Generated by `zigapagos migrate --from rails`.
    \\// Keep the action-token grammar in sync with `port.actionDescriptors`.
    \\export function targetsOf(root: HTMLElement, id: string, names: string[]) {
    \\  const out: Record<string, HTMLElement[]> = {};
    \\  for (const name of names) out[name] = Array.from(root.querySelectorAll<HTMLElement>(`[data-${id}-target~="${name}"]`));
    \\  return out;
    \\}
    \\
    \\export function valuesOf(root: HTMLElement, id: string, types: Record<string, string>) {
    \\  const owner = root.matches(`[data-controller~="${id}"]`) ? root : root.querySelector<HTMLElement>(`[data-controller~="${id}"]`);
    \\  const out: Record<string, unknown> = {};
    \\  for (const [name, type] of Object.entries(types)) {
    \\    const raw = owner?.getAttribute(`data-${id}-${name}-value`);
    \\    if (raw === null || raw === undefined) continue;
    \\    out[name] = type === "boolean" ? raw === "true" : type === "number" ? Number(raw) : type === "array" || type === "object" ? JSON.parse(raw) : raw;
    \\  }
    \\  return out;
    \\}
    \\
    \\export function classesOf(root: HTMLElement, id: string, names: string[]) {
    \\  const owner = root.matches(`[data-controller~="${id}"]`) ? root : root.querySelector<HTMLElement>(`[data-controller~="${id}"]`);
    \\  const out: Record<string, string> = {};
    \\  for (const name of names) {
    \\    const value = owner?.getAttribute(`data-${id}-${name}-class`);
    \\    if (value !== null && value !== undefined) out[name] = value;
    \\  }
    \\  return out;
    \\}
    \\
    \\export function bindActions(root: HTMLElement, id: string, handlers: Record<string, (event: Event) => void>) {
    \\  const removers: Array<() => void> = [];
    \\  for (const el of [root, ...root.querySelectorAll<HTMLElement>("[data-action]")]) {
    \\    for (const token of (el.getAttribute("data-action") ?? "").split(/\s+/)) {
    \\      const match = token.match(new RegExp(`^(?:(\\w[\\w:.-]*)->)?${id}#(\\w+)((?::\\w+)*)$`));
    \\      if (!match || !handlers[match[2]]) continue;
    \\      const event = match[1] ?? ({ A: "click", BUTTON: "click", FORM: "submit", INPUT: "input", SELECT: "change", TEXTAREA: "input" } as Record<string, string>)[el.tagName] ?? "click";
    \\      const options = match[3].split(":").filter(Boolean);
    \\      const wrapped = (e: Event) => { if (options.includes("prevent")) e.preventDefault(); if (options.includes("stop")) e.stopPropagation(); handlers[match[2]](e); };
    \\      el.addEventListener(event, wrapped);
    \\      removers.push(() => el.removeEventListener(event, wrapped));
    \\    }
    \\  }
    \\  return () => { for (const remove of removers) remove(); };
    \\}
    \\
;

fn emitFrameIsland(gpa: Allocator) Allocator.Error![]u8 {
    return gpa.dupe(u8,
        \\// Generated by `zigapagos migrate --from rails`.
        \\// The Rails application continues to serve `src`; this island replaces Turbo's browser-side frame navigation.
        \\import { useEffect, useState, type ComponentChildren } from "@z/runtime";
        \\
        \\export interface Props { id: string; src: string }
        \\
        \\export default function TurboFrame(props: Props & { children?: ComponentChildren }) {
        \\  const [html, setHtml] = useState<string | null>(null);
        \\  useEffect(() => {
        \\    fetch(props.src, { credentials: "same-origin", headers: { Accept: "text/html" } })
        \\      .then((response) => response.text())
        \\      .then((html) => new DOMParser().parseFromString(html, "text/html"))
        \\      .then((doc) => doc.getElementById(props.id) ?? doc.querySelector("main") ?? doc.body)
        \\      .then((el) => setHtml(el.innerHTML))
        \\      .catch(() => { setHtml(null); console.warn("zigapagos: turbo-frame " + props.id + " could not load " + props.src); });
        \\  }, [props.id, props.src]);
        \\  return <div id={props.id}>{html === null ? props.children : <div dangerouslySetInnerHTML={{ __html: html }} />}</div>;
        \\}
        \\
    );
}

fn emitStreamIsland(gpa: Allocator) Allocator.Error![]u8 {
    return gpa.dupe(u8,
        \\// Generated by `zigapagos migrate --from rails`.
        \\// ZigBase re-authorizes the subscription and every delivered record on the server.
        \\// This port dispatches portable stream facts; verify the receiving DOM renderer before claiming visual parity.
        \\import { useEffect, useRef, useState } from "@z/runtime";
        \\import type { RealtimeAction, RealtimeEvent } from "@zigbase/client/realtime";
        \\import { zb } from "../lib/zb";
        \\
        \\export type StreamAction = "append" | "prepend" | "replace" | "update" | "remove" | "before" | "after";
        \\export interface Props { stream: string; action: "subscribe" | StreamAction; target: string }
        \\export interface StreamDetail { stream: string; action: StreamAction; target: string; record: Record<string, unknown> }
        \\
        \\const actionFor = (action: Props["action"], event: RealtimeAction): StreamAction =>
        \\  action !== "subscribe" ? action : event === "create" ? "append" : event === "update" ? "replace" : "remove";
        \\
        \\export function dispatchStreamAction(root: HTMLElement, props: Props, event: RealtimeEvent) {
        \\  const detail: StreamDetail = { stream: props.stream, action: actionFor(props.action, event.action), target: props.target, record: event.record };
        \\  root.dispatchEvent(new CustomEvent<StreamDetail>("zigapagos:turbo-stream", { bubbles: true, detail }));
        \\}
        \\
        \\export default function TurboStream(props: Props) {
        \\  const root = useRef<HTMLSpanElement>(null);
        \\  const [error, setError] = useState("");
        \\  useEffect(() => {
        \\    let active = true;
        \\    let unsubscribe: (() => void) | undefined;
        \\    zb.realtime.subscribe(props.stream, (event) => {
        \\      if (active && root.current) dispatchStreamAction(root.current, props, event);
        \\    }).then((stop) => {
        \\      if (active) unsubscribe = stop; else stop();
        \\    }).catch((cause) => {
        \\      if (active) setError(cause instanceof Error ? cause.message : String(cause));
        \\    });
        \\    return () => { active = false; unsubscribe?.(); };
        \\  }, [props.stream, props.action, props.target]);
        \\  return <span ref={root} hidden data-stream={props.stream} data-realtime-error={error || undefined} />;
        \\}
        \\
    );
}

/// `lib/zb.ts`, byte for byte.
///
/// Assumption A1, verified against `~/nothlav/zigbase/clients/typescript`:
/// `createClient` and `LocalAuthStore` are what the package exports (there is
/// no `ZigBase` class), and `LocalAuthStore` is the store that actually
/// persists in a browser -- `CookieAuthStore` is a serializer the transport
/// never reads, since it sends `Authorization: Bearer` and no credentials.
/// The base URL is `""` so the built site talks to whatever origin serves it.
///
/// `auth_collection` fills `ClientOptions.authCollection`, which is what turns
/// on the client's own 401 refresh; it is set only when an auth journey is
/// bound (Stage 3 Task 5), because naming a collection no island authenticates
/// against would arm a refresh call that always fails.
///
/// The single writer of this file, so Task 5's auth scaffolds reuse it rather
/// than emitting a second, subtly different one.
///
/// Contract 1 (self-freeing): the formatted bytes are the only allocation and
/// they are released before returning -- nothing escapes, the written file is
/// the result.
fn writeClientLib(ctx: *Ctx, auth_collection: ?[]const u8, with_realtime: bool) WriteError!void {
    const gpa = ctx.gpa;
    const base = if (auth_collection) |c| try std.fmt.allocPrint(gpa,
        \\import {{ createClient, LocalAuthStore }} from "@zigbase/client";
        \\export const zb = createClient("", {{ authStore: new LocalAuthStore(), authCollection: "{s}", fetch: (input, init) => globalThis.fetch(input, init) }});
        \\
    , .{c}) else try gpa.dupe(u8,
        \\import { createClient, LocalAuthStore } from "@zigbase/client";
        \\export const zb = createClient("", { authStore: new LocalAuthStore(), fetch: (input, init) => globalThis.fetch(input, init) });
        \\
    );
    defer gpa.free(base);
    if (!with_realtime) return ctx.writeFile(client_lib_path, base);

    const realtime = if (auth_collection) |c| try std.fmt.allocPrint(gpa,
        \\import {{ createClient, LocalAuthStore }} from "@zigbase/client";
        \\import {{ withRealtime }} from "@zigbase/client/realtime";
        \\export const zb = withRealtime(createClient("", {{ authStore: new LocalAuthStore(), authCollection: "{s}", fetch: (input, init) => globalThis.fetch(input, init) }}));
        \\
    , .{c}) else try gpa.dupe(u8,
        \\import { createClient, LocalAuthStore } from "@zigbase/client";
        \\import { withRealtime } from "@zigbase/client/realtime";
        \\export const zb = withRealtime(createClient("", { authStore: new LocalAuthStore(), fetch: (input, init) => globalThis.fetch(input, init) }));
        \\
    );
    defer gpa.free(realtime);
    try ctx.writeFile(client_lib_path, realtime);
}

fn writeProjectFiles(ctx: *Ctx, acc: *Acc) WriteError!void {
    const gpa = ctx.gpa;

    const config = try emitConfig(gpa, ctx.in.app_name, acc.assets.items.len > 0);
    defer gpa.free(config);
    try ctx.writeFile("zigapagos.ziggy", config);

    // Sorted, not written-order: `build.sh`'s flag list is output, and output
    // is byte-identical for identical input (plan, Global Constraints).
    std.mem.sort([]const u8, acc.island_files.items, {}, lessThanStr);
    const build_sh = try emitBuildSh(gpa, acc.spa_files.items, acc.island_files.items);
    defer gpa.free(build_sh);
    try ctx.writeFile("build.sh", build_sh);

    try ctx.writeFile(".gitignore", target_gitignore);
    try ctx.writeFile("AGENTS.md", ctx.in.agents_md);
    try ctx.writeFile("CLAUDE.md", ctx.in.claude_md);

    const bound = acc.island_files.items.len > 0;
    var with_client = acc.spa_uses_client;
    var with_realtime = false;
    for (ctx.bindings.all) |binding| {
        if (!contains(acc.island_files.items, binding.island)) continue;
        switch (binding.kind) {
            .operation, .custom, .auth_signin, .auth_signup, .auth_logout, .data_list => with_client = true,
            .turbo_stream => {
                with_client = true;
                with_realtime = true;
            },
            .stimulus, .turbo_frame, .component, .@"inline", .drop => {},
        }
    }
    // #167 Stage 3 Task 5: `authCollection` arms the client's own 401
    // refresh, and it is set exactly when an auth scaffold reached the target
    // -- not merely when a journey was answered. Naming a collection nothing
    // in the site authenticates against would arm a refresh call that can
    // only ever fail.
    const auth_collection: ?[]const u8 = if (ctx.bindings.scaffold) |j|
        (if (contains(acc.island_files.items, auth_form_island_path) or
            contains(acc.island_files.items, auth_status_island_path)) j.collection else null)
    else
        null;
    if (with_client) try writeClientLib(ctx, auth_collection, with_realtime);
    var with_stimulus = false;
    for (acc.island_files.items) |path| if (std.mem.startsWith(u8, path, "components/stimulus/")) {
        with_stimulus = true;
        break;
    };
    if (with_stimulus) try ctx.writeFile("lib/stimulus.ts", stimulus_runtime);

    const component_sources = try collectComponentSources(gpa, ctx, acc.island_files.items);
    defer gpa.free(component_sources);
    var npm_compat: std.ArrayListUnmanaged([]const u8) = .empty;
    defer npm_compat.deinit(gpa);
    for (component_sources) |source| {
        const target_path = try copiedComponentPath(gpa, source.path);
        defer gpa.free(target_path);
        try ctx.writeFile(target_path, source.bytes);
        const imports = try port.reactImports(gpa, source.bytes);
        defer gpa.free(imports.list);
        for (imports.list) |imp| {
            if (!imp.relative and !port.isBridgeResolved(imp.spec)) try appendBorrowedUnique(gpa, &npm_compat, imp.spec);
        }
    }
    std.mem.sort([]const u8, npm_compat.items, {}, lessThanStr);
    if (component_sources.len > 0) {
        const bridge = try emitReactBridgeConfig(gpa, npm_compat.items);
        defer gpa.free(bridge);
        try ctx.writeFile("z-runtime.config.json", bridge);
    }

    // Only a SPA or an island needs a bundler at all: a pure content target
    // builds with the binary and nothing else, and emitting a `package.json`
    // that nothing installs would invite `bun install` into a project with no
    // JS.
    if (acc.spa_files.items.len > 0 or bound) {
        const pkg = try emitPackageCompat(gpa, ctx.in.app_name, runtimePath(ctx.in), with_client, npm_compat.items, ctx.in.discovery.npm_dependencies);
        defer gpa.free(pkg);
        try ctx.writeFile("package.json", pkg);
        try ctx.writeFile("tsconfig.json", target_tsconfig);
    }
}

fn appendBorrowedUnique(gpa: Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) Allocator.Error!void {
    if (!contains(list.items, value)) try list.append(gpa, value);
}

fn bindingById(bindings: []const convert.Binding, id: []const u8) ?convert.Binding {
    for (bindings) |binding| if (std.mem.eql(u8, binding.finding_id, id)) return binding;
    return null;
}

fn sourceByPath(sources: []const port.JsSource, path: []const u8) ?port.JsSource {
    for (sources) |source| if (std.mem.eql(u8, source.path, path)) return source;
    return null;
}

fn relativeJsSource(gpa: Allocator, sources: []const port.JsSource, importer: []const u8, spec: []const u8) Allocator.Error!?port.JsSource {
    const dir = std.fs.path.dirname(importer) orelse return null;
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(gpa);
    var base_it = std.mem.splitScalar(u8, dir, '/');
    while (base_it.next()) |part| if (part.len > 0) try parts.append(gpa, part);
    var spec_it = std.mem.splitScalar(u8, spec, '/');
    while (spec_it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len <= 2) return null;
            _ = parts.pop();
        } else try parts.append(gpa, part);
    }
    const joined = try std.mem.join(gpa, "/", parts.items);
    defer gpa.free(joined);
    for ([_][]const u8{ "", ".jsx", ".tsx", ".js", ".ts", "/index.jsx", "/index.tsx", "/index.js", "/index.ts" }) |suffix| {
        const candidate = try std.fmt.allocPrint(gpa, "{s}{s}", .{ joined, suffix });
        defer gpa.free(candidate);
        if (sourceByPath(sources, candidate)) |source| return source;
    }
    return null;
}

fn collectComponentSources(gpa: Allocator, ctx: *Ctx, written: []const []const u8) Allocator.Error![]port.JsSource {
    var queue: std.ArrayListUnmanaged(port.JsSource) = .empty;
    errdefer queue.deinit(gpa);
    for (ctx.in.discovery.fragments) |tpl| for (tpl.nodes) |node| {
        if (node.text != null or node.kind != .component_root) continue;
        const id = convert.findingIdFor(ctx.in.discovery.findings, tpl.path, node.line, node.col) orelse continue;
        const binding = bindingById(ctx.bindings.all, id) orelse continue;
        if (binding.kind != .component or !contains(written, binding.island)) continue;
        const source = componentSource(ctx.in.discovery.js_sources, node.name orelse "") orelse continue;
        var seen = false;
        for (queue.items) |have| if (std.mem.eql(u8, have.path, source.path)) {
            seen = true;
            break;
        };
        if (!seen) try queue.append(gpa, source);
    };
    var index: usize = 0;
    while (index < queue.items.len) : (index += 1) {
        const source = queue.items[index];
        const imports = try port.reactImports(gpa, source.bytes);
        defer gpa.free(imports.list);
        for (imports.list) |imp| {
            if (!imp.relative) continue;
            const child = (try relativeJsSource(gpa, ctx.in.discovery.js_sources, source.path, imp.spec)) orelse continue;
            var seen = false;
            for (queue.items) |have| if (std.mem.eql(u8, have.path, child.path)) {
                seen = true;
                break;
            };
            if (!seen) try queue.append(gpa, child);
        }
    }
    std.mem.sort(port.JsSource, queue.items, {}, struct {
        fn lessThan(_: void, a: port.JsSource, b: port.JsSource) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);
    return queue.toOwnedSlice(gpa);
}

fn emitReactBridgeConfig(gpa: Allocator, compat: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"islandImports\":{\"firstParty\":[],\"npmCompat\":[");
    for (compat, 0..) |name, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.append(gpa, '"');
        try appendJsEscaped(gpa, &out, name);
        try out.append(gpa, '"');
    }
    try out.appendSlice(gpa, "]},\"resolve\":{\"react\":\"@z/runtime/compat\",\"react-dom\":\"@z/runtime/compat\",\"react-dom/client\":\"@z/runtime/compat/client\",\"react/jsx-runtime\":\"@z/runtime/jsx-runtime\",\"react/jsx-dev-runtime\":\"@z/runtime/jsx-dev-runtime\"}}\n");
    return out.toOwnedSlice(gpa);
}

/// #179 option 1: the `file:` path a generated `package.json` points
/// `@z/runtime` at. `--runtime-path` wins over `ZIGAPAGOS_RUNTIME_DIR`
/// because a flag is an explicit answer and the variable is an ambient one.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn runtimePath(in: Input) ?[]const u8 {
    return in.runtime_path orelse in.runtime_dir_env;
}

/// Duplicated from `migrate.zig`'s `emitTargetConfig`, minus the Hexo-only
/// `url_path_prefix`: a Rails migration has no source for one.
/// `host_url` is a placeholder the operator edits -- Rails' own config knows
/// the production host, but this stage does not read it, and inventing one
/// would be worse than an obvious stand-in.
///
/// Contract 1 (self-freeing).
fn emitConfig(gpa: Allocator, app_name: []const u8, with_assets: bool) Allocator.Error![]u8 {
    var title: std.ArrayListUnmanaged(u8) = .empty;
    defer title.deinit(gpa);
    try appendZiggyEscaped(gpa, &title, app_name);
    return std.fmt.allocPrint(gpa,
        \\Site {{
        \\    .title = "{s}",
        \\    .host_url = "https://example.com",
        \\    .content_dir_path = "content",
        \\    .layouts_dir_path = "layouts",
        \\    .assets_dir_path = "assets",
        \\{s}}}
        \\
    , .{ title.items, if (with_assets) "    .static_assets = [\"**\"],\n" else "" });
}

/// Duplicated from `migrate.zig`'s `emitTargetBuildSh`, extended with one
/// `--spa=` per scaffolded SPA. The `bun install` line appears only when
/// there is a `package.json` for it to install.
///
/// Each `--spa=` carries its base: `--spa=spa/<seg>.spa.tsx|/<seg>`. The
/// two-part form is not decoration -- `src/spa.zig` skips BOTH of its
/// cross-checks on a spec with no declared base: the agreement check that the
/// file's own `export const spa.base` matches what the command line asked
/// for (`spa.zig:267`), and the overlap check that two SPAs are not mounted
/// inside one another (`findSpecViolation`, `spa.zig:611`). Since this file
/// generates both halves, restating the base is free and turns both checks
/// back on -- so a later hand edit to either side is caught at build time
/// rather than producing a site with two SPAs fighting over one prefix.
///
/// Contract 1 (self-freeing).
fn emitBuildSh(
    gpa: Allocator,
    spa_files: []const []const u8,
    island_files: []const []const u8,
) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\cd "$(dirname "$0")"
        \\
    );
    if (spa_files.len > 0 or island_files.len > 0) {
        try out.appendSlice(gpa, "bun install --frozen-lockfile 2>/dev/null || bun install\n");
    }
    try out.appendSlice(gpa, "exec \"${ZIGAPAGOS_BIN:-zigapagos}\" release --force --output=zig-out/site");
    for (spa_files) |f| {
        // SINGLE-QUOTED, and that is not a style choice. `|` is a pipeline
        // separator, so an unquoted `--spa=spa/posts.spa.tsx|/posts` makes
        // bash read the rest of the line as a second command named `/posts`:
        // exit 127, no argument ever reaching the binary, and a generated
        // project that cannot build at all. The line stays SYNTACTICALLY
        // valid -- `bash -n` is happy with it -- which is why only actually
        // running it catches this; see the replay test at the bottom of this
        // file. Every hand-written invocation in the repo quotes it the same
        // way (`examples/tsx-site/build.sh`, `site/build.sh`, `docs/spa.md`).
        //
        // Single quotes need no escaping analysis here: the whole value is a
        // path this file just built out of one route path segment
        // (`resolve.spaSegment`), so it can hold no quote to close them early.
        try out.appendSlice(gpa, " --spa='");
        try out.appendSlice(gpa, f);
        // The declared base, recovered from the file's own name: every path
        // in `spa_files` is `spa/<segment>.spa.tsx`, written by `writeSpas`
        // for a SPA whose `export const spa = { base: "/<segment>" }`. Same
        // string, one source.
        try out.appendSlice(gpa, "|/");
        try out.appendSlice(gpa, spaFileSegment(f));
        try out.append(gpa, '\'');
    }
    // `--island=` takes a bare path with no `|base` half, so it needs none of
    // the quoting the `--spa=` form does; single-quoted anyway, because the
    // one thing worse than an unquoted path is two conventions on one line.
    for (island_files) |f| {
        try out.appendSlice(gpa, " --island='");
        try out.appendSlice(gpa, f);
        try out.append(gpa, '\'');
    }
    try out.appendSlice(gpa, " \"$@\"\n");
    return out.toOwnedSlice(gpa);
}

/// Duplicated from `migrate.zig`'s `emitTargetPackage` + `targetProjectName`
/// + `runtimePathIsJsonSafe`. The one behavioural difference is the last of
/// those: `migrate.zig` asserts a JSON-safe runtime path, which is right for
/// a path it derived itself; here the path comes from a CLI flag, so an
/// unusable one falls back to the same visible placeholder an ABSENT path
/// gets, rather than tripping an assertion in a release build.
///
/// Contract 1 (self-freeing).
fn emitPackage(
    gpa: Allocator,
    app_name: []const u8,
    runtime_path: ?[]const u8,
    with_client: bool,
) Allocator.Error![]u8 {
    var name: std.ArrayListUnmanaged(u8) = .empty;
    defer name.deinit(gpa);
    for (app_name) |c| {
        try name.append(gpa, if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '_');
    }
    if (name.items.len == 0) try name.appendSlice(gpa, "migrated_site");
    if (std.ascii.isDigit(name.items[0])) name.items[0] = '_';

    const placeholder = "TODO-SET-RUNTIME-PATH";
    const path = if (runtime_path) |p| (if (jsonSafe(p)) p else placeholder) else placeholder;

    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "name": "{s}",
        \\  "private": true,
        \\  "type": "module",
        \\  "dependencies": {{ "@z/runtime": "file:{s}"{s} }}
        \\}}
        \\
    , .{
        name.items,
        path,
        // The version is PINNED, not a range: a generated project is a
        // snapshot of what this binary knows the client's API to be
        // (assumption A1), and a caret would let a later major silently
        // change `createClient`'s options under it.
        if (with_client) ", \"@zigbase/client\": \"" ++ zigbase_client_version ++ "\"" else "",
    });
}

fn emitPackageCompat(
    gpa: Allocator,
    app_name: []const u8,
    runtime_path: ?[]const u8,
    with_client: bool,
    compat: []const []const u8,
    dependencies: []const @import("integrations.zig").NpmDep,
) Allocator.Error![]u8 {
    const base = try emitPackage(gpa, app_name, runtime_path, with_client);
    defer gpa.free(base);
    if (compat.len == 0) return gpa.dupe(u8, base);
    const marker = " }\n}\n";
    const at = std.mem.lastIndexOf(u8, base, marker) orelse return gpa.dupe(u8, base);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, base[0..at]);
    for (compat) |name| {
        var version: ?[]const u8 = null;
        for (dependencies) |dep| if (std.mem.eql(u8, dep.name, name)) {
            version = dep.version;
            break;
        };
        if (version) |v| {
            try out.appendSlice(gpa, ", \"");
            try appendJsEscaped(gpa, &out, name);
            try out.appendSlice(gpa, "\": \"");
            try appendJsEscaped(gpa, &out, v);
            try out.append(gpa, '"');
        }
    }
    try out.appendSlice(gpa, base[at..]);
    return out.toOwnedSlice(gpa);
}

/// The `@zigbase/client` release the emitted islands are written against.
/// Matches `~/nothlav/zigbase/clients/typescript/package.json`.
const zigbase_client_version = "0.3.0";

/// `spa/posts.spa.tsx` -> `posts`. The inverse of the one place that builds
/// the name (`writeSpas`), kept next to its only caller so the two forms
/// cannot drift apart unnoticed. Contract 3 (caller-buffer): returns a
/// sub-slice of `path`.
fn spaFileSegment(path: []const u8) []const u8 {
    const prefix = "spa/";
    const suffix = ".spa.tsx";
    var s = path;
    if (std.mem.startsWith(u8, s, prefix)) s = s[prefix.len..];
    if (std.mem.endsWith(u8, s, suffix)) s = s[0 .. s.len - suffix.len];
    return s;
}

fn jsonSafe(value: []const u8) bool {
    for (value) |c| {
        if (c == '"' or c == '\\' or c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

/// Modelled on `manifest.zig`'s `emptyDiscovery`: `Discovery` declares no
/// field defaults on purpose, so a test helper spells every one out and a
/// newly-added escaping field forces a deliberate edit here.
fn emptyDiscovery() rails.Discovery {
    return .{
        .report = "",
        .integrity_blocker_count = 0,
        .route_count = 0,
        .route_mode = "none",
        .route_blocker = false,
        .severity_error_count = 0,
        .severity_warn_count = 0,
        .ruby = .{ .available = false },
        .route_templates = &.{},
        .templates = &.{},
        .assets = &.{},
        .version = .{},
        .routes = &.{},
        .classifications = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .fragments = &.{},
        .findings = &.{},
        .i18n_locale = null,
        .decisions = .empty,
        // #167 Stage 3: `ActionInfo.redirects` and the `before_action`
        // filters reach the scaffold through `Discovery`; empty here because
        // no test in this file has bound a backend endpoint yet.
        .actions = &.{},
        .before_actions = &.{},
        .skip_before_actions = &.{},
        .parents = &.{},
    };
}

fn tRoute(verb: []const u8, path: []const u8, controller: ?[]const u8, action: ?[]const u8, line: u64) route_mod.Route {
    return .{
        .verb = verb,
        .path = path,
        .controller = controller,
        .action = action,
        .name = null,
        .certain = true,
        .origin = .static_ast,
        .source = .{ .file = "config/routes.rb", .line = line },
    };
}

fn tVerdict(class: classify.Class) classify.Verdict {
    return .{ .class = class, .reason = "test", .candidates = &.{} };
}

fn tText(text: []const u8, line: u64) fragments.Node {
    return .{ .text = text, .kind = .unknown, .line = line, .col = 1, .output = false, .code = "", .name = null, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}

fn tNode(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8) fragments.Node {
    return .{ .text = null, .kind = kind, .line = line, .col = col, .output = false, .code = "", .name = name, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}

/// A block-opening node (`content_for :head do`): non-empty `code` and
/// `output == false` is what `convert.zig` reads as "this is a block".
fn tOpen(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8, code: []const u8) fragments.Node {
    var n = tNode(kind, line, col, name);
    n.code = code;
    return n;
}

fn tEnd(line: u64, col: u64) fragments.Node {
    var n = tNode(.block_end, line, col, null);
    n.code = "end";
    return n;
}

fn tTemplate(path: []const u8, nodes: []const fragments.Node) fragments.Template {
    return .{ .path = path, .nodes = @constCast(nodes), .error_message = null, .error_line = null, .unreadable = null };
}

/// The target path a test writes into: cwd-relative, like production's.
fn tmpTarget(gpa: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
}

fn readTarget(gpa: Allocator, tmp: *std.testing.TmpDir, relative: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(gpa, "out/{s}", .{relative});
    defer gpa.free(p);
    return tmp.dir.readFileAlloc(std.testing.io, p, gpa, .limited(1024 * 1024));
}

fn targetHas(tmp: *std.testing.TmpDir, relative: []const u8) bool {
    const gpa = testing.allocator;
    const p = std.fmt.allocPrint(gpa, "out/{s}", .{relative}) catch return false;
    defer gpa.free(p);
    tmp.dir.access(std.testing.io, p, .{}) catch return false;
    return true;
}

test "writeParityRunners pins fixed bytes, absence, and exclusive-create" {
    const gpa = testing.allocator;
    var empty = std.testing.tmpDir(.{});
    defer empty.cleanup();
    const empty_target = try tmpTarget(gpa, &empty);
    defer gpa.free(empty_target);
    var empty_error_path: ?[]const u8 = null;
    defer if (empty_error_path) |path| gpa.free(path);
    var empty_error: ?anyerror = null;
    try writeParityRunners(testing.io, gpa, empty_target, false, &empty_error_path, &empty_error);
    try testing.expect(!targetHas(&empty, parity_runner_path));
    try testing.expect(!targetHas(&empty, journey_runner_path));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var error_path: ?[]const u8 = null;
    defer if (error_path) |path| gpa.free(path);
    var error_cause: ?anyerror = null;
    try writeParityRunners(testing.io, gpa, target, true, &error_path, &error_cause);
    const parity = try readTarget(gpa, &tmp, parity_runner_path);
    defer gpa.free(parity);
    const journey = try readTarget(gpa, &tmp, journey_runner_path);
    defer gpa.free(journey);
    try testing.expectEqualStrings(parity_runner_ts, parity);
    try testing.expectEqualStrings(journey_runner_py, journey);
    try testing.expect(std.mem.indexOf(u8, parity, "MIGRATION.handoff.json") != null);
    try testing.expect(std.mem.indexOf(u8, journey, "MIGRATION.handoff.json") != null);
    // P4: null is an explicit "not statically knowable" marker, not a claim
    // that the target renderer must omit its own fallback title or heading.
    try testing.expect(std.mem.indexOf(u8, parity, "row.expect.title !== null") != null);
    try testing.expect(std.mem.indexOf(u8, parity, "row.expect.h1 !== null") != null);
    // Literal href facts are target bytes, including relative URLs, queries,
    // and fragments. Resolving them through URL.pathname would erase that
    // evidence and make a correct generated anchor fail parity.
    try testing.expect(std.mem.indexOf(u8, parity, "(m) => decodeHtml(m[1] ?? m[2] ?? m[3])") != null);
    try testing.expect(std.mem.indexOf(u8, parity, "new URL(decodeHtml") == null);
    // The mutation collection is the operation's target (`posts`), not the
    // auth collection (`users`). Authentication comes from the completed auth
    // phase instead of inventing a relation the OpenAPI document does not say.
    try testing.expect(std.mem.indexOf(u8, parity, "Array.from(clients.values()).find") != null);
    // Fetch rejects GET/HEAD requests carrying bodies. Denied endpoint rows
    // may describe either method, so the fixed runner must suppress both the
    // JSON body and its content type before it reaches the runtime.
    try testing.expect(std.mem.indexOf(u8, parity, "method !== \"GET\" && method !== \"HEAD\"") != null);
    try testing.expect(std.mem.indexOf(u8, parity, "body: carriesBody ? JSON.stringify(body) : undefined") != null);
    try testing.expect(std.mem.indexOf(u8, journey, "with page.expect_navigation") != null);
    try testing.expect(std.mem.indexOf(u8, journey, "consume_validation_console(errors)") != null);

    try testing.expectError(error.TargetWrite, writeParityRunners(testing.io, gpa, target, true, &error_path, &error_cause));
    try testing.expectEqual(error.PathAlreadyExists, error_cause.?);
    try testing.expect(std.mem.endsWith(u8, error_path.?, parity_runner_path));
}

test "writeParityRunners is leak-free under every allocation failure" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 20) return error.SweepNeverReachedSuccess;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(testing.allocator, &tmp);
        defer testing.allocator.free(target);
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var error_path: ?[]const u8 = null;
        defer if (error_path) |path| gpa.free(path);
        var error_cause: ?anyerror = null;
        if (writeParityRunners(testing.io, gpa, target, true, &error_path, &error_cause)) {
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
}

test "write: a static content route becomes a layout, a view and a content page" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.yield, 1, 13, null),
        tText("</body></html>", 1),
    };
    const view_nodes = [_]fragments.Node{tText("<h1>About us</h1>", 1)};
    const frags = [_]fragments.Template{
        tTemplate("app/views/layouts/marketing.html.erb", &layout_nodes),
        tTemplate("app/views/pages/about.html.erb", &view_nodes),
    };
    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = "app/views/layouts/marketing.html.erb" }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;

    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "agents\n",
        .claude_md = "claude\n",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 1), res.routes.len);
    try testing.expectEqual(Status.migrated, res.routes[0].status);
    try testing.expectEqual(@as(usize, 0), res.routes[0].open_finding_ids.len);
    try testing.expectEqual(@as(usize, 3), res.routes[0].artifacts.len);

    const page = try readTarget(gpa, &tmp, "content/about/index.smd");
    defer gpa.free(page);
    try testing.expectEqualStrings(
        \\---
        \\.title = "About us",
        \\.layout = "pages/about.shtml",
        \\.custom = {
        \\    .rails = {
        \\        .route = "GET /about",
        \\        .controller = "pages",
        \\        .action = "about",
        \\        .source = "app/views/pages/about.html.erb",
        \\    },
        \\},
        \\---
        \\
    , page);

    const view = try readTarget(gpa, &tmp, "layouts/pages/about.shtml");
    defer gpa.free(view);
    // The empty `<head id="head">` is not noise: a converted layout ALWAYS
    // declares `head` and `main` (ruling S9), and a `<super>` with no block
    // to fill it is a `MISSING TOP-LEVEL BLOCK` that stops the generated site
    // from building. So a view with nothing to put in the head still has to
    // say so.
    try testing.expectEqualStrings(
        \\<extend template="marketing.shtml">
        \\<head id="head"></head>
        \\<div id="main">
        \\<h1>About us</h1>
        \\</div>
        \\
    , view);

    try testing.expect(targetHas(&tmp, "layouts/templates/marketing.shtml"));

    // No assets copied, so no `.static_assets` line; no SPA, so no
    // `package.json` and no `bun install` in build.sh.
    const config = try readTarget(gpa, &tmp, "zigapagos.ziggy");
    defer gpa.free(config);
    try testing.expect(std.mem.indexOf(u8, config, ".title = \"Blog\"") != null);
    try testing.expect(std.mem.indexOf(u8, config, "static_assets") == null);
    const build_sh = try readTarget(gpa, &tmp, "build.sh");
    defer gpa.free(build_sh);
    try testing.expect(std.mem.indexOf(u8, build_sh, "bun install") == null);
    try testing.expect(std.mem.indexOf(u8, build_sh, "--spa=") == null);
    try testing.expect(!targetHas(&tmp, "package.json"));
    try testing.expect(targetHas(&tmp, "AGENTS.md"));
    try testing.expect(targetHas(&tmp, "CLAUDE.md"));
    try testing.expect(targetHas(&tmp, ".gitignore"));
    try testing.expect(err_path == null);
}

test "write: two routes rendering one view share its files and get their own pages" {
    // `root "pages#about"` alongside `get "/about"` is the fixture shape.
    // Writing `layouts/pages/about.shtml` twice would hit the exclusive-create
    // guard, so the dedupe is load-bearing, not an optimisation.
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const view_nodes = [_]fragments.Node{tText("<p>x</p>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{
        tRoute("GET", "/", "pages", "about", 1),
        tRoute("GET", "/about", "pages", "about", 2),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls, .layout = null },
        .{ .templates = &tpls, .layout = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 2), res.routes.len);
    for (res.routes) |o| try testing.expectEqual(Status.migrated, o.status);
    try testing.expect(targetHas(&tmp, "content/index.smd"));
    try testing.expect(targetHas(&tmp, "content/about/index.smd"));
    try testing.expect(targetHas(&tmp, "layouts/pages/about.shtml"));
}

test "write: a route whose view cannot be converted is acknowledged by a decision on that view's finding" {
    // The Haml route in `tests/migrate/rails-presentation`: the view is a real
    // file the inventory listed, but no fragment stream exists for it (the
    // templates op never scans an engine it cannot parse), so `ensureView`
    // refuses it. The route can never be `migrated` -- but ruling S18 gives
    // the view a `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` finding, and a decision
    // on it has to actually land, or `complete` is unreachable for any app
    // holding one Haml view.
    const gpa = testing.allocator;
    var rs = [_]route_mod.Route{tRoute("GET", "/posts/legacy", "posts", "legacy", 3)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/posts/legacy.html.haml"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .unsupported_templates = &[_]findings.UnsupportedTemplate{
            .{ .path = "app/views/posts/legacy.html.haml", .label = "Haml" },
        },
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    // Undecided: open, but carrying the id the operator has to answer.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
        try testing.expect(res.routes[0].decision_id == null);
        // Nothing was written: there is no converted view to write.
        try testing.expect(!targetHas(&tmp, "content/posts/legacy/index.smd"));
    }

    // Decided `blocked`.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "blocked",
            .rationale = "no Haml converter",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.blocked, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
    }
}

test "write: an undecided finding leaves the route open, and a blocked decision acknowledges it" {
    const gpa = testing.allocator;

    const view_nodes = [_]fragments.Node{
        tText("<p>", 1),
        tNode(.unknown, 1, 4, "number_to_currency"),
        tText("</p>", 1),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    // Undecided.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
        try testing.expect(res.routes[0].decision_id == null);
        // The page is still written: an open route is a page with a gap in
        // it, not an absent page.
        try testing.expect(targetHas(&tmp, "content/about/index.smd"));
    }

    // Decided `blocked`.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "blocked",
            .rationale = "needs a currency island",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.blocked, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
        // Acknowledged, not resolved: the finding is still listed.
        try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
    }

    // Decided `island` -- accepted, recorded, and still open.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "island",
            .rationale = "port it",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqualStrings("choice island deferred to Stage 4", res.routes[0].note.?);
    }
}

test "write: an unmapped region keeps the route open even with no finding ids" {
    // Ruling S6, and the discriminating case for it: a `form` block derives
    // NO Stage 1 finding, so `open_finding_ids` is empty and only the
    // converted bytes say the page is unfinished.
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const view_nodes = [_]fragments.Node{
        tNode(.form, 1, 1, null),
        tText("<input>", 2),
        tNode(.block_end, 3, 1, null),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/new.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tRoute("GET", "/new", "pages", "new", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/new.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 0), res.routes[0].open_finding_ids.len);
    try testing.expectEqual(Status.open, res.routes[0].status);
    try testing.expectEqualStrings("form: finding derivation drift", res.routes[0].note.?);
}

test "write: an acknowledged route writes no page and no view file (ruling S20)" {
    // `blocked` used to be a relabelling: the page was written before the
    // decision was read, so the built site served a blank `<main>` for a
    // route the handoff called blocked -- worse than a 404, because it looks
    // deliberate. The handoff row is the record; the target holds only what
    // the site serves.
    const gpa = testing.allocator;

    const view_nodes = [_]fragments.Node{
        tText("<p>", 1),
        tNode(.unknown, 1, 4, "number_to_currency"),
        tText("</p>", 1),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/help.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tRoute("GET", "/help", "pages", "help", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/help.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    // Undecided: the page and the view file ARE written. This half is the
    // discriminator -- without it the assertions below would pass just as
    // well against a converter that writes nothing at all.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expect(targetHas(&tmp, "content/help/index.smd"));
        try testing.expect(targetHas(&tmp, "layouts/pages/help.shtml"));
        try testing.expectEqual(@as(usize, 2), res.routes[0].artifacts.len);
    }

    // Decided `blocked`: neither file exists, and the row claims no artifact.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "blocked",
            .rationale = "no static equivalent",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.blocked, res.routes[0].status);
        try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
        try testing.expect(!targetHas(&tmp, "content/help/index.smd"));
        try testing.expect(!targetHas(&tmp, "layouts/pages/help.shtml"));
    }

    // Decided `retain`: the same, for the same reason -- the page stays on
    // Rails, so this target must not answer that URL either.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "retain",
            .rationale = "stays on Rails",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.retained, res.routes[0].status);
        try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
        try testing.expect(!targetHas(&tmp, "content/help/index.smd"));
        try testing.expect(!targetHas(&tmp, "layouts/pages/help.shtml"));
    }
}

test "write: a shared view is written once, by the first route that needs it (ruling S20)" {
    // The ViewCache is keyed by (view, layout) and a view serves several
    // routes, so S20's skip has to be "do not write YET", not "do not
    // convert": the file belongs to the first route that actually needs it.
    // Constructed directly here because the two routes cannot disagree
    // through the decisions file -- routes sharing a view under one layout
    // have identical `open_finding_ids`, so one answer settles both -- and a
    // future finding that is per-route rather than per-template would make
    // this reachable without touching this file.
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const view_nodes = [_]fragments.Node{tText("<h1>Shared</h1>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{
        tRoute("GET", "/", "pages", "about", 1),
        tRoute("GET", "/about", "pages", "about", 2),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls, .layout = null },
        .{ .templates = &tpls, .layout = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // Two routes, two pages, ONE view file -- written once, by whichever
    // route got there first, and never re-written (the exclusive-create guard
    // would have turned a second write into `error.TargetWrite`).
    for (res.routes) |o| try testing.expectEqual(Status.migrated, o.status);
    try testing.expect(targetHas(&tmp, "content/index.smd"));
    try testing.expect(targetHas(&tmp, "content/about/index.smd"));
    try testing.expect(targetHas(&tmp, "layouts/pages/about.shtml"));
}

test "write: an unbound local is answerable and participates in route acknowledgement" {
    // Issue #181: the helper and the standalone local are now two ordinary
    // findings. With neither answered the route stays open; ruling S19 still
    // lets a retain answer settle the whole Rails-owned route.
    const gpa = testing.allocator;

    const view_nodes = [_]fragments.Node{
        tText("<p>", 1),
        tNode(.unknown, 1, 4, "number_to_currency"),
        // No `locals` at a view's render site, so this one cannot be
        // substituted and derives RAILS_LOCAL_UNBOUND.
        tNode(.local, 1, 30, "m"),
        tText("</p>", 1),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/new.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tRoute("GET", "/new", "pages", "new", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/new.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 2), finding_list.len);
    var local_id: ?[]const u8 = null;
    for (finding_list) |finding| {
        if (std.mem.eql(u8, finding.code, findings.code_local_unbound)) local_id = finding.id;
    }
    try testing.expect(local_id != null);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    // Undecided: both named questions keep the route open.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqual(@as(usize, 2), res.routes[0].open_finding_ids.len);
    }

    // Answered `retain`: retained by the route-level acknowledgement rule.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "retain",
            .rationale = "stays on Rails for now",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.retained, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
        try testing.expect(res.routes[0].note == null or std.mem.indexOf(u8, res.routes[0].note.?, "unmapped") == null);
    }

    // Answered `island`: still open (the helper choice is deferred), and the
    // local remains independently addressable.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var deferred = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "island",
            .rationale = "a currency island, later",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &deferred, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expect(std.mem.indexOf(u8, res.routes[0].note.?, "choice island deferred") != null);
        try testing.expect(contains(res.routes[0].open_finding_ids, local_id.?));
    }
}

test "write: all issue 181 conditional gaps are named and can block the route" {
    const gpa = testing.allocator;

    const view_nodes = [_]fragments.Node{
        tNode(.local, 1, 4, "stray"),
        tNode(.render_partial, 2, 4, "shared/ghost"),
        tNode(.route_helper, 3, 4, "post"),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{
        tRoute("GET", "/about", "pages", "about", 2),
        tRoute("GET", "/posts/:id", "posts", "show", 3),
    };
    rs[0].name = "about";
    rs[1].name = "post";
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.backend) };
    var about_templates = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &about_templates, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    const route_names = [_][]const u8{ "about", "post" };
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer findings.free(gpa, finding_list);

    var issue_ids: [3][]const u8 = undefined;
    var issue_count: usize = 0;
    for (finding_list) |finding| {
        if (!std.mem.eql(u8, finding.code, findings.code_local_unbound) and
            !std.mem.eql(u8, finding.code, findings.code_partial_unresolved) and
            !std.mem.eql(u8, finding.code, findings.code_route_helper_unresolved)) continue;
        issue_ids[issue_count] = finding.id;
        issue_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), issue_count);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    // Unanswered: the content route exposes all three stable ids and no
    // converter-gap footnote.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqual(@as(usize, 3), res.routes[0].open_finding_ids.len);
        for (issue_ids) |id| try testing.expect(contains(res.routes[0].open_finding_ids, id));
        try testing.expect(res.routes[0].note == null or std.mem.indexOf(u8, res.routes[0].note.?, "converter gap") == null);
    }

    // Every placeholder is independently answerable. Blocking those answers
    // blocks the route and emits no target page.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided: [3]decisions.Decision = undefined;
        for (issue_ids, 0..) |id, i| decided[i] = .{ .id = id, .choice = "blocked", .rationale = "requires manual migration", .artifact = null };
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.blocked, res.routes[0].status);
        try testing.expect(!targetHas(&tmp, "content/about/index.smd"));
    }
}

test "write: a dynamic route is open until a spa decision scaffolds one .spa.tsx per segment" {
    const gpa = testing.allocator;

    var rs = [_]route_mod.Route{
        tRoute("GET", "/posts/:id", "posts", "show", 3),
        tRoute("GET", "/posts/:id/edit", "posts", "edit", 3),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    // Undecided.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        for (res.routes) |o| {
            try testing.expectEqual(Status.open, o.status);
            try testing.expectEqualStrings(finding_list[0].id, o.open_finding_ids[0]);
        }
        try testing.expectEqual(@as(usize, 0), res.spa_files.len);
    }

    // Decided `spa`: ONE file, both routes in it, both migrated.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "spa",
            .rationale = "client-routed",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = "../runtime",
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);

        try testing.expectEqual(@as(usize, 1), res.spa_files.len);
        try testing.expectEqualStrings("spa/posts.spa.tsx", res.spa_files[0]);
        for (res.routes) |o| {
            try testing.expectEqual(Status.migrated, o.status);
            try testing.expectEqual(@as(usize, 1), o.artifacts.len);
            try testing.expectEqualStrings("spa/posts.spa.tsx", o.artifacts[0]);
        }

        const spa_src = try readTarget(gpa, &tmp, "spa/posts.spa.tsx");
        defer gpa.free(spa_src);
        try testing.expectEqualStrings(
            \\// Generated by `zigapagos migrate --from rails`. Unported components below remain placeholders.
            \\import { Router } from "@z/runtime";
            \\
            \\export const spa = { base: "/posts", head: [] };
            \\
            \\function PostsShow() {
            \\  return <p>{"TODO: port GET /posts/:id (posts#show)"}</p>;
            \\}
            \\
            \\function PostsEdit() {
            \\  return <p>{"TODO: port GET /posts/:id/edit (posts#edit)"}</p>;
            \\}
            \\
            \\export const routes = [
            \\  { path: "/:id", component: PostsShow, skeleton: false as const, staticPaths: [] },
            \\  { path: "/:id/edit", component: PostsEdit, skeleton: false as const, staticPaths: [] },
            \\];
            \\
            \\export default function App() {
            \\  return <Router base={spa.base} routes={routes} />;
            \\}
            \\
        , spa_src);

        const build_sh = try readTarget(gpa, &tmp, "build.sh");
        defer gpa.free(build_sh);
        try testing.expectEqualStrings(
            \\#!/usr/bin/env bash
            \\set -euo pipefail
            \\cd "$(dirname "$0")"
            \\bun install --frozen-lockfile 2>/dev/null || bun install
            \\exec "${ZIGAPAGOS_BIN:-zigapagos}" release --force --output=zig-out/site --spa='spa/posts.spa.tsx|/posts' "$@"
            \\
        , build_sh);

        const pkg = try readTarget(gpa, &tmp, "package.json");
        defer gpa.free(pkg);
        try testing.expect(std.mem.indexOf(u8, pkg, "\"file:../runtime\"") != null);
        try testing.expect(targetHas(&tmp, "tsconfig.json"));
    }
}

test "write: backend and redirect routes produce no page, and a redirect is reported" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rs = [_]route_mod.Route{
        tRoute("POST", "/posts", "posts", "create", 3),
        tRoute("GET", "/posts/old", "posts", "old", 5),
    };
    var vs = [_]classify.Verdict{ tVerdict(.backend), tVerdict(.redirect) };
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // Sorted by path: `/posts` then `/posts/old`.
    try testing.expectEqual(Status.backend, res.routes[0].status);
    try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
    try testing.expectEqual(Status.redirect, res.routes[1].status);
    try testing.expectEqual(@as(usize, 1), res.redirects.len);
    try testing.expectEqualStrings("/posts/old", res.redirects[0].from);
    try testing.expect(res.redirects[0].to == null);
    // The redirect route carries the finding an operator acknowledges it by.
    try testing.expectEqualStrings(
        "RAILS_REDIRECT_HOST_CONFIG.config/routes%2Erb.L5",
        res.routes[1].open_finding_ids[0],
    );
}

test "write: a deterministic asset is copied, and the config then declares static_assets" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var img_dir = try tmp.dir.createDirPathOpen(std.testing.io, "app/assets/images", .{});
    img_dir.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/assets/images/logo.png", .data = "png bytes" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "robots.txt", .data = "User-agent: *\n" });

    var asset_list = [_]asset_mod.Asset{
        .{ .source = "app/assets/images/logo.png", .public_url = "/assets/logo-abc.png", .pipeline = .propshaft, .deterministic = true },
        // `public/`: no pipeline, deterministic by construction. The fixture
        // file above sits at the tmp root because `assetTargetPath` strips
        // the `public/` prefix -- so the SOURCE read uses the recorded path.
        .{ .source = "robots.txt", .public_url = "/robots.txt", .pipeline = null, .deterministic = true },
        // Not deterministic and pipeline known: discovery could not place it,
        // so it is not copied.
        .{ .source = "app/assets/images/ghost.png", .public_url = null, .pipeline = .propshaft, .deterministic = false },
    };
    var d = emptyDiscovery();
    d.assets = &asset_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 2), res.assets.len);
    try testing.expectEqualStrings("app/assets/images/logo.png", res.assets[0].source);
    try testing.expectEqualStrings("/assets/logo-abc.png", res.assets[0].rails_url.?);
    try testing.expectEqualStrings("/images/logo.png", res.assets[0].target_url);
    try testing.expectEqualStrings("robots.txt", res.assets[1].source);
    try testing.expectEqualStrings("/robots.txt", res.assets[1].target_url);

    const copied = try readTarget(gpa, &tmp, "assets/images/logo.png");
    defer gpa.free(copied);
    try testing.expectEqualStrings("png bytes", copied);
    try testing.expect(!targetHas(&tmp, "assets/images/ghost.png"));

    const config = try readTarget(gpa, &tmp, "zigapagos.ziggy");
    defer gpa.free(config);
    try testing.expect(std.mem.indexOf(u8, config, ".static_assets = [\"**\"],") != null);
}

test "write: the compiled pipeline output under public/assets is never copied (ruling S17)" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var man_dir = try tmp.dir.createDirPathOpen(std.testing.io, "public/assets", .{});
    man_dir.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "public/assets/.manifest.json", .data = "{}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "public/assets/logo-abc123.png", .data = "digested png" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "robots.txt", .data = "User-agent: *\n" });

    var asset_list = [_]asset_mod.Asset{
        // Both of these are real files the inventory lists and `assets.scan`
        // places deterministically -- they are served by the Rails app. They
        // are still build OUTPUT: the digested copy duplicates an
        // `app/assets/` source that is copied on its own, and the manifest is
        // the pipeline's bookkeeping. Copying either would ship
        // `assets/assets/...` in the target.
        .{ .source = "public/assets/.manifest.json", .public_url = "/assets/.manifest.json", .pipeline = null, .deterministic = true },
        .{ .source = "public/assets/logo-abc123.png", .public_url = "/assets/logo-abc123.png", .pipeline = null, .deterministic = true },
        .{ .source = "robots.txt", .public_url = "/robots.txt", .pipeline = null, .deterministic = true },
    };
    var d = emptyDiscovery();
    d.assets = &asset_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 1), res.assets.len);
    try testing.expectEqualStrings("robots.txt", res.assets[0].source);
    try testing.expect(!targetHas(&tmp, "assets/assets/.manifest.json"));
    try testing.expect(!targetHas(&tmp, "assets/assets/logo-abc123.png"));
    try testing.expect(targetHas(&tmp, "assets/robots.txt"));
}

test "write: an asset the source cannot read is SourceRead, naming the source path" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var asset_list = [_]asset_mod.Asset{
        .{ .source = "public/gone.png", .public_url = "/gone.png", .pipeline = null, .deterministic = true },
    };
    var d = emptyDiscovery();
    d.assets = &asset_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    try testing.expectError(error.SourceRead, write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause));
    try testing.expectEqualStrings("public/gone.png", err_path.?);
}

test "write: a file already in the target is TargetWrite, naming it -- never an overwrite" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_dir = try tmp.dir.createDirPathOpen(std.testing.io, "out", .{});
    out_dir.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "out/zigapagos.ziggy", .data = "hand edited\n" });

    var d = emptyDiscovery();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    try testing.expectError(error.TargetWrite, write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause));
    try testing.expect(std.mem.endsWith(u8, err_path.?, "out/zigapagos.ziggy"));

    // The pre-existing bytes are untouched.
    const kept = try readTarget(gpa, &tmp, "zigapagos.ziggy");
    defer gpa.free(kept);
    try testing.expectEqualStrings("hand edited\n", kept);
}

test "write: two runs of the identical input produce byte-identical trees" {
    const gpa = testing.allocator;

    const layout_nodes = [_]fragments.Node{ tText("<html>", 1), tNode(.yield, 1, 7, null), tText("</html>", 1) };
    const a_nodes = [_]fragments.Node{tText("<h1>A</h1>", 1)};
    const b_nodes = [_]fragments.Node{tText("<h1>B</h1>", 1)};
    const frags = [_]fragments.Template{
        tTemplate("app/views/layouts/application.html.erb", &layout_nodes),
        tTemplate("app/views/pages/a.html.erb", &a_nodes),
        tTemplate("app/views/pages/b.html.erb", &b_nodes),
    };
    var a_tpls = [_][]const u8{"app/views/pages/a.html.erb"};
    var b_tpls = [_][]const u8{"app/views/pages/b.html.erb"};

    // The two runs see the SAME routes in OPPOSITE order: nothing about the
    // emitted tree may depend on the sidecar's emission order.
    var forward = [_]route_mod.Route{
        tRoute("GET", "/a", "pages", "a", 1),
        tRoute("GET", "/b", "pages", "b", 2),
    };
    var reverse = [_]route_mod.Route{
        tRoute("GET", "/b", "pages", "b", 2),
        tRoute("GET", "/a", "pages", "a", 1),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var forward_rts = [_]rails.RouteTemplates{
        .{ .templates = &a_tpls, .layout = "app/views/layouts/application.html.erb" },
        .{ .templates = &b_tpls, .layout = "app/views/layouts/application.html.erb" },
    };
    var reverse_rts = [_]rails.RouteTemplates{
        .{ .templates = &b_tpls, .layout = "app/views/layouts/application.html.erb" },
        .{ .templates = &a_tpls, .layout = "app/views/layouts/application.html.erb" },
    };

    var first: ?[]u8 = null;
    defer if (first) |f| gpa.free(f);

    for ([_]bool{ true, false }) |is_forward| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var d = emptyDiscovery();
        d.routes = if (is_forward) &forward else &reverse;
        d.classifications = &vs;
        d.route_templates = if (is_forward) &forward_rts else &reverse_rts;
        d.fragments = @constCast(&frags);

        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);

        // The outcome list is in this file's own route order, not the input's,
        // so `route_index` is what differs between the runs -- the STATUSES
        // and artifacts must not.
        try testing.expectEqual(@as(usize, 2), res.routes.len);
        for (res.routes) |o| try testing.expectEqual(Status.migrated, o.status);

        const digest = try treeDigest(gpa, &tmp);
        if (first) |f| {
            try testing.expectEqualStrings(f, digest);
            gpa.free(digest);
        } else {
            first = digest;
        }
    }
}

/// Every target file's path and bytes, path-sorted: a whole-tree comparison
/// in one string, so a determinism failure names the file that differs.
fn treeDigest(gpa: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    var dir = try tmp.dir.openDir(std.testing.io, "out", .{ .iterate = true });
    defer dir.close(std.testing.io);

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        try paths.append(gpa, try gpa.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanStr);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (paths.items) |p| {
        try out.appendSlice(gpa, p);
        try out.append(gpa, '\n');
        const bytes = try dir.readFileAlloc(std.testing.io, p, gpa, .limited(1024 * 1024));
        defer gpa.free(bytes);
        try out.appendSlice(gpa, bytes);
        try out.appendSlice(gpa, "\n---\n");
    }
    return out.toOwnedSlice(gpa);
}

test "write: every allocation failure is clean -- no leaks on any OOM path" {
    // The sweep runs the whole `write` under a FailingAllocator that fails at
    // index 0, 1, 2, ... in turn. Any missing `errdefer` shows up as a leak
    // report from `std.testing.allocator` underneath it.
    const gpa = testing.allocator;

    const view_nodes = [_]fragments.Node{tText("<h1>T</h1>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/pages/a.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{
        tRoute("GET", "/a", "pages", "a", 1),
        tRoute("GET", "/p/:id", "posts", "show", 2),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var a_tpls = [_][]const u8{"app/views/pages/a.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &a_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    var asset_list = [_]asset_mod.Asset{
        .{ .source = "robots.txt", .public_url = "/robots.txt", .pipeline = null, .deterministic = true },
    };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.assets = &asset_list;

    // A `spa` decision so the sweep also covers pass 3 (the `.spa.tsx`, the
    // `package.json`, and the artifact-list grow on an already-built
    // outcome). Built with the REAL allocator: it is the test's own input,
    // not part of what is being swept.
    const spa_id = try findings.routeFindingId(gpa, findings.code_route_dynamic_segment, 2);
    defer gpa.free(spa_id);
    var decided = [_]decisions.Decision{.{
        .id = spa_id,
        .choice = "spa",
        .rationale = "client-routed",
        .artifact = null,
    }};

    var fail_index: usize = 0;
    while (fail_index < 400) : (fail_index += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "robots.txt", .data = "ok\n" });

        // The target path is built with the real allocator: it is the test's
        // own scaffolding, not part of what is being swept.
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);

        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| fa.free(p);
        var err_cause: ?anyerror = null;

        if (write(std.testing.io, fa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = "../runtime",
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause)) |res| {
            freeResult(fa, res);
            break; // past the last allocation: the sweep is complete.
        } else |err| switch (err) {
            error.OutOfMemory => {},
            // A partially-written tree from a previous OOM can make the next
            // exclusive-create collide; that is the guard doing its job, not
            // a leak, and the tmp dir is fresh each iteration anyway.
            error.TargetWrite, error.SourceRead => {},
        }
    }
    try testing.expect(fail_index < 400);
}

// ---- rulings S7/S9: the layout/view block interface ----------------------
//
// SuperHTML fatals in BOTH directions -- a block with no matching `<super>`
// is an `UNBOUND TOP-LEVEL BLOCK`, a `<super>` with no matching block is a
// `MISSING TOP-LEVEL BLOCK`. `scaffold.zig`'s only job here is to hand the
// view its layout's `block_ids`; these two tests pin that it does, from the
// outside, on the bytes that reach the target tree.

/// One `GET /about` route rendering `app/views/pages/about.html.erb` under
/// `app/views/layouts/application.html.erb`, converted into a fresh tmp
/// target. Returns the two written `.shtml`s plus the route's outcome note.
const Pair = struct {
    layout: []u8,
    view: []u8,
    status: Status,
    note: ?[]u8,

    fn deinit(self: *Pair, gpa: Allocator) void {
        gpa.free(self.layout);
        gpa.free(self.view);
        if (self.note) |n| gpa.free(n);
    }
};

fn scaffoldPair(
    gpa: Allocator,
    layout_nodes: []const fragments.Node,
    view_nodes: []const fragments.Node,
) !Pair {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const frags = [_]fragments.Template{
        tTemplate("app/views/layouts/application.html.erb", layout_nodes),
        tTemplate("app/views/pages/about.html.erb", view_nodes),
    };
    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = "app/views/layouts/application.html.erb" }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const layout = try readTarget(gpa, &tmp, "layouts/templates/application.shtml");
    errdefer gpa.free(layout);
    const view = try readTarget(gpa, &tmp, "layouts/pages/about.shtml");
    errdefer gpa.free(view);
    const note = if (res.routes[0].note) |n| try gpa.dupe(u8, n) else null;
    return .{ .layout = layout, .view = view, .status = res.routes[0].status, .note = note };
}

test "write: a layout's named yield becomes a block the view fills, empty when it has none" {
    const gpa = testing.allocator;
    // (a) `yield :sidebar` puts a third `<super>` in the layout. The view has
    // no `content_for :sidebar`, so it must still emit an EMPTY
    // `<div id="sidebar">` -- a `<super>` nothing fills is a
    // `MISSING TOP-LEVEL BLOCK` and the generated site would not build. The
    // scaffolder's whole contribution is passing the layout's `block_ids`
    // down; without it the view emits only `head`/`main`.
    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.yield, 1, 13, null),
        tText("<aside>", 2),
        tNode(.yield_named, 2, 8, "sidebar"),
        tText("</aside></body></html>", 2),
    };
    const view_nodes = [_]fragments.Node{tText("<h1>About</h1>", 1)};

    var pair = try scaffoldPair(gpa, &layout_nodes, &view_nodes);
    defer pair.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, pair.layout, "id=\"sidebar\"") != null);
    try testing.expect(std.mem.indexOf(u8, pair.view, "<div id=\"sidebar\"></div>") != null);
    try testing.expect(std.mem.indexOf(u8, pair.view, "<div id=\"main\">") != null);
    try testing.expect(std.mem.indexOf(u8, pair.view, "<h1>About</h1>") != null);
    // An empty block it had nothing to put in is not a defect: nothing was
    // lost, so the route is finished.
    try testing.expectEqual(Status.migrated, pair.status);
    try testing.expect(pair.note == null);
}

test "write: a content_for the layout does not declare is dropped, and the route says so" {
    const gpa = testing.allocator;
    // (b) The mirror image. The layout declares only `head`/`main`, so a
    // view's `content_for :sidebar` has no `<super>` to fill -- emitting it
    // would be an `UNBOUND TOP-LEVEL BLOCK`. `convert.zig` drops it and
    // reports the drop; this file folds `Output.dropped` into the route's
    // note, which is the only place an operator ever learns what went
    // missing.
    //
    // Ruling S15: this drop is NOT informational. `<nav>links</nav>` is
    // markup the author wrote and the target does not have -- unlike a
    // `csrf_meta_tags` drop, which removes a construct with a defined
    // conversion and loses nothing. So the route is `open`, not `migrated`.
    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.yield, 1, 13, null),
        tText("</body></html>", 1),
    };
    const view_nodes = [_]fragments.Node{
        tOpen(.content_for, 1, 1, "sidebar", "content_for :sidebar do"),
        tText("<nav>links</nav>", 1),
        tEnd(1, 40),
        tText("<h1>About</h1>", 2),
    };

    var pair = try scaffoldPair(gpa, &layout_nodes, &view_nodes);
    defer pair.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, pair.layout, "id=\"sidebar\"") == null);
    try testing.expect(std.mem.indexOf(u8, pair.view, "id=\"sidebar\"") == null);
    try testing.expect(std.mem.indexOf(u8, pair.view, "links") == null);
    // The loss is reported, not silent -- and it is reported as a REASON,
    // which is what keeps a human looking at this route.
    try testing.expect(pair.note != null);
    try testing.expect(std.mem.indexOf(u8, pair.note.?, "sidebar") != null);
    try testing.expectEqual(Status.open, pair.status);
}

test "write: a csrf drop stays informational -- the route is still migrated" {
    const gpa = testing.allocator;
    // The other half of ruling S15, and the case that makes it a distinction
    // rather than a blanket rule. `csrf_meta_tags` has a DEFINED conversion
    // (the ZigBase cookie boundary replaces it), so removing it loses
    // nothing an operator has to act on: the note is worth printing in
    // `MIGRATION.md` and worth nothing as a status.
    const layout_nodes = [_]fragments.Node{
        tText("<html><head>", 1),
        tNode(.csrf, 1, 13, "csrf_meta_tags"),
        tText("</head><body>", 1),
        tNode(.yield, 1, 30, null),
        tText("</body></html>", 1),
    };
    const view_nodes = [_]fragments.Node{tText("<h1>About</h1>", 1)};

    var pair = try scaffoldPair(gpa, &layout_nodes, &view_nodes);
    defer pair.deinit(gpa);

    try testing.expect(pair.note != null);
    try testing.expect(std.mem.indexOf(u8, pair.note.?, "csrf_meta_tags dropped") != null);
    try testing.expectEqual(Status.migrated, pair.status);
}

// ---- ruling S13: a SPA needs somewhere to mount --------------------------

test "write: a spa decision on a top-level dynamic route is not applied" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `get "/:slug"`. Honouring `spa` here would write `spa/:slug.spa.tsx`
    // with `base: "/:slug"` -- a filename with a colon and a mount base that
    // is a pattern. Nothing downstream can build it.
    var rs = [_]route_mod.Route{tRoute("GET", "/:slug", "pages", "show", 3)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var rts = [_]rails.RouteTemplates{.{ .templates = &.{}, .layout = null }};
    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    var decided = [_]decisions.Decision{.{
        .id = finding_list[0].id,
        .choice = "spa",
        .rationale = "client-routed",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(Status.open, res.routes[0].status);
    try testing.expectEqualStrings("spa needs a static first segment", res.routes[0].note.?);
    try testing.expectEqual(@as(usize, 0), res.spa_files.len);
    try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
    // The decision IS recorded -- it was made, it just could not be carried
    // out -- so the handoff can show why the route is still open.
    try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
    try testing.expect(!targetHas(&tmp, "package.json"));
}

test "write: staticPaths is emitted only for a spa entry whose own path is dynamic" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Grouping is by FIRST SEGMENT, so a static route can share a `.spa.tsx`
    // with a dynamic one. `runtime/src/router.ts:698` throws "staticPaths
    // declared on static route", so the static entry must not carry the key.
    var rs = [_]route_mod.Route{
        tRoute("GET", "/posts/:id", "posts", "show", 3),
        tRoute("GET", "/posts/new", "posts", "new", 3),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    var decided = [_]decisions.Decision{.{
        .id = finding_list[0].id,
        .choice = "spa",
        .rationale = "client-routed",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const spa_src = try readTarget(gpa, &tmp, "spa/posts.spa.tsx");
    defer gpa.free(spa_src);
    // `/posts/:id` -> `/:id`: dynamic, so it enumerates.
    try testing.expect(std.mem.indexOf(u8, spa_src, "{ path: \"/:id\", component: PostsShow, skeleton: false as const, staticPaths: [] }") != null);
    // `/posts/new` is NOT dynamic, so it never reached the SPA at all -- it
    // took the content path. Only the dynamic one is here.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, spa_src, "path: \""));

    // The build line restates the base, which turns `src/spa.zig`'s
    // agreement and overlap checks back on.
    const build_sh = try readTarget(gpa, &tmp, "build.sh");
    defer gpa.free(build_sh);
    // Quoted: see `emitBuildSh`. A substring check like this one is what let
    // the unquoted form ship, so it is paired with the replay test at the
    // bottom of this file rather than trusted on its own.
    try testing.expect(std.mem.indexOf(u8, build_sh, "--spa='spa/posts.spa.tsx|/posts'") != null);
}

test "spaRoutePath + isDynamicRoutePath is the gate staticPaths is emitted behind" {
    // The unit-level half of the rule above. There is deliberately no
    // end-to-end case for the OTHER branch, and the reason is worth writing
    // down rather than leaving as an untested line:
    //
    // only a route `findings.isDynamicRoutePath` accepts ever reaches
    // `writeSpas`, and ruling S13 refuses the one shape whose placeholder is
    // the FIRST segment -- so every surviving route has its placeholder
    // somewhere after the segment the SPA is mounted at, and the rest path is
    // always dynamic. The `if` in `emitSpa` is therefore defence in depth
    // against a future change to the grouping (mounting by controller, say,
    // which would put `/posts/new` and `/posts/:id` in one file), not a live
    // branch. Pinning the predicate here keeps that reasoning checkable
    // without inventing an input the production path cannot produce.
    try testing.expectEqualStrings("/:id", spaRoutePath("/posts/:id", "posts"));
    try testing.expectEqualStrings("/:id/edit", spaRoutePath("/posts/:id/edit", "posts"));
    try testing.expectEqualStrings("/new", spaRoutePath("/posts/new", "posts"));
    try testing.expectEqualStrings("/", spaRoutePath("/posts", "posts"));

    try testing.expect(findings.isDynamicRoutePath(spaRoutePath("/posts/:id", "posts")));
    try testing.expect(!findings.isDynamicRoutePath(spaRoutePath("/posts/new", "posts")));
    try testing.expect(!findings.isDynamicRoutePath(spaRoutePath("/posts", "posts")));
}

// A route routinely carries several findings and the operator may answer them
// differently, so which answer decides the ROUTE is a rule and not an
// accident. It was previously observable only through a whole `write` run,
// which meant swapping the two ranks broke no test at all: every case a run
// exercises has one answer.
test "pickDecision: blocked beats retain beats a deferral, ties broken by the smallest id" {
    var answers = [_]decisions.Decision{
        .{ .id = "A", .choice = "island", .rationale = "r", .artifact = null },
        .{ .id = "B", .choice = "retain", .rationale = "r", .artifact = null },
        .{ .id = "C", .choice = "blocked", .rationale = "r", .artifact = null },
        .{ .id = "D", .choice = "blocked", .rationale = "r", .artifact = null },
        .{ .id = "E", .choice = "retain", .rationale = "r", .artifact = null },
        .{ .id = "F", .choice = "backend", .rationale = "r", .artifact = null },
        .{ .id = "G", .choice = "backend", .rationale = "r", .artifact = null },
        .{ .id = "P", .choice = "public", .rationale = "r", .artifact = null },
        .{ .id = "Z", .choice = "createPosts", .rationale = "r", .artifact = null },
    };
    const parsed: decisions.Parsed = .{ .decisions = &answers, .stale = &.{} };

    // `blocked` is the stronger statement: an operator who blocked the route
    // on one of its gaps has not agreed to ship it because another gap was
    // marked `retain`. Asserted in both input orders, so the winner cannot be
    // "whichever id came first".
    try testing.expectEqualStrings("C", pickDecision(parsed, &.{ "A", "B", "C" }).?.id);
    try testing.expectEqualStrings("C", pickDecision(parsed, &.{ "C", "B", "A" }).?.id);
    // `retain` beats `island`/`backend`, which leave the route open anyway.
    try testing.expectEqualStrings("B", pickDecision(parsed, &.{ "A", "B", "F" }).?.id);
    try testing.expectEqualStrings("B", pickDecision(parsed, &.{ "F", "B", "A" }).?.id);
    // #167 Stage 3, the fourth tier: an answer that PRODUCES something beats a
    // deferral. `G` sorts BEFORE `Z`, so with the old three-tier rank the two
    // were equal and the deferral won on the id alone -- a route whose form
    // was bound to a real operation would have reported the `backend`
    // deferral's note instead of the binding.
    try testing.expectEqualStrings("Z", pickDecision(parsed, &.{ "G", "Z" }).?.id);
    try testing.expectEqualStrings("Z", pickDecision(parsed, &.{ "Z", "G" }).?.id);
    // The same, for the two other producing words.
    try testing.expectEqualStrings("P", pickDecision(parsed, &.{ "G", "P" }).?.id);
    try testing.expectEqualStrings("A", pickDecision(parsed, &.{ "G", "A" }).?.id);
    // …and `retain`/`blocked` still outrank a producing answer, because both
    // say the target does not serve this page at all.
    try testing.expectEqualStrings("B", pickDecision(parsed, &.{ "B", "Z" }).?.id);
    try testing.expectEqualStrings("C", pickDecision(parsed, &.{ "C", "Z" }).?.id);
    // Equal rank: the smallest id, again in both orders.
    try testing.expectEqualStrings("C", pickDecision(parsed, &.{ "D", "C" }).?.id);
    try testing.expectEqualStrings("C", pickDecision(parsed, &.{ "C", "D" }).?.id);
    try testing.expectEqualStrings("B", pickDecision(parsed, &.{ "E", "B" }).?.id);
    // An unanswered id contributes nothing; no answered id at all is `null`,
    // which is what leaves the route `open`.
    try testing.expectEqualStrings("B", pickDecision(parsed, &.{ "ghost", "B" }).?.id);
    try testing.expect(pickDecision(parsed, &.{"ghost"}) == null);
    try testing.expect(pickDecision(parsed, &.{}) == null);
}

// ---- ruling S14: a failure names its cause, a collision is not a failure --

test "write: a target-write failure reports the OS error, not just the path" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_dir = try tmp.dir.createDirPathOpen(std.testing.io, "out", .{});
    out_dir.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "out/zigapagos.ziggy", .data = "hand edited\n" });

    var d = emptyDiscovery();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    try testing.expectError(error.TargetWrite, write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause));
    // Without this the operator cannot tell "wipe the target and re-run" from
    // "fix a permission": `TargetWrite` alone says neither.
    try testing.expectEqual(@as(?anyerror, error.PathAlreadyExists), err_cause);
}

test "write: two routes mapping to one content path -- the second is open, not a failure" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `/about` and `/about/` normalise to the same `content/about/index.smd`
    // (`resolve.contentPath` trims the trailing slash), and a Rails app can
    // declare both. Before ruling S14 the second write hit the
    // exclusive-create guard and aborted the WHOLE migration with a
    // filesystem error naming neither route.
    const view_nodes = [_]fragments.Node{tText("<h1>About</h1>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{
        tRoute("GET", "/about", "pages", "about", 2),
        tRoute("GET", "/about/", "pages", "about", 3),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls, .layout = null },
        .{ .templates = &tpls, .layout = null },
    };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // Sorted by path: `/about` wins, `/about/` reports the clash.
    try testing.expectEqual(Status.migrated, res.routes[0].status);
    try testing.expectEqual(Status.open, res.routes[1].status);
    try testing.expectEqualStrings("content path collision with GET /about", res.routes[1].note.?);
    try testing.expect(err_path == null);
    try testing.expect(targetHas(&tmp, "content/about/index.smd"));
}

// ---- the C minors --------------------------------------------------------

test "write: a layout's own open finding leaves an otherwise-clean view open" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The view is spotless; the LAYOUT calls an unknown helper. A route is
    // its whole template graph, so the page is not finished.
    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.unknown, 1, 13, "number_to_currency"),
        tNode(.yield, 1, 40, null),
        tText("</body></html>", 1),
    };
    const view_nodes = [_]fragments.Node{tText("<h1>About</h1>", 1)};
    const frags = [_]fragments.Template{
        tTemplate("app/views/layouts/application.html.erb", &layout_nodes),
        tTemplate("app/views/pages/about.html.erb", &view_nodes),
    };
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);

    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = "app/views/layouts/application.html.erb" }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(Status.open, res.routes[0].status);
    try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
    try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
}

// Ruling S22. `pages#other` renders `:about` and has no `other.html.erb`, so
// the route reaches `contentRoute`, resolves no view, and writes nothing. It
// used to say so in a note with no id behind it, which made the whole app
// permanently incomplete: there was no line an operator could put in
// `MIGRATION.decisions.json`. The finding `derive` raises on the route's own
// `routes.rb` line is that line.
test "write: a route whose action resolves no view carries RAILS_NO_TEMPLATE, and an answer settles it (ruling S22)" {
    const gpa = testing.allocator;

    var rs = [_]route_mod.Route{tRoute("GET", "/other", "pages", "other", 3)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    // The route resolved a partial but no `pages/other.*`.
    var tpls = [_][]const u8{"app/views/shared/_nav.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};
    var rt_lists = [_][]const []const u8{&tpls};

    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_templates = &rt_lists,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    try testing.expectEqualStrings("RAILS_NO_TEMPLATE.config/routes%2Erb.L3", finding_list[0].id);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "retain",
            .rationale = "the action renders another template; leave it on Rails",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.retained, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
        try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
    }
}

// Ruling S21. The sibling of the test above, one layer up: ruling S18 gave a
// Haml VIEW an answerable finding, but a Haml LAYOUT left every route under it
// with nothing but an open note -- `complete` unreachable for the whole
// controller by any answer the operator could give. The layout's finding is
// the one question ("this chrome cannot be converted"), so one answer on it
// has to settle every route that declares it.
test "write: a route under an unconvertible layout carries that layout's finding, and one answer settles it (ruling S21)" {
    const gpa = testing.allocator;

    // The layout is Haml: real file, listed by the inventory, but the
    // templates op never scans an engine it cannot parse, so there is no
    // fragment stream for it and `ensureLayout` returns null. The VIEW is
    // ordinary ERB and converts cleanly.
    const view_nodes = [_]fragments.Node{tText("<h1>Lay</h1>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/lay/show.html.erb", &view_nodes)};
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .unsupported_templates = &[_]findings.UnsupportedTemplate{
            .{ .path = "app/views/layouts/legacy.html.haml", .label = "Haml" },
        },
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    try testing.expectEqualStrings(
        "RAILS_TEMPLATE_ENGINE_UNSUPPORTED.app/views/layouts/legacy%2Ehtml%2Ehaml.engine",
        finding_list[0].id,
    );

    var rs = [_]route_mod.Route{tRoute("GET", "/lay", "lay", "show", 3)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/lay/show.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = "app/views/layouts/legacy.html.haml" }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    // Undecided: the standalone page IS still emitted (it is chrome that is
    // missing, not content), and the layout's id is the question.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
        try testing.expect(targetHas(&tmp, "content/lay/index.smd"));
    }

    // Decided `blocked` on the LAYOUT's finding: the route is blocked and,
    // per ruling S20, writes nothing at all.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var decided = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "blocked",
            .rationale = "no Haml converter for the chrome",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.blocked, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
        try testing.expectEqual(@as(usize, 0), res.routes[0].artifacts.len);
        try testing.expect(!targetHas(&tmp, "content/lay/index.smd"));
    }
}

test "write: a finding inside an inlined partial reaches the route" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The view renders `shared/nav`, which is where the unknown helper is.
    // `convert.zig` inlines the partial, so the finding travels with it --
    // and the route must list it, because there is no other artifact the
    // partial's own gaps could be reported against.
    const view_nodes = [_]fragments.Node{
        tNode(.render_partial, 1, 1, "shared/nav"),
        tText("<h1>About</h1>", 2),
    };
    const partial_nodes = [_]fragments.Node{tNode(.unknown, 1, 1, "number_to_currency")};
    const frags = [_]fragments.Template{
        tTemplate("app/views/pages/about.html.erb", &view_nodes),
        tTemplate("app/views/shared/_nav.html.erb", &partial_nodes),
    };
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    try testing.expect(std.mem.indexOf(u8, finding_list[0].id, "_nav") != null);

    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{ "app/views/pages/about.html.erb", "app/views/shared/_nav.html.erb" };
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(Status.open, res.routes[0].status);
    try testing.expectEqual(@as(usize, 1), res.routes[0].open_finding_ids.len);
    try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
}

test "write: a computed content_for title can be blocked through its finding" {
    const gpa = testing.allocator;
    const path = "app/views/pages/about.html.erb";
    const view_nodes = [_]fragments.Node{
        tOpen(.content_for, 1, 1, "title", "content_for :title do"),
        tText("<span>Account</span>", 1),
        tText(" settings", 1),
        tEnd(1, 50),
        tText("<p>Body</p>", 2),
    };
    const frags = [_]fragments.Template{tTemplate(path, &view_nodes)};
    const route_views = [_]?[]const u8{path};
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .route_views = &route_views,
    });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    try testing.expectEqualStrings(findings.code_content_for_dynamic, finding_list[0].code);

    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{path};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    // Unanswered, the emitted page carries the id and the route stays open.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &.{}, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.open, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].open_finding_ids[0]);
        const view = try readTarget(gpa, &tmp, "layouts/pages/about.shtml");
        defer gpa.free(view);
        try testing.expect(std.mem.indexOf(u8, view, "<!-- rails:finding RAILS_CONTENT_FOR_DYNAMIC.") != null);
        try testing.expect(std.mem.indexOf(u8, view, "rails:unmapped content_for") == null);
        try testing.expect(std.mem.indexOf(u8, view, "<span>Account</span>") == null);
        try testing.expect(std.mem.indexOf(u8, view, "<p>Body</p>") != null);
    }

    // The same id is a real decision boundary, so blocked emits no page.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| gpa.free(p);
        var err_cause: ?anyerror = null;
        var answered = [_]decisions.Decision{.{
            .id = finding_list[0].id,
            .choice = "blocked",
            .rationale = "title requires Rails request state",
            .artifact = null,
        }};
        const res = try write(std.testing.io, gpa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &answered, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause);
        defer freeResult(gpa, res);
        try testing.expectEqual(Status.blocked, res.routes[0].status);
        try testing.expectEqualStrings(finding_list[0].id, res.routes[0].decision_id.?);
        try testing.expect(!targetHas(&tmp, "content/about/index.smd"));
    }
}

test "write: a description and a quoted title survive into Ziggy frontmatter" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `"` and `\` are the two characters that end a Ziggy string early; an
    // unescaped one makes the whole `.smd` unparseable, and the site fails to
    // build with an error pointing at the frontmatter rather than at the
    // Rails title it came from.
    const view_nodes = [_]fragments.Node{
        tOpen(.content_for, 1, 1, "title", "content_for :title do"),
        tText("The \"best\" C:\\path", 1),
        tEnd(1, 40),
        tText("<meta name=\"description\" content=\"Tea &amp; cake\">", 2),
        tText("<p>Body</p>", 3),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/pages/about.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tRoute("GET", "/about", "pages", "about", 2)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const page = try readTarget(gpa, &tmp, "content/about/index.smd");
    defer gpa.free(page);
    try testing.expect(std.mem.indexOf(u8, page, ".title = \"The \\\"best\\\" C:\\\\path\",") != null);
    // The description is plain text by the time it gets here: the HTML entity
    // is already resolved, and must not be double-unescaped.
    try testing.expect(std.mem.indexOf(u8, page, ".description = \"Tea & cake\",") != null);
}

test "write: a spa scaffolded with no runtime path says the package.json needs an edit" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rs = [_]route_mod.Route{tRoute("GET", "/posts/:id", "posts", "show", 3)};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var rts = [_]rails.RouteTemplates{.{ .templates = &.{}, .layout = null }};
    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer findings.free(gpa, finding_list);
    var decided = [_]decisions.Decision{.{
        .id = finding_list[0].id,
        .choice = "spa",
        .rationale = "client-routed",
        .artifact = null,
    }};
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // Migrated -- the conversion IS done -- with one edit named, because a
    // placeholder `file:` dependency is not something `bun install` can
    // resolve and nothing else in the output says so.
    try testing.expectEqual(Status.migrated, res.routes[0].status);
    try testing.expectEqualStrings("set dependencies.@z/runtime in package.json", res.routes[0].note.?);
    const pkg = try readTarget(gpa, &tmp, "package.json");
    defer gpa.free(pkg);
    try testing.expect(std.mem.indexOf(u8, pkg, "TODO-SET-RUNTIME-PATH") != null);
}

// ---- the generated build.sh has to actually RUN ---------------------------

/// Runs `bash` with `args`, returning its exit code and stdout. Skips the
/// whole test when there is no `bash` to run -- the same shape every other
/// subprocess test in this tree uses (`sidecar.zig`'s bun tests).
///
/// Contract 2 (owned-result): the returned stdout is a fresh `gpa`
/// allocation; stderr is released here.
fn runBash(gpa: Allocator, args: []const []const u8) !struct { code: u8, stdout: []u8 } {
    const r = std.process.run(gpa, std.testing.io, .{ .argv = args }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    gpa.free(r.stderr);
    errdefer gpa.free(r.stdout);
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        // A signal is not an exit code; report something non-zero rather than
        // silently reading it as success.
        else => 255,
    };
    return .{ .code = code, .stdout = r.stdout };
}

test "emitBuildSh: the emitted script parses, and each --spa/--island reaches the binary as ONE argument" {
    const gpa = testing.allocator;
    // The regression this pins: `--spa=<src>|<base>` written UNQUOTED makes
    // the `|` a pipeline separator, so bash reads the line as
    // `... --spa=spa/posts.spa.tsx | /posts "$@"` and tries to execute a
    // command called `/posts`. With `set -o pipefail` (which the emitted
    // script sets) that is exit 127 and NO arguments ever reach the binary --
    // the generated project simply cannot build. A byte-comparison test
    // cannot see this, which is exactly why the previous ones pinned the
    // broken form green: they compared the wrong thing correctly.
    //
    // Every hand-written invocation in this repo quotes it
    // (`examples/tsx-site/build.sh`, `site/build.sh`, `docs/spa.md`).
    const script = try emitBuildSh(
        gpa,
        &.{ "spa/posts.spa.tsx", "spa/admin.spa.tsx" },
        &.{"components/forms/registrations_new.island.tsx"},
    );
    defer gpa.free(script);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.sh", .data = script });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/build.sh", .{tmp.sub_path});
    defer gpa.free(path);

    // 1. It is a well-formed shell script at all.
    const syntax = try runBash(gpa, &.{ "bash", "-n", path });
    defer gpa.free(syntax.stdout);
    try testing.expectEqual(@as(u8, 0), syntax.code);

    // 2. The arguments survive word splitting. The `exec` line is replayed
    //    with `printf` standing in for the binary, so what is asserted is the
    //    ARGV the binary would have seen -- not the bytes of the file.
    const exec_line = lastLine(script);
    try testing.expect(std.mem.startsWith(u8, exec_line, "exec \"${ZIGAPAGOS_BIN:-zigapagos}\""));
    const tail = exec_line["exec \"${ZIGAPAGOS_BIN:-zigapagos}\"".len..];
    const program = try std.fmt.allocPrint(gpa, "set -euo pipefail\nprintf '%s\\n'{s}", .{tail});
    defer gpa.free(program);

    const replay = try runBash(gpa, &.{ "bash", "-c", program });
    defer gpa.free(replay.stdout);
    try testing.expectEqual(@as(u8, 0), replay.code);
    try testing.expectEqualStrings(
        \\release
        \\--force
        \\--output=zig-out/site
        \\--spa=spa/posts.spa.tsx|/posts
        \\--spa=spa/admin.spa.tsx|/admin
        \\--island=components/forms/registrations_new.island.tsx
        \\
    , replay.stdout);
}

/// The last non-empty line of `s`. Contract 3 (caller-buffer): a sub-slice.
fn lastLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, s, "\n");
    const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    return trimmed[nl + 1 ..];
}

// ---- ruling S16: one view, two layouts ------------------------------------

/// Two routes rendering the SAME view, each with its own layout (`null` means
/// no layout). Returns both outcomes plus the written view file.
const SharedView = struct {
    first: Status,
    second: Status,
    first_note: ?[]u8,
    second_note: ?[]u8,
    view: []u8,
    artifact_count: usize,

    fn deinit(self: *SharedView, gpa: Allocator) void {
        if (self.first_note) |n| gpa.free(n);
        if (self.second_note) |n| gpa.free(n);
        gpa.free(self.view);
    }
};

fn scaffoldSharedView(gpa: Allocator, second_layout: ?[]const u8) !SharedView {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.yield, 1, 13, null),
        tText("</body></html>", 1),
    };
    const view_nodes = [_]fragments.Node{tText("<h1>About</h1>", 1)};
    const frags = [_]fragments.Template{
        tTemplate("app/views/layouts/application.html.erb", &layout_nodes),
        tTemplate("app/views/layouts/marketing.html.erb", &layout_nodes),
        tTemplate("app/views/pages/about.html.erb", &view_nodes),
    };
    // Sorted by path, so `/a` is the FIRST route and owns the view file.
    var rs = [_]route_mod.Route{
        tRoute("GET", "/a", "pages", "about", 2),
        tRoute("GET", "/b", "pages", "about", 3),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var tpls = [_][]const u8{"app/views/pages/about.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls, .layout = "app/views/layouts/application.html.erb" },
        .{ .templates = &tpls, .layout = second_layout },
    };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);

    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const view = try readTarget(gpa, &tmp, "layouts/pages/about.shtml");
    errdefer gpa.free(view);
    return .{
        .first = res.routes[0].status,
        .second = res.routes[1].status,
        .first_note = if (res.routes[0].note) |n| try gpa.dupe(u8, n) else null,
        .second_note = if (res.routes[1].note) |n| try gpa.dupe(u8, n) else null,
        .view = view,
        .artifact_count = res.routes[1].artifacts.len,
    };
}

test "write: two routes sharing a view under the SAME layout share its file" {
    const gpa = testing.allocator;
    // The ordinary case, unchanged by ruling S16: one view file, two content
    // pages, both finished. Writing `layouts/pages/about.shtml` twice would
    // hit the exclusive-create guard, so the dedupe is load-bearing.
    var r = try scaffoldSharedView(gpa, "app/views/layouts/application.html.erb");
    defer r.deinit(gpa);

    try testing.expectEqual(Status.migrated, r.first);
    try testing.expectEqual(Status.migrated, r.second);
    try testing.expect(r.first_note == null);
    try testing.expect(r.second_note == null);
    try testing.expect(std.mem.indexOf(u8, r.view, "application.shtml") != null);
}

test "write: the same view under a DIFFERENT layout leaves the second route open" {
    const gpa = testing.allocator;
    // Ruling S16, and the bug it closes. A view's conversion is a function of
    // its LAYOUT as well as its own nodes: the `<extend template=...>` names
    // that layout, and `layout_blocks` decides which blocks the view emits.
    // The target has ONE `layouts/pages/about.shtml`, so the second route
    // cannot have its own -- and reusing the first route's would give it an
    // `<extend>` naming the wrong parent and a block set the wrong layout
    // declares, which SuperHTML rejects outright.
    //
    // The keyed cache makes the clash visible instead: the first route (in
    // this file's route order) owns the file, the second is `open` and names
    // both layouts.
    var r = try scaffoldSharedView(gpa, "app/views/layouts/marketing.html.erb");
    defer r.deinit(gpa);

    try testing.expectEqual(Status.migrated, r.first);
    try testing.expectEqual(Status.open, r.second);
    try testing.expect(r.second_note != null);
    try testing.expectEqualStrings(
        "view shared across layouts: application vs marketing",
        r.second_note.?,
    );
    // Nothing written for the loser: no half-page pointing at a layout that
    // does not match it.
    try testing.expectEqual(@as(usize, 0), r.artifact_count);
    // And the file that IS there belongs to the first route.
    try testing.expect(std.mem.indexOf(u8, r.view, "application.shtml") != null);
}

test "write: a view under a layout, then under none, is the same clash" {
    const gpa = testing.allocator;
    // `layout false` in one controller and a layout in another is the same
    // situation with `null` on one side: a standalone view has no `<extend>`
    // at all, so the two conversions are not interchangeable either.
    var r = try scaffoldSharedView(gpa, null);
    defer r.deinit(gpa);

    try testing.expectEqual(Status.migrated, r.first);
    try testing.expectEqual(Status.open, r.second);
    try testing.expectEqualStrings(
        "view shared across layouts: application vs (none)",
        r.second_note.?,
    );
}

// ---- #167 Stage 3: the operator's backend answers -------------------------

/// One collection, trimmed to what a binding actually reads out of a ZigBase
/// document. Deliberately NOT a copy of `backend.zig`'s own fixture: that one
/// exists to give every `x-zigbase-access` spelling a test, this one to give a
/// form a `create` and an `update` to bind to.
const bound_document =
    \\{
    \\  "openapi": "3.1.2",
    \\  "info": { "title": "ZigBase API", "version": "2026-08-29.1" },
    \\  "paths": {
    \\    "/api/collections/posts/records": {
    \\      "post": { "operationId": "createPosts", "x-zigbase-access": "locked" }
    \\    },
    \\    "/api/collections/posts/records/{id}": {
    \\      "patch": { "operationId": "updatePosts", "x-zigbase-access": "locked" },
    \\      "delete": { "operationId": "deletePosts", "x-zigbase-access": "locked" }
    \\    }
    \\  }
    \\}
;

const bound_view = "app/views/posts/new.html.erb";
const bound_island = "components/forms/posts_new.island.tsx";

fn tArgs(
    kind: fragments.Kind,
    line: u64,
    col: u64,
    name: []const u8,
    args: []const []const u8,
) fragments.Node {
    var n = tNode(kind, line, col, name);
    n.args = args;
    return n;
}

fn tNamed(
    verb: []const u8,
    path: []const u8,
    controller: ?[]const u8,
    action: ?[]const u8,
    line: u64,
    name: []const u8,
) route_mod.Route {
    var r = tRoute(verb, path, controller, action, line);
    r.name = name;
    return r;
}

/// `app/views/posts/new.html.erb`: an `@post.errors` summary whose loop body
/// holds a block local nothing binds (#181's exact shape), then a
/// `form_with model: @post` with a label, a text field and a submit.
///
/// `posts`, not `registrations`: assumption A5 makes every route under
/// `sessions`/`registrations` an auth-journey route, which raises no
/// `RAILS_BACKEND_ENDPOINT` at all. A test whose view could never carry the
/// finding it is about would pin nothing.
/// A literal `method: :patch` on the form, so a PATCH operation is in the
/// choice list `findings.derive` offers (`choicesFor` filters by verb).
const patch_attrs = [_]fragments.Attr{.{ .key = "method", .value = "patch" }};
/// The same, for the other collection call that addresses ONE record.
const delete_attrs = [_]fragments.Attr{.{ .key = "method", .value = "delete" }};

fn boundViewNodes(patch: bool, delete_form: bool) [10]fragments.Node {
    var nodes: [10]fragments.Node = .{
        tOpen(.errors, 1, 4, "post", "@post.errors.full_messages.each do |m|"),
        tText("<li>", 1),
        tNode(.local, 1, 44, "m"),
        tText("</li>", 1),
        tEnd(1, 60),
        tOpen(.form, 2, 4, "post", "form_with(model: @post) do |f|"),
        tArgs(.form_field, 2, 40, "label", &.{"title"}),
        tArgs(.form_field, 2, 60, "text_field", &.{"title"}),
        tArgs(.form_field, 2, 80, "submit", &.{"Create"}),
        tEnd(2, 100),
    };
    if (patch) nodes[5].attrs = &patch_attrs;
    if (delete_form) nodes[5].attrs = &delete_attrs;
    return nodes;
}

const BoundOpts = struct {
    /// What the operator answered the form's `RAILS_BACKEND_ENDPOINT` with.
    /// `null` leaves it unanswered.
    choice: ?[]const u8 = "createPosts",
    /// Whether a `--backend` document was supplied at all.
    with_backend: bool = true,
    /// Whether `posts#create` redirects anywhere this run can resolve.
    with_redirect: bool = true,
    runtime_path: ?[]const u8 = null,
    runtime_dir_env: ?[]const u8 = null,
    /// Give the form a literal `method: :patch`, which is what puts an
    /// `update` operation in its choice list at all.
    patch: bool = false,
    /// The same for `method: :delete`, which is what puts a DELETE operation
    /// in the list. Mutually exclusive with `patch`; the last one set wins.
    delete_form: bool = false,
};

/// One whole `write` over the bound fixture, with the REAL `findings.derive`
/// and `decisions.parse` in front of it: a hand-built finding list would let
/// this file agree with itself about ids that Stage 1 never emits.
const BoundRun = struct {
    tmp: std.testing.TmpDir,
    res: Result,
    finding_list: []findings.Finding,
    parsed: decisions.Parsed,
    doc: ?backend_mod.Document,
    /// The form's own finding id, borrowed from `finding_list`.
    form_id: []const u8,

    fn deinit(self: *BoundRun, gpa: Allocator) void {
        freeResult(gpa, self.res);
        decisions.free(gpa, self.parsed);
        findings.free(gpa, self.finding_list);
        if (self.doc) |d| backend_mod.free(gpa, d);
        self.tmp.cleanup();
    }

    fn route(self: *const BoundRun, verb: []const u8, path: []const u8) RouteOutcome {
        for (self.res.routes) |o| {
            const r = bound_routes[o.route_index];
            if (std.mem.eql(u8, r.verb, verb) and std.mem.eql(u8, r.path, path)) return o;
        }
        unreachable;
    }
};

/// Module-level so `BoundRun.route` can name a route after `runBound`'s own
/// stack frame is gone.
var bound_routes = [_]route_mod.Route{
    tNamed("GET", "/", "pages", "home", 1, "root"),
    // A GET route on the SAME controller#action as the mutation, and BEFORE
    // it, so a pairing that did not exclude GET would pick this one:
    // `posts#new`'s form submits, and a page route can never be where the
    // submission lands.
    tNamed("GET", "/posts/create", "posts", "create", 3, "create_post"),
    tNamed("POST", "/posts", "posts", "create", 2, "posts"),
    tNamed("GET", "/posts/new", "posts", "new", 2, "new_post"),
};

fn runBound(gpa: Allocator, opts: BoundOpts) !BoundRun {
    const view_nodes = boundViewNodes(opts.patch, opts.delete_form);
    const home_nodes = [_]fragments.Node{tText("<h1>Home</h1>", 1)};
    const frags = [_]fragments.Template{
        tTemplate("app/views/pages/home.html.erb", &home_nodes),
        tTemplate(bound_view, &view_nodes),
    };
    var vs = [_]classify.Verdict{
        tVerdict(.content),
        tVerdict(.content),
        tVerdict(.backend),
        tVerdict(.content),
    };
    var home_tpls = [_][]const u8{"app/views/pages/home.html.erb"};
    var new_tpls = [_][]const u8{bound_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &home_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &new_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{
        "app/views/pages/home.html.erb",
        null,
        null,
        bound_view,
    };
    const route_names = [_][]const u8{ "root", "posts", "create_post", "new_post" };

    var doc: ?backend_mod.Document = null;
    errdefer if (doc) |x| backend_mod.free(gpa, x);
    if (opts.with_backend) doc = try backend_mod.parse(gpa, bound_document, "openapi.json");

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &bound_routes,
        .classifications = &vs,
        .route_views = &route_views,
        .backend = doc,
    });
    errdefer findings.free(gpa, finding_list);

    var form_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint) and
            std.mem.eql(u8, f.path, bound_view)) form_id = f.id;
    }
    try testing.expect(form_id.len > 0);

    var problems: std.ArrayListUnmanaged(decisions.Problem) = .empty;
    defer decisions.freeProblems(gpa, &problems);
    const answers = if (opts.choice) |c| try std.fmt.allocPrint(gpa,
        \\{{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {{"id":"{s}","choice":"{s}","rationale":"the form posts a record"}}
        \\]}}
    , .{ form_id, c }) else try gpa.dupe(u8,
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[]}
    );
    defer gpa.free(answers);
    const parsed = try decisions.parse(gpa, answers, finding_list, &.{}, &problems);
    errdefer decisions.free(gpa, parsed);
    try testing.expectEqual(@as(usize, 0), problems.items.len);

    var redirects = [_]controllers.RedirectInfo{.{ .name = "root", .args = &.{} }};
    var actions = [_]controllers.ActionInfo{.{
        .controller = "posts",
        .action = "create",
        .redirects = if (opts.with_redirect) &redirects else &.{},
    }};

    var d = emptyDiscovery();
    d.routes = &bound_routes;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;
    d.actions = &actions;

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = parsed,
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = opts.runtime_path,
        .runtime_dir_env = opts.runtime_dir_env,
        .backend = doc,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);

    return .{
        .tmp = tmp,
        .res = res,
        .finding_list = finding_list,
        .parsed = parsed,
        .doc = doc,
        .form_id = form_id,
    };
}

test "write: a bound form becomes an island, and the ERB region it replaced is gone" {
    const gpa = testing.allocator;
    var bound = try runBound(gpa, .{});
    defer bound.deinit(gpa);

    const view = try readTarget(gpa, &bound.tmp, "layouts/posts/new.shtml");
    defer gpa.free(view);
    // The whole form is ONE `<island>`: no `rails:finding` marker, no
    // `rails:end`, no placeholder for the fields inside it.
    try testing.expect(std.mem.indexOf(
        u8,
        view,
        "<island src=\"" ++ bound_island ++ "\" client:load></island>",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, view, "rails:finding") == null);
    // The applied `errors` binding consumes its `|m|` block local with the
    // region, just as the open finding owns it before an answer is applied.
    try testing.expect(std.mem.indexOf(u8, view, "rails:unmapped") == null);

    const outcome = bound.route("GET", "/posts/new");
    try testing.expectEqual(Status.migrated, outcome.status);
    // The findings inside the bound region are ANSWERED, not open.
    try testing.expectEqual(@as(usize, 0), outcome.open_finding_ids.len);
    try testing.expect(contains(outcome.artifacts, bound_island));
    try testing.expect(contains(outcome.artifacts, client_lib_path));
}

test "write: the island's bytes are the form, the call and the error list" {
    const gpa = testing.allocator;
    var bound = try runBound(gpa, .{});
    defer bound.deinit(gpa);

    const island = try readTarget(gpa, &bound.tmp, bound_island);
    defer gpa.free(island);
    try testing.expectEqualStrings(
        \\// Generated by `zigapagos migrate --from rails` from app/views/posts/new.html.erb:2.
        \\// Replaces: form_with(model: @post) do |f|
        \\// Enforcement stays server-side: this island only presents the form and the backend's
        \\// validation errors; the ZigBase rule on the operation decides who may submit.
        \\import { useState } from "@z/runtime";
        \\import { isZigbaseError, type FieldError } from "@zigbase/client";
        \\import { zb } from "../../lib/zb";
        \\
        \\export interface Props {}
        \\
        \\export default function PostsNew(_props: Props) {
        \\  const [values, setValues] = useState<Record<string, string>>({});
        \\  const [errors, setErrors] = useState<Record<string, FieldError>>({});
        \\  const [done, setDone] = useState(false);
        \\  const set = (field: string) => (e: any) =>
        \\    setValues({ ...values, [field]: String(e.currentTarget.value ?? "") });
        \\  async function onSubmit(e: any) {
        \\    e.preventDefault();
        \\    setErrors({});
        \\    try {
        \\      await zb.collection("posts").create(values);
        \\      location.assign("/");
        \\    } catch (err) {
        \\      if (isZigbaseError(err)) {
        \\        setErrors(err.data);
        \\        return;
        \\      }
        \\      throw err;
        \\    }
        \\  }
        \\  const errorList = (
        \\    <ul class="errors">
        \\      {Object.entries(errors).map(([f, e]) => (
        \\        <li key={f}>{f + ": " + e.message}</li>
        \\      ))}
        \\    </ul>
        \\  );
        \\  if (done) return <p>{"Done."}</p>;
        \\  return (
        \\    <form onSubmit={onSubmit}>
        \\      {errorList}
        \\      <label htmlFor="title">{"Title"}</label>
        \\      <input id="title" type="text" name="title" value={values["title"] ?? ""} onInput={set("title")} />
        \\      <button type="submit">{"Create"}</button>
        \\    </form>
        \\  );
        \\}
        \\
    , island);
}

test "write: one lib/zb.ts, one package.json dependency pair, one --island flag" {
    const gpa = testing.allocator;
    var bound = try runBound(gpa, .{ .runtime_path = "../zigapagos/runtime" });
    defer bound.deinit(gpa);

    const zb = try readTarget(gpa, &bound.tmp, client_lib_path);
    defer gpa.free(zb);
    // Assumption A1, verified against ~/nothlav/zigbase: `createClient` +
    // `LocalAuthStore`, not the spec's sketched `new ZigBase(...)`.
    try testing.expectEqualStrings(
        \\import { createClient, LocalAuthStore } from "@zigbase/client";
        \\export const zb = createClient("", { authStore: new LocalAuthStore(), fetch: (input, init) => globalThis.fetch(input, init) });
        \\
    , zb);

    const pkg = try readTarget(gpa, &bound.tmp, "package.json");
    defer gpa.free(pkg);
    try testing.expectEqualStrings(
        \\{
        \\  "name": "blog",
        \\  "private": true,
        \\  "type": "module",
        \\  "dependencies": { "@z/runtime": "file:../zigapagos/runtime", "@zigbase/client": "0.3.0" }
        \\}
        \\
    , pkg);

    const build_sh = try readTarget(gpa, &bound.tmp, "build.sh");
    defer gpa.free(build_sh);
    try testing.expect(std.mem.indexOf(u8, build_sh, "bun install") != null);
    try testing.expect(std.mem.indexOf(u8, build_sh, " --island='" ++ bound_island ++ "'") != null);
}

test "write: a custom:/<path> answer sends the form through zb.send with the Rails verb" {
    const gpa = testing.allocator;
    // Assumption A3: the answer carries a path and no verb, so the verb is the
    // one the Rails form submits with (`form_with` defaults to POST).
    var bound = try runBound(gpa, .{ .choice = "custom:/api/contact" });
    defer bound.deinit(gpa);

    const island = try readTarget(gpa, &bound.tmp, bound_island);
    defer gpa.free(island);
    try testing.expect(std.mem.indexOf(
        u8,
        island,
        "await zb.send(\"POST\", \"/api/contact\", { body: values });",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, island, "zb.collection(") == null);

    // A `custom:` answer needs no document, so it still reaches the paired
    // route as an endpoint -- with `custom` as the operation id.
    const post = bound.route("POST", "/posts");
    try testing.expect(post.endpoint != null);
    try testing.expectEqualStrings("custom", post.endpoint.?.operation_id);
    try testing.expectEqualStrings("/api/contact", post.endpoint.?.path);
}

test "write: the form's answer becomes the paired POST route's endpoint" {
    const gpa = testing.allocator;
    var bound = try runBound(gpa, .{});
    defer bound.deinit(gpa);

    // Rails' own convention: `posts#new`'s form submits to `posts#create`, and
    // the endpoint belongs to THAT route -- the page route has no endpoint.
    const post = bound.route("POST", "/posts");
    try testing.expectEqual(Status.backend, post.status);
    try testing.expect(post.endpoint != null);
    try testing.expectEqualStrings("createPosts", post.endpoint.?.operation_id);
    try testing.expectEqualStrings("POST", post.endpoint.?.verb);
    try testing.expectEqualStrings("/api/collections/posts/records", post.endpoint.?.path);
    // A page route never carries an endpoint, not even one that happens to
    // name the same controller#action.
    try testing.expect(bound.route("GET", "/posts/new").endpoint == null);
    try testing.expect(bound.route("GET", "/posts/create").endpoint == null);
}

test "write: the redirect after a successful submit is the paired action's own" {
    const gpa = testing.allocator;
    // `posts#create` ends in `redirect_to root_path`, and `root` is a route
    // this run recovered, so the island navigates to `/`.
    var with = try runBound(gpa, .{});
    defer with.deinit(gpa);
    const a = try readTarget(gpa, &with.tmp, bound_island);
    defer gpa.free(a);
    try testing.expect(std.mem.indexOf(u8, a, "location.assign(\"/\");") != null);
    try testing.expect(std.mem.indexOf(u8, a, "setDone(true)") == null);

    // With no `redirect_to` to read, the island must NOT invent a destination.
    var without = try runBound(gpa, .{ .with_redirect = false });
    defer without.deinit(gpa);
    const b = try readTarget(gpa, &without.tmp, bound_island);
    defer gpa.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "location.assign") == null);
    try testing.expect(std.mem.indexOf(u8, b, "setDone(true);") != null);
}

test "write: a form in a rendered partial binds too, under the partial's own name" {
    const gpa = testing.allocator;
    // The commonest form in Rails lives in a `_form` partial the `new` view
    // renders. `convert.zig` inlines it, so the binding pre-pass has to follow
    // the same graph -- otherwise the finding is answerable and nothing acts
    // on the answer.
    const partial_path = "app/views/posts/_form.html.erb";
    const partial_island = "components/forms/posts__form.island.tsx";
    const form_nodes = boundViewNodes(false, false);
    const new_nodes = [_]fragments.Node{tNode(.render_partial, 1, 1, "form")};
    const frags = [_]fragments.Template{
        tTemplate(bound_view, &new_nodes),
        tTemplate(partial_path, &form_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("POST", "/posts", "posts", "create", 2, "posts"),
        tNamed("GET", "/posts/new", "posts", "new", 2, "new_post"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.backend), tVerdict(.content) };
    var new_tpls = [_][]const u8{bound_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &new_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{ null, bound_view };
    const route_names = [_][]const u8{ "posts", "new_post" };

    const doc = try backend_mod.parse(gpa, bound_document, "openapi.json");
    defer backend_mod.free(gpa, doc);
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .backend = doc,
    });
    defer findings.free(gpa, finding_list);

    var form_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint) and
            std.mem.eql(u8, f.path, partial_path)) form_id = f.id;
    }
    try testing.expect(form_id.len > 0);
    var decided = [_]decisions.Decision{.{
        .id = form_id,
        .choice = "createPosts",
        .rationale = "the form posts a record",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |x| gpa.free(x);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .backend = doc,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const island = try readTarget(gpa, &tmp, partial_island);
    defer gpa.free(island);
    // The header names the file an operator would actually open, not the view
    // the partial was inlined into.
    try testing.expect(std.mem.startsWith(
        u8,
        island,
        "// Generated by `zigapagos migrate --from rails` from " ++ partial_path ++ ":2.",
    ));
    const view = try readTarget(gpa, &tmp, "layouts/posts/new.shtml");
    defer gpa.free(view);
    try testing.expect(std.mem.indexOf(u8, view, "<island src=\"" ++ partial_island ++ "\"") != null);
    for (res.routes) |o| {
        if (!std.mem.eql(u8, rs[o.route_index].path, "/posts/new")) continue;
        try testing.expectEqual(Status.migrated, o.status);
    }
}

test "write: an unanswered form stays an answerable finding region, not an island" {
    const gpa = testing.allocator;
    var bound = try runBound(gpa, .{ .choice = null });
    defer bound.deinit(gpa);

    const view = try readTarget(gpa, &bound.tmp, "layouts/posts/new.shtml");
    defer gpa.free(view);
    try testing.expect(std.mem.indexOf(u8, view, "<island") == null);
    // The `|m|` block local belongs to the surrounding errors finding. It
    // must not add an id-less marker beside that answerable region (#181).
    try testing.expect(std.mem.indexOf(u8, view, "rails:unmapped local") == null);
    try testing.expect(std.mem.indexOf(u8, view, "rails:finding") != null);
    try testing.expect(!targetHas(&bound.tmp, bound_island));
    try testing.expectEqual(Status.open, bound.route("GET", "/posts/new").status);
}

test "write: #179 -- ZIGAPAGOS_RUNTIME_DIR fills the runtime dependency, and nothing else does" {
    const gpa = testing.allocator;
    {
        // The env var alone.
        var bound = try runBound(gpa, .{ .runtime_dir_env = "/home/x/zigapagos/runtime" });
        defer bound.deinit(gpa);
        const pkg = try readTarget(gpa, &bound.tmp, "package.json");
        defer gpa.free(pkg);
        try testing.expect(std.mem.indexOf(u8, pkg, "\"file:/home/x/zigapagos/runtime\"") != null);
    }
    {
        // `--runtime-path` is an explicit answer and beats the ambient one.
        var bound = try runBound(gpa, .{
            .runtime_path = "../flag",
            .runtime_dir_env = "/home/x/zigapagos/runtime",
        });
        defer bound.deinit(gpa);
        const pkg = try readTarget(gpa, &bound.tmp, "package.json");
        defer gpa.free(pkg);
        try testing.expect(std.mem.indexOf(u8, pkg, "\"file:../flag\"") != null);
    }
    {
        // Neither: the visible placeholder, unchanged from Stage 2.
        var bound = try runBound(gpa, .{});
        defer bound.deinit(gpa);
        const pkg = try readTarget(gpa, &bound.tmp, "package.json");
        defer gpa.free(pkg);
        try testing.expect(std.mem.indexOf(u8, pkg, "\"file:TODO-SET-RUNTIME-PATH\"") != null);
    }
}

test "write: a bound route answered retain writes no page and no island (ruling S20)" {
    const gpa = testing.allocator;
    // The form is bound AND the errors node above it is answered `retain`.
    // `retain` outranks the binding (`pickDecision`), so the page stays on
    // Rails -- and an island file for a page this target does not serve would
    // be source nothing imports.
    const view_nodes = boundViewNodes(false, false);
    const frags = [_]fragments.Template{tTemplate(bound_view, &view_nodes)};
    var rs = [_]route_mod.Route{
        tNamed("POST", "/posts", "posts", "create", 2, "posts"),
        tNamed("GET", "/posts/new", "posts", "new", 2, "new_post"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.backend), tVerdict(.content) };
    var new_tpls = [_][]const u8{bound_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &new_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{ null, bound_view };
    const route_names = [_][]const u8{ "posts", "new_post" };

    const doc = try backend_mod.parse(gpa, bound_document, "openapi.json");
    defer backend_mod.free(gpa, doc);
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .backend = doc,
    });
    defer findings.free(gpa, finding_list);

    var form_id: []const u8 = "";
    var errors_id: []const u8 = "";
    for (finding_list) |f| {
        if (!std.mem.eql(u8, f.path, bound_view)) continue;
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint)) form_id = f.id;
        if (std.mem.eql(u8, f.code, "RAILS_REQUEST_TIME_STATE")) errors_id = f.id;
    }
    try testing.expect(form_id.len > 0 and errors_id.len > 0);

    var problems: std.ArrayListUnmanaged(decisions.Problem) = .empty;
    defer decisions.freeProblems(gpa, &problems);
    const answers = try std.fmt.allocPrint(gpa,
        \\{{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {{"id":"{s}","choice":"createPosts","rationale":"the form posts a record"}},
        \\  {{"id":"{s}","choice":"retain","rationale":"the summary stays on Rails"}}
        \\]}}
    , .{ form_id, errors_id });
    defer gpa.free(answers);
    const parsed = try decisions.parse(gpa, answers, finding_list, &.{}, &problems);
    defer decisions.free(gpa, parsed);
    try testing.expectEqual(@as(usize, 0), problems.items.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = parsed,
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .backend = doc,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    for (res.routes) |o| {
        if (!std.mem.eql(u8, rs[o.route_index].path, "/posts/new")) continue;
        try testing.expectEqual(Status.retained, o.status);
        try testing.expectEqual(@as(usize, 0), o.artifacts.len);
    }
    try testing.expect(!targetHas(&tmp, bound_island));
    try testing.expect(!targetHas(&tmp, client_lib_path));
    try testing.expect(!targetHas(&tmp, "content/posts/new/index.smd"));
    // No island written means no client dependency either: a `package.json`
    // naming `@zigbase/client` in a project with no ZigBase call is a lie the
    // next `bun install` pays for.
    try testing.expect(!targetHas(&tmp, "package.json"));
}

test "write: the bound target is byte-identical on a second run" {
    const gpa = testing.allocator;
    var a = try runBound(gpa, .{ .runtime_path = "../rt" });
    defer a.deinit(gpa);
    var b = try runBound(gpa, .{ .runtime_path = "../rt" });
    defer b.deinit(gpa);

    const da = try treeDigest(gpa, &a.tmp);
    defer gpa.free(da);
    const db = try treeDigest(gpa, &b.tmp);
    defer gpa.free(db);
    try testing.expectEqualStrings(da, db);
}

test "write: an update binding with no id field says so instead of emitting a broken submit" {
    const gpa = testing.allocator;
    // `updatePosts` is `PATCH /api/collections/posts/records/{id}`, and a
    // static page has no request to read the id from. Rendering the form
    // anyway would give a control whose submit can only fail at runtime.
    var bound = try runBound(gpa, .{ .choice = "updatePosts", .patch = true });
    defer bound.deinit(gpa);
    const island = try readTarget(gpa, &bound.tmp, bound_island);
    defer gpa.free(island);
    try testing.expect(std.mem.indexOf(
        u8,
        island,
        "TODO: this form acts on one record; pass its id",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, island, "zb.collection") == null);
}

test "write: a delete binding with no id field says so instead of emitting a broken submit" {
    const gpa = testing.allocator;
    // The same ruling, on the other collection call that addresses ONE
    // record. `emitIsland` guarded `.update` alone, so a `deletePosts` answer
    // on a form with no `id` field emitted
    // `zb.collection("posts").delete(values.id)` -- `values` starts empty and
    // no field ever writes `id` into it, so that submit could only fail at
    // runtime, which is the exact outcome the `update` guard exists to
    // prevent. The CLICK island had guarded both shapes since round 3; the
    // form emitter had not, and the docs described the guard as covering
    // both.
    var bound = try runBound(gpa, .{ .choice = "deletePosts", .delete_form = true });
    defer bound.deinit(gpa);
    const island = try readTarget(gpa, &bound.tmp, bound_island);
    defer gpa.free(island);
    try testing.expect(std.mem.indexOf(
        u8,
        island,
        "TODO: this form acts on one record; pass its id",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, island, "zb.collection") == null);
}

test "write: a redirect route names where it goes (Stage 2's `to` was always null)" {
    const gpa = testing.allocator;
    // `pages#old` is `redirect_to "/about"` -- a literal target, the second
    // `RedirectInfo` shape -- and `pages#gone` redirects to a helper. Both
    // have to reach `Result.redirects[].to`, because the host-config stanza an
    // operator writes from that row is useless without a destination.
    var rs = [_]route_mod.Route{
        tNamed("GET", "/about", "pages", "about", 1, "about"),
        tNamed("GET", "/gone", "pages", "gone", 3, "gone"),
        tNamed("GET", "/old", "pages", "old", 2, "old"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.redirect), tVerdict(.redirect) };
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    var literal = [_]controllers.RedirectInfo{.{ .path = "/about" }};
    var helper = [_]controllers.RedirectInfo{
        .{ .dynamic = true },
        .{ .name = "about", .args = &.{} },
    };
    var actions = [_]controllers.ActionInfo{
        .{ .controller = "pages", .action = "old", .only_redirect = true, .redirects = &literal },
        .{ .controller = "pages", .action = "gone", .only_redirect = true, .redirects = &helper },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.actions = &actions;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 2), res.redirects.len);
    for (res.redirects) |x| {
        // A literal target rides through verbatim; a helper resolves against
        // the route table; a leading `dynamic` entry does not stop the search.
        try testing.expect(x.to != null);
        try testing.expectEqualStrings("/about", x.to.?);
    }
}

test "write: a redirect this run cannot resolve says so instead of inventing one" {
    const gpa = testing.allocator;
    var rs = [_]route_mod.Route{tNamed("GET", "/old", "pages", "old", 2, "old")};
    var vs = [_]classify.Verdict{tVerdict(.redirect)};
    var rts = [_]rails.RouteTemplates{.{ .templates = &.{}, .layout = null }};
    // `redirect_to @post`: the sidecar could not reduce it to a target.
    var dyn = [_]controllers.RedirectInfo{.{ .dynamic = true }};
    var actions = [_]controllers.ActionInfo{
        .{ .controller = "pages", .action = "old", .only_redirect = true, .redirects = &dyn },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.actions = &actions;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(@as(usize, 1), res.redirects.len);
    try testing.expect(res.redirects[0].to == null);
    try testing.expect(res.routes[0].note != null);
    try testing.expect(std.mem.indexOf(
        u8,
        res.routes[0].note.?,
        "redirect target is request-time state",
    ) != null);
}

/// A sign-in flow: `sessions#new` renders a password form, `sessions#create`
/// takes the submission. Assumption A5 folds both into ONE
/// `RAILS_AUTH_JOURNEY` finding, keyed on the smallest `routes.rb` line.
fn journeyDiscovery() struct {
    routes: [3]route_mod.Route,
    verdicts: [3]classify.Verdict,
} {
    return .{
        .routes = .{
            // `accounts` is not a journey controller by NAME. It is a journey
            // route because its view holds a password form -- A5's second
            // half, and the half a controller-name check alone would miss.
            tNamed("GET", "/login", "accounts", "new", 7, "login"),
            tNamed("POST", "/session", "sessions", "create", 5, "session"),
            tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
        },
        .verdicts = .{ tVerdict(.content), tVerdict(.backend), tVerdict(.content) },
    };
}

/// A sign-in form: one `password_field` inside one `form_with`.
fn passwordFormNodes() [3]fragments.Node {
    return .{
        tOpen(.form, 1, 4, null, "form_with(url: session_path) do |f|"),
        tArgs(.form_field, 1, 40, "password_field", &.{"password"}),
        tEnd(1, 70),
    };
}

test "write: the auth-journey finding rides on every journey route (ruling S21)" {
    const gpa = testing.allocator;
    // The seam this stage owns. `RAILS_AUTH_JOURNEY` is keyed on ONE line, so
    // only the route whose own declaration is that line could ever recompute
    // the id -- and even that one is a coincidence. Without the push, a
    // `retain` on the journey settles nothing and `GET /session/new` stays
    // open forever, which is exactly what `tests/migrate/rails-presentation.sh`
    // run 2 was failing on.
    const view_nodes = passwordFormNodes();
    const login_nodes = passwordFormNodes();
    const frags = [_]fragments.Template{
        tTemplate("app/views/accounts/new.html.erb", &login_nodes),
        tTemplate("app/views/sessions/new.html.erb", &view_nodes),
    };
    var j = journeyDiscovery();
    var login_tpls = [_][]const u8{"app/views/accounts/new.html.erb"};
    var new_tpls = [_][]const u8{"app/views/sessions/new.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &login_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &new_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{
        "app/views/accounts/new.html.erb",
        null,
        "app/views/sessions/new.html.erb",
    };
    const route_names = [_][]const u8{ "login", "session", "new_session" };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &j.routes,
        .classifications = &j.verdicts,
        .route_views = &route_views,
    });
    defer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
    }
    try testing.expect(journey_id.len > 0);
    var decided = [_]decisions.Decision{.{
        .id = journey_id,
        .choice = "retain",
        .rationale = "sign-in stays on Rails for now",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &j.routes;
    d.classifications = &j.verdicts;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    for (res.routes) |o| {
        // Both halves of the journey carry the id, the `backend` one included:
        // that is what lets assumption A2 count it as answered.
        try testing.expect(contains(o.open_finding_ids, journey_id));
        try testing.expectEqualStrings(journey_id, o.decision_id orelse "");
        const expected: Status = if (std.mem.eql(u8, j.routes[o.route_index].verb, "GET"))
            .retained
        else
            .backend;
        try testing.expectEqual(expected, o.status);
    }
    // Ruling S20: `retain` means the page stays on Rails, so nothing is
    // written for it -- including the route that is only a journey route
    // because of the password form in its view.
    try testing.expect(!targetHas(&tmp, "content/session/new/index.smd"));
    try testing.expect(!targetHas(&tmp, "content/login/index.smd"));
}

test "write: island on the auth journey with no collection to name scaffolds nothing" {
    const gpa = testing.allocator;
    // The guard behind Task 5's scaffolds. `island` names a ZigBase auth
    // collection in its `artifact` (assumption A4), and without one there is
    // nothing for `zb.collection(...)` to call -- so no island is emitted and
    // the route stays open saying so, rather than reporting `migrated` on an
    // answer nothing acted on. `decisions.parse` rejects this file, so the
    // only way here is a hand-built `Parsed`; the arm is the invariant guard
    // that keeps it from mattering.
    const view_nodes = passwordFormNodes();
    const login_nodes = passwordFormNodes();
    const frags = [_]fragments.Template{
        tTemplate("app/views/accounts/new.html.erb", &login_nodes),
        tTemplate("app/views/sessions/new.html.erb", &view_nodes),
    };
    var j = journeyDiscovery();
    var login_tpls = [_][]const u8{"app/views/accounts/new.html.erb"};
    var new_tpls = [_][]const u8{"app/views/sessions/new.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &login_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &new_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{
        "app/views/accounts/new.html.erb",
        null,
        "app/views/sessions/new.html.erb",
    };
    const route_names = [_][]const u8{ "login", "session", "new_session" };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &j.routes,
        .classifications = &j.verdicts,
        .route_views = &route_views,
    });
    defer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
    }
    var decided = [_]decisions.Decision{.{
        .id = journey_id,
        .choice = "island",
        .rationale = "sign-in becomes a ZigBase auth island",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &j.routes;
    d.classifications = &j.verdicts;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    for (res.routes) |o| {
        if (!std.mem.eql(u8, j.routes[o.route_index].verb, "GET")) continue;
        try testing.expectEqual(Status.open, o.status);
        try testing.expect(std.mem.indexOf(
            u8,
            o.note orelse "",
            "choice island on RAILS_AUTH_JOURNEY needs the auth scaffolds",
        ) != null);
    }
}

test "write: `public` on an auth guard ships the page and records the decision (assumption A7)" {
    const gpa = testing.allocator;
    // A static page cannot enforce `before_action :require_login`. The finding
    // is the question; `public` is the operator saying "ship it, the ZigBase
    // rules protect the data" -- so the page IS written and the route reaches
    // `migrated`, with the guard named in the note so nobody has to re-derive
    // why it was safe.
    const view_nodes = [_]fragments.Node{tText("<h1>Dashboard</h1>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/posts/index.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tNamed("GET", "/posts", "posts", "index", 4, "posts")};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/posts/index.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};
    const route_views = [_]?[]const u8{"app/views/posts/index.html.erb"};
    const route_names = [_][]const u8{"posts"};
    var before = [_]controllers.BeforeAction{
        .{ .controller = "posts", .name = "require_login", .line = 2 },
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .filters = .{ .before_actions = &before },
    });
    defer findings.free(gpa, finding_list);

    var guard_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_route_auth_guard)) guard_id = f.id;
    }
    try testing.expect(guard_id.len > 0);
    var decided = [_]decisions.Decision{.{
        .id = guard_id,
        .choice = "public",
        .rationale = "the list is public; the collection rule guards the data",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;
    d.before_actions = &before;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(Status.migrated, res.routes[0].status);
    try testing.expectEqual(@as(usize, 0), res.routes[0].open_finding_ids.len);
    try testing.expect(std.mem.indexOf(
        u8,
        res.routes[0].note orelse "",
        "guarded by before_action :require_login; shipped public by decision",
    ) != null);
    try testing.expect(targetHas(&tmp, "content/posts/index.smd"));

    // ... and an UNANSWERED guard keeps the route open: shipping it silently
    // public is the "looks migrated, isn't" the finding exists to prevent.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    const target2 = try tmpTarget(gpa, &tmp2);
    defer gpa.free(target2);
    var err_path2: ?[]const u8 = null;
    defer if (err_path2) |p| gpa.free(p);
    var err_cause2: ?anyerror = null;
    const res2 = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &.{}, .stale = &.{} },
        .source_root = tmp2.dir,
        .target = target2,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path2, &err_cause2);
    defer freeResult(gpa, res2);
    try testing.expectEqual(Status.open, res2.routes[0].status);
    try testing.expect(contains(res2.routes[0].open_finding_ids, guard_id));
}

test "write: the `public` note names the same guard the finding named" {
    const gpa = testing.allocator;
    // Two auth-looking `before_action`s on one controller, ordered so that
    // CHAIN order and NAME order disagree: `require_login` is declared first,
    // `authenticate_user!` sorts first.
    //
    // The finding picks the smallest `(name, line)` on purpose -- the chain's
    // own order within a controller is whatever order the sidecar's directory
    // walk emitted, and a filter NAME printed into the manifest has to be the
    // same on every machine. The note picked the first hit in chain order
    // instead, so the two rows describing one decision named two different
    // filters, and an operator reading the handoff had no way to tell which
    // one their `public` had actually been asked about.
    const view_nodes = [_]fragments.Node{tText("<h1>Dashboard</h1>", 1)};
    const frags = [_]fragments.Template{tTemplate("app/views/posts/index.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tNamed("GET", "/posts", "posts", "index", 4, "posts")};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/posts/index.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};
    const route_views = [_]?[]const u8{"app/views/posts/index.html.erb"};
    const route_names = [_][]const u8{"posts"};
    var before = [_]controllers.BeforeAction{
        .{ .controller = "posts", .name = "require_login", .line = 3 },
        .{ .controller = "posts", .name = "authenticate_user!", .line = 2 },
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .filters = .{ .before_actions = &before },
    });
    defer findings.free(gpa, finding_list);

    var guard_id: []const u8 = "";
    var guard_message: []const u8 = "";
    for (finding_list) |f| {
        if (!std.mem.eql(u8, f.code, findings.code_route_auth_guard)) continue;
        guard_id = f.id;
        guard_message = f.message;
    }
    try testing.expect(guard_id.len > 0);
    // The finding's own pick, restated so a change to it fails here too.
    try testing.expect(std.mem.indexOf(u8, guard_message, "authenticate_user!") != null);
    try testing.expect(std.mem.indexOf(u8, guard_message, "require_login") == null);

    var decided = [_]decisions.Decision{.{
        .id = guard_id,
        .choice = "public",
        .rationale = "the list is public; the collection rule guards the data",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;
    d.before_actions = &before;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const note = res.routes[0].note orelse return error.NoNote;
    try testing.expect(std.mem.indexOf(
        u8,
        note,
        "guarded by before_action :authenticate_user!; shipped public by decision",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, note, "require_login") == null);
}

// ---- ruling S3-R7: every answer on a route is applied ---------------------

const r7_view = "app/views/posts/index.html.erb";
/// Both controls live in one view, so they flatten to one stem and the second
/// takes the `_2` ordinal (see `islandPath`).
const r7_island_1 = "components/forms/posts_index.island.tsx";
const r7_island_2 = "components/forms/posts_index_2.island.tsx";

/// One `write` over a page carrying THREE answerable things at once: a
/// `link_to` that mutates, a `form_with` that mutates, and the controller's
/// `before_action :require_login`. Answered as ruling S3-R7's own shape they
/// are all rank 2, so which single one was carried out came down to the
/// tie-break on the finding id -- and the guard's id sorts last.
const R7Run = struct {
    tmp: std.testing.TmpDir,
    res: Result,
    finding_list: []findings.Finding,
    /// Borrowed from `finding_list`.
    guard_id: []const u8,

    fn deinit(self: *R7Run, gpa: Allocator) void {
        freeResult(gpa, self.res);
        findings.free(gpa, self.finding_list);
        self.tmp.cleanup();
    }
};

/// Which answers the decisions file carries.
///
/// `bound_and_public` is the shape ruling S3-R7 is about. `retain_control`
/// keeps that shape and answers the LINK `retain` instead of binding it, so
/// the route carries an acknowledgement and a `public` at once -- rank 3 and
/// rank 2 -- which is how the rank and the stop after an acknowledgement are
/// pinned without either assertion going vacuous. `guard_unanswered` answers
/// only the two controls, so the guard has nothing to settle it and must stay
/// open; without it the first case would pass on a route that had no open
/// guard to begin with.
const R7Answers = enum { bound_and_public, retain_control, guard_unanswered };

fn runR7(gpa: Allocator, answered: R7Answers) !R7Run {
    const link_attrs = [_]fragments.Attr{.{ .key = "method", .value = "delete" }};
    const link_args = [_][]const u8{"Delete first"};
    const nodes = [_]fragments.Node{
        tLink(
            2,
            5,
            "logout",
            &link_args,
            &link_attrs,
            "link_to \"Delete first\", logout_path, data: { method: :delete }",
        ),
        tOpen(.form, 3, 4, "beta", "form_with(url: \"/api/beta\") do |f|"),
        tArgs(.form_field, 3, 40, "text_field", &.{"beta_field"}),
        tArgs(.form_field, 3, 60, "submit", &.{"Go"}),
        tEnd(3, 80),
    };
    const frags = [_]fragments.Template{tTemplate(r7_view, &nodes)};
    var rs = [_]route_mod.Route{
        tNamed("GET", "/posts", "posts", "index", 2, "posts"),
        tNamed("DELETE", "/logout", "posts", "destroy", 4, "logout"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.backend) };
    var tpls = [_][]const u8{r7_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    const route_views = [_]?[]const u8{ r7_view, null };
    const route_names = [_][]const u8{ "posts", "logout" };
    var before = [_]controllers.BeforeAction{
        .{ .controller = "posts", .name = "require_login", .line = 2 },
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .filters = .{ .before_actions = &before },
    });
    errdefer findings.free(gpa, finding_list);

    var link_id: []const u8 = "";
    var form_id: []const u8 = "";
    var guard_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_route_auth_guard)) guard_id = f.id;
        if (!std.mem.eql(u8, f.code, findings.code_backend_endpoint)) continue;
        if (!std.mem.eql(u8, f.path, r7_view)) continue;
        if (f.line == 2) link_id = f.id else form_id = f.id;
    }
    try testing.expect(link_id.len > 0 and form_id.len > 0 and guard_id.len > 0);
    // The whole point of the ruling: the guard's id sorts AFTER both control
    // ids, so `pickDecision`'s smallest-id tie-break never reached it.
    try testing.expect(std.mem.order(u8, link_id, guard_id) == .lt);
    try testing.expect(std.mem.order(u8, form_id, guard_id) == .lt);

    var all_decided = [_]decisions.Decision{
        .{
            .id = link_id,
            .choice = if (answered == .retain_control) "retain" else "custom:/api/logout",
            .rationale = "the link deletes a record",
            .artifact = null,
        },
        .{ .id = form_id, .choice = "custom:/api/beta", .rationale = "the form posts a record", .artifact = null },
        .{ .id = guard_id, .choice = "public", .rationale = "the collection rule guards the data", .artifact = null },
    };
    const decided: []decisions.Decision = switch (answered) {
        .bound_and_public, .retain_control => all_decided[0..3],
        .guard_unanswered => all_decided[0..2],
    };

    var redirects = [_]controllers.RedirectInfo{.{ .name = "posts", .args = &.{} }};
    var actions = [_]controllers.ActionInfo{.{
        .controller = "posts",
        .action = "destroy",
        .redirects = &redirects,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;
    d.actions = &actions;
    d.before_actions = &before;

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    return .{
        .tmp = tmp,
        .res = res,
        .finding_list = finding_list,
        .guard_id = guard_id,
    };
}

fn r7Page(r7: *const R7Run) RouteOutcome {
    for (r7.res.routes) |o| {
        if (o.status != .backend) return o;
    }
    unreachable;
}

test "write: a bound mutation and a `public` guard on one route both apply (ruling S3-R7)" {
    const gpa = testing.allocator;
    // Two answers, two different questions: the controls are bound to backend
    // operations and the guard is shipped public. Applying only the strongest
    // -- and both are rank 2, so "strongest" was decided by which finding id
    // sorted first -- left the guard's id open and the route `open`, with no
    // note saying why. The operator's answer was read, validated, and then
    // silently dropped.
    var r7 = try runR7(gpa, .bound_and_public);
    defer r7.deinit(gpa);

    const page = r7Page(&r7);
    try testing.expectEqual(Status.migrated, page.status);
    try testing.expectEqual(@as(usize, 0), page.open_finding_ids.len);
    try testing.expect(std.mem.indexOf(
        u8,
        page.note orelse "",
        "guarded by before_action :require_login; shipped public by decision",
    ) != null);
    try testing.expect(targetHas(&r7.tmp, "content/posts/index.smd"));
    // The handoff's one decision slot still names the answer `pickDecision`
    // would have returned -- the smallest id of the top rank -- so widening
    // what RUNS did not change what the row reports as having decided it.
    try testing.expect(std.mem.order(u8, page.decision_id.?, r7.guard_id) == .lt);
}

test "write: a `retain` still outranks a `public` on the same route (ruling S3-R7)" {
    const gpa = testing.allocator;
    // The ruling widens WHICH answers run, not the rank that decides the
    // route: the link is answered `retain` (rank 3) and the guard `public`
    // (rank 2), so the page stays on Rails and ruling S20's no-page rule is
    // unchanged.
    var r7 = try runR7(gpa, .retain_control);
    defer r7.deinit(gpa);

    const page = r7Page(&r7);
    try testing.expectEqual(Status.retained, page.status);
    try testing.expect(!targetHas(&r7.tmp, "content/posts/index.smd"));
    // And the answers BELOW the acknowledgement do not run: `retain` moots
    // them, and `public`'s note says a guarded page is shipping -- which on a
    // route that stays on Rails would be a note about work not happening.
    try testing.expect(std.mem.indexOf(
        u8,
        page.note orelse "",
        "shipped public by decision",
    ) == null);
}

test "write: two bound controls on one route each settle their own finding (ruling S3-R7)" {
    const gpa = testing.allocator;
    // Deviation D's shape without the guard: one page, two mutating controls,
    // two answers. Only one of the two ids was settled before, so a page whose
    // every control was answered still reported one of them open -- and the
    // second island was on disk the whole time, which is what makes the row
    // wrong rather than merely conservative.
    var r7 = try runR7(gpa, .guard_unanswered);
    defer r7.deinit(gpa);

    const page = r7Page(&r7);
    try testing.expect(targetHas(&r7.tmp, r7_island_1));
    try testing.expect(targetHas(&r7.tmp, r7_island_2));
    // The guard is the ONLY thing left: both control answers settled.
    try testing.expectEqual(@as(usize, 1), page.open_finding_ids.len);
    try testing.expectEqualStrings(r7.guard_id, page.open_finding_ids[0]);
    try testing.expectEqual(Status.open, page.status);
}

test "write: data backend choice without a document names the required list operation" {
    const gpa = testing.allocator;
    // The choice is still offered (a `@posts` read could in principle become a
    // data-fetching island) and no stage has a converter for it. Stage 2's
    // note said "deferred to Stage 3"; this IS Stage 3, so the note has to
    // stop promising and point at the issue that tracks it.
    const view_nodes = [_]fragments.Node{tNode(.ivar, 1, 4, "posts")};
    const frags = [_]fragments.Template{tTemplate("app/views/posts/index.html.erb", &view_nodes)};
    var rs = [_]route_mod.Route{tNamed("GET", "/posts", "posts", "index", 4, "posts")};
    var vs = [_]classify.Verdict{tVerdict(.content)};
    var tpls = [_][]const u8{"app/views/posts/index.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpls, .layout = null }};

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{"posts"},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer findings.free(gpa, finding_list);

    var state_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, "RAILS_REQUEST_TIME_STATE")) state_id = f.id;
    }
    try testing.expect(state_id.len > 0);
    var decided = [_]decisions.Decision{.{
        .id = state_id,
        .choice = "backend",
        .rationale = "the list should come from ZigBase",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expectEqual(Status.open, res.routes[0].status);
    try testing.expect(std.mem.indexOf(
        u8,
        res.routes[0].note orelse "",
        "choice backend on RAILS_REQUEST_TIME_STATE needs a --backend document with a list operation for collection `posts`",
    ) != null);
}

test "write: a second bound form in one view gets its own island, numbered in source order" {
    const gpa = testing.allocator;
    // One `.island.tsx` per bound region, and the name has to distinguish them
    // -- two forms in `posts/new.html.erb` would otherwise both claim
    // `components/forms/posts_new.island.tsx` and the second write would trip
    // the exclusive-create guard.
    const view_nodes = [_]fragments.Node{
        tOpen(.form, 1, 4, "post", "form_with(model: @post) do |f|"),
        tArgs(.form_field, 1, 40, "submit", &.{"First"}),
        tEnd(1, 60),
        tOpen(.form, 2, 4, "post", "form_with(model: @post) do |g|"),
        tArgs(.form_field, 2, 40, "submit", &.{"Second"}),
        tEnd(2, 60),
    };
    const frags = [_]fragments.Template{tTemplate(bound_view, &view_nodes)};
    var rs = [_]route_mod.Route{
        tNamed("POST", "/posts", "posts", "create", 2, "posts"),
        tNamed("GET", "/posts/new", "posts", "new", 2, "new_post"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.backend), tVerdict(.content) };
    var new_tpls = [_][]const u8{bound_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &new_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{ null, bound_view };
    const route_names = [_][]const u8{ "posts", "new_post" };

    const doc = try backend_mod.parse(gpa, bound_document, "openapi.json");
    defer backend_mod.free(gpa, doc);
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .backend = doc,
    });
    defer findings.free(gpa, finding_list);

    var ids: [2][]const u8 = .{ "", "" };
    var n: usize = 0;
    for (finding_list) |f| {
        if (!std.mem.eql(u8, f.code, findings.code_backend_endpoint)) continue;
        if (!std.mem.eql(u8, f.path, bound_view)) continue;
        if (n < 2) ids[n] = f.id;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    var decided = [_]decisions.Decision{
        .{ .id = ids[0], .choice = "createPosts", .rationale = "first form", .artifact = null },
        .{ .id = ids[1], .choice = "createPosts", .rationale = "second form", .artifact = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .backend = doc,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    try testing.expect(targetHas(&tmp, bound_island));
    try testing.expect(targetHas(&tmp, "components/forms/posts_new_2.island.tsx"));
    const second = try readTarget(gpa, &tmp, "components/forms/posts_new_2.island.tsx");
    defer gpa.free(second);
    // Named after the file, so the two components cannot collide either.
    try testing.expect(std.mem.indexOf(u8, second, "export default function PostsNew2(") != null);
    try testing.expect(std.mem.indexOf(u8, second, "{\"Second\"}</button>") != null);

    // `build.sh` lists both, sorted -- the flag list is output, and output is
    // byte-identical for identical input.
    const build_sh = try readTarget(gpa, &tmp, "build.sh");
    defer gpa.free(build_sh);
    const a = std.mem.indexOf(u8, build_sh, "--island='" ++ bound_island ++ "'").?;
    const b = std.mem.indexOf(u8, build_sh, "--island='components/forms/posts_new_2.island.tsx'").?;
    try testing.expect(a < b);
}

/// Two view stems that flatten to ONE island name: `a_b/new` and `a/b_new`
/// both become `a_b_new` once `islandPath` replaces `/` with `_`.
const collide_view_a = "app/views/a_b/new.html.erb";
const collide_view_b = "app/views/a/b_new.html.erb";

test "write: two views whose stems flatten to one island name get two islands, not one" {
    const gpa = testing.allocator;
    // `islandPath` flattens `/` to `_` (so the built site's `/islands/<name>.js`
    // basenames stay distinct), which makes `app/views/a_b/new.html.erb` and
    // `app/views/a/b_new.html.erb` claim the same file. These are two
    // TEMPLATES, two findings and two answered endpoints -- not the shared
    // `_form` partial `materializeView` deduplicates -- so collapsing them
    // shipped `/y` with `/x`'s form, pointing at `/api/alpha`, and still
    // reported both routes `migrated` with nothing open. The name has to be
    // de-collided, and the write-once skip has to key on the BINDING.
    const nodes_a = [_]fragments.Node{
        tOpen(.form, 2, 4, "alpha", "form_with(url: \"/api/alpha\") do |f|"),
        tArgs(.form_field, 2, 40, "text_field", &.{"alpha_field"}),
        tArgs(.form_field, 2, 60, "submit", &.{"Alpha"}),
        tEnd(2, 80),
    };
    const nodes_b = [_]fragments.Node{
        tOpen(.form, 2, 4, "beta", "form_with(url: \"/api/beta\") do |f|"),
        tArgs(.form_field, 2, 40, "text_field", &.{"beta_field"}),
        tArgs(.form_field, 2, 60, "submit", &.{"Beta"}),
        tEnd(2, 80),
    };
    const frags = [_]fragments.Template{
        tTemplate(collide_view_a, &nodes_a),
        tTemplate(collide_view_b, &nodes_b),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/x", "a_b", "new", 2, "x"),
        tNamed("GET", "/y", "a", "b_new", 3, "y"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var tpls_a = [_][]const u8{collide_view_a};
    var tpls_b = [_][]const u8{collide_view_b};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls_a, .layout = null },
        .{ .templates = &tpls_b, .layout = null },
    };
    const route_views = [_]?[]const u8{ collide_view_a, collide_view_b };
    const route_names = [_][]const u8{ "x", "y" };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .backend = null,
    });
    defer findings.free(gpa, finding_list);

    // A `custom:` answer, so the two endpoints differ in a way the island's
    // own source spells out (`zb.send(..., "/api/alpha")`) -- which is the
    // only way to see WHICH form a page ended up shipping.
    var id_a: []const u8 = "";
    var id_b: []const u8 = "";
    for (finding_list) |f| {
        if (!std.mem.eql(u8, f.code, findings.code_backend_endpoint)) continue;
        if (std.mem.eql(u8, f.path, collide_view_a)) id_a = f.id;
        if (std.mem.eql(u8, f.path, collide_view_b)) id_b = f.id;
    }
    try testing.expect(id_a.len > 0 and id_b.len > 0);
    var decided = [_]decisions.Decision{
        .{ .id = id_a, .choice = "custom:/api/alpha", .rationale = "alpha form", .artifact = null },
        .{ .id = id_b, .choice = "custom:/api/beta", .rationale = "beta form", .artifact = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .backend = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    for (res.routes) |o| try testing.expectEqual(Status.migrated, o.status);

    // Two files, and `build.sh` bundles both.
    try testing.expect(targetHas(&tmp, "components/forms/a_b_new.island.tsx"));
    try testing.expect(targetHas(&tmp, "components/forms/a_b_new_2.island.tsx"));
    const build_sh = try readTarget(gpa, &tmp, "build.sh");
    defer gpa.free(build_sh);
    try testing.expectEqual(@as(usize, 2), countOccurrences(build_sh, "--island="));

    // Each page references its OWN island, and that island calls its OWN
    // endpoint. Read the reference out of the layout rather than assuming
    // which view won the un-suffixed name: the property under test is the
    // pairing, not the numbering.
    const layout_a = try readTarget(gpa, &tmp, "layouts/a_b/new.shtml");
    defer gpa.free(layout_a);
    const layout_b = try readTarget(gpa, &tmp, "layouts/a/b_new.shtml");
    defer gpa.free(layout_b);
    const src_a = try islandSrcOf(gpa, layout_a);
    defer gpa.free(src_a);
    const src_b = try islandSrcOf(gpa, layout_b);
    defer gpa.free(src_b);
    try testing.expect(!std.mem.eql(u8, src_a, src_b));

    const island_a = try readTarget(gpa, &tmp, src_a);
    defer gpa.free(island_a);
    const island_b = try readTarget(gpa, &tmp, src_b);
    defer gpa.free(island_b);
    try testing.expect(std.mem.indexOf(u8, island_a, "zb.send(\"POST\", \"/api/alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, island_b, "zb.send(\"POST\", \"/api/beta\"") != null);
    // …generated from its own template, so the header an operator reviews
    // against the ERB names the file they would actually open.
    try testing.expect(std.mem.indexOf(u8, island_a, "from " ++ collide_view_a ++ ":2.") != null);
    try testing.expect(std.mem.indexOf(u8, island_b, "from " ++ collide_view_b ++ ":2.") != null);
}

/// The `src` of the first `<island …>` in `bytes`.
///
/// Contract 1 (self-freeing): the returned path is the only allocation.
fn islandSrcOf(gpa: Allocator, bytes: []const u8) ![]u8 {
    const marker = "<island src=\"";
    const at = std.mem.indexOf(u8, bytes, marker) orelse return error.NoIsland;
    const rest = bytes[at + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.NoIsland;
    return gpa.dupe(u8, rest[0..end]);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |i| {
        n += 1;
        at = i + needle.len;
    }
    return n;
}

/// One `link_to`/`button_to` node as `classify_link` reports it.
fn tLink(
    line: u64,
    col: u64,
    stem: ?[]const u8,
    args: []const []const u8,
    attrs: []const fragments.Attr,
    code: []const u8,
) fragments.Node {
    var n = tNode(.link_to, line, col, stem);
    n.args = args;
    n.attrs = attrs;
    n.code = code;
    return n;
}

const link_view = "app/views/a_b/new.html.erb";
const form_view = "app/views/a/b_new.html.erb";

/// One whole `write` over a fixture holding a bound `button_to` on `GET /x`,
/// a bound form on `GET /y`, and the `DELETE /logout` route the button
/// submits to. The two view stems flatten to ONE island name, so the run also
/// exercises the de-collision against a form island of the same stem.
const BoundLinkRun = struct {
    tmp: std.testing.TmpDir,
    res: Result,
    finding_list: []findings.Finding,

    fn deinit(self: *BoundLinkRun, gpa: Allocator) void {
        freeResult(gpa, self.res);
        findings.free(gpa, self.finding_list);
        self.tmp.cleanup();
    }
};

/// What the decision file says about the link's page. `retained_page` gives
/// the link's view a SECOND finding and answers it `retain`, which is how
/// ruling S20 is reached: the route stays on Rails, so no page and no island
/// are written for it. `link_unanswered` answers only the form, leaving the
/// link's own `RAILS_BACKEND_ENDPOINT` standing.
const BoundLinkMode = enum { bound, retained_page, link_unanswered };

fn runBoundLink(gpa: Allocator, mode: BoundLinkMode) !BoundLinkRun {
    const retain_page = mode == .retained_page;
    const link_attrs = [_]fragments.Attr{
        .{ .key = "method", .value = "delete" },
        .{ .key = "data-confirm", .value = "Sure?" },
    };
    const link_args = [_][]const u8{"Sign out"};
    const all_link_nodes = [_]fragments.Node{
        tLink(
            2,
            5,
            "logout",
            &link_args,
            &link_attrs,
            "button_to \"Sign out\", logout_path, method: :delete",
        ),
        tNode(.ivar, 3, 5, "@who"),
    };
    const link_nodes: []const fragments.Node =
        if (retain_page) all_link_nodes[0..2] else all_link_nodes[0..1];
    const form_nodes = [_]fragments.Node{
        tOpen(.form, 2, 4, "beta", "form_with(url: \"/api/beta\") do |f|"),
        tArgs(.form_field, 2, 40, "text_field", &.{"beta_field"}),
        tArgs(.form_field, 2, 60, "submit", &.{"Beta"}),
        tEnd(2, 80),
    };
    const frags = [_]fragments.Template{
        tTemplate(link_view, link_nodes),
        tTemplate(form_view, &form_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/x", "a_b", "new", 2, "x"),
        tNamed("GET", "/y", "a", "b_new", 3, "y"),
        tNamed("DELETE", "/logout", "a_b", "destroy", 4, "logout"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content), tVerdict(.backend) };
    var tpls_link = [_][]const u8{link_view};
    var tpls_form = [_][]const u8{form_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls_link, .layout = null },
        .{ .templates = &tpls_form, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    const route_views = [_]?[]const u8{ link_view, form_view, null };
    const route_names = [_][]const u8{ "x", "y", "logout" };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .backend = null,
    });
    errdefer findings.free(gpa, finding_list);

    var link_id: []const u8 = "";
    var form_id: []const u8 = "";
    var ivar_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint)) {
            if (std.mem.eql(u8, f.path, link_view)) link_id = f.id;
            if (std.mem.eql(u8, f.path, form_view)) form_id = f.id;
        } else if (std.mem.eql(u8, f.path, link_view)) ivar_id = f.id;
    }
    try testing.expect(link_id.len > 0 and form_id.len > 0);
    try testing.expectEqual(retain_page, ivar_id.len > 0);
    var all_decided = [_]decisions.Decision{
        .{ .id = link_id, .choice = "custom:/api/logout", .rationale = "sign out", .artifact = null },
        .{ .id = form_id, .choice = "custom:/api/beta", .rationale = "beta form", .artifact = null },
        .{ .id = ivar_id, .choice = "retain", .rationale = "stays on Rails", .artifact = null },
    };
    const decided: []decisions.Decision = switch (mode) {
        .bound => all_decided[0..2],
        .retained_page => all_decided[0..3],
        .link_unanswered => all_decided[1..2],
    };

    // `a_b#destroy` redirects home, and that is where the island sends the
    // browser: the redirect is the MUTATING action's, and for a link the
    // mutating action is the one its own target route runs.
    var redirects = [_]controllers.RedirectInfo{.{ .name = "x", .args = &.{} }};
    var actions = [_]controllers.ActionInfo{.{
        .controller = "a_b",
        .action = "destroy",
        .redirects = &redirects,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;
    d.actions = &actions;

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .backend = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);

    return .{ .tmp = tmp, .res = res, .finding_list = finding_list };
}

fn outcomeFor(res: Result, route_index: usize) ?RouteOutcome {
    for (res.routes) |o| {
        if (o.route_index == route_index) return o;
    }
    return null;
}

/// `runBoundLink`'s route table, by index: the page holding the bound link,
/// the page holding the bound form, and the route the link submits to.
const link_page = 0;
const form_page = 1;
const link_target = 2;

test "write: a bound button_to becomes a click island, and its endpoint lands on the route it deletes" {
    const gpa = testing.allocator;
    // Task 5's concern 1. The binding existed and nothing consumed it: the
    // control converted to an `<a href>` to the very route it was supposed to
    // DELETE, no island file was written, and the route was reported bound
    // anyway. Everything asserted here was absent before the fix.
    var linked = try runBoundLink(gpa, .bound);
    defer linked.deinit(gpa);

    for (linked.res.routes) |o| try testing.expect(o.status != .open);

    // Two islands under one flattened stem: the link's and the form's. The
    // de-collision is the same one that keeps two forms apart, and a click
    // island is not exempt from it.
    try testing.expect(targetHas(&linked.tmp, "components/forms/a_b_new.island.tsx"));
    try testing.expect(targetHas(&linked.tmp, "components/forms/a_b_new_2.island.tsx"));
    const build_sh = try readTarget(gpa, &linked.tmp, "build.sh");
    defer gpa.free(build_sh);
    try testing.expectEqual(@as(usize, 2), countOccurrences(build_sh, "--island="));

    // The page mounts it, and the `<a href="/logout">` the old conversion
    // produced is gone.
    const layout = try readTarget(gpa, &linked.tmp, "layouts/a_b/new.shtml");
    defer gpa.free(layout);
    try testing.expect(std.mem.indexOf(u8, layout, "<a href") == null);
    const src = try islandSrcOf(gpa, layout);
    defer gpa.free(src);
    const island = try readTarget(gpa, &linked.tmp, src);
    defer gpa.free(island);

    // A button, not a form; the link's own text as the label; Rails'
    // `data-confirm` still in front of the request; the answered call; and
    // the target action's own `redirect_to` after it.
    try testing.expect(std.mem.indexOf(u8, island, "<form") == null);
    try testing.expect(std.mem.indexOf(u8, island, "<button type=\"button\" onClick={onClick}>{\"Sign out\"}</button>") != null);
    try testing.expect(std.mem.indexOf(u8, island, "if (!window.confirm(\"Sure?\")) return;") != null);
    try testing.expect(std.mem.indexOf(u8, island, "await zb.send(\"DELETE\", \"/api/logout\");") != null);
    try testing.expect(std.mem.indexOf(u8, island, "location.assign(\"/x\");") != null);
    try testing.expect(std.mem.indexOf(u8, island, "isZigbaseError(err)") != null);
    try testing.expect(std.mem.startsWith(
        u8,
        island,
        "// Generated by `zigapagos migrate --from rails` from " ++ link_view ++ ":2.",
    ));

    // The endpoint lands on the route the link SUBMITS to, not on the page it
    // sits on: `DELETE /logout`, by name and verb.
    const target_route = outcomeFor(linked.res, link_target) orelse return error.NoRoute;
    const ep = target_route.endpoint orelse return error.NoEndpoint;
    try testing.expectEqualStrings("custom", ep.operation_id);
    try testing.expectEqualStrings("DELETE", ep.verb);
    try testing.expectEqualStrings("/api/logout", ep.path);
    // …and never on a page route, which submits nothing.
    const page = outcomeFor(linked.res, link_page) orelse return error.NoRoute;
    try testing.expect(page.endpoint == null);
    const form = outcomeFor(linked.res, form_page) orelse return error.NoRoute;
    try testing.expect(form.endpoint == null);
    try testing.expectEqual(Status.migrated, form.status);
}

test "write: a retained page writes no click island, exactly as it writes no form island" {
    const gpa = testing.allocator;
    // Ruling S20, restated for the new shape. A `retain` answer on another of
    // the page's findings outranks the binding: the URL stays on Rails, so
    // the page is not written -- and neither is its island, which would
    // otherwise be dead source in the target with an `--island=` flag making
    // `release` bundle an entry no page mounts.
    var linked = try runBoundLink(gpa, .retained_page);
    defer linked.deinit(gpa);

    const page = outcomeFor(linked.res, link_page) orelse return error.NoRoute;
    try testing.expectEqual(Status.retained, page.status);
    try testing.expectEqual(@as(usize, 0), page.artifacts.len);
    try testing.expect(!targetHas(&linked.tmp, "layouts/a_b/new.shtml"));

    // The FORM island beside it still ships -- the ruling is per route, not
    // per run. It keeps the `_2` the de-collision gave it: names are handed
    // out in the binding pass, which runs before any acknowledgement is read,
    // so a page dropping out does not renumber the pages that stay. Only the
    // WRITE is skipped, and `build.sh` carries exactly one flag.
    try testing.expect(!targetHas(&linked.tmp, "components/forms/a_b_new.island.tsx"));
    try testing.expect(targetHas(&linked.tmp, "components/forms/a_b_new_2.island.tsx"));
    const build_sh = try readTarget(gpa, &linked.tmp, "build.sh");
    defer gpa.free(build_sh);
    try testing.expectEqual(@as(usize, 1), countOccurrences(build_sh, "--island="));

    // …and the endpoint still lands on `DELETE /logout`: the binding pass runs
    // before the route walk, so an acknowledgement on the PAGE cannot unanswer
    // the mutation the link performs.
    const target_route = outcomeFor(linked.res, link_target) orelse return error.NoRoute;
    const ep = target_route.endpoint orelse return error.NoEndpoint;
    try testing.expectEqualStrings("/api/logout", ep.path);
}

test "write: an unanswered mutating link keeps its page open, naming the link's finding" {
    const gpa = testing.allocator;
    // Round 4. Nothing answered the link, and the page came out `migrated`
    // with `complete` reachable: the conversion made the control an
    // `<a href="/logout">` and recorded no id, so the route had nothing in
    // `open_finding_ids` to stay open with. The spec's rule is that a route
    // is `open` while ANY finding on it is unanswered, and a form's already
    // was; this pins the link's.
    var linked = try runBoundLink(gpa, .link_unanswered);
    defer linked.deinit(gpa);

    var link_id: []const u8 = "";
    for (linked.finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint) and std.mem.eql(u8, f.path, link_view)) link_id = f.id;
    }
    try testing.expect(link_id.len > 0);

    const page = outcomeFor(linked.res, link_page) orelse return error.NoRoute;
    try testing.expectEqual(Status.open, page.status);
    try testing.expect(page.decision_id == null);
    try testing.expectEqual(@as(usize, 1), page.open_finding_ids.len);
    try testing.expectEqualStrings(link_id, page.open_finding_ids[0]);

    // An open page is a page with a gap in it, not an absent page: the view
    // is written, the gap is the link's region, and the GET to the DELETE
    // route is gone.
    const layout = try readTarget(gpa, &linked.tmp, "layouts/a_b/new.shtml");
    defer gpa.free(layout);
    const marker = try std.fmt.allocPrint(gpa, "<!-- rails:finding {s} -->", .{link_id});
    defer gpa.free(marker);
    try testing.expect(std.mem.indexOf(u8, layout, marker) != null);
    try testing.expect(std.mem.indexOf(u8, layout, "<a href") == null);
    try testing.expect(std.mem.indexOf(u8, layout, "<island") == null);

    // No click island was written for it -- only the form's, which is the
    // one `--island=` flag -- and no endpoint was paired onto the route the
    // link submits to: an unanswered question pairs nothing.
    const build_sh = try readTarget(gpa, &linked.tmp, "build.sh");
    defer gpa.free(build_sh);
    try testing.expectEqual(@as(usize, 1), countOccurrences(build_sh, "--island="));
    const target_route = outcomeFor(linked.res, link_target) orelse return error.NoRoute;
    try testing.expect(target_route.endpoint == null);
    const form = outcomeFor(linked.res, form_page) orelse return error.NoRoute;
    try testing.expectEqual(Status.migrated, form.status);
}

/// A click-island binding built by hand, so `emitClickIsland` can be pinned
/// shape by shape without a whole `write` per shape. `collection == null`
/// is the `custom:` answer, which goes through `zb.send`.
fn tClickBinding(verb: []const u8, collection: ?[]const u8) convert.Binding {
    return .{
        .finding_id = "RAILS_BACKEND_ENDPOINT.app/views/posts/show%2Ehtml%2Eerb.L3C5",
        .kind = if (collection == null) .custom else .operation,
        .verb = verb,
        .path = "/api/collections/posts/records",
        .operation_id = "op",
        .collection = collection,
        .island = "components/forms/posts_show.island.tsx",
        .redirect_to = "/posts",
    };
}

fn tClickSpec(b: convert.Binding, click: convert.Click) convert.IslandSpec {
    return .{
        .island = b.island,
        .fields = &.{},
        .errors_model = null,
        .submit_label = "Destroy",
        .click = click,
        .binding = b,
        .original = "link_to \"Destroy\", post_path(1), method: :delete",
        .line = 3,
        .source = "app/views/posts/show.html.erb",
    };
}

test "emitClickIsland: the delete shape, byte for byte" {
    const gpa = testing.allocator;
    // The whole file, because the parts that matter are positional: the
    // confirm BEFORE the request, the record id INSIDE the collection call,
    // the redirect AFTER it, and the error list -- the same markup the form
    // island renders, through the same emitter -- below the one button.
    const click: convert.Click = .{ .confirm = "Sure?", .record_id = "1" };
    const island = try emitClickIsland(gpa, tClickSpec(tClickBinding("DELETE", "posts"), click), click);
    defer gpa.free(island);
    try testing.expectEqualStrings(
        \\// Generated by `zigapagos migrate --from rails` from app/views/posts/show.html.erb:3.
        \\// Replaces: link_to "Destroy", post_path(1), method: :delete
        \\// Enforcement stays server-side: this island only presents the control and the
        \\// backend's errors; the ZigBase rule on the operation decides who may submit.
        \\import { useState } from "@z/runtime";
        \\import { isZigbaseError, type FieldError } from "@zigbase/client";
        \\import { zb } from "../../lib/zb";
        \\
        \\export interface Props {}
        \\
        \\export default function PostsShow(_props: Props) {
        \\  const [errors, setErrors] = useState<Record<string, FieldError>>({});
        \\  const [done, setDone] = useState(false);
        \\  async function onClick() {
        \\    if (!window.confirm("Sure?")) return;
        \\    setErrors({});
        \\    try {
        \\      await zb.collection("posts").delete("1");
        \\      location.assign("/posts");
        \\    } catch (err) {
        \\      if (isZigbaseError(err)) {
        \\        setErrors(err.data);
        \\        return;
        \\      }
        \\      throw err;
        \\    }
        \\  }
        \\  if (done) return <p>{"Done."}</p>;
        \\  return (
        \\    <span>
        \\      <button type="button" onClick={onClick}>{"Destroy"}</button>
        \\      <ul class="errors">
        \\        {Object.entries(errors).map(([f, e]) => (
        \\          <li key={f}>{f + ": " + e.message}</li>
        \\        ))}
        \\      </ul>
        \\    </span>
        \\  );
        \\}
        \\
    , island);
}

test "emitClickIsland: update and create call shapes, and the TODO for a record call with no id" {
    const gpa = testing.allocator;
    // `callShape` is read off the verb and the collection; each arm emits a
    // different `zb.collection(…)` call, and the record-addressing two
    // (`update`, `delete`) need the id the route helper carried. Nothing
    // pinned the arms apart: a swap between `delete("1")` and
    // `update("1", {})`, or a TODO that stopped firing, passed every test.
    const with_id: convert.Click = .{ .confirm = null, .record_id = "1" };
    const no_id: convert.Click = .{ .confirm = null, .record_id = null };

    const update = try emitClickIsland(gpa, tClickSpec(tClickBinding("PATCH", "posts"), with_id), with_id);
    defer gpa.free(update);
    try testing.expect(std.mem.indexOf(u8, update, "      await zb.collection(\"posts\").update(\"1\", {});\n") != null);
    try testing.expect(std.mem.indexOf(u8, update, "window.confirm") == null);

    // A `create` addresses no record: no id needed, none emitted, and no
    // TODO. `{}` and not `values`: a link has no fields.
    const create = try emitClickIsland(gpa, tClickSpec(tClickBinding("POST", "posts"), no_id), no_id);
    defer gpa.free(create);
    try testing.expect(std.mem.indexOf(u8, create, "      await zb.collection(\"posts\").create({});\n") != null);
    try testing.expect(std.mem.indexOf(u8, create, "TODO") == null);

    // A `delete` (or `update`) with no id is a control whose call can only
    // fail at runtime, so the island is the TODO and nothing else: no state,
    // no handler, no button -- but still a component with the header that
    // leads back to the ERB.
    const todo = try emitClickIsland(gpa, tClickSpec(tClickBinding("DELETE", "posts"), no_id), no_id);
    defer gpa.free(todo);
    try testing.expect(std.mem.indexOf(u8, todo, "  return <p>{\"TODO: this control acts on one record; pass its id\"}</p>;\n}\n") != null);
    try testing.expect(std.mem.indexOf(u8, todo, "useState(") == null);
    try testing.expect(std.mem.indexOf(u8, todo, "useState<") == null);
    try testing.expect(std.mem.indexOf(u8, todo, "<button") == null);
    try testing.expect(std.mem.indexOf(u8, todo, "export default function PostsShow(_props: Props) {\n") != null);
    const todo_update = try emitClickIsland(gpa, tClickSpec(tClickBinding("PATCH", "posts"), no_id), no_id);
    defer gpa.free(todo_update);
    try testing.expect(std.mem.indexOf(u8, todo_update, "TODO: this control acts on one record") != null);

    // A `custom:` answer has no collection and no record to address: a
    // missing id is not a TODO there, because `zb.send` needs none.
    const custom = try emitClickIsland(gpa, tClickSpec(tClickBinding("DELETE", null), no_id), no_id);
    defer gpa.free(custom);
    try testing.expect(std.mem.indexOf(u8, custom, "      await zb.send(\"DELETE\", \"/api/collections/posts/records\");\n") != null);
    try testing.expect(std.mem.indexOf(u8, custom, "TODO") == null);
}

test "emitClickIsland: leaks nothing under a FailingAllocator" {
    // The record-call arm builds its call in a scratch list before handing
    // it to `emitCollectionCall`; a failure between the two is the case a
    // `defer` has to cover.
    const gpa = testing.allocator;
    const click: convert.Click = .{ .confirm = "Sure?", .record_id = "1" };
    const spec = tClickSpec(tClickBinding("DELETE", "posts"), click);
    var fail_index: usize = 0;
    while (fail_index < 200) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        if (emitClickIsland(fa, spec, click)) |island| {
            fa.free(island);
            break;
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
    try testing.expect(fail_index < 200);
}

test "linkRoute: a name or path shared by several verbs resolves by the link's own verb" {
    // `session_path` is GET, POST and DELETE in a stock sessions resource,
    // and a single answer cannot stand for all three. The GET route is
    // listed FIRST so that dropping the verb check would return it.
    var rs = [_]route_mod.Route{
        tNamed("GET", "/session", "sessions", "new", 2, "session"),
        tNamed("DELETE", "/session", "sessions", "destroy", 3, "session"),
        tNamed("POST", "/session", "sessions", "create", 4, "session"),
    };
    var d = emptyDiscovery();
    d.routes = &rs;

    const args = [_][]const u8{"Sign out"};
    const helper = tLink(1, 4, "session", &args, &.{}, "button_to \"Sign out\", session_path, method: :delete");
    try testing.expectEqual(@as(?usize, 1), linkRoute(&d, helper, "DELETE"));
    try testing.expectEqual(@as(?usize, 2), linkRoute(&d, helper, "POST"));
    try testing.expectEqual(@as(?usize, 0), linkRoute(&d, helper, "GET"));
    // A verb the table has no row for, and no verb at all (a link that does
    // not submit), pair nothing.
    try testing.expectEqual(@as(?usize, null), linkRoute(&d, helper, "PATCH"));
    try testing.expectEqual(@as(?usize, null), linkRoute(&d, helper, null));

    // A literal target is matched by PATH, under the same verb rule…
    const literal_args = [_][]const u8{ "Sign out", "/session" };
    const literal = tLink(1, 4, null, &literal_args, &.{}, "link_to \"Sign out\", \"/session\", method: :delete");
    try testing.expectEqual(@as(?usize, 1), linkRoute(&d, literal, "DELETE"));
    // …and never against the route NAMES: `"session"` is not a path this
    // table serves, however many routes are named that.
    const name_as_path = [_][]const u8{ "Sign out", "session" };
    const misnamed = tLink(1, 4, null, &name_as_path, &.{}, "link_to \"Sign out\", \"session\", method: :delete");
    try testing.expectEqual(@as(?usize, null), linkRoute(&d, misnamed, "DELETE"));
}

test "write: the click-island branches leak nothing under a FailingAllocator" {
    // Round 3's click path -- `bindTemplate`'s link branch (`linkRoute`,
    // `actionRedirect`), `convert.emitIsland`'s link arm and its sentinel
    // note, `emitClickIsland` -- sat outside both Stage 3 sweeps, which feed
    // a form. Same discipline as those: the input is built with the real
    // allocator, only `write` is swept.
    const gpa = testing.allocator;

    const link_attrs = [_]fragments.Attr{
        .{ .key = "method", .value = "delete" },
        .{ .key = "data-turbo-confirm", .value = "Sure?" },
        .{ .key = "data", .value = convert.nested_hash_sentinel },
    };
    const link_args = [_][]const u8{"Sign out"};
    const link_nodes = [_]fragments.Node{tLink(
        2,
        5,
        "logout",
        &link_args,
        &link_attrs,
        "button_to \"Sign out\", logout_path, method: :delete",
    )};
    const frags = [_]fragments.Template{tTemplate(link_view, &link_nodes)};
    var rs = [_]route_mod.Route{
        tNamed("GET", "/x", "a_b", "new", 2, "x"),
        tNamed("DELETE", "/logout", "a_b", "destroy", 4, "logout"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.backend) };
    var tpls_link = [_][]const u8{link_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls_link, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    const route_views = [_]?[]const u8{ link_view, null };
    const route_names = [_][]const u8{ "x", "logout" };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .backend = null,
    });
    defer findings.free(gpa, finding_list);

    var link_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint) and std.mem.eql(u8, f.path, link_view)) link_id = f.id;
    }
    try testing.expect(link_id.len > 0);
    var decided = [_]decisions.Decision{.{
        .id = link_id,
        .choice = "custom:/api/logout",
        .rationale = "sign out",
        .artifact = null,
    }};

    var redirects = [_]controllers.RedirectInfo{.{ .name = "x", .args = &.{} }};
    var actions = [_]controllers.ActionInfo{.{
        .controller = "a_b",
        .action = "destroy",
        .redirects = &redirects,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;
    d.actions = &actions;

    var fail_index: usize = 0;
    while (fail_index < 800) : (fail_index += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);

        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| fa.free(p);
        var err_cause: ?anyerror = null;

        if (write(std.testing.io, fa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = null,
            .backend = null,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause)) |res| {
            // The run that got all the way through is the one that proves
            // the sweep reached the click path at all: the island is there,
            // and so is the note the sentinel earns.
            defer freeResult(fa, res);
            try testing.expect(targetHas(&tmp, "components/forms/a_b_new.island.tsx"));
            const page = outcomeFor(res, 0) orelse return error.NoRoute;
            try testing.expect(std.mem.indexOf(u8, page.note orelse "", "a confirm guard may be missing") != null);
            break; // past the last allocation: the sweep is complete.
        } else |err| switch (err) {
            error.OutOfMemory => {},
            error.TargetWrite, error.SourceRead => {},
        }
    }
    try testing.expect(fail_index < 800);
}

/// Two collections, so a route-level answer has to name which one it is.
const two_collection_document =
    \\{
    \\  "openapi": "3.1.2",
    \\  "info": { "title": "ZigBase API", "version": "2026-08-30.1" },
    \\  "paths": {
    \\    "/api/collections/posts/records": {
    \\      "post": { "operationId": "createPosts", "x-zigbase-access": "locked" }
    \\    },
    \\    "/api/collections/comments/records": {
    \\      "post": { "operationId": "createComments", "x-zigbase-access": "locked" }
    \\    }
    \\  }
    \\}
;

test "write: a non-GET route answered on its own route-level finding gets its own endpoint" {
    const gpa = testing.allocator;
    // `resources :posts, :comments` is one `config/routes.rb` line and one
    // verb declaring two mutations, and `createPosts` cannot serve a comment.
    // Task 3's fix rounds key `RAILS_BACKEND_ENDPOINT` on
    // `(line, verb, resource)` for exactly that reason, so this file has to
    // build the id with `findings.routeVerbFindingId` -- a line-only id
    // matches no finding at all, and a verb-only one would hand BOTH routes
    // the answer meant for one.
    var rs = [_]route_mod.Route{
        tNamed("POST", "/comments", "comments", "create", 2, "comments"),
        tNamed("POST", "/posts", "posts", "create", 2, "posts"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.backend), tVerdict(.backend) };
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };

    const doc = try backend_mod.parse(gpa, two_collection_document, "openapi.json");
    defer backend_mod.free(gpa, doc);
    const finding_list = try findings.derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "comments", "posts" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .backend = doc,
    });
    defer findings.free(gpa, finding_list);

    // Two findings on ONE line and ONE verb, told apart by the resource.
    var comments_id: []const u8 = "";
    var n: usize = 0;
    for (finding_list) |f| {
        if (!std.mem.eql(u8, f.code, findings.code_backend_endpoint)) continue;
        n += 1;
        if (std.mem.endsWith(u8, f.id, ".POST.comments")) comments_id = f.id;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(comments_id.len > 0);

    var decided = [_]decisions.Decision{.{
        .id = comments_id,
        .choice = "createComments",
        .rationale = "comment creation moves to the collection",
        .artifact = null,
    }};

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .backend = doc,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    for (res.routes) |o| {
        const r = rs[o.route_index];
        try testing.expectEqual(Status.backend, o.status);
        if (std.mem.eql(u8, r.path, "/comments")) {
            try testing.expect(o.endpoint != null);
            try testing.expectEqualStrings("createComments", o.endpoint.?.operation_id);
            try testing.expectEqualStrings("POST", o.endpoint.?.verb);
            try testing.expectEqualStrings("/api/collections/comments/records", o.endpoint.?.path);
            // Answered AND acted on, so the row is settled rather than open.
            try testing.expectEqualStrings(comments_id, o.decision_id orelse "");
            try testing.expectEqual(@as(usize, 0), o.open_finding_ids.len);
        } else {
            // Same line, same verb, different resource: a separate question,
            // and nobody answered it.
            try testing.expect(o.endpoint == null);
            try testing.expectEqual(@as(usize, 1), o.open_finding_ids.len);
            try testing.expect(std.mem.endsWith(u8, o.open_finding_ids[0], ".POST.posts"));
        }
    }
}

/// One `shared/_form` partial holding one bound form, plus `n` views that
/// each `render "shared/form"`. Each view's controller and action are read off
/// its own path (`app/views/pages/contact.html.erb` -> `pages#contact`), which
/// is the same rule `resolve.viewFor` matches on.
///
/// This is the shape C-1 aborted on: two views, one partial, one island path.
const SharedFormRun = struct {
    tmp: std.testing.TmpDir,
    res: Result,
    finding_list: []findings.Finding,
    doc: backend_mod.Document,

    fn deinit(self: *SharedFormRun, gpa: Allocator) void {
        freeResult(gpa, self.res);
        findings.free(gpa, self.finding_list);
        backend_mod.free(gpa, self.doc);
        self.tmp.cleanup();
    }
};

const shared_partial = "app/views/shared/_form.html.erb";
const shared_island = "components/forms/shared__form.island.tsx";
const shared_island_2 = "components/forms/shared__form_2.island.tsx";

/// The `forms = 2` shape: two bound regions in ONE partial, on their own
/// lines so the id sort and the source order agree.
const shared_two_form_nodes = [_]fragments.Node{
    tOpen(.form, 2, 4, "post", "form_with(model: @post) do |f|"),
    tArgs(.form_field, 2, 40, "submit", &.{"First"}),
    tEnd(2, 60),
    tOpen(.form, 3, 4, "post", "form_with(model: @post) do |g|"),
    tArgs(.form_field, 3, 40, "submit", &.{"Second"}),
    tEnd(3, 60),
};

fn runSharedForm(
    gpa: Allocator,
    comptime n: usize,
    view_paths: [n][]const u8,
    route_paths: [n][]const u8,
    comptime forms: usize,
) !SharedFormRun {
    const one_form_nodes = boundViewNodes(false, false);
    const form_nodes: []const fragments.Node =
        if (forms == 1) &one_form_nodes else &shared_two_form_nodes;
    const render_nodes = [_]fragments.Node{tNode(.render_partial, 1, 1, "shared/form")};

    var frags: [n + 1]fragments.Template = undefined;
    frags[0] = tTemplate(shared_partial, form_nodes);
    for (view_paths, 0..) |vp, i| frags[i + 1] = tTemplate(vp, &render_nodes);

    var rs: [n]route_mod.Route = undefined;
    var vs: [n]classify.Verdict = undefined;
    var tpl_slots: [n][1][]const u8 = undefined;
    var rts: [n]rails.RouteTemplates = undefined;
    var route_views: [n]?[]const u8 = undefined;
    for (0..n) |i| {
        const stem = resolve.viewStem(view_paths[i]);
        const slash = std.mem.indexOfScalar(u8, stem, '/').?;
        rs[i] = tNamed(
            "GET",
            route_paths[i],
            stem[0..slash],
            stem[slash + 1 ..],
            @intCast(i + 2),
            route_paths[i][1..],
        );
        vs[i] = tVerdict(.content);
        tpl_slots[i] = .{view_paths[i]};
        rts[i] = .{ .templates = &tpl_slots[i], .layout = null };
        route_views[i] = view_paths[i];
    }
    var names: [n][]const u8 = undefined;
    for (0..n) |i| names[i] = route_paths[i][1..];

    const doc = try backend_mod.parse(gpa, bound_document, "openapi.json");
    errdefer backend_mod.free(gpa, doc);
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .backend = doc,
    });
    errdefer findings.free(gpa, finding_list);

    var form_ids: [forms][]const u8 = @splat("");
    var found: usize = 0;
    for (finding_list) |f| {
        if (!std.mem.eql(u8, f.code, findings.code_backend_endpoint)) continue;
        if (!std.mem.eql(u8, f.path, shared_partial)) continue;
        if (found < forms) form_ids[found] = f.id;
        found += 1;
    }
    try testing.expectEqual(forms, found);
    var decided: [forms]decisions.Decision = undefined;
    for (&decided, form_ids) |*slot, id| slot.* = .{
        .id = id,
        .choice = "createPosts",
        .rationale = "one shared form, one operation",
        .artifact = null,
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |x| gpa.free(x);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .backend = doc,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);

    return .{ .tmp = tmp, .res = res, .finding_list = finding_list, .doc = doc };
}

test "write: one bound partial rendered by two views is ONE island file, not a collision" {
    const gpa = testing.allocator;
    // C-1. `buildBindings` binds each TEMPLATE once, but `convert.zig` matches
    // a binding by finding id -- so the partial is inlined into both views'
    // node walks and both `View`s come back holding the same `IslandSpec`,
    // under the same island path. Writing it per view hit the exclusive-create
    // guard and aborted the whole migration AFTER both pages were on disk:
    // `PathAlreadyExists`, a half-written target, no `build.sh` and no
    // `lib/zb.ts`. A shared `_form` partial is the commonest form in Rails, so
    // this was the ordinary case, not an exotic one.
    var shared = try runSharedForm(
        gpa,
        2,
        .{ "app/views/comments/new.html.erb", "app/views/pages/contact.html.erb" },
        .{ "/comments/new", "/contact" },
        1,
    );
    defer shared.deinit(gpa);

    // Both pages reference the island…
    const a = try readTarget(gpa, &shared.tmp, "layouts/comments/new.shtml");
    defer gpa.free(a);
    const b = try readTarget(gpa, &shared.tmp, "layouts/pages/contact.shtml");
    defer gpa.free(b);
    try testing.expect(std.mem.indexOf(u8, a, "<island src=\"" ++ shared_island ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "<island src=\"" ++ shared_island ++ "\"") != null);

    // …and the run finished, with the whole project written.
    try testing.expect(targetHas(&shared.tmp, shared_island));
    try testing.expect(targetHas(&shared.tmp, client_lib_path));
    try testing.expect(targetHas(&shared.tmp, "package.json"));
    for (shared.res.routes) |o| try testing.expectEqual(Status.migrated, o.status);

    // Exactly one `--island=` flag: a second one would make `release` bundle
    // the same entry twice.
    const build_sh = try readTarget(gpa, &shared.tmp, "build.sh");
    defer gpa.free(build_sh);
    var count: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, build_sh, at, "--island=")) |i| {
        count += 1;
        at = i + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);

    // The header names the PARTIAL, which is why the two writes would have
    // been byte-identical and why skipping the second loses nothing.
    const island = try readTarget(gpa, &shared.tmp, shared_island);
    defer gpa.free(island);
    try testing.expect(std.mem.startsWith(
        u8,
        island,
        "// Generated by `zigapagos migrate --from rails` from " ++ shared_partial ++ ":2.",
    ));
}

test "write: two bound forms in one shared partial stay two islands, deduped once each" {
    const gpa = testing.allocator;
    // The two halves of the write-once skip pulling in opposite directions on
    // one fixture: the ordinal has to keep the partial's SECOND form off the
    // first one's name (`_2`), and the id-keyed dedupe has to skip BOTH of
    // them when the second view renders the same partial. Get either wrong and
    // it shows here -- a missing `_2` collapses two forms into one file, a
    // path-blind dedupe writes each twice and trips the exclusive-create guard.
    var shared = try runSharedForm(
        gpa,
        2,
        .{ "app/views/comments/new.html.erb", "app/views/pages/contact.html.erb" },
        .{ "/comments/new", "/contact" },
        2,
    );
    defer shared.deinit(gpa);

    for (shared.res.routes) |o| try testing.expectEqual(Status.migrated, o.status);
    try testing.expect(targetHas(&shared.tmp, shared_island));
    try testing.expect(targetHas(&shared.tmp, shared_island_2));

    // Two `--island=` flags for two forms, not four for two views.
    const build_sh = try readTarget(gpa, &shared.tmp, "build.sh");
    defer gpa.free(build_sh);
    try testing.expectEqual(@as(usize, 2), countOccurrences(build_sh, "--island="));

    // Both pages carry both islands: the partial is rendered whole into each.
    const a = try readTarget(gpa, &shared.tmp, "layouts/comments/new.shtml");
    defer gpa.free(a);
    const b = try readTarget(gpa, &shared.tmp, "layouts/pages/contact.shtml");
    defer gpa.free(b);
    for ([_][]const u8{ a, b }) |page| {
        try testing.expect(std.mem.indexOf(u8, page, "<island src=\"" ++ shared_island ++ "\"") != null);
        try testing.expect(std.mem.indexOf(u8, page, "<island src=\"" ++ shared_island_2 ++ "\"") != null);
    }

    // …and `_2` is the SECOND form, in source order.
    const second = try readTarget(gpa, &shared.tmp, shared_island_2);
    defer gpa.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "{\"Second\"}</button>") != null);
}

test "write: build.sh lists its islands in PATH order, not in the order they were written" {
    const gpa = testing.allocator;
    // I-1. The flag list is output, and output is byte-identical for identical
    // input (plan, Global Constraints). Write order is ROUTE order -- `/a`
    // before `/b` -- and these two views are chosen so their island STEMS run
    // the other way (`zebra/new` before `apple/new`), which is the only shape
    // that can tell a sort from an accident.
    const form_a = boundViewNodes(false, false);
    const form_b = boundViewNodes(false, false);
    const frags = [_]fragments.Template{
        tTemplate("app/views/zebra/new.html.erb", &form_a),
        tTemplate("app/views/apple/new.html.erb", &form_b),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/a", "zebra", "new", 2, "a"),
        tNamed("GET", "/b", "apple", "new", 3, "b"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var a_tpls = [_][]const u8{"app/views/zebra/new.html.erb"};
    var b_tpls = [_][]const u8{"app/views/apple/new.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &a_tpls, .layout = null },
        .{ .templates = &b_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{
        "app/views/zebra/new.html.erb",
        "app/views/apple/new.html.erb",
    };

    const doc = try backend_mod.parse(gpa, bound_document, "openapi.json");
    defer backend_mod.free(gpa, doc);
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "a", "b" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .backend = doc,
    });
    defer findings.free(gpa, finding_list);

    var decided: [2]decisions.Decision = undefined;
    var n: usize = 0;
    for (finding_list) |f| {
        if (!std.mem.eql(u8, f.code, findings.code_backend_endpoint)) continue;
        if (std.mem.indexOf(u8, f.path, "config/routes") != null) continue;
        if (n < 2) decided[n] = .{
            .id = f.id,
            .choice = "createPosts",
            .rationale = "both forms post a record",
            .artifact = null,
        };
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |x| gpa.free(x);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .backend = doc,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const build_sh = try readTarget(gpa, &tmp, "build.sh");
    defer gpa.free(build_sh);
    const apple = std.mem.indexOf(u8, build_sh, "--island='components/forms/apple_new.island.tsx'").?;
    const zebra = std.mem.indexOf(u8, build_sh, "--island='components/forms/zebra_new.island.tsx'").?;
    // `apple` was written SECOND (route `/b`) and must be listed FIRST.
    try testing.expect(apple < zebra);
}

test "write: the Stage 3 branches leak nothing under a FailingAllocator" {
    // The Stage 2 N2 gap: the binding pre-pass, the island emitter and the
    // client lib are all on paths the existing sweep never reaches, and each
    // of them grows a list of owned strings behind a fallible allocation.
    //
    // Everything the sweep FEEDS is built with the real allocator -- it is the
    // test's own input, not part of what is being swept.
    const gpa = testing.allocator;

    const view_nodes = boundViewNodes(false, false);
    const home_nodes = [_]fragments.Node{tText("<h1>Home</h1>", 1)};
    const frags = [_]fragments.Template{
        tTemplate("app/views/pages/home.html.erb", &home_nodes),
        tTemplate(bound_view, &view_nodes),
    };
    var vs = [_]classify.Verdict{
        tVerdict(.content),
        tVerdict(.content),
        tVerdict(.backend),
        tVerdict(.content),
    };
    var home_tpls = [_][]const u8{"app/views/pages/home.html.erb"};
    var new_tpls = [_][]const u8{bound_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &home_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &new_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{
        "app/views/pages/home.html.erb",
        null,
        null,
        bound_view,
    };
    const route_names = [_][]const u8{ "root", "posts", "create_post", "new_post" };

    const doc = try backend_mod.parse(gpa, bound_document, "openapi.json");
    defer backend_mod.free(gpa, doc);
    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &bound_routes,
        .classifications = &vs,
        .route_views = &route_views,
        .backend = doc,
    });
    defer findings.free(gpa, finding_list);

    var form_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint) and
            std.mem.eql(u8, f.path, bound_view)) form_id = f.id;
    }
    try testing.expect(form_id.len > 0);
    var decided = [_]decisions.Decision{.{
        .id = form_id,
        .choice = "createPosts",
        .rationale = "the form posts a record",
        .artifact = null,
    }};

    var redirects = [_]controllers.RedirectInfo{.{ .name = "root", .args = &.{} }};
    var actions = [_]controllers.ActionInfo{.{
        .controller = "posts",
        .action = "create",
        .redirects = &redirects,
    }};

    var d = emptyDiscovery();
    d.routes = &bound_routes;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;
    d.actions = &actions;

    var fail_index: usize = 0;
    while (fail_index < 800) : (fail_index += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);

        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| fa.free(p);
        var err_cause: ?anyerror = null;

        if (write(std.testing.io, fa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = "../runtime",
            .backend = doc,
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause)) |res| {
            freeResult(fa, res);
            break; // past the last allocation: the sweep is complete.
        } else |err| switch (err) {
            error.OutOfMemory => {},
            error.TargetWrite, error.SourceRead => {},
        }
    }
    try testing.expect(fail_index < 800);
}

// ---- #167 Stage 3, Task 5: the auth-journey scaffolds ---------------------

/// The whole journey, as a Rails app actually lays it out: a `sessions`
/// resource, a `registrations` resource, and a marketing layout that renders
/// a `shared/_nav` partial holding the `current_user` region.
///
/// Module-level so `JourneyRun.route` can name a route after the helper's own
/// stack frame is gone.
var journey_app_routes = [_]route_mod.Route{
    tNamed("GET", "/", "pages", "home", 1, "root"),
    tNamed("POST", "/registration", "registrations", "create", 6, "registration"),
    tNamed("GET", "/registration/new", "registrations", "new", 6, "new_registration"),
    tNamed("DELETE", "/session", "sessions", "destroy", 5, "session"),
    tNamed("POST", "/session", "sessions", "create", 5, "session"),
    // A SECOND GET route on the `sessions` controller, sorting BEFORE
    // `sessions#new`: `AuthStatus` links to the sign-in PAGE, and a rule that
    // took the journey's first GET route would take this one.
    tNamed("GET", "/session/edit", "sessions", "edit", 5, "edit_session"),
    // Last, so `without_signin_route` can drop exactly it.
    tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
};

const journey_nav = "app/views/shared/_nav.html.erb";
const journey_layout = "app/views/layouts/marketing.html.erb";
const journey_signin_view = "app/views/sessions/new.html.erb";
const journey_signin_partial = "app/views/sessions/_form.html.erb";
const journey_edit_view = "app/views/sessions/edit.html.erb";
const journey_signup_view = "app/views/registrations/new.html.erb";

/// `<% if current_user %><%= current_user.email %>
/// <%= button_to "Sign out", session_path, method: :delete %><% end %>`, the
/// exact one-line shape the presentation fixture uses.
const journey_delete_attrs = [_]fragments.Attr{.{ .key = "method", .value = "delete" }};

fn journeyNavNodes() [7]fragments.Node {
    var button = tArgs(.link_to, 2, 45, "session", &.{"Sign out"});
    button.code = "button_to \"Sign out\", session_path, method: :delete";
    button.attrs = &journey_delete_attrs;
    return .{
        tOpen(.request_state, 2, 3, "current_user", "if current_user"),
        tNode(.request_state, 2, 25, "current_user"),
        button,
        tEnd(2, 100),
        // The signed-OUT half of the same nav: the COMPLEMENT of the region
        // above -- same predicate, opposite polarity -- which is the shape
        // `<% if current_user %>…<% end %><% unless current_user %>…<% end %>`
        // a real Rails nav is written in. Sliced OFF unless
        // `JourneyOpts.second_status_in_nav` asks for it: even unanswered it
        // is a finding, and an extra open id would change what every other
        // journey route reports.
        tOpen(.request_state, 3, 3, "current_user", "unless current_user"),
        tText("<a>Sign in</a>", 3),
        tEnd(3, 60),
    };
}

/// `registrations/new`: an error summary above a plain email/password form.
///
/// Deliberately WITHOUT a `password_confirmation` field: the controller name
/// alone has to be enough to make this the sign-up half, and the other signal
/// gets its own fixture (`a password_confirmation field makes a form sign-up
/// under any controller`). A form carrying both would let either rule fail
/// unnoticed.
fn journeySignupNodes() [7]fragments.Node {
    return .{
        tOpen(.errors, 1, 1, "@user", "@user.errors.full_messages.each do |m|"),
        tNode(.local, 1, 30, "m"),
        tEnd(1, 50),
        tOpen(.form, 1, 60, "user", "form_with(model: @user, url: registration_path) do |f|"),
        tArgs(.form_field, 1, 120, "email_field", &.{"email"}),
        tArgs(.form_field, 1, 140, "password_field", &.{"password"}),
        tEnd(1, 200),
    };
}

const JourneyOpts = struct {
    /// What the operator answered `RAILS_AUTH_JOURNEY` with. `null` leaves it
    /// unanswered.
    journey_choice: ?[]const u8 = "island",
    journey_artifact: []const u8 = "users",
    /// What the `current_user` region in `_nav` is answered with. `null`
    /// leaves it unanswered, which is a DIFFERENT thing from answering it
    /// `retain`: one skips the lookup, the other has to be rejected by the
    /// choice test.
    status_choice: ?[]const u8 = "island",
    /// Drop `GET /session/new` from the route table: a journey detected only
    /// by a password form has no sign-in page to link to (the plan's "T5
    /// self" scan row).
    without_signin_route: bool = false,
    /// Put a finding of a DIFFERENT code at the `current_user` region's
    /// position, ahead of the real one, and answer THAT `island`.
    /// `convert.findingIdFor` is a position lookup that ignores the code, so
    /// this is the shape that tells `bindAuthStatus`'s code check apart from
    /// no check at all.
    shadow_status_finding: bool = false,
    /// Answer the SECOND `current_user`-family region in `_nav` as well, so
    /// ONE template holds two answered regions.
    second_status_in_nav: bool = false,
    /// Give the home view a `current_user` region of its own and answer it,
    /// so two answered regions sit in two different templates -- one reached
    /// through the layout, one through a route's own view.
    status_in_home: bool = false,
    /// Ruling S3-R6: answer the `button_to` INSIDE the answered
    /// `current_user` region as well. `null` leaves it unanswered, which is
    /// what an operator who read the region's own answer would do -- and the
    /// difference between the two is the whole ruling.
    button_choice: ?[]const u8 = null,
    /// Render the nav partial from the HOME VIEW instead of from the layout.
    ///
    /// The two placements are the same app to an operator and different
    /// inputs to `buildBindings`: `bindTemplate` walks a route's own view and
    /// the partials it renders, and nothing else, so a nav in a view hands the
    /// swallowed `button_to` a binding of its own while a nav in the layout
    /// does not. Ruling S3-R6's note must not turn on that.
    nav_in_home: bool = false,
};

/// The shadow row `JourneyOpts.shadow_status_finding` inserts. Static: it is
/// never passed to `findings.free`, and its `choices` must outlive the
/// `decisions.parse` call that validates against them.
const shadow_status_choices = [_][]const u8{ "island", "retain" };
const shadow_status_finding: findings.Finding = .{
    .id = "RAILS_RAW_OUTPUT.app/views/shared/_nav%2Ehtml%2Eerb.L2C3",
    .code = "RAILS_RAW_OUTPUT",
    .severity = .warn,
    .path = journey_nav,
    .line = 2,
    .route_id = null,
    .message = "raw output",
    .choices = &shadow_status_choices,
    .requires_artifact = false,
};

const JourneyRun = struct {
    tmp: std.testing.TmpDir,
    res: Result,
    finding_list: []findings.Finding,
    parsed: decisions.Parsed,
    routes: []const route_mod.Route,
    journey_id: []const u8,
    status_id: []const u8,
    button_id: []const u8,
    errors_id: []const u8,
    /// The second answered region in `_nav`, and the one in the home view.
    /// Empty when the run did not ask for them.
    status2_id: []const u8,
    home_status_id: []const u8,

    fn deinit(self: *JourneyRun, gpa: Allocator) void {
        freeResult(gpa, self.res);
        decisions.free(gpa, self.parsed);
        findings.free(gpa, self.finding_list);
        self.tmp.cleanup();
    }

    fn route(self: *const JourneyRun, verb: []const u8, path: []const u8) RouteOutcome {
        for (self.res.routes) |o| {
            const r = self.routes[o.route_index];
            if (std.mem.eql(u8, r.verb, verb) and std.mem.eql(u8, r.path, path)) return o;
        }
        unreachable;
    }
};

/// One whole `write` over the journey fixture, with the REAL `findings.derive`
/// and `decisions.parse` in front of it -- a hand-built finding list would let
/// this file agree with itself about ids Stage 1 never emits, and assumption
/// A5's "a journey form raises no `RAILS_BACKEND_ENDPOINT`" is precisely the
/// input these tests depend on.
fn runJourney(gpa: Allocator, opts: JourneyOpts) !JourneyRun {
    // The home view can carry a `current_user` region of its own, so the two
    // answered regions live in DIFFERENT templates -- one reached through the
    // layout's partial, one through a route's own view.
    const home_all = [_]fragments.Node{
        tText("<h1>Home</h1>", 1),
        tOpen(.request_state, 2, 3, "current_user", "if current_user"),
        tText("<b>hi</b>", 2),
        tEnd(2, 40),
    };
    // `nav_in_home` moves the `render "shared/nav"` edge from the layout to
    // the home VIEW -- the same nav, on the same page, reached the other way
    // round. The nodes it prepends carry the partial's own line/col, so the
    // ids of everything already in `home_all` are untouched.
    const home_with_nav = [_]fragments.Node{
        tNode(.render_partial, 1, 1, "shared/nav"),
        home_all[0],
        home_all[1],
        home_all[2],
        home_all[3],
    };
    const home_len: usize = if (opts.status_in_home) 4 else 1;
    const home_nodes: []const fragments.Node = if (opts.nav_in_home)
        home_with_nav[0 .. home_len + 1]
    else
        home_all[0..home_len];
    const layout_all = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.render_partial, 2, 3, "shared/nav"),
        tNode(.yield, 3, 3, null),
        tText("</body></html>", 4),
    };
    const layout_without_nav = [_]fragments.Node{ layout_all[0], layout_all[2], layout_all[3] };
    const layout_nodes: []const fragments.Node =
        if (opts.nav_in_home) layout_without_nav[0..] else layout_all[0..];
    const nav_all = journeyNavNodes();
    const nav_nodes: []const fragments.Node =
        if (opts.second_status_in_nav) nav_all[0..7] else nav_all[0..4];
    // Ruling S3-R3, exercised rather than described: the sign-in form lives in
    // a PARTIAL the journey view renders, which is where a real Rails app
    // keeps it. A pre-pass that read only the route's own view would leave the
    // commonest journey form unbound.
    const signin_nodes = [_]fragments.Node{tNode(.render_partial, 1, 1, "form")};
    const signin_partial_nodes = passwordFormNodes();
    const edit_nodes = [_]fragments.Node{tText("<h1>Session</h1>", 1)};
    const signup_nodes = journeySignupNodes();
    const frags = [_]fragments.Template{
        tTemplate(journey_layout, layout_nodes),
        tTemplate("app/views/pages/home.html.erb", home_nodes),
        tTemplate(journey_signup_view, &signup_nodes),
        tTemplate(journey_edit_view, &edit_nodes),
        tTemplate(journey_signin_partial, &signin_partial_nodes),
        tTemplate(journey_signin_view, &signin_nodes),
        tTemplate(journey_nav, nav_nodes),
    };

    const all_routes: []const route_mod.Route = if (opts.without_signin_route)
        journey_app_routes[0 .. journey_app_routes.len - 1]
    else
        journey_app_routes[0..];
    var vs = [_]classify.Verdict{
        tVerdict(.content),
        tVerdict(.backend),
        tVerdict(.content),
        tVerdict(.backend),
        tVerdict(.backend),
        tVerdict(.content),
        tVerdict(.content),
    };
    var home_tpls = [_][]const u8{"app/views/pages/home.html.erb"};
    var signup_tpls = [_][]const u8{journey_signup_view};
    var edit_tpls = [_][]const u8{journey_edit_view};
    var signin_tpls = [_][]const u8{journey_signin_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &home_tpls, .layout = journey_layout },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signup_tpls, .layout = journey_layout },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &edit_tpls, .layout = journey_layout },
        .{ .templates = &signin_tpls, .layout = journey_layout },
    };
    const route_views = [_]?[]const u8{
        "app/views/pages/home.html.erb",
        null,
        journey_signup_view,
        null,
        null,
        journey_edit_view,
        journey_signin_view,
    };
    const route_names = [_][]const u8{
        "root",    "registration", "new_registration",
        "session", "new_session",  "edit_session",
    };
    // Assumption A5's transitive half needs the edges Stage 1 resolved. The
    // layout->nav edge is here too, and is deliberately NOT enough to make
    // `_nav` a journey view: `detectJourney` seeds on ROUTE views, so the
    // `button_to` in a layout partial keeps its own backend question. Under
    // `nav_in_home` the edge starts at the HOME view instead, and the same
    // reasoning holds for the same reason: `pages#home` is not a journey
    // route, so seeding on route views still never reaches `_nav`.
    const render_graph_from_layout = [_]findings.TemplateRenders{
        .{ .path = journey_layout, .renders = &[_][]const u8{journey_nav} },
        .{ .path = journey_signin_view, .renders = &[_][]const u8{journey_signin_partial} },
    };
    const render_graph_from_home = [_]findings.TemplateRenders{
        .{ .path = "app/views/pages/home.html.erb", .renders = &[_][]const u8{journey_nav} },
        .{ .path = journey_signin_view, .renders = &[_][]const u8{journey_signin_partial} },
    };
    const render_graph: []const findings.TemplateRenders =
        if (opts.nav_in_home) render_graph_from_home[0..] else render_graph_from_layout[0..];
    const n = all_routes.len;

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = all_routes,
        .classifications = vs[0..n],
        .route_views = route_views[0..n],
        .render_graph = render_graph,
    });
    errdefer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    var status_id: []const u8 = "";
    var button_id: []const u8 = "";
    var errors_id: []const u8 = "";
    var status2_id: []const u8 = "";
    var home_status_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint) and
            std.mem.eql(u8, f.path, journey_nav)) button_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_request_time_state) and
            std.mem.eql(u8, f.path, journey_nav) and
            std.mem.endsWith(u8, f.id, ".L2C3")) status_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_request_time_state) and
            std.mem.eql(u8, f.path, journey_nav) and
            std.mem.endsWith(u8, f.id, ".L3C3")) status2_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_request_time_state) and
            std.mem.eql(u8, f.path, "app/views/pages/home.html.erb")) home_status_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_request_time_state) and
            std.mem.eql(u8, f.path, journey_signup_view)) errors_id = f.id;
    }
    try testing.expect(journey_id.len > 0);
    try testing.expect(status_id.len > 0);
    // Assumption A5 from the other side: the journey's two forms raise NO
    // backend question of their own, so the only one in the app is the
    // `button_to` in a partial the LAYOUT renders (never a journey view).
    try testing.expect(button_id.len > 0);
    try testing.expect(std.mem.indexOf(u8, button_id, "sessions") == null);
    try testing.expect(errors_id.len > 0);

    // The shadow row goes FIRST, so `convert.findingIdFor` -- which matches on
    // position and returns the first hit -- hands it back for the
    // `current_user` node instead of the real `RAILS_REQUEST_TIME_STATE` row.
    var shadowed: [1 + 64]findings.Finding = undefined;
    var all_findings: []const findings.Finding = finding_list;
    if (opts.shadow_status_finding) {
        try testing.expect(finding_list.len < shadowed.len);
        shadowed[0] = shadow_status_finding;
        @memcpy(shadowed[1..][0..finding_list.len], finding_list);
        all_findings = shadowed[0 .. finding_list.len + 1];
    }

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"schema\":\"zigapagos.rails-decisions/1\",\"decisions\":[");
    var first = true;
    if (opts.journey_choice) |c| {
        try body.print(
            gpa,
            "{{\"id\":\"{s}\",\"choice\":\"{s}\",\"rationale\":\"the flow becomes ZigBase auth\",\"artifact\":\"{s}\"}}",
            .{ journey_id, c, opts.journey_artifact },
        );
        first = false;
    }
    if (opts.status_choice) |sc| {
        if (!first) try body.appendSlice(gpa, ",");
        try body.print(
            gpa,
            "{{\"id\":\"{s}\",\"choice\":\"{s}\",\"rationale\":\"who is signed in is client state\"}}",
            .{ status_id, sc },
        );
        if (std.mem.eql(u8, sc, "island")) {
            try body.print(
                gpa,
                ",{{\"id\":\"{s}\",\"choice\":\"island\",\"rationale\":\"the island renders the backend's errors\"}}",
                .{errors_id},
            );
        }
    }
    if (opts.second_status_in_nav) {
        try testing.expect(status2_id.len > 0);
        try body.print(
            gpa,
            ",{{\"id\":\"{s}\",\"choice\":\"island\",\"rationale\":\"the signed-out half of the same nav\"}}",
            .{status2_id},
        );
    }
    if (opts.status_in_home) {
        try testing.expect(home_status_id.len > 0);
        try body.print(
            gpa,
            ",{{\"id\":\"{s}\",\"choice\":\"island\",\"rationale\":\"who is signed in, on the home page too\"}}",
            .{home_status_id},
        );
    }
    if (opts.button_choice) |bc| {
        try testing.expect(button_id.len > 0);
        try body.print(
            gpa,
            ",{{\"id\":\"{s}\",\"choice\":\"{s}\",\"rationale\":\"answered a second time, from the handoff\"}}",
            .{ button_id, bc },
        );
    }
    if (opts.shadow_status_finding) {
        if (opts.journey_choice != null or opts.status_choice != null) try body.appendSlice(gpa, ",");
        try body.print(
            gpa,
            "{{\"id\":\"{s}\",\"choice\":\"island\",\"rationale\":\"an answer to a question that is not who is signed in\"}}",
            .{shadow_status_finding.id},
        );
    }
    try body.appendSlice(gpa, "]}");

    var problems: std.ArrayListUnmanaged(decisions.Problem) = .empty;
    defer decisions.freeProblems(gpa, &problems);
    const parsed = try decisions.parse(gpa, body.items, all_findings, &.{}, &problems);
    errdefer decisions.free(gpa, parsed);
    try testing.expectEqual(@as(usize, 0), problems.items.len);

    var signin_redirects = [_]controllers.RedirectInfo{.{ .name = "root", .args = &.{} }};
    var signup_redirects = [_]controllers.RedirectInfo{.{ .name = "new_session", .args = &.{} }};
    var actions = [_]controllers.ActionInfo{
        .{ .controller = "sessions", .action = "create", .redirects = &signin_redirects },
        .{ .controller = "registrations", .action = "create", .redirects = &signup_redirects },
    };

    var d = emptyDiscovery();
    d.routes = @constCast(all_routes);
    d.classifications = vs[0..n];
    d.route_templates = rts[0..n];
    d.fragments = @constCast(&frags);
    d.findings = @constCast(all_findings);
    d.actions = &actions;

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = parsed,
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);

    return .{
        .tmp = tmp,
        .res = res,
        .finding_list = finding_list,
        .parsed = parsed,
        .routes = all_routes,
        .journey_id = journey_id,
        .status_id = status_id,
        .button_id = button_id,
        .errors_id = errors_id,
        .status2_id = status2_id,
        .home_status_id = home_status_id,
    };
}

test "write: the journey's two views mount ONE AuthForm, told apart by a prop" {
    const gpa = testing.allocator;
    var j = try runJourney(gpa, .{});
    defer j.deinit(gpa);

    const signin = try readTarget(gpa, &j.tmp, "layouts/sessions/new.shtml");
    defer gpa.free(signin);
    try testing.expect(std.mem.indexOf(
        u8,
        signin,
        "<island src=\"" ++ auth_form_island_path ++ "\" client:load :props='{ .mode = \"signin\" }'></island>",
    ) != null);

    const signup = try readTarget(gpa, &j.tmp, "layouts/registrations/new.shtml");
    defer gpa.free(signup);
    try testing.expect(std.mem.indexOf(
        u8,
        signup,
        "<island src=\"" ++ auth_form_island_path ++ "\" client:load :props='{ .mode = \"signup\" }'></island>",
    ) != null);
    // The error summary above the form is the island's job now, and the `|m|`
    // loop local inside it never becomes an id-less `rails:unmapped`.
    try testing.expect(std.mem.indexOf(u8, signup, "rails:unmapped") == null);

    // ONE file, written once, however many views mount it.
    try testing.expect(targetHas(&j.tmp, auth_form_island_path));
    const build_sh = try readTarget(gpa, &j.tmp, "build.sh");
    defer gpa.free(build_sh);
    var at: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, build_sh, at, "--island='" ++ auth_form_island_path ++ "'")) |k| {
        count += 1;
        at = k + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "write: the AuthForm island signs in, signs up, and redirects where Rails did" {
    const gpa = testing.allocator;
    var j = try runJourney(gpa, .{});
    defer j.deinit(gpa);

    const island = try readTarget(gpa, &j.tmp, auth_form_island_path);
    defer gpa.free(island);
    try testing.expectEqualStrings(
        \\// Generated by `zigapagos migrate --from rails` for the Rails auth journey.
        \\// ONE component for both halves of the flow: assumption A5 folds sign-in and
        \\// sign-up into one finding with one answer, so `mode` is what tells them apart.
        \\// Enforcement stays server-side: this island only presents the form and the backend's
        \\// validation errors; the ZigBase rule on the operation decides who may submit.
        \\import { useState } from "@z/runtime";
        \\import { isZigbaseError, type FieldError } from "@zigbase/client";
        \\import { zb } from "../lib/zb";
        \\
        \\export interface Props { mode: "signin" | "signup" }
        \\
        \\export default function AuthForm(props: Props) {
        \\  const signup = props.mode === "signup";
        \\  const [email, setEmail] = useState("");
        \\  const [password, setPassword] = useState("");
        \\  const [passwordConfirm, setPasswordConfirm] = useState("");
        \\  const [errors, setErrors] = useState<Record<string, FieldError>>({});
        \\  async function onSubmit(e: any) {
        \\    e.preventDefault();
        \\    setErrors({});
        \\    try {
        \\      if (signup) {
        \\        await zb.collection("users").create({ email, password, passwordConfirm });
        \\      }
        \\      await zb.collection("users").authWithPassword(email, password);
        \\      location.assign(signup ? "/session/new" : "/");
        \\    } catch (err) {
        \\      if (isZigbaseError(err)) {
        \\        setErrors(err.data);
        \\        return;
        \\      }
        \\      throw err;
        \\    }
        \\  }
        \\  return (
        \\    <form onSubmit={onSubmit}>
        \\      <ul class="errors">
        \\        {Object.entries(errors).map(([f, e]) => (
        \\          <li key={f}>{f + ": " + e.message}</li>
        \\        ))}
        \\      </ul>
        \\      <label htmlFor="email">{"Email"}</label>
        \\      <input id="email" type="email" name="email" value={email}
        \\        onInput={(e: any) => setEmail(String(e.currentTarget.value ?? ""))} />
        \\      <label htmlFor="password">{"Password"}</label>
        \\      <input id="password" type="password" name="password" value={password}
        \\        onInput={(e: any) => setPassword(String(e.currentTarget.value ?? ""))} />
        \\      {signup ? <label htmlFor="passwordConfirm">{"Password confirmation"}</label> : null}
        \\      {signup ? (
        \\        <input id="passwordConfirm" type="password" name="passwordConfirm" value={passwordConfirm}
        \\          onInput={(e: any) => setPasswordConfirm(String(e.currentTarget.value ?? ""))} />
        \\      ) : null}
        \\      <button type="submit">{signup ? "Sign up" : "Sign in"}</button>
        \\    </form>
        \\  );
        \\}
        \\
    , island);
}

test "write: the current_user region becomes AuthStatus, and the button_to inside it is answered" {
    const gpa = testing.allocator;
    var j = try runJourney(gpa, .{});
    defer j.deinit(gpa);

    // The region lives in a partial the LAYOUT renders, so the island has to
    // reach the layout's own conversion -- every page under that layout
    // mounts it.
    const layout = try readTarget(gpa, &j.tmp, "layouts/templates/marketing.shtml");
    defer gpa.free(layout);
    try testing.expect(std.mem.indexOf(
        u8,
        layout,
        "<island src=\"" ++ auth_status_island_path ++ "\" client:load></island>",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, layout, "rails:finding") == null);
    try testing.expect(std.mem.indexOf(u8, layout, "rails:unmapped") == null);

    const island = try readTarget(gpa, &j.tmp, auth_status_island_path);
    defer gpa.free(island);
    try testing.expectEqualStrings(
        \\// Generated by `zigapagos migrate --from rails` for the Rails auth journey.
        \\// Replaces, in source order:
        \\//   app/views/shared/_nav.html.erb:2 -- if current_user
        \\// Enforcement stays server-side: this island only reports who the browser is
        \\// signed in as; the ZigBase rule on each operation decides what they may do.
        \\import { useEffect, useState } from "@z/runtime";
        \\import { zb } from "../lib/zb";
        \\
        \\export interface Props {}
        \\
        \\export default function AuthStatus(_props: Props) {
        \\  // The session lives in the visitor's own browser, so the prerendered HTML
        \\  // cannot know who is signed in: it renders the signed-out branch, and this
        \\  // flips once the island hydrates. Reading the store during the FIRST render
        \\  // instead would make the server's markup and the client's disagree.
        \\  const [ready, setReady] = useState(false);
        \\  useEffect(() => setReady(true), []);
        \\  async function logout() {
        \\    await zb.collection("users").logout();
        \\    location.reload();
        \\  }
        \\  if (!ready || !zb.authStore.isValid) {
        \\    return <a href="/session/new">{"Sign in"}</a>;
        \\  }
        \\  return (
        \\    <span>
        \\      {String(zb.authStore.record?.email ?? "")}{" "}
        \\      <button onClick={logout}>{"Sign out"}</button>
        \\    </span>
        \\  );
        \\}
        \\
    , island);

    // Every finding in the region is answered by the one island, the
    // `button_to`'s `RAILS_BACKEND_ENDPOINT` included -- nobody has to answer
    // a sign-out button that no longer exists in the markup.
    const home = j.route("GET", "/");
    try testing.expect(!contains(home.open_finding_ids, j.button_id));
    try testing.expect(!contains(home.open_finding_ids, j.status_id));
    try testing.expect(contains(home.artifacts, auth_status_island_path));
    try testing.expectEqual(Status.migrated, home.status);
}

test "write: the journey's three routes carry the client calls the document has no ids for" {
    const gpa = testing.allocator;
    // `x-zigbase-coverage.allAuthMethods` is always false: `auth-with-password`
    // and `auth-logout` are NOT in the OpenAPI document, so the handoff names
    // the CollectionService method instead of an operation id nobody could
    // look up.
    var j = try runJourney(gpa, .{});
    defer j.deinit(gpa);

    const signin = j.route("POST", "/session").endpoint.?;
    try testing.expectEqualStrings("authWithPassword", signin.operation_id);
    try testing.expectEqualStrings("POST", signin.verb);
    try testing.expectEqualStrings("/api/collections/users/auth-with-password", signin.path);

    const logout = j.route("DELETE", "/session").endpoint.?;
    try testing.expectEqualStrings("logout", logout.operation_id);
    try testing.expectEqualStrings("POST", logout.verb);
    try testing.expectEqualStrings("/api/collections/users/auth-logout", logout.path);

    // The registration POST is an ordinary collection create, so it DOES have
    // an operation id, derived by ZigBase's own `<verb><Base>` rule.
    const signup = j.route("POST", "/registration").endpoint.?;
    try testing.expectEqualStrings("createUsers", signup.operation_id);
    try testing.expectEqualStrings("POST", signup.verb);
    try testing.expectEqualStrings("/api/collections/users/records", signup.path);
}

test "authBaseName is ZigBase's own <Base> rule, so the synthesized create id is the document's" {
    const gpa = testing.allocator;
    // The three journey endpoints are synthesized from the collection name
    // because two of them are not in the document at all. This pins the third
    // against a REAL document's own id, so the trio cannot drift apart.
    const doc = try backend_mod.parse(gpa,
        \\{
        \\  "openapi": "3.1.2",
        \\  "info": { "title": "ZigBase API", "version": "1.0.0" },
        \\  "paths": {
        \\    "/api/collections/blog_users/records": {
        \\      "post": { "operationId": "createBlogUsers", "x-zigbase-access": "public" }
        \\    }
        \\  }
        \\}
    , "openapi.json");
    defer backend_mod.free(gpa, doc);

    const base = try authBaseName(gpa, "blog_users");
    defer gpa.free(base);
    const id = try std.fmt.allocPrint(gpa, "create{s}", .{base});
    defer gpa.free(id);
    try testing.expectEqualStrings("BlogUsers", base);
    try testing.expect(backend_mod.operationFor(doc, id) != null);
}

test "write: lib/zb.ts names the auth collection when a journey is bound" {
    const gpa = testing.allocator;
    // `authCollection` is what arms the client's own 401 refresh. Set only
    // when an auth island actually reached the target: naming a collection
    // nothing authenticates against would arm a refresh that always fails.
    var j = try runJourney(gpa, .{});
    defer j.deinit(gpa);

    const lib = try readTarget(gpa, &j.tmp, client_lib_path);
    defer gpa.free(lib);
    try testing.expectEqualStrings(
        \\import { createClient, LocalAuthStore } from "@zigbase/client";
        \\export const zb = createClient("", { authStore: new LocalAuthStore(), authCollection: "users", fetch: (input, init) => globalThis.fetch(input, init) });
        \\
    , lib);
}

test "write: the auth journey answered island settles every route it rides on" {
    const gpa = testing.allocator;
    // Stage 3 Task 4 could only say "needs the auth scaffolds". They exist
    // now, so the answer is carried out and the routes finish.
    var j = try runJourney(gpa, .{});
    defer j.deinit(gpa);

    for (j.res.routes) |o| {
        const r = j.routes[o.route_index];
        try testing.expect(!contains(o.open_finding_ids, j.journey_id));
        if (std.mem.eql(u8, r.verb, "GET")) {
            try testing.expectEqual(Status.migrated, o.status);
        } else {
            try testing.expectEqual(Status.backend, o.status);
        }
        try testing.expect(std.mem.indexOf(
            u8,
            o.note orelse "",
            "needs the auth scaffolds",
        ) == null);
    }
}

test "write: an answer on a control INSIDE a bound region is accepted, and named as superseded" {
    const gpa = testing.allocator;
    // Ruling S3-R6. The handoff lists the `button_to`'s own
    // `RAILS_BACKEND_ENDPOINT` under every route the nav rides on, so an
    // operator working through that list answers it -- and it is a perfectly
    // sensible answer, it is just already covered: the `AuthStatus` island
    // replaced the whole `if current_user` region, sign-out control included,
    // and performs the logout itself.
    //
    // Before this ruling the run FAILED on that answer. The backend arm asked
    // only `boundBy`, which sees the bindings a decision produced and not the
    // ids a binding SWALLOWED, so the route stayed open with
    // "needs the --backend document that names it" -- on a run that had been
    // given one, or (as here) on a `custom:` answer that needs no document at
    // all. Two wrong things at once: an unfinishable run, and a note blaming
    // the wrong input.
    var j = try runJourney(gpa, .{ .button_choice = "custom:/api/logout" });
    defer j.deinit(gpa);

    const root = j.route("GET", "/");
    // The answer really is the one under test: `pickDecision` ranks
    // `custom:…` and `island` equally and breaks the tie on the smallest id,
    // and `RAILS_BACKEND_ENDPOINT…` sorts before `RAILS_REQUEST_TIME_STATE…`.
    // Without this the rest of the test could pass on the region's own answer.
    try testing.expectEqualStrings(j.button_id, root.decision_id orelse "");
    try testing.expectEqual(Status.migrated, root.status);
    try testing.expect(!contains(root.open_finding_ids, j.button_id));

    // BOTH ids, because neither alone is actionable: the operator knows which
    // finding they answered and cannot otherwise tell which answer made
    // theirs redundant.
    const note = root.note orelse "";
    try testing.expect(std.mem.indexOf(u8, note, "superseded by the island answering") != null);
    try testing.expect(std.mem.indexOf(u8, note, j.button_id) != null);
    try testing.expect(std.mem.indexOf(u8, note, j.status_id) != null);
    // The misleading half of the old behaviour, pinned as absent.
    try testing.expect(std.mem.indexOf(u8, note, "needs the --backend document") == null);
}

test "write: the superseded note does not depend on where the nav is rendered from" {
    const gpa = testing.allocator;
    // The test above with ONE input changed: the nav partial is rendered by
    // `pages/home.html.erb` instead of by the layout. That is the same app to
    // an operator -- same nav, same page, same two answers -- and the note
    // they get must be the same too.
    //
    // It was not. `bindTemplate` walks a route's own view and the partials it
    // renders (never the layout), so a nav in a VIEW gives the swallowed
    // `button_to` a `Binding` of its own -- one nothing ever emits, because
    // `convert` replaced the whole region with the `AuthStatus` island before
    // reaching it. The backend arm asked `boundBy` FIRST and settled on that
    // phantom, silently, so the operator was told nothing at all about an
    // answer that produced no component. The layout placement, with no
    // binding to find, fell through to the superseded branch and explained
    // itself. Supersession is now asked first in both arms: an answer some
    // other answer swallowed is superseded whether or not a binding was also
    // recorded for it.
    var j = try runJourney(gpa, .{ .button_choice = "custom:/api/logout", .nav_in_home = true });
    defer j.deinit(gpa);

    const root = j.route("GET", "/");
    try testing.expectEqualStrings(j.button_id, root.decision_id orelse "");
    try testing.expectEqual(Status.migrated, root.status);
    try testing.expect(!contains(root.open_finding_ids, j.button_id));

    const note = root.note orelse "";
    try testing.expect(std.mem.indexOf(u8, note, "superseded by the island answering") != null);
    try testing.expect(std.mem.indexOf(u8, note, j.button_id) != null);
    try testing.expect(std.mem.indexOf(u8, note, j.status_id) != null);
    // And no click island for the swallowed control: the phantom binding is
    // still not something to emit, it is only something to explain.
    try testing.expect(!targetHas(&j.tmp, "components/forms/shared__nav.island.tsx"));
}

test "write: the error summary a bound auth form absorbed is named as superseded too" {
    const gpa = testing.allocator;
    // The ISLAND arm of `applyAcknowledgement`, which the test above does not
    // reach: it answers the `button_to`, whose finding is a
    // `RAILS_BACKEND_ENDPOINT` and so takes the backend arm. The two arms
    // call `settleSuperseded` from different branches, and until ruling S3-R7
    // nothing could reach this one -- `pickDecision` returned ONE answer per
    // route, and on `/registration/new` both answers (`island` on the
    // journey, `island` on the error summary the journey's AuthForm absorbed)
    // are rank 2, so the id tie-break handed back `RAILS_AUTH_JOURNEY...` and
    // the summary's answer was never applied at all. Every answer is applied
    // now, so it lands here -- as the superseded shape, not the deferred one:
    // the AuthForm island is what renders those errors.
    var j = try runJourney(gpa, .{});
    defer j.deinit(gpa);

    const signup = j.route("GET", "/registration/new");
    try testing.expectEqual(Status.migrated, signup.status);
    try testing.expect(!contains(signup.open_finding_ids, j.errors_id));

    const note = signup.note orelse return error.NoNote;
    try testing.expect(std.mem.indexOf(u8, note, "superseded by the island answering") != null);
    try testing.expect(std.mem.indexOf(u8, note, j.errors_id) != null);
    // The superseder is the JOURNEY, not an `AuthStatus`, which is exactly
    // why ruling S3-R7's silence rule does not cover this one: no status
    // region encloses the summary, so no `mounts nothing of its own` note is
    // coming, and naming the answer that swallowed it is the only way the
    // operator learns where their errors went.
    try testing.expect(std.mem.indexOf(u8, note, j.journey_id) != null);
    try testing.expect(std.mem.indexOf(u8, note, "deferred to Stage 4") == null);
}

test "write: with the nested control unanswered the route is finished and says nothing about it" {
    const gpa = testing.allocator;
    // The other half of the ruling. Answering the enclosing region alone is
    // the CORRECT operator move and was already the working path -- the note
    // must not appear on it, or every migrated route would carry an
    // explanation of an answer nobody wrote.
    var j = try runJourney(gpa, .{});
    defer j.deinit(gpa);

    const root = j.route("GET", "/");
    try testing.expectEqual(Status.migrated, root.status);
    try testing.expect(!contains(root.open_finding_ids, j.button_id));
    try testing.expect(std.mem.indexOf(u8, root.note orelse "", "superseded") == null);
}

test "write: retain on the nested control still outranks the island around it" {
    const gpa = testing.allocator;
    // Ruling S3-R6 changes what an ACCEPTED answer does, not the precedence
    // that decides which answer is read. `rank` puts `retain` (3) above every
    // answer that produces something (2), so an operator who wrote `retain`
    // against the sign-out control has said this page stays on Rails, and the
    // island around it does not overrule that -- the same reading ruling S19
    // gives a `retain` on the error summary a bound form absorbed. The route
    // is `retained`, writes no page, and gets no "superseded" note, because
    // nothing was superseded: the retain WON.
    var j = try runJourney(gpa, .{ .button_choice = "retain" });
    defer j.deinit(gpa);

    const root = j.route("GET", "/");
    try testing.expectEqualStrings(j.button_id, root.decision_id orelse "");
    try testing.expectEqual(Status.retained, root.status);
    try testing.expect(std.mem.indexOf(u8, root.note orelse "", "superseded") == null);
    try testing.expect(!targetHas(&j.tmp, "content/index.smd"));
}

test "write: retain on the auth journey scaffolds nothing at all" {
    const gpa = testing.allocator;
    // The brief's negative half: `retain` means the flow stays on Rails, so
    // there is no island, no client, and no `@zigbase/client` dependency for
    // `bun install` to fetch.
    var j = try runJourney(gpa, .{ .journey_choice = "retain", .status_choice = null });
    defer j.deinit(gpa);

    try testing.expect(!targetHas(&j.tmp, auth_form_island_path));
    try testing.expect(!targetHas(&j.tmp, auth_status_island_path));
    try testing.expect(!targetHas(&j.tmp, client_lib_path));
    try testing.expect(!targetHas(&j.tmp, "package.json"));
    // ... and no endpoint either: nothing was bound.
    try testing.expect(j.route("POST", "/session").endpoint == null);
    try testing.expect(j.route("DELETE", "/session").endpoint == null);
}

test "write: a journey with no sessions#new route renders no sign-in link" {
    const gpa = testing.allocator;
    // The plan's "T5 self" row. A journey detected only by a password form
    // has no sign-in PAGE, so there is nowhere for the signed-out branch to
    // point -- and a link to a route that does not exist is worse than none.
    var j = try runJourney(gpa, .{ .without_signin_route = true });
    defer j.deinit(gpa);

    const island = try readTarget(gpa, &j.tmp, auth_status_island_path);
    defer gpa.free(island);
    try testing.expect(std.mem.indexOf(u8, island, "<a href=") == null);
    try testing.expect(std.mem.indexOf(
        u8,
        island,
        "// This journey has no `sessions#new` route, so there is nowhere to link.\n    return null;",
    ) != null);
}

test "write: island on a request_state that is not the auth status keeps the Stage 4 deferral" {
    const gpa = testing.allocator;
    // Only the four names Rails' own auth helpers use become `AuthStatus`.
    // Everything else is Stage 4's component port, and claiming otherwise
    // would put an island in the target that logs the visitor out of a
    // shopping basket. The app HAS a bound journey, so the arm that would
    // wrongly claim this region is live.
    const view_nodes = [_]fragments.Node{
        tOpen(.request_state, 1, 4, "cart_count", "if cart_count"),
        tEnd(1, 40),
    };
    const signin_nodes = passwordFormNodes();
    const frags = [_]fragments.Template{
        tTemplate("app/views/pages/home.html.erb", &view_nodes),
        tTemplate("app/views/sessions/new.html.erb", &signin_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/", "pages", "home", 1, "root"),
        tNamed("POST", "/session", "sessions", "create", 5, "session"),
        tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.backend), tVerdict(.content) };
    var tpls = [_][]const u8{"app/views/pages/home.html.erb"};
    var signin_tpls = [_][]const u8{"app/views/sessions/new.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signin_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{
        "app/views/pages/home.html.erb",
        null,
        "app/views/sessions/new.html.erb",
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "root", "session", "new_session" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
    });
    defer findings.free(gpa, finding_list);

    var state_id: []const u8 = "";
    var journey_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_request_time_state)) state_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
    }
    try testing.expect(state_id.len > 0);
    try testing.expect(journey_id.len > 0);
    var decided = [_]decisions.Decision{
        .{
            .id = state_id,
            .choice = "island",
            .rationale = "the cart badge is client state",
            .artifact = "components/Cart.island.tsx",
        },
        .{ .id = journey_id, .choice = "island", .rationale = "auth", .artifact = "users" },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = null,
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const home = for (res.routes) |o| {
        if (std.mem.eql(u8, rs[o.route_index].path, "/")) break o;
    } else unreachable;
    try testing.expectEqual(Status.open, home.status);
    try testing.expect(std.mem.indexOf(
        u8,
        home.note orelse "",
        "choice island deferred to Stage 4",
    ) != null);
    try testing.expect(!targetHas(&tmp, auth_status_island_path));
    // The journey itself DID scaffold, so the arm really was reachable.
    try testing.expect(targetHas(&tmp, auth_form_island_path));
}

test "write: the auth scaffolds are byte-identical on a second run" {
    const gpa = testing.allocator;
    var a = try runJourney(gpa, .{});
    defer a.deinit(gpa);
    var b = try runJourney(gpa, .{});
    defer b.deinit(gpa);

    const paths = [_][]const u8{
        auth_form_island_path,
        auth_status_island_path,
        client_lib_path,
        "build.sh",
        "layouts/templates/marketing.shtml",
        "layouts/sessions/new.shtml",
        "layouts/registrations/new.shtml",
    };
    for (paths) |p| {
        const x = try readTarget(gpa, &a.tmp, p);
        defer gpa.free(x);
        const y = try readTarget(gpa, &b.tmp, p);
        defer gpa.free(y);
        try testing.expectEqualStrings(x, y);
    }
}

test "write: the auth-journey branches leak nothing under a FailingAllocator" {
    const gpa = testing.allocator;
    const home_nodes = [_]fragments.Node{tText("<h1>Home</h1>", 1)};
    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.render_partial, 2, 3, "shared/nav"),
        tNode(.yield, 3, 3, null),
        tText("</body></html>", 4),
    };
    const nav_all = journeyNavNodes();
    const nav_nodes = nav_all[0..4];
    // Ruling S3-R3, exercised rather than described: the sign-in form lives in
    // a PARTIAL the journey view renders, which is where a real Rails app
    // keeps it. A pre-pass that read only the route's own view would leave the
    // commonest journey form unbound.
    const signin_nodes = [_]fragments.Node{tNode(.render_partial, 1, 1, "form")};
    const signin_partial_nodes = passwordFormNodes();
    const edit_nodes = [_]fragments.Node{tText("<h1>Session</h1>", 1)};
    const signup_nodes = journeySignupNodes();
    const frags = [_]fragments.Template{
        tTemplate(journey_layout, &layout_nodes),
        tTemplate("app/views/pages/home.html.erb", &home_nodes),
        tTemplate(journey_signup_view, &signup_nodes),
        tTemplate(journey_edit_view, &edit_nodes),
        tTemplate(journey_signin_partial, &signin_partial_nodes),
        tTemplate(journey_signin_view, &signin_nodes),
        tTemplate(journey_nav, nav_nodes),
    };
    var vs = [_]classify.Verdict{
        tVerdict(.content),
        tVerdict(.backend),
        tVerdict(.content),
        tVerdict(.backend),
        tVerdict(.backend),
        tVerdict(.content),
        tVerdict(.content),
    };
    var home_tpls = [_][]const u8{"app/views/pages/home.html.erb"};
    var signup_tpls = [_][]const u8{journey_signup_view};
    var edit_tpls = [_][]const u8{journey_edit_view};
    var signin_tpls = [_][]const u8{journey_signin_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &home_tpls, .layout = journey_layout },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signup_tpls, .layout = journey_layout },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &edit_tpls, .layout = journey_layout },
        .{ .templates = &signin_tpls, .layout = journey_layout },
    };
    const route_views = [_]?[]const u8{
        "app/views/pages/home.html.erb",
        null,
        journey_signup_view,
        null,
        null,
        journey_edit_view,
        journey_signin_view,
    };
    const render_graph = [_]findings.TemplateRenders{
        .{ .path = journey_layout, .renders = &[_][]const u8{journey_nav} },
        .{ .path = journey_signin_view, .renders = &[_][]const u8{journey_signin_partial} },
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "root", "registration", "new_registration", "session", "new_session", "edit_session" },
        .locale = null,
        .render_graph = &render_graph,
        .routes = &journey_app_routes,
        .classifications = &vs,
        .route_views = &route_views,
    });
    defer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    var status_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_request_time_state) and
            std.mem.eql(u8, f.path, journey_nav) and
            std.mem.endsWith(u8, f.id, ".L2C3")) status_id = f.id;
    }
    var decided = [_]decisions.Decision{
        .{ .id = journey_id, .choice = "island", .rationale = "auth", .artifact = "users" },
        .{ .id = status_id, .choice = "island", .rationale = "state", .artifact = null },
    };

    var signin_redirects = [_]controllers.RedirectInfo{.{ .name = "root", .args = &.{} }};
    var actions = [_]controllers.ActionInfo{
        .{ .controller = "sessions", .action = "create", .redirects = &signin_redirects },
    };

    var d = emptyDiscovery();
    d.routes = &journey_app_routes;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;
    d.actions = &actions;

    var fail_index: usize = 0;
    while (fail_index < 1200) : (fail_index += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);

        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var err_path: ?[]const u8 = null;
        defer if (err_path) |p| fa.free(p);
        var err_cause: ?anyerror = null;

        if (write(std.testing.io, fa, .{
            .discovery = &d,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = tmp.dir,
            .target = target,
            .app_name = "Blog",
            .runtime_path = "../runtime",
            .agents_md = "",
            .claude_md = "",
        }, &err_path, &err_cause)) |res| {
            freeResult(fa, res);
            break; // past the last allocation: the sweep is complete.
        } else |err| switch (err) {
            error.OutOfMemory => {},
            error.TargetWrite, error.SourceRead => {},
        }
    }
    try testing.expect(fail_index < 1200);
}

/// The journey's render-depth boundary, as a whole `write`: `sessions#new`
/// renders `_a`, which renders `_b`, `_c` and finally `_deep`, which holds the
/// password form. Four hops, and `max_journey_render_depth` is three, so
/// `_deep` is NOT a journey view and keeps its own `RAILS_BACKEND_ENDPOINT`.
///
/// `deep_choice` is what the operator answered that question with, or `null`
/// for the unanswered case.
fn runDeepJourney(gpa: Allocator, deep_choice: ?[]const u8) !JourneyRun {
    const form_nodes = passwordFormNodes();
    // `new -> _a -> _b -> _c -> _deep`, one bare `render "<next>"` per
    // template (`partialPathIn` resolves a bare name against the rendering
    // template's own directory, Rails' own rule).
    const a_nodes = [_]fragments.Node{tNode(.render_partial, 1, 1, "a")};
    const b_nodes = [_]fragments.Node{tNode(.render_partial, 1, 1, "b")};
    const c_nodes = [_]fragments.Node{tNode(.render_partial, 1, 1, "c")};
    const deep_nodes = [_]fragments.Node{tNode(.render_partial, 1, 1, "deep")};
    const frags = [_]fragments.Template{
        tTemplate("app/views/sessions/_a.html.erb", &b_nodes),
        tTemplate("app/views/sessions/_b.html.erb", &c_nodes),
        tTemplate("app/views/sessions/_c.html.erb", &deep_nodes),
        tTemplate("app/views/sessions/_deep.html.erb", &form_nodes),
        tTemplate("app/views/sessions/new.html.erb", &a_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("POST", "/session", "sessions", "create", 5, "session"),
        tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.backend), tVerdict(.content) };
    var new_tpls = [_][]const u8{"app/views/sessions/new.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &new_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{ null, "app/views/sessions/new.html.erb" };
    // The four hops `new -> _a -> _b -> _c -> _deep`. The cap is three, so
    // `_deep` is outside the journey.
    const render_graph = [_]findings.TemplateRenders{
        .{ .path = "app/views/sessions/new.html.erb", .renders = &[_][]const u8{"app/views/sessions/_a.html.erb"} },
        .{ .path = "app/views/sessions/_a.html.erb", .renders = &[_][]const u8{"app/views/sessions/_b.html.erb"} },
        .{ .path = "app/views/sessions/_b.html.erb", .renders = &[_][]const u8{"app/views/sessions/_c.html.erb"} },
        .{ .path = "app/views/sessions/_c.html.erb", .renders = &[_][]const u8{"app/views/sessions/_deep.html.erb"} },
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "session", "new_session" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .render_graph = &render_graph,
    });
    errdefer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    var deep_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint) and
            std.mem.eql(u8, f.path, "app/views/sessions/_deep.html.erb")) deep_id = f.id;
    }
    try testing.expect(journey_id.len > 0);
    // The premise: `findings.derive` really does still ask about this form.
    // Without it the test would pass for the wrong reason.
    try testing.expect(deep_id.len > 0);

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    try body.print(
        gpa,
        "{{\"schema\":\"zigapagos.rails-decisions/1\",\"decisions\":[" ++
            "{{\"id\":\"{s}\",\"choice\":\"island\",\"rationale\":\"the flow becomes ZigBase auth\",\"artifact\":\"users\"}}",
        .{journey_id},
    );
    if (deep_choice) |c| {
        try body.print(
            gpa,
            ",{{\"id\":\"{s}\",\"choice\":\"{s}\",\"rationale\":\"this form is not the journey's\"}}",
            .{ deep_id, c },
        );
    }
    try body.appendSlice(gpa, "]}");

    var problems: std.ArrayListUnmanaged(decisions.Problem) = .empty;
    defer decisions.freeProblems(gpa, &problems);
    const parsed = try decisions.parse(gpa, body.items, finding_list, &.{}, &problems);
    errdefer decisions.free(gpa, parsed);
    try testing.expectEqual(@as(usize, 0), problems.items.len);

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = parsed,
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);

    return .{
        .tmp = tmp,
        .res = res,
        .finding_list = finding_list,
        .parsed = parsed,
        .routes = &deep_journey_routes,
        .journey_id = journey_id,
        .status_id = "",
        .button_id = "",
        .errors_id = deep_id,
        .status2_id = "",
        .home_status_id = "",
    };
}

/// `runDeepJourney`'s route table, module-level for the same reason
/// `journey_app_routes` is: `JourneyRun.route` reads it after the helper's own
/// frame is gone.
var deep_journey_routes = [_]route_mod.Route{
    tNamed("POST", "/session", "sessions", "create", 5, "session"),
    tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
};

test "write: a form past the journey's render depth keeps its own backend question" {
    const gpa = testing.allocator;
    // The guard that keeps this file's uncapped partial walk agreeing with
    // `findings.derive`'s capped one: `detectJourney` widens the journey
    // through at most three render hops, so a form four deep is NOT a journey
    // view and still raises its own `RAILS_BACKEND_ENDPOINT`. Binding it as an
    // `AuthForm` anyway would answer a question nobody answered, with a
    // component that signs people in.
    var j = try runDeepJourney(gpa, null);
    defer j.deinit(gpa);

    try testing.expect(!targetHas(&j.tmp, auth_form_island_path));
    for (j.res.routes) |o| {
        if (!std.mem.eql(u8, j.routes[o.route_index].verb, "GET")) continue;
        try testing.expect(contains(o.open_finding_ids, j.errors_id));
    }
}

test "write: a form past the journey's render depth is still bound by its own answer" {
    const gpa = testing.allocator;
    // The other half of the boundary, and the defect a SHARED `seen` set
    // caused. The journey pre-pass walks partials without a depth cap, so it
    // reached `_deep`, found a finding at the form (which is how it knows the
    // form is not the journey's) and correctly declined to bind it -- but with
    // one `seen` set it had also CLAIMED the template, so the ordinary pass
    // never walked it and the operator's answer produced nothing at all: no
    // island, no `lib/zb.ts`, and a route left open on a question that had
    // been answered. Two sets, and each pass sees every template it needs.
    var j = try runDeepJourney(gpa, "custom:/api/password-resets");
    defer j.deinit(gpa);

    // The journey's own scaffolds are still absent -- `_deep` is not a journey
    // view, so nothing in this app mounts an `AuthForm`.
    try testing.expect(!targetHas(&j.tmp, auth_form_island_path));

    // The answered form became an ordinary Task 4 island, and the marker it
    // replaced is gone from the page.
    const page = try readTarget(gpa, &j.tmp, "layouts/sessions/new.shtml");
    defer gpa.free(page);
    try testing.expect(std.mem.indexOf(u8, page, j.errors_id) == null);
    try testing.expect(std.mem.indexOf(u8, page, "<island src=\"components/forms/") != null);

    // The island file is on disk and calls the path the answer named. Read
    // through the route's own artifact list rather than by spelling the name,
    // so this test does not pin `islandPath`'s naming rule.
    const o = j.route("GET", "/session/new");
    var island_path: ?[]const u8 = null;
    for (o.artifacts) |a| {
        if (std.mem.startsWith(u8, a, "components/forms/")) island_path = a;
    }
    try testing.expect(island_path != null);
    const island = try readTarget(gpa, &j.tmp, island_path.?);
    defer gpa.free(island);
    try testing.expect(std.mem.indexOf(u8, island, "/api/password-resets") != null);
    try testing.expect(targetHas(&j.tmp, client_lib_path));
}

test "write: a password_confirmation field makes a form sign-up under any controller" {
    const gpa = testing.allocator;
    // The brief gives two independent signals for the sign-up half. This is
    // the one a controller-name check alone would miss: `accounts` is a
    // journey controller only because its view holds a password form (A5's
    // second half), and the confirmation field is what says it REGISTERS.
    var form_nodes = [_]fragments.Node{
        tOpen(.form, 1, 4, null, "form_with(url: accounts_path) do |f|"),
        tArgs(.form_field, 1, 40, "password_field", &.{"password"}),
        tArgs(.form_field, 1, 60, "password_field", &.{"password_confirmation"}),
        tEnd(1, 90),
    };
    const frags = [_]fragments.Template{tTemplate("app/views/accounts/new.html.erb", &form_nodes)};
    var rs = [_]route_mod.Route{
        tNamed("POST", "/accounts", "accounts", "create", 7, "accounts"),
        tNamed("GET", "/accounts/new", "accounts", "new", 7, "new_account"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.backend), tVerdict(.content) };
    var new_tpls = [_][]const u8{"app/views/accounts/new.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &new_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{ null, "app/views/accounts/new.html.erb" };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "accounts", "new_account" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
    });
    defer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
    }
    try testing.expect(journey_id.len > 0);
    var decided = [_]decisions.Decision{
        .{ .id = journey_id, .choice = "island", .rationale = "auth", .artifact = "users" },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const view = try readTarget(gpa, &tmp, "layouts/accounts/new.shtml");
    defer gpa.free(view);
    try testing.expect(std.mem.indexOf(u8, view, ":props='{ .mode = \"signup\" }'") != null);
}

test "write: an unanswered current_user region scaffolds no AuthStatus" {
    const gpa = testing.allocator;
    // The journey's `island` answers the FORMS. Who is signed in is a
    // separate finding with a separate answer, and replacing the region
    // without one would convert markup nobody asked about.
    var j = try runJourney(gpa, .{ .status_choice = null });
    defer j.deinit(gpa);

    try testing.expect(targetHas(&j.tmp, auth_form_island_path));
    try testing.expect(!targetHas(&j.tmp, auth_status_island_path));
    // ... and the region is still a question the operator can answer.
    const layout = try readTarget(gpa, &j.tmp, "layouts/templates/marketing.shtml");
    defer gpa.free(layout);
    try testing.expect(std.mem.indexOf(u8, layout, j.status_id) != null);

    // `retain` is the other half, and a different code path: the id IS in the
    // decisions file, so the binding is refused by the CHOICE and not by the
    // lookup. An `AuthStatus` here would replace a region the operator said
    // stays on Rails.
    var k = try runJourney(gpa, .{ .status_choice = "retain" });
    defer k.deinit(gpa);
    try testing.expect(!targetHas(&k.tmp, auth_status_island_path));
    for (k.res.routes) |o| {
        if (!std.mem.eql(u8, k.routes[o.route_index].verb, "GET")) continue;
        try testing.expectEqual(Status.retained, o.status);
    }
}

test "write: an island answer on a DIFFERENT code at the region's position scaffolds no AuthStatus" {
    const gpa = testing.allocator;
    // `convert.findingIdFor` is a POSITION lookup -- `(path, .L<line>C<col>)`,
    // first match in list order, code not consulted. So the id it hands back
    // for the `current_user` node is not necessarily the row the operator was
    // asked about, and an `island` there is not necessarily an answer to
    // "who is signed in". Without the code check, an `island` on any finding
    // that happens to share the position mounts an `AuthStatus` -- a component
    // that reads an auth store, in place of a region nobody asked about.
    var j = try runJourney(gpa, .{ .status_choice = null, .shadow_status_finding = true });
    defer j.deinit(gpa);

    try testing.expect(!targetHas(&j.tmp, auth_status_island_path));
    // The journey itself is untouched: its own answer still scaffolds.
    try testing.expect(targetHas(&j.tmp, auth_form_island_path));
    // …and the region is still a marker on the page rather than a component:
    // nothing answered the question that was actually asked about it. (The id
    // in the marker is the shadow's, because `openRegion` reads the same
    // position lookup -- which is the point: the id at a position is not
    // evidence about the code, so the code must be checked separately.)
    const layout = try readTarget(gpa, &j.tmp, "layouts/templates/marketing.shtml");
    defer gpa.free(layout);
    try testing.expect(std.mem.indexOf(u8, layout, "<!-- rails:finding ") != null);
    try testing.expect(std.mem.indexOf(u8, layout, "<island") == null);
}

test "write: lib/zb.ts names no auth collection when no scaffold reached the target" {
    const gpa = testing.allocator;
    // `authCollection` arms the client's own 401 refresh, which re-authenticates
    // against that collection. Setting it because a journey was ANSWERED --
    // rather than because an auth scaffold is actually in the target -- arms a
    // refresh for a site that never signs anybody in, so the first 401 from an
    // ordinary bound form turns into an auth call that can only fail. This app
    // is exactly that shape: the journey routes carry no view, so no
    // `AuthForm`; the `current_user` region is unanswered, so no `AuthStatus`;
    // and an ordinary form elsewhere is what puts `lib/zb.ts` in the target at
    // all.
    const home_nodes = boundViewNodes(false, false);
    const nav_all = journeyNavNodes();
    const nav_nodes = nav_all[0..4];
    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.render_partial, 2, 3, "shared/nav"),
        tNode(.yield, 3, 3, null),
        tText("</body></html>", 4),
    };
    const frags = [_]fragments.Template{
        tTemplate(journey_layout, &layout_nodes),
        tTemplate("app/views/pages/home.html.erb", &home_nodes),
        tTemplate(journey_nav, nav_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/", "pages", "home", 1, "root"),
        tNamed("POST", "/session", "sessions", "create", 5, "session"),
        tNamed("DELETE", "/session", "sessions", "destroy", 5, "session"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.backend), tVerdict(.backend) };
    var home_tpls = [_][]const u8{"app/views/pages/home.html.erb"};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &home_tpls, .layout = journey_layout },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &.{}, .layout = null },
    };
    const route_views = [_]?[]const u8{ "app/views/pages/home.html.erb", null, null };
    const render_graph = [_]findings.TemplateRenders{
        .{ .path = journey_layout, .renders = &[_][]const u8{journey_nav} },
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "root", "session", "session" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .render_graph = &render_graph,
    });
    defer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    var form_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint) and
            std.mem.eql(u8, f.path, "app/views/pages/home.html.erb")) form_id = f.id;
    }
    // The premise: a journey WAS detected (the two `sessions` routes), and an
    // ordinary form elsewhere WAS asked about.
    try testing.expect(journey_id.len > 0);
    try testing.expect(form_id.len > 0);

    var decided = [_]decisions.Decision{
        .{ .id = journey_id, .choice = "island", .rationale = "auth", .artifact = "users" },
        .{ .id = form_id, .choice = "custom:/api/posts", .rationale = "posts", .artifact = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // Neither scaffold is in the target…
    try testing.expect(!targetHas(&tmp, auth_form_island_path));
    try testing.expect(!targetHas(&tmp, auth_status_island_path));
    // …but the ordinary form's island is, so `lib/zb.ts` is written.
    try testing.expect(targetHas(&tmp, client_lib_path));
    const lib = try readTarget(gpa, &tmp, client_lib_path);
    defer gpa.free(lib);
    try testing.expect(std.mem.indexOf(u8, lib, "authCollection") == null);
    try testing.expect(std.mem.indexOf(u8, lib, "new LocalAuthStore()") != null);
}

test "write: the auth scaffolds and two colliding form stems each get their own file, written once" {
    const gpa = testing.allocator;
    // The seam between Task 5's fixed-path pair and Task 4 round 2's
    // de-collision, which pull in opposite directions and have to hold
    // together.
    //
    // `uniqueIslandPath` exists because flattening `/` to `_` makes DISTINCT
    // view stems claim one name, and two distinct islands under one path ship
    // the wrong form. The auth pair is the deliberate opposite: two bindings,
    // ONE path, because `sessions#new` and `registrations#new` mount the same
    // component and differ only by a prop. `writeIslandFiles` keys its skip on
    // the finding id rather than the path so both cases come out right -- the
    // journey's two bindings share the app's single `RAILS_AUTH_JOURNEY` id,
    // the two colliding forms do not share anything -- and it asserts the two
    // keys agree.
    //
    // The families also must not cross, and what keeps them apart is the
    // NAMES rather than the order the two passes run in: `islandPath` always
    // emits a `components/forms/` prefix and the auth pair is flat under
    // `components/`. (The property the pre-pass ORDER does carry --
    // `journeyEndpoints` filling `acc.endpoints` first -- has its own test.)
    const signin_nodes = passwordFormNodes();
    const signup_nodes = passwordFormNodes();
    const nav_all = journeyNavNodes();
    const nav_nodes = nav_all[0..4];
    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.render_partial, 2, 3, "shared/nav"),
        tNode(.yield, 3, 3, null),
        tText("</body></html>", 4),
    };
    // `a_b/new` and `a/b_new` both flatten to `components/forms/a_b_new`.
    const nodes_a = [_]fragments.Node{
        tOpen(.form, 2, 4, "alpha", "form_with(url: \"/api/alpha\") do |f|"),
        tArgs(.form_field, 2, 40, "text_field", &.{"alpha_field"}),
        tArgs(.form_field, 2, 60, "submit", &.{"Alpha"}),
        tEnd(2, 80),
    };
    const nodes_b = [_]fragments.Node{
        tOpen(.form, 2, 4, "beta", "form_with(url: \"/api/beta\") do |f|"),
        tArgs(.form_field, 2, 40, "text_field", &.{"beta_field"}),
        tArgs(.form_field, 2, 60, "submit", &.{"Beta"}),
        tEnd(2, 80),
    };
    const frags = [_]fragments.Template{
        tTemplate(journey_layout, &layout_nodes),
        tTemplate(collide_view_a, &nodes_a),
        tTemplate(collide_view_b, &nodes_b),
        tTemplate(journey_signup_view, &signup_nodes),
        tTemplate(journey_signin_view, &signin_nodes),
        tTemplate(journey_nav, nav_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("POST", "/registration", "registrations", "create", 6, "registration"),
        tNamed("GET", "/registration/new", "registrations", "new", 6, "new_registration"),
        tNamed("POST", "/session", "sessions", "create", 5, "session"),
        tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
        tNamed("GET", "/x", "a_b", "new", 2, "x"),
        tNamed("GET", "/y", "a", "b_new", 3, "y"),
    };
    var vs = [_]classify.Verdict{
        tVerdict(.backend), tVerdict(.content), tVerdict(.backend),
        tVerdict(.content), tVerdict(.content), tVerdict(.content),
    };
    var signup_tpls = [_][]const u8{journey_signup_view};
    var signin_tpls = [_][]const u8{journey_signin_view};
    var tpls_a = [_][]const u8{collide_view_a};
    var tpls_b = [_][]const u8{collide_view_b};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signup_tpls, .layout = journey_layout },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signin_tpls, .layout = journey_layout },
        .{ .templates = &tpls_a, .layout = journey_layout },
        .{ .templates = &tpls_b, .layout = journey_layout },
    };
    const route_views = [_]?[]const u8{
        null, journey_signup_view, null, journey_signin_view, collide_view_a, collide_view_b,
    };
    const route_names = [_][]const u8{
        "registration", "new_registration", "session", "new_session", "x", "y",
    };
    const render_graph = [_]findings.TemplateRenders{
        .{ .path = journey_layout, .renders = &[_][]const u8{journey_nav} },
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .render_graph = &render_graph,
    });
    defer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    var status_id: []const u8 = "";
    var alpha_id: []const u8 = "";
    var beta_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_request_time_state) and
            std.mem.eql(u8, f.path, journey_nav) and
            std.mem.endsWith(u8, f.id, ".L2C3")) status_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_backend_endpoint)) {
            if (std.mem.eql(u8, f.path, collide_view_a)) alpha_id = f.id;
            if (std.mem.eql(u8, f.path, collide_view_b)) beta_id = f.id;
        }
    }
    try testing.expect(journey_id.len > 0);
    try testing.expect(status_id.len > 0);
    // The premise: the two colliding forms ARE two separate questions, and the
    // journey's two forms are not questions of their own at all (A5).
    try testing.expect(alpha_id.len > 0);
    try testing.expect(beta_id.len > 0);
    try testing.expect(!std.mem.eql(u8, alpha_id, beta_id));

    var decided = [_]decisions.Decision{
        .{ .id = journey_id, .choice = "island", .rationale = "auth", .artifact = "users" },
        .{ .id = status_id, .choice = "island", .rationale = "client state", .artifact = null },
        .{ .id = alpha_id, .choice = "custom:/api/alpha", .rationale = "alpha", .artifact = null },
        .{ .id = beta_id, .choice = "custom:/api/beta", .rationale = "beta", .artifact = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // Four distinct island files: the journey's pair, and one per colliding
    // form -- the second de-collided by `uniqueIslandPath`'s per-name ordinal.
    try testing.expect(targetHas(&tmp, auth_form_island_path));
    try testing.expect(targetHas(&tmp, auth_status_island_path));
    try testing.expect(targetHas(&tmp, "components/forms/a_b_new.island.tsx"));
    try testing.expect(targetHas(&tmp, "components/forms/a_b_new_2.island.tsx"));

    // Each is bundled exactly once, and no auth name was ever a candidate the
    // form walk could have claimed.
    const build_sh = try readTarget(gpa, &tmp, "build.sh");
    defer gpa.free(build_sh);
    const paths = [_][]const u8{
        auth_form_island_path,
        auth_status_island_path,
        "components/forms/a_b_new.island.tsx",
        "components/forms/a_b_new_2.island.tsx",
    };
    for (paths) |p| {
        var at: usize = 0;
        var count: usize = 0;
        while (std.mem.indexOfPos(u8, build_sh, at, p)) |k| {
            count += 1;
            at = k + 1;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // The two colliding forms really did stay two islands calling two
    // endpoints -- the failure this de-collision exists to prevent is one page
    // shipping the other's form.
    const alpha = try readTarget(gpa, &tmp, "components/forms/a_b_new.island.tsx");
    defer gpa.free(alpha);
    const beta = try readTarget(gpa, &tmp, "components/forms/a_b_new_2.island.tsx");
    defer gpa.free(beta);
    try testing.expect(std.mem.indexOf(u8, alpha, "/api/alpha") != null);
    try testing.expect(std.mem.indexOf(u8, beta, "/api/beta") != null);

    // …and the journey's two views still mount ONE component, told apart by a
    // prop: the same-path case the id-keyed skip is what makes correct.
    const signin = try readTarget(gpa, &tmp, "layouts/sessions/new.shtml");
    defer gpa.free(signin);
    const signup = try readTarget(gpa, &tmp, "layouts/registrations/new.shtml");
    defer gpa.free(signup);
    try testing.expect(std.mem.indexOf(u8, signin, "\" client:load :props='{ .mode = \"signin\" }'") != null);
    try testing.expect(std.mem.indexOf(u8, signup, "\" client:load :props='{ .mode = \"signup\" }'") != null);
    try testing.expect(std.mem.indexOf(u8, signin, auth_form_island_path) != null);
    try testing.expect(std.mem.indexOf(u8, signup, auth_form_island_path) != null);
}

test "write: two answered status regions in ONE template share the one AuthStatus file" {
    const gpa = testing.allocator;
    // C-1. A nav that shows a name when signed in and a link when signed out
    // is two `request_state` regions, two findings and two `island` answers --
    // and ONE component, because `AuthStatus` renders both branches itself.
    // `bindAuthStatus` emits a binding per region, each carrying its own
    // region's finding id (which is what settles that region and places its
    // `<island>`), and every one of them names the same fixed path. Keying the
    // write-once skip on the binding id therefore saw the second island as
    // unwritten while its path was already on disk: the assertion fired
    // (RC 134 in Debug) and, with assertions off, `writeFile`'s
    // exclusive-create guard fataled `PathAlreadyExists` over a half-written
    // target. The island's identity is the JOURNEY's, not the region's.
    var j = try runJourney(gpa, .{ .second_status_in_nav = true });
    defer j.deinit(gpa);

    try testing.expect(targetHas(&j.tmp, auth_status_island_path));
    // Both regions were replaced -- neither is still a marker on the page.
    const layout = try readTarget(gpa, &j.tmp, "layouts/templates/marketing.shtml");
    defer gpa.free(layout);
    try testing.expect(std.mem.indexOf(u8, layout, j.status_id) == null);
    try testing.expect(std.mem.indexOf(u8, layout, j.status2_id) == null);
    // ONE mount, not two. `AuthStatus` renders BOTH branches itself, so
    // mounting it at each half of a complementary pair renders the whole
    // control twice: "Sign in" twice in one `<nav>` for a visitor with no
    // session, and the email plus a Sign-out button twice for one with. The
    // pair is one control and gets one mount, at the FIRST region; the second
    // is absorbed (see `bindAuthStatus`).
    var at: usize = 0;
    var mounts: usize = 0;
    while (std.mem.indexOfPos(u8, layout, at, "<island src=\"" ++ auth_status_island_path ++ "\"")) |k| {
        mounts += 1;
        at = k + 1;
    }
    try testing.expectEqual(@as(usize, 1), mounts);
    // Both findings are settled all the same -- the absorbed region was
    // answered, and an answer that produced nothing an operator can see would
    // leave the route open forever.
    const root = j.route("GET", "/");
    try testing.expectEqual(Status.migrated, root.status);
    try testing.expectEqual(@as(usize, 0), root.open_finding_ids.len);
    // ...and the route says WHICH region was folded in, so the operator can
    // see why one of their two answers produced no second component.
    const note = root.note orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, note, journey_nav) != null);
    try testing.expect(std.mem.indexOf(u8, note, "unless current_user") != null);

    // ONE file, and one `--island=` flag: two would make `release` bundle the
    // same entry twice.
    const build_sh = try readTarget(gpa, &j.tmp, "build.sh");
    defer gpa.free(build_sh);
    at = 0;
    var flags: usize = 0;
    while (std.mem.indexOfPos(u8, build_sh, at, "--island='" ++ auth_status_island_path ++ "'")) |k| {
        flags += 1;
        at = k + 1;
    }
    try testing.expectEqual(@as(usize, 1), flags);
}

test "write: two answered status regions in DIFFERENT templates share the one AuthStatus file" {
    const gpa = testing.allocator;
    // The same defect from the other direction, and the shape a real app hits
    // first: `current_user` in the `shared/_nav` the LAYOUT renders, and
    // another on a page's own view. The two regions are written by two
    // different code paths -- `ensureLayout` on the spot, `materializeView`
    // when the page goes out -- so they also prove `acc.island_ids` is shared
    // between them rather than per-cache.
    var j = try runJourney(gpa, .{ .status_in_home = true });
    defer j.deinit(gpa);

    try testing.expect(targetHas(&j.tmp, auth_status_island_path));

    const layout = try readTarget(gpa, &j.tmp, "layouts/templates/marketing.shtml");
    defer gpa.free(layout);
    const home = try readTarget(gpa, &j.tmp, "layouts/pages/home.shtml");
    defer gpa.free(home);
    try testing.expect(std.mem.indexOf(u8, layout, "<island src=\"" ++ auth_status_island_path ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, home, "<island src=\"" ++ auth_status_island_path ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, home, j.home_status_id) == null);

    const build_sh = try readTarget(gpa, &j.tmp, "build.sh");
    defer gpa.free(build_sh);
    var at: usize = 0;
    var flags: usize = 0;
    while (std.mem.indexOfPos(u8, build_sh, at, "--island='" ++ auth_status_island_path ++ "'")) |k| {
        flags += 1;
        at = k + 1;
    }
    try testing.expectEqual(@as(usize, 1), flags);

    // The home route is `migrated`: its region was answered and carried out.
    const root = j.route("GET", "/");
    try testing.expectEqual(Status.migrated, root.status);
    try testing.expect(contains(root.artifacts, auth_status_island_path));
}

test "write: a retained route writes no AuthStatus, and the route that keeps its page still does" {
    const gpa = testing.allocator;
    // Ruling S20 across the shared file. Two content routes, each with a
    // `current_user` region of its own answered `island`; the first is ALSO
    // `retain`ed on a second finding, which outranks `island`, so its page is
    // never materialized and its island must not go out with it. The other
    // route still writes the one shared file -- a per-route skip that keyed on
    // the region would have let the retained route claim the write and then
    // never perform it, leaving the surviving page pointing at a file that is
    // not there.
    const a_nodes = [_]fragments.Node{
        tOpen(.request_state, 1, 3, "current_user", "if current_user"),
        tText("<b>a</b>", 1),
        tEnd(1, 40),
        // The second question on this view, and the one answered `retain`.
        tNode(.raw, 2, 3, "body"),
    };
    const b_nodes = [_]fragments.Node{
        tOpen(.request_state, 1, 3, "current_user", "if current_user"),
        tText("<b>b</b>", 1),
        tEnd(1, 40),
    };
    const signin_nodes = passwordFormNodes();
    const frags = [_]fragments.Template{
        tTemplate("app/views/pages/a.html.erb", &a_nodes),
        tTemplate("app/views/pages/b.html.erb", &b_nodes),
        tTemplate(journey_signin_view, &signin_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/a", "pages", "a", 1, "a"),
        tNamed("GET", "/b", "pages", "b", 2, "b"),
        tNamed("POST", "/session", "sessions", "create", 5, "session"),
        tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
    };
    var vs = [_]classify.Verdict{
        tVerdict(.content), tVerdict(.content), tVerdict(.backend), tVerdict(.content),
    };
    var a_tpls = [_][]const u8{"app/views/pages/a.html.erb"};
    var b_tpls = [_][]const u8{"app/views/pages/b.html.erb"};
    var signin_tpls = [_][]const u8{journey_signin_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &a_tpls, .layout = null },
        .{ .templates = &b_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signin_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{
        "app/views/pages/a.html.erb",
        "app/views/pages/b.html.erb",
        null,
        journey_signin_view,
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "a", "b", "session", "new_session" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
    });
    defer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    var a_status: []const u8 = "";
    var b_status: []const u8 = "";
    var a_raw: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_request_time_state)) {
            if (std.mem.eql(u8, f.path, "app/views/pages/a.html.erb")) a_status = f.id;
            if (std.mem.eql(u8, f.path, "app/views/pages/b.html.erb")) b_status = f.id;
        }
        if (std.mem.eql(u8, f.code, "RAILS_RAW_OUTPUT") and
            std.mem.eql(u8, f.path, "app/views/pages/a.html.erb")) a_raw = f.id;
    }
    try testing.expect(journey_id.len > 0);
    try testing.expect(a_status.len > 0);
    try testing.expect(b_status.len > 0);
    // The premise: `/a` has a SECOND question, which is what `retain` answers.
    // Retaining the status region itself would test the choice check instead.
    try testing.expect(a_raw.len > 0);

    var decided = [_]decisions.Decision{
        .{ .id = journey_id, .choice = "island", .rationale = "auth", .artifact = "users" },
        .{ .id = a_status, .choice = "island", .rationale = "client state", .artifact = null },
        .{ .id = b_status, .choice = "island", .rationale = "client state", .artifact = null },
        .{ .id = a_raw, .choice = "retain", .rationale = "this page stays on Rails", .artifact = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // `/a` retained: no page, and its island did not ride out with it.
    try testing.expect(!targetHas(&tmp, "layouts/pages/a.shtml"));
    // `/b` kept its page, so the shared file IS in the target.
    try testing.expect(targetHas(&tmp, "layouts/pages/b.shtml"));
    try testing.expect(targetHas(&tmp, auth_status_island_path));
    const b_page = try readTarget(gpa, &tmp, "layouts/pages/b.shtml");
    defer gpa.free(b_page);
    try testing.expect(std.mem.indexOf(u8, b_page, "<island src=\"" ++ auth_status_island_path ++ "\"") != null);

    for (res.routes) |o| {
        if (std.mem.eql(u8, rs[o.route_index].path, "/a")) {
            try testing.expectEqual(Status.retained, o.status);
            try testing.expect(!contains(o.artifacts, auth_status_island_path));
        }
        if (std.mem.eql(u8, rs[o.route_index].path, "/b")) {
            try testing.expectEqual(Status.migrated, o.status);
            try testing.expect(contains(o.artifacts, auth_status_island_path));
        }
    }
}

test "write: the AuthStatus fold note is a migrated route's, not a retained route's" {
    const gpa = testing.allocator;
    // t5r3. The note was added by STATEMENT POSITION -- above the
    // acknowledgement return -- so it reached every route sharing a template
    // with a folded region, `retain`ed ones included. A retained route writes
    // no page and mounts no island, so "folded into the AuthStatus island
    // above it" pointed at an island that is not in the target and a page that
    // was never written. It belongs by DECISION, on the routes that actually
    // emit the island, which is where the `unmapped` footnote's own placement
    // is argued from (it stays above because it reports the emitted BYTES,
    // which a retained route really does produce).
    //
    // Both routes carry an if/unless pair, so both have a folded half; only
    // the retain answer tells them apart.
    const a_nodes = [_]fragments.Node{
        tOpen(.request_state, 1, 3, "current_user", "if current_user"),
        tText("<b>a1</b>", 1),
        tEnd(1, 40),
        tOpen(.request_state, 2, 3, "current_user", "unless current_user"),
        tText("<b>a2</b>", 2),
        tEnd(2, 40),
        // The second question on this view, and the one answered `retain`.
        tNode(.raw, 3, 3, "body"),
    };
    const b_nodes = [_]fragments.Node{
        tOpen(.request_state, 1, 3, "current_user", "if current_user"),
        tText("<b>b1</b>", 1),
        tEnd(1, 40),
        tOpen(.request_state, 2, 3, "current_user", "unless current_user"),
        tText("<b>b2</b>", 2),
        tEnd(2, 40),
    };
    const signin_nodes = passwordFormNodes();
    const frags = [_]fragments.Template{
        tTemplate("app/views/pages/a.html.erb", &a_nodes),
        tTemplate("app/views/pages/b.html.erb", &b_nodes),
        tTemplate(journey_signin_view, &signin_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/a", "pages", "a", 1, "a"),
        tNamed("GET", "/b", "pages", "b", 2, "b"),
        tNamed("POST", "/session", "sessions", "create", 5, "session"),
        tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
    };
    var vs = [_]classify.Verdict{
        tVerdict(.content), tVerdict(.content), tVerdict(.backend), tVerdict(.content),
    };
    var a_tpls = [_][]const u8{"app/views/pages/a.html.erb"};
    var b_tpls = [_][]const u8{"app/views/pages/b.html.erb"};
    var signin_tpls = [_][]const u8{journey_signin_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &a_tpls, .layout = null },
        .{ .templates = &b_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signin_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{
        "app/views/pages/a.html.erb",
        "app/views/pages/b.html.erb",
        null,
        journey_signin_view,
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "a", "b", "session", "new_session" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
    });
    defer findings.free(gpa, finding_list);

    var decided_buf: [8]decisions.Decision = undefined;
    var n: usize = 0;
    var a_raw: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) {
            decided_buf[n] = .{ .id = f.id, .choice = "island", .rationale = "auth", .artifact = "users" };
            n += 1;
        }
        if (std.mem.eql(u8, f.code, findings.code_request_time_state)) {
            decided_buf[n] = .{ .id = f.id, .choice = "island", .rationale = "client state", .artifact = null };
            n += 1;
        }
        if (std.mem.eql(u8, f.code, "RAILS_RAW_OUTPUT") and
            std.mem.eql(u8, f.path, "app/views/pages/a.html.erb")) a_raw = f.id;
    }
    // The journey plus the four status regions: a missing one would make this
    // measure a smaller app than it meant to.
    try testing.expectEqual(@as(usize, 5), n);
    // The premise: `/a` has a SECOND question, which is what `retain` answers.
    try testing.expect(a_raw.len > 0);
    decided_buf[n] = .{ .id = a_raw, .choice = "retain", .rationale = "this page stays on Rails", .artifact = null };
    n += 1;
    const decided = decided_buf[0..n];

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    var saw_a = false;
    var saw_b = false;
    for (res.routes) |o| {
        const note = o.note orelse "";
        if (std.mem.eql(u8, rs[o.route_index].path, "/a")) {
            saw_a = true;
            try testing.expectEqual(Status.retained, o.status);
            try testing.expect(std.mem.indexOf(u8, note, "folded into the AuthStatus island") == null);
        }
        if (std.mem.eql(u8, rs[o.route_index].path, "/b")) {
            saw_b = true;
            try testing.expectEqual(Status.migrated, o.status);
            try testing.expect(std.mem.indexOf(u8, note, "app/views/pages/b.html.erb:2 `unless current_user` folded into the AuthStatus island above it") != null);
        }
    }
    try testing.expect(saw_a);
    try testing.expect(saw_b);
}

test "write: a status region nested inside another one is named as such, not left silent" {
    const gpa = testing.allocator;
    // t5r4. `<% if signed_in? %><%= current_user.email %><% end %>` is the
    // ordinary way a nav shows who is signed in, and it is TWO answerable
    // regions. The outer one becomes the `AuthStatus` island, which replaces
    // `nodes[open..end]` wholesale -- so the inner region's own `island`
    // answer produces no markup, and `convert.zig` never even reaches it.
    //
    // That is the right conversion: the island renders the address itself. The
    // defect was silence. The inner region got a `StatusOrigin` and a header
    // line indistinguishable from a region the island really did stand in for,
    // and no route note at all -- so an operator reading MIGRATION.md saw two
    // answers, one component, and nothing saying why. The folded half of a
    // complementary pair already says so; this says so in its own words,
    // because there is no complementary region above it to go looking for.
    const home_nodes = [_]fragments.Node{
        tOpen(.request_state, 1, 3, "signed_in?", "if signed_in?"),
        tText("Signed in as ", 2),
        // Not a block: `current_user.email` is neither a `do`/`{` opener nor
        // one of the statement keywords `statementOpensBlock` pairs, so this
        // is one node inside the outer region's span.
        tOpen(.request_state, 2, 20, "current_user", "current_user.email"),
        tEnd(3, 3),
    };
    const signin_nodes = passwordFormNodes();
    const frags = [_]fragments.Template{
        tTemplate("app/views/pages/home.html.erb", &home_nodes),
        tTemplate(journey_signin_view, &signin_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/", "pages", "home", 1, "root"),
        tNamed("POST", "/session", "sessions", "create", 5, "session"),
        tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.backend), tVerdict(.content) };
    var home_tpls = [_][]const u8{"app/views/pages/home.html.erb"};
    var signin_tpls = [_][]const u8{journey_signin_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &home_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signin_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{ "app/views/pages/home.html.erb", null, journey_signin_view };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "root", "session", "new_session" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
    });
    defer findings.free(gpa, finding_list);

    var decided_buf: [4]decisions.Decision = undefined;
    var n: usize = 0;
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) {
            decided_buf[n] = .{ .id = f.id, .choice = "island", .rationale = "auth", .artifact = "users" };
            n += 1;
        }
        if (std.mem.eql(u8, f.code, findings.code_request_time_state)) {
            decided_buf[n] = .{ .id = f.id, .choice = "island", .rationale = "client state", .artifact = null };
            n += 1;
        }
    }
    // The premise: the journey plus BOTH regions are answered. One answer
    // short and this would be measuring the unanswered path instead.
    try testing.expectEqual(@as(usize, 3), n);
    const decided = decided_buf[0..n];

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |p| gpa.free(p);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    // One mount, from the outer region.
    const page = try readTarget(gpa, &tmp, "layouts/pages/home.shtml");
    defer gpa.free(page);
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, page, "<island src=\"" ++ auth_status_island_path ++ "\""),
    );

    // The header names the inner region AND says why it mounted nothing.
    const island = try readTarget(gpa, &tmp, auth_status_island_path);
    defer gpa.free(island);
    try testing.expect(std.mem.indexOf(u8, island, "//   app/views/pages/home.html.erb:1 -- if signed_in?\n") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        island,
        "//   app/views/pages/home.html.erb:2 -- current_user.email (inside the region above, which this replaces)\n",
    ) != null);

    // And the route says so too, in the note an operator actually reads.
    var saw = false;
    for (res.routes) |o| {
        if (!std.mem.eql(u8, rs[o.route_index].path, "/")) continue;
        saw = true;
        try testing.expectEqual(Status.migrated, o.status);
        const note = o.note orelse return error.NoNote;
        try testing.expect(std.mem.indexOf(u8, note, "app/views/pages/home.html.erb:2 `current_user.email` is inside the region the AuthStatus island replaced, so it mounts nothing of its own") != null);
        // Ruling S3-R7: ONCE, in those words, and not also in
        // `settleSuperseded`'s. The inner region is answered here (all three
        // `island` answers above), so with every answer applied it now
        // reaches `settleSuperseded` as a superseded one -- and that arm has
        // to stay quiet, or this row states one fact twice in two
        // vocabularies: `superseded by the island answering <id>`, naming
        // findings, and then `... mounts nothing of its own`, naming the file
        // and line the operator actually wrote. The second is the one worth
        // keeping, and it is the one that appears whether the inner region
        // was answered or not.
        try testing.expect(std.mem.indexOf(u8, note, "superseded by the island answering") == null);
    }
    try testing.expect(saw);
}

test "write: the journey's endpoints outrank the ones a paired form would derive" {
    const gpa = testing.allocator;
    // The property the pre-pass ORDER actually carries.
    //
    // `journeyEndpoints` fills `acc.endpoints` before `bindTemplate` runs, and
    // both `bindTemplate` (through `pairedRoute`) and the route-level loop in
    // `buildBindings` skip a slot that is already set. This fixture is the one
    // shape where the two can actually compete: `sessions#new` renders a form
    // four `render` hops down, past `max_journey_render_depth`, so the form is
    // NOT the journey's and keeps a `RAILS_BACKEND_ENDPOINT` the operator
    // answers -- and Rails' own `new` -> `create` convention would pair that
    // answer onto `POST /session`, the very route the journey speaks for. With
    // the journey first, the handoff says `authWithPassword`; flipped, it
    // tells the operator to POST a password-reset to the sign-in route.
    //
    // (This ordering is NOT what keeps the auth and form island names apart --
    // an earlier note claimed it was. `islandPath` always emits a
    // `components/forms/` prefix and the auth pair is flat under
    // `components/`, so those two cannot collide whichever order they run in.)
    var j = try runDeepJourney(gpa, "custom:/api/password-resets");
    defer j.deinit(gpa);

    // The premise: the deep form really was bound, so there IS a competing
    // answer to outrank. Without this the test would pass for the wrong reason.
    const page = try readTarget(gpa, &j.tmp, "layouts/sessions/new.shtml");
    defer gpa.free(page);
    try testing.expect(std.mem.indexOf(u8, page, "<island src=\"components/forms/") != null);

    const create = j.route("POST", "/session");
    const e = create.endpoint orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("authWithPassword", e.operation_id);
    try testing.expectEqualStrings("POST", e.verb);
    try testing.expectEqualStrings("/api/collections/users/auth-with-password", e.path);
}

/// A template holding two `request_state` regions whose code the caller
/// chooses, plus the journey routes that make an `AuthStatus` answerable.
///
/// The two regions are always both answered `island`; what varies is whether
/// they are a COMPLEMENTARY PAIR (one control, two branches) or two separate
/// controls that happen to ask the same kind of question.
const PairRun = struct {
    tmp: std.testing.TmpDir,
    res: Result,
    finding_list: []findings.Finding,
    routes: []const route_mod.Route,

    fn deinit(self: *PairRun, gpa: Allocator) void {
        freeResult(gpa, self.res);
        findings.free(gpa, self.finding_list);
        self.tmp.cleanup();
    }

    /// How many times the page mounts `AuthStatus`.
    fn mounts(self: *PairRun, gpa: Allocator) !usize {
        const page = try readTarget(gpa, &self.tmp, "layouts/pages/home.shtml");
        defer gpa.free(page);
        var at: usize = 0;
        var n: usize = 0;
        while (std.mem.indexOfPos(u8, page, at, "<island src=\"" ++ auth_status_island_path ++ "\"")) |k| {
            n += 1;
            at = k + 1;
        }
        return n;
    }
};

fn runStatusPair(
    gpa: Allocator,
    first_name: []const u8,
    first_code: []const u8,
    second_name: []const u8,
    second_code: []const u8,
) !PairRun {
    return runStatusRegions(gpa, &.{
        .{ first_name, first_code },
        .{ second_name, second_code },
    });
}

/// The same, for as many regions as the case needs: each becomes
/// `<% <code> %>…<% end %>` on its own line of `pages/home`, and each is
/// answered `island`.
fn runStatusRegions(gpa: Allocator, specs: []const [2][]const u8) !PairRun {
    // One frame's worth, and it outlives the `write` call below because that
    // call is in this frame.
    var node_buf: [3 * 8]fragments.Node = undefined;
    std.debug.assert(specs.len <= 8);
    for (specs, 0..) |spec, i| {
        const line: u64 = @intCast(i + 1);
        node_buf[i * 3 + 0] = tOpen(.request_state, line, 3, spec[0], spec[1]);
        node_buf[i * 3 + 1] = tText("<b>x</b>", line);
        node_buf[i * 3 + 2] = tEnd(line, 40);
    }
    const home_nodes = node_buf[0 .. specs.len * 3];
    const signin_nodes = passwordFormNodes();
    const frags = [_]fragments.Template{
        tTemplate("app/views/pages/home.html.erb", home_nodes),
        tTemplate(journey_signin_view, &signin_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/", "pages", "home", 1, "root"),
        tNamed("POST", "/session", "sessions", "create", 5, "session"),
        tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.backend), tVerdict(.content) };
    var home_tpls = [_][]const u8{"app/views/pages/home.html.erb"};
    var signin_tpls = [_][]const u8{journey_signin_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &home_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signin_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{
        "app/views/pages/home.html.erb", null, journey_signin_view,
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "root", "session", "new_session" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
    });
    errdefer findings.free(gpa, finding_list);

    var decided_buf: [1 + 8]decisions.Decision = undefined;
    var n: usize = 0;
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) {
            decided_buf[n] = .{ .id = f.id, .choice = "island", .rationale = "auth", .artifact = "users" };
            n += 1;
        }
    }
    for (finding_list) |f| {
        if (!std.mem.eql(u8, f.code, findings.code_request_time_state)) continue;
        if (!std.mem.eql(u8, f.path, "app/views/pages/home.html.erb")) continue;
        decided_buf[n] = .{ .id = f.id, .choice = "island", .rationale = "client state", .artifact = null };
        n += 1;
    }
    // The journey plus one answer per region: a missing finding would make
    // this test measure a smaller app than it meant to.
    try testing.expectEqual(specs.len + 1, n);
    const decided = decided_buf[0..n];

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |x| gpa.free(x);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);

    return .{ .tmp = tmp, .res = res, .finding_list = finding_list, .routes = &pair_routes };
}

/// `runStatusPair`'s route table, module-level so a `PairRun` outlives the
/// helper's own frame.
var pair_routes = [_]route_mod.Route{
    tNamed("GET", "/", "pages", "home", 1, "root"),
    tNamed("POST", "/session", "sessions", "create", 5, "session"),
    tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
};

test "write: an if/unless pair on one predicate is ONE AuthStatus mount" {
    const gpa = testing.allocator;
    // N-1. `AuthStatus` renders both branches itself, so the two halves of
    // `<% if current_user %>…<% end %><% unless current_user %>…<% end %>` are
    // one control. Mounting at each of them put the whole component on the
    // page twice: "Sign in" twice in one `<nav>` for a signed-out visitor,
    // their email and a Sign-out button twice for a signed-in one -- and
    // nothing said so.
    var p = try runStatusPair(gpa, "current_user", "if current_user", "current_user", "unless current_user");
    defer p.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), try p.mounts(gpa));
    try testing.expect(targetHas(&p.tmp, auth_status_island_path));
    // Both answers still settle: the absorbed region is answered, not ignored.
    for (p.res.routes) |o| {
        if (!std.mem.eql(u8, p.routes[o.route_index].path, "/")) continue;
        try testing.expectEqual(Status.migrated, o.status);
        try testing.expectEqual(@as(usize, 0), o.open_finding_ids.len);
    }
}

test "write: the negation may be written either way round" {
    const gpa = testing.allocator;
    // `<% unless X %>` and `<% if !X %>` are the same statement, and Rails
    // codebases hold both. The polarity is read off the code, not off the
    // keyword alone.
    var bang = try runStatusPair(gpa, "signed_in?", "if signed_in?", "signed_in?", "if !signed_in?");
    defer bang.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), try bang.mounts(gpa));

    var not = try runStatusPair(gpa, "current_user", "unless current_user", "current_user", "if current_user");
    defer not.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), try not.mounts(gpa));
}

test "write: two regions of the SAME polarity are two controls, and mount twice" {
    const gpa = testing.allocator;
    // The other half of the rule, and why it cannot simply be "one mount per
    // template": a nav greeting and a footer call-to-action are two separate
    // places that both show something when signed in. They are not two
    // branches of one control, and collapsing them would delete a control the
    // page has.
    var p = try runStatusPair(gpa, "current_user", "if current_user", "current_user", "if current_user");
    defer p.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), try p.mounts(gpa));
}

test "write: two regions on DIFFERENT predicates are two controls, and mount twice" {
    const gpa = testing.allocator;
    // Pairing is decided on the predicate the regions actually branch on.
    // `current_user` and `signed_in?` mean the same thing to a reader, but
    // this pass only sees the text, and guessing that two different helpers
    // are complements is how it would start deleting controls that are not
    // branches of each other.
    var p = try runStatusPair(gpa, "current_user", "if current_user", "signed_in?", "unless signed_in?");
    defer p.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), try p.mounts(gpa));
}

test "write: an if/else region was always one mount, and stays one" {
    const gpa = testing.allocator;
    // The third shape the ruling names. `<% if current_user %>…<% else %>…
    // <% end %>` reaches this file as ONE `request_state` region with a
    // `block_else` inside it -- one finding, one answer -- so it was never the
    // double-mount case. Pinned so the pair detection cannot start splitting
    // it into two.
    const home_nodes = [_]fragments.Node{
        tOpen(.request_state, 1, 3, "current_user", "if current_user"),
        tText("<b>hi</b>", 1),
        tNode(.block_else, 1, 20, null),
        tText("<a>Sign in</a>", 1),
        tEnd(1, 60),
    };
    const signin_nodes = passwordFormNodes();
    const frags = [_]fragments.Template{
        tTemplate("app/views/pages/home.html.erb", &home_nodes),
        tTemplate(journey_signin_view, &signin_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/", "pages", "home", 1, "root"),
        tNamed("POST", "/session", "sessions", "create", 5, "session"),
        tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.backend), tVerdict(.content) };
    var home_tpls = [_][]const u8{"app/views/pages/home.html.erb"};
    var signin_tpls = [_][]const u8{journey_signin_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &home_tpls, .layout = null },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signin_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{ "app/views/pages/home.html.erb", null, journey_signin_view };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "root", "session", "new_session" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
    });
    defer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    var status_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
        if (std.mem.eql(u8, f.code, findings.code_request_time_state) and
            std.mem.endsWith(u8, f.id, ".L1C3")) status_id = f.id;
    }
    try testing.expect(journey_id.len > 0);
    try testing.expect(status_id.len > 0);

    var decided = [_]decisions.Decision{
        .{ .id = journey_id, .choice = "island", .rationale = "auth", .artifact = "users" },
        .{ .id = status_id, .choice = "island", .rationale = "client state", .artifact = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |x| gpa.free(x);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const page = try readTarget(gpa, &tmp, "layouts/pages/home.shtml");
    defer gpa.free(page);
    var at: usize = 0;
    var mounts: usize = 0;
    while (std.mem.indexOfPos(u8, page, at, "<island src=\"" ++ auth_status_island_path ++ "\"")) |k| {
        mounts += 1;
        at = k + 1;
    }
    try testing.expectEqual(@as(usize, 1), mounts);
    // The `else` arm went with the region: the island renders both branches,
    // so neither the signed-in markup nor the signed-out markup is left behind.
    try testing.expect(std.mem.indexOf(u8, page, "rails:else") == null);
    try testing.expect(std.mem.indexOf(u8, page, "Sign in</a>") == null);
}

test "write: a shared AuthStatus is listed once in a route's artifacts" {
    const gpa = testing.allocator;
    // N-2. `artifacts` is a deduped, sorted set -- "the files this route
    // produced" -- and every other entry goes in through a unique-append.
    // The island loop did not, so a component mounted twice on one page was
    // listed twice, which reads as two files.
    var p = try runStatusPair(gpa, "current_user", "if current_user", "current_user", "if current_user");
    defer p.deinit(gpa);
    // Two SEPARATE controls, so two mounts of the one file -- the shape that
    // duplicated the entry.
    try testing.expectEqual(@as(usize, 2), try p.mounts(gpa));

    for (p.res.routes) |o| {
        if (!std.mem.eql(u8, p.routes[o.route_index].path, "/")) continue;
        var seen: usize = 0;
        for (o.artifacts) |a| {
            if (std.mem.eql(u8, a, auth_status_island_path)) seen += 1;
        }
        try testing.expectEqual(@as(usize, 1), seen);
    }
}

test "write: the shared AuthStatus header names every region it replaced" {
    const gpa = testing.allocator;
    // N-4. One component stands in for several ERB regions, so a header that
    // names one of them is a header that names whichever happened to be
    // converted first -- both incomplete and, worse, dependent on write order.
    // Every origin is listed, in source order.
    var j = try runJourney(gpa, .{ .status_in_home = true });
    defer j.deinit(gpa);

    const island = try readTarget(gpa, &j.tmp, auth_status_island_path);
    defer gpa.free(island);
    const home = std.mem.indexOf(u8, island, "app/views/pages/home.html.erb:2") orelse
        return error.TestUnexpectedResult;
    const nav = std.mem.indexOf(u8, island, "app/views/shared/_nav.html.erb:2") orelse
        return error.TestUnexpectedResult;
    // Source order, by path then line -- not the order the pages were written,
    // which is route order and would make these bytes depend on the route
    // table.
    try testing.expect(home < nav);
    try testing.expect(std.mem.indexOf(u8, island, "if current_user") != null);
}

test "regionBranch reads the polarity off the code, and stops at a word boundary" {
    // The pure rule behind the pair detection. Unit-tested because the
    // boundary check guards spellings a fixture cannot reach through
    // `findings.derive` -- a predicate that merely STARTS with one of the
    // three keywords -- and an unguarded `startsWith` would silently rewrite
    // what the region branches on.
    try testing.expect(regionBranch("if current_user").?.positive);
    try testing.expectEqualStrings("current_user", regionBranch("if current_user").?.predicate);
    try testing.expect(!regionBranch("unless current_user").?.positive);
    try testing.expect(!regionBranch("if !signed_in?").?.positive);
    try testing.expect(!regionBranch("if not signed_in?").?.positive);
    // Double negation is positive, both spellings.
    try testing.expect(regionBranch("unless !signed_in?").?.positive);
    try testing.expect(regionBranch("if not !signed_in?").?.positive);

    // A predicate that merely starts with a keyword keeps every letter of its
    // name: `not_signed_in?` is a helper, not a negated `_signed_in?`.
    const nots = regionBranch("if not_signed_in?").?;
    try testing.expect(nots.positive);
    try testing.expectEqualStrings("not_signed_in?", nots.predicate);
    // …and the same on the keyword itself: `iffy` is not `if`.
    try testing.expect(regionBranch("iffy current_user") == null);
    try testing.expect(regionBranch("unlesser current_user") == null);
    // Not a branch at all, so it pairs with nothing.
    try testing.expect(regionBranch("current_user") == null);
    try testing.expect(regionBranch("if") == null);
}

test "write: a third region does not pair with an already-absorbed one" {
    const gpa = testing.allocator;
    // `if X` / `unless X` / `if X` is one control plus a separate one -- a nav
    // that greets and offers a sign-in link, and a footer that greets again.
    // The first two are the pair; the third is its own control and mounts.
    // Without the already-paired check the third would pair with the SECOND,
    // which is already absorbed, and the footer's greeting would vanish.
    var p = try runStatusRegions(gpa, &.{
        .{ "current_user", "if current_user" },
        .{ "current_user", "unless current_user" },
        .{ "current_user", "if current_user" },
    });
    defer p.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), try p.mounts(gpa));
}

test "write: the AuthStatus header is in source order, not fragment-stream order" {
    const gpa = testing.allocator;
    // N-4's determinism half. The fragment stream's order is the sidecar's,
    // and these bytes reach a committed file: two runs that discovered the
    // same templates in a different order must produce the same component.
    // The fixture puts `shared/_nav` BEFORE `pages/home` in the stream, where
    // source order (path, then line) puts `pages/` first -- so an unsorted
    // list and a sorted one disagree here and nowhere else.
    const nav_nodes = [_]fragments.Node{
        tOpen(.request_state, 1, 3, "current_user", "if current_user"),
        tText("<b>nav</b>", 1),
        tEnd(1, 40),
    };
    const home_nodes = [_]fragments.Node{
        tOpen(.request_state, 1, 3, "current_user", "if current_user"),
        tText("<b>home</b>", 1),
        tEnd(1, 40),
    };
    const layout_nodes = [_]fragments.Node{
        tText("<html><body>", 1),
        tNode(.render_partial, 2, 3, "shared/nav"),
        tNode(.yield, 3, 3, null),
        tText("</body></html>", 4),
    };
    const signin_nodes = passwordFormNodes();
    const frags = [_]fragments.Template{
        tTemplate(journey_layout, &layout_nodes),
        // Stream order: the nav first…
        tTemplate(journey_nav, &nav_nodes),
        // …and the view that sorts before it second.
        tTemplate("app/views/pages/home.html.erb", &home_nodes),
        tTemplate(journey_signin_view, &signin_nodes),
    };
    var rs = [_]route_mod.Route{
        tNamed("GET", "/", "pages", "home", 1, "root"),
        tNamed("POST", "/session", "sessions", "create", 5, "session"),
        tNamed("GET", "/session/new", "sessions", "new", 5, "new_session"),
    };
    var vs = [_]classify.Verdict{ tVerdict(.content), tVerdict(.backend), tVerdict(.content) };
    var home_tpls = [_][]const u8{"app/views/pages/home.html.erb"};
    var signin_tpls = [_][]const u8{journey_signin_view};
    var rts = [_]rails.RouteTemplates{
        .{ .templates = &home_tpls, .layout = journey_layout },
        .{ .templates = &.{}, .layout = null },
        .{ .templates = &signin_tpls, .layout = null },
    };
    const route_views = [_]?[]const u8{ "app/views/pages/home.html.erb", null, journey_signin_view };
    const render_graph = [_]findings.TemplateRenders{
        .{ .path = journey_layout, .renders = &[_][]const u8{journey_nav} },
    };

    const finding_list = try findings.derive(gpa, .{
        .templates = &frags,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &[_][]const u8{ "root", "session", "new_session" },
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &route_views,
        .render_graph = &render_graph,
    });
    defer findings.free(gpa, finding_list);

    var journey_id: []const u8 = "";
    var nav_id: []const u8 = "";
    var home_id: []const u8 = "";
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.code, findings.code_auth_journey)) journey_id = f.id;
        if (!std.mem.eql(u8, f.code, findings.code_request_time_state)) continue;
        if (std.mem.eql(u8, f.path, journey_nav)) nav_id = f.id;
        if (std.mem.eql(u8, f.path, "app/views/pages/home.html.erb")) home_id = f.id;
    }
    try testing.expect(journey_id.len > 0);
    try testing.expect(nav_id.len > 0);
    try testing.expect(home_id.len > 0);

    var decided = [_]decisions.Decision{
        .{ .id = journey_id, .choice = "island", .rationale = "auth", .artifact = "users" },
        .{ .id = nav_id, .choice = "island", .rationale = "client state", .artifact = null },
        .{ .id = home_id, .choice = "island", .rationale = "client state", .artifact = null },
    };

    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &vs;
    d.route_templates = &rts;
    d.fragments = @constCast(&frags);
    d.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var err_path: ?[]const u8 = null;
    defer if (err_path) |x| gpa.free(x);
    var err_cause: ?anyerror = null;
    const res = try write(std.testing.io, gpa, .{
        .discovery = &d,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Blog",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &err_path, &err_cause);
    defer freeResult(gpa, res);

    const island = try readTarget(gpa, &tmp, auth_status_island_path);
    defer gpa.free(island);
    const home = std.mem.indexOf(u8, island, "app/views/pages/home.html.erb:1").?;
    const nav = std.mem.indexOf(u8, island, "app/views/shared/_nav.html.erb:1").?;
    try testing.expect(home < nav);
}

test "Stage 4 shared interactivity emitters have their runtime contracts" {
    const gpa = testing.allocator;
    const frame = try emitFrameIsland(gpa);
    defer gpa.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "fetch(props.src") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "dangerouslySetInnerHTML") != null);
    try testing.expect(std.mem.indexOf(u8, stimulus_runtime, "root.querySelectorAll<HTMLElement>(\"[data-action]\")") != null);
    try testing.expect(std.mem.indexOf(u8, stimulus_runtime, "split(/\\s+/)") != null);
    try testing.expect(std.mem.indexOf(u8, stimulus_runtime, "new RegExp(`^(?:(\\\\w[\\\\w:.-]*)->)?${id}#(\\\\w+)((?::\\\\w+)*)$`)") != null);
}

test "write: a Stimulus-only island emits its shared runtime without ZigBase" {
    const gpa = testing.allocator;
    const nodes = [_]fragments.Node{
        tOpen(.stimulus, 1, 1, "reveal", "<div data-controller=\"reveal\">"),
        tText("<button data-action=\"click->reveal#toggle:prevent\">Show</button>", 2),
        tEnd(3, 1),
    };
    const templates = [_]fragments.Template{tTemplate("app/views/pages/widgets.html.erb", &nodes)};
    var routes = [_]route_mod.Route{tRoute("GET", "/widgets", "pages", "widgets", 1)};
    var verdicts = [_]classify.Verdict{tVerdict(.content)};
    var template_paths = [_][]const u8{"app/views/pages/widgets.html.erb"};
    var route_templates = [_]rails.RouteTemplates{.{ .templates = &template_paths, .layout = null }};
    const route_views = [_]?[]const u8{"app/views/pages/widgets.html.erb"};
    const route_names = [_][]const u8{"widgets"};
    const sources = [_]port.JsSource{.{
        .path = "app/javascript/controllers/reveal_controller.js",
        .bytes = "export default class extends Controller { static targets = [\"details\"]; toggle() { this.detailsTarget.hidden = false } }",
    }};
    const finding_list = try findings.derive(gpa, .{
        .templates = &templates,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &route_names,
        .locale = null,
        .routes = &routes,
        .classifications = &verdicts,
        .route_views = &route_views,
        .js_sources = &sources,
    });
    defer findings.free(gpa, finding_list);
    var stimulus_id: []const u8 = "";
    for (finding_list) |finding| {
        if (std.mem.eql(u8, finding.code, findings.code_stimulus_controller)) stimulus_id = finding.id;
    }
    try testing.expect(stimulus_id.len > 0);
    var decided = [_]decisions.Decision{.{ .id = stimulus_id, .choice = "island", .rationale = "port structure", .artifact = null }};
    var discovery = emptyDiscovery();
    discovery.routes = &routes;
    discovery.classifications = &verdicts;
    discovery.route_templates = &route_templates;
    discovery.fragments = @constCast(&templates);
    discovery.findings = finding_list;
    discovery.js_sources = @constCast(&sources);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var error_path: ?[]const u8 = null;
    defer if (error_path) |path| gpa.free(path);
    var error_cause: ?anyerror = null;
    const result = try write(std.testing.io, gpa, .{
        .discovery = &discovery,
        .decisions = .{ .decisions = &decided, .stale = &.{} },
        .source_root = tmp.dir,
        .target = target,
        .app_name = "Widgets",
        .runtime_path = "../runtime",
        .agents_md = "",
        .claude_md = "",
    }, &error_path, &error_cause);
    defer freeResult(gpa, result);

    try testing.expect(targetHas(&tmp, "components/stimulus/reveal.island.tsx"));
    try testing.expect(targetHas(&tmp, "lib/stimulus.ts"));
    try testing.expect(!targetHas(&tmp, client_lib_path));
    const package = try readTarget(gpa, &tmp, "package.json");
    defer gpa.free(package);
    try testing.expect(std.mem.indexOf(u8, package, "@zigbase/client") == null);

    var fail_index: usize = 0;
    while (fail_index < 500) : (fail_index += 1) {
        var failing_tmp = std.testing.tmpDir(.{});
        defer failing_tmp.cleanup();
        const failing_target = try tmpTarget(gpa, &failing_tmp);
        defer gpa.free(failing_target);
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var failing_path: ?[]const u8 = null;
        defer if (failing_path) |path| fa.free(path);
        var failing_cause: ?anyerror = null;
        if (write(std.testing.io, fa, .{
            .discovery = &discovery,
            .decisions = .{ .decisions = &decided, .stale = &.{} },
            .source_root = failing_tmp.dir,
            .target = failing_target,
            .app_name = "Widgets",
            .runtime_path = "../runtime",
            .agents_md = "",
            .claude_md = "",
        }, &failing_path, &failing_cause)) |swept| {
            freeResult(fa, swept);
            break;
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
    }
    try testing.expect(fail_index < 500);
}

test "Stage 4 interactivity paths and React project metadata are deterministic" {
    const gpa = testing.allocator;
    var acc: BindingAcc = .{ .endpoints = &.{} };
    defer acc.deinit(gpa);
    const first = try acc.stimulusPath(gpa, "a-b");
    const second = try acc.stimulusPath(gpa, "a--b");
    try testing.expectEqualStrings("components/stimulus/a_b.island.tsx", first);
    try testing.expectEqualStrings("components/stimulus/a_b_2.island.tsx", second);
    try testing.expectEqualStrings(first, try acc.stimulusPath(gpa, "a-b"));
    const chart = try acc.componentPath(gpa, "Chart");
    try testing.expectEqualStrings("components/Chart.island.tsx", chart);
    try testing.expectEqualStrings(chart, try acc.componentPath(gpa, "Chart"));
    try testing.expectEqualStrings("components/AuthForm_2.island.tsx", try acc.componentPath(gpa, "AuthForm"));

    const config = try emitReactBridgeConfig(gpa, &.{ "d3", "zod" });
    defer gpa.free(config);
    try testing.expectEqualStrings("{\"islandImports\":{\"firstParty\":[],\"npmCompat\":[\"d3\",\"zod\"]},\"resolve\":{\"react\":\"@z/runtime/compat\",\"react-dom\":\"@z/runtime/compat\",\"react-dom/client\":\"@z/runtime/compat/client\",\"react/jsx-runtime\":\"@z/runtime/jsx-runtime\",\"react/jsx-dev-runtime\":\"@z/runtime/jsx-dev-runtime\"}}\n", config);
    const deps = [_]@import("integrations.zig").NpmDep{.{ .name = "d3", .version = "7.9.0" }};
    const package = try emitPackageCompat(gpa, "Charts", "../runtime", false, &.{"d3"}, &deps);
    defer gpa.free(package);
    try testing.expect(std.mem.indexOf(u8, package, "\"d3\": \"7.9.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, target_tsconfig, "\"jsxImportSource\": \"@z/runtime\"") != null);
    try testing.expect(std.mem.indexOf(u8, target_tsconfig, "\"module\": \"ESNext\"") != null);
    try testing.expect(std.mem.indexOf(u8, target_tsconfig, "\"target\": \"ESNext\"") != null);
    try testing.expect(std.mem.indexOf(u8, target_tsconfig, "\"allowJs\": true") != null);
    try testing.expect(std.mem.indexOf(u8, target_tsconfig, "\"allowImportingTsExtensions\": true") != null);
    try testing.expect(std.mem.indexOf(u8, target_tsconfig, "\"noEmit\": true") != null);
}

test "emitStimulusIsland: every allocation failure is clean" {
    const gpa = testing.allocator;
    const methods = [_]port.Method{.{ .name = "toggle", .source = "toggle() { this.openValue = !this.openValue }" }};
    const controller: port.Controller = .{
        .identifier = "reveal",
        .path = "app/javascript/controllers/reveal_controller.js",
        .targets = &.{"details"},
        .values = &.{.{ .name = "open", .kind = .boolean }},
        .classes = &.{},
        .methods = &methods,
        .lifecycle = &.{"connect"},
        .unsupported = null,
    };
    const mounts = [_]StatusOrigin{.{ .path = "app/views/pages/widgets.html.erb", .line = 2, .col = 1, .code = "", .finding_id = "f", .absorbed = false }};
    var fail_index: usize = 0;
    while (fail_index < 100) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        if (emitStimulusIsland(fa, controller, &.{}, &mounts)) |bytes| {
            fa.free(bytes);
            break;
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
    try testing.expect(fail_index < 100);
}

test "emitDataIsland carries the ported record body and collection contract" {
    const gpa = testing.allocator;
    const binding: convert.Binding = .{ .finding_id = "f", .kind = .data_list, .verb = "GET", .path = "", .operation_id = "list", .collection = "posts", .island = "components/data/posts_index.island.tsx", .redirect_to = null };
    const spec: convert.IslandSpec = .{ .island = binding.island, .fields = &.{}, .errors_model = null, .submit_label = "Save", .click = null, .binding = binding, .original = "@posts.each do |post|", .line = 1, .source = "app/views/posts/index.html.erb", .port = @constCast("h += \"<h2>\" + esc(String(rec.title ?? \"\")) + \"</h2>\";\n") };
    const bytes = try emitDataIsland(gpa, spec);
    defer gpa.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "zb.collection(\"posts\").getList(1, 50)") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "  h += \"<h2>\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "dangerouslySetInnerHTML") != null);
}

test "data island paths number a second region and emitter OOM paths are clean" {
    const gpa = testing.allocator;
    const first = try dataIslandPath(gpa, &.{}, "app/views/posts/index.html.erb");
    defer gpa.free(first);
    const binding: convert.Binding = .{ .finding_id = "a", .kind = .data_list, .verb = "GET", .path = "", .operation_id = "list", .collection = "posts", .island = first, .redirect_to = null };
    const second = try dataIslandPath(gpa, &.{binding}, "app/views/posts/index.html.erb");
    defer gpa.free(second);
    try testing.expectEqualStrings("components/data/posts_index_2.island.tsx", second);

    const spec: convert.IslandSpec = .{ .island = binding.island, .fields = &.{}, .errors_model = null, .submit_label = "Save", .click = null, .binding = binding, .original = "@posts.each do |post|", .line = 1, .source = "app/views/posts/index.html.erb", .port = @constCast("h += esc(String(rec.title ?? \"\"));\n") };
    var fail_index: usize = 0;
    while (fail_index < 100) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        if (emitDataIsland(fa, spec)) |bytes| {
            fa.free(bytes);
            break;
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
    try testing.expect(fail_index < 100);
}

test "write: island and backend choices emit the same document-backed data island" {
    const gpa = testing.allocator;
    const document = try backend_mod.parse(gpa,
        \\{"openapi":"3.1.0","info":{"version":"1"},"paths":{"/api/collections/notes/records":{"get":{"operationId":"listNotes"}},"/api/collections/posts/records":{"get":{"operationId":"listPosts"}},"/api/collections/posts/records/{id}":{"get":{"operationId":"viewPosts"}}}}
    , "openapi.json");
    defer backend_mod.free(gpa, document);
    var local = tNode(.local, 2, 3, "post");
    local.code = "post.title";
    const nodes = [_]fragments.Node{
        tOpen(.ivar, 1, 1, "@posts", "@posts.each do |post|"),
        tText("<h2>", 2),
        local,
        tText("</h2>", 2),
        tEnd(3, 1),
    };
    const templates = [_]fragments.Template{tTemplate("app/views/posts/index.html.erb", &nodes)};
    var routes = [_]route_mod.Route{tNamed("GET", "/posts", "posts", "index", 1, "posts")};
    var verdicts = [_]classify.Verdict{tVerdict(.content)};
    var paths = [_][]const u8{"app/views/posts/index.html.erb"};
    var route_templates = [_]rails.RouteTemplates{.{ .templates = &paths, .layout = null }};
    const route_views = [_]?[]const u8{"app/views/posts/index.html.erb"};
    const finding_list = try findings.derive(gpa, .{ .templates = &templates, .layouts = &.{}, .controller_files = &.{}, .route_names = &[_][]const u8{"posts"}, .locale = null, .routes = &routes, .classifications = &verdicts, .route_views = &route_views, .backend = document });
    defer findings.free(gpa, finding_list);
    var data_id: []const u8 = "";
    for (finding_list) |finding| if (std.mem.eql(u8, finding.code, findings.code_request_time_state)) {
        data_id = finding.id;
        break;
    };
    try testing.expect(data_id.len > 0);
    var discovery = emptyDiscovery();
    discovery.routes = &routes;
    discovery.classifications = &verdicts;
    discovery.route_templates = &route_templates;
    discovery.fragments = @constCast(&templates);
    discovery.findings = finding_list;
    var first_bytes: ?[]u8 = null;
    defer if (first_bytes) |bytes| gpa.free(bytes);
    const cases = [_]struct { choice: []const u8, artifact: ?[]const u8, collection: []const u8 }{
        .{ .choice = "island", .artifact = null, .collection = "posts" },
        .{ .choice = "backend", .artifact = null, .collection = "posts" },
        .{ .choice = "island", .artifact = "notes", .collection = "notes" },
    };
    for (cases, 0..) |case, run_index| {
        var decided = [_]decisions.Decision{.{ .id = data_id, .choice = case.choice, .rationale = "load records", .artifact = case.artifact }};
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var error_path: ?[]const u8 = null;
        defer if (error_path) |path| gpa.free(path);
        var error_cause: ?anyerror = null;
        const result = try write(std.testing.io, gpa, .{ .discovery = &discovery, .decisions = .{ .decisions = &decided, .stale = &.{} }, .source_root = tmp.dir, .target = target, .app_name = "Posts", .runtime_path = "../runtime", .backend = document, .agents_md = "", .claude_md = "" }, &error_path, &error_cause);
        defer freeResult(gpa, result);
        try testing.expectEqual(Status.migrated, result.routes[0].status);
        try testing.expect(result.routes[0].endpoint == null);
        const bytes = try readTarget(gpa, &tmp, "components/data/posts_index.island.tsx");
        const collection_call = try std.fmt.allocPrint(gpa, "zb.collection(\"{s}\").getList", .{case.collection});
        defer gpa.free(collection_call);
        try testing.expect(std.mem.indexOf(u8, bytes, collection_call) != null);
        if (run_index == 0) {
            first_bytes = bytes;
        } else if (run_index == 1) {
            defer gpa.free(bytes);
            try testing.expectEqualStrings(first_bytes.?, bytes);
        } else {
            defer gpa.free(bytes);
        }
        try testing.expect(targetHas(&tmp, client_lib_path));
    }
    var swept_decision = [_]decisions.Decision{.{ .id = data_id, .choice = "backend", .rationale = "load records", .artifact = null }};
    var fail_index: usize = 0;
    while (fail_index < 500) : (fail_index += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmpTarget(gpa, &tmp);
        defer gpa.free(target);
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var error_path: ?[]const u8 = null;
        defer if (error_path) |path| fa.free(path);
        var error_cause: ?anyerror = null;
        if (write(std.testing.io, fa, .{ .discovery = &discovery, .decisions = .{ .decisions = &swept_decision, .stale = &.{} }, .source_root = tmp.dir, .target = target, .app_name = "Posts", .runtime_path = "../runtime", .backend = document, .agents_md = "", .claude_md = "" }, &error_path, &error_cause)) |result| {
            freeResult(fa, result);
            break;
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
    }
    try testing.expect(fail_index < 500);
}

test "write: island-realtime replaces a portable Turbo Stream with a subscribed island" {
    const gpa = testing.allocator;
    var stream = tNode(.turbo_stream, 1, 5, "posts");
    stream.output = true;
    stream.code = "turbo_stream_from \"posts\"";
    stream.value = "subscribe";
    const nodes = [_]fragments.Node{stream};
    const templates = [_]fragments.Template{tTemplate("app/views/pages/live.html.erb", &nodes)};
    var routes = [_]route_mod.Route{tNamed("GET", "/live", "pages", "live", 1, "live")};
    var verdicts = [_]classify.Verdict{tVerdict(.content)};
    var paths = [_][]const u8{"app/views/pages/live.html.erb"};
    var route_templates = [_]rails.RouteTemplates{.{ .templates = &paths, .layout = null }};
    const route_views = [_]?[]const u8{"app/views/pages/live.html.erb"};
    const finding_list = try findings.derive(gpa, .{ .templates = &templates, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null, .routes = &routes, .classifications = &verdicts, .route_views = &route_views });
    defer findings.free(gpa, finding_list);
    try testing.expectEqual(@as(usize, 1), finding_list.len);
    var decided = [_]decisions.Decision{.{ .id = finding_list[0].id, .choice = "island-realtime", .rationale = "port the literal stream", .artifact = null }};
    var discovery = emptyDiscovery();
    discovery.routes = &routes;
    discovery.classifications = &verdicts;
    discovery.route_templates = &route_templates;
    discovery.fragments = @constCast(&templates);
    discovery.findings = finding_list;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var error_path: ?[]const u8 = null;
    defer if (error_path) |path| gpa.free(path);
    var error_cause: ?anyerror = null;
    const result = try write(std.testing.io, gpa, .{ .discovery = &discovery, .decisions = .{ .decisions = &decided, .stale = &.{} }, .source_root = tmp.dir, .target = target, .app_name = "Live", .runtime_path = "../runtime", .agents_md = "", .claude_md = "" }, &error_path, &error_cause);
    defer freeResult(gpa, result);

    try testing.expectEqual(Status.migrated, result.routes[0].status);
    const island = try readTarget(gpa, &tmp, "components/TurboStream.island.tsx");
    defer gpa.free(island);
    try testing.expect(std.mem.indexOf(u8, island, "zb.realtime.subscribe(props.stream") != null);
    try testing.expect(std.mem.indexOf(u8, island, "zigapagos:turbo-stream") != null);
    const client = try readTarget(gpa, &tmp, client_lib_path);
    defer gpa.free(client);
    try testing.expectEqualStrings(
        \\import { createClient, LocalAuthStore } from "@zigbase/client";
        \\import { withRealtime } from "@zigbase/client/realtime";
        \\export const zb = withRealtime(createClient("", { authStore: new LocalAuthStore(), fetch: (input, init) => globalThis.fetch(input, init) }));
        \\
    , client);
}

test "realtime props keep topic and target distinct and clean every allocation failure" {
    const gpa = testing.allocator;
    const props = try realtimeProps(gpa, "posts", "append", "post_list");
    defer gpa.free(props);
    try testing.expectEqualStrings("{ .stream = \"posts\", .action = \"append\", .target = \"post_list\" }", props);

    var fail_index: usize = 0;
    while (fail_index < 20) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        if (realtimeProps(fa, "posts", "append", "post_list")) |bytes| {
            fa.free(bytes);
            break;
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
    try testing.expect(fail_index < 20);
}

test "write: a dynamic route ports its record view into the SPA and carries layout styles" {
    const gpa = testing.allocator;
    const document = try backend_mod.parse(gpa,
        \\{"openapi":"3.1.0","info":{"version":"1"},"paths":{"/api/collections/posts/records":{"get":{"operationId":"listPosts"}},"/api/collections/posts/records/{id}":{"get":{"operationId":"viewPosts"}}}}
    , "openapi.json");
    defer backend_mod.free(gpa, document);
    var ivar = tNode(.ivar, 1, 5, "@post");
    ivar.output = true;
    ivar.code = "@post.title";
    const view_nodes = [_]fragments.Node{ tText("<h2>", 1), ivar, tText("</h2>", 1) };
    const edit_nodes = [_]fragments.Node{tText("<h2>Edit</h2>", 1)};
    var stylesheet = tNode(.asset, 1, 1, "stylesheet_link_tag");
    stylesheet.args = &.{"application"};
    const layout_nodes = [_]fragments.Node{ stylesheet, tNode(.yield, 2, 1, null) };
    const templates = [_]fragments.Template{
        tTemplate("app/views/layouts/application.html.erb", &layout_nodes),
        tTemplate("app/views/posts/show.html.erb", &view_nodes),
        tTemplate("app/views/posts/edit.html.erb", &edit_nodes),
    };
    var routes = [_]route_mod.Route{
        tNamed("GET", "/posts/:id", "posts", "show", 1, "post"),
        tNamed("GET", "/posts/:id/edit", "posts", "edit", 2, "edit_post"),
    };
    var verdicts = [_]classify.Verdict{ tVerdict(.content), tVerdict(.content) };
    var show_paths = [_][]const u8{"app/views/posts/show.html.erb"};
    var edit_paths = [_][]const u8{"app/views/posts/edit.html.erb"};
    var route_templates = [_]rails.RouteTemplates{
        .{ .templates = &show_paths, .layout = "app/views/layouts/application.html.erb" },
        .{ .templates = &edit_paths, .layout = "app/views/layouts/application.html.erb" },
    };
    const route_views = [_]?[]const u8{ "app/views/posts/show.html.erb", "app/views/posts/edit.html.erb" };
    var assets = [_]asset_mod.Asset{.{ .source = "app/assets/stylesheets/application.css", .public_url = "/stylesheets/application.css", .pipeline = .sprockets, .deterministic = true }};
    const finding_list = try findings.derive(gpa, .{ .templates = &templates, .layouts = &.{}, .controller_files = &.{}, .route_names = &[_][]const u8{ "post", "edit_post" }, .locale = null, .routes = &routes, .classifications = &verdicts, .route_views = &route_views, .assets = &assets, .backend = document });
    defer findings.free(gpa, finding_list);
    var show_dynamic_id: []const u8 = "";
    var edit_dynamic_id: []const u8 = "";
    var data_id: []const u8 = "";
    for (finding_list) |finding| {
        if (std.mem.eql(u8, finding.code, findings.code_route_dynamic_segment)) {
            if (finding.line == 1) show_dynamic_id = finding.id;
            if (finding.line == 2) edit_dynamic_id = finding.id;
        }
        if (std.mem.eql(u8, finding.code, findings.code_request_time_state)) data_id = finding.id;
    }
    try testing.expect(show_dynamic_id.len > 0 and edit_dynamic_id.len > 0 and data_id.len > 0);
    var decided = [_]decisions.Decision{
        .{ .id = show_dynamic_id, .choice = "spa", .rationale = "client route", .artifact = null },
        .{ .id = edit_dynamic_id, .choice = "spa", .rationale = "client route", .artifact = null },
        .{ .id = data_id, .choice = "backend", .rationale = "load record", .artifact = null },
    };
    var discovery = emptyDiscovery();
    discovery.routes = &routes;
    discovery.classifications = &verdicts;
    discovery.route_templates = &route_templates;
    discovery.fragments = @constCast(&templates);
    discovery.findings = finding_list;
    discovery.assets = &assets;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var styles_dir = try tmp.dir.createDirPathOpen(std.testing.io, "app/assets/stylesheets", .{});
    styles_dir.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/assets/stylesheets/application.css", .data = "body{}\n" });
    const target = try tmpTarget(gpa, &tmp);
    defer gpa.free(target);
    var error_path: ?[]const u8 = null;
    defer if (error_path) |path| gpa.free(path);
    var error_cause: ?anyerror = null;
    const result = try write(std.testing.io, gpa, .{ .discovery = &discovery, .decisions = .{ .decisions = &decided, .stale = &.{} }, .source_root = tmp.dir, .target = target, .app_name = "Posts", .runtime_path = "../runtime", .backend = document, .agents_md = "", .claude_md = "" }, &error_path, &error_cause);
    defer freeResult(gpa, result);
    for (result.routes) |outcome| {
        try testing.expectEqual(Status.migrated, outcome.status);
        try testing.expectEqual(@as(usize, 0), outcome.open_finding_ids.len);
    }
    const spa = try readTarget(gpa, &tmp, "spa/posts.spa.tsx");
    defer gpa.free(spa);
    try testing.expect(std.mem.indexOf(u8, spa, "head: [{ rel: \"stylesheet\", href: \"/stylesheets/application.css\" }]") != null);
    try testing.expect(std.mem.indexOf(u8, spa, "zb.collection(\"posts\").getOne(params.id)") != null);
    try testing.expect(std.mem.indexOf(u8, spa, "h += esc(String(rec.title ?? \"\"));") != null);
    try testing.expect(std.mem.indexOf(u8, spa, "TODO: port GET /posts/:id/edit (posts#edit)") != null);
    try testing.expect(targetHas(&tmp, client_lib_path));
}
