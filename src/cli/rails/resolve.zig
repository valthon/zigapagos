//! Pure lookups shared by Stage 2's converter (`convert.zig`) and scaffolder
//! (`scaffold.zig`): a Rails route helper -> the URL it builds, a Rails asset
//! helper -> the manifest asset it names, and the target-tree paths a route,
//! a view and a layout each become.
//!
//! Everything here is a total function of its arguments -- no filesystem, no
//! subprocess, no ambient state -- so the converter's output stays
//! byte-identical for identical input (plan, Global Constraints) without
//! either caller having to think about ordering. That is also why the two
//! "pick one of several candidates" rules below (`routeUrl`'s verb
//! preference, `assetFor`'s root/extension order) are written as a fixed
//! total order rather than "first match in slice order": the discovery
//! stage's route and asset slices are built by a directory walk and a Ruby
//! sidecar, and neither promises a stable order across machines.
//!
//! std-only, like every file in `src/cli/rails/`. Nothing here fatals; a
//! lookup that cannot be answered returns `null` so the caller can raise its
//! own finding with the context this file does not have.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assets = @import("assets.zig");
const classify = @import("classify.zig");
const controllers = @import("controllers.zig");
const routes = @import("routes.zig");

// ---- route helpers -------------------------------------------------------

/// A route path segment that stands for a value rather than matching itself:
/// `:id` (one segment) or `*path` (the rest of the path). Both are filled
/// from `routeUrl`'s literal args, in order.
fn isPlaceholder(segment: []const u8) bool {
    return segment.len > 1 and (segment[0] == ':' or segment[0] == '*');
}

/// Rails' route DSL has pattern syntax this stage does not interpret --
/// the optional-group form `(.:format)` being the one a reader will expect
/// here. Stage 1's `routes.rb` never emits it (its `emit` writes the bare
/// joined path), so this is defence for hand-built `Route` literals and for
/// a future `Origin` producer (`.actiondispatch` reads Rails' OWN route set,
/// where `(.:format)` IS present), not a case observed on the wire.
///
/// Pasting such a segment through would produce a URL and a content path
/// that look plausible and are wrong -- `content/about(.:format)/index.smd`
/// -- which is exactly the failure mode `assets.zig`'s header argues
/// against. Refusing the route instead leaves the caller a finding to
/// report.
fn isUninterpretable(segment: []const u8) bool {
    return std.mem.indexOfAny(u8, segment, "()") != null;
}

/// Strips a route path's trailing slash so `/about/` and `/about` produce the
/// same URL and the same content path. `/` is the one path whose slash IS the
/// path and is returned unchanged. Contract 3 (caller-buffer): returns a
/// sub-slice of `path`.
fn trimTrailingSlash(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

/// Iterates a route path's segments. `/admin/users` yields `admin`, `users`;
/// `/` yields nothing (one empty segment, which every caller skips).
///
/// Empty segments are the iterator's way of reporting adjacent slashes, and
/// every caller skips them -- so an internal `//` COLLAPSES: `/a//b` is read
/// as `/a/b`. That is the right reading for a URL path (an empty segment
/// addresses nothing), and Rails' own `join` in `routes.rb` already squeezes
/// runs of slashes before a path is emitted, so it is not a case this stage
/// sees on the wire. It is stated because collapsing is a silent
/// normalisation, not an error, and a reader tracking down "why did my path
/// change" should find the answer here.
fn segments(path: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, trimTrailingSlash(path), '/');
}

/// RFC 3986 section 2.3: the characters that never need escaping in a URI.
fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Percent-encodes `value` into `out` per RFC 3986: unreserved bytes verbatim,
/// every other byte as `%XX` with UPPERCASE hex (section 6.2.2.1 -- uppercase
/// is the normalised form, so two runs of this converter that encode the same
/// literal produce the same bytes, which the plan's byte-identical-output
/// constraint needs).
///
/// `keep_slash` is set only for a `*glob` placeholder, whose whole point is to
/// match a multi-segment remainder: `files_path("a dir/b.txt")` must build
/// `/files/a%20dir/b.txt`, encoding each component but leaving the separators
/// that make it a path. For a `:param` a slash is data, not a separator, and
/// is encoded (`%2F`) so a value containing one cannot silently invent a
/// segment the route never had.
///
/// Nothing is decoded first: a literal is what the Rails template author
/// wrote, not a URL, so `50%` encodes to `50%25` rather than being mistaken
/// for a truncated escape. Encoding is therefore deliberately NOT idempotent,
/// which is what makes an accidental double-encode visible instead of silently
/// correct-looking.
///
/// Contract 2 (owned-result), applied to a caller-owned collection:
/// everything allocated here is appended into `out`, which the caller already
/// owns and releases with `out.deinit(gpa)`. Nothing escapes separately.
fn appendPercentEncoded(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
    keep_slash: bool,
) Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (isUnreserved(c) or (keep_slash and c == '/')) {
            try out.append(gpa, c);
        } else {
            try out.appendSlice(gpa, &[_]u8{ '%', hex[c >> 4], hex[c & 0x0f] });
        }
    }
}

/// Route helper stem + literal args -> the URL that helper builds.
/// `posts` -> `/posts`; `post` + `{"1"}` -> `/posts/1` (each literal fills
/// the next placeholder segment, in order); `root` -> `/`.
///
/// Each literal arg is percent-encoded as it is spliced in (RFC 3986: the
/// unreserved set `A-Za-z0-9-._~` verbatim, every other byte as uppercase
/// `%XX`), so `a b` -> `a%20b`, `x/y` -> `x%2Fy` and `50%` -> `50%25`. An
/// arg reaches here as whatever the Rails template author wrote -- a slug, a
/// title, an interpolation this stage read as a literal -- and splicing it
/// raw would let a slash invent a path segment the route never had, or a
/// stray `%` emit a URL no browser can parse, with nothing in the output
/// looking wrong. A `*glob` arg keeps its slashes and encodes each component
/// (see `appendPercentEncoded`), because matching a multi-segment remainder
/// is exactly what a glob is for.
///
/// Only routes with `certain == true` and a non-null `name` participate: an
/// uncertain route is one `routes.rb` found through a construct it could not
/// fully evaluate and is explicitly not vouching for (`Route.certain`'s doc),
/// so building a URL from its path would be a guess dressed as a fact.
///
/// Returns `null` when no route carries `stem` as its name, when every route
/// that does has a placeholder count different from `args.len`, or when the
/// matched path contains syntax this stage does not interpret (see
/// `isUninterpretable`). Arity is a FILTER, not a post-check, so a name
/// shared by routes of differing arity still resolves for the arity the
/// caller supplied.
///
/// Among the routes that survive that filter, a `GET` one wins. The usual
/// duplicate is harmless -- `resources :posts` names both `GET /posts`
/// (index) and `POST /posts` (create) "posts", one path, so either
/// candidate yields the same bytes. The rule exists for the case that is
/// NOT harmless: this stage recovers routes by reading `config/routes.rb`
/// statically, and a file can pair `resources :posts` with an explicit
/// `get "/blog", as: :posts` -- a duplicate Rails itself would reject at
/// boot, but one the static walk faithfully reports as two certain routes
/// with two different paths. Left to slice order, the URL spliced into the
/// converted page would then depend on the sidecar's emission order.
/// Preferring `GET` picks the route a link is actually asking for, and
/// picks it the same way on every machine.
///
/// Contract 1 (self-freeing): all scratch is released; the returned URL is
/// the only allocation that escapes and is the caller's to free.
pub fn routeUrl(
    gpa: Allocator,
    all: []const routes.Route,
    stem: []const u8,
    args: []const []const u8,
) Allocator.Error!?[]const u8 {
    var best: ?routes.Route = null;
    for (all) |route| {
        if (!route.certain) continue;
        const name = route.name orelse continue;
        if (!std.mem.eql(u8, name, stem)) continue;

        var placeholders: usize = 0;
        var bad = false;
        var it = segments(route.path);
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (isUninterpretable(seg)) bad = true;
            if (isPlaceholder(seg)) placeholders += 1;
        }
        if (bad or placeholders != args.len) continue;

        // A GET candidate replaces any earlier one; a non-GET only fills an
        // empty slot. See the doc above for why the choice is fixed.
        if (best) |b| {
            if (std.mem.eql(u8, b.verb, "GET")) continue;
        }
        best = route;
    }

    const route = best orelse return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var next_arg: usize = 0;
    var it = segments(route.path);
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        try out.append(gpa, '/');
        if (isPlaceholder(seg)) {
            try appendPercentEncoded(gpa, &out, args[next_arg], seg[0] == '*');
            next_arg += 1;
        } else {
            try out.appendSlice(gpa, seg);
        }
    }
    // A route with no segments at all is the root route, whose URL is "/".
    if (out.items.len == 0) try out.append(gpa, '/');
    return try out.toOwnedSlice(gpa);
}

