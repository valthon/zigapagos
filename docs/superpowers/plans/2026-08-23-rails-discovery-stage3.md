# Rails Discovery Stage 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classify every recovered route as build-time `content`, an `island`, an `spa` route, `backend` responsibility, a `redirect`, or honestly `unresolved` — with the evidence for each decision carried alongside it.

**Architecture:** Classification joins three inputs that already exist separately — Stage 2's routes (verb, controller, action), Stage 1's inventory (which templates exist), and two new inspections: controller-action *shape* from a Prism AST (a new sidecar op) and template *content* markers (a Zig text scan). The classifier itself is a pure function so every rule is unit-testable without a filesystem or a sidecar.

**Tech Stack:** Zig 0.16, Ruby 3.4.10 with **Prism from stdlib — no gems**, NDJSON, bash for e2e.

**Spec:** `docs/superpowers/specs/2026-08-22-rails-source-discovery-design.md`

**Builds on:** Stage 1 (merged, `239eee9`) and Stage 2 (merged, `427d564`).

## Global Constraints

- Zig **0.16.0**; Ruby pinned in `mise.toml`. CI consumes both via `jdx/mise-action`.
- **`zig fmt` is gated with no exceptions**: `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check` must print nothing.
- **`src/cli/rails/` stays std-only**: no `@import` may escape that directory, never `../../fatal.zig`. All `fatal.*` stays in `migrate.zig`.
- **The sidecar uses no gems.** Prism is stdlib. `static_ast` mode exists to work on an app that *cannot boot*.
- **The sidecar never evaluates the source.** Controllers are read-only *and untrusted* input, exactly like `routes.rb`.
- **Allocator contracts (NO_SLOP.md §2.2a)**: every allocator-taking function names its contract. A **wrong** label is worse than none. `check-allocator-contracts.sh` must pass.
- **Determinism**: byte-identical output for identical input; no wall-clock timestamps.
- **Degradation exits 0.** Classification failing is not an inventory-integrity failure. If controller analysis is unavailable, routes classify as far as the remaining evidence allows and the shortfall is a non-integrity blocker.
- **Never push to main, force-push, or merge.** Work happens on `feature/166-rails-classify`.
- Regression tests must be **verified to fail without the fix** — and verified by *mutation*, not by "the suite passed".

---

## The asymmetry that drives every rule

`content` is the **only** classification that asserts something positive: *this page is safely static*. Every other outcome is a deferral (`unresolved`), a handoff (`backend`, `redirect`), or a narrower claim (`island`, `spa`).

That makes the error costs wildly asymmetric:

| Mistake | Cost |
| --- | --- |
| Falsely `unresolved` | a human looks at a route that was fine — wasted attention |
| Falsely `content` | the migration builds a **static page for a page that is not static** — a silently broken site |

So every rule that *prevents* reaching `content` must over-detect, and `content` must be reachable only when every negative test has failed. The spec's ordering already does this; do not reorder it for elegance.

Concretely: rule 5's request-time markers deliberately produce false positives. A view mentioning `params` in a comment still classifies `unresolved`. That is correct behavior, not a defect to tune away.

---

## Where each inspection happens (decided — say so if you disagree)

- **Rules 2 and 3 ask structural questions about Ruby** — "does this action exist?", "is its body *only* a `redirect_to`?", "does it render JSON?" Those need a Prism AST, so the **sidecar gains a `controllers` op**. Approximating them with regex is precisely the fragile-parsing mistake Stage 2 exists to avoid.
- **Rules 5 and 6 are text markers in templates** — `current_user`, `data-controller=`. A **Zig text scan** handles those: std-only, no round-trip per template, and biased to over-detect where that is the safe direction.

## File Structure

