//! The operator's answers to `findings.zig`'s questions: reading and
//! validating `MIGRATION.decisions.json`. std-only, see the note in
//! detect.zig; every failure is an error return plus a list of `Problem`s,
//! never a `fatal.*` call, because `migrate.zig` owns the exit path.
//!
//! **Why validation lives here and not in the caller.** A decisions file is
//! hand-written: the ids are long (`<code>.<path>.<loc>`, see
//! `findings.findingId`), the legal choices differ per finding, and the
//! whole point of the decide-then-re-run loop is that the operator edits
//! this file between runs. A typo in it must produce a message naming the
//! offending entry -- not a silently ignored key that records an answer
//! nobody gave. That is why `parse` opts into `ignore_unknown_fields =
//! false` and then does a second pass over the raw `std.json.Value` to name
//! the key: std's `error.UnknownField` says only THAT a key was unknown, and
//! "somewhere in your file there is a typo" is not a usable message.
//!
//! **Every offending entry is reported, not just the first.** `parse` walks
//! the whole list accumulating `problems` and only then returns `Invalid`.
//! An operator who has to re-run the migration once per complaint is the
//! failure mode this avoids; the id/index in each `Problem` is what lets the
//! caller print them all at once.
//!
//! **An id matching no finding is NOT an error.** The plan's interface
//! sketch said both "unknown `id` -> Invalid" and "a decision whose id
//! matches no finding in THIS run is not an error ... reported under
//! `stale`"; the second is the reconciled behaviour, and the reason is the
//! loop itself. Finding ids are derived from the template's own text and
//! location, so FIXING the template the operator was asked about (deleting
//! the helper call, resolving the i18n key) is exactly what makes their
//! recorded answer's id disappear. Failing the run there would punish the
//! remedy. The caller instead appends one `RAILS_DECISION_STALE` blocker
//! (integrity false, warn) per `stale` entry, so the answer can be pruned
//! from the file deliberately.
//!
//! Ownership: `Decision` fields are all fresh `gpa` allocations (nothing
//! borrows the wire bytes or the transient parse arena, both of which are
//! gone before `parse` returns), released by `free`. `Problem.message` and
//! `Problem.id` are likewise owned, released by `freeProblems`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const findings = @import("findings.zig");

/// The wire `schema` marker. Bumped only alongside an incompatible change to
/// the shape below; a file carrying anything else is `WrongSchema` rather
/// than a best-effort parse, because guessing at an unknown vintage's
/// meaning is how a wrong answer gets recorded as a right one.
pub const schema_id = "zigapagos.rails-decisions/1";

/// One operator answer. All four fields are owned (see the module doc).
pub const Decision = struct {
    /// The `findings.Finding.id` this answers.
    id: []const u8,
    /// One of that finding's `choices`. Validated for a live finding;
    /// carried verbatim for a `stale` one, which has no `choices` left to
    /// check against.
    choice: []const u8,
    /// Why. Required and non-blank: the file outlives the run and is read by
    /// the next person to touch the migration, so an unexplained `blocked`
    /// is a decision nobody can revisit.
    rationale: []const u8,
    /// The artifact the choice produces (e.g. an island component path),
    /// when the finding's `requires_artifact` demands one. `null` when
    /// absent; an empty string is normalised to `null` by `parse` so
    /// `"artifact": ""` cannot satisfy the requirement.
    artifact: ?[]const u8,
};

/// Contract 2 (owned-result): released by `free`.
pub const Parsed = struct {
    /// Answers whose `id` matches a finding in THIS run, in file order.
    decisions: []Decision,
    /// Answers whose `id` matches nothing in this run. Not an error; see the
    /// module doc.
    stale: []Decision,

    /// A run with no decisions file. Both slices are empty rather than null
    /// so `free` has one code path, and so every consumer's "did the operator
    /// answer this?" question is a lookup that finds nothing rather than a
    /// null check it could forget.
    pub const empty: Parsed = .{ .decisions = &.{}, .stale = &.{} };
};

/// One complaint about one entry, addressed to the operator.
pub const Problem = struct {
    /// 0-based position in the file's `decisions` array. `0` for a
    /// whole-file problem (bad JSON, wrong schema, unknown top-level key),
    /// which `message` distinguishes -- those carry `id == null` too.
    index: usize,
    /// The offending entry's `id` when it had a usable one. Owned: the
    /// transient parse arena the id was read from is released before `parse`
    /// returns, so borrowing it would dangle.
    id: ?[]const u8,
    /// Owned, human-readable, and always specific enough to edit the file
    /// from: it names the id, and for a rejected choice it lists the ones
    /// the finding actually allows.
    message: []const u8,
};

pub const ParseError = error{
    /// The bytes are not JSON, or not the shape this schema requires.
    InvalidJson,
    /// Valid JSON, but not `schema_id` (or carrying no `schema` at all).
    WrongSchema,
    /// Well-formed and correctly versioned, but at least one entry is not a
    /// usable answer. Every offender is in `problems`.
    Invalid,
} || Allocator.Error;

/// The file shape, exactly. `schema` defaults so that an absent marker is
/// reported as `WrongSchema` (a precise complaint) rather than std's
/// `error.MissingField` (which cannot say WHICH field). `decisions` gets no
/// default for the mirror-image reason: it is then the only field whose
/// absence can raise `MissingField`, which makes that error's mapping to a
/// message naming `decisions` exact rather than a guess. An empty
/// `decisions` array is legal -- that is a run with no answers yet, not a
/// malformed file.
const WireFile = struct {
    schema: []const u8 = "",
    decisions: []const WireDecision,
};

