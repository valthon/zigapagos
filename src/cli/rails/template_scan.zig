//! Text scan (not an ERB parse) over a template's raw source for the three
//! structural markers Stage 3 classification turns into evidence: does the
//! page read request-time state, does it wire up a Stimulus controller, does
//! it mount a JS component. Deliberately std-only -- no import escapes
//! `src/cli/rails/` -- so this backs the standalone `test-rails` suite like
//! its siblings.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Fixed-capacity, allocation-free set of borrowed name slices -- the
/// storage `Markers.stimulus_controllers`/`.component_roots` need to stay
/// contract 3 (caller-buffer: `scan` allocates nothing) while returning
/// more than one name. `names[0..len]` holds the slices; anything beyond
/// `cap` is documented truncation, not silent data loss: `addUnique` is a
/// no-op once `len == cap`, and every caller of `scan` can tell truncation
/// happened for a name it expected by checking `len == cap` itself (the
/// list is never partially deduped -- a full list is either exactly `cap`
/// distinct names, or fewer because there genuinely were fewer). See each
/// field's own doc for why its `cap` is never actually reachable in
/// practice.
fn BoundedNames(comptime cap: usize) type {
    return struct {
        const Self = @This();
        pub const capacity = cap;

        names: [cap][]const u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const Self) []const []const u8 {
            return self.names[0..self.len];
        }

        pub fn contains(self: *const Self, name: []const u8) bool {
            for (self.slice()) |n| {
                if (std.mem.eql(u8, n, name)) return true;
            }
            return false;
        }

        /// Adds `name` if it isn't already present. Silently a no-op past
        /// `cap` -- see this type's doc comment for why that is a
        /// documented rule, not a hidden one, and why it never fires for
        /// either field `scan` actually returns.
        pub fn addUnique(self: *Self, name: []const u8) void {
            if (self.contains(name)) return;
            if (self.len >= cap) return;
            self.names[self.len] = name;
            self.len += 1;
        }

        /// Test/literal convenience: a list holding exactly one name.
        pub fn one(name: []const u8) Self {
            var s: Self = .{};
            s.addUnique(name);
            return s;
        }
    };
}

/// Generous headroom for the number of DISTINCT Stimulus controller names
/// one template can name across every `data-controller="..."` attribute it
/// contains (each attribute itself can list several, space-separated).
/// Unlike `ComponentRoots` below, this is not tied to a comptime table, so
/// it is in principle reachable by a template with many distinct
/// controllers wired up -- 16 is chosen as comfortably beyond any real
/// Rails view this scanner has been run against. Reaching it does not
/// change classify.zig's Rule 6 verdict: that rule only asks whether the
/// list is non-empty, and the FIRST name found (real or, per `scan`'s doc,
/// the fallback name for a malformed attribute) always fits because the
/// list starts empty.
pub const max_stimulus_controllers: usize = 16;

pub const StimulusControllers = BoundedNames(max_stimulus_controllers);

/// One list slot per entry in `component_root_markers` -- never more,
/// because `scan` adds at most one name per TABLE ENTRY (not one per
/// occurrence in the source), so this capacity can never be exceeded and
/// `ComponentRoots.addUnique`'s truncation path is unreachable for this
/// field specifically.
pub const ComponentRoots = BoundedNames(component_root_markers.len);

