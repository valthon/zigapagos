# Rails Presentation Stage 2 — Converter, Scaffold, Decisions, Handoff

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `zigapagos migrate <app> --from rails --target DIR` converts every provable `content`/`island` route into a real Zigapagos page (SuperHTML layout + `.smd`), copies deterministic assets, reads an operator's `MIGRATION.decisions.json`, writes a versioned `MIGRATION.handoff.json` with a computed `complete` verdict, and exits non-zero while any user-facing route is neither migrated nor acknowledged.

**Architecture:** Four new std-only modules in `src/cli/rails/` — `resolve.zig` (pure lookups: route helper → URL, asset helper → target path, route → content path/layout names), `convert.zig` (a `fragments.Template` node stream → SuperHTML bytes, or findings), `decisions.zig` (read/validate the operator's answers), `scaffold.zig` (write the target tree, returning per-route outcomes), `handoff.zig` (status/completion + JSON + a second generated schema) — wired into `migrate.zig`'s Rails branch between the manifest write and its early return, replacing the "converts nothing" narrowing. The `/1` manifest is untouched; the handoff is a separate versioned artifact.

**Tech Stack:** Zig 0.16.0 (std-only inside `src/cli/rails/`), bash e2e under `tests/migrate/`, `jq`, Ruby 3.4 (unchanged sidecar), `bun` only for the optional SPA scaffold build in CI.

**Spec:** `docs/superpowers/specs/2026-08-29-rails-presentation-migration-design.md` — sections "Conversion: what a route becomes", "Findings, decisions, handoff", "Failure behavior", "Staging" item 2. Stage 1 (merged, PR #175) supplies `Discovery.fragments`/`.findings`/`.routes[].name`/`.route_templates[].layout`.

## Global Constraints

- `src/cli/rails/` is std-only; no `@import` escapes it. New modules return errors (never call `fatal.*`); `migrate.zig` turns them into `fatal.file`/`fatal.dir`. `rails.zig` imports each new file (`pub const x = @import("x.zig");`) so `refAllDecls` reaches its tests.
- Every allocator-taking function states its NO_SLOP §2.2a contract accurately.
- Output is byte-identical for identical input: every emitted list sorted by a total order; no absolute paths in any artifact; no timestamps.
- The source tree is never written. Target writes use exclusive-create (`writeTargetFile`'s semantics: create parents, `.{ .exclusive = true }`); a Rails `--target DIR` may pre-exist ONLY if it contains nothing but `MIGRATION.decisions.json` (ruling: the decide→re-run loop needs the decisions file to survive; everything else must be absent, so the operator wipes the previous output).
- `classification` in the manifest is discovery's verdict and is never changed; the handoff `status` derives from the conversion outcome (spec: "where the two disagree the conversion wins").
- Stage 2 decision choices IMPLEMENTED: `retain`, `blocked` (acknowledge → status), `spa` (only offered on `RAILS_ROUTE_DYNAMIC_SEGMENT`; scaffolds a `.spa.tsx`). Choices `island`/`backend` are ACCEPTED and recorded but leave the route `open` with `note: "deferred to Stage 3/4"` — never silently `migrated`.
- Exit codes: 0 complete; 1 the existing integrity/`--strict` failure; **3** = handoff `complete: false` (new; `migrate()` returns `u8`, `main.zig` maps it).
- Stimulus/Turbo/React regions are emitted as their original markup with their finding left open (Stage 4 adds the `island` choice); form regions likewise (Stage 3).
- Regression tests must be shown to fail without the fix. Gates: `zig fmt --check`, `zig build check`, `zig build check -Dsingle-threaded`, `zig build rails-check` (now two schemas), `bash tests/contract/rails-drift.sh`, `ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime zig build test-rails`, every `ruby runtime/sidecar/rails/test/*.rb`, every `tests/migrate/rails*.sh`, `bash tests/skills/sync.sh`, `bash tests/branding.sh`, `bash tests/confidentiality.sh`, `bash scripts/check-allocator-contracts.sh`.
- Commit with explicit paths (`git commit -F <msgfile> -- <paths>`); messages explain the defect and the reasoning; trailers `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4`.
- Environment: zsh `noclobber` (`>|`), `cp`/`mv` aliased `-i` (`command cp -f`), `du` aliased (`\du`), the worktree guard rejects compound commands (one plain command per tool call, or a script under `/home/valthon/.claude/jobs/361916b6/tmp/`), never bare `git stash`.

---

### Task 1: `resolve.zig` — pure lookups

**Files:** Create `src/cli/rails/resolve.zig`; modify `src/cli/rails/rails.zig` (import line).

**Interfaces (produces):**
```zig
pub const RouteUrl = struct { url: []const u8 };              // owned
/// Route helper stem + literal args → URL. `posts` → "/posts"; `post` + ["1"] → "/posts/1"
/// (each literal fills the next `:param` segment, in order); `root` → "/". Only routes with
/// `certain == true` and a non-null `name` participate. Returns null when no route matches or
/// the arg count does not equal the param count. Contract 1 (the returned url is the only escape).
pub fn routeUrl(gpa, routes: []const routes.Route, stem: []const u8, args: []const []const u8) Allocator.Error!?[]const u8;
/// An asset helper's literal → the manifest asset it names. `image_tag "logo.png"` looks under
/// `app/assets/images/` then `public/`; `stylesheet_link_tag "application"` → `app/assets/stylesheets/application.css`
/// (adds the extension); `javascript_include_tag`/`favicon_link_tag`/`asset_path` likewise by kind.
/// Returns the matching `assets.Asset` (borrowed) or null. Contract 3.
pub fn assetFor(assets: []const assets.Asset, helper: []const u8, literal: []const u8) ?assets.Asset;
/// Where a source asset lands in the target: `app/assets/images/logo.png` → "images/logo.png";
/// `public/robots.txt` → "robots.txt". Contract 1.
pub fn assetTargetPath(gpa, source: []const u8) Allocator.Error![]const u8;
/// Content path for a static GET route: "/" → "content/index.smd"; "/about" → "content/about/index.smd";
/// "/admin/users" → "content/admin/users/index.smd". Null when the path has a `:param` or `*glob`
/// segment. Contract 1.
pub fn contentPath(gpa, route_path: []const u8) Allocator.Error!?[]const u8;
/// `app/views/layouts/marketing.html.erb` → "marketing" (the `layouts/templates/<name>.shtml` stem). Contract 3.
pub fn layoutStem(layout_path: []const u8) []const u8;
/// `app/views/pages/about.html.erb` → "pages/about" (the `layouts/<stem>.shtml` stem). Contract 3.
pub fn viewStem(view_path: []const u8) []const u8;
/// First path segment of a dynamic route: "/posts/:id" → "posts". Contract 3.
pub fn spaSegment(route_path: []const u8) []const u8;
```

- [ ] Tests (write first, RED): each function above with the examples in its doc plus: `routeUrl` with wrong arity → null; uncertain route ignored; `assetFor` with a `deterministic: false` asset still returns it (the caller decides); `contentPath("/posts/:id")` → null; `contentPath("/files/*path")` → null.
- [ ] Implement; `zig build test-rails`; fmt.
- [ ] Commit: `git commit -F <msg> -- src/cli/rails/resolve.zig src/cli/rails/rails.zig`.

---

### Task 2: `decisions.zig` — the operator's answers

**Files:** Create `src/cli/rails/decisions.zig`; modify `src/cli/rails/rails.zig` (import).

**Interfaces:**
```zig
pub const schema_id = "zigapagos.rails-decisions/1";
pub const Decision = struct { id: []const u8, choice: []const u8, rationale: []const u8, artifact: ?[]const u8 }; // all owned
pub const Parsed = struct { decisions: []Decision };  // contract 2, `free`
pub const Problem = struct { index: usize, id: ?[]const u8, message: []const u8 };  // owned message
pub const ParseError = error{ InvalidJson, WrongSchema, Invalid } || Allocator.Error;
/// Parses and validates against `findings`: unknown `id` → Invalid; `choice` not in that finding's
/// `choices` → Invalid; a finding with `requires_artifact` and no `artifact` → Invalid; duplicate `id` → Invalid;
/// empty `rationale` → Invalid. On `Invalid`, `problems` (caller-owned list) names every offending entry
/// (index + id + message) so the fatal message can list them all. Contract 2.
pub fn parse(gpa, bytes: []const u8, findings: []const findings.Finding, problems: *std.ArrayListUnmanaged(Problem)) ParseError!Parsed;
/// Stale check: a decision whose id matches no finding in THIS run is not an error (the template was
/// fixed) — `parse` reports it under `stale` instead, and the caller appends one `RAILS_DECISION_STALE`
/// blocker (integrity false, warn) per entry. 
pub const Parsed = struct { decisions: []Decision, stale: []Decision };
pub fn lookup(parsed: Parsed, finding_id: []const u8) ?Decision;   // contract 3
```
(Reconcile the two `Parsed` declarations above into one struct with both slices.)

- [ ] Tests (RED first): valid file round-trips; unknown id → Invalid with the id in `problems`; bad choice → Invalid naming the allowed choices; missing artifact when required; duplicate id; stale id → in `stale`, not an error; malformed JSON → InvalidJson; wrong `schema` → WrongSchema; FailingAllocator sweep.
- [ ] Implement with `std.json.parseFromSlice` into wire structs (`ignore_unknown_fields = false` — an unknown key is a typo the operator wants to hear about: report as Invalid).
- [ ] Commit.

---

### Task 3: `convert.zig` — node stream → SuperHTML

**Files:** Create `src/cli/rails/convert.zig`; modify `src/cli/rails/rails.zig` (import).

**Interfaces:**
```zig
pub const Context = struct {
    routes: []const routes.Route,
    assets: []const assets.Asset,
    /// Every template's node stream, by path (for partial inlining).
    fragments: []const fragments.Template,
    /// Findings already derived for this run (for placeholder ids); convert never appends to it.
    findings: []const findings.Finding,
    layout_stem: ?[]const u8,     // for a view: the layout it extends
};
pub const Kind = enum { layout, view, partial };
pub const Output = struct {
    bytes: []u8,                  // the .shtml, owned
    title: ?[]const u8,           // from content_for/provide :title (literal), else first <h1> text, else null
    description: ?[]const u8,     // <meta name="description" content="…"> literal, else null
    open_finding_ids: [][]const u8,  // ids of findings hit while converting THIS template graph (view + inlined partials); owned
    dropped: [][]const u8,        // human notes for MIGRATION.md ("csrf_meta_tags dropped", …)
};
/// Contract 2 (`freeOutput`). Never fails on content: every unconvertible node becomes a placeholder
/// comment `<!-- rails:finding <id> -->` and its id lands in `open_finding_ids`. Returns error only for
/// a template with `error_message`/`unreadable` set (caller treats the route as open with that finding).
pub fn convert(gpa, ctx: Context, tpl: fragments.Template, kind: Kind) (error{Unconvertible} || Allocator.Error)!Output;
```

Conversion rules (the spec's fragment table, made concrete):
- text runs → verbatim.
- `literal` output → HTML-escaped text; `i18n` resolved → escaped text; `i18n` missing → placeholder.
- `yield` (layout) → `<div id="main"><super></div>`. `yield_named title` inside `<title>` → the whole `<title>` becomes `<title :text="$page.title"></title>`; `yield_named head` → the enclosing `<head>` gets `id="head"` and a `<super>` at that point; any other named yield → `<div id="<name>"><super></div>`.
- view (`kind == .view`): output is `<extend template="<layout_stem>.shtml">\n<div id="main">\n…converted body…\n</div>\n` plus, when the view has `content_for :head do … end`, a `<head id="head">…</head>` block BEFORE the main block. `content_for :title`/`provide(:title, …)` with a single literal/i18n child → `Output.title` and nothing emitted; anything else → finding placeholder. A view with no layout (`layout_stem == null`) is emitted standalone (no `<extend>`).
- `render_partial` → inline the converted partial (recursive; `render_partial_locals` substitutes each `local` node whose name is a key in `attrs` with the literal value, HTML-escaped; a `local` with no substitution is a finding `RAILS_PARTIAL_DYNAMIC`? — no: it is the existing `unknown`-family finding on the partial; do not invent new codes). Cycle guard: a partial already on the inline stack → placeholder.
- `link_to` → `<a href="<url>"[ attrs]>text</a>` using `resolve.routeUrl`; a literal-URL `link_to` (name null, args[1] literal) → `<a href="<literal>">`; unresolvable → placeholder for its existing finding.
- `route_helper` output → the URL text.
- `asset` → `image_tag` → `<img src="$site.asset('<target>').link()"[ alt=… from attrs]>`; `stylesheet_link_tag` → `<link rel="stylesheet" href="$site.asset('<target>').link()">`; `image_path`/`asset_path`/`asset_url` → the `$site.asset(...).link()` expression text; `javascript_include_tag`/`favicon_link_tag` and `importmap` → dropped with an HTML comment `<!-- rails: <helper> dropped; @z/runtime replaces the Rails JS entry -->` and a `dropped` note. An asset that `resolve.assetFor` cannot find, or with `deterministic == false` → placeholder for a NEW finding? No — findings are derived in Stage 1's `derive`; Stage 2 may ADD derivation rows there: add `RAILS_ASSET_TRANSFORM` (warn; choices retain/blocked) for an `asset` node whose literal resolves to a `deterministic: false` asset or to nothing, so the placeholder has an id. (This is a `findings.zig` change in this task.)
- `csrf` → dropped with comment + `dropped` note.
- `control`/`request_state`/`ivar`/`unknown`/`raw`/`render_dynamic`/`route_helper_dynamic`/`form`/`form_field`/`errors`/`turbo_*`/`component_root` → `<!-- rails:finding <id> -->` then the node's converted children (for block kinds) then `<!-- rails:end -->`; `block_else` → `<!-- rails:else -->`; `block_end` closes. Markup inside is never lost. `form_field`/`errors` inside a `form` block need no separate placeholder if the enclosing `form` already has one (avoid comment spam: only the outermost finding node in a nesting emits the placeholder; inner ones are still listed in `open_finding_ids`).
- HTML escaping of literal text: `&`, `<`, `>`, `"`.
- Placeholder ids: look up the finding for `(path, line, col)` in `ctx.findings` (the `L<line>C<col>` loc); if none exists for a node kind that should have one, that is a bug — return `error.Unconvertible`? No: emit `<!-- rails:unmapped <kind> L<line>C<col> -->` and add a test proving Stage 1's derivation covers every kind this converter treats as a finding.

- [ ] Tests (RED first), golden bytes on hand-built `fragments.Node` streams: a layout with `<%= yield %>` + `csrf_meta_tags` + `stylesheet_link_tag "application"` + `<title><%= yield(:title) %></title>`; a view with `content_for :title`, `t()`, `link_to "Home", root_path`, `image_tag "logo.png"`, `render "shared/nav"` (inlined), an `unknown` helper (placeholder with the right id), a `control` block (placeholder + inner markup preserved); a partial with literal locals; a partial cycle; a view with no layout; `Output.title` precedence (content_for > first h1 > null); determinism (same input twice → identical bytes); FailingAllocator sweep.
- [ ] Implement; gates; commit (`convert.zig`, `findings.zig` for the new row + its tests, `rails.zig`).

---

### Task 4: `scaffold.zig` — write the target tree

**Files:** Create `src/cli/rails/scaffold.zig`; modify `rails.zig` (import).

**Interfaces:**
```zig
pub const RouteOutcome = struct {
    route_index: usize,            // index into Discovery.routes
    status: Status,                // migrated | open | blocked | retained | backend | redirect
    artifacts: [][]const u8,       // target-relative paths written for this route (owned)
    open_finding_ids: [][]const u8,
    decision_id: ?[]const u8,      // the decision that set a non-open status, if any
    note: ?[]const u8,             // e.g. "choice island deferred to Stage 4"
};
pub const Status = enum { migrated, open, blocked, retained, backend, redirect };
pub const AssetOutcome = struct { source: []const u8, rails_url: ?[]const u8, target_url: []const u8 };
pub const Result = struct { routes: []RouteOutcome, assets: []AssetOutcome, redirects: []Redirect, spa_files: [][]const u8 };
pub const Redirect = struct { from: []const u8, to: ?[]const u8 };
pub const WriteError = error{ TargetWrite } || Allocator.Error;
pub const Input = struct { discovery: *const rails.Discovery, decisions: decisions.Parsed, target: []const u8, app_name: []const u8, runtime_path: ?[]const u8 };
/// Contract 2 (`freeResult`). Writes files with exclusive-create; on `TargetWrite` the failing path is in `last_error_path`.
pub fn write(io, gpa, in: Input, last_error_path: *?[]const u8) WriteError!Result;
```
Target tree written:
- `zigapagos.ziggy` (`Site { .title = "<app_name>", .host_url = "https://example.com", … , .static_assets = ["**"] when any asset copied }` — reuse the exact format `migrate.zig`'s `emitTargetConfig` emits; duplicate the small emitter here since `migrate.zig` is outside the std-only dir, and say so).
- `build.sh`: `exec "${ZIGAPAGOS_BIN:-zigapagos}" release --force --output=zig-out/site --spa=spa/<seg>.spa.tsx … "$@"` (one `--spa=` per SPA file; `bun install` line only when SPAs exist).
- `.gitignore`, `AGENTS.md`, `CLAUDE.md` (bytes passed in `Input` by `migrate.zig` via `@embedFile`, since `scaffold.zig` cannot embed files outside its dir — add `agents_md: []const u8, claude_md: []const u8` to `Input`).
- Layouts: for every `Discovery.route_templates[].layout` reached by a converted route: `layouts/templates/<stem>.shtml` (converted once, deduped).
- Per route: `content` or `island` classification with a static path → convert view → `layouts/<viewStem>.shtml` + `content/<contentPath>` with frontmatter `.title`, `.description` (when present), `.layout = "<viewStem>.shtml"`, `.custom = { .rails = { .route = "<id>", .controller = …, .action = …, .source = "<view path>" } }` (Ziggy-escaped). Status `migrated` iff `open_finding_ids` is empty for the view and its layout and inlined partials; else `open` — unless a decision on ANY of those findings says `retain`/`blocked` → that status (with `decision_id`).
- `unresolved` classification (Stage 1 verdict) with a static path → converted exactly the same way (the fragment-level findings decide the status — spec ruling).
- Dynamic-segment routes (`contentPath == null`): finding `RAILS_ROUTE_DYNAMIC_SEGMENT` must exist — ADD its derivation row in `findings.zig` (route-scoped: `route_id` set, path `config/routes.rb`, line = route line, loc `L<line>`, choices `spa`/`retain`/`blocked`); status `open` until decided; `spa` → `spa/<segment>.spa.tsx` (one file per first segment, listing every decided route under it: `export const spa = { base: "/<segment>" }`, `routes = [{ path: "<rest>", component: Skeleton, skeleton: false, staticPaths: [] }]` with a `TODO` component per route) + `package.json`/`tsconfig.json` (the `migrate.zig` shapes) → status `migrated` with the spa file as artifact.
- `backend` classification → status `backend`, no artifact. `redirect` → status `redirect` + `Result.redirects` entry (target from the controller's `redirect_to` is not extracted in Stage 1 → `to: null`) and — ADD a `RAILS_REDIRECT_HOST_CONFIG` derivation row (route-scoped, warn, choices retain/blocked) so the route can be acknowledged.
- Assets: every `Discovery.assets[]` with `deterministic == true` (or `pipeline == null`, i.e. `public/`) copied to `assets/<assetTargetPath>`; `AssetOutcome{source, rails_url = public_url, target_url = "/" ++ target path}`.
- `MIGRATION.md` and `MIGRATION.manifest.json` are NOT written here (migrate.zig does).

- [ ] Tests (RED first) on a `std.testing.tmpDir` with a hand-built `Discovery` (use `manifest.zig`'s `emptyDiscovery` as the model; a helper in this file): a content route → exact file set + frontmatter bytes; an open route → files written and status `open`; a `blocked` decision → status; a dynamic route with `spa` decision → the `.spa.tsx` + `build.sh` line; `island` decision → `open` with note; an asset copy; exclusive-create failure → `TargetWrite` with path; determinism.
- [ ] Commit (`scaffold.zig`, `findings.zig` new rows + tests, `rails.zig`).

---

### Task 5: `handoff.zig` + second schema

**Files:** Create `src/cli/rails/handoff.zig`; modify `src/cli/rails/schema_gen.zig` (second document), `build/rails_schema.zig` (both files under `rails-schema`/`rails-check`), create `contract/rails-handoff.v1.schema.json` (generated), modify `tests/contract/rails-drift.sh` (cover the second schema in its case A), `rails.zig` (import).

**Interfaces / wire (field order is the contract):**
```jsonc
{ "schema": "zigapagos.rails-handoff/1", "schema_version": 1,
  "generator": {"tool","version"},
  "backend": null,                                   // Stage 3 fills it
  "complete": false,
  "routes": [{"route_id","status","artifacts":[…],"endpoint":null,"decision":{"id","choice","rationale"}|null,"findings":[…ids],"note":null|"…"}],
  "assets": [{"source","rails_url","target_url"}],
  "redirects": [{"from","to"}],
  "parity": [] }                                     // Stage 5 fills it
```
`complete` = every route with verb GET/HEAD has status ∈ {migrated, retained, redirect} or (blocked with a decision). `retained`/`blocked` require a decision (by construction). Sorted: routes by `(route path, verb)` via `report.routeLessThan`; assets by source; redirects by from. `pub fn build(gpa, BuildInput{generator_version, discovery, scaffold_result, decisions}) Allocator.Error![]u8` contract 1, trailing newline. `pub fn isComplete(...) bool` separately testable.

- [ ] Tests (RED first): golden bytes for a two-route handoff; `isComplete` truth table (migrated/retained/blocked-with-decision → true; open/blocked-without → false; a POST route never counts); determinism; `schema_gen` generates the second document and `rails-check` catches drift in either (extend `tests/contract/rails-drift.sh` case A to mutate `handoff.zig` too).
- [ ] Commit (all listed files + the generated schema).

---

### Task 6: Wire into `migrate.zig` + `main.zig` + `report.zig`

**Files:** Modify `src/cli/migrate.zig` (usage text, `--decisions FILE`, Rails branch, `migrate()` → `u8`), `src/main.zig` (map the `u8`), `src/cli/rails/report.zig` (`## Handoff` section: `complete`, counts per status, next step), `tests/migrate/rails.sh` (the `--target` exact listing on `rails-sample` becomes the new listing; the no-clobber and byte-identity assertions adapt: the manifest and report must still be byte-identical between `-o` and `--target` — but `--target` now ALSO scaffolds, so compare only the two discovery artifacts).

Behaviour:
- `--decisions FILE` (Rails only; default `<target>/MIGRATION.decisions.json` when it exists). Parse via `decisions.parse` AFTER discovery (needs findings); on `Invalid` print every problem and `fatal.usageError`-style exit 1.
- `--target DIR` for Rails: DIR may pre-exist containing only `MIGRATION.decisions.json`; otherwise the existing guards. Writes the two discovery artifacts, then `scaffold.write`, then `MIGRATION.handoff.json`, then `MIGRATION.md` (report now includes the Handoff section, so the report is written AFTER the scaffold; keep the manifest byte-identical to the `-o` run).
- Without `--target`: behaviour unchanged (report + manifest only; no scaffold; exit as today) — the handoff is only meaningful with a target.
- Exit: `migrate()` returns `u8`: 1 for the existing `railsExitError`, else 3 when `handoff.complete == false` (with a one-line stderr summary: "N route(s) open — answer MIGRATION.handoff.json's findings in MIGRATION.decisions.json and re-run"), else 0. `main.zig`: `.migrate` arm returns the `u8` directly; other arms `@intFromBool`.
- Help text for `--target` corrected: Rails now assembles a project.
- `RAILS_DECISION_STALE` blockers appended for stale decisions (they must land in the manifest → parse decisions before `manifest.build`; this means parsing decisions needs `discovery.findings` but the blocker must be appended to `discovery.blockers` — add `rails.appendBlocker(gpa, *Discovery, …)`? Simpler: `discover()` gains an optional `decisions_bytes: ?[]const u8` parameter and does the parse + stale-blocker append internally, returning `Discovery.decisions: decisions.Parsed`. Choose this; document.

- [ ] Tests: `rails.sh` pins updated (record the exact new listing for `rails-sample` — `pages#about` converts; the `posts` routes are `open`); a unit test for the exit mapping in `migrate.zig`'s `railsExitCode(strict, integrity, blockers, complete) u8`.
- [ ] Gates incl. `rails.sh`, `rails-presentation.sh` (its two-file listing assertion now FAILS by design — update it in Task 7; run it here to confirm the failure is the expected one, then leave it for Task 7).
- [ ] Commit.

---

### Task 7: Fixture decisions + e2e

**Files:** Create `tests/migrate/rails-presentation/MIGRATION.decisions.json`; modify `tests/migrate/rails-presentation.sh`; modify the fixture where needed (e.g. a `redirect` route: add `get "/old", to: "pages#old"` with an action that only `redirect_to`s, to exercise `RAILS_REDIRECT_HOST_CONFIG`).

The e2e proves the whole loop:
1. First run into `out1` (no decisions) → exit **3**; `MIGRATION.handoff.json` validates against `contract/rails-handoff.v1.schema.json` (`rails_manifest_validate` takes any schema+instance); `complete == false`; exact status per route pinned (`/` and `/about` migrated; `/help`, `/broken`, `/links`, `/posts`, `/posts/:id`, `/posts/legacy`, `/session/new`, `/registration/new`, `/old` open/redirect as appropriate); `content/about/index.smd` frontmatter bytes pinned; `layouts/templates/marketing.shtml` contains `<div id="main"><super></div>`; `layouts/pages/about.shtml` starts with `<extend template="marketing.shtml">`; `assets/images/logo.png` and `assets/robots.txt` copied; no `.new` files; source tree unchanged.
2. Second run into `out2` with `--decisions tests/migrate/rails-presentation/MIGRATION.decisions.json` (checked-in answers: `blocked` for help/broken/links/legacy(haml)/old; `retain` for the two forms and `/posts`; `spa` for `/posts/:id`) → exit **0**, `complete == true`, `spa/posts.spa.tsx` exists and `build.sh` carries `--spa=spa/posts.spa.tsx`.
3. `zigapagos release` on `out2` (with `ZIGAPAGOS_RUNTIME_DIR` set; needs `bun` — skip loudly if absent) exits 0 and `zigapagos doctor` on its output reports no errors — the "valid Zigapagos target" criterion.
4. Determinism: run 2 twice → `cmp` identical handoff + manifest.
5. A decisions file with an unknown id → exit 1 and the id named on stderr; with a bad choice → exit 1 naming the allowed choices; a stale id → `RAILS_DECISION_STALE` blocker, exit unaffected.
6. `--target` pre-existing with only `MIGRATION.decisions.json` inside → accepted; with any other file → rejected.
7. The Haml route cannot become `migrated` even if the decisions file says so (the choice is not offered → Invalid).

- [ ] Write; prove discrimination (remove one decision → exit 3; edit a pinned frontmatter byte → FAIL).
- [ ] Commit (`git add` the fixture files; commit with explicit paths).

---

### Task 8: Docs, skill mirror, changelog

**Files:** `docs/migration/rails-to-zigapagos.md` (+ byte mirror `skills/zigapagos-rails-migration/references/rails-to-zigapagos.md`), `skills/zigapagos-rails-migration/SKILL.md` (steps: run with `--target`, read the handoff, answer findings in `MIGRATION.decisions.json`, wipe and re-run until `complete`, then `zigapagos release`), `changelog.d/rails-convert.md`, `src/cli/init/`? (no).

Doc sections: "What `--target` writes" (the tree), "The conversion rules" (the concrete table from Task 3), "Decisions" (file format, choices per code, validation errors, stale), "The handoff" (fields, `complete`, exit code 3), "Re-run loop", and corrections to every sentence that still says Rails converts nothing. Gates: `tests/skills/sync.sh`, `tests/branding.sh`, `tests/confidentiality.sh`, full gate list.

- [ ] Write, mirror, gates, commit.

---

## Self-review

Spec coverage for Stage 2 ("Staging" item 2): converter (T3), scaffold (T4), decisions (T2), handoff + schema + gate (T5), completion exit code (T6), content/island pages + layouts + partial inlining + assets + `zigapagos.ziggy`/`build.sh` (T3/T4), dynamic-segment → `spa` (T4), fixture + e2e (T7), docs (T8). Findings derivation rows added in Stage 2: `RAILS_ASSET_TRANSFORM` (T3), `RAILS_ROUTE_DYNAMIC_SEGMENT`, `RAILS_REDIRECT_HOST_CONFIG` (T4), `RAILS_DECISION_STALE` blocker (T6) — all spec-listed. Not in Stage 2 (deliberately): `RAILS_BACKEND_ENDPOINT`/auth/forms (Stage 3), Turbo/Stimulus/React islands (Stage 4), parity (Stage 5).
