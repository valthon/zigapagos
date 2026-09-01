//! The Zig client for the Rails template-fragment sidecar op
//! (`runtime/sidecar/rails/analyze.rb`'s `"templates"` op, backed by
//! `runtime/sidecar/rails/templates.rb`'s Prism walk): given a list of
//! root-relative view paths, spawns a persistent-protocol process for
//! exactly one request/response pair and turns the answer into one owned
//! NODE STREAM per template.
//!
//! Modelled on `controllers.zig` end to end -- same `sidecar_client`
//! spawn/watchdog/query/kill/wait sequence, same `Environ.Map` parameter,
//! same absolute-`root` contract, same `decodeResponse` split so the JSON
//! half is unit-testable without spawning anything. It is a THIRD process,
//! not a request folded into `routes`'/`controllers`' own: see
//! `controllers.zig`'s module doc for the full ruling -- `queryOnce` closes
//! the child's stdin immediately after writing its one request, which is
//! what lets `analyze.rb`'s loop treat that close as an ordinary shutdown,
//! and neither sibling exposes a live `child` past its own return. Sharing
//! would mean changing one of those two things; spawning is the sanctioned
//! alternative.
//!
//! **The degradation table is one code wide.** Every sidecar-side failure --
//! `ZIGAPAGOS_RUNTIME_DIR` unset, no `analyze.rb`, an unresolvable app root,
//! a spawn/exit/response failure, a malformed line, a well-formed
//! `{"ok":false,...}` -- appends exactly ONE `RAILS_TEMPLATES_UNAVAILABLE`
//! blocker (`integrity = false`, `severity = .@"error"`) and returns an
//! empty `templates` slice. There is no second "missing" code the way
//! `controllers.zig` has `RAILS_CONTROLLERS_MISSING`: this op is handed an
//! explicit path list by its caller rather than discovering a directory of
//! its own, so "there is nothing to look at" is not a failure here at all --
//! it is an empty `paths` list, which returns early WITHOUT spawning Ruby
//! and without appending anything. An empty view list is a fact about the
//! app, not a gap in this run's evidence.
//!
//! `integrity = false` for the same reason `routes.zig`/`controllers.zig`
//! give: a run that recovers no fragment streams still has a complete,
//! trustworthy `inventory.walk` result; what it loses is the LATER
//! presentation analysis layered on top. `severity = .@"error"` because
//! nothing here ran -- every template this run would otherwise have a node
//! stream for is missing that evidence entirely, which is the same
//! wholesale-failure story the two sibling ops' own `*_UNAVAILABLE` codes
//! carry.
//!
//! **A per-entry `error`/`unreadable` is NOT a blocker here.** `handle_
//! templates` answers per path: `{path, nodes}`, `{path, error, line}` (the
//! ERB/Ruby parse failed) or `{path, unreadable}` (the file could not be
//! read, or resolved outside the app root). The latter two ride back on
//! `Template.error_message`/`error_line`/`unreadable` and are deliberately
//! left as data rather than folded into the blocker list -- unlike
//! `controllers.zig`, which does turn its own per-file `unresolved[]`
//! entries into blockers. The difference is what the operator has to DO
//! about it: a controller the walk could not read silently weakens a later
//! classification rule, so it has to be announced. A template that does not
//! parse is a QUESTION for the operator -- retain this view as-is, or block
//! the migration on it -- and questions are what `findings.zig` produces.
//! Answering it here, before the finding machinery has looked at what the
//! template actually is, would both prejudge it and double-report it once
//! that pass runs.
//!
//! `i18n_errors[]` (R16) is carried the same way, for the mirror-image
//! reason: it is NOT a question -- a locale file that will not parse has
//! nothing to decide about -- but the blocker for it belongs where the
//! findings it qualifies are derived (`rails.zig`'s `discover`), so this
//! file decodes it and hands it on. What it must never be is DROPPED: an
//! unloadable `config/locales/en.yml` leaves an empty translation table, and
//! then every `t()` key in the app comes back `missing: true`.
//!
//! **An unrecognised wire `kind` decodes as `.unknown`, never dropped.**
//! `Kind` is a closed enum this build compiles against; `templates.rb` is
//! free to grow a new one. Dropping the node would silently shorten the
//! stream and shift every position-sensitive consumer after it, so the node
//! survives with its line/col/code intact and only its classification
//! degrades -- the same forward-compatibility rule `controllers.zig`'s
//! `staticUnresolvedCode` follows for a blocker code it does not know.
//!
//! std-only, like every file in `src/cli/rails/`: no `@import` escapes this
//! directory, and `fatal.*` handling stays migrate.zig's job.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const blockers = @import("blockers.zig");
const sidecar_client = @import("sidecar_client.zig");

/// Every classification `runtime/sidecar/rails/templates.rb` emits as a
/// node's `kind`, plus `unknown` -- which is BOTH a wire value that file
/// sends itself (a call it walked but could not classify) and this decoder's
/// fallback for a wire value this build has never heard of. Collapsing those
/// two into one tag is deliberate: from a consumer's point of view they are
/// the same fact ("there is a code fragment here whose meaning is not
/// recovered"), and the node's `code`/`name` carry whatever detail either
/// case actually has.
///
/// Closed, not an open string, so Stage 1's `findings.zig` switches over it
/// exhaustively and a new sidecar kind shows up as a compile error there the
/// day this enum grows -- rather than as a string comparison nobody updated.
pub const Kind = enum {
    yield,
    yield_named,
    content_for,
    render_partial,
    render_partial_locals,
    render_dynamic,
    route_helper,
    route_helper_dynamic,
    link_to,
    asset,
    importmap,
    csrf,
    i18n,
    literal,
    form,
    form_field,
    errors,
    request_state,
    ivar,
    local,
    control,
    block_else,
    block_end,
    turbo_frame,
    turbo_stream,
    component_root,
    /// An element carrying `data-controller`, found in a TEXT run rather than
    /// in a Ruby fragment: Rails writes Stimulus, Turbo frames and React
    /// roots as ordinary HTML, so `templates.rb` scans the runs for them (see
    /// its element-scan section) and closes each into a region with a
    /// `block_end` whose `code` is the close TAG. `name` is the
    /// `data-controller` value VERBATIM -- it may name several identifiers --
    /// and `value` is the tag name.
    stimulus,
    /// An element carrying `data-vue-component`. Vue is out of scope (spec
    /// decision 7), so this node exists to be REPORTED -- as a blocker and a
    /// finding -- never to be built from.
    vue_root,
    raw,
    unknown,
};

/// What a `component_root`'s prop VALUE was before it was rendered to text.
///
/// A React prop's type is part of it: `points: 3` has to reach the target as
/// `.points = 3`, not `"3"`, because the island's `Props` interface is
/// typechecked and a number arriving as a string fails the build with an
/// error about the generated file rather than about the template. Every
/// OTHER `attrs` consumer wants the rendered HTML attribute and is served by
/// the default, which is why this rides on the existing pair instead of
/// forking `attrs` in two.
pub const ValueKind = enum { string, number, boolean, null };

/// Contract 3 (caller-buffer): takes no allocator and allocates nothing.
/// Unrecognised names degrade to `.string` rather than erroring, for the
/// reason `kindFromWire` degrades to `.unknown`: `templates.rb` may grow a
/// type this build has never heard of, and refusing the attribute would
/// shorten a props list the target is typechecked against. The same
/// `inline for` keeps the enum the single source of truth.
pub fn valueKindFromWire(s: []const u8) ValueKind {
    inline for (@typeInfo(ValueKind).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, s)) return @field(ValueKind, f.name);
    }
    return .string;
}

/// Contract 3 (caller-buffer): takes no allocator and allocates nothing --
/// the returned `Kind` is a plain value and `s` is only read. The `inline
/// for` unrolls to one `std.mem.eql` per tag, so the tag list stays the
/// single source of truth (adding a `Kind` automatically makes its wire
/// spelling decodable) instead of a hand-maintained parallel table that can
/// drift from the enum next to it.
pub fn kindFromWire(s: []const u8) Kind {
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, s)) return @field(Kind, f.name);
    }
    // Not an error and not a dropped node -- see the module doc.
    return .unknown;
}

