//! Turns ONE `fragments.Template` node stream into SuperHTML bytes: a layout
//! (`<super>` blocks where Rails yielded), a view (`<extend>` + the blocks it
//! fills) or a partial (inlined verbatim at every render site, since
//! SuperHTML's `<extend>`/`<super>` is inheritance, not composition -- see
//! `docs/superhtml.md`).
//!
//! **Never fails on content.** Every fragment this stage cannot express as
//! static HTML becomes a comment marker with the surrounding markup left
//! intact, so a half-convertible template still produces a page an operator
//! can read and finish by hand. Three markers, and they are a CONTRACT the
//! e2e greps for:
//!
//! - `<!-- rails:finding <id> -->` ... `<!-- rails:end -->` wraps a region
//!   whose `findings.Finding` id an operator answers in
//!   `MIGRATION.decisions.json`. `<!-- rails:else -->` separates the branches
//!   of a control block inside one.
//! - `<!-- rails:unmapped <kind> L<line>C<col> -->` marks a fragment this
//!   converter treats as unconvertible for which NO finding could be found at
//!   this position -- so there is no id to decide about. It is standalone
//!   (never paired with an `end`) precisely because it is a hole rather than a
//!   question. Since ruling S12 every kind in `isFindingKind` HAS a derivation
//!   row, so this is no longer a standing gap in the vocabulary; it fires for
//!   a construct with no row at all (a partial cycle, an unbound local) and as
//!   the backstop for a node whose finding the lookup cannot match. The test
//!   at the bottom of this file pins the full coverage.
//! - `<!-- rails: <helper> dropped; <why> -->` records a helper whose
//!   conversion IS "delete it" (`csrf_meta_tags`, the JS-entry family), with
//!   a matching `Output.dropped` note for `MIGRATION.md`.
//!
//! **`Output.open_finding_ids` is not the whole picture, and the caller must
//! know it.** An `unmapped` region contributes NO id (there is none), so a
//! template whose only blemish is one converts with an empty
//! `open_finding_ids`. A caller deciding "migrated vs. open" from that field
//! alone would call such a route migrated. It must also treat `rails:unmapped`
//! in `bytes` as "not finished" -- a rule that survives S12 rather than being
//! made redundant by it: full derivation coverage is a property of today's
//! vocabulary, and this marker is what makes a future gap visible instead of
//! silently reporting a finished page.
//!
//! **A layout and a view have to agree on a block interface, and SuperHTML
//! fatals in BOTH directions if they do not** -- a block with no matching
//! `<super>` is an `UNBOUND TOP-LEVEL BLOCK`, a `<super>` with no matching
//! block a `MISSING TOP-LEVEL BLOCK`. So the interface is explicit rather
//! than assumed: a converted LAYOUT reports every id it declares in
//! `Output.block_ids` (always `head` and `main` -- both are synthesised when
//! the Rails layout does not spell them out -- plus one per other named
//! yield), and a converted VIEW is handed that list as
//! `Context.layout_blocks` and emits exactly those blocks, empty where it has
//! no `content_for` to fill them and dropping (with a note) any `content_for`
//! naming an id the layout never declared. Convert the layout first: the
//! empty `layout_blocks` default covers only a layout that declares nothing
//! beyond `head` and `main`, and pairing it with one that declares more
//! leaves that layout's extra `<super>`s unmatched.
//!
//! A view with no layout at all (`layout_stem == null`) is a whole document,
//! so it has no blocks: its collected `content_for` content is inlined
//! instead -- head content first, then the body.
//!
//! `yield(:title)` is the one named yield with no block: the title lives in
//! the `.smd`'s frontmatter, so a `<title>` around it is replaced wholesale
//! by `<title :text="$page.title"></title>` (any text that shared the element
//! is dropped with a note -- `:text` needs an empty element), and a
//! `yield(:title)` anywhere else interpolates through a `<ctx>`.
//!
//! **Only the OUTERMOST finding in a nesting emits a marker.** A `form`
//! holding six `form_field`s is one region to answer, not seven; the inner
//! ids still land in `open_finding_ids` so nothing is hidden from the report,
//! but the converted page does not become a wall of comments.
//!
//! **Block structure is read off the stream, not guessed at.**
//! `templates.rb` emits a flat stream with explicit `block_else`/`block_end`
//! markers but no "this node opens a block" flag, so `opensBlock` recovers it
//! from the two facts that ARE on the wire: `.control` (if/unless/case/
//! while/until) always closes with a `block_end` in `emit_statement`, and any
//! other opener was written with a Ruby block opener at the end of its own
//! source text (`do`, `do |f|`, `{`). A misread there degrades to an
//! unbalanced comment marker, never to lost markup -- text runs are appended
//! verbatim regardless of what frame they land in.
//!
//! Determinism (plan, Global Constraints): every lookup goes through
//! `resolve.zig`'s total functions, `open_finding_ids` and `dropped` are
//! sorted and deduped, and nothing reads the filesystem or the clock. The
//! same node stream converts to the same bytes on every machine.
//!
//! std-only, like every file in `src/cli/rails/`: nothing here fatals, and
//! the one error it returns (`Unconvertible`, for a template the sidecar
//! could not parse or read at all) is the caller's to turn into a finding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assets = @import("assets.zig");
const findings = @import("findings.zig");
const fragments = @import("fragments.zig");
const port = @import("port.zig");
const resolve = @import("resolve.zig");
const routes = @import("routes.zig");

/// Everything one template's conversion needs to look outward: the route and
/// asset tables `resolve.zig` answers against, every OTHER template's node
/// stream (partials are expanded inline, so a view's conversion reads them),
/// the findings Stage 1 already derived (for the placeholder ids -- `convert`
/// never appends to this), and the layout a view extends.
///
/// All slices are BORROWED and must outlive the `convert` call; nothing here
/// is freed by `freeOutput`.
pub const Context = struct {
    routes: []const routes.Route,
    assets: []const assets.Asset,
    /// Every template's node stream, by path (for partial inlining).
    fragments: []const fragments.Template,
    /// Findings already derived for this run (for placeholder ids); convert
    /// never appends to it.
    findings: []const findings.Finding,
    /// For a view: the `resolve.layoutStem` of the layout it extends. `null`
    /// emits the view standalone.
    layout_stem: ?[]const u8,
    /// For a view: the `Output.block_ids` of its ALREADY-CONVERTED layout --
    /// every id that layout declares a `<super>` under. The view fills each
    /// one, emitting an empty block for those it has no `content_for` for,
    /// and drops a `content_for` naming an id that is not here.
    ///
    /// This is the whole reason the pairing type-checks: SuperHTML fatals on
    /// a block with no matching `<super>` (`UNBOUND TOP-LEVEL BLOCK`) AND on
    /// a `<super>` with no matching block (`MISSING TOP-LEVEL BLOCK`), so
    /// neither side may guess what the other declared.
    ///
    /// Defaulted empty so a caller that has not converted a layout yet still
    /// gets the two blocks every converted layout is guaranteed to declare
    /// (`head`, `main`); see `convert`'s assembly. That default is a floor,
    /// NOT a safe universal: a layout that declares anything else -- any named
    /// yield beyond `title`/`head` -- pairs with such a view only to leave its
    /// own extra `<super>`s unmatched. Pass the real list.
    layout_blocks: []const []const u8 = &.{},
    /// #167 Stage 3: the operator's backend answers, keyed by the finding id
    /// of the OUTERMOST node each one replaces. A node whose finding id is in
    /// here is not converted at all: the whole region becomes one `<island>`
    /// and every finding inside it is reported BOUND rather than open.
    ///
    /// Borrowed like everything else in `Context`, and defaulted empty so a
    /// caller with no answers (Stage 1's manifest-only run, every pre-Stage-3
    /// test) behaves exactly as before.
    bindings: []const Binding = &.{},
};

/// What one answered `RAILS_BACKEND_ENDPOINT` finding binds to (#167 Stage
/// 3). Built by `scaffold.zig`, which is the only place that can see the
/// decisions file, the ZigBase document and the route table at once; read
/// here to decide which regions become islands, and read back off
/// `IslandSpec` to emit the island's own source.
///
/// Every string is BORROWED from the caller and must outlive the `Output`
/// the conversion returns -- `freeOutput` never frees one.
pub const Binding = struct {
    /// The finding this answers, and the key `Context.bindings` is searched
    /// by: the id of the outermost node the island replaces.
    finding_id: []const u8,
    kind: Binding.Kind,
    /// Upper-case HTTP verb the client call uses (`POST`, `PATCH`).
    verb: []const u8,
    /// The backend path the call reaches (`/api/collections/posts/records`,
    /// or the operator's own `custom:/<path>` payload).
    path: []const u8,
    /// The ZigBase operation id, or the literal `custom` for a
    /// `custom:/<path>` answer (assumption A3).
    operation_id: []const u8,
    /// The collection a `zb.collection(...)` call names, when the operation
    /// is a collection operation at all. `null` for a consumer route or a
    /// `custom:` answer, which go through `zb.send`.
    collection: ?[]const u8,
    /// Target-relative path of the island file this region becomes, e.g.
    /// `components/forms/registrations_new.island.tsx`.
    island: []const u8,
    /// Site URL to send the browser to after a successful call, resolved
    /// from the paired Rails action's own `redirect_to`. `null` leaves the
    /// island on the page with a "done" state instead.
    redirect_to: ?[]const u8,
    /// The Ziggy props literal the `<island>` tag carries, WITHOUT the
    /// surrounding quotes (`{ .mode = "signin" }`), or `null` for an island
    /// that takes none.
    ///
    /// Only the auth journey needs this so far: assumption A5 folds sign-in
    /// and sign-up into ONE finding and Task 5 answers it with ONE component,
    /// so the two Rails views that mount it differ only in a prop. A form
    /// island generated per region encodes everything in its own source and
    /// leaves this null.
    props: ?[]const u8 = null,
    /// Where the region this binding replaces sits, for the bindings that
    /// have no finding id to join on.
    ///
    /// The auth journey is exactly that case: assumption A5 says a form in a
    /// journey view derives NO `RAILS_BACKEND_ENDPOINT`, because the single
    /// `RAILS_AUTH_JOURNEY` row is the question for the whole flow. So the
    /// form node the island replaces carries no id at all, and `finding_id`
    /// (which is the journey's, shared by every such binding) cannot pick it
    /// out of the node stream. When this is set it is the ONLY key used --
    /// never a fallback, so one journey answer cannot silently bind an
    /// unrelated node whose id happens to match.
    at: ?At = null,
    /// This region is ANSWERED but mounts nothing: another binding's island
    /// already covers it, so the region is consumed silently -- no marker, no
    /// `rails:end`, no `<island>` -- and every finding id inside it is still
    /// recorded as bound.
    ///
    /// The auth journey is the only thing that sets it, and only for the
    /// second half of a complementary pair: `AuthStatus` renders both the
    /// signed-in and the signed-out branch itself, so
    /// `<% if current_user %>…<% end %><% unless current_user %>…<% end %>` is
    /// ONE control written as two regions. Mounting at each of them put the
    /// whole component on the page twice. `scaffold.zig`'s `bindAuthStatus`
    /// decides which of the two is absorbed; this flag is how it says so.
    ///
    /// Answered, not ignored: the id still settles, because the operator did
    /// answer that region and a route that stayed open on it would never
    /// finish.
    absorbed: bool = false,

    /// Stage 4 bindings can preserve a region as an island slot instead of
    /// replacing it. `directive` applies only to an emitted island.
    wrap: bool = false,
    directive: []const u8 = "client:load",
    /// Every Stimulus identifier on the element, outermost first.
    identifiers: []const []const u8 = &.{},
    /// Aliases used to reproduce a data island's record body.
    aliases: []const port.Alias = &.{},

    pub const Kind = enum { operation, custom, auth_signin, auth_signup, auth_logout, stimulus, turbo_frame, component, data_list, @"inline", drop };

    /// A source position in one template, as `fragments.Node` reports it.
    pub const At = struct { path: []const u8, line: u64, col: u64 };
};

/// One control inside a bound form, in source order: what
/// `runtime/sidecar/rails/templates.rb` recovered for one `f.<helper>` call.
///
/// BORROWED from the template's own node stream (`Context.fragments`), which
/// outlives the `Output`; only the enclosing slice is an allocation.
pub const Field = struct {
    /// The form-builder helper as written: `text_field`, `email_field`,
    /// `password_field`, `hidden_field`, `text_area`, `check_box`, `select`,
    /// `label`, `submit`. An unrecognised one is carried through verbatim so
    /// the island emitter can say what it could not render.
    helper: []const u8,
    /// The attribute name the control submits under (`email`). Empty for a
    /// `submit`, which names no field.
    name: []const u8,
    /// An explicit label/button text the author passed
    /// (`f.label :email, "Your email"`), else `null` -- the emitter
    /// humanises `name` in that case.
    label: ?[]const u8,
    /// A `select`'s literal options, in source order. Empty for every other
    /// helper, and also for a `select` whose option list was not a literal.
    options: []const []const u8,
};

/// What distinguishes a bound `link_to`/`button_to` from a bound form: the
/// control is a single BUTTON, and everything the call needs has to come off
/// the link itself, because a link has no fields to collect.
///
/// Every string BORROWED from the template's node stream, like `Field`.
pub const Click = struct {
    /// The `data-confirm` / `data-turbo-confirm` / `confirm:` text Rails would
    /// have put in front of the request (the nested `data: { turbo_confirm:
    /// … }` spelling arrives as `data-turbo-confirm`, flattened by the
    /// sidecar), or `null` when the author wrote none. Dropping it would
    /// turn a guarded destructive action into an unguarded one, which is a
    /// behaviour change no operator asked for.
    confirm: ?[]const u8,
    /// The route helper's first literal argument (`post_path(1)` -> `1`),
    /// which is the only record id a link carries -- `null` for
    /// `session_path` and for a literal target. An `update`/`delete`
    /// collection call with no id gets the same TODO a fieldless form does.
    record_id: ?[]const u8,
};

/// One island a bound region becomes. `scaffold.zig` turns this into the
/// `.island.tsx` file `binding.island` names.
///
/// Mixed ownership, and the split is deliberate: `fields`, `original`, and
/// optional `port` are owned; `binding`, `extent`, and the remaining strings
/// borrow from the conversion inputs. `freeOutput` releases only the owned
/// members.
pub const IslandSpec = struct {
    /// `binding.island`, repeated so a consumer sorting or writing island
    /// files does not have to reach through the binding.
    island: []const u8,
    /// Owned slice of borrowed `Field`s, in source order.
    fields: []const Field,
    /// The model name of the `errors` region this form's island absorbed
    /// (`user`), or `null` when the template had none -- in which case the
    /// island still renders the backend's errors, above its submit button.
    errors_model: ?[]const u8,
    /// The submit button's text: the author's own `f.submit "Sign in"`, else
    /// `Save` -- and, for a bound link, the link's own text.
    submit_label: []const u8,
    /// Set when the region is a bound `link_to`/`button_to` rather than a
    /// form; `null` for a form. Also the emitter's discriminator: a link
    /// island is a button, not a `<form>`, and `fields.len == 0` cannot say
    /// so (a form with no recovered controls is empty too).
    click: ?Click,
    binding: Binding,
    /// The region's source text as one line, for the island's header
    /// comment. OWNED.
    original: []const u8,
    /// The template line the region starts on, for the same header comment:
    /// a generated file that cannot be traced back to the ERB it replaced is
    /// a file nobody can review against its source.
    line: u64,
    /// The template the region came from, BORROWED. Not always the view being
    /// converted: a form in a `_form` partial is inlined into the view's node
    /// walk, and the header comment has to name the file an operator would
    /// actually open.
    source: []const u8,
    /// Owned data-island body; null for every other island kind.
    port: ?[]u8 = null,
    /// Borrowed source extent for a wrapping island's review header.
    extent: ?[]const u8 = null,
};

/// Which of the three SuperHTML shapes to assemble. A `partial` is converted
/// as a bare fragment because that is what an inline expansion needs; it is
/// never written to the target tree on its own.
pub const Kind = enum { layout, view, partial };

/// Contract 2 (owned-result): every field is a fresh `gpa` allocation;
/// released by `freeOutput`.
pub const Output = struct {
    bytes: []u8,
    /// `content_for`/`provide(:title, …)` with a single literal child, else
    /// the first `<h1>`'s text, else null. Plain text (HTML entities
    /// resolved), because it becomes a Ziggy frontmatter value.
    title: ?[]const u8,
    /// `<meta name="description" content="…">`'s value, plain text.
    description: ?[]const u8,
    /// Ids of findings hit while converting THIS template graph (the template
    /// plus every partial inlined into it), sorted and deduped. See the
    /// module doc for why an empty list is not proof of a finished page.
    open_finding_ids: [][]const u8,
    /// Human notes for `MIGRATION.md` ("csrf_meta_tags dropped"), sorted and
    /// deduped: a helper dropped at five render sites is one note.
    dropped: [][]const u8,
    /// LAYOUT only: every block id this layout declares a `<super>` under,
    /// sorted and deduped. Always contains `head` and `main` (both are
    /// synthesised when the Rails layout does not spell them out) plus one id
    /// per other named yield. Empty for a view or a partial, which declare no
    /// blocks -- they FILL them. Feed it to the view's
    /// `Context.layout_blocks`.
    block_ids: [][]const u8,
    /// #167 Stage 3: one entry per `Context.bindings` entry this template
    /// graph actually hit, in source order. `scaffold.zig` writes one
    /// `.island.tsx` per entry.
    islands: []IslandSpec,
    /// Ids of findings this conversion RESOLVED rather than left open: the
    /// bound region's own id plus every id inside it. Sorted and deduped,
    /// disjoint from `open_finding_ids` by construction. A route is
    /// `migrated` once what is left open is empty -- these ids are answered,
    /// and the island is the answer.
    bound_finding_ids: [][]const u8,
    /// #167 Stage 3, ruling S3-R6: the subset of `bound_finding_ids` that was
    /// bound because something ELSE answered the region it sits in, and which
    /// binding that was. In walk order, deduped.
    ///
    /// `bound_finding_ids` alone cannot say this: it flattens "the region the
    /// operator answered" and "the ids that region swallowed" into one list,
    /// and only the second kind can be answered a second time by an operator
    /// who reads the handoff and sees the nested finding listed under a route.
    enclosed: []Enclosure,
};

/// One finding a bound region swallowed, and the answered region that
/// swallowed it.
///
/// The shape is ordinary in Rails: `button_to "Sign out", session_path,
/// method: :delete` written inside `<% if current_user %>`. The `if` is a
/// `RAILS_REQUEST_TIME_STATE` an operator answers `island`; the `button_to`
/// raises its own `RAILS_BACKEND_ENDPOINT` inside it. The island replaces the
/// whole region -- the control included -- so the inner finding is answered
/// by the outer answer and nothing separate is ever built for it.
///
/// BOTH strings borrow `Context.findings` (`id` through the id join,
/// `by` through `Binding.finding_id`), which outlives the `Output` -- so only
/// the enclosing slice is an allocation, exactly like `IslandSpec`'s borrowed
/// members. `freeOutput` releases that slice and nothing else.
pub const Enclosure = struct {
    /// The finding raised INSIDE the region.
    id: []const u8,
    /// The finding the enclosing region's binding was keyed on -- the answer
    /// that supersedes an answer on `id`.
    by: []const u8,
};

/// The prefix of the one `Output.dropped` note that reports LOST AUTHOR
/// MARKUP rather than a construct with a defined conversion: a `content_for`
/// naming a block the layout does not declare, whose body simply has nowhere
/// to go.
///
/// Public because `scaffold.zig` has to tell that note apart from the others
/// (ruling S15: this one makes the route `open`, a `csrf_meta_tags` or
/// JS-entry or `<title>`-suffix drop does not). Shared as a constant rather
/// than matched on the prose there, so rewording the message cannot silently
/// downgrade a lost block to a footnote.
pub const dropped_content_for_prefix = "content_for :";

pub const Error = error{Unconvertible} || Allocator.Error;

/// Contract 2 counterpart to `convert`.
pub fn freeOutput(gpa: Allocator, out: Output) void {
    gpa.free(out.bytes);
    if (out.title) |t| gpa.free(t);
    if (out.description) |d| gpa.free(d);
    freeStrings(gpa, out.open_finding_ids);
    freeStrings(gpa, out.dropped);
    freeStrings(gpa, out.block_ids);
    // `IslandSpec`'s owned members, and nothing else -- see its doc for why
    // every other string in it is borrowed.
    for (out.islands) |s| {
        gpa.free(s.fields);
        gpa.free(s.original);
        if (s.port) |body| gpa.free(body);
    }
    gpa.free(out.islands);
    freeStrings(gpa, out.bound_finding_ids);
    // Slice only: see `Enclosure` for why both of its strings are borrowed.
    gpa.free(out.enclosed);
}

/// Contract 2 counterpart to the two `finalize*` builders.
fn freeStrings(gpa: Allocator, list: [][]const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

const StripMode = enum { turbo, stimulus };
const Stripped = struct { bytes: []u8, dropped: bool };

fn stimulusAttrFor(key: []const u8, identifiers: []const []const u8) bool {
    if (std.mem.eql(u8, key, "data-controller") or std.mem.eql(u8, key, "data-action")) return true;
    if (!std.mem.startsWith(u8, key, "data-")) return false;
    const rest = key["data-".len..];
    for (identifiers) |identifier| {
        if (!std.mem.startsWith(u8, rest, identifier)) continue;
        if (rest.len <= identifier.len or rest[identifier.len] != '-') continue;
        const tail = rest[identifier.len + 1 ..];
        if (std.mem.eql(u8, tail, "target")) return true;
        if ((std.mem.endsWith(u8, tail, "-value") or std.mem.endsWith(u8, tail, "-class")) and
            std.mem.indexOfScalar(u8, tail, '-') != null) return true;
    }
    return false;
}

fn shouldStripAttr(key: []const u8, mode: StripMode, identifiers: []const []const u8) bool {
    return switch (mode) {
        .stimulus => stimulusAttrFor(key, identifiers),
        .turbo => std.mem.eql(u8, key, "data-turbo") or
            std.mem.eql(u8, key, "data-turbo-action") or
            std.mem.eql(u8, key, "data-turbo-track") or
            std.mem.eql(u8, key, "data-turbo-permanent") or
            std.mem.eql(u8, key, "data-turbo-prefetch"),
    };
}

fn tagEnd(text: []const u8, start: usize) ?usize {
    var quote: ?u8 = null;
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (quote) |q| {
            if (ch == q) quote = null;
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
        } else if (ch == '>') return i + 1;
    }
    return null;
}

fn stripTagAttrs(
    gpa: Allocator,
    out: *List,
    tag: []const u8,
    mode: StripMode,
    identifiers: []const []const u8,
    dropped: *bool,
) Allocator.Error!void {
    if (tag.len < 3 or tag[0] != '<' or tag[1] == '/' or tag[1] == '!' or tag[1] == '?') {
        try out.appendSlice(gpa, tag);
        return;
    }
    var i: usize = 1;
    while (i < tag.len and !std.ascii.isWhitespace(tag[i]) and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
    try out.appendSlice(gpa, tag[0..i]);
    while (i < tag.len) {
        const whitespace = i;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] == '>' or tag[i] == '/') {
            try out.appendSlice(gpa, tag[whitespace..]);
            return;
        }
        const key_start = i;
        while (i < tag.len and !std.ascii.isWhitespace(tag[i]) and tag[i] != '=' and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
        if (i == key_start) {
            try out.appendSlice(gpa, tag[whitespace .. i + 1]);
            i += 1;
            continue;
        }
        const key = tag[key_start..i];
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i < tag.len and tag[i] == '=') {
            i += 1;
            while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
            if (i < tag.len and (tag[i] == '\'' or tag[i] == '"')) {
                const quote = tag[i];
                i += 1;
                while (i < tag.len and tag[i] != quote) : (i += 1) {}
                if (i < tag.len) i += 1;
            } else {
                while (i < tag.len and !std.ascii.isWhitespace(tag[i]) and tag[i] != '>') : (i += 1) {}
            }
        }
        if (shouldStripAttr(key, mode, identifiers)) {
            dropped.* = true;
        } else {
            try out.appendSlice(gpa, tag[whitespace..i]);
        }
    }
}

/// Contract 1 (self-freeing): the returned bytes are the sole allocation.
/// Only attributes inside real start tags are considered; quotes may contain
/// `>` without ending the tag.
fn stripLexicalAttrs(gpa: Allocator, text: []const u8, mode: StripMode, identifiers: []const []const u8) Allocator.Error!Stripped {
    var out: List = .empty;
    errdefer out.deinit(gpa);
    var dropped = false;
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, at, '<')) |start| {
        try out.appendSlice(gpa, text[at..start]);
        const end = tagEnd(text, start) orelse {
            try out.appendSlice(gpa, text[start..]);
            at = text.len;
            break;
        };
        try stripTagAttrs(gpa, &out, text[start..end], mode, identifiers, &dropped);
        at = end;
    }
    if (at < text.len) try out.appendSlice(gpa, text[at..]);
    return .{ .bytes = try out.toOwnedSlice(gpa), .dropped = dropped };
}

// ---- escaping ------------------------------------------------------------

/// The four characters that change the meaning of HTML text or of a
/// double-quoted attribute value. `'` is deliberately NOT escaped: every
/// attribute this file emits is double-quoted, so a raw apostrophe is
/// ordinary data there, and escaping it in text would turn readable prose
/// into entity soup for no gain.
///
/// Contract 2 (owned-result), inherited from `convert`: `gpa` is used only to
/// grow the CALLER's `out` buffer, which the caller already owns and frees;
/// this function retains nothing of its own.
fn escapeInto(gpa: Allocator, out: *List, text: []const u8) Allocator.Error!void {
    for (text) |ch| switch (ch) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        else => try out.append(gpa, ch),
    };
}