/// Every field defaults so that a missing one lands in this module's own
/// validation (which can name the entry's index and id) instead of std's
/// field-blind `error.MissingField`. `ignore_unknown_fields = false` still
/// catches the case a default would otherwise hide: a MISSPELLED key, which
/// would silently leave the real field at its default.
const WireDecision = struct {
    id: []const u8 = "",
    choice: []const u8 = "",
    rationale: []const u8 = "",
    artifact: ?[]const u8 = null,
};

const top_level_keys = [_][]const u8{ "schema", "decisions" };
const decision_keys = [_][]const u8{ "id", "choice", "rationale", "artifact" };

/// Contract 2 (owned-result): parses `bytes`, validates every entry against
/// `findings`, and returns a `Parsed` whose two slices and every string in
/// them are fresh `gpa` allocations released by `free`. `problems` is
/// caller-owned and caller-freed (`freeProblems`) on EVERY path, including
/// the error ones -- that is the point of it: the caller needs the list
/// after the error to render the message.
///
/// Rejections, all of which accumulate rather than short-circuit: a blank
/// `id`; a duplicate `id` (the second and later occurrences are the
/// offenders -- the first is a good answer, and blaming it would send the
/// operator to the wrong line); a blank `rationale`; a `choice` outside the
/// finding's `choices`; a finding with `requires_artifact` answered without
/// one. An id matching no finding is `stale`, not a rejection.
///
/// `auth_collections` is `backend.Document.auth_collections` (empty for a
/// run with no `--backend`), and is read by exactly one rule -- see
/// `unknownAuthCollection`. It is a bare string list rather than the
/// document itself so this file keeps its one import.
pub fn parse(
    gpa: Allocator,
    bytes: []const u8,
    finding_list: []const findings.Finding,
    auth_collections: []const []const u8,
    problems: *std.ArrayListUnmanaged(Problem),
) ParseError!Parsed {
    // Two-stage on purpose: the `Value` tree from stage one is what stage
    // two's `error.UnknownField` gets interrogated against to name the bad
    // key. Parsing straight from the slice would leave nothing to inspect.
    var doc = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try addProblem(gpa, problems, 0, null, "not valid JSON ({s})", .{@errorName(err)});
            return error.InvalidJson;
        },
    };
    defer doc.deinit();

    var typed = std.json.parseFromValue(WireFile, gpa, doc.value, .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownField => {
            if (findUnknownKey(doc.value)) |u| {
                try addProblem(gpa, problems, u.index, null, "unrecognized key \"{s}\"{s}", .{
                    u.key,
                    if (u.in_decision) " in a decision entry; expected id/choice/rationale/artifact" else " at the top level; expected schema/decisions",
                });
            } else {
                // Unreachable in practice (stage two only rejects keys stage
                // one preserved), but a wrong guess must not become a wrong
                // message: say only what is certainly true.
                try addProblem(gpa, problems, 0, null, "the file contains a key this schema does not define", .{});
            }
            return error.Invalid;
        },
        error.MissingField => {
            try addProblem(gpa, problems, 0, null, "missing the required `decisions` array", .{});
            return error.InvalidJson;
        },
        else => {
            try addProblem(gpa, problems, 0, null, "not the shape `{s}` requires ({s})", .{ schema_id, @errorName(err) });
            return error.InvalidJson;
        },
    };
    defer typed.deinit();

    if (!std.mem.eql(u8, typed.value.schema, schema_id)) {
        try addProblem(gpa, problems, 0, null, "schema is \"{s}\", expected \"{s}\"", .{ typed.value.schema, schema_id });
        return error.WrongSchema;
    }

    const wire = typed.value.decisions;

    var live: std.ArrayListUnmanaged(Decision) = .empty;
    errdefer {
        freeItems(gpa, live.items);
        live.deinit(gpa);
    }
    var stale: std.ArrayListUnmanaged(Decision) = .empty;
    errdefer {
        freeItems(gpa, stale.items);
        stale.deinit(gpa);
    }

    var any_invalid = false;
    for (wire, 0..) |w, i| {
        if (std.mem.trim(u8, w.id, " \t\r\n").len == 0) {
            try addProblem(gpa, problems, i, null, "entry {d} has no `id`; it must name the finding it answers", .{i});
            any_invalid = true;
            continue;
        }

        // Linear rather than a hash set: this list is one operator's
        // hand-written answers (tens of entries), so the set would cost an
        // allocation and a failure path to save nothing measurable.
        var duplicate = false;
        for (wire[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, w.id)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try addProblem(gpa, problems, i, w.id, "duplicate decision for id \"{s}\"; each finding may be answered once", .{w.id});
            any_invalid = true;
            continue;
        }

        // Every remaining check runs even after an earlier one failed, so a
        // single entry with two faults reports both.
        var entry_ok = true;
        if (std.mem.trim(u8, w.rationale, " \t\r\n").len == 0) {
            try addProblem(gpa, problems, i, w.id, "decision \"{s}\" has an empty `rationale`; say why, the next reader cannot ask", .{w.id});
            entry_ok = false;
        }

        const finding = findById(finding_list, w.id);
        if (finding) |f| {
            const is_backend = std.mem.eql(u8, f.code, findings.code_backend_endpoint);
            if (!containsString(f.choices, w.choice)) {
                // #167 Stage 3 ruling A3. The spec lists `custom:<path>`
                // among a `RAILS_BACKEND_ENDPOINT` finding's answers, and a
                // free-form token cannot sit in a fixed `choices[]` -- the
                // manifest would have to enumerate every URL the operator
                // might invent. So `choices[]` stays the document's
                // operations plus `retain`/`blocked`, and the SHAPE is
                // validated here instead; the finding's own message spells
                // it out so the file is still self-describing.
                //
                // The `custom:` PREFIX is what routes an entry to this arm:
                // a plain misspelling still gets the ordinary "not offered;
                // allowed: ..." message, which is the more useful one when
                // the operator meant an operation id.
                if (is_backend and std.mem.startsWith(u8, w.choice, custom_prefix)) {
                    if (!validCustomChoice(w.choice)) {
                        try addProblem(gpa, problems, i, w.id, "choice \"{s}\" must be custom:/<absolute path> with no whitespace or quotes", .{w.choice});
                        entry_ok = false;
                    }
                } else {
                    const allowed = try joinChoices(gpa, f.choices);
                    defer gpa.free(allowed);
                    try addProblem(gpa, problems, i, w.id, "choice \"{s}\" is not offered for \"{s}\"; allowed: {s}", .{ w.choice, w.id, allowed });
                    entry_ok = false;
                }
            }
            const artifact = normalizeArtifact(w.artifact);
            // #167 Stage 3 ruling A4. `requires_artifact` says the choice
            // that RESOLVES this finding produces something; `retain` and
            // `blocked` produce nothing, and demanding an artifact path for
            // a decision to write no files was the Stage 2 rule written when
            // no finding set the flag at all.
            if (f.requires_artifact and artifact == null and !isNoopChoice(w.choice)) {
                try addProblem(gpa, problems, i, w.id, "finding \"{s}\" requires an `artifact` path alongside the choice", .{w.id});
                entry_ok = false;
            }
            // #167 Stage 3. The `RAILS_AUTH_JOURNEY` artifact is a ZigBase
            // auth collection NAME, and a name that is not one produces an
            // `AuthForm` calling `zb.collection("members").authWithPassword`
            // against a collection that cannot authenticate -- a migration
            // that builds, ships, and fails at the first sign-in. When
            // `--backend` gave us the list, check it. Without a document
            // there is nothing to check against, and refusing every name
            // would make the flag unanswerable without one.
            if (artifact) |a| {
                if (unknownAuthCollection(f, w.choice, a, auth_collections)) {
                    const known = try joinChoices(gpa, auth_collections);
                    defer gpa.free(known);
                    try addProblem(gpa, problems, i, w.id, "artifact \"{s}\" is not an auth collection in the backend document; auth collections: {s}", .{ a, known });
                    entry_ok = false;
                }
            }
        }

        if (!entry_ok) {
            any_invalid = true;
            continue;
        }

        const owned = try dupDecision(gpa, w);
        errdefer freeOne(gpa, owned);
        // A stale entry is still held to the id/duplicate/rationale rules
        // above: it is an operator answer that may well be revived by an
        // edit, so it should be well-formed even while it applies to
        // nothing.
        const target: *std.ArrayListUnmanaged(Decision) = if (finding == null) &stale else &live;
        try target.append(gpa, owned);
    }

    if (any_invalid) return error.Invalid;

    const live_slice = try live.toOwnedSlice(gpa);
    errdefer {
        freeItems(gpa, live_slice);
        gpa.free(live_slice);
    }
    const stale_slice = try stale.toOwnedSlice(gpa);
    return .{ .decisions = live_slice, .stale = stale_slice };
}

