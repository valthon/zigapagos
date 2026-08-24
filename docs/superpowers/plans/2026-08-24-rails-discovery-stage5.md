# Rails discovery Stage 5 — target assembly, docs, and the skill mirror

**Spec (binding authority):** `docs/superpowers/specs/2026-08-22-rails-source-discovery-design.md`
**Issue:** #166 — **this stage closes it.** Depends on Stages 1-4 (PRs #168,
#169, #170, #171, #172, #173 — all merged).

Stage 4 made `migrate` emit a versioned, schema'd, drift-gated manifest beside
`MIGRATION.md`. Stage 5 is the last of the five: `--target DIR` assembly, the
migration guide, its skill mirror, and the sync gate that keeps the two
byte-identical.

`src/cli/migrate.zig:833` currently fatals with *"--target is not yet supported
for Rails sources; target assembly lands in a later stage"*. That placeholder is
this stage's starting point.

---

## Global constraints

- `src/cli/rails/` is **std-only**: no `@import` may escape that directory.
  `migrate.zig` is outside it and may import normally.
- Every allocator-taking function states which NO_SLOP.md §2.2a contract it
  satisfies, on **every error path**. A wrong label is worse than none, and the
  allocator gate does NOT check label accuracy — three functions on this feature
  were found mislabelled.
- **The source tree is read-only.** Hash it before and after; the spec makes this
  a test, not a promise.
- **Outputs never clobber**: `.new`, `.new.2`, … is the inherited invariant.
- **Determinism**: the manifest is diffed byte-for-byte by `rails-check`. The
  same app from two differently-named directories must produce identical output.
- Degradation stays **exit 0** without `--strict`; a degraded run still emits
  both artifacts.
- Any new blocker code must be registered in the spec's table under "Emitted
  today" — that table is the schema's registry and the gate's input.

## Testing standard

Tasks state the **property a test must discriminate and what the wrong answer
looks like**; the implementer writes the assertion. Nine defects on this feature
came from plan-supplied test code.

Mutate by LINE NUMBER or by deleting the line — never string search, which
rewrites the production literal and the test's identical literal together and
reports a false green. **Verify the mutation actually applied** before trusting
green. **Restoring: `git checkout -- <path>` only when the file's ONLY change is
the mutation; a copy when it holds uncommitted work — and check the backup path
exists.** Both idioms failed on this feature in opposite directions, one
destroying uncommitted work and one silently no-op'ing.

---

## Task 1 — `--target DIR` for Rails

**Files:** `src/cli/migrate.zig`.

Replace the placeholder fatal. Per the spec, `--target DIR` "produces both in
`DIR`" — `MIGRATION.md` and the manifest.

`--target` is already mutually exclusive with `--output`/`--scaffold`/
`--convert-content`/`--copy-assets`, and already fatals when DIR is nested or
non-empty. Reuse that machinery rather than adding a Rails-specific path;
read how the eight existing sources use it first.

**What `--target` must NOT do for Rails.** The other sources assemble a project:
content conversion, island scaffolding, asset copying. **Rails converts
nothing** — that is #167, and the spec is explicit that this work "converts
nothing". So Rails' `--target` writes the two discovery artifacts and no
scaffold. If that makes the flag's help text wrong for Rails, fix the help text;
do not invent a conversion to justify the flag.

**Discriminate:** that both artifacts land in DIR and nowhere else, and that the
manifest is byte-identical to the same app's `-o` run. A test asserting only
that DIR is non-empty passes against an implementation that writes one file, or
that writes a scaffold Rails should not have.

## Task 2 — a Sprockets fixture, end to end

**Files:** `tests/migrate/rails-legacy-assets/**`, `tests/migrate/rails.sh` or a
sibling script.

`assets.zig` resolves Sprockets assets through a compiled manifest, and that
branch has unit tests but **no fixture**: the only `sprockets` string in the
whole fixture tree is a COMMENTED-OUT gem, used to prove commented gems are not
detected. So the branch that reads a real Sprockets manifest has never run
end to end.