/// The inverse, for the two values that leave this file as PLAIN TEXT rather
/// than markup (`Output.title`, `Output.description`): they are read out of
/// already-converted bytes, so they arrive escaped, and they are written into
/// Ziggy frontmatter, which has escaping rules of its own. Handing the caller
/// `A page &amp; more` would put the entity in the page title.
///
/// Contract 1 (self-freeing): the returned buffer is the only allocation.
fn unescape(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const table = [_]struct { entity: []const u8, ch: u8 }{
        .{ .entity = "&amp;", .ch = '&' },
        .{ .entity = "&lt;", .ch = '<' },
        .{ .entity = "&gt;", .ch = '>' },
        .{ .entity = "&quot;", .ch = '"' },
        .{ .entity = "&#39;", .ch = '\'' },
        .{ .entity = "&apos;", .ch = '\'' },
    };
    var out: List = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    outer: while (i < text.len) {
        if (text[i] == '&') {
            for (table) |row| {
                if (std.mem.startsWith(u8, text[i..], row.entity)) {
                    try out.append(gpa, row.ch);
                    i += row.entity.len;
                    continue :outer;
                }
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ---- block structure -----------------------------------------------------

/// Whether this node has a matching `block_end` further down the stream. See
/// the module doc for why it cannot simply be read off the wire.
///
/// Public because `findings.zig` needs the SAME answer to scope ruling S12's
/// "only the outermost form asks the question" to an enclosing `form` block.
/// Exported from here rather than duplicated there because a second copy of
/// `codeOpensBlock`'s `do`-with-a-word-boundary rule is exactly the kind of
/// near-identical predicate that drifts: the converter and the derivation
/// table would then disagree about which `form_field`s are inside a form, and
/// the placeholder in the page would stop matching the finding list.
///
/// Contract 3 (caller-buffer): allocates nothing.
pub fn opensBlock(node: fragments.Node) bool {
    if (node.text != null) return false;
    if (node.kind == .stimulus or node.kind == .vue_root) return !node.missing;
    if (node.kind == .component_root and !node.output) return !node.missing;
    if (node.kind == .turbo_frame and node.value != null and std.mem.eql(u8, node.value.?, "turbo-frame")) return !node.missing;
    switch (node.kind) {
        // Element regions are paired with a synthetic `block_end` carrying
        // their closing tag. They do not contain Ruby `do`, so the lexical
        // fallback below cannot see them. A missing element has no close and
        // must remain a one-node region. The component arm is retained per
        // the Stage 1 ledger ruling even though Stage 4 replaces portable
        // React roots: an unanswered HTML root still needs a bounded marker.
        // `emit_statement` always pairs these with a `block_end`, whatever
        // their source text looks like (`if x` carries no `do`).
        .control => return true,
        .block_else, .block_end => return false,
        else => return codeOpensBlock(node.code) or statementOpensBlock(node),
    }
}

/// The Ruby statement keywords `emit_statement` pairs with a `block_end`.
///
/// Needed because a statement does NOT always arrive as `.control`: ruling
/// R2c names a branch after what it branches ON, so `<% if current_user %>`
/// reaches this file as `request_state` and `<% if @post.errors.any? %>` as
/// `errors`. The sidecar still emits their `block_end` (`emit_statement`
/// closes every If/Unless/Case/While/Until node, and even a MODIFIER `if`
/// gets one, with empty code), so reading only `.control` lost the pairing
/// for exactly the branches Stage 2 and Stage 3 care most about: the region
/// collapsed to a marker plus an immediate `rails:end`, its body converted as
/// though it were unconditional, and the unmatched `end` was silently
/// dropped. #167 Stage 3 Task 5 depends on the region being a region -- the
/// `AuthStatus` island replaces `<% if current_user %> … <% end %>` whole,
/// sign-out button included.
///
/// `output` is required to be false: only a STATEMENT tag is paired this way,
/// and an output tag whose expression happens to start with one of these
/// words is not one.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn statementOpensBlock(node: fragments.Node) bool {
    if (node.output) return false;
    const keywords = [_][]const u8{ "if", "unless", "case", "while", "until" };
    const code = std.mem.trimStart(u8, node.code, " \t");
    for (keywords) |k| {
        if (!std.mem.startsWith(u8, code, k)) continue;
        const rest = code[k.len..];
        // A word boundary, so `unlessness` and a bare `if` (the latter is not
        // Ruby anyway) are not mistaken for the keyword.
        if (rest.len == 0) continue;
        if (std.ascii.isAlphanumeric(rest[0]) or rest[0] == '_') continue;
        return true;
    }
    return false;
}

/// `content_for :title do` / `form_with(model: @post) do |f|` / `items.each {`
/// -> true. The block-parameter list is stripped first so the `do` is at the
/// end where it can be checked for a word boundary -- without that,
/// `render_dynamic` on a variable named `dodo` would read as an opener.
fn codeOpensBlock(code: []const u8) bool {
    var s = std.mem.trimEnd(u8, code, " \t\r\n");
    if (s.len > 0 and s[s.len - 1] == '|') {
        if (std.mem.lastIndexOfScalar(u8, s[0 .. s.len - 1], '|')) |open| {
            s = std.mem.trimEnd(u8, s[0..open], " \t");
        }
    }
    if (s.len > 0 and s[s.len - 1] == '{') return true;
    if (!std.mem.endsWith(u8, s, "do")) return false;
    if (s.len == 2) return true;
    const before = s[s.len - 3];
    return !(std.ascii.isAlphanumeric(before) or before == '_');
}

/// Index of the `block_end` that closes the block `open` starts, or `null`
/// when `open` starts none. Used only where a range has to be SKIPPED or
/// REDIRECTED wholesale (`content_for :title`/`:head`); the ordinary walk
/// tracks nesting with a frame stack instead and never needs to look ahead.
///
/// `pub` for `scaffold.zig`'s `bindAuthStatus`, which has to know the same
/// span this file skips: the island replaces `nodes[open..end]` wholesale, so
/// an answered region inside that range is one this file will never reach.
/// The two must agree on where the range ENDS, which is why it reads this
/// definition rather than growing a second one.
pub fn matchingEnd(nodes: []const fragments.Node, open: usize) ?usize {
    if (!opensBlock(nodes[open])) return null;
    var depth: usize = 0;
    var i: usize = open;
    while (i < nodes.len) : (i += 1) {
        const n = nodes[i];
        if (n.text != null) continue;
        if (n.kind == .block_end) {
            depth -= 1;
            if (depth == 0) return i;
        } else if (opensBlock(n)) {
            depth += 1;
        }
    }
    return null;
}

/// The kinds whose conversion is ALWAYS a placeholder region, whatever their
/// operands look like. The conditional ones are not here and are decided at
/// the point of conversion instead: an `i18n` whose key resolved, a
/// `route_helper`/`link_to` that names a certain route, an `asset` the
/// manifest pins are all ordinary output.
///
/// Every one of these has a row in `findings.derive` (ruling S12 added the
/// last six -- `form`, `form_field`, `errors`, `turbo_frame`, `turbo_stream`,
/// `component_root`), so each emits `rails:finding <id>` with an id an
/// operator can answer. That is the invariant, and the test at the bottom of
/// this file asserts it as an equality with no exemption list: a kind added
/// here without a derivation row fails there.
///
/// The stages still differ in what they can OFFER -- Stage 2 gives the last
/// six `retain`/`blocked`, Stage 3 widens the form codes with backend
/// operations and Stage 4 widens the Turbo/component ones with `island` --
/// but that is the finding's `choices`, not whether the finding exists.
/// Withholding the row was the earlier mistake: `rails:unmapped` carries no
/// id, so such a route could not be acknowledged by any choice at all.
fn isFindingKind(kind: fragments.Kind) bool {
    return switch (kind) {
        .control,
        .request_state,
        .ivar,
        .unknown,
        .raw,
        .render_dynamic,
        .route_helper_dynamic,
        .form,
        .form_field,
        .errors,
        .turbo_frame,
        .turbo_stream,
        .component_root,
        .stimulus,
        .vue_root,
        => true,
        else => false,
    };
}

fn isElementNode(node: fragments.Node) bool {
    return node.kind == .stimulus or node.kind == .vue_root or (node.kind == .component_root and !node.output) or
        (node.kind == .turbo_frame and node.value != null and std.mem.eql(u8, node.value.?, "turbo-frame"));
}

/// The kinds an operator's `RAILS_BACKEND_ENDPOINT` answer can turn into an
/// island.
///
/// `isFindingKind` plus `link_to`, and the difference is the whole point.
/// `isFindingKind` answers "does this ALWAYS become a placeholder", and a
/// `link_to` does not: an unbound `link_to "Home", root_path` is an ordinary
/// `<a href>` and must stay one, so putting `link_to` in that set would turn
/// every navigation link in every template into a placeholder region.
///
/// But a `button_to`, or a `link_to … method: :delete`, SUBMITS -- `findings`
/// raises `RAILS_BACKEND_ENDPOINT` on exactly those (`deriveMutationLink`) and
/// `scaffold.bindTemplate` records a binding when one is answered. Before this
/// gate existed that binding was never consumed: the walk asked
/// `isFindingKind` on the way in, `link_to` said no, and the answered control
/// converted as if it had never been bound -- an `<a href>` to a route the
/// target site does not serve, with the route still reported migrated.
fn isBindableKind(kind: fragments.Kind) bool {
    return isFindingKind(kind) or kind == .link_to;
}

/// The confirmation prompt a bound link carries, or `null`.
///
/// Three spellings, because Rails has had three: `data-confirm` (UJS),
/// `data-turbo-confirm` (Turbo) and a bare `confirm:`. The Turbo one is
/// usually WRITTEN nested -- `data: { turbo_confirm: "Sure?" }` -- and the
/// sidecar's `flatten_opts` spells that out as `data-turbo-confirm` the way
/// Rails' own tag helper does, so one string key covers both spellings here.
/// A sidecar that did not flatten it leaves `data` holding
/// `nested_hash_sentinel` instead, which `emitIsland` reports rather than
/// reads (see `hasSentinel`).
///
/// Contract 3 (caller-buffer): borrows the node's own attribute values.
fn confirmText(attrs: []const fragments.Attr) ?[]const u8 {
    for (attrs) |a| {
        if (std.mem.eql(u8, a.key, "data-confirm") or
            std.mem.eql(u8, a.key, "data-turbo-confirm") or
            std.mem.eql(u8, a.key, "confirm"))
        {
            if (a.value.len > 0) return a.value;
        }
    }
    return null;
}

/// What `runtime/sidecar/rails/templates.rb`'s `literal_attrs` reports as
/// the VALUE of an option whose value was a nested hash of literals it did
/// not spell out (`html: { a: 1 }`). It is a marker, not content: nothing in
/// the node stream says what the hash held.
pub const nested_hash_sentinel = "{...}";

/// Whether `key` among `attrs` carries `nested_hash_sentinel`.
///
/// The sidecar that ships beside this binary flattens `data:` (and `aria:`)
/// before they get here, so from it a `data` key never carries the sentinel.
/// But `--runtime-path` / `ZIGAPAGOS_RUNTIME_DIR` choose the sidecar, and an
/// older `templates.rb` still collapses the hash -- in which case a
/// `data: { turbo_confirm: … }` the author wrote is simply not in the node
/// stream, and the island built from it would drop a confirmation guard
/// without a word. This is how `emitIsland` notices.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn hasSentinel(attrs: []const fragments.Attr, key: []const u8) bool {
    for (attrs) |a| {
        if (std.mem.eql(u8, a.key, key) and std.mem.eql(u8, a.value, nested_hash_sentinel)) return true;
    }
    return false;
}

/// Whether an `errors` node's receiver names the same model a `form`'s does.
///
/// Both spellings reach here: `classify_form` strips the sigil (`@user` ->
/// `user`, ruling R9: a form's name is Rails' own PARAM KEY), while an
/// `errors` node's name is `receiver_root_name`, which may keep it. Stripping
/// on both sides is what makes `form_with model: @user` and `@user.errors`
/// one pair rather than two unrelated regions.
///
/// A form with NO model matches every `errors` node in its template: there is
/// one error summary and nothing else it could belong to. An `errors` node
/// with no name matches nothing -- an unnamed receiver is not evidence.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn modelMatches(form_model: ?[]const u8, errors_model: ?[]const u8) bool {
    const form = form_model orelse return true;
    const errs = errors_model orelse return false;
    return std.mem.eql(u8, stripSigil(form), stripSigil(errs));
}

fn stripSigil(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == '@') name[1..] else name;
}

/// A code fragment's source text, collapsed to one line and capped, so it can
/// ride in a `//` comment. Runs of whitespace become one space; the cap is a
/// generous 160 bytes because the point is a legible reminder of what the
/// island replaced, not a faithful copy (the Rails app is still the source of
/// truth for that).
///
/// Contract 1 (self-freeing): the returned line is the only allocation.
fn oneLine(gpa: Allocator, code: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var space = false;
    for (code) |ch| {
        if (std.ascii.isWhitespace(ch)) {
            space = out.items.len > 0;
            continue;
        }
        if (space) try out.append(gpa, ' ');
        space = false;
        if (out.items.len == 160) {
            try out.appendSlice(gpa, "...");
            break;
        }
        try out.append(gpa, ch);
    }
    return out.toOwnedSlice(gpa);
}

/// The finding Stage 1 derived at this exact source position, or `null`.
///
/// Public since #167 Stage 3: `scaffold.zig` walks the same node streams to
/// decide which answered findings become bindings, and it must reach the id
/// the SAME way this file does. Re-deriving it there from `line`/`col` by
/// hand is exactly the drift ruling S22's "never re-derive ids" forbids.
///
/// Matched on the id's `loc` tail rather than on `line`/`col` fields because
/// `Finding` carries only `line`: `findings.zig` folds line+col into the id
/// (`…​.L3C5`), and that string is unique per node by construction (see its
/// `lessThan` doc). The leading `.` is part of the needle so `L3C5` cannot
/// match the tail of `L13C5`. `loc` contains neither `%` nor `.`, so
/// `escapePart` is the identity on it and no un-escaping is needed.
///
/// Contract 3 (caller-buffer): allocates nothing; the result borrows
/// `finding_list`.
pub fn findingIdFor(finding_list: []const findings.Finding, path: []const u8, line: u64, col: u64) ?[]const u8 {
    var buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, ".L{d}C{d}", .{ line, col }) catch return null;
    for (finding_list) |f| {
        if (!std.mem.eql(u8, f.path, path)) continue;
        if (std.mem.endsWith(u8, f.id, needle)) return f.id;
    }
    return null;
}

// ---- the walk ------------------------------------------------------------

const List = std.ArrayListUnmanaged(u8);

/// One open block. `close` is the static markup the `block_end` appends
/// (`</div>` for a `content_for` block, nothing for a finding region, whose
/// own `end` marker `emitted` covers). `prev_sink` is non-null only for the
/// one frame that redirects output -- a view's `content_for :head`.
const Frame = struct {
    close: []const u8,
    is_finding: bool,
    owns_finding: bool = false,
    emitted: bool,
    prev_sink: ?*List,
};