/// One `key => value` pair off a node's `attrs`. A wire value of JSON `null`
/// decodes as `""` rather than being modelled as an optional: `templates.rb`
/// sends `null` for an option whose value it could read the KEY of but not
/// the value (a non-literal), and every consumer of `attrs` cares about
/// which keys are present far more than about telling "absent value" from
/// "empty value". An optional here would push that distinction into every
/// call site to no benefit. Contract 2 (owned-result): both strings are
/// fresh `gpa` allocations, released by `freeResult`.
pub const Attr = struct {
    key: []const u8,
    value: []const u8,
    /// What the value WAS before it was rendered to text. `.string` for every
    /// pair the sidecar sends as a two-element array -- which is every pair
    /// but a `component_root`'s props -- so a consumer that does not care
    /// about types reads exactly what it always read, and a sidecar predating
    /// the third element decodes unchanged.
    kind: ValueKind = .string,
};

/// One entry in a template's node stream, in source order.
///
/// `text` non-null marks a TEXT RUN -- literal template output between code
/// fragments. `line` stays REAL there: the wire node for a text run carries
/// `t`/`text`/`line`, and that line is the template line the run starts on,
/// which is exactly why a consumer may walk the whole stream reading only
/// `line`. Every OTHER field is unset (`kind` is `.unknown`, `col` is 0,
/// the strings empty/null, the flags false) and must not be read -- there
/// was nothing else on the wire to decode them from. `text == null` marks a
/// CODE fragment, where the rest of the struct is meaningful.
///
/// This is a nullable field rather than a tagged union because the wire
/// shape isn't one either (`templates.rb` emits a flat object discriminated
/// by `t`), and because a union would force every consumer walking the
/// stream to switch even when it only cares about, say, `line`. That the
/// one field such a consumer reads is also the one field a text run really
/// carries is what keeps it safe.
///
/// Contract 2 (owned-result): `text`, `code`, `name`, `value`, every element
/// of `args`, and both halves of every `attrs` entry are fresh `gpa`
/// allocations independent of the decoded response's JSON arena;
/// `freeResult` is the release.
pub const Node = struct {
    /// Non-null exactly for a text run; see the type doc.
    text: ?[]const u8,
    /// `.unknown` for a wire kind this build does not recognise -- the node
    /// still rides through with its position and source text.
    kind: Kind,
    /// 1-based, in TEMPLATE coordinates (`templates.rb` maps Prism's
    /// generated-program positions back through its own line map).
    line: u64,
    col: u64,
    /// True when this fragment was written as an output tag (`<%= %>`).
    output: bool,
    /// The fragment's own source text, as written in the template.
    code: []const u8,
    name: ?[]const u8,
    value: ?[]const u8,
    args: []const []const u8,
    attrs: []const Attr,
    /// Two readings, one per family of node -- both of them "the thing this
    /// node names was looked for and not found". On an `i18n` node: the key
    /// resolved to no translation in the loaded locale. On an ELEMENT node
    /// (`stimulus`, `vue_root`, an HTML-form `turbo_frame`/`component_root`):
    /// no close tag was found at the same Ruby block depth, so the region has
    /// no extent and nothing that needs one may be offered for it (B11).
    missing: bool,
    /// The construct was recognised but one of its operands is not a
    /// literal, so no name/value could be recovered statically.
    dynamic: bool,
};

/// One `templates[]` entry: either a recovered node stream, or the reason
/// there isn't one. Exactly one of `nodes` being non-empty, `error_message`
/// being set, or `unreadable` being set describes any given entry -- the
/// other two are empty/null. (A genuinely empty template is the one
/// ambiguity: it has no nodes and no failure, which is the honest answer.)
///
/// `error_message`/`unreadable` are carried as DATA, not as blockers -- see
/// the module doc for why that is this file's job to hold and
/// `findings.zig`'s to interpret.
///
/// Contract 2 (owned-result): `path`, every node (see `Node`'s doc),
/// `error_message` and `unreadable` are fresh `gpa` allocations; released by
/// `freeResult`.
pub const Template = struct {
    path: []const u8,
    /// Empty when `error_message`/`unreadable` is set.
    nodes: []Node,
    /// The ERB/Ruby parse failure `templates.rb` reported for this file.
    error_message: ?[]const u8,
    /// The template line that failure points at, when it has one.
    error_line: ?u64,
    /// Why the file could not be read at all (`Errno::ENOENT: ...`, `outside
    /// root`, `path is not a string`). Distinct from `error_message`: the
    /// file was never parsed, so there is no line to point at.
    unreadable: ?[]const u8,
    /// Stage 5 presentation facts recovered by the sidecar from literal HTML
    /// text runs. Dynamic markup is absent rather than guessed.
    parity_h1: ?[]const u8 = null,
    parity_h1_node: ?usize = null,
    parity_links: [][]const u8 = &.{},
    parity_link_nodes: []usize = &.{},
};

/// One `config/locales/**` file `RailsI18n.load` could not turn into a
/// translation table, as `Table#errors` recorded it: a YAML syntax error, a
/// read failure, anything `YAML.safe_load` raised. The file is SKIPPED, not
/// fatal -- the run continues against whatever other locale files loaded --
/// which is exactly why it has to be reported: a skipped `en.yml` leaves an
/// empty table, and every `t()` key in the app then looks missing.
///
/// Carried as DATA for the same reason `Template.unreadable` is (see the
/// module doc): this client's job is to decode, and `rails.zig`'s `discover`
/// is where the blocker belongs, because it is also where the FINDINGS that
/// this fact qualifies are derived.
///
/// Contract 2 (owned-result): both strings are fresh `gpa` allocations,
/// released by `freeResult`.
pub const I18nError = struct {
    /// Root-relative (`analyze.rb` strips the root prefix before sending).
    path: []const u8,
    /// The Ruby exception class and its first message line.
    detail: []const u8,
};

/// `discoverTemplates`'s return.
///
/// `locale` is the I18n locale `analyze.rb`'s `RailsI18n.load` settled on
/// for this run (null when it could not determine one) -- it belongs on the
/// result rather than on each template because one request analyses every
/// path against ONE loaded translation table, so `Node.value`/`missing` on
/// every `i18n` node in every template are answers about this one locale.
///
/// `ruby` is this op's own half of `discovery.ruby`; see `routes.zig`'s
/// `Result.ruby` doc for why it is only a half (`rails.zig`'s `combineRuby`
/// ORs the ops' answers together before either reaches a consumer).
pub const Result = struct {
    /// Owned; released by `freeResult`.
    templates: []Template,
    /// Owned when non-null; released by `freeResult`.
    locale: ?[]const u8,
    /// The locale files that failed to load for this run. Owned; released by
    /// `freeResult`. Empty on every degradation path, and empty in the
    /// ordinary case where every locale file parsed.
    i18n_errors: []I18nError,
    ruby: sidecar_client.Ruby,
};

/// Env var naming the Ruby interpreter to spawn; `ruby` on `PATH` when unset
/// or blank. See `routes.zig`'s identical constant for the full rationale.
const ruby_env = "ZIGAPAGOS_RUBY";

/// The same variable `routes.zig`/`controllers.zig` re-declare from
/// `src/cli/release.zig`; see that file's comment for why this is a
/// re-declaration, not an import.
const runtime_dir_env = "ZIGAPAGOS_RUNTIME_DIR";

/// The single degradation code this file has (see the module doc). A
/// `Blocker.code` must be a static literal -- `blockers.free` never frees it
/// -- so it lives here rather than being built per site.
const unavailable_code = "RAILS_TEMPLATES_UNAVAILABLE";

/// The `path` every degradation that is about the SIDECAR ITSELF (rather
/// than about a specific file this run named) reports. Matches
/// `controllers.zig`'s per-site choice.
const sidecar_path = "sidecar/rails/analyze.rb";

