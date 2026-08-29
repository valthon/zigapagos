# Rails presentation migration

Design for [#167](https://github.com/valthon/zigapagos/issues/167). It consumes
the `zigapagos.rails-presentation/1` manifest that
[#166](2026-08-22-rails-source-discovery-design.md) produces and turns the
*supported* part of a Rails frontend into a Zigapagos target, while making every
unsupported part an explicit, acknowledgeable finding. #166 discovers and
converts nothing; this work converts, and its central rule is the inverse of
#166's: **nothing is reported as migrated unless a converter proved it.**

## What #166 left on the table

Facts established by reading the shipped code, because the shape of this design
follows from them:

- **Nothing parses ERB.** `src/cli/rails/template_scan.zig` is three
  `std.mem.indexOf` sweeps for request-state markers, Stimulus attributes and
  component roots, plus four literal `render` shapes. The Ruby sidecar
  (`runtime/sidecar/rails/analyze.rb`) has two ops, `routes` and
  `controllers`, and never opens `app/views/`. There is no document tree a
  converter could consume.
- **Route `name` is always `null`** (`routes.rb:768-771`), so `posts_path`
  cannot be resolved to `/posts` today. Route helpers are the single most
  common thing in a Rails template.
- **Controllers yield three facts per action** (`only_redirect`,
  `renders_json`, `line`). A `layout "x"` declaration is invisible; layouts
  are resolved by convention only (`rails.zig:896`).
- **`classify.Class.spa` is declared and never assigned**, pinned by a test.
  `RouteEntry.candidates[]` was designed as this issue's input
  (`classify.zig:130-133`).
- **The `--target` seam exists** (`migrate.zig:906-928`, validated
  not-inside-source and must-be-empty) and returns at `:1016`, before
  `assembleTarget` at `:1022`. `tests/migrate/rails.sh:458` pins the target
  listing to exactly two files as a deliberate tripwire.
- **There is no template converter anywhere in the repo.** The Astro path
  writes fixed `.shtml` literals (`init_from_astro.emitLayoutStub`) and lists
  layouts as worklist items. ERB→SuperHTML is the first real one.
- **Schema `/1` has not shipped in a release**
  (`contract/rails-presentation.v1.schema.json:5`), so additive *required*
  fields are still free. That window closes at the next release that carries
  the schema.
- On the ZigBase side, the backend half of a Rails migration already exists:
  `docs/migrate-rails-api.md` + `tools/rails/rails2zb.py`, whose vocabulary is
  `Finding{id, severity, code, message, choices, requiresArtifact}` and
  `Decision{id, choice, rationale, artifact}`. `app openapi` emits an OpenAPI
  document with `x-zigbase-coverage.consumerRoutes`, and Zigapagos already
  reads exactly that format in `runtime/scripts/apigen.ts`.
  `docs/zigapagos-pairing.md` and the `zigbase-zigapagos-fullstack` skill are
  the "coordinating full-stack migration skill" the issue names.

## Decisions taken — review these

Each of these changes what gets built. They are listed first so a reviewer can
veto one without reading the mechanism that follows it.

1. **Target shape is SuperHTML + `.smd`, not TSX.** #166's spec called this
   work "ERB-to-TSX". A Rails view is a server-rendered document; the Zigapagos
   equivalent is a `.shtml` layout plus a `.smd` page (the blog example in
   ZigBase, `examples/blog/frontend/`, is exactly this shape). TSX is reserved
   for what actually needs a client: Stimulus/React/Turbo-frame regions become
   `<island>` elements with generated `.island.tsx` scaffolds, and dynamic
   routes may become a `.spa.tsx` — by decision, never by default. Converting
   every page to TSX would make every page an island, lose static rendering,
   and force the `tsc` props gate onto content that has no props.
   *Alternative:* TSX everywhere. Rejected for the reasons above.
2. **The sidecar parses ERB whole: tokenize and classify in Ruby, assemble
   in Zig.** `erb.rb` scans a template with Erubi's grammar (Rails does not
   use stdlib `ERB`; Erubi's scanner is one regex, vendored the way
   `inflect.rb` vendors the inflector, so `<%==` raw output and the trim modes
   behave as Rails' do), classifies each Ruby fragment with Prism into a
   closed vocabulary, and returns one ordered node stream per template —
   `[{text}, {code, kind, …}, …]`. Zig walks that stream and does the
   SuperHTML-structure work (wrapping a `data-controller` element in
   `<island>`, placing `<super>`, inlining partials) on the text runs. Without
   Ruby there is no conversion, and every convertible route reports it — the
   same degradation #166 already documents.
   *Alternative:* tokenize in Zig, classify fragments in Ruby. Rejected on
   review: it needs ids and position stitching across the wire for no gain,
   since a Ruby-less run cannot convert anyway, and a Zig grammar would be a
   second, unverified copy of Erubi's lexing rules.
   *Alternative:* pattern-match the fragment vocabulary in Zig. Rejected: the
   #166 spike measured lexical matching at 54% precision on a smaller grammar.
3. **The backend endpoint manifest is a ZigBase OpenAPI document.** Passed as
   `--backend FILE`; read with `std.json` only; the format is what
   `app openapi` emits and what `apigen.ts` already consumes. No new contract.
   *Alternative:* a bespoke `rails-backend.json`. Rejected: a second format
   for the same facts, and the operator would author it by hand.
4. **Decisions mirror `rails2zb`.** Findings are emitted by the tool with
   stable ids and `choices`; the operator answers in
   `MIGRATION.decisions.json` (`{id, choice, rationale, artifact?}`); the tool
   re-runs consuming them. Same nouns, same escaping rules, same "message is
   not identity" invariant, so an operator who did the backend half is not
   learning a second system.
5. **Completion is a computed verdict with its own exit code, not a flag.** A
   conversion run exits non-zero while any user-facing route has neither a
   migrated artifact nor an acknowledged finding. The first run of any real
   app therefore fails, by design. `--strict` keeps its existing meaning.
6. **Digested asset URLs are recorded, not reproduced.** `public/`-rooted
   files keep their exact URL. Pipeline assets are copied undigested and every
   old→new URL pair is written to the handoff so the host can redirect. A
   digest belongs to the pipeline that computed it; reproducing it would be a
   lie about who owns cache-busting.
   *Alternative:* write `assets/assets/logo-<digest>.png` so the URL survives
   verbatim. Rejected as a path nobody would maintain.
7. **Vue is a blocker.** `docs/migration/react-spa-bridge.md` is React-only.
   A `data-vue-component` root gets `RAILS_COMPONENT_VUE_UNSUPPORTED`; the
   issue's "where the current runtime bridge supports them" is satisfied by
   saying so.
8. **One new fixture app, not four.** `tests/migrate/rails-presentation/`
   holds the whole supported matrix plus one of each blocker so the "cannot be
   silently marked complete" criterion is an assertion. The two existing
   fixtures stay as they are.

## Architecture

```
zigapagos migrate <rails-app> --from rails --target DIR
        [--backend openapi.json] [--decisions MIGRATION.decisions.json]

  #166 discovery (unchanged) ──► rails.Discovery
                                     │
  Zig: src/cli/rails/                │        Ruby sidecar (Prism, stdlib only)
    fragments.zig node stream ◄──────┼──────  erb.rb        Erubi-grammar scan
                                     │        templates.rb  classify fragments
    names.zig     route helpers ◄────┼──────  routes.rb     fill `name`
                                     │        i18n.rb       config/locales/*.yml
    backend.zig   read OpenAPI       │        controllers.rb `layout` decl
    convert.zig   ERB subset → SuperHTML
    findings.zig  stable ids + choices
    decisions.zig read operator answers
    scaffold.zig  write the target tree
    handoff.zig   MIGRATION.handoff.json (+ schema)
    parity.zig    checklist entries
                                     │
  DIR/  zigapagos.ziggy  content/  layouts/  components/  assets/  lib/  test/
        MIGRATION.md  MIGRATION.manifest.json  MIGRATION.handoff.json
```

Everything new is std-only Zig inside `src/cli/rails/` (the module-root rule
from `CLAUDE.md` still applies: `rails.zig` is the `test-rails` root and cannot
import outside its directory) plus three stdlib-only Ruby files beside
`analyze.rb`. `migrate.zig`'s Rails branch grows one call between the manifest
write (`:965`) and its early return (`:1016`).

### Sidecar extension

`analyze.rb` gains ops, same NDJSON protocol, same 60 s timeout, same
degrade-and-report failure path:

| op          | input                              | output                                                                 |
| ----------- | ---------------------------------- | ---------------------------------------------------------------------- |
| `routes`    | unchanged                          | `name` is now filled for `resources`/`resource`/`namespace`/`scope`/`as:`/`root`; `nil` only when Rails itself would not name the route |
| `controllers` | unchanged                        | adds `layout: {value, line}` for a literal `layout "x"` / `layout :sym` / `layout false`; a dynamic or conditional layout reports `layout: {dynamic: true, line}` |
| `templates` | `{paths: [...]}`                   | per path: an ordered `nodes[]` — `{text}` runs and `{code, kind, line, col, …}` fragments (kinds below) — or `{error, line}` |
| `templates` (i18n) | `locale` is read from `config/application.rb`'s literal `config.i18n.default_locale`, else `en` | each `i18n` node carries `{key, value}` or `{key, missing: true}`, resolved from `config/locales/**/*.yml` with `yaml` (Psych, a default gem shipped with Ruby — no bundler). Folded into `templates` rather than a separate op because `sidecar_client.queryOnce` closes stdin after one request; a separate op would be a second Ruby spawn plus a key round-trip |

Route naming follows Rails' rules exactly for the DSL subset #166 already
parses with `certain` confidence: `resources :posts` → `posts`, `post`,
`new_post`, `edit_post`; `member { post :publish }` → `publish_post`;
`namespace :admin` prefixes `admin_`; `as:` overrides; `root` → `root`. Names
are emitted only for `certain` routes; an `uncertain` route keeps `name: null`
so a helper that resolves to it becomes a finding, not a guess.

### Fragment vocabulary

`erb.rb` scans the template with Erubi's grammar (`<%`, `<%=`, `<%==`, `<%#`,
`<%-`, `-%>`, `<%%`); `templates.rb` parses each code fragment with Prism and
reduces it to one of these kinds. The set is closed; anything else is `unknown` and becomes
`RAILS_HELPER_UNKNOWN`. Only literal arguments are read — a `link_to` whose
second argument is a method call on a variable is `dynamic`, not resolved.

| kind                  | Ruby shape                                                       | conversion                                      |
| --------------------- | ---------------------------------------------------------------- | ----------------------------------------------- |
| `yield`               | `yield`                                                          | `<super>` inside the block element `id="main"`  |
| `yield_named`         | `yield :head`, `content_for?(:x)`                                | named `<super>` block `id="<name>"`             |
| `content_for`         | `content_for :x do … end`, `provide(:x, "literal")`              | child block `<… id="<name>">`                   |
| `render_partial`      | `render "x"`, `render partial: "x"` with no `locals:`/`collection:` | inline expansion of the converted partial    |
| `render_partial_locals` | same with `locals:` of literals only                           | inline expansion with literal substitution      |
| `render_dynamic`      | `render @x`, `collection:`, non-literal locals                   | finding `RAILS_PARTIAL_DYNAMIC`                 |
| `route_helper`        | `<name>_path`, `<name>_url`, no args or literal args             | the route's path, literals substituted          |
| `route_helper_dynamic`| args are not literals                                            | finding `RAILS_ROUTE_HELPER_DYNAMIC`            |
| `link_to`             | `link_to "text", <route_helper> [, html_opts literals]`          | `<a href="…">text</a>`                          |
| `asset`               | `image_tag`, `image_path`, `asset_path`, `stylesheet_link_tag`, `javascript_include_tag`, `favicon_link_tag` with a literal | `$site.asset('…').link()` when `assets[]` has it deterministic; else `RAILS_ASSET_TRANSFORM` |
| `importmap`           | `javascript_importmap_tags`, `turbo_include_tags`                | dropped; one finding `RAILS_JS_ENTRY` per app   |
| `csrf`                | `csrf_meta_tags`, `csp_meta_tag`                                 | dropped; noted in `MIGRATION.md` (ZigBase cookie/CSRF boundary owns this) |
| `i18n`                | `t("key")`, `t(".key")`, `I18n.t`                                | resolved literal; `RAILS_I18N_UNRESOLVED` if missing |
| `literal`             | string/number/`nil`/`true`/`false`                               | HTML-escaped text                               |
| `form`                | `form_with`/`form_for`/`form_tag` block and its `f.*` builder calls | form island scaffold (see Backend boundary)  |
| `form_field`          | `f.text_field :title`, `f.label`, `f.submit`, `f.check_box`, `f.select` with literal options, `f.text_area`, `f.email_field`, `f.password_field`, `f.hidden_field` | field descriptor inside the enclosing `form` |
| `errors`              | `@x.errors.full_messages`, `errors.any?`, `f.object.errors[:y]`   | validation-presentation region of the form island |
| `request_state`       | `current_user`, `session`, `flash`, `cookies`, `params` (non-route), `request.`, `signed_in?`, `policy(`, `can?`, `Current.` | finding `RAILS_REQUEST_TIME_STATE`             |
| `ivar`                | `@anything` outside the shapes above                             | finding `RAILS_REQUEST_TIME_STATE`              |
| `control`             | `if`/`unless`/`case`/`each` whose condition classifies as `literal`, `local` or `unknown` (a request-state/ivar/errors condition takes that kind instead) | finding `RAILS_TEMPLATE_CONTROL_FLOW`           |
| `turbo_frame`         | `turbo_frame_tag`                                                | see Interactivity                               |
| `turbo_stream`        | `turbo_stream_from`, `turbo_stream.*`                            | finding `RAILS_TURBO_STREAM`                    |
| `component_root`      | `react_component("Name", {…})`                                   | see Interactivity                               |
| `raw`                 | `<%== %>`, `raw(...)`, `.html_safe`                              | finding `RAILS_RAW_OUTPUT` — unescaped output is never passed through |
| `comment`             | `<%# %>`                                                         | dropped                                         |
| `unknown`             | everything else                                                  | finding `RAILS_HELPER_UNKNOWN`                  |

`<%= %>` output of anything other than `literal`, `route_helper`, `link_to`,
`asset`, `i18n`, `yield*`, `render_partial*` is a finding at that source
location; the converted template carries a stable placeholder comment
`<!-- rails:finding <id> -->` at the spot so the operator can see where the
gap is in the output as well as in the report.

### Conversion: what a route becomes

| classification            | artifact                                                                                       |
| ------------------------- | ---------------------------------------------------------------------------------------------- |
| `content`                 | `content/<url>/index.smd` + `layouts/<controller>/<action>.shtml` extending `layouts/templates/<layout>.shtml` |
| `island`                  | same, with Stimulus / React / Turbo-frame regions replaced by `<island>` elements and their scaffolds |
| `backend`                 | no page; a finding `RAILS_BACKEND_ENDPOINT` mapping it (or a `retain`/`blocked` decision)      |
| `redirect`                | a `redirects[]` entry in the handoff and a finding `RAILS_REDIRECT_HOST_CONFIG` (`warn`, acknowledgeable) — the host-config emitters own redirects, not the static tree |
| `unresolved`              | a finding per cause with choices `island` / `spa` / `backend` / `retain` / `blocked`; a page is emitted only once a choice is recorded |
| any, with a dynamic segment (`:id`) | finding `RAILS_ROUTE_DYNAMIC_SEGMENT`, choices `spa` / `retain` / `blocked`; `spa` scaffolds one `.spa.tsx` per first path segment with a route entry per decided route, a skeleton, and a `staticPaths` stub |

`classification` is discovery's verdict and stays untouched in the manifest;
the handoff `status` is derived from the *conversion outcome*, and where the
two disagree the conversion wins. The case that makes this matter: #166's
rule 5 classifies `pages#about` in the existing fixture `unresolved` because
its layout contains `csrf_meta_tags`, but that fragment has a defined
conversion (dropped), so the route converts and reports `migrated`. The
reverse also holds — a `content` route whose view turns out to contain an
`unknown` helper is `open`, not `migrated`, however static it looked to the
substring scan.

The view body goes into the `.shtml`, not the `.smd`, because SuperMD forbids
raw HTML. The `.smd` carries `.title` (from `content_for :title`, `provide`, a
`<title>`, or the first `<h1>`, in that order), `.description` from a
`<meta name="description">` if present, `.layout`, and
`.custom.rails = { .route = "GET /about", .controller, .action, .source }` so
`$page.custom` can be inspected from a layout and the provenance survives
edits. Rails URLs map to content paths: `/` → `content/index.smd`, `/about` →
`content/about.smd`, `/admin/users` → `content/admin/users.smd`. The static
tree serves `/about/`; whether `/about` is a redirect or a 200 is the host's
call, and that difference is a parity check, not something this converter can
hide.

Layouts: every `app/views/layouts/*.html.erb` a migrated route reaches becomes
`layouts/templates/<name>.shtml`; `yield` becomes `<super>` inside an element
with `id="main"`, named yields become `<super>` blocks under their own ids.
Partials are expanded inline at every render site (SuperHTML has no include;
`<extend>`/`<super>` is inheritance, not composition), which is why only
literal-local partials convert. Head-only Rails partials (`_head.html.erb`
rendered from a layout) expand into the `id="head"` block.

Canonical metadata, headings, links and public asset URLs are the things the
issue says to preserve; each is a `parity[]` entry (below), so preservation is
checked rather than asserted.

Everything written obeys the existing rules: `--target` must be missing or
empty (`migrate.zig:906-928`), writes go through `writeTargetFile`, the source
tree is never touched, output is byte-identical across runs, and
`MIGRATION.md`/`MIGRATION.manifest.json` keep their current shape (the manifest
gains fields; it does not change).

### Backend boundary

`--backend FILE` reads a ZigBase OpenAPI document: `paths` × verbs with
`operationId`, security, and `x-zigbase-*` extensions;
`x-zigbase-coverage.consumerRoutes` decides whether custom routes are even
described. Without `--backend`, every backend-bound item is a finding and the
target still emits its pages.

Each of these produces a `RAILS_BACKEND_ENDPOINT` finding whose `choices` are
the matching operations in the document (by verb and path shape, the standard
`/api/collections/<name>/records` CRUD for a `resources :<name>` route first),
plus `custom:<path>`, `retain`, `blocked`:

- every non-GET route (`classification: backend`);
- every `form` fragment's action;
- every `link_to`/`button_to` with `method:`/`data-turbo-method`.

A suggestion is evidence, not a decision: the finding is open until the
operator picks. The chosen operation is written into the generated form
island as a typed call through `lib/zb.ts`, a generated client factory:

```ts
import { ZigBase, CookieAuthStore } from "@zigbase/client";
export const zb = new ZigBase({ baseUrl: "", authStore: new CookieAuthStore() });
```

Sessions and authenticity tokens are replaced by that boundary: same-origin
cookies, `CookieAuthStore`, no CSRF meta tag. `csrf` fragments are dropped
with a note rather than a finding because there is nothing to decide.

**Auth journeys.** Devise routes are already `RAILS_ROUTE_GEM_GENERATED`
blockers; plain `sessions#new`/`registrations#new` forms are ordinary `form`
fragments whose fields are `email`/`password`(`_confirmation`). Either way the
operator answers one finding, `RAILS_AUTH_JOURNEY`, with the auth collection
name (`artifact` required, validated against the backend document). That
scaffolds `components/AuthForm.island.tsx` — `authWithPassword` for sign-in,
`collection(name).create` then `authWithPassword` for sign-up, `logout` — and
`components/AuthStatus.island.tsx` for `current_user`-only regions (the
blog example's shape). `current_user` in a template therefore has a concrete
`island` choice, not just a blocker.

**Enforcement stays server-side.** Generated islands hide or disable on client
auth state for convenience only; each carries a header comment saying so, the
doc says so, and the parity checklist contains a `submit_denied` entry per
mapped mutation that proves the backend refuses an unauthenticated call
regardless of what the island shows.

**Validation presentation.** A form with an `errors` fragment renders
`ClientResponseError.data` field errors in the position the ERB rendered
`full_messages`; the `validation_error` parity entry submits a required field
empty and expects the error region to be non-empty.

### Interactivity and assets

- **Turbo Drive** — ordinary navigation; nothing to emit. Documented as the
  mapping, with `data-turbo`/`data-turbo-action` attributes dropped.
- **Turbo Frames** — `turbo_frame_tag "x" do … end` and a literal
  `<turbo-frame id="x" src="…">`: finding `RAILS_TURBO_FRAME`, choices
  `island` (the frame body becomes an island that fetches `src` through
  `lib/zb.ts`), `inline` (a frame with no `src` is just markup), `blocked`.
- **Turbo Streams** — `RAILS_TURBO_STREAM`, choices `island-realtime`
  (`@zigbase/client` realtime subscription scaffold), `blocked`.
- **Stimulus** — each `data-controller="a b"` element becomes
  `<island src="components/stimulus/a.island.tsx" client:load>` wrapping the
  element's markup as the default slot; the scaffold file quotes the original
  controller's path, its `static targets`/`values` and every `data-action`
  found on the element, and exports a component that renders its slot
  unchanged. The Stimulus source is not transpiled — its API is not Preact's —
  so the finding `RAILS_STIMULUS_CONTROLLER` (choices `island`, `drop`,
  `blocked`) is what marks it migrated, and the scaffold is a starting point
  with the facts gathered, not a claim of behavioral parity.
- **React roots** — `react_component("Name", {literal props})` /
  `data-react-class` becomes `<island src="components/Name.island.tsx"
  :props='{…}'>` with a scaffold that imports the existing component through
  the compat bridge; `z-runtime.config.json` is emitted with the resolve map
  and an `islandImports` allowlist entry per root. Non-literal props →
  `RAILS_COMPONENT_PROPS_DYNAMIC`. Vue → `RAILS_COMPONENT_VUE_UNSUPPORTED`.
- **JS entry** — `app/javascript/application.js` side effects are not
  inspected; one `RAILS_JS_ENTRY` finding per app names the file for review.
- **Assets** — `public/**` copies to `assets/**` (URL preserved). Pipeline
  assets with `deterministic: true` copy to `assets/<path relative to
  app/assets>` and template references become `$site.asset(...)`; the handoff
  records `{source, rails_url, target_url}`. `deterministic: false` (ERB,
  SCSS, any preprocessor, a missing manifest) → `RAILS_ASSET_TRANSFORM` with
  the preprocessor named; the reference stays as a finding placeholder.

### Findings, decisions, handoff

**Findings** are the manifest's new top-level `findings[]` (additive to `/1`,
allowed because it has not shipped): `{id, code, severity, source{file,line},
route_id, message, choices[], requires_artifact}`. `id` is
`finding_id(code, route_id | template path, discriminator)` with `rails2zb`'s
reversible `%`/`.` escaping; `message` is not identity. Sorted by
`(code, file, line, id)`. The existing `blockers[]` is untouched: a blocker is
a fact about discovery, a finding is a question for the operator.

**Decisions** come from `--decisions FILE` (default `DIR/MIGRATION.decisions.json`
if present), schema `zigapagos.rails-decisions/1`:
`{schema, decisions: [{id, choice, rationale, artifact?}]}`. Unknown id,
choice not in the finding's `choices`, or a missing required `artifact` is
fatal with the offending entry named — a decision file that does not match the
findings is a user assertion error, not a degradation. A decision's `id` is
stable across runs by construction, so recording one against a finding that
later disappears (the template was fixed) is reported as `stale`, `warn`.

**Handoff** is `MIGRATION.handoff.json`, schema `zigapagos.rails-handoff/1`,
generated from Zig types with the same `@typeInfo` walker as the manifest
(`schema_gen.zig` grows a second entry point; `build/rails_schema.zig` gains
`contract/rails-handoff.v1.schema.json` under the same `rails-check` gate):

```jsonc
{
  "schema": "zigapagos.rails-handoff/1",
  "generator": { "tool": "zigapagos", "version": "0.4.0" },
  "backend": { "file": "openapi.json", "contract_version": "2026-06-27.1" } | null,
  "complete": false,
  "routes": [{
    "route_id": "GET /about",
    "status": "migrated" | "blocked" | "retained" | "backend" | "redirect" | "open",
    "artifacts": ["content/about.smd", "layouts/pages/about.shtml"],
    "endpoint": null | { "operation_id": "createPost", "verb": "POST", "path": "/api/collections/posts/records" },
    "decision": null | { "id": "...", "choice": "...", "rationale": "..." },
    "findings": ["..."]
  }],
  "assets": [{ "source": "app/assets/images/logo.png", "rails_url": "/assets/logo-abc.png", "target_url": "/images/logo.png" }],
  "redirects": [{ "from": "/posts/old", "to": "/posts" }],
  "parity": [{ "id": "navigate:GET /about", "kind": "navigate", "url": "/about",
               "expect": { "status": 200, "title": "About", "h1": "About us", "links": ["/", "/posts"] } }]
}
```

`complete` is true iff every route whose verb is GET or HEAD has `status ∈
{migrated, retained, redirect}` or `status = blocked` with a decision
(`retained` and `blocked` both require a decision with a rationale). Exit code:
0 when complete, a new non-zero value when not, distinct from the existing
integrity failure so an agent loop can tell "decide more" from "discovery
broke". `--strict` continues to fail on any blocker.

Parity kinds: `navigate` (status, `<title>`, first `<h1>`, links present),
`asset` (URL returns 200 and the content type), `signup`, `signin`,
`submit_allowed` (authenticated, expects 2xx), `submit_denied`
(unauthenticated, expects 401/403), `validation_error`. Every entry is derived
from a migrated artifact or a decided endpoint, so the list is deterministic.

The target gets `test/parity.ts`, a fixed template (one file, no generation
logic) that reads the handoff and replays every entry with `fetch` against
`ZIGAPAGOS_ORIGIN` and, when `RAILS_ORIGIN` is set, against the running Rails
app too, diffing the two. It runs under the existing harness:
`zigapagos e2e --site=dist --zigbase=<app binary> -- bun test/parity.ts`.
The browser journey (cookies, rendered validation) reuses the Playwright
pattern `init_from_astro` already emits (`test/hydrate_playwright.py`) with a
`test/journey_playwright.py` that walks `signup → signin → submit_allowed →
validation_error`.

### Blocker and finding codes

Emitted for the first time (all were declared reserved by #166 or are new):
`RAILS_REQUEST_TIME_STATE`, `RAILS_HELPER_UNKNOWN`, `RAILS_ASSET_TRANSFORM`,
`RAILS_NO_TEMPLATE` (a `content`/`island` route whose view vanished between
discovery and conversion), `RAILS_PARTIAL_DYNAMIC`,
`RAILS_ROUTE_HELPER_DYNAMIC`, `RAILS_ROUTE_HELPER_UNKNOWN` (a helper whose
route is `uncertain` or unnamed), `RAILS_I18N_UNRESOLVED`,
`RAILS_TEMPLATE_CONTROL_FLOW`, `RAILS_JS_ENTRY`, `RAILS_BACKEND_ENDPOINT`,
`RAILS_AUTH_JOURNEY`, `RAILS_REDIRECT_HOST_CONFIG`,
`RAILS_ROUTE_DYNAMIC_SEGMENT`, `RAILS_TURBO_FRAME`, `RAILS_TURBO_STREAM`,
`RAILS_STIMULUS_CONTROLLER`, `RAILS_COMPONENT_PROPS_DYNAMIC`,
`RAILS_COMPONENT_VUE_UNSUPPORTED`, `RAILS_DECISION_STALE`,
`RAILS_LAYOUT_DYNAMIC` (a controller `layout` that is a method or conditional),
`RAILS_RAW_OUTPUT`,
`RAILS_TEMPLATE_PARSE_ERROR` (ERB scans but a fragment is not valid Ruby;
distinct from `RAILS_TEMPLATE_UNREADABLE`, which is a read failure),
`RAILS_TEMPLATE_UNSCANNED` (the fragment analysis refused the view outright --
it resolved outside the app root, or could not be read at the moment the
analysis ran, after the template-graph scan had already read it successfully;
the one finding with no source LINE, since the file was never parsed),
`RAILS_I18N_LOCALE_UNREADABLE` (a `config/locales/*` file that failed to load,
which would otherwise turn every `t()` key in the app into a false
`RAILS_I18N_UNRESOLVED` -- a blocker, not a finding: nothing is decided about
it, the locale file is simply broken).
Additive-only, stable, every one with a source location except
`RAILS_TEMPLATE_UNSCANNED` as noted.

Haml/Slim stay `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` from #166; such a route can
only reach `blocked` or `retained`, never `migrated`, and the fixture pins it.

## Failure behavior

| Failure                                         | Behavior                                                                 |
| ----------------------------------------------- | ------------------------------------------------------------------------ |
| Ruby absent / sidecar failed                    | discovery artifacts as today; no conversion; every convertible route `open` with the existing Ruby blocker; `complete: false` |
| a template fails to parse in `templates`        | that template's routes `open` with `RAILS_TEMPLATE_PARSE_ERROR` at the line; everything else converts |
| `--backend` unreadable / not OpenAPI 3          | fatal (user assertion)                                                    |
| decisions file malformed / unknown id / bad choice | fatal, entry named                                                    |
| conversion cannot write (target vanished, EACCES) | fatal; partial target is the existing `--target` contract (empty-or-missing at start) |
| a converted `.shtml` would not validate         | not possible by construction: the emitter only produces the `<extend>`/`<super>`/`<ctx>`/`$site.asset` subset, and the fixture target is built with `zigapagos release` + `doctor` in CI to prove it |

## Testing

- **Unit (`test-rails`)** — `fragments.zig` node-stream decoding (unknown
  kind degrades to `unknown`, not a drop); `convert.zig` on inline node
  streams (each vocabulary row has a converted-bytes case and a
  finding-emitted case); `findings.zig` id round-trip; `decisions.zig`
  validation errors; `handoff.zig` completion predicate; `backend.zig` on the
  in-repo `contract/zigbase.openapi.json`.
- **Ruby (`runtime/sidecar/rails/test/`)** — `erb_test.rb` for every tag form,
  `<%==`, trim modes and an unterminated tag, with expectations generated by
  real Erubi as the documented developer step (the same oracle pattern as the
  route expectations); `templates_test.rb` per fragment kind including the
  negative "this is `dynamic`, not resolved" cases;
  `routes_test.rb` naming against the checked-in ActionDispatch expectations
  (the oracle already exists — it gains a `name` column, regenerated with
  ruby + actionpack as the documented developer step); `i18n_test.rb`.
- **Fixture** — `tests/migrate/rails-presentation/`: `application` layout
  with `yield`, `content_for :title`, `_nav` partial using route helpers and
  `image_tag`; `pages#about` (content); `posts#index` reading `@posts`
  (request-time → decided `spa`); `posts#show` (`:id` → `spa`); `sessions`
  and `registrations` forms with `errors.full_messages`; a Stimulus
  controller; a Turbo frame; a React root; a Vue root; a `t()` key; a Haml
  view; a `public/` file; a Propshaft manifest with one ERB stylesheet; a
  `backend/openapi.json` in ZigBase shape with a `users` auth collection and
  a `posts` collection; a `MIGRATION.decisions.json` that drives to
  `complete: true`. Expected `MIGRATION.handoff.json` is checked in and diffed
  byte-for-byte.
- **Shell e2e** — `tests/migrate/rails-presentation.sh`: first run exits
  incomplete with the exact expected findings; second run with decisions is
  complete; `zigapagos release` on the target succeeds and `doctor` is clean;
  determinism (two runs identical), source untouched, no `.new` files; Haml
  route cannot reach `migrated` even with a `migrated`-looking decision (the
  choice is not offered); Vue root is a blocker; `--backend` absent →
  endpoint findings with no choices beyond `retain`/`blocked`.
  `tests/migrate/rails.sh:458`'s exact two-file listing is replaced by the
  exact *new* listing for the old fixture (`pages#about` now converts; the
  `posts` routes stay `open`), so the tripwire keeps its shape — an exact
  directory listing — and its intent, "nothing is written that the test did
  not name", moves from "no output" to "only proven output".
- **Parity e2e** — `tests/migrate/rails-presentation-parity.sh`: builds the
  fixture target, boots the stock ZigBase with a `schema apply` of the
  fixture's collections, runs `test/parity.ts` under `zigapagos e2e`. Skips
  loudly without `bun`, as `tests/dev/*` do.
- **Gates** — `zig build rails-check` (both schemas), `test-rails`, the Ruby
  suites, `tests/skills/sync.sh`, `zig fmt --check`. Every regression test
  verified to fail without its fix.

## Documentation

`docs/migration/rails-to-zigapagos.md` gains the conversion sections and the
**supported Rails frontend matrix** (the fragment table above, the
classification→artifact table, and the Turbo/Stimulus/React/Vue mapping, each
row marked converted / decided / blocked). `skills/zigapagos-rails-migration/`
gets the byte-mirrored copy, `SKILL.md` steps 5-8 (run with `--target`, answer
findings, re-run to complete, replay parity, hand off to
`zigbase-zigapagos-fullstack`), and `tests/skills/sync.sh` keeps its single
row. `src/cli/init/AGENTS.md` is embedded in the target so an agent landing in
the generated tree has the fix loop.

## Staging

Each stage ships on its own, green, with its docs and skill mirror.

1. **Template front end.** Sidecar `erb.rb` + `templates`/`i18n` ops, route
   names, controller `layout`, `findings[]` in the manifest (schema regen),
   `RAILS_HELPER_UNKNOWN`/`RAILS_REQUEST_TIME_STATE`/`RAILS_I18N_UNRESOLVED`/
   `RAILS_LAYOUT_DYNAMIC` emitted. No target output yet: the deliverable is a
   manifest that says exactly which fragments a converter would refuse.
2. **Converter and scaffold.** `fragments.zig`, `convert.zig`, `scaffold.zig`, `decisions.zig`,
   `handoff.zig` + schema + gate, completion exit code, `content`/`island`
   pages, layouts, partial inlining, assets, `zigapagos.ziggy`/`build.sh`,
   dynamic-segment → `spa` decision. The fixture app and its first e2e.
   Stimulus/Turbo/React regions are emitted as their original markup with
   their finding open; the `island` choice arrives in Stage 4.
3. **Backend boundary.** `--backend`, `backend.zig`, endpoint findings, form
   islands, `lib/zb.ts`, auth journey scaffolds, validation presentation.
4. **Interactivity.** Turbo frame/stream, Stimulus, React root islands,
   `z-runtime.config.json`, Vue blocker, `RAILS_JS_ENTRY`.
5. **Parity and handoff.** `parity[]`, `test/parity.ts`,
   `journey_playwright.py`, the parity e2e against real ZigBase, the support
   matrix doc, skill steps 5-8.

## Out of scope

Per the issue's non-goals: no Rails rendering inside Zigapagos, no
ActiveRecord/controller/job/mailer conversion (that is `rails2zb`), no
automatic conversion of arbitrary Ruby or gem-provided helpers. Also out:
transpiling Stimulus controllers to Preact, reproducing pipeline digests,
Vue, `actiondispatch`/`routes_import` route modes (still #166 follow-ups), and
non-default i18n locales (the default locale converts; others are a finding).

## Open decisions

- **Exit code value** for `complete: false` — a new number in the existing
  table, chosen in Stage 2 when the table is edited.
- **Where `lib/zb.ts` gets `@zigbase/client`** — the generated `package.json`
  pins it; the version is whatever the pairing doc pins at the time and is a
  single constant in `scaffold.zig`.
- **Inline partial expansion vs. one `.shtml` per partial** — inline is
  chosen because SuperHTML has no include; if a future SuperHTML sync adds
  one, the converter's partial step is the only place that changes.