/// Contract 3 (caller-buffer): allocates nothing and returns a borrowed
/// view into `parsed`. Only live decisions are searched -- a `stale` answer
/// belongs to a finding that no longer exists, so returning it would let it
/// resolve some other run's question.
pub fn lookup(parsed: Parsed, finding_id: []const u8) ?Decision {
    for (parsed.decisions) |d| {
        if (std.mem.eql(u8, d.id, finding_id)) return d;
    }
    return null;
}

/// Contract 2 counterpart to `parse`: releases every string in both slices
/// and the slices themselves.
pub fn free(gpa: Allocator, parsed: Parsed) void {
    freeItems(gpa, parsed.decisions);
    gpa.free(parsed.decisions);
    freeItems(gpa, parsed.stale);
    gpa.free(parsed.stale);
}

/// Contract 2 counterpart to the `problems` list `parse` fills: releases
/// each `message`/`id` and the list's own buffer. Safe on a partially filled
/// list, which is exactly what an `OutOfMemory` return leaves behind.
pub fn freeProblems(gpa: Allocator, list: *std.ArrayListUnmanaged(Problem)) void {
    for (list.items) |p| {
        gpa.free(p.message);
        if (p.id) |v| gpa.free(v);
    }
    list.deinit(gpa);
}

fn freeOne(gpa: Allocator, d: Decision) void {
    gpa.free(d.id);
    gpa.free(d.choice);
    gpa.free(d.rationale);
    if (d.artifact) |a| gpa.free(a);
}

fn freeItems(gpa: Allocator, items: []const Decision) void {
    for (items) |d| freeOne(gpa, d);
}

/// `""` and `null` mean the same thing to every consumer -- no artifact --
/// so they are collapsed here rather than at each of the several places that
/// would otherwise have to remember to check both.
fn normalizeArtifact(raw: ?[]const u8) ?[]const u8 {
    const v = raw orelse return null;
    return if (v.len == 0) null else v;
}