/// The walk's mutable state. Every method on it appends into a buffer the
/// caller of `convert` will own (`sink`/`head`) or into one of this struct's
/// own lists, so they all inherit `convert`'s **contract 2 (owned-result)**
/// rather than each declaring one: nothing here allocates something that
/// escapes except through `Output`, and `deinit` releases whatever an early
/// `OutOfMemory` left behind. `ids` holds BORROWED pointers into
/// `ctx.findings` (duped only when `Output` is assembled); `dropped` holds
/// owned strings that `finalizeOwned` hands over on the success path.
const Converter = struct {
    gpa: Allocator,
    ctx: Context,
    kind: Kind,
    /// Where the next byte goes. Swapped by a view's `content_for :x` (into
    /// that block's buffer) and, briefly, by a `<title>` rewrite.
    sink: *List,
    /// A view's named blocks, keyed by id. Each `Block` is heap-allocated so
    /// `sink` can point at one across an append to this list -- growing an
    /// `ArrayList` of by-value `List`s would dangle that pointer.
    blocks: std.ArrayListUnmanaged(*Block) = .empty,
    /// LAYOUT only: the block ids the converted layout declares, minus the
    /// two that are always synthesised (`head`, `main`). Borrowed from the
    /// node that named them.
    named_yields: std.ArrayListUnmanaged([]const u8) = .empty,
    /// LAYOUT only: a bare `yield` was converted in place, so the `id="main"`
    /// block already exists and `finishLayout` must not synthesise a second.
    saw_bare_yield: bool = false,
    /// Borrowed ids; duped only when the owned `Output` is assembled.
    ids: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Borrowed ids an island answered (#167 Stage 3), same lifetime rule as
    /// `ids`.
    bound: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The subset of `bound` that was answered by an ENCLOSING region's
    /// binding (#167 Stage 3, ruling S3-R6). Borrowed both ways, same
    /// lifetime rule as `ids`; handed to `Output.enclosed` as-is.
    enclosed: std.ArrayListUnmanaged(Enclosure) = .empty,
    /// One per bound region hit, in source order. `fields` is owned by the
    /// list element and handed to `Output`; `original` likewise.
    islands: std.ArrayListUnmanaged(IslandSpec) = .empty,
    /// Owned notes.
    dropped: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Partial paths currently being inlined -- the cycle guard.
    stack: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Active Stimulus `drop` extent and templates that already reported a
    /// Turbo Drive attribute removal.
    drop_identifiers: []const []const u8 = &.{},
    turbo_noted_paths: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Nesting depth of finding regions; only depth 0 emits a marker.
    finding_depth: usize = 0,
    /// Finding regions in scope that have a real id. Unlike
    /// `finding_depth`, this excludes id-less backstop regions.
    answerable_depth: usize = 0,
    /// Borrowed from the node that supplied it.
    title: ?[]const u8 = null,
    /// A `yield(:title)` replaced its enclosing `<title>` element wholesale,
    /// so everything up to and including the original `</title>` is being
    /// swallowed into `junk` (see `emitNamedYield`).
    consuming_title: bool = false,
    junk: List = .empty,
    title_prev_sink: ?*List = null,

    const Block = struct { name: []const u8, buf: List };

    fn deinit(c: *Converter) void {
        c.ids.deinit(c.gpa);
        c.bound.deinit(c.gpa);
        c.enclosed.deinit(c.gpa);
        for (c.islands.items) |s| {
            c.gpa.free(s.fields);
            c.gpa.free(s.original);
            if (s.port) |body| c.gpa.free(body);
        }
        c.islands.deinit(c.gpa);
        for (c.dropped.items) |d| c.gpa.free(d);
        c.dropped.deinit(c.gpa);
        c.stack.deinit(c.gpa);
        c.turbo_noted_paths.deinit(c.gpa);
        c.named_yields.deinit(c.gpa);
        for (c.blocks.items) |b| {
            b.buf.deinit(c.gpa);
            c.gpa.destroy(b);
        }
        c.blocks.deinit(c.gpa);
        c.junk.deinit(c.gpa);
    }

    /// The buffer for block `name`, created empty on first use. Borrowed
    /// `name` (it points at a node's own storage or at a static literal).
    fn block(c: *Converter, name: []const u8) Allocator.Error!*List {
        for (c.blocks.items) |b| {
            if (std.mem.eql(u8, b.name, name)) return &b.buf;
        }
        const fresh = try c.gpa.create(Block);
        errdefer c.gpa.destroy(fresh);
        fresh.* = .{ .name = name, .buf = .empty };
        try c.blocks.append(c.gpa, fresh);
        return &fresh.buf;
    }

    fn blockContents(c: *Converter, name: []const u8) []const u8 {
        for (c.blocks.items) |b| {
            if (std.mem.eql(u8, b.name, name)) return b.buf.items;
        }
        return "";
    }

    fn put(c: *Converter, text: []const u8) Allocator.Error!void {
        try c.sink.appendSlice(c.gpa, text);
    }

    fn putEscaped(c: *Converter, text: []const u8) Allocator.Error!void {
        try escapeInto(c.gpa, c.sink, text);
    }

    fn putFmt(c: *Converter, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const s = try std.fmt.allocPrint(c.gpa, fmt, args);
        defer c.gpa.free(s);
        try c.sink.appendSlice(c.gpa, s);
    }

    fn note(c: *Converter, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const s = try std.fmt.allocPrint(c.gpa, fmt, args);
        errdefer c.gpa.free(s);
        try c.dropped.append(c.gpa, s);
    }

    fn noteTurboDrop(c: *Converter, path: []const u8) Allocator.Error!void {
        for (c.turbo_noted_paths.items) |seen| if (std.mem.eql(u8, seen, path)) return;
        try c.turbo_noted_paths.append(c.gpa, path);
        try c.note("data-turbo attributes dropped; Turbo Drive is ordinary navigation here", .{});
    }

    /// Applies the two lexical attribute policies before bytes enter any
    /// output sink. The returned slice is always owned by the caller.
    fn filtered(c: *Converter, path: []const u8, text: []const u8) Allocator.Error![]u8 {
        const turbo = try stripLexicalAttrs(c.gpa, text, .turbo, &.{});
        defer c.gpa.free(turbo.bytes);
        if (turbo.dropped) try c.noteTurboDrop(path);
        if (c.drop_identifiers.len == 0) return try c.gpa.dupe(u8, turbo.bytes);
        const stimulus = try stripLexicalAttrs(c.gpa, turbo.bytes, .stimulus, c.drop_identifiers);
        return stimulus.bytes;
    }

    fn putFiltered(c: *Converter, path: []const u8, text: []const u8) Allocator.Error!void {
        const clean = try c.filtered(path, text);
        defer c.gpa.free(clean);
        try c.put(clean);
    }

    fn emitText(c: *Converter, path: []const u8, text: []const u8) Allocator.Error!void {
        const clean = try c.filtered(path, text);
        defer c.gpa.free(clean);
        if (c.consuming_title) {
            // Everything between the rewritten `<title>` and the original
            // `</title>` is swallowed: `:text` fills an element that must be
            // EMPTY, so a `<title><%= yield(:title) %> · MyApp</title>` has
            // nowhere to keep the ` · MyApp`.
            if (std.mem.indexOf(u8, clean, "</title>")) |at| {
                try c.put(clean[0..at]);
                try c.endTitleConsume();
                try c.put(clean[at + "</title>".len ..]);
                return;
            }
            try c.put(clean);
            return;
        }
        try c.put(clean);
    }

    fn beginTitleConsume(c: *Converter) void {
        c.junk.clearRetainingCapacity();
        c.title_prev_sink = c.sink;
        c.sink = &c.junk;
        c.consuming_title = true;
    }

    fn endTitleConsume(c: *Converter) Allocator.Error!void {
        if (!c.consuming_title) return;
        c.consuming_title = false;
        c.sink = c.title_prev_sink.?;
        c.title_prev_sink = null;
        const suffix = std.mem.trim(u8, c.junk.items, " \t\r\n");
        if (suffix.len > 0) try c.note("<title> suffix '{s}' dropped: :text needs an empty element", .{suffix});
        c.junk.clearRetainingCapacity();
    }

    /// Records the node's finding id (always, even when nested) and emits the
    /// opening marker (only at depth 0). Returns true when the marker was a
    /// `rails:finding` -- the only case that gets a paired `rails:end`.
    fn openRegion(c: *Converter, path: []const u8, n: fragments.Node) Allocator.Error!bool {
        const id = findingIdFor(c.ctx.findings, path, n.line, n.col);
        if (id) |x| try c.ids.append(c.gpa, x);
        if (c.finding_depth > 0) return false;
        if (id) |x| {
            try c.putFmt("<!-- rails:finding {s} -->", .{x});
            return true;
        }
        try c.unmapped(n);
        return false;
    }

    fn unmapped(c: *Converter, n: fragments.Node) Allocator.Error!void {
        try c.putFmt("<!-- rails:unmapped {s} L{d}C{d} -->", .{ @tagName(n.kind), n.line, n.col });
    }

    /// A placeholder for a node that opens no block: marker, then (for a real
    /// finding) its immediate `end`, so the region is well-formed even when
    /// it is empty.
    fn inlineRegion(c: *Converter, path: []const u8, n: fragments.Node) Allocator.Error!void {
        if (try c.openRegion(path, n)) try c.put("<!-- rails:end -->");
    }

    fn drop(c: *Converter, n: fragments.Node, why: []const u8) Allocator.Error!void {
        const name = n.name orelse "";
        try c.putFmt("<!-- rails: {s} dropped; {s} -->", .{ name, why });
        try c.note("{s} dropped", .{name});
    }

    fn setTitle(c: *Converter, text: []const u8) void {
        if (c.title == null) c.title = text;
    }

    /// Whether a view's `content_for :name` has a block to become. `head` and
    /// `main` are unconditional because `finishLayout` guarantees every
    /// converted layout declares both, which also keeps a view convertible
    /// before its layout has been converted (`layout_blocks` empty).
    /// (`main` is collected like any other block and then folded into the
    /// body by `convert`, because the body IS the main block -- Rails appends
    /// a `content_for :main` to whatever the template rendered.)
    fn fillsBlock(c: *Converter, name: []const u8) bool {
        if (std.mem.eql(u8, name, "head") or std.mem.eql(u8, name, "main")) return true;
        for (c.ctx.layout_blocks) |b| {
            if (std.mem.eql(u8, b, name)) return true;
        }
        return false;
    }

    /// The binding answering the node at this position, or null.
    ///
    /// Keyed on the finding id, so the id stays the one join key between the
    /// manifest, the decisions file and this walk (ruling S22's mechanism,
    /// and the reason ids are never re-derived).
    ///
    /// A binding carrying `at` is keyed on the POSITION instead, and only on
    /// it -- see `Binding.at` for why the auth journey has no id to join on,
    /// and why a fallback to the id would be wrong rather than merely
    /// redundant: every journey binding carries the SAME `finding_id`, so an
    /// id fallback would let the sign-in binding claim the sign-up form.
    fn bindingAt(c: *Converter, path: []const u8, n: fragments.Node) ?Binding {
        for (c.ctx.bindings) |b| {
            const at = b.at orelse continue;
            if (at.line == n.line and at.col == n.col and std.mem.eql(u8, at.path, path)) return b;
        }
        const id = findingIdFor(c.ctx.findings, path, n.line, n.col) orelse return null;
        for (c.ctx.bindings) |b| {
            if (b.at != null) continue;
            if (std.mem.eql(u8, b.finding_id, id)) return b;
        }
        return null;
    }

    /// Whether `n` is a `link_to`/`button_to` that SUBMITS rather than
    /// navigates. `false` for every other kind.
    ///
    /// The rule is `findings.nodeVerb`'s, not a restatement of it: that is
    /// the predicate that raised the link's `RAILS_BACKEND_ENDPOINT`, and
    /// asking the same function here is what keeps "which links are a
    /// question" and "which links get a region" from drifting apart (the
    /// asset arm does the same with `resolve.isAbsoluteAssetLiteral`). The
    /// finding itself is not consulted, on purpose: `openRegion` looks it up
    /// and falls back to `rails:unmapped` when it is missing, which keeps the
    /// route unfinished either way.
    ///
    /// Borrows `nodeVerb`'s contract 1: its one allocation is freed here, so
    /// nothing escapes.
    fn linkSubmits(c: *Converter, n: fragments.Node) Allocator.Error!bool {
        if (n.kind != .link_to) return false;
        const verb = (try findings.nodeVerb(c.gpa, n)) orelse return false;
        c.gpa.free(verb);
        return true;
    }

    /// Records every finding id in `region` as ANSWERED by an island, and
    /// emits nothing: the region's markup is replaced by the island, so its
    /// `<%= %>` fragments have no output of their own.
    ///
    /// Applied bindings also consume block locals with their owner region;
    /// the ordinary walk now follows the same ownership rule while a finding
    /// is still open, so neither path invents an id-less nested question.
    ///
    /// `by` is the finding the region's own binding was keyed on. Every OTHER
    /// id in the region is recorded in `c.enclosed` as well, because ruling
    /// S3-R6 turns on that distinction: an answer on the region's own id is
    /// the answer, while an answer on an id the region swallowed is a second
    /// answer to the same question and has to be accepted as superseded
    /// rather than reported as an unbuilt binding.
    ///
    /// Contract 2 (owned-result), inherited from `convert`: it appends
    /// BORROWED ids to `c.bound` (pointers into `ctx.findings`) and allocates
    /// nothing of its own beyond those lists' growth; `Output.bound_finding_ids`
    /// is where they are duped, and `freeOutput` is the release.
    fn bindRegion(
        c: *Converter,
        path: []const u8,
        region: []const fragments.Node,
        by: []const u8,
    ) Allocator.Error!void {
        for (region) |m| {
            if (m.text != null) continue;
            const mid = findingIdFor(c.ctx.findings, path, m.line, m.col) orelse continue;
            try c.bound.append(c.gpa, mid);
            if (std.mem.eql(u8, mid, by)) continue;
            // Deduped on the spot rather than in `finalize`: a template graph
            // that inlines one partial twice hits the same region twice, and
            // the list is a handful of entries at most.
            var seen = false;
            for (c.enclosed.items) |e| {
                if (std.mem.eql(u8, e.id, mid) and std.mem.eql(u8, e.by, by)) seen = true;
            }
            if (!seen) try c.enclosed.append(c.gpa, .{ .id = mid, .by = by });
        }
    }

    /// Data islands replace rendered partials as part of the same region, so
    /// their findings are enclosed by the outer ivar answer even though the
    /// nodes live in a different template stream.
    fn bindRegionDeep(c: *Converter, path: []const u8, region: []const fragments.Node, by: []const u8) Allocator.Error!void {
        try c.bindRegion(path, region, by);
        for (region) |node| {
            if (node.text != null or (node.kind != .render_partial and node.kind != .render_partial_locals and node.kind != .render_dynamic)) continue;
            const target = node.name orelse continue;
            const partial = partialPathIn(c.ctx.fragments, path, target) orelse continue;
            var cyclic = false;
            for (c.stack.items) |seen| {
                if (std.mem.eql(u8, seen, partial)) cyclic = true;
            }
            if (cyclic) continue;
            const tpl = templateFor(c.ctx.fragments, partial) orelse continue;
            if (tpl.error_message != null or tpl.unreadable != null) continue;
            try c.stack.append(c.gpa, partial);
            try c.bindRegionDeep(partial, tpl.nodes, by);
            _ = c.stack.pop();
        }
    }

    fn bindHead(c: *Converter, b: Binding) Allocator.Error!void {
        try c.bound.append(c.gpa, b.finding_id);
    }

    fn appendSimpleIsland(c: *Converter, path: []const u8, b: Binding, head: fragments.Node, extent: ?[]const u8) Allocator.Error!void {
        const original = try oneLine(c.gpa, head.code);
        errdefer c.gpa.free(original);
        const fields = try c.gpa.alloc(Field, 0);
        errdefer c.gpa.free(fields);
        try c.islands.append(c.gpa, .{
            .island = b.island,
            .fields = fields,
            .errors_model = null,
            .submit_label = "Save",
            .click = null,
            .binding = b,
            .original = original,
            .line = head.line,
            .source = path,
            .extent = extent,
        });
    }

    fn putIslandOpen(c: *Converter, island: []const u8, b: Binding) Allocator.Error!void {
        try c.putFmt("<island src=\"{s}\" {s}", .{ island, b.directive });
        if (b.props) |props| try c.putFmt(" :props='{s}'", .{props});
        try c.put(">");
    }

    fn flattenedStimulusPath(c: *Converter, identifier: []const u8) Allocator.Error![]u8 {
        var stem: List = .empty;
        defer stem.deinit(c.gpa);
        var i: usize = 0;
        while (i < identifier.len) {
            if (identifier[i] == '-') {
                try stem.append(c.gpa, '_');
                while (i < identifier.len and identifier[i] == '-') : (i += 1) {}
            } else {
                try stem.append(c.gpa, identifier[i]);
                i += 1;
            }
        }
        return try std.fmt.allocPrint(c.gpa, "components/stimulus/{s}.island.tsx", .{stem.items});
    }

    fn emitWrapped(c: *Converter, path: []const u8, b: Binding, region: []const fragments.Node, locals: []const fragments.Attr) Allocator.Error!void {
        const head = region[0];
        try c.bindHead(b);
        try c.appendSimpleIsland(path, b, head, head.code);
        const single = [_][]const u8{""};
        const identifiers: []const []const u8 = if (b.kind == .stimulus and b.identifiers.len > 0) b.identifiers else &single;
        for (identifiers, 0..) |identifier, index| {
            if (index == 0) {
                try c.putIslandOpen(b.island, b);
            } else {
                const island = try c.flattenedStimulusPath(identifier);
                defer c.gpa.free(island);
                try c.putIslandOpen(island, b);
            }
        }
        const has_end = region.len > 1 and region[region.len - 1].kind == .block_end;
        if (head.kind == .stimulus) try c.putFiltered(path, head.code);
        if (has_end) try c.walk(path, region[1 .. region.len - 1], locals);
        if (head.kind == .stimulus and has_end) try c.putFiltered(path, region[region.len - 1].code);
        // Both helper and HTML Turbo frames discard their Rails wrapper: the
        // generated island renders its own id-bearing div. A helper's body
        // has already been walked above; a self-closing frame has none.
        var close_count = identifiers.len;
        while (close_count > 0) : (close_count -= 1) try c.put("</island>");
    }

    fn emitInline(c: *Converter, path: []const u8, b: Binding, region: []const fragments.Node, locals: []const fragments.Attr) Allocator.Error!void {
        const head = region[0];
        try c.bindHead(b);
        const has_end = region.len > 1 and region[region.len - 1].kind == .block_end;
        const html_frame = head.value != null and std.mem.eql(u8, head.value.?, "turbo-frame");
        if (html_frame) {
            try c.putFiltered(path, head.code);
        } else {
            try c.put("<turbo-frame id=\"");
            try c.putEscaped(head.name orelse "");
            try c.put("\">");
        }
        if (has_end) try c.walk(path, region[1 .. region.len - 1], locals);
        if (html_frame and has_end) try c.putFiltered(path, region[region.len - 1].code) else try c.put("</turbo-frame>");
    }

    fn emitDropped(c: *Converter, path: []const u8, b: Binding, region: []const fragments.Node, locals: []const fragments.Attr) Allocator.Error!void {
        const head = region[0];
        try c.bindHead(b);
        const previous = c.drop_identifiers;
        c.drop_identifiers = b.identifiers;
        defer c.drop_identifiers = previous;
        try c.putFiltered(path, head.code);
        const has_end = region.len > 1 and region[region.len - 1].kind == .block_end;
        if (has_end) try c.walk(path, region[1 .. region.len - 1], locals);
        if (has_end) try c.putFiltered(path, region[region.len - 1].code);
    }

    /// An `errors` region a bound form's island takes over, and the form it
    /// belongs to.
    /// `by` is the absorbing form's binding id -- what `bindRegion` records as
    /// the answer that supersedes an answer on anything in this region.
    const Absorbed = struct { start: usize, end: usize, form: usize, model: ?[]const u8, by: []const u8 };

    /// Which `errors` regions in THIS node stream a bound form absorbs.
    ///
    /// Rails writes the error summary as a sibling of the form, above it --
    /// `app/views/registrations/new.html.erb` in the fixture does exactly
    /// that -- so it is not inside the region the island replaces and would
    /// otherwise survive as markup rendering nothing (the island already
    /// renders the backend's `ZigbaseError.data`). An `errors` node is
    /// absorbed when its model name matches the form's (`@user.errors` and
    /// `form_with model: @user`), or unconditionally when the form declares
    /// no model at all -- a model-less form has one error summary and there
    /// is nothing else it could belong to.
    ///
    /// Contract 2 (owned-result): the returned list is the caller's to
    /// `deinit`; every string in it is borrowed from `nodes`.
    fn absorbedErrors(
        c: *Converter,
        path: []const u8,
        nodes: []const fragments.Node,
    ) Allocator.Error!std.ArrayListUnmanaged(Absorbed) {
        var out: std.ArrayListUnmanaged(Absorbed) = .empty;
        errdefer out.deinit(c.gpa);
        if (c.ctx.bindings.len == 0) return out;
        for (nodes, 0..) |n, fi| {
            if (n.text != null or n.kind != .form) continue;
            const form_binding = c.bindingAt(path, n) orelse continue;
            for (nodes, 0..) |e, ei| {
                if (e.text != null or e.kind != .errors) continue;
                if (ei > fi and ei <= (matchingEnd(nodes, fi) orelse fi)) continue;
                if (!modelMatches(n.name, e.name)) continue;
                try out.append(c.gpa, .{
                    .start = ei,
                    .end = if (opensBlock(e)) (matchingEnd(nodes, ei) orelse ei) else ei,
                    .form = fi,
                    .model = e.name,
                    .by = form_binding.finding_id,
                });
            }
        }
        return out;
    }

    /// Replaces one bound region with its `<island>` and records the spec
    /// `scaffold.zig` turns into the island's source.
    ///
    /// `client:load` and not `client:visible`: the region this replaces is a
    /// form or a mutating control the page's own markup no longer carries,
    /// so deferring hydration would leave a visitor looking at markup that
    /// does nothing until it scrolls into view.
    ///
    /// Contract 2 (owned-result), inherited from `convert`: the `IslandSpec`
    /// it appends owns `fields`, `original`, and for a data island `port`;
    /// `freeOutput` releases them. On an `OutOfMemory`
    /// after either is built, the `errdefer`s here release it and nothing
    /// escapes half-owned.
    fn emitIsland(
        c: *Converter,
        path: []const u8,
        b: Binding,
        region: []const fragments.Node,
        errors_model: ?[]const u8,
    ) Allocator.Error!void {
        // The props literal is emitted VERBATIM inside single quotes, which is
        // the same shape `docs/islands.md` documents and `site/` writes by
        // hand. It is built by `scaffold.zig` out of a fixed vocabulary (a
        // mode word), never out of author text, so there is no quote in it to
        // close the attribute early.
        if (b.props) |p| {
            try c.putFmt("<island src=\"{s}\" {s} :props='{s}'></island>", .{ b.island, b.directive, p });
        } else {
            try c.putFmt("<island src=\"{s}\" {s}></island>", .{ b.island, b.directive });
        }
        if (b.kind == .data_list)
            try c.bindRegionDeep(path, region, b.finding_id)
        else
            try c.bindRegion(path, region, b.finding_id);

        var owned_port: ?[]u8 = null;
        errdefer if (owned_port) |body| c.gpa.free(body);
        if (b.kind == .data_list) {
            const body_region = if (!region[0].output and region.len > 1) region[1 .. region.len - 1] else region;
            const body = try port.recordBody(c.gpa, c.ctx, path, body_region, b.aliases);
            if (body.unportable) |bad| {
                c.gpa.free(bad.why);
                c.gpa.free(body.js);
            } else {
                owned_port = body.js;
            }
        }

        var fields: std.ArrayListUnmanaged(Field) = .empty;
        errdefer fields.deinit(c.gpa);
        var submit_label: []const u8 = "Save";
        for (region) |m| {
            if (m.text != null or m.kind != .form_field) continue;
            const helper = m.name orelse continue;
            if (std.mem.eql(u8, helper, "submit")) {
                if (m.args.len > 0) submit_label = m.args[0];
                continue;
            }
            try fields.append(c.gpa, .{
                .helper = helper,
                .name = if (m.args.len > 0) m.args[0] else "",
                .label = if (m.args.len > 1) m.args[1] else null,
                .options = if (std.mem.eql(u8, helper, "select") and m.args.len > 1) m.args[1..] else &.{},
            });
        }
        // A bound `link_to`/`button_to` has no fields at all; its text is the
        // button's label, which is exactly what `submit_label` means here.
        const head = region[0];
        var click: ?Click = null;
        if (head.kind == .link_to) {
            if (head.args.len > 0) submit_label = head.args[0];
            // The operator's answer still stands and the island is still
            // written -- refusing the binding would leave them nothing to
            // do but edit the ERB. What must not happen is silence: the
            // page says it beside the island, and the route's note in
            // MIGRATION.handoff.json says it too (the report renders the
            // classifier's reason, not this note).
            if (hasSentinel(head.attrs, "data")) {
                try c.put("<!-- rails: data: on this control was not recovered; a confirm guard may be missing -->");
                try c.note(
                    "{s}:{d}: nested data: on a bound control was not recovered; a confirm guard may be missing",
                    .{ path, head.line },
                );
            }
            click = .{
                .confirm = confirmText(head.attrs),
                // `classify_link` puts the link TEXT first and the route
                // helper's own literal arguments after it, so `args[1]` is
                // the record the helper was called with -- when it was called
                // with one at all.
                .record_id = if (head.name != null and head.args.len > 1) head.args[1] else null,
            };
        }

        const original = try oneLine(c.gpa, head.code);
        errdefer c.gpa.free(original);
        const owned_fields = try fields.toOwnedSlice(c.gpa);
        errdefer c.gpa.free(owned_fields);
        try c.islands.append(c.gpa, .{
            .island = b.island,
            .fields = owned_fields,
            .errors_model = errors_model,
            .submit_label = submit_label,
            .click = click,
            .binding = b,
            .original = original,
            .line = head.line,
            .source = path,
            .port = owned_port,
        });
        owned_port = null;
    }

    fn walk(
        c: *Converter,
        path: []const u8,
        nodes: []const fragments.Node,
        locals: []const fragments.Attr,
    ) Allocator.Error!void {
        var frames: std.ArrayListUnmanaged(Frame) = .empty;
        defer frames.deinit(c.gpa);

        // Named for what it holds, not for the flag: `Binding.absorbed` a few
        // lines below means "another binding's island already renders this
        // region", which is a different fact about a different thing. One
        // `absorbed` covering both read as if the loop were consulting the
        // flag it is standing next to.
        var absorbed_errors = try c.absorbedErrors(path, nodes);
        defer absorbed_errors.deinit(c.gpa);

        var i: usize = 0;
        while (i < nodes.len) : (i += 1) {
            const n = nodes[i];
            if (n.text) |t| {
                try c.emitText(path, t);
                continue;
            }
            switch (n.kind) {
                .block_end => {
                    // A `<title>` that opened inside this block and never
                    // closed ends HERE. Left running, its saved sink would
                    // outlive the frame that owns it, and the first `</title>`
                    // anywhere further down the template would restore output
                    // into a block that has already been closed and emitted.
                    try c.endTitleConsume();
                    // A stray `end` with no opener on this stream cannot
                    // close anything; dropping it is the only option that
                    // keeps the rest of the template converting.
                    const f = frames.pop() orelse continue;
                    if (f.owns_finding) c.answerable_depth -= 1;
                    if (f.is_finding) c.finding_depth -= 1;
                    if (f.close.len > 0) try c.put(f.close);
                    if (f.emitted) try c.put("<!-- rails:end -->");
                    if (f.prev_sink) |p| c.sink = p;
                    continue;
                },
                .block_else => {
                    // Only inside a region whose marker we actually wrote:
                    // an `else` floating outside one marks nothing.
                    if (frames.items.len > 0 and frames.items[frames.items.len - 1].emitted) {
                        try c.put("<!-- rails:else -->");
                    }
                    continue;
                },
                else => {},
            }

            const opens = opensBlock(n);

            // A view's own `content_for :title` / `:head` are not markup at
            // all -- one becomes frontmatter, the other a separate block --
            // so they are intercepted before the generic conversion. Only at
            // the top level: a `content_for` nested inside a control block is
            // conditional, and lifting it would assert something the template
            // does not.
            if (c.kind == .view and n.kind == .content_for and frames.items.len == 0) {
                const name = n.name orelse "";
                if (std.mem.eql(u8, name, "title")) {
                    const block_end = if (opens) matchingEnd(nodes, i) else null;
                    if (n.value) |v| {
                        c.setTitle(v);
                        continue;
                    }
                    if (block_end) |e| {
                        if (singleLiteralChild(nodes[i + 1 .. e])) |t| {
                            c.setTitle(t);
                            i = e;
                            continue;
                        }
                    }
                    // A title this stage cannot evaluate is a GAP, not a
                    // title, and it must not fall through to the generic
                    // `content_for` conversion either: a `<div id="title">`
                    // in the middle of the `id="main"` block is not a
                    // SuperHTML block (those are top-level only) and would
                    // render the computed title's markup inline as if it were
                    // page content. Its dedicated finding makes the swallowed
                    // block acknowledgeable; `openRegion` retains the old
                    // unmapped fallback for incomplete discovery.
                    const ids_before = c.ids.items.len;
                    const emitted = try c.openRegion(path, n);
                    const owns_finding = c.ids.items.len > ids_before;
                    // Rails captures this body for the title; it is never
                    // page markup. Skip the complete extent after emitting
                    // the question so literal runs cannot leak into `main`.
                    if (block_end) |e| {
                        if (emitted) try c.put("<!-- rails:end -->");
                        i = e;
                        continue;
                    }
                    if (opens) {
                        try frames.append(c.gpa, .{ .close = "", .is_finding = true, .owns_finding = owns_finding, .emitted = emitted, .prev_sink = null });
                        c.finding_depth += 1;
                        if (owns_finding) c.answerable_depth += 1;
                    } else if (emitted) {
                        try c.put("<!-- rails:end -->");
                    }
                    continue;
                } else if (c.fillsBlock(name)) {
                    // Ruling S9: a `content_for` naming a block the layout
                    // declares becomes THAT block, collected on the side and
                    // emitted at the top level of the extending template --
                    // never inline, where SuperHTML would reject it
                    // (`block_cannot_be_inlined`).
                    const buf = try c.block(name);
                    if (opens) {
                        try frames.append(c.gpa, .{ .close = "", .is_finding = false, .emitted = false, .prev_sink = c.sink });
                        c.sink = buf;
                        continue;
                    }
                    try escapeInto(c.gpa, buf, n.value orelse "");
                    continue;
                } else {
                    // No `<super>` anywhere in the layout carries this id, so
                    // there is nothing for the block to fill. Rails renders
                    // nothing for such a `content_for` either -- the content
                    // is simply never yielded -- so dropping it matches the
                    // app's own behaviour rather than inventing markup.
                    try c.note(dropped_content_for_prefix ++ "{s} dropped: the layout declares no block with that id", .{name});
                    if (opens) {
                        if (matchingEnd(nodes, i)) |e| {
                            i = e;
                            continue;
                        }
                    }
                    continue;
                }
            }

            // #167 Stage 3, before the generic finding arm: a region an
            // operator bound to a backend operation is not converted at all.
            // The island replaces it wholesale -- no marker, no `rails:end`,
            // no placeholder -- and every id inside it is ANSWERED.
            if (isBindableKind(n.kind)) {
                var consumed = false;
                for (absorbed_errors.items) |a| {
                    if (a.start != i) continue;
                    try c.bindRegion(path, nodes[i .. a.end + 1], a.by);
                    i = a.end;
                    consumed = true;
                    break;
                }
                if (!consumed) {
                    if (c.bindingAt(path, n)) |b| {
                        const end = if (opens) (matchingEnd(nodes, i) orelse i) else i;
                        if (b.absorbed) {
                            // Another binding's island already renders this
                            // region. Bind it -- the answer is real and has to
                            // settle -- and emit nothing at all.
                            try c.bindRegion(path, nodes[i .. end + 1], b.finding_id);
                        } else {
                            var model: ?[]const u8 = null;
                            for (absorbed_errors.items) |a| {
                                if (a.form == i) model = a.model;
                            }
                            const region = nodes[i .. end + 1];
                            if (b.kind == .@"inline") {
                                try c.emitInline(path, b, region, locals);
                            } else if (b.kind == .drop) {
                                try c.emitDropped(path, b, region, locals);
                            } else if (b.wrap) {
                                try c.emitWrapped(path, b, region, locals);
                            } else {
                                try c.emitIsland(path, b, region, model);
                            }
                        }
                        i = end;
                        consumed = true;
                    }
                }
                if (consumed) continue;
            }

            // An UNBOUND link that submits is the other half of the gate
            // above: it raised a `RAILS_BACKEND_ENDPOINT` nobody has answered,
            // so it is a question, and a question is a region -- not the
            // `<a href>` `emitLink` would make of it, which navigates (GET) to
            // the route the control was supposed to DELETE and, having
            // recorded no id, let the route report `migrated` with the
            // finding still standing (round 4).
            if (isFindingKind(n.kind) or try c.linkSubmits(n)) {
                const ids_before = c.ids.items.len;
                const emitted = try c.openRegion(path, n);
                const owns_finding = c.ids.items.len > ids_before;
                const element = isElementNode(n);
                if (element) try c.putFiltered(path, n.code);
                if (opens) {
                    const close = if (element) blk: {
                        const end = matchingEnd(nodes, i) orelse break :blk "";
                        break :blk nodes[end].code;
                    } else "";
                    try frames.append(c.gpa, .{ .close = close, .is_finding = true, .owns_finding = owns_finding, .emitted = emitted, .prev_sink = null });
                    c.finding_depth += 1;
                    if (owns_finding) c.answerable_depth += 1;
                } else if (emitted) {
                    try c.put("<!-- rails:end -->");
                }
                continue;
            }

            if (n.kind == .content_for and opens) {
                const name = n.name orelse "";
                try c.put("<div id=\"");
                try c.putEscaped(name);
                try c.put("\">");
                try frames.append(c.gpa, .{ .close = "</div>", .is_finding = false, .emitted = false, .prev_sink = null });
                continue;
            }

            try c.emitLeaf(path, n, locals);
            // A non-finding, non-`content_for` node that nonetheless opened a
            // block (a helper called with `do … end`): its body converts in
            // place and its `end` needs a frame to pop, or the NEXT enclosing
            // block would be closed by it.
            if (opens) {
                try frames.append(c.gpa, .{ .close = "", .is_finding = false, .emitted = false, .prev_sink = null });
            }
        }
    }

    fn emitLeaf(
        c: *Converter,
        path: []const u8,
        n: fragments.Node,
        locals: []const fragments.Attr,
    ) Allocator.Error!void {
        switch (n.kind) {
            .literal => if (n.output) try c.putEscaped(n.value orelse ""),
            .i18n => {
                if (n.missing) return c.inlineRegion(path, n);
                try c.putEscaped(n.value orelse "");
            },
            .yield => {
                try c.put("<div id=\"main\"><super></div>");
                c.saw_bare_yield = true;
            },
            .yield_named => try c.emitNamedYield(n),
            .content_for => {
                // `provide(:x, "literal")` -- a block-less content_for. (The
                // view-level `:title`/`:head` cases never reach here.)
                const name = n.name orelse "";
                try c.put("<div id=\"");
                try c.putEscaped(name);
                try c.put("\">");
                try c.putEscaped(n.value orelse "");
                try c.put("</div>");
            },
            .render_partial, .render_partial_locals => try c.inlinePartial(path, n),
            .route_helper => {
                const stem = n.name orelse return c.inlineRegion(path, n);
                const url = try resolve.routeUrl(c.gpa, c.ctx.routes, stem, n.args);
                const u = url orelse return c.inlineRegion(path, n);
                defer c.gpa.free(u);
                try c.putEscaped(u);
            },
            .link_to => try c.emitLink(path, n),
            .asset => try c.emitAsset(path, n),
            // The Rails JS entry has no static equivalent: `@z/runtime` and
            // the island bundle replace it wholesale, so keeping a link to a
            // Sprockets/importmap entry that will not exist in the target
            // tree would be worse than saying it is gone.
            .importmap => try c.drop(n, js_entry_reason),
            .csrf => try c.drop(n, csrf_reason),
            .local => {
                if (n.name) |name| {
                    for (locals) |l| {
                        if (std.mem.eql(u8, l.key, name)) return c.putEscaped(l.value);
                    }
                }
                // A block parameter inside an answerable outer region belongs
                // to that region's decision. Emitting an id-less marker for
                // it would invent a second question no decision can name;
                // the outer finding already preserves the whole source span
                // and an applied island replaces that span wholesale.
                if (c.answerable_depth > 0) return;
                // A local with nothing bound to it: the render site passed no
                // `locals:` (or not this key), so there is no value to
                // substitute and no finding of its own to point at.
                try c.unmapped(n);
            },
            // Handled by `walk`; unreachable is not used because a future
            // sidecar kind decoding as one of these must not crash a build.
            else => {},
        }
    }

    fn emitNamedYield(c: *Converter, n: fragments.Node) Allocator.Error!void {
        const name = n.name orelse "";
        if (std.mem.eql(u8, name, "title")) return c.emitTitleYield();
        // `yield :head` is handled ENTIRELY by `finishLayout`, which puts one
        // `<super>` inside the layout's `<head id="head">` whether or not the
        // Rails layout ever wrote `yield :head`. Emitting one here as well
        // would give the layout two `<super>`s under one id
        // (`two_supers_one_id`), and emitting one here INSTEAD would leave a
        // layout without the yield declaring no head block at all -- the
        // asymmetry that made a converted view's `<head id="head">` an
        // `UNBOUND TOP-LEVEL BLOCK` (ruling S7).
        if (std.mem.eql(u8, name, "head")) return;
        // `yield :main` names the block a bare `yield` produces, so it is
        // handled the same way -- at the author's own position, and marking
        // the block as placed. Falling through to the generic arm below would
        // record `main` in `named_yields` (putting it in `block_ids` twice)
        // and leave `saw_bare_yield` false, so `finishLayout` would synthesise
        // a SECOND `id="main"` block: `two_supers_one_id`.
        if (std.mem.eql(u8, name, "main")) {
            try c.put("<div id=\"main\"><super></div>");
            c.saw_bare_yield = true;
            return;
        }
        // Every other named yield is a real block. `<div>` rather than the
        // author's own element because the yield says nothing about what
        // element wrapped it, and a `<super>` must sit inside one carrying
        // the id (`super_parent_element_missing_id`).
        try c.put("<div id=\"");
        try c.putEscaped(name);
        try c.put("\"><super></div>");
        try c.named_yields.append(c.gpa, name);
    }

    /// `yield(:title)`. The page title lives in the `.smd`'s frontmatter, so
    /// the layout reads it with `:text` and the child supplies no block at
    /// all -- which is only expressible when the `<title>` element is
    /// otherwise EMPTY (`:text` replaces an element's whole content).
    ///
    /// So when this yield sits inside a `<title>`, the whole element is
    /// replaced and its surrounding text is swallowed with a `dropped` note
    /// (ruling S8): `<title><%= yield(:title) %> · MyApp</title>` used to emit
    /// the rewritten element AND a stray `</title>`, which SuperHTML rejects.
    /// Anywhere else, there is no element to make empty, so the value is
    /// interpolated through a `<ctx>` -- a wrapper that is itself never
    /// emitted (ruling S10).
    fn emitTitleYield(c: *Converter) Allocator.Error!void {
        const start = c.openTitleTag() orelse {
            try c.put("<ctx :text=\"$page.title\"></ctx>");
            return;
        };
        const gt = std.mem.indexOfScalarPos(u8, c.sink.items, start, '>') orelse start;
        // The replacement element carries `:text` and nothing else, so a
        // `<title data-turbo-track="reload">` loses its attributes. Small, but
        // it is the author's markup: say so rather than deleting it quietly.
        const attr_start = @min(start + "<title".len, gt);
        const attrs = std.mem.trim(u8, c.sink.items[attr_start..gt], " \t\r\n/");
        if (attrs.len > 0) try c.note("<title> attributes '{s}' dropped: the converted element carries only :text", .{attrs});
        if (gt + 1 <= c.sink.items.len) {
            const prefix = std.mem.trim(u8, c.sink.items[gt + 1 ..], " \t\r\n");
            if (prefix.len > 0) try c.note("<title> prefix '{s}' dropped: :text needs an empty element", .{prefix});
        }
        c.sink.items.len = start;
        try c.put("<title :text=\"$page.title\"></title>");
        c.beginTitleConsume();
    }

    /// Offset of the `<title` start tag this position sits inside, or null.
    /// "Inside" means the last `<title` start tag in the buffer has no
    /// `</title>` after it. The next byte must be `>` or whitespace so a
    /// hypothetical `<titlebar>` cannot match.
    fn openTitleTag(c: *Converter) ?usize {
        var found: ?usize = null;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, c.sink.items, at, "<title")) |idx| {
            at = idx + "<title".len;
            if (at < c.sink.items.len and c.sink.items[at] != '>' and !std.ascii.isWhitespace(c.sink.items[at])) continue;
            found = idx;
        }
        const start = found orelse return null;
        if (std.mem.indexOfPos(u8, c.sink.items, start, "</title>") != null) return null;
        return start;
    }

    fn emitLink(c: *Converter, path: []const u8, n: fragments.Node) Allocator.Error!void {
        // `classify_link` puts the link TEXT first and the route helper's own
        // literal arguments after it, so `args[1..]` is what fills the route's
        // placeholders.
        const text = if (n.args.len > 0) n.args[0] else "";
        var owned: ?[]const u8 = null;
        defer if (owned) |o| c.gpa.free(o);
        const href: []const u8 = blk: {
            if (n.name) |stem| {
                const rest: []const []const u8 = if (n.args.len > 1) n.args[1..] else &.{};
                const url = try resolve.routeUrl(c.gpa, c.ctx.routes, stem, rest);
                owned = url;
                break :blk url orelse "";
            }
            break :blk if (n.args.len > 1) n.args[1] else "";
        };
        if (href.len == 0) return c.inlineRegion(path, n);
        try c.put("<a href=\"");
        try c.putAttrValue(href);
        try c.put("\"");
        try c.emitAttrs(n.attrs, .drop_method);
        try c.put(">");
        try c.putEscaped(text);
        try c.put("</a>");
    }

    /// An attribute value the converter CONSTRUCTS from Rails data, as
    /// opposed to one it copies out of the template's own markup.
    ///
    /// In SuperHTML an ordinary attribute whose value starts with `$` is a
    /// Scripty EXPRESSION, not a literal (`docs/superhtml.md`: "an ordinary
    /// attribute with a `$` value is already dynamic"). A Rails
    /// `link_to "x", "$special"` or an `alt: "$5 off"` would therefore be
    /// evaluated as code and fail the build. Only the FIRST byte matters, and
    /// only there is it neutralised -- `&#36;` renders as `$` and is not a
    /// sigil.
    fn putAttrValue(c: *Converter, value: []const u8) Allocator.Error!void {
        if (value.len > 0 and value[0] == '$') {
            try c.put("&#36;");
            return c.putEscaped(value[1..]);
        }
        try c.putEscaped(value);
    }

    /// Whether the tag being written is an `<a>`, which has no `method`
    /// attribute to carry.
    const MethodAttr = enum { keep_method, drop_method };

    fn emitAttrs(c: *Converter, attrs: []const fragments.Attr, method: MethodAttr) Allocator.Error!void {
        // Source order, which `literal_attrs` preserves -- sorting them would
        // reorder the author's own markup for no benefit, and source order is
        // just as deterministic.
        for (attrs) |a| {
            // NEW-3. `nested_hash_sentinel` is this converter's own marker for
            // "the sidecar collapsed a nested hash and its contents are not in
            // the node stream". It is not content and must never reach a page:
            // rendered as an attribute value it is `form="{...}"`, which tells
            // a reader nothing, means nothing to a browser, and looks like
            // something the author wrote. The BOUND path already handles it --
            // `emitIsland` reports the loss and emits no markup -- but an
            // unbound control (a GET `button_to`, which raises no finding
            // because it mutates nothing) came straight through here.
            //
            // Dropped rather than reported, because there is nothing to
            // report: the collapsed option was `form:`/`html:` styling, and
            // unlike the bound `data:` case no guard can be hiding in it. The
            // author's other attributes on the same tag are untouched.
            if (std.mem.eql(u8, a.value, nested_hash_sentinel)) continue;
            // Task 4 round-4 O1: `method` is a `<form>` attribute, and Rails'
            // `button_to`/`link_to … method:` put it on the form or on
            // `data-method`, never on an anchor. Only the INERT spelling can
            // reach an `<a>` -- a mutating unbound link is a region (see
            // `mutationVerb`'s caller) and a bound one is an island -- so this
            // drops `method="get"`/`"head"`, which a browser ignores and a
            // reader could mistake for a real submit.
            if (method == .drop_method and std.mem.eql(u8, a.key, "method")) continue;
            try c.put(" ");
            try c.putEscaped(a.key);
            try c.put("=\"");
            try c.putAttrValue(a.value);
            try c.put("\"");
        }
    }

    /// The inside of a Scripty single-quoted string (`$site.asset('…')`).
    /// Scripty's tokenizer ends the string at the first unescaped quote and
    /// treats `\` as the escape (`Tokenizer.zig`'s `c == quote and last ==
    /// '\\'`), so a path containing either character has to carry it
    /// escaped -- otherwise `assets/it's.png` truncates the expression and
    /// the rest of the attribute becomes syntax errors.
    fn putScriptyString(c: *Converter, text: []const u8) Allocator.Error!void {
        for (text) |ch| switch (ch) {
            '\\' => try c.put("\\\\"),
            '\'' => try c.put("\\'"),
            else => try c.sink.append(c.gpa, ch),
        };
    }

    /// `$site.asset('<target>').link()`, quoted for Scripty.
    fn putAssetExpr(c: *Converter, target: []const u8) Allocator.Error!void {
        try c.put("$site.asset('");
        try c.putScriptyString(target);
        try c.put("').link()");
    }

    /// The URL half of an asset helper's markup: the `$site.asset(…)`
    /// expression for a local asset, or -- ruling S23 -- the literal itself
    /// for an absolute URL, which names a resource on another host and so has
    /// no target file to reference.
    fn putAssetUrl(c: *Converter, target: ?[]const u8, literal: []const u8) Allocator.Error!void {
        if (target) |t| return c.putAssetExpr(t);
        return c.putAttrValue(literal);
    }

    fn emitAsset(c: *Converter, path: []const u8, n: fragments.Node) Allocator.Error!void {
        const helper = n.name orelse return c.inlineRegion(path, n);
        if (std.mem.eql(u8, helper, "javascript_include_tag") or std.mem.eql(u8, helper, "favicon_link_tag")) {
            return c.drop(n, js_entry_reason);
        }
        // `stylesheet_link_tag "a", "b"` is one call and N stylesheets: Rails
        // emits a `<link>` per argument. Converting only `args[0]` silently
        // dropped every sheet after the first. Every other helper in this
        // family takes exactly one source, so the loop is a no-op for them --
        // and one unresolvable argument makes the WHOLE node a placeholder,
        // which is what keeps this in step with `findings.zig`'s
        // `RAILS_ASSET_TRANSFORM` row (one finding per node, not per arg).
        const args: []const []const u8 = if (n.args.len > 0) n.args else &.{""};
        for (args) |literal| {
            // Ruling S23, and `resolve.assetFor`'s own documented contract: an
            // absolute URL names a resource on another host. It resolves to
            // no local asset by construction, so asking `assetFor` about it
            // would turn every CDN reference in the app into an unresolved-
            // asset placeholder. Recognised HERE, before the lookup, with the
            // same predicate `findings.zig` uses so the two cannot drift.
            if (resolve.isAbsoluteAssetLiteral(literal)) continue;
            const found = resolve.assetFor(c.ctx.assets, helper, literal) orelse return c.inlineRegion(path, n);
            // `deterministic == false` means the asset EXISTS but its built
            // URL could not be derived without guessing (`assets.Asset`'s
            // doc). The target tree copies the source file, so a target path
            // is still computable -- but the operator has to confirm the
            // transform, which is exactly what `RAILS_ASSET_TRANSFORM` asks.
            if (!found.deterministic) return c.inlineRegion(path, n);
        }
        for (args) |literal| {
            // `null` target == "emit the literal", the absolute-URL case
            // above; every other argument reached the second loop only
            // because the first one resolved it deterministically.
            var target: ?[]const u8 = null;
            defer if (target) |t| c.gpa.free(t);
            if (!resolve.isAbsoluteAssetLiteral(literal)) {
                const found = resolve.assetFor(c.ctx.assets, helper, literal).?;
                target = try resolve.assetTargetPath(c.gpa, found.source);
            }
            if (std.mem.eql(u8, helper, "image_tag")) {
                try c.put("<img src=\"");
                try c.putAssetUrl(target, literal);
                try c.put("\"");
                try c.emitAttrs(n.attrs, .keep_method);
                try c.put(">");
                continue;
            }
            if (std.mem.eql(u8, helper, "stylesheet_link_tag")) {
                try c.put("<link rel=\"stylesheet\" href=\"");
                try c.putAssetUrl(target, literal);
                try c.put("\">");
                continue;
            }
            // `image_path`/`asset_path`/`asset_url` and the media/font
            // helpers: the author wrote the URL into their own markup, so
            // emit the URL expression and nothing else.
            try c.putAssetUrl(target, literal);
        }
    }

    fn inlinePartial(c: *Converter, path: []const u8, n: fragments.Node) Allocator.Error!void {
        const target = n.name orelse return c.unmapped(n);
        const p = c.partialPath(path, target) orelse return c.unmapped(n);
        // Rails renders a self-referential partial until the request dies;
        // this stage refuses instead. `unmapped`, not a finding: there is no
        // derivation row for "the partial graph has a cycle", and inventing
        // one here would be a code the manifest schema has never seen.
        for (c.stack.items) |s| {
            if (std.mem.eql(u8, s, p)) return c.unmapped(n);
        }
        const tpl = templateFor(c.ctx.fragments, p) orelse return c.unmapped(n);
        if (tpl.error_message != null or tpl.unreadable != null) return c.unmapped(n);
        try c.stack.append(c.gpa, p);
        defer _ = c.stack.pop();
        const locals: []const fragments.Attr = if (n.kind == .render_partial_locals) n.attrs else &.{};
        try c.walk(p, tpl.nodes, locals);
    }

    /// `render "shared/nav"` from any template -> `app/views/shared/_nav.*`;
    /// a bare `render "nav"` resolves against the RENDERING template's own
    /// directory, which is Rails' own rule. Returns a path present in
    /// `ctx.fragments` (borrowed) or null.
    ///
    /// Contract 3 (caller-buffer): the candidate prefix is formatted into a
    /// stack buffer; the result borrows `ctx.fragments`.
    fn partialPath(c: *Converter, current: []const u8, target: []const u8) ?[]const u8 {
        return partialPathIn(c.ctx.fragments, current, target);
    }
};

