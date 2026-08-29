---
name: zigapagos-rails-migration
description: Discover and classify the routes of a Rails app for a future zigapagos migration. Use when asked to inventory, scan, or assess a Rails project for zigapagos migration — covers route recovery via a Ruby/Prism sidecar, the six-way route classification, Rails route-helper names, controller layouts, and the JSON manifest contract including its per-fragment `findings[]`. Discovery and findings only: this does not convert a Rails app into a zigapagos project (that is issue #167 Stage 2, not yet implemented).
license: MIT
metadata:
  source: https://github.com/valthon/zigapagos
---

# Discovering a Rails app for zigapagos migration

You are running discovery over a Rails project ahead of a possible zigapagos
migration. This is **not** a conversion tool — it inventories the app, reads
routes and controller-action shapes, resolves each route's view template
(and its layout and any partials it renders, transitively), classifies each
route with an evidence-gated verdict, resolves each `certain` route's Rails
helper `name` and each controller's declared `layout`, and parses every
route-reachable ERB template into a closed vocabulary of fragments —
surfacing anything a converter would need a human decision on as a
`findings[]` entry (issue #167 Stage 1). No content, layout, or island is
written for the Rails source. The full deterministic reference —
classification meanings, the `unresolved` follow-ups, `severity` vs.
`integrity`, `--strict`, route-id non-uniqueness, route-name derivation,
layout resolution, and the findings/fragment-vocabulary tables — is in
[references/rails-to-zigapagos.md](references/rails-to-zigapagos.md). Read
the sections you need as you reach them; do not guess a meaning that file
defines.

## Preconditions

- The `zigapagos` binary on PATH (or a known path). No Ruby toolchain is
  required to run the command at all, but route and controller-action
  recovery need `ruby` on PATH plus this repo's `runtime/sidecar/rails`
  Ruby/Prism sidecar (set `ZIGAPAGOS_RUNTIME_DIR` when running from a
  zigapagos checkout rather than an installed release). Without Ruby, the run
  still completes and still writes both artifacts — it degrades to
  inventory-only with a descriptive (not necessarily integrity) blocker
  explaining why routes weren't recovered.
- Source files are read-only and the Rails app is **never booted**: no
  initializer runs, no database connects. Route recovery is a static AST
  walk of `config/routes.rb`.

## Procedure

1. **Run discovery.**

   ```sh
   zigapagos migrate <rails-app> --from rails -o MIGRATION.md
   ```

   `--from rails` is optional when detection is unambiguous, but pass it
   explicitly in a monorepo or CI script. On a tree with no Rails evidence
   this is fatal — it never produces a confident, empty report.

2. **Check the exit code before trusting anything.** Non-zero means at least
   one `integrity: true` blocker fired — the report and manifest are still
   written ("report, never omit silently"), but their counts may be
   incomplete. Add `--strict` in a CI/agent gate that wants zero blockers of
   ANY kind, not just integrity ones — see the reference's `--strict`
   section for exactly what that widens.

3. **Read the manifest, not just the prose report, for automation.**
   `MIGRATION.manifest.json` (named from `-o`'s stem, e.g.
   `MIGRATION.md` → `MIGRATION.manifest.json`) is the
   `zigapagos.rails-presentation/1` JSON manifest and the binding contract —
   `MIGRATION.md` is a rendering of it. Its shape is
   `contract/rails-presentation.v1.schema.json`, generated from the emitter's
   own Zig types.

4. **Triage every route by `classification`, not by skimming prose.** Only
   `content` asserts something positive ("safe to treat as static"). `island`
   is a narrower positive claim (interactivity found). `backend`/`redirect`
   are handoffs. `unresolved` requires the specific human follow-up named in
   the reference's classification table for that route's exact reason
   string — do not treat every `unresolved` route the same way; the reason
   tells you what evidence is actually missing.

5. **Read `findings[]`.** Each is a question with a fixed set of `choices`
   — a per-fragment or per-declaration decision a converter would need a
   human to make (an unknown helper, request-time state, a missing
   translation, a dynamic layout, …). `route_id` is always `null` in this
   stage; a finding never affects the exit code, `--strict` included.
   Nothing converts yet: recording an answer has nowhere to go until issue
   #167 Stage 2 adds a `MIGRATION.decisions.json` input this tool reads
   back.
6. **Do not attempt to convert anything here.** Producing zigapagos content,
   islands, or a `.spa.tsx` from a classified route or an answered finding
   is issue #167 Stage 2, not yet implemented. This skill's job ends at an
   honest inventory, classification, and findings.

## Rules

- `spa` is a declared classification value that is **never assigned** by
  this tool — proving a component root owns routing needs module/import
  resolution this stage does not perform. A route with a component-root
  marker classifies `island` instead, a narrower, provable claim. Do not
  expect or produce `spa` in any manifest this command writes.
- `routes[].id` (`"<VERB> <path>"`) is a display label, not a unique key —
  two identical route declarations produce the same id. A blocker's
  `route_id` similarly names ONE affected route for a per-file finding
  (e.g. an unreadable shared layout), not every route that finding affects.
- `severity` and `integrity` are different axes on a blocker. Only
  `integrity` drives the exit code; filtering on `severity == "error"` alone
  will surface errors on a run that is otherwise perfectly healthy (e.g. one
  that simply lacks Ruby).
- `--scaffold`, `--copy-assets`, and `--convert-content` are all rejected
  for Rails sources — there is no conversion step yet for them to drive.
  `--target DIR` is accepted, but for Rails it only redirects the same two
  discovery artifacts into `DIR`; it assembles no project scaffold the way
  it does for every other source.