/// The `t: "text"` discriminator off the wire.
const wire_text = "text";

/// One node object as `runtime/sidecar/rails/templates.rb`'s `emit` writes
/// it. Only the keys relevant to a given node are present -- a text run
/// carries `t`/`text`/`line` and nothing else, an `i18n` node carries no
/// `args`/`attrs`, and so on -- so every field except the discriminator `t`
/// has a default. `kind` is `?[]const u8` (not defaulted to a string)
/// because its absence and the literal `"unknown"` are different wire facts
/// even though `kindFromWire` maps them to the same tag; the optional keeps
/// the wire struct an honest mirror.
const WireNode = struct {
    t: []const u8,
    text: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    line: u64 = 0,
    col: u64 = 0,
    output: bool = false,
    code: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    /// Elements are optional because `literal_args` emits a nil for an
    /// argument it could not read as a literal; `dupeNode` decodes those as
    /// `""` (see `Attr`'s doc for the same call on the value side).
    args: []const ?[]const u8 = &.{},
    /// A `[key, value]` array per attribute, with a nullable value --
    /// `templates.rb` emits pairs, not an object, so key order survives the
    /// round trip. A `component_root`'s props add a THIRD element naming the
    /// value's type (`ValueKind`); every other node sends two. Typed as a
    /// slice-of-slices rather than a tuple because std.json has no
    /// fixed-arity array type; `dupeNode` tolerates a pair of any length
    /// (see there).
    attrs: []const []const ?[]const u8 = &.{},
    missing: bool = false,
    dynamic: bool = false,
};

/// One `templates[]` entry as `analyze.rb`'s `handle_templates` writes it:
/// `{path, nodes}` | `{path, error, line}` | `{path, unreadable}`. Only
/// `path` is always present.
const WireTemplate = struct {
    path: []const u8,
    nodes: []const WireNode = &.{},
    @"error": ?[]const u8 = null,
    /// The line `@"error"` points at. Only meaningful alongside it.
    line: ?u64 = null,
    unreadable: ?[]const u8 = null,
    parity_h1: ?[]const u8 = null,
    parity_h1_node: ?usize = null,
    parity_links: []const []const u8 = &.{},
    parity_link_nodes: []const usize = &.{},
};

/// One `i18n_errors[]` entry as `analyze.rb` writes it from `Table#errors`.
/// Both fields default so a truncated entry decodes rather than failing the
/// whole response -- the same forward-compatibility stance `WireNode` takes.
const WireI18nError = struct {
    path: []const u8 = "",
    detail: []const u8 = "",
};

const WireResponse = struct {
    ok: bool,
    locale: ?[]const u8 = null,
    templates: []const WireTemplate = &.{},
    @"error": ?[]const u8 = null,
    /// R16: this used to be deliberately UNdeclared, dropped by
    /// `ignore_unknown_fields`, on the grounds that a `config/locales/*`
    /// load failure "belongs to whichever pass reports on i18n coverage".
    /// That pass is `findings.zig`, in this same run, reading this same
    /// `Result` -- so dropping the field did not defer the report, it
    /// deleted it, and left the coverage pass confidently blaming N missing
    /// keys on the templates that used them. Defaulted so a response
    /// predating the field (or a hand-written test literal) still decodes.
    i18n_errors: []const WireI18nError = &.{},
    // This op's own half of `discovery.ruby`; optional so a hand-written
    // `ok:false`/malformed test literal that predates the field still
    // decodes, same as in `routes.zig`/`controllers.zig`.
    ruby: ?sidecar_client.WireRuby = null,
};

/// Contract 2 (owned-result) helper for `dupeTemplate`: every string on the
/// returned `Node` is a fresh `gpa` allocation independent of `wn`'s backing
/// JSON arena. On a mid-construction failure every piece already allocated
/// is released before the error propagates -- the element-then-array
/// `errdefer` shape `rails.zig`'s `dupeNameList` documents, applied twice
/// here (once for `args`, once for `attrs`) because both are nested owned
/// slices.
///
/// A null wire `text`/`code` decodes as `""` rather than propagating the
/// optional: `Node.code` is non-optional (every code fragment has source
/// text, even if `templates.rb` could only recover an empty slice for it)
/// and `Node.text`'s nullness is reserved for the text-run discriminator
/// (see `Node`'s doc), so it must be driven by `t`, never by whether the
/// `text` key happened to be present.
fn dupeNode(gpa: Allocator, wn: WireNode) Allocator.Error!Node {
    const is_text = std.mem.eql(u8, wn.t, wire_text);

    const text: ?[]const u8 = if (is_text) try gpa.dupe(u8, wn.text orelse "") else null;
    errdefer if (text) |t| gpa.free(t);

    const code = try gpa.dupe(u8, wn.code orelse "");
    errdefer gpa.free(code);

    const name: ?[]const u8 = if (wn.name) |n| try gpa.dupe(u8, n) else null;
    errdefer if (name) |n| gpa.free(n);

    const value: ?[]const u8 = if (wn.value) |v| try gpa.dupe(u8, v) else null;
    errdefer if (value) |v| gpa.free(v);

    const args = try gpa.alloc([]const u8, wn.args.len);
    var args_filled: usize = 0;
    errdefer {
        for (args[0..args_filled]) |a| gpa.free(a);
        gpa.free(args);
    }
    for (wn.args, 0..) |a, i| {
        // A nil argument (`literal_args` could not read this one as a
        // literal) becomes `""` -- see `Attr`'s doc for the reasoning.
        args[i] = try gpa.dupe(u8, a orelse "");
        args_filled = i + 1;
    }

    const attrs = try gpa.alloc(Attr, wn.attrs.len);
    var attrs_filled: usize = 0;
    errdefer {
        for (attrs[0..attrs_filled]) |a| freeAttr(gpa, a);
        gpa.free(attrs);
    }
    for (wn.attrs, 0..) |pair, i| {
        // Length-tolerant on purpose. A `component_root`'s props carry a
        // THIRD element (the `ValueKind`) and every other node carries two,
        // so the arity is genuinely variable -- and a future/garbled shape
        // must not index out of bounds either. A missing half reads as the
        // same `""` a JSON `null` does; a missing type reads as `.string`,
        // which is what every pair meant before the type existed.
        const key_src: ?[]const u8 = if (pair.len > 0) pair[0] else null;
        const val_src: ?[]const u8 = if (pair.len > 1) pair[1] else null;
        const kind_src: ?[]const u8 = if (pair.len > 2) pair[2] else null;
        const key = try gpa.dupe(u8, key_src orelse "");
        errdefer gpa.free(key);
        const val = try gpa.dupe(u8, val_src orelse "");
        attrs[i] = .{
            .key = key,
            .value = val,
            .kind = if (kind_src) |k| valueKindFromWire(k) else .string,
        };
        attrs_filled = i + 1;
    }

    return .{
        .text = text,
        .kind = if (is_text) .unknown else kindFromWire(wn.kind orelse ""),
        .line = wn.line,
        .col = wn.col,
        .output = wn.output,
        .code = code,
        .name = name,
        .value = value,
        .args = args,
        .attrs = attrs,
        .missing = wn.missing,
        .dynamic = wn.dynamic,
    };
}

fn freeAttr(gpa: Allocator, a: Attr) void {
    gpa.free(a.key);
    gpa.free(a.value);
}

fn freeNode(gpa: Allocator, n: Node) void {
    if (n.text) |t| gpa.free(t);
    gpa.free(n.code);
    if (n.name) |v| gpa.free(v);
    if (n.value) |v| gpa.free(v);
    for (n.args) |a| gpa.free(a);
    gpa.free(n.args);
    for (n.attrs) |a| freeAttr(gpa, a);
    gpa.free(n.attrs);
}

