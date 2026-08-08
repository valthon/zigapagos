> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/diagnostics/> — the site is the canonical reading experience.

# Machine-readable diagnostics

`zigapagos release --format=json` emits build diagnostics as NDJSON
(newline-delimited JSON) on stderr, with a stable per-diagnostic `code`, rather
than prose. `zigapagos explain-code <CODE>` is the companion command for reading
the long-form meaning of a code.

This document is the consumer contract: the wire schema, what is and isn't
guaranteed, and what the stream covers.

## Enabling it

```sh
zigapagos release --format=json -o public
```

Default is `--format=text`. An invalid value fatals with a usage error naming
the accepted values:

```sh
zigapagos release --format=xml
# error: invalid --format value 'xml' (want text|json)
```

`--format` is accepted by `release` and `validate` (build diagnostics), plus
`doctor` (its own finding stream on stdout — see below). `release` and
`validate` share one stream and schema — `validate` covers the release
build's pre-SSR subset, see `zigapagos validate --help` for exactly what that
excludes. It is not a flag `dev` recognises: `dev` re-runs a rebuild command
and reports whatever that command printed.

## Wire schema

One JSON object per line on **stderr**, minified, UTF-8, LF-terminated:

```json
{"code":"ZP_LINK_NOT_A_SECTION","severity":"error","file":"content/other.smd","line":11,"col":1,"message":"this page has no subpages (page is not a section)","help":"a leading '.' means \"subpage of this section\", not a relative path -- to link a sibling page, use $link.page(\"...\")"}
```

