# Rails Presentation Stage 5 — Parity and Handoff

> Execute one task at a time. Read the matching brief and the durable ledger in
> `.superpowers/sdd/2026-08-30-rails-presentation-stage5/` first. The ledger's
> later rulings bind when they conflict with this plan.

**Goal:** finish issue #167 with a typed, deterministic `parity[]` handoff,
fixed target-side parity and browser-journey runners, and an end-to-end proof
against the stock ZigBase binary. A generated migration must be able to replay
page, asset, authentication, authorization, mutation, and validation evidence
without generated test logic.

**Stacking:** this stage starts at Stage 4 PR #190's tip on
`feature/167-stage5-parity`. Do not publish the Stage 5 PR until David has
merged #190; then rebase these commits onto `main`, verify the tree, and push
only the Stage 5 branch. Never push `main`.

**Spec:** `docs/superpowers/specs/2026-08-29-rails-presentation-migration-design.md`,
especially “Parity kinds”, “Parity e2e”, documentation, and Staging item 5.
Stage 2–4 rulings continue to bind.

## Global constraints

- `src/cli/rails/` remains std-only. Owned-result and caller-buffer functions
  document their allocator contracts and pass the repository allocator gate.
- Identical input produces byte-identical output. Every parity row and every
  list inside an expectation has a documented total order and deduplication
  rule. No timestamp, random credential, absolute path, or machine path is
  written to the handoff.
- Generated target writes retain exclusive-create semantics; the Rails source
  tree is never written.
- `test/parity.ts` and `test/journey_playwright.py` are fixed byte templates.
  They read `MIGRATION.handoff.json`; no per-route TypeScript or Python source
  is generated.
- Each regression is observed red before its implementation and important
  semantic branches get mutation checks. Run focused gates per task and the
  full handover gate set before history curation.
