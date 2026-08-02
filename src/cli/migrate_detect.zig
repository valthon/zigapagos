//! Pure (std-only) detection and inference helpers for `zigapagos migrate`.
//!
//! These operate on in-memory source text so they can be unit-tested without
//! any filesystem / `Io` plumbing (see the `test` blocks at the bottom, which
//! drive the cases a real Astro site hits). `migrate.zig` is the IO/CLI shell
//! that walks the project, calls these, and renders the report/skeletons.
//!
//! Two jobs live here:
//!   1. Island detection — a component is an island only when it is used at a
//!      call site with a `client:*` directive (that is how Astro marks one).
//!      A component file living in `src/components/` is NOT, on its own,
//!      evidence of an island: static `.astro` components become SuperHTML
//!      partials, and a component that is only ever a child of another
//!      component (never used with `client:*`) is not an island either.
//!   2. Props inference — best-effort extraction of prop field names and
//!      TypeScript types from an Astro/React component. Used by the scaffold
//!      to re-emit the Props declaration verbatim in a TSX island skeleton.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A single inferred prop field — name and raw TypeScript type text.
pub const PropField = struct {
    name: []const u8,
    /// Raw TypeScript type text from the source (empty when inferred from
    /// destructuring, where no type information is available).
    ts_type: []const u8,
};

/// A single parsed ES `import` statement — the module specifier and the named
/// identifiers it binds. `specifier` and each element of `names` slice into
/// the source buffer (lifetime: caller keeps `src` alive). Only the outer
/// array and each per-statement `names` sub-array are heap-allocated; free
/// with `freeImports`. `names` is empty for default, namespace (`* as NS`),
/// and side-effect imports.
pub const ImportStmt = struct {
    specifier: []const u8,
    names: []const []const u8,
};

// ---------------------------------------------------------------------------
// Island detection
// ---------------------------------------------------------------------------

/// Collect the Capitalised tag names in `src` that are used with a `client:`
/// directive (e.g. `<ContactForm client:load …>` → "ContactForm"). This is how
/// Astro marks a component as an island: the directive lives at the *call
/// site*, not inside the component's own file. Plain HTML elements (lowercase
/// tags) and components used without a directive are ignored. Names are duped
/// into `gpa` and inserted into `set`.
pub fn collectClientUsages(
    gpa: Allocator,
    src: []const u8,
    set: *std.StringHashMapUnmanaged(void),
) !void {
    const needle = "client:";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, needle)) |pos| {
        i = pos + needle.len;
        const tag = tagOpeningAt(src, pos) orelse continue;
        // Components are Capitalised; lowercase tags are plain HTML elements.
        if (tag.len == 0 or !std.ascii.isUpper(tag[0])) continue;
        // Use the last dotted segment as the bare name (`ui.Button` → `Button`).
        var name = tag;
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| name = name[d + 1 ..];
        if (name.len == 0 or !std.ascii.isUpper(name[0])) continue;
        if (set.contains(name)) continue;
        try set.put(gpa, try gpa.dupe(u8, name), {});
    }
}

/// Given a position known to be inside an opening tag (at/after the tag name),
/// backtrack to the `<` and return the tag identifier that follows it. Returns
/// null if a `>` is hit first (the position is not inside a tag).
fn tagOpeningAt(src: []const u8, pos: usize) ?[]const u8 {
    var k = pos;
    while (k > 0) {
        k -= 1;
        switch (src[k]) {
            '<' => {
                var j = k + 1;
                const start = j;
                while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_' or src[j] == '.')) j += 1;
                return src[start..j];
            },
            '>' => return null, // left the tag without finding its '<'
            else => {},
        }
    }
    return null;
}

/// The classification of a component file once the set of island names is known.
pub const Role = enum {
    /// Used somewhere with `client:*` → port as a TSX island (`@z/runtime`).
    island,
    /// A static `.astro` component never used with `client:*` → SuperHTML partial.
    partial,
    /// A non-`.astro` component never used with `client:*` (e.g. a transitive
    /// child of another component). Port only if a real island needs it.
    plain,
};

/// Decide a component's role from its path and the set of island names.
pub fn componentRole(path: []const u8, island_names: *const std.StringHashMapUnmanaged(void)) Role {
    const name = moduleName(path);
    if (island_names.contains(name)) return .island;
    if (std.mem.endsWith(u8, path, ".astro")) return .partial;
    return .plain;
}

/// "src/components/Counter.astro" -> "Counter".
pub fn moduleName(path: []const u8) []const u8 {
    var name = path;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |s| name = name[s + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| name = name[0..d];
    return name;
}

// ---------------------------------------------------------------------------
// Props inference
// ---------------------------------------------------------------------------

/// Infer `Props` fields from an Astro/React component source. Strategies, first win:
///   1. `interface Props { field: type; … }`
///   2. `type Props = { field: type; … }`
///   3. `const { a, b, … } = Astro.props;` (types unknown → empty ts_type)
/// All inference is best-effort / approximate.
pub fn inferProps(gpa: Allocator, src: []const u8) ![]PropField {
    if (findPropsBlock(src)) |block| {
        return parsePropsBlock(gpa, block);
    }
    return parseDestructuring(gpa, src);
}

/// Find the braced body of `interface Props { … }` or `type Props = { … }`.
fn findPropsBlock(src: []const u8) ?[]const u8 {
    const patterns = [_][]const u8{
        "interface Props",
        "type Props =",
        "interface Props{",
        "type Props={",
    };
    var start: ?usize = null;
    for (patterns) |pat| {
        if (std.mem.indexOf(u8, src, pat)) |idx| {
            if (start == null or idx < start.?) start = idx;
        }
    }
    const s = start orelse return null;
    const brace = std.mem.indexOfScalarPos(u8, src, s, '{') orelse return null;
    var depth: usize = 0;
    var j: usize = brace;
    while (j < src.len) : (j += 1) {
        switch (src[j]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return src[brace + 1 .. j];
            },
            else => {},
        }
    }
    return null;
}

/// Find and return the full text of `interface Props { … }` or `type Props = { … }`,
/// including the keyword prefix. Used by the TSX scaffold fallback to re-emit the
/// Props declaration verbatim.
pub fn findPropsSpan(src: []const u8) ?[]const u8 {
    const patterns = [_][]const u8{
        "interface Props",
        "type Props =",
        "interface Props{",
        "type Props={",
    };
    var start: ?usize = null;
    for (patterns) |pat| {
        if (std.mem.indexOf(u8, src, pat)) |idx| {
            if (start == null or idx < start.?) start = idx;
        }
    }
    const s = start orelse return null;
    const brace = std.mem.indexOfScalarPos(u8, src, s, '{') orelse return null;
    var depth: usize = 0;
    var j: usize = brace;
    while (j < src.len) : (j += 1) {
        switch (src[j]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return src[s .. j + 1];
            },
            else => {},
        }
    }
    return null;
}