/// Where a controller action's `redirect_to` sends the browser, as a site
/// URL, or `null` when this run cannot say.
///
/// #167 Stage 3. Stage 2 recovered only THAT an action redirects
/// (`controllers.ActionInfo.only_redirect`), which is why the handoff's
/// `redirects[].to` was always null and a converted form island had nowhere
/// to send the browser after a successful mutation. `controllers.
/// RedirectInfo` now carries the target in one of three shapes, and this is
/// the one place that turns all three into a URL:
///
///  * `name` -- a route-helper stem, resolved through `routeUrl` against the
///    route table this run recovered (`root` -> `/`, `post` + `{"1"}` ->
///    `/posts/1`);
///  * `path` -- a literal string target, taken VERBATIM. It is whatever the
///    author wrote and may be an absolute URL; normalising it here would
///    invent a fact the source does not carry;
///  * `dynamic` -- the sidecar could not reduce the target to anything, so
///    there is nothing to resolve and the entry is SKIPPED.
///
/// The FIRST entry that resolves wins, and a `dynamic` one does not stop the
/// search: an action whose first `redirect_to` is `redirect_to @post` and
/// whose second is `redirect_to root_path` really does have a target this
/// stage can name for the second branch, and reporting none would lose it.
/// A `name` that resolves to no route is equally skipped -- an unknown
/// helper is not a URL.
///
/// Contract 1 (self-freeing): all scratch is released; the returned URL is
/// the only allocation that escapes and is the caller's to free.
pub fn redirectUrl(
    gpa: Allocator,
    all: []const routes.Route,
    list: []const controllers.RedirectInfo,
) Allocator.Error!?[]const u8 {
    for (list) |r| {
        if (r.dynamic) continue;
        if (r.name) |stem| {
            if (try routeUrl(gpa, all, stem, r.args)) |url| return url;
            continue;
        }
        if (r.path) |p| return try gpa.dupe(u8, p);
    }
    return null;
}

// ---- asset helpers -------------------------------------------------------

/// What one Rails asset helper resolves against: the `app/assets/`
/// subdirectory Rails' own `AssetUrlHelper::ASSET_PUBLIC_DIRECTORIES` maps
/// that helper's kind to, and the extension the helper appends to a bare
/// logical name (`stylesheet_link_tag "application"` means
/// `application.css`).
///
/// `dir == null` means "every kind directory, then `public/`" -- the
/// generic `asset_path`/`asset_url`, which Rails resolves against the whole
/// asset load path rather than one kind's subdirectory.
const HelperKind = struct {
    dir: ?[]const u8,
    ext: ?[]const u8,
};

/// The helper vocabulary is exactly `templates.rb`'s `ASSET_HELPERS` list --
/// the set the sidecar tags `kind: "asset"` -- so every fragment the scanner
/// can hand `convert.zig` has an entry here and an unknown helper really is
/// unknown rather than merely unlisted. Keep the two in sync.
fn helperKind(helper: []const u8) ?HelperKind {
    const table = .{
        .{ "image_tag", HelperKind{ .dir = "images", .ext = null } },
        .{ "image_path", HelperKind{ .dir = "images", .ext = null } },
        .{ "favicon_link_tag", HelperKind{ .dir = "images", .ext = null } },
        .{ "audio_tag", HelperKind{ .dir = "audios", .ext = null } },
        .{ "video_tag", HelperKind{ .dir = "videos", .ext = null } },
        .{ "font_path", HelperKind{ .dir = "fonts", .ext = null } },
        .{ "stylesheet_link_tag", HelperKind{ .dir = "stylesheets", .ext = ".css" } },
        .{ "javascript_include_tag", HelperKind{ .dir = "javascripts", .ext = ".js" } },
        .{ "asset_path", HelperKind{ .dir = null, .ext = null } },
        .{ "asset_url", HelperKind{ .dir = null, .ext = null } },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, helper, row[0])) return row[1];
    }
    return null;
}

/// Every `app/assets/` kind directory, in the order `asset_path` searches
/// them. Rails resolves a generic `asset_path` against the whole asset load
/// path, whose order depends on the app's own configuration; this stage
/// cannot read that, so it fixes one order and documents it rather than
/// inheriting the asset slice's walk order (see this file's header).
const all_kind_dirs = [_][]const u8{ "images", "stylesheets", "javascripts", "fonts", "audios", "videos" };

/// The longest possible candidate: `app/assets/` + the longest kind dir +
/// a generous logical name + the longest suffix below. A helper literal
/// longer than this is not a logical asset name, and `assetFor` reports it
/// as unresolved rather than truncating it into a different asset's path.
const candidate_max = 512;

/// The preprocessor sources a logical asset name can actually be compiled
/// from, tried after the exact name fails.
///
/// Returning the preprocessor source (rather than `null`) is deliberate: the
/// caller needs the source path to raise `ASSET_TRANSFORM` naming the file an
/// operator has to port by hand. Distinguishing "plain file" from "needs a
/// transform" is the caller's job -- it has the returned `source`'s
/// extension, and this file has no findings vocabulary.
///
/// `chained` forms keep the logical extension and append the preprocessor's
/// (`application.css.erb`); `swapped` forms replace it
/// (`application.scss`). Both are ordinary in real apps and Sprockets
/// accepts both.
///
/// Only `.css` and `.js` have entries. Sprockets will happily compile a
/// `logo.svg.erb` too, but a bare `image_tag "logo.png"` naming a
/// `logo.scss` is not a thing, and generating those candidates anyway would
/// mean a mistyped image literal could match an unrelated stylesheet whose
/// stem happened to collide. An empty list is the honest answer for every
/// other extension.
const PreprocessorForms = struct {
    chained: []const []const u8 = &.{},
    swapped: []const []const u8 = &.{},
};

fn preprocessorForms(logical: []const u8) PreprocessorForms {
    if (std.mem.endsWith(u8, logical, ".css")) return .{
        .chained = &.{ ".erb", ".scss", ".sass" },
        .swapped = &.{ ".scss", ".sass" },
    };
    if (std.mem.endsWith(u8, logical, ".js")) return .{
        .chained = &.{ ".erb", ".coffee" },
        .swapped = &.{".coffee"},
    };
    return .{};
}

