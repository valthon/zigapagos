//! The Zig client for the Rails controller-shape sidecar op
//! (`runtime/sidecar/rails/analyze.rb`'s `"controllers"` op, backed by Task
//! 1's `runtime/sidecar/rails/controllers.rb`): locates Ruby and the
//! sidecar script, spawns a persistent-protocol process for exactly one
//! request/response pair, and folds the result into the discovery pass's
//! blocker list. Mirrors `routes.zig`'s shape closely -- same spawn helper
//! idiom, same `Environ.Map` parameter, same absolute-`root` contract, same
//! bounded wait -- because this file exists to answer the same kind of
//! question (what did the static AST find) over the same kind of transport.
//!
//! **Separate sidecar process, not a shared one.** The brief's efficiency
//! note asks for the `controllers` request to ride the SAME process
//! `discoverRoutes` already spawned for `routes`, saving one Ruby
//! interpreter start (~100ms). That is not done here: `discoverRoutes`
//! fully owns its child (spawn, one query, kill/wait) as a private,
//! self-contained sequence and never exposes the live `child` past its own
//! return -- there is no seam to hang a second request off of without
//! either changing its public signature (spawn separately of routes, hand
//! back a `*Child` for a caller to drive) or touching how it feeds/closes
//! stdin (`queryOnce` closes `child.stdin` immediately after writing the
//! one request, which is what lets analyze.rb's loop treat that close as
//! ordinary shutdown -- delaying it to allow a second request changes that
//! path). The ruling for this task is explicit that touching either of
//! those is out of bounds for this task, and that spawning a second sidecar
//! is a sanctioned outcome when sharing would require it. This file spawns
//! its own process instead of threading a live `child` through a modified
//! `discoverRoutes`.
//!
//! Every way this can fail -- no Ruby, no sidecar script, a spawn/exit/
//! response failure, or no `app/controllers/` -- degrades to a blocker
//! rather than a fatal, for the same reason `routes.zig`'s module doc gives:
//! a Rails app with no recovered action shape is still a useful inventory.
//! Unlike `routes.zig`'s four-way split, this file's degradation table (see
//! the brief) collapses every sidecar-side failure -- no Ruby, no script, a
//! spawn/exit/response failure, a malformed or `ok:false` response -- into
//! ONE code, `RAILS_CONTROLLERS_UNAVAILABLE`; only "the directory itself is
//! absent" gets its own code, `RAILS_CONTROLLERS_MISSING`, because that is
//! the one case where "the sidecar is fine but there is nothing to look at"
//! is a meaningfully different story from "the sidecar could not be asked".
//!
//! Both codes carry `integrity = false`: see `routes.zig`'s module doc for
//! why -- `discoverControllers` finding nothing changes only whether the
//! LATER classification rules that depend on action shape can fire (Stage
//! 3's rules 2/3), never whether `inventory.walk`'s presentation-layer
//! findings are trustworthy.
//!
//! `RAILS_CONTROLLERS_MISSING`/`RAILS_CONTROLLERS_UNAVAILABLE` are
//! `severity = .@"error"` (Stage 4 Task 1), same reasoning as `routes.zig`'s
//! four wholesale codes: nothing here ran, so every route this run would
//! otherwise resolve a controller action for is missing that evidence
//! entirely. Contrast the per-file `unresolved[].code` family below
//! (`RAILS_CONTROLLER_PARSE_ERROR`, `RAILS_CONTROLLER_UNREADABLE`, and the
//! `RAILS_CONTROLLER_UNRESOLVED` fallback), which name ONE controller file
//! the walk correctly identified as unreadable/unparseable while the rest of
//! the recovered action set came back intact -- those are `severity = .warn`.
//!
//! std-only, like every file in `src/cli/rails/`: no `@import` escapes this
//! directory, and `fatal.*` handling stays migrate.zig's job. The spawn/
//! resolve/watchdog/query plumbing (`resolveAbsRoot`, `killOnTimeout`,
//! `queryOnce`) lives in the sibling `sidecar_client.zig` and is imported
//! from there, NOT duplicated -- fix round 1 (task-2-fixes.md item 1)
//! extracted it after review found the two copies byte-identical apart from
//! `queryOnce`'s wire op string, which is now a parameter. That extraction
//! is a pure relocation of three already-private, self-contained helpers:
//! it changes neither `discoverRoutes`'s public signature nor its watchdog/
//! stdin-close semantics, so the ruling above (no touching `routes.zig` to
//! force PROCESS SHARING) still stands -- this file still spawns its OWN
//! sidecar process, it just no longer carries a second hand-copied
//! implementation of how to talk to one.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const blockers = @import("blockers.zig");
const sidecar_client = @import("sidecar_client.zig");

// Every field defaults so a classifier test can write `.action = .{
// .renders_json = true }` and name only the field its case is about,
// instead of restating three irrelevant ones. Every PRODUCTION construction
// site (`dupeAction` below) still sets all four fields explicitly -- the
// defaults exist for tests only. The empty-string default is also the safe
// direction: an `ActionInfo` that ever ended up with an empty `controller`
// simply never matches in `find()` below, so the route falls through to
// `unresolved` rather than being silently misclassified.
pub const ActionInfo = struct {
    controller: []const u8 = "",
    action: []const u8 = "",
    only_redirect: bool = false,
    renders_json: bool = false,
    /// #167 Stage 3: one entry per `redirect_to` ANYWHERE in the action
    /// body, in source order -- not just the single-statement case
    /// `only_redirect` above answers. Contract 2 (owned-result): each
    /// `name`/`args[]` string is a fresh `gpa` allocation; `freeActions` is
    /// the release. Empty for an action with no redirect at all, and also
    /// for a response from a sidecar that predates the field.
    redirects: []const RedirectInfo = &.{},
};

/// One `redirect_to` target recovered from a controller action (#167 Stage
/// 3). Stage 2 recorded only THAT an action was a pure redirect
/// (`ActionInfo.only_redirect`), which is why the handoff's `redirects[].to`
/// was always null and a converted form island had nowhere to send the
/// browser after a successful mutation.
///
/// `name` is the route-helper STEM -- `root` for `root_path`, `post` for
/// `post_url` -- because that is what `resolve.routeUrl` resolves against
/// the route table this run recovered from `config/routes.rb`.
///
/// `path` is the second resolvable variant (fix round 1, I-3): a literal
/// string target (`redirect_to "/about"`), usable verbatim. It is kept apart
/// from `name` because it resolves through nothing -- there is no helper to
/// look up -- and apart from `dynamic` because throwing away a target the
/// sidecar could read would be a straight loss. The string is EXACTLY as
/// written and may be an absolute URL; it is neither normalised nor checked
/// against the route table.
///
/// `dynamic` is the sidecar's honest "I could not reduce this to a target at
/// all": `redirect_to @post`, a local variable, a non-literal helper
/// argument (`post_path(@post)`), an interpolated string, and
/// `redirect_back`/`redirect_back_or_to`/`redirect_to :back`, whose
/// destination is a request-time `Referer`. A `dynamic` entry carries no
/// `name`, `path` or `args`; a consumer must leave the redirect unresolved
/// rather than invent a target.
///
/// Exactly one of the three is meaningful per entry, but they are three
/// independent fields rather than a tagged union for the same reason
/// `LayoutInfo`'s are: the wire shape is not one either.
///
/// Contract 2 (owned-result), same as `ActionInfo`: `name`, `path` and every
/// element of `args` are fresh `gpa` allocations independent of the decoded
/// response's JSON arena.
pub const RedirectInfo = struct {
    name: ?[]const u8 = null,
    /// The helper's positional arguments, as the literal text a URL needs
    /// (`post_path(1)` -> `.{"1"}`). Empty for a helper called with none.
    args: []const []const u8 = &.{},
    path: ?[]const u8 = null,
    dynamic: bool = false,
};

/// One class-level `before_action` declaration (#167 Stage 3, assumption
/// A7). A static page cannot enforce a Rails filter, so a page route whose
/// controller runs an auth-looking one has to raise a question rather than
/// ship silently public -- `guards` and `looksLikeAuthGuard` below are the
/// two predicates that decide when.
///
/// One entry per SYMBOL, not per call: `before_action :a, :b` registers two
/// independent filters in Rails, and each name is separately something the
/// heuristic reads. `after_action`/`around_action` are not collected at all
/// -- they run after or around the response, so they cannot gate whether the
/// page is reachable.
///
/// `dynamic` means the sidecar found a filter it could not read as a name: a
/// block, a proc/lambda, a constant, or an `only:`/`except:` value that is
/// not a symbol or an array of symbols. Such an entry carries no `name` and
/// empty scope lists, and BOTH predicates below answer `false` for it --
/// see `guards`'s doc for why an unreadable scope must not be treated as an
/// empty (i.e. all-covering) one.
///
/// Contract 2 (owned-result): `controller`, `name` and every element of
/// `only`/`except` are fresh `gpa` allocations; `freeBeforeActions` is the
/// release.
pub const BeforeAction = struct {
    controller: []const u8 = "",
    name: ?[]const u8 = null,
    only: []const []const u8 = &.{},
    except: []const []const u8 = &.{},
    dynamic: bool = false,
    line: u64 = 0,
};

/// One `class Child < Parent` edge between two controller keys (fix round 1,
/// I-1). Rails filters INHERIT, and the commonest auth idiom of all declares
/// `before_action :authenticate_user!` once on `ApplicationController`: that
/// filter arrives keyed `application` while every route names `posts`,
/// `pages`, ... , so without this edge no consumer can attribute it and
/// every guarded page reports as unguarded -- the exact failure
/// `BeforeAction` exists to prevent.
///
/// Both fields are controller keys of the same shape `ActionInfo.controller`
/// uses. `parent` is derived from the superclass CONSTANT NAME (the child's
/// source is the only place it appears), so it is a convention-based guess in
/// the way a path-derived key is not -- see `analyze.rb`'s
/// `controller_key_from_class_name`. A wrong guess costs only that hop: the
/// walk finds no filters under that key and stops.
///
/// An edge is emitted only when the superclass resolves to an app controller
/// key; `ApplicationController < ActionController::Base` contributes none, so
/// the chain terminates at the framework instead of at an invented node.
///
/// Contract 2 (owned-result): both strings are fresh `gpa` allocations;
/// `freeParents` is the release.
pub const ParentEdge = struct {
    controller: []const u8 = "",
    parent: []const u8 = "",
};

/// One controller's own `layout` declaration, recovered from
/// `runtime/sidecar/rails/controllers.rb`'s Prism-AST walk (#167 Stage 1):
/// layout resolution needs to know when a controller OVERRIDES the Rails
/// convention (a `<controller>/application.html.erb`-shaped default) rather
/// than merely falling through to it. Contract 2 (owned-result): `controller`
/// and `value` (when present) are each a fresh `gpa` allocation independent
/// of the decoded response's JSON arena; `freeLayouts` is the release.
///
/// `value`/`disabled`/`dynamic` are mutually informative, not a tagged
/// union, because the wire shape (`WireLayout`) isn't one either -- three
/// independent booleans/optional straight off `controllers.rb`'s own
/// classification:
/// - `value` non-null, `disabled`/`dynamic` both false: a literal
///   `layout "marketing"` -- resolution should use `value` as the layout
///   name.
/// - `disabled` true (`value` null): `layout false` -- this controller
///   renders with NO layout at all, not even the default.
/// - `dynamic` true (`value` null): `layout :some_method` or a proc --
///   the static walk cannot resolve a name, but the controller DOES
///   override the convention; resolution should treat this as "known
///   non-default, name unavailable" rather than silently falling back to
///   convention.
pub const LayoutInfo = struct {
    controller: []const u8,
    value: ?[]const u8,
    disabled: bool,
    dynamic: bool,
    line: u64,
};

/// Env var naming the Ruby interpreter to spawn; `ruby` on `PATH` when
/// unset or blank. See `routes.zig`'s identical constant for the full
/// rationale (`std.process.spawn` resolves a bare name against `PATH`
/// itself).
const ruby_env = "ZIGAPAGOS_RUBY";

/// The same variable `routes.zig` re-declares from `src/cli/release.zig`;
/// see that file's comment for why this is a re-declaration, not an import.
const runtime_dir_env = "ZIGAPAGOS_RUNTIME_DIR";

// `resolveAbsRoot`, `killOnTimeout`, `queryOnce` moved to `sidecar_client.zig`
// (fix round 1, task-2-fixes.md item 1) -- see that file for their docs, and
// this file's module doc for why a SEPARATE process (not a shared one) is
// still spawned here. This is a pure relocation: no behavior changed.

