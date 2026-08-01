> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/build-errors/> — the site is the canonical reading experience.

# Common build errors

The errors a new project actually hits, with what each one means and what to
change. Every message on this page was produced by running the binary — none is
paraphrased — and the table at the end pins each one to the source that emits
it, so a reworded message fails CI instead of silently making this page a lie.

This page is for humans reading a build log. Its machine-readable counterpart is
[Diagnostics](diagnostics.md): `--format=json` emits the same failures as NDJSON
with a stable `code`, and `zigapagos explain-code <CODE>` prints a long-form
explanation of any code named below.

## Links between pages

### `this page has no subpages (page is not a section)`

```
content/a.smd:9:5: error: this page has no subpages (page is not a section)
|    see [b](.b)
|        ^^^^^^^
|   note: a leading '.' means "subpage of this section", not a relative path -- to link a sibling page, use $link.page("...")
```

**Cause.** In SuperMD a leading `.` in a link target means *subpage of this
section*, not *relative path*. `(.b)` on a page that is not a section asks for a
child that cannot exist. This is the single most expensive misreading in the
project's own history: it produced 55 build errors in one sitting when
publishing existing Markdown, because `./b` and `.b` look like ordinary relative
links.

**Fix.** For a sibling, `[b]($link.page("b"))`. The leading-dot form is only for
a section page linking its own children.

Code: `ZP_LINK_NOT_A_SECTION`.

### `path is empty`

```
content/index.smd:8:4: [scripty] path is empty
|    go [home]($link.page(""))
|       ^^^^^^^^^^^^^^^^^^^^^^
|   note: to link to the site homepage, use $link.site()
```

**Cause.** `$link.page("")` is rejected. It looks like it should work because
`$site.page('')` *does* work in a `.shtml` layout — the shipped `base.shtml`
uses exactly that for its home link — so the prose form reads like the same
thing.

**Fix.** `$link.site()`, which is the content-side builtin for the site root.
The note is fork-added enrichment printed around SuperMD's own message; if an
upstream sync rewords `path is empty` the note stops firing and
`tests/rendering/empty-page-path-hint.sh` goes red rather than drifting.

Code: `ZP_SUPERMD`.

### `unknown page`

```
content/index.smd:9:5: error: unknown page
```

**Cause.** `$link.page("x")` names no page. The argument is a page *path* under
`content/`, without the `.smd` extension and without a leading slash —
`$link.page("blog/first")`, not `"/blog/first.smd"`.

**Fix.** Check the path. If the target is legitimately not built yet,
`--allow-missing-pages` downgrades this to a warning
(`ZP_MISSING_PAGE_TOLERATED`) and emits the link anyway.

Code: `ZP_UNKNOWN_PAGE`.

### `unknown ref`

```
content/index.smd:9:6: error: unknown ref
```

**Cause.** An in-page anchor (`[jump](#nope)`) whose target id does not exist.
SuperMD resolves anchors at build time rather than shipping a dead fragment, so
every `#…` link must name a real id.

**Fix.** Give the target heading an id — `[]($heading.id("nope"))` at the start
of the heading — or correct the anchor. Headings do **not** get slugs
automatically; see [Generated content](generated-content.md) for how this site's
own pipeline adds them.

Code: `ZP_UNKNOWN_REF`.

## Frontmatter and layouts

### `missing layout file`

```
content/index.smd:6:11: error: missing layout file
```

**Cause.** The page's `.layout` names a file that is not under
`layouts_dir_path`, or is not usable as a layout.

**Fix.** Check the name and the directory. The path is relative to the layouts
directory, extension included: `.layout = "index.shtml"`.

Code: `ZP_MISSING_LAYOUT`. Only `title` and `layout` are required in
frontmatter; `author`, `date` and `draft` have defaults.

### `unexpected '.', expected: ',' or '}' or '---' or 'EOF'`

```
content/index.smd:3:1:
    .layout = "index.shtml",
    ^
unexpected '.', expected: ',' or '}' or '---' or 'EOF'
```

**Cause.** The block between the `---` delimiters is a **Ziggy** struct literal,
not YAML. Every field is `.name = value`, and fields are **comma-separated**.
The example above is missing the comma after the previous field, so the parser
sees the next `.` where it wanted `,`.

**Fix.** A comma after every field except, optionally, the last one — the
error's own expected-set says so: after a value the parser will also take the
closing `---`. A trailing comma on the last field is the house style here and is
always accepted, so "comma after every field" is the rule that never bites.
Strings are double-quoted; dates are `@date("2020-01-01T00:00:00")`; booleans
are bare `true`/`false`.

Code: `ZP_FRONTMATTER_PARSE`.

## Assets

### `field not found` on `$site.asset(...)`