/// The free function behind `Converter.partialPath`, public since #167 Stage
/// 3: `scaffold.zig`'s binding pre-pass has to follow the SAME partial graph
/// this file inlines -- a Rails `new.html.erb` that renders `_form` keeps its
/// form in the partial, and a pre-pass that only read the main view would
/// leave the commonest form in Rails unbindable.
///
/// Contract 3 (caller-buffer): the candidate prefix is formatted into a stack
/// buffer; the result borrows `frags`.
pub fn partialPathIn(
    frags: []const fragments.Template,
    current: []const u8,
    target: []const u8,
) ?[]const u8 {
    var dir: []const u8 = "";
    var base: []const u8 = target;
    if (std.mem.lastIndexOfScalar(u8, target, '/')) |s| {
        dir = target[0..s];
        base = target[s + 1 ..];
    } else {
        const prefix = "app/views/";
        const rel = if (std.mem.startsWith(u8, current, prefix)) current[prefix.len..] else current;
        if (std.mem.lastIndexOfScalar(u8, rel, '/')) |s| dir = rel[0..s];
    }
    if (base.len == 0) return null;
    var buf: [512]u8 = undefined;
    const needle = (if (dir.len > 0)
        std.fmt.bufPrint(&buf, "app/views/{s}/_{s}.", .{ dir, base })
    else
        std.fmt.bufPrint(&buf, "app/views/_{s}.", .{base})) catch return null;
    // A format/handler chain means several files can share one stem
    // (`_nav.html.erb`, `_nav.json.erb`). The smallest path wins rather
    // than the first in slice order: the fragment list comes off a
    // directory walk, whose order is not promised across machines.
    var best: ?[]const u8 = null;
    for (frags) |t| {
        if (!std.mem.startsWith(u8, t.path, needle)) continue;
        if (best) |b| {
            if (std.mem.order(u8, t.path, b) != .lt) continue;
        }
        best = t.path;
    }
    return best;
}

const js_entry_reason = "@z/runtime replaces the Rails JS entry";
const csrf_reason = "the ZigBase cookie/CSRF boundary owns this";

/// Contract 3 (caller-buffer): allocates nothing; the result borrows `list`.
fn templateFor(list: []const fragments.Template, path: []const u8) ?fragments.Template {
    for (list) |t| {
        if (std.mem.eql(u8, t.path, path)) return t;
    }
    return null;
}

/// The text of a `content_for :title do … end` whose body is exactly one
/// literal thing, or null. Whitespace-only text runs are ignored (ERB
/// indentation), so `do %>\n  About\n<% end` still counts as one child; a
/// body with a helper call in it does not, because a title this stage cannot
/// evaluate must stay a gap rather than become a wrong `.title`.
///
/// Contract 3 (caller-buffer): allocates nothing; the result borrows `nodes`.
pub fn singleLiteralChild(nodes: []const fragments.Node) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (nodes) |n| {
        if (n.text) |t| {
            const trimmed = std.mem.trim(u8, t, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (found != null) return null;
            found = trimmed;
            continue;
        }
        switch (n.kind) {
            .literal => {
                if (found != null) return null;
                found = n.value orelse return null;
            },
            .i18n => {
                if (n.missing) return null;
                if (found != null) return null;
                found = n.value orelse return null;
            },
            else => return null,
        }
    }
    return found;
}

/// The first `<h1>`'s text with nested tags stripped and entities resolved,
/// or null. Read off the CONVERTED bytes rather than the node stream so an
/// `<h1><%= t(".heading") %></h1>` yields the resolved translation -- the
/// same string the page will actually show.
///
/// Contract 1 (self-freeing): the returned buffer is the only allocation.
fn firstH1(gpa: Allocator, bytes: []const u8) Allocator.Error!?[]u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search, "<h1")) |open| {
        const after = open + "<h1".len;
        if (after >= bytes.len) return null;
        // `<h1>` or `<h1 class=…>`, never `<h1x>`.
        if (bytes[after] != '>' and !std.ascii.isWhitespace(bytes[after])) {
            search = after;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, bytes, after, '>') orelse return null;
        const close = std.mem.indexOfPos(u8, bytes, gt + 1, "</h1>") orelse return null;
        return try plainText(gpa, bytes[gt + 1 .. close]);
    }
    return null;
}

/// `<meta name="description" content="…">`'s value as plain text, or null.
/// Both quote characters are accepted because the source template's own
/// markup is copied through verbatim and Rails templates use either.
///
/// Contract 1 (self-freeing).
fn metaDescription(gpa: Allocator, bytes: []const u8) Allocator.Error!?[]u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search, "<meta")) |open| {
        const gt = std.mem.indexOfScalarPos(u8, bytes, open, '>') orelse return null;
        const tag = bytes[open .. gt + 1];
        search = gt + 1;
        if (std.mem.indexOf(u8, tag, "name=\"description\"") == null and
            std.mem.indexOf(u8, tag, "name='description'") == null) continue;
        const value = attrValue(tag, "content") orelse continue;
        return try plainText(gpa, value);
    }
    return null;
}

/// The quoted value of `key=` inside one already-delimited tag, or null.
/// Contract 3 (caller-buffer): the result borrows `tag`.
fn attrValue(tag: []const u8, key: []const u8) ?[]const u8 {
    var buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "{s}=", .{key}) catch return null;
    const at = std.mem.indexOf(u8, tag, needle) orelse return null;
    const q = at + needle.len;
    if (q >= tag.len) return null;
    const quote = tag[q];
    if (quote != '"' and quote != '\'') return null;
    const end = std.mem.indexOfScalarPos(u8, tag, q + 1, quote) orelse return null;
    return tag[q + 1 .. end];
}

/// Markup -> the text a reader sees: tags removed, entities resolved, ends
/// trimmed. Null when nothing is left, so an empty `<h1></h1>` does not
/// become an empty `.title`.
///
/// Contract 1 (self-freeing): the returned buffer is the only allocation
/// that escapes; the intermediate is freed.
fn plainText(gpa: Allocator, markup: []const u8) Allocator.Error!?[]u8 {
    var stripped: List = .empty;
    defer stripped.deinit(gpa);
    var i: usize = 0;
    while (i < markup.len) {
        if (markup[i] == '<') {
            i = (std.mem.indexOfScalarPos(u8, markup, i, '>') orelse markup.len - 1) + 1;
            continue;
        }
        try stripped.append(gpa, markup[i]);
        i += 1;
    }
    const decoded = try unescape(gpa, stripped.items);
    // Arms only for the `dupe` below; every other exit either returns
    // `decoded` itself or frees it explicitly.
    errdefer gpa.free(decoded);
    const trimmed = std.mem.trim(u8, decoded, " \t\r\n");
    if (trimmed.len == 0) {
        gpa.free(decoded);
        return null;
    }
    if (trimmed.len == decoded.len) return decoded;
    const out = try gpa.dupe(u8, trimmed);
    gpa.free(decoded);
    return out;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Sorts, dedupes and DUPES a list of borrowed strings into an owned slice.
///
/// Contract 2 (owned-result), inherited from `convert`: on `OutOfMemory`
/// every string already duped is freed before propagating.
fn finalizeBorrowed(gpa: Allocator, items: [][]const u8) Allocator.Error![][]const u8 {
    std.mem.sort([]const u8, items, {}, lessThanString);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (items, 0..) |s, idx| {
        if (idx > 0 and std.mem.eql(u8, s, items[idx - 1])) continue;
        // The dupe is held in a local with its own `errdefer` rather than
        // nested inside the `append` call: a failing `append` would otherwise
        // drop the only reference to a string the list never took, which the
        // FailingAllocator sweep catches as a leak.
        const copy = try gpa.dupe(u8, s);
        errdefer gpa.free(copy);
        try out.append(gpa, copy);
    }
    return out.toOwnedSlice(gpa);
}

/// Sorts and dedupes a list of ALREADY-OWNED strings in place, freeing the
/// duplicates it drops, and hands the buffer over as the result.
///
/// Contract 2 (owned-result), inherited from `convert`.
fn finalizeOwned(gpa: Allocator, list: *std.ArrayListUnmanaged([]const u8)) Allocator.Error![][]const u8 {
    std.mem.sort([]const u8, list.items, {}, lessThanString);
    var write: usize = 0;
    for (list.items, 0..) |s, idx| {
        if (idx > 0 and std.mem.eql(u8, s, list.items[idx - 1])) {
            gpa.free(s);
            continue;
        }
        list.items[write] = s;
        write += 1;
    }
    list.items.len = write;
    return list.toOwnedSlice(gpa);
}

/// Appends a block's converted body, guaranteeing the closing tag starts on
/// its own line: a `<div id="main">` whose body ends mid-line would put
/// `</div>` inside the author's last element.
///
/// Contract 2 (owned-result), inherited from `convert`, for the same reason
/// `escapeInto` is: it only grows the caller's buffer.
fn appendBlockBody(gpa: Allocator, out: *List, body: []const u8) Allocator.Error!void {
    try out.appendSlice(gpa, body);
    if (body.len == 0 or body[body.len - 1] != '\n') try out.append(gpa, '\n');
}

/// One top-level block of an extending template: `<tag id="<id>">…</tag>`,
/// collapsed to one line when it has no content so an unfilled block stays
/// obviously empty rather than looking like a two-line hole.
///
/// Contract 2 (owned-result), inherited from `convert`.
fn appendBlock(gpa: Allocator, out: *List, tag: []const u8, id: []const u8, body: []const u8) Allocator.Error!void {
    try out.appendSlice(gpa, "<");
    try out.appendSlice(gpa, tag);
    try out.appendSlice(gpa, " id=\"");
    try out.appendSlice(gpa, id);
    try out.appendSlice(gpa, "\">");
    if (body.len == 0) {
        try out.appendSlice(gpa, "</");
        try out.appendSlice(gpa, tag);
        try out.appendSlice(gpa, ">\n");
        return;
    }
    try out.append(gpa, '\n');
    try appendBlockBody(gpa, out, body);
    try out.appendSlice(gpa, "</");
    try out.appendSlice(gpa, tag);
    try out.appendSlice(gpa, ">\n");
}

/// Offset of a start tag named `name` (`<head`, `<html`, `<body`) whose next
/// byte is `>` or whitespace, searching from `from`. The next-byte check is
/// what keeps `<head` from matching `<header` -- the bug that made the old
/// bare `lastIndexOf("<head>")` miss a `<head lang="en">` entirely and then
/// synthesise a second head.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn findStartTag(bytes: []const u8, name: []const u8, from: usize) ?usize {
    var at = from;
    while (std.mem.indexOfPos(u8, bytes, at, name)) |idx| {
        at = idx + name.len;
        if (at >= bytes.len) return null;
        if (bytes[at] == '>' or std.ascii.isWhitespace(bytes[at])) return idx;
    }
    return null;
}

