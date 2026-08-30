---
name: zigapagos-rails-migration
description: Migrate a Rails app's presentation layer to zigapagos — discover and classify its routes, then convert them into a real zigapagos project. Use when asked to inventory, scan, assess, or port a Rails project for zigapagos — covers route recovery via a Ruby/Prism sidecar, the six-way route classification, the JSON manifest contract and its per-fragment `findings[]`, and the `--target` decide-and-re-run conversion loop that ends in a buildable site. Islands (Stage 4) and backend endpoints (Stage 3) are not produced yet: those choices are recorded and leave the route open.
license: MIT
metadata:
  source: https://github.com/valthon/zigapagos
---

# Migrating a Rails app to zigapagos

You are porting a Rails project's presentation layer to zigapagos. The tool
does this in two phases, and the same command drives both.

**Discovery** (no `--target`) inventories the app, reads routes and
controller-action shapes, resolves each route's view template (and its layout
and any partials it renders, transitively), classifies each route with an
evidence-gated verdict, resolves each `certain` route's Rails helper `name`
and each controller's declared `layout`, and parses every route-reachable ERB
template into a closed vocabulary of fragments — surfacing anything the
converter needs a human decision on as a `findings[]` entry.

**Conversion** (`--target DIR`) turns that into a real zigapagos project:
`content/<url>/index.smd` pages, `.shtml` layouts, copied assets, a
`zigapagos.ziggy` and a `build.sh`. A route the converter cannot finish on
its own is reported `open` in `DIR/MIGRATION.handoff.json` with the finding
ids you have to answer; the run exits **3**; you answer them in
`DIR/MIGRATION.decisions.json` and run the same command again. When every
user-facing route is accounted for the handoff says `"complete": true` and
the run exits 0.

The full deterministic reference — classification meanings, the `unresolved`
follow-ups, `severity` vs. `integrity`, `--strict`, route-id non-uniqueness,
route-name derivation, layout resolution, the findings and fragment-vocabulary
tables, the conversion rules, the decisions file, and the handoff schema — is
in [references/rails-to-zigapagos.md](references/rails-to-zigapagos.md). Read
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

   `classification` is discovery's verdict, not a prediction of what the
   conversion will do. An `unresolved` route routinely converts cleanly, and
   a `content` route routinely does not. The handoff's `status` is the
   answer to "did this route migrate".

5. **Run the conversion.**

   ```sh
   zigapagos migrate <rails-app> --from rails --target <new-site>
   ```

   `<new-site>` must be missing, or empty, or contain nothing but
   `MIGRATION.decisions.json`. Exit `1` means the run is broken and no
   amount of deciding will help; exit `3` means it worked and the migration
   is not finished; exit `0` means it is.

6. **On exit 3, read `<new-site>/MIGRATION.handoff.json`** — not the emitted
   tree. Every route has a `status`; each `open` one lists the finding ids it
   left unanswered in `findings[]` and says why in `note`. An `open` route
   may still have written its page: it is the *decision* that is missing.

   A route whose view would not convert — a template parse error, an
   unsupported engine (Haml, Slim) — is still **answerable**: it carries
   `RAILS_TEMPLATE_PARSE_ERROR` or `RAILS_TEMPLATE_ENGINE_UNSUPPORTED`, and a
   `retain`/`blocked` answer settles it. So is a route whose *layout* is Haml
   or Slim (it carries the layout's id, so one answer settles every route
   under that layout) and a route whose action resolves no view at all
   (`RAILS_NO_TEMPLATE`, keyed on the `routes.rb` line). None of them can ever
   be `migrated`, because `migrated` is not a choice anywhere. The only route
   no answer reaches is one whose sole remaining problem is a `rails:unmapped`
   region **and** which raises no finding at all — the placeholder carries no
   id. It is emitted from four places (an unbound template local; an
   unresolvable or cyclic `render` target; a `content_for :title` whose body
   is not a literal; and a backstop that in practice catches a route helper
   called with the wrong arity, such as `post_path` for `/posts/:id`); the
   reference enumerates them. Those are converter gaps, tracked as #181, and
   the route's `note` says `<kind>: converter gap (see #181)` rather than
   pretending a later stage owns them.

   Note that `retain` and `blocked` write **no page and no view file** — the
   answered route's URL is left to Rails, or not shipped at all. Run 2's tree
   is therefore smaller than run 1's, and that is the point: emitting a page
   anyway would serve a blank `<main>` for a route the handoff calls blocked.