| File | Responsibility |
| --- | --- |
| `runtime/sidecar/rails/controllers.rb` (create) | Prism walk of `app/controllers/**` → per-action shape |
| `runtime/sidecar/rails/test/controllers_test.rb` (create) | Ruby-side unit tests |
| `runtime/sidecar/rails/analyze.rb` (modify) | Add the `controllers` op |
| `src/cli/rails/controllers.zig` (create) | Sidecar client + `ActionInfo` |
| `src/cli/rails/template_scan.zig` (create) | Pure template marker scan |
| `src/cli/rails/classify.zig` (create) | The pure rule table + `candidates[]` |
| `src/cli/rails/rails.zig` (modify) | Join routes + inventory + the two inspections |
| `src/cli/rails/report.zig` (modify) | Render classification per route |
| `tests/migrate/rails-sample/**` (modify) | Fixture exercising every rule |
| `tests/migrate/rails.sh` (modify) | e2e assertions |
| `changelog.d/rails-classify.md` (create) | Changelog fragment |

---

### Task 1: Controller-action shape from a Prism AST

**Files:**
- Create: `runtime/sidecar/rails/controllers.rb`
- Create: `runtime/sidecar/rails/test/controllers_test.rb`

**Interfaces:**
- Consumes: nothing (a sibling of `routes.rb`; do **not** couple them).
- Produces: `RailsControllers.parse(source, path:) -> { controller: String|nil, actions: {name => {only_redirect:, renders_json:, line:}}, unresolved: [...] }`

- [ ] **Step 1: Write the failing test**

Create `runtime/sidecar/rails/test/controllers_test.rb`. Each case is a literal controller source — no fixtures on disk, so it is fast and hermetic:

```ruby
require_relative "../controllers"

$failures = 0
def check(label, src, expected)
  got = RailsControllers.parse(src, path: "app/controllers/x_controller.rb")
  actual = got[:actions].transform_values { |v| v.reject { |k, _| k == :line } }
  return if actual == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  $failures += 1
end

check "a plain action is neither a redirect nor json",
  'class PostsController < ApplicationController
     def index; @posts = Post.all; end
   end',
  { "index" => { only_redirect: false, renders_json: false } }

check "an action whose whole body is redirect_to",
  'class SessionsController < ApplicationController
     def create
       redirect_to root_path
     end
   end',
  { "create" => { only_redirect: true, renders_json: false } }

# A redirect alongside other work is NOT a pure redirect: the other work may
# be the thing that matters, so claiming `redirect` would lose it.
check "a redirect with other statements is not a pure redirect",
  'class SessionsController < ApplicationController
     def create
       Audit.record!(current_user)
       redirect_to root_path
     end
   end',
  { "create" => { only_redirect: false, renders_json: false } }

check "render json marks the action",
  'class ApiController < ApplicationController
     def show; render json: { ok: true }; end
   end',
  { "show" => { only_redirect: false, renders_json: true } }

check "private methods are not actions",
  'class PostsController < ApplicationController
     def index; end
     private
     def set_post; end
   end',
  { "index" => { only_redirect: false, renders_json: false } }

check "an empty controller has no actions",
  'class BareController < ApplicationController
   end', {}

abort "#{$failures} controllers failure(s)" if $failures > 0
puts "PASS: controllers_test.rb"
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- ruby runtime/sidecar/rails/test/controllers_test.rb`
Expected: FAIL — `cannot load such file -- controllers`

- [ ] **Step 3: Implement**

Create `runtime/sidecar/rails/controllers.rb`. `require "prism"` only — **never evaluate the source**, for the same reason `routes.rb` does not.

Required behavior:
- Walk the class body; each public `def` is an action. `private`/`protected` switches visibility for the rest of the body — anything after is not an action.
- `only_redirect` is true when the body is **exactly one** statement and it is a `redirect_to` call. A redirect among other statements is **false**: the other work may be what matters, and claiming `redirect` would discard it.
- `renders_json` is true when any `render` call carries a `json:` keyword argument.
- Record each action's line.
- A Prism parse failure returns a structured result with `RAILS_CONTROLLER_PARSE_ERROR` in `unresolved` — it must never raise. The sidecar is persistent; an exception kills the run.
- Anything you cannot determine is simply absent from the flags — do **not** guess. An action whose body you cannot interpret is `only_redirect: false, renders_json: false`, which routes it toward the more conservative classification downstream.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- ruby runtime/sidecar/rails/test/controllers_test.rb` → `PASS`

- [ ] **Step 5: Commit**

```bash
git add -- runtime/sidecar/rails/controllers.rb runtime/sidecar/rails/test/controllers_test.rb
git commit -m "Read controller-action shape from a Prism AST