/// Makes a converted LAYOUT declare the two blocks every converted view
/// fills, whether or not the Rails layout spelled them out (ruling S7).
/// SuperHTML fatals BOTH ways -- a block with no `<super>` is an
/// `UNBOUND TOP-LEVEL BLOCK`, a `<super>` with no block is a
/// `MISSING TOP-LEVEL BLOCK` -- so "emit the head block only when the layout
/// had `yield :head`" was wrong in one direction and "always emit it from the
/// view" was wrong in the other. Declaring both unconditionally is the only
/// rule under which any converted layout pairs with any converted view.
///
/// `head`: the layout's own `<head …>` gains `id="head"` and a `<super>` just
/// before its `</head>`; a layout with no head at all gets a synthesised one
/// after `<html …>` (or at the very top).
/// `main`: only when no bare `yield` already produced it -- before `</body>`
/// if there is one, else appended.
///
/// Contract 2 (owned-result), inherited from `convert`: only grows `out`.
fn finishLayout(gpa: Allocator, out: *List, saw_bare_yield: bool) Allocator.Error!void {
    if (findStartTag(out.items, "<head", 0)) |head_at| {
        const gt = std.mem.indexOfScalarPos(u8, out.items, head_at, '>') orelse out.items.len - 1;
        // A `<head>` that already carries the id is one a previous pass (or a
        // hand-written layout) produced; inserting a second `id` attribute
        // would be invalid HTML.
        if (std.mem.indexOf(u8, out.items[head_at..gt], "id=\"head\"") == null) {
            try out.insertSlice(gpa, head_at + "<head".len, " id=\"head\"");
        }
        const close = std.mem.indexOfPos(u8, out.items, head_at, "</head>") orelse out.items.len;
        try out.insertSlice(gpa, close, "<super>");
    } else if (findStartTag(out.items, "<html", 0)) |html_at| {
        const gt = std.mem.indexOfScalarPos(u8, out.items, html_at, '>') orelse out.items.len - 1;
        try out.insertSlice(gpa, gt + 1, "\n<head id=\"head\"><super></head>");
    } else {
        try out.insertSlice(gpa, 0, "<head id=\"head\"><super></head>\n");
    }

    if (saw_bare_yield) return;
    if (std.mem.lastIndexOf(u8, out.items, "</body>")) |at| {
        try out.insertSlice(gpa, at, "<div id=\"main\"><super></div>");
        return;
    }
    try out.appendSlice(gpa, "<div id=\"main\"><super></div>");
}

/// One template's node stream -> SuperHTML bytes. See the module doc for the
/// marker vocabulary and for why `Output.open_finding_ids` alone does not
/// prove a page is finished.
///
/// Returns `error.Unconvertible` ONLY for a template the sidecar could not
/// parse (`error_message`) or read (`unreadable`): there is no node stream to
/// convert, and both cases already carry a Stage 1 finding the caller reports
/// instead. Every other gap becomes a marker in the output.
///
/// Contract 2 (owned-result): every field of the returned `Output` is a fresh
/// `gpa` allocation, released by `freeOutput`. Nothing in `ctx` or `tpl` is
/// retained.
pub fn convert(gpa: Allocator, ctx: Context, tpl: fragments.Template, kind: Kind) Error!Output {
    if (tpl.error_message != null or tpl.unreadable != null) return error.Unconvertible;

    var body: List = .empty;
    defer body.deinit(gpa);

    var c: Converter = .{
        .gpa = gpa,
        .ctx = ctx,
        .kind = kind,
        .sink = &body,
    };
    defer c.deinit();

    try c.walk(tpl.path, tpl.nodes, &.{});
    // A `<title>` whose `</title>` never arrived: put the sink back so the
    // assembly below reads the real buffer, and record what was swallowed.
    try c.endTitleConsume();
    // `content_for :main` names the same block the template's own markup
    // fills, and Rails APPENDS to that buffer rather than replacing it. Both
    // assembly branches below emit `body`, so folding it in here is what keeps
    // it from being collected and then never read.
    try body.appendSlice(gpa, c.blockContents("main"));

    var out: List = .empty;
    errdefer out.deinit(gpa);

    var block_id_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer block_id_list.deinit(gpa);

    if (kind == .view and ctx.layout_stem != null) {
        // `docs/superhtml.md`: the child's FIRST node must be `<extend>`, and
        // a template that extends supplies ONLY blocks at the top level.
        try out.appendSlice(gpa, "<extend template=\"");
        try out.appendSlice(gpa, ctx.layout_stem.?);
        try out.appendSlice(gpa, ".shtml\">\n");
        // Ruling S7/S9: exactly the layout's blocks, no more and no fewer.
        // `head`/`main` are always declared by a converted layout (see
        // `finishLayout`), so they are emitted even when `layout_blocks` is
        // empty -- which is the case while a caller converts a view without
        // having converted its layout first.
        try appendBlock(gpa, &out, "head", "head", c.blockContents("head"));
        try appendBlock(gpa, &out, "div", "main", body.items);
        for (ctx.layout_blocks) |id| {
            if (std.mem.eql(u8, id, "head") or std.mem.eql(u8, id, "main")) continue;
            try appendBlock(gpa, &out, "div", id, c.blockContents(id));
        }
    } else {
        // No parent to extend: there is no `<super>` to fill, so a block
        // wrapper would be a plain `<div>` asserting a structure the template
        // never had. A layout and a standalone view are whole documents.
        //
        // The collected blocks are still CONTENT, though. `walk` intercepts
        // `content_for` for every view, layout or not, so a standalone view's
        // `content_for :head` is diverted into a block buffer that only the
        // extend branch reads -- and used to be dropped here without even a
        // note. Inlining is the honest answer: head content first (it was
        // written for the document head), then the body, then anything else in
        // source order. `c.blocks` is empty for a layout or a partial, so this
        // is a no-op for them.
        try out.appendSlice(gpa, c.blockContents("head"));
        try out.appendSlice(gpa, body.items);
        for (c.blocks.items) |b| {
            if (std.mem.eql(u8, b.name, "head") or std.mem.eql(u8, b.name, "main")) continue;
            try out.appendSlice(gpa, b.buf.items);
        }
        if (kind == .layout) {
            try finishLayout(gpa, &out, c.saw_bare_yield);
            try block_id_list.append(gpa, "head");
            try block_id_list.append(gpa, "main");
            try block_id_list.appendSlice(gpa, c.named_yields.items);
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
    }
    const bytes = try out.toOwnedSlice(gpa);
    errdefer gpa.free(bytes);

    const title: ?[]u8 = if (c.title) |t| try gpa.dupe(u8, t) else try firstH1(gpa, bytes);
    errdefer if (title) |t| gpa.free(t);
    const description = try metaDescription(gpa, bytes);
    errdefer if (description) |d| gpa.free(d);
    const ids = try finalizeBorrowed(gpa, c.ids.items);
    errdefer freeStrings(gpa, ids);
    const block_ids = try finalizeBorrowed(gpa, block_id_list.items);
    errdefer freeStrings(gpa, block_ids);
    const bound = try finalizeBorrowed(gpa, c.bound.items);
    errdefer freeStrings(gpa, bound);
    // Handed over rather than duped: both strings in an `Enclosure` borrow
    // `ctx.findings`, which outlives the `Output`. Emptied on the success path
    // so `Converter.deinit` does not free the list twice.
    const enclosed = try c.enclosed.toOwnedSlice(gpa);
    errdefer gpa.free(enclosed);
    // Handed over rather than copied: `Converter.deinit` frees whatever is
    // still in the list, so it must be emptied on the success path.
    const islands = try c.islands.toOwnedSlice(gpa);
    errdefer {
        for (islands) |s| {
            gpa.free(s.fields);
            gpa.free(s.original);
            if (s.port) |port_body| gpa.free(port_body);
        }
        gpa.free(islands);
    }
    const dropped = try finalizeOwned(gpa, &c.dropped);

    return .{
        .block_ids = block_ids,
        .bytes = bytes,
        .title = title,
        .description = description,
        .open_finding_ids = ids,
        .dropped = dropped,
        .islands = islands,
        .bound_finding_ids = bound,
        .enclosed = enclosed,
    };
}

// ---- tests ---------------------------------------------------------------

fn tNode(text: []const u8, line: u64) fragments.Node {
    return .{
        .text = text,
        .kind = .unknown,
        .line = line,
        .col = 0,
        .output = false,
        .code = "",
        .name = null,
        .value = null,
        .args = &.{},
        .attrs = &.{},
        .missing = false,
        .dynamic = false,
    };
}

fn cNode(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8) fragments.Node {
    return .{
        .text = null,
        .kind = kind,
        .line = line,
        .col = col,
        .output = true,
        .code = "",
        .name = name,
        .value = null,
        .args = &.{},
        .attrs = &.{},
        .missing = false,
        .dynamic = false,
    };
}

/// A block opener: `code` is what `opensBlock` reads to decide the node has a
/// matching `block_end` further down the stream.
fn openNode(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8, code: []const u8) fragments.Node {
    var n = cNode(kind, line, col, name);
    n.code = code;
    n.output = false;
    return n;
}

fn endNode(line: u64, col: u64) fragments.Node {
    var n = cNode(.block_end, line, col, null);
    n.output = false;
    n.code = "end";
    return n;
}

fn mkAsset(source: []const u8, deterministic: bool) assets.Asset {
    return .{ .source = source, .public_url = null, .pipeline = null, .deterministic = deterministic };
}

fn mkRoute(verb: []const u8, path: []const u8, name: ?[]const u8) routes.Route {
    return .{
        .verb = verb,
        .path = path,
        .controller = "pages",
        .action = "show",
        .name = name,
        .certain = true,
        .origin = .static_ast,
    };
}

fn mkFinding(id: []const u8, code: []const u8, path: []const u8, line: u64) findings.Finding {
    return .{
        .id = id,
        .code = code,
        .severity = .warn,
        .path = path,
        .line = line,
        .route_id = null,
        .message = "",
        .choices = &.{ "retain", "blocked" },
        .requires_artifact = false,
    };
}

fn mkTemplate(path: []const u8, nodes: []const fragments.Node) fragments.Template {
    return .{
        .path = path,
        .nodes = @constCast(nodes),
        .error_message = null,
        .error_line = null,
        .unreadable = null,
    };
}

fn stage4Binding(id: []const u8, kind: Binding.Kind, island: []const u8) Binding {
    return .{
        .finding_id = id,
        .kind = kind,
        .verb = "",
        .path = "",
        .operation_id = "",
        .collection = null,
        .island = island,
        .redirect_to = null,
    };
}

test "convert: a multi-controller Stimulus island wraps markup without swallowing inner findings" {
    const gpa = std.testing.allocator;
    const path = "app/views/pages/widgets.html.erb";
    var head = openNode(.stimulus, 2, 1, "reveal modal", "<div data-controller=\"reveal modal\">");
    head.value = "div";
    var missing = cNode(.i18n, 3, 3, ".missing");
    missing.missing = true;
    missing.code = "t(\".missing\")";
    var close = endNode(4, 1);
    close.code = "</div>";
    const nodes = [_]fragments.Node{ head, tNode("<button>Show</button>", 2), missing, close };
    const finding_list = [_]findings.Finding{
        mkFinding("RAILS_STIMULUS_CONTROLLER.app/views/pages/widgets%2Ehtml%2Eerb.L2C1", "RAILS_STIMULUS_CONTROLLER", path, 2),
        mkFinding("RAILS_I18N_MISSING.app/views/pages/widgets%2Ehtml%2Eerb.L3C3", "RAILS_I18N_MISSING", path, 3),
    };
    var binding = stage4Binding(finding_list[0].id, .stimulus, "components/stimulus/reveal.island.tsx");
    binding.wrap = true;
    binding.identifiers = &.{ "reveal", "modal" };
    const out = try convert(gpa, .{ .routes = &.{}, .assets = &.{}, .fragments = &.{}, .findings = &finding_list, .layout_stem = null, .bindings = &.{binding} }, mkTemplate(path, &nodes), .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings(
        "<island src=\"components/stimulus/reveal.island.tsx\" client:load><island src=\"components/stimulus/modal.island.tsx\" client:load><div data-controller=\"reveal modal\"><button>Show</button><!-- rails:finding RAILS_I18N_MISSING.app/views/pages/widgets%2Ehtml%2Eerb.L3C3 --><!-- rails:end --></div></island></island>\n",
        out.bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), out.open_finding_ids.len);
    try std.testing.expectEqualStrings(finding_list[1].id, out.open_finding_ids[0]);
    try std.testing.expectEqual(@as(usize, 1), out.bound_finding_ids.len);
    try std.testing.expectEqualStrings(finding_list[0].id, out.bound_finding_ids[0]);
    try std.testing.expectEqual(@as(usize, 0), out.enclosed.len);
}

test "convert: lazy and inline Turbo frames preserve only the promised markup" {
    const gpa = std.testing.allocator;
    const path = "app/views/pages/x.html.erb";
    var lazy = openNode(.turbo_frame, 1, 1, "latest", "turbo_frame_tag \"latest\" do");
    lazy.value = "posts";
    var lazy_close = endNode(1, 40);
    lazy_close.code = "end";
    const lazy_nodes = [_]fragments.Node{ lazy, tNode("<p>Loading</p>", 1), lazy_close };
    const lazy_finding = [_]findings.Finding{mkFinding("RAILS_TURBO_FRAME.x.L1C1", "RAILS_TURBO_FRAME", path, 1)};
    var lazy_binding = stage4Binding(lazy_finding[0].id, .turbo_frame, "components/TurboFrame.island.tsx");
    lazy_binding.wrap = true;
    lazy_binding.directive = "client:visible";
    lazy_binding.props = "{ .id = \"latest\", .src = \"/posts\" }";
    const lazy_out = try convert(gpa, .{ .routes = &.{}, .assets = &.{}, .fragments = &.{}, .findings = &lazy_finding, .layout_stem = null, .bindings = &.{lazy_binding} }, mkTemplate(path, &lazy_nodes), .view);
    defer freeOutput(gpa, lazy_out);
    try std.testing.expectEqualStrings("<island src=\"components/TurboFrame.island.tsx\" client:visible :props='{ .id = \"latest\", .src = \"/posts\" }'><p>Loading</p></island>\n", lazy_out.bytes);

    const plain = openNode(.turbo_frame, 2, 1, "static", "turbo_frame_tag \"static\" do");
    var plain_close = endNode(2, 50);
    plain_close.code = "end";
    const plain_nodes = [_]fragments.Node{ plain, tNode("<p>Just markup</p>", 2), plain_close };
    const plain_finding = [_]findings.Finding{mkFinding("RAILS_TURBO_FRAME.x.L2C1", "RAILS_TURBO_FRAME", path, 2)};
    const plain_binding = stage4Binding(plain_finding[0].id, .@"inline", "");
    const plain_out = try convert(gpa, .{ .routes = &.{}, .assets = &.{}, .fragments = &.{}, .findings = &plain_finding, .layout_stem = null, .bindings = &.{plain_binding} }, mkTemplate(path, &plain_nodes), .view);
    defer freeOutput(gpa, plain_out);
    try std.testing.expectEqualStrings("<turbo-frame id=\"static\"><p>Just markup</p></turbo-frame>\n", plain_out.bytes);
}

test "convert: drop strips only Stimulus attributes in the bound extent" {
    const gpa = std.testing.allocator;
    const path = "app/views/pages/x.html.erb";
    var head = openNode(.stimulus, 1, 1, "reveal", "<div class=\"box\" data-controller=\"reveal\" data-reveal-open-value=\"true\">");
    head.value = "div";
    var close = endNode(2, 1);
    close.code = "</div>";
    const nodes = [_]fragments.Node{ head, tNode("<button class=\"go\" data-action=\"click->reveal#toggle\" data-reveal-target=\"details\">Go</button>", 1), close };
    const finding_list = [_]findings.Finding{mkFinding("RAILS_STIMULUS_CONTROLLER.x.L1C1", "RAILS_STIMULUS_CONTROLLER", path, 1)};
    var binding = stage4Binding(finding_list[0].id, .drop, "");
    binding.identifiers = &.{"reveal"};
    const out = try convert(gpa, .{ .routes = &.{}, .assets = &.{}, .fragments = &.{}, .findings = &finding_list, .layout_stem = null, .bindings = &.{binding} }, mkTemplate(path, &nodes), .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings("<div class=\"box\"><button class=\"go\">Go</button></div>\n", out.bytes);
    try std.testing.expectEqual(@as(usize, 1), out.bound_finding_ids.len);
}

test "convert: component props are emitted verbatim and Turbo Drive attributes get one note" {
    const gpa = std.testing.allocator;
    const path = "app/views/pages/x.html.erb";
    const component = cNode(.component_root, 1, 1, "Chart");
    const finding_list = [_]findings.Finding{mkFinding("RAILS_COMPONENT_ROOT.x.L1C1", "RAILS_COMPONENT_ROOT", path, 1)};
    var binding = stage4Binding(finding_list[0].id, .component, "components/Chart.island.tsx");
    binding.props = "{ .active = true, .points = 3, .series = \"a\\\"b\" }";
    const nodes = [_]fragments.Node{ tNode("<main data-turbo-action=\"advance\">", 1), component, tNode("</main><a data-turbo-prefetch=\"false\">x</a>", 2) };
    const out = try convert(gpa, .{ .routes = &.{}, .assets = &.{}, .fragments = &.{}, .findings = &finding_list, .layout_stem = null, .bindings = &.{binding} }, mkTemplate(path, &nodes), .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings("<main><island src=\"components/Chart.island.tsx\" client:load :props='{ .active = true, .points = 3, .series = \"a\\\"b\" }'></island></main><a>x</a>\n", out.bytes);
    try std.testing.expectEqual(@as(usize, 1), out.dropped.len);
    try std.testing.expectEqualStrings("data-turbo attributes dropped; Turbo Drive is ordinary navigation here", out.dropped[0]);
    const again = try convert(gpa, .{ .routes = &.{}, .assets = &.{}, .fragments = &.{}, .findings = &finding_list, .layout_stem = null, .bindings = &.{binding} }, mkTemplate(path, &nodes), .view);
    defer freeOutput(gpa, again);
    try std.testing.expectEqualStrings(out.bytes, again.bytes);
    try std.testing.expectEqualStrings(out.dropped[0], again.dropped[0]);
}

test "convert: a data island binds findings reached through rendered partials" {
    const gpa = std.testing.allocator;
    const path = "app/views/posts/index.html.erb";
    const partial_path = "app/views/posts/_post.html.erb";
    var outer = openNode(.ivar, 1, 1, "@posts", "@posts.each do |post|");
    outer.output = false;
    const render = cNode(.render_partial, 2, 3, "post");
    const close = endNode(3, 1);
    const nodes = [_]fragments.Node{ outer, render, close };
    var literal = cNode(.literal, 1, 1, null);
    literal.value = "card";
    const partial_nodes = [_]fragments.Node{literal};
    const partial = mkTemplate(partial_path, &partial_nodes);
    const finding_list = [_]findings.Finding{
        mkFinding("RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L1C1", "RAILS_REQUEST_TIME_STATE", path, 1),
        mkFinding("RAILS_TEMPLATE_CONTROL_FLOW.app/views/posts/_post%2Ehtml%2Eerb.L1C1", "RAILS_TEMPLATE_CONTROL_FLOW", partial_path, 1),
    };
    var binding = stage4Binding(finding_list[0].id, .data_list, "components/data/posts_index.island.tsx");
    binding.collection = "posts";
    binding.aliases = &.{
        .{ .ruby = "@posts", .js = "rec" },
        .{ .ruby = "post", .js = "rec" },
    };
    const out = try convert(gpa, .{ .routes = &.{}, .assets = &.{}, .fragments = &.{partial}, .findings = &finding_list, .layout_stem = null, .bindings = &.{binding} }, mkTemplate(path, &nodes), .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings("<island src=\"components/data/posts_index.island.tsx\" client:load></island>\n", out.bytes);
    try std.testing.expectEqual(@as(usize, 2), out.bound_finding_ids.len);
    try std.testing.expectEqual(@as(usize, 1), out.enclosed.len);
    try std.testing.expectEqualStrings(finding_list[1].id, out.enclosed[0].id);
    try std.testing.expectEqualStrings(finding_list[0].id, out.enclosed[0].by);
    try std.testing.expect(out.islands[0].port != null);
}

test "convert: a missing Stimulus element is one complete open region" {
    const gpa = std.testing.allocator;
    const path = "app/views/pages/x.html.erb";
    var node = openNode(.stimulus, 1, 1, "split", "<div data-controller=\"split\">");
    node.missing = true;
    const finding_list = [_]findings.Finding{mkFinding("RAILS_STIMULUS_CONTROLLER.x.L1C1", "RAILS_STIMULUS_CONTROLLER", path, 1)};
    const out = try convert(gpa, .{ .routes = &.{}, .assets = &.{}, .fragments = &.{}, .findings = &finding_list, .layout_stem = null }, mkTemplate(path, &.{node}), .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings("<!-- rails:finding RAILS_STIMULUS_CONTROLLER.x.L1C1 --><div data-controller=\"split\"><!-- rails:end -->\n", out.bytes);

    node.missing = false;
    var close = endNode(2, 1);
    close.code = "</div>";
    const closed_nodes = [_]fragments.Node{ node, tNode("<span>x</span>", 1), close };
    const closed = try convert(gpa, .{ .routes = &.{}, .assets = &.{}, .fragments = &.{}, .findings = &finding_list, .layout_stem = null }, mkTemplate(path, &closed_nodes), .view);
    defer freeOutput(gpa, closed);
    try std.testing.expectEqualStrings("<!-- rails:finding RAILS_STIMULUS_CONTROLLER.x.L1C1 --><div data-controller=\"split\"><span>x</span></div><!-- rails:end -->\n", closed.bytes);
}

test "convert: Stage 4 binding branches survive every allocation failure" {
    const path = "app/views/pages/all.html.erb";
    var wrap_head = openNode(.stimulus, 1, 1, "reveal", "<div data-controller=\"reveal\">");
    wrap_head.value = "div";
    var wrap_close = endNode(1, 30);
    wrap_close.code = "</div>";
    var drop_head = openNode(.stimulus, 2, 1, "modal", "<div class=\"m\" data-controller=\"modal\">");
    drop_head.value = "div";
    var drop_close = endNode(2, 30);
    drop_close.code = "</div>";
    var ivar = cNode(.ivar, 4, 1, "@post");
    ivar.code = "@post.title";
    const nodes = [_]fragments.Node{
        tNode("<main data-turbo=\"false\">", 1),
        wrap_head,
        tNode("<button data-action=\"reveal#toggle\">x</button>", 1),
        wrap_close,
        drop_head,
        tNode("<span data-modal-target=\"body\">y</span>", 2),
        drop_close,
        cNode(.component_root, 3, 1, "Chart"),
        ivar,
        tNode("</main>", 5),
    };
    const finding_list = [_]findings.Finding{
        mkFinding("S.x.L1C1", "RAILS_STIMULUS_CONTROLLER", path, 1),
        mkFinding("D.x.L2C1", "RAILS_STIMULUS_CONTROLLER", path, 2),
        mkFinding("C.x.L3C1", "RAILS_COMPONENT_ROOT", path, 3),
        mkFinding("I.x.L4C1", "RAILS_REQUEST_TIME_STATE", path, 4),
    };
    var wrap = stage4Binding(finding_list[0].id, .stimulus, "components/stimulus/reveal.island.tsx");
    wrap.wrap = true;
    wrap.identifiers = &.{"reveal"};
    var drop = stage4Binding(finding_list[1].id, .drop, "");
    drop.identifiers = &.{"modal"};
    var component = stage4Binding(finding_list[2].id, .component, "components/Chart.island.tsx");
    component.props = "{ .points = 3 }";
    var data = stage4Binding(finding_list[3].id, .data_list, "components/data/post.island.tsx");
    data.collection = "posts";
    data.aliases = &.{.{ .ruby = "@post", .js = "rec" }};
    const bindings = [_]Binding{ wrap, drop, component, data };

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (convert(failing.allocator(), .{ .routes = &.{}, .assets = &.{}, .fragments = &.{}, .findings = &finding_list, .layout_stem = null, .bindings = &bindings }, mkTemplate(path, &nodes), .view)) |out| {
            defer freeOutput(std.testing.allocator, out);
            try std.testing.expectEqual(@as(usize, 3), out.islands.len);
            try std.testing.expectEqual(@as(usize, 4), out.bound_finding_ids.len);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "convert: a layout turns yield into an id=main super block, rewrites <title>, drops csrf and resolves a stylesheet" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        tNode("<!DOCTYPE html>\n<html>\n  <head>\n    <title>", 1),
        cNode(.yield_named, 4, 12, "title"),
        tNode("</title>\n    ", 4),
        cNode(.csrf, 5, 5, "csrf_meta_tags"),
        tNode("\n    ", 5),
        blk: {
            var n = cNode(.asset, 6, 5, "stylesheet_link_tag");
            n.args = &.{"application"};
            break :blk n;
        },
        tNode("\n  </head>\n  <body>\n    <main>", 6),
        cNode(.yield, 9, 11, null),
        tNode("</main>\n  </body>\n</html>\n", 9),
    };
    const asset_list = [_]assets.Asset{mkAsset("app/assets/stylesheets/application.css", true)};
    const tpl = mkTemplate("app/views/layouts/application.html.erb", &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &asset_list,
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, tpl, .layout);
    defer freeOutput(gpa, out);

    try std.testing.expectEqualStrings(
        \\<!DOCTYPE html>
        \\<html>
        \\  <head id="head">
        \\    <title :text="$page.title"></title>
        \\    <!-- rails: csrf_meta_tags dropped; the ZigBase cookie/CSRF boundary owns this -->
        \\    <link rel="stylesheet" href="$site.asset('stylesheets/application.css').link()">
        \\  <super></head>
        \\  <body>
        \\    <main><div id="main"><super></div></main>
        \\  </body>
        \\</html>
        \\
    , out.bytes);
    try std.testing.expectEqual(@as(usize, 0), out.open_finding_ids.len);
    try std.testing.expectEqual(@as(usize, 1), out.dropped.len);
    try std.testing.expectEqualStrings("csrf_meta_tags dropped", out.dropped[0]);
    // Ruling S7: a converted layout ALWAYS declares both, so any converted
    // view pairs with it. This layout never wrote `yield :head`.
    try std.testing.expectEqual(@as(usize, 2), out.block_ids.len);
    try std.testing.expectEqualStrings("head", out.block_ids[0]);
    try std.testing.expectEqualStrings("main", out.block_ids[1]);
}

test "convert: a view extends its layout, lifts content_for :title, and resolves an i18n literal" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        openNode(.content_for, 1, 4, "title", "content_for :title do"),
        tNode("About", 1),
        endNode(1, 30),
        tNode("<h1>", 1),
        blk: {
            var n = cNode(.i18n, 1, 40, "pages.about.heading");
            n.value = "About us";
            break :blk n;
        },
        tNode("</h1><p>Static.</p>\n", 1),
    };
    const tpl = mkTemplate("app/views/pages/about.html.erb", &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = "marketing",
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expectEqualStrings(
        \\<extend template="marketing.shtml">
        \\<head id="head"></head>
        \\<div id="main">
        \\<h1>About us</h1><p>Static.</p>
        \\</div>
        \\
    , out.bytes);
    try std.testing.expectEqualStrings("About", out.title.?);
    try std.testing.expect(out.description == null);
    // A view declares no blocks of its own; it fills the layout's.
    try std.testing.expectEqual(@as(usize, 0), out.block_ids.len);
}

test "convert: content_for :head becomes a head block before the main block" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        openNode(.content_for, 1, 4, "head", "content_for :head do"),
        tNode("<meta name=\"description\" content=\"A page &amp; more\">", 1),
        endNode(1, 60),
        tNode("<p>Body</p>", 2),
    };
    const tpl = mkTemplate("app/views/pages/about.html.erb", &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = "marketing",
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expectEqualStrings(
        \\<extend template="marketing.shtml">
        \\<head id="head">
        \\<meta name="description" content="A page &amp; more">
        \\</head>
        \\<div id="main">
        \\<p>Body</p>
        \\</div>
        \\
    , out.bytes);
    // The description is un-escaped back to plain text: it becomes a Ziggy
    // frontmatter value, not markup.
    try std.testing.expectEqualStrings("A page & more", out.description.?);
}

test "convert: provide(:title, literal) lifts the title; a computed title is an answerable region" {
    const gpa = std.testing.allocator;
    const ctx: Context = .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = "marketing",
    };

    const provided = [_]fragments.Node{
        blk: {
            var n = cNode(.content_for, 1, 1, "title");
            n.value = "About";
            break :blk n;
        },
        tNode("<p>x</p>", 2),
    };
    const out_provided = try convert(gpa, ctx, mkTemplate("app/views/pages/a.html.erb", &provided), .view);
    defer freeOutput(gpa, out_provided);
    try std.testing.expectEqualStrings("About", out_provided.title.?);

    // `content_for :title do <%= @post.name %> end`: nothing to lift, and the
    // block must NOT become a `<div id="title">` inside the main block -- a
    // SuperHTML block is top-level only, so that div would render the title
    // markup as page content.
    const computed = [_]fragments.Node{
        openNode(.content_for, 1, 1, "title", "content_for :title do"),
        cNode(.ivar, 1, 25, "@post"),
        endNode(1, 40),
        tNode("<p>x</p>", 2),
    };
    const computed_path = "app/views/pages/b.html.erb";
    const computed_id = "RAILS_CONTENT_FOR_DYNAMIC.app/views/pages/b%2Ehtml%2Eerb.L1C1";
    const computed_findings = [_]findings.Finding{mkFinding(computed_id, "RAILS_CONTENT_FOR_DYNAMIC", computed_path, 1)};
    var computed_ctx = ctx;
    computed_ctx.findings = &computed_findings;
    const out_computed = try convert(gpa, computed_ctx, mkTemplate(computed_path, &computed), .view);
    defer freeOutput(gpa, out_computed);
    try std.testing.expect(out_computed.title == null);
    try std.testing.expectEqualStrings(
        \\<extend template="marketing.shtml">
        \\<head id="head"></head>
        \\<div id="main">
        \\<!-- rails:finding RAILS_CONTENT_FOR_DYNAMIC.app/views/pages/b%2Ehtml%2Eerb.L1C1 --><!-- rails:end --><p>x</p>
        \\</div>
        \\
    , out_computed.bytes);
    // The `@post` inside the unresolvable title is INSIDE that region, so it
    // emits no marker of its own -- the outermost-only rule.
    try std.testing.expectEqual(@as(usize, 1), out_computed.open_finding_ids.len);
    try std.testing.expectEqualStrings(computed_id, out_computed.open_finding_ids[0]);
}

test "convert: link_to, route_helper and image_tag resolve through resolve.zig" {
    const gpa = std.testing.allocator;
    const route_list = [_]routes.Route{
        mkRoute("GET", "/", "root"),
        mkRoute("GET", "/posts/:id", "post"),
    };
    const asset_list = [_]assets.Asset{mkAsset("app/assets/images/logo.png", true)};
    const link_attrs = [_]fragments.Attr{.{ .key = "class", .value = "nav" }};
    const img_attrs = [_]fragments.Attr{.{ .key = "alt", .value = "Logo & co" }};
    const nodes = [_]fragments.Node{
        blk: {
            var n = cNode(.link_to, 1, 1, "root");
            n.args = &.{"Home"};
            n.attrs = &link_attrs;
            break :blk n;
        },
        blk: {
            var n = cNode(.route_helper, 2, 1, "post");
            n.args = &.{"7"};
            break :blk n;
        },
        blk: {
            var n = cNode(.asset, 3, 1, "image_tag");
            n.args = &.{"logo.png"};
            n.attrs = &img_attrs;
            break :blk n;
        },
        blk: {
            var n = cNode(.link_to, 4, 1, null);
            n.args = &.{ "Docs", "https://example.com/docs" };
            break :blk n;
        },
    };
    const tpl = mkTemplate("app/views/shared/_nav.html.erb", &nodes);
    const out = try convert(gpa, .{
        .routes = &route_list,
        .assets = &asset_list,
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, tpl, .partial);
    defer freeOutput(gpa, out);

    try std.testing.expectEqualStrings(
        "<a href=\"/\" class=\"nav\">Home</a>" ++
            "/posts/7" ++
            "<img src=\"$site.asset('images/logo.png').link()\" alt=\"Logo &amp; co\">" ++
            "<a href=\"https://example.com/docs\">Docs</a>\n",
        out.bytes,
    );
}

// Ruling S23. `resolve.assetFor`'s own doc states the contract this pins: an
// absolute-URL literal resolves to `null` there, and THIS file must recognise
// it BEFORE asking -- otherwise every CDN reference in the app becomes a
// spurious "matches no file under app/assets/" placeholder instead of the
// markup the author wrote. The literal is copied through verbatim because
// there is nothing to copy INTO the target: the resource lives on someone
// else's host.
test "convert: an absolute asset URL is emitted verbatim, with no placeholder (ruling S23)" {
    const gpa = std.testing.allocator;
    const img_attrs = [_]fragments.Attr{.{ .key = "alt", .value = "x" }};
    const nodes = [_]fragments.Node{
        blk: {
            var n = cNode(.asset, 1, 1, "image_tag");
            n.args = &.{"https://cdn.example.com/x.png"};
            n.attrs = &img_attrs;
            break :blk n;
        },
        // Protocol-relative, the third shape `assetFor` names. It must not be
        // mistaken for the `/`-rooted "already a public path" idiom.
        blk: {
            var n = cNode(.asset, 2, 1, "stylesheet_link_tag");
            n.args = &.{"//cdn.example.com/s.css"};
            break :blk n;
        },
        blk: {
            var n = cNode(.asset, 3, 1, "asset_path");
            n.args = &.{"http://cdn.example.com/f.woff"};
            break :blk n;
        },
    };
    const tpl = mkTemplate("app/views/shared/_nav.html.erb", &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, tpl, .partial);
    defer freeOutput(gpa, out);

    try std.testing.expectEqualStrings(
        "<img src=\"https://cdn.example.com/x.png\" alt=\"x\">" ++
            "<link rel=\"stylesheet\" href=\"//cdn.example.com/s.css\">" ++
            "http://cdn.example.com/f.woff\n",
        out.bytes,
    );
    try std.testing.expectEqual(@as(usize, 0), out.open_finding_ids.len);
}

// The mixed case, which is what keeps this file's predicate and
// `findings.zig`'s in step: one absolute argument does NOT excuse a second
// one that resolves to nothing. `findings.zig` derives its
// `RAILS_ASSET_TRANSFORM` from the same walk, so the id exists and the region
// is answerable rather than an id-less `rails:unmapped asset`.
test "convert: an absolute argument beside an unresolvable one still yields a finding region" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        blk: {
            var n = cNode(.asset, 1, 1, "stylesheet_link_tag");
            n.args = &.{ "//cdn.example.com/s.css", "ghost" };
            break :blk n;
        },
    };
    const finding_list = [_]findings.Finding{
        mkFinding("RAILS_ASSET_TRANSFORM.x.L1C1", "RAILS_ASSET_TRANSFORM", "app/views/shared/_nav.html.erb", 1),
    };
    const tpl = mkTemplate("app/views/shared/_nav.html.erb", &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
    }, tpl, .partial);
    defer freeOutput(gpa, out);

    try std.testing.expectEqualStrings(
        "<!-- rails:finding RAILS_ASSET_TRANSFORM.x.L1C1 --><!-- rails:end -->\n",
        out.bytes,
    );
}

