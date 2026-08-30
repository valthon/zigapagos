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
}

/// Contract 2 counterpart to the two `finalize*` builders.
fn freeStrings(gpa: Allocator, list: [][]const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
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
    switch (node.kind) {
        // `emit_statement` always pairs these with a `block_end`, whatever
        // their source text looks like (`if x` carries no `do`).
        .control => return true,
        .block_else, .block_end => return false,
        else => return codeOpensBlock(node.code),
    }
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
fn matchingEnd(nodes: []const fragments.Node, open: usize) ?usize {
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
        => true,
        else => false,
    };
}

/// The finding Stage 1 derived at this exact source position, or `null`.
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
fn findingIdFor(finding_list: []const findings.Finding, path: []const u8, line: u64, col: u64) ?[]const u8 {
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
    /// Owned notes.
    dropped: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Partial paths currently being inlined -- the cycle guard.
    stack: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Nesting depth of finding regions; only depth 0 emits a marker.
    finding_depth: usize = 0,
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
        for (c.dropped.items) |d| c.gpa.free(d);
        c.dropped.deinit(c.gpa);
        c.stack.deinit(c.gpa);
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

    fn emitText(c: *Converter, text: []const u8) Allocator.Error!void {
        if (c.consuming_title) {
            // Everything between the rewritten `<title>` and the original
            // `</title>` is swallowed: `:text` fills an element that must be
            // EMPTY, so a `<title><%= yield(:title) %> · MyApp</title>` has
            // nowhere to keep the ` · MyApp`.
            if (std.mem.indexOf(u8, text, "</title>")) |at| {
                try c.put(text[0..at]);
                try c.endTitleConsume();
                try c.put(text[at + "</title>".len ..]);
                return;
            }
            try c.put(text);
            return;
        }
        try c.put(text);
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

    fn walk(
        c: *Converter,
        path: []const u8,
        nodes: []const fragments.Node,
        locals: []const fragments.Attr,
    ) Allocator.Error!void {
        var frames: std.ArrayListUnmanaged(Frame) = .empty;
        defer frames.deinit(c.gpa);

        var i: usize = 0;
        while (i < nodes.len) : (i += 1) {
            const n = nodes[i];
            if (n.text) |t| {
                try c.emitText(t);
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
                    if (f.is_finding) c.finding_depth -= 1;
                    if (f.emitted) try c.put("<!-- rails:end -->");
                    if (f.close.len > 0) try c.put(f.close);
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
                    if (n.value) |v| {
                        c.setTitle(v);
                        continue;
                    }
                    if (opens) {
                        if (matchingEnd(nodes, i)) |e| {
                            if (singleLiteralChild(nodes[i + 1 .. e])) |t| {
                                c.setTitle(t);
                                i = e;
                                continue;
                            }
                        }
                    }
                    // A title this stage cannot evaluate is a GAP, not a
                    // title, and it must not fall through to the generic
                    // `content_for` conversion either: a `<div id="title">`
                    // in the middle of the `id="main"` block is not a
                    // SuperHTML block (those are top-level only) and would
                    // render the computed title's markup inline as if it were
                    // page content. `unmapped`, because `content_for` has no
                    // derivation row to point an operator at.
                    try c.unmapped(n);
                    if (opens) {
                        try frames.append(c.gpa, .{ .close = "", .is_finding = true, .emitted = false, .prev_sink = null });
                        c.finding_depth += 1;
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

            if (isFindingKind(n.kind)) {
                const emitted = try c.openRegion(path, n);
                if (opens) {
                    try frames.append(c.gpa, .{ .close = "", .is_finding = true, .emitted = emitted, .prev_sink = null });
                    c.finding_depth += 1;
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
                const name = n.name orelse return c.unmapped(n);
                for (locals) |l| {
                    if (std.mem.eql(u8, l.key, name)) return c.putEscaped(l.value);
                }
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
        try c.emitAttrs(n.attrs);
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

    fn emitAttrs(c: *Converter, attrs: []const fragments.Attr) Allocator.Error!void {
        // Source order, which `literal_attrs` preserves -- sorting them would
        // reorder the author's own markup for no benefit, and source order is
        // just as deterministic.
        for (attrs) |a| {
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
                try c.emitAttrs(n.attrs);
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
        // than the first in slice order: `ctx.fragments` comes off a
        // directory walk, whose order is not promised across machines.
        var best: ?[]const u8 = null;
        for (c.ctx.fragments) |t| {
            if (!std.mem.startsWith(u8, t.path, needle)) continue;
            if (best) |b| {
                if (std.mem.order(u8, t.path, b) != .lt) continue;
            }
            best = t.path;
        }
        return best;
    }
};

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
fn singleLiteralChild(nodes: []const fragments.Node) ?[]const u8 {
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
    const dropped = try finalizeOwned(gpa, &c.dropped);

    return .{
        .block_ids = block_ids,
        .bytes = bytes,
        .title = title,
        .description = description,
        .open_finding_ids = ids,
        .dropped = dropped,
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

test "convert: provide(:title, literal) lifts the title; a computed title stays a marked gap" {
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
    const out_computed = try convert(gpa, ctx, mkTemplate("app/views/pages/b.html.erb", &computed), .view);
    defer freeOutput(gpa, out_computed);
    try std.testing.expect(out_computed.title == null);
    try std.testing.expectEqualStrings(
        \\<extend template="marketing.shtml">
        \\<head id="head"></head>
        \\<div id="main">
        \\<!-- rails:unmapped content_for L1C1 --><p>x</p>
        \\</div>
        \\
    , out_computed.bytes);
    // The `@post` inside the unresolvable title is INSIDE that region, so it
    // emits no marker of its own -- the outermost-only rule.
    try std.testing.expectEqual(@as(usize, 0), out_computed.open_finding_ids.len);
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

test "convert: attributes on the rewritten <title> are reported, not silently lost" {
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
        "<title> attributes 'data-turbo-track=\"reload\"' dropped: the converted element carries only :text",
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