Classification needs three structural facts about each action -- does it
exist, is its body only a redirect, does it render JSON -- and all three are
questions about Ruby code, not text. Regex would answer them plausibly and
wrongly, which is the mistake the routes parser exists to avoid, so this
walks a Prism AST and never evaluates the file: controllers are read-only
AND untrusted input.

A redirect_to among other statements is deliberately NOT a pure redirect.
The other statements may be the thing that matters, and classifying the
route as a redirect would silently discard them." -- runtime/sidecar/rails/controllers.rb runtime/sidecar/rails/test/controllers_test.rb
```

---

### Task 2: The `controllers` sidecar op and its Zig client

**Files:**
- Modify: `runtime/sidecar/rails/analyze.rb`
- Create: `src/cli/rails/controllers.zig`

**Interfaces:**
- Consumes: `RailsControllers.parse` (Task 1); `blockers.Blocker` (Stage 1).
- Produces:
  - `pub const ActionInfo = struct { controller: []const u8, action: []const u8, only_redirect: bool, renders_json: bool }`
  - `pub fn discoverControllers(io, gpa, root, root_path, blocker_list, environ_map) Allocator.Error![]ActionInfo`
  - `pub fn freeActions(gpa, actions) void`
  - `pub fn find(actions: []const ActionInfo, controller: []const u8, action: []const u8) ?ActionInfo`

- [ ] **Step 1: Extend the sidecar**

Add `when "controllers"` to `analyze.rb`'s dispatch, mirroring the `routes` op exactly: walk `app/controllers/**/*.rb` under the request's `root`, parse each, and answer one JSON line:

`{"ok":true,"actions":[{"controller":"posts","action":"index","only_redirect":false,"renders_json":false,"line":2}],"unresolved":[…]}`

The `controller` value must be the Rails controller **path key** — `admin/users` for `app/controllers/admin/users_controller.rb` — because that is what a route's `controller` field holds. Derive it from the file path, not the class name: a class name cannot express nesting reliably without evaluating the file.

Every property Task 4 of Stage 2 established still holds: one response line per request, structured answers to bad input, stdout is protocol-only, signals re-raised past the broad rescue.

Extend `runtime/sidecar/rails/test/analyze_test.rb` with a `controllers` round-trip, and a case where `app/controllers/` is absent (answer structurally; do not crash).

- [ ] **Step 2: Write the failing Zig test**

In `src/cli/rails/controllers.zig`, test `decodeResponse` against a canned response line — the JSON half, testable without spawning. Follow `routes.zig`'s existing shape, including its ownership idiom (`blockers.free(gpa, list.toOwnedSlice(gpa))`, **not** `free(items)` + `deinit()`, which double-frees).

- [ ] **Step 3: Implement the client**

Model it on `src/cli/rails/routes.zig`: same spawn helper, same `Environ.Map` parameter (no libc), same absolute-`root` contract, same bounded wait.

**Degradation, all `integrity = false`, all returning zero actions:**

| Condition | Blocker code |
| --- | --- |
| sidecar unavailable / failed | `RAILS_CONTROLLERS_UNAVAILABLE` |
| `app/controllers/` absent | `RAILS_CONTROLLERS_MISSING` |

Zero actions is not a failure — it means rules 2 and 3 cannot fire, and routes fall through to the remaining evidence. Classification degrades in the conservative direction on its own.

**Efficiency note:** the sidecar is persistent, so issue the `controllers` request on the **same** process as `routes` rather than spawning twice. If the existing client's shape makes that awkward, say so in your report rather than spawning a second sidecar silently.

- [ ] **Step 4: Verify**

`mise exec -- ruby runtime/sidecar/rails/test/analyze_test.rb`, `zig build test-rails`, `zig build check`, `check -Dsingle-threaded`, `zig fmt --check`, `check-allocator-contracts.sh`.

- [ ] **Step 5: Commit**

```bash
git add -- runtime/sidecar/rails/analyze.rb runtime/sidecar/rails/test/analyze_test.rb src/cli/rails/controllers.zig
git commit -m "Serve controller-action shape over the existing sidecar

