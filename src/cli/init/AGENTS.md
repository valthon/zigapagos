# AGENTS.md — working on this zigapagos site

This site is built with [zigapagos](https://github.com/valthon/zigapagos), a
static site generator with TSX islands and native SPAs. This file is for
coding agents; humans are welcome too.

## Command names — two traps

- There is **no `build` command**: building the site is `zigapagos release`
  (outputs to `public/` by default).
- There is **no `serve` command**: the dev server is `zigapagos dev`
  (`zigapagos e2e --site=DIR -- CMD` is the one-shot serve-and-run variant).

Run `zigapagos help` for the full command list, and `zigapagos <cmd> --help`
for per-command flags.

## The build/fix loop

Use machine-readable diagnostics; never parse the prose output.

```sh
zigapagos release --format=json -o public
```

- Diagnostics arrive as NDJSON on **stderr**, one object per line:
  `{"code","severity","file","line","col","message","help"}`.
- **Match on `code`, never on `message`** — messages reword across releases;
  codes are frozen forever.
- Skip any stderr line that does not parse as JSON (other tools legitimately
  share the stream); never fail the run on one.
- For the long-form meaning of any code:
  `zigapagos explain-code <CODE>` (add `--format=json` for
  `{"code","summary","explanation"}`; output is on stderr — pipe with `2>&1`).

## Checking work

| Command | What it does |
| --- | --- |
| `zigapagos validate --format=json` | Fast in-memory subset of release's checks — no island SSR, no SPA checks, nothing written. A green validate is NOT a green release; it is the cheap first gate. |
| `zigapagos release --format=json -o public` | The real build. The full diagnostic surface. |
| `zigapagos doctor public --format=json` | Audits the BUILT tree (dangling internal links, root-relative og/canonical URLs). Findings as NDJSON on stdout: `{"check","severity","file","message"}` + a final summary object. |
| `zigapagos explain <route>` | Why a route renders the way it does: content source, layout chain, effective frontmatter. |

Exit codes: 0 = clean, non-zero = at least one error (for `doctor`, also when
any file was skipped). Warnings alone exit 0 (`doctor --strict` makes
warnings fail too).

## Layout

- `zigapagos.ziggy` — site config (Ziggy format).
- `content/` — pages (`.smd`: `---` Ziggy frontmatter `---` + SuperMD body).
- `layouts/` — SuperHTML templates (`.shtml`).
- `assets/` — site assets.
- `public/` — build output; never edit by hand.

Docs: <https://github.com/valthon/zigapagos/tree/main/docs>
