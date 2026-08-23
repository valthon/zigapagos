# Rails discovery Stage 4 — the versioned manifest

**Spec (binding authority):** `docs/superpowers/specs/2026-08-22-rails-source-discovery-design.md`
**Issue:** #166. **Depends on:** Stages 1-3 (PRs #168, #169, #170, #171 — all merged).

Stage 3 made every route carry a classification and a reason. Those verdicts
currently exist only as prose in `MIGRATION.md`. **The manifest is the
deliverable; `MIGRATION.md` is a rendering of it** (spec, "The manifest"), and
Stage 5's `--target` assembly consumes the manifest, not the prose. This stage
produces it, versions it, and gates it against drift.

---

## How this plan differs from Stage 3's, and why

Stage 3 shipped, but **nine defects in it were traced to this plan file's own
text**, several of which would have shipped a silently-broken page. Two changes
follow from that, and they bind every task below.

### 1. Tasks specify the PROPERTY a test must discriminate, never the assertion

Stage 3's plan supplied test code verbatim. That code contained assertions that
could not fail (`indexOf(md, "uncertain")` matched the section's own prose), one
that would not compile (`.action = .{ .renders_json = true }` against a struct
with no field defaults), and several that checked a class while leaving the
`reason` unasserted so a rule firing for the wrong cause passed.

Every task here instead states **what must be discriminated and what the wrong
answer would look like**, and the implementer writes the assertion. An
implementer who has read the code writes a better assertion than a planner who
has not, and the failure mode of a vague property ("this test doesn't pin
enough") is visible at review, whereas the failure mode of a supplied bad
assertion is an always-green test nobody re-reads.

### 2. Every test is mutation-proven, BY LINE NUMBER

Mutate the exact production line the test guards, confirm THAT test goes red,
restore, confirm green — and never mutate by string search. A string-search
`sed` rewrites the production literal AND the test's identical
`expectEqualStrings` literal in one pass, so the test compares garbage to
garbage and reports a false green. That happened on Stage 3 and was caught only
because the implementer double-checked its own harness.

---

## Global constraints

- `src/cli/rails/` is **std-only**: no `@import` may escape that directory (never
  `../../fatal.zig`), because the directory backs a standalone test suite.
- Every allocator-taking function states which NO_SLOP.md §2.2a contract it
  satisfies, and satisfies it on **every error path**. Contract 1 = self-freeing
  (one allocation escapes as the return); 2 = owned graph with a free
  counterpart; 3 = allocates nothing. Three functions on this feature were found
  labelled 2 when they were 1. **The allocator gate cannot catch a wrong label**
  — it polices arena-wrapped testing allocators only.
- `blockers.append`'s `code` is always a static literal; release with
  `blockers.free(gpa, list.toOwnedSlice(gpa))`, never `free(items)` + `deinit()`.
- Any new file needs `pub const <n> = @import(...)` **and** `_ = <n>;` in
  `rails.zig`'s `test` block, or `test-rails` never runs its suite.
- **Degradation stays exit 0.** Missing Ruby, missing sidecar, missing
  `app/controllers/`, an unreadable template: each records a non-integrity
  blocker and the run succeeds. A claim about what a route IS must never come
  from missing evidence.
- The source tree is **read-only**; outputs never clobber (`.new`, `.new.2`).
- **Determinism is a hard requirement.** The same app analysed at two different
  directories must produce byte-identical manifests. Stage 3 fixed an
  absolute-path leak into blocker `detail` for exactly this reason, and this
  stage is what makes it load-bearing: the drift gate diffs committed output.
  Paths in the manifest are app-relative, always.

---

## Two shippable phases

Each is its own PR. Phase 1 has no new user-visible surface; it only enriches
data the report already renders, so it can merge on its own.

---

# Phase 1 — backfill the producers (PR A)

The spec's v1 manifest documents fields no producer fills. Each task below
closes one gap. **Decided: build them all rather than publishing structurally
empty fields** — a consumer must never be unable to tell "this app has no
assets" from "we never looked".

## Task 1 — `blockers`: severity and route association

**Files:** `src/cli/rails/blockers.zig`, every call site.

Add `severity` (`error` | `warn`) and `route_id: ?[]const u8` to `Blocker`.

Assign a severity to every existing code. The rule: `error` means the inventory
or the analysis is untrustworthy; `warn` means an expected finding that was
correctly detected and reported. `RAILS_INVENTORY_UNREADABLE` is an error;
`RAILS_TEMPLATE_ENGINE_UNSUPPORTED` is a warn — a Haml view is not a failure,
it is a fact we detected and are declining to convert.

**`severity` does NOT gate `--strict`** (Task 11). `--strict` is spec-literal:
any blocker at all. Severity is descriptive metadata for a consumer, and wiring
the two together later would silently change what `--strict` means.

**Discriminate:** that severity is per-code and not a constant. A test asserting
only that the field exists passes against an implementation that returns `warn`
for everything. Pin at least one code of each severity, and the *count* of each
on the fixture.

## Task 2 — routes carry their source location, and Ruby its version

**Files:** `runtime/sidecar/rails/routes.rb`, `analyze.rb`, `src/cli/rails/routes.zig`.

`Route` has no line number; the manifest requires `source: {file, line}` on every
route. `routes.rb` already records lines for `unresolved` entries, so the walker
knows them — they are dropped at the wire.

Also capture `discovery.ruby: {available, version}`. `version_check.rb` already
prints `{"ruby":..., "prism":...}` but discovery never captures it. Add it to
the sidecar's response rather than shelling out a second time.

**Discriminate:** that the line is the ROUTE's line, not the file's first or
last line, and not the `draw` block's. Two routes on different lines must report
different numbers. A test pinning one route's line passes against an
implementation returning a constant.

## Task 3 — `template_scan`: named Stimulus controllers and component roots

**Files:** `src/cli/rails/template_scan.zig`.

`Markers.stimulus` is a bool; the manifest needs `stimulus_controllers[]` — the
NAMES from `data-controller="reveal modal"` (space-separated, possibly several).
`component_root` is a single optional; the manifest needs `component_roots[]`.

Keep `classify.zig`'s behaviour identical: it asks whether ANY interactivity
exists, which is now "the list is non-empty". **Rule 6 must not change its
verdict on any input** — verify against the fixture's existing distribution.

Preserve every Stage 3 property: the over-detection is deliberate, ERB comments
are not stripped, the request-state table's order is load-bearing with the
generic `current_` catch-all last, and a bare `<div id="app">` is not evidence.

**Discriminate:** that `data-controller="reveal modal"` yields TWO names, not one
string and not the raw attribute value. A single-controller test passes against
an implementation that never splits.

## Task 4 — expose the template graph the transitive scan already walks

**Files:** `src/cli/rails/rails.zig`.

Stage 3's transitive scan resolves each route's layout and the partials it
renders, then discards that structure after merging markers. The manifest needs
it: `routes[].templates[]`, `routes[].layout`, and `templates[].renders[]`.

This is plumbing, not new analysis — the resolution already happens. Do not
re-walk; surface what the existing walk knows.

**Watch the lifetime.** `template_scan.Markers` borrow from the buffers passed to
`scan`, and `TransitiveScan.buffers` keeps them alive together. Anything you now
retain past that scope must be duped or kept alive deliberately. State in your
report which you chose.

**Discriminate:** that `renders[]` reflects the ACTUAL resolved partial, not the
literal render argument. `render "nav"` inside `app/views/layouts/posts.html.erb`
must appear as `app/views/layouts/_nav.html.erb`.

## Task 5 — populate `route_id` where a blocker is genuinely route-scoped

**Files:** `src/cli/rails/rails.zig` (and any other site emitting inside a
per-route loop).

Task 1 added `route_id` to `Blocker` and every call site passes `null`. Nothing
in the original plan populated it — **a gap in this plan, found by Task 1's
implementer**, and precisely the structurally-empty-field failure this stage
exists to avoid: a manifest whose every `route_id` is `null` cannot tell a
consumer "this blocker is not about a route" from "we never associated it".

At least two sites already know the route. `rails.zig` emits
`RAILS_TEMPLATE_UNREADABLE` and the render-depth blocker from inside the
per-route classification loop, with the route in hand, and passes `null` anyway.

Populate `route_id` at every site where a specific route is in scope, using the
same id form the manifest uses for `routes[].id` (verb + space + path, e.g.
`GET /articles/:id`). Leave it `null` where the blocker genuinely is not
route-scoped — `RAILS_GEMFILE_UNREADABLE` is about the app, not a route.

**Discriminate BOTH directions.** A test asserting only that a route-scoped
blocker carries an id passes against an implementation that stamps the same id
on everything; a test asserting only that a Gemfile blocker is `null` passes
against one that never populates anything. Pin one of each, and pin that the id
matches the route that actually produced it — not merely that it is non-null.

Route-discovery blockers arriving from `routes.rb`'s `unresolved[]` are a
separate case: they describe a CONSTRUCT the parser could not evaluate, which
may correspond to no recovered route at all. Leave those `null` and say so in a
comment, so a later reader does not take it for an oversight.

## Task 6 — the asset inventory

**Files:** new `src/cli/rails/assets.zig`, wired into `rails.zig`.

`assets[]`: `source`, `public_url`, `pipeline` (`propshaft` | `sprockets`),
`deterministic`.

Pipeline detection comes from the Gemfile — Propshaft and Sprockets are distinct
gems. `deterministic` records whether the public URL can be derived statically:
Propshaft's digest depends on file content, which we CAN compute; a Sprockets
manifest may not be present. **Where the URL cannot be derived, say so** —
`deterministic: false` with the real reason — rather than guessing a URL that
will 404.

**Discriminate:** that `deterministic` is false for at least one real case and
true for another. A test where every asset is deterministic passes against an
implementation that hardcodes true. The fixture must contain both.

## Task 7 — the Rails version, with its evidence

**Files:** `src/cli/rails/detect.zig`.

`source.version: {value, evidence}` — e.g. `"7.1.3"` with evidence
`"Gemfile.lock:rails (7.1.3)"`. Parse `Gemfile.lock`, not `Gemfile`: the lock
file has the resolved version, the Gemfile has a constraint.

Absent or unparseable lock file is not a failure — `null` plus a `warn` blocker.

**Discriminate:** that the version comes from the `rails` gem specifically, not
the first version-shaped string in the file. A `Gemfile.lock` naming several
gems with versions must still yield Rails'.

---

# Phase 2 — the manifest, its schema, and the gate (PR B)

## Task 8 — `src/cli/rails/manifest.zig`

The emitter. Zig types are the single source of truth for the manifest's shape;
Task 9 derives the schema from them rather than maintaining a parallel document.

Every field in the spec's "The manifest" section, populated from Phase 1's
producers. `schema: "zigapagos.rails-presentation/1"`, `schema_version: 1`.

**Key ordering must be stable and explicit**, not incidental to struct field
order — the drift gate diffs bytes, so a field reorder during a refactor would
present as spurious drift.

**Discriminate:** determinism directly. The same fixture analysed from two
different absolute directories must produce byte-identical manifests. That is
the property the whole gate rests on, and Stage 3 shipped an absolute-path leak
that this exact check would have caught.

## Task 9 — the schema and the drift gate

**Files:** `contract/rails-presentation.v1.schema.json`, `build/codegen.zig` (or a
sibling), `.github/workflows/ci.yml`.

Generate the schema FROM the Zig types, and gate it exactly as `api-check` does:
regenerate → `git add` → `git diff --cached --exit-code`. Read
`build/codegen.zig`'s `api-check` block and mirror its structure, including its
own `Run` step so the gate always regenerates independently.

Register `rails-schema` (regenerate) and `rails-check` (gate) build steps, and
**add `rails-check` to `ci.yml` explicitly** — that file's step list is
enumerated by hand and a new step is invisible to CI otherwise. This exact
omission is why the Ruby suites once existed without running.

## Task 10 — prove the gate is not vacuous

**Files:** `tests/contract/rails-drift.sh` (picked up by the `tests/*/*.sh` glob).

Model on `contract/test/drift.sh`, and read its header first — it documents a
trap this repo already paid for:

> A gate written to prove another gate is not vacuous was itself vacuous. An
> exit status alone cannot tell "the compiler found the divergence" from "the
> compiler could not launch."

So: **assert on the diagnostic text, treat exit status as necessary but not
sufficient.** Break the schema on purpose, confirm `rails-check` fails *and*
says why; break the manifest emitter, confirm the same; then a clean-tree
control case, because without it both halves would be satisfied by a gate that
fails unconditionally.

Restore the tree on **every** path via an `EXIT` trap, and have the trap fail the
script if anything it mutated is still dirty — CI runs this in a shared
checkout where a leaked mutation corrupts whatever runs next.

## Task 11 — `--strict`

**Files:** `src/cli/migrate.zig`.

Exit non-zero when any blocker exists, per the spec. Not severity-filtered —
see Task 1.

The fixture currently produces `RAILS_ROUTE_CONDITIONAL`,
`RAILS_ROUTE_ENGINE_MOUNT` and `RAILS_TEMPLATE_ENGINE_UNSUPPORTED`, so
`--strict` fails on it. That is correct and is the point: strict mode is for an
agent loop or a CI gate that wants a clean discovery or none.

**Discriminate:** that `--strict` changes ONLY the exit code. The manifest and
report must be byte-identical with and without it. A test checking only the exit
code passes against an implementation that also suppresses output.

## Task 12 — fixture, e2e, changelog

The fixture must exercise both asset pipelines' cases (deterministic and not),
a multi-controller `data-controller` attribute, and a `Gemfile.lock` with
several gems.

The e2e asserts the manifest's key fields and the `--strict` exit contract.
Then **stub the manifest emitter and confirm the e2e fails on the manifest
assertions specifically** — an e2e that passes against a stubbed emitter asserts
nothing about the manifest.

Changelog honest about scope: the manifest is emitted and versioned; `--target`
assembly is Stage 5; conversion is #167.

---

## Exit criteria

- The manifest validates against its own committed schema, and the gate is
  proven to notice both schema drift and emitter drift.
- Two runs from different directories are byte-identical.
- `--strict` exits non-zero on any blocker and changes nothing else.
- `rails-check` runs in CI by name.
- Degradation still exits 0 and still emits a manifest — a manifest that
  honestly records what was not discoverable is the point.

## Not in this plan

Stage 5 (`--target` assembly, `docs/migration/rails-to-zigapagos.md`, the
`skills/` mirror and `tests/skills/sync.sh`). Resolving request-time state is
#167.

**Stage 5 carries a known trap**, recorded now so it is not discovered late:
`docs/migration/` and `skills/*/references/` are byte-mirrored under a sync gate
whose file list is **hardcoded**, so the doc, its skill copy, and the gate's list
must land in the same commit.