const WireAction = struct {
    controller: []const u8,
    action: []const u8,
    only_redirect: bool,
    renders_json: bool,
    /// #167 Stage 3. Decoded straight into the PUBLIC `RedirectInfo` rather
    /// than through a separate `WireRedirect`: unlike this struct and
    /// `WireLayout`, whose wire shapes carry a field the owned type
    /// deliberately drops (`line`), the redirect shape is field-for-field
    /// identical on both sides, so a second struct would state nothing and
    /// would fork `dupeRedirects` in two (`decodeResponse` and `dupeActions`
    /// both need it). The strings a parse leaves here alias the JSON arena;
    /// `dupeRedirects` is what makes the escaping copy `gpa`-owned.
    ///
    /// Defaulted, not required: a response from a sidecar build that
    /// predates this field decodes as an empty list, exactly as `layouts`
    /// below already does.
    redirects: []const RedirectInfo = &.{},
    // `line` rides the wire (analyze.rb always sends it) but `ActionInfo`
    // has no field for it -- Stage 3's classification rules (the brief this
    // task serves) never need a line number, only the three structural
    // facts. `ignore_unknown_fields` on the decode below is what lets this
    // struct simply omit it rather than declaring and discarding it.
};

const WireUnresolved = struct {
    code: []const u8,
    /// The file this finding is about, relative to the app root (fix round
    /// B / B1) -- e.g. `"app/controllers/posts_controller.rb"`. Empty when
    /// absent (an older sidecar build, or a future code this build doesn't
    /// send a path for): `decodeResponse` falls back to `src_path` (the
    /// directory every controller finding used to share) in that case, same
    /// as before this field existed.
    path: []const u8 = "",
    detail: []const u8 = "",
    line: ?u64 = null,
};

const WireResponse = struct {
    ok: bool,
    actions: []const WireAction = &.{},
    /// `analyze.rb`'s `controllers` op's layout declarations (#167 Stage 1):
    /// one entry per controller that names its own `layout` call, literal or
    /// dynamic (a symbol/proc argument) or explicitly disabled (`layout
    /// false`). Defaulted, not required -- an older sidecar build's response
    /// simply predates this field, and `decodeResponse` below treats that
    /// the same as an explicit empty array (see `Decoded.layouts`'s doc).
    layouts: []const WireLayout = &.{},
    /// #167 Stage 3: the class-level filters, flattened across every
    /// controller file the op walked and keyed on the same path-derived
    /// `controller` string `actions[]` uses. Decoded straight into the
    /// public `BeforeAction` for the same reason `WireAction.redirects` is
    /// -- the two shapes are field-for-field identical. Defaulted so an
    /// older sidecar's response decodes as an empty list.
    before_actions: []const BeforeAction = &.{},
    /// #167 Stage 3 fix round 1 (I-1): `skip_before_action` declarations,
    /// same entry shape. Their OWN array, not a flag on `before_actions`,
    /// so a consumer that iterated one merged list without checking the flag
    /// could not read a skip as a guard. Defaulted, same older-sidecar
    /// tolerance as every field above.
    skip_before_actions: []const BeforeAction = &.{},
    /// #167 Stage 3 fix round 1 (I-1): the `class Child < Parent` edges that
    /// make an inherited filter attributable. Defaulted; an older sidecar's
    /// response simply has no chain, and `guardsFor` then reports only each
    /// controller's own filters -- the pre-fix behaviour, not a crash.
    parents: []const ParentEdge = &.{},
    unresolved: []const WireUnresolved = &.{},
    @"error": ?[]const u8 = null,
    // This op's own half of `discovery.ruby` -- see `routes.zig`'s `Ruby`
    // doc for why the type/decode logic is shared (`sidecar_client.zig`)
    // rather than a second hand copy. Optional so a hand-written `"ok":
    // false`/malformed test literal that predates this field still decodes.
    ruby: ?sidecar_client.WireRuby = null,
};

/// Wire shape of one `layouts[]` entry. `value` is the layout name when
/// `analyze.rb` could read it as a literal string (`layout "marketing"`);
/// `null` covers both `dynamic` (a symbol/proc/method argument the static
/// walk can't resolve to a name, e.g. `layout :choose_layout`) and
/// `disabled` (`layout false`) -- the two booleans, not `value`'s nullness
/// alone, are what tell those apart on the Zig side (see `LayoutInfo`'s
/// doc).
const WireLayout = struct {
    controller: []const u8,
    value: ?[]const u8 = null,
    disabled: bool = false,
    dynamic: bool = false,
    line: u64 = 0,
};

/// The known `unresolved[].code` vocabulary `runtime/sidecar/rails/
/// controllers.rb` and `analyze.rb`'s `handle_controllers` emit:
/// `RailsControllers.parse`'s own code for a file it read and rejected, and
/// `handle_controllers`'s own code (distinct since fix round B / B2) for a
/// file it never managed to read at all -- see that handler's own comment
/// for why those are not the same finding. Matched against rather than
/// trusting the JSON string directly, for the identical `Blocker.code`-
/// must-be-a-static-literal reason `routes.zig`'s `known_unresolved_codes`
/// documents.
const known_unresolved_codes = [_][]const u8{
    "RAILS_CONTROLLER_PARSE_ERROR",
    "RAILS_CONTROLLER_UNREADABLE",
};

/// Fallback for a code this build's table doesn't recognize. The real text
/// is not dropped -- `decodeResponse` folds it into the blocker's `detail`.
const unrecognized_unresolved_code = "RAILS_CONTROLLER_UNRESOLVED";

fn staticUnresolvedCode(json_code: []const u8) []const u8 {
    for (known_unresolved_codes) |c| {
        if (std.mem.eql(u8, c, json_code)) return c;
    }
    return unrecognized_unresolved_code;
}

/// Contract 2 (owned-result) helper for `decodeResponse`: every string
/// field of the returned `ActionInfo` is a fresh `gpa` allocation,
/// independent of `wa`'s backing JSON arena. On a mid-construction
/// allocation failure, `controller` is freed via `errdefer` before the
/// error propagates.
fn dupeAction(gpa: Allocator, wa: WireAction) Allocator.Error!ActionInfo {
    const controller = try gpa.dupe(u8, wa.controller);
    errdefer gpa.free(controller);
    const action = try gpa.dupe(u8, wa.action);
    errdefer gpa.free(action);
    const redirects = try dupeRedirects(gpa, wa.redirects);
    return .{
        .controller = controller,
        .action = action,
        .only_redirect = wa.only_redirect,
        .renders_json = wa.renders_json,
        .redirects = redirects,
    };
}

fn freeActionFields(gpa: Allocator, a: ActionInfo) void {
    gpa.free(a.controller);
    gpa.free(a.action);
    freeRedirects(gpa, a.redirects);
}

