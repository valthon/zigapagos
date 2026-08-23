# Rails Discovery Stage 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `zigapagos migrate <rails-app>` a route graph — recovered by a Ruby sidecar that parses `config/routes.rb` with Prism — where every route records how it was learned and whether the parser vouches for it, and everything it cannot resolve becomes a blocker.

**Architecture:** A Ruby sidecar (`runtime/sidecar/rails/`) speaks NDJSON over stdin/stdout, mirroring the existing Bun sidecar (`runtime/sidecar/render.ts` + `src/islands/sidecar.zig`). Zig spawns it, sends one request per line, and folds the result into the Stage 1 report. The rails package stays std-only; the sidecar client lives in `src/cli/rails/` and returns errors, never `fatal.*`.

**Tech Stack:** Zig 0.16, Ruby (pinned in `mise.toml`) with **Prism from stdlib — no gems**, NDJSON, bash for e2e.

**Spec:** `docs/superpowers/specs/2026-08-22-rails-source-discovery-design.md`

**Builds on:** Stage 1 (merged, `239eee9`) — `src/cli/rails/{blockers,detect,integrations,inventory,rails,report}.zig`.

## Global Constraints

- Zig **0.16.0** exactly; Ruby pinned in `mise.toml` (the repo's single source of truth for toolchains — CI consumes it via `jdx/mise-action`; do **not** add a separate setup action).
- **`zig fmt` is gated with no exceptions**: `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check` must print nothing.
- **Allocator contracts (NO_SLOP.md §2.2a)**: every allocator-taking function names its contract in a doc comment. A **wrong** label is worse than none — Stage 1 shipped one and it was caught in review. `bash scripts/check-allocator-contracts.sh` must pass.
- **`src/cli/rails/` stays std-only**: no `@import` may escape that directory, never `../../fatal.zig`. All `fatal.*` stays in `migrate.zig`.
- **The sidecar uses no gems.** Prism is Ruby stdlib from 3.3+. `require "active_support"` or any bundler dependency is a defect — the whole point of `static_ast` mode is that it works on an app that does not boot.
- **Determinism**: routes sort by `(path, verb)`; blockers by `(code, path)`; no wall-clock timestamps.
- **Source is read-only.** The sidecar reads `config/routes.rb`; it must never write into the scanned project, and must never `eval` it (see Task 3).
- **Never push to main, force-push, or merge.** Work happens on `feature/166-rails-routes`.
- Regression tests must be **verified to fail without the fix**.

---

## Licensing constraint (settled — do not relitigate)

The spike calibrated against `config/routes.rb` from eight production apps, but **six are GPL/AGPL** (mastodon, discourse, canvas-lms, redmine, openproject, diaspora) and **this repo is MIT**. Vendoring those files — or checked-in expected-output derived from them — would redistribute GPL source from an MIT repo.

Therefore, amending the spec's Stage-2 testing note:

- **In-repo fixtures are synthetic**, authored here, exercising the same constructs.
- **The oracle ships as a developer tool**, not as a CI dependency, and the corpus is fetched locally on demand. `scripts/rails-route-calibrate.sh` (Task 7) fetches into a temp dir and never writes into the repo.
- CI never needs the corpus, gems, or network.

A reference copy of the throwaway spike parser and oracle is at
`/home/valthon/.claude/jobs/6e29fb04/tmp/rails-spike-ref/` (`tier_b.rb`, `oracle.rb`). It is unversioned, uncommitted, prototype-quality — a **reference for semantics, not code to copy wholesale**. Its measured behavior: 91.6% recall at 98.2% precision on the confident subset.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `mise.toml` (modify) | Pin Ruby |
| `.github/workflows/ci.yml` (modify) | Ruby available to the rails suites |
| `runtime/sidecar/rails/inflect.rb` (create) | Gem-free singularize rule table |
| `runtime/sidecar/rails/routes.rb` (create) | Prism-based `routes.rb` parser + confidence |
| `runtime/sidecar/rails/analyze.rb` (create) | NDJSON request loop |
| `runtime/sidecar/rails/test/*.rb` (create) | Ruby-side unit tests |
| `src/cli/rails/routes.zig` (create) | Sidecar client, `Route` type, degradation blockers |
| `src/cli/rails/rails.zig` (modify) | Call route discovery from `discover` |
| `src/cli/rails/report.zig` (modify) | Render the routes section |
| `tests/migrate/rails-sample/config/routes.rb` (modify) | Exercise the supported subset + unresolvables |
| `tests/migrate/rails.sh` (modify) | e2e assertions for routes and route blockers |
| `scripts/rails-route-calibrate.sh` (create) | Developer-only corpus calibration |
| `changelog.d/rails-routes.md` (create) | Changelog fragment |

---

### Task 1: Pin Ruby and prove the toolchain reaches CI

The riskiest unknown is not the parser — it is whether Ruby with a usable Prism is actually present where the tests run. Settle that before writing anything that depends on it.

**Files:**
- Modify: `mise.toml`
- Modify: `.github/workflows/ci.yml`
- Create: `runtime/sidecar/rails/version_check.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: a pinned Ruby whose `prism` stdlib import succeeds.

- [ ] **Step 1: Write the failing check**

Create `runtime/sidecar/rails/version_check.rb`:

```ruby
# Fails loudly if the pinned Ruby cannot provide Prism from stdlib.
# `static_ast` mode is gem-free by design, so a missing stdlib Prism is a
# toolchain defect, not something to degrade around.
require "prism"
require "json"

min = Gem::Version.new("3.3.0")
if Gem::Version.new(RUBY_VERSION) < min
  warn "rails sidecar needs Ruby >= #{min} for stdlib Prism, got #{RUBY_VERSION}"
  exit 1
end
puts JSON.generate({ ruby: RUBY_VERSION, prism: Prism::VERSION })
```

- [ ] **Step 2: Run it to see the current state**

Run: `ruby runtime/sidecar/rails/version_check.rb`
Expected: prints a JSON line with both versions, exit 0. If `ruby` is not on PATH, that is exactly what Task 1 fixes — continue.

- [ ] **Step 3: Pin Ruby in mise.toml**

```toml
[tools]
zig = "0.16.0"
bun = "1.3.14"
ruby = "3.4"
```

Pin the same way the existing entries do (a `3.4` line pins the latest 3.4.x; use an exact version if the repo's convention is exact — check `bun = "1.3.14"` and match the style). Ruby must be **≥ 3.3** so Prism is stdlib.

Verify: `mise install && mise exec -- ruby runtime/sidecar/rails/version_check.rb`

- [ ] **Step 4: Make Ruby available in CI**

`ci.yml` already runs `jdx/mise-action`, which installs everything in `mise.toml` — so pinning is usually sufficient. **Verify rather than assume**: check whether the job that runs `zig build test-rails` and the shell-e2e job both go through the mise step. If a job does not, add the mise step there rather than adding a separate Ruby action.

- [ ] **Step 5: Commit**

```bash
git add -- mise.toml .github/workflows/ci.yml runtime/sidecar/rails/version_check.rb
git commit -m "Pin Ruby for the Rails route sidecar

static_ast route recovery parses config/routes.rb with Prism, which is
Ruby stdlib from 3.3 -- so the sidecar needs no gems and works on an app
that cannot boot. Pinning in mise.toml rather than a CI-only action keeps
the toolchain in the one place this repo treats as authoritative.

version_check.rb fails loudly rather than degrading: a pinned Ruby without
stdlib Prism is a toolchain defect, not a condition to work around." -- mise.toml .github/workflows/ci.yml runtime/sidecar/rails/version_check.rb
```

---

### Task 2: Gem-free inflector

The spec flagged this as the Stage 2 scoping item: the spike borrowed `ActiveSupport#singularize`, so the cost of irregular and uncountable nouns was **never measured**. `static_ast` mode has no gems, so the rules must be vendored.

Why it matters: a route declared bare inside a `resources :people` block nests under `:person_id`, not `:people_id`. Get the inflector wrong and every nested route under an irregular plural is wrong.

**Files:**
- Create: `runtime/sidecar/rails/inflect.rb`
- Create: `runtime/sidecar/rails/test/inflect_test.rb`

**Interfaces:**
- Produces: `Inflect.singularize(String) -> String`

- [ ] **Step 1: Write the failing test**

Create `runtime/sidecar/rails/test/inflect_test.rb`:

```ruby
require_relative "../inflect"

def assert_eq(expected, actual, label)
  return if expected == actual
  warn "FAIL #{label}: expected #{expected.inspect}, got #{actual.inspect}"
  $failures += 1
end
$failures = 0

# Regular
assert_eq "post",     Inflect.singularize("posts"),      "regular s"
assert_eq "category", Inflect.singularize("categories"), "ies -> y"
assert_eq "box",      Inflect.singularize("boxes"),      "xes"
assert_eq "bus",      Inflect.singularize("buses"),      "ses"
assert_eq "wish",     Inflect.singularize("wishes"),     "shes"
assert_eq "match",    Inflect.singularize("matches"),    "ches"
assert_eq "analysis", Inflect.singularize("analyses"),   "ses -> sis"

# Irregular -- these are what an s-stripping heuristic gets wrong, and each
# is a real Rails resource name.
assert_eq "person",   Inflect.singularize("people"),     "people"
assert_eq "child",    Inflect.singularize("children"),   "children"
assert_eq "man",      Inflect.singularize("men"),        "men"
assert_eq "woman",    Inflect.singularize("women"),      "women"

# Uncountable -- singular == plural; stripping the s corrupts the param.
assert_eq "series",   Inflect.singularize("series"),     "series"
assert_eq "news",     Inflect.singularize("news"),       "news"
assert_eq "equipment",Inflect.singularize("equipment"),  "equipment"

# Already singular must be left alone.
assert_eq "profile",  Inflect.singularize("profile"),    "already singular"

abort "#{$failures} inflect failure(s)" if $failures > 0
puts "PASS: inflect_test.rb"
```

- [ ] **Step 2: Run to verify it fails**

Run: `ruby runtime/sidecar/rails/test/inflect_test.rb`
Expected: FAIL — `cannot load such file -- inflect`

- [ ] **Step 3: Implement**

Create `runtime/sidecar/rails/inflect.rb` implementing `Inflect.singularize`. Required behavior, in precedence order:

1. **Uncountable** (return unchanged): `series`, `news`, `equipment`, `information`, `rice`, `money`, `species`, `fish`, `sheep`, `police`, `deer`.
2. **Irregular** (explicit table, both directions of the pair only as needed here): `people→person`, `children→child`, `men→man`, `women→woman`, `feet→foot`, `teeth→tooth`, `mice→mouse`, `geese→goose`, `oxen→ox`.
3. **Suffix rules**, longest-match-first: `analyses→analysis` (`ses`→`sis` for the `-lysis`/`-sis` family), `ies→y`, `ves→fe`/`f`, `(x|ch|ss|sh)es→\1`, `ses→s`, `s→` (but not `ss`).
4. Otherwise return unchanged.

Match case-insensitively on the lookup but preserve the input's case for the returned stem. Keep it a plain module with no requires — it must load standalone.

- [ ] **Step 4: Run to verify it passes**

Run: `ruby runtime/sidecar/rails/test/inflect_test.rb`
Expected: `PASS: inflect_test.rb`

- [ ] **Step 5: Cross-check against the real inflector (developer step, not CI)**

If the machine happens to have ActiveSupport, spot-check divergence:

```bash
ruby -e 'require "active_support/all"; require_relative "runtime/sidecar/rails/inflect"; \
  %w[posts categories people children series analyses boxes buses wishes matches statuses].each { |w| \
    a = w.singularize; b = Inflect.singularize(w); \
    puts "#{w}: activesupport=#{a} ours=#{b}#{a == b ? "" : "  <-- DIVERGES"}" }' 2>/dev/null || echo "activesupport absent; skipped"
```

Record the output in your report. Divergence on a word Rails apps actually use as a resource name is a finding; divergence on an exotic noun is not. **CI must not depend on this** — it is calibration, not a gate.

- [ ] **Step 6: Commit**

```bash
git add -- runtime/sidecar/rails/inflect.rb runtime/sidecar/rails/test/inflect_test.rb
git commit -m "Vendor a gem-free inflector for the route sidecar

Routes declared bare inside a resources block nest under the parent's
:<singular>_id, so deriving that param needs Rails' pluralization rules.
static_ast mode is gem-free by design -- it has to work on an app that
cannot boot -- so ActiveSupport is unavailable and the rules are vendored.

The spike borrowed ActiveSupport#singularize and therefore never measured
the irregular and uncountable cases; those are exactly where an s-stripping
heuristic fails, and each tested word is a real Rails resource name.
resources :people nests under :person_id, not :people_id, and an
uncountable like :series must not lose its s at all." -- runtime/sidecar/rails/inflect.rb runtime/sidecar/rails/test/inflect_test.rb
```

---

### Task 3: The Prism route parser

**Files:**
- Create: `runtime/sidecar/rails/routes.rb`
- Create: `runtime/sidecar/rails/test/routes_test.rb`

**Interfaces:**
- Consumes: `Inflect.singularize` (Task 2).
- Produces: `RailsRoutes.parse(source, path:) -> { routes: [...], unresolved: [...] }` where each route is
  `{verb:, path:, controller:, action:, name:, line:, certain:}` and each unresolved entry is
  `{code:, detail:, line:}`.

**This parser never evaluates Ruby.** It walks a Prism AST. `eval`-ing an untrusted `routes.rb` would execute arbitrary code from the migrated project — the source tree is read-only *and* untrusted input.

- [ ] **Step 1: Write the failing test**

Create `runtime/sidecar/rails/test/routes_test.rb` covering the DSL subset below. Each case is a literal `routes.rb` string and its expected `(verb, path)` set — no fixtures on disk, so the test is fast and hermetic:

```ruby
require_relative "../routes"

$failures = 0
def check(label, src, expected_pairs, expect_unresolved: [])
  got = RailsRoutes.parse(src, path: "config/routes.rb")
  pairs = got[:routes].map { |r| "#{r[:verb]} #{r[:path]}" }.sort.uniq
  want = expected_pairs.sort.uniq
  if pairs != want
    warn "FAIL #{label}\n  missing: #{(want - pairs).inspect}\n  extra:   #{(pairs - want).inspect}"
    $failures += 1
  end
  codes = got[:unresolved].map { |u| u[:code] }.sort.uniq
  unless expect_unresolved.sort.uniq == codes
    warn "FAIL #{label} (unresolved): expected #{expect_unresolved.inspect}, got #{codes.inspect}"
    $failures += 1
  end
end

check "root", 'Rails.application.routes.draw do
  root "home#index"
end', ["GET /"]

check "verb with rocket", 'Rails.application.routes.draw do
  get "/about" => "pages#about"
end', ["GET /about"]

check "verb with to:", 'Rails.application.routes.draw do
  post "/signup", to: "users#create"
end', ["POST /signup"]

# resources generates 8 routes: update is both PATCH and PUT.
check "resources", 'Rails.application.routes.draw do
  resources :posts
end', [
  "GET /posts", "POST /posts", "GET /posts/new", "GET /posts/:id/edit",
  "GET /posts/:id", "PATCH /posts/:id", "PUT /posts/:id", "DELETE /posts/:id",
]

check "singular resource has no index and no :id", 'Rails.application.routes.draw do
  resource :profile
end', [
  "POST /profile", "GET /profile/new", "GET /profile/edit",
  "GET /profile", "PATCH /profile", "PUT /profile", "DELETE /profile",
]

check "only: filters", 'Rails.application.routes.draw do
  resources :posts, only: [:index, :show]
end', ["GET /posts", "GET /posts/:id"]

check "namespace prefixes path and controller", 'Rails.application.routes.draw do
  namespace :admin do
    resources :users, only: [:index]
  end
end', ["GET /admin/users"]

check "member and collection", 'Rails.application.routes.draw do
  resources :posts, only: [] do
    member { post :publish }
    collection { get :archived }
  end
end', ["POST /posts/:id/publish", "GET /posts/archived"]

# A bare route inside a resources block nests under the parent param, and
# the param uses the SINGULAR -- irregular plurals included.
check "bare nested route uses the singular parent param", 'Rails.application.routes.draw do
  resources :people, only: [] do
    get :dossier
  end
end', ["GET /people/:person_id/dossier"]

check "dynamic path is unresolved, not guessed", 'Rails.application.routes.draw do
  get "/#{ENV["PREFIX"]}/x", to: "a#b"
end', [], expect_unresolved: ["RAILS_ROUTE_DYNAMIC_PATH"]

check "engine mount is unresolved", 'Rails.application.routes.draw do
  mount Sidekiq::Web => "/sidekiq"
end', [], expect_unresolved: ["RAILS_ROUTE_ENGINE_MOUNT"]

check "loop-generated routes are uncertain, not silently dropped", 'Rails.application.routes.draw do
  %w[a b].each do |n|
    get "/\#{n}", to: "x#y"
  end
end', [], expect_unresolved: ["RAILS_ROUTE_LOOP"]

abort "#{$failures} routes failure(s)" if $failures > 0
puts "PASS: routes_test.rb"
```

- [ ] **Step 2: Run to verify it fails**

Run: `ruby runtime/sidecar/rails/test/routes_test.rb`
Expected: FAIL — `cannot load such file -- routes`

- [ ] **Step 3: Implement the parser**

Create `runtime/sidecar/rails/routes.rb`. Use `require "prism"` and walk `Prism.parse(source).value`.

The reference implementation at `/home/valthon/.claude/jobs/6e29fb04/tmp/rails-spike-ref/tier_b.rb` measured 91.6% recall / 98.2% precision on the confident subset. Treat it as a semantics reference; it is prototype-quality and lacks the error handling, line numbers, and code taxonomy this task requires.

**DSL subset to support** (each maps to a `when` in a call-node dispatch):

| Construct | Semantics |
| --- | --- |
| `draw` (no receiver) | descend |
| `namespace :x` | path prefix `/x` **and** controller prefix `x/` |
| `scope path:/module:/"str"` | path and/or controller prefix independently |
| `constraints` / `defaults` / `with_options` | transparent — descend, no prefix |
| `resources :x` | the 8 RESTful routes; honour `only:`, `except:`, `path:`, `controller:` |
| `resource :x` | singular: no index, no `:id` |
| nested block after `resources` | bare routes nest under `/<x>/:<singular>_id` |
| `member` / `collection` / `new` | `/:id/…`, `/…`, `/new/…` under the resource |
| `get`/`post`/`put`/`patch`/`delete`/`match` | both `"p" => "c#a"` and `"p", to: "c#a"`; `match` honours `via:` |
| `root` | `GET` at the current scope |
| `concern` / `concerns` | define and expand |

**Confidence and unresolved codes.** A route is `certain: false` when produced inside a construct the parser cannot evaluate. Emit an `unresolved` entry with a stable code and the source line:

- `RAILS_ROUTE_DYNAMIC_PATH` — interpolated or computed path
- `RAILS_ROUTE_LOOP` — inside `each`/`map`/any unknown block
- `RAILS_ROUTE_CONDITIONAL` — inside `if`/`unless`
- `RAILS_ROUTE_ENGINE_MOUNT` — `mount`
- `RAILS_ROUTE_CUSTOM_ROUTER` — `draw` with a **constant** receiver (`ApiRouteSet::V1.draw(self)`); note `X.routes.draw` is the genuine route set and must NOT be flagged
- `RAILS_ROUTE_EXTERNAL_FILE` — `draw(:name)` referencing `config/routes/<name>.rb`
- `RAILS_ROUTE_GEM_GENERATED` — `devise_for` and similar

The custom-router distinction is subtle and cost the spike a 40-point precision swing: dispatch on the receiver's **node type**, not the method name.

**Robustness:** a Prism parse failure returns `{routes: [], unresolved: [{code: "RAILS_ROUTES_PARSE_ERROR", …}]}` rather than raising. The sidecar must never crash on a malformed `routes.rb`.

- [ ] **Step 4: Run to verify it passes**

Run: `ruby runtime/sidecar/rails/test/routes_test.rb`
Expected: `PASS: routes_test.rb`

- [ ] **Step 5: Commit**

```bash
git add -- runtime/sidecar/rails/routes.rb runtime/sidecar/rails/test/routes_test.rb
git commit -m "Recover Rails routes from a Prism AST

config/routes.rb is a Ruby DSL, not data, so the route table is recovered
by walking a Prism AST -- never by evaluating the file. Evaluating it would
execute arbitrary code from the migrated project, which is both read-only
and untrusted input.

A spike measured this approach at 91.6% recall and 98.2% precision on the
subset the parser vouches for, against ground truth expanded through a real
ActionDispatch route set. That gap between the two numbers is the design:
the parser marks what it cannot evaluate rather than guessing, so
interpolated paths, loops, conditionals, engine mounts and app-defined
routers become coded unresolved entries instead of plausible-looking
fabrications.

The custom-router case dispatches on the receiver's node type: X.routes.draw
is the genuine route set, while a bare constant receiver like
ApiRouteSet::V1.draw is an app-defined router applying a prefix the parser
cannot know. Conflating them cost the spike 40 points of precision." -- runtime/sidecar/rails/routes.rb runtime/sidecar/rails/test/routes_test.rb
```

---

### Task 4: The NDJSON sidecar

**Files:**
- Create: `runtime/sidecar/rails/analyze.rb`
- Create: `runtime/sidecar/rails/test/analyze_test.rb`

**Interfaces:**
- Consumes: `RailsRoutes.parse` (Task 3).
- Produces: a process reading one JSON request per line on stdin, writing one JSON response per line on stdout.

**Protocol** (mirrors `runtime/sidecar/render.ts`; read it first):

Request: `{"op":"routes","root":"/abs/path/to/app"}`
Response: `{"ok":true,"routes":[…],"unresolved":[…]}` or `{"ok":false,"error":"…"}`

- [ ] **Step 1: Write the failing test**

Create `runtime/sidecar/rails/test/analyze_test.rb` that spawns the sidecar as a subprocess, writes a request line, and reads a response line — exercising the real protocol, not the parser directly:

```ruby
require "json"
require "open3"
require "tmpdir"

$failures = 0
def check(label, cond)
  return if cond
  warn "FAIL #{label}"; $failures += 1
end

script = File.expand_path("../analyze.rb", __dir__)

Dir.mktmpdir do |dir|
  Dir.mkdir(File.join(dir, "config"))
  File.write(File.join(dir, "config/routes.rb"), <<~RB)
    Rails.application.routes.draw do
      root "home#index"
      resources :posts, only: [:index]
    end
  RB

  Open3.popen3("ruby", script) do |stdin, stdout, _stderr, _thr|
    stdin.puts JSON.generate({ op: "routes", root: dir })
    stdin.flush
    res = JSON.parse(stdout.gets, symbolize_names: true)
    check("ok", res[:ok] == true)
    paths = res[:routes].map { |r| "#{r[:verb]} #{r[:path]}" }.sort
    check("routes", paths == ["GET /", "GET /posts"])

    # A second request on the SAME process: the sidecar is persistent.
    stdin.puts JSON.generate({ op: "routes", root: dir })
    stdin.flush
    check("second request answered", JSON.parse(stdout.gets, symbolize_names: true)[:ok] == true)

    # A missing routes.rb is a structured answer, not a crash.
    stdin.puts JSON.generate({ op: "routes", root: File.join(dir, "nope") })
    stdin.flush
    res3 = JSON.parse(stdout.gets, symbolize_names: true)
    check("missing routes.rb answered structurally", res3.key?(:ok))

    # Malformed input must not kill the process.
    stdin.puts "{not json"
    stdin.flush
    res4 = JSON.parse(stdout.gets, symbolize_names: true)
    check("malformed request answered", res4[:ok] == false)

    stdin.close
  end
end

abort "#{$failures} analyze failure(s)" if $failures > 0
puts "PASS: analyze_test.rb"
```

- [ ] **Step 2: Run to verify it fails**

Run: `ruby runtime/sidecar/rails/test/analyze_test.rb`
Expected: FAIL — the script does not exist.

- [ ] **Step 3: Implement**

Create `runtime/sidecar/rails/analyze.rb`: read lines from stdin until EOF; parse each as JSON; dispatch on `op`; write exactly one JSON line per request and flush. A malformed request line answers `{"ok":false,...}` and **continues** — one bad line must never kill a persistent process mid-build. Unknown `op` answers `{"ok":false}`. Never write anything to stdout except response lines (diagnostics go to stderr), or the protocol desynchronizes.

- [ ] **Step 4: Run to verify it passes**

Run: `ruby runtime/sidecar/rails/test/analyze_test.rb`
Expected: `PASS: analyze_test.rb`

- [ ] **Step 5: Commit**

```bash
git add -- runtime/sidecar/rails/analyze.rb runtime/sidecar/rails/test/analyze_test.rb
git commit -m "Add the Rails sidecar's NDJSON request loop

One persistent process per migrate run, one JSON request per line, matching
the Bun sidecar's protocol shape so the Zig client side looks familiar.

Two failure modes get structured answers rather than a crash: a malformed
request line and a missing routes.rb. A sidecar that dies on one bad line
takes the whole run with it, and stdout carries the protocol -- so
diagnostics go to stderr, because a stray print desynchronizes every
subsequent response." -- runtime/sidecar/rails/analyze.rb runtime/sidecar/rails/test/analyze_test.rb
```

---

### Task 5: The Zig sidecar client

**Files:**
- Create: `src/cli/rails/routes.zig`
- Modify: `src/cli/rails/rails.zig`

**Interfaces:**
- Consumes: `blockers.Blocker` / `blockers.append` (Stage 1).
- Produces:
  - `pub const Route = struct { verb: []const u8, path: []const u8, controller: ?[]const u8, action: ?[]const u8, name: ?[]const u8, certain: bool, origin: Origin }`
  - `pub const Origin = enum { static_ast, actiondispatch, routes_import }`
  - `pub const Result = struct { routes: []Route, mode: []const u8 }` — `mode` is a static literal (`"static_ast"` / `"none"`) and is never freed; `routes` is owned
  - `pub fn discoverRoutes(io: Io, gpa: Allocator, root: Io.Dir, root_path: []const u8, blocker_list: *std.ArrayListUnmanaged(blockers.Blocker)) Allocator.Error!Result`
  - `pub fn freeRoutes(gpa: Allocator, routes: []Route) void`
  - `fn decodeResponse(gpa: Allocator, line: []const u8, src_path: []const u8, blocker_list: *std.ArrayListUnmanaged(blockers.Blocker)) Allocator.Error![]Route` — the unit-testable half; `discoverRoutes` wraps it with the spawn

Note `report.Input` already carries `blockers` (Stage 1), so Task 6 adds only `routes` and `route_mode`; `route_mode` is `Result.mode` passed straight through.

- [ ] **Step 1: Write the failing test**

Add to `src/cli/rails/routes.zig` a test that parses a canned sidecar **response line** into `[]Route` — the JSON decoding is the part worth unit-testing without spawning a process:

```zig
test "a sidecar response decodes into routes, preserving certainty" {
    const line =
        \\{"ok":true,"routes":[
        \\{"verb":"GET","path":"/","controller":"home","action":"index","name":"root","certain":true},
        \\{"verb":"GET","path":"/x","controller":null,"action":null,"name":null,"certain":false}],
        \\"unresolved":[{"code":"RAILS_ROUTE_LOOP","detail":"each","line":12}]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.items);
    defer blocker_list.deinit(std.testing.allocator);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 2), res.len);
    try std.testing.expectEqualStrings("GET", res[0].verb);
    try std.testing.expect(res[0].certain);
    try std.testing.expect(!res[1].certain);
    // Unresolved entries become blockers, not silence.
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_ROUTE_LOOP", blocker_list.items[0].code);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/cli/rails/routes.zig`
Expected: FAIL — `decodeResponse` undefined.

- [ ] **Step 3: Implement**

Write `decodeResponse` using `std.json` (Stage 1's `integrations.zig` already uses `std.json.parseFromSlice` against the pinned toolchain — follow that, and free the parsed tree). Then the spawn path, modelled on `src/islands/sidecar.zig`:

- Locate Ruby: prefer `ZIGAPAGOS_RUBY`, else `ruby` on PATH.
- Locate the script via `ZIGAPAGOS_RUNTIME_DIR` (same mechanism the Bun sidecar uses) + `sidecar/rails/analyze.rb`.
- Spawn, write one request line, read one response line, close.

**Degradation is the contract, not an afterthought.** Each of these appends a blocker with `integrity = false` and returns zero routes — none is fatal, because a Rails app with no route graph is still a useful inventory (Stage 1 shipped exactly that):

> **Corrected post-implementation (whole-branch review, I-6):** this section originally said `integrity = true` and the commit message below originally said "so the run still exits non-zero." Both were reversed mid-Stage-2, and the code that shipped is `integrity = false` / exit 0 — `Blocker.integrity` means *the inventory itself* is untrustworthy, and none of these four conditions touch the inventory `inventory.walk` already produced; only the separate, optional route graph is absent. `src/cli/rails/routes.zig`'s module doc has the full reasoning, including the `tests/migrate/rails.sh` regression that caught the `integrity = true` version being wrong. Left uncorrected below (not deleted) so this is legible as "what was planned, then reversed," not silently rewritten history.

| Condition | Blocker code |
| --- | --- |
| Ruby not found | `RAILS_RUBY_UNAVAILABLE` |
| runtime dir / script not found | `RAILS_SIDECAR_MISSING` |
| spawn fails, non-zero exit, or bad response | `RAILS_SIDECAR_FAILED` |
| `config/routes.rb` absent | `RAILS_ROUTES_MISSING` |

Bound the wait so a hung sidecar cannot hang the build.

Doc-comment the allocator contract on every allocating function. `discoverRoutes` is **contract 2 (owned-result)**; note which `Route` fields are owned versus borrowed, since Stage 1's review caught exactly that class of mistake.

- [ ] **Step 4: Run to verify it passes**

Run: `zig test src/cli/rails/routes.zig` → PASS
Run: `zig build test-rails` → PASS (add `_ = routes;` to `rails.zig`'s test block so the new suite is reached)

- [ ] **Step 5: Call it from `discover`**

In `rails.zig`'s `discover`, call `discoverRoutes` after the inventory, threading the same `blocker_list`, and carry the routes into the report input. Free with `defer`.

- [ ] **Step 6: Verify**

```bash
zig build test-rails && zig build check && zig build check -Dsingle-threaded
git ls-files -z '*.zig' | xargs -0 -r zig fmt --check
bash scripts/check-allocator-contracts.sh
```

- [ ] **Step 7: Commit**

```bash
git add -- src/cli/rails/routes.zig src/cli/rails/rails.zig
git commit -m "Spawn the Rails route sidecar from the discovery pass

Mirrors the Bun sidecar's shape: locate the interpreter, locate the script
through ZIGAPAGOS_RUNTIME_DIR, one request line, one response line.

Every way this can fail degrades to a blocker rather than a fatal, because
an app with no route graph is still a useful inventory -- which is exactly
what Stage 1 shipped. A missing Ruby, a missing script, a dead sidecar and
a missing routes.rb are four distinct codes, so the report says which
happened instead of just showing no routes. All four are NON-integrity
blockers (integrity means the INVENTORY is untrustworthy, not that the
separate route graph is absent), so the run still exits 0.

Routes the parser does not vouch for arrive with certain=false and their
unresolved entries become blockers, so an unrecoverable construct is
visible in the worklist rather than absent from it." -- src/cli/rails/routes.zig src/cli/rails/rails.zig
```

---

### Task 6: Render routes in the report

**Files:**
- Modify: `src/cli/rails/report.zig`

**Interfaces:**
- Consumes: `routes.Route`.
- Produces: a `## Routes` section; `Input` gains `routes: []const routes.Route` and `route_mode: []const u8`.

- [ ] **Step 1: Write the failing test**

Add to `report.zig`:

```zig
test "routes render with their origin, and uncertain ones are marked" {
    const rs = [_]routes.Route{
        .{ .verb = "GET", .path = "/", .controller = "home", .action = "index",
           .name = "root", .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/x", .controller = null, .action = null,
           .name = null, .certain = false, .origin = .static_ast },
    };
    const md = try build(std.testing.allocator, .{
        .app_path = "app", .entries = &.{}, .integrations = &.{},
        .blockers = &.{}, .routes = &rs, .route_mode = "static_ast",
    });
    defer std.testing.allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "## Routes") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "GET /") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "home#index") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "static_ast") != null);
    // The uncertain route must be visibly distinguished, not silently equal.
    try std.testing.expect(std.mem.indexOf(u8, md, "uncertain") != null);
}

test "a run with no routes says why rather than showing an empty section" {
    const md = try build(std.testing.allocator, .{
        .app_path = "app", .entries = &.{}, .integrations = &.{},
        .blockers = &.{}, .routes = &.{}, .route_mode = "none",
    });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "No routes were recovered") != null);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/cli/rails/report.zig`
Expected: FAIL — `Input` has no `routes` field.

- [ ] **Step 3: Implement**

Add the section after the inventory table. Sort by `(path, verb)`. Render each route with verb, path, `controller#action` when known, and mark `certain == false` rows explicitly. State the `route_mode` once. When `routes.len == 0`, print a sentence naming why (the blocker list carries the cause) rather than an empty table — an empty section reads as "this app has no routes".

Update `rails.zig`'s call site for the new `Input` fields.

- [ ] **Step 4: Verify**

Run: `zig test src/cli/rails/report.zig` → PASS; `zig build test-rails` → PASS

- [ ] **Step 5: Commit**

```bash
git add -- src/cli/rails/report.zig src/cli/rails/rails.zig
git commit -m "Render recovered routes in the worklist

Each route carries how it was learned and whether the parser vouches for
it, because a route recovered from a construct the parser could not
evaluate is not the same claim as one read straight out of the DSL, and a
worklist that presents them identically invites the reader to trust both
equally.

Zero routes prints why rather than an empty section: an empty Routes
heading reads as 'this app has no routes', which is never the true reason." -- src/cli/rails/report.zig src/cli/rails/rails.zig
```

---

### Task 7: Fixture, e2e, calibration script, changelog

**Files:**
- Modify: `tests/migrate/rails-sample/config/routes.rb`
- Modify: `tests/migrate/rails.sh`
- Create: `scripts/rails-route-calibrate.sh`
- Create: `changelog.d/rails-routes.md`

- [ ] **Step 1: Extend the fixture's routes.rb**

Rewrite `tests/migrate/rails-sample/config/routes.rb` to exercise both halves — what the parser recovers and what it refuses:

```ruby
Rails.application.routes.draw do
  root "posts#index"
  resources :posts do
    member { post :publish }
  end
  namespace :admin do
    resources :users, only: [:index]
  end
  # Deliberately unresolvable: proves the parser reports rather than guesses.
  mount Sidekiq::Web => "/sidekiq"
end
```

- [ ] **Step 2: Add e2e assertions**

In `tests/migrate/rails.sh`, after the inventory assertions:

```bash
# --- routes ------------------------------------------------------------------
grep -q "## Routes" "$WORK/one.md" || fail "no Routes section"
grep -q "GET /posts" "$WORK/one.md" || fail "resources :posts did not expand"
grep -q "POST /posts/:id/publish" "$WORK/one.md" || fail "member route missing"
grep -q "GET /admin/users" "$WORK/one.md" || fail "namespaced route missing"
grep -q "static_ast" "$WORK/one.md" || fail "route mode not stated"
# The engine mount must be a blocker, never a silently-dropped route.
grep -q "RAILS_ROUTE_ENGINE_MOUNT" "$WORK/one.md" || fail "mount not reported as a blocker"
```

Guard the whole block on Ruby being available, and **skip loudly** when it is not:

```bash
if command -v ruby >/dev/null 2>&1; then
  ...assertions...
else
  echo "SKIP: route assertions (no ruby on PATH)"
fi
```

- [ ] **Step 3: Verify the assertions genuinely bite**

Temporarily make `RailsRoutes.parse` return `{routes: [], unresolved: []}`, rebuild, run `bash tests/migrate/rails.sh`, and confirm it fails **on the route assertions specifically**. Restore, confirm PASS, then `git diff --exit-code` to prove nothing was left edited. Record both outputs.

- [ ] **Step 4: Add the calibration script**

Create `scripts/rails-route-calibrate.sh` — a **developer tool, never run by CI**. It fetches a corpus of real `routes.rb` files into a temp directory, runs the parser over them, and reports recall/precision against an oracle expansion when `actionpack` is available.

It must: work only in `mktemp -d`, never write into the repo, state clearly in a header comment that the fetched files are third-party and **must not be committed** (this repo is MIT; much of the corpus is GPL/AGPL), and degrade with a clear message when the network or `actionpack` is absent.

- [ ] **Step 5: Changelog**

Create `changelog.d/rails-routes.md`. Be precise about what is and is not delivered: routes are recovered by static AST parsing with per-route confidence; unresolvable constructs are reported as blockers; `actiondispatch` and `routes_import` modes are **not** implemented yet; classification (content/island/SPA/backend/redirect) is Stage 3.

- [ ] **Step 6: Full gate run**

```bash
zig build test-rails && zig build test-migrate && zig build test-init
zig build check && zig build check -Dsingle-threaded
bash tests/migrate/rails.sh && bash tests/migrate/frameworks.sh
git ls-files -z '*.zig' | xargs -0 -r zig fmt --check
bash scripts/check-allocator-contracts.sh
for t in runtime/sidecar/rails/test/*.rb; do ruby "$t" || exit 1; done
```

Also verify from the tracked tree:
```bash
T=$(mktemp -d); git archive HEAD tests/migrate/rails-sample | tar -x -C "$T"
./zig-out/bin/zigapagos migrate "$T/tests/migrate/rails-sample" -o "$T/out.md"; cat "$T/out.md"
```

- [ ] **Step 7: Commit**

```bash
git add -- tests/migrate/rails-sample/config/routes.rb tests/migrate/rails.sh scripts/rails-route-calibrate.sh changelog.d/rails-routes.md
git commit -m "Pin route recovery end to end

The fixture's routes.rb exercises both halves of the contract: constructs
the parser expands (root, resources, member, namespace) and one it must
refuse (an engine mount). Asserting only the first half would let a parser
that silently drops what it cannot handle pass green.

The corpus the spike calibrated against cannot live here -- six of its
eight projects are GPL or AGPL and this repo is MIT -- so the calibration
script fetches into a temp directory, never the repo, and CI depends on
neither the corpus nor the network nor any gem." -- tests/migrate/rails-sample/config/routes.rb tests/migrate/rails.sh scripts/rails-route-calibrate.sh changelog.d/rails-routes.md
```

---

## Stage 2 exit criteria

- `zig build test-rails` passes, including the new routes suite.
- Every `runtime/sidecar/rails/test/*.rb` passes under the pinned Ruby.
- `bash tests/migrate/rails.sh` passes, and its route assertions were seen to fail with the parser stubbed out.
- `migrate tests/migrate/rails-sample` emits a `## Routes` section with the expanded routes, states `static_ast`, and reports the engine mount as a blocker.
- With Ruby removed from PATH, the same command still emits the Stage 1 inventory, reports `RAILS_RUBY_UNAVAILABLE`, and exits **0** (non-integrity: the inventory itself is unaffected; only the optional route graph is absent — see the I-6 correction above Task 5's degradation table).
- `check`, `check -Dsingle-threaded`, `zig fmt --check`, and the allocator gate are clean.
- No gem is required at any point; no third-party `routes.rb` is committed.

## Not in this plan

Stage 3 (the classifier), Stage 4 (the versioned manifest and its drift gate), and Stage 5 (`--target` assembly, docs, and the `skills/` mirror) get their own plans. The `actiondispatch` and `routes_import` origins are declared in the schema but not implemented here — `static_ast` is the mode that works on an app that cannot boot, and it is the one Stage 2 delivers.