/// Contract 2 (owned-result): every field escapes into the returned
/// `Decision`, released by `freeOne`/`free`. `errdefer`s unwind in reverse
/// order of acquisition so a mid-way `OutOfMemory` frees what it took.
fn dupDecision(gpa: Allocator, w: WireDecision) Allocator.Error!Decision {
    const id = try gpa.dupe(u8, w.id);
    errdefer gpa.free(id);
    const choice = try gpa.dupe(u8, w.choice);
    errdefer gpa.free(choice);
    const rationale = try gpa.dupe(u8, w.rationale);
    errdefer gpa.free(rationale);
    const artifact: ?[]const u8 = if (normalizeArtifact(w.artifact)) |a| try gpa.dupe(u8, a) else null;
    return .{ .id = id, .choice = choice, .rationale = rationale, .artifact = artifact };
}

/// Contract 2 (owned-result): the formatted message and the duplicated id
/// escape into `list` and are released by `freeProblems`.
fn addProblem(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Problem),
    index: usize,
    id: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const message = try std.fmt.allocPrint(gpa, fmt, args);
    errdefer gpa.free(message);
    const id_copy: ?[]const u8 = if (id) |v| try gpa.dupe(u8, v) else null;
    errdefer if (id_copy) |v| gpa.free(v);
    try list.append(gpa, .{ .index = index, .id = id_copy, .message = message });
}

/// Contract 1 (self-freeing): the joined buffer is the only allocation and
/// it escapes to the caller.
fn joinChoices(gpa: Allocator, choices: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (choices, 0..) |c, i| {
        if (i != 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// Contract 3 (caller-buffer): allocates nothing; the result borrows from
/// `finding_list`.
fn findById(finding_list: []const findings.Finding, id: []const u8) ?findings.Finding {
    for (finding_list) |f| {
        if (std.mem.eql(u8, f.id, id)) return f;
    }
    return null;
}

/// #167 Stage 3 ruling A3's marker.
const custom_prefix = "custom:";

/// The two answers that resolve a finding by producing nothing. Named
/// because ruling A4 turns on exactly this set, and a third such word would
/// otherwise have to be remembered in two places.
fn isNoopChoice(choice: []const u8) bool {
    return std.mem.eql(u8, choice, "retain") or std.mem.eql(u8, choice, "blocked");
}

/// Ruling A3's shape: `custom:` followed by an ABSOLUTE path with no
/// whitespace and no quote.
///
/// Absolute because the binding is `zb.send("<VERB>", "<path>", …)` and a
/// relative path there resolves against whatever page happens to be open --
/// a bug that only shows on a nested URL. No whitespace and no `"` because
/// the token is interpolated into generated TypeScript, and because a
/// trailing space in a hand-edited JSON file is otherwise an invisible
/// difference between two paths.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn validCustomChoice(choice: []const u8) bool {
    if (!std.mem.startsWith(u8, choice, custom_prefix)) return false;
    const path = choice[custom_prefix.len..];
    if (path.len == 0 or path[0] != '/') return false;
    for (path) |c| {
        if (c == '"' or std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

/// True when this entry names an auth collection the backend document does
/// not have.
///
/// Scoped tightly on purpose: only a `RAILS_AUTH_JOURNEY` finding, only a
/// choice that actually builds the auth islands (`retain`/`blocked` may
/// carry an artifact note that means something else entirely), and only when
/// a document gave us a non-empty list to check against.
///
/// Contract 3 (caller-buffer): allocates nothing.
fn unknownAuthCollection(
    f: findings.Finding,
    choice: []const u8,
    artifact: []const u8,
    auth_collections: []const []const u8,
) bool {
    if (auth_collections.len == 0) return false;
    if (!std.mem.eql(u8, f.code, findings.code_auth_journey)) return false;
    if (isNoopChoice(choice)) return false;
    return !containsString(auth_collections, artifact);
}

fn containsString(choices: []const []const u8, choice: []const u8) bool {
    for (choices) |c| {
        if (std.mem.eql(u8, c, choice)) return true;
    }
    return false;
}

const UnknownKey = struct {
    /// Index of the decision entry the key sits in; `0` when `in_decision`
    /// is false (a top-level key belongs to no entry).
    index: usize,
    key: []const u8,
    in_decision: bool,
};

/// Contract 3 (caller-buffer): allocates nothing; `key` borrows from `root`,
/// which the caller still owns when the message is formatted.
///
/// Exists only because std's `error.UnknownField` is field-blind. Walks the
/// same document `parseFromValue` just rejected, in document order, and
/// returns the first key neither schema level defines -- top level first,
/// then each decision entry, which is the order a reader scans the file in.
fn findUnknownKey(root: std.json.Value) ?UnknownKey {
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (!containsString(&top_level_keys, entry.key_ptr.*)) {
            return .{ .index = 0, .key = entry.key_ptr.*, .in_decision = false };
        }
    }
    const list = switch (obj.get("decisions") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    for (list.items, 0..) |item, i| {
        const entry_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        var eit = entry_obj.iterator();
        while (eit.next()) |entry| {
            if (!containsString(&decision_keys, entry.key_ptr.*)) {
                return .{ .index = i, .key = entry.key_ptr.*, .in_decision = true };
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------- tests ---

const retain_blocked = [_][]const u8{ "retain", "blocked" };
const island_spa_retain_blocked = [_][]const u8{ "island", "spa", "retain", "blocked" };

/// Findings are read-only inputs to `parse`, so a test fixture can hand it
/// static literals: nothing here is ever passed to `findings.free`.
fn fixture(id: []const u8, choices: []const []const u8, requires_artifact: bool) findings.Finding {
    return .{
        .id = id,
        .code = "RAILS_HELPER_UNKNOWN",
        .severity = .warn,
        .path = "app/views/x.html.erb",
        .line = 1,
        .route_id = null,
        .message = "unknown helper",
        .choices = choices,
        .requires_artifact = requires_artifact,
    };
}

/// `fixture`'s sibling for the two Stage 3 rules that key off the finding's
/// CODE rather than only off its `choices`.
fn codedFixture(code: []const u8, id: []const u8, choices: []const []const u8, requires_artifact: bool) findings.Finding {
    var f = fixture(id, choices, requires_artifact);
    f.code = code;
    return f;
}

fn expectMessageContains(problem: Problem, needle: []const u8) !void {
    std.testing.expect(std.mem.indexOf(u8, problem.message, needle) != null) catch |err| {
        std.debug.print("expected message to contain \"{s}\", got \"{s}\"\n", .{ needle, problem.message });
        return err;
    };
}

test "parse: a valid file round-trips every field; artifact is optional" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{
        fixture("A", &retain_blocked, false),
        fixture("B", &island_spa_retain_blocked, true),
    };
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"A","choice":"retain","rationale":"the helper is presentational"},
        \\  {"id":"B","choice":"island","rationale":"needs client state","artifact":"components/Cart.island.tsx"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    const parsed = try parse(gpa, bytes, &fs, &.{}, &problems);
    defer free(gpa, parsed);

    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.stale.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.decisions.len);
    try std.testing.expectEqualStrings("A", parsed.decisions[0].id);
    try std.testing.expectEqualStrings("retain", parsed.decisions[0].choice);
    try std.testing.expectEqualStrings("the helper is presentational", parsed.decisions[0].rationale);
    try std.testing.expect(parsed.decisions[0].artifact == null);
    try std.testing.expectEqualStrings("B", parsed.decisions[1].id);
    try std.testing.expectEqualStrings("components/Cart.island.tsx", parsed.decisions[1].artifact.?);

    // The wire bytes are not borrowed: every field is a fresh allocation, so
    // the caller may free `bytes` (or let a parse arena die) and still read.
    try std.testing.expect(parsed.decisions[0].id.ptr != bytes.ptr);
}

test "lookup: finds a live decision by finding id and never a stale one" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &retain_blocked, false)};
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"A","choice":"retain","rationale":"keep"},
        \\  {"id":"GONE","choice":"blocked","rationale":"answered last run"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    const parsed = try parse(gpa, bytes, &fs, &.{}, &problems);
    defer free(gpa, parsed);

    try std.testing.expectEqualStrings("retain", lookup(parsed, "A").?.choice);
    // Stale entries are reported, never answered with: a decision whose
    // finding is gone must not resolve some other run's finding.
    try std.testing.expect(lookup(parsed, "GONE") == null);
    try std.testing.expect(lookup(parsed, "nope") == null);
}

test "parse: an id matching no finding is stale, not an error" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &retain_blocked, false)};
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"GONE","choice":"whatever","rationale":"the template was fixed"},
        \\  {"id":"A","choice":"blocked","rationale":"still open"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    const parsed = try parse(gpa, bytes, &fs, &.{}, &problems);
    defer free(gpa, parsed);

    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.decisions.len);
    try std.testing.expectEqualStrings("A", parsed.decisions[0].id);
    try std.testing.expectEqual(@as(usize, 1), parsed.stale.len);
    try std.testing.expectEqualStrings("GONE", parsed.stale[0].id);
    // A stale entry's `choice` is carried verbatim: there is no finding left
    // to validate it against, and the caller only reports it.
    try std.testing.expectEqualStrings("whatever", parsed.stale[0].choice);
}