/// Contract 2 (owned-result) helper shared by `dupeRedirects` and
/// `dupeBeforeAction`: a fresh `gpa`-owned copy of a list of strings, with
/// every element already copied released on a mid-list failure.
fn dupeStringList(gpa: Allocator, src: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try gpa.alloc([]const u8, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (src, 0..) |s, i| {
        out[i] = try gpa.dupe(u8, s);
        filled = i + 1;
    }
    return out;
}

fn freeStringList(gpa: Allocator, list: []const []const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

/// Contract 2 (owned-result). Takes `[]const RedirectInfo` on purpose, so
/// the same function serves BOTH callers: `decodeResponse` (whose source
/// aliases the JSON arena, since `WireAction.redirects` is this very type)
/// and `dupeActions` (whose source is another `gpa`-owned copy about to be
/// freed). `freeRedirects` is the release.
fn dupeRedirects(gpa: Allocator, src: []const RedirectInfo) Allocator.Error![]const RedirectInfo {
    const out = try gpa.alloc(RedirectInfo, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |r| freeRedirectFields(gpa, r);
        gpa.free(out);
    }
    for (src, 0..) |r, i| {
        const name: ?[]const u8 = if (r.name) |n| try gpa.dupe(u8, n) else null;
        errdefer if (name) |n| gpa.free(n);
        const path: ?[]const u8 = if (r.path) |p| try gpa.dupe(u8, p) else null;
        errdefer if (path) |p| gpa.free(p);
        out[i] = .{
            .name = name,
            .args = try dupeStringList(gpa, r.args),
            .path = path,
            .dynamic = r.dynamic,
        };
        filled = i + 1;
    }
    return out;
}

fn freeRedirectFields(gpa: Allocator, r: RedirectInfo) void {
    if (r.name) |n| gpa.free(n);
    if (r.path) |p| gpa.free(p);
    freeStringList(gpa, r.args);
}

fn freeRedirects(gpa: Allocator, list: []const RedirectInfo) void {
    for (list) |r| freeRedirectFields(gpa, r);
    gpa.free(list);
}

/// Contract 2 (owned-result), and the same both-callers argument
/// `dupeRedirects` documents: `WireResponse.before_actions` IS
/// `[]const BeforeAction`, so `decodeResponse` and `dupeBeforeActions` share
/// one implementation. `freeBeforeActions` is the release.
fn dupeBeforeAction(gpa: Allocator, src: BeforeAction) Allocator.Error!BeforeAction {
    const controller = try gpa.dupe(u8, src.controller);
    errdefer gpa.free(controller);
    const name: ?[]const u8 = if (src.name) |n| try gpa.dupe(u8, n) else null;
    errdefer if (name) |n| gpa.free(n);
    const only = try dupeStringList(gpa, src.only);
    errdefer freeStringList(gpa, only);
    const except = try dupeStringList(gpa, src.except);
    return .{
        .controller = controller,
        .name = name,
        .only = only,
        .except = except,
        .dynamic = src.dynamic,
        .line = src.line,
    };
}

fn freeBeforeActionFields(gpa: Allocator, b: BeforeAction) void {
    gpa.free(b.controller);
    if (b.name) |n| gpa.free(n);
    freeStringList(gpa, b.only);
    freeStringList(gpa, b.except);
}

/// Contract 2 counterpart to `BeforeAction`: releases every owned string on
/// every entry plus the slice itself, in one call -- the same
/// one-release-for-the-whole-slice idiom as `freeActions`/`freeLayouts`.
pub fn freeBeforeActions(gpa: Allocator, list: []BeforeAction) void {
    for (list) |b| freeBeforeActionFields(gpa, b);
    gpa.free(list);
}

/// Contract 2 (owned-result): the `ParentEdge` counterpart to
/// `dupeBeforeActions`. Serves both `decodeResponse` (source aliases the
/// JSON arena) and `rails.zig`'s `Discovery` copy, same as its siblings.
/// `freeParents` is the release.
pub fn dupeParents(gpa: Allocator, src: []const ParentEdge) Allocator.Error![]ParentEdge {
    const out = try gpa.alloc(ParentEdge, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |p| freeParentFields(gpa, p);
        gpa.free(out);
    }
    for (src, 0..) |p, i| {
        const controller = try gpa.dupe(u8, p.controller);
        errdefer gpa.free(controller);
        out[i] = .{ .controller = controller, .parent = try gpa.dupe(u8, p.parent) };
        filled = i + 1;
    }
    return out;
}

fn freeParentFields(gpa: Allocator, p: ParentEdge) void {
    gpa.free(p.controller);
    gpa.free(p.parent);
}

/// Contract 2 counterpart to `ParentEdge`; one call for the whole slice,
/// same idiom as `freeActions`/`freeBeforeActions`.
pub fn freeParents(gpa: Allocator, list: []ParentEdge) void {
    for (list) |p| freeParentFields(gpa, p);
    gpa.free(list);
}

/// Contract 2 (owned-result): a `gpa`-owned deep copy of an action list,
/// for `rails.zig`'s `Discovery` -- which outlives the `Result` these came
/// from (`discover`'s own `defer freeResult` runs first), so a shallow copy
/// would leave the manifest and the scaffold pointing at freed memory. Lives
/// here rather than in `rails.zig` because this file is the one place that
/// knows what an `ActionInfo` owns now that it owns a nested graph.
/// `freeActions` is the release.
pub fn dupeActions(gpa: Allocator, src: []const ActionInfo) Allocator.Error![]ActionInfo {
    const out = try gpa.alloc(ActionInfo, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |a| freeActionFields(gpa, a);
        gpa.free(out);
    }
    for (src, 0..) |a, i| {
        const controller = try gpa.dupe(u8, a.controller);
        errdefer gpa.free(controller);
        const action = try gpa.dupe(u8, a.action);
        errdefer gpa.free(action);
        out[i] = .{
            .controller = controller,
            .action = action,
            .only_redirect = a.only_redirect,
            .renders_json = a.renders_json,
            .redirects = try dupeRedirects(gpa, a.redirects),
        };
        filled = i + 1;
    }
    return out;
}

/// Contract 2 (owned-result): the `BeforeAction` counterpart to
/// `dupeActions`, for the same `Discovery`-outlives-`Result` reason.
/// `freeBeforeActions` is the release.
pub fn dupeBeforeActions(gpa: Allocator, src: []const BeforeAction) Allocator.Error![]BeforeAction {
    const out = try gpa.alloc(BeforeAction, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |b| freeBeforeActionFields(gpa, b);
        gpa.free(out);
    }
    for (src, 0..) |b, i| {
        out[i] = try dupeBeforeAction(gpa, b);
        filled = i + 1;
    }
    return out;
}

/// Contract 3 (caller-buffer): whether `filter` runs for `action`, by Rails'
/// own rule -- `only:` decides alone when it is present, and `except:` is
/// consulted only when it is not. An implementation that ANDed or ORed the
/// two would disagree with Rails on `only: [:index], except: [:index]`.
///
/// A `dynamic` filter answers `false` for every action. Its empty scope
/// lists are "not read", not "not scoped": treating them as an unscoped
/// filter would claim a block filter covers every action in the controller,
/// which is the same over-claim that would mark pages open that Rails serves
/// publicly.
pub fn guards(filter: BeforeAction, action: []const u8) bool {
    if (filter.dynamic) return false;
    if (filter.only.len > 0) {
        for (filter.only) |a| {
            if (std.mem.eql(u8, a, action)) return true;
        }
        return false;
    }
    for (filter.except) |a| {
        if (std.mem.eql(u8, a, action)) return false;
    }
    return true;
}

/// Contract 3 (caller-buffer): assumption A7's heuristic -- the filter's
/// name contains `login`, `auth`, `sign` or `user`, ASCII case-insensitively.
///
/// A heuristic, and deliberately a broad one: it decides whether to ASK the
/// operator (`RAILS_ROUTE_AUTH_GUARD`), never whether to ship or block a
/// page by itself. A false positive costs one answerable question; a false
/// negative ships a guarded page silently public, which is exactly what #167
/// forbids. Matching is on the substring rather than the whole name because
/// the real-world spellings (`require_login`, `authenticate_user!`,
/// `require_signed_in`, `current_user_required`) share no common shape.
///
/// A `dynamic` filter has no name and answers `false` -- there is nothing to
/// read. That is a known gap in A7's coverage, not an oversight: a block
/// filter could be an auth guard, but reporting every one of them as such
/// would raise the finding on controllers that merely set a locale.
pub fn looksLikeAuthGuard(filter: BeforeAction) bool {
    const name = filter.name orelse return false;
    for ([_][]const u8{ "login", "auth", "sign", "user" }) |needle| {
        if (std.ascii.indexOfIgnoreCase(name, needle) != null) return true;
    }
    return false;
}

/// The three lists `guardsFor` needs, named rather than passed as three
/// same-typed positional slices -- two of them ARE the same type, and a call
/// site that swapped `before_actions` and `skips` would compile and quietly
/// invert every answer.
///
/// Contract 3 (caller-buffer): a borrowed view. It owns nothing and outlives
/// nothing; build one from a `controllers.Result` (`Result.filterSet`) or
/// from `rails.Discovery` (`Discovery.filterSet`).
pub const FilterSet = struct {
    before_actions: []const BeforeAction = &.{},
    skips: []const BeforeAction = &.{},
    parents: []const ParentEdge = &.{},
};

/// How far `guardsFor` will walk up the `class Child < Parent` chain. Real
/// Rails hierarchies are two or three deep (`ApplicationController` ->
/// maybe one `Admin::BaseController` -> the controller); eight is generous
/// headroom. The cap is a second line of defence only -- the cycle check
/// below already terminates `A < B < A` -- but a cap that does not depend on
/// the cycle check being right is worth its four lines in a walker fed by
/// untrusted source.
pub const max_parent_chain = 8;

/// Every filter that runs for `controller#action`, own controller first and
/// then up the inheritance chain, with `skip_before_action` honoured.
///
/// An iterator rather than an allocated slice so this is contract 3
/// (caller-buffer, takes no allocator at all): the chain is bounded by
/// `max_parent_chain`, so it fits in the iterator itself and a caller that
/// only wants the FIRST match -- which is what `RAILS_ROUTE_AUTH_GUARD` and
/// `authGuardFor` below want -- pays for nothing more.
///
/// Each yielded `BeforeAction` keeps the `controller` it was DECLARED on,
/// not the one asked about, which is what a finding message needs to say
/// ("guarded by before_action :authenticate_user! on application").
pub const GuardIterator = struct {
    set: FilterSet,
    action: []const u8,
    chain: [max_parent_chain][]const u8,
    chain_len: usize,
    chain_i: usize = 0,
    filter_i: usize = 0,

    pub fn next(self: *GuardIterator) ?BeforeAction {
        while (self.chain_i < self.chain_len) {
            const owner = self.chain[self.chain_i];
            while (self.filter_i < self.set.before_actions.len) {
                const f = self.set.before_actions[self.filter_i];
                self.filter_i += 1;
                if (!std.mem.eql(u8, f.controller, owner)) continue;
                if (!guards(f, self.action)) continue;
                if (self.skipped(f)) continue;
                return f;
            }
            self.chain_i += 1;
            self.filter_i = 0;
        }
        return null;
    }

    /// A `skip_before_action` suppresses a same-named filter for the actions
    /// the SKIP's own only:/except: scope covers -- but only when the skip is
    /// declared AT OR BELOW the filter, i.e. on the declaring class itself or
    /// on a descendant of it.
    ///
    /// Position matters, and an earlier round's claim that it does not
    /// ("a skip is always written in a subclass of whatever declared the
    /// filter") was simply wrong: `raise: false` makes any placement legal,
    /// so
    ///
    ///     class ApplicationController < ActionController::Base
    ///       skip_before_action :authenticate_user!, raise: false
    ///     end
    ///     class PostsController < ApplicationController
    ///       before_action :authenticate_user!
    ///     end
    ///
    /// parses fine and Rails still RUNS the filter -- the skip ran against a
    /// callback chain that did not yet contain it. Suppressing on a name
    /// match anywhere in the chain reported that page unguarded.
    ///
    /// `chain[0]` is the route's own controller and each later index is one
    /// step further up, so "at or below" is `skip index <= filter index`.
    /// `chain_i` is the index the filter currently being yielded came from.
    ///
    /// WITHIN one class the index is equal and says nothing, so source order
    /// decides (fix round 3, NEW-2). It is the same rule for the same
    /// reason -- a skip only removes what the callback chain already holds:
    ///
    ///     class PostsController < ApplicationController
    ///       skip_before_action :authenticate_user!, raise: false  # line 2
    ///       before_action :authenticate_user!                     # line 3
    ///     end
    ///
    /// runs the filter, because line 2 skipped a chain that did not yet
    /// contain it; swap the two lines and it does not. So an equal index
    /// additionally requires `skip.line > filter.line`. Both lines ride the
    /// wire already.
    ///
    /// A `dynamic` skip suppresses nothing -- it has no name to match, and
    /// `guards` answers false for it. That leaves the filter reported, i.e.
    /// over-reports the guard, which is the direction A7 requires.
    fn skipped(self: *const GuardIterator, filter: BeforeAction) bool {
        const name = filter.name orelse return false;
        for (self.set.skips) |s| {
            const sn = s.name orelse continue;
            if (!std.mem.eql(u8, sn, name)) continue;
            const at = self.chainIndex(s.controller) orelse continue;
            if (at > self.chain_i) continue; // declared above the filter: no effect
            // Same class: the skip has to come after the filter it removes.
            if (at == self.chain_i and s.line <= filter.line) continue;
            if (guards(s, self.action)) return true;
        }
        return false;
    }

    /// Position of `controller` in the chain, or null when it is not in it.
    /// `0` is the route's own controller; larger is further up.
    fn chainIndex(self: *const GuardIterator, controller: []const u8) ?usize {
        for (self.chain[0..self.chain_len], 0..) |c, i| {
            if (std.mem.eql(u8, c, controller)) return i;
        }
        return null;
    }

    fn inChain(self: *const GuardIterator, controller: []const u8) bool {
        return self.chainIndex(controller) != null;
    }
};

/// Contract 3 (caller-buffer): builds the controller's inheritance chain and
/// returns an iterator over the filters that run for `action`. Allocates
/// nothing.
///
/// The chain is resolved eagerly and stops on the first repeat, so a
/// malformed `class A < B` / `class B < A` pair in the analysed app
/// terminates instead of looping -- the same "one bad file must not hang the
/// build" rule the Ruby side's own cycle detection follows. A chain longer
/// than `max_parent_chain` is truncated, which under-reports filters
/// declared above the cut rather than spinning.
pub fn guardsFor(set: FilterSet, controller: []const u8, action: []const u8) GuardIterator {
    var it: GuardIterator = .{
        .set = set,
        .action = action,
        .chain = undefined,
        .chain_len = 0,
    };
    var current = controller;
    while (it.chain_len < max_parent_chain) {
        if (it.inChain(current)) break; // cycle
        it.chain[it.chain_len] = current;
        it.chain_len += 1;
        const parent = parentOf(set.parents, current) orelse break;
        current = parent;
    }
    return it;
}

fn parentOf(parents: []const ParentEdge, controller: []const u8) ?[]const u8 {
    for (parents) |p| {
        if (std.mem.eql(u8, p.controller, controller)) return p.parent;
    }
    return null;
}

/// THE auth filter running for `controller#action` -- what
/// `RAILS_ROUTE_AUTH_GUARD` asks, in one call. Null when the action runs no
/// auth-looking filter.
///
/// The pick is the smallest `(name, line)`, not the first hit in CHAIN order,
/// and that is a deliberate choice about determinism: the chain's own order
/// within one controller is whatever order the sidecar's directory walk
/// emitted the filters in. This filter's NAME is printed into the manifest
/// (the finding's message) AND into the handoff (`scaffold`'s `public` note),
/// so an unstable pick is an unstable artifact.
///
/// One function, and not two, for the second half of the same reason. The
/// note and the finding are two rows about ONE decision; while `findings.zig`
/// kept its own stable picker and `scaffold.zig` called a chain-order one,
/// a controller with two auth-looking filters had them naming different
/// guards, and an operator could not tell which filter their `public` had
/// been asked about.
///
/// A dynamic filter never wins: `looksLikeAuthGuard` answers false for it
/// (there is no symbol to read), which is the A7-safe direction only because
/// Task 2's Ruby side keeps the symbol wherever it can see one.
///
/// Contract 3 (caller-buffer): allocates nothing; the result borrows `set`.
pub fn authGuardFor(set: FilterSet, controller: ?[]const u8, action: ?[]const u8) ?BeforeAction {
    const c = controller orelse return null;
    const a = action orelse return null;
    var best: ?BeforeAction = null;
    var it = guardsFor(set, c, a);
    while (it.next()) |f| {
        if (!looksLikeAuthGuard(f)) continue;
        const cur = best orelse {
            best = f;
            continue;
        };
        const order = std.mem.order(u8, f.name orelse "", cur.name orelse "");
        if (order == .lt or (order == .eq and f.line < cur.line)) best = f;
    }
    return best;
}

/// Decodes one sidecar response LINE (`{"ok":true,"actions":[...],
/// "unresolved":[...]}` or `{"ok":false,"error":"..."}`) into `[]ActionInfo`.
/// Split out from `discoverControllers` so the JSON half is unit-testable
/// without spawning anything, mirroring `routes.zig`'s `decodeResponse`.
///
/// Contract 2 (owned-result): see `dupeAction`'s doc for the per-field
/// ownership story. `parsed.deinit()` frees the JSON tree the result was
/// decoded from before this function returns, so nothing in the returned
/// slice may alias it; `freeActions` is the matching release.
///
/// `unresolved` entries become blockers (`integrity = false` -- an action
/// shape the walk could not read is an expected finding about one file, not
/// a reason to distrust the whole recovered set) rather than being silently
/// dropped. A malformed line, or a well-formed `{"ok":false,...}`, both
/// collapse to a single `RAILS_CONTROLLERS_UNAVAILABLE` blocker (per the
/// brief's degradation table, every sidecar-side failure -- including a bad
/// response -- shares this one code) and an empty action slice.
///
/// Each `unresolved` entry's blocker gets its OWN `path` -- the file it is
/// about (`u.path`, relative to the app root) -- rather than the shared
/// `src_path` directory every controller finding used to collapse onto
/// (fix round B / B1: `path` should name the file the blocker is about,
/// same as `RAILS_TEMPLATE_UNREADABLE` already does). `src_path` remains
/// the fallback for an entry with no `path` (an older sidecar build, or the
/// `RAILS_CONTROLLERS_UNAVAILABLE` cases above that have no single file to
/// name).
///
/// `ruby` is decoded independent of `ok`, same reasoning as `routes.zig`'s
/// `decodeResponse`: even an `{"ok":false,...}` response still comes from a
/// Ruby process that genuinely ran and answered, so `analyze.rb` stamps
/// `RUBY_INFO` on every `handle_controllers` response, success or not
/// (Stage 4's task-2-fixes.md item 1). Only a response this function could
/// not decode AT ALL (the malformed-line branch below) has no `ruby` to
/// read, and falls back to `available: false`.
const Decoded = struct {
    actions: []ActionInfo,
    /// Owned (contract 2, see `LayoutInfo`'s doc); released by `freeLayouts`.
    /// Every early-return above (malformed line, `ok:false`) sets this to
    /// `&.{}` -- same reasoning as those branches' `actions = &.{}`: there is
    /// no response to have decoded a layout list FROM.
    layouts: []LayoutInfo,
    /// Owned (contract 2, see `BeforeAction`'s doc); released by
    /// `freeBeforeActions`. Empty on every early-return branch, and equally
    /// empty for a sidecar build that predates the field.
    before_actions: []BeforeAction,
    /// Owned; released by `freeBeforeActions`. See `FilterSet`.
    skip_before_actions: []BeforeAction,
    /// Owned; released by `freeParents`. See `ParentEdge`.
    parents: []ParentEdge,
    ruby: sidecar_client.Ruby,
};

fn decodeResponse(
    gpa: Allocator,
    line: []const u8,
    src_path: []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error!Decoded {
    var parsed = std.json.parseFromSlice(WireResponse, gpa, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", src_path, @errorName(err), false, .@"error", null, null);
            return .{ .actions = &.{}, .layouts = &.{}, .before_actions = &.{}, .skip_before_actions = &.{}, .parents = &.{}, .ruby = .{ .available = false, .version = null } };
        },
    };
    defer parsed.deinit();
    const resp = parsed.value;

    const ruby = try sidecar_client.decodeRuby(gpa, resp.ruby);
    errdefer sidecar_client.freeRuby(gpa, ruby);

    if (!resp.ok) {
        try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", src_path, resp.@"error" orelse "sidecar reported failure", false, .@"error", null, null);
        return .{ .actions = &.{}, .layouts = &.{}, .before_actions = &.{}, .skip_before_actions = &.{}, .parents = &.{}, .ruby = ruby };
    }

    var actions = try gpa.alloc(ActionInfo, resp.actions.len);
    var filled: usize = 0;
    errdefer {
        for (actions[0..filled]) |a| freeActionFields(gpa, a);
        gpa.free(actions);
    }
    for (resp.actions, 0..) |wa, i| {
        actions[i] = try dupeAction(gpa, wa);
        filled = i + 1;
    }

    var layouts = try gpa.alloc(LayoutInfo, resp.layouts.len);
    var lfilled: usize = 0;
    errdefer {
        for (layouts[0..lfilled]) |l| freeLayoutFields(gpa, l);
        gpa.free(layouts);
    }
    for (resp.layouts, 0..) |wl, i| {
        const controller = try gpa.dupe(u8, wl.controller);
        errdefer gpa.free(controller);
        const value: ?[]const u8 = if (wl.value) |v| try gpa.dupe(u8, v) else null;
        layouts[i] = .{ .controller = controller, .value = value, .disabled = wl.disabled, .dynamic = wl.dynamic, .line = wl.line };
        lfilled = i + 1;
    }

    const before_actions = try dupeBeforeActions(gpa, resp.before_actions);
    errdefer freeBeforeActions(gpa, before_actions);

    const skip_before_actions = try dupeBeforeActions(gpa, resp.skip_before_actions);
    errdefer freeBeforeActions(gpa, skip_before_actions);

    const parents = try dupeParents(gpa, resp.parents);
    errdefer freeParents(gpa, parents);

    // `route_id` stays `null` here, deliberately (Stage 4 Task 5): each `u`
    // describes an action shape one controller FILE's parse could not
    // resolve, before this run has joined controller/action pairs to any
    // route at all (that join is `rails.zig`'s `actionFor`, which runs
    // later against `route_result.routes`) -- the same "a construct, not a
    // recovered route" reasoning `routes.zig`'s own `resp.unresolved` loop
    // documents.
    for (resp.unresolved) |u| {
        const code = staticUnresolvedCode(u.code);
        const recognized = !std.mem.eql(u8, code, unrecognized_unresolved_code);
        const blocker_path = if (u.path.len > 0) u.path else src_path;
        var detail_buf: [320]u8 = undefined;
        const detail = if (recognized)
            (if (u.line) |ln|
                std.fmt.bufPrint(&detail_buf, "{s} (line {d})", .{ u.detail, ln }) catch u.detail
            else
                u.detail)
        else if (u.line) |ln|
            std.fmt.bufPrint(&detail_buf, "unrecognized code {s}: {s} (line {d})", .{ u.code, u.detail, ln }) catch u.detail
        else
            std.fmt.bufPrint(&detail_buf, "unrecognized code {s}: {s}", .{ u.code, u.detail }) catch u.detail;
        try blockers.append(gpa, blocker_list, code, blocker_path, detail, false, .warn, null, u.line);
    }

    return .{
        .actions = actions,
        .layouts = layouts,
        .before_actions = before_actions,
        .skip_before_actions = skip_before_actions,
        .parents = parents,
        .ruby = ruby,
    };
}

/// Contract 2 counterpart to `discoverControllers`/`decodeResponse`:
/// releases every owned string on every action (see `dupeAction`'s
/// ownership note) plus the slice itself. `only_redirect`/`renders_json`
/// are plain values with nothing to free. Matches `routes.zig`'s
/// `freeRoutes` ownership idiom, NOT `blockers.free` + a separate
/// `deinit()` -- this is the one release call for the whole slice.
pub fn freeActions(gpa: Allocator, actions: []ActionInfo) void {
    for (actions) |a| freeActionFields(gpa, a);
    gpa.free(actions);
}

fn freeLayoutFields(gpa: Allocator, l: LayoutInfo) void {
    gpa.free(l.controller);
    if (l.value) |v| gpa.free(v);
}

/// Contract 2 counterpart to `LayoutInfo`: releases every owned string on
/// every entry (see `LayoutInfo`'s ownership note) plus the slice itself.
/// `disabled`/`dynamic`/`line` are plain values with nothing to free. Same
/// one-call-for-the-whole-slice idiom as `freeActions`.
pub fn freeLayouts(gpa: Allocator, layouts: []LayoutInfo) void {
    for (layouts) |l| freeLayoutFields(gpa, l);
    gpa.free(layouts);
}

/// Contract 3 (caller-buffer): plain linear lookup, no allocation, same
/// reasoning as `find` above -- one Rails app's worth of controllers is
/// small enough that a hash map buys nothing. Returns a copy of the
/// matching `LayoutInfo` (a plain-value struct whose string fields alias
/// `layouts`' own storage) so the caller cannot free through it
/// independently of `layouts`.
pub fn findLayout(layouts: []const LayoutInfo, controller: []const u8) ?LayoutInfo {
    for (layouts) |l| {
        if (std.mem.eql(u8, l.controller, controller)) return l;
    }
    return null;
}

/// `discoverControllers`'s return: the recovered action shapes plus this
/// op's own half of `discovery.ruby` (see `routes.zig`'s `Result.ruby` doc
/// for why this is only a HALF -- `rails.zig`'s `combineRuby` ORs it
/// together with `routes.Result.ruby` before either reaches a consumer).
pub const Result = struct {
    /// Owned; release with `freeActions`.
    actions: []ActionInfo,
    /// Owned; release with `freeLayouts`. See `LayoutInfo`'s doc.
    layouts: []LayoutInfo,
    /// Owned; release with `freeBeforeActions`. See `BeforeAction`'s doc.
    /// Flattened across every controller file the op walked -- one list for
    /// the whole app, keyed on the same path-derived `controller` string
    /// `actions` uses, so `guards` needs no per-file grouping to answer.
    before_actions: []BeforeAction,
    /// Owned; release with `freeBeforeActions`. `skip_before_action`
    /// declarations -- see `FilterSet` and `GuardIterator.skipped`.
    skip_before_actions: []BeforeAction,
    /// Owned; release with `freeParents`. The inheritance edges that make an
    /// inherited filter attributable -- see `ParentEdge`.
    parents: []ParentEdge,
    ruby: sidecar_client.Ruby,

    /// Contract 3: the borrowed view `guardsFor`/`authGuardFor` take.
    /// A method so the three lists cannot be paired up wrongly at a call
    /// site (see `FilterSet`'s doc).
    pub fn filterSet(self: Result) FilterSet {
        return .{
            .before_actions = self.before_actions,
            .skips = self.skip_before_actions,
            .parents = self.parents,
        };
    }
};

/// Contract 2 counterpart to `discoverControllers`: releases every owned
/// piece of a `Result` (`actions` via `freeActions`, `layouts` via
/// `freeLayouts`, `ruby.version` via `sidecar_client.freeRuby`) in one call,
/// mirroring `routes.zig`'s `freeResult`.
pub fn freeResult(gpa: Allocator, result: Result) void {
    freeActions(gpa, result.actions);
    freeLayouts(gpa, result.layouts);
    freeBeforeActions(gpa, result.before_actions);
    freeBeforeActions(gpa, result.skip_before_actions);
    freeParents(gpa, result.parents);
    sidecar_client.freeRuby(gpa, result.ruby);
}

/// Plain linear lookup, no allocation -- not one of NO_SLOP.md's §2.2a
/// allocator contracts because it takes no `Allocator` at all. `actions` is
/// typically small (one Rails app's worth of controller actions), so a
/// linear scan is not worth a hash map for Stage 3's per-route lookups.
/// Returns a copy of the matching `ActionInfo` (a plain-value struct whose
/// string fields alias `actions`' own storage, not new allocations) so the
/// caller cannot free through it independently of `actions`.
pub fn find(actions: []const ActionInfo, controller: []const u8, action: []const u8) ?ActionInfo {
    for (actions) |a| {
        if (std.mem.eql(u8, a.controller, controller) and std.mem.eql(u8, a.action, action)) return a;
    }
    return null;
}

/// Contract 2 (owned-result): every `ActionInfo.controller`/`.action` string
/// is a fresh `gpa`-owned allocation (see `dupeAction`'s doc); `freeActions`
/// is the matching release. `only_redirect`/`renders_json` are plain values.
/// `Result.ruby.version`, when present, is a SEPARATE `gpa`-owned
/// allocation released by `sidecar_client.freeRuby` -- `freeResult` frees
/// both in one call (Stage 4's task-2-fixes.md item 1 added this half of
/// `Result`; before it, this function returned a bare `[]ActionInfo`).
///
/// Every failure mode -- Ruby not found, the sidecar script/runtime dir not
/// found, a spawn/exit/response failure, or no `app/controllers/` -- appends
/// exactly one blocker with `integrity = false` (see the module doc) and
/// returns a `Result` with an empty slice and `ruby.available = false`
/// (there is no interpreter to ask on any of those paths). This function's
/// own error return stays `Allocator.Error` only: every other failure
/// degrades instead of propagating, matching `routes.zig`'s
/// `discoverRoutes`.
///
/// `app/controllers/`'s absence -- and, since fix round B / B3, its being
/// PRESENT but unreadable -- is detected HERE, client-side, via `openDir`
/// (not the bare `root.access` this used to be: `access`'s existence check
/// succeeds even when the directory's contents cannot be listed, since
/// resolving the path only needs search permission on its PARENT, not read
/// permission on the target itself -- so a `chmod 000 app/controllers` used
/// to sail through this check and on into the sidecar, whose own
/// `Dir.glob` swallows the resulting permission error and answers
/// `{"actions":[],"unresolved":[]}` -- indistinguishable from a genuinely
/// empty `app/controllers/`. `openDir` actually attempts to read the
/// directory, so it fails the same way `inventory.walk`'s own `openDir`
/// probe of `app/` does.) The same reasoning `routes.zig` gives for
/// checking `config/routes.rb` client-side rather than relying on
/// analyze.rb's own answer applies to both outcomes: each gets its own
/// blocker code (`RAILS_CONTROLLERS_MISSING` for `error.FileNotFound`,
/// `RAILS_CONTROLLERS_UNAVAILABLE` -- the same code every OTHER sidecar-side
/// degradation shares -- for anything else, chiefly `error.AccessDenied`)
/// and skips spawning Ruby entirely for an app this adapter already knows
/// has nothing usable to analyze. (analyze.rb's `handle_controllers` still
/// answers the ABSENT case correctly and structurally on its own --
/// `Dir.glob` against a nonexistent directory returns `[]` -- which is what
/// its own Ruby test pins; this client-side check is purely the "skip the
/// spawn" optimization for that one outcome, not a correctness requirement
/// analyze.rb relies on. The UNREADABLE case has no such fallback: without
/// this probe, that run silently reports zero actions with zero blockers,
/// which is exactly the "looks like a complete, controller-less app"
/// failure mode B3 exists to close.)
///
/// `environ_map` is threaded down the same way `routes.zig`'s
/// `discoverRoutes` receives it -- see that function's doc.
pub fn discoverControllers(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    root_path: []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
    environ_map: *const std.process.Environ.Map,
) Allocator.Error!Result {
    // Every degradation branch below returns this literally -- Ruby/the
    // sidecar never ran, so there is no interpreter to ask and `ruby.
    // available` is unconditionally `false` here, same as `routes.zig`'s
    // identical `none`. The success path (the final `decodeResponse` call)
    // overrides `.ruby` with whatever the sidecar's own response reported.
    const none: Result = .{ .actions = &.{}, .layouts = &.{}, .before_actions = &.{}, .skip_before_actions = &.{}, .parents = &.{}, .ruby = .{ .available = false, .version = null } };

    var controllers_dir = root.openDir(io, "app/controllers", .{ .iterate = true }) catch |err| {
        const code = if (err == error.FileNotFound) "RAILS_CONTROLLERS_MISSING" else "RAILS_CONTROLLERS_UNAVAILABLE";
        try blockers.append(gpa, blocker_list, code, "app/controllers", @errorName(err), false, .@"error", null, null);
        return none;
    };
    // Only a readability probe -- the actual walk happens Ruby-side via
    // `Dir.glob`, same division of labor as before this openDir replaced a
    // bare `access` call.
    controllers_dir.close(io);

    const ruby_path = environ_map.get(ruby_env) orelse "ruby";

    const runtime_dir_raw = environ_map.get(runtime_dir_env);
    const runtime_dir = if (runtime_dir_raw) |v| std.mem.trim(u8, v, " \t\r\n") else "";
    if (runtime_dir.len == 0) {
        try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", "sidecar/rails/analyze.rb", "ZIGAPAGOS_RUNTIME_DIR is not set", false, .@"error", null, null);
        return none;
    }

    const script_path = try std.fs.path.join(gpa, &.{ runtime_dir, "sidecar", "rails", "analyze.rb" });
    defer gpa.free(script_path);

    var script_abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const script_abs_n = Io.Dir.cwd().realPathFile(io, script_path, &script_abs_buf) catch |err| {
        // R12 (fix round 1, task-8 review): `Blocker.path` is documented
        // app-root-relative and feeds the discovery report, so two machines
        // analysing the same app must produce the same bytes for it.
        // `script_path` is `$ZIGAPAGOS_RUNTIME_DIR` joined -- absolute on any
        // real install -- so it cannot go here. The static literal does; the
        // path actually attempted moves into free-text `detail`, which
        // carries no determinism contract. Same split the spawn branch below
        // already made for `ruby_path` (F3); this site had simply been
        // missed. Changed in `routes.zig` and `fragments.zig` at the same
        // time so the three clients stay mirrors.
        var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s}: {t}", .{ script_path, err }) catch @errorName(err);
        try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", "sidecar/rails/analyze.rb", detail, false, .@"error", null, null);
        return none;
    };
    const script_abs = script_abs_buf[0..script_abs_n];

    const abs_root = sidecar_client.resolveAbsRoot(io, gpa, root_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // R12, same reasoning as the site above: `root_path` is the
            // caller's own cwd-relative (or absolute) handle on the app, not
            // a path relative to the app root. `"."` IS the app-root-relative
            // name of the thing that could not be resolved -- the app root
            // itself -- and is identical on every machine; `root_path` moves
            // into `detail`.
            var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "{s}: {t}", .{ root_path, err }) catch @errorName(err);
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", ".", detail, false, .@"error", null, null);
            return none;
        },
    };
    defer gpa.free(abs_root);

    var child = std.process.spawn(io, .{
        .argv = &.{ ruby_path, script_abs },
        .stdin = .pipe,
        .stdout = .pipe,
        // stderr inherits the parent so a Ruby crash/backtrace is visible
        // in the build log, same as `routes.zig`.
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // `path` names the sidecar script, not `ruby_path` -- see
            // `routes.zig`'s identical spawn-failure branch for why a
            // machine-specific interpreter path must not reach a field
            // documented "relative to the app root". The interpreter is
            // still named, in free-text `detail` instead.
            var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "interpreter '{s}': {t}", .{ ruby_path, err }) catch @errorName(err);
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", "sidecar/rails/analyze.rb", detail, false, .@"error", null, null);
            return none;
        },
    };

    var done: Io.Event = .unset;
    const watchdog: ?std.Thread = if (comptime !builtin.single_threaded)
        std.Thread.spawn(.{}, sidecar_client.killOnTimeout, .{ io, &child, &done }) catch null
    else
        null; // -Dsingle-threaded has no threads to spawn a watchdog on; see routes.zig's identical note.

    const query_result = sidecar_client.queryOnce(io, gpa, &child, "controllers", abs_root);

    // Stop the watchdog (if any) BEFORE touching `child` again below -- see
    // `sidecar_client.killOnTimeout`'s doc for why this ordering keeps
    // `child.kill`/`child.wait` single-threaded.
    done.set(io);
    if (watchdog) |t| t.join();

    const line = query_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            child.kill(io);
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", "sidecar/rails/analyze.rb", @errorName(err), false, .@"error", null, null);
            return none;
        },
    };
    defer gpa.free(line);

    const term = child.wait(io) catch |err| {
        try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", "sidecar/rails/analyze.rb", @errorName(err), false, .@"error", null, null);
        return none;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            var buf: [48]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "ruby exited {d}", .{code}) catch "ruby exited nonzero";
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", "sidecar/rails/analyze.rb", detail, false, .@"error", null, null);
            return none;
        },
        .signal, .stopped, .unknown => {
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", "sidecar/rails/analyze.rb", "sidecar terminated abnormally", false, .@"error", null, null);
            return none;
        },
    }

    const decoded = try decodeResponse(gpa, line, "app/controllers", blocker_list);
    return .{
        .actions = decoded.actions,
        .layouts = decoded.layouts,
        .before_actions = decoded.before_actions,
        .skip_before_actions = decoded.skip_before_actions,
        .parents = decoded.parents,
        .ruby = decoded.ruby,
    };
}