/// Ruling S23. True for an asset literal that names a resource on ANOTHER
/// host: `http://…`, `https://…`, or the protocol-relative `//host/…`.
///
/// This is the one literal shape `assetFor` below cannot answer usefully. It
/// returns `null` for it -- correctly, since no local file matches -- and
/// `null` means "unresolved asset" to both of this function's callers, so
/// without an interception every CDN reference in an app became a
/// `RAILS_ASSET_TRANSFORM` finding and a placeholder region in place of the
/// author's `<img>`.
///
/// It lives HERE, next to `assetFor`, rather than in either caller, because
/// two files have to agree on it exactly: `convert.zig` skips these literals
/// when it decides whether a node can be emitted, and `findings.zig` skips
/// them when it decides whether to ask about one. A copy in each would let
/// one file emit clean markup while the other asked a question about it (or,
/// worse, the reverse: a placeholder pointing at a finding id nobody
/// derived).
///
/// Order matters against the `/`-rooted public-path idiom `assetFor`
/// documents: `//cdn/x.png` starts with `/` too, so this predicate must be
/// consulted first.
///
/// The shape is Rails' own: `AssetUrlHelper::URI_REGEXP` is
/// `%r{^[-a-z]+://|^(?:cid|data):|^//}i`, so a `data:` image, a `cid:`
/// reference and any `scheme://` are all "already a URL, do not look for a
/// file" to the helper the author called. Matching only `http(s)://` here
/// made a `data:` image -- the one literal that most obviously has no local
/// file -- vanish into an empty finding region.
///
/// Contract 3 (caller-buffer): allocates nothing.
pub fn isAbsoluteAssetLiteral(literal: []const u8) bool {
    if (std.mem.startsWith(u8, literal, "//")) return true;
    if (std.ascii.startsWithIgnoreCase(literal, "cid:") or
        std.ascii.startsWithIgnoreCase(literal, "data:")) return true;
    // `[-a-z]+://`, case-insensitively: a non-empty run of letters and
    // hyphens, then the separator.
    var i: usize = 0;
    while (i < literal.len and (std.ascii.isAlphabetic(literal[i]) or literal[i] == '-')) : (i += 1) {}
    return i > 0 and std.mem.startsWith(u8, literal[i..], "://");
}

test "isAbsoluteAssetLiteral: Rails' URI_REGEXP shapes pass, paths and names do not" {
    const testing = std.testing;
    try testing.expect(isAbsoluteAssetLiteral("http://cdn.example.com/x.png"));
    try testing.expect(isAbsoluteAssetLiteral("HTTPS://cdn.example.com/x.png"));
    try testing.expect(isAbsoluteAssetLiteral("//cdn.example.com/x.png"));
    try testing.expect(isAbsoluteAssetLiteral("ftp://files.example.com/x.png"));
    try testing.expect(isAbsoluteAssetLiteral("data:image/gif;base64,R0lGODlh"));
    try testing.expect(isAbsoluteAssetLiteral("cid:part1@example.com"));
    try testing.expect(!isAbsoluteAssetLiteral("logo.png"));
    try testing.expect(!isAbsoluteAssetLiteral("/uploads/x.png"));
    try testing.expect(!isAbsoluteAssetLiteral("images/logo.png"));
    try testing.expect(!isAbsoluteAssetLiteral("://nothing"));
    try testing.expect(!isAbsoluteAssetLiteral("data-x.png"));
}

/// An asset helper's literal -> the manifest asset it names.
/// `image_tag "logo.png"` looks under `app/assets/images/` then `public/`;
/// `stylesheet_link_tag "application"` appends `.css` and finds
/// `app/assets/stylesheets/application.css`; `asset_path` searches every
/// kind directory. Returns `null` for an unknown helper or an unmatched
/// literal.
///
/// A literal beginning with `/` is Rails' "this is already a path, do not run
/// it through the asset pipeline" idiom (`image_tag "/uploads/x.png"`), and is
/// resolved under `public/` ALONE -- the leading slash stripped, the pipeline
/// roots and the preprocessor forms both skipped. Searching the pipeline roots
/// too would let `/logo.png` come back as `app/assets/images/logo.png`, an
/// asset the author explicitly did not ask for and whose digested URL is not
/// the path they wrote.
///
/// An ABSOLUTE URL literal (`https://cdn.example.com/x.png`, or the
/// protocol-relative `//cdn.example.com/x.png`) resolves to `null`, since no
/// local asset can match one. That is the correct answer here but not a
/// complete one: such a literal names a resource the migration should copy
/// through unchanged rather than report as missing, so **`convert.zig` and
/// `findings.zig` both call `isAbsoluteAssetLiteral` above and skip the
/// literal BEFORE calling this function** -- ruling S23. Without that, every
/// CDN reference in the app became a spurious unresolved-asset finding.
///
/// A `deterministic == false` asset is returned like any other. That is the
/// point of the split: this function answers "which file does this helper
/// name", and whether that file's public URL could be derived is a separate
/// fact the caller reads off the returned `Asset` -- suppressing it here
/// would leave the caller a bare `null` and no way to tell "no such asset"
/// (an author typo) from "this asset exists but its URL is unknowable" (an
/// `ASSET_*` finding on a real file).
///
/// Contract 3 (caller-buffer): allocates nothing. Candidate paths are
/// formatted into a stack buffer and the result borrows `items`' own
/// storage, so the returned `Asset` lives exactly as long as `items` does.
///
/// See `isAbsoluteAssetLiteral` for the one literal shape callers must
/// intercept before reaching this function.
pub fn assetFor(items: []const assets.Asset, helper: []const u8, literal: []const u8) ?assets.Asset {
    const kind = helperKind(helper) orelse return null;

    // A rooted literal names a `public/`-relative path verbatim; the leading
    // slash is the marker, not part of the name, so it is dropped before any
    // candidate is built. Concatenating it would produce `public//uploads/x.png`
    // and match nothing -- the defect this branch replaces.
    const rooted = literal.len > 0 and literal[0] == '/';
    const bare = if (rooted) literal[1..] else literal;

    // The logical name: the literal, plus the helper's extension when it does
    // not already carry it (`stylesheet_link_tag "application"` and
    // `stylesheet_link_tag "application.css"` name the same asset). A rooted
    // literal gains the extension too -- `/css/print` is still a stylesheet.
    var logical_buf: [candidate_max]u8 = undefined;
    const logical = blk: {
        const ext = kind.ext orelse break :blk bare;
        if (std.mem.endsWith(u8, bare, ext)) break :blk bare;
        break :blk std.fmt.bufPrint(&logical_buf, "{s}{s}", .{ bare, ext }) catch return null;
    };
    // The logical name minus its final extension, for the swapped
    // preprocessor forms. Only the BASENAME's dots count: a directory
    // component may contain one (`app/assets/images/v1.2/logo.png`).
    const slash = std.mem.lastIndexOfScalar(u8, logical, '/');
    const base_start = if (slash) |s| s + 1 else 0;
    const dot = std.mem.lastIndexOfScalar(u8, logical[base_start..], '.');
    const stem = if (dot) |d| logical[0 .. base_start + d] else logical;
    // A rooted literal asks for a file as-is, so it gets no preprocessor
    // fallback: `/app.css` names `public/app.css` and never a `.scss` that
    // would have to be compiled into it.
    const forms = if (rooted) PreprocessorForms{} else preprocessorForms(logical);

    // Roots in resolution order: the helper's own kind directory (or every
    // one, for the generic helpers), then `public/`, which bypasses the
    // pipeline entirely (`assets.scan`'s doc). `dirs.len + 1` roots, the
    // last always `public/`. `one_dir` is a named function-scope local
    // rather than an inline `&[_][]const u8{d}`: the latter takes the
    // address of a temporary whose lifetime is a language detail, and this
    // slice outlives the expression that builds it.
    var one_dir: [1][]const u8 = undefined;
    const dirs: []const []const u8 = if (rooted)
        // No pipeline roots at all: the loop below runs its single trailing
        // `public/` iteration and stops.
        &.{}
    else if (kind.dir) |d| blk: {
        one_dir[0] = d;
        break :blk &one_dir;
    } else &all_kind_dirs;

    // Root-major, and within a root the exact source before any
    // preprocessor form: an `app/assets/` preprocessor source beats a
    // `public/` file of the same logical name (Rails' own precedence, and
    // the case an operator cares about -- the compiled asset is what the
    // page actually links to), while a plain `application.css` beats the
    // `application.scss` sitting next to it.
    for (0..dirs.len + 1) |i| {
        var root_buf: [candidate_max]u8 = undefined;
        const root = if (i < dirs.len)
            std.fmt.bufPrint(&root_buf, "app/assets/{s}/", .{dirs[i]}) catch return null
        else
            "public/";

        var buf: [candidate_max]u8 = undefined;
        if (find(items, std.fmt.bufPrint(&buf, "{s}{s}", .{ root, logical }) catch continue)) |hit| return hit;
        for (forms.chained) |suffix| {
            const c = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ root, logical, suffix }) catch continue;
            if (find(items, c)) |hit| return hit;
        }
        for (forms.swapped) |suffix| {
            const c = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ root, stem, suffix }) catch continue;
            if (find(items, c)) |hit| return hit;
        }
    }
    return null;
}

