# Rails source discovery and target assembly

Design for [#166](https://github.com/valthon/zigapagos/issues/166). Scope is
**discovery and classification only**: this work converts nothing. The
presentation-semantics migration ([#167](https://github.com/valthon/zigapagos/issues/167))
consumes the manifest defined here and is specced separately, because its shape
depends on what discovery proves is findable.

## Why Rails is not a ninth SSG adapter

`zigapagos migrate` today handles Astro, Next.js, Gatsby, Nuxt/Vue, Hugo,
Jekyll, Eleventy and Hexo. All eight share two properties that Rails breaks:

1. **They are build-time static.** The flat `Entry{path, kind, role}` model in
   `src/cli/migrate.zig` has no vocabulary for *backend responsibility*,
   *redirect*, or *unresolved request-time behavior* — the exact classifications
   #166 requires. Rails is the first source whose entire job is request-time.
2. **Their routes are files.** A page's URL is its path on disk. In Rails the
   route table is a Ruby DSL in `config/routes.rb`, and recovering it is a
   program-analysis problem rather than a directory walk.

Grafting Rails into the shared `Source` enum would degrade the eight working
adapters. Rails gets its own package instead.

## Evidence: the routing spike

Before committing to an approach we measured how much of `config/routes.rb` is
statically recoverable. Corpus: 13 real `routes.rb` files from production open
source Rails apps; 7 usable as ground truth (**3,452 routes**), the rest
discarded because the oracle's constant-stubbing degraded their expansion.
Ground truth came from expanding each file through a genuine
`ActionDispatch::Routing::RouteSet` (actionpack 8.1.3.1), not by hand.

| Approach                       | Recall | Precision |
| ------------------------------ | ------ | --------- |
| Lexical / regex (no dependency)| 80.1%  | **54.1%** |
| Prism AST, all routes          | 93.6%  | 75.5%     |
| Prism AST, **confident subset**| 91.6%  | **98.2%** |

Per-file confident precision was uniform rather than an average hiding an
outlier: canvas-lms 98.9%, redmine 99.1%, lobsters 98.7%, openproject 96.0%,
diaspora / huginn / zammad 100%.

Three conclusions drive this design:

- **A static parser can know when it doesn't know.** Flagging 28.1% of emitted
  routes as uncertain is what turns a 75.5%-precision guess into a
  98.2%-precision assertion plus an explicit blocker list. Confidence is
  therefore a *required* field, not metadata.
- **The lexical tier is not viable.** At 54.1% precision every other route is
  wrong — worse than useless for a migration.
- **The residual is small and enumerable**: dynamic paths (159), unknown blocks
  (58), external `draw` files (30), conditionals (14), engine mounts (14),
  custom routers (5), `devise_for` (2). Each becomes a coded blocker.

A cautionary note for implementation: the spike's *first* measurement read
51% / 39% and would have argued for the opposite design. The gap was harness
bugs, not Rails dynamism — the oracle folds `via: [:get, :post]` into one
`GET|POST` route, `(.:format)` was stripped on one side only, and the parent
`:<singular>_id` prefix that Rails applies to bare routes inside a `resources`
block was computed and never applied. Measuring parser quality is itself easy to
get wrong, which is why the oracle becomes a checked-in test fixture rather than
a one-off script.

## Architecture

A two-process split drawn at the **Ruby-semantics boundary**:

```
                 zigapagos migrate <rails-app> [--target DIR]
                                  |
        +-------------------------+--------------------------+
        |  Zig: src/cli/rails/                                |
        |    detect.zig        Gemfile, config/application.rb |
        |    inventory.zig     views/layouts/partials/mailers |
        |    integrations.zig  Propshaft|Sprockets|jsbundling |
        |                      Turbo|Stimulus|React|Vue       |
        |    classify.zig      6-way route classification     |
        |    manifest.zig      versioned JSON contract        |
        |    report.zig        MIGRATION.md                   |
        +-----------+-----------------------------------------+
                    | NDJSON over stdin/stdout, one request per line
                    | (same protocol shape as runtime/sidecar/render.ts)
        +-----------+-----------------------------------------+
        |  Ruby sidecar: routes.rb + ERB semantics            |
        |    static mode : Prism (stdlib, no gems)   91.6%    |
        |    exact mode  : real ActionDispatch expansion      |
        +-----------------------------------------------------+
```

Everything on the Zig side is filesystem convention — walking `app/views`,
reading `Gemfile`, matching `package.json` dependencies — and needs no Ruby.
Only genuinely Ruby-semantic work crosses the wire.

That boundary buys the property which makes the dependency acceptable:
**without Ruby you still get the complete file inventory, integration detection
and asset mapping; you lose only the route graph**, and the loss is reported as
a blocker rather than a silent gap.

### Alternatives rejected

- **Vendored libprism, all analysis in Zig.** libprism is MIT, C99 and
  dependency-free, so it would integrate like `wuffs`. Rejected because it
  requires porting Rails DSL semantics *and* the inflector rule table to Zig,
  hand-written Prism AST bindings, a separate ERB parser and five more platform
  build surfaces — and it can never reach the exactness the app's own gems
  provide, permanently capping recovery at 91.6%.
- **Consume `rails routes` JSON only.** Zero dependencies and exact, but
  requires an app that boots (many migrations start on apps that do not),
  cannot inventory views or ERB, and fails the issue's explicit "needs a useful
  static fallback" requirement. Retained as an *optional input*, not the plan.

### Sidecar placement

`runtime/sidecar/rails/analyze.rb`, located through the existing
`ZIGAPAGOS_RUNTIME_DIR` mechanism that the Bun sidecar already uses, so the
curl installer, the npm package and a plain checkout all work with no new
machinery. The wrinkle, recorded honestly: `runtime/` is conceptually the
*shipped* `@z/runtime`, and a migration analyzer is not part of what a built
site ships. A top-level `tools/` is cleaner conceptually but needs a new
locator and new release-job packaging. Reuse wins; revisit if `runtime/` starts
accumulating unrelated build-time tools.

## Route discovery modes

Every route records how it was learned. All three modes populate the same
schema.

| `origin`         | Trigger                  | Accuracy               | Requires        |
| ---------------- | ------------------------ | ---------------------- | --------------- |
| `static_ast`     | default                  | 91.6% recall / 98.2% p | Ruby only       |
| `actiondispatch` | app's bundle resolves    | ~100%                  | Ruby + app gems |
| `routes_import`  | `--rails-routes <file>`  | exact, user-supplied   | nothing         |

`static_ast` is the default because it is the only mode that works on an app
that does not boot.

## The manifest

The manifest is the deliverable; `MIGRATION.md` is a rendering of it. It is
written beside the report, so `--target DIR` produces both in `DIR`.

```jsonc
{
  "schema": "zigapagos.rails-presentation/1",
  "schema_version": 1,
  "generator": { "tool": "zigapagos", "version": "0.4.0" },
  "source": {
    "framework": "rails",
    "version": { "value": "7.1.3", "evidence": "Gemfile.lock:rails (7.1.3)" },
    "root_evidence": ["Gemfile", "config/application.rb", "app/views"]
  },
  "discovery": {
    "route_mode": "static_ast",
    "ruby": { "available": true, "version": "3.3.6" }
  },
  "routes": [{
    "id": "GET /articles/:id",
    "verb": "GET", "path": "/articles/:id",
    "controller": "articles", "action": "show", "name": "article",
    "source": { "file": "config/routes.rb", "line": 42 },
    "origin": "static_ast", "confidence": "certain",
    "classification": "content",
    "candidates": [{ "target": "content", "evidence": ["no request-time state in view"] }],
    "templates": ["app/views/articles/show.html.erb"],
    "layout": "app/views/layouts/application.html.erb"
  }],
  "templates": [{
    "path": "app/views/articles/show.html.erb", "engine": "erb", "kind": "view",
    "renders": ["app/views/articles/_article.html.erb"],
    "stimulus_controllers": ["reveal"], "component_roots": []
  }],
  "assets": [{
    "source": "app/assets/images/logo.png", "public_url": "/assets/logo.png",
    "pipeline": "propshaft", "deterministic": true
  }],
  "integrations": [{
    "name": "turbo", "version": "8.0.4",
    "evidence": "package.json:@hotwired/turbo-rails"
  }],
  "blockers": [{
    "code": "RAILS_DYNAMIC_ROUTE_PATH", "severity": "warn",
    "source": { "file": "config/routes.rb", "line": 118 },
    "message": "route path is built from an interpolated expression",
    "route_id": null
  }]
}
```

`origin` and `confidence` carry the spike's central lesson and are mandatory on
every route. Without them the same parser output is a 75.5%-precision liar.

### `candidates`: a deliberate addition

The issue specifies six `classification` values, kept verbatim as an acceptance
criterion. But the target end state for the driving migration is **undecided**,
and a single verdict per route would bake in a choice that discovery has not
earned. Each route therefore also carries `candidates[]` — the viable zigapagos
shapes with the evidence for each. `classification` states the Rails-side fact;
`candidates` serves the decision that follows.

## Classification

First match wins. Anything unmatched falls to `unresolved` rather than a guess.

| # | Condition                                                                              | Result       |
| - | -------------------------------------------------------------------------------------- | ------------ |
| 1 | verb not in {GET, HEAD}                                                                 | `backend`    |
| 2 | no view template; action renders JSON or is absent                                      | `backend`    |
| 3 | controller action body is only `redirect_to`                                            | `redirect`   |
| 4 | view engine is Haml or Slim                                                             | `unresolved` |
| 5 | view references request-time state (`current_user`, `session`, `flash`, `cookies`, non-route `params`) | `unresolved` |
| 6 | view has Stimulus controllers or React/Vue roots                                        | `island`     |
| 7 | view is static-safe                                                                     | `content`    |
| — | anything else                                                                           | `unresolved` |

Rules 4 and 5 are the load-bearing ones. Rule 4 keeps unsupported template
languages from ever being reported as converted. Rule 5 is what stops the
adapter claiming false parity on a page that merely *looks* static; resolving
those routes is #167's job.

`spa` is assigned only on positive evidence — a component root that owns
routing — never as a default. Statically inferring "this should be an SPA" is
precisely the false confidence the issue warns against.

## Blocker codes

Stable and additive-only within schema v1. Every blocker carries a source
location; that is what makes it reviewable instead of a summary count.

`RAILS_DYNAMIC_ROUTE_PATH`, `RAILS_ROUTE_LOOP`, `RAILS_ROUTE_CONDITIONAL`,
`RAILS_ENGINE_MOUNT`, `RAILS_CUSTOM_ROUTER`, `RAILS_EXTERNAL_ROUTE_FILE`,
`RAILS_GEM_GENERATED_ROUTES`, `RAILS_TEMPLATE_ENGINE_UNSUPPORTED`,
`RAILS_REQUEST_TIME_STATE`, `RAILS_HELPER_UNKNOWN`, `RAILS_ASSET_TRANSFORM`,
`RAILS_NO_TEMPLATE`, `RAILS_RUBY_UNAVAILABLE`, `RAILS_SIDECAR_FAILED`,
`RAILS_ROUTES_PARSE_ERROR`.

## Determinism

Byte-identical output for identical input, and it is tested:

- routes sorted by `(path, verb)`; templates and assets by path; blockers by
  `(code, file, line)`
- all paths relative to the source root, forward slashes
- **no wall-clock timestamp in the artifact** — generator version only; any
  stamping is behind an opt-in flag

## Failure behavior

Discovery failures degrade and report. User-assertion failures are fatal.

| Failure                                | Behavior                                                        |
| -------------------------------------- | --------------------------------------------------------------- |
| Ruby absent                            | inventory-only, `route_mode: "none"`, `RAILS_RUBY_UNAVAILABLE`, exit 0 |
| Sidecar crash or timeout (60s)         | inventory-only, `RAILS_SIDECAR_FAILED` + stderr excerpt, exit 0 |
| `routes.rb` syntax error               | `RAILS_ROUTES_PARSE_ERROR` with line; inventory still emitted   |
| `--from rails` on a non-Rails tree     | fatal                                                            |
| Ambiguous auto-detection               | fatal, "pass `--from`" (existing pattern)                        |
| `--target` nested or non-empty         | fatal (existing rule)                                            |

A half-discovered app is still a useful inventory, so partial discovery never
discards the parts that worked. Inherited invariants hold unchanged: the source
is read-only and outputs never clobber (`.new`, `.new.2`, …).

`--strict` exits non-zero when any blocker exists, which is what makes this
usable in an agent loop or a CI gate.

## Testing

Four synthetic fixture apps, since the driving application cannot ship:

- `erb-basic` — layouts, partials, static pages
- `hotwire` — Turbo, Stimulus, a React root
- `legacy-assets` — Sprockets, digests, preprocessors
- `blocked` — Haml, Slim, dynamic routes, an engine mount, a custom router: the
  whole unsupported matrix in one app, so "cannot be silently marked complete"
  is a test rather than a promise

**The spike's oracle becomes a fixture generator, not a runtime dependency.**
Expected route JSON is produced by real `ActionDispatch` expansion and checked
in; CI asserts against the checked-in expectations, so the test run needs no
gems while ground truth stays pinned to what Rails actually does. Regeneration
is a documented developer step requiring ruby + actionpack.

Also required:

- determinism test — run twice, diff byte-for-byte
- read-only test — hash the source tree before and after
- contract test — validate every fixture manifest against
  `contract/rails-presentation.v1.schema.json`
- drift gate mirroring `api-check`: regenerate fixture manifests,
  `git diff --exit-code`
- a new `test-rails` step in `build/tests.zig`, **also added explicitly to
  `ci.yml`**, whose list is enumerated by hand
- shell e2e at `tests/migrate/rails-*.sh` (picked up by the existing glob)

Per repo convention every regression test is verified to fail without its fix.

**CI risk.** The static path needs Prism, which is Ruby stdlib only from 3.3+,
and runners do not reliably ship that. Ruby gets pinned in `mise.toml` — the
repo's single source of truth for toolchains, already consumed by
`jdx/mise-action` in `ci.yml` — rather than by adding a separate setup action.

## Staging

Each stage is independently shippable and testable.

1. Detection + inventory + integrations + `MIGRATION.md` — pure Zig, no Ruby.
   Answers "what is in this app" on its own.
2. Ruby sidecar + route discovery (`static_ast`) + `origin` / `confidence`.
3. Classifier + evidence + blockers.
4. Manifest + JSON Schema + contract tests + drift gate.
5. `--target` assembly + `docs/migration/rails-to-zigapagos.md` + the `skills/`
   reference mirror + `tests/skills/sync.sh` update.

Stage 5 carries a known trap: `docs/migration/` and `skills/*/references/` are
byte-mirrored under a sync gate whose file list is hardcoded, so the doc, its
skill copy and the gate's list must land together.

## Out of scope

All of these belong to #167: ERB-to-TSX conversion, backend endpoint mapping,
ZigBase auth and CSRF replacement, Turbo/Stimulus behavioral migration, and
browser parity. #166 discovers and classifies; it converts nothing.

Also out of scope permanently, per the issue's non-goals: converting
ActiveRecord, controllers, jobs, mailers or database data, and reproducing
Rails request-time rendering inside zigapagos.

## Open decisions

- **Sidecar location** — `runtime/sidecar/rails/` for locator reuse versus a
  top-level `tools/` for conceptual cleanliness. Defaulting to reuse.
- **`candidates[]`** — an addition beyond the issue's literal schema. Drop it if
  strict conformance is preferred.
- **Inflector** — Rails' pluralization rules are needed to derive `:<singular>_id`
  nesting for routes declared inside a `resources` block. Exact mode gets this
  free from ActiveSupport, but static mode is gem-free by definition, so the
  sidecar must vendor a rule table in plain Ruby. The spike borrowed
  `ActiveSupport#singularize` and therefore did **not** measure the cost of the
  irregular/uncountable cases; scope is confirmed at stage 2.
