# Rails Presentation Stage 3 — Backend Boundary

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `zigapagos migrate <app> --from rails --target DIR --backend openapi.json` turns every Rails mutation and auth journey into a real binding against the ZigBase contract: a `RAILS_BACKEND_ENDPOINT` finding whose `choices` are the document's own operations, a form island that calls the chosen operation through `@zigbase/client` and redirects where the Rails action did, an `AuthForm`/`AuthStatus` pair for the session/registration journey, validation errors rendered where the ERB rendered `full_messages`, `routes[].endpoint` and `backend` filled in the handoff — so a route answered with an operation reaches `migrated` instead of staying `open` with `choice backend deferred to Stage 3`.

**Architecture:** One new std-only module `src/cli/rails/backend.zig` (read the OpenAPI document, rank operations for a verb/resource) feeding `findings.zig` (widened and new rows), `decisions.zig` (two validation additions), `convert.zig` (a bound form/link/auth region becomes an `<island>`), `scaffold.zig` (island files, `lib/zb.ts`, `package.json`, `build.sh --island=`, redirect targets, endpoint pairing), `handoff.zig` (`backend`, `endpoint`, the `backend` status rule) and `migrate.zig` (`--backend FILE`). The Ruby `controllers` op grows two facts per action (`before_actions`, `redirects`). The `/1` manifest gains nothing but wider `choices`; the handoff `/1` schema is unchanged (both `Backend` and `Endpoint` were declared in Stage 2).

**Tech Stack:** Zig 0.16.0 (std-only inside `src/cli/rails/`), Ruby 3.4 + Prism (sidecar), bash e2e under `tests/migrate/`, `jq`, `bun` for the island build in the e2e, `@zigbase/client` 0.3.0 (npm; `createClient`, `LocalAuthStore`, `ZigbaseError`), the real `zigbase openapi` document shape (OpenAPI 3.1.2, `x-zigbase-coverage`, `list|create|view|update|delete<Base>` operation ids, `<Base>Create` schemas carrying `password`/`passwordConfirm` for an auth collection).

