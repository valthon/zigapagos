# Rails → Zigapagos: discovery reference

`zigapagos migrate <rails-app> --from rails` is **discovery-only**. Unlike the
Astro adapter, it performs no conversion: it recovers what a Rails app's
routes, controllers, and views actually do, classifies each route with an
honest, evidence-gated verdict, and writes that as a human report
(`MIGRATION.md`) and a versioned JSON manifest
(`MIGRATION.manifest.json`). **It converts nothing.** Wiring the classified
routes into an actual Zigapagos target — content pages, islands, a `.spa.tsx`
— is tracked separately as issue #167 and is not implemented by this stage.

This is a deterministic reference for what discovery does and does not claim,
written for an agent or a human driving the tool unattended — not a tutorial.
If you haven't already, read `astro-to-zigapagos.md` first (this repository's
`docs/migration/` directory, or the published docs site — not shipped
alongside this file when it is installed standalone as part of the
`zigapagos-rails-migration` skill): this document follows the same house
register (mapping tables, exact command output, explicit gaps) but for a
narrower job — inventory and classification, not conversion.

```sh
zigapagos migrate path/to/rails-app -o MIGRATION.md
zigapagos migrate path/to/rails-app --from rails -o MIGRATION.md
zigapagos migrate path/to/rails-app --target path/to/new-site
zigapagos migrate path/to/rails-app --strict
```

Detection is automatic from conventional Rails evidence (`Gemfile`,
`config/application.rb`, `app/views`, …); pass `--from rails` explicitly in a
monorepo or when detection is ambiguous. `--from rails` on a tree with no
Rails evidence is fatal — it does not write a confident, empty report.