test "parse: a choice outside the finding's set is Invalid and the message lists the allowed choices" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &retain_blocked, false)};
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"A","choice":"spa","rationale":"wishful"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    try std.testing.expectError(error.Invalid, parse(gpa, bytes, &fs, &.{}, &problems));
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
    try std.testing.expectEqual(@as(usize, 0), problems.items[0].index);
    try std.testing.expectEqualStrings("A", problems.items[0].id.?);
    try expectMessageContains(problems.items[0], "spa");
    try expectMessageContains(problems.items[0], "retain, blocked");
}

test "parse: a finding that requires an artifact rejects a decision without one" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &island_spa_retain_blocked, true)};
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"A","choice":"island","rationale":"needs state"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    try std.testing.expectError(error.Invalid, parse(gpa, bytes, &fs, &.{}, &problems));
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
    try std.testing.expectEqualStrings("A", problems.items[0].id.?);
    try expectMessageContains(problems.items[0], "artifact");
}

test "parse: an empty artifact string counts as absent" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &island_spa_retain_blocked, true)};
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"A","choice":"island","rationale":"needs state","artifact":""}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    try std.testing.expectError(error.Invalid, parse(gpa, bytes, &fs, &.{}, &problems));
    try expectMessageContains(problems.items[0], "artifact");
}

test "parse: a duplicate id is Invalid and names the id" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &retain_blocked, false)};
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"A","choice":"retain","rationale":"first"},
        \\  {"id":"A","choice":"blocked","rationale":"second"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    try std.testing.expectError(error.Invalid, parse(gpa, bytes, &fs, &.{}, &problems));
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
    // The SECOND entry is the offender: the first one is a perfectly good
    // answer, and pointing at it would send the operator to the wrong line.
    try std.testing.expectEqual(@as(usize, 1), problems.items[0].index);
    try std.testing.expectEqualStrings("A", problems.items[0].id.?);
    try expectMessageContains(problems.items[0], "duplicate");
}