/// Markers `scan` found in one template's raw text. `request_state`, when
/// set, names itself with the marker that matched (e.g. `"current_user"`)
/// -- see `scan`'s doc comment for where that string lives.
/// `stimulus_controllers` and `component_roots` are the NAMES the marker
/// text yielded (Stimulus controller identifiers off `data-controller`;
/// which component-mount technologies -- `react_component`,
/// `data-react-class`, `data-vue-component` -- appear at all), not just
/// whether either exists; classify.zig's Rule 6 asks whether either list
/// is non-empty, which is information-preserving relative to the bool/
/// single-optional shape this replaced.
pub const Markers = struct {
    request_state: ?[]const u8 = null,
    stimulus_controllers: StimulusControllers = .{},
    component_roots: ComponentRoots = .{},
    /// Fix round 2 (phase-1-review.md's challenge to Ruling 7 /
    /// phase-1-fixes.md section 4): set when `scanStimulusControllers` finds
    /// a `data-controller=` attribute it cannot parse a real name out of
    /// (missing/unterminated quotes, an empty value) -- see that function's
    /// doc for the exact shapes. The ORIGINAL rule for this case added the
    /// literal, malformed match text (`"data-controller="`) to
    /// `stimulus_controllers` itself, on the reasoning that every name in
    /// that list must be a slice of `src` and a static placeholder would
    /// break that invariant. Reversed: a non-name string is a PRESENT AND
    /// WRONG value in a list `templates[].stimulus_controllers[]` a
    /// consumer reads as "the identifiers of the Stimulus controllers wired
    /// to this template" -- exactly the failure shape this whole feature
    /// exists to refuse, and the drift gate / `--target` assembly reading
    /// this list are not human readers who can tell an odd string apart at
    /// a glance. This flag carries the SAME fact (rule 6's "was there any
    /// interactivity marker at all, even a malformed one") without adding a
    /// non-name to the list: `stimulus_controllers` stays all-`src`-slices
    /// (just possibly empty), and rule 6's verdict is unchanged -- see
    /// `classify.zig`'s Rule 6, which now ORs this flag in alongside the
    /// two list-length checks.
    malformed_stimulus_attr: bool = false,
};

/// Request-time-state markers, in return-priority order. `scan` walks THIS
/// table in order and returns the first entry that appears anywhere in the
/// source; where a marker sits in the source text is never compared, and is
/// used only to slice the matched name back out. So `current_user` wins over
/// `session` even when `session` appears first in the template -- the test
/// "table order wins over source order for request-state precedence" pins
/// exactly that, in both source orders.
///
/// Table order rather than source order because the point of returning a name
/// at all is that the evidence identifies the construct a caller should go
/// look for, rather than a generic "found something" flag; the most specific
/// and most actionable marker should therefore win regardless of where in the
/// file it happens to sit. That is also why the generic `current_` catch-all
/// is last (see its own comment below).
const request_state_markers = [_][]const u8{
    "current_user",
    "session",
    "flash",
    "cookies",
    "params",
    "signed_in?",
    "logged_in?",
    // Appended, not interleaved: fix round 1 (issue #166 stage 3) found a
    // template using `Current.user` (ActiveSupport::CurrentAttributes, the
    // standard request-scoped-state idiom in modern Rails) yielded no
    // marker at all -- the unsafe direction, since it let a per-user page
    // classify as `content` and get built as a static page. `Current.`
    // requires the trailing dot and capital C so it doesn't fire on any
    // word merely containing "current". `request.` covers the request
    // object used directly (`request.path`, `request.remote_ip`, ...).
    // Appending rather than inserting keeps every existing precedence
    // relationship (e.g. `current_user` still beats `session`) unchanged.
    "Current.",
    "request.",
    // Fix round 2 (issue #166 stage 3): three more executed-and-confirmed
    // gaps, all in the unsafe direction (no marker -> `content` -> a
    // static page built for a page that isn't). `current_account` and
    // `current_organization` are the same multi-tenant `current_*`
    // convention as `current_user`, listed by name so common helpers still
    // report themselves precisely. `csrf_meta_tags` and
    // `form_authenticity_token` emit Rails' per-session CSRF token --
    // caching that into a static page ships a stale token, so every form
    // POST from that page fails at runtime. `policy(` (Pundit) and `can?`
    // (CanCanCan) gate markup on the current user's authorization.
    "current_account",
    "current_organization",
    "csrf_meta_tags",
    "form_authenticity_token",
    "policy(",
    "can?",
    // Generic catch-all, deliberately LAST: every specific `current_*`
    // entry above sorts before it, so a common name still reports itself
    // precisely (`current_user`, `current_account`, ...) and only an
    // unanticipated helper (`current_tenant`, `current_site`,
    // `@current_workspace`) falls back to this generic evidence string.
    // Placed earlier, every `current_user` page would report the less
    // useful `current_` instead, throwing away evidence quality for
    // nothing.
    "current_",
};