Reuses the persistent process rather than spawning a second one: the
sidecar already exists for routes, and one process answering two ops is
strictly cheaper than two answering one each.

The controller key is derived from the FILE PATH, not the class name --
app/controllers/admin/users_controller.rb is the key admin/users, which is
what a route's controller field holds. A class name cannot express that
nesting without evaluating the file, which this deliberately never does.

Missing controllers degrade to a non-integrity blocker and zero actions:
rules that depend on action shape simply cannot fire, and every route falls
through to the more conservative classification." -- runtime/sidecar/rails/analyze.rb runtime/sidecar/rails/test/analyze_test.rb src/cli/rails/controllers.zig
```

---

### Task 3: Template marker scan

**Files:**
- Create: `src/cli/rails/template_scan.zig`

**Interfaces:**
- Produces:
  - `pub const Markers = struct { request_state: ?[]const u8 = null, stimulus: bool = false, component_root: ?[]const u8 = null }`
  - `pub fn scan(src: []const u8) Markers` — contract 3 (caller-buffer): allocates nothing; `request_state` and `component_root` borrow from `src`.

- [ ] **Step 1: Write the failing test**

```zig
test "request-time state markers are detected, and name themselves" {
    try std.testing.expect(scan("<p><%= current_user.name %></p>").request_state != null);
    try std.testing.expectEqualStrings("current_user", scan("<%= current_user %>").request_state.?);
    try std.testing.expectEqualStrings("session", scan("<% session[:x] %>").request_state.?);
    try std.testing.expectEqualStrings("flash", scan("<%= flash[:notice] %>").request_state.?);
    try std.testing.expectEqualStrings("cookies", scan("<% cookies[:a] %>").request_state.?);
    try std.testing.expectEqualStrings("params", scan("<%= params[:id] %>").request_state.?);
}

test "a static template has no markers" {
    const m = scan("<h1>Posts</h1>\n<%= render partial: \"post\" %>\n");
    try std.testing.expect(m.request_state == null);
    try std.testing.expect(!m.stimulus);
    try std.testing.expect(m.component_root == null);
}

test "over-detection is deliberate: a marker in a comment still counts" {
    // Rule 5 routes to `unresolved`, which costs a human a look. Missing a
    // marker routes to `content`, which builds a static page for a page that
    // is not static. The false positive is the safe direction.
    try std.testing.expect(scan("<%# current_user is not used here %>").request_state != null);
}