test "parse: an empty or whitespace-only rationale is Invalid" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{
        fixture("A", &retain_blocked, false),
        fixture("B", &retain_blocked, false),
    };
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"A","choice":"retain","rationale":""},
        \\  {"id":"B","choice":"retain","rationale":"   "}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    try std.testing.expectError(error.Invalid, parse(gpa, bytes, &fs, &.{}, &problems));
    try std.testing.expectEqual(@as(usize, 2), problems.items.len);
    try expectMessageContains(problems.items[0], "rationale");
    try std.testing.expectEqualStrings("B", problems.items[1].id.?);
    try expectMessageContains(problems.items[1], "rationale");
}

test "parse: a missing id names the entry by index, with no id to quote" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &retain_blocked, false)};
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"choice":"retain","rationale":"which finding?"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    try std.testing.expectError(error.Invalid, parse(gpa, bytes, &fs, &.{}, &problems));
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
    try std.testing.expect(problems.items[0].id == null);
    try expectMessageContains(problems.items[0], "id");
}

test "parse: every offending entry gets its own problem, and valid siblings do not" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{
        fixture("A", &retain_blocked, false),
        fixture("B", &retain_blocked, false),
        fixture("C", &island_spa_retain_blocked, true),
    };
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"A","choice":"retain","rationale":"fine"},
        \\  {"id":"B","choice":"nope","rationale":"bad choice"},
        \\  {"id":"C","choice":"island","rationale":""}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    // One run must list EVERY offending entry: an operator re-running after
    // each single complaint is the failure mode this reporting avoids.
    try std.testing.expectError(error.Invalid, parse(gpa, bytes, &fs, &.{}, &problems));
    try std.testing.expectEqual(@as(usize, 3), problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), problems.items[0].index);
    try std.testing.expectEqual(@as(usize, 2), problems.items[1].index);
    try std.testing.expectEqual(@as(usize, 2), problems.items[2].index);
    try expectMessageContains(problems.items[1], "rationale");
    try expectMessageContains(problems.items[2], "artifact");
}

test "parse: malformed JSON is InvalidJson" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &retain_blocked, false)};
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    try std.testing.expectError(error.InvalidJson, parse(gpa, "{\"schema\": ", &fs, &.{}, &problems));
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
    try expectMessageContains(problems.items[0], "JSON");
}

test "parse: a missing `decisions` key is InvalidJson, not an empty decision set" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &retain_blocked, false)};
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1"}
    ;
    try std.testing.expectError(error.InvalidJson, parse(gpa, bytes, &fs, &.{}, &problems));
    try expectMessageContains(problems.items[0], "decisions");
}

test "parse: a wrong or absent schema id is WrongSchema" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &retain_blocked, false)};

    const wrong =
        \\{"schema":"zigapagos.rails-decisions/2","decisions":[]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);
    try std.testing.expectError(error.WrongSchema, parse(gpa, wrong, &fs, &.{}, &problems));
    try expectMessageContains(problems.items[0], schema_id);
    try expectMessageContains(problems.items[0], "zigapagos.rails-decisions/2");

    const absent =
        \\{"decisions":[]}
    ;
    var problems2: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems2);
    try std.testing.expectError(error.WrongSchema, parse(gpa, absent, &fs, &.{}, &problems2));
    try expectMessageContains(problems2.items[0], schema_id);
}

test "parse: an unrecognized key is Invalid and names the key" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &retain_blocked, false)};

    // A typo'd key inside one decision: silently ignoring it would record an
    // answer the operator did not give (here: no rationale at all).
    const inner =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"A","choice":"retain","rationalle":"typo"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);
    try std.testing.expectError(error.Invalid, parse(gpa, inner, &fs, &.{}, &problems));
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
    try std.testing.expectEqual(@as(usize, 0), problems.items[0].index);
    try expectMessageContains(problems.items[0], "rationalle");

    // ... and at the top level.
    const outer =
        \\{"schema":"zigapagos.rails-decisions/1","desicions":[]}
    ;
    var problems2: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems2);
    try std.testing.expectError(error.Invalid, parse(gpa, outer, &fs, &.{}, &problems2));
    try expectMessageContains(problems2.items[0], "desicions");
}

test "parse: an empty decision list is valid" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{fixture("A", &retain_blocked, false)};
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);

    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[]}
    ;
    const parsed = try parse(gpa, bytes, &fs, &.{}, &problems);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 0), parsed.decisions.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.stale.len);
}