test "convert: render_partial inlines the converted partial; locals substitute literal values" {
    const gpa = std.testing.allocator;
    const nav_nodes = [_]fragments.Node{
        tNode("<nav>", 1),
        cNode(.local, 1, 6, "who"),
        tNode("</nav>", 1),
    };
    const frag_list = [_]fragments.Template{mkTemplate("app/views/shared/_nav.html.erb", &nav_nodes)};
    const locals = [_]fragments.Attr{.{ .key = "who", .value = "Ann & Bob" }};
    const nodes = [_]fragments.Node{
        blk: {
            var n = cNode(.render_partial_locals, 1, 1, "shared/nav");
            n.attrs = &locals;
            break :blk n;
        },
    };
    const tpl = mkTemplate("app/views/pages/about.html.erb", &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &frag_list,
        .findings = &.{},
        .layout_stem = null,
    }, tpl, .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings("<nav>Ann &amp; Bob</nav>\n", out.bytes);
}

test "convert: a local with no substitution and an unlocatable partial are unmapped, not lost" {
    const gpa = std.testing.allocator;
    const nav_nodes = [_]fragments.Node{ tNode("<nav>", 1), cNode(.local, 1, 6, "who"), tNode("</nav>", 1) };
    const frag_list = [_]fragments.Template{mkTemplate("app/views/shared/_nav.html.erb", &nav_nodes)};
    const nodes = [_]fragments.Node{
        cNode(.render_partial, 1, 1, "shared/nav"),
        cNode(.render_partial, 2, 1, "shared/ghost"),
    };
    const tpl = mkTemplate("app/views/pages/about.html.erb", &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &frag_list,
        .findings = &.{},
        .layout_stem = null,
    }, tpl, .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings(
        "<nav><!-- rails:unmapped local L1C6 --></nav>" ++
            "<!-- rails:unmapped render_partial L2C1 -->\n",
        out.bytes,
    );
}

test "convert: a partial that renders itself is cut by the cycle guard" {
    const gpa = std.testing.allocator;
    const loop_nodes = [_]fragments.Node{
        tNode("<a>", 1),
        cNode(.render_partial, 1, 4, "shared/loop"),
        tNode("</a>", 1),
    };
    const frag_list = [_]fragments.Template{mkTemplate("app/views/shared/_loop.html.erb", &loop_nodes)};
    const nodes = [_]fragments.Node{cNode(.render_partial, 1, 1, "shared/loop")};
    const tpl = mkTemplate("app/views/pages/about.html.erb", &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &frag_list,
        .findings = &.{},
        .layout_stem = null,
    }, tpl, .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings("<a><!-- rails:unmapped render_partial L1C4 --></a>\n", out.bytes);
}

test "convert: a control block keeps its markup between a finding placeholder, an else marker and an end" {
    const gpa = std.testing.allocator;
    const path = "app/views/posts/index.html.erb";
    const id = "RAILS_TEMPLATE_CONTROL_FLOW.app/views/posts/index%2Ehtml%2Eerb.L3C4";
    const finding_list = [_]findings.Finding{mkFinding(id, "RAILS_TEMPLATE_CONTROL_FLOW", path, 3)};
    const nodes = [_]fragments.Node{
        openNode(.control, 3, 4, "if", "if flag"),
        tNode("<p>yes</p>", 3),
        blk: {
            var n = cNode(.block_else, 4, 4, null);
            n.output = false;
            break :blk n;
        },
        tNode("<p>no</p>", 4),
        endNode(5, 4),
    };
    const tpl = mkTemplate(path, &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
    }, tpl, .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings(
        "<!-- rails:finding " ++ id ++ " --><p>yes</p><!-- rails:else --><p>no</p><!-- rails:end -->\n",
        out.bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), out.open_finding_ids.len);
    try std.testing.expectEqualStrings(id, out.open_finding_ids[0]);
}

test "convert: only the outermost finding emits a placeholder; the inner id is still reported" {
    const gpa = std.testing.allocator;
    const path = "app/views/posts/index.html.erb";
    const outer = "RAILS_TEMPLATE_CONTROL_FLOW.app/views/posts/index%2Ehtml%2Eerb.L1C1";
    const inner = "RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L2C3";
    const finding_list = [_]findings.Finding{
        mkFinding(inner, "RAILS_REQUEST_TIME_STATE", path, 2),
        mkFinding(outer, "RAILS_TEMPLATE_CONTROL_FLOW", path, 1),
    };
    const nodes = [_]fragments.Node{
        openNode(.control, 1, 1, "if", "if flag"),
        tNode("<b>", 1),
        cNode(.request_state, 2, 3, "current_user"),
        tNode("</b>", 2),
        endNode(3, 1),
    };
    const tpl = mkTemplate(path, &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
    }, tpl, .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings(
        "<!-- rails:finding " ++ outer ++ " --><b></b><!-- rails:end -->\n",
        out.bytes,
    );
    // Sorted and deduped: RAILS_REQUEST_TIME_STATE sorts before RAILS_TEMPLATE_*.
    try std.testing.expectEqual(@as(usize, 2), out.open_finding_ids.len);
    try std.testing.expectEqualStrings(inner, out.open_finding_ids[0]);
    try std.testing.expectEqualStrings(outer, out.open_finding_ids[1]);
}

test "convert: a finding-kind node with no derived finding is unmapped rather than silently converted" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{cNode(.unknown, 7, 2, "number_to_currency")};
    const tpl = mkTemplate("app/views/pages/help.html.erb", &nodes);
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, tpl, .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings("<!-- rails:unmapped unknown L7C2 -->\n", out.bytes);
    try std.testing.expectEqual(@as(usize, 0), out.open_finding_ids.len);
}

test "convert: title falls back to the first h1 and then to null" {
    const gpa = std.testing.allocator;
    const with_h1 = [_]fragments.Node{tNode("<div><h1 class=\"x\">Hello <em>you</em> &amp; me</h1></div>", 1)};
    const out_h1 = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/pages/a.html.erb", &with_h1), .view);
    defer freeOutput(gpa, out_h1);
    try std.testing.expectEqualStrings("Hello you & me", out_h1.title.?);

    const bare = [_]fragments.Node{tNode("<p>nothing</p>", 1)};
    const out_bare = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/pages/b.html.erb", &bare), .view);
    defer freeOutput(gpa, out_bare);
    try std.testing.expect(out_bare.title == null);
}

test "convert: an unreadable or unparsed template is Unconvertible" {
    const gpa = std.testing.allocator;
    const ctx: Context = .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    };
    var broken = mkTemplate("app/views/pages/broken.html.erb", &.{});
    broken.error_message = "unexpected end";
    try std.testing.expectError(error.Unconvertible, convert(gpa, ctx, broken, .view));
    var refused = mkTemplate("app/views/pages/linked.html.erb", &.{});
    refused.unreadable = "outside root";
    try std.testing.expectError(error.Unconvertible, convert(gpa, ctx, refused, .view));
}

test "convert: the same input converts to the same bytes twice" {
    const gpa = std.testing.allocator;
    const route_list = [_]routes.Route{mkRoute("GET", "/", "root")};
    const asset_list = [_]assets.Asset{mkAsset("app/assets/images/logo.png", true)};
    const nav_nodes = [_]fragments.Node{
        tNode("<nav>", 1),
        blk: {
            var n = cNode(.link_to, 1, 6, "root");
            n.args = &.{"Home"};
            break :blk n;
        },
        tNode("</nav>", 1),
    };
    const frag_list = [_]fragments.Template{mkTemplate("app/views/shared/_nav.html.erb", &nav_nodes)};
    const nodes = [_]fragments.Node{
        cNode(.render_partial, 1, 1, "shared/nav"),
        cNode(.csrf, 2, 1, "csrf_meta_tags"),
        cNode(.importmap, 3, 1, "javascript_importmap_tags"),
        blk: {
            var n = cNode(.asset, 4, 1, "image_tag");
            n.args = &.{"logo.png"};
            break :blk n;
        },
    };
    const ctx: Context = .{
        .routes = &route_list,
        .assets = &asset_list,
        .fragments = &frag_list,
        .findings = &.{},
        .layout_stem = "marketing",
    };
    const tpl = mkTemplate("app/views/pages/about.html.erb", &nodes);
    const a = try convert(gpa, ctx, tpl, .view);
    defer freeOutput(gpa, a);
    const b = try convert(gpa, ctx, tpl, .view);
    defer freeOutput(gpa, b);
    try std.testing.expectEqualStrings(a.bytes, b.bytes);
    try std.testing.expectEqual(a.dropped.len, b.dropped.len);
    for (a.dropped, b.dropped) |x, y| try std.testing.expectEqualStrings(x, y);
    // Sorted and deduped, one entry per dropped helper.
    try std.testing.expectEqual(@as(usize, 2), a.dropped.len);
    try std.testing.expectEqualStrings("csrf_meta_tags dropped", a.dropped[0]);
    try std.testing.expectEqualStrings("javascript_importmap_tags dropped", a.dropped[1]);
}

test "convert: an asset the manifest cannot pin gets the ASSET_TRANSFORM placeholder Stage 1 derives" {
    const gpa = std.testing.allocator;
    const path = "app/views/pages/a.html.erb";
    const id = "RAILS_ASSET_TRANSFORM.app/views/pages/a%2Ehtml%2Eerb.L1C1";
    const finding_list = [_]findings.Finding{mkFinding(id, "RAILS_ASSET_TRANSFORM", path, 1)};
    const asset_list = [_]assets.Asset{mkAsset("app/assets/images/logo.png", false)};
    const nodes = [_]fragments.Node{
        blk: {
            var n = cNode(.asset, 1, 1, "image_tag");
            n.args = &.{"logo.png"};
            break :blk n;
        },
    };
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &asset_list,
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
    }, mkTemplate(path, &nodes), .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings(
        "<!-- rails:finding " ++ id ++ " --><!-- rails:end -->\n",
        out.bytes,
    );
    try std.testing.expectEqualStrings(id, out.open_finding_ids[0]);
}

test "convert: every kind treated as a finding has a Stage 1 derivation row -- no exemptions left" {
    // The plan asks for proof that the derivation table covers every kind
    // this converter turns into a placeholder, and as of ruling S12 it DOES.
    //
    // This test used to pin the opposite: six kinds (`form`, `form_field`,
    // `errors`, `turbo_frame`, `turbo_stream`, `component_root`) were a
    // recorded gap, because the plan's Global Constraints park their real
    // handling on Stages 3 and 4. That reading was wrong in a way this test
    // was built to make visible: a placeholder with no finding behind it is
    // not a deferral, it is a route that can never be acknowledged, because
    // `rails:unmapped` carries no id for a decision to name (ruling S6 keeps
    // such a route `open`, correctly, and forever). Stage 2 now derives all
    // six with `retain`/`blocked`; Stages 3/4 widen their CHOICES rather than
    // introducing them.
    //
    // The equality below is therefore the real invariant, with no exemption
    // list to drift: a new `isFindingKind` entry without a derivation row
    // fails here.
    const gpa = std.testing.allocator;
    inline for (@typeInfo(fragments.Kind).@"enum".fields) |f| {
        const kind = @field(fragments.Kind, f.name);
        if (isFindingKind(kind)) {
            const nodes = [_]fragments.Node{cNode(kind, 1, 1, "x")};
            const derived = try findings.derive(gpa, .{
                .templates = &[_]fragments.Template{mkTemplate("app/views/pages/a.html.erb", &nodes)},
                .layouts = &.{},
                .controller_files = &.{},
                .route_names = &.{},
                .locale = null,
            });
            defer findings.free(gpa, derived);
            try std.testing.expectEqual(@as(usize, 1), derived.len);
            // And the converter can FIND it: the id it would splice into the
            // page is the id the table produced. Asserted through the real
            // lookup rather than an `endsWith(".L1C1")` on the string, because
            // the string check passes whatever `findingIdFor` does -- it would
            // still hold if the lookup matched on the wrong path, or stopped
            // matching at all. Without this the two halves could each be right
            // on their own and never line up.
            try std.testing.expect(findingIdFor(derived, "app/views/pages/a.html.erb", 1, 1) != null);
            try std.testing.expectEqualStrings(
                derived[0].id,
                findingIdFor(derived, "app/views/pages/a.html.erb", 1, 1).?,
            );
        }
    }
}

// ---- rulings S7/S8/S9/S10: the layout/view block interface ----------------
//
// SuperHTML fatals in BOTH directions -- a block with no matching `<super>`
// is an `UNBOUND TOP-LEVEL BLOCK`, a `<super>` with no matching block is a
// `MISSING TOP-LEVEL BLOCK` -- so these tests convert a layout AND a view and
// assert the pair agrees, which is the only property that actually matters.

/// Converts `layout_nodes` as a layout, then `view_nodes` as a view whose
/// `layout_blocks` come from that layout's own `block_ids`. Exactly what
/// `scaffold.zig` will do.
fn convertPair(
    gpa: std.mem.Allocator,
    layout_nodes: []const fragments.Node,
    view_nodes: []const fragments.Node,
) !struct { layout: Output, view: Output } {
    const layout = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/layouts/application.html.erb", layout_nodes), .layout);
    errdefer freeOutput(gpa, layout);
    const view = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = "application",
        .layout_blocks = layout.block_ids,
    }, mkTemplate("app/views/pages/a.html.erb", view_nodes), .view);
    return .{ .layout = layout, .view = view };
}

/// Every `id="…"` a template declares a block or a `<super>` under, in order
/// of appearance -- the interface the two halves must agree on.
fn idsIn(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, "id=\"")) |idx| {
        const start = idx + 4;
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '"') orelse break;
        try out.append(gpa, bytes[start..end]);
        at = end;
    }
}

test "convert: ruling S7 -- layout and view agree on head/main whichever side declares them" {
    const gpa = std.testing.allocator;
    const yield_head = cNode(.yield_named, 3, 5, "head");
    // Four layouts x two views. The layouts differ in whether they name the
    // head block themselves; the views in whether they fill it.
    const layouts: []const []const fragments.Node = &.{
        // (1) a plain `<head>` and no `yield :head` -- the common Rails case,
        //     and the one that used to leave a view's head block UNBOUND.
        &.{ tNode("<html><head><title>x</title></head><body>", 1), cNode(.yield, 2, 1, null), tNode("</body></html>", 3) },
        // (2) `<head lang="en">` plus an explicit `yield :head` -- the old
        //     bare `lastIndexOf("<head>")` matched neither.
        &.{ tNode("<html><head lang=\"en\">", 1), yield_head, tNode("</head><body>", 4), cNode(.yield, 5, 1, null), tNode("</body></html>", 6) },
        // (3) no `<head>` at all, but an `<html>` to hang one off.
        &.{ tNode("<html><body>", 1), cNode(.yield, 2, 1, null), tNode("</body></html>", 3) },
        // (4) a fragment layout: no `<html>`, no `<head>`, and no bare yield
        //     either, so BOTH blocks are synthesised.
        &.{tNode("<p>bare</p>", 1)},
    };
    const views: []const []const fragments.Node = &.{
        // fills the head block
        &.{ openNode(.content_for, 1, 1, "head", "content_for :head do"), tNode("<meta charset=\"utf-8\">", 1), endNode(1, 40), tNode("<p>body</p>", 2) },
        // does not
        &.{tNode("<p>body</p>", 1)},
    };

    for (layouts) |ln| for (views) |vn| {
        const pair = try convertPair(gpa, ln, vn);
        defer freeOutput(gpa, pair.layout);
        defer freeOutput(gpa, pair.view);

        try std.testing.expectEqual(@as(usize, 2), pair.layout.block_ids.len);
        try std.testing.expectEqualStrings("head", pair.layout.block_ids[0]);
        try std.testing.expectEqualStrings("main", pair.layout.block_ids[1]);

        // Exactly one `<super>` per declared id in the layout, and exactly
        // one block per declared id in the view.
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pair.layout.bytes, "<super>"));
        var layout_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer layout_ids.deinit(gpa);
        try idsIn(gpa, pair.layout.bytes, &layout_ids);
        var view_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer view_ids.deinit(gpa);
        try idsIn(gpa, pair.view.bytes, &view_ids);
        try std.testing.expectEqual(layout_ids.items.len, view_ids.items.len);
        std.mem.sort([]const u8, layout_ids.items, {}, lessThanString);
        std.mem.sort([]const u8, view_ids.items, {}, lessThanString);
        for (layout_ids.items, view_ids.items) |l, v| try std.testing.expectEqualStrings(l, v);
        // The head block is a `<head>`, not a `<div>`: a div in the document
        // head is not valid HTML.
        try std.testing.expect(std.mem.indexOf(u8, pair.view.bytes, "<head id=\"head\"") != null);
    };
}