/// A component-root marker's search text (`needle`) and the name `scan`
/// reports when it matches (`name`). `name` is always a prefix of
/// `needle` (often the whole thing) so that the returned slice -- taken
/// as `src[idx .. idx + name.len]` starting where `needle` matched -- is
/// itself literal text of `src`, not a copy of `name`.
const ComponentRootMarker = struct {
    needle: []const u8,
    name: []const u8,
};

const component_root_markers = [_]ComponentRootMarker{
    .{ .needle = "react_component(", .name = "react_component" },
    .{ .needle = "data-react-class", .name = "data-react-class" },
    .{ .needle = "data-vue-component", .name = "data-vue-component" },
};

/// Contract 3 (caller-buffer): `scan` allocates nothing. `request_state`
/// and every name in `stimulus_controllers`/`component_roots` are slices
/// *into `src`* -- never a stack temporary, never a static buffer this
/// function fills -- so a `Markers` value is only valid as long as `src`
/// stays alive, exactly like any other borrow of it. `stimulus_controllers`
/// and `component_roots` are themselves inline, fixed-capacity storage
/// (`BoundedNames`, above) rather than a `[]const` slice from an
/// allocation, so a `Markers` value can be copied and returned by value
/// with no `deinit` -- see `BoundedNames`'s doc for the truncation rule
/// that keeps this allocation-free even though it now returns lists.
///
/// This is a substring scan, not an ERB parse, and deliberately so: it
/// does not strip `<%# ... %>` comments or string literals before
/// matching. The classifier this feeds treats a marker as evidence a page
/// needs request-time state or a JS mount point; MISSING one routes the
/// page to `content`, and the migration then builds a static page for a
/// page that isn't static -- a silent break a site visitor finds, not a
/// build failure a human sees. A SPURIOUS match (e.g. a marker mentioned
/// inside a comment, as in this file's test suite) only routes the page
/// to `unresolved`, which costs a human one look at a diff. Over-detection
/// is the cheap, safe failure mode, so this scanner never tries to be
/// smarter than `std.mem.indexOf`.
///
/// A bare `<div id="app">` or `<div id="root">` is deliberately NOT
/// component-root evidence, even though it's the idiomatic React/Vue
/// mount point: every Rails layout ships one whether or not anything ever
/// mounts into it, so treating it as a marker would classify most of an
/// application as islands on no real evidence.
pub fn scan(src: []const u8) Markers {
    var markers: Markers = .{};

    for (request_state_markers) |marker| {
        if (std.mem.indexOf(u8, src, marker)) |idx| {
            markers.request_state = src[idx .. idx + marker.len];
            break;
        }
    }

    scanStimulusControllers(src, &markers.stimulus_controllers, &markers.malformed_stimulus_attr);

    // Unlike the request-state table above, every entry here is checked --
    // no `break` -- because the manifest wants to know EVERY component
    // technology a template mounts (a page could use `react_component` and
    // `data-vue-component` together), not just the first table entry that
    // happens to match. This can add at most `component_root_markers.len`
    // names (one per table entry, deduplicated by construction since each
    // entry contributes a distinct `name`), which is exactly `ComponentRoots`'
    // capacity -- see that type's doc.
    for (component_root_markers) |marker| {
        if (std.mem.indexOf(u8, src, marker.needle) != null) {
            markers.component_roots.addUnique(marker.name);
        }
    }

    return markers;
}