- Commit each task with explicit paths and the trailers:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4`.
- Use `ZIG_GLOBAL_CACHE_DIR=/tmp/zigapagos-global-zig-cache`. Host-only Bun,
  browser, schema-apply, or ZigBase commands use `TMPDIR=/tmp` and escalation
  when the sandbox denies their runtime/cache or loopback needs.

## Binding Stage 5 rulings

- **P1 — typed wire shape.** `ParityEntry.kind` is an enum and `expect` is a
  tagged union serialized as the payload object itself, not as `{tag,value}`.
  The schema correlates each kind with its expectation through `oneOf` arms.
  Navigation expects `status`, nullable `title`/`h1`, and sorted unique links;
  assets expect `status`, `content_type`, and optional `rails_url`.
- **P2 — replay inputs live beside expected outputs.** Auth and mutation
  expectation payloads also carry the minimum deterministic replay facts:
  collection, operation, method, and sorted field names/default scalar values.
  These are not hidden generator logic; they are the evidence that makes a
  handoff row replayable. Values are harmless fixed fixtures (`parity@example.invalid`,
  a non-secret password, `zigapagos parity`, `1`, `true`). Runtime uniqueness
  is added in memory by the runner and never written to disk.
- **P3 — evidence only.** A row is emitted only from a written migrated
  artifact or an applied endpoint binding. Navigate facts come from converted
  view/layout node facts, not by reparsing generated HTML and not from the
  runner's response. Asset facts come from copied deterministic assets.
  Mutation facts come from bound form fields plus the selected backend
  operation. No open, retained, or blocked route produces a row.
- **P4 — literal presentation facts.** The first statically knowable `<h1>`
  and literal links are collected by the Rails sidecar fragment stream before
  conversion; dynamic values are `null`/omitted rather than guessed. Layout
  links are unioned with view links. Target URLs are resolved through the same
  route-helper/asset resolver used by conversion. Title uses conversion's
  existing literal title result. Links are sorted and unique.
- **P5 — mutation coverage.** Every applied non-public mutation endpoint gets
  `submit_denied`, even when it has no form payload. Every bound form endpoint
  gets `submit_allowed`; when it has a required field it also gets
  `validation_error` by blanking that field. Auth journeys produce `signup`
  and/or `signin` rows from the answered auth collection. Unsupported scalar
  input shapes remain replayable as strings because generated form controls
  submit strings; a missing required field suppresses only `validation_error`,
  never the authorization proof.
- **P6 — runner phases.** The fixed Bun runner validates static navigation and
  assets first, then signs up/signs in once per auth collection, then executes
  denied requests without a token, allowed requests with the saved token, and
  invalid requests with the token. It checks the declared expectation on the
  Zigapagos origin. With `RAILS_ORIGIN`, only requests whose payload declares a
  Rails URL are replayed there and presentation results are diffed; Rails is an
  optional oracle, not a prerequisite for the stock-ZigBase e2e.
- **P7 — browser responsibility.** The Playwright runner consumes the same
  rows but drives rendered labels/fields through the existing emitted auth and
  form islands. It proves signup → signout/signin → allowed submit → rendered
  validation error. It locates system Chrome with the same policy as
  `init_from_astro`; lack of Playwright/Chrome skips loudly in the shell e2e,
  while an installed browser that fails the journey is a failure.
- **P8 — real server.** `rails-presentation-parity.sh` never substitutes the
  development stub. It locates `REAL_ZIGBASE`, PATH, or the pinned cache; it
  may explicitly request the pinned download. It applies the fixture schema
  to the same data dir passed to `zigapagos e2e`, builds the generated target,
  and runs Bun plus Playwright against that stock binary. Missing Bun or an
  unavailable real binary skips loudly and successfully; a located binary's
  failure is fatal.
- **P9 — schema ownership.** Extend the generic schema walker only where the
  new tagged-union contract requires it. Hand-maintained special casing keyed
  on a field or type name is forbidden. Both checked-in schemas regenerate
  byte-identically and the drift trap stays green.
- **P10 — scope.** Stage 5 does not make the Rails fixture a bootable Rails
  application, does not implement Turbo Streams (#189), and does not convert
  controllers or ActiveRecord. `RAILS_ORIGIN` support is exercised by unit
  tests of the runner contract; the required integration proof is generated
  target plus real ZigBase.

## Task 1 — Typed parity contract and schema

**Files:** `src/cli/rails/handoff.zig`, `src/cli/rails/schema_gen.zig`,
`contract/rails-migration-handoff.schema.json`, contract drift tests.

- Add the seven parity kinds and typed expectation payloads, including a small
  JSON-scalar/request-field vocabulary and custom serialization for tagged
  payload unions.
- Teach the structural schema generator to describe tagged unions as correlated
  `oneOf` object arms. Keep the existing empty Stage 4 golden byte-identical
  except for the schema contract itself.
- Make `handoff.build` accept, own/sort, and emit caller parity rows; reject a
  kind/payload mismatch at compile time, and test ordering, serialization,
  parsing, freeing, and failing allocators.

## Task 2 — Derive presentation and endpoint evidence

**Files:** Rails sidecar fragment extraction/tests, `fragments.zig`,
`scaffold.zig`, `backend.zig`, `handoff.zig`, `migrate.zig`.

- Add explicit sidecar facts for static heading text and literal anchor hrefs;
  do not add an HTML parser on the Zig side. Preserve source location and
  distinguish dynamic content.
- Carry owned parity seeds through the view/layout caches and final scaffold
  result before those caches are freed. Union layout/view links and resolve
  helpers with the existing conversion resolver.
- Retain sorted form field facts and the selected backend operation/access long
  enough to derive P5 rows. Extend backend request facts only as needed for
  deterministic scalar defaults; do not broaden backend matching.
- Build the final rows in `migrate.zig` after scaffold outcomes are known and
  pass them to `handoff.build`. Test duplicate routes, shared layouts, dynamic
  headings/links, retained pages, public/conditional operations, and OOM.

## Task 3 — Emit the fixed parity and journey runners

**Files:** `src/cli/rails/scaffold.zig` and its tests.

- Emit `test/parity.ts` and `test/journey_playwright.py` exactly once whenever
  the handoff has at least one parity row; include both in route artifacts only
  where the existing project-file policy requires shared artifacts.
- Bun runner: validate the handoff schema version, use `fetch` and the shipped
  `@zigbase/client` API/auth store, implement P6 phases, useful per-row errors,
  and a nonzero exit when any row fails.
- Browser runner: reuse the repository Chrome discovery/server-origin pattern,
  drive the generated islands, and fail with a row id and visible state.
- Pin fixed bytes, absence on empty parity, deterministic writes, exclusive
  create behavior, and allocator failures.

## Task 4 — Expand and pin the presentation fixture

**Files:** `tests/migrate/rails-presentation/**`,
`tests/migrate/rails-presentation.sh`, `tests/migrate/rails.sh` as required.

- Add a conventional `posts#new`/`posts#create` title form and bind it to the
  conditional `createPosts` operation. Keep the source non-bootable per P10.
- Regenerate decisions and pin exact nonempty parity JSON: navigate, assets,
  signup/signin, allowed/denied create, and title validation.
- Pin runner bytes/listing, route artifacts/notes, deterministic second run,
  source untouched, target build, SSR/doctor, and no-backend behavior.
- Execute semantic mutations that remove one navigate fact, invert endpoint
  access, and blank the validation field; demonstrate each test fails.

## Task 5 — Real-ZigBase parity e2e

**Files:** add `tests/migrate/rails-presentation-parity.sh`; adjust build/test
registration only if this repository explicitly enumerates migrate scripts.

- Build the CLI and answered target, locate a real ZigBase per P8, apply
  `tests/migrate/rails-presentation/backend/schema.json` into an isolated data
  directory, and run the emitted Bun parity runner under `zigapagos e2e`.
- Run the emitted Playwright journey against the same stock server/data model.
  Ensure repeatability with a fresh data dir and runtime-unique credentials.
- Loudly distinguish missing-tool skips from failures. Add shell syntax and
  static contract assertions so CI still tests the script when its optional
  runtime tools are absent.

## Task 6 — Support matrix, skill, and generated handoff guide

**Files:** `docs/migration/rails-to-zigapagos.md`, mirrored skill references and
`SKILL.md`, `src/cli/init/AGENTS.md`, `CHANGELOG.md`, sync tests if needed.

- Add the supported Rails frontend matrix with converted/decided/blocked
  status, the classification-to-artifact table, and Turbo/Stimulus/React/Vue
  mapping. State the enforcement boundary and Stage 5 parity limitations.
- Add skill steps 5–8: generate target, answer findings, rerun to complete,
  replay parity, then hand off to `zigbase-zigapagos-fullstack`.
- Document the two fixed runners and `RAILS_ORIGIN`; mirror bytes exactly and
  update generated AGENTS guidance. Add a changelog entry for completed #167.
- Run documentation, branding, confidentiality, and sync gates.

## Task 7 — Final review, history, and PR

- Run all handover gates, every Ruby test, every `tests/migrate/rails*.sh`
  including the new parity e2e, contract drift after a checkpoint commit, an
  independently generated target build/doctor, and allocator checks.
- Review the integrated diff against this plan/spec and resolve every finding.
  Curate fix commits into their task chapters and prove pre/post trees equal.
- Wait for #190 to merge if necessary; rebase onto current `main`, rerun the
  proportional full gates, push `feature/167-stage5-parity`, and open a PR on
  `valthon/zigapagos` whose body starts `Part of #167`. David merges.