/// Exact `source` match. Contract 3 (caller-buffer): allocates nothing.
fn find(items: []const assets.Asset, source: []const u8) ?assets.Asset {
    for (items) |item| {
        if (std.mem.eql(u8, item.source, source)) return item;
    }
    return null;
}

/// Where a source asset lands in the target tree, relative to its assets
/// root: `app/assets/images/logo.png` -> `images/logo.png`;
/// `public/robots.txt` -> `robots.txt`.
///
/// A path under neither root is duped verbatim. `assets.scan` only ever
/// produces those two roots (`inventory.classify` gives `Kind.asset` to
/// nothing else), so the fallback is unreachable today; it exists because
/// silently returning an empty string or a basename for a path this function
/// does not recognise would collide two assets into one target file, and a
/// verbatim copy at least stays injective.
///
/// Contract 1 (self-freeing): the returned path is the only allocation and
/// is the caller's to free.
pub fn assetTargetPath(gpa: Allocator, source: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, source, "app/assets/")) {
        return gpa.dupe(u8, source["app/assets/".len..]);
    }
    if (std.mem.startsWith(u8, source, "public/")) {
        return gpa.dupe(u8, source["public/".len..]);
    }
    return gpa.dupe(u8, source);
}

// ---- target-tree paths ---------------------------------------------------

/// The content file a static GET route becomes: `/` -> `content/index.smd`,
/// `/about` -> `content/about/index.smd`, `/admin/users` ->
/// `content/admin/users/index.smd`.
///
/// Directory-index form (`about/index.smd`) rather than `about.smd` per the
/// plan's Task 1 interface. The spec's prose names `content/about.smd` in
/// one sentence and `content/<url>/index.smd` in its own conversion table
/// two paragraphs earlier; the table (and the plan) win, and the index form
/// is the one that makes a route with children (`/admin` alongside
/// `/admin/users`) representable at all.
///
/// Returns `null` when any segment is a placeholder (`:id`, `*path`) -- such
/// a route has no single static path, and the caller raises
/// `RAILS_ROUTE_DYNAMIC_SEGMENT` -- or contains syntax this stage does not
/// interpret (see `isUninterpretable`).
///
/// Contract 1 (self-freeing): all scratch is released; the returned path is
/// the only allocation that escapes and is the caller's to free.
pub fn contentPath(gpa: Allocator, route_path: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "content");
    var it = segments(route_path);
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (isPlaceholder(seg) or isUninterpretable(seg)) return null;
        try out.append(gpa, '/');
        try out.appendSlice(gpa, seg);
    }
    try out.appendSlice(gpa, "/index.smd");
    return try out.toOwnedSlice(gpa);
}

/// Drops every extension from a path's basename: `about.html.erb` ->
/// `about`. The FIRST dot wins, not the last -- a Rails template name is a
/// stem followed by a format/handler chain, so `about.html.erb` has two
/// extensions and `.last` would leave `about.html`. Contract 3
/// (caller-buffer): returns a sub-slice of `path`.
fn dropExtensions(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const base_start = if (slash) |s| s + 1 else 0;
    const dot = std.mem.indexOfScalar(u8, path[base_start..], '.') orelse return path;
    return path[0 .. base_start + dot];
}

/// The VIEW among a route's scanned templates: the one at
/// `app/views/<controller>/<action>.*`.
///
/// The rest of a route's template list are the partials the view renders, and
/// the list is path-sorted rather than view-first, so the view has to be
/// identified by name. Returns `null` when the route resolved no view at all
/// -- a controller or action discovery never recovered, or an action with no
/// template file, which is ruling S22's `RAILS_NO_TEMPLATE`.
///
/// It lives here rather than in `scaffold.zig` (its original home) because
/// `findings.zig` has to answer the SAME question to decide whether to derive
/// that finding, and a route the finding fires on but the scaffold finds a
/// view for -- or the reverse -- is a manifest row nothing can answer.
///
/// Contract 3 (caller-buffer): allocates nothing; the result is one of
/// `templates`' own strings.
pub fn viewFor(templates: []const []const u8, controller: ?[]const u8, action: ?[]const u8) ?[]const u8 {
    const c = controller orelse return null;
    const a = action orelse return null;
    for (templates) |t| {
        const stem = viewStem(t);
        // `pages/about` == `<controller>/<action>`, compared without
        // allocating: the two halves and the separator, in order.
        if (stem.len != c.len + 1 + a.len) continue;
        if (!std.mem.startsWith(u8, stem, c)) continue;
        if (stem[c.len] != '/') continue;
        if (!std.mem.eql(u8, stem[c.len + 1 ..], a)) continue;
        return t;
    }
    return null;
}

/// `app/views/layouts/marketing.html.erb` -> `marketing`, the stem the
/// target tree writes as `layouts/templates/<stem>.shtml`. A path outside
/// `app/views/layouts/` keeps whatever leading directories it has, so a
/// caller passing the wrong thing gets an obviously-wrong stem rather than a
/// silently-collapsed one. Contract 3 (caller-buffer): returns a sub-slice
/// of `layout_path`.
pub fn layoutStem(layout_path: []const u8) []const u8 {
    const prefix = "app/views/layouts/";
    const rel = if (std.mem.startsWith(u8, layout_path, prefix)) layout_path[prefix.len..] else layout_path;
    return dropExtensions(rel);
}

/// `app/views/pages/about.html.erb` -> `pages/about`, the stem the target
/// tree writes as `layouts/<stem>.shtml`. The controller directory is part
/// of the stem on purpose: two controllers routinely have an `index` view,
/// and collapsing to the basename would overwrite one with the other.
/// Contract 3 (caller-buffer): returns a sub-slice of `view_path`.
pub fn viewStem(view_path: []const u8) []const u8 {
    const prefix = "app/views/";
    const rel = if (std.mem.startsWith(u8, view_path, prefix)) view_path[prefix.len..] else view_path;
    return dropExtensions(rel);
}

/// The first path segment of a dynamic route: `/posts/:id` -> `posts`. That
/// segment names the `.spa.tsx` a `spa` decision scaffolds, so every dynamic
/// route sharing a first segment lands in one SPA. Empty for `/` (which has
/// no segment and is never dynamic). Contract 3 (caller-buffer): returns a
/// sub-slice of `route_path`.
pub fn spaSegment(route_path: []const u8) []const u8 {
    var it = segments(route_path);
    while (it.next()) |seg| {
        if (seg.len != 0) return seg;
    }
    return "";
}

// ---- content-path claims (#182) ------------------------------------------

/// True when a route path stands for a family of URLs rather than one: a
/// `:param` or `*glob` segment.
///
/// THE definition, and the only one. It lives here because `isPlaceholder`
/// -- which `contentPath` uses to decide the very same thing -- lives here,
/// and "dynamic" is defined as exactly "`contentPath` gives it no single
/// static page". `findings.isDynamicRoutePath` used to be a second copy of
/// the loop kept honest by a test; it now delegates, so there is nothing left
/// to drift.
///
/// Contract 3 (caller-buffer): allocates nothing.
pub fn isDynamicRoutePath(route_path: []const u8) bool {
    var it = segments(route_path);
    while (it.next()) |seg| {
        if (isPlaceholder(seg)) return true;
    }
    return false;
}

