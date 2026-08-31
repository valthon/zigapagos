---
name: zigapagos-rails-migration
description: Migrate a Rails app's presentation layer to zigapagos — discover and classify routes, convert and decide a real project, bind ZigBase forms/data, port supported interactivity, and replay typed parity before backend handoff. Use when asked to inventory, assess, or port Rails to zigapagos.
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

**Binding** (`--backend FILE`, alongside `--target`) is the third job. `FILE`
is the OpenAPI document `zigbase openapi` writes; its operations become the
`choices` a `RAILS_BACKEND_ENDPOINT` finding offers, and an answered finding
turns the Rails form, mutating link or auth journey it names into a generated
island that calls that operation through `@zigbase/client`. Without the flag
those findings offer only `retain`/`blocked` — a backend route can be
acknowledged but not bound, and a user-facing GET that renders JSON keeps the
run incomplete.

The full deterministic reference — classification meanings, the `unresolved`
follow-ups, `severity` vs. `integrity`, `--strict`, route-id non-uniqueness,
route-name derivation, layout resolution, the findings and fragment-vocabulary
tables, the conversion rules, the decisions file, the handoff schema, and the
backend boundary (§18) — is in
[references/rails-to-zigapagos.md](references/rails-to-zigapagos.md). Read
the sections you need as you reach them; do not guess a meaning that file
defines.

The ZigBase half of the port — designing the collections, their rules and the
consumer routes that document describes, and moving the Rails models behind
them — is **not** this skill's job: it consumes the document, it does not
author it. ZigBase ships its own skills for that half
(`zigbase-zigapagos-fullstack` for the paired port,
`zigbase-migrate-rails-api` for the Rails API side). Hand it to those, or to
whoever owns the backend, and come back with an `openapi.json`.

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

