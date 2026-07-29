### Added

- `zigapagos release --format=json` emits build diagnostics as NDJSON on stderr — one
  minified JSON object per line, `{"code","severity","file","line","col","message","help"}`
  — instead of the historical multi-line prose. The consumer this is for is an unattended
  agent: it can now tell *which* diagnostic fired without pattern-matching English. Default
  is `--format=text` and text mode is byte-for-byte unchanged.
- `code` is the stability guarantee; `message` and `help` explicitly are not.
  `src/diag-codes.frozen` is the append-only ledger that makes that a gate rather than a
  promise — a code is never renamed and never reused for a different meaning after
  retirement, enforced against the enum on every build.
- `zigapagos explain-code <CODE>` prints the long form of any code: what condition produced
  the diagnostic and what to change in the source. `zigapagos explain-code` with no argument lists
  every registered code with a one-line summary. Every code is required by the compiler to
  have both, so the listing cannot go stale relative to what the build emits.
- The two `:` directive lints get one code each rather than a shared one —
  `ZP_TEMPLATE_ELSE_DIRECTIVE` and `ZP_TEMPLATE_BRANCHING_WITHOUT_END_TAG` — because they
  are unrelated failures with unrelated fixes and `code` is what a consumer switches on.
- `docs/diagnostics.md` is the consumer contract: the wire schema, what is and is not
  stable, and an explicit inventory of what is *not* converted and why — including the
  rule that matters most, **skip a stderr line that does not parse as JSON rather than
  failing the run**, since the Bun sidecar and the usage-menu path legitimately write
  prose to the same stream.

### Fixed

- Under `--format=json`, a `fatal.msg` no longer aborts a Debug build with SIGABRT: it
  emits one `ZP_FATAL` object and exits 1. The `std.Progress` bar and the
  Debug/tracy/tsan warning banners are suppressed in that mode too, since all three write
  to the same stderr the NDJSON stream uses.