The spec asks for a `legacy-assets` app — "Sprockets, digests, preprocessors".
Build the smallest one that exercises the real path: a Gemfile declaring
`sprockets-rails`, a compiled `public/assets/.sprockets-manifest*.json` (or
whatever the resolver actually looks for — **read the resolver, do not guess the
filename**), and at least one asset it lists plus one it does not.

**Discriminate:** a listed asset resolves to its digested URL as a FACT, and an
unlisted one reports `public_url: null` with `deterministic: false` and a
blocker. A fixture where every asset resolves passes against a resolver that
ignores the manifest and guesses.

**Confirm every new fixture file is tracked** with
`git archive HEAD tests/migrate/<dir> | tar -t`. A file silently swallowed by
`.gitignore` passes locally and fails in CI — that exact defect hit Stage 1.

## Task 3 — `docs/migration/rails-to-zigapagos.md`

**Files:** `docs/migration/rails-to-zigapagos.md`.

Read `docs/migration/astro-to-zigapagos.md` first for the house register: this
is a deterministic mapping spec written so an agent can work from it unattended,
not a tutorial.

It must be **honest about what discovery does and does not do**, because that is
the whole value of the artifact:

- what each of the six classifications means, and that `content` is the only one
  asserting a page is safely static;
- that `spa` is never assigned — Stage 3 declines to guess, and the enum value
  exists because the schema declares it;
- what `unresolved` obliges a human to do, per rule;
- that `severity` and `integrity` are different axes and only `integrity` drives
  the exit code;
- that `--strict` fails on ANY blocker;
- that conversion is #167 and this converts nothing.

Point at the manifest as the machine-readable contract and the schema as its
description. Do not imply a complete migration path.

## Task 4 — the skill mirror and its gate

**Files:** `skills/zigapagos-rails-migration/**`, `tests/skills/sync.sh`.

`tests/skills/sync.sh` byte-compares `skills/zigapagos-astro-migration/
references/*` against `docs/migration/*` — with a **hardcoded** skill name and a
**hardcoded** three-file list. Adding a second skill means restructuring that
loop, not appending to it.

**This is the trap this stage was warned about**: the doc, its skill copy, and
the gate's list must land in the SAME commit, or the gate passes while the
mirror is absent, or fails on a file nobody added yet.

Mirror the astro skill's structure: `SKILL.md` with `name:` exactly matching the
directory and a `description:`, plus `references/rails-to-zigapagos.md` as a
byte copy.

**Discriminate:** that the gate FAILS when the copy drifts from the canonical
doc, and fails when the copy is missing entirely. A gate asserting only that
both files exist passes against two files with different contents — which is the
precise failure it exists to prevent.

## Task 5 — changelog, and closing #166

**Files:** `changelog.d/`, the spec's staging section.

Changelog honest about scope: discovery and classification are complete and
emit a versioned manifest; **conversion is #167 and has not started**.

Mark Stage 5 done in the spec's staging list. `#166` closes with this stage —
so the PR may say `Closes #166`, unlike every previous stage's `Refs`.

---

## Exit criteria

- `--target DIR` writes both artifacts for a Rails app and no scaffold.
- The Sprockets path runs end to end against a real fixture.
- `docs/migration/rails-to-zigapagos.md` exists and its skill copy is
  byte-identical, with the gate covering BOTH skills and proven to fail on
  drift.
- Source tree read-only, outputs non-clobbering, determinism intact.
- Every gate green, every emitted code registered.

## Not in this plan

#167 — ERB-to-TSX conversion, backend endpoint mapping, ZigBase auth and CSRF,
Turbo/Stimulus behavioural migration, browser parity. Permanently out of scope
per the issue's non-goals: converting ActiveRecord, controllers, jobs, mailers
or database data.
