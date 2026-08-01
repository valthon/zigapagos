//! Machine-readable diagnostics (issue #46 / DX-27).
//!
//! `zigapagos release --format=json` emits one NDJSON object per diagnostic on
//! stderr instead of the historical multi-line prose. The wire schema is
//! fixed by issue #46: `{"code","severity","file","line","col","message",
//! "help"}`, field order is the declaration order below (`std.json.Stringify`
//! emits struct fields in declaration order, and that order is part of the
//! published contract, not an implementation detail).
//!
//! Stability contract: a `Code` tag name, once shipped, is the wire string
//! forever. `src/diag-codes.frozen` is the append-only ledger that makes that
//! a gate rather than a promise:
//!
//!   * adding a code = a new `Code` field + a new `[ACTIVE]` line.
//!   * retiring a code = delete the `Code` field, MOVE its line to
//!     `[RETIRED]`. The line never disappears and never gets reused for a
//!     different meaning.
//!   * renaming is not a supported operation -- it is a retirement plus an
//!     addition, because a consumer that switches on the old string must not
//!     silently start matching nothing.
//!
//! The `test "diag: ..."` blocks at the bottom of this file enforce all of
//! that against the frozen file, and `info()`'s exhaustive switch (no `else`
//! arm) makes "every code has a summary and an explanation" a compile error
//! away from being violated rather than a convention.
//!
//! `format` is a plain `var`, not behind a mutex: it is set exactly once, in
//! `main.zig`, before `std.Progress.start` and before `worker.start` spawns
//! any thread. Every worker thread only ever READS it afterwards, so there is
//! no data race in practice even though the type system can't see that.
//! Never write it after that point.
pub var format: Format = .text;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Format = enum { text, json };

/// `--format=VALUE` -> the parsed `Format`, or `null` on an unrecognised
/// value. Never fatals: this runs both from `scanArgv` (before any real
/// argument parser exists, so there is nothing to hand a good error message
/// to yet) and from `release.zig`'s `Command.parse` (which DOES own the
/// error message for a bad value -- duplicating it here would drift).
pub fn parseFormat(value: []const u8) ?Format {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

/// Scans one command's own arguments for a `--format=` flag and returns the
/// format it names, BEFORE that command's real argument parser has run --
/// `main.zig` needs the answer prior to `std.Progress.start` and the
/// Debug/tracy/tsan banners, all of which write to stderr and would
/// interleave with the NDJSON stream otherwise (see main.zig).
///
/// The caller decides WHOSE arguments these are; `main.zig` passes only
/// `zigapagos release`'s, because `release` is the only command that accepts
/// the flag. Stopping at the first bare `--` is nonetheless a property of the
/// scanner itself, so a future caller passing an argv with a passthrough tail
/// (`zigapagos e2e --site=x -- mycmd --format=json`) cannot have zigapagos's
/// OWN diagnostic format flipped by the wrapped command's identically-spelled
/// flag.
///
/// An unrecognised `--format=` value returns `null` (same as "no flag seen")
/// rather than fatal-ing -- this is a pre-scan, not the authoritative parse;
/// the real parser (`release.zig`) reports the bad value with a proper usage
/// error once it runs.
///
/// Contract 3 (caller-buffer, NO_SLOP §2.2a): allocates nothing, returns a
/// value type, and borrows nothing past return.
pub fn scanArgv(args: []const []const u8) ?Format {
    const prefix = "--format=";
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return null;
        if (std.mem.startsWith(u8, arg, prefix)) {
            return parseFormat(arg[prefix.len..]);
        }
    }
    return null;
}

pub const Severity = enum { @"error", warning };

/// Field order is the wire order and is part of the published schema (issue
/// #46's `{"code","severity","file","line","col","message","help"}`).
/// `std.json.Stringify` emits struct fields in declaration order -- do not
/// reorder these without treating it as a schema change.
pub const Diagnostic = struct {
    code: Code,
    severity: Severity,
    file: ?[]const u8 = null,
    line: ?u64 = null,
    col: ?u64 = null,
    message: []const u8,
    help: ?[]const u8 = null,
};

