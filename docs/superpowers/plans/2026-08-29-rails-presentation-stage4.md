# Rails Presentation Stage 4 — Interactivity

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the three Stage 2 findings that could only ever be acknowledged — `RAILS_TURBO_FRAME`, `RAILS_COMPONENT_ROOT`, and the Stimulus `data-controller` element that raised no finding at all — become answerable with `island`, and the answer produces a component in the target: a Stimulus controller becomes `components/stimulus/<identifier>.island.tsx` wrapping the element's own markup and wiring its `data-action`/`data-*-target`/`-value` attributes to handlers ported structurally from `app/javascript/controllers/<identifier>_controller.js`; a Turbo frame with a `src` becomes a mount of `components/TurboFrame.island.tsx` that fetches the frame's HTML; a React root becomes `components/<Name>.island.tsx` importing the copied component through the compat bridge with its literal props serialised as Ziggy `:props`, plus a `z-runtime.config.json`; a Vue root is a blocker and a finding; `app/javascript/application.js` raises the one `RAILS_JS_ENTRY` question per app; and the `backend`/`island` answer on an `ivar`-shaped `RAILS_REQUEST_TIME_STATE` (issue #184, option 1) becomes a data-fetching island calling `list<Base>` — or, on a `spa` route, a real SPA route component calling `view<Base>` — through `lib/zb.ts`, with the ERB region ported to a string-templating body under stated rules. The SPA scaffold gains `spa.head` (issue #180, option 1). `tests/migrate/rails-presentation.sh` reaches `complete` with every one of those answers, builds, passes `doctor` with zero warnings, and mounts three of the generated islands in happy-dom.

**Architecture:** the sidecar (`templates.rb`) grows the element vocabulary — it already sees every text run, so it is the one place that can find `<div data-controller>`, `<turbo-frame>`, `data-react-class`/`data-vue-component` and close them into ordinary regions with a `block_end`; nothing on the Zig side parses HTML. One new std-only module `src/cli/rails/port.zig` holds the three pure analyses (the Stimulus controller scan, the action-descriptor grammar, the record-body port) that `findings.zig` uses to decide what to OFFER and `scaffold.zig` uses to EMIT, so a choice is offered iff the emitter can carry it out. `convert.zig` gains a second island shape — a WRAPPING island whose default slot is the region's converted body — beside Stage 3's replacing one. `scaffold.zig` gains four emitters and the project files they need (`lib/stimulus.ts`, `z-runtime.config.json`, copied React sources, `allowJs`). `rails.zig` reads the JS sources the templates name. The manifest `/1` gains four codes and one choice-list change; the handoff `/1` schema is untouched; `rails-check` must regenerate nothing.

**Tech Stack:** Zig 0.16.0 (std-only inside `src/cli/rails/`), Ruby 3.4 + Prism (sidecar; `JSON` stdlib for `data-react-props`), bash e2e under `tests/migrate/`, `jq`, `bun` for the island build and the happy-dom mount test, `@zigbase/client` 0.3.0 (`CollectionService.getList(page, perPage, opts)`, `getOne(id, opts)`, `isZigbaseError`), `@z/runtime` (`useState`, `useEffect`, `useRef`, `useParams`, `ComponentChildren`; `@z/runtime/compat` re-exports the React surface with a default export; `@z/runtime/testing` `renderIsland`/`click`/`flush` under `@z/runtime/testing/preload`; `@z/runtime/slots` `slotVNode`), the island contract in `docs/islands.md` (an `<island>`'s non-`<template slot>` children are the default slot, delivered as `children`; `:props` is a Ziggy struct literal typechecked against `export interface Props`), `docs/migration/react-spa-bridge.md` (`z-runtime.config.json` `islandImports`/`resolve`; explicit `resolve` keys are importable under the lint; `@z/runtime`-surface targets stay external), `docs/spa.md` `spa.head` (`[{ rel, href }]`, root-relative hrefs resolved against the assets dir at build).

**Spec:** `docs/superpowers/specs/2026-08-29-rails-presentation-migration-design.md` — decisions 1 (islands by decision, never by default) and 7 (Vue is a blocker), "Interactivity and assets", the `turbo_frame`/`turbo_stream`/`component_root` vocabulary rows, the codes `RAILS_TURBO_FRAME`, `RAILS_TURBO_STREAM`, `RAILS_COMPONENT_ROOT`, `RAILS_STIMULUS_CONTROLLER`, `RAILS_COMPONENT_PROPS_DYNAMIC`, `RAILS_COMPONENT_VUE_UNSUPPORTED`, `RAILS_JS_ENTRY`, "Staging" item 4, and "Out of scope" (no transpiling Stimulus to Preact, no Vue). Stage 2 (PR #183) rulings S1–S23 and Stage 3 (PR #188, tip `5b8ccd1`) rulings A1–A8 and S3-R2..R7 in their SDD ledgers bind this plan where they overlap; where this plan and a ledger conflict, the ledger wins.

## Global Constraints

- `src/cli/rails/` is std-only; no `@import` escapes it. New modules return errors (never call `fatal.*`); `migrate.zig` turns them into `fatal.file`/`fatal.dir`. `rails.zig` imports each new file (`pub const x = @import("x.zig");`) so `refAllDecls` reaches its tests.
- Every allocator-taking function states its NO_SLOP §2.2a contract accurately.
- Output is byte-identical for identical input: every emitted list sorted by a total order; no absolute paths in any artifact; no timestamps.
- The source tree is never written. Target writes use exclusive-create (`writeTargetFile`'s semantics: create parents, `.{ .exclusive = true }`); a Rails `--target DIR` may pre-exist ONLY if it contains nothing but `MIGRATION.decisions.json` (ruling S3).
- `classification` in the manifest is discovery's verdict and is never changed; the handoff `status` derives from the conversion outcome (spec: "where the two disagree the conversion wins").
- Exit codes: 0 complete; 1 the existing integrity/`--strict` failure, an unusable decisions file, a rejected `--target`, and an unusable `--backend` file; 3 = handoff `complete: false`.
- Regression tests must be shown to fail without the fix. Gates: `zig fmt --check` (via `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check`), `zig build check`, `zig build check -Dsingle-threaded`, `zig build rails-check`, `bash tests/contract/rails-drift.sh` (**its EXIT trap runs `git checkout HEAD --` over `handoff.zig`/`manifest.zig`/`schema_gen.zig`/both contract schemas — commit before running it**), `ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime zig build test-rails`, every `ruby runtime/sidecar/rails/test/*.rb`, `zig build` then every `tests/migrate/rails*.sh` (`rails.sh` reuses a stale `zig-out/bin/zigapagos` otherwise), `bash tests/skills/sync.sh`, `bash tests/branding.sh`, `bash tests/confidentiality.sh`, `bash scripts/check-allocator-contracts.sh`.
- Commit with explicit paths (`git commit -F <msgfile> -- <paths>`); messages explain the defect and the reasoning; trailers `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4`.
- Environment: zsh `noclobber` (`>|`), `cp`/`mv` aliased `-i` (`command cp -f`), `du` aliased (`\du`), the worktree guard rejects compound commands (one plain command per tool call, or a script under `$CLAUDE_JOB_DIR/tmp/`), never bare `git stash`.
- Stage 2 rulings that bind here: **S6** (a `rails:unmapped` region keeps an otherwise-migrated route open), **S12** (the Turbo/component rows exist NOW with `retain`/`blocked`; this stage WIDENS them, never renames them — the one exception, assumption B8, is a shape that never had a decision recorded against it), **S19/S21** (an acknowledgement on any finding of a route settles the route; a layout's finding id rides on every route under it), **S20** (a `retained`/`blocked` route writes no page), **S22** (route-level ids are keyed on the `config/routes.rb` line).
- Stage 3 rulings that bind here: **A1** (`lib/zb.ts` is `createClient("", { authStore: new LocalAuthStore() })`, errors are `ZigbaseError`/`isZigbaseError`), **A3** (`custom:/<path>` on `RAILS_BACKEND_ENDPOINT` only), **A4** (`artifact` is demanded only for a choice that produces something), **A5** (journey views raise no `RAILS_BACKEND_ENDPOINT`), **A6** (superseded here by B7), **S3-R2** (the backend row's `(line, verb, resource)` id), **S3-R6** (a finding inside a region an island replaced is `enclosed`; an answer on it is accepted and settled by `settleSuperseded`, whose note is SILENT when `reportedAsFolded` says the status-region walk already reports the id), **S3-R7** (`applyAcknowledgements` applies every answer on a route strongest-first — `rank`: `blocked` 4, `retain` 3, producing 2, `backend` 1 — and STOPS after a `retain`/`blocked`; the dynamic-route, redirect and backend arms each apply exactly one answer).
- Island mechanics that bind here, as shipped by Stage 3: an island file is written ONCE, keyed by `islandIdentity` (the region's finding id for a per-region island, a journey-level key for a shared one); a per-region island path is `uniqueIslandPath` — per-name ordinal de-collision keyed on template identity, `_2`, `_3` for a second region in one template — and a retained binding still reserves its name; `Binding.at` is the only key for a binding with no finding id of its own; `Context.bindings` is searched by the id of the OUTERMOST node the island replaces; `Output.bound_finding_ids` is disjoint from `open_finding_ids`; `lib/zb.ts` has ONE writer (`writeClientLib`); `package.json` is written iff a SPA or an island exists and pins `@zigbase/client` to `zigbase_client_version` (`"0.3.0"`); `build.sh` lists `--island=` flags sorted; `--spa=` restates the base.
- The ZigBase contract is what `~/nothlav/zigbase` ships, verified for this plan: `CollectionService.getList(page = 1, perPage = 30, opts)` returns `{ items, page, perPage, totalItems }`; `getOne(id, opts)`; realtime lives behind `@zigbase/client/realtime` (`subscribe(topic, cb, opts)`), which this stage does NOT use (B4). The `@z/runtime` facts above were read from `runtime/src/index.ts`, `runtime/src/router.ts` (`useParams<T>()`), `runtime/src/islands.ts` (`h(mod.default, { ...props, slots }, children)`), `runtime/src/testing/README.md`. A `file:` `@z/runtime` dependency is materialised by `bun install` as a COPY that carries the runtime's own `node_modules`, with `happy-dom`, `preact`, `typescript` hoisted to the target's top level (measured on this machine with bun 1.3.14 on a scratch `package.json`; the probe is `$CLAUDE_JOB_DIR/tmp/stage4-plan/bun-file-dep.sh`) — which is what makes B12's target-side happy-dom test resolvable.

### Assumptions marked for the controller's ruling

- **B1 (what "port a Stimulus controller" means).** The spec rules out transpiling Stimulus to Preact and describes a scaffold "with the facts gathered"; the brief for this plan asks for a TSX that ports the controller's targets and actions from its JS source. This plan does the STRUCTURAL port and nothing more: `static targets`/`static values`/`static classes` and the method names are read lexically from the controller file; every `data-action` descriptor in the element's extent is bound at mount to a handler of that name; each handler's body is the original method's source quoted in a comment above a `console.warn("zigapagos: <identifier>#<method> is not ported")` and a `TODO`. Targets, values and classes are resolved from the DOM at mount and passed to the handlers (`targets.details`, `values.open`, `classes.hidden`) so the operator's port has the same locals `this.detailsTarget`/`this.openValue` gave. Behavioural parity is NOT claimed anywhere — the header says so, the finding message says so, the doc says so. Cost if wrong: the handler-body policy is one function in `scaffold.zig`.
- **B2 (`RAILS_STIMULUS_CONTROLLER` choices).** The spec lists `island`, `drop`, `blocked`; this plan offers `island`, `drop`, `retain`, `blocked` — `retain` added because every code in the vocabulary offers it (S12's precedent) and an operator keeping a page on Rails because of its JS is the ordinary case. `drop` is always offered (stripping attributes needs no source); `island` only when every identifier's source is found and followed and every descriptor parses (Task 3's rule). Cost if wrong: one word in one list.
- **B3 (what a Turbo-frame island fetches, and from where).** The spec says the frame body "fetches `src` through `lib/zb.ts`". A frame's `src` is a Rails HTML route and the client's operations return JSON, so the island fetches `src` as HTML with `fetch(src, { credentials: "same-origin", headers: { Accept: "text/html" } })` from the site's own origin, extracts `#<id>` (else `main`, else `body`) and renders it. Who answers that URL is the `src` route's own handoff status: `migrated` means the static page this target built; `retained` means the host must proxy the path to Rails, and the route note says so (`frame src /posts is served by the retained Rails route; the host config must proxy it`); a `backend`-classified or JSON src is not offered `island` at all. `loading: "lazy"` maps to `client:visible`, everything else to `client:load`. Cost if wrong: one emitter and one message.
- **B4 (Turbo streams stay acknowledgeable).** `RAILS_TURBO_STREAM` keeps `["retain", "blocked"]`; the spec's `island-realtime` scaffold is not built here (the brief: "note/blocked"). The message names the stream and the follow-up issue (`turbo_stream_issue`, filed at PR time, the `a6_issue` pattern). Cost if wrong: a choice to add later.
- **B5 (Vue is a blocker AND a finding).** Decision 7 says blocker; S18's precedent says a route holding one must still be answerable or `complete` is unreachable. So `RAILS_COMPONENT_VUE_UNSUPPORTED` is both: a `warn`, non-integrity blocker per template from the Stage 1 `component_roots` markers (`data-vue-component`), and a `["retain", "blocked"]` finding per `vue_root` node. Cost if wrong: one row.
- **B6 (`RAILS_JS_ENTRY` rides on every page that loaded the entry).** One finding per app, id `RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry`, `line: null`, `loc` the word `entry` (the `unscanned`/`engine` precedent: nothing parsed the file). It is attached to every route whose layout or view carries an `importmap` node (`javascript_importmap_tags`/`turbo_include_tags`, the S21 layout mechanism), so one `drop` answer settles it everywhere. Choices `["drop", "blocked"]` — no `retain`, because under S19 a `retain` on an app-wide id would retain every page. Cost if wrong: a finding to detach.
- **B7 (`backend` and `island` on an `ivar` region are one converter).** Issue #184 option 1 defines the `backend` word as the data-fetching island; the brief calls the same thing the `island` answer. Both words on an `ivar`-shaped `RAILS_REQUEST_TIME_STATE` produce the data island; `rank("backend")` becomes 2 (producing) for that code only. `artifact` is OPTIONAL and names the collection; absent, the ivar stem is matched exactly against the document's collections, then with an `s` appended (`@post` → `posts`). A6's note is retired. Cost if wrong: one arm and one rank line.
- **B8 (dynamic props get their own code).** A `component_root` with `dynamic: true` derived `RAILS_COMPONENT_ROOT` in Stage 2; it now derives `RAILS_COMPONENT_PROPS_DYNAMIC` (`["retain", "blocked"]`), the code the spec names. `/1` has not shipped and no fixture recorded a decision against the old id. Cost if wrong: revert one `switch` arm.
- **B9 (React sources are copied, imports are lexical).** The island imports the component from `components/react/<path under app/javascript/components/>`, a byte copy — an import across trees would be an absolute path. `port.reactImports` follows `import … from "x"` / `import "x"` / `export … from "x"` lexically (string-literal specifiers only, ESM only): a relative specifier must resolve to a file in `app/javascript/` (extensions `.jsx .tsx .js .ts`, then `/index.*`) and is copied too; `react`, `react-dom`, `react-dom/client`, `react/jsx-runtime`, `react/jsx-dev-runtime` go through the bridge's `resolve` map; any other bare specifier must have a string version in the Rails `package.json` `dependencies`/`devDependencies` — it becomes an `npmCompat` entry and a target dependency at that version — else the root is not offered `island` (the message names the specifier). CSS/JSON/asset imports and `require()` are "cannot follow". The emitted `tsconfig.json` gains `"allowJs": true` so `tsc` can import the `.jsx`. Cost if wrong: a rule in `port.zig`.
- **B10 (two island shapes).** A Stimulus or Turbo-frame island WRAPS: `<island …>` + the region's converted body + `</island>`, and binds only the element's own finding id — findings inside its extent stay open, because the island claims the behaviour, not the content. A React-root or data island REPLACES its region like a Stage 3 form island: `bindRegion` runs, inner ids are `enclosed`, S3-R6 applies. Cost if wrong: one flag.
- **B11 (element extents are closed by the sidecar, same-block-depth).** The sidecar depth-counts `<tag`/`</tag>` across the text runs that follow an element node and emits a `block_end` after the close tag when it is found at the same Ruby block depth as the opener; otherwise the node carries `missing: true` and the finding offers `drop`/`retain`/`blocked` only (`island`/`inline` need the extent). Cost if wrong: an unusual template stays acknowledgeable.
- **B12 (hydration proof).** The e2e writes `test/hydrate.test.ts` + `bunfig.toml` into the BUILT target and runs `bun test` there: the generated islands are mounted with `@z/runtime/testing`'s `renderIsland` under happy-dom, a click reaches the Stimulus handler, the frame island renders a mocked `fetch` response, the React island renders the copied component through the real `z-runtime.config.json` (the preload applies its `resolve` map), the data island renders a mocked `getList` response. It runs only when `bun` is present (A8's skip). Browser hydration with cookies stays Stage 5's Playwright journey. Cost if wrong: an e2e arm.
- **B13 (`spa.head`, #180 option 1).** Every SPA gets `head: [{ rel: "stylesheet", href: "<target_url>" }]` for each deterministic `stylesheet_link_tag` asset in the layout each of its routes resolves (union, sorted by href, deduped), `head: []` when there is none; the e2e's "declares no spa.head" pin is deleted per its own comment. Cost if wrong: one line in `emitSpa`.

### Issues #180, #181, #184, #185

| Issue | Owned here? | Why |
|---|---|---|
| #180 `spa.head` | **Yes, option 1** (Task 6, B13) | The issue's own recommendation names Stage 4; `emitSpa` is rewritten here anyway. |
| #181 unmapped regions without a finding | **Partly** (Task 6) | A `local` inside a ported region (`<%= post.title %>` under `@posts.each`) and a `render partial:, locals: { post: post }` inside it are consumed by the data island, so they never reach `rails:unmapped`. A computed `content_for` name and an unresolvable `render` outside any region stay #181. |
| #184 `backend` on `RAILS_REQUEST_TIME_STATE` | **Yes, option 1** (Task 6, B7) | Closes with `Closes #184` on the PR. |
| #185 `tsc` TS7026 on every island | **No** | Task 5 touches the same `target_tsconfig` (adds `allowJs`) but the JSX-namespace fix is a runtime-package types question; own PR. Task 5 must not make it worse: `tsc -p tsconfig.json` in the built fixture target may report TS7026 and nothing else. |

---

### Task 1: Sidecar vocabulary — elements in text runs, typed props, portable shapes

**Files:** Modify `runtime/sidecar/rails/erb.rb` (text tokens gain `col:`), `runtime/sidecar/rails/templates.rb`, `runtime/sidecar/rails/test/templates_test.rb`, `runtime/sidecar/rails/test/erb_test.rb`, `src/cli/rails/fragments.zig` (decode).

**Wire (additive; an older Zig decodes a new kind as `unknown`, an older sidecar leaves every new field at its default):**

- Two new kinds: `stimulus`, `vue_root`. `fragments.Kind` gains `stimulus` and `vue_root`; `kindFromWire` needs no change.
- **Element scan of text runs.** `RailsErb.scan` puts `col:` on text tokens (`col_of(src, text_start)`), and `compile` keeps `text_tokens` by generated line beside `code_tokens` so `Walker#visit`'s `buf_append?` branch can find its token. That branch runs `scan_elements(text)`: every opening tag — `<([A-Za-z][\w-]*)` followed by attributes (`"…"`, `'…'`, unquoted), skipping `<!-- … -->`, `<script>…</script>` and `<style>…</style>` — whose name is `turbo-frame` or whose attributes include `data-controller=`, `data-react-class=` or `data-vue-component=`. At each hit the text run is SPLIT: the text before it (if non-empty), then the element node, then the remainder (which still begins with the tag: the node is a MARKER, it consumes no bytes, so the converter passes the markup through). `(line, col)` of the `<` is the text token's own start advanced over the prefix (newlines advance `line` and reset `col` to 1).
  - `stimulus`: `{kind: "stimulus", name: "<data-controller value, verbatim>", value: "<tag name>", attrs: [[k, v] for every data-action, data-*-target, data-*-*-value, data-*-*-class attribute ON THIS TAG], code: "<the opening tag's source>", output: false}`.
  - `turbo_frame` (HTML form): `{kind: "turbo_frame", name: "<id attr>", value: "turbo-frame", attrs: [["src", …], ["loading", …]] as present, dynamic: <id attr absent>, code}`.
  - `component_root` (HTML form): `{kind: "component_root", name: "<data-react-class>", attrs: <triples, below> from JSON.parse(data-react-props) when it is a flat object of string/number/boolean/null values; dynamic: true when the attribute is absent, not JSON, or nested; code}`.
  - `vue_root`: `{kind: "vue_root", name: "<data-vue-component>", code}`.
  - **Extent (B11).** After emitting an element node the walker depth-counts `<name`/`</name>` over the text runs it subsequently visits, at the SAME block depth (it tracks depth in `walk_block`/`emit_statement`), skipping comments; at the close tag it splits that text run and inserts `{kind: "block_end", code: "</name>", line, col}`. Void elements (`input`, `img`, `br`, `hr`, `meta`, `link`, `area`, `base`, `col`, `embed`, `source`, `track`, `wbr`), a self-closing `/>`, a close found at another depth, or none found before the template ends → no `block_end`, and the element node carries `missing: true`.
- **`turbo_frame_tag` (helper form)** gains `attrs: literal_attrs(opts)` (already flattened), and when `src:` is a receiverless `<stem>_path`/`_url` call with literal arguments: `value: "<stem>"`, `args: [<literal args>]`, `src` removed from `attrs`; `dynamic: true` when the id is not a literal or `src:` is anything else. `loading: :lazy` arrives as `["loading", "lazy"]`.
- **`component_root` props are TRIPLES** `[key, value, type]`, `type ∈ string|number|boolean|null`, from the Prism node class (`literal_pairs` gains a typed variant used here only). `fragments.Attr` gains `kind: ValueKind = .string` (`enum { string, number, boolean, null }`); the decoder accepts 2- or 3-element arrays on every node and reads the third only when present.
- **Shapes the port reads (Task 2):** `render_dynamic` gains `attrs: [[key, "<value source>"]]` when every `locals:` value is a bare local variable (`{ post: post }`), else no `attrs`; `route_helper_dynamic` gains `args: [<each positional argument's source slice>]` and, for the `link_to` form, `value: "<the link text's source slice>"`; `turbo_stream` gains `name: <literal first argument>` when literal.

- [ ] Ruby tests (RED first): each node shape above with exact `(line, col)`; a `data-controller` tag spanning two lines; `<!-- <div data-controller="x"> -->` yields nothing; `<script>` content is skipped; `data-react-props='{"a":1,"b":"x","c":true,"d":null}'` → four triples; `{"a":{"b":1}}` → `dynamic: true`; extent: `<div data-controller="r"><div>inner</div></div>` closes at the OUTER `</div>` (depth counts same-name tags), `<input data-controller="r">` is `missing: true`, a close inside `<% if x %>…<% end %>` while the opener is outside is `missing: true`, the split text runs re-join to the original source byte for byte; `turbo_frame_tag "latest", src: posts_path do … end` → `name latest, value posts, args []`; `src: post_path(1)` → `args ["1"]`; `src: post_path(@post)` → `dynamic: true`; `turbo_frame_tag "static" do … end` → no `value`, no `src`; `react_component("Chart", { series: "a", points: 3, on: true })` → triples with `number`/`boolean`; `render partial: "post", locals: { post: post }` → `attrs [["post","post"]]`; `link_to post.title, post_path(post)` → `route_helper_dynamic {name: "post", value: "post.title", args: ["post"]}`; `turbo_stream_from "posts"` → `name posts`. The erb test pins `col:` on text tokens and the untouched trim behaviour.
- [ ] Zig tests: decode of `stimulus`/`vue_root`, triples, a 2-element pair defaults to `.string`, a `block_end` with `</div>` code, `missing` on an element node; an older payload (no triples, no col) decodes exactly as before; FailingAllocator sweep of the decode.
- [ ] Commit: `git commit -F <msg> -- runtime/sidecar/rails/erb.rb runtime/sidecar/rails/templates.rb runtime/sidecar/rails/test/templates_test.rb runtime/sidecar/rails/test/erb_test.rb src/cli/rails/fragments.zig`.

---

### Task 2: `port.zig` — the three pure analyses

**Files:** Create `src/cli/rails/port.zig`; modify `src/cli/rails/rails.zig` (import line only).

**Interfaces:**
```zig
pub const JsSource = struct { path: []const u8, bytes: []const u8 };   // borrowed, app-relative

// (a) Stimulus controller source.
pub const ValueType = enum { string, number, boolean, array, object };
pub const Method = struct { name: []const u8, source: []const u8 };     // borrowed slices of the file
pub const Controller = struct {
    identifier: []const u8, path: []const u8,
    targets: []const []const u8, values: []const struct { name: []const u8, kind: ValueType },
    classes: []const []const u8, methods: []const Method,
    /// `null` when the port follows the file; else why it cannot (below).
    unsupported: ?[]const u8,
};
/// Contract 3: `admin--users` -> `app/javascript/controllers/admin/users_controller`; `-` inside a segment -> `_`.
pub fn controllerStem(buf: *[512]u8, identifier: []const u8) []const u8;
/// Contract 2 (`freeController`). `null` when no `sources` entry has `path` == stem + one of `.js .ts .jsx .tsx` (first in that order).
pub fn stimulusSource(gpa, identifier: []const u8, sources: []const JsSource) Allocator.Error!?Controller;

// (b) Action descriptors, from an element extent's text.
pub const Descriptor = struct { event: []const u8, identifier: []const u8, method: []const u8, prevent: bool, stop: bool, selector_index: usize };
/// Contract 2. Every `data-action` attribute in `text` (all tags, the opener included), each whitespace-separated token parsed as
/// `(event->)?identifier#method(:prevent|:stop)*`; `event` defaults by the tag: a/button -> click, form -> submit, input/textarea -> input,
/// select -> change, details -> toggle, else click. Tokens naming another identifier are skipped. `unsupported` names the first token with
/// `@window`/`@document` or any other option, or a malformed token.
pub fn actionDescriptors(gpa, text: []const u8, identifier: []const u8) Allocator.Error!struct { list: []Descriptor, unsupported: ?[]const u8 };

// (c) Record body: an ERB region as a JS string-templating function body.
pub const Alias = struct { ruby: []const u8, js: []const u8 };           // `post` -> `rec`
pub const Unportable = struct { kind: fragments.Kind, line: u64, col: u64, why: []const u8 };
pub const Body = struct { js: []u8, unportable: ?Unportable };
/// Contract 2 (`freeBody`). Emits `h += "…";` statements into `js` (no function wrapper) under the rules below; on the first node it
/// cannot follow it STOPS and reports it (js is then meaningless and the caller offers no island).
pub fn recordBody(gpa, ctx: convert.Context, path: []const u8, nodes: []const fragments.Node, aliases: []const Alias) Allocator.Error!Body;

// (d) React imports.
pub const Import = struct { spec: []const u8, relative: bool };
/// Contract 2. ESM `import … from "x"`, `import "x"`, `export … from "x"` with a string-literal specifier, in source order; `require(` or a
/// dynamic `import(` anywhere -> `unsupported`.
pub fn reactImports(gpa, bytes: []const u8) Allocator.Error!struct { list: []Import, unsupported: ?[]const u8 };
```

**Stimulus scan rules (lexical, and the plan says so):** strings, template literals, `//` and `/* */` comments are skipped; the class body is the first `{` after `extends Controller` (or `extends` anything) to its matching `}`; at body depth 1, `static targets = [ … ]`, `static values = { name: Type | { type: Type, … }, … }`, `static classes = [ … ]` are read (Type ∈ String/Number/Boolean/Array/Object); a method is `(async )?name(…) {` at depth 1, its `source` the header through the matching `}`; `constructor`, `initialize`, `connect`, `disconnect` and `*TargetConnected`/`*TargetDisconnected`/`*ValueChanged` are lifecycle and excluded from `methods` (their presence is noted in the header comment). `unsupported` when: `static outlets` is present; a getter/setter (`get name(`) or computed key (`[`) at depth 1; the body cannot be bracketed (unbalanced braces after skipping strings/comments — a regex literal containing `{` is the known way to reach this); the file is not `export default class`.

**Record-body rules**, per node in order, `aliases` in scope: text → `h += "<JS-escaped text>";` ; `literal` output → HTML-escaped; `i18n` resolved → value, missing → unportable; `route_helper` (literal args) → the URL `resolve.routeUrl` gives, as `convert` emits it; `link_to` literal → `<a href="…">text</a>` as `convert` emits it; `asset` deterministic → `resolve.assetTargetPath` URL in the same tag `convert` emits (`<img src>`, bare URL); `csrf`/`importmap` → dropped; a `local` OUTPUT node whose `code` is `<alias>` or `<alias>.<ident>` (`ident` = `[a-z_][a-z0-9_]*`, an optional trailing `?` dropped) → `h += esc(String(<js>.<ident> ?? ""));` ; an `ivar` OUTPUT node whose `@name` is an alias → the same; `route_helper_dynamic` with `args` all of the shape `<alias>` or `<alias>.<ident>` and a `certain` route named `<name>` whose `:param` count equals `args.len` → the route path with each `:param` replaced, in order, by `" + encodeURIComponent(String(<js>.id ?? "")) + "` (a bare alias means its `id`) or `<js>.<ident>`; the `link_to` form additionally requires `value` of the shape `<alias>.<ident>` and emits the `<a>`; `control` whose `code` is `if <alias>.<ident>?`/`if <alias>.<ident>`/`unless …` (one predicate, no operators) → `h += (<js>.<ident> ? A : B)` across its `block_else`/`block_end`; `render_partial`/`render_partial_locals` → the partial's nodes inlined (`convert.partialPathIn`, cycle-guarded) with its literal locals as aliases to JS string literals; `render_dynamic` with `attrs` whose every value is an alias → inlined with `key -> alias.js`; any other node (`unknown`, `request_state`, a non-alias `ivar`, `form`, `errors`, `raw`, `.present?`/`.any?`/`.each` inside, a `control` on anything else, a non-literal `asset`) → `unportable{why}`. The generated body uses one helper the emitter writes once: `const esc = (s: string) => s.replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));`.

- [ ] Tests (RED first): `controllerStem` for `reveal`, `admin--users`, `date-picker`; `stimulusSource` on the fixture controller of Task 7 → `targets ["details"]`, `values [{open, boolean}]`, `methods [toggle]` with the exact `source` slice; an empty `export default class extends Controller {}` → all empty, followed; `static outlets` → unsupported; a getter → unsupported; a `/{/` regex → unsupported (the documented limit, pinned); `actionDescriptors` on `<button data-action="click->reveal#toggle">`, `data-action="reveal#toggle"` (default click), `<form data-action="reveal#save">` (submit), `"keydown->reveal#close:prevent modal#x"` (the `modal#x` token skipped), `"click@window->reveal#x"` → unsupported; `recordBody` golden JS for: text + `<%= post.title %>`, `link_to post.title, post_path(post)` → `"/posts/" + encodeURIComponent(String(rec.id ?? ""))`, `if post.published?`, the fixture's `_post` partial reached through `render partial: "post", locals: { post: post }`, `<%= post.author.name %>` → unportable at its `(line, col)`, `<%= current_user %>` → unportable; `reactImports` on the fixture `Chart.jsx` (`react`), `import "./x.css"` (a relative CSS import is listed and Task 3 refuses it), `require("x")` → unsupported; FailingAllocator sweep of all four.
- [ ] Commit (`port.zig`, `rails.zig`).

---

### Task 3: `findings.zig`, `decisions.zig`, `rails.zig` — the rows, the choices, the JS sources

**Files:** Modify `src/cli/rails/findings.zig`, `src/cli/rails/decisions.zig`, `src/cli/rails/rails.zig` (`Discovery.js_sources`, `Discovery.js_entry`, `Discovery.npm_dependencies`, the Vue blocker, `DeriveInput` threading), `src/cli/rails/integrations.zig` (`dependencyVersions`), `src/cli/rails/blockers.zig` (nothing new; `append` is reused).

**`rails.discover`:** after the `templates` op, read into `Discovery.js_sources: []port.JsSource` (owned; `readFileAlloc … .limited(256 * 1024)`, at most 32 files per named root): for every `stimulus` node, each identifier's `port.controllerStem` + the first of `.js .ts .jsx .tsx` present in the inventory (`Kind.stimulus_controller`); for every `component_root` node, `app/javascript/components/<name>.<jsx|tsx|js|ts>` (first present) and, transitively, every relative `port.reactImports` target that resolves under `app/javascript/` (`.jsx .tsx .js .ts`, then `/index.*`). A read failure leaves the file out (the finding says "source not found" with the OS error). `Discovery.js_entry: ?[]const u8` = the inventory's `Kind.js_entry` path when exactly one exists. `Discovery.npm_dependencies: []NpmDep{name, version}` from `integrations.dependencyVersions(gpa, pkg)` — every string-valued entry of `dependencies` then `devDependencies`, sorted by name. All three freed by `freeDiscovery`. The Vue blocker: for every `Discovery.templates[]` whose `component_roots` contains `data-vue-component`, `blockers.append(gpa, &list, "RAILS_COMPONENT_VUE_UNSUPPORTED", path, "Vue roots have no runtime bridge; React only", false, .warn, null, null)`.

**`DeriveInput` gains:** `js_sources: []const port.JsSource = &.{}`, `js_entry: ?[]const u8 = null`, `npm_dependencies: []const NpmDep = &.{}`, `route_params: []const struct { name: []const u8, path: []const u8 } = &.{}` (certain routes: name + path, for the frame src and the port's `route_helper_dynamic` rule), plus `resolve`'s view of the same `fragments` it already has.

Rows (all `severity: warn`; template-node ids `L<line>C<col>`; messages exact):

| code | trigger | choices | message |
|---|---|---|---|
| `RAILS_STIMULUS_CONTROLLER` (new) | a `stimulus` node | `["island","drop","retain","blocked"]` when NOT `missing`, not nested inside another stimulus element's extent, every identifier has a `stimulusSource` with `unsupported == null`, and `actionDescriptors` over the extent's text reports no `unsupported` for any identifier; else `["drop","retain","blocked"]` | `` stimulus `reveal` on <div>; actions: click->reveal#toggle; targets: details; source app/javascript/controllers/reveal_controller.js `` — the `actions:`/`targets:` lists are sorted and omitted when empty; a refused one ends instead with `; source not found (app/javascript/controllers/reveal_controller.{js,ts,jsx,tsx})`, `; port cannot follow: <unsupported>`, `; element is not closed at its own block depth`, or `; nested inside the stimulus element at L2C1` |
| `RAILS_TURBO_FRAME` (widened) | a `turbo_frame` node (either form) | `["island","retain","blocked"]` when the frame has a src that resolves — a literal absolute path, or `value`+`args` naming a `certain` route with `:param` count == `args.len` — whose route is not `backend`-classified and not JSON; `["inline","retain","blocked"]` when it has no src and is not `missing`; else `["retain","blocked"]` | `` turbo-frame `latest` src=/posts `` / `` turbo-frame `static` (no src) `` / `` turbo-frame `x` src is request-time state `` / `` turbo-frame `x` src=/feed is API traffic `` |
| `RAILS_TURBO_STREAM` (message only) | as S12 | `["retain","blocked"]` | `` turbo-stream `posts`: a realtime subscription has no converter (see #<turbo_stream_issue>) `` |
| `RAILS_COMPONENT_ROOT` (widened) | a `component_root` node with `dynamic == false` | `["island","retain","blocked"]` when the source is found and every import in its closure is relative-and-found, a bridge specifier, or a bare specifier with a version in `npm_dependencies`, and `reactImports.unsupported == null` for every file; else `["retain","blocked"]` | `` React root `Chart` props {points, series}; source app/javascript/components/Chart.jsx `` / `…; source not found under app/javascript/components/` / `` …; import "d3" from Chart.jsx has no version in package.json `` / `` …; import "./x.css" from Chart.jsx cannot be bundled `` |
| `RAILS_COMPONENT_PROPS_DYNAMIC` (new, B8) | a `component_root` node with `dynamic == true` | `["retain","blocked"]` | `` React root `Chart` with request-time props `` |
| `RAILS_COMPONENT_VUE_UNSUPPORTED` (new, B5) | a `vue_root` node | `["retain","blocked"]` | `` Vue root `Widget`: the runtime bridge is React-only `` |
| `RAILS_JS_ENTRY` (new, B6) | `js_entry != null`; path = that file, `line: null`, `loc` `entry` | `["drop","blocked"]` | `` JS entry app/javascript/application.js was not inspected; imports: ./controllers, @hotwired/turbo-rails; the islands replace it — drop after review, or block `` (imports from `port.reactImports`, sorted) |
| `RAILS_REQUEST_TIME_STATE` (`ivar`, gated) | an `ivar` node | `choices_full` when `port.recordBody` follows the region (the node's block body for an opener, the node alone for an output read) with the ivar itself aliased to `rec`; else `["spa","retain","blocked"]` | unchanged, plus `; collection posts (in --backend)` when the stem (or stem + `s`) names a document collection, `; island/backend need artifact = a collection in --backend (posts, users)` when a document is present and none matches, nothing without a document |

`request_state` nodes keep `choices_full` untouched (Stage 3's `AuthStatus` shape). The nesting rule: a `stimulus` node whose index lies inside another stimulus node's extent (`convert.matchingEnd`) is nested.

**`decisions.parse` additions:** `drop` and `inline` are ordinary words validated against the finding's list (no special case). An `island`/`backend` answer on a `RAILS_REQUEST_TIME_STATE` finding carrying an `artifact`, when `parse` was given a non-empty `collections: []const []const u8` (every `backend.Document.operations[].collection`, deduped, sorted), must name one of them; the problem text is `artifact "foo" is not a collection in the backend document; collections: posts, users`. Without a document the name is accepted verbatim.

- [ ] Tests (RED first): one derive case per row with exact id/choices/message on hand-built inputs (the fixture-shaped `backend.Document` from Stage 3's `fixture_document`, `js_sources` inline); the gating negatives (missing source, `static outlets`, a nested stimulus element, `missing: true`, a `backend`-classified src route, an unpinned bare import, a CSS import); `RAILS_JS_ENTRY` absent when `js_entry == null`; the ivar gate on the fixture's `posts/index` and `posts/show` node streams (both offered) and on `<%= @post.author.name %>` (not); `decisions.parse` accepts `drop`/`inline` where offered, rejects `artifact: "foo"` with the text above; `rails.discover` reads exactly the named sources (a controller nothing names is not read), caps at 32, and `freeDiscovery` leaks nothing; `dependencyVersions` on `{"dependencies":{"react":"19.0.0","x":{"workspace":"*"}}}` → `[react 19.0.0]`; FailingAllocator sweep.
- [ ] Implement; gates; commit (`findings.zig`, `decisions.zig`, `rails.zig`, `integrations.zig`).

---

### Task 4: `convert.zig` — wrapping islands, pass-through answers, Turbo Drive attributes

**Files:** Modify `src/cli/rails/convert.zig`.

**Interfaces:**
```zig
pub const Binding = struct {
    …existing…,
    kind: Binding.Kind,            // gains: stimulus, turbo_frame, component, data_list, inline, drop
    /// B10: the island WRAPS the region (its converted body is the default slot) instead of replacing it.
    wrap: bool = false,
    /// `client:load` or `client:visible` (a lazy frame). Ignored unless the binding emits an `<island>`.
    directive: []const u8 = "client:load",
    /// Stimulus: every identifier on the element, outermost first; the island path is the FIRST's.
    identifiers: []const []const u8 = &.{},
    /// data_list: the aliases the port was run with (`post` -> `rec`) and the collection.
    aliases: []const port.Alias = &.{},
    collection: ?[]const u8,       // already present; reused for data_list
};
pub const IslandSpec = struct { …existing…, port: ?[]u8 /* OWNED: recordBody js for data_list */, extent: ?[]const u8 /* BORROWED: the region's source text for a wrapping island's header */ };
```
Behaviour in `walk`:
- A region whose head node has a binding with `wrap == true` (kinds `stimulus`, `turbo_frame`): emit `<island src="<island>" <directive>[ :props='…']>`, walk the region's body (all nodes between head and its `block_end`) exactly as if unbound — inner findings emit their markers and stay open — then `</island>`. Only the head's finding id goes to `bound_finding_ids`; nothing is `enclosed`. A `stimulus` binding with several identifiers nests one `<island>` per identifier, outermost first (`<island src="components/stimulus/reveal.island.tsx" client:load><island src="components/stimulus/modal.island.tsx" client:load><div data-controller="reveal modal">…</div></island></island>`). A Turbo frame island's props are `{ .id = "latest", .src = "/posts" }` (JS-escaped as Ziggy strings; the `src` is the resolved URL); a helper-form frame's body is its block, a self-closing one's is empty; for the HTML form the `<turbo-frame …>` opening tag and the `</turbo-frame>` close are cut out of their text runs — the island renders the `<div id>` itself.
- A binding with `kind == .component` (replacing): `<island src="components/Chart.island.tsx" client:load :props='{ .points = 3, .series = "a" }'></island>` — keys sorted, `number`/`boolean` unquoted, `null` omitted (the emitter declares that prop optional), strings Ziggy-escaped; `bindRegion` runs (no inner nodes exist).
- A binding with `kind == .data_list` (replacing): `<island src="components/data/posts_index.island.tsx" client:load></island>`; `bindRegion` runs over the region AND, new, follows every `render_partial`/`render_partial_locals`/`render_dynamic` node inside it into the partial's node stream (`partialPathIn`, cycle-guarded) binding those ids under the partial's own path — the `_post` partial's `RAILS_ROUTE_HELPER_DYNAMIC`/`RAILS_TEMPLATE_CONTROL_FLOW` are inside the island, so they are enclosed by it. `IslandSpec.port` = `port.recordBody(...).js` (unportable is impossible here: Task 3 offered the choice only after it followed).
- `kind == .inline`: the head's finding id is bound; the region passes through — helper form: `<turbo-frame id="static">` + body + `</turbo-frame>`; HTML form: verbatim.
- `kind == .drop`: bound; the region passes through with every `data-controller`, `data-action`, `data-<id>-target`, `data-<id>-<name>-value`, `data-<id>-<name>-class` attribute (for each of the element's identifiers) removed from every tag in the extent's text runs — attribute removal is lexical on `<tag …>` text, quotes respected.
- Turbo Drive: every text run drops `data-turbo`, `data-turbo-action`, `data-turbo-track`, `data-turbo-permanent`, `data-turbo-prefetch` attributes (same lexical remover); one `dropped` note per template: `data-turbo attributes dropped; Turbo Drive is ordinary navigation here` (informational, like `csrf_meta_tags dropped`).
- `opensBlock` returns true for `.stimulus`, `.vue_root`, and a `.turbo_frame` whose `value == "turbo-frame"`, iff `!node.missing` (their `block_end` is the sidecar's close-tag marker; a `missing` element opens nothing and its region is the node alone).
- An unbound element node is a `rails:finding` region as today (the marker before the tag, `rails:end` after the close tag); a `vue_root` region likewise.

- [ ] Tests (RED first), golden bytes: a wrapped Stimulus region with an unanswered `<%= t(".missing") %>` inside — the island tags, the inner `rails:finding` marker still present and its id in `open_finding_ids`, only the head id bound; two identifiers → nested islands outermost first; a lazy frame → `client:visible` with `:props='{ .id = "latest", .src = "/posts" }'`; a frame answered `inline` → `<turbo-frame id="static"><p>Just markup</p></turbo-frame>`; `drop` strips exactly the listed attributes and leaves `class`; the component `:props` literal with a number, a boolean, a sorted key order and a `"` in a string; the data island region binds the partial's ids (`bound_finding_ids` contains the `_post` ids, `enclosed` names the ivar id as `by`); `data-turbo-action="advance"` stripped with the note; a `missing` stimulus node emits a marker and `rails:end` around the tag alone; determinism; FailingAllocator sweep reaching every new branch.
- [ ] Commit (`convert.zig`).

---

### Task 5: `scaffold.zig` — Stimulus, Turbo-frame and React islands; project files

**Files:** Modify `src/cli/rails/scaffold.zig`.

**Bindings (`bindTemplate` gains three node kinds):** `.stimulus`, `.turbo_frame`, `.component_root` with a decision on the head's id:
- `island` on `RAILS_STIMULUS_CONTROLLER` → `Binding{ kind = .stimulus, wrap = true, identifiers, island = "components/stimulus/<first identifier with "--" and "-" → "_">.island.tsx" }`; `islandIdentity` = the identifier (one file per controller, written once, mounted at every element); a name taken by another identifier's flattening (`a-b` vs `a--b`) gets the `_2` ordinal.
- `island` on `RAILS_TURBO_FRAME` → `Binding{ kind = .turbo_frame, wrap = true, island = turbo_frame_island_path, props, directive = "client:visible" iff attrs has loading=lazy }`; `pub const turbo_frame_island_path = "components/TurboFrame.island.tsx"`, identity the constant (shared, like `AuthForm`).
- `island` on `RAILS_COMPONENT_ROOT` → `Binding{ kind = .component, island = "components/<Name>.island.tsx", props }`; identity = the name; a name colliding with `AuthForm`, `AuthStatus`, `TurboFrame` or another root's flattening gets `_2`. The copied sources go to `components/react/<path relative to app/javascript/components/>` (the closure's files under `app/javascript/` but outside `components/` go to `components/react/_/<path relative to app/javascript/>`), written once each by path.
- `drop`/`inline` → `Binding{ kind = .drop | .inline }` with `island = ""`.

**Emitters** (exact shapes; header comment on every file as in Stage 3: `// Generated by … from <source>:<line>.` / `// Replaces: <one-line ERB>`):
- `emitStimulusIsland(gpa, controller: port.Controller, descriptors: []const port.Descriptor, mounts: []const StatusOrigin-like{path,line})`:
  ```tsx
  // Ported STRUCTURALLY from app/javascript/controllers/reveal_controller.js — targets, values,
  // classes and action bindings are wired; the method bodies are quoted below and NOT translated.
  // Behavioural parity is not claimed. Mounted at: app/views/pages/widgets.html.erb:2.
  import { useEffect, useRef, type ComponentChildren } from "@z/runtime";
  import { bindActions, targetsOf, valuesOf, classesOf } from "../../lib/stimulus";

  export interface Props {}

  export default function Reveal(props: Props & { children?: ComponentChildren }) {
    const root = useRef<HTMLDivElement>(null);
    useEffect(() => {
      const el = root.current!;
      const targets = targetsOf(el, "reveal", ["details"]);
      const values = valuesOf(el, "reveal", { open: "boolean" });
      const classes = classesOf(el, "reveal", []);
      // toggle — original:
      //   toggle() {
      //     this.openValue = !this.openValue
      //     this.detailsTarget.classList.toggle("hidden", !this.openValue)
      //   }
      function toggle(event: Event) {
        console.warn("zigapagos: reveal#toggle is not ported");
        // TODO: port the body above; `targets.details[0]` is this.detailsTarget, `values.open` is this.openValue
      }
      return bindActions(el, "reveal", { toggle });
    }, []);
    return <div ref={root} style="display:contents">{props.children}</div>;
  }
  ```
  Lifecycle methods present in the source are named in the header (`connect/disconnect present: port them into the effect`). Handlers with no descriptor in any mount are still emitted (the controller is the unit).
- `lib/stimulus.ts`, written once when any stimulus binding exists: `targetsOf(root, id, names)` → `Record<name, HTMLElement[]>` via `[data-<id>-target~="<name>"]`; `valuesOf(root, id, types)` → reads `data-<id>-<name>-value` off the `[data-controller~="<id>"]` element, coercing by type (`boolean`: `"true"`, `number`: `Number`, `array`/`object`: `JSON.parse`, else string); `classesOf` → `data-<id>-<name>-class`; `bindActions(root, id, handlers)` → for every `[data-action]` element in `root` (itself included) and every whitespace-separated token matching `^(?:(\w[\w:.-]*)->)?<id>#(\w+)((?::\w+)*)$`, `addEventListener(event ?? default-by-tag, wrapped)` where the wrapper applies `:prevent`/`:stop`, and returns a cleanup removing them. The same grammar as `port.actionDescriptors`, restated in TS because the browser has no Zig; the golden test pins the file and a comment in each names the other.
- `emitFrameIsland` (`components/TurboFrame.island.tsx`, written once): `export interface Props { id: string; src: string }`; `useState<string | null>(null)`; `useEffect` → `fetch(props.src, { credentials: "same-origin", headers: { Accept: "text/html" } })` → `text()` → `new DOMParser().parseFromString(html, "text/html")` → `doc.getElementById(props.id) ?? doc.querySelector("main") ?? doc.body` → `setHtml(el.innerHTML)`; on any rejection `setHtml(null)` and `console.warn("zigapagos: turbo-frame " + props.id + " could not load " + props.src)`; render `<div id={props.id}>{html === null ? props.children : <div dangerouslySetInnerHTML={{ __html: html }} />}</div>` (the slot is the placeholder until the fetch lands — SSR shows it). Header: B3's sentence about who serves `src`.
- `emitComponentIsland(name, copied_path, props: []const Attr)`:
  ```tsx
  // Generated by `zigapagos migrate --from rails` from app/views/pages/widgets.html.erb:9.
  // Replaces: react_component("Chart", { series: "a", points: 3 })
  // The component is app/javascript/components/Chart.jsx, copied unchanged to components/react/Chart.jsx;
  // its `react` imports resolve to the shared runtime through z-runtime.config.json (docs/migration/react-spa-bridge.md).
  import Chart from "./react/Chart.jsx";

  export interface Props { points: number; series: string }

  export default function ChartIsland(props: Props) {
    return <Chart {...props} />;
  }
  ```
  Prop types from `Attr.kind` (`string`/`number`/`boolean`; a `null` prop is `name?: null`).
- `z-runtime.config.json`, written when any component binding exists, exact bytes: `{"islandImports":{"firstParty":[],"npmCompat":[<sorted bare specifiers>]},"resolve":{"react":"@z/runtime/compat","react-dom":"@z/runtime/compat","react-dom/client":"@z/runtime/compat/client","react/jsx-runtime":"@z/runtime/jsx-runtime","react/jsx-dev-runtime":"@z/runtime/jsx-dev-runtime"}}` + newline. `emitPackage` gains one `"<pkg>": "<version>"` per `npmCompat` entry (sorted, after `@zigbase/client`). `target_tsconfig` gains `"allowJs": true` after `"skipLibCheck"`.
- `applyAcknowledgement`: `island` on the three codes → settle iff `boundBy` (the generic deferral note is unreachable now for a finding that offered `island`; keep it for a finding answered `island` that did not offer it — `decisions.parse` refuses that, so the note is the "vocabulary drift" backstop); `drop` on `RAILS_STIMULUS_CONTROLLER` → settle + note `` stimulus `reveal` dropped by decision ``; `inline` → settle + note `` turbo-frame `static` inlined ``; `drop` on `RAILS_JS_ENTRY` → settle + note `app/javascript/application.js dropped by decision`. `rank("drop") == rank("inline") == 2`. Status: unchanged rule — `migrated` iff nothing open and no unmapped region; a wrapped island's inner open findings keep the route open (B10).
- `RAILS_JS_ENTRY` attachment: `ensureLayout`/`ensureView` append the entry's id (from `firstFindingWithCode(ctx.in.discovery.findings, "RAILS_JS_ENTRY")`) to the layout's/view's `open_ids` when the template's nodes contain an `importmap` node.
- `writeProjectFiles`: `bound` now also true for stimulus/frame/component/data bindings; `lib/zb.ts` is written only when a binding actually calls the client (form, click, journey, data) — a Stimulus-only target has no client library and no `@zigbase/client` dependency (`emitPackage`'s `with_client` follows that).

- [ ] Tests (RED first), golden bytes: the three island files and `lib/stimulus.ts` exactly; the nested two-identifier mount writes two files; a shared controller mounted from two views is written once with both mounts in its header; `TurboFrame` written once for two frames; `z-runtime.config.json`, `package.json` with a pinned `d3`, `tsconfig.json` with `allowJs`; the copied `.jsx` is byte-identical to the source; `drop`/`inline` notes; `RAILS_JS_ENTRY` rides on every route under an importmap layout and one `drop` settles all; a retained route with a stimulus binding writes no page (S20) but the shared island file is still written when another route mounts it; Stimulus-only target has no `lib/zb.ts`; determinism; FailingAllocator sweep.
- [ ] Commit (`scaffold.zig`).

---

### Task 6: `scaffold.zig` — data islands (#184), SPA view components, `spa.head` (#180)

**Files:** Modify `src/cli/rails/scaffold.zig`, `src/cli/rails/resolve.zig` (`collectionFor`).

**Binding:** `island` or `backend` on an `ivar`-shaped `RAILS_REQUEST_TIME_STATE` whose region `port.recordBody` follows (Task 3 offered it) → collection = the answer's `artifact`, else `resolve.collectionFor(doc, stem)` (exact, then stem + `s`); a document with a `.list` operation on that collection is required → `Binding{ kind = .data_list, island = "components/data/<viewStem>[_n].island.tsx" (the `uniqueIslandPath` rule with the `data/` prefix), collection, aliases = [{block param, "rec"}, {ivar, "rec"}] }`. Without a document, or with no list operation: no binding; `applyAcknowledgement` adds the open note `` choice backend on RAILS_REQUEST_TIME_STATE needs a --backend document with a list operation for collection `posts` `` (the same shape as the Stage 3 backend-arm note; `island` says `choice island …`).

**`emitDataIsland`**:
```tsx
// Generated by `zigapagos migrate --from rails` from app/views/posts/index.html.erb:1.
// Replaces: @posts.each do |post|
// Reads collection `posts` through lib/zb.ts; the collection's list rule decides what a visitor sees.
import { useEffect, useState } from "@z/runtime";
import { isZigbaseError } from "@zigbase/client";
import { zb } from "../../lib/zb";

export interface Props {}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

function body(rec: any): string {
  let h = "";
  <recordBody js, one statement per line, indented two>
  return h;
}

export default function PostsIndex(_props: Props) {
  const [html, setHtml] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    zb.collection("posts").getList(1, 50)
      .then((page) => setHtml(page.items.map(body).join("")))
      .catch((err) => setError(isZigbaseError(err) ? err.code : String(err)));
  }, []);
  if (error !== null) return <p>{"Could not load posts: " + error}</p>;
  if (html === null) return <p>{"Loading…"}</p>;
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}
```
**SPA view components (the `view<Base>` half):** in `dynamicRoute`, after the `spa` answer is applied, if the route's own view has an `ivar` finding answered `island`/`backend`, the route path has exactly one `:param`, the collection (rule above) has a `.view` operation, and `port.recordBody` follows the WHOLE view with `[{ivar, "rec"}]` — then `SpaRoute` carries `port_js`, `collection`, `param`, and `emitSpa` writes, instead of the `TODO` placeholder: `import { Router, useParams, useEffect, useState } from "@z/runtime"; import { isZigbaseError } from "@zigbase/client"; import { zb } from "../lib/zb";`, the same `esc`/`body` pair per ported route, and `function PostsShow() { const params = useParams<{ id: string }>(); … zb.collection("posts").getOne(params.id) … }` with the same three render states. The finding's id is settled on that route (the dynamic-route arm applies a second answer here — the one exception to "exactly one", stated in `applyAcknowledgement`'s doc and in the docs). A view the port cannot follow keeps the placeholder and the finding stays open with `choice backend on …: the view is not portable (<why> at L<line>C<col>)`.

**`spa.head` (B13):** `emitSpa` writes `export const spa = { base: "/posts", head: [{ rel: "stylesheet", href: "/stylesheets/application.css" }] };` — one entry per deterministic `stylesheet_link_tag` asset (`resolve.assetFor` + `assetTargetPath`, `/`-prefixed) in the layout of every route in the group, sorted, deduped; `head: []` when none.

`lib/zb.ts` and `"@zigbase/client"` are written when a data binding or a ported SPA route exists.

- [ ] Tests (RED first): golden bytes for the data island on the fixture's `posts/index` graph (the `_post` partial inlined into `body`, `"/posts/" + encodeURIComponent(String(rec.id ?? ""))`, `rec.published ?`), for the SPA file with a ported `PostsShow` and a `head`, and for a SPA with two routes of which one is ported; `artifact` overrides the stem; stem + `s`; no document → the open note; no list operation → the open note; `island` and `backend` produce identical bytes; the route's endpoint stays `null`; a second data region in one view → `_2`; `head: []` on a stylesheet-less layout; determinism; FailingAllocator sweep.
- [ ] Commit (`scaffold.zig`, `resolve.zig`).

---

### Task 7: Fixture additions + e2e

**Files:** Modify `tests/migrate/rails-presentation/config/routes.rb`, `app/controllers/pages_controller.rb`, `MIGRATION.decisions.json`, `tests/migrate/rails-presentation.sh`; create `app/views/pages/widgets.html.erb`, `app/views/pages/live.html.erb`, `app/javascript/application.js`, `app/javascript/controllers/reveal_controller.js`, `app/javascript/components/Chart.jsx`; re-pin `tests/migrate/rails.sh` where `rails-sample` moves.

Fixture edits (exact; every addition goes at the END of its file so no existing `L<line>` id moves — `L14`, `L20`, `L38`, `L53` and the `posts_controller.rb` `L3` are pinned):
- `config/routes.rb`, before the final `end`: `get "/widgets", to: "pages#widgets"` then `get "/live", to: "pages#live"`, each with a comment naming the constructs it exercises.
- `pages_controller.rb`: `def widgets; end` and `def live; end` appended before the class's `end`.
- `app/views/pages/widgets.html.erb`:
  ```erb
  <% content_for :title do %>Widgets<% end %>
  <div data-controller="reveal" data-reveal-open-value="false">
    <button data-action="click->reveal#toggle">Show details</button>
    <p data-reveal-target="details" class="hidden">Details</p>
  </div>
  <%= turbo_frame_tag "latest", src: posts_path do %><p>Loading latest…</p><% end %>
  <%= turbo_frame_tag "static" do %><p>Just markup</p><% end %>
  <%= react_component("Chart", { series: "a", points: 3 }) %>
  <a href="/about" data-turbo-action="advance">About</a>
  ```
- `app/views/pages/live.html.erb`: `<%= turbo_stream_from "posts" %><div data-vue-component="Widget"></div>` (one line).
- `app/javascript/application.js`: `import "@hotwired/turbo-rails"` / `import "./controllers"`.
- `app/javascript/controllers/reveal_controller.js`: the controller quoted in Task 5's island (`static targets = ["details"]`, `static values = { open: Boolean }`, `toggle()` with the two lines shown).
- `app/javascript/components/Chart.jsx`: `import React from "react";` / `export default function Chart({ series, points }) { return <button type="button">{series}:{points}</button>; }`.
- `MIGRATION.decisions.json` (ids re-derived from run 1 as the e2e header documents): the two `/posts` `retain` answers (`RAILS_PARTIAL_DYNAMIC…index L1C61`, `RAILS_REQUEST_TIME_STATE…index L1C33`) are DELETED; `RAILS_REQUEST_TIME_STATE…index L1C33` → `backend` (rationale names #184 and B7); `RAILS_REQUEST_TIME_STATE…show L1C9` → `backend`; the stimulus, both frames (`island`, `inline`), the React root (`island`) → answered; `RAILS_TURBO_STREAM…live…` → `blocked`; `RAILS_COMPONENT_VUE_UNSUPPORTED…live…` → `blocked`; `RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry` → `drop`; everything else as today.

The e2e proves:
1. Run 1 (`--backend`): exit 3; exact ids for `RAILS_STIMULUS_CONTROLLER…widgets…L2C1` with `choices == island,drop,retain,blocked` and the exact message; the two `RAILS_TURBO_FRAME` ids with `island,retain,blocked` / `inline,retain,blocked` and messages (`src=/posts`); `RAILS_COMPONENT_ROOT…` with `island,retain,blocked` and message `props {points, series}; source app/javascript/components/Chart.jsx`; `RAILS_TURBO_STREAM…live…` message names `posts` and the issue; `RAILS_COMPONENT_VUE_UNSUPPORTED…live…` finding AND blocker (`integrity == false`, `severity == warn`); `RAILS_JS_ENTRY.app/javascript/application%2Ejs.entry` with `line == null`, `choices == drop,blocked`; `GET /widgets` and `GET /live` `open`; `GET /` open on the four nav ids PLUS the JS entry id (the S21 ride); `index L1C33`'s message ends `; collection posts (in --backend)`; the `badwords` closed set gains `drop`, `inline`; the run-1 listing gains `content/widgets/index.smd`, `layouts/pages/widgets.shtml`, `content/live/index.smd`, `layouts/pages/live.shtml` and nothing under `components/`; `widgets.shtml` carries `<!-- rails:finding RAILS_STIMULUS_CONTROLLER…` before `<div data-controller` and no `data-turbo-action`.
2. Run 1b (no `--backend`): `index L1C33`'s message carries no collection hint; the stimulus/frame/component choices are unchanged (they need no document).
3. Run 2: exit 0, `complete: true`; `GET /widgets` `migrated`, `GET /live` `blocked`, `GET /posts` `migrated` with note `guarded by before_action :require_login; shipped public by decision` (S3-R7 in run 2 proper now), `GET /posts/:id` `migrated`; exact run-2 listing = Stage 3's plus `components/stimulus/reveal.island.tsx`, `components/TurboFrame.island.tsx`, `components/Chart.island.tsx`, `components/react/Chart.jsx`, `components/data/posts_index.island.tsx`, `lib/stimulus.ts`, `z-runtime.config.json`, `content/posts/index.smd`, `layouts/posts/index.shtml`, `content/widgets/index.smd`, `layouts/pages/widgets.shtml` (no `content/live`); `widgets.shtml` contains `<island src="components/stimulus/reveal.island.tsx" client:load><div data-controller="reveal"`, `<island src="components/TurboFrame.island.tsx" client:load :props='{ .id = "latest", .src = "/posts" }'><p>Loading latest…</p></island>`, `<turbo-frame id="static"><p>Just markup</p></turbo-frame>`, `<island src="components/Chart.island.tsx" client:load :props='{ .points = 3, .series = "a" }'></island>`, and no `data-turbo-action`; `layouts/posts/index.shtml` contains `<island src="components/data/posts_index.island.tsx" client:load></island>` and no `rails:finding`; `spa/posts.spa.tsx` contains `head: [{ rel: "stylesheet", href: "/stylesheets/application.css" }]`, `useParams`, `getOne(params.id)`; `posts_index.island.tsx` contains `getList(1, 50)` and `"/posts/" + encodeURIComponent(String(rec.id ?? ""))`; `z-runtime.config.json` exact bytes; `tsconfig.json` has `"allowJs": true`; `build.sh` has one `--island=` per island file, sorted; `components/react/Chart.jsx` `cmp`s the fixture file; every route's note pinned exactly (the `GET /posts` note, the `/widgets` note `data-turbo attributes dropped…`; `/posts/:id` re-pinned to whatever the ported view yields, `<null>` included).
4. Build: `bash build.sh` exits 0; `zig-out/site/widgets/index.html` contains `data-z-module="/islands/reveal.island.js"`, `data-z-slots`, `<button type="button">a:3</button>` (the React component SSR'd through the bridge), `{"id":"latest","src":"/posts"}`; `zig-out/site/posts/_shell.html` contains `<link rel="stylesheet" href="/stylesheets/application.css">`; the `declares no spa.head` pin is DELETED and replaced by `grep -q "declares no spa.head" && fail`; `doctor`: `0 errors`, no `^warn ` lines; `tsc -p tsconfig.json` output contains no error code other than `TS7026` (#185's known state).
5. Hydration (B12, `bun` present): the e2e writes `test/hydrate.test.ts` at the target root and a `bunfig.toml` with `[test]\npreload = ["@z/runtime/testing/preload"]`, then runs `bun test` in the target: (a) `renderIsland(Reveal, { children: slotVNode("default", '<div data-controller="reveal" data-reveal-open-value="false"><button data-action="click->reveal#toggle">Show</button><p data-reveal-target="details" class="hidden">D</p></div>') })`, a `console.warn` spy, `await click(get("button"))` → the spy saw `zigapagos: reveal#toggle is not ported`; (b) `globalThis.fetch` mocked to resolve `<html><body><div id="latest">loaded</div></body></html>`, `renderIsland(TurboFrame, { id: "latest", src: "/posts" })`, `await flush()` → `text()` contains `loaded`; (c) `renderIsland(ChartIsland, { series: "a", points: 3 })` → `text() == "a:3"`; (d) `fetch` mocked to resolve `{"items":[{"id":"1","title":"Hello","published":true}],"page":1,"perPage":50,"totalItems":1}`, `renderIsland(PostsIndex, {})`, `await flush()` → `get("a").getAttribute("href") == "/posts/1"`, `text()` contains `Hello` and `Published`. Skips with `SKIP(partial)` only when `bun` is absent.
6. Determinism (run 2 twice → `cmp` on manifest, handoff, `MIGRATION.md`, every island, `lib/stimulus.ts`, `z-runtime.config.json`, `build.sh`); source untouched; no `.new` files.
7. Negatives: `island` on `RAILS_TURBO_STREAM…` → exit 1 `allowed: retain, blocked`; `artifact: "nope"` on `index L1C33` with `backend` → exit 1 `collections: posts, users`; run 2 without `--backend` → exit 3 with `needs a --backend document with a list operation` on `GET /posts`; delete the `RAILS_JS_ENTRY` answer → exit 3 and every page route open on that id; delete the `index L1C33` answer → exit 3, `GET /posts` `open` with its page written and the `public` note (the former guard-only arm, moved here); the stimulus finding answered `drop` (a copy) → run completes, `widgets.shtml` has `<div>` with no `data-*` attributes and no `components/stimulus/`.
8. `rails.sh`: `rails-sample` now raises `RAILS_STIMULUS_CONTROLLER` on `dashboard.html.erb` (`reveal` has an empty controller source → followed; `modal` has none → the element's choices are `drop,retain,blocked`, pinned) and `RAILS_JS_ENTRY`; its exact `--target` listing is unchanged (open routes still emit pages); re-pin whatever finding counts moved.

- [ ] Write; prove discrimination (revert Task 5's `bindActions` call → arm 5a fails; drop the `head:` → arm 4's shell grep fails; change `getList(1, 50)` → 5d fails).
- [ ] Commit (fixture files, decisions, e2e, `rails.sh`).

---

### Task 8: Docs, skill mirror, changelog

**Files:** `docs/migration/rails-to-zigapagos.md` (new §19 "Interactivity": the element scan and B11's extent rule; the Stimulus port — B1 stated as a limit, the island and `lib/stimulus.ts` verbatim, the descriptor grammar, `drop`; Turbo Drive attributes dropped; frames — B3, the shared `TurboFrame` island verbatim, `inline`, `client:visible`; streams — B4; React roots — B9, the island and `z-runtime.config.json` verbatim, the copy rule, `allowJs`, `RAILS_COMPONENT_PROPS_DYNAMIC`; Vue — B5; `RAILS_JS_ENTRY` — B6; data islands — B7, the `body()` port rules as a table with every "cannot follow" row, the SPA view component, `collectionFor`; `spa.head`; §12's fourth column for `turbo_frame`/`turbo_stream`/`component_root`/`stimulus`/`vue_root`; §15's choice table gains `island` on the four codes, `drop`, `inline`, `backend` on an `ivar`, and the second dynamic-route answer; §11's code list; §17's run tables; §18 "Known limitations" loses the Stage 4 bullet and #184, gains: inner findings of a wrapped island stay open, nested controllers, the descriptor options not followed, the Stimulus scan's lexical limits, `require()`, the frame proxy rule, streams), byte mirror `skills/zigapagos-rails-migration/references/rails-to-zigapagos.md`, `skills/zigapagos-rails-migration/SKILL.md` (step 7: `island`/`drop`/`inline` on the four codes, `backend` on an `ivar` region with an optional `artifact`, `RAILS_JS_ENTRY` `drop` after reading the file; step 8 mentions `bun test` in the target for the generated islands), `changelog.d/rails-interactivity.md` (Added / Changed: `RAILS_COMPONENT_PROPS_DYNAMIC` replaces one shape, `rank("backend")`, `allowJs` / Known limitations, with `Closes #184` and `Closes #180` stated for the PR body), `src/cli/init/AGENTS.md` (one paragraph: the generated islands' `TODO`/`console.warn` convention).

- [ ] Write, mirror (`command cp -f docs/migration/rails-to-zigapagos.md skills/zigapagos-rails-migration/references/`), gates (`tests/skills/sync.sh`, `tests/branding.sh`, `tests/confidentiality.sh`, full list), commit.

---

## Pre-flight conflict scan

| pair | shared file / interface | check |
|---|---|---|
| T1/T2 | `route_helper_dynamic.args/value`, `render_dynamic.attrs`, `Attr.kind`, `turbo_frame.value/args` ↔ `port.recordBody` and the frame src rule | consistent; T2 reads only fields T1 defines |
| T1/T4 | element `block_end` after the close tag + `missing` ↔ `opensBlock`/`matchingEnd` | consistent: an element region is an ordinary region; `missing` opens nothing |
| T2/T3/T5 | `port.stimulusSource`/`actionDescriptors`/`reactImports` decide the OFFER in T3 and the EMIT in T5 | one function each; T5 never re-derives followability |
| T2/T4/T6 | `port.recordBody` gates the ivar choices (T3), fills `IslandSpec.port` (T4) and the SPA component (T6) | one function; T4/T6 call it with the aliases T6 documents |
| T3 vs `rails.zig` | only T3 edits `rails.zig` (T2 adds the import line first) | serialise T2 → T3; T4/T5/T6 never touch it |
| T4/T5 | `Binding.Kind` additions, `wrap`, `directive`, `identifiers`, `IslandSpec.port/extent` ↔ `bindTemplate`, `emitIslandFor`, `islandIdentity` | consistent; T5 switches on every new kind (a missing arm is a compile error) |
| T5/T6 | both edit `scaffold.zig` (`bindTemplate`, `applyAcknowledgement`, `writeProjectFiles`, `emitSpa`) | serialise T5 → T6 in one tree; `bound`/`with_client` predicates written once in T5, widened in T6 |
| T4 self | a data island's `bindRegion` follows partials — the partial's ids are bound under the partial's PATH, which is how `collectTemplateFindings` lists them on the route | stated; the fixture's `_post` ids are the pin |
| T5 self | `TurboFrame`/`AuthForm`/`AuthStatus` are fixed names a React root can collide with | `_2` ordinal, stated |
| T5 vs Stage 3 | `writeClientLib` stays the single writer; a Stimulus-only target must not get `lib/zb.ts` | `with_client` predicate, pinned |
| T6 vs S3-R7 | the dynamic-route arm applies a second answer (the ivar's) | the one exception, documented in `applyAcknowledgement` and §15 |
| T6/T7 | `/posts` flips `retained` → `migrated`; the guard-only variant's drop set changes; the `spa.head` pin flips | T7 re-pins; the former variant becomes negative arm 7 |
| T3/T7 vs `rails.sh` | `rails-sample` gains `RAILS_STIMULUS_CONTROLLER` (dashboard) and `RAILS_JS_ENTRY`; its `--target` listing is unchanged | T7 re-pins counts; the listing tripwire must NOT move |
| T3 self | `RAILS_COMPONENT_VUE_UNSUPPORTED` blocker from Stage 1 markers vs finding from the node — two detectors for one fact | both substring-exact on `data-vue-component`; the e2e pins both on one template |
| all vs schemas | four new codes, no new wire fields on the manifest or handoff | `rails-check` must regenerate nothing; stop and report if it does |
| T8/T1–T7 | the doc quotes exact bytes | write T8 last, from the committed tree |

## Self-review

Spec coverage for Stage 4 ("Staging" item 4, "Interactivity and assets"): Turbo Drive (T4's attribute drop, documented as the mapping), Turbo frames with `island`/`inline` (T1, T3, T4, T5; B3 rules the fetch), Turbo streams as a note (T3; B4), Stimulus islands wrapping the element with the controller's facts gathered (T1, T2, T3, T5; B1 states the port's limits and B2 the choices), React roots through the compat bridge with serialised props and `z-runtime.config.json` (T1, T2, T3, T4, T5; B9), non-literal props → `RAILS_COMPONENT_PROPS_DYNAMIC` (T3; B8), Vue → `RAILS_COMPONENT_VUE_UNSUPPORTED` as blocker and finding (T3; B5), `RAILS_JS_ENTRY` (T3, T5; B6), the `island`/`backend` answer on an `ivar` region as a data island calling `list<Base>`/`view<Base>` through `lib/zb.ts` (T2, T6; B7, closes #184), `spa.head` (T6; B13, closes #180), the fixture growing every construct and the e2e reaching `complete`, `release`, `doctor` and a happy-dom mount (T7; B12), docs + skill + changelog (T8). Every choice offered is gated on the same function that emits it, so `island` is never offered for a shape the target cannot build. Deliberately not here: `island-realtime` (B4), transpiling controller bodies (B1), the Playwright browser journey and `parity[]` (Stage 5), #185.