test "a sidecar response decodes into actions, preserving redirect/json flags" {
    const line =
        \\{"ok":true,"actions":[
        \\{"controller":"posts","action":"index","only_redirect":false,"renders_json":false,"line":2},
        \\{"controller":"admin/users","action":"create","only_redirect":true,"renders_json":false,"line":3}],
        \\"unresolved":[],
        \\"ruby":{"available":true,"version":"3.3.6"}}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res.actions);
    defer sidecar_client.freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 2), res.actions.len);
    try std.testing.expectEqualStrings("posts", res.actions[0].controller);
    try std.testing.expectEqualStrings("index", res.actions[0].action);
    try std.testing.expect(!res.actions[0].only_redirect);
    try std.testing.expect(!res.actions[0].renders_json);
    try std.testing.expectEqualStrings("admin/users", res.actions[1].controller);
    try std.testing.expect(res.actions[1].only_redirect);
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
    // The sidecar's own response, not a second `version_check.rb` spawn.
    try std.testing.expect(res.ruby.available);
    try std.testing.expectEqualStrings("3.3.6", res.ruby.version.?);
}

test "decodeResponse: an OOM at any point in a multi-row decode leaves no leak" {
    // Fix round 1, item 3 (task-2-fixes.md): review deleted decodeResponse's
    // partial-fill `errdefer` block outright and all 68 tests still passed
    // -- that guard was dead by this branch's standard. This test sweeps
    // EVERY allocation-failure point rather than hardcoding one `fail_index`:
    // the exact number of allocations `std.json.parseFromSlice` spends on
    // its internal arena before this function's own `gpa.alloc`/`dupeAction`
    // calls begin is a std.json implementation detail, not something this
    // test should hardcode and have silently stop meaning anything the next
    // time that shifts. Sweeping guarantees at least one iteration lands
    // squarely between two `dupeAction` calls -- i.e. genuinely "partway
    // through decoding a multi-row response", with one row's `ActionInfo`
    // already filled when the next allocation fails -- without this test
    // needing to know in advance which iteration that is.
    //
    // `std.testing.allocator`'s own leak detector is what actually proves
    // "no leak": every iteration runs allocations through it (via
    // `FailingAllocator`'s `internal_allocator`), and a missing `errdefer`
    // fails the WHOLE TEST through that detector -- not through an explicit
    // assertion this test has to write itself. See the mutation note in
    // task-2-fix-report.md for the observed red/green.
    // Includes a non-null "ruby" key (fix round, task-2-3-fixes.md item 1):
    // without one, `decodeRuby`'s `ruby.version` is always null and
    // `sidecar_client.freeRuby` -- called both by this test's own success
    // path AND by decodeResponse's `errdefer sidecar_client.freeRuby(gpa,
    // ruby);` on every later-allocation failure -- has nothing to release
    // either way, so a deleted `errdefer` would leak nothing and this sweep
    // would stay green regardless. A real version string gives every
    // failure index AFTER the ruby dupe (but before the sweep succeeds)
    // something the errdefer must actually free.
    //
    // Review fix round 1 (task-7 review, Important finding): the fixture
    // used to carry no "layouts" key at all, so `resp.layouts.len == 0` and
    // `gpa.alloc(LayoutInfo, 0)` never reaches the allocator vtable
    // (`std.mem.Allocator.allocBytesWithAlignment`'s documented zero-byte
    // shortcut) -- the `layouts` dupe/errdefer chain added alongside
    // `LayoutInfo` was never exercised by this sweep. Two rows below: one
    // with a non-null `value` (exercises the `controller` dupe, then the
    // `value` dupe and its own nested `errdefer`) and one with
    // `value: null` (exercises the `controller`-only dupe with `lfilled`
    // already at 1) -- so a missing `errdefer` on either dupe, or a wrong
    // `lfilled` bump, each have a failure index that would now leak.
    const line =
        \\{"ok":true,"actions":[
        \\{"controller":"posts","action":"index","only_redirect":false,"renders_json":false,"line":2},
        \\{"controller":"admin/users","action":"create","only_redirect":true,"renders_json":false,"line":3,
        \\ "redirects":[{"name":"user","args":["1"]},{"path":"/x"},
        \\ {"name":"stem","args":["1","2"],"path":"/both"},{"dynamic":true}]},
        \\{"controller":"comments","action":"destroy","only_redirect":false,"renders_json":true,"line":9}],
        \\"layouts":[
        \\{"controller":"pages","value":"marketing","disabled":false,"dynamic":false,"line":2},
        \\{"controller":"api","value":null,"disabled":true,"dynamic":false,"line":3}],
        \\"before_actions":[
        \\{"controller":"posts","name":"require_login","only":["index","show"],"except":[],"line":2},
        \\{"controller":"posts","dynamic":true,"line":3}],
        \\"skip_before_actions":[
        \\{"controller":"admin/users","name":"require_login","only":["create"],"except":[],"line":4}],
        \\"parents":[{"controller":"posts","parent":"application"},
        \\{"controller":"admin/users","parent":"application"}],
        \\"unresolved":[],
        \\"ruby":{"available":true,"version":"3.3.6"}}
    ;

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        // Safety valve: a real decode of this line needs on the rough order
        // of 10-20 allocations (JSON-parse arena chunks plus one `gpa.alloc`
        // and two `dupeAction` dupes per row). 1000 is generous headroom
        // against that drifting with a future std.json change, while still
        // catching an infinite-sweep regression (e.g. `decodeResponse`
        // somehow never reaching a real success) as a test failure rather
        // than a hang.
        if (fail_index > 1000) return error.SweepNeverReachedSuccess;

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
        defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

        if (decodeResponse(failing.allocator(), line, "app/controllers", &blocker_list)) |decoded| {
            defer freeDecoded(std.testing.allocator, decoded);
            // `fail_index` finally exceeded every allocation this decode
            // needs: confirm it decoded correctly one last time, then the
            // sweep is done -- every earlier index already ran under the
            // leak detector above.
            try std.testing.expectEqual(@as(usize, 3), decoded.actions.len);
            try std.testing.expectEqual(@as(usize, 2), decoded.layouts.len);
            try std.testing.expectEqual(@as(usize, 2), decoded.before_actions.len);
            try std.testing.expectEqual(@as(usize, 1), decoded.skip_before_actions.len);
            try std.testing.expectEqual(@as(usize, 2), decoded.parents.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "an ok:false response becomes one RAILS_CONTROLLERS_UNAVAILABLE blocker and zero actions" {
    const line =
        \\{"ok":false,"error":"boom: NoMethodError"}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res.actions);
    defer sidecar_client.freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 0), res.actions.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_UNAVAILABLE", blocker_list.items[0].code);
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "a malformed response line becomes one RAILS_CONTROLLERS_UNAVAILABLE blocker and zero actions" {
    const line = "not json";
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res.actions);
    defer sidecar_client.freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 0), res.actions.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_UNAVAILABLE", blocker_list.items[0].code);
}