/// Finds every `data-controller="..."` (or `'...'`) attribute in `src` and
/// adds each space-separated name in its value to `out` (Stimulus allows
/// wiring several controllers to one element, e.g.
/// `data-controller="reveal modal"` -- two names, not one).
///
/// Safety property this preserves: the OLD `stimulus: bool` was
/// `indexOf(src, "data-controller=") != null`, i.e. true on ANY occurrence
/// regardless of what followed. classify.zig's Rule 6 must not change
/// verdict on any input (see this file's module doc / the brief this
/// implements), so this function guarantees EITHER `out.len > 0` OR
/// `malformed.* = true` after scanning whenever that substring appears
/// anywhere in `src` -- including when the attribute value is missing its
/// closing quote, unquoted, or empty. In the well-formed case that
/// guarantee is met by the real controller names; in a malformed case
/// (fix round 2, phase-1-review.md's challenge to Ruling 7) it sets
/// `malformed.*` instead of adding a non-name string to `out` -- see
/// `Markers.malformed_stimulus_attr`'s doc for why a fabricated "name" in
/// this list is worse than a separate flag. `malformed.*` is OR-accumulated
/// (never cleared back to `false`) so multiple calls across one scan (this
/// function only ever sees one call per `scan`, but the flag itself is also
/// unioned across a whole route's template chain by `rails.zig`'s
/// `transitiveScan` the same way `stimulus_controllers`/`component_roots`
/// are) never lose an earlier true.
fn scanStimulusControllers(src: []const u8, out: *StimulusControllers, malformed: *bool) void {
    const needle = "data-controller=";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, needle)) |idx| {
        const after_eq = idx + needle.len;
        i = after_eq;
        var found_name = false;

        if (after_eq < src.len and (src[after_eq] == '"' or src[after_eq] == '\'')) {
            const quote = src[after_eq];
            if (std.mem.indexOfScalarPos(u8, src, after_eq + 1, quote)) |close| {
                const value = src[after_eq + 1 .. close];
                var it = std.mem.tokenizeAny(u8, value, " \t\r\n");
                while (it.next()) |name| {
                    out.addUnique(name);
                    found_name = true;
                }
                i = close + 1;
            }
        }

        if (!found_name) {
            // Malformed or empty attribute value: record that this
            // occurrence existed WITHOUT adding a non-name to `out` -- see
            // `Markers.malformed_stimulus_attr`'s doc.
            malformed.* = true;
        }
    }
}

/// One `render` call `scanRenders` found in a template's raw text, naming
/// what it renders. When `resolved` is `true`, `text` is the literal
/// partial-name argument exactly as written in the source (e.g. `"post"`,
/// `"shared/nav"`) -- turning that into a template PATH by Rails' partial
/// resolution convention is `rails.zig`'s job (this module has no inventory
/// to resolve against, and stays std-only/pure by design). When `resolved`
/// is `false`, `text` is a bounded slice of raw source around the call,
/// kept as evidence for a human (or a blocker) to read: the target could
/// not be determined from source text alone (a dynamic expression like
/// `render @post`, or `render partial: some_var`).
pub const RenderTarget = struct {
    text: []const u8,
    resolved: bool,
};

const max_render_evidence_len: usize = 48;

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn boundedEvidence(rest: []const u8) []const u8 {
    // Stop at the enclosing ERB tag's close, if it's within the window, so
    // the evidence reads as "the render call" rather than trailing off into
    // "%>" or whatever markup follows it.
    var n: usize = @min(max_render_evidence_len, rest.len);
    if (std.mem.indexOf(u8, rest[0..n], "%>")) |tag_close| n = tag_close;
    return std.mem.trimEnd(u8, rest[0..n], " \t\r\n");
}