/// Parse a TS interface/type body into PropFields. Fields are separated by `;`
/// or newlines. Each entry: `name?: TypeExpr`. A nested object value can itself
/// contain `;`/newlines, so we split on top-level separators only
/// (brace/paren/angle-depth aware).
fn parsePropsBlock(gpa: Allocator, block: []const u8) ![]PropField {
    var fields: std.ArrayListUnmanaged(PropField) = .empty;
    errdefer {
        for (fields.items) |field| {
            gpa.free(field.name);
            gpa.free(field.ts_type);
        }
        fields.deinit(gpa);
    }
    var it = TopLevelFieldIterator{ .src = block };
    while (it.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t\r\n");
        if (entry.len == 0) continue;
        // Split name from type at the first top-level ':'.
        const colon = topLevelColon(entry) orelse continue;
        var name = std.mem.trim(u8, entry[0..colon], " \t?\r\n"); // strip optional marker
        if (std.mem.indexOfScalar(u8, name, '[')) |bi| name = name[0..bi];
        name = std.mem.trim(u8, name, " \t");
        if (!isIdent(name)) continue;
        // Type is everything after ':' minus a trailing `//` comment.
        var type_str = entry[colon + 1 ..];
        if (std.mem.indexOf(u8, type_str, "//")) |ci| type_str = type_str[0..ci];
        type_str = std.mem.trim(u8, type_str, " \t\r\n,");
        if (type_str.len == 0) continue;
        const name_copy = try gpa.dupe(u8, name);
        errdefer gpa.free(name_copy);
        const type_copy = try gpa.dupe(u8, type_str);
        errdefer gpa.free(type_copy);
        try fields.append(gpa, .{ .name = name_copy, .ts_type = type_copy });
    }
    return fields.toOwnedSlice(gpa);
}

/// Iterate top-level fields of an interface/type body, splitting on `;` and
/// newlines that are NOT nested inside `{…}`, `(…)`, or `<…>`. This keeps a
/// callback type like `(token: string) => void` or a nested object intact.
const TopLevelFieldIterator = struct {
    src: []const u8,
    pos: usize = 0,

    fn next(self: *TopLevelFieldIterator) ?[]const u8 {
        if (self.pos >= self.src.len) return null;
        var depth: i32 = 0;
        const start = self.pos;
        var j = self.pos;
        while (j < self.src.len) : (j += 1) {
            switch (self.src[j]) {
                '{', '(', '[', '<' => depth += 1,
                '}', ')', ']', '>' => if (depth > 0) {
                    depth -= 1;
                },
                ';', '\n' => if (depth == 0) {
                    self.pos = j + 1;
                    return self.src[start..j];
                },
                else => {},
            }
        }
        self.pos = self.src.len;
        return self.src[start..];
    }
};

/// Index of the first `:` at brace/paren/angle depth 0, or null.
fn topLevelColon(entry: []const u8) ?usize {
    var depth: i32 = 0;
    for (entry, 0..) |ch, idx| {
        switch (ch) {
            '{', '(', '[', '<' => depth += 1,
            '}', ')', ']', '>' => if (depth > 0) {
                depth -= 1;
            },
            ':' => if (depth == 0) return idx,
            else => {},
        }
    }
    return null;
}

/// True if `s` is a non-empty plain identifier (letters, digits, `_`, `$`).
fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) return false;
    }
    return true;
}