/// Writes one minified JSON object (no hand-rolled escaping -- see `write`)
/// plus a trailing '\n' to locked stderr. Reachable from `fatal.oom()`, so
/// this must allocate NOTHING (contract 3, caller-buffer, NO_SLOP §2.2a): a
/// failure here on an OOM path must not itself need memory. Errors from the
/// underlying writer are swallowed exactly like `std.debug.print` swallows
/// them -- a failed write to stderr is unrecoverable and there is nothing a
/// diagnostic emitter can do about it that the caller couldn't already do
/// better (NO_SLOP §2.3).
pub fn emit(d: Diagnostic) void {
    var buf: [4096]u8 = undefined;
    const locked = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr(); // flushes: std/Io/Threaded.zig's unlockStderr
    const w = &locked.file_writer.interface;
    write(d, w) catch return;
    w.writeByte('\n') catch return;
}

/// The testable half of `emit`: writes one minified JSON object (no trailing
/// newline) for `d` to `w`. Split out so test 8 (below) can assert exact
/// bytes -- including field order and escaping -- without locking stderr.
/// Contract 3 (caller-buffer): allocates nothing, the caller owns `w`.
pub fn write(d: Diagnostic, w: *Writer) Writer.Error!void {
    try std.json.Stringify.value(d, .{}, w);
}

/// Renders `fmt`/`args` into a CALLER-PROVIDED buffer, truncating (never
/// failing) if the rendered text doesn't fit. Contract 3 (caller-buffer,
/// NO_SLOP §2.2a): no allocator parameter, so this is safe to call from
/// anywhere a `Diagnostic`'s `message`/`file`/`help` is being assembled,
/// including paths reachable from an OOM fatal. An oversized message yields
/// a truncated (but present) diagnostic rather than no diagnostic at all.
pub fn render(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: Writer = .fixed(buf);
    w.print(fmt, args) catch {}; // error.WriteFailed == buffer full; keep what fits
    return w.buffered();
}

/// Renders a `fatal.msg`/`fatal.usageError` format string+args into a
/// fixed stack buffer and emits it as a single `ZP_FATAL` diagnostic.
/// Contract 3 (caller-buffer): the buffer is on this function's stack frame,
/// never escapes, and nothing here allocates -- required, since this is the
/// JSON-mode replacement for a `fatal.msg` call and therefore must itself be
/// safe to reach from `fatal.oom()`.
pub fn emitFatal(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const rendered = render(&buf, fmt, args);
    // Text-mode fatal messages end in "\n" (sometimes several, from a
    // multi-line format string); trim so the JSON `message` field carries
    // just the text, not formatting artifacts meant for a terminal.
    const trimmed = std.mem.trim(u8, rendered, " \t\r\n");
    emit(.{
        .code = .ZP_FATAL,
        .severity = .@"error",
        .message = trimmed,
    });
}