/// Contract 1 (self-freeing): the returned `[]RenderTarget` is the ONE
/// allocation that escapes; every `.text` slice borrows `src` exactly like
/// `scan`'s `Markers` does (same lifetime rule: valid only as long as `src`
/// is), so releasing the returned slice with a plain `gpa.free` is enough --
/// no per-element cleanup, because nothing per-element was allocated.
///
/// A text scan, not a Ruby parse -- see `scan`'s doc for the over-detection-
/// is-safe rationale this shares: misreading a render call as "resolved"
/// when it is not would be the UNSAFE direction here (a page with unscanned
/// content could still reach `content`), so the shapes this recognizes are
/// deliberately narrow and literal, in match-priority order:
///
///   - `render partial: "x"` / `render(partial: 'x')` -- literal; the
///     target is the quoted string.
///   - `render partial: <anything else>` (a local, an ivar, ...) --
///     dynamic; the target cannot be read from source text.
///   - `render "x"` / `render('x')` -- Rails' bare-string shorthand for a
///     partial when written INSIDE a template (there is no controller
///     context here to make it mean an action template instead, unlike the
///     same shorthand in a controller method) -- literal.
///   - `render @x` -- the "render this object" shorthand, which resolves to
///     a partial named after the object's class at runtime -- dynamic,
///     because that class is not knowable from source text.
///
/// Anything else following `render` (`render json: ...`, `render layout:
/// false`, `render status: 404`, `render plain: "..."`, a call this
/// scanner's narrow shapes don't recognize, ...) is NOT reported as a
/// render target at all -- these are real Rails idioms with nothing to do
/// with partial content, and misreading them as an unresolved partial would
/// flood unrelated routes with false `unresolved` verdicts. `rails.zig`'s
/// caller only cares about a `render` call that references PARTIAL content,
/// which is the only thing this scanner's evidence bundle affects.
pub fn scanRenders(gpa: Allocator, src: []const u8) Allocator.Error![]RenderTarget {
    var out: std.ArrayListUnmanaged(RenderTarget) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, "render")) |call_start| {
        i = call_start + "render".len;
        // Word-boundary guard on both sides: neither "prerendered" nor
        // "render_to_string"/"renderer" is a bare `render` call.
        if (call_start > 0 and isIdentChar(src[call_start - 1])) continue;
        if (i < src.len and isIdentChar(src[i])) continue;

        var rest = std.mem.trimStart(u8, src[i..], " \t\r\n");
        if (rest.len > 0 and rest[0] == '(') rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");

        if (std.mem.startsWith(u8, rest, "partial:")) {
            const after = std.mem.trimStart(u8, rest["partial:".len..], " \t\r\n");
            if (after.len > 0 and (after[0] == '"' or after[0] == '\'')) {
                const quote = after[0];
                if (std.mem.indexOfScalar(u8, after[1..], quote)) |end| {
                    try out.append(gpa, .{ .text = after[1 .. 1 + end], .resolved = true });
                    continue;
                }
            }
            try out.append(gpa, .{ .text = boundedEvidence(rest), .resolved = false });
            continue;
        }

        if (rest.len > 0 and (rest[0] == '"' or rest[0] == '\'')) {
            const quote = rest[0];
            if (std.mem.indexOfScalar(u8, rest[1..], quote)) |end| {
                try out.append(gpa, .{ .text = rest[1 .. 1 + end], .resolved = true });
            }
            continue;
        }

        if (rest.len > 0 and rest[0] == '@') {
            try out.append(gpa, .{ .text = boundedEvidence(rest), .resolved = false });
            continue;
        }
        // Not a shape this scanner understands as a partial reference --
        // deliberately not reported (see doc comment above).
    }

    return out.toOwnedSlice(gpa);
}

test "request-time state markers are detected, and name themselves" {
    try std.testing.expect(scan("<p><%= current_user.name %></p>").request_state != null);
    try std.testing.expectEqualStrings("current_user", scan("<%= current_user %>").request_state.?);
    try std.testing.expectEqualStrings("session", scan("<% session[:x] %>").request_state.?);
    try std.testing.expectEqualStrings("flash", scan("<%= flash[:notice] %>").request_state.?);
    try std.testing.expectEqualStrings("cookies", scan("<% cookies[:a] %>").request_state.?);
    try std.testing.expectEqualStrings("params", scan("<%= params[:id] %>").request_state.?);
}