/// Strategy 3: parse `const { a, b, c = default } = Astro.props;`
/// No type information available — ts_type is left empty.
fn parseDestructuring(gpa: Allocator, src: []const u8) ![]PropField {
    const needle = "Astro.props";
    const pos = std.mem.indexOf(u8, src, needle) orelse return &.{};
    var open: ?usize = null;
    var j: usize = pos;
    while (j > 0) : (j -= 1) {
        if (src[j] == '{') {
            open = j;
            break;
        }
        if (src[j] == '\n') break;
    }
    const ob = open orelse return &.{};
    const cb = std.mem.indexOfScalarPos(u8, src, ob, '}') orelse return &.{};
    const inner = src[ob + 1 .. cb];
    var fields: std.ArrayListUnmanaged(PropField) = .empty;
    errdefer {
        for (fields.items) |field| gpa.free(field.name);
        fields.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw| {
        var name = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.indexOfScalar(u8, name, '=')) |ei| name = name[0..ei];
        if (std.mem.indexOfScalar(u8, name, ':')) |ci| name = name[0..ci];
        name = std.mem.trim(u8, name, " \t");
        if (!isIdent(name)) continue;
        const name_copy = try gpa.dupe(u8, name);
        errdefer gpa.free(name_copy);
        try fields.append(gpa, .{ .name = name_copy, .ts_type = "" });
    }
    return fields.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Import guardrail classification — single source of truth.
// ---------------------------------------------------------------------------

/// Single source of truth for the migrate scaffolder's import classification.
/// Only the `runtime_ok` and `relative_ok` arms mirror the lint's BASE_ALLOW in
/// runtime/scripts/lint-island-imports.ts (the shared contract, drift-guarded by
/// test). The rest are migrate-ONLY advisory recipes and are NOT part of the
/// lint's base contract: `first_party_ok`/`legacy_shared_map` are a pre-existing
/// pilot-site-specific mapping the doctor suggests; `react_rewrite` is
/// mechanically swappable to "@z/runtime". (The lint allows extra scopes — a
/// shared package, or an opt-in npm-compat package — per a project's
/// z-runtime.config.json, not via this table.) Everything else is
/// `forbidden_npm` (the scaffold flags it; the doctor may still suggest a shim
/// target — see analyze()).
pub const ImportClass = enum {
    runtime_ok,
    first_party_ok,
    relative_ok,
    react_rewrite,
    legacy_shared_map,
    forbidden_npm,
};

pub fn classifyImport(spec: []const u8) ImportClass {
    if (std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../")) return .relative_ok;
    if (std.mem.eql(u8, spec, "@z/runtime") or std.mem.startsWith(u8, spec, "@z/runtime/")) return .runtime_ok;
    if (std.mem.eql(u8, spec, "@your-org/shared-lite") or std.mem.startsWith(u8, spec, "@your-org/shared-lite/")) return .first_party_ok;
    const react = [_][]const u8{ "react", "react-dom", "react-dom/client", "react/jsx-runtime", "react/jsx-dev-runtime" };
    for (react) |r| if (std.mem.eql(u8, spec, r)) return .react_rewrite;
    if (std.mem.startsWith(u8, spec, "@legacy-app/")) return .legacy_shared_map;
    return .forbidden_npm;
}

// ---------------------------------------------------------------------------
// Import extraction — multi-line-aware, brace/quote-aware.
// ---------------------------------------------------------------------------

/// Return the text between the opening quote at `pos` and its matching close.
/// Handles both `"` and `'`. `end` is the index of the closing quote in `src`.
fn parseQuotedAt(src: []const u8, pos: usize) ?struct { text: []const u8, end: usize } {
    if (pos >= src.len) return null;
    const q = src[pos];
    if (q != '"' and q != '\'') return null;
    var j = pos + 1;
    while (j < src.len) : (j += 1) {
        if (src[j] == '\\') {
            j += 1;
            continue;
        } // skip escape
        if (src[j] == q) return .{ .text = src[pos + 1 .. j], .end = j };
    }
    return null;
}

/// Extract every ES `import` statement from `src` into a heap-allocated slice
/// of `ImportStmt`. Specifiers and name strings slice into `src` (no copies).
/// Only the outer stmt array and each per-statement `names` sub-array are
/// heap-allocated. Free with `freeImports`.
pub fn extractImports(gpa: Allocator, src: []const u8) ![]ImportStmt {
    var stmts: std.ArrayListUnmanaged(ImportStmt) = .empty;
    errdefer {
        for (stmts.items) |stmt| gpa.free(stmt.names);
        stmts.deinit(gpa);
    }
    var i: usize = 0;

    while (i < src.len) {
        const kw = "import";
        const pos = std.mem.indexOfPos(u8, src, i, kw) orelse break;

        // Statement boundary: position 0, or preceded by \n / ; / whitespace.
        if (pos > 0) {
            switch (src[pos - 1]) {
                '\n', ';', ' ', '\t', '\r' => {},
                else => {
                    i = pos + 1;
                    continue;
                },
            }
        }

        // Must be followed by whitespace, `{`, `*`, a quote char, or `(` (dynamic import).
        const after_kw = pos + kw.len;
        if (after_kw >= src.len) break;
        switch (src[after_kw]) {
            ' ', '\t', '{', '*', '"', '\'', '(' => {},
            else => {
                i = pos + 1;
                continue;
            },
        }

        // Fix 2: skip 'import' tokens that appear after '//' on the same line.
        {
            const line_start: usize = if (std.mem.lastIndexOfScalar(u8, src[0..pos], '\n')) |nl| nl + 1 else 0;
            if (std.mem.indexOf(u8, src[line_start..pos], "//") != null) {
                i = pos + kw.len;
                continue;
            }
        }

        i = after_kw;
        // Skip whitespace after "import".
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}
        if (i >= src.len) break;

        // Dynamic import:  import("specifier")  or  import( "specifier" )
        // Emits specifier with empty names (no named bindings in a dynamic import).
        if (src[i] == '(') {
            i += 1; // skip '('
            while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}
            if (i >= src.len) break;
            if (src[i] != '"' and src[i] != '\'') {
                i += 1;
                continue;
            }
            const pq = parseQuotedAt(src, i) orelse {
                i += 1;
                continue;
            };
            i = pq.end + 1;
            // advance past closing paren if present
            while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}
            if (i < src.len and src[i] == ')') i += 1;
            var dyn_names: std.ArrayListUnmanaged([]const u8) = .empty;
            try stmts.append(gpa, .{
                .specifier = pq.text,
                .names = try dyn_names.toOwnedSlice(gpa),
            });
            continue;
        }

        // Side-effect import:  import "specifier"  or  import 'specifier'
        if (src[i] == '"' or src[i] == '\'') {
            const pq = parseQuotedAt(src, i) orelse {
                i += 1;
                continue;
            };
            var side_names: std.ArrayListUnmanaged([]const u8) = .empty;
            try stmts.append(gpa, .{
                .specifier = pq.text,
                .names = try side_names.toOwnedSlice(gpa),
            });
            i = pq.end + 1;
            continue;
        }

        // Named imports:  import { … }  — block may span newlines.
        var brace_content: ?[]const u8 = null;
        if (src[i] == '{') {
            const bc_start = i + 1;
            i += 1;
            var depth: usize = 1;
            while (i < src.len) : (i += 1) {
                switch (src[i]) {
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if (depth == 0) break; // continue expr skipped on break
                    },
                    else => {},
                }
            }
            // i now points at closing '}'  (break skips the `: (i += 1)`)
            if (depth == 0) {
                brace_content = src[bc_start..i];
                i += 1; // advance past '}'
            }
        } else if (src[i] != '*') {
            // Combined default+named: `import Default, { named1, named2 } from …`
            // Scan forward to the ' from ' boundary looking for a ', {' sequence.
            const scan_limit = std.mem.indexOfPos(u8, src, i, " from ") orelse src.len;
            var scan = i;
            while (scan < scan_limit) : (scan += 1) {
                if (src[scan] == ',') {
                    var k = scan + 1;
                    while (k < scan_limit and (src[k] == ' ' or src[k] == '\t' or src[k] == '\n' or src[k] == '\r')) : (k += 1) {}
                    if (k < src.len and src[k] == '{') {
                        // Run the brace-depth scanner on this block.
                        const cbc_start = k + 1;
                        var cbd: usize = 1;
                        var cbj = cbc_start;
                        while (cbj < src.len) : (cbj += 1) {
                            switch (src[cbj]) {
                                '{' => cbd += 1,
                                '}' => {
                                    cbd -= 1;
                                    if (cbd == 0) break;
                                },
                                else => {},
                            }
                        }
                        if (cbd == 0) brace_content = src[cbc_start..cbj];
                    }
                    break; // stop after first comma
                }
            }
        }
        // Default  (import X from)  and namespace  (import * as NS from)  imports
        // leave i unchanged here; the "from " search below picks them up.

        // Find the "from " keyword to reach the specifier.
        const from_needle = "from ";
        const from_pos = std.mem.indexOfPos(u8, src, i, from_needle) orelse continue;
        i = from_pos + from_needle.len;

        // Skip whitespace between "from" and the opening quote.
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}
        if (i >= src.len) break;

        const pq = parseQuotedAt(src, i) orelse continue;
        i = pq.end + 1;

        // Parse named identifiers from the brace content (if any).
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer names.deinit(gpa);
        if (brace_content) |bc| {
            var it = std.mem.splitScalar(u8, bc, ',');
            while (it.next()) |raw| {
                var entry = std.mem.trim(u8, raw, " \t\r\n");
                if (entry.len == 0) continue;
                // Strip alias:  `useTransition as ut`  →  `useTransition`
                if (std.mem.indexOf(u8, entry, " as ")) |as_pos| {
                    entry = entry[0..as_pos];
                }
                entry = std.mem.trim(u8, entry, " \t");
                if (!isIdent(entry)) continue;
                try names.append(gpa, entry); // slice into src — no dupe
            }
        }

        const owned_names = try names.toOwnedSlice(gpa);
        errdefer gpa.free(owned_names);
        try stmts.append(gpa, .{
            .specifier = pq.text,
            .names = owned_names,
        });
    }

    return stmts.toOwnedSlice(gpa);
}