/// Contract 2 (owned-result) helper for `decodeResponse`: see `Template`'s
/// doc for the ownership story. Same element-then-array `errdefer` shape as
/// `dupeNode`, one level up.
fn dupeTemplate(gpa: Allocator, wt: WireTemplate) Allocator.Error!Template {
    const path = try gpa.dupe(u8, wt.path);
    errdefer gpa.free(path);

    const error_message: ?[]const u8 = if (wt.@"error") |e| try gpa.dupe(u8, e) else null;
    errdefer if (error_message) |e| gpa.free(e);

    const unreadable: ?[]const u8 = if (wt.unreadable) |u| try gpa.dupe(u8, u) else null;
    errdefer if (unreadable) |u| gpa.free(u);

    const parity_h1: ?[]const u8 = if (wt.parity_h1) |h| try gpa.dupe(u8, h) else null;
    errdefer if (parity_h1) |h| gpa.free(h);
    const parity_links = try gpa.alloc([]const u8, wt.parity_links.len);
    var links_filled: usize = 0;
    errdefer {
        for (parity_links[0..links_filled]) |link| gpa.free(link);
        gpa.free(parity_links);
    }
    for (wt.parity_links, 0..) |link, i| {
        parity_links[i] = try gpa.dupe(u8, link);
        links_filled = i + 1;
    }
    const parity_link_nodes = try gpa.dupe(usize, wt.parity_link_nodes);
    errdefer gpa.free(parity_link_nodes);

    const nodes = try gpa.alloc(Node, wt.nodes.len);
    var filled: usize = 0;
    errdefer {
        for (nodes[0..filled]) |n| freeNode(gpa, n);
        gpa.free(nodes);
    }
    for (wt.nodes, 0..) |wn, i| {
        nodes[i] = try dupeNode(gpa, wn);
        filled = i + 1;
    }

    return .{
        .path = path,
        .nodes = nodes,
        .error_message = error_message,
        // Only carried alongside an actual error: `line` is a bare integer
        // on the wire with no meaning of its own, and a stray one on an
        // otherwise-successful entry would read as "this template failed at
        // line N" to anything that checks `error_line` first.
        .error_line = if (wt.@"error" != null) wt.line else null,
        .unreadable = unreadable,
        .parity_h1 = parity_h1,
        .parity_h1_node = wt.parity_h1_node,
        .parity_links = parity_links,
        .parity_link_nodes = parity_link_nodes,
    };
}

fn freeTemplate(gpa: Allocator, t: Template) void {
    gpa.free(t.path);
    for (t.nodes) |n| freeNode(gpa, n);
    gpa.free(t.nodes);
    if (t.error_message) |e| gpa.free(e);
    if (t.unreadable) |u| gpa.free(u);
    if (t.parity_h1) |h| gpa.free(h);
    for (t.parity_links) |link| gpa.free(link);
    gpa.free(t.parity_links);
    gpa.free(t.parity_link_nodes);
}

/// Contract 2 counterpart to `discoverTemplates`/`decodeResponse`: releases
/// every owned piece of a `Result` -- each template (path, node stream and
/// every string inside it, error/unreadable text), the `templates` slice
/// itself, `locale`, and `ruby.version` -- in one call, mirroring
/// `controllers.zig`'s `freeResult`. Safe on a degraded result: every
/// early-return path returns empty slices and null optionals, all of which
/// this walks to nothing.
pub fn freeResult(gpa: Allocator, r: Result) void {
    for (r.templates) |t| freeTemplate(gpa, t);
    gpa.free(r.templates);
    if (r.locale) |l| gpa.free(l);
    freeI18nErrors(gpa, r.i18n_errors);
    sidecar_client.freeRuby(gpa, r.ruby);
}

fn freeI18nError(gpa: Allocator, e: I18nError) void {
    gpa.free(e.path);
    gpa.free(e.detail);
}

/// Contract 2 counterpart to `Result.i18n_errors`, split out of `freeResult`
/// because `rails.zig`'s `discover` releases that ONE field on its own: the
/// other two owned halves are moved onto the `Discovery` it returns, exactly
/// as it already does for `ruby`. See that call site's comment.
pub fn freeI18nErrors(gpa: Allocator, list: []I18nError) void {
    for (list) |e| freeI18nError(gpa, e);
    gpa.free(list);
}

/// Decodes one sidecar response LINE into an owned `Result`. Split out from
/// `discoverTemplates` so the JSON half is unit-testable without spawning
/// anything, exactly as `controllers.zig`/`routes.zig` do.
///
/// Contract 2 (owned-result): see `Template`/`Node`'s docs for the per-field
/// ownership story. `parsed.deinit()` frees the JSON tree the result was
/// decoded from before this function returns, so nothing in the returned
/// slice may alias it; `freeResult` is the matching release.
///
/// A malformed line and a well-formed `{"ok":false,...}` both collapse to a
/// single `RAILS_TEMPLATES_UNAVAILABLE` blocker and an empty `templates`
/// slice (module doc). Per-entry `error`/`unreadable` do NOT become blockers
/// -- they ride back on the `Template` for `findings.zig` to interpret.
///
/// `ruby` is decoded independent of `ok`, same reasoning as the sibling
/// clients: an `{"ok":false,...}` response still came from a Ruby process
/// that genuinely ran and answered, and `analyze.rb` stamps `RUBY_INFO` on
/// every `handle_templates` response either way. Only a line this function
/// could not decode AT ALL has no `ruby` to read, and falls back to
/// `available: false`.
fn decodeResponse(
    gpa: Allocator,
    line: []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error!Result {
    var parsed = std.json.parseFromSlice(WireResponse, gpa, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try blockers.append(gpa, blocker_list, unavailable_code, sidecar_path, @errorName(err), false, .@"error", null, null);
            return .{ .templates = &.{}, .locale = null, .i18n_errors = &.{}, .ruby = .{ .available = false, .version = null } };
        },
    };
    defer parsed.deinit();
    const resp = parsed.value;

    const ruby = try sidecar_client.decodeRuby(gpa, resp.ruby);
    errdefer sidecar_client.freeRuby(gpa, ruby);

    if (!resp.ok) {
        try blockers.append(gpa, blocker_list, unavailable_code, sidecar_path, resp.@"error" orelse "sidecar reported failure", false, .@"error", null, null);
        return .{ .templates = &.{}, .locale = null, .i18n_errors = &.{}, .ruby = ruby };
    }

    const locale: ?[]const u8 = if (resp.locale) |l| try gpa.dupe(u8, l) else null;
    errdefer if (locale) |l| gpa.free(l);

    // Same element-then-array `errdefer` shape as the two nested slices in
    // `dupeNode`: `filled` is what keeps a mid-loop OOM from freeing memory
    // that was never allocated.
    const i18n_errors = try gpa.alloc(I18nError, resp.i18n_errors.len);
    var i18n_filled: usize = 0;
    errdefer {
        for (i18n_errors[0..i18n_filled]) |e| freeI18nError(gpa, e);
        gpa.free(i18n_errors);
    }
    for (resp.i18n_errors, 0..) |we, i| {
        const path = try gpa.dupe(u8, we.path);
        errdefer gpa.free(path);
        const detail = try gpa.dupe(u8, we.detail);
        i18n_errors[i] = .{ .path = path, .detail = detail };
        i18n_filled = i + 1;
    }

    const templates = try gpa.alloc(Template, resp.templates.len);
    var filled: usize = 0;
    errdefer {
        for (templates[0..filled]) |t| freeTemplate(gpa, t);
        gpa.free(templates);
    }
    for (resp.templates, 0..) |wt, i| {
        templates[i] = try dupeTemplate(gpa, wt);
        filled = i + 1;
    }

    return .{ .templates = templates, .locale = locale, .i18n_errors = i18n_errors, .ruby = ruby };
}