/// One route that reduced to a `content/.../index.smd` an EARLIER route had
/// already claimed. `with` is the index of that earlier route -- the finding
/// has to name it ("content path collision with GET /about"), which is why
/// this is a pair and not a bare index.
pub const ContentCollision = struct {
    /// Index into the `route_list` `contentClaims` was given.
    route: usize,
    /// Index of the route that got the path first.
    with: usize,
};

/// Which routes cannot be written as a content page, and why. Both lists
/// hold indexes into the `route_list` passed to `contentClaims`, ascending.
///
/// Contract 2 (owned-result): released by `deinit`.
pub const ContentClaims = struct {
    /// Ascending by `route`.
    collisions: []ContentCollision,
    /// Ascending. A static GET route whose path `contentPath` refuses --
    /// `(.:format)` and friends, i.e. route syntax this stage does not
    /// interpret.
    unsupported: []usize,

    pub fn deinit(self: ContentClaims, gpa: Allocator) void {
        gpa.free(self.collisions);
        gpa.free(self.unsupported);
    }
};

/// #182: the two ways a route with a perfectly good classification still
/// gets no page written for it, computed ONCE so `findings.zig`'s two
/// route-level rows and `scaffold.zig`'s route walk cannot disagree about
/// which routes they are. Before this, both were bare `addOpenNote`
/// sentences in `scaffold.zig` with no finding id behind them, so no
/// decisions file could name them and `complete` was unreachable for an app
/// that had one.
///
/// The walk mirrors `scaffold.zig`'s `writeRoutes`/`routeOutcome` exactly,
/// and it has to: the FIRST route to claim a content path is the one that
/// keeps it, so the answer depends on the order routes are visited in.
/// That order is `scaffold.routeLessThan` -- (path, verb, controller,
/// action) -- chosen there so the outcome does not depend on the order the
/// sidecar happened to emit the route table in, and restated here rather
/// than exported because `scaffold.zig` imports this file, not the reverse.
///
/// The exclusions are scaffold's own earlier branches, in its order: a
/// `redirect` route, a `backend` route or any non-GET/HEAD verb, and a
/// dynamic path all return before the content path is ever computed.
///
/// **One difference from `scaffold.zig`, deliberately:** scaffold registers
/// a claim only once the page is actually on disk (`out.artifacts.items.
/// len > 0`), so a winner that turned out to have no view leaves the path
/// free for the next route. This function cannot know that -- it has no
/// template graph -- so it claims on the content path alone. The effect is
/// confined to a route that both collides AND whose winner is viewless,
/// which needs a duplicate declaration and a missing template together;
/// `findings.routeHasNoView` documents the mirror-image gap on the other
/// side. Task 4 folds `scaffold.zig` onto this function, which is when the
/// difference disappears.
///
/// Contract 2 (owned-result): both slices are fresh `gpa` allocations,
/// released by `ContentClaims.deinit`.
pub fn contentClaims(
    gpa: Allocator,
    route_list: []const routes.Route,
    classifications: []const classify.Verdict,
) Allocator.Error!ContentClaims {
    const order = try gpa.alloc(usize, route_list.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, route_list, routeLessThan);

    // `path` is owned by this list; `route` is the index that claimed it.
    const Claim = struct { path: []const u8, route: usize };
    var claims: std.ArrayListUnmanaged(Claim) = .empty;
    defer {
        for (claims.items) |c| gpa.free(c.path);
        claims.deinit(gpa);
    }

    var collisions: std.ArrayListUnmanaged(ContentCollision) = .empty;
    errdefer collisions.deinit(gpa);
    var unsupported: std.ArrayListUnmanaged(usize) = .empty;
    errdefer unsupported.deinit(gpa);

    for (order) |i| {
        const r = route_list[i];
        // A missing verdict is `null`, not `.backend`: an unclassified route
        // is one this run has no verdict for, and the same stance
        // `findings.DeriveInput.classifications` takes.
        const class: ?classify.Class = if (i < classifications.len) classifications[i].class else null;
        if (class == classify.Class.redirect) continue;
        const is_get = std.mem.eql(u8, r.verb, "GET") or std.mem.eql(u8, r.verb, "HEAD");
        if (class == classify.Class.backend or !is_get) continue;
        if (isDynamicRoutePath(r.path)) continue;

        const maybe_path = try contentPath(gpa, r.path);
        const path = maybe_path orelse {
            try unsupported.append(gpa, i);
            continue;
        };
        var owned = true;
        defer if (owned) gpa.free(path);

        for (claims.items) |c| {
            if (!std.mem.eql(u8, c.path, path)) continue;
            try collisions.append(gpa, .{ .route = i, .with = c.route });
            break;
        } else {
            try claims.append(gpa, .{ .path = path, .route = i });
            owned = false;
        }
    }

    // The walk order is scaffold's; the OUTPUT order is by route index, so a
    // consumer can zip either list against the route table without sorting.
    std.mem.sort(ContentCollision, collisions.items, {}, collisionLessThan);
    std.mem.sort(usize, unsupported.items, {}, ascending);

    const collisions_owned = try collisions.toOwnedSlice(gpa);
    errdefer gpa.free(collisions_owned);
    const unsupported_owned = try unsupported.toOwnedSlice(gpa);
    return .{ .collisions = collisions_owned, .unsupported = unsupported_owned };
}

fn collisionLessThan(_: void, a: ContentCollision, b: ContentCollision) bool {
    return a.route < b.route;
}

fn ascending(_: void, a: usize, b: usize) bool {
    return a < b;
}