test "ActiveSupport::CurrentAttributes and the request object are request-state markers" {
    // Fix round 1: `Current.user` and `request.path` are the standard
    // request-scoped-state idioms this table originally missed. A miss
    // here means a per-user page classifies as `content` and the migration
    // builds a static page for it -- the exact failure this scanner exists
    // to prevent, so this is pinned directly rather than folded into the
    // first table-driven test above.
    try std.testing.expectEqualStrings("Current.", scan("<%= Current.user %>").request_state.?);
    try std.testing.expectEqualStrings("request.", scan("<%= request.path %>").request_state.?);
}

test "CSRF, app-specific current_* helpers, and authorization gates are request-state markers" {
    // Fix round 2: three more executed-and-confirmed gaps, all in the
    // unsafe direction. Each assertion below is the literal evidence
    // string the classifier will see for that idiom.
    try std.testing.expectEqualStrings("current_account", scan("<%= current_account.name %>").request_state.?);
    try std.testing.expectEqualStrings("current_organization", scan("<%= current_organization.name %>").request_state.?);
    try std.testing.expectEqualStrings("csrf_meta_tags", scan("<%= csrf_meta_tags %>").request_state.?);
    try std.testing.expectEqualStrings("form_authenticity_token", scan("<%= form_authenticity_token %>").request_state.?);
    try std.testing.expectEqualStrings("policy(", scan("<% if policy(@post).edit? %>").request_state.?);
    try std.testing.expectEqualStrings("can?", scan("<% if can? :edit, @post %>").request_state.?);
    // An unanticipated `current_*` helper falls back to the generic
    // catch-all, listed last so it never shadows a specific entry above.
    try std.testing.expectEqualStrings("current_", scan("<%= current_tenant.name %>").request_state.?);
}

test "the underscore and the paren are load-bearing, not incidental" {
    // Proves `current_` and `policy(` don't fire on the bare English words
    // "current" and "policy" -- only on the Ruby-identifier shapes.
    try std.testing.expect(scan("<p>Our current policy is simple.</p>").request_state == null);
    // `can?` is short and deliberately not word-bounded: it matches inside
    // ordinary English ("You can? Really?") too. This is the over-detection
    // the scanner is biased toward by design (see `scan`'s doc comment) --
    // reported here, not dodged by narrowing the marker.
    try std.testing.expect(scan("<p>You can? Really?</p>").request_state != null);
}

test "table order wins over source order for request-state precedence" {
    // `current_user` must win over `session` by TABLE order regardless of
    // which one appears first in the source. Asserting only one source
    // order is also satisfied by a different, wrong rule -- "first match
    // in the source" -- which happens to agree with table order on
    // whichever single input is checked. Asserting both orders is what
    // actually distinguishes "table order" from "source order".
    try std.testing.expectEqualStrings(
        "current_user",
        scan("<% session[:x] %><%= current_user %>").request_state.?,
    );
    try std.testing.expectEqualStrings(
        "current_user",
        scan("<%= current_user %><% session[:x] %>").request_state.?,
    );
}

test "a static template has no markers" {
    // `scan` never looks INSIDE the rendered partial's own file -- it is a
    // single-buffer scanner by design (see this file's module doc). That is
    // NOT the same claim as "a view that renders a partial is clean": the
    // partial's body is unscanned evidence, and `rails.zig`'s transitive
    // walk (view + layout + `render`ed partials, via `scanRenders` below) is
    // what actually closes that gap by scanning the partial's file too and
    // merging its markers in. This test only pins `scan`'s own single-file
    // scope, not the whole classification story.
    const m = scan("<h1>Posts</h1>\n<%= render partial: \"post\" %>\n");
    try std.testing.expect(m.request_state == null);
    try std.testing.expectEqual(@as(usize, 0), m.stimulus_controllers.len);
    try std.testing.expectEqual(@as(usize, 0), m.component_roots.len);
    try std.testing.expect(!m.malformed_stimulus_attr);
}