/// The stable diagnostic-code registry (issue #46 / DX-27, wave 1). A tag
/// name here IS the wire code -- `@tagName` needs no mapping table. See the
/// module doc comment for the stability contract; see
/// `src/diag-codes.frozen` for the machine-checked ledger.
///
/// Every field carries a `// emitted by:` comment naming the call site. There
/// is no compiler check that a registered code is actually emitted anywhere
/// (unlike `info()`'s exhaustiveness, which only checks that an emitted code
/// is documented) -- the comment is what makes a dead/unreachable code
/// visible in review. Never register a code this PR does not also emit.
pub const Code = enum {
    // emitted by: root.zig, static asset glob matched nothing
    ZP_STATIC_ASSET_GLOB_EMPTY,
    // emitted by: root.zig, a listed static asset does not exist
    ZP_STATIC_ASSET_MISSING,
    // emitted by: root.zig, i18n ziggy file failed to parse
    ZP_I18N_PARSE,
    // emitted by: root.zig, an empty content file was skipped (warning)
    ZP_EMPTY_PAGE,
    // emitted by: root.zig, frontmatter is missing its opening/closing '---'
    ZP_FRONTMATTER_FRAMING,
    // emitted by: root.zig, frontmatter failed to parse as Ziggy
    ZP_FRONTMATTER_PARSE,
    // emitted by: context/Page.zig FrontmatterAnalysisError, missing/invalid layout
    ZP_MISSING_LAYOUT,
    // emitted by: context/Page.zig FrontmatterAnalysisError, invalid `aliases` entry
    ZP_INVALID_ALIAS,
    // emitted by: context/Page.zig FrontmatterAnalysisError, invalid alternative name
    ZP_INVALID_ALTERNATIVE_NAME,
    // emitted by: context/Page.zig FrontmatterAnalysisError, invalid alternative path
    ZP_INVALID_ALTERNATIVE_PATH,
    // emitted by: context/Page.zig FrontmatterAnalysisError, invalid alternative layout
    ZP_INVALID_ALTERNATIVE_LAYOUT,
    // emitted by: context/Page.zig PageAnalysisError.not_a_section
    ZP_LINK_NOT_A_SECTION,
    // emitted by: context/Page.zig PageAnalysisError.no_parent_section
    ZP_LINK_NO_PARENT_SECTION,
    // emitted by: context/Page.zig PageAnalysisError.resource_kind_mismatch
    ZP_RESOURCE_KIND_MISMATCH,
    // emitted by: context/Page.zig PageAnalysisError.unknown_page
    ZP_UNKNOWN_PAGE,
    // emitted by: context/Page.zig PageAnalysisError.missing_page_tolerated (warning)
    ZP_MISSING_PAGE_TOLERATED,
    // emitted by: context/Page.zig PageAnalysisError.unknown_alternative
    ZP_UNKNOWN_ALTERNATIVE,
    // emitted by: context/Page.zig PageAnalysisError.missing_asset (kind == .site)
    ZP_MISSING_SITE_ASSET,
    // emitted by: context/Page.zig PageAnalysisError.missing_asset (kind == .page)
    ZP_MISSING_PAGE_ASSET,
    // emitted by: context/Page.zig PageAnalysisError.missing_asset (kind == .build)
    ZP_MISSING_BUILD_ASSET,
    // emitted by: context/Page.zig PageAnalysisError.build_asset_missing_install_path
    ZP_BUILD_ASSET_NO_INSTALL_PATH,
    // emitted by: context/Page.zig PageAnalysisError.unknown_language (warning)
    ZP_UNKNOWN_LANGUAGE,
    // emitted by: context/Page.zig PageAnalysisError.unknown_ref
    ZP_UNKNOWN_REF,
    // emitted by: context/Page.zig PageAnalysisError.locale_link_unsupported
    ZP_LOCALE_LINK_UNSUPPORTED,
    // emitted by: root.zig, two pages in one locale share a translation_key
    ZP_DUPLICATE_TRANSLATION_KEY,
    // emitted by: root.zig, two pages resolved to the same output URL
    ZP_URL_COLLISION,
    // emitted by: root.zig, a layout template failed to parse (HTML or template AST)
    ZP_TEMPLATE_PARSE,
    // emitted by: root.zig, a `:name="..."` directive attribute isn't a real directive
    ZP_TEMPLATE_BAD_DIRECTIVE_ATTR,
    // emitted by: root.zig, `:if`/`:loop` on an element with no end tag
    ZP_TEMPLATE_BRANCHING_WITHOUT_END_TAG,
    // emitted by: root.zig, a `:else` directive SuperHTML parses and never evaluates
    ZP_TEMPLATE_ELSE_DIRECTIVE,
    // emitted by: root.zig, a template `:extends`s a parent that doesn't exist
    ZP_TEMPLATE_MISSING_PARENT,
    // emitted by: root.zig printSuperMdErrors, any SuperMD-reported error
    ZP_SUPERMD,
    // emitted by: fatal.zig msg/usageError, the catch-all for everything not
    // yet promoted to a named code (see docs/diagnostics.md's scope section)
    ZP_FATAL,
};

pub const Info = struct {
    /// One line, no trailing period. Shown by `zigapagos explain-code`
    /// with no arguments, one per code.
    summary: []const u8,
    /// The long form: what condition produced the diagnostic and what to
    /// change in the source to resolve it. May be multi-line.
    explanation: []const u8,
};