test "stimulus and component roots are distinguished" {
    try std.testing.expect(scan("<div data-controller=\"reveal\"></div>").stimulus);
    try std.testing.expectEqualStrings(
        "react_component",
        scan("<%= react_component(\"Chart\") %>").component_root.?,
    );
    try std.testing.expectEqualStrings(
        "data-react-class",
        scan("<div data-react-class=\"Chart\"></div>").component_root.?,
    );
    // A bare mount div is NOT evidence -- every app has a <div id="app">.
    try std.testing.expect(scan("<div id=\"app\"></div>").component_root == null);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- zig test src/cli/rails/template_scan.zig` → FAIL, `scan` undefined.

- [ ] **Step 3: Implement**

A substring scan over the raw template text. Markers:

- **request state**: `current_user`, `session`, `flash`, `cookies`, `params`, `signed_in?`, `logged_in?`. Return the **first** match by table order so the evidence names itself.
- **stimulus**: `data-controller=`.
- **component root**: `react_component(`, `data-react-class`, `data-vue-component`. Return which one matched.

Deliberately **not** detected: a bare `<div id="app">` or `<div id="root">`. Every Rails app has one; treating it as evidence would classify half an app as islands. Comment that decision — it looks like an omission otherwise.

Do not attempt to strip ERB comments or string literals. The over-detection is the point (see the test's comment), and stripping would need a real ERB parse for a result that is *less* safe.

- [ ] **Step 4: Verify** — `mise exec -- zig test src/cli/rails/template_scan.zig` → PASS

- [ ] **Step 5: Commit**

```bash
git add -- src/cli/rails/template_scan.zig
git commit -m "Scan templates for the markers classification turns on

A text scan, not a parse, and deliberately biased to over-detect. Rule 5
routes a match to `unresolved`, which costs a human one look; missing a
match routes to `content`, which builds a static page for a page that is
not static. The false positive is the cheap direction, so a marker inside
an ERB comment still counts.

A bare <div id=\"app\"> is deliberately NOT component-root evidence. Every
Rails layout has one, and treating it as a mount point would classify half
an application as islands on no evidence at all." -- src/cli/rails/template_scan.zig
```

---

### Task 4: The classifier

**Files:**
- Create: `src/cli/rails/classify.zig`

**Interfaces:**
- Consumes: `routes.Route`, `inventory.Entry`/`Engine`, `controllers.ActionInfo`, `template_scan.Markers`.
- Produces:
  - `pub const Class = enum { content, island, spa, backend, redirect, unresolved }`
  - `pub const Candidate = struct { target: []const u8, evidence: []const u8 }`
  - `pub const Verdict = struct { class: Class, reason: []const u8, candidates: []const Candidate }`
  - `pub const ViewRef = struct { path: []const u8, engine: inventory.Engine, markers: template_scan.Markers }`
  - `pub const Input = struct { verb: []const u8, view: ?ViewRef = null, action: ?controllers.ActionInfo = null }`
  - `pub fn classify(in: Input) Verdict` — **pure, contract 3**. `reason` and every `candidate` string is a static literal, never allocated, so `Verdict` owns nothing and needs no free.

`controllers.ActionInfo` (Task 2) must give **defaults to every field** so a test can write `.action = .{ .renders_json = true }` without restating the rest. If that conflicts with how the sidecar client builds them, say so rather than making the tests verbose.

- [ ] **Step 1: Write the failing test**

One test per rule, each asserting the class **and** the reason, so a rule firing for the wrong cause is caught:

```zig
fn v(in: Input) Verdict { return classify(in); }

test "rule 1: a non-GET verb is backend regardless of anything else" {
    const got = v(.{ .verb = "POST", .view = null, .action = null });
    try std.testing.expectEqual(Class.backend, got.class);
    try std.testing.expectEqualStrings("non-GET verb is a backend responsibility", got.reason);
}

test "rule 2: no view and no action is backend" {
    const got = v(.{ .verb = "GET", .view = null, .action = null });
    try std.testing.expectEqual(Class.backend, got.class);
}

test "rule 2: a json-rendering action is backend even with a view present" {
    const got = v(.{ .verb = "GET", .view = erbView(.{}), .action = .{ .renders_json = true } });
    try std.testing.expectEqual(Class.backend, got.class);
}

test "rule 3: a pure redirect is a redirect" {
    const got = v(.{ .verb = "GET", .view = null, .action = .{ .only_redirect = true } });
    try std.testing.expectEqual(Class.redirect, got.class);
}

test "rule 4: an unsupported engine is unresolved, never converted" {
    const got = v(.{ .verb = "GET", .view = hamlView(.{}), .action = .{} });
    try std.testing.expectEqual(Class.unresolved, got.class);
}

test "rule 5 beats rule 6: request state wins over an island marker" {
    // An interactive page that also reads session state is NOT an island we
    // can build -- the state has to be resolved first (that is #167's job).
    const got = v(.{ .verb = "GET", .action = .{},
        .view = erbView(.{ .request_state = "session", .stimulus = true }) });
    try std.testing.expectEqual(Class.unresolved, got.class);
}

test "rule 6: a stimulus marker makes it an island" {
    const got = v(.{ .verb = "GET", .action = .{}, .view = erbView(.{ .stimulus = true }) });
    try std.testing.expectEqual(Class.island, got.class);
}

test "rule 7: a static-safe view is content, and content is the last resort" {
    const got = v(.{ .verb = "GET", .action = .{}, .view = erbView(.{}) });
    try std.testing.expectEqual(Class.content, got.class);
    try std.testing.expectEqualStrings("no request-time state or interactivity found", got.reason);
}

test "spa is never assigned without positive evidence" {
    // Nothing in Stage 3 proves a component owns routing, so an island root
    // stays `island`. Claiming `spa` would be exactly the false confidence
    // the issue warns against.
    const got = v(.{ .verb = "GET", .action = .{},
        .view = erbView(.{ .component_root = "react_component" }) });
    try std.testing.expect(got.class != Class.spa);
    try std.testing.expectEqual(Class.island, got.class);
}
```

Write `erbView`/`hamlView` as small test helpers so each case reads as one line.

- [ ] **Step 2: Run to verify it fails** — `mise exec -- zig test src/cli/rails/classify.zig` → FAIL

- [ ] **Step 3: Implement**

The spec's rule table, first-match-wins, in exactly the spec's order. Every branch sets a `reason` naming the rule that fired.

`candidates[]` records the viable zigapagos shapes with their evidence, per the spec's addition — for a `content` verdict, one candidate `content`; for `island`, `island` plus `content` if the only interactivity is Stimulus (which may be portable); for `unresolved`, none.

**`spa` is unreachable in Stage 3, on purpose.** Nothing here proves a component root *owns routing* — that needs resolving the component's module and its imports. Keep the enum value (the spec and manifest declare it), leave a comment saying why nothing assigns it yet, and let the test above pin that. Do not invent a heuristic to make the value look used.

- [ ] **Step 4: Verify** — `mise exec -- zig test src/cli/rails/classify.zig` → PASS

- [ ] **Step 5: Prove the rules bite by mutation**

For rules 5 and 7 — the two that decide whether `content` is reached — swap their order in the rule chain, confirm the rule-5 test goes RED, restore, confirm GREEN. Record both. This is the check that the ordering is load-bearing rather than incidental. (This branch has had four "test passes for the wrong reason" defects; order-dependence is exactly the kind of thing a per-rule test can miss.)

- [ ] **Step 6: Commit**

```bash
git add -- src/cli/rails/classify.zig
git commit -m "Classify each route, with the reason it was classified

The spec's rule table, first match wins, in the spec's order -- the order is
load-bearing, not stylistic. `content` is the only verdict that asserts
something positive (this page is safely static); every other outcome is a
deferral or a handoff. So `content` sits last and is reachable only when
every negative test has failed, and request-time state beats an island
marker: an interactive page that also reads session state is not an island
we can build.

Every verdict carries the reason the rule fired, so a route classified for
the wrong cause is visible rather than merely wrong.

`spa` is deliberately unreachable here. Proving a component root owns
routing needs its module and imports resolved, which Stage 3 does not do,
and inventing a heuristic to make the enum value look used is exactly the
false confidence issue #166 warns against." -- src/cli/rails/classify.zig
```

---

### Task 5: Join the inputs and render the verdict

**Files:**
- Modify: `src/cli/rails/rails.zig`, `src/cli/rails/report.zig`

- [ ] **Step 1: Resolve each route to its view**

In `rails.zig`, for each route with a `controller` and `action`, find the inventory entry whose path is `app/views/<controller>/<action>.<ext>` and whose kind is `view` or `mailer_view`. Prefer an `.html.*` match. **A `.json.jbuilder`-only match is an API response**, which rule 2 should treat as backend — note that in the code, since it looks like a missing view otherwise.

Read matched templates and run `template_scan.scan` on each. Read failures are non-fatal: no markers means the classifier falls through to its own conservative default, and the read failure becomes a non-integrity blocker.

- [ ] **Step 2: Write the failing report test**

```zig
test "each route renders with its classification and reason" {
    // …one content route, one unresolved route…
    try std.testing.expect(std.mem.indexOf(u8, md, "- `GET /posts` → `posts#index` — content\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "unresolved") != null);
}

test "a classification summary counts every class" {
    // The table must account for every route, so a class silently dropped
    // shows up as a count mismatch -- the same property the inventory table has.
}
```

Assert **exact rendered lines**, not document-level substrings. This branch has shipped four assertions that passed for the wrong reason; the worst checked that a document contained a word its own intro sentence already contained.

- [ ] **Step 3: Render**

Extend the `## Routes` section so each line carries its class, and add a short classification summary table above it (one row per class, counts summing to the route total). Keep the existing `certain`/`uncertain` marker — a route can be uncertain *and* classified, and those are independent claims.

Sort and determinism rules are unchanged.

- [ ] **Step 4: Verify** — `zig build test-rails`, `bash tests/migrate/rails.sh`, all gates.

- [ ] **Step 5: Commit** with a message explaining the join and the jbuilder case.

---

### Task 6: Fixture, e2e, changelog

**Files:**
- Modify: `tests/migrate/rails-sample/**`, `tests/migrate/rails.sh`
- Create: `changelog.d/rails-classify.md`

- [ ] **Step 1: Extend the fixture to exercise every rule**

The current fixture has one controller with one action and three views. It cannot reach most rules. Add — keeping it minimal, one file per rule:

- a controller action that is **only** `redirect_to` (rule 3)
- an action that `render json:` (rule 2)
- a view with `<%= current_user %>` (rule 5)
- a view with `data-controller="reveal"` (rule 6)
- a plainly static view (rule 7) — `posts/index.html.erb` already qualifies
- the existing `legacy.html.haml` (rule 4)

State the expected classification for **every** route in the fixture in your report, and make the e2e assert each one.

- [ ] **Step 2: e2e assertions**

Assert the classification summary counts and at least one exact rendered line per class reached. Guard on Ruby with a loud `SKIP:`, following the existing pattern.

- [ ] **Step 3: Verify the assertions bite**

Force `classify` to return `.unresolved` unconditionally, rebuild, confirm the e2e fails **on the classification assertions specifically**, restore, confirm PASS, then `git diff --exit-code`. Record both outputs.

- [ ] **Step 4: Changelog**

`changelog.d/rails-classify.md`, honest about scope: routes are classified with per-route evidence; `spa` is declared but never assigned in this stage; classification depends on controller analysis that degrades to a blocker when unavailable; the versioned manifest and `--strict` remain Stage 4; `--target` assembly is Stage 5. Do not imply a complete migration path.

- [ ] **Step 5: Full gates + tracked-tree check**

```
zig build test-rails && zig build test-init && zig build check && zig build check -Dsingle-threaded
bash tests/migrate/rails.sh && bash tests/migrate/frameworks.sh
git ls-files -z '*.zig' | xargs -0 -r zig fmt --check
bash scripts/check-allocator-contracts.sh
for t in runtime/sidecar/rails/test/*.rb; do mise exec -- ruby "$t" || exit 1; done
mise exec -- ruby runtime/sidecar/rails/version_check.rb
```

Plus, because a fixture file silently gitignored passes locally and fails in CI (that exact defect bit Stage 1 via `.gitignore`'s bare `public` rule):

```bash
T=$(mktemp -d); git archive HEAD tests/migrate/rails-sample | tar -x -C "$T"
ZIGAPAGOS_RUNTIME_DIR="$PWD/runtime" ./zig-out/bin/zigapagos migrate "$T/tests/migrate/rails-sample" -o "$T/out.md"; cat "$T/out.md"
```

**Ignore `zig build test-migrate`** — it fails on local `.zig-cache` corruption, proven environmental (passes against a fresh `--cache-dir`; no branch since Stage 1 has touched that suite).

Note this shell is zsh with `noclobber`: overwrite with `>|`, never bare `>`, or the redirect aborts, the command never runs, and you validate a stale file.

- [ ] **Step 6: Commit**

---

## Stage 3 exit criteria

- Every route in the fixture carries a classification and a reason.
- `content` is reached only when every negative rule has failed, and rule ordering is proven load-bearing by mutation.
- `spa` is assigned to nothing, deliberately, and a test pins that.
- Controller analysis unavailable → non-integrity blocker, exit 0, routes still classify on remaining evidence.
- All gates green; the Ruby suites run in CI (they do, since Stage 2).
- The e2e's classification assertions were seen to fail with `classify` stubbed.

## Not in this plan

Stage 4 (the versioned manifest, its JSON Schema, the drift gate, and `--strict`) and Stage 5 (`--target` assembly, `docs/migration/rails-to-zigapagos.md`, the `skills/` mirror) get their own plans. Resolving request-time state — everything rule 5 defers — is issue #167, not this stage.