/// Contract 2 (owned-result): every string reachable from the returned
/// `Result` is a fresh `gpa` allocation (see `Template`/`Node`/`Result`'s
/// docs); `freeResult` is the single matching release.
///
/// `paths` are root-relative view paths -- `analyze.rb`'s `handle_templates`
/// rejects anything else per entry (an absolute path, or one that escapes
/// the root, comes back as `unreadable: "outside root"` rather than being
/// read). `root_path` may be relative; it is resolved to an absolute path
/// before it goes on the wire, because the sidecar joins it as-is against
/// its OWN cwd otherwise.
///
/// An EMPTY `paths` list returns immediately: no Ruby is spawned and no
/// blocker is appended. That is not a degradation -- an app with no views
/// for this pass to analyse has nothing to report about, and spawning an
/// interpreter to be told so would cost ~100ms to learn nothing. This is the
/// case `controllers.zig` would call `RAILS_CONTROLLERS_MISSING`; it isn't
/// one here because the caller, not this function, decided what to look at.
///
/// Every OTHER failure mode -- Ruby not found, the runtime dir/sidecar
/// script not found, an unresolvable root, a spawn/exit/response failure, a
/// malformed or `ok:false` response -- appends exactly one
/// `RAILS_TEMPLATES_UNAVAILABLE` blocker (`integrity = false`, `severity =
/// .@"error"`) and returns an empty result with `ruby.available = false`
/// (there is no interpreter to vouch for on any of those paths). This
/// function's own error return stays `Allocator.Error` only: everything else
/// degrades rather than propagating, matching both sibling clients.
///
/// `environ_map` is threaded down the same way `routes.zig`'s
/// `discoverRoutes` receives it -- see that function's doc.
pub fn discoverTemplates(
    io: Io,
    gpa: Allocator,
    root_path: []const u8,
    paths: []const []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
    environ_map: *const std.process.Environ.Map,
) Allocator.Error!Result {
    // Every degradation branch below returns this literally -- Ruby/the
    // sidecar never ran on any of them, so `ruby.available` is
    // unconditionally `false` here, same as the sibling clients' identical
    // `none`. The success path (the final `decodeResponse` call) overrides
    // it with whatever the sidecar's own response reported.
    const none: Result = .{ .templates = &.{}, .locale = null, .i18n_errors = &.{}, .ruby = .{ .available = false, .version = null } };

    // Nothing to ask about: return before the interpreter, and before any
    // blocker. See the doc above for why this is not a degradation.
    if (paths.len == 0) return none;

    const ruby_path = environ_map.get(ruby_env) orelse "ruby";

    const runtime_dir_raw = environ_map.get(runtime_dir_env);
    const runtime_dir = if (runtime_dir_raw) |v| std.mem.trim(u8, v, " \t\r\n") else "";
    if (runtime_dir.len == 0) {
        try blockers.append(gpa, blocker_list, unavailable_code, sidecar_path, "ZIGAPAGOS_RUNTIME_DIR is not set", false, .@"error", null, null);
        return none;
    }

    const script_path = try std.fs.path.join(gpa, &.{ runtime_dir, "sidecar", "rails", "analyze.rb" });
    defer gpa.free(script_path);

    var script_abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const script_abs_n = Io.Dir.cwd().realPathFile(io, script_path, &script_abs_buf) catch |err| {
        // R12: `Blocker.path` is documented app-root-relative and feeds the
        // discovery report, so two machines analysing the same app must
        // produce the same bytes for it. `script_path` is
        // `$ZIGAPAGOS_RUNTIME_DIR` joined -- absolute on any real install --
        // so it cannot go here. The static literal does; the path actually
        // attempted moves into free-text `detail`, which carries no
        // determinism contract and is where a machine-specific string
        // belongs (same split as the spawn branch below, which keeps
        // `ruby_path` out of `path` for the identical reason).
        var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s}: {t}", .{ script_path, err }) catch @errorName(err);
        try blockers.append(gpa, blocker_list, unavailable_code, sidecar_path, detail, false, .@"error", null, null);
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
            try blockers.append(gpa, blocker_list, unavailable_code, ".", detail, false, .@"error", null, null);
            return none;
        },
    };
    defer gpa.free(abs_root);

    var child = std.process.spawn(io, .{
        .argv = &.{ ruby_path, script_abs },
        .stdin = .pipe,
        .stdout = .pipe,
        // stderr inherits the parent so a Ruby crash/backtrace is visible in
        // the build log, same as the sibling clients.
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // `path` names the sidecar script, not `ruby_path` -- a
            // machine-specific interpreter path must not reach a field
            // documented "relative to the app root" (F3, see
            // `controllers.zig`'s identical branch). The interpreter is
            // still named, in free-text `detail` instead.
            var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "interpreter '{s}': {t}", .{ ruby_path, err }) catch @errorName(err);
            try blockers.append(gpa, blocker_list, unavailable_code, sidecar_path, detail, false, .@"error", null, null);
            return none;
        },
    };

    var done: Io.Event = .unset;
    const watchdog: ?std.Thread = if (comptime !builtin.single_threaded)
        std.Thread.spawn(.{}, sidecar_client.killOnTimeout, .{ io, &child, &done }) catch null
    else
        null; // -Dsingle-threaded has no threads to spawn a watchdog on; see routes.zig's identical note.

    const query_result = sidecar_client.queryOnceTemplates(io, gpa, &child, abs_root, paths);

    // Stop the watchdog (if any) BEFORE touching `child` again below -- see
    // `sidecar_client.killOnTimeout`'s doc for why this ordering keeps
    // `child.kill`/`child.wait` single-threaded.
    done.set(io);
    if (watchdog) |t| t.join();

    const line = query_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            child.kill(io);
            try blockers.append(gpa, blocker_list, unavailable_code, sidecar_path, @errorName(err), false, .@"error", null, null);
            return none;
        },
    };
    defer gpa.free(line);

    const term = child.wait(io) catch |err| {
        try blockers.append(gpa, blocker_list, unavailable_code, sidecar_path, @errorName(err), false, .@"error", null, null);
        return none;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            var buf: [48]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "ruby exited {d}", .{code}) catch "ruby exited nonzero";
            try blockers.append(gpa, blocker_list, unavailable_code, sidecar_path, detail, false, .@"error", null, null);
            return none;
        },
        .signal, .stopped, .unknown => {
            try blockers.append(gpa, blocker_list, unavailable_code, sidecar_path, "sidecar terminated abnormally", false, .@"error", null, null);
            return none;
        },
    }

    return decodeResponse(gpa, line, blocker_list);
}

test "decodeResponse: a node stream decodes with kinds, positions, args and attrs; unknown kind degrades" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"locale":"en","templates":[
        \\{"path":"app/views/posts/index.html.erb","nodes":[
        \\{"t":"text","text":"<h1>","line":1},
        \\{"t":"code","kind":"i18n","line":1,"col":5,"output":true,"code":"t(\".heading\")","name":"posts.index.heading","value":"Posts"},
        \\{"t":"code","kind":"link_to","line":2,"col":1,"output":true,"code":"link_to \"Home\", root_path","name":"root","args":["Home"],"attrs":[["class","x"]]},
        \\{"t":"code","kind":"something_new","line":3,"col":1,"output":false,"code":"zzz"}
        \\]},
        \\{"path":"app/views/posts/broken.html.erb","error":"unexpected end","line":4},
        \\{"path":"app/views/posts/gone.html.erb","unreadable":"Errno::ENOENT"}
        \\],"i18n_errors":[],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, &list);
    defer freeResult(gpa, d);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqualStrings("en", d.locale.?);
    try std.testing.expectEqual(@as(usize, 3), d.templates.len);
    const t0 = d.templates[0];
    try std.testing.expectEqual(@as(usize, 4), t0.nodes.len);
    try std.testing.expectEqualStrings("<h1>", t0.nodes[0].text.?);
    try std.testing.expectEqual(Kind.i18n, t0.nodes[1].kind);
    try std.testing.expectEqualStrings("Posts", t0.nodes[1].value.?);
    try std.testing.expectEqual(@as(u64, 5), t0.nodes[1].col);
    try std.testing.expectEqual(Kind.link_to, t0.nodes[2].kind);
    try std.testing.expectEqualStrings("Home", t0.nodes[2].args[0]);
    try std.testing.expectEqualStrings("class", t0.nodes[2].attrs[0].key);
    try std.testing.expectEqual(Kind.unknown, t0.nodes[3].kind);
    try std.testing.expectEqualStrings("unexpected end", d.templates[1].error_message.?);
    try std.testing.expectEqual(@as(u64, 4), d.templates[1].error_line.?);
    try std.testing.expectEqualStrings("Errno::ENOENT", d.templates[2].unreadable.?);
}