/// Exhaustive on purpose: no `else` arm. A new `Code` field without a
/// matching arm here is a COMPILE ERROR -- that is the entire enforcement
/// mechanism behind "every registered code is documented".
pub fn info(c: Code) Info {
    return switch (c) {
        .ZP_STATIC_ASSET_GLOB_EMPTY => .{
            .summary = "a static-asset glob in zigapagos.ziggy matched no files",
            .explanation =
            \\A `static_assets` entry ending in `**` (or exactly `**`) is a glob:
            \\it installs every asset under a prefix instead of one named file.
            \\This fires when that prefix matched nothing in `assets_dir_path`.
            \\
            \\Check the prefix for a typo, confirm the directory actually has
            \\files in it, and remember the glob is relative to
            \\`assets_dir_path`, not the project root.
            ,
        },
        .ZP_STATIC_ASSET_MISSING => .{
            .summary = "a static asset named in zigapagos.ziggy does not exist",
            .explanation =
            \\A `static_assets` entry names an exact path that must exist under
            \\`assets_dir_path`. This one didn't resolve to any scanned asset.
            \\
            \\Check the path for a typo (it's relative to `assets_dir_path`),
            \\and confirm the file wasn't renamed or moved.
            ,
        },
        .ZP_I18N_PARSE => .{
            .summary = "an i18n `.ziggy` file failed to parse",
            .explanation =
            \\Every locale's i18n data file is parsed as Ziggy before the build
            \\proceeds. This fires when that parse failed -- the underlying
            \\Ziggy diagnostic (attached to `message`) names the exact syntax
            \\problem and its location within the file.
            ,
        },
        .ZP_EMPTY_PAGE => .{
            .summary = "a content file was empty and was skipped (warning)",
            .explanation =
            \\A `.smd`/`.md` file with zero bytes has no frontmatter to parse
            \\and nothing to render, so it is skipped rather than failing the
            \\build. If this file is supposed to have content, it was likely
            \\left as a placeholder or lost its contents in an edit.
            ,
        },
        .ZP_FRONTMATTER_FRAMING => .{
            .summary = "a content file's frontmatter delimiters are malformed",
            .explanation =
            \\Every content file must open with a `---` line and close
            \\frontmatter with a matching `---` line before the Markdown body
            \\begins. This fires when the opening delimiter is missing entirely,
            \\or the closing delimiter was never found.
            \\
            \\Check that the file starts with `---` on its own line and that a
            \\second `---` on its own line closes the frontmatter block.
            ,
        },
        .ZP_FRONTMATTER_PARSE => .{
            .summary = "a content file's frontmatter is not valid Ziggy",
            .explanation =
            \\The text between the `---` delimiters must parse as a Ziggy
            \\struct literal. This fires on a Ziggy syntax error inside that
            \\block -- the attached Ziggy diagnostic (in `message`) names the
            \\exact problem and its location.
            ,
        },
        .ZP_MISSING_LAYOUT => .{
            .summary = "a page's `layout` field names a template that doesn't exist",
            .explanation =
            \\Every page must set `layout` to a `.shtml`/`.xml`/... file that
            \\exists under `layouts_dir_path` and is a real layout (not a
            \\partial marked non-layout). This fires when the named file is
            \\missing, or isn't usable as a layout.
            ,
        },
        .ZP_INVALID_ALIAS => .{
            .summary = "an entry in a page's `aliases` list is malformed",
            .explanation =
            \\Each `aliases` entry must be a non-empty ASCII path with a file
            \\extension, no backslashes, and no `.` in a directory component.
            \\This fires when an entry violates one of those rules.
            ,
        },
        .ZP_INVALID_ALTERNATIVE_NAME => .{
            .summary = "an `alternatives` entry has an invalid `name`",
            .explanation =
            \\Each entry in a page's `alternatives` list needs a `name` field
            \\usable to reference it (e.g. from `$page.alternative(...)`,
            \\a template loop). This fires when that field is missing or empty.
            ,
        },
        .ZP_INVALID_ALTERNATIVE_PATH => .{
            .summary = "an `alternatives` entry has an invalid output path",
            .explanation =
            \\Each `alternatives` entry's `output` must follow the same rules
            \\as an `aliases` entry: non-empty ASCII, a file extension, no
            \\backslashes, no `.` in a directory component.
            ,
        },
        .ZP_INVALID_ALTERNATIVE_LAYOUT => .{
            .summary = "an `alternatives` entry's `layout` doesn't exist",
            .explanation =
            \\Each `alternatives` entry may set its own `layout`; when it does,
            \\that path must resolve to a real layout under `layouts_dir_path`,
            \\same as a page's own top-level `layout` field.
            ,
        },
        .ZP_LINK_NOT_A_SECTION => .{
            .summary = "a link targets this page as a section, but it isn't one",
            .explanation =
            \\This page has no subpages, so it cannot be the target of a
            \\subpage-style reference (`$page.subpage(...)`, or a link whose
            \\target starts with a leading `.`).
            \\
            \\A leading `.` in a link target means "subpage of this section",
            \\not "a relative path" -- that's the trap issue #28 documents. To
            \\link a SIBLING page instead, use `$link.page("...")` with the
            \\sibling's own full page path, not a dotted relative form.
            ,
        },
        .ZP_LINK_NO_PARENT_SECTION => .{
            .summary = "the root index page has no parent section to link to",
            .explanation =
            \\The site's root `index.smd` is the top of the section tree; a
            \\reference asking for ITS parent section has nowhere to resolve.
            \\This is almost always a template used by both the root page and
            \\deeper pages, written as though every page has a parent.
            ,
        },
        .ZP_RESOURCE_KIND_MISMATCH => .{
            .summary = "a reference resolved to a page of the wrong kind",
            .explanation =
            \\Some builtins expect a specific resource kind (e.g. a section
            \\vs. a leaf page) and this reference resolved to the other kind.
            \\Check which builtin produced this reference and what kind of
            \\page it documents itself as expecting.
            ,
        },
        .ZP_UNKNOWN_PAGE => .{
            .summary = "a `$link.page`/`$site.page` reference names a page that doesn't exist",
            .explanation =
            \\The referenced page path did not resolve to any scanned content
            \\page. Check the path for a typo, confirm the target file exists
            \\under `content_dir_path`, and note this is a build-time link --
            \\the target must exist NOW, not eventually.
            \\
            \\If the target genuinely doesn't exist yet (e.g. content being
            \\authored incrementally), pass `--allow-missing-pages` to tolerate
            \\it instead of failing the build (see `ZP_MISSING_PAGE_TOLERATED`).
            ,
        },
        .ZP_MISSING_PAGE_TOLERATED => .{
            .summary = "a dangling page reference was tolerated by --allow-missing-pages (warning)",
            .explanation =
            \\`--allow-missing-pages` was set, so a `$link.page`/`$site.page`
            \\reference to a page that doesn't exist YET was rewritten to the
            \\href the page WILL have once it's authored, instead of failing
            \\the build. The emitted HTML is byte-identical to what the
            \\eventual, real link will render as.
            ,
        },
        .ZP_UNKNOWN_ALTERNATIVE => .{
            .summary = "a reference names an alternative that doesn't exist on its page",
            .explanation =
            \\`$page.alternative("name")` (or similar) was called with a name
            \\that doesn't match any entry in the target page's `alternatives`
            \\list. Check the name against that page's frontmatter.
            ,
        },
        .ZP_MISSING_SITE_ASSET => .{
            .summary = "a `$site.asset(...)` reference names an asset that doesn't exist",
            .explanation =
            \\The referenced path did not resolve to any file scanned under
            \\`assets_dir_path`. Check the path for a typo and confirm the
            \\file exists there.
            ,
        },
        .ZP_MISSING_PAGE_ASSET => .{
            .summary = "a `$page.asset(...)` reference names an asset that doesn't exist",
            .explanation =
            \\The referenced path did not resolve to any file scanned in the
            \\current page's own asset directory. Check the path for a typo
            \\and confirm the file exists alongside this page's content.
            ,
        },
        .ZP_MISSING_BUILD_ASSET => .{
            .summary = "a `$build.asset(...)` reference names an asset that wasn't declared",
            .explanation =
            \\The referenced name was not registered via a `--build-asset=`
            \\flag at build time. Check the name against your build invocation
            \\(`zigapagos release --build-asset=NAME PATH ...`).
            ,
        },
        .ZP_BUILD_ASSET_NO_INSTALL_PATH => .{
            .summary = "a build asset is referenced by `.link()` but has no install path",
            .explanation =
            \\A `$build.asset(...)` result can only produce a link (`.link()`)
            \\if the asset was registered with an install path (`--install=`
            \\or `--install-always=`). This one was referenced for linking but
            \\registered without one.
            ,
        },
        .ZP_UNKNOWN_LANGUAGE => .{
            .summary = "a code-fence language isn't registered for highlighting (warning)",
            .explanation =
            \\The fence's language tag doesn't match any entry in the
            \\syntax-highlighting registry, so the block is emitted unhighlighted
            \\(valid output, just without color). Run `zigapagos languages` for
            \\the full registered list and any did-you-mean suggestion.
            ,
        },
        .ZP_UNKNOWN_REF => .{
            .summary = "a `#fragment`/heading reference doesn't resolve",
            .explanation =
            \\The referenced heading/anchor id was not found on the target
            \\page. Check the id for a typo, and if the target uses
            \\GitHub-style implicit heading anchors, confirm
            \\`auto_heading_ids` is enabled for that content tree.
            ,
        },
        .ZP_LOCALE_LINK_UNSUPPORTED => .{
            .summary = "a locale-qualified page link isn't supported yet",
            .explanation =
            \\Linking directly to another locale's variant of a page by
            \\locale-qualified path isn't implemented. Link within the current
            \\locale, or use the multilingual alternative-page mechanism
            \\instead.
            ,
        },
        .ZP_DUPLICATE_TRANSLATION_KEY => .{
            .summary = "two pages in the same locale share a translation_key",
            .explanation =
            \\`translation_key` must be unique within a single locale -- it's
            \\how a multilingual site pairs a page with its translations across
            \\locales. Two pages claiming the same key within one locale is
            \\ambiguous: rename one of them.
            ,
        },
        .ZP_URL_COLLISION => .{
            .summary = "two pages (or an alias/alternative) resolved to the same output URL",
            .explanation =
            \\Every emitted page, alias, and alternative output must land at a
            \\distinct URL. This fires when two of them resolved to the same
            \\one -- check both authoring the `message` names for a page whose
            \\alias, alternative `output`, or default URL was meant to be
            \\different.
            ,
        },
        .ZP_TEMPLATE_PARSE => .{
            .summary = "a layout template failed to parse",
            .explanation =
            \\The named layout file under `layouts_dir_path` failed either its
            \\HTML parse or its SuperHTML-directive parse. The attached
            \\rendered block (in `message`) is the parser's own error output --
            \\it names the exact syntax problem and location within the file.
            ,
        },
        .ZP_TEMPLATE_BAD_DIRECTIVE_ATTR => .{
            .summary = "a `:name=\"...\"` attribute isn't a real SuperHTML directive",
            .explanation =
            \\SuperHTML's only `:`-prefixed directives are `:if`, `:loop`,
            \\`:text`, `:html` (plus `:props` on `<island>`). A dynamic
            \\ordinary attribute uses the BARE name with a Scripty value --
            \\write `name="$expr"`, not `:name="$expr"`. The `:` form
            \\evaluates the value but keeps the literal `:name` attribute, so
            \\the real `name` attribute is silently never set.
            \\
            \\`:else` parses but never renders; it has its own code
            \\(`ZP_TEMPLATE_ELSE_DIRECTIVE`) and is not in the list above.
            ,
        },
        .ZP_TEMPLATE_BRANCHING_WITHOUT_END_TAG => .{
            .summary = "`:if`/`:loop` sits on an element that has no end tag",
            .explanation =
            \\SuperHTML restarts a conditional or a loop by rewinding its print
            \\cursor to the element's end tag. A void element (`<img>`, `<br>`,
            \\...) or a self-closing one has none, so the rewind goes to offset
            \\0 and the whole raw template source is spliced into the page --
            \\with exit code 0 -- or the slice runs backwards and panics.
            \\
            \\`:if`/`:loop` only ever affect an element's BODY anyway: the tag
            \\and all of its attributes are emitted either way. Wrap the element
            \\in a `<ctx>` that carries the directive instead:
            \\`<ctx :if="$cond"><img ...></ctx>`.
            ,
        },
        .ZP_TEMPLATE_ELSE_DIRECTIVE => .{
            .summary = "`:else` is parsed at parse time and never evaluated at render time",
            .explanation =
            \\SuperHTML validates `:else` while parsing and then has no case for
            \\it in the evaluator: it reads the attribute's value, which a bare
            \\`:else` does not have, and panics on the null unwrap. No template
            \\using `:else` has ever rendered.
            \\
            \\Write the negated condition on a second `<ctx>` instead:
            \\`<ctx :if="$cond">...</ctx>` followed by
            \\`<ctx :if="$cond.not()">...</ctx>`.
            ,
        },
        .ZP_TEMPLATE_MISSING_PARENT => .{
            .summary = "a template `:extends` a parent layout that doesn't exist",
            .explanation =
            \\The named parent template does not exist under
            \\`layouts_dir_path`. Check the name for a typo, and confirm the
            \\parent file wasn't renamed or moved.
            ,
        },
        .ZP_SUPERMD => .{
            .summary = "SuperMD reported a parse/scripty error in a content file's body",
            .explanation =
            \\A single code covers every SuperMD-reported error kind rather
            \\than one code per kind, because the underlying error tags come
            \\from `supermd`, a gitignored dependency synced at upstream
            \\release tags -- coupling the stable code space to that tag set
            \\would break at every sync. `message` carries `[<tag>] <text>`,
            \\where `<tag>` is SuperMD's own error-kind name -- read it for the
            \\specific problem; only `code` (this one) is a stability
            \\guarantee, the tag inside `message` is not.
            ,
        },
        .ZP_FATAL => .{
            .summary = "an internal or configuration fatal not yet assigned its own code",
            .explanation =
            \\This is the catch-all every `fatal.msg`/`fatal.usageError` call
            \\emits under `--format=json` until it is promoted to a dedicated
            \\code (see `docs/diagnostics.md`'s scope section for what's
            \\promoted so far and what isn't). `message` carries the same text
            \\the text-mode build would have printed, trimmed of surrounding
            \\whitespace. If you're scripting against this code specifically,
            \\you're scripting against unstable prose -- file a request to
            \\promote the specific fatal you depend on to a named code
            \\instead.
            ,
        },
    };
}