/// The "Capabilities & gaps" section (§5) of the generated `MIGRATION.md`.
///
/// Lives here, in the unit-tested module, with a drift guard (below) so it can't
/// fall out of sync with docs/migration/astro-to-zigapagos.md by re-listing a
/// shipped host binding as an unsupported gap — the F3 bug, where the generated
/// worklist wrongly told migrators that matchMedia, scroll/resize listeners,
/// portals, third-party widgets, and client flags/experiments couldn't be built.
/// The list of shipped capabilities below mirrors that doc's "Now supported".
pub const capabilities_section =
    \\
    \\## 5. Capabilities & gaps (see the mapping reference)
    \\
    \\- [ ] Supported: dynamic props (`$page.title`) incl. structured data via
    \\      `$expr.toJson()`, site-wide global data (`$site.data('name')`),
    \\      named slots, nested islands in slot content, cross-island state
    \\      (i64 + string stores), client input glue, client `setTimeout`,
    \\      `fetch` (GET) and `host.fetchOpts(req)` (method/headers/body +
    \\      `{status,headers,body}` envelope), `host.fetchShared(url, store)`,
    \\      the synchronous clock (`host.now()` / `host.localDateParts()`),
    \\      cookies (`host.cookies.get(name)` / `host.cookies.set(name, v, opts)`),
    \\      location path (`host.pathname()`), error reporting
    \\      (`host.reportError(msg)`), global event subscriptions
    \\      (`host.onScroll(cb)` / `host.onResize(cb)` / `host.matchMedia(q, cb)`),
    \\      portals (`host.portal(selector)` or `createPortal` from `@z/runtime`),
    \\      the scoped DOM enhancer (`host.enhance.setText` / `setHtml` /
    \\      `setStyle` / `addClass` / `removeClass` / `toggleClass`),
    \\      third-party widgets (`host.loadScript(url)` / `host.getValue(id)`),
    \\      feature flags (`useFlag(name)` / `<FeatureFlag name>`), and A/B
    \\      experiments (`useVariant(name)` / `<Experiment name variant>`).
    \\- [ ] Gaps (use workarounds): dynamic routes `[slug]`, stores beyond
    \\      i64/string, streaming (incremental) fetch bodies, `window.location`
    \\      beyond the path (query/hash), client-side routing / History API,
    \\      arbitrary cross-root `document.querySelector` DOM access (coordinate
    \\      via a shared store, a portal, or the scoped enhancer), an implicit
    \\      React-style context provider tree (use shared flags + cookies/props).
    \\      See the "Gaps" section of docs/migration/astro-to-zigapagos.md for
    \\      each workaround.
    \\
;

// ---------------------------------------------------------------------------
// Port analysis — structs, lookup tables, and analyze().
// ---------------------------------------------------------------------------

pub const HookFinding = struct { name: []const u8, supported: bool, note: []const u8 };
pub const HostNeed = struct { smell: []const u8, binding: []const u8 };
pub const SharedMap = struct { symbol: []const u8, target: []const u8 };
pub const ImportFinding = struct { specifier: []const u8, class: ImportClass, suggested: []const u8 };
pub const PortReport = struct {
    component: []const u8,
    has_default_export: bool,
    hooks: []HookFinding,
    host_needs: []HostNeed,
    imports: []ImportFinding,
    shared: []SharedMap,
    pub fn violations(self: PortReport) usize {
        var n: usize = 0;
        for (self.imports) |im| if (im.class == .forbidden_npm) {
            n += 1;
        };
        return n;
    }
};

/// Mirrors the hook/JSX names exported by runtime/src/index.ts (drift-guarded).
pub const supported_hooks = [_][]const u8{
    "useState",            "useEffect",  "useLayoutEffect",      "useRef",        "useMemo",      "useCallback",
    "useReducer",          "useContext", "useSyncExternalStore", "createContext", "createPortal", "forwardRef",
    "useImperativeHandle", "h",          "Fragment",
};

/// Source substring → host.* binding. Heuristic + advisory; does NOT gate exit.
const HostSmell = struct { pat: []const u8, binding: []const u8 };
const host_smells = [_]HostSmell{
    .{ .pat = "window.matchMedia(", .binding = "host.matchMedia(query, cb)" },
    .{ .pat = "addEventListener(\"scroll\"", .binding = "host.onScroll(cb)" },
    .{ .pat = "window.scrollY", .binding = "host.onScroll(cb)" },
    .{ .pat = "addEventListener(\"resize\"", .binding = "host.onResize(cb)" },
    .{ .pat = "window.innerWidth", .binding = "host.onResize(cb)" },
    .{ .pat = "document.cookie", .binding = "host.cookies.get/set(name, \u{2026})" },
    .{ .pat = "Date.now()", .binding = "host.now()" },
    .{ .pat = "new Date(", .binding = "host.localDateParts()" },
    .{ .pat = "document.querySelector", .binding = "host.portal(selector) / host.enhance.*" },
    .{ .pat = "fetch(", .binding = "host.fetchOpts(req) or host.fetchShared(url, store)" },
    .{ .pat = "grecaptcha", .binding = "@z/runtime/compat ReCAPTCHA (host.loadScript under the hood)" },
    .{ .pat = "console.error", .binding = "host.reportError(err)" },
};

/// @legacy-app/shared symbol → shim target (points at the compat shims).
const shared_map = [_]SharedMap{
    .{ .symbol = "FlagsProvider", .target = "@z/runtime/compat (FlagsProvider)" },
    .{ .symbol = "FeatureFlag", .target = "@z/runtime (FeatureFlag)" },
    .{ .symbol = "Experiment", .target = "@z/runtime (Experiment)" },
    .{ .symbol = "useFlag", .target = "@z/runtime (useFlag)" },
    .{ .symbol = "useVariant", .target = "@z/runtime (useVariant) / @z/runtime/compat (useExperiment)" },
    .{ .symbol = "useCustomer", .target = "@your-org/shared-lite (makeSharedResource over host.fetchShared)" },
    .{ .symbol = "Recaptcha", .target = "@z/runtime/compat (ReCAPTCHA)" },
};

/// Known forbidden-npm → shim suggestion (so the doctor still points the way).
const forbidden_shim = [_]struct { spec: []const u8, target: []const u8 }{
    .{ .spec = "react-google-recaptcha", .target = "@z/runtime/compat (ReCAPTCHA)" },
};