test "an unrecognized unresolved code is not dropped: it folds into detail under a static fallback code" {
    const line =
        \\{"ok":true,"actions":[],"unresolved":[{"code":"RAILS_CONTROLLER_FUTURE_THING","detail":"whatever","line":3}]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res.actions);
    defer sidecar_client.freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLER_UNRESOLVED", blocker_list.items[0].code);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, "RAILS_CONTROLLER_FUTURE_THING") != null);
    try std.testing.expect(!blocker_list.items[0].integrity);
    try std.testing.expectEqual(blockers.Severity.warn, blocker_list.items[0].severity);
}

test "a recognized unresolved code (RAILS_CONTROLLER_PARSE_ERROR) becomes a blocker with that exact code" {
    const line =
        \\{"ok":true,"actions":[],"unresolved":[{"code":"RAILS_CONTROLLER_PARSE_ERROR","detail":"bad.rb: syntax error","line":7}]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res.actions);
    defer sidecar_client.freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLER_PARSE_ERROR", blocker_list.items[0].code);
    try std.testing.expectEqual(blockers.Severity.warn, blocker_list.items[0].severity);
    // Stage 4 Task 8b: `u.line` off the wire must reach `Blocker.line`, not
    // be dropped on the way in -- the third instance of that bug shape on
    // this feature (see the task brief).
    try std.testing.expectEqual(@as(?u64, 7), blocker_list.items[0].line);
}