// The accepting path only. The REJECTING path allocates too -- and more
// intricately -- so it gets its own sweep below; an all-valid fixture never
// reaches `addProblem`/`joinChoices` at all.
test "parse under a FailingAllocator leaks nothing on any partial allocation" {
    const fs = [_]findings.Finding{
        fixture("A", &retain_blocked, false),
        fixture("B", &island_spa_retain_blocked, true),
    };
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"A","choice":"retain","rationale":"keep"},
        \\  {"id":"B","choice":"island","rationale":"state","artifact":"components/Cart.island.tsx"},
        \\  {"id":"GONE","choice":"retain","rationale":"stale"}
        \\]}
    ;

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 1000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var problems: std.ArrayListUnmanaged(Problem) = .empty;
        // `problems` is caller-owned on every path, including the OOM one:
        // freeing it through the SAME failing allocator is what proves the
        // partial list is reclaimable rather than leaked.
        defer freeProblems(gpa, &problems);
        if (parse(gpa, bytes, &fs, &.{}, &problems)) |parsed| {
            defer free(gpa, parsed);
            try std.testing.expectEqual(@as(usize, 2), parsed.decisions.len);
            try std.testing.expectEqual(@as(usize, 1), parsed.stale.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "parse under a FailingAllocator leaks nothing while REPORTING problems" {
    const fs = [_]findings.Finding{
        fixture("A", &retain_blocked, false),
        fixture("B", &island_spa_retain_blocked, true),
        fixture("C", &retain_blocked, false),
    };

    // Three fixtures, because the allocating rejection paths are genuinely
    // different code. A bad choice runs `joinChoices` AND `addProblem` from
    // inside the validation loop, at a point where two already-owned
    // `Decision`s and a partly built `problems` list are both live -- the
    // densest unwind in the file. An unrecognized key runs `findUnknownKey`
    // + `addProblem` with the `std.json.Value` document still open and no
    // decision owned yet. Malformed bytes fail before either list exists.
    const Case = struct { bytes: []const u8, want: ParseError, problems: usize };
    const cases = [_]Case{
        .{
            .bytes =
            \\{"schema":"zigapagos.rails-decisions/1","decisions":[
            \\  {"id":"A","choice":"retain","rationale":"keep"},
            \\  {"id":"B","choice":"island","rationale":"state","artifact":"components/Cart.island.tsx"},
            \\  {"id":"C","choice":"nope","rationale":"not on offer"},
            \\  {"id":"C","choice":"retain","rationale":"answered twice"}
            \\]}
            ,
            .want = error.Invalid,
            .problems = 2,
        },
        .{
            .bytes =
            \\{"schema":"zigapagos.rails-decisions/1","decisions":[
            \\  {"id":"A","choice":"retain","rationalle":"typo"}
            \\]}
            ,
            .want = error.Invalid,
            .problems = 1,
        },
        .{
            .bytes = "{\"schema\": ",
            .want = error.InvalidJson,
            .problems = 1,
        },
    };

    for (cases) |c| {
        // Anti-vacuous guard: a sweep that only ever saw `OutOfMemory` would
        // pass while proving nothing about the reporting path it exists to
        // cover, so the rejection must actually be reached.
        var reached_rejection = false;
        var fail_index: usize = 0;
        while (fail_index <= 1000) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            const gpa = failing.allocator();
            var problems: std.ArrayListUnmanaged(Problem) = .empty;
            // Released through the SAME failing allocator on every path --
            // the OOM one included, where the list is half-built. That is
            // what makes a missing `errdefer` inside `addProblem` show up
            // here as a testing-allocator leak rather than passing silently.
            defer freeProblems(gpa, &problems);
            if (parse(gpa, c.bytes, &fs, &.{}, &problems)) |parsed| {
                free(gpa, parsed);
                return error.SweepAcceptedAnInvalidFile;
            } else |err| {
                if (err == error.OutOfMemory) continue;
                try std.testing.expectEqual(c.want, err);
                // Every problem the rejection promised is present and owned:
                // an empty list here would mean the sweep never allocated a
                // message at all.
                try std.testing.expectEqual(c.problems, problems.items.len);
                reached_rejection = true;
                break;
            }
        }
        try std.testing.expect(reached_rejection);
    }
}

// ---- #167 Stage 3 --------------------------------------------------------

const backend_choices = [_][]const u8{ "createPosts", "retain", "blocked" };
const journey_choices = [_][]const u8{ "island", "retain", "blocked" };
const users_collection = [_][]const u8{"users"};

test "parse: custom:/<path> answers a RAILS_BACKEND_ENDPOINT finding, and only that code" {
    const gpa = std.testing.allocator;
    // Ruling A3. `choices[]` cannot enumerate a free-form URL, so the SHAPE
    // is validated here; the finding's message is what tells the operator
    // the answer exists at all.
    const fs = [_]findings.Finding{
        codedFixture(findings.code_backend_endpoint, "F", &backend_choices, false),
        codedFixture("RAILS_REQUEST_TIME_STATE", "S", &retain_blocked, false),
    };
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"F","choice":"custom:/api/contact","rationale":"a consumer route, not a collection"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);
    const parsed = try parse(gpa, bytes, &fs, &.{}, &problems);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    try std.testing.expectEqualStrings("custom:/api/contact", parsed.decisions[0].choice);

    // The same token on a finding that is NOT a backend endpoint is just a
    // choice nobody offered.
    const other =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"S","choice":"custom:/api/contact","rationale":"wrong finding"}
        \\]}
    ;
    var problems2: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems2);
    try std.testing.expectError(error.Invalid, parse(gpa, other, &fs, &.{}, &problems2));
    try expectMessageContains(problems2.items[0], "is not offered for");
}

test "parse: a malformed custom: choice names the shape it must have" {
    const gpa = std.testing.allocator;
    const fs = [_]findings.Finding{codedFixture(findings.code_backend_endpoint, "F", &backend_choices, false)};
    const cases = [_][]const u8{
        // No leading slash: the binding is `zb.send(verb, path)`, and a
        // relative path resolves against whatever page is open.
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"F","choice":"custom:api/contact","rationale":"relative"}
        \\]}
        ,
        // Whitespace: invisible in a hand-edited file, and interpolated
        // straight into generated TypeScript.
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"F","choice":"custom:/a b","rationale":"a space"}
        \\]}
        ,
    };
    const wanted = [_][]const u8{
        "choice \"custom:api/contact\" must be custom:/<absolute path> with no whitespace or quotes",
        "choice \"custom:/a b\" must be custom:/<absolute path> with no whitespace or quotes",
    };
    for (cases, wanted) |bytes, want| {
        var problems: std.ArrayListUnmanaged(Problem) = .empty;
        defer freeProblems(gpa, &problems);
        try std.testing.expectError(error.Invalid, parse(gpa, bytes, &fs, &.{}, &problems));
        try std.testing.expectEqual(@as(usize, 1), problems.items.len);
        try std.testing.expectEqualStrings(want, problems.items[0].message);
    }
}