test "over-detection is deliberate: a marker in a comment still counts" {
    // Rule 5 routes to `unresolved`, which costs a human a look. Missing a
    // marker routes to `content`, which builds a static page for a page that
    // is not static. The false positive is the safe direction.
    try std.testing.expect(scan("<%# current_user is not used here %>").request_state != null);
}

test "stimulus and component roots are distinguished" {
    const stimulus = scan("<div data-controller=\"reveal\"></div>");
    try std.testing.expectEqual(@as(usize, 1), stimulus.stimulus_controllers.len);
    try std.testing.expectEqualStrings("reveal", stimulus.stimulus_controllers.slice()[0]);

    try std.testing.expectEqual(@as(usize, 1), scan("<%= react_component(\"Chart\") %>").component_roots.len);
    try std.testing.expectEqualStrings(
        "react_component",
        scan("<%= react_component(\"Chart\") %>").component_roots.slice()[0],
    );
    try std.testing.expectEqual(@as(usize, 1), scan("<div data-react-class=\"Chart\"></div>").component_roots.len);
    try std.testing.expectEqualStrings(
        "data-react-class",
        scan("<div data-react-class=\"Chart\"></div>").component_roots.slice()[0],
    );
    // A bare mount div is NOT evidence -- every app has a <div id="app">.
    try std.testing.expectEqual(@as(usize, 0), scan("<div id=\"app\"></div>").component_roots.len);
}

test "data-controller with several space-separated names yields one name per controller" {
    // The brief's discriminator: a single-controller test passes against an
    // implementation that never splits the attribute value. `data-controller=
    // "reveal modal"` is ONE attribute naming TWO Stimulus controllers, and
    // `stimulus_controllers` must contain both names -- not the raw
    // "reveal modal" string, and not just "reveal".
    const m = scan("<div data-controller=\"reveal modal\"></div>");
    try std.testing.expectEqual(@as(usize, 2), m.stimulus_controllers.len);
    try std.testing.expectEqualStrings("reveal", m.stimulus_controllers.slice()[0]);
    try std.testing.expectEqualStrings("modal", m.stimulus_controllers.slice()[1]);
    // Neither the whole attribute value nor a comma-joined form is present.
    try std.testing.expect(!m.stimulus_controllers.contains("reveal modal"));
}

test "data-controller names are deduplicated across repeated attributes" {
    const m = scan(
        "<div data-controller=\"reveal\"></div><div data-controller=\"reveal modal\"></div>",
    );
    try std.testing.expectEqual(@as(usize, 2), m.stimulus_controllers.len);
    try std.testing.expect(m.stimulus_controllers.contains("reveal"));
    try std.testing.expect(m.stimulus_controllers.contains("modal"));
}

test "a template using both react_component and data-vue-component reports both roots" {
    const m = scan("<%= react_component(\"Chart\") %><div data-vue-component=\"Widget\"></div>");
    try std.testing.expectEqual(@as(usize, 2), m.component_roots.len);
    try std.testing.expect(m.component_roots.contains("react_component"));
    try std.testing.expect(m.component_roots.contains("data-vue-component"));
}