const frozen = @embedFile("diag-codes.frozen");

fn frozenSection(comptime header: []const u8) []const u8 {
    const start_marker = "[" ++ header ++ "]";
    const start = std.mem.indexOf(u8, frozen, start_marker).? + start_marker.len;
    const rest = frozen[start..];
    const end = std.mem.indexOf(u8, rest, "\n[") orelse rest.len;
    return rest[0..end];
}

/// Splits a `[SECTION]` slice of `diag-codes.frozen` into its non-blank,
/// non-comment lines. Contract 2 (owned-result, NO_SLOP §2.2a): the returned
/// list owns its backing array and the caller must `deinit(gpa)` it. The
/// elements are NOT owned -- they are slices into the comptime `@embedFile`
/// data, which outlives every caller, so freeing the list frees everything
/// this allocated. `errdefer` covers the partial list on an append failure.
fn frozenLines(section: []const u8, gpa: Allocator) !std.ArrayListUnmanaged([]const u8) {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, section, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try list.append(gpa, line);
    }
    return list;
}

test "diag: every Code appears in diag-codes.frozen [ACTIVE]" {
    const gpa = std.testing.allocator;
    const active_section = frozenSection("ACTIVE");
    var active = try frozenLines(active_section, gpa);
    defer active.deinit(gpa);

    inline for (@typeInfo(Code).@"enum".fields) |field| {
        var found = false;
        for (active.items) |line| {
            if (std.mem.eql(u8, line, field.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("Code.{s} has no matching line in [ACTIVE]\n", .{field.name});
        }
        try std.testing.expect(found);
    }
}

test "diag: every [ACTIVE] line is a Code" {
    const gpa = std.testing.allocator;
    const active_section = frozenSection("ACTIVE");
    var active = try frozenLines(active_section, gpa);
    defer active.deinit(gpa);

    for (active.items) |line| {
        const matched = std.meta.stringToEnum(Code, line) != null;
        if (!matched) {
            std.debug.print("[ACTIVE] line '{s}' does not match any Code field\n", .{line});
        }
        try std.testing.expect(matched);
    }
}

test "diag: no Code matches a [RETIRED] line" {
    const gpa = std.testing.allocator;
    const retired_section = frozenSection("RETIRED");
    var retired = try frozenLines(retired_section, gpa);
    defer retired.deinit(gpa);

    inline for (@typeInfo(Code).@"enum".fields) |field| {
        for (retired.items) |line| {
            if (std.mem.eql(u8, line, field.name)) {
                std.debug.print("Code.{s} reuses a RETIRED name -- pick a new one\n", .{field.name});
                try std.testing.expect(false);
            }
        }
    }
}

test "diag: [ACTIVE] is alphabetically sorted and has no duplicates" {
    const gpa = std.testing.allocator;
    const active_section = frozenSection("ACTIVE");
    var active = try frozenLines(active_section, gpa);
    defer active.deinit(gpa);

    for (active.items[1..], 1..) |line, i| {
        const prev = active.items[i - 1];
        if (std.mem.eql(u8, prev, line)) {
            std.debug.print("[ACTIVE] has duplicate line '{s}'\n", .{line});
            try std.testing.expect(false);
        }
        if (std.mem.order(u8, prev, line) != .lt) {
            std.debug.print("[ACTIVE] is not sorted: '{s}' should come after '{s}'\n", .{ prev, line });
            try std.testing.expect(false);
        }
    }
}

test "diag: every Code has a non-empty summary and explanation" {
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        const c: Code = @enumFromInt(field.value);
        const i = info(c);
        try std.testing.expect(i.summary.len > 0);
        try std.testing.expect(i.explanation.len > 0);
    }
}

test "diag: ZP_FATAL is registered" {
    // Named assertion because ZP_FATAL is the catch-all every not-yet-promoted
    // fatal.msg/usageError falls back to -- if it silently stopped compiling
    // (e.g. a typo during a future refactor), fatal.zig would fail to build.
    // This test exists anyway, as a directly-named guarantee.
    _ = info(.ZP_FATAL);
}

test "diag: parseFormat" {
    try std.testing.expectEqual(Format.json, parseFormat("json").?);
    try std.testing.expectEqual(Format.text, parseFormat("text").?);
    try std.testing.expect(parseFormat("xml") == null);
    try std.testing.expect(parseFormat("") == null);
}

test "diag: scanArgv finds --format=json anywhere before a bare --" {
    try std.testing.expectEqual(Format.json, scanArgv(&.{ "release", "--format=json" }).?);
    try std.testing.expect(scanArgv(&.{"release"}) == null);
    try std.testing.expectEqual(
        Format.json,
        scanArgv(&.{ "release", "--force", "--format=json", "-o", "out" }).?,
    );
}

test "diag: scanArgv stops at a bare -- (does not see the wrapped command's own flag)" {
    try std.testing.expect(scanArgv(&.{
        "e2e", "--site=x", "--", "mycmd", "--format=json",
    }) == null);
}

test "diag: emit round-trips through std.json, exact bytes and field order" {
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try write(.{
        .code = .ZP_LINK_NOT_A_SECTION,
        .severity = .@"error",
        .file = "content/a \"quoted\".smd",
        .line = 3,
        .col = 7,
        .message = "line one\nline two with a \" quote",
        .help = null,
    }, &w);

    const got = w.buffered();
    const want =
        \\{"code":"ZP_LINK_NOT_A_SECTION","severity":"error","file":"content/a \"quoted\".smd","line":3,"col":7,"message":"line one\nline two with a \" quote","help":null}
    ;
    try std.testing.expectEqualStrings(want, got);
}

test "diag: render truncates rather than failing on an oversized message" {
    var buf: [8]u8 = undefined;
    const got = render(&buf, "{s}", .{"this is definitely longer than eight bytes"});
    try std.testing.expect(got.len <= 8);
    try std.testing.expect(got.len > 0);
}

test "diag: render fits a normal message untruncated" {
    var buf: [64]u8 = undefined;
    const got = render(&buf, "unknown page '{s}'", .{"blog/foo"});
    try std.testing.expectEqualStrings("unknown page 'blog/foo'", got);
}