/// `scaffold.zig`'s own route order, restated (see `contentClaims`).
fn routeLessThan(list: []const routes.Route, ai: usize, bi: usize) bool {
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

// ---- tests ---------------------------------------------------------------

fn mkRoute(verb: []const u8, path: []const u8, name: ?[]const u8, certain: bool) routes.Route {
    return .{
        .verb = verb,
        .path = path,
        .controller = "posts",
        .action = "index",
        .name = name,
        .certain = certain,
        .origin = .static_ast,
    };
}

test "redirectUrl: a helper stem resolves against the route table" {
    const gpa = std.testing.allocator;
    const all = [_]routes.Route{
        mkRoute("GET", "/", "root", true),
        mkRoute("GET", "/posts/:id", "post", true),
    };
    const root = [_]controllers.RedirectInfo{.{ .name = "root", .args = &.{} }};
    const url = (try redirectUrl(gpa, &all, &root)).?;
    defer gpa.free(url);
    try std.testing.expectEqualStrings("/", url);

    const post = [_]controllers.RedirectInfo{.{ .name = "post", .args = &.{"7"} }};
    const with_arg = (try redirectUrl(gpa, &all, &post)).?;
    defer gpa.free(with_arg);
    try std.testing.expectEqualStrings("/posts/7", with_arg);
}

test "redirectUrl: a literal path is taken verbatim and a dynamic entry is skipped, not fatal" {
    const gpa = std.testing.allocator;
    const all = [_]routes.Route{mkRoute("GET", "/about", "about", true)};
    // A literal target resolves through nothing: it is whatever the author
    // wrote, and normalising it would invent a fact the source does not carry.
    const literal = [_]controllers.RedirectInfo{.{ .path = "https://example.com/x" }};
    const a = (try redirectUrl(gpa, &all, &literal)).?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("https://example.com/x", a);

    // `redirect_to @post` first, `redirect_to about_path` second: the FIRST
    // that resolves wins, and a dynamic entry does not end the search -- an
    // action with two branches really does have a target for the second.
    const mixed = [_]controllers.RedirectInfo{
        .{ .dynamic = true },
        .{ .name = "about", .args = &.{} },
    };
    const b = (try redirectUrl(gpa, &all, &mixed)).?;
    defer gpa.free(b);
    try std.testing.expectEqualStrings("/about", b);
}

test "redirectUrl: nothing resolvable answers null rather than a guess" {
    const gpa = std.testing.allocator;
    const all = [_]routes.Route{mkRoute("GET", "/about", "about", true)};
    try std.testing.expect(try redirectUrl(gpa, &all, &.{}) == null);
    const dyn = [_]controllers.RedirectInfo{.{ .dynamic = true }};
    try std.testing.expect(try redirectUrl(gpa, &all, &dyn) == null);
    // A helper naming no route this run recovered is not a URL.
    const ghost = [_]controllers.RedirectInfo{.{ .name = "ghost", .args = &.{} }};
    try std.testing.expect(try redirectUrl(gpa, &all, &ghost) == null);
}

test "redirectUrl leaks nothing under a FailingAllocator" {
    const all = [_]routes.Route{mkRoute("GET", "/posts/:id", "post", true)};
    const list = [_]controllers.RedirectInfo{
        .{ .dynamic = true },
        .{ .name = "post", .args = &.{"a b"} },
    };
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        const gpa = failing.allocator();
        if (redirectUrl(gpa, &all, &list)) |maybe| {
            if (maybe) |u| gpa.free(u);
            break;
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
    try std.testing.expect(i < 24);
}

test "routeUrl: a zero-param helper is its route's path" {
    const rs = [_]routes.Route{mkRoute("GET", "/posts", "posts", true)};
    const u = (try routeUrl(std.testing.allocator, &rs, "posts", &.{})).?;
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("/posts", u);
}

test "routeUrl: literal args fill the :param segments in order" {
    const rs = [_]routes.Route{mkRoute("GET", "/posts/:post_id/comments/:id", "post_comment", true)};
    const u = (try routeUrl(std.testing.allocator, &rs, "post_comment", &.{ "1", "2" })).?;
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("/posts/1/comments/2", u);
}

test "routeUrl: root_path is /" {
    const rs = [_]routes.Route{mkRoute("GET", "/", "root", true)};
    const u = (try routeUrl(std.testing.allocator, &rs, "root", &.{})).?;
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("/", u);
}

test "routeUrl: the arg count must equal the placeholder count" {
    const rs = [_]routes.Route{mkRoute("GET", "/posts/:id", "post", true)};
    try std.testing.expectEqual(@as(?[]const u8, null), try routeUrl(std.testing.allocator, &rs, "post", &.{}));
    try std.testing.expectEqual(@as(?[]const u8, null), try routeUrl(std.testing.allocator, &rs, "post", &.{ "1", "2" }));
}

test "routeUrl: arity filters candidates rather than rejecting the name" {
    // `post` naming both a member route and (contrived) a zero-param one:
    // supplying one arg must still find the member route, not give up
    // because the first name match had the wrong arity.
    const rs = [_]routes.Route{
        mkRoute("GET", "/posts/latest", "post", true),
        mkRoute("GET", "/posts/:id", "post", true),
    };
    const u = (try routeUrl(std.testing.allocator, &rs, "post", &.{"7"})).?;
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("/posts/7", u);
}

test "routeUrl: an uncertain route never answers" {
    const rs = [_]routes.Route{mkRoute("GET", "/posts", "posts", false)};
    try std.testing.expectEqual(@as(?[]const u8, null), try routeUrl(std.testing.allocator, &rs, "posts", &.{}));
}

test "routeUrl: an unnamed route never answers" {
    const rs = [_]routes.Route{mkRoute("GET", "/posts", null, true)};
    try std.testing.expectEqual(@as(?[]const u8, null), try routeUrl(std.testing.allocator, &rs, "posts", &.{}));
}

test "routeUrl: an unknown stem is null, not an error" {
    const rs = [_]routes.Route{mkRoute("GET", "/posts", "posts", true)};
    try std.testing.expectEqual(@as(?[]const u8, null), try routeUrl(std.testing.allocator, &rs, "widgets", &.{}));
}

test "routeUrl: the common shared-name case is order-independent" {
    // `resources :posts` names both GET /posts (index) and POST /posts
    // (create) "posts". Same path, so either candidate yields the same
    // bytes; this only pins that a duplicate name is answered rather than
    // refused. The discriminating case is the next test.
    const post_first = [_]routes.Route{
        mkRoute("POST", "/posts", "posts", true),
        mkRoute("GET", "/posts", "posts", true),
    };
    const from_post = (try routeUrl(std.testing.allocator, &post_first, "posts", &.{})).?;
    defer std.testing.allocator.free(from_post);
    try std.testing.expectEqualStrings("/posts", from_post);

    const get_first = [_]routes.Route{
        mkRoute("GET", "/posts", "posts", true),
        mkRoute("POST", "/posts", "posts", true),
    };
    const from_get = (try routeUrl(std.testing.allocator, &get_first, "posts", &.{})).?;
    defer std.testing.allocator.free(from_get);
    try std.testing.expectEqualStrings("/posts", from_get);
}

test "routeUrl: when a shared name spans two PATHS the GET route wins" {
    // A static parser can emit a helper name on two different paths that
    // Rails itself would reject at boot (`resources :posts` plus an
    // explicit `get "/blog", as: :posts`), and then the verb preference is
    // observable rather than cosmetic. Asserted in both slice orders so the
    // test fails if the rule degrades to "first match wins".
    const post_first = [_]routes.Route{
        mkRoute("POST", "/submissions", "posts", true),
        mkRoute("GET", "/blog", "posts", true),
    };
    const from_post = (try routeUrl(std.testing.allocator, &post_first, "posts", &.{})).?;
    defer std.testing.allocator.free(from_post);
    try std.testing.expectEqualStrings("/blog", from_post);

    const get_first = [_]routes.Route{
        mkRoute("GET", "/blog", "posts", true),
        mkRoute("POST", "/submissions", "posts", true),
    };
    const from_get = (try routeUrl(std.testing.allocator, &get_first, "posts", &.{})).?;
    defer std.testing.allocator.free(from_get);
    try std.testing.expectEqualStrings("/blog", from_get);
}

test "routeUrl: a name carried only by non-GET routes still resolves" {
    const rs = [_]routes.Route{mkRoute("DELETE", "/posts/:id", "post", true)};
    const u = (try routeUrl(std.testing.allocator, &rs, "post", &.{"3"})).?;
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("/posts/3", u);
}

test "routeUrl: a trailing slash in the route path is normalised away" {
    const rs = [_]routes.Route{mkRoute("GET", "/about/", "about", true)};
    const u = (try routeUrl(std.testing.allocator, &rs, "about", &.{})).?;
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("/about", u);
}

test "routeUrl: a *glob segment is a placeholder like :param" {
    const rs = [_]routes.Route{mkRoute("GET", "/files/*path", "files", true)};
    const u = (try routeUrl(std.testing.allocator, &rs, "files", &.{"a/b.txt"})).?;
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("/files/a/b.txt", u);
}

test "routeUrl: a literal arg is percent-encoded into its segment" {
    const rs = [_]routes.Route{mkRoute("GET", "/posts/:id", "post", true)};

    // A plain integer is all-unreserved and passes through untouched.
    const plain = (try routeUrl(std.testing.allocator, &rs, "post", &.{"42"})).?;
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("/posts/42", plain);

    const spaced = (try routeUrl(std.testing.allocator, &rs, "post", &.{"a b"})).?;
    defer std.testing.allocator.free(spaced);
    try std.testing.expectEqualStrings("/posts/a%20b", spaced);

    // A slash inside a :param must NOT split the segment.
    const slashed = (try routeUrl(std.testing.allocator, &rs, "post", &.{"x/y"})).?;
    defer std.testing.allocator.free(slashed);
    try std.testing.expectEqualStrings("/posts/x%2Fy", slashed);

    // The escape character itself is escaped, so a double-encoded URL is
    // detectably wrong rather than accidentally equal to a correct one.
    const pct = (try routeUrl(std.testing.allocator, &rs, "post", &.{"50%"})).?;
    defer std.testing.allocator.free(pct);
    try std.testing.expectEqualStrings("/posts/50%25", pct);
}

test "routeUrl: the unreserved set survives encoding unchanged" {
    const rs = [_]routes.Route{mkRoute("GET", "/posts/:id", "post", true)};
    const u = (try routeUrl(std.testing.allocator, &rs, "post", &.{"aZ0-._~"})).?;
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("/posts/aZ0-._~", u);
}

test "routeUrl: a *glob arg keeps its slashes but encodes each component" {
    const rs = [_]routes.Route{mkRoute("GET", "/files/*path", "files", true)};
    const u = (try routeUrl(std.testing.allocator, &rs, "files", &.{"a dir/b.txt"})).?;
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("/files/a%20dir/b.txt", u);
}

test "routeUrl: a (.:format) suffix is refused rather than pasted through" {
    // Stage 1's `routes.rb` never emits one -- its `emit` writes the bare
    // joined path -- so this pins the defensive branch, not observed output.
    const rs = [_]routes.Route{mkRoute("GET", "/posts/:id(.:format)", "post", true)};
    try std.testing.expectEqual(@as(?[]const u8, null), try routeUrl(std.testing.allocator, &rs, "post", &.{"1"}));
}

fn mkAsset(source: []const u8) assets.Asset {
    return .{ .source = source, .public_url = null, .pipeline = null, .deterministic = true };
}

test "assetFor: image_tag looks under app/assets/images before public/" {
    const items = [_]assets.Asset{ mkAsset("public/logo.png"), mkAsset("app/assets/images/logo.png") };
    try std.testing.expectEqualStrings(
        "app/assets/images/logo.png",
        assetFor(&items, "image_tag", "logo.png").?.source,
    );
}

test "assetFor: image_tag falls back to public/" {
    const items = [_]assets.Asset{mkAsset("public/logo.png")};
    try std.testing.expectEqualStrings(
        "public/logo.png",
        assetFor(&items, "image_tag", "logo.png").?.source,
    );
}

test "assetFor: a nested literal keeps its subdirectory" {
    const items = [_]assets.Asset{mkAsset("app/assets/images/icons/star.svg")};
    try std.testing.expectEqualStrings(
        "app/assets/images/icons/star.svg",
        assetFor(&items, "image_tag", "icons/star.svg").?.source,
    );
}

test "assetFor: stylesheet_link_tag adds .css and prefers the plain source" {
    const items = [_]assets.Asset{
        mkAsset("app/assets/stylesheets/application.css.erb"),
        mkAsset("app/assets/stylesheets/application.css"),
    };
    try std.testing.expectEqualStrings(
        "app/assets/stylesheets/application.css",
        assetFor(&items, "stylesheet_link_tag", "application").?.source,
    );
}

test "assetFor: with no plain .css the chained preprocessor source is returned" {
    const items = [_]assets.Asset{mkAsset("app/assets/stylesheets/application.css.erb")};
    try std.testing.expectEqualStrings(
        "app/assets/stylesheets/application.css.erb",
        assetFor(&items, "stylesheet_link_tag", "application").?.source,
    );
}

test "assetFor: with no plain .css the swapped .scss source is returned" {
    const items = [_]assets.Asset{mkAsset("app/assets/stylesheets/application.scss")};
    try std.testing.expectEqualStrings(
        "app/assets/stylesheets/application.scss",
        assetFor(&items, "stylesheet_link_tag", "application").?.source,
    );
}

test "assetFor: a literal that already carries the extension is not doubled" {
    const items = [_]assets.Asset{mkAsset("app/assets/stylesheets/application.css")};
    try std.testing.expectEqualStrings(
        "app/assets/stylesheets/application.css",
        assetFor(&items, "stylesheet_link_tag", "application.css").?.source,
    );
}

test "assetFor: an app/assets preprocessor source beats a public/ plain one" {
    const items = [_]assets.Asset{
        mkAsset("public/application.css"),
        mkAsset("app/assets/stylesheets/application.scss"),
    };
    try std.testing.expectEqualStrings(
        "app/assets/stylesheets/application.scss",
        assetFor(&items, "stylesheet_link_tag", "application").?.source,
    );
}

test "assetFor: javascript_include_tag adds .js" {
    const items = [_]assets.Asset{mkAsset("app/assets/javascripts/app.js")};
    try std.testing.expectEqualStrings(
        "app/assets/javascripts/app.js",
        assetFor(&items, "javascript_include_tag", "app").?.source,
    );
}

test "assetFor: favicon_link_tag resolves the public/ default" {
    const items = [_]assets.Asset{mkAsset("public/favicon.ico")};
    try std.testing.expectEqualStrings(
        "public/favicon.ico",
        assetFor(&items, "favicon_link_tag", "favicon.ico").?.source,
    );
}

test "assetFor: asset_path searches every kind directory" {
    const items = [_]assets.Asset{mkAsset("app/assets/stylesheets/print.css")};
    try std.testing.expectEqualStrings(
        "app/assets/stylesheets/print.css",
        assetFor(&items, "asset_path", "print.css").?.source,
    );
    const fonts = [_]assets.Asset{mkAsset("app/assets/fonts/inter.woff2")};
    try std.testing.expectEqualStrings(
        "app/assets/fonts/inter.woff2",
        assetFor(&fonts, "font_path", "inter.woff2").?.source,
    );
}

test "assetFor: a leading / means public/ verbatim, skipping the pipeline" {
    // `image_tag "/uploads/x.png"` is Rails' "this is already a path, do not
    // run it through the asset pipeline" idiom.
    const items = [_]assets.Asset{mkAsset("public/uploads/x.png")};
    try std.testing.expectEqualStrings(
        "public/uploads/x.png",
        assetFor(&items, "image_tag", "/uploads/x.png").?.source,
    );
}

test "assetFor: a rooted literal is NOT searched under app/assets" {
    // The pipeline roots must not answer a rooted literal: `/logo.png` names
    // `public/logo.png` and nothing else, so a same-named pipeline asset is
    // not returned as a match it never was.
    const items = [_]assets.Asset{mkAsset("app/assets/images/logo.png")};
    try std.testing.expectEqual(@as(?assets.Asset, null), assetFor(&items, "image_tag", "/logo.png"));
}

test "assetFor: a rooted literal naming nothing resolves nothing" {
    const items = [_]assets.Asset{mkAsset("public/uploads/x.png")};
    try std.testing.expectEqual(@as(?assets.Asset, null), assetFor(&items, "image_tag", "/missing.png"));
}

test "assetFor: a rooted stylesheet literal still gains its .css extension" {
    const items = [_]assets.Asset{mkAsset("public/css/print.css")};
    try std.testing.expectEqualStrings(
        "public/css/print.css",
        assetFor(&items, "stylesheet_link_tag", "/css/print").?.source,
    );
}

test "assetFor: an unknown helper resolves nothing" {
    const items = [_]assets.Asset{mkAsset("app/assets/images/logo.png")};
    try std.testing.expectEqual(@as(?assets.Asset, null), assetFor(&items, "link_to", "logo.png"));
}

test "assetFor: a literal naming no asset resolves nothing" {
    const items = [_]assets.Asset{mkAsset("app/assets/images/logo.png")};
    try std.testing.expectEqual(@as(?assets.Asset, null), assetFor(&items, "image_tag", "missing.png"));
}

test "assetFor: a non-deterministic asset is still returned" {
    // Whether an underivable public_url is a finding is the CALLER's
    // decision; hiding the asset here would leave it nothing to report.
    const items = [_]assets.Asset{.{
        .source = "app/assets/images/logo.png",
        .public_url = null,
        .pipeline = .propshaft,
        .deterministic = false,
    }};
    const hit = assetFor(&items, "image_tag", "logo.png").?;
    try std.testing.expectEqualStrings("app/assets/images/logo.png", hit.source);
    try std.testing.expect(!hit.deterministic);
}

test "assetTargetPath: the app/assets/ and public/ roots are stripped" {
    const gpa = std.testing.allocator;
    const p1 = try assetTargetPath(gpa, "app/assets/images/logo.png");
    defer gpa.free(p1);
    try std.testing.expectEqualStrings("images/logo.png", p1);

    const p2 = try assetTargetPath(gpa, "public/robots.txt");
    defer gpa.free(p2);
    try std.testing.expectEqualStrings("robots.txt", p2);

    const p3 = try assetTargetPath(gpa, "vendor/logo.png");
    defer gpa.free(p3);
    try std.testing.expectEqualStrings("vendor/logo.png", p3);
}

test "contentPath: a static GET route becomes a directory index" {
    const gpa = std.testing.allocator;
    const root = (try contentPath(gpa, "/")).?;
    defer gpa.free(root);
    try std.testing.expectEqualStrings("content/index.smd", root);

    const about = (try contentPath(gpa, "/about")).?;
    defer gpa.free(about);
    try std.testing.expectEqualStrings("content/about/index.smd", about);

    const nested = (try contentPath(gpa, "/admin/users")).?;
    defer gpa.free(nested);
    try std.testing.expectEqualStrings("content/admin/users/index.smd", nested);
}

test "contentPath: a trailing slash is normalised away" {
    const gpa = std.testing.allocator;
    const p = (try contentPath(gpa, "/about/")).?;
    defer gpa.free(p);
    try std.testing.expectEqualStrings("content/about/index.smd", p);
}

test "contentPath: a dynamic, glob or uninterpretable segment has no static path" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]const u8, null), try contentPath(gpa, "/posts/:id"));
    try std.testing.expectEqual(@as(?[]const u8, null), try contentPath(gpa, "/files/*path"));
    try std.testing.expectEqual(@as(?[]const u8, null), try contentPath(gpa, "/about(.:format)"));
}

