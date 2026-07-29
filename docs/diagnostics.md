# Machine-readable diagnostics

Issue #46 / DX-27. `zigapagos release --format=json` emits build diagnostics as
NDJSON (newline-delimited JSON) on stderr, with a stable per-diagnostic
`code`, instead of the historical multi-line prose. `zigapagos explain-code <CODE>`
is the companion command for reading the long-form meaning of a code.

This document is the consumer contract: the wire schema, what is and isn't
guaranteed, and the current coverage. It is **not** registered on the
marketing site (`site/scripts/docs-registry.json`) — see [Scope](#scope)
below for why, and what a future PR would do about it.

## Enabling it

```sh
zigapagos release --format=json -o public
```

Default is `--format=text` (unchanged prose). An invalid value fatals with a
usage error naming the accepted values:

```sh
zigapagos release --format=xml
# error: invalid --format value 'xml' (want text|json)
```

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
  still prose — see [Scope](#scope).
- A missing `zigapagos.ziggy` hits `fatal.helpError()`, which prints the
  **whole usage menu** as prose, not a diagnostic (see below).

**The consumer rule: skip a line that does not parse as JSON. Never fail the
whole run on one.** Every line this PR's converted call sites produce does
parse; a non-parsing line means something outside this mechanism wrote to
stderr, which is expected, not a bug in the stream.

### `fatal.helpError()` stays prose

The one call site that is deliberately **not** converted, even though it's a
fatal exit path: `fatal.helpError()` prints the full top-level usage menu (the
`Commands:` / `General Options:` listing), not a single diagnostic — there is
no sensible one-line NDJSON shape for "here is the whole command reference."
Concretely: running `zigapagos release --format=json` in a directory with no
`zigapagos.ziggy` still prints plain prose plus the usage menu on stderr, exit
1. This is the one place JSON mode still looks like text mode.

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
one-line summary.

`explain-code` writes to **stderr**, not stdout — same stream as the NDJSON
diagnostics above, and the same convention as `zigapagos languages`. So
`zigapagos explain-code 2>&1 | grep ZP_LINK` works and a bare `| grep` sees
nothing. That is a deliberate consistency choice rather than the ideal one for
a listing command, and moving informational CLI output to stdout is listed as
a follow-up in [Scope](#scope) below.

## Scope

**Converted in this PR:** every diagnostic that can set
`build.any_prerendering_error` in `src/root.zig` (static asset checks, i18n
parsing, content parsing, frontmatter/page analysis, duplicate translation
keys, URL collisions, template parsing/linting), plus the two warnings printed
in that same region (`ZP_EMPTY_PAGE`, and the warning-severity
`PageAnalysisError` kinds), plus a catch-all: every `fatal.msg` /
`fatal.usageError` call anywhere in the codebase emits as `ZP_FATAL`. That is
a complete phase — the whole prerender/analysis gate — not a sample.

**Not converted, deliberately** (each is a candidate follow-up issue):

1. **Page-render errors** (`src/worker.zig`, SuperHTML template rendering).
   These are produced on worker threads through a shared writer; converting
   them means restructuring that batching under concurrency, which is out of
   scope here.
2. **The island props-check / `tsc` gate** (`src/islands/props_check.zig`).
   Its output is `tsc`'s own, passed through verbatim. A per-mismatch
   `ZP_ISLAND_PROPS_MISMATCH` wrapper is a reasonable follow-up.
3. **Config-validation fatals** (`src/root.zig`, `Config.load`/`validate`,
   roughly 25 `fatal.msg` call sites). All of these already emit as
   `ZP_FATAL` under `--format=json` — promoting the common ones (bad
   `host_url`, bad `deploy_target`, …) to named codes is mechanical, now that
   the `ZP_FATAL` path itself is proven out end to end (see the `ZP_FATAL`
   test phase in `tests/diagnostics/format-json.sh`, which pins that this
   path exits 1 cleanly rather than panicking under a Debug build).
4. **`fatal.helpError()`'s usage-menu path** — see above, stays prose by
   design, not by omission.
5. **`zigapagos doctor --format=json`.** `doctor` already has its own stable
   check-id namespace (`abs-url-meta`, `dangling-internal-link`, …);
   unifying the two namespaces (or leaving them separate but documenting
   both from one place) is a design decision, not a mechanical port.
6. **`serve` / `dev`.** The consumer this issue is written for is an
   unattended agent running `zigapagos release`. The live server's in-memory
   error list (`build.mode.memory.errors`) is untouched — `--format=` is not
   even a recognised flag there.
7. **No generated code table on this page.** The table of every code (past
   the schema above) lives only in `zigapagos explain-code`'s output, not
   duplicated here by hand or by a docgen pass. `zigapagos explain-code` (no
   argument) is the authoritative, always-current listing; a docgen'd table
   plus a drift gate pinning it against `src/diag-codes.frozen` is a
   reasonable follow-up.
8. **This page is not registered in `site/scripts/docs-registry.json`** — it
   is not published on the marketing site yet. Registering it pulls in the
   marketing-site nav entry and the mirror-freshness gate, which is a
   separate piece of work from shipping the mechanism; a follow-up.
9. **One `ZP_SUPERMD` code, not one per SuperMD error kind.** SuperMD's error
   *tags* (`scripty`, `html`, `duplicate_id`, …) come from the `supermd`
   package, a gitignored dependency synced at upstream release tags — one
   code per tag would couple this PR's stable code space to that upstream
   tag set. The tag is carried inside `message` (`"[<tag>] <text>"`)
   instead; only the outer `ZP_SUPERMD` code is a stability guarantee.
10. **stderr is not pure NDJSON** — covered above, repeated here because it's
    the single most likely thing to trip up a naive consumer.
11. **`explain-code`'s own output is not part of this stream** — it prints human
    prose to stderr, not NDJSON and not stdout. stderr is what `zigapagos
    languages` (the sibling informational subcommand) already does, so this
    PR does not split the two adjacent listing commands across two streams.
    Moving them both is a CLI-wide change with a real behavioural edge — a
    stdout writer makes `explain-code | head` an EPIPE that `src/cli/doctor.zig`'s
    established convention turns into a `fatal.msg` — so it wants its own
    issue and its own regression test, not a drive-by here.