5. **Run the conversion — with `--backend` if the target site has a ZigBase
   backend.**

   ```sh
   zigapagos migrate <rails-app> --from rails --target <new-site> \
     --backend <path>/openapi.json
   ```

   `<new-site>` must be missing, or empty, or contain nothing but
   `MIGRATION.decisions.json`. Exit `1` means the run is broken and no
   amount of deciding will help; exit `3` means it worked and the migration
   is not finished; exit `0` means it is.

   **Where `openapi.json` comes from.** It is not generated by this tool and
   there is no default location — a document you did not name is a document
   the run does not have. Whoever owns the ZigBase side produces it against a
   data directory:

   ```sh
   zigbase migrate       --data-dir "$d"                 # create the database
   zigbase schema apply  schema.json --data-dir "$d"     # the collections
   zigbase openapi       --data-dir "$d" --api-version 1.0.0 --out openapi.json
   ```

   (There is no `zigbase collection create` subcommand; the declarative
   `schema apply` path is the equivalent.) Check `schema.json` into version
   control alongside the document so the artifact is reproducible.

   **Pass `--backend` on every run of the loop, not just the last one.** It is
   what widens the `choices` an answer has to come from: a run without it
   rejects the operation id you recorded last time (`allowed: retain,
   blocked`), and a run without it first never shows you the ids to choose
   among. An unreadable or non-OpenAPI `--backend` file is exit `1` with the
   flag, the path and the reason on stderr — never a silent degradation to
   `retain`/`blocked`, which would look like the document simply had no
   matching operation.

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
   answered route's URL is left to Rails, or not shipped at all. Emitting a
   page anyway would serve a blank `<main>` for a route the handoff calls
   blocked. So run 2's tree loses every acknowledged route's files, and gains
   whatever the answers that *produce* something wrote: `components/*.tsx`,
   `lib/zb.ts`, `package.json`, `spa/*.spa.tsx`.

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
   non-blank.

   What settles a route: `retain`, `blocked`, `spa` (on a dynamic route with a
   static first segment), an **operation id** or `custom:/<path>` on
   `RAILS_BACKEND_ENDPOINT`, `island` on `RAILS_AUTH_JOURNEY` or on an
   `errors`/`current_user` region, `island`/`backend` on a portable `ivar`,
   `island` on a portable Stimulus controller, Turbo frame, or React root,
   `inline` on a closed source-less frame, `drop` on Stimulus or the reviewed
   `RAILS_JS_ENTRY`, and `public` on `RAILS_ROUTE_AUTH_GUARD`. Turbo Streams
   and Vue roots offer only `retain`/`blocked`.

   Three answers need something extra:

   - **`RAILS_BACKEND_ENDPOINT`** — its `choices` are the `--backend`
     document's own operation ids, filtered to the finding's own verb and
     ranked with its own resource first. `custom:/<path>` is additionally
     accepted (absolute path, no whitespace, no quotes) for a consumer route
     the document does not describe; it is not listed in `choices` because a
     free-form token cannot be.
   - **`RAILS_AUTH_JOURNEY`** — one question for the whole sign-in/sign-up
     flow. `"choice": "island"` **requires** `"artifact": "<auth collection>"`,
     and the name is checked against the document: an auth collection is the
     one whose create schema carries both `password` and `passwordConfirm`,
     and naming anything else is rejected with the allowed list. `retain` and
     `blocked` need no artifact.
   - **`RAILS_ROUTE_AUTH_GUARD`** — `public` means "ship the page; the ZigBase
     rule on the operation protects the data". It settles the guard and
     nothing else, so a route carrying other open findings still needs each of
     them answered too.
   - **portable `RAILS_REQUEST_TIME_STATE` ivar** — `island` and `backend`
     use the same record-backed data-island converter. Optional `artifact`
     names the backend collection and is checked against `--backend`. On a
     dynamic route it is applied after the route's `spa` answer.
   - **Stimulus / Turbo frame / React root** — choose `island` only after
     reading the named source and portability message. `drop` removes
     Stimulus wiring; `inline` preserves a source-less frame. A wrapping
     island does not settle findings inside its slot.
   - **`RAILS_JS_ENTRY`** — read the file and listed imports before choosing
     `drop`; the generated islands and `@z/runtime` replace it, but discovery
     deliberately does not execute it.

   **Answer every open finding on a route; all of them are applied.** Each
   answered finding is settled by its own choice, and the route's status is
   the strongest outcome among them: `blocked` > `retain` > an answer that
   produces something (an operation id, `island`, `public`) > a deferral. So a
   route with both a bound mutation and a guard, answered an operation id and
   `public`, comes back `migrated` carrying `guarded by before_action
   :require_login; shipped public by decision` — you do not have to pick which
   of its questions to answer. A `retain` or `blocked` anywhere on the route
   wins outright and stops there: the route stays on Rails or does not ship,
   so notes about work that is not happening are not filed. Three arms sit
   outside the rule and apply one answer each: a **dynamic route** (only the
   answer to its own `RAILS_ROUTE_DYNAMIC_SEGMENT`), and a **redirect** or
   **backend** route (each records its own answer — a backend route that
   bound an endpoint also settles it — without letting it change the route's
   status).

   An answer on a finding that some other answer already swallowed — the
   sign-out `button_to` inside an `if current_user` region an `island` answer
   replaces — is **accepted**, not refused: it is settled, and the route's
   `note` names both ids (`choice … superseded by the island answering …,
   which replaced the region it sits in`).

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