test "layoutStem: the layouts/ root and every extension are dropped" {
    try std.testing.expectEqualStrings("marketing", layoutStem("app/views/layouts/marketing.html.erb"));
    try std.testing.expectEqualStrings("application", layoutStem("app/views/layouts/application.html.erb"));
}

test "viewStem: the controller directory survives, the extensions do not" {
    try std.testing.expectEqualStrings("pages/about", viewStem("app/views/pages/about.html.erb"));
    try std.testing.expectEqualStrings("admin/users/index", viewStem("app/views/admin/users/index.html.erb"));
}

test "spaSegment: the first path segment names the SPA" {
    try std.testing.expectEqualStrings("posts", spaSegment("/posts/:id"));
    try std.testing.expectEqualStrings("posts", spaSegment("/posts"));
    try std.testing.expectEqualStrings("", spaSegment("/"));
}

// ---- #182: contentClaims -------------------------------------------------

fn claimRoute(verb: []const u8, path: []const u8, action: []const u8, line: u64) routes.Route {
    return .{
        .verb = verb,
        .path = path,
        .controller = "pages",
        .action = action,
        .name = null,
        .certain = true,
        .origin = .static_ast,
        .source = .{ .file = "config/routes.rb", .line = line },
    };
}

fn claimVerdict(class: classify.Class) classify.Verdict {
    return .{ .class = class, .reason = "test", .candidates = &.{} };
}