/// Analyse a single React/Astro component source and return a `PortReport`
/// describing hooks, host-binding needs, import classes, and @legacy-app/shared
/// symbol mappings.
///
/// NO_SLOP.md §2.2a contract 4 — **caller must pass an arena.** The report's
/// four slices borrow their strings from `extractImports`'s `imps` slice and its
/// per-statement `names` sub-arrays, which are never freed here: an interlinked
/// graph with no `deinit` (1) whose pieces cannot be freed individually without
/// invalidating the report that points into them (2), and which dies with the
/// `zigapagos migrate doctor` run that requested it (3). A general-purpose
/// allocator without a wrapping arena leaks every `extractImports` allocation.
///
/// This is the one genuine contract-4 site in the tree that does NOT carry the
/// `RenderArena` marker type, and the reason is mechanical, not a judgment:
/// `src/cli/migrate_detect.zig` is the ROOT source file of its own test module
/// (`zig build test-migrate`), and Zig 0.16 refuses an import that escapes a
/// module's directory — so it cannot reach `src/islands/render_arena.zig`.
/// Adopting the type here needs a one-line build/tests.zig change (pass the type as a
/// module import to `migrate_tests`), which is deliberately not made here.
pub fn analyze(gpa: Allocator, component: []const u8, src: []const u8) !PortReport {
    const imps = try extractImports(gpa, src);
    var hooks: std.ArrayListUnmanaged(HookFinding) = .empty;
    var host_needs_out: std.ArrayListUnmanaged(HostNeed) = .empty;
    var imports_out: std.ArrayListUnmanaged(ImportFinding) = .empty;
    var shared_out: std.ArrayListUnmanaged(SharedMap) = .empty;

    for (imps) |im| {
        const cls = classifyImport(im.specifier);
        var suggested: []const u8 = "";
        switch (cls) {
            .react_rewrite => suggested = "@z/runtime",
            .forbidden_npm => for (forbidden_shim) |fs| {
                if (std.mem.eql(u8, fs.spec, im.specifier)) {
                    suggested = fs.target;
                    break;
                }
            },
            else => {},
        }
        try imports_out.append(gpa, .{ .specifier = im.specifier, .class = cls, .suggested = suggested });
        // hooks: named imports from a react_rewrite specifier → check support
        if (cls == .react_rewrite) for (im.names) |nm| {
            const ok = isSupportedHook(nm);
            try hooks.append(gpa, .{ .name = nm, .supported = ok, .note = if (ok) "import-swap" else "no @z/runtime equivalent — rework" });
        };
        // shared symbols from @legacy-app/* imports
        if (cls == .legacy_shared_map) for (im.names) |nm| {
            const tgt = sharedTargetFor(nm) orelse "map to @your-org/shared-lite or a host.* binding (unmapped — confirm)";
            try shared_out.append(gpa, .{ .symbol = nm, .target = tgt });
        };
    }
    for (host_smells) |hs| if (std.mem.indexOf(u8, src, hs.pat) != null) {
        try host_needs_out.append(gpa, .{ .smell = hs.pat, .binding = hs.binding });
    };
    return .{
        .component = component,
        .has_default_export = std.mem.indexOf(u8, src, "export default") != null,
        .hooks = try hooks.toOwnedSlice(gpa),
        .host_needs = try host_needs_out.toOwnedSlice(gpa),
        .imports = try imports_out.toOwnedSlice(gpa),
        .shared = try shared_out.toOwnedSlice(gpa),
    };
}

// ---------------------------------------------------------------------------
// Renderers — human checklist + JSON (port-doctor output).
// ---------------------------------------------------------------------------

/// Emit a human-readable Markdown checklist for the port doctor to any writer.
/// The writer is `anytype` (same pattern as `buildWiringSection` etc. in
/// migrate.zig).
///
/// Every write is propagated: the production caller (`migrate.zig`'s `doctor`)
/// renders to a *file* writer on stdout, where a write can fail with EPIPE
/// (`… | head -1`), ENOSPC or EIO. Swallowing those would emit a truncated
/// report and still exit 0 — a false clean. The caller must report the failure
/// and exit non-zero.
pub fn renderDoctorHuman(w: anytype, rep: PortReport) !void {
    try w.print("# Port doctor: {s}\n\n", .{rep.component});
    try w.print("Source: {s} default export.\n\n", .{
        if (rep.has_default_export) "has" else "no",
    });

    try w.writeAll("## Hooks (→ @z/runtime)\n\n");
    for (rep.hooks) |hf| {
        if (hf.supported) {
            try w.print("- [x] {s}  {s}\n", .{ hf.name, hf.note });
        } else {
            try w.print("- [ ] {s}  {s}\n", .{ hf.name, hf.note });
        }
    }

    try w.writeAll("\n## Host bindings you'll need\n\n");
    for (rep.host_needs) |hn| {
        try w.print("- [ ] {s}  → {s}\n", .{ hn.smell, hn.binding });
    }

    try w.writeAll("\n## Imports (no-npm guardrail)\n\n");
    for (rep.imports) |im| {
        switch (im.class) {
            .forbidden_npm => try w.print("- [ ] {s}  FORBIDDEN — {s}\n", .{ im.specifier, im.suggested }),
            .react_rewrite => try w.print("- [x] {s}  → rewrite to \"@z/runtime\"\n", .{im.specifier}),
            else => try w.print("- [x] {s}  OK\n", .{im.specifier}),
        }
    }

    try w.writeAll("\n## @legacy-app/shared symbols\n\n");
    for (rep.shared) |sm| {
        try w.print("- [ ] {s}  → {s}\n", .{ sm.symbol, sm.target });
    }

    const n = rep.violations();
    try w.print("\n{d} guardrail violation(s). See docs/migration/recipes.md (no-npm-guardrail).\n", .{n});
}

/// Emit a JSON object describing the port report. Uses `writeJsonString` for
/// every string value and `@tagName(class)` for the `ImportClass` field.
///
/// Every write is propagated (same rationale as `renderDoctorHuman`): a
/// swallowed write error here would hand downstream tooling a truncated,
/// unparseable JSON document under a successful exit status.
pub fn renderDoctorJson(w: anytype, rep: PortReport) !void {
    try w.writeAll("{\n");
    try w.writeAll("  \"component\": ");
    try writeJsonString(w, rep.component);
    try w.writeAll(",\n");
    try w.print("  \"hasDefaultExport\": {s},\n", .{if (rep.has_default_export) "true" else "false"});

    // hooks array
    try w.writeAll("  \"hooks\": [\n");
    for (rep.hooks, 0..) |hf, i| {
        try w.writeAll("    {\"name\": ");
        try writeJsonString(w, hf.name);
        try w.print(", \"supported\": {s}, \"note\": ", .{if (hf.supported) "true" else "false"});
        try writeJsonString(w, hf.note);
        try w.writeAll("}");
        if (i + 1 < rep.hooks.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ],\n");

    // hostNeeds array
    try w.writeAll("  \"hostNeeds\": [\n");
    for (rep.host_needs, 0..) |hn, i| {
        try w.writeAll("    {\"smell\": ");
        try writeJsonString(w, hn.smell);
        try w.writeAll(", \"binding\": ");
        try writeJsonString(w, hn.binding);
        try w.writeAll("}");
        if (i + 1 < rep.host_needs.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ],\n");

    // imports array
    try w.writeAll("  \"imports\": [\n");
    for (rep.imports, 0..) |im, i| {
        try w.writeAll("    {\"specifier\": ");
        try writeJsonString(w, im.specifier);
        try w.writeAll(", \"class\": ");
        try writeJsonString(w, @tagName(im.class));
        try w.writeAll(", \"suggested\": ");
        try writeJsonString(w, im.suggested);
        try w.writeAll("}");
        if (i + 1 < rep.imports.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ],\n");

    // shared array
    try w.writeAll("  \"shared\": [\n");
    for (rep.shared, 0..) |sm, i| {
        try w.writeAll("    {\"symbol\": ");
        try writeJsonString(w, sm.symbol);
        try w.writeAll(", \"target\": ");
        try writeJsonString(w, sm.target);
        try w.writeAll("}");
        if (i + 1 < rep.shared.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ],\n");

    try w.print("  \"guardrailViolations\": {d}\n", .{rep.violations()});
    try w.writeAll("}\n");
}

/// Write a JSON-quoted string to `w`, escaping `"` → `\"`, `\` → `\\`, and
/// control characters (`\n`, `\t`, `\r`, others < 0x20 → `\u00XX`).
/// Write errors propagate — see `renderDoctorJson`.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            else => if (c < 0x20) {
                try w.print("\\u{X:0>4}", .{c});
            } else {
                try w.writeByte(c);
            },
        }
    }
    try w.writeAll("\"");
}