// The brief's own decode test above asserts `attrs[0].key`; these pin the
// two facts a decoder can get wrong while still passing it -- the node
// stream's ORDER (a text run is not dropped or reordered relative to the
// code fragments around it) and the null-value rule on both `args` and
// `attrs`. Without these, a `dupeNode` that skipped nil args entirely (a
// tempting "filter out the unreadable ones" shortcut) would shorten `args`
// and go unnoticed.
test "decodeResponse: a nil arg and a nil attr value each decode to an empty string, keeping arity" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"locale":null,"templates":[{"path":"a.html.erb","nodes":[
        \\{"t":"code","kind":"link_to","line":1,"col":1,"output":true,"code":"link_to x, y","name":null,"args":["Home",null],"attrs":[["class","x"],["data-turbo",null]]}
        \\]}],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, &list);
    defer freeResult(gpa, d);
    try std.testing.expectEqual(@as(?[]const u8, null), d.locale);
    const n = d.templates[0].nodes[0];
    try std.testing.expectEqual(@as(usize, 2), n.args.len);
    try std.testing.expectEqualStrings("Home", n.args[0]);
    try std.testing.expectEqualStrings("", n.args[1]);
    try std.testing.expectEqual(@as(usize, 2), n.attrs.len);
    try std.testing.expectEqualStrings("x", n.attrs[0].value);
    try std.testing.expectEqualStrings("data-turbo", n.attrs[1].key);
    try std.testing.expectEqualStrings("", n.attrs[1].value);
    // `name: null` on the wire stays null -- it is NOT coerced to "" the way
    // an args/attrs member is, because a consumer asking "did this node
    // recover a name" has to be able to tell.
    try std.testing.expectEqual(@as(?[]const u8, null), n.name);
}

test "decodeResponse: a text run is null-kinded and keeps its position in the stream" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"templates":[{"path":"a.html.erb","nodes":[
        \\{"t":"code","kind":"yield","line":1,"col":1,"output":true,"code":"yield"},
        \\{"t":"text","text":" middle ","line":2},
        \\{"t":"code","kind":"block_end","line":3,"col":1,"output":false,"code":"end"}
        \\]}],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, &list);
    defer freeResult(gpa, d);
    const nodes = d.templates[0].nodes;
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
    try std.testing.expectEqual(Kind.yield, nodes[0].kind);
    try std.testing.expect(nodes[0].text == null);
    try std.testing.expectEqualStrings(" middle ", nodes[1].text.?);
    try std.testing.expectEqual(Kind.block_end, nodes[2].kind);
    // A successful entry carries no error line even though `error_line` and
    // the wire's `line` key share a name -- pins `dupeTemplate`'s
    // "only alongside an actual error" rule.
    try std.testing.expectEqual(@as(?u64, null), d.templates[0].error_line);
    try std.testing.expectEqual(@as(?[]const u8, null), d.templates[0].error_message);
}

test "decodeResponse preserves one template per requested path in wire order" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"templates":[
        \\{"path":"app/views/z.html.erb","nodes":[]},
        \\{"path":"app/views/a.html.erb","unreadable":"missing"},
        \\{"path":"app/views/m.html.erb","error":"bad","line":7}
        \\]}
    ;
    const d = try decodeResponse(gpa, line, &list);
    defer freeResult(gpa, d);
    try std.testing.expectEqual(@as(usize, 3), d.templates.len);
    try std.testing.expectEqualStrings("app/views/z.html.erb", d.templates[0].path);
    try std.testing.expectEqualStrings("app/views/a.html.erb", d.templates[1].path);
    try std.testing.expectEqualStrings("app/views/m.html.erb", d.templates[2].path);
    try std.testing.expect(d.templates[1].unreadable != null);
    try std.testing.expectEqual(@as(?u64, 7), d.templates[2].error_line);
}

test "decodeResponse: presentation facts are owned and old payloads default empty" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"templates":[{"path":"a.html.erb","nodes":[],"parity_h1":"About","parity_h1_node":3,"parity_links":["/","/posts"],"parity_link_nodes":[1,4]}]}
    ;
    const d = try decodeResponse(gpa, line, &list);
    defer freeResult(gpa, d);
    try std.testing.expectEqualStrings("About", d.templates[0].parity_h1.?);
    try std.testing.expectEqual(@as(?usize, 3), d.templates[0].parity_h1_node);
    try std.testing.expectEqual(@as(usize, 2), d.templates[0].parity_links.len);
    try std.testing.expectEqualStrings("/posts", d.templates[0].parity_links[1]);
    try std.testing.expectEqualSlices(usize, &.{ 1, 4 }, d.templates[0].parity_link_nodes);

    const old = try decodeResponse(gpa, "{\"ok\":true,\"templates\":[{\"path\":\"old.erb\",\"nodes\":[]}]}", &list);
    defer freeResult(gpa, old);
    try std.testing.expect(old.templates[0].parity_h1 == null);
    try std.testing.expectEqual(@as(usize, 0), old.templates[0].parity_links.len);
    try std.testing.expectEqual(@as(usize, 0), old.templates[0].parity_link_nodes.len);
}

test "decodeResponse: ok:false and a malformed line each become ONE RAILS_TEMPLATES_UNAVAILABLE blocker" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const a = try decodeResponse(gpa, "{\"ok\":false,\"error\":\"boom\",\"ruby\":{\"available\":true}}", &list);
    defer freeResult(gpa, a);
    const b = try decodeResponse(gpa, "not json", &list);
    defer freeResult(gpa, b);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATES_UNAVAILABLE", list.items[0].code);
    try std.testing.expect(!list.items[0].integrity);
    try std.testing.expectEqual(blockers.Severity.@"error", list.items[0].severity);
    try std.testing.expectEqualStrings("boom", list.items[0].detail);
    try std.testing.expect(a.ruby.available);
    try std.testing.expect(!b.ruby.available);
}

// A per-entry failure is DATA, not a blocker (module doc). This is the one
// test that would fail if a later change "helpfully" started announcing
// them here as well as in `findings.zig` -- the brief's own decode test
// asserts the fields are carried, but not that the blocker list stayed
// empty for a response that is entirely per-entry failures.
test "decodeResponse: per-entry error/unreadable entries append NO blockers" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"templates":[
        \\{"path":"a.html.erb","error":"syntax error","line":9},
        \\{"path":"b.html.erb","unreadable":"outside root"}
        \\],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, &list);
    defer freeResult(gpa, d);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(usize, 2), d.templates.len);
    try std.testing.expectEqual(@as(usize, 0), d.templates[0].nodes.len);
    try std.testing.expectEqual(@as(u64, 9), d.templates[0].error_line.?);
    try std.testing.expectEqualStrings("outside root", d.templates[1].unreadable.?);
}