// Discriminates the BLOCKER's own line, not a constant: an implementation
// that hardcodes `.line = null` passes every other test in this file, since
// none of them assert an unresolved entry's blocker carries a REAL,
// non-null line that differs from another one. This is the one that would
// catch it; the third case (no `line` key at all) proves the honest-null
// path still works, in the same test.
test "unresolved entries at different wire lines decode to different blocker.line values, and a lineless one is null" {
    const line =
        \\{"ok":true,"actions":[],"unresolved":[
        \\{"code":"RAILS_CONTROLLER_PARSE_ERROR","path":"a.rb","detail":"first","line":5},
        \\{"code":"RAILS_CONTROLLER_PARSE_ERROR","path":"b.rb","detail":"second","line":41},
        \\{"code":"RAILS_CONTROLLER_UNREADABLE","path":"c.rb","detail":"no line at all"}
        \\]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res.actions);
    defer sidecar_client.freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 3), blocker_list.items.len);
    try std.testing.expectEqual(@as(?u64, 5), blocker_list.items[0].line);
    try std.testing.expectEqual(@as(?u64, 41), blocker_list.items[1].line);
    try std.testing.expect(blocker_list.items[0].line != blocker_list.items[1].line);
    try std.testing.expectEqual(@as(?u64, null), blocker_list.items[2].line);
}

test "B1: an unresolved entry's own `path` becomes the blocker's `path`, not the shared directory `src_path`" {
    // Regression for final-fixes-B.md's B1: the controller blockers used to
    // put the DIRECTORY (`src_path`, e.g. "app/controllers") in `path` for
    // every finding, with the actual FILE buried inside `detail`'s text.
    // Exact-string equality on `.path` -- not merely `indexOf` on `.detail`
    // -- is what a reversion back to that shape would actually fail: an
    // `indexOf` check would still pass if the file happened to reappear
    // somewhere else in the string.
    const line =
        \\{"ok":true,"actions":[],"unresolved":[
        \\{"code":"RAILS_CONTROLLER_PARSE_ERROR","path":"app/controllers/posts_controller.rb","detail":"unexpected 'end'","line":3}
        \\]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res.actions);
    defer sidecar_client.freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("app/controllers/posts_controller.rb", blocker_list.items[0].path);
    try std.testing.expectEqualStrings("unexpected 'end' (line 3)", blocker_list.items[0].detail);
}

test "an unresolved entry with no `path` (older sidecar shape) falls back to the shared src_path" {
    const line =
        \\{"ok":true,"actions":[],"unresolved":[{"code":"RAILS_CONTROLLER_PARSE_ERROR","detail":"bad.rb: syntax error","line":7}]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res.actions);
    defer sidecar_client.freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqualStrings("app/controllers", blocker_list.items[0].path);
}

test "B2: RAILS_CONTROLLER_UNREADABLE is a recognized code, distinct from RAILS_CONTROLLER_PARSE_ERROR" {
    const line =
        \\{"ok":true,"actions":[],"unresolved":[
        \\{"code":"RAILS_CONTROLLER_UNREADABLE","path":"app/controllers/broken_controller.rb","detail":"Errno::EACCES: Permission denied","line":1}
        \\]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res.actions);
    defer sidecar_client.freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    // Exact code, not the `RAILS_CONTROLLER_UNRESOLVED` fallback -- proves
    // this code is in `known_unresolved_codes`, not merely tolerated.
    try std.testing.expectEqualStrings("RAILS_CONTROLLER_UNREADABLE", blocker_list.items[0].code);
    try std.testing.expectEqualStrings("app/controllers/broken_controller.rb", blocker_list.items[0].path);
    try std.testing.expectEqual(blockers.Severity.warn, blocker_list.items[0].severity);
}

test "decodeResponse: layouts[] decodes literal, disabled and dynamic shapes; absent layouts is empty" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"actions":[],"layouts":[
        \\{"controller":"pages","value":"marketing","disabled":false,"dynamic":false,"line":2},
        \\{"controller":"api","value":null,"disabled":true,"dynamic":false,"line":3},
        \\{"controller":"posts","value":null,"disabled":false,"dynamic":true,"line":4}
        \\],"unresolved":[],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, "app/controllers", &list);
    defer freeActions(gpa, d.actions);
    defer freeLayouts(gpa, d.layouts);
    defer sidecar_client.freeRuby(gpa, d.ruby);
    try std.testing.expectEqual(@as(usize, 3), d.layouts.len);
    const pages = findLayout(d.layouts, "pages").?;
    try std.testing.expectEqualStrings("marketing", pages.value.?);
    try std.testing.expect(!pages.disabled and !pages.dynamic);
    try std.testing.expect(findLayout(d.layouts, "api").?.disabled);
    try std.testing.expect(findLayout(d.layouts, "posts").?.dynamic);
    try std.testing.expectEqual(@as(u64, 4), findLayout(d.layouts, "posts").?.line);
    try std.testing.expect(findLayout(d.layouts, "nope") == null);

    const old = try decodeResponse(gpa, "{\"ok\":true,\"actions\":[],\"unresolved\":[]}", "app/controllers", &list);
    defer freeActions(gpa, old.actions);
    defer freeLayouts(gpa, old.layouts);
    defer sidecar_client.freeRuby(gpa, old.ruby);
    try std.testing.expectEqual(@as(usize, 0), old.layouts.len);
}

/// Test-only release for a whole `Decoded`. Spelled once so a field added to
/// `Decoded` cannot be silently left unfreed by half the tests in this file.
fn freeDecoded(gpa: Allocator, d: Decoded) void {
    freeActions(gpa, d.actions);
    freeLayouts(gpa, d.layouts);
    freeBeforeActions(gpa, d.before_actions);
    freeBeforeActions(gpa, d.skip_before_actions);
    freeParents(gpa, d.parents);
    sidecar_client.freeRuby(gpa, d.ruby);
}

test "decodeResponse: redirects[] and before_actions[] decode into owned copies" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"actions":[
        \\{"controller":"pages","action":"old","only_redirect":true,"renders_json":false,"line":9,
        \\ "redirects":[{"name":"about","args":[]}]},
        \\{"controller":"posts","action":"update","only_redirect":false,"renders_json":false,"line":14,
        \\ "redirects":[{"name":"post","args":["1"]},{"dynamic":true}]},
        \\{"controller":"posts","action":"index","only_redirect":false,"renders_json":false,"line":4}],
        \\"before_actions":[
        \\{"controller":"posts","name":"require_login","only":["index"],"except":[],"line":2},
        \\{"controller":"posts","dynamic":true,"line":3}],
        \\"unresolved":[],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, "app/controllers", &list);
    defer freeDecoded(gpa, d);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);

    const old = find(d.actions, "pages", "old").?;
    try std.testing.expectEqual(@as(usize, 1), old.redirects.len);
    try std.testing.expectEqualStrings("about", old.redirects[0].name.?);
    try std.testing.expectEqual(@as(usize, 0), old.redirects[0].args.len);
    try std.testing.expect(!old.redirects[0].dynamic);

    // Source order is load-bearing: Task 4 takes the FIRST non-dynamic
    // redirect as the island's post-mutation target, so a decode that
    // reordered or deduplicated these would silently pick the wrong one.
    const update = find(d.actions, "posts", "update").?;
    try std.testing.expectEqual(@as(usize, 2), update.redirects.len);
    try std.testing.expectEqualStrings("post", update.redirects[0].name.?);
    try std.testing.expectEqual(@as(usize, 1), update.redirects[0].args.len);
    try std.testing.expectEqualStrings("1", update.redirects[0].args[0]);
    try std.testing.expect(update.redirects[1].dynamic);
    try std.testing.expect(update.redirects[1].name == null);

    // An action entry the sidecar sent WITHOUT a `redirects` key at all --
    // an empty list, not a missing field, is what every consumer sees.
    try std.testing.expectEqual(@as(usize, 0), find(d.actions, "posts", "index").?.redirects.len);

    try std.testing.expectEqual(@as(usize, 2), d.before_actions.len);
    try std.testing.expectEqualStrings("posts", d.before_actions[0].controller);
    try std.testing.expectEqualStrings("require_login", d.before_actions[0].name.?);
    try std.testing.expectEqual(@as(usize, 1), d.before_actions[0].only.len);
    try std.testing.expectEqualStrings("index", d.before_actions[0].only[0]);
    try std.testing.expectEqual(@as(usize, 0), d.before_actions[0].except.len);
    try std.testing.expect(!d.before_actions[0].dynamic);
    try std.testing.expectEqual(@as(u64, 2), d.before_actions[0].line);
    try std.testing.expect(d.before_actions[1].dynamic);
    try std.testing.expect(d.before_actions[1].name == null);
}

test "decodeResponse: a sidecar that predates the two new fields decodes them empty, not absent" {
    // Backward compatibility is the whole reason both fields are defaulted
    // on the wire structs: `ZIGAPAGOS_RUNTIME_DIR` can point at an installed
    // runtime older than this binary, and that response must still decode
    // into the same shape every consumer reads -- an empty list, never a
    // decode error and never a missing field.
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"actions":[
        \\{"controller":"posts","action":"index","only_redirect":false,"renders_json":false,"line":2}],
        \\"unresolved":[]}
    ;
    const d = try decodeResponse(gpa, line, "app/controllers", &list);
    defer freeDecoded(gpa, d);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(usize, 1), d.actions.len);
    try std.testing.expectEqual(@as(usize, 0), d.actions[0].redirects.len);
    try std.testing.expectEqual(@as(usize, 0), d.before_actions.len);
    // Fix round 1: the same tolerance for the three fields THAT round added.
    // An older sidecar sends no chain and no skips, and `guardsFor` then
    // reports each controller's own filters -- the pre-fix answer, not a
    // crash and not a wrong one.
    try std.testing.expectEqual(@as(usize, 0), d.skip_before_actions.len);
    try std.testing.expectEqual(@as(usize, 0), d.parents.len);
    try std.testing.expect(d.actions[0].redirects.len == 0);

    // And a redirect entry from a sidecar that predates `path` decodes with
    // `path == null`, not with an empty string that would read as "redirects
    // to the site root".
    const older_redirect =
        \\{"ok":true,"actions":[
        \\{"controller":"pages","action":"old","only_redirect":true,"renders_json":false,
        \\ "redirects":[{"name":"about","args":[]}],"line":9}],"unresolved":[]}
    ;
    const d2 = try decodeResponse(gpa, older_redirect, "app/controllers", &list);
    defer freeDecoded(gpa, d2);
    try std.testing.expect(d2.actions[0].redirects[0].path == null);
}

