# Rails → Zigapagos: discovery reference

`zigapagos migrate <rails-app> --from rails` is **discovery, plus (as of
issue #167 Stage 1) per-fragment findings — still no conversion**. It
recovers what a Rails app's routes, controllers, and views actually do,
classifies each route with an honest, evidence-gated verdict, resolves each
`certain` route's Rails helper `name` and each controller's declared
`layout`, and parses every route-reachable ERB template into a closed
vocabulary of fragments — surfacing anything a converter would need a human
decision on as a `findings[]` entry. All of that is written as a human report
(`MIGRATION.md`) and a versioned JSON manifest (`MIGRATION.manifest.json`).
**It converts nothing.** Turning a finding's `choices` (or a classified
route) into an actual Zigapagos target — content pages, islands, a
`.spa.tsx` — is issue #167 **Stage 2**, and is not implemented yet.

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

As of #167 Stage 1, the manifest also carries a top-level `findings[]` array
— the **last** key, after `blockers[]` — one entry per per-fragment or
per-declaration question a converter would need an operator to answer. See
[§9](#9-route-names-stage-1) through [§12](#12-the-fragment-vocabulary)
below for what a finding means, its id format, and the closed vocabulary it
is derived from.

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
| `view reads request-time state` / `the resolved layout reads request-time state` / `a rendered partial reads request-time state` | The view, its layout, or a partial it renders references `current_user`, `session`, `flash`, `cookies`, or a non-route `params` read. This is still `unresolved` as a *classification* — resolving *how* that state should be reproduced (a shared runtime store, a fetch, a dropped feature) is issue #167 Stage 2's job, not this stage's. As of Stage 1, the same fragment also surfaces as a `RAILS_REQUEST_TIME_STATE` finding ([§11](#11-findings)) with concrete `choices` — read that finding rather than treating the route as a dead end. |
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
- The layout resolved for a route (`routes[].layout`) prefers a **literal**
  `layout` declaration on the controller over convention — as of #167 Stage
  1; before it, this field was convention-only. See
  [§10](#10-layouts-stage-1) for the exact four-case rule (literal beats
  convention, a missing declared layout resolves to none, `false` disables,
  a dynamic declaration falls back to convention plus a finding). Absent any
  declaration, the convention is `app/views/layouts/<controller>.*`, else
  `app/views/layouts/application.*` — `null` when neither exists, same as
  before.
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

## 9. Route names (Stage 1)

Every recovered route's `routes[].name` field — always `null` before #167
Stage 1 — is now filled with the Rails route-helper stem (`posts` for
`posts_path`/`posts_url`), derived by the same rules Rails' own `Mapper`
applies, so a helper in a template can be resolved back to a route without
booting the app. `name` stays `null` in exactly two cases: the route is
`uncertain` (see [§7](#7-what-discovery-reads-and-what-it-never-does)) — a
helper resolving to a route this parser is not vouching for becomes a
finding, never a guess — or the route genuinely has no Rails-derivable name
(a literal path with a `:param`/`*glob` segment and no `as:`).

The derivation rules (`runtime/sidecar/rails/routes.rb`'s `emit` /
`prefixed_name` / `derived_name_from_path`):

- `resources :posts` names its actions off the plural/singular stem:
  `index`/`create` → `posts`; `new` → `new_post`; `edit` → `edit_post`;
  `show`/`update`/`destroy` → `post`. A singular `resource :profile` (no
  plural of its own) names `create`/`show`/`update`/`destroy` `profile`;
  `new`/`edit` still get the `new_<stem>`/`edit_<stem>` prefix regardless
  of singular/plural, so they are `new_profile`/`edit_profile`, not bare
  `profile`.
- `member { post :publish }` → `publish_post`; `collection { get :recent }`
  → `recent_posts`; `new { get :preview }` → `preview_new_post` — Rails'
  `<verb-name>_<singular-or-plural>` convention for a route declared inside a
  `member`/`collection`/`new` block.
- A bare route nested directly in a `resources`/`resource` block, with
  **no** `member`/`collection`/`new` wrapper (`resources :posts do get
  :stats end`) → `<parent_singular>_<verb-name>` (e.g. `post_stats`) — name
  first, segment second, the reverse order from the member/collection case
  above.
- A nested resource compounds onto its parent's **singular** stem, however
  many levels deep: `resources :posts do resources :comments do resources
  :replies end end` names `replies`' own routes `post_comment_reply` /
  `post_comment_replies`, never off the plural.
- `namespace :admin` and `scope as: "x"` push onto an accumulated
  `as_prefix`, joined with `_`, prepended to every name declared inside —
  independent of the `path:`/`module:` prefixes, which have their own
  overrides.
- `as:` — on `resources`/`resource`, a verb call, or `root` — always
  overrides the derived stem, and every action name re-derives from that
  override (`resources :articles, as: :stories` names `new_story`, not
  `new_article`).
- `root` → named `root` (or prefixed, e.g. `admin_root`).
- A literal path outside all of the above derives its name from the path
  itself: segments joined by `_`, hyphens folded to underscores (`get
  "/about-us"` → `about_us`).
- Any segment that is a `:param` or a `*glob` makes the route nameless —
  Rails would not generate a helper for it either.
- A non-literal `as:` (a method call, an interpolated string) is
  `RAILS_ROUTE_DYNAMIC_PATH`, the same unresolved code every other
  unresolvable literal argument in this parser already reports — the route
  it would have named is not emitted with a guessed name.

**Known gap, follow-up filed:** a singular `resource :x` derives controller
`x`, but Rails maps a singular resource to the **plural** controller
(`resource :profile` → `ProfilesController`, not `ProfileController`) unless
`controller:` is given explicitly. Pass `controller:` on every singular
`resource` until this is fixed.

## 10. Layouts (Stage 1)

`routes[].layout` now takes a controller's own declared `layout` into
account, not the convention-only scan the field used to run (see
[§7](#7-what-discovery-reads-and-what-it-never-does)'s layout bullet for the
before/after). The four cases, in priority order:

- **A literal `layout "x"` beats convention.** If a matching `app/views/
  layouts/x.*` exists on disk, that is the resolved layout — even when a
  per-controller or app-wide default layout also exists.
- **A declared layout absent on disk resolves to no layout at all — not the
  convention fallback.** Rails raises at render time for a missing named
  layout; silently substituting `application` here would report a template
  graph the app never actually renders.
- **`layout false` disables the layout entirely.** `routes[].layout` is
  `null`, the same shape as "no layout found."
- **A symbol, a proc, or a literal carrying `only:`/`except:` is dynamic.**
  Any of these is decided per request, which this static walk cannot
  resolve — the layout falls back to convention (so the route still gets a
  plausible layout to classify against) **and** a `RAILS_LAYOUT_DYNAMIC`
  finding is emitted, naming the controller file and the declaration's
  line, so the approximation is visible rather than silent.
- `self.layout "x"` is the identical class-level call as the bare `layout
  "x"` form and is read the same way; a `layout` call on any other receiver
  (`Foo.layout`) is not this controller's own declaration and is ignored.

## 11. Findings

`findings[]` is the manifest's new top-level array (the last key, after
`blockers[]` — see [§1](#1-what-gets-written)): a per-fragment or
per-declaration **question for the operator**, not a fact discovery already
settled. A blocker states what discovery could or could not establish; a
finding states a decision a converter cannot make on the operator's behalf,
with a fixed list of `choices`. **A finding is never a blocker in disguise:
it does not affect the exit code, with or without `--strict`, and it never
makes `MIGRATION.md` or the manifest any less trustworthy.**

A real entry, from this repository's own `tests/migrate/rails-presentation`
fixture:

```jsonc
{
  "id": "RAILS_HELPER_UNKNOWN.app/views/pages/help%2Ehtml%2Eerb.L1C18",
  "code": "RAILS_HELPER_UNKNOWN",
  "severity": "warn",
  "source": { "file": "app/views/pages/help.html.erb", "line": 1 },
  "route_id": null,
  "message": "unknown helper `number_to_currency`",
  "choices": ["island", "retain", "blocked"],
  "requires_artifact": false
}
```

- **`id`** is `<code>.<path>.<loc>`, with `%` escaped to `%25` and `.` to
  `%2E` (in that order, so the mapping is reversible) in each of `code` and
  `path`; `loc` is `L<line>C<col>` for a template-node finding, or
  `L<line>` for a parse-error or layout finding, or the word `unscanned`
  for a view the fragment analysis never read. `id` is stable across a
  reworded `message` or a template edit elsewhere in the file — a future
  stage's decision file references a finding by `id`, never by array
  position or message text. `col` is the 1-based source column of the
  **fragment**, not of the `<% %>` tag around it: one tag can hold several
  fragments (`<% number_to_currency(1); pluralize(2) %>`), and each gets its
  own column so each gets its own `id`.
- **`code`** is the stable, machine-greppable identifier
  (`RAILS_HELPER_UNKNOWN`, `RAILS_LAYOUT_DYNAMIC`, …).
- **`severity`** — `"warn"` or `"error"` — the same two-value type
  `blockers[]` uses, but per the note above it never touches the exit code
  the way a blocker's `integrity` does.
- **`source`** — `{file, line}`.
- **`route_id`** is **always `null` in Stage 1** — every finding is scoped
  to a template or a controller file, not yet joined to a specific route.
- **`message`** is human prose, explicitly **not** part of `id`; reword it
  freely without invalidating a previously recorded decision.
- **`choices`** is the fixed set of answers an operator may record against
  this finding.
- **`requires_artifact`** is `false` for every Stage 1 finding — none of
  them demands generating a component or file yet, only recording a choice.

`findings[]` is sorted by `(code, path, line, id)`. `MIGRATION.md` renders a
separate `## Findings` section, after `## Blockers` on purpose — the two
must never be mixed into one list a reader could mistake for a single kind
of thing. It says `None.` when the array is empty rather than omitting the
section; otherwise it prints a count line per distinct code, then one line
per finding — both also real output from the same fixture run:

```
## Findings

- RAILS_HELPER_UNKNOWN: 1
- RAILS_I18N_UNRESOLVED: 1
- RAILS_LAYOUT_DYNAMIC: 1
...

- `RAILS_HELPER_UNKNOWN` `app/views/pages/help.html.erb:1` — unknown helper `number_to_currency` (choices: island, retain, blocked)
...
```

Stage 1 derives these codes — `src/cli/rails/findings.zig`'s derivation
table is the single source of truth:

| Code | Trigger | Choices |
|---|---|---|
| `RAILS_HELPER_UNKNOWN` | a fragment classifies `unknown` — outside the closed vocabulary, [§12](#12-the-fragment-vocabulary) | island, retain, blocked |
| `RAILS_REQUEST_TIME_STATE` | `current_user`/`session`/`flash`/`cookies`/non-route `params`/`request.`/`policy(`/… or a bare `@ivar` | island, spa, backend, retain, blocked |
| `RAILS_I18N_UNRESOLVED` | `t("key")` has no entry under the default locale | retain, blocked |
| `RAILS_RAW_OUTPUT` | `<%== %>`, `raw(...)`, `.html_safe` | island, retain, blocked |
| `RAILS_PARTIAL_DYNAMIC` | `render @x`, `collection:`, or non-literal `locals:` | island, spa, retain, blocked |
| `RAILS_ROUTE_HELPER_DYNAMIC` | a `*_path`/`*_url` helper (or `link_to`'s route target) has non-literal arguments | island, spa, retain, blocked |
| `RAILS_ROUTE_HELPER_UNKNOWN` | a route helper's name matches no `certain` named route (an unnamed or `uncertain` route) | retain, blocked |
| `RAILS_TEMPLATE_CONTROL_FLOW` | `if`/`unless`/`case`/`while`/`until` (also a bare `.each`/`.map`/… loop over a plain local) whose branch predicate classifies as `literal`, `local`, or `unknown` — i.e. nothing more specific applies; a request-state/ivar/errors predicate takes that kind instead (and that kind's own finding, or none for `errors`) | island, spa, retain, blocked |
| `RAILS_TEMPLATE_PARSE_ERROR` | a template's Ruby fragments do not assemble into valid Ruby | retain, blocked |
| `RAILS_TEMPLATE_UNSCANNED` | the fragment analysis refused the view outright — it resolved outside the app root, or could not be read at the moment the analysis ran (a file replaced or removed mid-run). Distinct from the `RAILS_TEMPLATE_UNREADABLE` *blocker*, which is the earlier template-graph scan failing to read a file: here that scan succeeded, so nothing else in the manifest mentions the view at all. Its `loc` is the word `unscanned`, not an `L<line>` — the file was never parsed, so there is no line to point at | retain, blocked |
| `RAILS_LAYOUT_DYNAMIC` | a controller's `layout` declaration is a symbol, a proc, or carries `only:`/`except:` | retain, blocked |

Only the **default** locale's `t()` keys are resolved (`config.i18n.
default_locale`, else `en`); a key that only exists in a non-default locale
still reports `RAILS_I18N_UNRESOLVED` — non-default locales are out of scope
for this stage entirely, not a partial best-effort.

A `config/locales/**` file that fails to load (a YAML syntax error, a read
failure, or a construct the loader deliberately refuses) is **skipped**, not
fatal, which leaves the translation table empty or partial — and then every
`t()` key in the app looks missing. That would be N `RAILS_I18N_UNRESOLVED`
findings blaming the templates for a broken YAML file, so discovery says so
twice: one `RAILS_I18N_LOCALE_UNREADABLE` **blocker** (`warn`, non-integrity
— the inventory and the route graph are unaffected) per file that failed,
naming the file and the Ruby error; and a caveat appended to every
`RAILS_I18N_UNRESOLVED` message for that run — *"— a locale file failed to
load: `config/locales/en.yml`"*. The findings keep their code, their
`choices` and their `id`: the key really does not resolve and the decision
is unchanged; what the caveat fixes is the *reason* the operator would
otherwise infer.

The sidecar parses locale files from untrusted third-party apps, so what
counts as "a construct the loader deliberately refuses" above is itself
deliberate: YAML aliases (`*ref`) are not accepted in locale files — inline
the referenced block — because expanding one lets a small file balloon into
a huge one ("billion laughs"); an anchor definition (`&ref`) alone is not
itself the hole and loads fine, since nothing expands until something
references it. `permitted_classes: [Symbol, Date, Time]` accepts three
plain-scalar tags without reopening that hole: Symbol, because Rails' own
shipped locale files use one (`date.order: [:year, :month, :day]`) and apps
copy that idiom; Date and Time, because Psych's core schema resolves an
untagged scalar like `since: 2024-01-01` to one of them with no explicit
tag at all, and Rails itself loads such a file without complaint. None of
the three is an instantiation or size-expansion vector under `safe_load`; a
non-String leaf (Symbol, Date, Time, or otherwise) is simply ignored by
lookup rather than resolved.

## 12. The fragment vocabulary

`erb.rb` scans a template with Erubi's grammar; `templates.rb` compiles its
Ruby fragments into one program, parses it once with Prism, and classifies
each fragment into one of the kinds below — block structure (`do…end`,
`if…else…end`) becomes real, explicit `block_else`/`block_end` nodes in the
stream rather than being inferred from indentation. A template's Haml/Slim
sibling is never sent through this op at all — it already carries
`RAILS_TEMPLATE_ENGINE_UNSUPPORTED` and asking an ERB parser to scan
non-ERB source would only manufacture a parse error on top of a finding
that already exists. This table is the design spec's own "Fragment
vocabulary" table, unchanged, with a fourth column added: what Stage 1
actually does with each kind today. **Every kind is classified in Stage 1;
none is converted — conversion, the "conversion" column below, is Stage
2's job.**

| kind                  | Ruby shape                                                       | conversion                                      | Stage 1 status |
| --------------------- | ------------------------------------------------------------------ | ----------------------------------------------- | --- |
| `yield`               | `yield`                                                          | `<super>` inside the block element `id="main"`  | classified |
| `yield_named`         | `yield :head`, `content_for?(:x)`                                | named `<super>` block `id="<name>"`             | classified |
| `content_for`         | `content_for :x do … end`, `provide(:x, "literal")`              | child block `<… id="<name>">`                   | classified |
| `render_partial`      | `render "x"`, `render partial: "x"` with no `locals:`/`collection:` | inline expansion of the converted partial    | classified |
| `render_partial_locals` | same with `locals:` of literals only                           | inline expansion with literal substitution      | classified |
| `render_dynamic`      | `render @x`, `collection:`, non-literal locals                   | finding `RAILS_PARTIAL_DYNAMIC`                 | finding: `RAILS_PARTIAL_DYNAMIC` |
| `route_helper`        | `<name>_path`, `<name>_url`, no args or literal args             | the route's path, literals substituted          | classified; finding: `RAILS_ROUTE_HELPER_UNKNOWN` when its name matches no `certain` route |
| `route_helper_dynamic`| args are not literals                                            | finding `RAILS_ROUTE_HELPER_DYNAMIC`            | finding: `RAILS_ROUTE_HELPER_DYNAMIC` |
| `link_to`             | `link_to "text", <route_helper> [, html_opts literals]`          | `<a href="…">text</a>`                          | classified (also covers `button_to`); finding: `RAILS_ROUTE_HELPER_UNKNOWN` when its route name matches no `certain` route |
| `asset`               | `image_tag`, `image_path`, `asset_path`, `stylesheet_link_tag`, `javascript_include_tag`, `favicon_link_tag` with a literal | `$site.asset('…').link()` when `assets[]` has it deterministic; else `RAILS_ASSET_TRANSFORM` | classified (no finding yet — asset resolution, and `RAILS_ASSET_TRANSFORM`, land with conversion) |
| `importmap`           | `javascript_importmap_tags`, `turbo_include_tags`                | dropped; one finding `RAILS_JS_ENTRY` per app   | classified (no finding yet — `RAILS_JS_ENTRY` lands with conversion) |
| `csrf`                | `csrf_meta_tags`, `csp_meta_tag`                                 | dropped; noted in `MIGRATION.md` (ZigBase cookie/CSRF boundary owns this) | classified (drop-with-note lands with conversion) |
| `i18n`                | `t("key")`, `t(".key")`, `I18n.t`                                | resolved literal; `RAILS_I18N_UNRESOLVED` if missing | classified; finding: `RAILS_I18N_UNRESOLVED` when the key is missing from the default locale |
| `literal`             | string/number/`nil`/`true`/`false`                               | HTML-escaped text                               | classified |
| `form`                | `form_with`/`form_for`/`form_tag` block and its `f.*` builder calls | form island scaffold (see Backend boundary)  | classified (no finding yet — form conversion is a later stage) |
| `form_field`          | `f.text_field :title`, `f.label`, `f.submit`, `f.check_box`, `f.select` with literal options, `f.text_area`, `f.email_field`, `f.password_field`, `f.hidden_field` | field descriptor inside the enclosing `form` | classified (no finding yet) |
| `errors`              | `@x.errors.full_messages`, `errors.any?`, `f.object.errors[:y]`   | validation-presentation region of the form island | classified (no finding yet) |
| `request_state`       | `current_user`, `session`, `flash`, `cookies`, `params` (non-route), `request.`, `signed_in?`, `policy(`, `can?`, `Current.` | finding `RAILS_REQUEST_TIME_STATE`             | finding: `RAILS_REQUEST_TIME_STATE` |
| `ivar`                | `@anything` outside the shapes above                             | finding `RAILS_REQUEST_TIME_STATE`              | finding: `RAILS_REQUEST_TIME_STATE` |
| `control`             | `if`/`unless`/`case`/`each` whose condition classifies as `literal`, `local` or `unknown` (a request-state/ivar/errors condition takes that kind instead) | finding `RAILS_TEMPLATE_CONTROL_FLOW`           | finding: `RAILS_TEMPLATE_CONTROL_FLOW` |
| `turbo_frame`         | `turbo_frame_tag`                                                | see Interactivity                               | classified (no finding yet — `RAILS_TURBO_FRAME` is a later stage) |
| `turbo_stream`        | `turbo_stream_from`, `turbo_stream.*`                            | finding `RAILS_TURBO_STREAM`                    | classified (no finding yet — `RAILS_TURBO_STREAM` is a later stage) |
| `component_root`      | `react_component("Name", {…})`                                   | see Interactivity                               | classified (no finding yet — the React-root findings are a later stage) |
| `raw`                 | `<%== %>`, `raw(...)`, `.html_safe`                              | finding `RAILS_RAW_OUTPUT` — unescaped output is never passed through | finding: `RAILS_RAW_OUTPUT` |
| `comment`             | `<%# %>`                                                         | dropped                                         | dropped before classification — `erb.rb`'s tokenizer consumes a comment tag and emits no token for it at all, so no `comment` node ever reaches `templates.rb` |
| `unknown`             | everything else                                                  | finding `RAILS_HELPER_UNKNOWN`                  | finding: `RAILS_HELPER_UNKNOWN` |

`erb.rb`/`templates.rb` also produce a handful of purely structural node
kinds this table's spec original does not list because they carry no
finding of their own and never will: `block_else`/`block_end` (the
`else`/`elsif`/`when`/`in`/`end` fragment closing an emitted block) and
`local` (a bare template-local variable, e.g. a block param or a `each` loop
variable — distinct from `ivar`, which is always request-time state). A
plain text run between tags never produces a finding either, regardless of
its content — only a classified Ruby fragment can.

The `templates` op refuses to read outside the Rails app root: a request
naming an absolute path, a path containing `..`, or a path that resolves
(after following symlinks) outside the app root's own resolved path comes
back `unreadable: "outside root"` rather than being read — the check is
applied twice, once cheaply on the unresolved path and once again with
`File.realpath` on the resolved one, so a symlink that itself points outside
the root cannot be used to read arbitrary files from the machine running
discovery.

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
4. **Read `findings[]`.** Each is a question with a fixed set of `choices` —
   see [§11](#11-findings) for the field list and [§12](#12-the-fragment-vocabulary)
   for what fragment kind produced it. Nothing converts yet: recording an
   answer has nowhere to go until issue #167 Stage 2 adds a
   `MIGRATION.decisions.json` input this tool reads back.
5. **Do not attempt conversion here.** This stage's output is an honest
   inventory, classification, and a set of findings — not a target project.
   Turning a classified route or an answered finding into actual Zigapagos
   content, an island, or a `.spa.tsx` route is issue #167 **Stage 2**, not
   yet implemented.