test "decodeResponse: OOM at any point leaves no leak" {
    // Sweeps EVERY allocation-failure point rather than hardcoding one
    // index, for the reason `controllers.zig`'s equivalent sweep documents:
    // how many allocations `std.json.parseFromSlice` spends before this
    // function's own dupes begin is a std.json implementation detail. The
    // fixture is chosen so the sweep reaches the DEEPEST allocation this
    // file has -- a nested `attrs` key/value dupe inside a node inside a
    // template -- so a missing `errdefer` at any of the three levels has a
    // failure index that leaks. R16 added a fourth owned slice
    // (`i18n_errors`, itself two dupes per element), so the fixture carries
    // one of those too. `std.testing.allocator`'s leak detector
    // (reached through `FailingAllocator.internal_allocator`) is what
    // actually fails the test; nothing here asserts it explicitly.
    //
    // Stage 4 added a THIRD element to an attribute pair. It allocates
    // nothing of its own (`ValueKind` is a plain value), but the fixture
    // carries a `component_root` triple anyway so the sweep keeps exercising
    // the arity the decoder actually meets in the field -- a later change
    // that started duping the type string would otherwise sweep untested.
    const line =
        \\{"ok":true,"locale":"en","templates":[{"path":"a.html.erb","nodes":[{"t":"text","text":"x","line":1},{"t":"code","kind":"asset","line":1,"col":2,"output":true,"code":"image_tag \"l\"","name":"image_tag","args":["l"],"attrs":[["alt","L"]]},{"t":"code","kind":"component_root","line":2,"col":1,"output":false,"code":"<div data-react-class=\"C\">","name":"C","value":"div","attrs":[["p","3","number"]]}],"parity_h1":"Heading","parity_links":["/","/posts"]}],"i18n_errors":[{"path":"config/locales/en.yml","detail":"Psych::SyntaxError"}],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    var fail_index: usize = 0;
    var reached_success = false;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
        defer blockers.freeList(gpa, &list);
        const r = decodeResponse(gpa, line, &list) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        freeResult(gpa, r);
        reached_success = true;
        break;
    }
    // Without this, a `decodeResponse` that somehow OOM'd on all 64 indices
    // (or needed more than 64 allocations after a std.json change) would
    // make the loop above pass vacuously -- every iteration taking the
    // `continue` branch and asserting nothing about a real decode. Same
    // safety valve as `controllers.zig`'s `SweepNeverReachedSuccess`.
    try std.testing.expect(reached_success);
}

// Ruling R16 (review finding 2): `i18n_errors` was decoded away by
// `ignore_unknown_fields` on the grounds that it "belongs to whichever pass
// reports on i18n coverage". That pass is `findings.zig`, in this same run,
// and it had no way to know -- so a `config/locales/en.yml` Psych could not
// parse produced N confident `RAILS_I18N_UNRESOLVED` findings ("this key has
// no translation") and not one word about the empty translation table that
// actually caused them.
test "decodeResponse: i18n_errors decode as data, without becoming blockers" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"locale":"en","templates":[{"path":"a.html.erb","nodes":[]}],
        \\"i18n_errors":[{"path":"config/locales/en.yml","detail":"Psych::SyntaxError: mapping values are not allowed"},
        \\{"path":"config/locales/de.yml","detail":"Errno::EACCES: Permission denied"}],
        \\"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, &list);
    defer freeResult(gpa, d);
    // Same split as a per-template `unreadable`: this is DATA the caller
    // turns into a blocker, so this decoder appends none of its own.
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(usize, 2), d.i18n_errors.len);
    try std.testing.expectEqualStrings("config/locales/en.yml", d.i18n_errors[0].path);
    try std.testing.expectEqualStrings("Psych::SyntaxError: mapping values are not allowed", d.i18n_errors[0].detail);
    try std.testing.expectEqualStrings("config/locales/de.yml", d.i18n_errors[1].path);
}

test "decodeResponse: an absent or empty i18n_errors decodes as an empty slice" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const d = try decodeResponse(gpa, "{\"ok\":true,\"templates\":[],\"ruby\":{\"available\":true}}", &list);
    defer freeResult(gpa, d);
    try std.testing.expectEqual(@as(usize, 0), d.i18n_errors.len);
    // A degraded response has none either -- the field must be safe to walk
    // on every path `freeResult` is safe to walk.
    const e = try decodeResponse(gpa, "not json", &list);
    defer freeResult(gpa, e);
    try std.testing.expectEqual(@as(usize, 0), e.i18n_errors.len);
}

// #167 Stage 4 Task 1: the sidecar's element vocabulary. Rails writes three
// of the four interactive constructs as ORDINARY HTML, so `templates.rb` now
// finds them in the TEXT runs and closes each into a region with a
// `block_end` whose `code` is the close TAG (not a Ruby `end`). Two things
// here can silently get it wrong: a new `kind` decoding as `.unknown`
// (harmless for an unknown helper, a deleted island for a `stimulus` node),
// and an `attrs` triple's third element being dropped, which turns a React
// `points: 3` into the string `"3"` and fails the target's typecheck.
test "decodeResponse: element nodes, typed attr triples and a close-tag block_end" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"templates":[{"path":"a.html.erb","nodes":[
        \\{"t":"code","kind":"stimulus","line":2,"col":3,"output":false,"code":"<div data-controller=\"reveal\">","name":"reveal","value":"div","attrs":[["data-action","click->reveal#toggle"]]},
        \\{"t":"text","text":"<div data-controller=\"reveal\">x</div>","line":2},
        \\{"t":"code","kind":"block_end","line":2,"col":34,"output":false,"code":"</div>"},
        \\{"t":"code","kind":"vue_root","line":3,"col":1,"output":false,"code":"<div data-vue-component=\"Widget\">","name":"Widget","missing":true},
        \\{"t":"code","kind":"component_root","line":4,"col":1,"output":false,"code":"<div data-react-class=\"Chart\">","name":"Chart","attrs":[["series","a","string"],["points","3","number"],["on","true","boolean"],["off","","null"]]}
        \\]}],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, &list);
    defer freeResult(gpa, d);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    const n = d.templates[0].nodes;
    try std.testing.expectEqual(@as(usize, 5), n.len);

    try std.testing.expectEqual(Kind.stimulus, n[0].kind);
    try std.testing.expectEqualStrings("reveal", n[0].name.?);
    try std.testing.expectEqualStrings("div", n[0].value.?);
    try std.testing.expectEqual(@as(u64, 3), n[0].col);
    try std.testing.expect(!n[0].missing);
    // A stimulus attribute is a plain string pair: the third element is
    // absent, and the decoder must not read past the pair it was given.
    try std.testing.expectEqual(ValueKind.string, n[0].attrs[0].kind);
    try std.testing.expectEqualStrings("click->reveal#toggle", n[0].attrs[0].value);

    // The element node consumes no bytes -- the tag itself still rides
    // through as an ordinary text run, so the converter can pass it on.
    try std.testing.expectEqualStrings("<div data-controller=\"reveal\">x</div>", n[1].text.?);

    try std.testing.expectEqual(Kind.block_end, n[2].kind);
    try std.testing.expectEqualStrings("</div>", n[2].code);

    try std.testing.expectEqual(Kind.vue_root, n[3].kind);
    try std.testing.expectEqualStrings("Widget", n[3].name.?);
    // `missing` on an ELEMENT node means the sidecar found no close tag at
    // the same block depth -- the region has no extent, so no choice that
    // needs one may be offered for it.
    try std.testing.expect(n[3].missing);

    try std.testing.expectEqual(Kind.component_root, n[4].kind);
    try std.testing.expectEqual(@as(usize, 4), n[4].attrs.len);
    try std.testing.expectEqual(ValueKind.string, n[4].attrs[0].kind);
    try std.testing.expectEqual(ValueKind.number, n[4].attrs[1].kind);
    try std.testing.expectEqualStrings("3", n[4].attrs[1].value);
    try std.testing.expectEqual(ValueKind.boolean, n[4].attrs[2].kind);
    try std.testing.expectEqual(ValueKind.null, n[4].attrs[3].kind);
    try std.testing.expectEqualStrings("", n[4].attrs[3].value);
}