test "guards: only wins over except, and both empty guards every action" {
    const unscoped: BeforeAction = .{ .controller = "posts", .name = "require_login" };
    try std.testing.expect(guards(unscoped, "index"));
    try std.testing.expect(guards(unscoped, "destroy"));

    const only: BeforeAction = .{ .controller = "posts", .name = "require_login", .only = &.{ "index", "show" } };
    try std.testing.expect(guards(only, "index"));
    try std.testing.expect(guards(only, "show"));
    try std.testing.expect(!guards(only, "destroy"));

    const except: BeforeAction = .{ .controller = "posts", .name = "set_post", .except = &.{"destroy"} };
    try std.testing.expect(guards(except, "index"));
    try std.testing.expect(!guards(except, "destroy"));

    // Rails evaluates `only:` and ignores `except:` when both are given, and
    // an implementation that ANDed the two would answer `false` for `index`
    // here while an implementation that ORed them would answer `true` for
    // `destroy` -- this pair discriminates all three readings.
    const both: BeforeAction = .{
        .controller = "posts",
        .name = "require_login",
        .only = &.{"index"},
        .except = &.{"index"},
    };
    try std.testing.expect(guards(both, "index"));
    try std.testing.expect(!guards(both, "destroy"));

    // A filter this walk could not read names no action and guards nothing
    // it can be asked about: `guards` must not report a dynamic filter as
    // covering every action just because both scope lists are empty.
    const dynamic: BeforeAction = .{ .controller = "posts", .dynamic = true };
    try std.testing.expect(!guards(dynamic, "index"));
}

test "looksLikeAuthGuard: A7's four substrings, case-insensitively, and nothing else" {
    try std.testing.expect(looksLikeAuthGuard(.{ .controller = "c", .name = "require_login" }));
    try std.testing.expect(looksLikeAuthGuard(.{ .controller = "c", .name = "authenticate_user!" }));
    try std.testing.expect(looksLikeAuthGuard(.{ .controller = "c", .name = "require_signed_in" }));
    try std.testing.expect(looksLikeAuthGuard(.{ .controller = "c", .name = "current_user_required" }));
    // Case-insensitive, ASCII: a filter is a Ruby symbol, so this is only
    // ever about an author writing `Require_Login`, never about Unicode.
    try std.testing.expect(looksLikeAuthGuard(.{ .controller = "c", .name = "Require_LOGIN" }));

    try std.testing.expect(!looksLikeAuthGuard(.{ .controller = "c", .name = "set_post" }));
    try std.testing.expect(!looksLikeAuthGuard(.{ .controller = "c", .name = "set_locale" }));
    // A dynamic filter has no name to read. Answering `true` here would
    // raise A7's finding on every controller with a block filter; answering
    // `false` is what the field means -- see `BeforeAction.dynamic`'s doc
    // for why that direction is the honest one.
    try std.testing.expect(!looksLikeAuthGuard(.{ .controller = "c", .dynamic = true }));
}

test "decodeResponse: the two-file app -- a filter on ApplicationController guards posts#index" {
    // Fix round 1, I-1. This is the commonest Rails auth idiom there is, and
    // before the `parents` edge existed the filter arrived keyed
    // `application` while the route names `posts`, so nothing could
    // attribute it and the page shipped silently public. The wire fixture is
    // exactly what `analyze.rb` answers for a two-file app.
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"actions":[
        \\{"controller":"posts","action":"index","only_redirect":false,"renders_json":false,"line":2}],
        \\"before_actions":[
        \\{"controller":"application","name":"authenticate_user!","only":[],"except":[],"line":2}],
        \\"parents":[{"controller":"posts","parent":"application"}],
        \\"unresolved":[],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, "app/controllers", &list);
    defer freeDecoded(gpa, d);

    const set: FilterSet = .{
        .before_actions = d.before_actions,
        .skips = d.skip_before_actions,
        .parents = d.parents,
    };
    const guard = authGuardFor(set, "posts", "index").?;
    // The DECLARING controller, not the one asked about -- that is what the
    // finding message has to name.
    try std.testing.expectEqualStrings("application", guard.controller);
    try std.testing.expectEqualStrings("authenticate_user!", guard.name.?);

    // Without the edge the same filter is invisible from `posts`, which is
    // the pre-fix behaviour this test exists to keep out.
    const chainless: FilterSet = .{ .before_actions = d.before_actions };
    try std.testing.expect(authGuardFor(chainless, "posts", "index") == null);
    // And it is still attributable from the controller that declares it.
    try std.testing.expect(authGuardFor(chainless, "application", "index") != null);
}

test "guardsFor: own filters first, then the chain; skips suppress; cycles and depth terminate" {
    const filters = [_]BeforeAction{
        .{ .controller = "application", .name = "authenticate_user!" },
        .{ .controller = "application", .name = "set_locale" },
        .{ .controller = "admin/base", .name = "require_admin" },
        .{ .controller = "admin/users", .name = "load_record", .only = &.{"show"} },
    };
    const parents = [_]ParentEdge{
        .{ .controller = "admin/users", .parent = "admin/base" },
        .{ .controller = "admin/base", .parent = "application" },
    };
    const set: FilterSet = .{ .before_actions = &filters, .parents = &parents };

    // Own controller first, then up the chain, and `only:` still applies at
    // every level.
    var it = guardsFor(set, "admin/users", "show");
    try std.testing.expectEqualStrings("load_record", it.next().?.name.?);
    try std.testing.expectEqualStrings("require_admin", it.next().?.name.?);
    try std.testing.expectEqualStrings("authenticate_user!", it.next().?.name.?);
    try std.testing.expectEqualStrings("set_locale", it.next().?.name.?);
    try std.testing.expect(it.next() == null);

    // `load_record` is `only: [:show]`, so it drops out for `index` -- the
    // chain walk does not bypass `guards`.
    var idx = guardsFor(set, "admin/users", "index");
    try std.testing.expectEqualStrings("require_admin", idx.next().?.name.?);

    // A skip anywhere in the chain suppresses the inherited filter for the
    // actions the SKIP's own scope covers, and only those.
    const skips = [_]BeforeAction{
        .{ .controller = "admin/users", .name = "authenticate_user!", .only = &.{"show"} },
    };
    const with_skips: FilterSet = .{ .before_actions = &filters, .skips = &skips, .parents = &parents };
    try std.testing.expect(authGuardFor(with_skips, "admin/users", "show") == null);
    try std.testing.expect(authGuardFor(with_skips, "admin/users", "index") != null);
    // A skip declared OUTSIDE this controller's chain must not suppress
    // anything here.
    const foreign = [_]BeforeAction{
        .{ .controller = "pages", .name = "authenticate_user!" },
    };
    const foreign_set: FilterSet = .{ .before_actions = &filters, .skips = &foreign, .parents = &parents };
    try std.testing.expect(authGuardFor(foreign_set, "admin/users", "show") != null);
    // A dynamic skip names nothing and suppresses nothing -- over-reporting
    // the guard is the direction A7 requires.
    const dyn_skip = [_]BeforeAction{.{ .controller = "admin/users", .dynamic = true }};
    const dyn_set: FilterSet = .{ .before_actions = &filters, .skips = &dyn_skip, .parents = &parents };
    try std.testing.expect(authGuardFor(dyn_set, "admin/users", "show") != null);

    // A cycle terminates instead of looping, and each controller's filters
    // are still yielded exactly once.
    const cyc = [_]ParentEdge{
        .{ .controller = "a", .parent = "b" },
        .{ .controller = "b", .parent = "a" },
    };
    const cyc_filters = [_]BeforeAction{
        .{ .controller = "a", .name = "one" },
        .{ .controller = "b", .name = "two" },
    };
    var cit = guardsFor(.{ .before_actions = &cyc_filters, .parents = &cyc }, "a", "index");
    try std.testing.expectEqualStrings("one", cit.next().?.name.?);
    try std.testing.expectEqualStrings("two", cit.next().?.name.?);
    try std.testing.expect(cit.next() == null);

    // A chain longer than the cap truncates rather than spinning; the walk
    // covers exactly `max_parent_chain` controllers.
    var deep_parents: [max_parent_chain + 4]ParentEdge = undefined;
    var deep_filters: [max_parent_chain + 5]BeforeAction = undefined;
    var names: [max_parent_chain + 5][2]u8 = undefined;
    for (0..max_parent_chain + 5) |i| {
        names[i] = .{ 'c', @intCast('0' + i) };
        deep_filters[i] = .{ .controller = &names[i], .name = "f" };
    }
    for (0..max_parent_chain + 4) |i| {
        deep_parents[i] = .{ .controller = &names[i], .parent = &names[i + 1] };
    }
    var dit = guardsFor(.{ .before_actions = &deep_filters, .parents = &deep_parents }, &names[0], "index");
    var seen: usize = 0;
    while (dit.next()) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, max_parent_chain), seen);

    // A controller with no edge at all still reports its own filters.
    var lone = guardsFor(.{ .before_actions = &filters }, "application", "index");
    try std.testing.expectEqualStrings("authenticate_user!", lone.next().?.name.?);
}

test "guardsFor: a skip declared ABOVE the filter it names does not suppress it" {
    // Fix round 2, N2. `raise: false` makes this parse, and Rails still runs
    // the filter: the skip ran against a callback chain that did not yet
    // contain it. Suppressing on a name match anywhere in the chain reported
    // this page unguarded.
    const filters = [_]BeforeAction{
        .{ .controller = "posts", .name = "authenticate_user!" },
    };
    const skips = [_]BeforeAction{
        .{ .controller = "application", .name = "authenticate_user!" },
    };
    const parents = [_]ParentEdge{.{ .controller = "posts", .parent = "application" }};
    const set: FilterSet = .{ .before_actions = &filters, .skips = &skips, .parents = &parents };
    try std.testing.expect(authGuardFor(set, "posts", "index") != null);

    // The same two declarations the other way up: the filter on the parent,
    // the skip on the child, which IS the placement Rails honours.
    const inherited = [_]BeforeAction{
        .{ .controller = "application", .name = "authenticate_user!" },
    };
    const child_skip = [_]BeforeAction{
        .{ .controller = "posts", .name = "authenticate_user!" },
    };
    try std.testing.expect(authGuardFor(.{
        .before_actions = &inherited,
        .skips = &child_skip,
        .parents = &parents,
    }, "posts", "index") == null);

    // Same class declares both -- "at or below" includes "at", and within one
    // class source order is what decides (fix round 3, NEW-2). The skip AFTER
    // the filter removes it...
    const same_filter = [_]BeforeAction{
        .{ .controller = "posts", .name = "authenticate_user!", .line = 2 },
    };
    const same_skip_after = [_]BeforeAction{
        .{ .controller = "posts", .name = "authenticate_user!", .line = 3 },
    };
    try std.testing.expect(authGuardFor(.{
        .before_actions = &same_filter,
        .skips = &same_skip_after,
        .parents = &parents,
    }, "posts", "index") == null);

    // ...and the same two lines the other way round do NOT: `raise: false`
    // makes it parse, but line 2 skipped a callback chain that did not yet
    // hold the filter, so Rails runs it. Reporting this page public is the
    // defect NEW-2 names.
    const same_skip_before = [_]BeforeAction{
        .{ .controller = "posts", .name = "authenticate_user!", .line = 1 },
    };
    try std.testing.expect(authGuardFor(.{
        .before_actions = &same_filter,
        .skips = &same_skip_before,
        .parents = &parents,
    }, "posts", "index") != null);

    // Equal lines cannot both be true, and the same declaration cannot skip
    // itself -- `<=` keeps that from reading as a suppression.
    try std.testing.expect(authGuardFor(.{
        .before_actions = &same_filter,
        .skips = &same_filter,
        .parents = &parents,
    }, "posts", "index") != null);

    // Line order is a WITHIN-CLASS rule only: a skip in the subclass removes
    // an inherited filter no matter which line either sits on.
    const parent_filter = [_]BeforeAction{
        .{ .controller = "application", .name = "authenticate_user!", .line = 99 },
    };
    const child_skip_low = [_]BeforeAction{
        .{ .controller = "posts", .name = "authenticate_user!", .line = 1 },
    };
    try std.testing.expect(authGuardFor(.{
        .before_actions = &parent_filter,
        .skips = &child_skip_low,
        .parents = &parents,
    }, "posts", "index") == null);
}

test "decodeResponse: a literal-string redirect decodes as `path`, distinct from a stem and from dynamic" {
    // Fix round 1, I-3.
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"actions":[
        \\{"controller":"pages","action":"old","only_redirect":true,"renders_json":false,"line":9,
        \\ "redirects":[{"path":"/about"},{"name":"root","args":[]},{"dynamic":true}]}],
        \\"unresolved":[]}
    ;
    const d = try decodeResponse(gpa, line, "app/controllers", &list);
    defer freeDecoded(gpa, d);

    const r = d.actions[0].redirects;
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqualStrings("/about", r[0].path.?);
    try std.testing.expect(r[0].name == null and !r[0].dynamic);
    // The three variants stay apart: a stem carries no path, and a dynamic
    // entry carries neither.
    try std.testing.expect(r[1].path == null);
    try std.testing.expectEqualStrings("root", r[1].name.?);
    try std.testing.expect(r[2].path == null and r[2].name == null and r[2].dynamic);
}