`--scaffold`, `--copy-assets`, and `--convert-content` are all rejected for
Rails: there is no conversion step for them to drive yet. `--target DIR` **is**
accepted, but its Rails behavior is narrower than for every other source —
see [`--target` for Rails](#8---target-for-rails) below.

Source files are read **only**. Route recovery is a **static AST walk** of
`config/routes.rb` through a Ruby/Prism sidecar — the app is never booted, no
initializer runs, no database connection is opened.

## 1. What gets written

Two artifacts, both regenerated on every run (plain overwrite, not the
`.new`/`.new.2` versioning `--scaffold`/`--copy-assets` use elsewhere — this
output is not hand-edited so there is nothing to preserve):

| File | What it is |
|---|---|
| `MIGRATION.md` (or `-o PATH`) | A human-readable rendering: inventory counts, routes with their classification and reason, blockers. |
| `<same stem>.manifest.json` beside it (e.g. `MIGRATION.manifest.json`) | The `zigapagos.rails-presentation/1` manifest — the **machine-readable contract**. `MIGRATION.md` is a *rendering* of the manifest's data, not an independent source of truth; when the two could be read to disagree, the manifest is authoritative. |

The manifest's shape is described by
`contract/rails-presentation.v1.schema.json` (this repository's root; not
shipped alongside this file in the standalone skill install) — a JSON Schema
**generated from** `src/cli/rails/manifest.zig`'s own Zig
types (`src/cli/rails/schema_gen.zig`), not hand-maintained. Field order in
every manifest object matches the schema's declared property order, and that
order is part of the wire contract: it is not safe to assume alphabetical or
arbitrary key ordering when writing a consumer.

## 2. The six classifications

Every recovered route gets exactly one `classification`, decided by a fixed,
**first-match-wins** rule chain (`src/cli/rails/classify.zig`). The order is
load-bearing, not stylistic: **`content` is the only value that asserts
something positive** — "this page is safe to treat as static." Every other
value is a deferral, a handoff, or a narrower claim:

| Value | What it actually asserts |
|---|---|
| `content` | The route's view (and its resolved layout and every partial it renders, transitively) show no request-time state and no interactivity marker, and a controller action was actually recovered to confirm it. The one positive claim discovery makes. |
| `island` | The view (or a partial/layout it renders) has a Stimulus `data-controller` attribute or a mounted component root. A narrower, still-positive claim — "this page has client-side interactivity," not "this page is static." |
| `backend` | Either the verb isn't `GET`/`HEAD`, **or** no view template exists **and** (the action renders JSON, or — when controller evidence is trustworthy — no action was recovered at all). "The action renders JSON" is not an independent trigger on its own: a dual-format `respond_to { |f| f.html; f.json { ... } }` action with a real, static `.html.erb` view classifies `content`, not `backend` — `classify.zig`'s rule 2 gates BOTH sub-clauses on `view == null` (see the numbered rule chain below, which states this correctly). A handoff: this route is a real backend responsibility, not a page to render. |
| `redirect` | The controller action's body is only a `redirect_to` call. A handoff to whatever routing scheme the target site uses. |
| `unresolved` | Discovery could not reach a verdict safely. See below — this is the value that obliges a human to look. |
| `spa` | **Never assigned.** See [below](#spa-is-never-assigned). |

`classify.Class` is checked first-match against `classify.zig`'s own rule
chain, in this exact order — numbered here exactly as `classify.zig`'s own
`Rule N:` comments number them, so a reader can jump straight to the source:
Rule 1, non-`GET`/`HEAD` verb → `backend`; Rule 2, no view template, with
either a JSON-rendering action or (when controller evidence is trustworthy) no
action at all → `backend`, otherwise (when controller evidence degraded) →
`unresolved`; Rule 3, a redirect-only action → `redirect`; an unlabeled guard
between rules 3 and 4 — no view left to classify at all → `unresolved`; Rule
4, an unsupported template engine (anything but ERB — Haml, Slim, Jbuilder,
Builder, or unidentified) → `unresolved`; Rule 5, request-time state read by
the view, its resolved layout, or a rendered partial → `unresolved`; Rule 6, a
Stimulus controller or component-root marker → `island`; Rule 7 — the last
resort, reachable only once every rule above failed to fire, and only when a
controller action was actually recovered — → `content`. That is eight
first-match checks total (seven of them the code's own numbered `Rule 1`–
`Rule 7`, plus the one unlabeled view-missing guard), not seven — an earlier
version of this paragraph renumbered them sequentially 1–8 instead of quoting
the code's own labels, which drifted the doc's numbering away from
`classify.zig`'s the moment a reader tried to match the two side by side. A
static-looking view with **no** recovered action does not reach
`content`; it falls to `unresolved` instead ("view looks static but no
controller action was recovered to confirm it"), because an absence of
counter-evidence is not proof.

### `unresolved` — what it obliges a human to do

Every route carries the exact string its classification rule returned, in
**both** artifacts: the manifest's `routes[].reason` field, and — right after
the classification, in parentheses — the corresponding line in `MIGRATION.md`
(e.g. `` - `GET /about` — unresolved (no view template to classify) ``). This
matters most for `unresolved`: `candidates[]` is empty by design for that
class (`classify.zig`'s rule chain never attaches a candidate to an
`unresolved` verdict), so `reason` is the *only* evidence a route classified
`unresolved` carries — without it there is no way to tell one `unresolved`
route from another, or to know which follow-up below applies. Every distinct
`unresolved` reason names a different follow-up:

| `routes[].reason` (verbatim, when `routes[].classification` == `unresolved`) | What a human needs to do |
|---|---|
| `no view template, and controller evidence was unavailable for this run` | Controller-shape discovery degraded wholesale for this run (no Ruby, no sidecar, no `app/controllers/`) — rerun with Ruby/the sidecar available before trusting any verdict near this route, or manually confirm the route's behavior. |
| `no view template to classify` | An action was recovered but no matching view template exists under `app/views/<controller>/<action>.*` — confirm by hand whether this action actually renders something (a partial name discovery couldn't resolve, an unconventional path) or is genuinely backend-only. |
| `unsupported template engine, never converted` | The view uses Haml, Slim, Jbuilder, Builder, or an engine discovery couldn't identify. Only ERB is proven-safe today; read the template yourself to decide `content` vs. `island` vs. something else. |
| `view reads request-time state` / `the resolved layout reads request-time state` / `a rendered partial reads request-time state` | The view, its layout, or a partial it renders references `current_user`, `session`, `flash`, `cookies`, or a non-route `params` read. Resolving *how* that state should be reproduced (a shared runtime store, a fetch, a dropped feature) is issue #167's job, not this stage's — for now, treat the route as not-yet-classifiable. |
| `view looks static but no controller action was recovered to confirm it` | The view shows no counter-evidence, but with no recovered action there is nothing to confirm it against. Rerun with controller discovery available, or manually verify the action's behavior. |

**A second, disjoint set of `unresolved` reasons comes from the transitive
template SCAN, not from `classify.zig`'s rule chain above.** Verified against
this project's own fixture: `GET /posts/featured` classifies `unresolved`
with `reason` `` template renders a dynamic partial target that cannot be
resolved statically `` — a string that does not appear in the table above at
all, because it is produced by `rails.zig`'s `unresolvedRenderReason`
(`transitiveScan` downgrading what would otherwise be a `content` verdict),
not by `classify.classify`. There are four of these, and — unlike every
reason in the table above — each one always has a same-route blocker naming
the affected file, so a human never has to treat the reason string alone as
the only evidence:

| `routes[].reason` (verbatim) | Accompanying blocker | What a human needs to do |
|---|---|---|
| `template renders a dynamic partial target that cannot be resolved statically` | `RAILS_TEMPLATE_RENDER_UNRESOLVED` | A `render` call's target is a Ruby expression (e.g. `render @post`), not a literal — confirm by hand which partial it actually resolves to at runtime. |
| `template renders a partial target that does not match any known template` | `RAILS_TEMPLATE_RENDER_UNRESOLVED` | A `render` call names a literal target that does not match any file this scan found — check for a typo, an unconventional path, or a partial generated some other way. |
| `template's partial nesting exceeds the depth this scan follows` | `RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED` | The partial chain nests deeper than this scan's bounded depth — read the blocker's `source.file` (where the walk stopped) and the templates below it by hand, or flatten the nesting. |
| `a layout or partial this template renders could not be read` | `RAILS_TEMPLATE_UNREADABLE` | A file in this route's template graph could not be read (permissions, a broken symlink) — fix the read failure and rerun; nothing about this route's true shape is known until then. |

A `RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED` or `RAILS_TEMPLATE_UNREADABLE`
blocker on a route's transitive template scan has the same effect one level
up: unscanned content is evidence discovery does not have, so a route whose
scan hit either condition cannot reach `content` — it lands on `unresolved`
too, for the identical "no false confidence" reason.

### `spa` is never assigned

`classify.Class` declares `spa` because the manifest schema declares it — the
design spec reserves the value for a future stage — but **no rule chain path
ever returns it**, and `classify.zig` pins that with a dedicated test ("spa is
never assigned without positive evidence"). Proving that a component root
*owns routing* (rather than just being a mounted island on an otherwise
server-rendered page) needs module and import resolution this stage does not
perform. A route whose view mounts a component root and would, once that
deeper analysis exists, turn out to be an SPA entry point classifies as
`island` today — a true but narrower claim. Do not read the presence of the
`spa` enum value in the schema as a signal that any route will ever actually
carry it from this tool.

## 3. `candidates[]` is a separate question from `classification`

`routes[].candidates` is not a second opinion on `classification` — the
six-value classification stays the Rails-side *fact* discovery found. Where
present, `candidates[]` names the **still-undecided** question of which
Zigapagos shape a route might become — e.g. an `island` route whose only
interactivity marker is a Stimulus controller also carries a `content`
candidate, because a Stimulus behavior *may* be portable to plain static
content (a mounted component root never earns that second candidate — it is
not portable the same way). Do not conflate "candidate target" with
"classification": a route's `candidates` list can be empty, one entry
matching its own classification, or (for that one Stimulus case) two.

## 4. `severity` vs. `integrity`: different axes

Every entry in `blockers[]` (both the manifest's top-level list and the
per-route ones a `route_id` names) carries **two independent fields**:

- **`integrity`** (bool) — whether this blocker means the inventory/route
  data itself cannot be trusted. **This is what the exit code is computed
  from** — any blocker with `integrity: true` makes the run exit non-zero
  (report and manifest are still written either way; only the exit status
  changes — see "report, never omit silently" below).
- **`severity`** (`"error"` | `"warn"`) — descriptive metadata about the
  finding, for a human or a consumer deciding how loudly to surface it.

**These do not derive from each other.** A run that simply lacks Ruby on
`PATH` reports `RAILS_RUBY_UNAVAILABLE`-style blockers at
`severity: "error"` — loud, because route/controller recovery genuinely could
not run — but `integrity: false`, because the inventory scan itself (files,
assets, Gemfile) is unaffected and still trustworthy. **A consumer that
filters `severity == "error"` will see errors on an otherwise healthy run.**
Read `integrity` for "can I trust these counts," and `severity` for "how
should I present this to a person" — never substitute one for the other.

## 5. `--strict`

`--strict` (Rails only; rejected for every other source) widens the exit-code
check: it fails on **any** blocker at all, `severity`-blind, not a filtered
subset. Concretely (`railsExitError` in `src/cli/migrate.zig`):

- without `--strict`: exit non-zero **iff** at least one blocker has
  `integrity: true`;
- with `--strict`: exit non-zero if **either** an integrity blocker exists
  **or** `blockers[]` is non-empty at all — including purely descriptive,
  non-integrity, `warn`-severity findings like an unsupported template
  engine or a dynamic route path.

`--strict` never changes what gets written — `MIGRATION.md` and the manifest
are byte-identical with or without it. It exists for an agent loop or a CI
gate that wants "clean discovery, or nothing" as a single exit-code check,
without having to parse the manifest's `blockers[]` itself.

## 6. Route identity: `routes[].id` is not unique

`routes[].id` is `"<VERB> <path>"` (e.g. `"GET /articles/:id"`), formatted by
`rails.formatRouteId`. It is a **label for display, not a unique key**. Two
identical route declarations in `config/routes.rb` — an unusual but not
rejected occurrence — produce the same `id`. Do not build a map keyed on
`id` and expect one entry per declaration.

The same non-uniqueness applies from the other direction to a blocker's
`route_id`: `RAILS_TEMPLATE_UNREADABLE` and similar template-graph blockers
are deduplicated **per unreadable file**, not per affected route. A layout
shared by twenty routes that fails to read produces **one** blocker, and its
`route_id` names whichever route's scan happened to hit the unreadable file
first — not an exhaustive list of the other nineteen. Treat a `route_id` on a
blocker as "at least this one route is affected," never as "only this one."

## 7. What discovery reads, and what it never does

- Route recovery is a **static AST walk** (`origin: "static_ast"` on every
  route today — `"actiondispatch"` and `"routes_import"` are reserved enum
  values for a future, unimplemented recovery path, not something this
  version of the tool ever emits) of `config/routes.rb`, run through a
  Ruby/Prism sidecar process. The Rails app itself is **never booted**: no
  initializer runs, no database connects, no middleware loads.
- Every route also carries `routes[].confidence` — `"certain"` or
  `"uncertain"` — which is a **different claim from `classification`**:
  confidence is about whether the *route itself* was recovered reliably,
  independent of what it was then classified as. `"uncertain"` means the
  route was found through a construct the parser can see the shape of but
  not the activation of (a route declared inside `if`/`unless`/`case`) —
  treat it as a lead, not a settled fact. `MIGRATION.md` marks this visibly:
  an uncertain route's line carries a `— **uncertain**` marker between its
  destination and its classification (e.g.
  `` - `GET /x` — **uncertain** — unresolved (...) ``), and a route can be
  both uncertain AND classified — those are independent claims, not mutually
  exclusive ones.
- `templates[].renders == []` **ordinarily means exactly what it says: this
  template renders nothing.** That is the common case — 9 of the 12
  templates in this project's own checked-in fixture render with an empty
  `renders`, and none of them hit the depth cap. The one other cause
  collapses to the identical empty value: at `RAILS_TEMPLATE_RENDER_DEPTH_
  EXCEEDED`'s three-hop partial-nesting cap, the scan stops looking and that
  node's `renders` is empty because its own targets were genuinely never
  resolved. The two are **not** distinguishable from `renders` alone — the
  disambiguator is `blockers[]`: only when a `RAILS_TEMPLATE_RENDER_DEPTH_
  EXCEEDED` blocker names this same template's path was the walk cut short;
  absent that blocker, an empty `renders` means what it says. An unreadable
  template never becomes a `templates[]` entry at all (its render targets are
  unknown, not empty), so every entry that DOES appear here was itself
  successfully read.
- The layout resolved for a route (`routes[].layout`) is a **convention**
  (`app/views/layouts/<controller>.*`, else `app/views/layouts/application.*`)
  — not read from a `layout` declaration in the controller's source. Reading
  that declaration is deeper controller analysis out of scope for this
  stage; convention is right for the overwhelming majority of apps but is
  not a guarantee for one that overrides it per-controller.
- **Report, never omit silently**: even a run that hits a wholesale
  degradation (no Ruby, no sidecar, an unreadable `Gemfile`) still writes
  `MIGRATION.md` and the manifest — only the exit code (and, honestly, the
  trustworthiness of the counts) changes. A script should check the exit
  code and `blockers[]`, not assume a written report means a clean one.

## 8. `--target` for Rails

For every other source, `--target DIR` assembles a scaffolded Zigapagos
project — content conversion, island scaffolding, asset copying. **For
Rails, which converts nothing, `--target DIR` writes only the same two
discovery artifacts** — `DIR/MIGRATION.md` and `DIR/MIGRATION.manifest.json`
— into `DIR` instead of alongside the default `-o` path. No `zigapagos.ziggy`,
no `content/`, no `components/` — nothing else is assembled. `DIR` must be
missing or empty, and must not be inside the source tree, the same
guards every other `--target` use enforces. `--runtime-path` (which only
matters when there are React island candidates to scaffold) has no effect for
Rails and is rejected unless a `--target` is also given.

## Procedure (for an agent)

1. **Discover.** `zigapagos migrate <rails-app> --from rails -o MIGRATION.md`.
   Read the exit code: non-zero means at least one `integrity: true` blocker
   fired (or, under `--strict`, any blocker at all) — treat the counts as
   provisional until that's resolved (commonly: install/expose Ruby and the
   sidecar's dependencies, or fix an unreadable file).
2. **Read the manifest**, not just the prose report, for anything driving
   further automation — it is the binding shape
   (`contract/rails-presentation.v1.schema.json` describes it precisely).
3. **Triage by classification.** `content` routes are the only ones safe to
   treat as static without further review. `island` routes need their
   component's own source read. `backend`/`redirect` routes are handoffs to
   whatever serves the target site's dynamic behavior. For each `unresolved`
   route, read its `routes[].reason` (or the parenthesized text after
   `unresolved` in `MIGRATION.md`) and look that exact string up in the table
   in [§2](#unresolved--what-it-obliges-a-human-to-do) above for the specific
   follow-up it names.
4. **Do not attempt conversion here.** This stage's output is an honest
   inventory and classification, not a target project. Turning a classified
   route into actual Zigapagos content, an island, or a `.spa.tsx` route is
   issue #167 — a separate, not-yet-implemented stage.