test "convert: ruling S8 -- a <title> with text around the yield keeps only :text, and says what it dropped" {
    const gpa = std.testing.allocator;
    const ctx: Context = .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    };

    const suffix = [_]fragments.Node{
        tNode("<head><title>", 1),
        cNode(.yield_named, 1, 14, "title"),
        tNode(" &middot; MyApp</title></head>", 1),
    };
    const out_suffix = try convert(gpa, ctx, mkTemplate("app/views/layouts/a.html.erb", &suffix), .layout);
    defer freeOutput(gpa, out_suffix);
    // Exactly one `<title>` element, and no orphan `</title>`.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out_suffix.bytes, "<title"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out_suffix.bytes, "</title>"));
    try std.testing.expect(std.mem.indexOf(u8, out_suffix.bytes, "<title :text=\"$page.title\"></title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_suffix.bytes, "MyApp") == null);
    try std.testing.expectEqualStrings(
        "<title> suffix '&middot; MyApp' dropped: :text needs an empty element",
        out_suffix.dropped[0],
    );

    const prefix = [_]fragments.Node{
        tNode("<head><title>MyApp | ", 1),
        cNode(.yield_named, 1, 22, "title"),
        tNode("</title></head>", 1),
    };
    const out_prefix = try convert(gpa, ctx, mkTemplate("app/views/layouts/b.html.erb", &prefix), .layout);
    defer freeOutput(gpa, out_prefix);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out_prefix.bytes, "</title>"));
    try std.testing.expect(std.mem.indexOf(u8, out_prefix.bytes, "MyApp") == null);
    try std.testing.expectEqualStrings(
        "<title> prefix 'MyApp |' dropped: :text needs an empty element",
        out_prefix.dropped[0],
    );
}

test "convert: ruling S10 -- yield(:title) outside a <title> interpolates through a ctx" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        tNode("<h1>", 1),
        cNode(.yield_named, 1, 5, "title"),
        tNode("</h1>", 1),
    };
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/layouts/c.html.erb", &nodes), .layout);
    defer freeOutput(gpa, out);
    // A `<div id="title"><super></div>` here would be a block nobody fills
    // (and invalid inside an `<h1>`); `<ctx>` carries the directive and is
    // itself never emitted.
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "<h1><ctx :text=\"$page.title\"></ctx></h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "id=\"title\"") == null);
}

test "convert: ruling S9 -- a named yield is a block a view fills, or an empty one, or a dropped content_for" {
    const gpa = std.testing.allocator;
    const layout_nodes = [_]fragments.Node{
        tNode("<html><head></head><body><aside>", 1),
        cNode(.yield_named, 1, 33, "sidebar"),
        tNode("</aside>", 1),
        cNode(.yield, 2, 1, null),
        tNode("</body></html>", 3),
    };
    const filled = [_]fragments.Node{
        openNode(.content_for, 1, 1, "sidebar", "content_for :sidebar do"),
        tNode("<p>links</p>", 1),
        endNode(1, 40),
        tNode("<p>body</p>", 2),
    };
    const pair = try convertPair(gpa, &layout_nodes, &filled);
    defer freeOutput(gpa, pair.layout);
    defer freeOutput(gpa, pair.view);
    try std.testing.expectEqual(@as(usize, 3), pair.layout.block_ids.len);
    try std.testing.expectEqualStrings("head", pair.layout.block_ids[0]);
    try std.testing.expectEqualStrings("main", pair.layout.block_ids[1]);
    try std.testing.expectEqualStrings("sidebar", pair.layout.block_ids[2]);
    try std.testing.expect(std.mem.indexOf(u8, pair.layout.bytes, "<div id=\"sidebar\"><super></div>") != null);
    try std.testing.expectEqualStrings(
        \\<extend template="application.shtml">
        \\<head id="head"></head>
        \\<div id="main">
        \\<p>body</p>
        \\</div>
        \\<div id="sidebar">
        \\<p>links</p>
        \\</div>
        \\
    , pair.view.bytes);

    // The same layout, a view that does not fill the sidebar: the block is
    // still emitted, empty, because the layout's `<super>` needs one.
    const unfilled = [_]fragments.Node{tNode("<p>body</p>", 1)};
    const pair2 = try convertPair(gpa, &layout_nodes, &unfilled);
    defer freeOutput(gpa, pair2.layout);
    defer freeOutput(gpa, pair2.view);
    try std.testing.expect(std.mem.indexOf(u8, pair2.view.bytes, "<div id=\"sidebar\"></div>") != null);

    // A `content_for` naming an id no `<super>` carries: Rails never renders
    // it either, so it is dropped with a note rather than emitted as an
    // unbound block.
    const stray = [_]fragments.Node{
        openNode(.content_for, 1, 1, "nope", "content_for :nope do"),
        tNode("<p>orphan</p>", 1),
        endNode(1, 40),
        tNode("<p>body</p>", 2),
    };
    const pair3 = try convertPair(gpa, &layout_nodes, &stray);
    defer freeOutput(gpa, pair3.layout);
    defer freeOutput(gpa, pair3.view);
    try std.testing.expect(std.mem.indexOf(u8, pair3.view.bytes, "orphan") == null);
    try std.testing.expect(std.mem.indexOf(u8, pair3.view.bytes, "id=\"nope\"") == null);
    try std.testing.expectEqualStrings(
        "content_for :nope dropped: the layout declares no block with that id",
        pair3.view.dropped[0],
    );
}

test "convert: a constructed attribute value starting with $ is not a Scripty expression" {
    const gpa = std.testing.allocator;
    const attrs = [_]fragments.Attr{.{ .key = "title", .value = "$5 off" }};
    const nodes = [_]fragments.Node{
        blk: {
            var n = cNode(.link_to, 1, 1, null);
            n.args = &.{ "Deal", "$special" };
            n.attrs = &attrs;
            break :blk n;
        },
    };
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/pages/a.html.erb", &nodes), .partial);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings(
        "<a href=\"&#36;special\" title=\"&#36;5 off\">Deal</a>\n",
        out.bytes,
    );
}

test "convert: an asset path is escaped for Scripty, and one link is emitted per stylesheet argument" {
    const gpa = std.testing.allocator;
    const asset_list = [_]assets.Asset{
        mkAsset("app/assets/stylesheets/application.css", true),
        mkAsset("app/assets/stylesheets/print.css", true),
        mkAsset("app/assets/images/it's a logo.png", true),
    };
    const nodes = [_]fragments.Node{
        blk: {
            var n = cNode(.asset, 1, 1, "stylesheet_link_tag");
            n.args = &.{ "application", "print" };
            break :blk n;
        },
        blk: {
            var n = cNode(.asset, 2, 1, "image_tag");
            n.args = &.{"it's a logo.png"};
            break :blk n;
        },
    };
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &asset_list,
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/pages/a.html.erb", &nodes), .partial);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings(
        "<link rel=\"stylesheet\" href=\"$site.asset('stylesheets/application.css').link()\">" ++
            "<link rel=\"stylesheet\" href=\"$site.asset('stylesheets/print.css').link()\">" ++
            "<img src=\"$site.asset('images/it\\'s a logo.png').link()\">\n",
        out.bytes,
    );
}

// ---- fix round 2: content that must not vanish ---------------------------

test "convert: a standalone view keeps its content_for :head instead of dropping it" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        openNode(.content_for, 1, 1, "head", "content_for :head do"),
        tNode("<meta name=\"description\" content=\"Standalone\">", 1),
        endNode(1, 50),
        tNode("<p>Body</p>", 2),
    };
    // `layout_stem == null`: nothing to extend, so there are no blocks --
    // but the head content is still content, and inlining it is the only
    // answer that does not silently delete the author's `<meta>`.
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/pages/a.html.erb", &nodes), .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings(
        "<meta name=\"description\" content=\"Standalone\"><p>Body</p>\n",
        out.bytes,
    );
    // ...and because it survives into `bytes`, the description is found.
    try std.testing.expectEqualStrings("Standalone", out.description.?);
    try std.testing.expectEqual(@as(usize, 0), out.dropped.len);
}

test "convert: content_for :main is appended to the main block, not swallowed" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        tNode("<p>Body</p>", 1),
        openNode(.content_for, 2, 1, "main", "content_for :main do"),
        tNode("<p>More</p>", 2),
        endNode(2, 40),
    };
    // Rails appends a `content_for :main` to whatever the template rendered
    // into that buffer, so it goes AFTER the body rather than replacing it.
    const extended = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = "application",
    }, mkTemplate("app/views/pages/a.html.erb", &nodes), .view);
    defer freeOutput(gpa, extended);
    try std.testing.expectEqualStrings(
        \\<extend template="application.shtml">
        \\<head id="head"></head>
        \\<div id="main">
        \\<p>Body</p><p>More</p>
        \\</div>
        \\
    , extended.bytes);

    const standalone = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/pages/a.html.erb", &nodes), .view);
    defer freeOutput(gpa, standalone);
    try std.testing.expectEqualStrings("<p>Body</p><p>More</p>\n", standalone.bytes);
}

test "convert: yield :main declares the main block once, like a bare yield" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        tNode("<html><head></head><body><main>", 1),
        cNode(.yield_named, 1, 32, "main"),
        tNode("</main></body></html>", 1),
    };
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/layouts/a.html.erb", &nodes), .layout);
    defer freeOutput(gpa, out);
    // One `<super>` for head, one for main -- `finishLayout` must not add a
    // second `id="main"` block next to the one the yield already placed
    // (`two_supers_one_id`), and `main` must appear once in `block_ids`.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.bytes, "<super>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.bytes, "id=\"main\""));
    try std.testing.expectEqual(@as(usize, 2), out.block_ids.len);
    try std.testing.expectEqualStrings("head", out.block_ids[0]);
    try std.testing.expectEqualStrings("main", out.block_ids[1]);
    // The author's own position is kept: inside their `<main>`, not appended
    // before `</body>`.
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "<main><div id=\"main\"><super></div></main>") != null);
}

test "convert: an unclosed <title> cannot outlive the block it was opened in" {
    const gpa = std.testing.allocator;
    // The `<title>` opens inside a `content_for :head`, whose frame redirects
    // the sink, and never closes there. A `</title>` further down the BODY
    // then ends a consume whose saved sink is the head block that already
    // closed -- so `<p>b</p>` was written back into `<head id="head">`, after
    // the body had moved on. Staged rather than observed, because that is the
    // only way to reach a restore of a dead sink deterministically.
    const nodes = [_]fragments.Node{
        openNode(.content_for, 1, 1, "head", "content_for :head do"),
        tNode("<title>", 1),
        cNode(.yield_named, 1, 8, "title"),
        endNode(2, 1),
        tNode("<p>a</p></title><p>b</p>", 3),
    };
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = "application",
    }, mkTemplate("app/views/pages/a.html.erb", &nodes), .view);
    defer freeOutput(gpa, out);
    try std.testing.expectEqualStrings(
        \\<extend template="application.shtml">
        \\<head id="head">
        \\<title :text="$page.title"></title>
        \\</head>
        \\<div id="main">
        \\<p>a</p></title><p>b</p>
        \\</div>
        \\
    , out.bytes);
}

test "convert: Turbo Drive attributes on a rewritten title use the template-level drop note" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        tNode("<head><title data-turbo-track=\"reload\">", 1),
        cNode(.yield_named, 1, 40, "title"),
        tNode("</title></head>", 1),
    };
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/layouts/a.html.erb", &nodes), .layout);
    defer freeOutput(gpa, out);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "<title :text=\"$page.title\"></title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "data-turbo-track") == null);
    try std.testing.expectEqualStrings(
        "data-turbo attributes dropped; Turbo Drive is ordinary navigation here",
        out.dropped[0],
    );
}

