# Upgrade an existing site to Ziggy 0.3.0

Commit your site before upgrading. Use the converter shipped in this repository
(Python 3, no packages required), from a checkout of Zigapagos:

```sh
python3 scripts/upgrade-ziggy.py /absolute/path/to/your/site
cd /absolute/path/to/your/site
zigapagos install-schemas
zigapagos release --force
```

Review the diff and compare the rendered output with your previous release.
The converter accepts directories or individual `.ziggy` and `.smd` files and
is safe to run twice. It skips dependency, cache and output directories and
symlinks. It preserves strings and comments, except for CRLF normalization. Whitespace
and comment-terminating newlines stay in place; the converter does not format
them away. Insignificant spacing can therefore differ from the examples below.
Comments between legacy `.`/`@` prefixes, names and tag parentheses are preserved
too, while their replacement syntax is made contiguous for the new tokenizer.
Author and pagination enum migrations apply only to page frontmatter; arbitrary
data-file field names and custom values retain their meanings.
It changes only the frontmatter and its delimiters in `.smd` files: every byte
of the body below the closing delimiter is preserved, including CRLF and code
examples. Config and data files are normalized throughout. Malformed framing
or a non-string old author field requires manual repair; the tool reports the
file and exits nonzero. Copy the script into an existing site's `scripts/`
directory if you want the diagnostic's suggested relative command to work there.

The old config form `Site { ... }` becomes:

```ziggy
.site = .simple(.{
    .title = "My site",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .custom = { "organization": "Example" },
    .supermd = .{ .auto_target_blank = true },
})
```

Use `.site = .multilingual(.{ ... })` for a multilingual site; each locale
record starts with `.{`. The config keeps its name, `zigapagos.ziggy`. There is
no version field. Existing fork settings keep their meanings. `static_assets`
still lists file names or existing globs; this upgrade adds no directory entries.
`$site.custom.get('organization')` reads the dictionary above.

Legacy quoted dates such as `.date = "2024-01-01"` are also wrapped as
`.date = .date("2024-01-01")` by the converter.

In frontmatter, replace `@date("2024-01-01T00:00:00")` with
`.date("2024-01-01T00:00:00")`, or use `.unix(1704067200)` for epoch seconds.
Replace `.author = "Jane"` with `.authors = ["Jane"]`; an empty author becomes
`[]`. In templates use `$page.authors.join(', ')` to display names, or loop over
the list. An omitted authors field is an empty list; an omitted date remains
the Unix epoch. Title and layout remain required.

Struct literals now start with a dot: `{ .a = 1 }` becomes `.{ .a = 1 }`.
Dictionaries use quoted keys and no dot: `{ "a": 1 }`. This applies to nested
frontmatter records, alternatives, pagination, asset data and island `:props`
literals. The file converter handles config/data files and frontmatter; update
inline Ziggy in templates, scripts and body examples manually. Pagination uses
enum literals such as `.url_style = .plain_dir` (also converted automatically). The converter
changes an old custom record to a dictionary; review named nested records manually.
Optional fields, slices and dictionaries may be omitted.

Ziggy rejects carriage returns and most control bytes. The converter normalizes
CRLF to LF in config/data and frontmatter. Remove other invalid controls by hand.
A carriage return in the Markdown body is outside Ziggy's document.

`zigapagos install-schemas` writes `.zigapagos.ziggy-schema` beside the config
and `.smd.ziggy-schema` into each configured content directory. `init` includes
these files. Configure your editor to run the Ziggy LSP on `.ziggy`,
`.ziggy-schema` and `.smd`. Rerun the command after future schema changes;
the shipped sources in `src/schemas/` are authoritative. The former root
`frontmatter.ziggy-schema` is removed. Schemas provide editor assistance and do
not override the compiled runtime types.

External Markdown links still open a new tab by default. Set the site's
`.supermd = .{ .auto_target_blank = false }` to disable that default. Explicit
per-link choices still apply. Heading baseline behavior and all existing
Scripty builtin signatures are preserved except that `Array.first?()` and
`Array.last?()` now declare optional returns (`?any`) instead of arrays; their
runtime results are unchanged. Reference array types now use
`[]String`; variadic parameters retain `[String...]`.

## Manual steps the converter does not perform

The converter intentionally leaves these cases for review. Finish them before
building, including occurrences in custom data and island props:

| Legacy spelling or case | Manual step |
| --- | --- |
| Named nested records, e.g. `Alternative { … }` | Replace the name and brace with `.{ … }`. The type name is lost; the destination field determines the record type. |
| Tagged strings, e.g. `@kind("value")` | Write `.kind("value")`; keep the tag when it carries application meaning. |
| Tagged pagination enums, e.g. `.url_style = @enum("plain_dir")` | Write `.url_style = .plain_dir` (likewise `.page_dir` or `.page_html`). |
| `\u{…}` escapes | Replace each code point with literal UTF-8, or a supported `\uXXXX` escape where representable. |
| Single-quoted dates, e.g. `.date = '2024-01-01'` | Use `.date = .date("2024-01-01")`. |
| Multiline (`\\`) author strings | Replace the old `.author` with `.authors = ["Name"]`, choosing the intended names explicitly. |
| Comments before the opening frontmatter fence | Move the opening `---` to the start of the file; move comments inside the frontmatter or into the body. |
| An indented closing frontmatter fence | Put the closing `---` at column one. |
| `.skip_subdirs = …` | Delete it. `forbid_subsections` is a separate section validation rule, **not a rename**; omit unwanted content from the content tree instead. |
| Duplicate dictionary keys | Choose one value per decoded key and remove the duplicates. Duplicates now fail, including differently escaped spellings of the same key. |
| Inline Ziggy in templates, scripts or Markdown bodies | Update these literals by hand: struct `.{ … }`, dictionary `{ "key": value }`, union `.tag(value)` and enum `.tag`. Bodies are deliberately preserved byte for byte. |
| `$page.author` in templates | Use `$page.authors.join(', ')` or loop over `$page.authors`. |

Named nested records may retain their old type name after conversion; remove it
rather than treating it as a string or a union tag. Inspect all converter output,
not just files for which it printed a diagnostic.