**Spec:** `docs/superpowers/specs/2026-08-29-rails-presentation-migration-design.md` — "Backend boundary", "Auth journeys", "Validation presentation", "Findings, decisions, handoff", "Staging" item 3, the `RAILS_BACKEND_ENDPOINT`/`RAILS_AUTH_JOURNEY` rows. Stage 2 (PR #183, tip `d453f75`) and its rulings S1–S23 in the Stage 2 SDD ledger bind this plan where they overlap; where this plan and that ledger conflict, the ledger wins.

## Global Constraints

- `src/cli/rails/` is std-only; no `@import` escapes it. New modules return errors (never call `fatal.*`); `migrate.zig` turns them into `fatal.file`/`fatal.dir`. `rails.zig` imports each new file (`pub const x = @import("x.zig");`) so `refAllDecls` reaches its tests.
- Every allocator-taking function states its NO_SLOP §2.2a contract accurately.
- Output is byte-identical for identical input: every emitted list sorted by a total order; no absolute paths in any artifact; no timestamps.
- The source tree is never written. Target writes use exclusive-create (`writeTargetFile`'s semantics: create parents, `.{ .exclusive = true }`); a Rails `--target DIR` may pre-exist ONLY if it contains nothing but `MIGRATION.decisions.json` (ruling S3).
- `classification` in the manifest is discovery's verdict and is never changed; the handoff `status` derives from the conversion outcome (spec: "where the two disagree the conversion wins").
- Exit codes: 0 complete; 1 the existing integrity/`--strict` failure, an unusable decisions file, a rejected `--target`, **and (new) an unusable `--backend` file**; 3 = handoff `complete: false`.
- Regression tests must be shown to fail without the fix. Gates: `zig fmt --check` (via `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check`), `zig build check`, `zig build check -Dsingle-threaded`, `zig build rails-check`, `bash tests/contract/rails-drift.sh` (**its EXIT trap runs `git checkout HEAD --` over `handoff.zig`/`manifest.zig`/`schema_gen.zig`/both contract schemas — commit before running it**), `ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime zig build test-rails`, every `ruby runtime/sidecar/rails/test/*.rb`, `zig build` then every `tests/migrate/rails*.sh` (`rails.sh` reuses a stale `zig-out/bin/zigapagos` otherwise), `bash tests/skills/sync.sh`, `bash tests/branding.sh`, `bash tests/confidentiality.sh`, `bash scripts/check-allocator-contracts.sh`.
- Commit with explicit paths (`git commit -F <msgfile> -- <paths>`); messages explain the defect and the reasoning; trailers `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4`.
- Environment: zsh `noclobber` (`>|`), `cp`/`mv` aliased `-i` (`command cp -f`), `du` aliased (`\du`), the worktree guard rejects compound commands (one plain command per tool call, or a script under `$CLAUDE_JOB_DIR/tmp/`), never bare `git stash`.
- Stage 2 rulings that bind here: **S11** (`backend` status counts as accounted until this stage's endpoint mapping reopens it — Task 5 is that reopening), **S12** (`form`/`form_field` → `RAILS_BACKEND_ENDPOINT`, `errors` → `RAILS_REQUEST_TIME_STATE`; one finding per outermost form; Stage 3 WIDENS these rows, never renames them), **S19/S21** (an acknowledgement on any finding of a route settles the route; a layout's finding id rides on every route under it), **S20** (a `retained`/`blocked` route writes no page), **S22** (route-level finding ids are keyed on the `config/routes.rb` line: `<CODE>.config/routes%2Erb.L<line>`, one finding per line, `message` listing every route on it), **S6** (a `rails:unmapped` region keeps an otherwise-migrated route open).
- The ZigBase contract is what `~/nothlav/zigbase` ships, not what the spec sketched. Verified facts this plan is built on: `@zigbase/client` exports `createClient(baseUrl, {authStore, authCollection, …})`, `LocalAuthStore`, `CookieAuthStore` (a serializer with `exportToCookie`/`loadFromCookie`, never read by the transport), `ZigbaseError{status, code, data: Record<string, {code, message}>}`, `isZigbaseError`; `CollectionService` has `authWithPassword(identity, password)`, `logout()`, `create(body)`; `Transport` sends `Authorization: Bearer` only — no `credentials`, no CSRF header. `zigbase openapi` emits `openapi: "3.1.2"`, `x-zigbase-coverage{collections, consumerRoutes, admin, realtime, fileBytes, allAuthMethods}` (the last always `false`: `auth-with-password`/`auth-logout` are NOT in the document), `x-zigbase-access` (`public`/`locked`/`conditional`) on collection operations and `x-zigbase-auth` (`public`/`authenticated`/`superuser`/`path-secret`) on consumer routes, operation ids `list<Base>`/`create<Base>`/`view<Base>`/`update<Base>`/`delete<Base>` where `<Base>` is the collection name with `_`/`-` removed and each word capitalised (`users` → `Users`), and an auth collection is recognisable ONLY by its `<Base>Create` schema carrying `password` and `passwordConfirm`. The in-repo `contract/zigbase.openapi.json` is an older 3.0.3 document with three consumer routes, `x-zigbase-contract-version: "2026-06-27.1"` and no coverage object; `backend.zig` must read both.

### Assumptions marked for the controller's ruling

- **A1 (spec deviation, verified against the client).** `lib/zb.ts` uses `createClient("", { authStore: new LocalAuthStore() })` and errors are `ZigbaseError`, not the spec's `new ZigBase({ baseUrl: "", authStore: new CookieAuthStore() })` / `ClientResponseError`: neither `ZigBase` nor `ClientResponseError` is exported, and `CookieAuthStore` persists nothing in a browser (the transport never sends `credentials` or a CSRF header, so a cookie session is unusable through the client). `LocalAuthStore` is what the blog example's own `api.ts` does with `localStorage`. Cost if wrong: one line in `lib/zb.ts` and one import in the auth island.
- **A2 (completion rule).** In `isComplete`, a `backend` row is accounted iff `endpoint != null` OR `decision != null` (S11's "reopened through its own finding"). Non-GET/HEAD routes stay outside the count (Stage 2 doc: "form traffic"); the rule therefore bites only on a GET route that renders JSON. Cost if wrong: S11's original permissiveness returns.
- **A3 (`custom:<path>`).** The spec lists `custom:<path>` among a `RAILS_BACKEND_ENDPOINT` finding's choices, but a free-form token cannot be enumerated in a fixed `choices[]`. Ruling proposed: `choices[]` lists operation ids + `retain` + `blocked`; `decisions.parse` ADDITIONALLY accepts a choice matching `custom:/<path>` (starts with `custom:/`, no whitespace, no `"`) on `RAILS_BACKEND_ENDPOINT` findings only; the binding is `zb.send("<VERB>", "<path>", { body })` and the handoff endpoint is `{ "operation_id": "custom", "verb", "path" }`. The finding's `message` says so.
- **A4 (artifact requirement).** `RAILS_AUTH_JOURNEY` has `requires_artifact: true`; `decisions.parse` requires `artifact` only when the choice is one that produces something (`island`), never for `retain`/`blocked` — the Stage 2 rule "required when `requires_artifact`" was written when no finding set it.
- **A5 (journey detection).** The auth journey = every route whose controller is `sessions` or `registrations`, plus every route whose reachable ERB view holds a `form` containing a `form_field` named `password_field`. Forms in journey views derive NO `RAILS_BACKEND_ENDPOINT` (the journey finding is their question); a wrong guess only moves a form from one answerable finding to another.
- **A6 (the literal `backend` choice on `RAILS_REQUEST_TIME_STATE`).** Still not produced by this stage (a data-fetching island for `@posts` is neither in "Backend boundary" nor in Stage 4). Its note changes from `choice backend deferred to Stage 3` to `choice backend on RAILS_REQUEST_TIME_STATE has no converter (see #<issue>)`, and a GitHub issue is filed at PR time.
- **A7 (new code).** `RAILS_ROUTE_AUTH_GUARD` (`choices: [public, retain, blocked]`), route-scoped, for a page route whose controller runs a `before_action` whose symbol name contains `login`, `auth`, `sign` or `user`: a static page cannot enforce the guard, and shipping it silently public is the "silently marked complete" the issue forbids. `public` is a new choice word: "ship the page; the ZigBase rules protect the data".
- **A8 (e2e network).** The island build step of the e2e runs `bun install` in the target, which fetches `@zigbase/client@0.3.0` from npm. CI already fetches for `runtime/`; the step skips loudly (`SKIP(partial)`) only when `bun` is absent, never when the network is.

### Issues #178–#182

| Issue | Owned here? | Why |
|---|---|---|
| #178 MIGRATION.md absolute app path | **No** | Pre-existing since #166 and unrelated to the backend boundary; own PR. |
| #179 `file:TODO-SET-RUNTIME-PATH` default | **Yes, option 1** (Task 4) | This stage emits islands that need `@z/runtime` on every bound form, so the placeholder now hits every backend answer; `emitPackage` is rewritten anyway. |
| #180 `spa.head` | **No** | Stage 4 per the issue's own recommendation. |
| #181 unmapped regions without a finding | **Partly** (Task 4) | The `full_messages.each do \|m\|` local disappears when the `errors` region is rendered by the bound form island; `render`/`content_for`/other `local` cases stay #181. |
| #182 id-less route notes | **Yes** (Task 3) | Same S22 mechanism as the route-level rows this stage adds: `RAILS_CONTENT_PATH_COLLISION` and `RAILS_ROUTE_PATH_UNSUPPORTED`, `retain`/`blocked`. |

---

### Task 1: `backend.zig` — read the ZigBase OpenAPI document

**Files:** Create `src/cli/rails/backend.zig`; modify `src/cli/rails/rails.zig` (import line).

**Interfaces:**
```zig
pub const Access = enum { public, locked, conditional, authenticated, superuser, path_secret, unknown };
pub const Kind = enum { list, create, view, update, delete, custom };
pub const Operation = struct {
    operation_id: []const u8,   // owned
    verb: []const u8,           // owned, upper-case ("POST")
    path: []const u8,           // owned, as written ("/api/collections/posts/records", "/api/contact")
    collection: ?[]const u8,    // owned; the <name> of "/api/collections/<name>/records[/{id}]", else null
    kind: Kind,                 // from the path shape + verb; every non-collection path is .custom
    access: Access,             // x-zigbase-access, else x-zigbase-auth, else .unknown
};
pub const Document = struct {
    file: []const u8,               // owned basename of the file, for the handoff `backend.file`
    contract_version: []const u8,   // owned: `x-zigbase-contract-version` when present, else `info.version`
    consumer_routes: bool,          // `x-zigbase-coverage.consumerRoutes` when present, else true iff any .custom op exists
    operations: []Operation,        // sorted by (path, verb)
    auth_collections: [][]const u8, // owned, sorted: every collection whose create op's request schema has BOTH `password` and `passwordConfirm` properties (resolved through `$ref` to `#/components/schemas/<X>`)
};
pub const ParseError = error{ InvalidJson, NotOpenApi3, NoPaths } || Allocator.Error;
/// Contract 2 (`free`). `NotOpenApi3` when `openapi` is absent or does not start with "3."; `NoPaths` when `paths` is not an object. Unknown keys are ignored (the document is ZigBase's, not the operator's).
pub fn parse(gpa, bytes: []const u8, file_label: []const u8) ParseError!Document;
pub fn free(gpa, doc: Document) void;
/// Contract 1: the choice list for one question. `verb` upper-case; `resource` the Rails resource/controller name (`posts`) or null.
/// Order: operations with `verb` and `collection == resource` first (by operation_id), then every other operation with `verb` (by operation_id), then "retain", "blocked". Never an operation with a different verb.
pub fn choicesFor(gpa, doc: ?Document, verb: []const u8, resource: ?[]const u8) Allocator.Error![][]const u8;
/// Contract 3: the operation an answered choice names, or null for retain/blocked/custom:<path>.
pub fn operationFor(doc: Document, choice: []const u8) ?Operation;
```

- [ ] Tests (RED first): parse the in-repo `contract/zigbase.openapi.json` → 3 ops, all `.custom`, `access == .unknown`, `contract_version == "2026-06-27.1"`, `consumer_routes == true`, no auth collections; parse an inline 3.1.2 document shaped like the fixture's (Task 6 writes the same bytes) → `createUsers` is `.create` on `users` with `access == .public`, `listPosts` `.conditional`, `viewPosts` `.public`, `auth_collections == ["users"]`; `choicesFor(doc, "POST", "posts")` == `["createPosts", "createUsers", "retain", "blocked"]` and `choicesFor(doc, "GET", "posts")` == `["listPosts", "viewPosts", "listUsers", "viewUsers", "retain", "blocked"]` (collection match first, then the other same-verb operations, each group by operation id); `choicesFor(null, "POST", null)` == `["retain", "blocked"]`; `"2.0"` → `NotOpenApi3`; missing `paths` → `NoPaths`; determinism (parse twice → identical `operations` order); FailingAllocator sweep.
- [ ] Implement with `std.json.parseFromSlice(std.json.Value, …)`; `zig build test-rails`; fmt.
- [ ] Commit: `git commit -F <msg> -- src/cli/rails/backend.zig src/cli/rails/rails.zig`.

---

### Task 2: Sidecar `controllers` op — `before_actions` and `redirects`

**Files:** Modify `runtime/sidecar/rails/controllers.rb`, `runtime/sidecar/rails/test/controllers_test.rb`, `src/cli/rails/controllers.zig` (wire decode + `ActionInfo`), `src/cli/rails/rails.zig` (thread through `Discovery`).

**Wire (additive; an older sidecar's response decodes as empty):** each `actions[]` entry gains
`"redirects": [{"name": "root", "args": ["1"]} | {"dynamic": true}]` — one per `redirect_to` call anywhere in the action body, in source order; `name` is the `_path`/`_url` helper stem with literal args only, `dynamic` for `redirect_to @post`, a variable, or non-literal args. The response gains a top-level
`"before_actions": [{"controller": "posts", "name": "require_login", "only": ["index"], "except": [], "line": 2}]` — one per literal `before_action :sym` / `before_action :sym, only: [...]` / `except:`; a block or non-symbol argument is `{"controller", "dynamic": true, "line"}`. `after_action`/`around_action` are ignored.

**Zig:**
```zig
pub const RedirectInfo = struct { name: ?[]const u8, args: []const []const u8, dynamic: bool };  // owned
pub const ActionInfo = struct { controller, action, only_redirect, renders_json, redirects: []const RedirectInfo = &.{} };
pub const BeforeAction = struct { controller: []const u8, name: ?[]const u8, only: []const []const u8, except: []const []const u8, dynamic: bool, line: u64 };
pub const Result = struct { …existing…, before_actions: []BeforeAction };
/// Contract 3: whether `filter` applies to `action` (`only` empty and `except` not containing it, or `only` containing it).
pub fn guards(filter: BeforeAction, action: []const u8) bool;
/// Contract 3: the heuristic of assumption A7 — `name` contains "login", "auth", "sign" or "user" (ASCII case-insensitive).
pub fn looksLikeAuthGuard(filter: BeforeAction) bool;
```
`Discovery` gains `before_actions: []controllers.BeforeAction` and `actions` keeps `redirects` (both freed by `freeDiscovery`).

- [ ] Ruby tests (RED first): `redirect_to root_path` → `{name: "root", args: []}`; `redirect_to post_path(1)` → args `["1"]`; `redirect_to @post` / `redirect_to post_path(@post)` → dynamic; `before_action :require_login, only: [:index, :show]`; `before_action :set_post, except: :destroy` (a bare symbol normalises to a one-element array); `before_action { … }` → dynamic; `after_action` ignored; the existing fixture's `pages#old` yields `redirects: [{name: "about", args: []}]`.
- [ ] Zig tests: decode of the new fields; missing fields decode empty; `guards` truth table (`only` wins over `except`; both empty → true); `looksLikeAuthGuard("require_login") == true`, `("set_post") == false`; FailingAllocator sweep of the dupe.
- [ ] Commit (`controllers.rb`, its test, `controllers.zig`, `rails.zig`).

---

### Task 3: `findings.zig` + `decisions.zig` — the Stage 3 rows and their validation

**Files:** Modify `src/cli/rails/findings.zig`, `src/cli/rails/decisions.zig`, `src/cli/rails/rails.zig` (`DeriveInput` threading; `DecisionsInput` gains `backend`).

**`Finding.choices` becomes owned** (every row dupes its list; `free` releases it) — the only way a list built from a document can live beside the static ones. Every existing test literal `.choices = &choices_retain_blocked` becomes a dupe through a test helper.

**`DeriveInput` gains:** `backend: ?backend.Document`, `before_actions: []const controllers.BeforeAction`, `actions: []const controllers.ActionInfo`, `route_views: []const ?[]const u8` (index-aligned: the view each route resolved, from `Discovery.route_templates`), `content_collisions: []const usize` and `unsupported_route_paths: []const usize` (route indexes; both computed by the caller with `resolve.contentPath` exactly as `scaffold.zig` does — one function, exported from `resolve.zig` as `pub fn contentClaims(gpa, routes, classifications) …`, so the finding and the scaffold note cannot disagree).

Rows (all `severity: warn`; route-scoped ids per S22; messages exact):

| code | trigger | id | choices | message |
|---|---|---|---|---|
| `RAILS_BACKEND_ENDPOINT` (form, widened) | outermost `form` not in a journey view (A5); orphan `form_field` | template `L<line>C<col>` (unchanged) | `backend.choicesFor(doc, verb, resource)` where verb = literal `method` attr upper-cased else `POST`, resource = the template's route controller | `form submits to a Rails action: model \`user\` method=post; bind it to a backend operation, retain, or block. A route not in the document is answerable as custom:/<path>.` |
| `RAILS_BACKEND_ENDPOINT` (link, new) | a `link_to` node whose source `code` starts with `button_to`, or whose attrs carry `method` ≠ `get` or `data-turbo-method` | template `L<line>C<col>` | `choicesFor(doc, verb, resource)` with verb from the attr (`delete` → `DELETE`), `button_to` default `POST`; resource = the route helper stem's resource (`session_path` → `session`) | `link performs a mutation: button_to \`Sign out\` method=delete` |
| `RAILS_BACKEND_ENDPOINT` (route, new) | every route with classification `backend` or a non-GET/HEAD verb, not in the journey | `config/routes%2Erb.L<line>` | `choicesFor(doc, route verb, route controller)` | `route is API traffic and needs a backend operation: POST /registration` |
| `RAILS_AUTH_JOURNEY` (new, at most one per app) | the journey (A5) is non-empty | `config/routes%2Erb.L<smallest line of a journey route>` | `["island", "retain", "blocked"]`, `requires_artifact: true` | `auth journey: GET /registration/new, GET /session/new, POST /registration, POST /session, DELETE /session; island needs artifact = the ZigBase auth collection name (in --backend: users)` (`(in --backend: …)` becomes `(pass --backend to validate the name)` without a document) |
| `RAILS_ROUTE_AUTH_GUARD` (new, A7) | a GET route that produces a page (not `backend`/`redirect`/dynamic) whose controller has a `looksLikeAuthGuard` filter that `guards` the action | `config/routes%2Erb.L<line>` | `["public", "retain", "blocked"]` | `page is guarded by before_action :require_login on posts; a static page cannot enforce it: GET /posts` |
| `RAILS_REQUEST_TIME_STATE` (`errors`, widened) | as S12 | unchanged | `["island", "retain", "blocked"]` | unchanged |
| `RAILS_CONTENT_PATH_COLLISION` (new, #182) | the second route claiming a content path | `config/routes%2Erb.L<line>` | `["retain", "blocked"]` | `content path collision with GET /about: GET /about/` |
| `RAILS_ROUTE_PATH_UNSUPPORTED` (new, #182) | a static GET route `resolve.contentPath` refuses (`(.:format)`) | `config/routes%2Erb.L<line>` | `["retain", "blocked"]` | `route path contains syntax this stage does not interpret: GET /posts(.:format)` |

**`decisions.parse` additions:** (1) A3: a choice `custom:/…` on a `RAILS_BACKEND_ENDPOINT` finding is valid; the problem text for a malformed one is `choice "custom:x" must be custom:/<absolute path> with no whitespace or quotes`. (2) A4: `requires_artifact` demands `artifact` only when the choice is not `retain`/`blocked`; the problem text is unchanged. (3) `parse` gains `auth_collections: []const []const u8` (from `backend.Document`, empty without one): an `island` answer on `RAILS_AUTH_JOURNEY` whose `artifact` is not in the list, when the list is non-empty, is `Invalid` with `artifact "members" is not an auth collection in the backend document; auth collections: users`. Without a document the name is accepted verbatim (the doc says so).

- [ ] Tests (RED first): one derive case per row above with exact id/choices/message on hand-built inputs (including the fixture-shaped `backend.Document` from Task 1); a form in a journey view derives NO `RAILS_BACKEND_ENDPOINT`; `link_to` with `method: :get` derives nothing; one `RAILS_AUTH_JOURNEY` however many journey routes; `choices` are freed (leak check); `decisions.parse` accepts `custom:/api/contact`, rejects `custom:api/contact` and `custom:/a b`, accepts `retain` without artifact on a `requires_artifact` finding, rejects `island` without one, rejects an unknown auth collection with the text above; FailingAllocator sweep.
- [ ] Implement; `rails.zig` threads the new inputs (Task 2's fields; `backend` from `DecisionsInput.backend: ?backend.Document`); gates; commit (`findings.zig`, `decisions.zig`, `resolve.zig`, `rails.zig`).

---

### Task 4: `convert.zig` + `scaffold.zig` — bindings for forms, links and redirects

**Files:** Modify `src/cli/rails/convert.zig`, `src/cli/rails/scaffold.zig`, `src/cli/rails/resolve.zig` (`redirectUrl`).

**Interfaces:**
```zig
// convert.zig
pub const Binding = struct { finding_id: []const u8, kind: enum { operation, custom, auth_signin, auth_signup, auth_logout }, verb: []const u8, path: []const u8, operation_id: []const u8, collection: ?[]const u8, island: []const u8 /* target-relative component path */, redirect_to: ?[]const u8 /* site URL after success */ };
pub const Context = struct { …existing…, bindings: []const Binding };  // by finding id of the outermost node they replace
pub const IslandSpec = struct { island: []const u8, fields: []const Field, errors_model: ?[]const u8, submit_label: []const u8, binding: Binding, original: []const u8 /* the ERB region's source text, for the header comment */ };
pub const Field = struct { helper: []const u8 /* text_field|email_field|password_field|hidden_field|text_area|check_box|select|label|submit */, name: []const u8, label: ?[]const u8, options: []const []const u8 /* select literals */ };
pub const Output = struct { …existing…, islands: []IslandSpec, bound_finding_ids: [][]const u8 };
```
Conversion of a bound region: the whole `form` block (or the `link_to` node) is replaced by
`<island src="<island>" client:load></island>` — no placeholder comment, no `rails:end`; every finding id inside the region (form fields, an `errors` node whose `name` equals the form's model name — or any `errors` node in the template for a model-less form — and the region's nested nodes) lands in `bound_finding_ids`, not `open_finding_ids`. The `full_messages.each do |m|` local inside a bound `errors` node therefore never reaches `rails:unmapped` (#181, this case only).

**Scaffold** (`scaffold.zig`), per view with a non-empty `islands`:
- `components/forms/<viewStem with '/'→'_'>[_<n>].island.tsx` (`_2`, `_3`… for a second form in one view, in source order), exact shape:
  ```tsx
  // Generated by `zigapagos migrate --from rails` from app/views/registrations/new.html.erb:1.
  // Enforcement stays server-side: this island only presents the form and the backend's
  // validation errors; the ZigBase rule on the operation decides who may submit.
  import { useState } from "@z/runtime";
  import { isZigbaseError, type FieldError } from "@zigbase/client";
  import { zb } from "../../lib/zb";
  export interface Props {}
  export default function RegistrationsNew(_props: Props) { … }
  ```
  The body renders one control per `Field` (`label` → `<label htmlFor=…>`, `email_field` → `<input type="email" name=…>`, `password_field` → `type="password"`, `text_field` → `text`, `hidden_field` → `hidden`, `text_area` → `<textarea>`, `check_box` → `checkbox`, `select` → `<select>` with its literal `<option>`s, `submit` → `<button type="submit">{label}</button>`), holds `Record<string, string>` state, and on submit calls `zb.collection("<collection>").create(body)` for `kind == .operation` on a `.create` op, `zb.collection("<c>").update(id, body)` for `.update` (id from a `hidden_field :id`, else the island renders `TODO: this form updates a record; pass its id`), `zb.send("<VERB>", "<path>", { body })` for `.custom` and consumer routes; on success `location.assign("<redirect_to>")` when set, else `setDone(true)`; on `isZigbaseError(e)` sets `errors = e.data` and renders `<ul class="errors">` of `Object.entries(errors).map(([f, e]) => f + ": " + e.message)` at the position of the bound `errors` node (or above the submit when the ERB had none).
- `lib/zb.ts`, written once when any binding exists, exactly:
  ```ts
  import { createClient, LocalAuthStore } from "@zigbase/client";
  export const zb = createClient("", { authStore: new LocalAuthStore() });
  ```
- `package.json` written when islands OR SPAs exist; `dependencies` = `"@z/runtime": "<file:runtime_path | ZIGAPAGOS_RUNTIME_DIR from Input.runtime_dir_env | file:TODO-SET-RUNTIME-PATH>"` (#179 option 1: `Input.runtime_dir_env: ?[]const u8`, read by `migrate.zig` from the environment) and, when any binding exists, `"@zigbase/client": "0.3.0"`. `tsconfig.json` alongside.
- `build.sh` gains one ` --island=<path>` per island file (sorted), before `"$@"`; `bun install` line present whenever `package.json` is.
- Redirect-after-mutation: for a bound form on route `C#new`/`C#edit` the paired action is `C#create`/`C#update` (Rails convention; else none); its first non-dynamic `RedirectInfo` resolves through `resolve.routeUrl` → `Binding.redirect_to`. The same resolution fills `Redirect.to` for `redirect` routes (`pages#old` → `"/about"`), closing Stage 2's "`to` is always null".
- Endpoint pairing: the paired non-GET route's outcome gets `endpoint = {operation_id, verb, path}` from the form's binding; a non-GET route answered directly on its own route-level finding gets its own. `RouteOutcome` gains `endpoint: ?Endpoint` (same three fields as `handoff.Endpoint`).
- Status: after acknowledgement precedence (`blocked` > `retain` > operation/`island` > deferred), a route is `migrated` iff `open_finding_ids` minus `bound_finding_ids` is empty and no `rails:unmapped` region remains (S6). Artifacts of a bound route include its island files and `lib/zb.ts`.
- `applyAcknowledgement`: an operation id / `custom:/…` choice on `RAILS_BACKEND_ENDPOINT` → binding; `backend` on `RAILS_REQUEST_TIME_STATE` → note `choice backend on RAILS_REQUEST_TIME_STATE has no converter (see #<issue>)` (A6); `public` on `RAILS_ROUTE_AUTH_GUARD` → the page is written, status unaffected, note `guarded by before_action :require_login; shipped public by decision`.

- [ ] Tests (RED first), golden bytes: a view with a bound form → the `<island>` line, the island file bytes, `lib/zb.ts` bytes, `package.json` bytes with both dependencies, `build.sh` with `--island=components/forms/registrations_new.island.tsx`; an `errors` node bound with its form → no `rails:unmapped local`; a `custom:/api/contact` binding → `zb.send("POST", "/api/contact", …)`; redirect resolution (`root` → `/`); endpoint pairing onto the POST route; `Redirect.to` filled; a form answered `retain` still writes no page (S20); `ZIGAPAGOS_RUNTIME_DIR` default (#179) and the placeholder fallback; determinism; FailingAllocator sweep reaching the new branches (the Stage 2 N2 gap).
- [ ] Commit (`convert.zig`, `scaffold.zig`, `resolve.zig`).

---

### Task 5: Auth journey scaffolds

**Files:** Modify `src/cli/rails/scaffold.zig`, `src/cli/rails/convert.zig` (the `AuthStatus` region rule).

Given an `island` decision on `RAILS_AUTH_JOURNEY` with `artifact = <C>`:
- `components/AuthForm.island.tsx` — `export interface Props { mode: "signin" | "signup" }`; signin: `await zb.collection("<C>").authWithPassword(email, password)`; signup: `await zb.collection("<C>").create({ email, password, passwordConfirm })` then `authWithPassword`; on success `location.assign("<redirect>")` where redirect = the paired `create` action's resolved redirect (`root` → `/`) else `/`; `ZigbaseError.data` rendered as in Task 4; header comment as in Task 4 (`Enforcement stays server-side…`).
- `components/AuthStatus.island.tsx` — `export interface Props {}`; renders `<span>{email} <button onClick={logout}>Sign out</button></span>` when `zb.authStore.isValid` (`email` from `zb.authStore.record`), else `<a href="<sign-in URL>">Sign in</a>` where the URL is the journey's `sessions#new` route path (`/session/new`); `logout` = `zb.collection("<C>").logout()` then `location.reload()`. The ERB region it replaced is quoted in a header comment.
- Every `form` in a journey view → `<island src="components/AuthForm.island.tsx" client:load :props='{ .mode = "signin" }'></island>` (mode `signup` when the form holds a `password_confirmation` field or the view's controller is `registrations`).
- A `request_state` region whose name is `current_user`, `signed_in?`, `logged_in?` or `user_signed_in?` answered `island` on its own `RAILS_REQUEST_TIME_STATE` finding → replaced by `<island src="components/AuthStatus.island.tsx" client:load></island>`; every finding inside the region (including a `button_to … method: :delete` `RAILS_BACKEND_ENDPOINT`) is bound by it. `island` on any other `RAILS_REQUEST_TIME_STATE` keeps the Stage 2 deferral note (Stage 4).
- Endpoints on journey routes: `sessions#create` → `{ "operation_id": "authWithPassword", "verb": "POST", "path": "/api/collections/<C>/auth-with-password" }`; `registrations#create` → `{ "operation_id": "create<Base>", … "/api/collections/<C>/records" }`; `sessions#destroy` → `{ "operation_id": "logout", "verb": "POST", "path": "/api/collections/<C>/auth-logout" }` (the first and last are `CollectionService` method names — `allAuthMethods: false` means the document has no ids for them, and the handoff says which client call is meant). Journey routes acknowledged `retain`/`blocked` behave as any other.
- `lib/zb.ts` gains `authCollection: "<C>"` in its options when a journey is bound (auto-refresh on 401).

- [ ] Tests (RED first): golden bytes for both island files; the `<island … :props='{ .mode = "signup" }'>` line for `registrations/new`; the `AuthStatus` replacement and its covered `button_to` finding; the three journey endpoints; `retain` on the journey → no islands, no `lib/zb.ts`; determinism; FailingAllocator sweep.
- [ ] Commit (`scaffold.zig`, `convert.zig`).

---

### Task 6: `--backend`, handoff, report, exit rule

**Files:** Modify `src/cli/migrate.zig` (usage, `--backend FILE`, `Input.runtime_dir_env`, handoff rows), `src/cli/rails/handoff.zig` (`RouteRow.endpoint`, `BuildInput.backend`, `statusAccounted`), `src/cli/rails/report.zig` (`## Handoff` gains `backend: <file> (<contract_version>)` / `backend: none` and an `endpoint` count line), `src/cli/rails/rails.zig` (`DecisionsInput.backend`), `tests/migrate/rails.sh` (the `rails-sample` `--target` listing is unchanged — no binding, no island — pin that; add a `--backend contract/zigbase.openapi.json -o` run whose manifest differs from the no-backend one only in `RAILS_BACKEND_ENDPOINT` `choices`).

Behaviour:
- `--backend FILE` (Rails only, with or without `--target`, like `--decisions`); read via `Io.Dir.cwd().readFileAlloc` (missing → `fatal.file`, exit 1); `backend.parse` failure → `error: <FILE> is not a ZigBase OpenAPI document: <InvalidJson|NotOpenApi3|NoPaths>` exit 1. The handoff `backend` is `{ "file": "<basename>", "contract_version": "<…>" }` or `null`; the manifest carries nothing about the file (determinism: choices only).
- `RouteRow` gains `endpoint: ?Endpoint`; `orderEndpoint` is already total. `statusAccounted`: `.backend => row.endpoint != null or row.decision != null` (A2).
- Schemas: `zig build rails-check` must stay green with NO regenerated file — `Backend`/`Endpoint` were declared in Stage 2. If the generator output changes, the plan is wrong; stop and report.
- Exit-3 stderr line unchanged.

- [ ] Tests (RED first): `isComplete` truth table gains `backend + endpoint → true`, `backend + decision → true`, `backend alone → false`; golden handoff bytes with `backend` and one `endpoint` row; `railsExitCode` unchanged; `rails.sh` pins.
- [ ] Gates incl. `rails.sh`; `rails-presentation.sh` FAILS here by design (its pins move in Task 7) — confirm the failure is a moved pin, not a crash.
- [ ] Commit.

---

### Task 7: Fixture additions + e2e

**Files:** Modify `tests/migrate/rails-presentation/` (below), `tests/migrate/rails-presentation/MIGRATION.decisions.json`, `tests/migrate/rails-presentation.sh`; create `tests/migrate/rails-presentation/backend/openapi.json`.

Fixture edits (exact):
- `config/routes.rb`: `resource :session, only: [:new, :create, :destroy], controller: "sessions"`; add `get "/feed", to: "posts#feed"` (a JSON GET).
- `app/controllers/sessions_controller.rb`: `def destroy; reset_session; redirect_to root_path; end`.
- `app/controllers/posts_controller.rb`: `before_action :require_login, only: [:index]` on line 2 (the `layout :choose` line moves to 3 — `RAILS_LAYOUT_DYNAMIC` re-pins to `L3`); `def feed; render json: Post.all; end`; a private `def require_login; redirect_to new_session_path unless session[:user_id]; end`.
- `app/views/registrations/new.html.erb`: drop the standalone `<%= @user.email %>`; add `<%= f.password_field :password_confirmation %>` after the password field (the ivar shape stays covered by `posts/index` and `posts/show`).
- `app/views/shared/_nav.html.erb`: after the sign-in link, `<% if current_user %><%= current_user.email %> <%= button_to "Sign out", session_path, method: :delete %><% end %>` on one line.
- `backend/openapi.json`: the exact bytes `zigbase openapi --data-dir <dir> --api-version 1.0.0` writes for a data dir holding auth collection `users` (`email` required, create rule `@public`) and base collection `posts` (`title` required text, `body` editor, list rule `@public`, create rule `@request.auth.id != ""`) — regenerated with the real binary as the documented developer step (`tests/migrate/rails-presentation/backend/README` names the two `zigbase collection create` commands), then checked in. Operation ids present: `listUsers createUsers viewUsers updateUsers deleteUsers listPosts createPosts viewPosts updatePosts deletePosts`.
- `MIGRATION.decisions.json`: ids re-derived from run 1 (`jq -r '.findings[].id'`, as the e2e header documents); answers: `RAILS_AUTH_JOURNEY…` → `island`, artifact `users`; the `_nav` `current_user` finding → `island`; the registration `errors` findings → `island`; `RAILS_ROUTE_AUTH_GUARD.config/routes%2Erb.L14` → `public`; `RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L<feed line>` → `listPosts`; the rest as today (help/broken/links/legacy `blocked`, `/posts` `retain`, `/posts/:id` `spa`, `/old` `retain`). The Stage 2 `RAILS_BACKEND_ENDPOINT` form answers are DELETED (journey forms no longer raise them).

The e2e proves:
1. Run 1 (no decisions, `--backend backend/openapi.json`): exit 3; exact finding ids for `RAILS_AUTH_JOURNEY.config/routes%2Erb.L<session line>`, the `_nav` `current_user` `RAILS_REQUEST_TIME_STATE` and its inner `button_to` `RAILS_BACKEND_ENDPOINT`, `RAILS_ROUTE_AUTH_GUARD.config/routes%2Erb.L14`, `RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L<feed line>` with `choices == ["listPosts","viewPosts","listUsers","viewUsers","retain","blocked"]`; `POST /registration`, `POST /session` and `DELETE /session` carry NO route-level finding (journey) while `GET /feed` does; `sessions/new` and `registrations/new` raise zero `RAILS_BACKEND_ENDPOINT`; **every page route is `open` in run 1** — the shared `_nav` partial now reads `current_user`, and a layout's findings ride on every route under it (S21), so `GET /`, `GET /about` and `GET /linked` lose their Stage 2 `migrated` pin here and regain it in run 2; `GET /feed` status `backend`, `DELETE /session` `backend`; `redirects[0].to == "/about"`; handoff `backend.file == "openapi.json"`.
2. Run 1b without `--backend`: the feed finding's `choices == ["retain","blocked"]`; the journey message ends `(pass --backend to validate the name)`.
3. Run 2 (decisions + `--backend` + `--runtime-path`): exit 0, `complete: true`; `GET /session/new`, `GET /registration/new`, `GET /`, `GET /about`, `GET /linked`, `GET /posts/:id` `migrated`; `GET /feed` `backend` with `endpoint.operation_id == "listPosts"`; `POST /session` endpoint `authWithPassword`, `DELETE /session` `logout`, `POST /registration` `createUsers`; exact run-2 listing (Stage 2's plus `components/AuthForm.island.tsx`, `components/AuthStatus.island.tsx`, `lib/zb.ts`, `content/session/new/index.smd`, `content/registration/new/index.smd`, `layouts/sessions/new.shtml`, `layouts/registrations/new.shtml`, `package.json`, `tsconfig.json`); `layouts/registrations/new.shtml` contains `<island src="components/AuthForm.island.tsx" client:load :props='{ .mode = "signup" }'></island>` and NO `rails:unmapped`; `layouts/templates/marketing.shtml` contains the `AuthStatus` island; `package.json` has `"@zigbase/client": "0.3.0"`; `build.sh` has `--island=components/AuthForm.island.tsx`.
4. Build (`bun` present): `ZIGAPAGOS_BIN=… bash build.sh` exits 0 (`bun install` fetches `@zigbase/client`; A8), `zig-out/site/session/new/index.html` exists and contains `data-z-props`, `doctor` reports `0 errors` and NO `dangling-internal-link` for `/session/new` (the Stage 2 pin flips: the route is now migrated; the remaining allowed warning set is empty — assert no `^warn ` lines at all).
5. Determinism (run 2 twice → `cmp` manifest + handoff); source untouched; no `.new` files.
6. Negative: `--backend` pointing at `Gemfile` → exit 1 with `is not a ZigBase OpenAPI document`; a decisions file answering the journey `island` with `artifact: "members"` → exit 1 naming `auth collections: users`; answering the feed finding `createPosts` (wrong verb, not offered) → exit 1 `allowed: listPosts, viewPosts, listUsers, viewUsers, retain, blocked`; a `custom:/api/feed` answer on the feed finding → exit 0 path with `endpoint.operation_id == "custom"`.
7. `RAILS_ROUTE_AUTH_GUARD` answered `public`: in run 2 `GET /posts` is `retained` (its `RAILS_PARTIAL_DYNAMIC`/`RAILS_REQUEST_TIME_STATE` answers say `retain`, and `retain` outranks `public`), its `findings[]` lists the guard id, and no page is written (S20). A separate run with those two `retain` answers deleted from a copy of the decisions file → `GET /posts` is `open` (the two findings are unanswered), its page IS written, and `note` contains `shipped public by decision` — which pins that `public` writes the page and never settles anything else.

- [ ] Write; prove discrimination (delete the journey decision → exit 3; change `"signup"` to `"signin"` in the island grep → FAIL; remove `--backend` from run 2 → the `listPosts` answer is rejected, exit 1).
- [ ] Commit (fixture files, decisions, e2e, `backend/README`).

---

### Task 8: Docs, skill mirror, changelog

**Files:** `docs/migration/rails-to-zigapagos.md` (new §18 "The backend boundary": `--backend`, what `backend.zig` reads and the coverage caveat (`allAuthMethods: false`), the three `RAILS_BACKEND_ENDPOINT` shapes and their `choices` ranking, `custom:/<path>`, the auth journey (`RAILS_AUTH_JOURNEY`, artifact, A5's detection rule, the three journey endpoints), `RAILS_ROUTE_AUTH_GUARD` and `public`, `RAILS_CONTENT_PATH_COLLISION`/`RAILS_ROUTE_PATH_UNSUPPORTED`, the island files and `lib/zb.ts` verbatim, `package.json`/`build.sh` changes, redirect-after-mutation and `redirects[].to`, the amended `complete` rule (A2), the `island` choice on `errors`/`current_user`; corrections to every Stage 2 sentence that says `backend` is always `null`, `endpoint` is always `null`, `to` is always `null`, `requires_artifact` is never `true`, `choice backend deferred to Stage 3`, and the §17 fixture walk-through (run 1/run 2 tables, the dangling-link paragraph); §11's route-scoped code list grows), byte mirror `skills/zigapagos-rails-migration/references/rails-to-zigapagos.md`, `skills/zigapagos-rails-migration/SKILL.md` (step 5 passes `--backend` when the operator has run `zigbase openapi`; step 7 explains operation-id answers and the journey artifact; the hand-off to `zigbase-zigapagos-fullstack` for the ZigBase half), `changelog.d/rails-backend.md` (Added / Changed / Known limitations: A6, Stage 4/5 items, the coverage caveat), `src/cli/migrate.zig` help text (Task 6 wrote it; verify the doc quotes it).

- [ ] Write, mirror (`cp docs/migration/rails-to-zigapagos.md skills/zigapagos-rails-migration/references/`), gates (`tests/skills/sync.sh`, `tests/branding.sh`, `tests/confidentiality.sh`, full list), commit.

---

## Pre-flight conflict scan

| pair | shared file / interface | check |
|---|---|---|
| T1/T3 | `backend.Document`, `choicesFor(gpa, ?Document, verb, resource)`, `operationFor` ↔ `findings.DeriveInput.backend` and the row table | consistent; T3 consumes only these three |
| T1/T6 | `Document.file`/`contract_version` ↔ `handoff.Backend{file, contract_version}` | consistent (same two fields, Stage 2 declared them) |
| T1/T3/T4/T6 vs `rails.zig` | all four edit `rails.zig` (`@import` line; `DeriveInput` threading; `DecisionsInput.backend`; `Discovery.before_actions`) | serialise on `rails.zig`: T1 → T2 → T3 → T6; T4/T5 do not touch it |
| T2/T3 | `controllers.BeforeAction`, `guards`, `looksLikeAuthGuard`, `ActionInfo.redirects` ↔ `DeriveInput.before_actions/actions` | consistent |
| T2/T4 | `RedirectInfo{name,args}` ↔ `resolve.routeUrl(all, stem, args)` → `Binding.redirect_to`, `Redirect.to` | consistent (`routeUrl` already takes literal args) |
| T3/T4 | finding ids for bound regions come from `ctx.findings` by `(path, line, col)` (Stage 2 mechanism); `custom:/…` choice string ↔ `Binding.kind == .custom`; `public` choice ↔ `applyAcknowledgement` | consistent; T4 must not re-derive ids |
| T3/T5 | `RAILS_AUTH_JOURNEY` id keyed on the smallest journey route line ↔ T5 looks the decision up by that id on every journey route's `open_ids` (S21 mechanism) | consistent — T4/T5 must push the journey id into each journey route's `open_ids` |
| T3 self | `Finding.choices` ownership change touches every `.choices = &…` literal in `findings.zig`, `decisions.zig` and `scaffold.zig` tests | cost noted; one helper `testChoices(gpa, …)` |
| T4/T5 | both add to `convert.Context.bindings` and `Output.islands`; both write `components/*.island.tsx`, `lib/zb.ts`, `package.json` via one emitter | T5 runs after T4 in the same tree; `lib/zb.ts` written by ONE function `writeClientLib(ctx, auth_collection: ?[]const u8)` |
| T4/T6 | `RouteOutcome.endpoint` ↔ `handoff.RouteRow.endpoint`; `Input.runtime_dir_env` set by `migrate.zig` | consistent |
| T4 self | S20 vs binding: a `retain` answer on another finding of a bound route wins (precedence) and writes no page — the island file for that route is then NOT written either (artifacts empty) | stated in Task 4 status rule |
| T5 self | `AuthStatus` sign-in URL needs the journey's `sessions#new` route path; a journey detected only by `password_field` (no `sessions` controller) has none → render no link (`null`), documented | stated |
| T6/T7 | `rails.sh` pins vs `rails-presentation.sh` pins move in different tasks | T6 confirms the presentation failure is the expected moved pin |
| T6 self | `rails-check` must not regenerate a schema; `RouteRow.endpoint` is an input row, not a wire type | stated; stop if it regenerates |
| T7 self | every fixture edit shifts `L1C<col>` ids in the edited templates; `posts_controller.rb` edit shifts `RAILS_LAYOUT_DYNAMIC` to `L3` | re-derive from run 1 as the e2e header documents; re-pin every `have_finding` |
| T7 vs Stage 2 e2e | the `/session/new` dangling-link pin and the "3 warnings" prose (`docs` §13) invert | T7 flips the pin; T8 rewrites the prose |
| T8/T3–T7 | the doc quotes exact messages, ids, file bytes | write T8 last, from the committed tree |

## Self-review

Spec coverage for Stage 3 ("Staging" item 3): `--backend` + `backend.zig` (T1, T6), endpoint findings with per-finding choices (T3), form islands + `lib/zb.ts` (T4), auth journey scaffolds (T5), validation presentation (T4's `errors` binding + `ZigbaseError.data`), `RAILS_BACKEND_ENDPOINT` for non-GET routes, forms and `link_to`/`button_to` with `method:` (T3), `backend`/`endpoint` in the handoff and the S11 reopening (T6), fixture + e2e reaching `complete` through backend answers (T7), docs + skill + changelog (T8). Spec deviations are all listed as assumptions A1–A8 with the evidence. Not in Stage 3 (deliberately): Turbo/Stimulus/React islands and the `island` choice on non-auth `RAILS_REQUEST_TIME_STATE` (Stage 4), `parity[]`, `test/parity.ts`, `journey_playwright.py`, `submit_denied`/`validation_error` replay against a running ZigBase (Stage 5), the literal `backend` choice on `RAILS_REQUEST_TIME_STATE` (A6, issue at PR time).