test "a malformed data-controller attribute sets malformed_stimulus_attr, WITHOUT adding a non-name to the list (Rule 6 safety, fix round 2)" {
    // Preserves the OLD bool's over-detection guarantee -- `indexOf(src,
    // "data-controller=") != null` was true here too -- via the SEPARATE
    // `malformed_stimulus_attr` flag rather than a fabricated list entry
    // (fix round 2, phase-1-review.md's challenge to Ruling 7). Missing the
    // flag in the safe direction would flip Rule 6's verdict from island to
    // something else on an input the old scanner correctly flagged; adding
    // a non-name string to `stimulus_controllers` would publish
    // "data-controller=" as though it were a real Stimulus identifier.
    const unquoted = scan("<div data-controller=reveal></div>");
    try std.testing.expectEqual(@as(usize, 0), unquoted.stimulus_controllers.len);
    try std.testing.expect(unquoted.malformed_stimulus_attr);

    const unterminated = scan("<div data-controller=\"reveal");
    try std.testing.expectEqual(@as(usize, 0), unterminated.stimulus_controllers.len);
    try std.testing.expect(unterminated.malformed_stimulus_attr);

    const empty_value = scan("<div data-controller=\"\"></div>");
    try std.testing.expectEqual(@as(usize, 0), empty_value.stimulus_controllers.len);
    try std.testing.expect(empty_value.malformed_stimulus_attr);

    // The well-formed sibling tests above this one still see the flag
    // false -- a real, parsed name never sets it.
    try std.testing.expect(!scan("<div data-controller=\"reveal\"></div>").malformed_stimulus_attr);
}

fn expectTargets(src: []const u8, want: []const RenderTarget) !void {
    const gpa = std.testing.allocator;
    const got = try scanRenders(gpa, src);
    defer gpa.free(got);
    try std.testing.expectEqual(want.len, got.len);
    for (got, want) |g, w| {
        try std.testing.expectEqualStrings(w.text, g.text);
        try std.testing.expectEqual(w.resolved, g.resolved);
    }
}

test "scanRenders resolves render partial: \"x\" to a literal target" {
    try expectTargets(
        "<%= render partial: \"post\", collection: @posts %>",
        &.{.{ .text = "post", .resolved = true }},
    );
}

test "scanRenders resolves the bare-string partial shorthand" {
    try expectTargets(
        "<%= render \"shared/nav\" %>",
        &.{.{ .text = "shared/nav", .resolved = true }},
    );
}

test "scanRenders treats render partial: <var> as unresolvable" {
    const got = try scanRenders(std.testing.allocator, "<%= render partial: some_var %>");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(!got[0].resolved);
    try std.testing.expect(std.mem.indexOf(u8, got[0].text, "partial: some_var") != null);
}

test "scanRenders treats render @x as unresolvable (implicit object-to-partial)" {
    const got = try scanRenders(std.testing.allocator, "<%= render @post %>");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(!got[0].resolved);
    try std.testing.expect(std.mem.indexOf(u8, got[0].text, "@post") != null);
}

test "scanRenders ignores render calls that are not partial references" {
    // `render json:`/`layout:`/`status:`/`plain:` have nothing to do with
    // partial content -- see the doc comment's rationale for why flagging
    // these would be the WRONG direction of over-detection (it would flood
    // unrelated routes with a false "unresolved include" rather than
    // costing a human one accurate look).
    try expectTargets("<% render json: { ok: true } %>", &.{});
    try expectTargets("<% render layout: false do %><% end %>", &.{});
    try expectTargets("<% render status: 404 %>", &.{});
    // Word-boundary guards: neither of these is a bare `render` call.
    try expectTargets("<%= prerendered_html %>", &.{});
    try expectTargets("<%= render_to_string(partial: \"x\") %>", &.{});
}

test "scanRenders finds every render call in a template, in source order" {
    try expectTargets(
        "<%= render partial: \"header\" %><%= render \"shared/nav\" %><%= render @post %>",
        &.{
            .{ .text = "header", .resolved = true },
            .{ .text = "shared/nav", .resolved = true },
            .{ .text = "@post", .resolved = false },
        },
    );
}

test "scanRenders: parenthesized calls are recognized the same as bare ones" {
    try expectTargets(
        "<%= render(partial: \"post\") %>",
        &.{.{ .text = "post", .resolved = true }},
    );
    try expectTargets(
        "<%= render('shared/nav') %>",
        &.{.{ .text = "shared/nav", .resolved = true }},
    );
}

test "scanRenders: a template with no render calls returns an empty slice" {
    try expectTargets("<h1>Static</h1>", &.{});
}