// Forward AND backward compatibility, in one payload: a sidecar predating
// Stage 4 sends two-element pairs and no `col` on a text run, and this build
// must read it exactly as the Stage 3 build did. The wire is additive on
// purpose -- an operator can upgrade the binary and the runtime dir
// separately -- so the defaults are the contract, not an accident.
test "decodeResponse: a pre-Stage-4 payload decodes exactly as before" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"templates":[{"path":"a.html.erb","nodes":[
        \\{"t":"code","kind":"component_root","line":1,"col":5,"output":true,"code":"react_component(\"Hello\", { name: \"n\" })","name":"Hello","attrs":[["name","n"]]},
        \\{"t":"code","kind":"turbo_frame","line":2,"col":5,"output":true,"code":"turbo_frame_tag \"x\" do","name":"x","dynamic":false}
        \\]}],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, &list);
    defer freeResult(gpa, d);
    const n = d.templates[0].nodes;
    try std.testing.expectEqual(@as(usize, 1), n[0].attrs.len);
    try std.testing.expectEqualStrings("name", n[0].attrs[0].key);
    try std.testing.expectEqualStrings("n", n[0].attrs[0].value);
    // The whole point: a pair with no type element is a STRING, which is what
    // every pre-Stage-4 `attrs` consumer already assumed.
    try std.testing.expectEqual(ValueKind.string, n[0].attrs[0].kind);
    try std.testing.expectEqual(Kind.turbo_frame, n[1].kind);
    try std.testing.expect(!n[1].dynamic);
    try std.testing.expectEqual(@as(usize, 0), n[1].attrs.len);
}

test "valueKindFromWire covers every enum tag and falls back to string" {
    inline for (@typeInfo(ValueKind).@"enum".fields) |f| {
        try std.testing.expectEqual(@field(ValueKind, f.name), valueKindFromWire(f.name));
    }
    // An unrecognised type name degrades to the kind every pre-Stage-4 pair
    // had, for the same reason `kindFromWire` degrades to `.unknown`: the
    // sidecar may grow a type this build has never heard of, and dropping the
    // attribute would shorten a props list the target is typechecked against.
    try std.testing.expectEqual(ValueKind.string, valueKindFromWire("bigint"));
    try std.testing.expectEqual(ValueKind.string, valueKindFromWire(""));
}

test "kindFromWire covers every enum tag and falls back to unknown" {
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        try std.testing.expectEqual(@field(Kind, f.name), kindFromWire(f.name));
    }
    try std.testing.expectEqual(Kind.unknown, kindFromWire("never_heard_of_it"));
    // The empty string is what `dupeNode` passes for a code node with no
    // `kind` key at all -- it must land on `unknown`, not on whichever tag
    // happens to be first.
    try std.testing.expectEqual(Kind.unknown, kindFromWire(""));
}

test "discoverTemplates: an empty path list never spawns and appends nothing" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const r = try discoverTemplates(std.testing.io, gpa, ".", &.{}, &list, &env);
    defer freeResult(gpa, r);
    try std.testing.expectEqual(@as(usize, 0), r.templates.len);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    // The early return happens before `environ_map` is ever read, which is
    // why an empty map (no ZIGAPAGOS_RUNTIME_DIR) still appends nothing --
    // an implementation that checked the env first would append the
    // "ZIGAPAGOS_RUNTIME_DIR is not set" blocker here.
    try std.testing.expect(!r.ruby.available);
}

test "discoverTemplates: a non-empty path list with no ZIGAPAGOS_RUNTIME_DIR degrades to one blocker" {
    // The mirror image of the test above: proves the early return is keyed
    // on `paths.len`, not on this function simply never doing anything.
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const r = try discoverTemplates(std.testing.io, gpa, ".", &.{"app/views/posts/index.html.erb"}, &list, &env);
    defer freeResult(gpa, r);
    try std.testing.expectEqual(@as(usize, 0), r.templates.len);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATES_UNAVAILABLE", list.items[0].code);
    try std.testing.expectEqualStrings("sidecar/rails/analyze.rb", list.items[0].path);
    try std.testing.expect(!list.items[0].integrity);
    try std.testing.expectEqual(blockers.Severity.@"error", list.items[0].severity);
    try std.testing.expect(!r.ruby.available);
}

test "discoverTemplates: ZIGAPAGOS_RUBY pointing at a nonexistent binary yields RAILS_TEMPLATES_UNAVAILABLE" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put(ruby_env, "/nonexistent/ruby-binary-does-not-exist-xyz");
    try env.put(runtime_dir_env, "runtime");

    const r = try discoverTemplates(std.testing.io, gpa, "tests/migrate/rails-sample", &.{"app/views/posts/index.html.erb"}, &list, &env);
    defer freeResult(gpa, r);

    try std.testing.expectEqual(@as(usize, 0), r.templates.len);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATES_UNAVAILABLE", list.items[0].code);
    // F3: `path` names the sidecar script, never the machine-specific
    // `ZIGAPAGOS_RUBY` value -- which is still reported, in `detail`.
    try std.testing.expectEqualStrings("sidecar/rails/analyze.rb", list.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, list.items[0].detail, "/nonexistent/ruby-binary-does-not-exist-xyz") != null);
    try std.testing.expect(!r.ruby.available);
}

test "discoverTemplates spawns the real Ruby sidecar and recovers a node stream" {
    // Needs `ruby` on PATH (mise) and to run from the repo root, same
    // requirement the sibling clients' live-spawn tests document. Degrades
    // to a RAILS_TEMPLATES_UNAVAILABLE blocker whose detail is the bare
    // `@errorName` `FileNotFound` when ruby genuinely isn't installed --
    // skip, not fail; any OTHER degradation is a real regression.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put(runtime_dir_env, "runtime");

    // Confirm the fixture is where this test expects before spawning, so a
    // missing fixture skips rather than looking like a sidecar failure.
    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    app_dir.close(io);

    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);

    const r = try discoverTemplates(io, gpa, "tests/migrate/rails-sample", &.{"app/views/posts/index.html.erb"}, &list, &env);
    defer freeResult(gpa, r);

    if (list.items.len > 0) {
        if (list.items.len == 1 and
            std.mem.eql(u8, list.items[0].code, unavailable_code) and
            std.mem.indexOf(u8, list.items[0].detail, "FileNotFound") != null)
            return error.SkipZigTest;
        std.debug.print("discoverTemplates degraded unexpectedly: {s}: {s}\n", .{
            list.items[list.items.len - 1].code,
            list.items[list.items.len - 1].detail,
        });
        return error.UnexpectedTemplateDiscoveryDegradation;
    }

    try std.testing.expectEqual(@as(usize, 1), r.templates.len);
    const t = r.templates[0];
    try std.testing.expectEqualStrings("app/views/posts/index.html.erb", t.path);
    try std.testing.expectEqual(@as(?[]const u8, null), t.unreadable);
    try std.testing.expectEqual(@as(?[]const u8, null), t.error_message);
    try std.testing.expect(t.nodes.len > 0);
    // The real Ruby process that answered this request knows its own
    // version -- see `sidecar_client.zig` on why this comes from the
    // response rather than a second spawn.
    try std.testing.expect(r.ruby.available);
    try std.testing.expect(r.ruby.version.?.len > 0);
}

// R12 (fix round 1): `Blocker.path` must be machine-stable -- see the module
// doc. This is the site where that is easiest to get wrong, because the path
// this function actually tried IS machine-specific whenever
// `ZIGAPAGOS_RUNTIME_DIR` is absolute. Driven the same way the
// `ZIGAPAGOS_RUBY` test above drives its own site: an `Environ.Map` this test
// owns, pointed at a runtime dir that does not exist.
test "discoverTemplates: an unresolvable sidecar script reports a machine-stable path, attempted path in detail" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put(runtime_dir_env, "no-such-runtime-dir-xyz");

    const r = try discoverTemplates(std.testing.io, gpa, ".", &.{"app/views/posts/index.html.erb"}, &list, &env);
    defer freeResult(gpa, r);

    try std.testing.expectEqual(@as(usize, 0), r.templates.len);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATES_UNAVAILABLE", list.items[0].code);
    // The whole point: a literal, app-root-relative constant, NOT the joined
    // `script_path` (which is absolute whenever the env var is).
    try std.testing.expectEqualStrings("sidecar/rails/analyze.rb", list.items[0].path);
    // The attempted path is not lost -- it moves into free-text `detail`,
    // which carries no determinism contract.
    try std.testing.expect(std.mem.indexOf(u8, list.items[0].detail, "no-such-runtime-dir-xyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items[0].detail, "FileNotFound") != null);
    try std.testing.expect(!r.ruby.available);
}
