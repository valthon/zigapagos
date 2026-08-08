### Added

- `zigapagos validate --format=json` (issue #131): the fast pre-SSR gate now emits the same
  NDJSON diagnostic stream on stderr as `release --format=json` — same `ZP_*` code registry,
  same `{"code","severity","file","line","col","message","help"}` schema — so an agent's
  `release` → fix → `validate` loop never parses prose. In JSON mode the trailing
  `validate: FAILED` prose line is suppressed; the non-zero exit and the stream carry it.
- `zigapagos doctor --format=json`: each finding as one NDJSON object on **stdout** (doctor's
  report stream, distinct from the build-diagnostics stderr stream), shaped
  `{"check","severity","file","message"}`, followed by exactly one
  `{"errors","warnings","files","skipped"}` summary object as the last line. `check` ids
  (`abs-url-meta`, `dangling-internal-link`, …) are stable once shipped; `message` prose is
  not. Doctor fatals emit `ZP_FATAL` NDJSON on stderr. Text-mode output is byte-for-byte
  unchanged.
- `zigapagos explain-code --format=json`: the frozen code registry as NDJSON on stderr, one
  `{"code","summary","explanation"}` object per line — the machine-readable dictionary an
  agent reaches for after matching a `code`.
- `zigapagos init` now scaffolds `AGENTS.md` and `CLAUDE.md` into a new site (`CLAUDE.md` is
  exactly `@AGENTS.md`). The generated `AGENTS.md` documents the two naming traps (`build` is
  spelled `release`, `serve` is spelled `dev`), the `--format=json` fix loop, the
  match-on-`code`-never-`message` rule, and the exit-code semantics. Both ride the existing
  exclusive-create path — an existing file is skipped, never overwritten.
- The Astro migration ships as an installable Agent Skill: `skills/zigapagos-astro-migration/`
  in the open agentskills.io `SKILL.md` format (read by Claude Code, Codex, Cursor, Gemini CLI
  and others) — a workflow layer over the `zigapagos migrate` scan and the JSON fix loop, with
  the full deterministic mapping spec bundled under `references/`.

### Changed

- The `--format` pre-scan gate in `main.zig` (which suppresses stderr chatter before the
  authoritative parse) now covers `release`, `validate`, `doctor` and `explain-code`. It stays
  an explicit allowlist — a command joins it only in the same change that teaches its own
  parser the flag.

### Fixed

- The `--format` pre-scan disagreed with the command parsers on a repeated flag: it kept the
  **first** `--format=` value while every accepting parser keeps the **last**, so accepted
  input like `release --format=text --format=json` printed the Debug banner onto what the
  parser then treated as an NDJSON stream — reachable on released builds. The scan is now
  last-wins with the parsers' overwrite semantics, and a trailing invalid value resolves to
  "no format chosen", matching the parser about to fatal on it.
- `doctor --format=json` printed a mid-walk failure (an unreadable subdirectory encountered
  after the walk began) as prose straight onto the machine-readable stream; it now emits
  `ZP_FATAL` NDJSON in JSON mode, with text mode byte-identical.

### Internal

- `tests/skills/sync.sh` turns drift between `skills/zigapagos-astro-migration/references/*`
  and the canonical `docs/migration/*` into a red test (the reference copies must be
  byte-identical — an installed skill is self-contained), and checks the agentskills.io
  frontmatter invariants plus the progressive-disclosure line budget on `SKILL.md`.
- Four new shell gates cover the JSON surfaces and the scaffold, each verified to fail against
  the pre-change binary.