Fields, in this exact declaration order (part of the schema — see
`src/diag.zig`'s `Diagnostic` struct):

| field      | type              | meaning |
| ---------- | ----------------- | ------- |
| `code`     | string            | **The stable identifier.** See [Stability](#stability). |
| `severity` | `"error"` \| `"warning"` | Whether this diagnostic, by itself, fails the build. |
| `file`     | string \| `null`  | Source path, relative to the content/layouts root, when the diagnostic names one file. `null` when it doesn't (e.g. a URL collision between two pages) or names more than one (folded into `message` instead). |
| `line`     | integer \| `null` | 1-based line, when known. |
| `col`      | integer \| `null` | 1-based column, when known. |
| `message`  | string            | Human-readable headline. **Not stable** — see [Stability](#stability). May be multi-line (embedded `\n`) when it wraps a foreign printer's block output (SuperHTML/ziggy). |
| `help`     | string \| `null`  | A short inline hint, when the diagnostic has one. This is **not** the long form — that's `zigapagos explain-code <CODE>`. |

## Consuming the stream: skip what doesn't parse

**stderr under `--format=json` is not guaranteed to be pure NDJSON.** Several
things legitimately write to the same stream outside this mechanism:

- The Bun sidecar (SSR, CSS minification) inherits stderr directly and prints
  its own diagnostics on failure.
- Page-render errors (SuperHTML template rendering, on worker threads) are
  prose — see [Coverage](#coverage).
- Two scan-time advisories in `src/root.zig` are prose: the site-wide-artifact
  alias warning (`aliases: ["404.html"]` on a non-root page) and the
  sectionless-directory warning (a content directory with pages but no
  `index.smd`). Neither touches `any_prerendering_error` — they are advisory
  only, and both are multi-line `note:`-style blocks whose value is in the
  prose.
- A missing `zigapagos.ziggy` hits `fatal.helpError()`, which prints the
  **whole usage menu** as prose, not a diagnostic (see below).

**The consumer rule: skip a line that does not parse as JSON. Never fail the
whole run on one.** Every diagnostic this mechanism produces does parse; a
non-parsing line means something outside it wrote to stderr, which is expected,
not a bug in the stream.

### `fatal.helpError()` stays prose

One fatal exit path is deliberately not a diagnostic: `fatal.helpError()` prints
the full top-level usage menu (the `Commands:` / `General Options:` listing),
not a single diagnostic — there is no sensible one-line NDJSON shape for "here
is the whole command reference." Concretely: running `zigapagos release
--format=json` in a directory with no `zigapagos.ziggy` prints plain prose plus
the usage menu on stderr, exit 1. This is the one place JSON mode still looks
like text mode.

## Stability

**`code` is the stability guarantee. `message` and `help` are not.**

- A `code`, once shipped, is permanent. `src/diag-codes.frozen` is the
  append-only ledger backing this: a code is never renamed and never reused
  for a different meaning after retirement. `src/diag.zig`'s `test "diag:
  ..."` blocks enforce this against the frozen file on every build.
- `message` is free-form prose. Several codes (`ZP_SUPERMD`,
  `ZP_TEMPLATE_PARSE`) wrap a **foreign** printer's output (SuperMD, a
  gitignored dependency synced at upstream release tags; SuperHTML's own
  error printer) — that text can and will reword across a sync. Match on
  `code`, never on `message` content.
- `help`, when present, is a short fixed hint tied to the code, not
  independently versioned — treat it the same as `message`: informative, not
  a contract.

Run `zigapagos explain-code <CODE>` for the long-form explanation of any code,
or `zigapagos explain-code` with no argument to list every registered code with a
one-line summary. That listing is the authoritative, always-current table of
codes; it is deliberately not duplicated into this page, which would drift.

`explain-code` writes to **stderr**, not stdout — same stream as the NDJSON
diagnostics above, and the same convention as `zigapagos languages`. So
`zigapagos explain-code 2>&1 | grep ZP_LINK` works and a bare `| grep` sees
nothing.

`explain-code --format=json` emits the same information as NDJSON on stderr:
one `{"code","summary","explanation"}` object per line (one line for a single
`CODE`, one per registered code for the no-argument listing) — the
machine-readable form of this registry.

## Coverage

The NDJSON stream covers **the whole prerender/analysis gate**: every diagnostic
that can set `build.any_prerendering_error` in `src/root.zig` (static asset
checks, i18n parsing, content parsing, frontmatter/page analysis, duplicate
translation keys, URL collisions, template parsing/linting), plus the warnings
printed in that same region (`ZP_EMPTY_PAGE`, and the warning-severity
`PageAnalysisError` kinds). On top of that, every `fatal.msg` /
`fatal.usageError` call anywhere in the codebase emits as `ZP_FATAL`.

What stays prose, and why:

| Source | Why |
| --- | --- |
| Page-render errors (`src/worker.zig`, SuperHTML rendering) | Produced on worker threads through a shared writer; the batching is not per-diagnostic. |
| The island props-check gate (`src/islands/props_check.zig`) | Its output is `tsc`'s own, passed through verbatim. |
| `fatal.helpError()`'s usage menu | No one-line NDJSON shape for a command reference — see above. |
| The two scan-time advisories | Advisory-only multi-line `note:` blocks; see the consumer rule above. |

Config-validation failures (bad `host_url`, bad `deploy_target`, …) do reach the
stream, as `ZP_FATAL` rather than under named codes of their own.

`zigapagos doctor` has its own stable check-id namespace (`abs-url-meta`,
`dangling-internal-link`, …) and does not emit this stream. It has its own
`--format=json`: one NDJSON object per finding on **stdout** (doctor's report
stream), shaped `{"check","severity","file","message"}` with `severity` one of
`"error"`/`"warning"`, followed by exactly one summary object
`{"errors","warnings","files","skipped"}` as the last line. `check` follows the
same stability rule as `code` here: stable once shipped; `message` is prose and
is not. Doctor fatals (a bad `DIR`) do emit on this page's stderr stream, as
`ZP_FATAL`.

SuperMD errors carry **one** code, `ZP_SUPERMD`, not one per error kind.
SuperMD's error *tags* (`scripty`, `html`, `duplicate_id`, …) come from the
`supermd` package, a gitignored dependency synced at upstream release tags, so
one code per tag would couple this stable code space to that upstream tag set.
The tag is carried inside `message` as `"[<tag>] <text>"`; only the outer
`ZP_SUPERMD` code is a stability guarantee.