fn isSupportedHook(name: []const u8) bool {
    for (supported_hooks) |h| if (std.mem.eql(u8, h, name)) return true;
    return false;
}

fn sharedTargetFor(symbol: []const u8) ?[]const u8 {
    for (shared_map) |m| if (std.mem.eql(u8, m.symbol, symbol)) return m.target;
    return null;
}

// ===========================================================================
// Tests — drive the cases a real Astro marketing site hits.
// ===========================================================================

const testing = std.testing;

test "capabilities section: shipped host bindings are listed Supported, not as gaps" {
    const sec = capabilities_section;
    const supported_start = std.mem.indexOf(u8, sec, "Supported:").?;
    const gaps_start = std.mem.indexOf(u8, sec, "Gaps (use workarounds):").?;
    const supported = sec[supported_start..gaps_start];
    const gaps = sec[gaps_start..];

    // These all ship as host bindings — they must appear under Supported and must
    // NOT appear under Gaps (the F3 contradiction the migrate tool used to emit).
    const shipped = [_][]const u8{
        "matchMedia",  "onScroll",   "host.portal",  "loadScript",
        "fetchShared", "useVariant", "host.cookies",
    };
    for (shipped) |cap| {
        try testing.expect(std.mem.indexOf(u8, supported, cap) != null);
        try testing.expect(std.mem.indexOf(u8, gaps, cap) == null);
    }

    // And a couple of genuine gaps must still be listed as gaps.
    try testing.expect(std.mem.indexOf(u8, gaps, "[slug]") != null);
    try testing.expect(std.mem.indexOf(u8, gaps, "streaming") != null);
}

test "island detection: only components used with client:* are islands" {
    const gpa = testing.allocator;
    var set: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        set.deinit(gpa);
    }

    // A page that hydrates ContactForm and Counter, and statically uses Footer.
    const page =
        \\---
        \\import ContactForm from "../components/ContactForm.tsx";
        \\import Counter from "../components/Counter.jsx";
        \\import Footer from "../components/Footer.astro";
        \\---
        \\<main>
        \\  <Counter client:visible start={0} />
        \\  <ContactForm client:load endpoint="/api" />
        \\  <Footer site={site} />
        \\</main>
    ;
    try collectClientUsages(gpa, page, &set);

    // ContactForm + Counter are islands; Footer (no client:*) is not.
    try testing.expect(set.contains("ContactForm"));
    try testing.expect(set.contains("Counter"));
    try testing.expect(!set.contains("Footer"));
    // Recaptcha is a transitive child of ContactForm, never used with a
    // directive, so it never appears here.
    try testing.expect(!set.contains("Recaptcha"));
    try testing.expectEqual(@as(usize, 2), set.count());

    // Roles fall out of the set + extension.
    try testing.expectEqual(Role.island, componentRole("src/components/ContactForm.tsx", &set));
    try testing.expectEqual(Role.island, componentRole("src/components/Counter.jsx", &set));
    try testing.expectEqual(Role.partial, componentRole("src/components/Footer.astro", &set));
    try testing.expectEqual(Role.plain, componentRole("src/components/Recaptcha.tsx", &set));
}

test "island detection ignores lowercase html elements and directives in markup" {
    const gpa = testing.allocator;
    var set: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        set.deinit(gpa);
    }
    // `client:` on a lowercase element (not a thing in Astro, but be robust)
    // must not register an island.
    const src = "<div client:load></div><Widget client:idle />";
    try collectClientUsages(gpa, src, &set);
    try testing.expect(set.contains("Widget"));
    try testing.expect(!set.contains("div"));
    try testing.expectEqual(@as(usize, 1), set.count());
}

test "props inference: field names and TS types are preserved" {
    const gpa = testing.allocator;
    // Component with a string scalar and a callback prop — both fields are kept,
    // with their raw TypeScript types, for verbatim re-emission in the TSX skeleton.
    const src =
        \\interface Props {
        \\  siteKey: string;
        \\  onChange: (token: string) => void;
        \\}
    ;
    const props = try inferProps(gpa, src);
    defer freeProps(gpa, props);
    try testing.expectEqual(@as(usize, 2), props.len);

    try testing.expectEqualStrings("siteKey", props[0].name);
    try testing.expectEqualStrings("string", props[0].ts_type);

    try testing.expectEqualStrings("onChange", props[1].name);
    try testing.expectEqualStrings("(token: string) => void", props[1].ts_type);
}

test "props inference: object and primitive TS types" {
    const gpa = testing.allocator;
    const src = "interface Props { site: Site; year: number }";
    const props = try inferProps(gpa, src);
    defer freeProps(gpa, props);
    try testing.expectEqual(@as(usize, 2), props.len);

    try testing.expectEqualStrings("site", props[0].name);
    try testing.expectEqualStrings("Site", props[0].ts_type);

    try testing.expectEqualStrings("year", props[1].name);
    try testing.expectEqualStrings("number", props[1].ts_type);
}

test "props inference: single-line interface and destructuring fallback" {
    const gpa = testing.allocator;
    {
        const props = try inferProps(gpa, "interface Props { count: number; label: string }");
        defer freeProps(gpa, props);
        try testing.expectEqual(@as(usize, 2), props.len);
        try testing.expectEqualStrings("count", props[0].name);
        try testing.expectEqualStrings("number", props[0].ts_type);
        try testing.expectEqualStrings("label", props[1].name);
        try testing.expectEqualStrings("string", props[1].ts_type);
    }
    {
        // No interface → destructuring fallback, names only (no type info).
        const props = try inferProps(gpa, "const { name, greeting } = Astro.props;");
        defer freeProps(gpa, props);
        try testing.expectEqual(@as(usize, 2), props.len);
        try testing.expectEqualStrings("name", props[0].name);
        try testing.expectEqualStrings("", props[0].ts_type);
        try testing.expectEqualStrings("greeting", props[1].name);
        try testing.expectEqualStrings("", props[1].ts_type);
    }
}

test "findPropsSpan: returns verbatim interface text" {
    const src =
        \\import { useState } from "@z/runtime";
        \\export interface Props {
        \\  headline: string;
        \\  count: number;
        \\}
        \\export default function Hero({ headline }: Props) {}
    ;
    const span = findPropsSpan(src).?;
    try testing.expect(std.mem.startsWith(u8, span, "interface Props"));
    try testing.expect(std.mem.endsWith(u8, span, "}"));
    try testing.expect(std.mem.indexOf(u8, span, "headline: string") != null);
    try testing.expect(std.mem.indexOf(u8, span, "count: number") != null);
}

fn freeProps(gpa: Allocator, props: []PropField) void {
    for (props) |p| {
        gpa.free(p.name);
        if (p.ts_type.len > 0) gpa.free(p.ts_type);
    }
    gpa.free(props);
}