8. **Re-run to complete, build, replay parity, and hand off.**

   ```sh
   find <new-site> -mindepth 1 -maxdepth 1 ! -name MIGRATION.decisions.json -exec rm -rf {} +
   zigapagos migrate <rails-app> --from rails --target <new-site> \
     --backend <path>/openapi.json --runtime-path <path-to>/runtime
   ```

   Every file in the target is exclusive-create, so a re-run into a populated
   directory is rejected rather than half-overwritten. Repeat 6–8 until exit
   0 and `"complete": true`.

   **`@z/runtime` needs a real path whenever the target has JS** — a `spa`
   answer, a `--backend` binding, or both. Three ways it gets one, in order:
   `--runtime-path <path-to>/runtime` (always wins); the
   `ZIGAPAGOS_RUNTIME_DIR` environment variable the run already reads for the
   sidecar; or editing the generated `package.json` afterwards. Without any of
   them the dependency is the placeholder `file:TODO-SET-RUNTIME-PATH` and
   the build below fails during `bun install` with
   `Could not find package.json for "file:TODO-SET-RUNTIME-PATH"`. The
   handoff says so too — that route's `note` reads
   `set dependencies.@z/runtime in package.json`. A target with no SPA and no
   island has no `package.json` and needs none of them.

   Build only after exit 0:

   ```sh
   bash <new-site>/build.sh
   zigapagos doctor <new-site>/zig-out/site
   ```

   That is `bun install` (only when there is a `package.json`) then
   `zigapagos release --force --output=zig-out/site`, plus one `--spa=` per
   scaffolded `.spa.tsx` and one `--island=` per generated island. Edit
   `zigapagos.ziggy`'s `host_url` first — it is written as a
   `https://example.com` placeholder, not read from Rails config.

   `bun install` fetches `@zigbase/client` from npm when any island was
   generated, so the build step needs network the first time.

   A scaffolded SPA carries the deterministic stylesheet links recovered from
   its Rails layout in `spa.head`. Review that list when the old app computed
   head assets dynamically.

   Expect **0 errors**, and one `dangling-internal-link` warning per link into a route
   you answered `retain` or `blocked` — those routes write no page, so the
   static tree genuinely does not answer those URLs while Rails still does.
   That is the honest report of a partial migration, not a conversion defect.

   A nonempty `parity[]` also writes two fixed runners. Initialize the same
   schema that produced the OpenAPI document into an isolated data directory,
   then run both through stock ZigBase (never substitute the development
   stub):

   ```sh
   d="$(mktemp -d)"
   zigbase migrate --data-dir "$d"
   zigbase schema apply <path>/schema.json --data-dir "$d"
   zigapagos e2e --site=<new-site>/zig-out/site --data-dir="$d" -- \
     bun <new-site>/test/parity.ts
   zigapagos e2e --site=<new-site>/zig-out/site --data-dir="$d" -- \
     python3 <new-site>/test/journey_playwright.py
   ```

   `test/parity.ts` replays page, asset, auth, authorization, mutation and
   validation facts from `MIGRATION.handoff.json`; it contains no per-route
   generated logic. `test/journey_playwright.py` drives signup,
   signout/signin, allowed submit, and the rendered validation error in system
   Chrome. `RAILS_ORIGIN` is an optional copied-asset oracle, not proof that
   the source Rails app boots. Missing Playwright/Chrome may skip the browser
   journey loudly; a located browser/server failure is a failure.

   Finish open leftovers by hand: grep for `rails:finding`, `rails:unmapped`
   and `rails: `. Then hand the schema/OpenAPI document and remaining model,
   rule, consumer-route and data work to `zigbase-zigapagos-fullstack` (or
   `zigbase-migrate-rails-api` for the API-only half). This skill stops at the
   presentation target and replay evidence; it does not author backend policy.

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
- `complete` counts only GET/HEAD routes. A `POST` is form traffic, outside
  the count entirely — the question `complete` asks is whether the migrated
  site is browsable. A `backend` row accounts for its route only with a
  non-null `endpoint` or a non-null `decision`, which given the GET/HEAD-only
  count bites on exactly one shape: a user-facing GET that renders JSON.
- **Enforcement stays server-side.** Every generated island says so in its
  header comment, and it is not a formality: an island hides or disables on
  client auth state for convenience only, and the ZigBase rule on the
  operation is the thing that decides who may actually submit. Answering
  `public` on a `RAILS_ROUTE_AUTH_GUARD` records that you understood this;
  it does not make the page safe by itself.
- `--scaffold`, `--copy-assets`, and `--convert-content` are rejected for
  Rails sources: those are the React/Markdown ports, and the Rails conversion
  is driven by `--target` alone.
- The conversion is deterministic — no timestamps, no absolute paths, no
  ambient state. Two runs over the same app and the same decisions file
  produce byte-identical trees. If they do not, that is a bug worth
  reporting, not something to work around.