test "contentClaims: the second route reducing to one content path is the collision, whatever the input order" {
    const gpa = std.testing.allocator;
    // `/about` and `/about/` are one `content/about/index.smd` after
    // `contentPath` normalises the trailing slash, and a Rails app can
    // declare both. The WINNER is decided by scaffold's route order (path,
    // verb, controller, action), not by the order the sidecar emitted --
    // so both input orders must name the same pair.
    const forward = [_]routes.Route{
        claimRoute("GET", "/about", "about", 2),
        claimRoute("GET", "/about/", "about_alias", 3),
        claimRoute("GET", "/help", "help", 4),
    };
    const vs = [_]classify.Verdict{ claimVerdict(.content), claimVerdict(.content), claimVerdict(.content) };
    const a = try contentClaims(gpa, &forward, &vs);
    defer a.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), a.collisions.len);
    try std.testing.expectEqual(@as(usize, 1), a.collisions[0].route);
    try std.testing.expectEqual(@as(usize, 0), a.collisions[0].with);
    try std.testing.expectEqual(@as(usize, 0), a.unsupported.len);

    const reverse = [_]routes.Route{
        claimRoute("GET", "/about/", "about_alias", 3),
        claimRoute("GET", "/about", "about", 2),
        claimRoute("GET", "/help", "help", 4),
    };
    const b = try contentClaims(gpa, &reverse, &vs);
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), b.collisions.len);
    // Index 0 is now `/about/`, and `/about` (index 1) still sorts first, so
    // the loser is index 0 and the winner index 1: the same two routes.
    try std.testing.expectEqual(@as(usize, 0), b.collisions[0].route);
    try std.testing.expectEqual(@as(usize, 1), b.collisions[0].with);
}

test "contentClaims: a path contentPath refuses is unsupported, not a collision" {
    const gpa = std.testing.allocator;
    const rs = [_]routes.Route{
        claimRoute("GET", "/posts(.:format)", "index", 2),
        claimRoute("GET", "/about", "about", 3),
    };
    const vs = [_]classify.Verdict{ claimVerdict(.content), claimVerdict(.content) };
    const c = try contentClaims(gpa, &rs, &vs);
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), c.collisions.len);
    try std.testing.expectEqual(@as(usize, 1), c.unsupported.len);
    try std.testing.expectEqual(@as(usize, 0), c.unsupported[0]);
}

test "contentClaims: redirect, backend, non-GET and dynamic routes never claim a path" {
    const gpa = std.testing.allocator;
    // Each of these returns from `scaffold.routeOutcome` before the content
    // path is computed, so none of them can win or lose one. `/about`
    // appears four times over and still collides with nothing.
    const rs = [_]routes.Route{
        claimRoute("GET", "/about", "about", 2),
        claimRoute("GET", "/about", "redirected", 3),
        claimRoute("GET", "/about", "api", 4),
        claimRoute("POST", "/about", "create", 5),
        claimRoute("GET", "/posts/:id", "show", 6),
    };
    const vs = [_]classify.Verdict{
        claimVerdict(.content),
        claimVerdict(.redirect),
        claimVerdict(.backend),
        claimVerdict(.content),
        claimVerdict(.content),
    };
    const c = try contentClaims(gpa, &rs, &vs);
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), c.collisions.len);
    try std.testing.expectEqual(@as(usize, 0), c.unsupported.len);
}

test "contentClaims: an unclassified route is not treated as backend" {
    const gpa = std.testing.allocator;
    // Same stance `findings.DeriveInput.classifications` takes: a SHORT
    // slice means "no verdict", which must not silently exempt the route.
    const rs = [_]routes.Route{
        claimRoute("GET", "/about", "about", 2),
        claimRoute("GET", "/about/", "alias", 3),
    };
    const c = try contentClaims(gpa, &rs, &.{});
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), c.collisions.len);
}

test "contentClaims under a FailingAllocator leaks nothing on any partial allocation" {
    const rs = [_]routes.Route{
        claimRoute("GET", "/about", "about", 2),
        claimRoute("GET", "/about/", "alias", 3),
        claimRoute("GET", "/posts(.:format)", "index", 4),
        claimRoute("GET", "/help", "help", 5),
    };
    const vs = [_]classify.Verdict{
        claimVerdict(.content),
        claimVerdict(.content),
        claimVerdict(.content),
        claimVerdict(.content),
    };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 500) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (contentClaims(failing.allocator(), &rs, &vs)) |c| {
            // Freed through the same allocator interface that allocated it;
            // the wrapped testing allocator would ACCEPT the frees, but the
            // FailingAllocator's own accounting is part of what the sweep
            // checks (PR #188 review).
            defer c.deinit(failing.allocator());
            try std.testing.expectEqual(@as(usize, 1), c.collisions.len);
            try std.testing.expectEqual(@as(usize, 1), c.unsupported.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