/// Free the arrays allocated by `extractImports`. Specifier and name strings
/// are slices into the original `src` buffer and are NOT freed here.
pub fn freeImports(gpa: Allocator, imps: []ImportStmt) void {
    for (imps) |imp| {
        gpa.free(imp.names); // free the per-statement names sub-array
    }
    gpa.free(imps);
}

const AllocationFailureChecks = struct {
    fn inferPropsCheck(gpa: Allocator) !void {
        const props = try inferProps(gpa,
            \\interface Props {
            \\  title: string;
            \\  count: number;
            \\  options: { active: boolean; label: string };
            \\}
        );
        defer freeProps(gpa, props);
    }

    fn destructuringCheck(gpa: Allocator) !void {
        const props = try inferProps(gpa, "const { title, count, options } = Astro.props;");
        defer freeProps(gpa, props);
    }

    fn importsCheck(gpa: Allocator) !void {
        const imports = try extractImports(gpa,
            \\import React, { useState, useEffect } from "react";
            \\import { signal, computed, effect } from "@z/runtime";
            \\import "./styles.css";
        );
        defer freeImports(gpa, imports);
    }
};

test "allocator failures: owned migrate parser results leak nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, AllocationFailureChecks.inferPropsCheck, .{});
    try testing.checkAllAllocationFailures(testing.allocator, AllocationFailureChecks.destructuringCheck, .{});
    try testing.checkAllAllocationFailures(testing.allocator, AllocationFailureChecks.importsCheck, .{});
}

test "classifyImport: migrate scaffolder classes (base arms mirror lint BASE_ALLOW)" {
    // runtime_ok + relative_ok are the shared contract with the lint's BASE_ALLOW;
    // the remaining classes are migrate-only advisory recipes (see classifyImport doc).
    try testing.expectEqual(ImportClass.relative_ok, classifyImport("./lib/x"));
    try testing.expectEqual(ImportClass.relative_ok, classifyImport("../a"));
    try testing.expectEqual(ImportClass.runtime_ok, classifyImport("@z/runtime"));
    try testing.expectEqual(ImportClass.runtime_ok, classifyImport("@z/runtime/compat"));
    try testing.expectEqual(ImportClass.first_party_ok, classifyImport("@your-org/shared-lite/customer"));
    try testing.expectEqual(ImportClass.react_rewrite, classifyImport("react"));
    try testing.expectEqual(ImportClass.react_rewrite, classifyImport("react-dom/client"));
    try testing.expectEqual(ImportClass.react_rewrite, classifyImport("react/jsx-runtime"));
    try testing.expectEqual(ImportClass.react_rewrite, classifyImport("react/jsx-dev-runtime"));
    try testing.expectEqual(ImportClass.legacy_shared_map, classifyImport("@legacy-app/shared/flags"));
    try testing.expectEqual(ImportClass.forbidden_npm, classifyImport("react-google-recaptcha"));
    try testing.expectEqual(ImportClass.forbidden_npm, classifyImport("lodash"));
}

test "classifyImport base allowed-set is pinned to lint-island-imports.ts BASE_ALLOW" {
    // Drift guard: the TS lint's BASE_ALLOW must still cover the shared base classes
    // (runtime + relative). @your-org/shared-lite is NO LONGER a lint concern — it was
    // removed from the hardcoded allowlist (extra scopes are now project config in
    // z-runtime.config.json); it survives here only as a migrate-only advisory recipe.
    // (@embedFile is rejected across module boundaries; cwd = repo root under `zig build`.)
    const lint = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        std.testing.io,
        "runtime/scripts/lint-island-imports.ts",
        testing.allocator,
        std.Io.Limit.limited(64 * 1024),
    );
    defer testing.allocator.free(lint);
    try testing.expect(std.mem.indexOf(u8, lint, "@z\\/runtime") != null);
    try testing.expect(std.mem.indexOf(u8, lint, "\\.\\.?\\/") != null); // the relative pattern
    // The hardcoded first-party scope must be GONE from the lint (now project config).
    try testing.expect(std.mem.indexOf(u8, lint, "@your-org\\/shared-lite") == null);
}

test "extractImports: single-line, multi-line, default, namespace, side-effect" {
    const gpa = testing.allocator;
    const src =
        \\import { useState, useRef } from "react";
        \\import {
        \\  useId,
        \\  useTransition as ut,
        \\} from "react";
        \\import ReCAPTCHA from "react-google-recaptcha";
        \\import * as React from "react";
        \\import "./styles.css";
        \\import { FlagsProvider } from "@legacy-app/shared/flags";
    ;
    const imps = try extractImports(gpa, src);
    defer freeImports(gpa, imps);
    // 6 import statements
    try testing.expectEqual(@as(usize, 6), imps.len);
    // line 1: react with useState, useRef
    try testing.expectEqualStrings("react", imps[0].specifier);
    try testing.expectEqual(@as(usize, 2), imps[0].names.len);
    try testing.expectEqualStrings("useState", imps[0].names[0]);
    // line 2 (multi-line): react with useId, useTransition (alias stripped)
    try testing.expectEqualStrings("react", imps[1].specifier);
    try testing.expectEqualStrings("useId", imps[1].names[0]);
    try testing.expectEqualStrings("useTransition", imps[1].names[1]);
    // default import: no named symbols
    try testing.expectEqualStrings("react-google-recaptcha", imps[2].specifier);
    try testing.expectEqual(@as(usize, 0), imps[2].names.len);
    // namespace import: no named symbols
    try testing.expectEqualStrings("react", imps[3].specifier);
    try testing.expectEqual(@as(usize, 0), imps[3].names.len);
    // side-effect import
    try testing.expectEqualStrings("./styles.css", imps[4].specifier);
    // legacy-app named
    try testing.expectEqualStrings("@legacy-app/shared/flags", imps[5].specifier);
    try testing.expectEqualStrings("FlagsProvider", imps[5].names[0]);
}

test "extractImports: combined default+named import keeps the named symbols" {
    const gpa = testing.allocator;
    const imps = try extractImports(gpa, "import React, { useState, useEffect } from \"react\";");
    defer freeImports(gpa, imps);
    try testing.expectEqual(@as(usize, 1), imps.len);
    try testing.expectEqualStrings("react", imps[0].specifier);
    try testing.expectEqual(@as(usize, 2), imps[0].names.len);
    try testing.expectEqualStrings("useState", imps[0].names[0]);
    try testing.expectEqualStrings("useEffect", imps[0].names[1]);
}

test "extractImports: a commented-out import is ignored" {
    const gpa = testing.allocator;
    const imps = try extractImports(gpa, "// import useState from \"react\"\nimport { useRef } from \"react\";");
    defer freeImports(gpa, imps);
    try testing.expectEqual(@as(usize, 1), imps.len);
    try testing.expectEqualStrings("useRef", imps[0].names[0]);
}

test "extractImports: dynamic import() is captured (specifier, no names)" {
    const gpa = testing.allocator;
    const imps = try extractImports(gpa, "const m = await import(\"lodash\");\nimport { useState } from \"react\";");
    defer freeImports(gpa, imps);
    try testing.expectEqual(@as(usize, 2), imps.len);
    try testing.expectEqualStrings("lodash", imps[0].specifier);
    try testing.expectEqual(@as(usize, 0), imps[0].names.len);
    try testing.expectEqualStrings("react", imps[1].specifier);
}