test "parse: requires_artifact demands an artifact only from a choice that produces one" {
    const gpa = std.testing.allocator;
    // Ruling A4. `retain` and `blocked` write nothing, so demanding a path
    // for them was the Stage 2 rule written when no finding set the flag.
    const fs = [_]findings.Finding{codedFixture(findings.code_auth_journey, "J", &journey_choices, true)};
    const ok =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"J","choice":"retain","rationale":"the Rails app keeps the sign-in flow"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);
    const parsed = try parse(gpa, ok, &fs, &.{}, &problems);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    try std.testing.expect(parsed.decisions[0].artifact == null);

    const bad =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"J","choice":"island","rationale":"migrate it"}
        \\]}
    ;
    var problems2: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems2);
    try std.testing.expectError(error.Invalid, parse(gpa, bad, &fs, &.{}, &problems2));
    try std.testing.expectEqual(@as(usize, 1), problems2.items.len);
    // The Stage 2 wording, unchanged: only WHEN it fires has moved.
    try std.testing.expectEqualStrings(
        "finding \"J\" requires an `artifact` path alongside the choice",
        problems2.items[0].message,
    );
}

test "parse: an auth-journey artifact must be an auth collection the document carries" {
    const gpa = std.testing.allocator;
    // The failure this prevents is silent and late: an `AuthForm` calling
    // `zb.collection("members").authWithPassword` against a collection that
    // cannot authenticate builds, ships, and fails at the first sign-in.
    const fs = [_]findings.Finding{codedFixture(findings.code_auth_journey, "J", &journey_choices, true)};
    const bad =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"J","choice":"island","rationale":"migrate it","artifact":"members"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);
    try std.testing.expectError(error.Invalid, parse(gpa, bad, &fs, &users_collection, &problems));
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
    try std.testing.expectEqualStrings(
        "artifact \"members\" is not an auth collection in the backend document; auth collections: users",
        problems.items[0].message,
    );

    const good =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"J","choice":"island","rationale":"migrate it","artifact":"users"}
        \\]}
    ;
    var problems2: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems2);
    const parsed = try parse(gpa, good, &fs, &users_collection, &problems2);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 0), problems2.items.len);
}

test "parse: without a backend document an auth collection name is accepted verbatim" {
    const gpa = std.testing.allocator;
    // There is nothing to check against, and refusing every name would make
    // `RAILS_AUTH_JOURNEY` unanswerable without `--backend` -- which the
    // finding's own message promises it is not.
    const fs = [_]findings.Finding{codedFixture(findings.code_auth_journey, "J", &journey_choices, true)};
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"J","choice":"island","rationale":"migrate it","artifact":"members"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);
    const parsed = try parse(gpa, bytes, &fs, &.{}, &problems);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    try std.testing.expectEqualStrings("members", parsed.decisions[0].artifact.?);
}

test "parse: the auth-collection rule is scoped to an island answer on the journey finding" {
    const gpa = std.testing.allocator;
    // A `retain` may carry an artifact note that means something else
    // entirely, and an `island` artifact on any OTHER finding is a component
    // path -- neither is an auth collection name, and rejecting them against
    // that list would be nonsense.
    const fs = [_]findings.Finding{
        codedFixture(findings.code_auth_journey, "J", &journey_choices, true),
        codedFixture("RAILS_REQUEST_TIME_STATE", "S", &island_spa_retain_blocked, true),
    };
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"J","choice":"retain","rationale":"kept","artifact":"notes/why.md"},
        \\  {"id":"S","choice":"island","rationale":"state","artifact":"components/Cart.island.tsx"}
        \\]}
    ;
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    defer freeProblems(gpa, &problems);
    const parsed = try parse(gpa, bytes, &fs, &users_collection, &problems);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
}

test "parse: the Stage 3 rejections leak nothing under a FailingAllocator" {
    // The sweep above never reaches `validCustomChoice`'s message or the
    // auth-collection one, both of which allocate.
    const fs = [_]findings.Finding{
        codedFixture(findings.code_backend_endpoint, "F", &backend_choices, false),
        codedFixture(findings.code_auth_journey, "J", &journey_choices, true),
    };
    const bytes =
        \\{"schema":"zigapagos.rails-decisions/1","decisions":[
        \\  {"id":"F","choice":"custom:api/contact","rationale":"relative"},
        \\  {"id":"J","choice":"island","rationale":"migrate it","artifact":"members"}
        \\]}
    ;
    var reached_rejection = false;
    var fail_index: usize = 0;
    while (fail_index <= 1000) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var problems: std.ArrayListUnmanaged(Problem) = .empty;
        defer freeProblems(gpa, &problems);
        if (parse(gpa, bytes, &fs, &users_collection, &problems)) |parsed| {
            free(gpa, parsed);
            return error.SweepAcceptedAnInvalidFile;
        } else |err| {
            if (err == error.OutOfMemory) continue;
            try std.testing.expectEqual(error.Invalid, err);
            try std.testing.expectEqual(@as(usize, 2), problems.items.len);
            reached_rejection = true;
            break;
        }
    }
    try std.testing.expect(reached_rejection);
}