test "convert of a LAYOUT under a FailingAllocator leaks nothing on any partial allocation" {
    // The view sweep below never reaches `finishLayout`, `named_yields`,
    // `block_id_list`, a non-empty `block_ids`, or the `junk` buffer -- every
    // allocation on the layout path was unswept until this test.
    const nodes = [_]fragments.Node{
        tNode("<html><head><title>", 1),
        cNode(.yield_named, 1, 20, "title"),
        tNode(" &middot; MyApp</title></head><body><aside>", 1),
        cNode(.yield_named, 2, 1, "sidebar"),
        tNode("</aside>", 2),
        cNode(.yield, 3, 1, null),
        tNode("</body></html>", 4),
    };
    const ctx: Context = .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    };
    const tpl = mkTemplate("app/views/layouts/a.html.erb", &nodes);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (convert(gpa, ctx, tpl, .layout)) |out| {
            defer freeOutput(gpa, out);
            try std.testing.expectEqual(@as(usize, 3), out.block_ids.len);
            try std.testing.expectEqualStrings("sidebar", out.block_ids[2]);
            try std.testing.expectEqual(@as(usize, 1), out.dropped.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "convert under a FailingAllocator leaks nothing on any partial allocation" {
    const route_list = [_]routes.Route{mkRoute("GET", "/", "root")};
    const asset_list = [_]assets.Asset{mkAsset("app/assets/images/logo.png", true)};
    const nav_nodes = [_]fragments.Node{
        tNode("<nav>", 1),
        blk: {
            var n = cNode(.link_to, 1, 6, "root");
            n.args = &.{"Home"};
            break :blk n;
        },
        tNode("</nav>", 1),
    };
    const frag_list = [_]fragments.Template{mkTemplate("app/views/shared/_nav.html.erb", &nav_nodes)};
    const path = "app/views/pages/about.html.erb";
    const id = "RAILS_TEMPLATE_CONTROL_FLOW.app/views/pages/about%2Ehtml%2Eerb.L5C1";
    const finding_list = [_]findings.Finding{mkFinding(id, "RAILS_TEMPLATE_CONTROL_FLOW", path, 5)};
    const nodes = [_]fragments.Node{
        openNode(.content_for, 1, 1, "title", "content_for :title do"),
        tNode("About", 1),
        endNode(1, 30),
        tNode("<h1>Hi</h1>", 2),
        cNode(.render_partial, 3, 1, "shared/nav"),
        cNode(.csrf, 4, 1, "csrf_meta_tags"),
        openNode(.control, 5, 1, "if", "if flag"),
        tNode("<p>x</p>", 5),
        endNode(6, 1),
        blk: {
            var n = cNode(.asset, 7, 1, "image_tag");
            n.args = &.{"logo.png"};
            break :blk n;
        },
    };
    const ctx: Context = .{
        .routes = &route_list,
        .assets = &asset_list,
        .fragments = &frag_list,
        .findings = &finding_list,
        .layout_stem = "marketing",
    };
    const tpl = mkTemplate(path, &nodes);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (convert(gpa, ctx, tpl, .view)) |out| {
            defer freeOutput(gpa, out);
            try std.testing.expectEqualStrings("About", out.title.?);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "opensBlock treats closed element regions as blocks but never missing ones" {
    for ([_]fragments.Kind{ .stimulus, .vue_root, .component_root }) |kind| {
        var node = openNode(kind, 1, 1, "x", "<div>");
        try std.testing.expect(opensBlock(node));
        node.missing = true;
        try std.testing.expect(!opensBlock(node));
    }
    var frame = openNode(.turbo_frame, 1, 1, "x", "<turbo-frame>");
    frame.value = "turbo-frame";
    try std.testing.expect(opensBlock(frame));
    frame.missing = true;
    try std.testing.expect(!opensBlock(frame));
}

test "convert: a bound region becomes one <island>, and every id inside it is answered" {
    const gpa = std.testing.allocator;
    // The seam Stage 3 adds to this file: a node whose finding an operator
    // bound is not converted at all. No `rails:finding` marker, no
    // `rails:end`, no placeholder for the fields -- the island IS the region.
    const nodes = [_]fragments.Node{
        openNode(.form, 1, 4, "post", "form_with(model: @post) do |f|"),
        cNode(.form_field, 1, 40, "text_field"),
        endNode(1, 60),
    };
    const tpl = mkTemplate("app/views/posts/new.html.erb", &nodes);
    const finding_list = [_]findings.Finding{
        mkFinding(
            "RAILS_BACKEND_ENDPOINT.app/views/posts/new%2Ehtml%2Eerb.L1C4",
            "RAILS_BACKEND_ENDPOINT",
            "app/views/posts/new.html.erb",
            1,
        ),
    };
    const bindings = [_]Binding{.{
        .finding_id = finding_list[0].id,
        .kind = .operation,
        .verb = "POST",
        .path = "/api/collections/posts/records",
        .operation_id = "createPosts",
        .collection = "posts",
        .island = "components/forms/posts_new.island.tsx",
        .redirect_to = "/",
    }};

    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &bindings,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expect(std.mem.indexOf(
        u8,
        out.bytes,
        "<island src=\"components/forms/posts_new.island.tsx\" client:load></island>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "rails:") == null);
    try std.testing.expectEqual(@as(usize, 0), out.open_finding_ids.len);
    try std.testing.expectEqual(@as(usize, 1), out.bound_finding_ids.len);
    try std.testing.expectEqualStrings(finding_list[0].id, out.bound_finding_ids[0]);

    try std.testing.expectEqual(@as(usize, 1), out.islands.len);
    const spec = out.islands[0];
    try std.testing.expectEqualStrings("app/views/posts/new.html.erb", spec.source);
    try std.testing.expectEqual(@as(u64, 1), spec.line);
    // The header comment's `Replaces:` line: one line, whatever the ERB's
    // own wrapping was.
    try std.testing.expectEqualStrings("form_with(model: @post) do |f|", spec.original);
    try std.testing.expectEqual(@as(usize, 1), spec.fields.len);
    try std.testing.expectEqualStrings("text_field", spec.fields[0].helper);
    // No `f.submit` in the ERB, so the button gets a neutral default rather
    // than a label invented from the model name.
    try std.testing.expectEqualStrings("Save", spec.submit_label);
    try std.testing.expect(spec.errors_model == null);
}

test "convert: an id inside a bound region is bound, and says which answer swallowed it" {
    const gpa = std.testing.allocator;
    // Ruling S3-R6's mechanism, in the shape every Rails nav has it: a
    // `button_to … method: :delete` written INSIDE `<% if current_user %>`.
    // Both raise a finding, the operator answers the outer one, and the
    // island replaces the whole region -- so the inner id is answered by
    // somebody else's answer. `bound_finding_ids` alone cannot say that (it
    // holds the outer id too), which is why `enclosed` exists: an answer on
    // the region's own id IS the answer, while an answer on an id the region
    // swallowed is a second answer to a question already settled.
    const nodes = [_]fragments.Node{
        openNode(.request_state, 5, 6, "current_user", "if current_user"),
        linkNode(5, 54, "session", &.{"Sign out"}, &.{
            .{ .key = "method", .value = "delete" },
        }, "button_to \"Sign out\", session_path, method: :delete"),
        endNode(6, 1),
    };
    const tpl = mkTemplate("app/views/shared/_nav.html.erb", &nodes);
    const finding_list = [_]findings.Finding{
        mkFinding(
            "RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L5C6",
            "RAILS_REQUEST_TIME_STATE",
            "app/views/shared/_nav.html.erb",
            5,
        ),
        mkFinding(
            "RAILS_BACKEND_ENDPOINT.app/views/shared/_nav%2Ehtml%2Eerb.L5C54",
            "RAILS_BACKEND_ENDPOINT",
            "app/views/shared/_nav.html.erb",
            5,
        ),
    };
    const bindings = [_]Binding{.{
        .finding_id = finding_list[0].id,
        .kind = .auth_logout,
        .verb = "POST",
        .path = "auth-logout",
        .operation_id = "logout",
        .collection = "users",
        .island = "components/AuthStatus.island.tsx",
        .redirect_to = null,
    }};

    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &bindings,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    // The control is gone from the page: the island performs the logout.
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "href=\"/session\"") == null);
    try std.testing.expectEqual(@as(usize, 0), out.open_finding_ids.len);
    try std.testing.expectEqual(@as(usize, 2), out.bound_finding_ids.len);

    // Exactly one entry, and it is the INNER id: the region's own id is the
    // answer, not something the answer superseded.
    try std.testing.expectEqual(@as(usize, 1), out.enclosed.len);
    try std.testing.expectEqualStrings(finding_list[1].id, out.enclosed[0].id);
    try std.testing.expectEqualStrings(finding_list[0].id, out.enclosed[0].by);
}

test "convert: with no binding the same nested control is an open question, and nothing is enclosed" {
    const gpa = std.testing.allocator;
    // The other half of the pin above. Nothing was answered, so the region is
    // converted as two questions and `enclosed` stays empty -- the note ruling
    // S3-R6 adds must not fire on a run where no island swallowed anything.
    const nodes = [_]fragments.Node{
        openNode(.request_state, 5, 6, "current_user", "if current_user"),
        linkNode(5, 54, "session", &.{"Sign out"}, &.{
            .{ .key = "method", .value = "delete" },
        }, "button_to \"Sign out\", session_path, method: :delete"),
        endNode(6, 1),
    };
    const tpl = mkTemplate("app/views/shared/_nav.html.erb", &nodes);
    const finding_list = [_]findings.Finding{
        mkFinding(
            "RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L5C6",
            "RAILS_REQUEST_TIME_STATE",
            "app/views/shared/_nav.html.erb",
            5,
        ),
        mkFinding(
            "RAILS_BACKEND_ENDPOINT.app/views/shared/_nav%2Ehtml%2Eerb.L5C54",
            "RAILS_BACKEND_ENDPOINT",
            "app/views/shared/_nav.html.erb",
            5,
        ),
    };

    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &.{},
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expectEqual(@as(usize, 2), out.open_finding_ids.len);
    try std.testing.expectEqual(@as(usize, 0), out.bound_finding_ids.len);
    try std.testing.expectEqual(@as(usize, 0), out.enclosed.len);
}

/// One `link_to`/`button_to` node as `classify_link` reports it: the link
/// TEXT first in `args`, the route helper's own literal arguments after it,
/// and the `html_opts` literals in `attrs`.
fn linkNode(
    line: u64,
    col: u64,
    stem: ?[]const u8,
    args: []const []const u8,
    attrs: []const fragments.Attr,
    code: []const u8,
) fragments.Node {
    var n = cNode(.link_to, line, col, stem);
    n.args = args;
    n.attrs = attrs;
    n.code = code;
    return n;
}

test "convert: a bound button_to becomes an island instead of a link to the route it deletes" {
    const gpa = std.testing.allocator;
    // The gap this closes. `isFindingKind` says no to `link_to` -- correctly:
    // an unbound `link_to "Home", root_path` is an ordinary `<a href>` and
    // must stay one. But the walk asked THAT question on the way into the
    // binding arm too, so an answered `button_to … method: :delete` fell
    // through to `emitLink` and converted to `<a href="/session">`: a
    // navigation link to the route the control was supposed to DELETE, with
    // the binding `scaffold.bindTemplate` had built for it never consumed and
    // the route still reported bound.
    const attrs = [_]fragments.Attr{
        .{ .key = "method", .value = "delete" },
        .{ .key = "data-confirm", .value = "Sure?" },
    };
    const args = [_][]const u8{"Sign out"};
    const nodes = [_]fragments.Node{linkNode(
        3,
        5,
        "session",
        &args,
        &attrs,
        "button_to \"Sign out\", session_path, method: :delete",
    )};
    const tpl = mkTemplate("app/views/shared/_nav.html.erb", &nodes);
    const finding_list = [_]findings.Finding{mkFinding(
        "RAILS_BACKEND_ENDPOINT.app/views/shared/_nav%2Ehtml%2Eerb.L3C5",
        "RAILS_BACKEND_ENDPOINT",
        "app/views/shared/_nav.html.erb",
        3,
    )};
    const bindings = [_]Binding{.{
        .finding_id = finding_list[0].id,
        .kind = .custom,
        .verb = "DELETE",
        .path = "/api/session",
        .operation_id = "custom",
        .collection = null,
        .island = "components/forms/shared__nav.island.tsx",
        .redirect_to = "/",
    }};
    // A route the helper stem DOES resolve against, so an unbound conversion
    // would produce a perfectly good `<a href="/session">` -- the shape this
    // test has to be able to tell apart from the island.
    const route_list = [_]routes.Route{mkRoute("DELETE", "/session", "session")};

    const out = try convert(gpa, .{
        .routes = &route_list,
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &bindings,
    }, tpl, .partial);
    defer freeOutput(gpa, out);

    try std.testing.expect(std.mem.indexOf(
        u8,
        out.bytes,
        "<island src=\"components/forms/shared__nav.island.tsx\" client:load></island>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "<a href") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "rails:") == null);
    try std.testing.expectEqual(@as(usize, 0), out.open_finding_ids.len);
    try std.testing.expectEqual(@as(usize, 1), out.bound_finding_ids.len);
    try std.testing.expectEqualStrings(finding_list[0].id, out.bound_finding_ids[0]);

    try std.testing.expectEqual(@as(usize, 1), out.islands.len);
    const spec = out.islands[0];
    // `click` is the emitter's discriminator: this island is a button, and a
    // form island's empty `fields` cannot say so.
    const click = spec.click orelse return error.NotAClickIsland;
    try std.testing.expectEqualStrings("Sure?", click.confirm orelse "");
    // `session_path` names no record, so there is no id for a collection call
    // to address.
    try std.testing.expect(click.record_id == null);
    try std.testing.expectEqual(@as(usize, 0), spec.fields.len);
    // The link's own text is the button's label.
    try std.testing.expectEqualStrings("Sign out", spec.submit_label);
    try std.testing.expectEqualStrings("app/views/shared/_nav.html.erb", spec.source);
    try std.testing.expectEqual(@as(u64, 3), spec.line);
}

test "convert: a bound link carries the record its route helper names, and an unbound one is still a link" {
    const gpa = std.testing.allocator;
    // Two halves of the same gate. `post_path(1)` puts the record id in
    // `args[1]` -- the only place a link carries one, and what a
    // `delete(id)`/`update(id, …)` collection call needs. And the widened
    // gate must not widen the PLACEHOLDER arm to every link: an unbound
    // NAVIGATION link is still `<a href>`, exactly as before, or every link
    // in every template would become a region. (An unbound MUTATING link is
    // a region since round 4 -- the test after this one.)
    const del_attrs = [_]fragments.Attr{.{ .key = "method", .value = "delete" }};
    const del_args = [_][]const u8{ "Destroy", "1" };
    const nav_args = [_][]const u8{"Home"};
    const nodes = [_]fragments.Node{
        linkNode(1, 4, "post", &del_args, &del_attrs, "link_to \"Destroy\", post_path(1), method: :delete"),
        linkNode(2, 4, "root", &nav_args, &.{}, "link_to \"Home\", root_path"),
    };
    const tpl = mkTemplate("app/views/posts/show.html.erb", &nodes);
    const finding_list = [_]findings.Finding{mkFinding(
        "RAILS_BACKEND_ENDPOINT.app/views/posts/show%2Ehtml%2Eerb.L1C4",
        "RAILS_BACKEND_ENDPOINT",
        "app/views/posts/show.html.erb",
        1,
    )};
    const bindings = [_]Binding{.{
        .finding_id = finding_list[0].id,
        .kind = .operation,
        .verb = "DELETE",
        .path = "/api/collections/posts/records/{id}",
        .operation_id = "deletePosts",
        .collection = "posts",
        .island = "components/forms/posts_show.island.tsx",
        .redirect_to = null,
    }};
    const route_list = [_]routes.Route{
        mkRoute("DELETE", "/posts/:id", "post"),
        mkRoute("GET", "/", "root"),
    };

    const out = try convert(gpa, .{
        .routes = &route_list,
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &bindings,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expectEqual(@as(usize, 1), out.islands.len);
    const click = out.islands[0].click orelse return error.NotAClickIsland;
    try std.testing.expectEqualStrings("1", click.record_id orelse "");
    try std.testing.expect(click.confirm == null);

    // …and the unbound link beside it is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "<a href=\"/\">Home</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "rails:") == null);
}

test "convert: a literal-path target is not a record id" {
    const gpa = std.testing.allocator;
    // `classify_link` puts a literal target in `args[1]` -- the SAME slot a
    // route helper's record id lands in -- and only `name` says which it
    // was. Without the `head.name != null` guard, `link_to "Delete",
    // "/posts/1", method: :delete` would hand `/posts/1` to
    // `zb.collection("posts").delete(…)` as the record id.
    const attrs = [_]fragments.Attr{.{ .key = "method", .value = "delete" }};
    const args = [_][]const u8{ "Delete", "/posts/1" };
    const nodes = [_]fragments.Node{
        linkNode(1, 4, null, &args, &attrs, "link_to \"Delete\", \"/posts/1\", method: :delete"),
    };
    const tpl = mkTemplate("app/views/posts/show.html.erb", &nodes);
    const finding_list = [_]findings.Finding{mkFinding(
        "RAILS_BACKEND_ENDPOINT.app/views/posts/show%2Ehtml%2Eerb.L1C4",
        "RAILS_BACKEND_ENDPOINT",
        "app/views/posts/show.html.erb",
        1,
    )};
    const bindings = [_]Binding{.{
        .finding_id = finding_list[0].id,
        .kind = .operation,
        .verb = "DELETE",
        .path = "/api/collections/posts/records/{id}",
        .operation_id = "deletePosts",
        .collection = "posts",
        .island = "components/forms/posts_show.island.tsx",
        .redirect_to = null,
    }};
    const route_list = [_]routes.Route{mkRoute("DELETE", "/posts/:id", "post")};

    const out = try convert(gpa, .{
        .routes = &route_list,
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &bindings,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expectEqual(@as(usize, 1), out.islands.len);
    const click = out.islands[0].click orelse return error.NotAClickIsland;
    try std.testing.expect(click.record_id == null);
    try std.testing.expectEqualStrings("Delete", out.islands[0].submit_label);
}

test "convert: the Turbo spellings are honoured on a bound link, and a data sentinel is noted" {
    const gpa = std.testing.allocator;
    // Two links, one template. The first is what the sidecar sends for
    // `link_to "Sign out", logout_path, data: { turbo_method: :delete,
    // turbo_confirm: "Sign out?" }` since `flatten_opts`: the confirmation
    // is read off `data-turbo-confirm` exactly as off `data-confirm`. The
    // second is what an OLDER sidecar (chosen by `--runtime-path`) still
    // sends for the same ERB: the hash collapsed to `data="{...}"`, its
    // text gone. That one is still bound -- the answer stands -- but the
    // page and the notes say a guard may be missing, instead of shipping an
    // unguarded destructive control in silence.
    const turbo_attrs = [_]fragments.Attr{
        .{ .key = "data-turbo-method", .value = "delete" },
        .{ .key = "data-turbo-confirm", .value = "Sign out?" },
    };
    const sentinel_attrs = [_]fragments.Attr{
        .{ .key = "method", .value = "delete" },
        .{ .key = "data", .value = nested_hash_sentinel },
    };
    const args = [_][]const u8{"Sign out"};
    const nodes = [_]fragments.Node{
        linkNode(1, 4, "logout", &args, &turbo_attrs, "link_to \"Sign out\", logout_path, data: { turbo_method: :delete, turbo_confirm: \"Sign out?\" }"),
        linkNode(2, 4, "logout", &args, &sentinel_attrs, "button_to \"Sign out\", logout_path, method: :delete, data: { turbo_confirm: \"Sign out?\" }"),
    };
    const tpl = mkTemplate("app/views/pages/home.html.erb", &nodes);
    const finding_list = [_]findings.Finding{
        mkFinding(
            "RAILS_BACKEND_ENDPOINT.app/views/pages/home%2Ehtml%2Eerb.L1C4",
            "RAILS_BACKEND_ENDPOINT",
            "app/views/pages/home.html.erb",
            1,
        ),
        mkFinding(
            "RAILS_BACKEND_ENDPOINT.app/views/pages/home%2Ehtml%2Eerb.L2C4",
            "RAILS_BACKEND_ENDPOINT",
            "app/views/pages/home.html.erb",
            2,
        ),
    };
    const bindings = [_]Binding{
        .{
            .finding_id = finding_list[0].id,
            .kind = .custom,
            .verb = "DELETE",
            .path = "/api/logout",
            .operation_id = "custom",
            .collection = null,
            .island = "components/forms/pages_home.island.tsx",
            .redirect_to = "/",
        },
        .{
            .finding_id = finding_list[1].id,
            .kind = .custom,
            .verb = "DELETE",
            .path = "/api/logout",
            .operation_id = "custom",
            .collection = null,
            .island = "components/forms/pages_home_2.island.tsx",
            .redirect_to = "/",
        },
    };
    const route_list = [_]routes.Route{mkRoute("DELETE", "/logout", "logout")};

    const out = try convert(gpa, .{
        .routes = &route_list,
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &bindings,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expectEqual(@as(usize, 2), out.islands.len);
    const turbo = out.islands[0].click orelse return error.NotAClickIsland;
    try std.testing.expectEqualStrings("Sign out?", turbo.confirm orelse "");
    const collapsed = out.islands[1].click orelse return error.NotAClickIsland;
    try std.testing.expect(collapsed.confirm == null);

    // The sentinel never reaches the page as markup, and the warning sits
    // beside the island it is about -- after the second `<island>`, not the
    // first.
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, nested_hash_sentinel) == null);
    const warning = "<!-- rails: data: on this control was not recovered; a confirm guard may be missing -->";
    const second_island = std.mem.indexOf(u8, out.bytes, "pages_home_2.island.tsx") orelse return error.NoSecondIsland;
    const at = std.mem.indexOf(u8, out.bytes, warning) orelse return error.NoWarning;
    try std.testing.expect(at > second_island);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.bytes, warning));
    try std.testing.expectEqual(@as(usize, 1), out.dropped.len);
    try std.testing.expectEqualStrings(
        "app/views/pages/home.html.erb:2: nested data: on a bound control was not recovered; a confirm guard may be missing",
        out.dropped[0],
    );
}

test "convert: an UNBOUND link emits neither the hash sentinel nor an inert method" {
    const gpa = std.testing.allocator;
    // NEW-3, parked out of Task 4's round 4. The sentinel test above covers
    // the BOUND path, where `emitIsland` reports the collapsed hash and emits
    // no markup for it. The unbound path had no such guard: `button_to
    // "Search", about_path, method: :get, form: { class: "c" }` is a real
    // Rails spelling (a GET `button_to` is a search link), it raises no
    // finding because `:get` mutates nothing, and so it went out through
    // `emitLink` as
    //
    //     <a href="/about" method="get" form="{...}">Search</a>
    //
    // `form="{...}"` is the converter's own internal marker rendered into a
    // page as if it were the author's content -- it says nothing to a reader
    // and nothing to a browser -- and `method` is not an `<a>` attribute at
    // all (Task 4 round-4 O1): Rails put it on a `<form>`, and the only
    // `method` that can reach here is the inert GET/HEAD one, since a
    // mutating link is a region by the test below. Both are dropped; the
    // author's real attributes are not.
    const attrs = [_]fragments.Attr{
        .{ .key = "method", .value = "get" },
        .{ .key = "form", .value = nested_hash_sentinel },
        .{ .key = "class", .value = "btn" },
    };
    const args = [_][]const u8{"Search"};
    const nodes = [_]fragments.Node{
        linkNode(1, 4, "about", &args, &attrs, "button_to \"Search\", about_path, method: :get, form: { class: \"c\" }"),
    };
    const tpl = mkTemplate("app/views/pages/home.html.erb", &nodes);
    const route_list = [_]routes.Route{mkRoute("GET", "/about", "about")};

    const out = try convert(gpa, .{
        .routes = &route_list,
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
        .bindings = &.{},
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expectEqualStrings(
        "<a href=\"/about\" class=\"btn\">Search</a>\n",
        out.bytes,
    );
    // Stated separately from the byte comparison so a future change to the
    // surrounding markup cannot let either of these back in unnoticed.
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, nested_hash_sentinel) == null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "method=") == null);
}

test "convert: a sentinel-valued attribute is dropped from an image_tag too" {
    const gpa = std.testing.allocator;
    // The sentinel is `literal_attrs`' answer for ANY option whose value was
    // a nested hash it did not spell out, so `<a>` is not the only tag that
    // can carry one -- `image_tag "logo.png", data: { turbo: { permanent:
    // true } }` collapses the same way. The drop therefore lives in
    // `emitAttrs`, which every tag goes through, rather than in `emitLink`.
    const attrs = [_]fragments.Attr{
        .{ .key = "data", .value = nested_hash_sentinel },
        .{ .key = "alt", .value = "Logo" },
    };
    const args = [_][]const u8{"logo.png"};
    const nodes = [_]fragments.Node{blk: {
        var n = cNode(.asset, 1, 4, "image_tag");
        n.args = &args;
        n.attrs = &attrs;
        n.code = "image_tag \"logo.png\", data: { turbo: { permanent: true } }";
        break :blk n;
    }};
    const tpl = mkTemplate("app/views/pages/home.html.erb", &nodes);
    const asset_list = [_]assets.Asset{mkAsset("app/assets/images/logo.png", true)};

    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &asset_list,
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
        .bindings = &.{},
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expect(std.mem.indexOf(u8, out.bytes, nested_hash_sentinel) == null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "alt=\"Logo\"") != null);
    // `method` is dropped on the `<a>` only: it is meaningless there, but no
    // claim is being made about every other tag's attribute vocabulary.
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "<img src=") != null);
}

test "convert: an unbound mutating link is a region, and its finding stays open" {
    const gpa = std.testing.allocator;
    // Round 4. The finding existed and was unanswered, and the route still
    // came out `migrated`: `emitLink` resolved `logout_path`, emitted
    // `<a href="/logout">` -- a GET to a DELETE route -- and recorded no id,
    // so `open_finding_ids` had nothing to keep the route open with. A
    // question the operator has not answered has to be a region, exactly as
    // a form's is.
    const del_attrs = [_]fragments.Attr{.{ .key = "method", .value = "delete" }};
    const del_args = [_][]const u8{"Sign out"};
    const nav_args = [_][]const u8{"Home"};
    const nodes = [_]fragments.Node{
        linkNode(1, 4, "logout", &del_args, &del_attrs, "button_to \"Sign out\", logout_path, method: :delete"),
        linkNode(2, 4, "root", &nav_args, &.{}, "link_to \"Home\", root_path"),
    };
    const tpl = mkTemplate("app/views/pages/home.html.erb", &nodes);
    const finding_list = [_]findings.Finding{mkFinding(
        "RAILS_BACKEND_ENDPOINT.app/views/pages/home%2Ehtml%2Eerb.L1C4",
        "RAILS_BACKEND_ENDPOINT",
        "app/views/pages/home.html.erb",
        1,
    )};
    // Both helpers resolve, so the old conversion produced a perfectly good
    // `<a href="/logout">` -- the shape the assertions have to rule out.
    const route_list = [_]routes.Route{
        mkRoute("DELETE", "/logout", "logout"),
        mkRoute("GET", "/", "root"),
    };
    const ctx: Context = .{
        .routes = &route_list,
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
    };

    const out = try convert(gpa, ctx, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expect(std.mem.indexOf(
        u8,
        out.bytes,
        "<!-- rails:finding " ++ "RAILS_BACKEND_ENDPOINT.app/views/pages/home%2Ehtml%2Eerb.L1C4" ++ " --><!-- rails:end -->",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "/logout") == null);
    try std.testing.expectEqual(@as(usize, 1), out.open_finding_ids.len);
    try std.testing.expectEqualStrings(finding_list[0].id, out.open_finding_ids[0]);
    try std.testing.expectEqual(@as(usize, 0), out.islands.len);
    try std.testing.expectEqual(@as(usize, 0), out.bound_finding_ids.len);
    // The navigation link beside it asks nothing and stays a link: the
    // predicate is "does it submit", not "is it a link".
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "<a href=\"/\">Home</a>") != null);

    // Ruling S6's net holds for a link too: the same control with its
    // finding missing from the list is `rails:unmapped`, never an `<a href>`,
    // so the route cannot reach `migrated` on the strength of an empty
    // `open_finding_ids` either.
    var bare = ctx;
    bare.findings = &.{};
    const out_bare = try convert(gpa, bare, tpl, .view);
    defer freeOutput(gpa, out_bare);
    try std.testing.expect(std.mem.indexOf(u8, out_bare.bytes, "<!-- rails:unmapped link_to L1C4 -->") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_bare.bytes, "/logout") == null);
    try std.testing.expectEqual(@as(usize, 0), out_bare.open_finding_ids.len);
}

test "convert: a branch named after what it branches on is still a region" {
    const gpa = std.testing.allocator;
    // Ruling R2c renames an `<% if signed_in? %>` statement from `control` to
    // `request_state`, and `<% if @post.errors.any? %>` to `errors`. The
    // sidecar still pairs both with a `block_end`, so reading only `.control`
    // ended the region at the marker: the body converted as though it were
    // unconditional and the `end` was dropped on the floor.
    const nodes = [_]fragments.Node{
        openNode(.request_state, 1, 1, "signed_in?", "if signed_in?"),
        cNode(.ivar, 1, 20, "@user"),
        endNode(1, 40),
        // A statement whose code merely STARTS with the letters of a keyword
        // opens nothing, and the sidecar emits no `end` for it -- so treating
        // it as a block would swallow every node after it into a region.
        openNode(.unknown, 2, 1, null, "iffy_helper"),
        cNode(.ivar, 3, 1, "@posts"),
    };
    const tpl = mkTemplate("app/views/shared/_nav.html.erb", &nodes);
    const finding_list = [_]findings.Finding{
        mkFinding(
            "RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L1C1",
            "RAILS_REQUEST_TIME_STATE",
            "app/views/shared/_nav.html.erb",
            1,
        ),
        mkFinding(
            "RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L1C20",
            "RAILS_REQUEST_TIME_STATE",
            "app/views/shared/_nav.html.erb",
            1,
        ),
        mkFinding(
            "RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L2C1",
            "RAILS_REQUEST_TIME_STATE",
            "app/views/shared/_nav.html.erb",
            2,
        ),
        mkFinding(
            "RAILS_REQUEST_TIME_STATE.app/views/shared/_nav%2Ehtml%2Eerb.L3C1",
            "RAILS_REQUEST_TIME_STATE",
            "app/views/shared/_nav.html.erb",
            3,
        ),
    };

    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    // ONE region for the branch: the `@user` inside it is nested, so it gets
    // no marker of its own, and the `@posts` AFTER the `end` gets one.
    var at: usize = 0;
    var markers: usize = 0;
    while (std.mem.indexOfPos(u8, out.bytes, at, "<!-- rails:finding ")) |k| {
        markers += 1;
        at = k + 1;
    }
    try std.testing.expectEqual(@as(usize, 3), markers);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, ".L1C20") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, ".L2C1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, ".L3C1") != null);
    // Every id is still REPORTED, nested or not: the operator has to be able
    // to answer the inner one.
    try std.testing.expectEqual(@as(usize, 4), out.open_finding_ids.len);
}

test "convert: a positional binding reaches a journey form, which has no finding of its own" {
    const gpa = std.testing.allocator;
    // Assumption A5: a form in an auth-journey view derives NO
    // `RAILS_BACKEND_ENDPOINT` -- the one `RAILS_AUTH_JOURNEY` row is the
    // question for the whole flow. So the node the island replaces carries no
    // id, and `finding_id` (the journey's, shared by both journey forms)
    // cannot pick it out of the stream. `Binding.at` is the key that can.
    const nodes = [_]fragments.Node{
        openNode(.form, 1, 4, null, "form_with(url: session_path) do |f|"),
        cNode(.form_field, 1, 40, "password_field"),
        endNode(1, 70),
    };
    const tpl = mkTemplate("app/views/sessions/new.html.erb", &nodes);
    // The journey's finding lives on `config/routes.rb`, not on this
    // template -- exactly why an id join cannot work here.
    const finding_list = [_]findings.Finding{
        mkFinding(
            "RAILS_AUTH_JOURNEY.config/routes%2Erb.L5",
            "RAILS_AUTH_JOURNEY",
            "config/routes.rb",
            5,
        ),
    };
    const bindings = [_]Binding{.{
        .finding_id = finding_list[0].id,
        .kind = .auth_signin,
        .verb = "POST",
        .path = "/api/collections/users/auth-with-password",
        .operation_id = "authWithPassword",
        .collection = "users",
        .island = "components/AuthForm.island.tsx",
        .redirect_to = "/",
        .props = "{ .mode = \"signin\" }",
        .at = .{ .path = "app/views/sessions/new.html.erb", .line = 1, .col = 4 },
    }};

    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &bindings,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    // The props ride on the tag: one component, two Rails views, and the
    // mode is the only thing that differs between them.
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.bytes,
        "<island src=\"components/AuthForm.island.tsx\" client:load :props='{ .mode = \"signin\" }'></island>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "rails:") == null);
    try std.testing.expectEqual(@as(usize, 1), out.islands.len);
    try std.testing.expectEqualStrings("password_field", out.islands[0].fields[0].helper);
}

test "convert: a positional binding binds THAT node and no other with the same id" {
    const gpa = std.testing.allocator;
    // `at` is the only key when it is set, never a fallback after the id.
    // Two journey forms share one `finding_id` (the journey's), so an id
    // fallback would let the sign-in binding claim the sign-up form too --
    // and the sign-up view would mount the island with the wrong mode.
    const nodes = [_]fragments.Node{
        openNode(.form, 1, 4, null, "form_with(url: registration_path) do |f|"),
        endNode(1, 70),
    };
    const tpl = mkTemplate("app/views/registrations/new.html.erb", &nodes);
    // A finding that DOES sit on this node, and whose id the binding also
    // carries: the only thing keeping the binding off it is that `at` names
    // somewhere else.
    const finding_list = [_]findings.Finding{
        mkFinding(
            "RAILS_BACKEND_ENDPOINT.app/views/registrations/new%2Ehtml%2Eerb.L1C4",
            "RAILS_BACKEND_ENDPOINT",
            "app/views/registrations/new.html.erb",
            1,
        ),
    };
    const bindings = [_]Binding{.{
        .finding_id = finding_list[0].id,
        .kind = .auth_signin,
        .verb = "POST",
        .path = "/api/collections/users/auth-with-password",
        .operation_id = "authWithPassword",
        .collection = "users",
        .island = "components/AuthForm.island.tsx",
        .redirect_to = "/",
        .props = "{ .mode = \"signin\" }",
        // A DIFFERENT template's form.
        .at = .{ .path = "app/views/sessions/new.html.erb", .line = 1, .col = 4 },
    }};

    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &bindings,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expectEqual(@as(usize, 0), out.islands.len);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "<island") == null);
}

test "convert: a bound form absorbs the errors summary its model names, and nothing else's" {
    const gpa = std.testing.allocator;
    // Rails writes the summary as a SIBLING above the form, so it is not in
    // the region the island replaces -- yet the island already renders
    // `ZigbaseError.data`, and leaving the ERB copy would render an empty
    // `<ul>` for ever. The `|m|` loop local inside it is #181's exact shape.
    const nodes = [_]fragments.Node{
        openNode(.errors, 1, 4, "@post", "@post.errors.full_messages.each do |m|"),
        cNode(.local, 1, 44, "m"),
        endNode(1, 60),
        openNode(.errors, 2, 4, "@user", "@user.errors.full_messages.each do |m|"),
        cNode(.local, 2, 44, "m"),
        endNode(2, 60),
        openNode(.form, 3, 4, "post", "form_with(model: @post) do |f|"),
        endNode(3, 40),
    };
    const tpl = mkTemplate("app/views/posts/new.html.erb", &nodes);
    const p = "app/views/posts/new.html.erb";
    const finding_list = [_]findings.Finding{
        mkFinding("RAILS_REQUEST_TIME_STATE.x.L1C4", "RAILS_REQUEST_TIME_STATE", p, 1),
        mkFinding("RAILS_REQUEST_TIME_STATE.x.L2C4", "RAILS_REQUEST_TIME_STATE", p, 2),
        mkFinding("RAILS_BACKEND_ENDPOINT.x.L3C4", "RAILS_BACKEND_ENDPOINT", p, 3),
    };
    const bindings = [_]Binding{.{
        .finding_id = "RAILS_BACKEND_ENDPOINT.x.L3C4",
        .kind = .operation,
        .verb = "POST",
        .path = "/api/collections/posts/records",
        .operation_id = "createPosts",
        .collection = "posts",
        .island = "components/forms/posts_new.island.tsx",
        .redirect_to = null,
    }};

    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &bindings,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    // `@post.errors` is the form's own model: absorbed, local and all.
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "L1C4") == null);
    // `@user.errors` belongs to something else and stays a finding region.
    // Its `|m|` is owned by that answerable region rather than becoming a
    // second, id-less marker that no decision can name (#181).
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "L2C4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "rails:unmapped local") == null);
    try std.testing.expectEqual(@as(usize, 1), out.open_finding_ids.len);
    try std.testing.expectEqualStrings("RAILS_REQUEST_TIME_STATE.x.L2C4", out.open_finding_ids[0]);
    try std.testing.expectEqual(@as(usize, 2), out.bound_finding_ids.len);
    // The island renders the summary where the ERB had it: at the top.
    try std.testing.expectEqualStrings("@post", out.islands[0].errors_model orelse "");
}

test "convert: an id-less outer region cannot claim its nested block local" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        openNode(.errors, 1, 4, "@post", "@post.errors.full_messages.each do |m|"),
        cNode(.local, 1, 44, "m"),
        endNode(1, 60),
    };
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &.{},
        .layout_stem = null,
    }, mkTemplate("app/views/posts/new.html.erb", &nodes), .view);
    defer freeOutput(gpa, out);

    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "rails:unmapped errors") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "rails:unmapped local") != null);
}

test "convert: a model-less form absorbs the template's error summary whatever it names" {
    const gpa = std.testing.allocator;
    // `form_with(url: ...)` has no model, so there is nothing to match on --
    // and exactly one error summary it could belong to.
    const nodes = [_]fragments.Node{
        openNode(.errors, 1, 4, "@user", "@user.errors.any?"),
        endNode(1, 40),
        openNode(.form, 2, 4, null, "form_with(url: session_path) do |f|"),
        endNode(2, 40),
    };
    const tpl = mkTemplate("app/views/sessions/new.html.erb", &nodes);
    const p = "app/views/sessions/new.html.erb";
    const finding_list = [_]findings.Finding{
        mkFinding("RAILS_REQUEST_TIME_STATE.y.L1C4", "RAILS_REQUEST_TIME_STATE", p, 1),
        mkFinding("RAILS_BACKEND_ENDPOINT.y.L2C4", "RAILS_BACKEND_ENDPOINT", p, 2),
    };
    const bindings = [_]Binding{.{
        .finding_id = "RAILS_BACKEND_ENDPOINT.y.L2C4",
        .kind = .custom,
        .verb = "POST",
        .path = "/api/contact",
        .operation_id = "custom",
        .collection = null,
        .island = "components/forms/sessions_new.island.tsx",
        .redirect_to = null,
    }};

    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
        .bindings = &bindings,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expectEqual(@as(usize, 0), out.open_finding_ids.len);
    try std.testing.expectEqual(@as(usize, 2), out.bound_finding_ids.len);
}

test "convert: with no bindings the same template converts exactly as before" {
    const gpa = std.testing.allocator;
    // The default `Context.bindings` is empty, and an empty binding list must
    // change nothing: every pre-Stage-3 caller relies on it.
    const nodes = [_]fragments.Node{
        openNode(.form, 1, 4, "post", "form_with(model: @post) do |f|"),
        cNode(.form_field, 1, 40, "text_field"),
        endNode(1, 60),
    };
    const tpl = mkTemplate("app/views/posts/new.html.erb", &nodes);
    const finding_list = [_]findings.Finding{
        mkFinding(
            "RAILS_BACKEND_ENDPOINT.app/views/posts/new%2Ehtml%2Eerb.L1C4",
            "RAILS_BACKEND_ENDPOINT",
            "app/views/posts/new.html.erb",
            1,
        ),
    };
    const out = try convert(gpa, .{
        .routes = &.{},
        .assets = &.{},
        .fragments = &.{},
        .findings = &finding_list,
        .layout_stem = null,
    }, tpl, .view);
    defer freeOutput(gpa, out);

    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "<island") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes, "rails:finding") != null);
    try std.testing.expectEqual(@as(usize, 1), out.open_finding_ids.len);
    try std.testing.expectEqual(@as(usize, 0), out.bound_finding_ids.len);
    try std.testing.expectEqual(@as(usize, 0), out.islands.len);
}