// ---------------------------------------------------------------------------
// Test helpers for PortReport assertions.
// ---------------------------------------------------------------------------

fn hookSupported(rep: PortReport, name: []const u8) bool {
    for (rep.hooks) |hf| if (std.mem.eql(u8, hf.name, name)) return hf.supported;
    return false;
}

fn hasHostSmell(rep: PortReport, pat: []const u8) bool {
    for (rep.host_needs) |hn| if (std.mem.indexOf(u8, hn.smell, pat) != null) return true;
    return false;
}

fn importClassIs(rep: PortReport, spec: []const u8, cls: ImportClass) bool {
    for (rep.imports) |im| if (std.mem.eql(u8, im.specifier, spec)) return im.class == cls;
    return false;
}

fn importSuggested(rep: PortReport, spec: []const u8) []const u8 {
    for (rep.imports) |im| if (std.mem.eql(u8, im.specifier, spec)) return im.suggested;
    return "";
}

fn sharedTarget(rep: PortReport, symbol: []const u8) []const u8 {
    for (rep.shared) |sm| if (std.mem.eql(u8, sm.symbol, symbol)) return sm.target;
    return "";
}

test "analyze: ContactForm-shaped component — hooks, host needs, imports, shared" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\import { useState, useId } from "react";
        \\import ReCAPTCHA from "react-google-recaptcha";
        \\import { FlagsProvider, useCustomer } from "@legacy-app/shared/flags";
        \\export default function ContactForm() {
        \\  const r = await fetch("/api/contact");
        \\  if (window.matchMedia("(max-width: 600px)").matches) {}
        \\  return <div />;
        \\}
    ;
    const rep = try analyze(a, "ContactForm", src);
    try testing.expectEqualStrings("ContactForm", rep.component);
    try testing.expect(rep.has_default_export);
    // hooks: useState supported, useId not
    try testing.expect(hookSupported(rep, "useState"));
    try testing.expect(!hookSupported(rep, "useId"));
    // host needs: fetch + matchMedia detected
    try testing.expect(hasHostSmell(rep, "fetch("));
    try testing.expect(hasHostSmell(rep, "matchMedia"));
    // imports: react→rewrite, react-google-recaptcha→forbidden with a shim suggestion
    try testing.expect(importClassIs(rep, "react-google-recaptcha", .forbidden_npm));
    try testing.expect(std.mem.indexOf(u8, importSuggested(rep, "react-google-recaptcha"), "@z/runtime/compat") != null);
    // shared: FlagsProvider + useCustomer mapped
    try testing.expect(std.mem.indexOf(u8, sharedTarget(rep, "FlagsProvider"), "@z/runtime/compat") != null);
    try testing.expect(std.mem.indexOf(u8, sharedTarget(rep, "useCustomer"), "@your-org/shared-lite") != null);
    // one guardrail violation (react-google-recaptcha)
    try testing.expectEqual(@as(usize, 1), rep.violations());
}

test "supported-hook set is pinned to runtime/src/index.ts" {
    // (@embedFile is rejected across module boundaries; cwd = repo root under `zig build`.)
    const index_ts = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        std.testing.io,
        "runtime/src/index.ts",
        testing.allocator,
        std.Io.Limit.limited(64 * 1024),
    );
    defer testing.allocator.free(index_ts);
    for (supported_hooks) |hook| {
        try testing.expect(std.mem.indexOf(u8, index_ts, hook) != null);
    }
}

test "renderDoctorHuman: checklist contains hooks, host needs, imports, violations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rep = try analyze(a, "ContactForm", "import { useState, useId } from \"react\";\nimport X from \"react-google-recaptcha\";\nexport default function ContactForm(){ fetch(\"/x\"); }");
    var aw: std.Io.Writer.Allocating = .init(a);
    try renderDoctorHuman(&aw.writer, rep);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Port doctor: ContactForm") != null);
    try testing.expect(std.mem.indexOf(u8, out, "useState") != null);
    try testing.expect(std.mem.indexOf(u8, out, "useId") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rework") != null); // useId unsupported
    try testing.expect(std.mem.indexOf(u8, out, "host.fetchOpts") != null); // fetch host-need
    try testing.expect(std.mem.indexOf(u8, out, "FORBIDDEN") != null);
    try testing.expect(std.mem.indexOf(u8, out, "@z/runtime/compat") != null); // recaptcha shim hint
    try testing.expect(std.mem.indexOf(u8, out, "1 guardrail violation") != null);
}

test "renderDoctorJson: valid-ish JSON with escaped strings + violation count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rep = try analyze(a, "ContactForm", "import X from \"react-google-recaptcha\";\nexport default function ContactForm(){}");
    var aw: std.Io.Writer.Allocating = .init(a);
    try renderDoctorJson(&aw.writer, rep);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"component\": \"ContactForm\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"guardrailViolations\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"class\": \"forbidden_npm\"") != null);
}

test "writeJsonString escapes quotes and backslashes" {
    // `writeJsonString` writes to a caller's writer and allocates nothing, so the
    // arena that used to wrap the testing allocator here was masking leak
    // detection for no reason (NO_SLOP.md §2.2a).
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeJsonString(&aw.writer, "a\"b\\c");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\"", aw.written());
}

// --- Regression: doctor renderers must not swallow stdout write failures ----
//
// `migrate.zig`'s `doctor` renders to a FILE writer on stdout, where a write
// can fail (EPIPE from `… | head -1`, ENOSPC, EIO). When these renderers
// swallowed errors with `catch {}` they emitted a truncated report — truncated
// JSON for downstream tooling — and the command still exited 0, i.e. "no
// guardrail violations found". Both renderers must surface the failure.
//
// `std.Io.Writer.failing` is the stdlib's always-fails sink: zero-length
// buffer, every drain returns `error.WriteFailed`.

test "renderDoctorJson propagates a write failure instead of emitting truncated JSON" {
    const rep: PortReport = .{
        .component = "ContactForm",
        .has_default_export = true,
        .hooks = &.{},
        .host_needs = &.{},
        .imports = &.{},
        .shared = &.{},
    };
    var fw: std.Io.Writer = .failing;
    try testing.expectError(error.WriteFailed, renderDoctorJson(&fw, rep));
}

test "renderDoctorHuman propagates a write failure instead of emitting a truncated checklist" {
    const rep: PortReport = .{
        .component = "ContactForm",
        .has_default_export = true,
        .hooks = &.{},
        .host_needs = &.{},
        .imports = &.{},
        .shared = &.{},
    };
    var fw: std.Io.Writer = .failing;
    try testing.expectError(error.WriteFailed, renderDoctorHuman(&fw, rep));
}

test "writeJsonString propagates a write failure" {
    var fw: std.Io.Writer = .failing;
    try testing.expectError(error.WriteFailed, writeJsonString(&fw, "abc"));
}