test "dupeActions/dupeBeforeActions copy the whole graph, and free every allocation on OOM" {
    const gpa = std.testing.allocator;
    const src_actions = [_]ActionInfo{
        .{
            .controller = "pages",
            .action = "old",
            .only_redirect = true,
            .redirects = &.{.{ .name = "about", .args = &.{} }},
        },
        .{
            .controller = "posts",
            .action = "update",
            .redirects = &.{
                .{ .name = "post", .args = &.{"1"} },
                .{ .path = "/about" },
                // All three fields at once: the only shape in which EVERY
                // per-field `errdefer` in `dupeRedirects` has a later
                // allocation that can fail. Without it the `path` errdefer
                // is unreachable and a mutation deleting it survives.
                .{ .name = "stem", .args = &.{ "1", "2" }, .path = "/both" },
                .{ .dynamic = true },
            },
        },
    };
    const src_filters = [_]BeforeAction{
        .{ .controller = "posts", .name = "require_login", .only = &.{"index"}, .line = 2 },
        .{ .controller = "posts", .dynamic = true, .line = 3 },
    };

    const actions = try dupeActions(gpa, &src_actions);
    defer freeActions(gpa, actions);
    const filters = try dupeBeforeActions(gpa, &src_filters);
    defer freeBeforeActions(gpa, filters);

    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("post", actions[1].redirects[0].name.?);
    try std.testing.expectEqualStrings("1", actions[1].redirects[0].args[0]);
    // A COPY, not an alias: `Discovery` outlives the `controllers.Result`
    // these came from, so a shallow copy would leave it pointing at freed
    // memory the moment `discover`'s `defer freeResult` runs.
    try std.testing.expect(actions[1].redirects[0].args[0].ptr != src_actions[1].redirects[0].args[0].ptr);
    try std.testing.expectEqualStrings("/about", actions[1].redirects[1].path.?);
    try std.testing.expect(actions[1].redirects[1].path.?.ptr != src_actions[1].redirects[1].path.?.ptr);
    try std.testing.expectEqualStrings("/both", actions[1].redirects[2].path.?);
    try std.testing.expectEqualStrings("stem", actions[1].redirects[2].name.?);
    try std.testing.expect(actions[1].redirects[3].dynamic);
    try std.testing.expectEqualStrings("index", filters[0].only[0]);
    try std.testing.expect(filters[0].only[0].ptr != src_filters[0].only[0].ptr);
    try std.testing.expect(filters[1].dynamic);
    try std.testing.expect(filters[1].name == null);

    // Same sweep discipline as `decodeResponse`'s: every allocation index in
    // turn, with `std.testing.allocator`'s leak detector -- not an explicit
    // assertion -- proving each `errdefer` on the nested redirect/arg dupes
    // actually releases what it claimed.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 200) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        if (dupeActions(failing.allocator(), &src_actions)) |out| {
            freeActions(gpa, out);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
    fail_index = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 200) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        if (dupeBeforeActions(failing.allocator(), &src_filters)) |out| {
            freeBeforeActions(gpa, out);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }

    // Fix round 1: the same sweep for the inheritance edges. Two rows, so at
    // least one failure index lands between the `controller` and `parent`
    // dupes of the second one, with the first already filled.
    const src_parents = [_]ParentEdge{
        .{ .controller = "posts", .parent = "application" },
        .{ .controller = "admin/users", .parent = "admin/base" },
    };
    const owned_parents = try dupeParents(gpa, &src_parents);
    defer freeParents(gpa, owned_parents);
    try std.testing.expectEqualStrings("admin/base", owned_parents[1].parent);
    try std.testing.expect(owned_parents[1].parent.ptr != src_parents[1].parent.ptr);

    fail_index = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 200) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        if (dupeParents(failing.allocator(), &src_parents)) |out| {
            freeParents(gpa, out);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "find matches on (controller, action) pair, not either alone" {
    const line =
        \\{"ok":true,"actions":[
        \\{"controller":"posts","action":"index","only_redirect":false,"renders_json":false,"line":2},
        \\{"controller":"posts","action":"show","only_redirect":true,"renders_json":false,"line":6},
        \\{"controller":"comments","action":"index","only_redirect":false,"renders_json":true,"line":9}],
        \\"unresolved":[]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res.actions);
    defer sidecar_client.freeRuby(std.testing.allocator, res.ruby);

    const show = find(res.actions, "posts", "show");
    try std.testing.expect(show != null);
    try std.testing.expect(show.?.only_redirect);

    const comments_index = find(res.actions, "comments", "index");
    try std.testing.expect(comments_index != null);
    try std.testing.expect(comments_index.?.renders_json);

    // Same action name under a different controller must NOT match --
    // pins that the lookup keys on the PAIR, not `action` alone.
    try std.testing.expect(find(res.actions, "comments", "show") == null);
    // Same controller, nonexistent action.
    try std.testing.expect(find(res.actions, "posts", "destroy") == null);
}

test "discoverControllers spawns the real Ruby sidecar and recovers PostsController#index" {
    // Needs `ruby` on PATH (mise) and to run from the repo root, same
    // requirement `routes.zig`'s equivalent live-spawn test documents.
    // Degrades to a RAILS_CONTROLLERS_UNAVAILABLE blocker whose detail is
    // the bare `@errorName` `FileNotFound` (this file does not special-case
    // that error the way `routes.zig` attributes it to "not found on PATH"
    // -- see the module doc: every spawn-side failure collapses to one
    // code/detail-from-errorName here) -- not a hard failure -- when ruby
    // genuinely isn't installed; any OTHER degradation is a real
    // regression.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put(runtime_dir_env, "runtime");

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try discoverControllers(io, gpa, app_dir, "tests/migrate/rails-sample", &blocker_list, &env_map);
    defer freeResult(gpa, result);

    if (result.actions.len == 0 and blocker_list.items.len > 0) {
        if (blocker_list.items.len == 1 and
            std.mem.eql(u8, blocker_list.items[0].code, "RAILS_CONTROLLERS_UNAVAILABLE") and
            std.mem.indexOf(u8, blocker_list.items[0].detail, "FileNotFound") != null)
            return error.SkipZigTest;
        std.debug.print("discoverControllers degraded unexpectedly: {s}: {s}\n", .{
            blocker_list.items[blocker_list.items.len - 1].code,
            blocker_list.items[blocker_list.items.len - 1].detail,
        });
        return error.UnexpectedControllerDiscoveryDegradation;
    }

    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
    const posts_index = find(result.actions, "posts", "index");
    try std.testing.expect(posts_index != null);
    try std.testing.expect(!posts_index.?.only_redirect);
    try std.testing.expect(!posts_index.?.renders_json);

    // The real Ruby process that answered this request knows its own
    // version -- see `sidecar_client.zig`'s module doc on why this is
    // captured from the sidecar's own response rather than a second spawn.
    try std.testing.expect(result.ruby.available);
    try std.testing.expect(result.ruby.version != null);
    try std.testing.expect(result.ruby.version.?.len > 0);
}

test "discoverControllers: no app/controllers/ appends RAILS_CONTROLLERS_MISSING and finds zero actions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    // No env vars matter for this path -- `discoverControllers` returns
    // before ever reading `environ_map` (the app/controllers check comes
    // first) -- so an empty map is enough.
    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();

    const result = try discoverControllers(io, gpa, tmp.dir, ".", &blocker_list, &env_map);
    defer freeResult(gpa, result);

    try std.testing.expectEqual(@as(usize, 0), result.actions.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_MISSING", blocker_list.items[0].code);
    try std.testing.expect(!blocker_list.items[0].integrity);
    try std.testing.expectEqual(blockers.Severity.@"error", blocker_list.items[0].severity);
    // `app/controllers/` absence is caught client-side (openDir) before
    // Ruby ever spawns -- no interpreter to vouch for.
    try std.testing.expect(!result.ruby.available);
}

test "discoverControllers: app/controllers/ present but unreadable yields RAILS_CONTROLLERS_UNAVAILABLE, not silence" {
    // Regression for B3 (final-fixes-B.md): the whole-branch review's
    // degradation matrix found that a `chmod 000 app/controllers` used to
    // sail past the old `root.access` check (existence alone, not
    // readability) and on into the sidecar, whose own `Dir.glob` swallows
    // the permission error -- the run then reported ZERO actions and ZERO
    // controller-related blockers, indistinguishable from a genuinely
    // controller-less app. `openDir` (not `access`) is what actually
    // attempts to read the directory and surfaces the failure here.
    //
    // Same reliability caveat as inventory.zig's identical chmod tests:
    // skipped at comptime where `Permissions` isn't POSIX mode bits, and at
    // runtime if stripping permissions doesn't actually block the open
    // (root, or a sandboxed filesystem that ignores mode bits).
    if (!Io.Dir.Permissions.has_executable_bit) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var controllers_dir = try tmp.dir.createDirPathOpen(io, "app/controllers", .{ .open_options = .{ .iterate = true } });
    try controllers_dir.setPermissions(io, .fromMode(0));
    defer {
        controllers_dir.setPermissions(io, .fromMode(0o755)) catch {};
        controllers_dir.close(io);
    }

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();

    const result = try discoverControllers(io, gpa, tmp.dir, ".", &blocker_list, &env_map);
    defer freeResult(gpa, result);

    if (blocker_list.items.len == 0) {
        // Permission enforcement didn't actually block the open in this
        // environment -- nothing to assert.
        return error.SkipZigTest;
    }

    try std.testing.expectEqual(@as(usize, 0), result.actions.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_UNAVAILABLE", blocker_list.items[0].code);
    try std.testing.expectEqualStrings("app/controllers", blocker_list.items[0].path);
    try std.testing.expect(!blocker_list.items[0].integrity);
    try std.testing.expectEqual(blockers.Severity.@"error", blocker_list.items[0].severity);
    try std.testing.expect(!result.ruby.available);
}

test "discoverControllers: ZIGAPAGOS_RUBY pointing at a nonexistent binary yields RAILS_CONTROLLERS_UNAVAILABLE" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put(ruby_env, "/nonexistent/ruby-binary-does-not-exist-xyz");
    try env_map.put(runtime_dir_env, "runtime");

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try discoverControllers(io, gpa, app_dir, "tests/migrate/rails-sample", &blocker_list, &env_map);
    defer freeResult(gpa, result);

    try std.testing.expectEqual(@as(usize, 0), result.actions.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_UNAVAILABLE", blocker_list.items[0].code);
    // F3 (phase-2-review.md): `path` must name the sidecar script, never
    // the machine-specific `ZIGAPAGOS_RUBY` value -- see `routes.zig`'s
    // identical assertion for why. The interpreter is still named, but
    // only in free-text `detail`.
    try std.testing.expectEqualStrings("sidecar/rails/analyze.rb", blocker_list.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, "/nonexistent/ruby-binary-does-not-exist-xyz") != null);
    try std.testing.expect(!blocker_list.items[0].integrity);
    // The spawn itself failed (ENOENT) -- no interpreter ever ran.
    try std.testing.expect(!result.ruby.available);
}

test "discoverControllers: ZIGAPAGOS_RUNTIME_DIR with no sidecar/rails/analyze.rb yields RAILS_CONTROLLERS_UNAVAILABLE" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var runtime_tmp = std.testing.tmpDir(.{});
    defer runtime_tmp.cleanup();
    var runtime_dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir_abs_n = try runtime_tmp.dir.realPath(io, &runtime_dir_buf);
    const runtime_dir_abs = runtime_dir_buf[0..runtime_dir_abs_n];

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put(runtime_dir_env, runtime_dir_abs);

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try discoverControllers(io, gpa, app_dir, "tests/migrate/rails-sample", &blocker_list, &env_map);
    defer freeResult(gpa, result);

    try std.testing.expectEqual(@as(usize, 0), result.actions.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_UNAVAILABLE", blocker_list.items[0].code);
    // R12 (fix round 1, task-8 review): `path` is the machine-stable
    // literal, never the absolute `script_path` this run actually tried --
    // that string is machine-specific and would make the same app produce
    // different report bytes on two machines. It is not lost: it moves into
    // `detail`, which carries no determinism contract.
    try std.testing.expectEqualStrings("sidecar/rails/analyze.rb", blocker_list.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, runtime_dir_abs) != null);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, "FileNotFound") != null);
    try std.testing.expect(!blocker_list.items[0].integrity);
    try std.testing.expect(!result.ruby.available);
}