```
content/index.smd:8:1: [scripty] field not found
|    [css]($site.asset("nope.css").link())
|    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

**Cause.** The asset does not exist under `assets_dir_path`. The message is
Scripty's generic one for a failed lookup and does not name the file.

**Fix.** Check the path, which is relative to the assets directory. Note the
three asset scopes are distinct builtins with distinct roots:
`$site.asset(...)` for `assets_dir_path`, `$page.asset(...)` for files beside
the page, and `$build.asset(...)` for build-generated ones.

Codes: `ZP_MISSING_SITE_ASSET`, `ZP_MISSING_PAGE_ASSET`,
`ZP_MISSING_BUILD_ASSET`.

## Content

### `unknown code-fence language 'jsonc'`

```
content/index.smd:9:1: warning: unknown code-fence language 'jsonc'; emitting the block unhighlighted (did you mean 'json'?)
```

**Cause.** The fence's info string is not a registered syntax.

**This is a warning, not an error** — the block is emitted unhighlighted and the
build succeeds. It used to be fatal, with no list of accepted languages
anywhere, which made the loop "guess a language, wait two minutes, fail, guess
again". `zigapagos languages` prints the registered list, and a near-miss gets a
did-you-mean.

Code: `ZP_UNKNOWN_LANGUAGE`.

## Islands

### `unknown island directive`

```
unknown island directive 'client:visable' (expected load|idle|visible|media|only)
```

**Cause.** A typo, or an Astro directive with no counterpart here. The build
rejects it because the alternative is an island that renders and then silently
never hydrates.

**Fix.** One of the five. Their semantics are on the
[islands page](islands.md#hydration-directives-client).

### `props mismatch`

```
error: props mismatch on /  <island src="components/Hero.island.tsx" id="z-island-0">
  resolved props: {"headline":5}
  Type 'number' is not assignable to type 'string'. (TS2322)
```

**Cause.** The island's **resolved** props — `:props` merged with `prop-NAME`
overrides and any `$page.*` values — do not typecheck against the component's
exported `Props` type. A misspelled prop shows up here as an excess-property
error.

**Fix.** The `resolved props:` line is the actual JSON the island would have
received; compare it against `Props`. `--island-props-check=warn` downgrades the
gate while you work, and `off` disables it.

### `failed to spawn island sidecar`

```
error: failed to spawn island sidecar (/usr/bin/bun .../runtime/sidecar/render.ts): FileNotFound
```

**Cause.** The build could not start the Bun SSR sidecar. `FileNotFound` here
almost always means the **interpreter** — `bun` — is not at the path the build
was told to use, not that `render.ts` is missing.

**Fix.** Check that `bun` resolves (`command -v bun`) and matches the version
`mise.toml` pins. A site with no islands and no SPA never spawns the sidecar at
all.

## SPAs

### `dynamic route "…" declares no skeleton`

```
error: spa describe failed for app/app.spa.tsx: dynamic route "/club/:id" declares no skeleton — the build SSRs its shell at the base-relative path "/club/_" (every :param and * segment substituted with "_"), so its SSR output differs from the first client render, which breaks hydration. Give the route a param-independent `skeleton` component, or set `skeleton: false` to assert the component is hydration-stable without one.
```

**Cause.** A dynamic route is prerendered **once**, with every `:param` replaced
by `_`. A component that renders the real parameter would therefore produce
different markup on the server than on the first client render, and Preact's
`hydrate()` does not repair that.

**Fix.** Give the route a `skeleton` component that does not depend on the
parameter, or `skeleton: false` to assert the component is hydration-stable.
`staticPaths` is the third option: enumerate the concrete parameter values and
each gets its own real shell.

### `spa declares neither a "/" route nor any dynamic route`

**Cause.** An SPA that prerenders nothing. Every SPA needs at least one shell
for a host to serve.

**Fix.** Add a `{ path: "/", component: … }` entry — the
[SPA quickstart](spa.md#quickstart-the-smallest-spa-that-works) is the minimum
that works.

## Layouts

Three template mistakes fail the build with their own codes, all covered on the
[SuperHTML page](superhtml.md#these-do-not-exist): `:attr` is not a directive
(`ZP_TEMPLATE_BAD_DIRECTIVE_ATTR`), `:else` is parsed and never evaluated
(`ZP_TEMPLATE_ELSE_DIRECTIVE`), and `:if`/`:loop` on a void or self-closing
element can never work (`ZP_TEMPLATE_BRANCHING_WITHOUT_END_TAG`).

## Where each message comes from

Machine-checked. `tests/meta/build-errors-doc.sh` reads this table and fails if
a fragment is no longer present in the file that emits it, or if a code is not
`[ACTIVE]` in `src/diag-codes.frozen`. A row that cannot be greppable is the
defect this page exists to prevent: an invented error message is worse than no
page at all, because it sends a reader looking for something that never happens.

| Message fragment | Code | Emitted by |
|------------------|------|------------|
| `this page has no subpages (page is not a section)` | `ZP_LINK_NOT_A_SECTION` | `src/context/Page.zig` |
| `not a relative path -- to link a sibling page, use $link.page(` | `ZP_LINK_NOT_A_SECTION` | `src/context/Page.zig` |
| `to link to the site homepage, use $link.site()` | `ZP_SUPERMD` | `src/root.zig` |
| `unknown page` | `ZP_UNKNOWN_PAGE` | `src/context/Page.zig` |
| `unknown ref` | `ZP_UNKNOWN_REF` | `src/context/Page.zig` |
| `missing layout file` | `ZP_MISSING_LAYOUT` | `src/context/Page.zig` |
| `unknown code-fence language` | `ZP_UNKNOWN_LANGUAGE` | `src/context/Page.zig` |
| `unknown island directive` | `-` | `src/islands/pass.zig` |
| `props mismatch on` | `-` | `src/islands/props_check.zig` |
| `failed to spawn island sidecar` | `-` | `src/root.zig` |
| `declares no skeleton` | `-` | `runtime/src/router.ts` |
| ` route nor any dynamic route, so nothing ` | `-` | `src/spa.zig` |