7. **Answer the findings** in `<new-site>/MIGRATION.decisions.json`:

   ```jsonc
   {
     "schema": "zigapagos.rails-decisions/1",
     "decisions": [
       { "id": "<finding id, verbatim>",
         "choice": "<one of THAT finding's own choices>",
         "rationale": "why" }
     ]
   }
   ```

   Read the `choices` array on the finding you are answering — the same
   `code` can offer different lists. `rationale` is required and must be
   non-blank. `retain`, `blocked` and (on a dynamic route with a static first
   segment) `spa` settle a route; `island` and `backend` are accepted,
   recorded, and leave it `open` with the deferral named, because this
   version cannot produce the island or the endpoint they promise.

   An unusable file exits 1 and names **every** offending entry at once — a
   choice the finding does not offer, a blank rationale, a duplicate id, a
   wrong `schema`, a misspelled key. There is **no** "unknown id" failure: an
   id matching no finding in this run is a `RAILS_DECISION_STALE` blocker
   (`warn`, exit unaffected), because nothing can tell a typo from an answer
   whose finding was fixed since, and fixing the template you were asked
   about is exactly what makes its id disappear.

   A Haml/Slim route is answered through
   `RAILS_TEMPLATE_ENGINE_UNSUPPORTED.<path>.engine` — note the `engine` tail
   instead of a line/column, because nothing parsed the file.

8. **Wipe the target except the decisions file, and re-run.**

   ```sh
   find <new-site> -mindepth 1 -maxdepth 1 ! -name MIGRATION.decisions.json -exec rm -rf {} +
   zigapagos migrate <rails-app> --from rails --target <new-site> \
     --runtime-path <path-to>/runtime
   ```

   Every file in the target is exclusive-create, so a re-run into a populated
   directory is rejected rather than half-overwritten. Repeat 6–8 until exit
   0 and `"complete": true`.

   **`--runtime-path` is required whenever any answer was `spa`.** The
   scaffolded `.spa.tsx` comes with a `package.json` whose `@z/runtime`
   dependency is otherwise the placeholder `file:TODO-SET-RUNTIME-PATH`, and
   step 9's `bun install` then fails with
   `Could not find package.json for "file:TODO-SET-RUNTIME-PATH"`. The
   handoff says so too — that route's `note` reads
   `set dependencies.@z/runtime in package.json`. Editing that one line
   afterwards works equally well. A target with no SPA has no `package.json`
   and needs neither.

9. **Build the migrated site.**

   ```sh
   bash <new-site>/build.sh
   ```

   That is `bun install` (only when there is a `package.json`) then
   `zigapagos release --force --output=zig-out/site`, plus one `--spa=` per
   scaffolded `.spa.tsx`. Edit `zigapagos.ziggy`'s `host_url` first — it is
   written as a `https://example.com` placeholder, not read from Rails
   config.

   A scaffolded SPA declares no `spa.head`, so `release` warns that its
   routes will render unstyled (a SPA shell's `<head>` is fixed and does not
   inherit the site's stylesheet links). The build still succeeds; add the
   `head:` the warning spells out when you port the placeholder components.

   Then audit it: `zigapagos doctor <new-site>/zig-out/site`. Expect **0
   errors**, and one `dangling-internal-link` warning per link into a route
   you answered `retain` or `blocked` — those routes write no page, so the
   static tree genuinely does not answer those URLs while Rails still does.
   That is the honest report of a partial migration, not a conversion defect.

10. **Finish the leftovers by hand.** A route left `open` still builds: its
    unfinished regions are `<!-- rails:finding … -->` HTML comments, visible
    in the built page. Grep the emitted tree for `rails:finding`,
    `rails:unmapped` and `rails: ` to find every one.

## Rules

- `spa` as a **classification** is a declared value that is **never assigned**
  by this tool — proving a component root owns routing needs module/import
  resolution discovery does not perform. A route with a component-root marker
  classifies `island` instead. `spa` as a **decision choice** on
  `RAILS_ROUTE_DYNAMIC_SEGMENT` is a different thing entirely and does real
  work.
- `routes[].id` (`"<VERB> <path>"`) is a display label, not a unique key —
  two identical route declarations produce the same id. The handoff's
  `routes[].route_id` is the same label with the same caveat. A blocker's
  `route_id` similarly names ONE affected route for a per-file finding
  (e.g. an unreadable shared layout), not every route that finding affects.
- `severity` and `integrity` are different axes on a blocker. Only
  `integrity` drives the exit code; filtering on `severity == "error"` alone
  will surface errors on a run that is otherwise perfectly healthy (e.g. one
  that simply lacks Ruby).
- **`status`, not `classification`, answers "did this route migrate."** Where
  the two disagree the conversion wins.
- `complete` counts only GET/HEAD routes. A `POST` is form traffic Stage 3
  owns, and a `backend` status accounts for its route with or without a
  decision — the question `complete` asks is whether the migrated site is
  browsable.
- `--scaffold`, `--copy-assets`, and `--convert-content` are rejected for
  Rails sources: those are the React/Markdown ports, and the Rails conversion
  is driven by `--target` alone.
- The conversion is deterministic — no timestamps, no absolute paths, no
  ambient state. Two runs over the same app and the same decisions file
  produce byte-identical trees. If they do not, that is a bug worth
  reporting, not something to work around.
