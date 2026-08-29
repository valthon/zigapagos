# Rails Presentation Stage 1 — Template Front End Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Rails discovery manifest say exactly which template fragments a converter would refuse — by parsing every route-reachable ERB template in the Ruby sidecar, naming routes, reading controller `layout` declarations, and emitting a new top-level `findings[]` array — without writing any target output yet.

**Architecture:** The Ruby sidecar (`runtime/sidecar/rails/`) gains an Erubi-grammar ERB scanner (`erb.rb`), a Prism-based fragment classifier with inline i18n resolution (`templates.rb`, `i18n.rb`), route naming in `routes.rb`, and a `layouts` array in the `controllers` op. The Zig side (`src/cli/rails/`) gains `fragments.zig` (the `templates` op client, one node stream per template) and `findings.zig` (stable ids, choices, derivation from node streams), wires both into `rails.discover`, and extends the `/1` manifest with `findings[]` (schema regenerated under the existing `rails-check` gate). A new fixture app `tests/migrate/rails-presentation/` pins every finding code this stage emits.

**Tech Stack:** Zig 0.16.0 (std-only inside `src/cli/rails/`), Ruby 3.4 stdlib only (`prism`, `json`, `yaml`), bash e2e under `tests/migrate/`, `jq`.

**Spec:** `docs/superpowers/specs/2026-08-29-rails-presentation-migration-design.md` — sections "Sidecar extension", "Fragment vocabulary", "Findings, decisions, handoff", "Blocker and finding codes", "Staging" item 1.

## Global Constraints

- `src/cli/rails/*.zig` is std-only: no `@import` may escape that directory (`rails.zig` is the `test-rails` root). `rails.zig`'s `test { std.testing.refAllDecls(@This()); }` is how sibling files' tests run — a new file must be imported from `rails.zig` to be tested.
- Every allocator-taking function states its NO_SLOP §2.2a contract in its doc comment (1 self-freeing, 2 owned-result, 3 caller-buffer, 4 arena-scoped).
- `Blocker.code` and `Finding.code` are always static string literals (never freed); a wire code the Zig side does not recognise degrades to a fallback code, never a drop.
- Manifest output is byte-identical for identical input; no absolute paths on the wire; every array a consumer reads is sorted by a total order.
- Ruby sidecar: stdlib only (`require "prism"`, `"json"`, `"yaml"`), stdout carries protocol lines only, every failure answers `{"ok":false,...}` and keeps serving.
- Schema `/1` has not shipped, so adding required manifest fields is allowed; regenerate with `zig build rails-schema` and keep `zig build rails-check` green.
- Every regression test must be shown to fail without its fix before it counts.
- Formatting gate: `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check`.
- Commit with explicit paths — `git commit -F - -- <paths>` — because the index is shared across worktrees. Commit messages explain the defect and the reasoning.
- One spec amendment lands with this plan (Task 0): i18n resolution is folded into the `templates` op's response rather than a separate `i18n` op, because `sidecar_client.queryOnce` closes stdin after exactly one request and a separate op would cost a second Ruby spawn plus a key round-trip.

---

### Task 0: Amend the spec's op table (i18n folded into `templates`) — DONE with the plan commit

**Files:**
- Modify: `docs/superpowers/specs/2026-08-29-rails-presentation-migration-design.md` (the "Sidecar extension" table)

- [x] **Step 1: Replace the `i18n` row and note the reason**

Find the table row beginning `| \`i18n\`` and replace it with:

```markdown
| `templates` (i18n) | `locale` is read from `config/application.rb`'s literal `config.i18n.default_locale`, else `en` | each `i18n` node carries `{key, value}` or `{key, missing: true}`, resolved from `config/locales/**/*.yml` with `yaml` (Psych, a default gem shipped with Ruby — no bundler). Folded into `templates` rather than a separate op because `sidecar_client.queryOnce` closes stdin after one request; a separate op would be a second Ruby spawn plus a key round-trip |
```

Also change `i18n via sidecar ◄───────────────┼──────  i18n.rb       config/locales/*.yml` in the architecture diagram to `                                     │        i18n.rb       config/locales/*.yml` (i18n.rb is a helper of templates.rb, not its own client).

- [ ] **Step 2: Commit**

```bash
git commit -F - -- docs/superpowers/specs/2026-08-29-rails-presentation-migration-design.md <<'EOF'
Fold i18n resolution into the templates op (#167 Stage 1 plan)

sidecar_client.queryOnce closes stdin after exactly one request, so every
op is its own Ruby spawn. A separate `i18n` op would mean a second spawn
plus shipping the keys the templates op just found back across the wire.
templates.rb resolves keys inline instead; i18n.rb stays a helper module.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 1: Route names in `routes.rb`

**Files:**
- Modify: `runtime/sidecar/rails/routes.rb` (`Scope`, `emit`, `resources_call`, `member_collection_new_call`, `namespace_call`, `scope_call`, `verb_call`, `root_call`)
- Test: `runtime/sidecar/rails/test/routes_test.rb`

**Interfaces:**
- Produces: every emitted route hash gains a real `name:` (String or nil). Rules: `resources :posts` → `posts` (index/create), `post` (show/update/destroy), `new_post`, `edit_post`; `resource :profile` → `profile`, `new_profile`, `edit_profile`; `member { post :publish }` → `publish_post`; `collection { get :recent }` → `recent_posts`; `new { get :preview }` → `preview_new_post`; `namespace :admin` prefixes `admin_`; `scope as: "x"` prefixes `x_`; `as:` on a verb call or on `resources` overrides the derived base; `root` → `root`; a bare verb call with no `as:` and a literal path derives the name Rails would (`get "/about"` → `about`; `get "/posts/old"` → `posts_old`; a path with `:param` segments or `*glob` → nil). Name is nil whenever the route is emitted under `@uncertain` (the spec: uncertain routes keep `name: null`).
- Zig side needs no change: `routes.zig:468` already dupes `name` when present.

- [ ] **Step 1: Write the failing tests**

Append to `runtime/sidecar/rails/test/routes_test.rb`, before the final `abort` line:

```ruby
# Task 1 (#167 Stage 1): route names. `check` never inspects :name, so this
# compares the exact (verb, path, name) triple -- a name attached to the
# wrong route is the bug that matters, not a missing name.
def check_names(label, src, expected)
  got = RailsRoutes.parse(src, path: "config/routes.rb")
  actual = got[:routes].map { |r| [r[:verb], r[:path], r[:name]] }.sort_by(&:inspect)
  want = expected.sort_by(&:inspect)
  return if actual == want
  warn "FAIL #{label}\n  missing: #{(want - actual).inspect}\n  extra:   #{(actual - want).inspect}"
  $failures += 1
end

check_names "resources derive the seven Rails helper names",
            "Rails.application.routes.draw do\n  resources :posts\nend\n",
            [
              ["GET", "/posts", "posts"], ["POST", "/posts", "posts"],
              ["GET", "/posts/new", "new_post"], ["GET", "/posts/:id/edit", "edit_post"],
              ["GET", "/posts/:id", "post"], ["PATCH", "/posts/:id", "post"],
              ["PUT", "/posts/:id", "post"], ["DELETE", "/posts/:id", "post"],
            ]

check_names "singular resource names",
            "Rails.application.routes.draw do\n  resource :profile\nend\n",
            [
              ["POST", "/profile", "profile"], ["GET", "/profile/new", "new_profile"],
              ["GET", "/profile/edit", "edit_profile"], ["GET", "/profile", "profile"],
              ["PATCH", "/profile", "profile"], ["PUT", "/profile", "profile"],
              ["DELETE", "/profile", "profile"],
            ]

check_names "member/collection/new routes inside resources",
            "Rails.application.routes.draw do\n" \
            "  resources :posts, only: [] do\n" \
            "    member { post :publish }\n" \
            "    collection { get :recent }\n" \
            "    new { get :preview }\n" \
            "  end\n" \
            "end\n",
            [
              ["POST", "/posts/:id/publish", "publish_post"],
              ["GET", "/posts/recent", "recent_posts"],
              ["GET", "/posts/new/preview", "preview_new_post"],
            ]

check_names "namespace prefixes, scope as: prefixes, as: overrides, root",
            "Rails.application.routes.draw do\n" \
            "  root \"home#index\"\n" \
            "  namespace :admin do\n" \
            "    resources :users, only: [:index]\n" \
            "  end\n" \
            "  scope as: \"legacy\" do\n" \
            "    get \"/old\", to: \"pages#old\"\n" \
            "  end\n" \
            "  get \"/about\", to: \"pages#about\"\n" \
            "  get \"/posts/old\", to: \"posts#old\"\n" \
            "  get \"/help\", to: \"pages#help\", as: :support\n" \
            "  resources :articles, only: [:index], as: :stories\n" \
            "end\n",
            [
              ["GET", "/", "root"],
              ["GET", "/admin/users", "admin_users"],
              ["GET", "/old", "legacy_old"],
              ["GET", "/about", "about"],
              ["GET", "/posts/old", "posts_old"],
              ["GET", "/help", "support"],
              ["GET", "/articles", "stories"],
            ]

check_names "a dynamic path segment or a glob yields no derived name; an uncertain route never has one",
            "Rails.application.routes.draw do\n" \
            "  get \"/posts/:id/raw\", to: \"posts#raw\"\n" \
            "  get \"/files/*path\", to: \"files#show\"\n" \
            "  if ENV[\"X\"]\n" \
            "    get \"/maybe\", to: \"pages#maybe\"\n" \
            "  end\n" \
            "end\n",
            [
              ["GET", "/posts/:id/raw", nil],
              ["GET", "/files/*path", nil],
              ["GET", "/maybe", nil],
            ]
```

- [ ] **Step 2: Run to verify it fails**

Run: `ruby runtime/sidecar/rails/test/routes_test.rb`
Expected: `FAIL resources derive the seven Rails helper names` … and `abort` with a non-zero count (every name is currently `nil`).

- [ ] **Step 3: Implement naming**

In `runtime/sidecar/rails/routes.rb`:

1. Extend `Scope` with an `as_prefix` (the accumulated `namespace`/`scope as:` name prefix, e.g. `"admin"`):

```ruby
  Scope = Struct.new(:path, :module_, :as_prefix) do
    def child(path: self.path, module_: self.module_, as_prefix: self.as_prefix)
      Scope.new(path, module_, as_prefix)
    end
  end
```

Update the initial scope construction (search for `Scope.new(` in `parse`/`Walker#initialize`) to pass `""` for `as_prefix`.

2. Extend `ResourceCtx` with the singular and plural name stems:

```ruby
  ResourceCtx = Struct.new(:base, :ctrl, :singular, :name_singular, :name_plural, keyword_init: true)
```

3. Change `emit` to take a name and null it under `@uncertain`:

```ruby
    def emit(verb, path, ctrl, action, line, name: nil)
      p = path.nil? || path.empty? ? "/" : path
      p = p == "/" ? "/" : p.chomp("/")
      p = "/" if p.empty?
      @routes << {
        verb: verb,
        path: p,
        controller: ctrl,
        action: action,
        # Task 1 (#167 Stage 1): the Rails route-helper name (`posts` for
        # `posts_path`), derived by the same rules Rails' Mapper applies.
        # nil under @uncertain on purpose: a helper resolving to a route
        # this parser is not vouching for must become a finding
        # (RAILS_ROUTE_HELPER_UNKNOWN), not a confident URL.
        name: @uncertain ? nil : name,
        line: line,
        certain: !@uncertain,
      }
    end

    # Joins the scope's as_prefix and a route's own name stem with `_`,
    # returning nil when the stem is nil (a route Rails itself would not
    # name, e.g. a bare path with a dynamic segment and no as:).
    def prefixed_name(sc, stem)
      return nil if stem.nil? || stem.empty?
      sc.as_prefix.empty? ? stem : "#{sc.as_prefix}_#{stem}"
    end

    # Rails' Mapper#name_for_action derives a helper name from a literal
    # path when no as: is given: segments joined by `_`, with any dynamic
    # (`:id`) or glob (`*path`) segment making the route nameless.
    def derived_name_from_path(seg)
      return nil if seg.nil?
      parts = seg.split("/").reject(&:empty?)
      return nil if parts.empty?
      return nil if parts.any? { |s| s.start_with?(":", "*") || s.include?("(") }
      parts.join("_").tr("-", "_")
    end
```

4. In `namespace_call`, add `as_prefix:` to the child scope: `as_prefix: sc.as_prefix.empty? ? seg : "#{sc.as_prefix}_#{seg}"`.

5. In `scope_call`, after computing `new_module`, read `as:`:

```ruby
      new_as = sc.as_prefix
      if opts["as"]
        as_lit = literal(opts["as"])
        if as_lit.nil?
          mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node), "scope as: is not a literal")
          return
        end
        new_as = sc.as_prefix.empty? ? as_lit : "#{sc.as_prefix}_#{as_lit}"
      end
      walk(blk, sc.child(path: new_path, module_: new_module, as_prefix: new_as), res_ctx)
```

6. In `resources_call`, inside `pos.each do |p|` after `ctrl = ...`, compute the stems and pass names into `emit`. `as:` on `resources` replaces the plural stem (`as: :stories` → plural `stories`, singular `Inflect.singularize("stories")`):

```ruby
        as_opt = opts["as"] ? literal(opts["as"]) : nil
        plural = singular ? nm : (as_opt || nm)
        sing = singular ? (as_opt || nm) : Inflect.singularize(plural)

        actions.each do |a|
          verb, kind = RESOURCE_ACTIONS[a]
          route_path = resource_action_path(base, kind, singular)
          stem = case kind
                 when :collection then plural
                 when :member then sing
                 when :new then "new_#{sing}"
                 when :edit then "edit_#{sing}"
                 end
          emit(verb, route_path, ctrl, a.to_s, line_of(node), name: prefixed_name(sc, stem))
          emit("PUT", route_path, ctrl, "update", line_of(node), name: prefixed_name(sc, stem)) if a == :update
        end
```

and build `inner_ctx = ResourceCtx.new(base: base, ctrl: ctrl, singular: singular, name_singular: sing, name_plural: plural)`. For a singular `resource`, `plural` is the same as `sing` for collection routes (`resource :profile` → `profile` for every action; that is what Rails does).

Note: `dynamic_option?(opts, "as")` must be added to the fail-closed check at the top of `resources_call` so a computed `as:` marks the resource unresolved rather than silently deriving the un-aliased name.

7. In `member_collection_new_call`, thread the kind into the inner scope so `verb_call` can build `publish_post`/`recent_posts`/`preview_new_post`. Add a `:res_kind` to `Scope` — simpler: pass it through `res_ctx` by creating a child ctx:

```ruby
      inner_ctx = ResourceCtx.new(base: res_ctx.base, ctrl: res_ctx.ctrl, singular: res_ctx.singular,
                                  name_singular: res_ctx.name_singular, name_plural: res_ctx.name_plural)
      @res_kind_stack.push(kind)
      walk(blk, sc.child(path: new_path), inner_ctx)
      @res_kind_stack.pop
```

Initialise `@res_kind_stack = []` in `Walker#initialize`.

8. In `verb_call`, compute the name per path in `segs.each`:

```ruby
        route_name =
          if opts["as"]
            as_lit = literal(opts["as"])
            as_lit.nil? ? nil : prefixed_name(sc, as_lit)
          elsif res_ctx && !@res_kind_stack.empty? && seg && !seg.start_with?("/")
            case @res_kind_stack.last
            when :member then prefixed_name(sc, "#{seg}_#{res_ctx.name_singular}")
            when :collection then prefixed_name(sc, "#{seg}_#{res_ctx.name_plural}")
            when :new then prefixed_name(sc, "#{seg}_new_#{res_ctx.name_singular}")
            end
          elsif res_ctx && seg && !seg.start_with?("/")
            # bare route inside a resources block (`resources :posts do get :stats end`)
            prefixed_name(sc, "#{seg}_#{res_ctx.name_singular}")
          else
            prefixed_name(sc, derived_name_from_path(seg))
          end
        verbs.each { |v| emit(v, route_path, ctrl, action, line_of(node), name: route_name) }
```

A non-literal `as:` must be reported: add `if dynamic_option?(opts, "as") then mark_unresolved("RAILS_ROUTE_DYNAMIC_PATH", line_of(node), "#{name} as: is not a literal"); return; end` next to the existing `controller:` check.

9. In `root_call`: `emit("GET", path, ctrl, action || "index", line_of(node), name: prefixed_name(sc, "root"))`.

- [ ] **Step 4: Run to verify it passes**

Run: `ruby runtime/sidecar/rails/test/routes_test.rb`
Expected: `PASS: routes_test.rb`. Also run `ruby runtime/sidecar/rails/test/analyze_test.rb` (unchanged expectations must still hold).

- [ ] **Step 5: Verify the Zig side passes names through**

Run: `ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime zig build test-rails` then
`ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime bash tests/migrate/rails.sh`
Expected: both PASS (no test pins `name == null` on the wire; the Zig `Route.name` doc comment saying "Always `null` today" is updated in Task 7).

- [ ] **Step 6: Commit**

```bash
git commit -F - -- runtime/sidecar/rails/routes.rb runtime/sidecar/rails/test/routes_test.rb <<'EOF'
Name routes the way Rails' Mapper does (#167 Stage 1)

`name` was a nil placeholder since Stage 2 of #166. Route helpers
(`posts_path`, `root_path`) are the single most common thing in a Rails
template, and the presentation stage cannot resolve one without the name
table. The derivation mirrors Mapper: resources/resource stems, member/
collection/new prefixes, namespace and `scope as:` prefixes, `as:`
overrides, `root`, and a literal path's segments joined by `_` when no
`as:` is given -- with dynamic and glob segments making the route
nameless, as in Rails.

A name is nulled under @uncertain on purpose: a helper resolving to a
route this parser is not vouching for must become a finding, never a
confident URL.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 2: Controller `layout` declarations

**Files:**
- Modify: `runtime/sidecar/rails/controllers.rb` (`Walker#result`, `walk_class_body`)
- Modify: `runtime/sidecar/rails/analyze.rb` (`handle_controllers`)
- Test: `runtime/sidecar/rails/test/controllers_test.rb`, `runtime/sidecar/rails/test/analyze_test.rb`

**Interfaces:**
- Produces: `RailsControllers.parse` result gains `layout:` — `nil` (no declaration), `{ value: "marketing", line: 3 }` (literal string), `{ value: nil, disabled: true, line: 3 }` (`layout false`), or `{ dynamic: true, line: 3 }` (a symbol — a METHOD name Rails calls at request time — a proc/lambda, a non-literal expression, or a literal with `only:`/`except:` conditions).
- `handle_controllers` response gains `layouts: [{ controller: "pages", value: "marketing", disabled: false, dynamic: false, line: 3 }]` — one entry per controller file that declares one, `controller` being the same path key `actions[].controller` uses.

- [ ] **Step 1: Write the failing tests**

Append to `controllers_test.rb` before the final `abort`:

```ruby
# Task 2 (#167 Stage 1): `layout` declarations. Rails' `layout :sym` names
# a METHOD evaluated per request, so only a string literal (with no
# only:/except:) is static; `false` is static too (no layout).
def check_layout(label, src, expected)
  got = RailsControllers.parse(src, path: "app/controllers/x_controller.rb")
  return if got[:layout] == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{got[:layout].inspect}"
  $failures += 1
end

check_layout "no declaration is nil", "class PagesController < ApplicationController\n  def about; end\nend\n", nil
check_layout "a string literal is static",
             "class PagesController < ApplicationController\n  layout \"marketing\"\n  def about; end\nend\n",
             { value: "marketing", line: 2 }
check_layout "layout false disables the layout",
             "class ApiController < ApplicationController\n  layout false\nend\n",
             { value: nil, disabled: true, line: 2 }
check_layout "a symbol names a method -- dynamic",
             "class PostsController < ApplicationController\n  layout :choose\nend\n",
             { dynamic: true, line: 2 }
check_layout "a proc is dynamic",
             "class PostsController < ApplicationController\n  layout proc { |c| c.request.xhr? ? false : \"application\" }\nend\n",
             { dynamic: true, line: 2 }
check_layout "a literal with only:/except: is conditional, so dynamic",
             "class PostsController < ApplicationController\n  layout \"wide\", only: [:index]\nend\n",
             { dynamic: true, line: 2 }
check_layout "the LAST declaration wins, as in Rails",
             "class PostsController < ApplicationController\n  layout \"a\"\n  layout \"b\"\nend\n",
             { value: "b", line: 3 }
```

Append to `analyze_test.rb` inside the existing `Open3.popen3` block for the `controllers` op (find `stdin.puts JSON.generate({ op: "controllers", root: dir })` and its checks), and add a controller with a layout to the fixture written at the top of the file:

```ruby
  File.write(File.join(dir, "app/controllers/pages_controller.rb"), <<~RB)
    class PagesController < ApplicationController
      layout "marketing"
      def about; end
    end
  RB
```

then, after the existing `controllers` checks:

```ruby
    layouts = res[:layouts]
    check("layouts present", layouts.is_a?(Array))
    pages = layouts.find { |l| l[:controller] == "pages" }
    check("pages layout literal", pages == { controller: "pages", value: "marketing", disabled: false, dynamic: false, line: 2 })
    check("undeclared controllers have no layouts entry", layouts.none? { |l| l[:controller] == "posts" })
```

- [ ] **Step 2: Run to verify they fail**

Run: `ruby runtime/sidecar/rails/test/controllers_test.rb; ruby runtime/sidecar/rails/test/analyze_test.rb`
Expected: `FAIL a string literal is static` etc.; `FAIL layouts present`.

- [ ] **Step 3: Implement**

In `controllers.rb`'s `Walker`:

```ruby
    def initialize
      @controller = nil
      @actions = {}
      @classes = []
      @layout = nil
    end

    def result
      { controller: @controller, actions: @actions, layout: @layout, unresolved: [] }
    end
```

In `walk_class_body`'s `when Prism::CallNode` branch, before the visibility handling:

```ruby
        when Prism::CallNode
          record_layout(n) if n.receiver.nil? && n.name == :layout
          visibility = handle_visibility_call(n, visibility)
```

and add:

```ruby
    # `layout "x"` is the only static shape. `layout :sym` names a method
    # Rails calls per request; a proc, a non-literal, or a literal carrying
    # only:/except: are all decided at request time -- reported as dynamic
    # so the Zig side can fall back to convention AND raise a finding,
    # instead of guessing which layout wins.
    def record_layout(node)
      line = node.location.start_line
      args = node.arguments&.arguments || []
      first = args.first
      has_opts = args.any? { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
      @layout =
        if first.is_a?(Prism::StringNode) && !has_opts
          { value: first.unescaped, line: line }
        elsif first.is_a?(Prism::FalseNode) && !has_opts
          { value: nil, disabled: true, line: line }
        else
          { dynamic: true, line: line }
        end
    end
```

In `analyze.rb`'s `handle_controllers`, add `layouts = []` next to `actions = []`, and after `controller_key = controller_path_key(file, controllers_root)`:

```ruby
      if (lay = result[:layout])
        layouts << {
          controller: controller_key,
          value: lay[:value],
          disabled: lay[:disabled] == true,
          dynamic: lay[:dynamic] == true,
          line: lay[:line],
        }
      end
```

Note the `next if result[:actions].empty?` guard sits BEFORE the key is computed today; move the `controller_key` computation above that guard and change the guard to only skip the `actions.each` loop, so a controller that declares a layout but has no public actions still reports its layout. Return `{ ok: true, actions: actions, layouts: layouts, unresolved: unresolved, ruby: RUBY_INFO }`.

- [ ] **Step 4: Run to verify they pass**

Run: `ruby runtime/sidecar/rails/test/controllers_test.rb; ruby runtime/sidecar/rails/test/analyze_test.rb`
Expected: `PASS` for both.

- [ ] **Step 5: Commit**

```bash
git commit -F - -- runtime/sidecar/rails/controllers.rb runtime/sidecar/rails/analyze.rb runtime/sidecar/rails/test/controllers_test.rb runtime/sidecar/rails/test/analyze_test.rb <<'EOF'
Read controller `layout` declarations (#167 Stage 1)

Layouts were resolved by convention only (per-controller file, else
application) because the controller walk never looked for `layout`. A
string literal is static and overrides convention; `false` disables the
layout; a symbol is a METHOD Rails calls per request, and a proc or an
only:/except: condition is likewise decided at request time -- all of
those are reported `dynamic` so the client can keep the convention as an
approximation and raise RAILS_LAYOUT_DYNAMIC rather than guess.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 3: `erb.rb` — the Erubi-grammar scanner

**Files:**
- Create: `runtime/sidecar/rails/erb.rb`
- Test: `runtime/sidecar/rails/test/erb_test.rb`

**Interfaces:**
- Produces: `RailsErb.scan(src) -> Array<Hash>` of tokens in source order: `{ type: :text, text: String, line: Integer }` and `{ type: :code, indicator: "" | "=" | "==" | "#" | "-", code: String, line: Integer, col: Integer }`. `line`/`col` are 1-based positions of the `<%` in `src`. Trim behaviour follows Erubi with `trim: true` (Rails' default): a code-only tag (`<%`/`<%-`/`<%#`) alone on its line swallows its leading indentation and trailing newline; `<%=` never trims; `-%>`'s trailing newline is dropped; `<%%` is the literal text `<%`. Comment tags produce no token but their newlines are preserved in the adjacent text so line numbers stay true.

- [ ] **Step 1: Write the failing test**

```ruby
# runtime/sidecar/rails/test/erb_test.rb
require_relative "../erb"

# Expectations follow Erubi (the engine Rails actually uses, trim: true).
# To cross-check against the real gem: `gem install erubi` and run
#   ruby -rerubi -e 'puts Erubi::Engine.new(File.read(ARGV[0]), trim: true).src' FILE
# -- every text run below must appear as a `_buf << '...'` literal there
# with the same whitespace, and every code token as the same statement.
$failures = 0
def check(label, src, expected)
  got = RailsErb.scan(src).map { |t| t.reject { |k, _| k == :col } }
  return if got == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{got.inspect}"
  $failures += 1
end

check "text only", "<h1>Hi</h1>\n", [{ type: :text, text: "<h1>Hi</h1>\n", line: 1 }]

check "output tag keeps surrounding text and newline",
      "<p><%= @x %></p>\n",
      [{ type: :text, text: "<p>", line: 1 },
       { type: :code, indicator: "=", code: " @x ", line: 1 },
       { type: :text, text: "</p>\n", line: 1 }]

check "raw output tag is its own indicator",
      "<%== raw_html %>",
      [{ type: :code, indicator: "==", code: " raw_html ", line: 1 }]

check "a code-only tag alone on its line is trimmed with its indentation and newline",
      "<ul>\n  <% items.each do |i| %>\n  <li><%= i %></li>\n  <% end %>\n</ul>\n",
      [{ type: :text, text: "<ul>\n", line: 1 },
       { type: :code, indicator: "", code: " items.each do |i| ", line: 2 },
       { type: :text, text: "  <li>", line: 3 },
       { type: :code, indicator: "=", code: " i ", line: 3 },
       { type: :text, text: "</li>\n", line: 3 },
       { type: :code, indicator: "", code: " end ", line: 4 },
       { type: :text, text: "</ul>\n", line: 5 }]

check "a code tag with text before it on the same line is NOT trimmed",
      "<b><% x = 1 %>\n",
      [{ type: :text, text: "<b>", line: 1 },
       { type: :code, indicator: "", code: " x = 1 ", line: 1 },
       { type: :text, text: "\n", line: 1 }]

check "-%> drops the trailing newline on an output tag",
      "<%= a -%>\nb",
      [{ type: :code, indicator: "=", code: " a ", line: 1 },
       { type: :text, text: "b", line: 2 }]

check "a comment leaves no token but keeps line numbers true",
      "<%# note %>\n<%= a %>",
      [{ type: :text, text: "\n", line: 1 },
       { type: :code, indicator: "=", code: " a ", line: 2 }]

check "<%% is literal text",
      "<%% not code %>",
      [{ type: :text, text: "<% not code %>", line: 1 }]

check "col is the 1-based column of the tag" , "", []
got = RailsErb.scan("ab <%= c %>")
unless got[1] && got[1][:col] == 4
  warn "FAIL col: #{got.inspect}"; $failures += 1
end

check "an unterminated tag is text (Erubi does the same)",
      "<p><% oops\n",
      [{ type: :text, text: "<p><% oops\n", line: 1 }]

abort "#{$failures} erb failure(s)" if $failures > 0
puts "PASS: erb_test.rb"
```

- [ ] **Step 2: Run to verify it fails**

Run: `ruby runtime/sidecar/rails/test/erb_test.rb`
Expected: `cannot load such file -- .../erb` (LoadError).

- [ ] **Step 3: Implement the scanner**

```ruby
# runtime/sidecar/rails/erb.rb
#
# An ERB scanner with Erubi's grammar and trim rules. Rails does not use
# stdlib ERB: ActionView compiles templates with Erubi (trim: true, escape:
# true), so `<%==` is raw output and a code-only tag alone on its line is
# trimmed with its indentation. This is Erubi::Engine#initialize's scan
# loop, ported to emit TOKENS instead of Ruby source -- vendored the same
# way inflect.rb vendors ActiveSupport's inflection rules, so the migration
# adapter sees the same tokens Rails does without depending on the gem.
#
# Never evaluates anything. Templates under migration are untrusted input.
module RailsErb
  # Erubi's own regexp, verbatim.
  TAG = /<%(={1,2}|-|\#|%)?(.*?)([-=])?%>([ \t]*\r?\n)?/m

  # Returns an Array of tokens in source order:
  #   { type: :text, text:, line: }
  #   { type: :code, indicator: ""|"="|"=="|"#"|"-", code:, line:, col: }
  # `<%#` comments emit no code token; their newlines are folded into the
  # surrounding text so every later token's :line is still its true line.
  def self.scan(src)
    tokens = []
    pos = 0
    is_bol = true
    pending_text = +""
    pending_line = 1

    flush = lambda do
      unless pending_text.empty?
        tokens << { type: :text, text: pending_text, line: pending_line }
        pending_text = +""
      end
    end
    add_text = lambda do |s, at_pos|
      next if s.nil? || s.empty?
      pending_line = line_of(src, at_pos) if pending_text.empty?
      pending_text << s
    end

    src.scan(TAG) do
      m = Regexp.last_match
      indicator, code, tailch, rspace = m[1], m[2], m[3], m[4]
      text_start = pos
      text = src[pos, m.begin(0) - pos]
      tag_pos = m.begin(0)
      pos = m.end(0)
      ch = indicator ? indicator[0] : nil

      lspace = nil
      if ch != "="
        if text.empty?
          lspace = "" if is_bol
        elsif text[-1] == "\n"
          lspace = ""
        else
          rindex = text.rindex("\n")
          if rindex
            s = text[(rindex + 1)..]
            if /\A[ \t]*\z/.match?(s)
              lspace = s
              text = text[0..rindex]
            end
          elsif is_bol && /\A[ \t]*\z/.match?(text)
            lspace = text
            text = ""
          end
        end
      end
      is_bol = !rspace.nil?

      add_text.call(text, text_start)
      case ch
      when "="
        rspace = nil if tailch && !tailch.empty?
        add_text.call(lspace, tag_pos)
        flush.call
        tokens << { type: :code, indicator: indicator, code: code, line: line_of(src, tag_pos), col: col_of(src, tag_pos) }
        add_text.call(rspace, m.end(0))
      when "#"
        n = code.count("\n") + (rspace ? 1 : 0)
        if lspace && rspace
          add_text.call("\n" * n, tag_pos)
        else
          add_text.call(lspace, tag_pos)
          add_text.call("\n" * n, tag_pos)
          add_text.call(rspace, m.end(0))
        end
      when "%"
        add_text.call("#{lspace}<%#{code}#{tailch}%>#{rspace}", tag_pos)
      when nil, "-"
        if lspace && rspace
          flush.call
          tokens << { type: :code, indicator: indicator.to_s, code: code, line: line_of(src, tag_pos), col: col_of(src, tag_pos) }
          # Erubi keeps the swallowed newline INSIDE the generated code so
          # line numbers stay true; a token stream has no such slot, and
          # the next text token's own :line is computed from its position,
          # so nothing needs re-adding here.
        else
          add_text.call(lspace, tag_pos)
          flush.call
          tokens << { type: :code, indicator: indicator.to_s, code: code, line: line_of(src, tag_pos), col: col_of(src, tag_pos) }
          add_text.call(rspace, m.end(0))
        end
      end
    end
    rest = pos.zero? ? src : src[pos..]
    add_text.call(rest, pos)
    flush.call
    tokens
  end

  def self.line_of(src, pos)
    src[0, pos].count("\n") + 1
  end

  def self.col_of(src, pos)
    last_nl = src.rindex("\n", pos - 1) if pos > 0
    last_nl ? pos - last_nl : pos + 1
  end
end
```

Trace the trimmed-block case by hand before running: for `"<ul>\n  <% items.each do |i| %>\n"`, the first match has `text = "<ul>\n  "`, `rindex` finds the newline, `s = "  "` is whitespace-only so `lspace = "  "` and `text` becomes `"<ul>\n"`; `rspace = "\n"`; both set, so the text `"<ul>\n"` is flushed and the code token is emitted with no trailing text — exactly the expectation.

- [ ] **Step 4: Run to verify it passes**

Run: `ruby runtime/sidecar/rails/test/erb_test.rb`
Expected: `PASS: erb_test.rb`. If a whitespace case disagrees, cross-check with the erubi one-liner in the test header and fix the port, never the expectation.

- [ ] **Step 5: Commit**

```bash
git commit -F - -- runtime/sidecar/rails/erb.rb runtime/sidecar/rails/test/erb_test.rb <<'EOF'
Vendor Erubi's ERB grammar as a token scanner (#167 Stage 1)

Rails compiles templates with Erubi, not stdlib ERB: `<%==` is raw
output and a code-only tag alone on its line is trimmed together with its
indentation. A converter working from any other tokenization would place
whitespace -- and, worse, unescaped output -- differently from what the
app actually renders. This ports Erubi::Engine's scan loop verbatim to
emit tokens with true line/col, the same vendoring precedent inflect.rb
set for ActiveSupport's inflections.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 4: `i18n.rb` — default-locale lookup

**Files:**
- Create: `runtime/sidecar/rails/i18n.rb`
- Test: `runtime/sidecar/rails/test/i18n_test.rb`

**Interfaces:**
- Produces: `RailsI18n.load(root) -> RailsI18n::Table` (reads `config/application.rb` for a literal `config.i18n.default_locale = :xx`, else `"en"`; loads every `config/locales/**/*.yml` whose top-level key is that locale; malformed files are skipped and recorded in `table.errors` as `{ path:, detail: }`). `Table#locale -> String`, `Table#lookup(key) -> String | nil` (dotted key, nested hashes; a non-string leaf such as a Hash or Array returns nil). `RailsI18n.expand_lazy(key, template_rel_path) -> String` turns `".heading"` in `app/views/posts/index.html.erb` into `"posts.index.heading"` (partials drop their leading `_`: `app/views/posts/_post.html.erb` → `posts.post.heading`), matching Rails' `ActionView::Helpers::TranslationHelper#scope_key_by_partial`.

- [ ] **Step 1: Write the failing test**

```ruby
# runtime/sidecar/rails/test/i18n_test.rb
require "tmpdir"
require "fileutils"
require_relative "../i18n"

$failures = 0
def check(label, cond)
  return if cond
  warn "FAIL #{label}"; $failures += 1
end

Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, "config/locales/nested"))
  File.write(File.join(dir, "config/application.rb"), "module App\n  class Application < Rails::Application\n    config.i18n.default_locale = :fr\n  end\nend\n")
  File.write(File.join(dir, "config/locales/fr.yml"), "fr:\n  posts:\n    index:\n      heading: \"Articles\"\n  nav:\n    home: \"Accueil\"\n")
  File.write(File.join(dir, "config/locales/en.yml"), "en:\n  nav:\n    home: \"Home\"\n")
  File.write(File.join(dir, "config/locales/nested/extra.yml"), "fr:\n  extra:\n    deep: \"Profond\"\n    list: [1, 2]\n")
  File.write(File.join(dir, "config/locales/broken.yml"), "fr: [unclosed\n")

  t = RailsI18n.load(dir)
  check("locale from application.rb", t.locale == "fr")
  check("nested lookup", t.lookup("posts.index.heading") == "Articles")
  check("only the default locale is merged", t.lookup("nav.home") == "Accueil")
  check("nested directory files load", t.lookup("extra.deep") == "Profond")
  check("non-string leaf is nil", t.lookup("extra.list").nil?)
  check("missing key is nil", t.lookup("nope.nope").nil?)
  check("malformed file recorded, not fatal", t.errors.any? { |e| e[:path] == "config/locales/broken.yml" })
end

Dir.mktmpdir do |dir|
  t = RailsI18n.load(dir)
  check("no config/locales: empty table, locale en", t.locale == "en" && t.lookup("x").nil? && t.errors.empty?)
end

check("lazy key in a view", RailsI18n.expand_lazy(".heading", "app/views/posts/index.html.erb") == "posts.index.heading")
check("lazy key in a partial drops the underscore", RailsI18n.expand_lazy(".title", "app/views/posts/_post.html.erb") == "posts.post.title")
check("lazy key in a nested layout", RailsI18n.expand_lazy(".brand", "app/views/layouts/admin/base.html.erb") == "layouts.admin.base.brand")
check("absolute key untouched", RailsI18n.expand_lazy("nav.home", "app/views/x.html.erb") == "nav.home")

abort "#{$failures} i18n failure(s)" if $failures > 0
puts "PASS: i18n_test.rb"
```

- [ ] **Step 2: Run to verify it fails**

Run: `ruby runtime/sidecar/rails/test/i18n_test.rb`
Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# runtime/sidecar/rails/i18n.rb
#
# Default-locale translation lookup for the templates op. Reads YAML with
# Psych (a default gem shipped with every supported Ruby; no bundler) and
# NEVER evaluates a locale file -- `YAML.safe_load` only. Only the default
# locale converts in this stage; every other locale is out of scope by the
# spec and never loaded.
require "yaml"

module RailsI18n
  class Table
    attr_reader :locale, :errors

    def initialize(locale)
      @locale = locale
      @data = {}
      @errors = []
    end

    def merge!(hash)
      deep_merge!(@data, hash)
    end

    def lookup(key)
      node = @data
      key.split(".").each do |part|
        return nil unless node.is_a?(Hash) && node.key?(part)
        node = node[part]
      end
      node.is_a?(String) ? node : nil
    end

    private

    def deep_merge!(into, from)
      from.each do |k, v|
        if v.is_a?(Hash) && into[k].is_a?(Hash)
          deep_merge!(into[k], v)
        else
          into[k] = v
        end
      end
    end
  end

  DEFAULT_LOCALE_RE = /config\.i18n\.default_locale\s*=\s*(?::(\w+)|["'](\w+)["'])/

  def self.default_locale(root)
    src = File.read(File.join(root, "config/application.rb"))
    m = DEFAULT_LOCALE_RE.match(src)
    m ? (m[1] || m[2]) : "en"
  rescue SystemCallError, IOError
    "en"
  end

  def self.load(root)
    table = Table.new(default_locale(root))
    Dir.glob(File.join(root, "config/locales/**/*.{yml,yaml}")).sort.each do |file|
      rel = file.delete_prefix("#{root}/")
      begin
        doc = YAML.safe_load(File.read(file), permitted_classes: [Symbol], aliases: true)
      rescue StandardError => e
        table.errors << { path: rel, detail: "#{e.class}: #{e.message.lines.first.to_s.strip}" }
        next
      end
      next unless doc.is_a?(Hash)
      slice = doc[table.locale] || doc[table.locale.to_sym]
      table.merge!(slice) if slice.is_a?(Hash)
    end
    table
  end

  # Rails' scope_key_by_partial: `.key` inside app/views/posts/index.html.erb
  # is `posts.index.key`; a partial's leading underscore is dropped.
  def self.expand_lazy(key, template_rel_path)
    return key unless key.start_with?(".")
    rel = template_rel_path.delete_prefix("app/views/")
    base = rel.sub(/\..*\z/, "") # strip every extension: index.html.erb -> index
    parts = base.split("/")
    parts[-1] = parts[-1].delete_prefix("_")
    "#{parts.join(".")}#{key}"
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `ruby runtime/sidecar/rails/test/i18n_test.rb`
Expected: `PASS: i18n_test.rb`.

- [ ] **Step 5: Commit**

```bash
git commit -F - -- runtime/sidecar/rails/i18n.rb runtime/sidecar/rails/test/i18n_test.rb <<'EOF'
Resolve default-locale t() keys from config/locales (#167 Stage 1)

`t(".heading")` is the ordinary way a Rails template carries copy, and a
converter that cannot read it would report every such page as blocked.
Loads only the default locale (a literal config.i18n.default_locale, else
en) via YAML.safe_load; other locales stay out of scope per the spec. Lazy
keys expand exactly as ActionView's scope_key_by_partial does, partial
underscore included.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 5: `templates.rb` — fragment classification into the closed vocabulary

**Files:**
- Create: `runtime/sidecar/rails/templates.rb`
- Test: `runtime/sidecar/rails/test/templates_test.rb`

**Interfaces:**
- Consumes: `RailsErb.scan`, `RailsI18n::Table`, `RailsI18n.expand_lazy`.
- Produces: `RailsTemplates.analyze(src, path:, i18n:) -> { nodes: [...] } | { error: String, line: Integer }`. Each node is a Hash with `t: "text", text:, line:` or `t: "code", kind:, line:, col:, output: Boolean, code:` plus kind-specific keys: `name:` (helper/partial/route/i18n key/controller), `args:` (Array of literal positional args as Strings), `attrs:` (Array of `[key, value]` literal option pairs), `value:` (resolved i18n text or literal value), `missing: true` (i18n), `dynamic: true` (form/component props not literal). Block-structured kinds (`form`, `control`, `content_for`, `turbo_frame`) are followed in-order by their children, then a `{ t: "code", kind: "block_end", line: }` node; an `else`/`elsif` emits `{ kind: "block_else" }` between branches.
- Kinds (closed set, spec "Fragment vocabulary" plus `local`, `block_else`, `block_end` which the spec's node-stream form needs): `yield`, `yield_named`, `content_for`, `render_partial`, `render_partial_locals`, `render_dynamic`, `route_helper`, `route_helper_dynamic`, `link_to`, `asset`, `importmap`, `csrf`, `i18n`, `literal`, `form`, `form_field`, `errors`, `request_state`, `ivar`, `local`, `control`, `block_else`, `block_end`, `turbo_frame`, `turbo_stream`, `component_root`, `raw`, `unknown`.
- Mechanism: the token stream is compiled to a line-preserving Ruby program (text → `_buf << '…';`, `<%=` → `_out((…));`, `<%==` → `_raw((…));`, code verbatim) and parsed ONCE with Prism, so block structure (`do … end`, `if … end`) is real AST nesting; an unparsable program is the `{error, line}` result (this is what `RAILS_TEMPLATE_PARSE_ERROR` means).

- [ ] **Step 1: Write the failing test**

```ruby
# runtime/sidecar/rails/test/templates_test.rb
require_relative "../templates"
require_relative "../i18n"

$failures = 0
I18N = RailsI18n::Table.new("en")
I18N.merge!({ "posts" => { "index" => { "heading" => "Posts" } }, "nav" => { "home" => "Home" } })

def kinds(src, path: "app/views/posts/index.html.erb")
  res = RailsTemplates.analyze(src, path: path, i18n: I18N)
  raise "unexpected error #{res.inspect}" if res[:error]
  res[:nodes].select { |n| n[:t] == "code" }
end

def check(label, src, expected_kinds, path: "app/views/posts/index.html.erb")
  got = kinds(src, path: path).map { |n| n[:kind] }
  return if got == expected_kinds
  warn "FAIL #{label}\n  expected: #{expected_kinds.inspect}\n  actual:   #{got.inspect}"
  $failures += 1
end

def check_node(label, src, index, expected_subset, path: "app/views/posts/index.html.erb")
  node = kinds(src, path: path)[index]
  ok = node && expected_subset.all? { |k, v| node[k] == v }
  return if ok
  warn "FAIL #{label}\n  expected ⊇ #{expected_subset.inspect}\n  actual:   #{node.inspect}"
  $failures += 1
end

check "yield and named yield", "<%= yield %><%= yield :head %><%= content_for?(:side) %>", %w[yield yield_named yield_named]
check_node "named yield carries its name", "<%= yield :head %>", 0, { name: "head" }

check "content_for block and provide", "<% content_for :title do %>x<% end %><% provide(:title, \"T\") %>",
      %w[content_for block_end content_for]
check_node "provide carries literal value", "<% provide(:title, \"T\") %>", 0, { name: "title", value: "T" }

check "partials: literal, literal locals, collection, ivar",
      "<%= render \"nav\" %><%= render partial: \"post\", locals: { a: 1 } %><%= render partial: \"post\", collection: @posts %><%= render @post %>",
      %w[render_partial render_partial_locals render_dynamic render_dynamic]
check_node "literal partial target", "<%= render partial: \"shared/nav\" %>", 0, { name: "shared/nav" }
check_node "literal locals are attrs", "<%= render partial: \"post\", locals: { a: 1, b: \"x\" } %>", 0, { attrs: [["a", "1"], ["b", "x"]] }

check "route helpers", "<%= posts_path %><%= post_path(1) %><%= post_path(@post) %><%= root_url %>",
      %w[route_helper route_helper route_helper_dynamic route_helper]
check_node "route helper name is the stem", "<%= post_path(1) %>", 0, { name: "post", args: ["1"] }

check "link_to literal vs dynamic",
      "<%= link_to \"Home\", root_path %><%= link_to \"P\", post_path(@p) %><%= link_to @p.title, root_path %>",
      %w[link_to route_helper_dynamic route_helper_dynamic]
check_node "link_to carries text and target", "<%= link_to \"Home\", root_path, class: \"x\" %>", 0,
           { name: "root", args: ["Home"], attrs: [["class", "x"]] }

check "assets, importmap, csrf",
      "<%= image_tag \"logo.png\" %><%= stylesheet_link_tag \"application\" %><%= javascript_importmap_tags %><%= csrf_meta_tags %><%= csp_meta_tag %>",
      %w[asset asset importmap csrf csrf]
check_node "asset name", "<%= image_tag \"logo.png\", alt: \"L\" %>", 0, { name: "image_tag", args: ["logo.png"], attrs: [["alt", "L"]] }

check "i18n resolves absolute and lazy keys", "<%= t(\"nav.home\") %><%= t(\".heading\") %><%= t(\".nope\") %>", %w[i18n i18n i18n]
check_node "resolved value", "<%= t(\".heading\") %>", 0, { name: "posts.index.heading", value: "Posts" }
check_node "missing key", "<%= t(\".nope\") %>", 0, { name: "posts.index.nope", missing: true }

check "literals", "<%= \"a\" %><%= 1 %><%= nil %>", %w[literal literal literal]

check "form with fields and errors",
      "<%= form_with(model: @post, url: \"/posts\") do |f| %><%= f.label :title %><%= f.text_field :title %><%= f.submit \"Go\" %><% end %><% if @post.errors.any? %><%= @post.errors.full_messages %><% end %>",
      %w[form form_field form_field form_field block_end errors errors block_end]
check_node "form attrs and model", "<%= form_with(model: @post, url: \"/posts\") do |f| %><% end %>", 0,
           { attrs: [["url", "/posts"]], name: "post", dynamic: true }
check_node "form field carries builder method and field", "<%= form_with(url: \"/x\") do |f| %><%= f.email_field :email %><% end %>", 1,
           { name: "email_field", args: ["email"] }

check "request state and ivars",
      "<%= current_user.name %><% if signed_in? %><% end %><%= session[:x] %><%= @posts.count %><%= Current.account %>",
      %w[request_state request_state block_end request_state ivar request_state]
check_node "request_state names the marker", "<%= current_user.name %>", 0, { name: "current_user" }

check "locals", "<%= post.title %><%= post %>", %w[local local]

check "control flow", "<% if true %>a<% else %>b<% end %><% 3.times do %><% end %>",
      %w[control block_else block_end control block_end]
check "control with request state or ivar is that, not control",
      "<% @posts.each do |p| %><%= p.title %><% end %>", %w[ivar local block_end]

check "turbo and components",
      "<%= turbo_frame_tag \"x\" do %><% end %><%= turbo_stream_from @post %><%= react_component(\"Hello\", { name: \"n\" }) %><%= react_component(\"Hello\", @props) %>",
      %w[turbo_frame block_end turbo_stream component_root component_root]
check_node "component props literal", "<%= react_component(\"Hello\", { name: \"n\" }) %>", 0, { name: "Hello", attrs: [["name", "n"]] }
check_node "component props dynamic", "<%= react_component(\"Hello\", @props) %>", 0, { name: "Hello", dynamic: true }

check "raw", "<%== x %><%= raw(y) %><%= z.html_safe %>", %w[raw raw raw]

check "unknown helper", "<%= number_to_currency(3) %>", %w[unknown]
check_node "unknown names the method", "<%= number_to_currency(3) %>", 0, { name: "number_to_currency" }

# A template whose fragments do not assemble into a valid program is a parse
# error at the offending line -- never a partial node list.
res = RailsTemplates.analyze("<p>\n<% if x %>\n</p>\n", path: "app/views/posts/index.html.erb", i18n: I18N)
unless res[:error] && res[:line].is_a?(Integer)
  warn "FAIL parse error reporting: #{res.inspect}"; $failures += 1
end

# Text nodes interleave in order with true line numbers.
res = RailsTemplates.analyze("<h1>\n  <%= yield %>\n</h1>\n", path: "app/views/layouts/application.html.erb", i18n: I18N)
texts = res[:nodes].select { |n| n[:t] == "text" }.map { |n| [n[:text], n[:line]] }
unless texts == [["<h1>\n  ", 1], ["\n</h1>\n", 2]] && res[:nodes][1][:kind] == "yield" && res[:nodes][1][:line] == 2 && res[:nodes][1][:col] == 3
  warn "FAIL text interleave: #{res[:nodes].inspect}"; $failures += 1
end

abort "#{$failures} templates failure(s)" if $failures > 0
puts "PASS: templates_test.rb"
```

- [ ] **Step 2: Run to verify it fails**

Run: `ruby runtime/sidecar/rails/test/templates_test.rb`
Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# runtime/sidecar/rails/templates.rb
#
# Classifies every Ruby fragment of an ERB template into the closed
# vocabulary the design spec's "Fragment vocabulary" table defines, and
# returns ONE ordered node stream per template: text runs and classified
# code nodes, with block structure made explicit (`block_else`/`block_end`).
#
# How: the token stream from erb.rb is compiled into a line-preserving Ruby
# program (text -> `_buf << '...';`, `<%=` -> `_out((...));`, `<%==` ->
# `_raw((...));`, code verbatim, comments -> their newlines) and parsed ONCE
# with Prism. That is the only honest way to see block structure: a single
# `<% form_with ... do |f| %>` fragment is not valid Ruby on its own, but the
# whole program is, and `do ... end` / `if ... end` become real AST nesting.
# A program Prism rejects is a template whose fragments do not assemble --
# reported as {error, line} and consumed as RAILS_TEMPLATE_PARSE_ERROR.
#
# Never evaluates anything. Templates under migration are untrusted input.
require "prism"
require_relative "erb"
require_relative "i18n"

module RailsTemplates
  REQUEST_STATE = %w[current_user session flash cookies params request signed_in? logged_in?
                     user_signed_in? current_account current_organization policy can? authorize].freeze
  ASSET_HELPERS = %w[image_tag image_path asset_path asset_url stylesheet_link_tag
                     javascript_include_tag favicon_link_tag audio_tag video_tag font_path].freeze
  IMPORTMAP_HELPERS = %w[javascript_importmap_tags turbo_include_tags].freeze
  CSRF_HELPERS = %w[csrf_meta_tags csrf_meta_tag csp_meta_tag].freeze
  FORM_HELPERS = %w[form_with form_for form_tag].freeze
  CONTROL_CALLS = %w[each each_with_index map times each_slice].freeze

  def self.analyze(src, path:, i18n:)
    tokens = RailsErb.scan(src)
    program, code_tokens = compile(tokens)
    result = Prism.parse(program)
    if result.failure?
      err = result.errors.first
      return { error: err&.message || "parse error", line: err&.location&.start_line || 1 }
    end
    walker = Walker.new(path, i18n, code_tokens)
    walker.walk_statements(result.value.statements&.body || [])
    { nodes: walker.nodes }
  rescue StandardError, SystemStackError => e
    { error: "#{e.class}: #{e.message}", line: 1 }
  end

  # Text runs become single-quoted literals with newlines kept INSIDE the
  # literal, so every later fragment lands on its true source line.
  def self.compile(tokens)
    out = +""
    code_tokens = []
    tokens.each do |t|
      case t[:type]
      when :text
        out << "_buf << '" << t[:text].gsub("\\", "\\\\\\\\").gsub("'", "\\\\'") << "';"
      when :code
        code_tokens << t
        case t[:indicator]
        when "=" then out << "_out((" << t[:code] << "));"
        when "==" then out << "_raw((" << t[:code] << "));"
        else out << t[:code] << ";"
        end
      end
    end
    [out, code_tokens]
  end

  class Walker
    attr_reader :nodes

    def initialize(path, i18n, code_tokens)
      @path = path
      @i18n = i18n
      @nodes = []
      # Tokens by line, consumed in order, so a node's :col is the column of
      # the tag it came from (the compiled program's columns are meaningless).
      @tokens_by_line = code_tokens.group_by { |t| t[:line] }
      @form_builders = [] # block-param names of open form blocks
    end

    def walk_statements(stmts)
      stmts.each { |s| visit(s) }
    end

    private

    def visit(node)
      line = node.location.start_line
      if buf_append?(node)
        text = node.arguments.arguments.first
        @nodes << { t: "text", text: text.unescaped, line: line }
        return
      end
      if out_call?(node, :_out)
        emit(classify(node.arguments.arguments.first, output: true), line, node)
        return
      end
      if out_call?(node, :_raw)
        emit({ kind: "raw", output: true }, line, node)
        return
      end
      emit_statement(node, line)
    end

    # ---- statement-level (code fragments) --------------------------------

    def emit_statement(node, line)
      case node
      when Prism::IfNode, Prism::UnlessNode
        cond = node.predicate
        emit(state_or(cond, { kind: "control", name: node.is_a?(Prism::IfNode) ? "if" : "unless" }), line, node)
        walk_statements(statements_of(node.statements))
        sub = node.respond_to?(:subsequent) ? node.subsequent : node.else_clause
        while sub
          @nodes << { t: "code", kind: "block_else", line: sub.location.start_line, output: false, code: "" }
          if sub.is_a?(Prism::IfNode)
            walk_statements(statements_of(sub.statements))
            sub = sub.subsequent
          else
            walk_statements(statements_of(sub.statements))
            sub = nil
          end
        end
        block_end(node)
      when Prism::CaseNode, Prism::WhileNode, Prism::UntilNode
        emit(state_or(node.respond_to?(:predicate) ? node.predicate : nil, { kind: "control", name: node.class.name.split("::").last.sub("Node", "").downcase }), line, node)
        walk_statements(descendant_statements(node))
        block_end(node)
      when Prism::CallNode
        info = classify(node, output: false)
        emit(info, line, node)
        if node.block.is_a?(Prism::BlockNode)
          @form_builders.push(block_param_name(node.block)) if info[:kind] == "form"
          walk_statements(statements_of(node.block.body))
          @form_builders.pop if info[:kind] == "form"
          block_end(node)
        end
      else
        emit(classify(node, output: false), line, node)
      end
    end

    def block_end(node)
      @nodes << { t: "code", kind: "block_end", line: node.location.end_line, output: false, code: "" }
    end

    # ---- expression classification -----------------------------------------

    def classify(node, output:)
      info = classify_inner(node)
      info[:output] = output
      info
    end

    def classify_inner(node)
      case node
      when Prism::YieldNode
        args = positional(node.arguments)
        sym = args.first
        return { kind: "yield" } if args.empty?
        return { kind: "yield_named", name: literal(sym) } if literal(sym)
        return { kind: "unknown", name: "yield" }
      when Prism::StringNode, Prism::IntegerNode, Prism::FloatNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SymbolNode
        return { kind: "literal", value: literal(node).to_s }
      when Prism::InterpolatedStringNode
        return { kind: "literal", value: literal(node) } if literal(node)
      when Prism::InstanceVariableReadNode
        return { kind: "ivar", name: node.name.to_s }
      when Prism::ConstantReadNode
        return { kind: "request_state", name: "Current" } if node.name == :Current
      when Prism::LocalVariableReadNode
        return { kind: "local", name: node.name.to_s }
      when Prism::CallNode
        return classify_call(node)
      end
      state_or(node, { kind: "unknown", name: node.class.name.split("::").last })
    end

    def classify_call(node)
      name = node.name.to_s
      recv = node.receiver
      args = positional(node.arguments)
      opts = hash_opts(node.arguments)

      if recv.nil?
        return { kind: "request_state", name: name } if REQUEST_STATE.include?(name) || name.start_with?("current_")
        return { kind: "local", name: name } if node.variable_call?
        case name
        when "content_for?"
          return { kind: "yield_named", name: literal(args.first) } if literal(args.first)
        when "content_for"
          return { kind: "content_for", name: literal(args.first).to_s, value: (args[1] ? literal(args[1]) : nil) }.compact if literal(args.first)
        when "provide"
          return { kind: "content_for", name: literal(args.first).to_s, value: literal(args[1]) } if literal(args.first) && literal(args[1])
        when "render"
          return classify_render(args, opts)
        when "link_to", "button_to"
          return classify_link(args, opts)
        when "raw"
          return { kind: "raw" }
        when "t", "translate"
          return classify_i18n(args)
        when "form_with", "form_for", "form_tag"
          return classify_form(args, opts)
        when "turbo_frame_tag"
          return { kind: "turbo_frame", name: literal(args.first), dynamic: literal(args.first).nil? }.compact
        when "turbo_stream_from"
          return { kind: "turbo_stream" }
        when "react_component"
          return classify_component(args)
        end
        return { kind: "importmap", name: name } if IMPORTMAP_HELPERS.include?(name)
        return { kind: "csrf", name: name } if CSRF_HELPERS.include?(name)
        if ASSET_HELPERS.include?(name)
          return { kind: "asset", name: name, args: literal_args(args), attrs: literal_attrs(opts) } if args.empty? || literal(args.first)
          return state_or(node, { kind: "unknown", name: name })
        end
        if name.end_with?("_path", "_url")
          stem = name.sub(/_(path|url)\z/, "")
          return { kind: "route_helper", name: stem, args: literal_args(args), attrs: literal_attrs(opts) } if all_literal?(args) && all_literal_opts?(opts)
          return state_or(node, { kind: "route_helper_dynamic", name: stem })
        end
        return { kind: "unknown", name: name }
      end

      # receiver present
      return { kind: "raw" } if name == "html_safe"
      return { kind: "i18n" }.merge(classify_i18n(args)) if recv.is_a?(Prism::ConstantReadNode) && recv.name == :I18n && %w[t translate].include?(name)
      return { kind: "turbo_stream" } if recv.is_a?(Prism::CallNode) && recv.receiver.nil? && recv.name == :turbo_stream
      return { kind: "errors", name: receiver_root_name(recv) } if chain_calls?(node, "errors")
      if recv.is_a?(Prism::LocalVariableReadNode) && @form_builders.include?(recv.name.to_s)
        return { kind: "form_field", name: name, args: literal_args(args), attrs: literal_attrs(opts) }
      end
      if recv.is_a?(Prism::CallNode) && recv.receiver.nil? && recv.variable_call? && @form_builders.include?(recv.name.to_s)
        return { kind: "form_field", name: name, args: literal_args(args), attrs: literal_attrs(opts) }
      end
      if CONTROL_CALLS.include?(name) && node.block
        return state_or(recv, { kind: "control", name: name })
      end
      state_or(node, { kind: "local", name: receiver_root_name(recv) }.then { |h| root_is_local?(recv) ? h : { kind: "unknown", name: name } })
    end

    def classify_render(args, opts)
      target = opts["partial"] || (args.first.is_a?(Prism::StringNode) ? args.first : nil)
      return state_or(args.first, { kind: "render_dynamic", name: safe_slice(args.first) }) if target.nil?
      lit = literal(target)
      return { kind: "render_dynamic", name: safe_slice(target) } if lit.nil?
      return { kind: "render_dynamic", name: lit } if opts["collection"] || opts["object"] || opts["layout"]
      if opts["locals"]
        pairs = literal_pairs(opts["locals"])
        return { kind: "render_dynamic", name: lit } if pairs.nil?
        return { kind: "render_partial_locals", name: lit, attrs: pairs }
      end
      { kind: "render_partial", name: lit }
    end

    def classify_link(args, opts)
      text, target = args[0], args[1]
      return state_or(target || text, { kind: "route_helper_dynamic", name: "link_to" }) unless literal(text)
      if target.is_a?(Prism::CallNode) && target.receiver.nil? && target.name.to_s.end_with?("_path", "_url")
        stem = target.name.to_s.sub(/_(path|url)\z/, "")
        targs = positional(target.arguments)
        if all_literal?(targs) && all_literal_opts?(opts)
          return { kind: "link_to", name: stem, args: [literal(text)] + literal_args(targs), attrs: literal_attrs(opts) }
        end
        return state_or(target, { kind: "route_helper_dynamic", name: stem })
      end
      return { kind: "link_to", name: nil, args: [literal(text), literal(target)], attrs: literal_attrs(opts) } if literal(target) && all_literal_opts?(opts)
      state_or(target, { kind: "route_helper_dynamic", name: "link_to" })
    end

    def classify_i18n(args)
      key = literal(args.first)
      return { kind: "unknown", name: "t" } if key.nil?
      full = RailsI18n.expand_lazy(key, @path)
      value = @i18n.lookup(full)
      value ? { kind: "i18n", name: full, value: value } : { kind: "i18n", name: full, missing: true }
    end

    def classify_form(args, opts)
      model = opts["model"] || (args.first.is_a?(Prism::InstanceVariableReadNode) ? args.first : nil)
      info = { kind: "form", attrs: literal_attrs(opts.reject { |k, _| k == "model" }) }
      if model.is_a?(Prism::InstanceVariableReadNode)
        info[:name] = model.name.to_s.delete_prefix("@")
        info[:dynamic] = true
      elsif model
        info[:name] = safe_slice(model)
        info[:dynamic] = true
      end
      info
    end

    def classify_component(args)
      name = literal(args.first)
      return { kind: "unknown", name: "react_component" } if name.nil?
      props = args[1]
      return { kind: "component_root", name: name, attrs: [] } if props.nil?
      pairs = literal_pairs(props)
      pairs ? { kind: "component_root", name: name, attrs: pairs } : { kind: "component_root", name: name, dynamic: true }
    end

    # Request-time state or an ivar ANYWHERE inside `node` wins over the
    # fallback classification -- that is the finding a human needs first.
    def state_or(node, fallback)
      found = nil
      each_descendant(node) do |n|
        case n
        when Prism::InstanceVariableReadNode
          found ||= { kind: "ivar", name: n.name.to_s }
        when Prism::CallNode
          nm = n.name.to_s
          if n.receiver.nil? && (REQUEST_STATE.include?(nm) || nm.start_with?("current_"))
            found = { kind: "request_state", name: nm }
            break
          end
        when Prism::ConstantReadNode
          found = { kind: "request_state", name: "Current" } if n.name == :Current
        end
      end
      found || fallback
    end

    # ---- emission ---------------------------------------------------------

    def emit(info, line, node)
      tok = (@tokens_by_line[line] || []).shift
      @nodes << { t: "code", line: line, col: tok ? tok[:col] : 0, code: (tok ? tok[:code].strip : safe_slice(node)) }.merge(info)
    end

    # ---- helpers -----------------------------------------------------------

    def buf_append?(node)
      node.is_a?(Prism::CallNode) && node.name == :<< && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :_buf &&
        node.arguments&.arguments&.first.is_a?(Prism::StringNode)
    end

    def out_call?(node, sym)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == sym && node.arguments&.arguments&.length == 1
    end

    def positional(arguments)
      return [] unless arguments
      arguments.arguments.reject { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::BlockArgumentNode) }
    end

    def hash_opts(arguments)
      return {} unless arguments
      h = arguments.arguments.find { |a| a.is_a?(Prism::KeywordHashNode) }
      return {} unless h
      h.elements.each_with_object({}) do |e, acc|
        next unless e.is_a?(Prism::AssocNode)
        k = literal(e.key)
        acc[k.to_s] = e.value if k
      end
    end

    def literal(node)
      case node
      when Prism::StringNode then node.unescaped
      when Prism::SymbolNode then node.unescaped
      when Prism::IntegerNode then node.value.to_s
      when Prism::FloatNode then node.value.to_s
      when Prism::TrueNode then "true"
      when Prism::FalseNode then "false"
      when Prism::NilNode then ""
      when Prism::InterpolatedStringNode
        node.parts.all? { |p| p.is_a?(Prism::StringNode) } ? node.parts.map(&:unescaped).join : nil
      else nil
      end
    end

    def all_literal?(nodes) = nodes.all? { |n| literal(n) }
    def all_literal_opts?(opts) = opts.values.all? { |v| literal(v) || literal_pairs(v) }
    def literal_args(nodes) = nodes.map { |n| literal(n) }

    def literal_attrs(opts)
      opts.map { |k, v| [k, literal(v) || (literal_pairs(v) ? "{...}" : nil)] }.select { |_, v| v }
    end

    # A HashNode/KeywordHashNode whose keys and values are all literals -> [[k, v], ...]; else nil.
    def literal_pairs(node)
      return nil unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      node.elements.map do |e|
        return nil unless e.is_a?(Prism::AssocNode)
        k = literal(e.key)
        v = literal(e.value)
        return nil if k.nil? || v.nil?
        [k.to_s, v]
      end
    end

    def chain_calls?(node, method_name)
      n = node
      while n.is_a?(Prism::CallNode)
        return true if n.name.to_s == method_name
        n = n.receiver
      end
      false
    end

    def receiver_root_name(node)
      n = node
      n = n.receiver while n.is_a?(Prism::CallNode) && n.receiver
      case n
      when Prism::LocalVariableReadNode then n.name.to_s
      when Prism::CallNode then n.name.to_s
      when Prism::InstanceVariableReadNode then n.name.to_s
      else safe_slice(n)
      end
    end

    def root_is_local?(node)
      n = node
      n = n.receiver while n.is_a?(Prism::CallNode) && n.receiver
      n.is_a?(Prism::LocalVariableReadNode) || (n.is_a?(Prism::CallNode) && n.receiver.nil? && n.variable_call?)
    end

    def block_param_name(block)
      params = block.parameters&.parameters
      req = params&.requireds&.first
      req.respond_to?(:name) ? req.name.to_s : nil
    end

    def statements_of(body)
      case body
      when Prism::StatementsNode then body.body
      when Prism::BeginNode then body.statements&.body || []
      when nil then []
      else [body]
      end
    end

    def descendant_statements(node)
      out = []
      node.compact_child_nodes.each do |c|
        case c
        when Prism::StatementsNode then out.concat(c.body)
        when Prism::WhenNode, Prism::InNode, Prism::ElseNode then out.concat(statements_of(c.statements))
        end
      end
      out
    end

    def each_descendant(node, &blk)
      return unless node.respond_to?(:compact_child_nodes)
      blk.call(node)
      node.compact_child_nodes.each { |c| each_descendant(c, &blk) }
    end

    def safe_slice(node)
      node.slice
    rescue StandardError
      "?"
    end
  end
  private_constant :Walker
end
```

Prism API notes for the implementer: `CallNode#variable_call?` is true for a bare identifier Prism could not prove is a method call (`post`); `IfNode#subsequent` (Prism ≥ 0.29; older is `#consequent`) holds the `else`/`elsif` — the code above handles both; `ElseNode#statements` is a `StatementsNode`. Check the installed Prism with `ruby -rprism -e 'p Prism::VERSION'` and adjust the method name if needed — the test file pins behaviour, not method names.

- [ ] **Step 4: Run to verify it passes**

Run: `ruby runtime/sidecar/rails/test/templates_test.rb`
Expected: `PASS: templates_test.rb`. Work through failures one `check` at a time; the `state_or` precedence (request_state > ivar > fallback) and the `_buf`/`_out` unwrapping are the two places most likely to need adjustment.

- [ ] **Step 5: Commit**

```bash
git commit -F - -- runtime/sidecar/rails/templates.rb runtime/sidecar/rails/test/templates_test.rb <<'EOF'
Classify ERB fragments into the closed vocabulary (#167 Stage 1)

One node stream per template: text runs and code nodes each tagged with
a kind from the spec's table, with block structure explicit. The token
stream is compiled to a line-preserving Ruby program and parsed ONCE with
Prism, because a single `form_with ... do |f|` fragment is not Ruby on
its own but the whole program is -- that is what makes `do...end` and
`if...end` real AST nesting instead of a guess, and what makes a template
whose fragments do not assemble a parse error rather than a partial list.

Request-time state or an ivar anywhere inside an expression wins over the
fallback classification: that is the finding a human needs first, and
the #166 spike's 54% lexical precision is why this is an AST walk and not
a pattern table.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 6: The `templates` op in `analyze.rb`

**Files:**
- Modify: `runtime/sidecar/rails/analyze.rb` (requires, `dispatch`, new `handle_templates`, module doc's line-length note)
- Test: `runtime/sidecar/rails/test/analyze_test.rb`

**Interfaces:**
- Produces: request `{"op":"templates","root":"/abs","paths":["app/views/…", …]}` → response `{"ok":true,"locale":"en","templates":[{"path":"…","nodes":[…]} | {"path":"…","error":"…","line":N} | {"path":"…","unreadable":"…"}],"i18n_errors":[{"path","detail"}],"ruby":RUBY_INFO}`. `paths` are root-relative; more than `MAX_TEMPLATE_PATHS = 5000` entries answers `{"ok":false,"error":…}`. Output order equals request order.

- [ ] **Step 1: Write the failing test**

Append to `analyze_test.rb`, inside a new `Dir.mktmpdir` block after the existing ones:

```ruby
Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, "app/views/posts"))
  FileUtils.mkdir_p(File.join(dir, "config/locales"))
  File.write(File.join(dir, "config/locales/en.yml"), "en:\n  posts:\n    index:\n      heading: \"Posts\"\n")
  File.write(File.join(dir, "app/views/posts/index.html.erb"), "<h1><%= t(\".heading\") %></h1>\n<%= current_user.name %>\n")
  File.write(File.join(dir, "app/views/posts/broken.html.erb"), "<% if x %>\n")

  Open3.popen3("ruby", script) do |stdin, stdout, _stderr, _thr|
    stdin.puts JSON.generate({ op: "templates", root: dir, paths: ["app/views/posts/index.html.erb", "app/views/posts/broken.html.erb", "app/views/posts/missing.html.erb"] })
    stdin.flush
    res = JSON.parse(stdout.gets, symbolize_names: true)
    check("templates ok", res[:ok] == true)
    check("templates locale", res[:locale] == "en")
    check("templates ruby stamped", res[:ruby][:available] == true)
    t = res[:templates]
    check("order preserved", t.map { |x| x[:path] } == ["app/views/posts/index.html.erb", "app/views/posts/broken.html.erb", "app/views/posts/missing.html.erb"])
    kinds = t[0][:nodes].select { |n| n[:t] == "code" }.map { |n| n[:kind] }
    check("index kinds", kinds == %w[i18n request_state])
    check("i18n resolved through the op", t[0][:nodes].find { |n| n[:kind] == "i18n" }[:value] == "Posts")
    check("broken is a parse error with a line", t[1][:error].is_a?(String) && t[1][:line].is_a?(Integer))
    check("missing is unreadable, not fatal", t[2][:unreadable].is_a?(String))

    stdin.puts JSON.generate({ op: "templates", root: dir, paths: ["../etc/passwd"] })
    stdin.flush
    res = JSON.parse(stdout.gets, symbolize_names: true)
    check("a path escaping root is refused per-entry", res[:ok] == true && res[:templates][0][:unreadable]&.include?("outside"))

    stdin.puts JSON.generate({ op: "templates", root: dir, paths: "nope" })
    stdin.flush
    res = JSON.parse(stdout.gets, symbolize_names: true)
    check("non-array paths is ok:false", res[:ok] == false)
  end
end
```

Add `require "fileutils"` at the top of the file if absent.

- [ ] **Step 2: Run to verify it fails**

Run: `ruby runtime/sidecar/rails/test/analyze_test.rb`
Expected: `FAIL templates ok` (unknown op).

- [ ] **Step 3: Implement**

In `analyze.rb`: add `require_relative "templates"` and `require_relative "i18n"`. Update the module doc's line-length paragraph: the `templates` op DOES send inline data (a path list), and its cap is `MAX_TEMPLATE_PATHS` below — a request beyond it answers `ok:false` before any file is read. Add:

```ruby
  # A generous bound on one request's path list. Route-reachable templates
  # number in the hundreds on a large app; this cap exists so a malformed
  # request cannot make the sidecar buffer an unbounded line (see the
  # module doc's note on line length).
  MAX_TEMPLATE_PATHS = 5000

  # One response per requested path, in request order, each either a node
  # stream, a parse error with a line, or an unreadable reason. A path that
  # is absolute or escapes `root` after normalization is refused PER ENTRY
  # (`unreadable: "outside root"`) -- the request names files inside the
  # app under migration and nothing else.
  def self.handle_templates(req)
    root = req["root"]
    if !root.is_a?(String) || root.empty?
      return { ok: false, error: "templates: \"root\" must be a non-empty string", ruby: RUBY_INFO }
    end
    paths = req["paths"]
    return { ok: false, error: "templates: \"paths\" must be an array", ruby: RUBY_INFO } unless paths.is_a?(Array)
    return { ok: false, error: "templates: more than #{MAX_TEMPLATE_PATHS} paths", ruby: RUBY_INFO } if paths.length > MAX_TEMPLATE_PATHS

    table = RailsI18n.load(root)
    root_abs = File.expand_path(root)
    templates = paths.map do |rel|
      next { path: rel.to_s, unreadable: "path is not a string" } unless rel.is_a?(String)
      abs = File.expand_path(rel, root_abs)
      next { path: rel, unreadable: "outside root" } unless abs.start_with?("#{root_abs}/")
      source =
        begin
          File.read(abs)
        rescue SystemCallError, IOError => e
          next { path: rel, unreadable: "#{e.class}: #{e.message.gsub(abs, rel)}" }
        end
      res = RailsTemplates.analyze(source, path: rel, i18n: table)
      res[:error] ? { path: rel, error: res[:error], line: res[:line] } : { path: rel, nodes: res[:nodes] }
    end
    { ok: true, locale: table.locale, templates: templates, i18n_errors: table.errors, ruby: RUBY_INFO }
  end
```

and in `dispatch`: `when "templates" then handle_templates(req)`.

- [ ] **Step 4: Run to verify it passes**

Run: `for t in runtime/sidecar/rails/test/*.rb; do ruby "$t" || exit 1; done`
Expected: every file prints `PASS`.

- [ ] **Step 5: Commit**

```bash
git commit -F - -- runtime/sidecar/rails/analyze.rb runtime/sidecar/rails/test/analyze_test.rb <<'EOF'
Add the templates op: one node stream per route-reachable ERB (#167 Stage 1)

Same NDJSON protocol, same degrade-and-report contract: an unreadable or
unparsable template is a per-entry result, never a failed request, and a
path that escapes the app root is refused per entry. i18n is resolved
inline (default locale) because queryOnce closes stdin after one request
and a second op would be a second interpreter spawn. This op sends inline
data (a path list), so it carries the line-length cap analyze.rb's module
doc reserved for exactly that case.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 7: Zig client plumbing — `queryOnceTemplates`, controller `layouts`

**Files:**
- Modify: `src/cli/rails/sidecar_client.zig` (`queryOnce` split; new `queryOnceTemplates`)
- Modify: `src/cli/rails/controllers.zig` (`WireResponse.layouts`, `LayoutInfo`, `Result.layouts`, `freeResult`)
- Modify: `src/cli/rails/routes.zig:82-91` (the `Route.name` doc comment only)
- Test: inline `test` blocks in `controllers.zig`

**Interfaces:**
- Produces: `sidecar_client.queryOnceTemplates(io, gpa, child, root_abs, paths: []const []const u8) ![]u8` — writes `{"op":"templates","root":…,"paths":[…]}`, closes stdin, reads one line. `queryOnce` keeps its signature; both share a private `readOneLine`.
- Produces: `controllers.LayoutInfo = struct { controller: []const u8, value: ?[]const u8, disabled: bool, dynamic: bool, line: u64 }` (contract 2, owned strings); `controllers.Result.layouts: []LayoutInfo`; `controllers.findLayout(layouts, controller) ?LayoutInfo` (contract 3).

- [ ] **Step 1: Write the failing tests in `controllers.zig`**

```zig
test "decodeResponse: layouts[] decodes literal, disabled and dynamic shapes; absent layouts is empty" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"actions":[],"layouts":[
        \\{"controller":"pages","value":"marketing","disabled":false,"dynamic":false,"line":2},
        \\{"controller":"api","value":null,"disabled":true,"dynamic":false,"line":3},
        \\{"controller":"posts","value":null,"disabled":false,"dynamic":true,"line":4}
        \\],"unresolved":[],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, "app/controllers", &list);
    defer freeActions(gpa, d.actions);
    defer freeLayouts(gpa, d.layouts);
    defer sidecar_client.freeRuby(gpa, d.ruby);
    try std.testing.expectEqual(@as(usize, 3), d.layouts.len);
    const pages = findLayout(d.layouts, "pages").?;
    try std.testing.expectEqualStrings("marketing", pages.value.?);
    try std.testing.expect(!pages.disabled and !pages.dynamic);
    try std.testing.expect(findLayout(d.layouts, "api").?.disabled);
    try std.testing.expect(findLayout(d.layouts, "posts").?.dynamic);
    try std.testing.expectEqual(@as(u64, 4), findLayout(d.layouts, "posts").?.line);
    try std.testing.expect(findLayout(d.layouts, "nope") == null);

    const old = try decodeResponse(gpa, "{\"ok\":true,\"actions\":[],\"unresolved\":[]}", "app/controllers", &list);
    defer freeActions(gpa, old.actions);
    defer freeLayouts(gpa, old.layouts);
    defer sidecar_client.freeRuby(gpa, old.ruby);
    try std.testing.expectEqual(@as(usize, 0), old.layouts.len);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-rails`
Expected: compile error — `layouts`/`findLayout`/`freeLayouts` undefined.

- [ ] **Step 3: Implement**

`sidecar_client.zig`: split `queryOnce` into a request writer plus `readOneLine`:

```zig
fn readOneLine(io: Io, gpa: Allocator, child: *std.process.Child) ![]u8 {
    var rbuf: [4096]u8 = undefined;
    var fr = child.stdout.?.reader(io, &rbuf);
    var line_aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer line_aw.deinit();
    _ = try fr.interface.streamDelimiter(&line_aw.writer, '\n');
    return line_aw.toOwnedSlice();
}

fn closeStdin(io: Io, child: *std.process.Child) void {
    child.stdin.?.close(io);
    child.stdin = null;
}

pub fn queryOnce(io: Io, gpa: Allocator, child: *std.process.Child, op: []const u8, root_abs: []const u8) ![]u8 {
    var wbuf: [4096]u8 = undefined;
    var fw = child.stdin.?.writer(io, &wbuf);
    const w = &fw.interface;
    try w.writeAll("{\"op\":");
    try std.json.Stringify.value(op, .{}, w);
    try w.writeAll(",\"root\":");
    try std.json.Stringify.value(root_abs, .{}, w);
    try w.writeAll("}\n");
    try w.flush();
    closeStdin(io, child);
    return readOneLine(io, gpa, child);
}

/// Contract 1 (self-freeing), same shape as `queryOnce`: the only escaping
/// allocation is the response line. Writes the `templates` request --
/// `{"op":"templates","root":…,"paths":[…]}` -- for a root-relative path
/// list (`analyze.rb`'s `handle_templates` refuses anything else per
/// entry). The request line is bounded by the path list; `analyze.rb`
/// caps it at MAX_TEMPLATE_PATHS and answers ok:false beyond that.
pub fn queryOnceTemplates(io: Io, gpa: Allocator, child: *std.process.Child, root_abs: []const u8, paths: []const []const u8) ![]u8 {
    var wbuf: [4096]u8 = undefined;
    var fw = child.stdin.?.writer(io, &wbuf);
    const w = &fw.interface;
    try w.writeAll("{\"op\":\"templates\",\"root\":");
    try std.json.Stringify.value(root_abs, .{}, w);
    try w.writeAll(",\"paths\":");
    try std.json.Stringify.value(paths, .{}, w);
    try w.writeAll("}\n");
    try w.flush();
    closeStdin(io, child);
    return readOneLine(io, gpa, child);
}
```

Keep `queryOnce`'s existing doc comment; add a sentence that the read half is shared with `queryOnceTemplates`.

`controllers.zig`:

```zig
pub const LayoutInfo = struct {
    controller: []const u8,
    value: ?[]const u8,
    disabled: bool,
    dynamic: bool,
    line: u64,
};

const WireLayout = struct {
    controller: []const u8,
    value: ?[]const u8 = null,
    disabled: bool = false,
    dynamic: bool = false,
    line: u64 = 0,
};
```

Add `layouts: []const WireLayout = &.{},` to `WireResponse`; add `layouts: []LayoutInfo` to `Decoded` and `Result`; in `decodeResponse` after the actions loop:

```zig
    var layouts = try gpa.alloc(LayoutInfo, resp.layouts.len);
    var lfilled: usize = 0;
    errdefer {
        for (layouts[0..lfilled]) |l| freeLayoutFields(gpa, l);
        gpa.free(layouts);
    }
    for (resp.layouts, 0..) |wl, i| {
        const controller = try gpa.dupe(u8, wl.controller);
        errdefer gpa.free(controller);
        const value: ?[]const u8 = if (wl.value) |v| try gpa.dupe(u8, v) else null;
        layouts[i] = .{ .controller = controller, .value = value, .disabled = wl.disabled, .dynamic = wl.dynamic, .line = wl.line };
        lfilled = i + 1;
    }
```

Every early-return in `decodeResponse` and every `none` literal in `discoverControllers` sets `.layouts = &.{}`. Add:

```zig
fn freeLayoutFields(gpa: Allocator, l: LayoutInfo) void {
    gpa.free(l.controller);
    if (l.value) |v| gpa.free(v);
}

/// Contract 2 counterpart to `LayoutInfo`.
pub fn freeLayouts(gpa: Allocator, layouts: []LayoutInfo) void {
    for (layouts) |l| freeLayoutFields(gpa, l);
    gpa.free(layouts);
}

/// Contract 3: linear scan, returns a shallow copy aliasing `layouts`.
pub fn findLayout(layouts: []const LayoutInfo, controller: []const u8) ?LayoutInfo {
    for (layouts) |l| if (std.mem.eql(u8, l.controller, controller)) return l;
    return null;
}
```

`freeResult` frees `layouts` too. Update `routes.zig`'s `Route.name` doc: "Filled by `routes.rb`'s Mapper-faithful naming since #167 Stage 1; `null` when Rails itself would not name the route or when the route is `certain: false`."

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-rails && zig build check && zig build check -Dsingle-threaded`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git commit -F - -- src/cli/rails/sidecar_client.zig src/cli/rails/controllers.zig src/cli/rails/routes.zig <<'EOF'
Decode controller layouts; add the templates request writer (#167 Stage 1)

controllers.zig now carries the sidecar's `layouts[]` (literal, disabled,
dynamic) so layout resolution can prefer a declaration over convention.
sidecar_client gains queryOnceTemplates, which differs from queryOnce only
in its request body; the read half is shared rather than copied, for the
same reason the two files' original copies were extracted here.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 8: `fragments.zig` — the `templates` op client

**Files:**
- Create: `src/cli/rails/fragments.zig`
- Modify: `src/cli/rails/rails.zig` (add `const fragments = @import("fragments.zig");` and `pub const fragments_mod = fragments;` next to the other imports so `refAllDecls` reaches its tests)

**Interfaces:**
- Produces:

```zig
pub const Kind = enum { yield, yield_named, content_for, render_partial, render_partial_locals, render_dynamic,
    route_helper, route_helper_dynamic, link_to, asset, importmap, csrf, i18n, literal, form, form_field, errors,
    request_state, ivar, local, control, block_else, block_end, turbo_frame, turbo_stream, component_root, raw, unknown };
pub const Attr = struct { key: []const u8, value: []const u8 };
pub const Node = struct {
    text: ?[]const u8,      // non-null for a text run; every other field is then unset
    kind: Kind,             // `.unknown` for a wire kind this build does not recognise
    line: u64, col: u64,
    output: bool, code: []const u8,
    name: ?[]const u8, value: ?[]const u8,
    args: []const []const u8, attrs: []const Attr,
    missing: bool, dynamic: bool,
};
pub const Template = struct {
    path: []const u8,
    nodes: []Node,             // empty when `error_message`/`unreadable` is set
    error_message: ?[]const u8, error_line: ?u64,
    unreadable: ?[]const u8,
};
pub const Result = struct { templates: []Template, locale: ?[]const u8, ruby: sidecar_client.Ruby };
pub fn discoverTemplates(io, gpa, root_path, paths: []const []const u8, blocker_list, environ_map) Allocator.Error!Result;
pub fn freeResult(gpa, r: Result) void;
pub fn kindFromWire(s: []const u8) Kind;   // contract 3
```

- Degradation: every sidecar-side failure appends ONE `RAILS_TEMPLATES_UNAVAILABLE` blocker (`integrity = false`, `severity = .@"error"`, path `sidecar/rails/analyze.rb`) and returns an empty `templates` slice. An empty `paths` list never spawns Ruby and appends nothing. Per-entry `error`/`unreadable` are NOT blockers here — `findings.zig` turns them into findings (Task 9).

- [ ] **Step 1: Write the failing tests (in `fragments.zig`)**

```zig
test "decodeResponse: a node stream decodes with kinds, positions, args and attrs; unknown kind degrades" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const line =
        \\{"ok":true,"locale":"en","templates":[
        \\{"path":"app/views/posts/index.html.erb","nodes":[
        \\{"t":"text","text":"<h1>","line":1},
        \\{"t":"code","kind":"i18n","line":1,"col":5,"output":true,"code":"t(\".heading\")","name":"posts.index.heading","value":"Posts"},
        \\{"t":"code","kind":"link_to","line":2,"col":1,"output":true,"code":"link_to \"Home\", root_path","name":"root","args":["Home"],"attrs":[["class","x"]]},
        \\{"t":"code","kind":"something_new","line":3,"col":1,"output":false,"code":"zzz"}
        \\]},
        \\{"path":"app/views/posts/broken.html.erb","error":"unexpected end","line":4},
        \\{"path":"app/views/posts/gone.html.erb","unreadable":"Errno::ENOENT"}
        \\],"i18n_errors":[],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    const d = try decodeResponse(gpa, line, &list);
    defer freeResult(gpa, d);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqualStrings("en", d.locale.?);
    try std.testing.expectEqual(@as(usize, 3), d.templates.len);
    const t0 = d.templates[0];
    try std.testing.expectEqual(@as(usize, 4), t0.nodes.len);
    try std.testing.expectEqualStrings("<h1>", t0.nodes[0].text.?);
    try std.testing.expectEqual(Kind.i18n, t0.nodes[1].kind);
    try std.testing.expectEqualStrings("Posts", t0.nodes[1].value.?);
    try std.testing.expectEqual(@as(u64, 5), t0.nodes[1].col);
    try std.testing.expectEqual(Kind.link_to, t0.nodes[2].kind);
    try std.testing.expectEqualStrings("Home", t0.nodes[2].args[0]);
    try std.testing.expectEqualStrings("class", t0.nodes[2].attrs[0].key);
    try std.testing.expectEqual(Kind.unknown, t0.nodes[3].kind);
    try std.testing.expectEqualStrings("unexpected end", d.templates[1].error_message.?);
    try std.testing.expectEqual(@as(u64, 4), d.templates[1].error_line.?);
    try std.testing.expectEqualStrings("Errno::ENOENT", d.templates[2].unreadable.?);
}

test "decodeResponse: ok:false and a malformed line each become ONE RAILS_TEMPLATES_UNAVAILABLE blocker" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    const a = try decodeResponse(gpa, "{\"ok\":false,\"error\":\"boom\",\"ruby\":{\"available\":true}}", &list);
    defer freeResult(gpa, a);
    const b = try decodeResponse(gpa, "not json", &list);
    defer freeResult(gpa, b);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATES_UNAVAILABLE", list.items[0].code);
    try std.testing.expect(!list.items[0].integrity);
    try std.testing.expectEqual(blockers.Severity.@"error", list.items[0].severity);
    try std.testing.expectEqualStrings("boom", list.items[0].detail);
    try std.testing.expect(a.ruby.available);
    try std.testing.expect(!b.ruby.available);
}

test "decodeResponse: OOM at any point leaves no leak" {
    const line =
        \\{"ok":true,"locale":"en","templates":[{"path":"a.html.erb","nodes":[{"t":"text","text":"x","line":1},{"t":"code","kind":"asset","line":1,"col":2,"output":true,"code":"image_tag \"l\"","name":"image_tag","args":["l"],"attrs":[["alt","L"]]}]}],"i18n_errors":[],"ruby":{"available":true,"version":"3.4.10"}}
    ;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
        defer blockers.freeList(gpa, &list);
        const r = decodeResponse(gpa, line, &list) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        freeResult(gpa, r);
        break;
    }
}

test "kindFromWire covers every enum tag and falls back to unknown" {
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        try std.testing.expectEqual(@field(Kind, f.name), kindFromWire(f.name));
    }
    try std.testing.expectEqual(Kind.unknown, kindFromWire("never_heard_of_it"));
}

test "discoverTemplates: an empty path list never spawns and appends nothing" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.freeList(gpa, &list);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const r = try discoverTemplates(std.testing.io, gpa, ".", &.{}, &list, &env);
    defer freeResult(gpa, r);
    try std.testing.expectEqual(@as(usize, 0), r.templates.len);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}
```

(Match the exact `std.testing.io` / `Environ.Map` spelling used by `controllers.zig`'s own spawn tests — grep `test "discoverControllers` there and copy its setup.)

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-rails`
Expected: compile error, `fragments.zig` not found / not imported.

- [ ] **Step 3: Implement**

`fragments.zig` mirrors `controllers.zig` end to end. Module doc: what it is, the one-code degradation table, why per-entry errors are findings not blockers (a template that does not parse is a QUESTION for the operator — retain or block — not a fact about discovery integrity), std-only. Wire types:

```zig
const WireNode = struct {
    t: []const u8,
    text: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    line: u64 = 0,
    col: u64 = 0,
    output: bool = false,
    code: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    args: []const ?[]const u8 = &.{},
    attrs: []const []const ?[]const u8 = &.{},
    missing: bool = false,
    dynamic: bool = false,
};
const WireTemplate = struct {
    path: []const u8,
    nodes: []const WireNode = &.{},
    @"error": ?[]const u8 = null,
    line: ?u64 = null,
    unreadable: ?[]const u8 = null,
};
const WireResponse = struct {
    ok: bool,
    locale: ?[]const u8 = null,
    templates: []const WireTemplate = &.{},
    @"error": ?[]const u8 = null,
    ruby: ?sidecar_client.WireRuby = null,
};
```

`args` entries and `attrs` values may be JSON `null` (a nil literal) — decode as `?[]const u8` and dupe `""` for null. `kindFromWire` is an `inline for` over `@typeInfo(Kind).@"enum".fields` comparing `std.mem.eql`, returning `.unknown` otherwise. `decodeResponse(gpa, line, blocker_list) Allocator.Error!Result` follows `controllers.decodeResponse` exactly: `parseFromSlice` with `.ignore_unknown_fields = true`, blocker on parse failure and on `!resp.ok`, `decodeRuby`, then a `dupeTemplate` per entry with an element-then-array `errdefer` (the shape `rails.zig`'s `dupeNameList` documents). `Node` string fields are fresh dupes; `text` non-null exactly when `t == "text"`. `freeResult` releases everything. `discoverTemplates` copies `discoverControllers`' spawn/watchdog/query/kill/wait sequence with `queryOnceTemplates`, an early `if (paths.len == 0) return none;`, and `RAILS_TEMPLATES_UNAVAILABLE` at every degradation site. Contract docs: `decodeResponse`/`discoverTemplates` contract 2, `kindFromWire` contract 3.

In `rails.zig`, next to `const controllers = @import("controllers.zig");` add `const fragments = @import("fragments.zig");` and, so `refAllDecls` sees it, `pub const fragments_mod = fragments;` (the same trick used for any other sibling that is only referenced lazily — check how `schema_validate`/`assets` are reached; if every sibling is reached through a `pub` use, add a `test { _ = fragments; }` block instead).

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-rails && zig build check -Dsingle-threaded`
Expected: pass. The single-threaded gate matters: the watchdog spawn must be behind `if (comptime !builtin.single_threaded)` exactly as in `controllers.zig`.

- [ ] **Step 5: Commit**

```bash
git commit -F - -- src/cli/rails/fragments.zig src/cli/rails/rails.zig <<'EOF'
Client for the templates op: one node stream per template (#167 Stage 1)

Mirrors controllers.zig's spawn/decode/degrade shape. A wire kind this
build does not recognise decodes as `unknown` rather than being dropped,
the same forward-compatibility rule the blocker vocabulary follows. A
template's own parse error or unreadable reason is carried per entry, not
turned into a blocker here: it is a question for the operator (retain or
block), which is what findings are for.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 9: `findings.zig` — ids, choices, derivation

**Files:**
- Create: `src/cli/rails/findings.zig`
- Modify: `src/cli/rails/rails.zig` (import + `refAllDecls` reach, as in Task 8)

**Interfaces:**
- Produces:

```zig
pub const Severity = blockers.Severity;
pub const Finding = struct {
    id: []const u8,            // owned
    code: []const u8,          // static literal
    severity: Severity,
    path: []const u8,          // owned, root-relative
    line: ?u64,
    route_id: ?[]const u8,     // owned when non-null; null for every Stage 1 finding (template/controller-scoped)
    message: []const u8,       // owned; NOT identity
    choices: []const []const u8,  // static literal slice
    requires_artifact: bool,
};
pub fn escapePart(gpa, part) ![]u8;              // "%"->"%25", "."->"%2E"  (contract 1)
pub fn findingId(gpa, code, path, loc) ![]u8;    // escapePart(code) ++ "." ++ escapePart(path) ++ "." ++ escapePart(loc)  (contract 1)
pub fn lessThan(_: void, a: Finding, b: Finding) bool;  // (code, path, line, id) total order
pub fn free(gpa, list: []Finding) void;
pub const DeriveInput = struct {
    templates: []const fragments.Template,
    layouts: []const controllers.LayoutInfo,
    controller_files: []const ControllerFile,   // {controller, path} pairs from inventory, for RAILS_LAYOUT_DYNAMIC's path
    route_names: []const []const u8,            // names of `certain` routes
};
pub const ControllerFile = struct { controller: []const u8, path: []const u8 };
pub fn derive(gpa, in: DeriveInput) Allocator.Error![]Finding;   // contract 2, sorted by lessThan
```

- Derivation table (Stage 1):

| trigger | code | severity | choices |
| --- | --- | --- | --- |
| node `.unknown` | `RAILS_HELPER_UNKNOWN` | warn | island, retain, blocked |
| node `.request_state` / `.ivar` | `RAILS_REQUEST_TIME_STATE` | warn | island, spa, backend, retain, blocked |
| node `.i18n` with `missing` | `RAILS_I18N_UNRESOLVED` | warn | retain, blocked |
| node `.raw` | `RAILS_RAW_OUTPUT` | warn | island, retain, blocked |
| node `.render_dynamic` | `RAILS_PARTIAL_DYNAMIC` | warn | island, spa, retain, blocked |
| node `.route_helper_dynamic` | `RAILS_ROUTE_HELPER_DYNAMIC` | warn | island, spa, retain, blocked |
| node `.route_helper` / `.link_to` whose `name` is non-null and not in `route_names` | `RAILS_ROUTE_HELPER_UNKNOWN` | warn | retain, blocked |
| node `.control` | `RAILS_TEMPLATE_CONTROL_FLOW` | warn | island, spa, retain, blocked |
| template `error_message` | `RAILS_TEMPLATE_PARSE_ERROR` | error | retain, blocked |
| template `unreadable` | none here — `RAILS_TEMPLATE_UNREADABLE` blocker already exists from the transitive scan | | |
| layout `dynamic` | `RAILS_LAYOUT_DYNAMIC` | warn | retain, blocked |

- `loc` for a node finding is `"L<line>C<col>"`; for a parse error `"L<line>"`; for a layout `"L<line>"`. `line` on the `Finding` is the node line. Messages: `"unknown helper `<name>`"`, `"request-time state `<name>`"`, `"missing translation `<key>` (locale <locale>)"` (locale passed via `DeriveInput.locale: ?[]const u8`), `"unescaped output"`, `"dynamic render target `<name>`"`, `"route helper `<name>` has non-literal arguments"`, `"route helper `<name>` matches no certain named route"`, `"control flow `<name>`"`, `"template does not parse: <error>"`, `"controller declares a dynamic layout"`.

- [ ] **Step 1: Write the failing tests (in `findings.zig`)**

```zig
test "findingId escapes the separator reversibly" {
    const gpa = std.testing.allocator;
    const id = try findingId(gpa, "RAILS_HELPER_UNKNOWN", "app/views/posts/index.html.erb", "L3C5");
    defer gpa.free(id);
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/posts/index%2Ehtml%2Eerb.L3C5", id);
    const pct = try escapePart(gpa, "a%b.c");
    defer gpa.free(pct);
    try std.testing.expectEqualStrings("a%25b%2Ec", pct);
}

test "derive: one finding per triggering node, with code/choices/loc from the table, sorted" {
    const gpa = std.testing.allocator;
    var nodes = [_]fragments.Node{
        nodeText("<h1>", 1),
        nodeCode(.request_state, 2, 3, "current_user"),
        nodeCode(.unknown, 1, 9, "number_to_currency"),
        nodeCode(.route_helper, 4, 1, "root"),
        nodeCode(.route_helper, 5, 1, "ghost"),
        nodeCode(.link_to, 6, 1, "posts"),
        nodeCode(.raw, 7, 1, null),
    };
    var missing = nodeCode(.i18n, 8, 1, "posts.index.nope");
    missing.missing = true;
    const all = nodes ++ [_]fragments.Node{missing};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&all), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/posts/broken.html.erb", .nodes = &.{}, .error_message = "unexpected end", .error_line = 4, .unreadable = null },
    };
    const layouts = [_]controllers.LayoutInfo{
        .{ .controller = "posts", .value = null, .disabled = false, .dynamic = true, .line = 2 },
        .{ .controller = "pages", .value = "marketing", .disabled = false, .dynamic = false, .line = 2 },
    };
    const files = [_]ControllerFile{
        .{ .controller = "posts", .path = "app/controllers/posts_controller.rb" },
        .{ .controller = "pages", .path = "app/controllers/pages_controller.rb" },
    };
    const names = [_][]const u8{ "root", "posts" };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &layouts, .controller_files = &files, .route_names = &names, .locale = "en" });
    defer free(gpa, out);

    const expect_codes = [_][]const u8{
        "RAILS_HELPER_UNKNOWN",
        "RAILS_I18N_UNRESOLVED",
        "RAILS_LAYOUT_DYNAMIC",
        "RAILS_RAW_OUTPUT",
        "RAILS_REQUEST_TIME_STATE",
        "RAILS_ROUTE_HELPER_UNKNOWN",
        "RAILS_TEMPLATE_PARSE_ERROR",
    };
    try std.testing.expectEqual(expect_codes.len, out.len);
    for (expect_codes, out) |c, f| try std.testing.expectEqualStrings(c, f.code);

    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/posts/index%2Ehtml%2Eerb.L1C9", out[0].id);
    try std.testing.expectEqualStrings("app/controllers/posts_controller.rb", out[2].path);
    try std.testing.expectEqual(@as(?u64, 2), out[2].line);
    try std.testing.expectEqualStrings("ghost", out[5].message[std.mem.indexOf(u8, out[5].message, "ghost").?..][0..5]);
    try std.testing.expectEqual(blockers.Severity.@"error", out[6].severity);
    try std.testing.expectEqualStrings("retain", out[6].choices[0]);
    try std.testing.expect(out[0].route_id == null);
    try std.testing.expect(!out[0].requires_artifact);
}

test "derive: input order does not leak into output -- ids and order are identical either way" {
    const gpa = std.testing.allocator;
    const a_nodes = [_]fragments.Node{ nodeCode(.unknown, 3, 1, "foo"), nodeCode(.raw, 1, 1, null) };
    const b_nodes = [_]fragments.Node{ nodeCode(.raw, 1, 1, null), nodeCode(.unknown, 3, 1, "foo") };
    const tpl_a = [_]fragments.Template{
        .{ .path = "app/views/b.html.erb", .nodes = @constCast(&a_nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/a.html.erb", .nodes = @constCast(&a_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const tpl_b = [_]fragments.Template{
        .{ .path = "app/views/a.html.erb", .nodes = @constCast(&b_nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/b.html.erb", .nodes = @constCast(&b_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out_a = try derive(gpa, .{ .templates = &tpl_a, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out_a);
    const out_b = try derive(gpa, .{ .templates = &tpl_b, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out_b);
    try std.testing.expectEqual(@as(usize, 4), out_a.len);
    try std.testing.expectEqual(out_a.len, out_b.len);
    for (out_a, out_b) |x, y| try std.testing.expectEqualStrings(x.id, y.id);
    // (code, path, line, id): both HELPER_UNKNOWN rows sort before both RAW_OUTPUT rows, a.html before b.html within a code.
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/a%2Ehtml%2Eerb.L3C1", out_a[0].id);
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/b%2Ehtml%2Eerb.L3C1", out_a[1].id);
    try std.testing.expectEqualStrings("RAILS_RAW_OUTPUT.app/views/a%2Ehtml%2Eerb.L1C1", out_a[2].id);
}

fn nodeText(text: []const u8, line: u64) fragments.Node {
    return .{ .text = text, .kind = .literal, .line = line, .col = 0, .output = false, .code = "", .name = null, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}
fn nodeCode(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8) fragments.Node {
    return .{ .text = null, .kind = kind, .line = line, .col = col, .output = true, .code = "", .name = name, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}
```

Write the determinism test in full (two `derive` calls over the same templates listed in different orders; compare `id` sequences).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-rails`
Expected: compile error.

- [ ] **Step 3: Implement**

Static choice slices:

```zig
const choices_retain_blocked = [_][]const u8{ "retain", "blocked" };
const choices_island_retain_blocked = [_][]const u8{ "island", "retain", "blocked" };
const choices_island_spa_retain_blocked = [_][]const u8{ "island", "spa", "retain", "blocked" };
const choices_full = [_][]const u8{ "island", "spa", "backend", "retain", "blocked" };
```

`derive` walks templates in the order given, then layouts; appends via a private `append(gpa, list, code, severity, path, line, loc, message, choices)` that builds `id` with `findingId`, dupes `path`/`message`; messages via `std.fmt.allocPrint`. Route-name membership: a linear scan over `route_names` (a set the size of one app's route table). At the end `std.mem.sort(Finding, out, {}, lessThan)` and `toOwnedSlice`. `lessThan`: `std.mem.order` on code, then path, then `line orelse 0`, then id — a total order because `id` is unique per (code, path, loc). Contract docs on every function.

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-rails`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git commit -F - -- src/cli/rails/findings.zig src/cli/rails/rails.zig <<'EOF'
Derive findings from node streams with stable ids (#167 Stage 1)

A finding is a question for the operator with a fixed set of answers; a
blocker is a fact about discovery. Ids follow rails2zb's reversible
`%`/`.` escaping so a decision recorded against one survives a reworded
message, and the derivation table is the one place a fragment kind maps
to a code, a severity and its choices.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 10: Wire into `discover`: declared layouts, templates op, findings

**Files:**
- Modify: `src/cli/rails/rails.zig` (`Discovery`, `freeDiscovery`, `discover`, `classifyRoutes`, `resolveLayoutEntry`, the classify per-route loop)
- Test: inline tests in `rails.zig`

**Interfaces:**
- `Discovery` gains `fragments: []fragments.Template`, `findings: []findings.Finding`, `i18n_locale: ?[]const u8` (owned; all released by `freeDiscovery`).
- `resolveLayoutEntry(entries, controller, declared: ?controllers.LayoutInfo) ?inventory.Entry`: `declared.disabled` → `null`; `declared.value` literal → `matchesLayoutFor(entries, value)` (a declared layout that does not exist on disk falls through to `null`, not to convention — Rails would raise); `declared.dynamic` or `null` → the existing convention.
- `classifyRoutes` takes `layouts: []const controllers.LayoutInfo` and passes `controllers.findLayout(layouts, r.controller.?)` to `resolveLayoutEntry`.

- [ ] **Step 1: Write the failing tests**

```zig
test "resolveLayoutEntry: a literal declaration beats convention; false disables; dynamic keeps convention" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/application.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/layouts/marketing.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/layouts/posts.html.erb", .kind = .layout, .engine = .erb },
    };
    const lit: controllers.LayoutInfo = .{ .controller = "posts", .value = "marketing", .disabled = false, .dynamic = false, .line = 2 };
    try std.testing.expectEqualStrings("app/views/layouts/marketing.html.erb", resolveLayoutEntry(&entries, "posts", lit).?.path);
    const off: controllers.LayoutInfo = .{ .controller = "posts", .value = null, .disabled = true, .dynamic = false, .line = 2 };
    try std.testing.expect(resolveLayoutEntry(&entries, "posts", off) == null);
    const dyn: controllers.LayoutInfo = .{ .controller = "posts", .value = null, .disabled = false, .dynamic = true, .line = 2 };
    try std.testing.expectEqualStrings("app/views/layouts/posts.html.erb", resolveLayoutEntry(&entries, "posts", dyn).?.path);
    const ghost: controllers.LayoutInfo = .{ .controller = "posts", .value = "nope", .disabled = false, .dynamic = false, .line = 2 };
    try std.testing.expect(resolveLayoutEntry(&entries, "posts", ghost) == null);
}
```

(Match `inventory.Entry`'s real field list — open `inventory.zig` and copy a literal from an existing `rails.zig` test at `:2202`.)

Plus a `discover` fixture test: extend the existing test that runs `discover` on `tests/migrate/rails-sample` (grep `rails-sample` in `rails.zig`'s tests) to assert `d.findings.len > 0`, that a finding with code `RAILS_REQUEST_TIME_STATE` exists for path `app/views/posts/profile.html.erb`, and that `d.fragments.len == d.templates.len` filtered to `.erb` (guard the whole assertion with the same `ruby`-availability check that test already uses).

- [ ] **Step 2: Run to verify they fail**

Run: `ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime zig build test-rails`
Expected: compile errors (signature, fields).

- [ ] **Step 3: Implement**

In `discover`, after `classifyRoutes` (which now receives `ctrl_result.layouts`):

```zig
    // #167 Stage 1: one node stream per route-reachable ERB template. Only
    // `.erb` engines are sent -- a Haml/Slim template already carries
    // RAILS_TEMPLATE_ENGINE_UNSUPPORTED and can never be converted, so
    // asking the sidecar to scan it would only manufacture a parse error
    // on top of the real finding.
    var erb_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer erb_paths.deinit(gpa);
    for (classify_result.templates) |t| if (t.engine == .erb) try erb_paths.append(gpa, t.path);
    const frag_result = try fragments.discoverTemplates(io, gpa, app_path, erb_paths.items, &blocker_list, environ_map);
    errdefer fragments.freeResult(gpa, frag_result);

    var route_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer route_names.deinit(gpa);
    for (route_result.routes) |r| if (r.certain) if (r.name) |n| try route_names.append(gpa, n);
    var controller_files: std.ArrayListUnmanaged(findings.ControllerFile) = .empty;
    defer controller_files.deinit(gpa);
    for (wr.entries) |e| if (e.kind == .controller) try controller_files.append(gpa, .{ .controller = controllerKeyOf(e.path), .path = e.path });
    const finding_list = try findings.derive(gpa, .{
        .templates = frag_result.templates,
        .layouts = ctrl_result.layouts,
        .controller_files = controller_files.items,
        .route_names = route_names.items,
        .locale = frag_result.locale,
    });
    errdefer findings.free(gpa, finding_list);
```

`controllerKeyOf(path)` mirrors `analyze.rb`'s `controller_path_key`: strip `app/controllers/` and `.rb`, drop `_controller` from the last segment (contract 3, borrows into `path`; add a unit test with `app/controllers/admin/users_controller.rb` → `admin/users`). `frag_result.ruby` is folded into `combineRuby` the same way `ctrl_result.ruby` is (extend `combineRuby` to three halves, or call it twice). Since `fragments.Result` owns `templates` and `locale`, move them into `Discovery` (`.fragments = frag_result.templates, .i18n_locale = frag_result.locale`) and free only `frag_result.ruby` at the end; document that `freeDiscovery` releases the rest.

Update the `RouteTemplates`/`resolveLayoutEntry` doc comments: convention is no longer the only source.

- [ ] **Step 4: Run to verify it passes**

Run: `ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime zig build test-rails && zig build check -Dsingle-threaded && ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime bash tests/migrate/rails.sh && ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime bash tests/migrate/rails-legacy-assets.sh`
Expected: all PASS. `rails.sh`'s classification pins must be unchanged — no fixture controller declares a layout — and the blocker counts `rails-legacy-assets.sh` pins are unchanged because findings are not blockers.

- [ ] **Step 5: Commit**

```bash
git commit -F - -- src/cli/rails/rails.zig <<'EOF'
Wire template fragments and findings into discovery (#167 Stage 1)

Layout resolution now prefers a controller's literal `layout` over
convention, treats `layout false` as no layout, and keeps convention as
the honest approximation under a dynamic declaration (which is its own
finding). Every route-reachable .erb template is sent to the templates
op in one spawn; Haml/Slim are not, because they already carry the
engine blocker and can never convert. Findings escape the Discovery the
same way routes/templates/assets do.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 11: Manifest `findings[]`, schema regen, `MIGRATION.md` section

**Files:**
- Modify: `src/cli/rails/manifest.zig` (`FindingEntry`, `FindingSource`, `Manifest.findings`, `build`, golden test)
- Modify: `src/cli/rails/schema_gen.zig` (descriptions for the new fields)
- Regenerate: `contract/rails-presentation.v1.schema.json`
- Modify: `src/cli/rails/report.zig` (`Input.findings`, a `## Findings` section)
- Test: inline tests in `manifest.zig` and `report.zig`

**Interfaces:**
- Wire order (the contract): `FindingEntry { id, code, severity, source{file,line}, route_id, message, choices, requires_artifact }`; `Manifest.findings` is the LAST top-level key (after `blockers`). Sorted by `findings.lessThan`.
- `report.Input.findings: []const findings.Finding = &.{}`; the section renders `## Findings`, a one-line count per code (sorted), then one bullet per finding `- \`CODE\` \`path:line\` — message`.

- [ ] **Step 1: Write the failing tests**

In `manifest.zig`:

```zig
const two_choices = [_][]const u8{ "retain", "blocked" };

fn testFinding(code: []const u8, id: []const u8, path: []const u8, line: ?u64, message: []const u8) findings.Finding {
    return .{ .id = id, .code = code, .severity = .warn, .path = path, .line = line, .route_id = null, .message = message, .choices = &two_choices, .requires_artifact = false };
}

test "build: findings[] is emitted last, sorted by findings.lessThan, with the wire field order" {
    const gpa = testing.allocator;
    var fs = [_]findings.Finding{
        testFinding("RAILS_REQUEST_TIME_STATE", "RAILS_REQUEST_TIME_STATE.app/views/p%2Ehtml%2Eerb.L2C1", "app/views/p.html.erb", 2, "request-time state `current_user`"),
        testFinding("RAILS_HELPER_UNKNOWN", "RAILS_HELPER_UNKNOWN.app/views/p%2Ehtml%2Eerb.L1C1", "app/views/p.html.erb", 1, "unknown helper `foo`"),
    };
    const d: rails.Discovery = blk: {
        var v = emptyDiscovery();
        v.findings = &fs;
        break :blk v;
    };
    const out = try build(gpa, .{ .generator_version = "0.0.0-test", .root_evidence = &.{}, .discovery = &d });
    defer gpa.free(out);

    const blockers_at = std.mem.indexOf(u8, out, "\"blockers\": [").?;
    const findings_at = std.mem.indexOf(u8, out, "\"findings\": [").?;
    try testing.expect(findings_at > blockers_at);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("findings").?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("RAILS_HELPER_UNKNOWN", arr[0].object.get("code").?.string);
    try testing.expectEqualStrings("app/views/p.html.erb", arr[0].object.get("source").?.object.get("file").?.string);
    try testing.expectEqual(@as(i64, 1), arr[0].object.get("source").?.object.get("line").?.integer);
    try testing.expect(arr[0].object.get("route_id").? == .null);
    try testing.expectEqual(@as(usize, 2), arr[0].object.get("choices").?.array.items.len);
    try testing.expect(!arr[0].object.get("requires_artifact").?.bool);

    // Key order inside one finding object is the wire contract: assert the
    // byte offsets are strictly increasing within the first object.
    const first_obj = out[findings_at..std.mem.indexOfPos(u8, out, findings_at, "\"requires_artifact\"").? + 1];
    const keys = [_][]const u8{ "\"id\"", "\"code\"", "\"severity\"", "\"source\"", "\"route_id\"", "\"message\"", "\"choices\"", "\"requires_artifact\"" };
    var last: usize = 0;
    for (keys) |k| {
        const at = std.mem.indexOfPos(u8, first_obj, last, k).?;
        try testing.expect(at >= last);
        last = at + k.len;
    }
}
```

`emptyDiscovery()` (the helper the "fully degraded" test already uses) gains `.findings = &.{}`, `.fragments = &.{}`, `.i18n_locale = null` so every existing test literal keeps compiling. Extend `manifestGoldenBytes` (line ~784) expected bytes with `"findings": []` as the last key — this WILL fail first, which is the point.

In `report.zig`:

```zig
const report_choices = [_][]const u8{ "retain", "blocked" };

test "build: a Findings section lists count-per-code and one exact line per finding" {
    const fs = [_]findings.Finding{
        .{ .id = "RAILS_HELPER_UNKNOWN.app/views/posts/index%2Ehtml%2Eerb.L1C9", .code = "RAILS_HELPER_UNKNOWN", .severity = .warn, .path = "app/views/posts/index.html.erb", .line = 1, .route_id = null, .message = "unknown helper `number_to_currency`", .choices = &report_choices, .requires_artifact = false },
        .{ .id = "RAILS_LAYOUT_DYNAMIC.app/controllers/posts_controller%2Erb.L2", .code = "RAILS_LAYOUT_DYNAMIC", .severity = .warn, .path = "app/controllers/posts_controller.rb", .line = 2, .route_id = null, .message = "controller declares a dynamic layout", .choices = &report_choices, .requires_artifact = false },
    };
    const md = try build(std.testing.allocator, .{ .app_path = "app", .entries = &.{}, .integrations = &.{}, .blockers = &.{}, .findings = &fs });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n## Findings\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n- RAILS_HELPER_UNKNOWN: 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n- RAILS_LAYOUT_DYNAMIC: 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n- `RAILS_HELPER_UNKNOWN` `app/views/posts/index.html.erb:1` — unknown helper `number_to_currency` (choices: retain, blocked)\n") != null);
}

test "build: zero findings still renders the section, saying so" {
    const md = try build(std.testing.allocator, .{ .app_path = "app", .entries = &.{}, .integrations = &.{}, .blockers = &.{} });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n## Findings\n\nNone.\n") != null);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test-rails`
Expected: compile errors / golden mismatch.

- [ ] **Step 3: Implement**

`manifest.zig`:

```zig
pub const FindingSource = struct { file: []const u8, line: ?u64 };

/// Field order is the wire contract: id, code, severity, source, route_id,
/// message, choices, requires_artifact. `id` is the join key a decision
/// file references; `message` is prose and deliberately NOT identity.
pub const FindingEntry = struct {
    id: []const u8,
    code: []const u8,
    severity: blockers.Severity,
    source: FindingSource,
    route_id: ?[]const u8,
    message: []const u8,
    choices: []const []const u8,
    requires_artifact: bool,
};
```

Add `findings: []const FindingEntry,` as the last `Manifest` field; in `build`, a sorted private copy (`gpa.dupe` + `std.mem.sort` with `findings.lessThan`) mapped field-by-field; add to `manifest_value`. Update the module doc's key-order list.

`schema_gen.zig`: add description rows for `manifest.Manifest.findings` ("Questions for the operator … answered by id in MIGRATION.decisions.json (Stage 2); a blocker is a fact about discovery, a finding is a choice"), `manifest.FindingEntry.id` ("stable across runs and across message rewording; rails2zb's reversible `%`/`.` escaping"), `.choices`, `.requires_artifact`.

Regenerate: `zig build rails-schema`, then `zig build rails-check` must pass, then `bash tests/contract/rails-drift.sh`.

`report.zig`: add `findings` to `Input`; render the section after Blockers. Thread `finding_list` into `report.build` from `discover` (the call in Task 10 gains `.findings = finding_list`).

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-rails && zig build rails-check && bash tests/contract/rails-drift.sh && ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime bash tests/migrate/rails.sh`
Expected: all PASS; `rails.sh`'s manifest validation (`rails_manifest_validate`) accepts the new array.

- [ ] **Step 5: Commit**

```bash
git commit -F - -- src/cli/rails/manifest.zig src/cli/rails/schema_gen.zig src/cli/rails/report.zig src/cli/rails/rails.zig contract/rails-presentation.v1.schema.json <<'EOF'
Emit findings[] in the manifest and MIGRATION.md (#167 Stage 1)

Schema /1 has not shipped, so this is the window in which a required
top-level key can still be added (contract/rails-presentation.v1.schema.json's
own STABILITY note). findings[] is a separate array from blockers[] on
purpose: a consumer filtering blockers for exit-code facts must not have
operator questions mixed in, and a decision file joins on finding ids
alone.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 12: The `rails-presentation` fixture and its e2e; pins on the old fixture

**Files:**
- Create: `tests/migrate/rails-presentation/` (Rails app subset — see the tree below)
- Create: `tests/migrate/rails-presentation.sh`
- Modify: `tests/migrate/rails.sh` (route-name and findings pins on `rails-sample`)

**Fixture tree (Stage 1 subset; later stages add `backend/`, `MIGRATION.decisions.json`, JS, more views):**

```
tests/migrate/rails-presentation/
  Gemfile                      # rails 7.2, propshaft, turbo-rails, stimulus-rails
  Gemfile.lock                 # minimal specs: rails (7.2.1), propshaft, turbo-rails, stimulus-rails
  config/application.rb        # config.i18n.default_locale = :en
  config/routes.rb
  config/locales/en.yml
  app/controllers/pages_controller.rb      # layout "marketing"; def about; end; def help; end
  app/controllers/posts_controller.rb      # layout :choose; def index; @posts = Post.all; end; def show; @post = Post.find(params[:id]); end; private def choose; "application"; end
  app/controllers/sessions_controller.rb   # def new; end; def create; ...; end
  app/controllers/registrations_controller.rb  # def new; end; def create; ...; end
  app/views/layouts/application.html.erb   # <!DOCTYPE html>… <title><%= content_for?(:title) ? yield(:title) : t("site.name") %></title> <%= csrf_meta_tags %> <%= stylesheet_link_tag "application" %> <%= javascript_importmap_tags %> … <%= render "shared/nav" %> <main><%= yield %></main>
  app/views/layouts/marketing.html.erb     # same shell, different class; <%= yield %>
  app/views/shared/_nav.html.erb           # <nav><%= link_to t("nav.home"), root_path %> <%= link_to "About", about_path %> <%= link_to "Sign in", new_session_path %> <%= image_tag "logo.png", alt: "Logo" %></nav>
  app/views/pages/about.html.erb           # <% content_for :title do %>About<% end %><h1><%= t(".heading") %></h1><p>Static.</p>
  app/views/pages/help.html.erb            # <h1>Help</h1><%= number_to_currency(3) %><%== raw_html %><%= t(".missing") %>
  app/views/posts/index.html.erb           # <h1><%= t(".heading") %></h1><% @posts.each do |post| %><%= render partial: "post", locals: { post: post } %><% end %>
  app/views/posts/show.html.erb            # <h1><%= @post.title %></h1><%= link_to "Back", posts_path %>
  app/views/posts/_post.html.erb           # <article><%= link_to post.title, post_path(post) %></article>
  app/views/posts/legacy.html.haml         # %h1 Legacy
  app/views/sessions/new.html.erb          # <%= form_with(url: session_path) do |f| %><%= f.label :email %><%= f.email_field :email %><%= f.password_field :password %><%= f.submit "Sign in" %><% end %>
  app/views/registrations/new.html.erb     # <% if @user&.errors&.any? %><ul><% @user.errors.full_messages.each do |m| %><li><%= m %></li><% end %></ul><% end %><%= form_with(model: @user, url: registration_path) do |f| %>…<% end %>
  app/assets/images/logo.png               # any small PNG (copy tests/migrate/rails-sample/app/assets/images/logo.png)
  app/assets/stylesheets/application.css   # plain CSS
  public/assets/.manifest.json             # {"logo.png":"logo-abc123.png","application.css":"application-def456.css"}
  public/robots.txt
```

`config/routes.rb`:

```ruby
Rails.application.routes.draw do
  root "pages#about"
  get "/about", to: "pages#about"
  get "/help", to: "pages#help"
  resources :posts, only: [:index, :show]
  get "/posts/legacy", to: "posts#legacy"
  resource :session, only: [:new, :create]
  resource :registration, only: [:new, :create]
end
```

`config/locales/en.yml`:

```yaml
en:
  site:
    name: "Presentation Fixture"
  nav:
    home: "Home"
  pages:
    about:
      heading: "About us"
  posts:
    index:
      heading: "Posts"
```

- [ ] **Step 1: Write the fixture files** exactly as sketched (write out every file in full; the sketches above are the content).

- [ ] **Step 2: Write the failing e2e**

```bash
#!/usr/bin/env bash
# tests/migrate/rails-presentation.sh — #167 Stage 1: the manifest names
# every fragment a converter would refuse, and nothing else changes yet
# (no target output beyond the two discovery artifacts).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
fail() { echo "FAIL: $*"; exit 1; }
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"
[[ -x "$ZIGAPAGOS" ]] || zig build || fail "zig build failed"
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"
command -v ruby >/dev/null || { echo "SKIP: ruby not on PATH; Stage 1 findings need the sidecar"; exit 0; }
command -v jq >/dev/null || fail "jq required"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp -R "$REPO/tests/migrate/rails-presentation" "$WORK/app"
before="$(cd "$WORK/app" && find . -type f | sort | xargs shasum)"

"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out" || fail "migrate exited $?"
MANIFEST="$WORK/out/MIGRATION.manifest.json"
[[ -f "$MANIFEST" ]] || fail "no manifest"
listing="$(cd "$WORK/out" && find . -type f | sort | tr '\n' ' ')"
[[ "$listing" == "./MIGRATION.manifest.json ./MIGRATION.md " ]] || fail "Stage 1 must write only the two artifacts, got: $listing"

after="$(cd "$WORK/app" && find . -type f | sort | xargs shasum)"
[[ "$before" == "$after" ]] || fail "source tree modified"

# --- route names ------------------------------------------------------------
name_of() { jq -r --arg v "$1" --arg p "$2" '.routes[] | select(.verb == $v and .path == $p) | .name' "$MANIFEST"; }
[[ "$(name_of GET /)" == "root" ]] || fail "root name: $(name_of GET /)"
[[ "$(name_of GET /about)" == "about" ]] || fail "about name"
[[ "$(name_of GET /posts)" == "posts" ]] || fail "posts name"
[[ "$(name_of GET /posts/:id)" == "post" ]] || fail "post name"
[[ "$(name_of GET /session/new)" == "new_session" ]] || fail "new_session name"
[[ "$(name_of POST /registration)" == "registration" ]] || fail "registration name"

# --- layouts ---------------------------------------------------------------
about_layout=$(jq -r '.routes[] | select(.path == "/about") | .layout' "$MANIFEST")
[[ "$about_layout" == "app/views/layouts/marketing.html.erb" ]] || fail "declared layout not honoured: $about_layout"
posts_layout=$(jq -r '.routes[] | select(.path == "/posts" and .verb == "GET") | .layout' "$MANIFEST")
[[ "$posts_layout" == "app/views/layouts/application.html.erb" ]] || fail "dynamic layout must fall back to convention: $posts_layout"

# --- findings: exact id set ------------------------------------------------
# Every finding this stage can emit appears at least once, with the exact
# id that a Stage 2 decision file will reference. An id is (code, path,
# location) -- assert the WHOLE thing so a shifted line is caught.
have_finding() { jq -e --arg id "$1" '.findings[] | select(.id == $id)' "$MANIFEST" >/dev/null || fail "missing finding $1"; }
have_finding 'RAILS_HELPER_UNKNOWN.app/views/pages/help%2Ehtml%2Eerb.L1C13'
have_finding 'RAILS_RAW_OUTPUT.app/views/pages/help%2Ehtml%2Eerb.L1C39'
have_finding 'RAILS_I18N_UNRESOLVED.app/views/pages/help%2Ehtml%2Eerb.L1C55'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/posts/index%2Ehtml%2Eerb.L1C31'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/posts/show%2Ehtml%2Eerb.L1C5'
have_finding 'RAILS_ROUTE_HELPER_DYNAMIC.app/views/posts/_post%2Ehtml%2Eerb.L1C10'
have_finding 'RAILS_LAYOUT_DYNAMIC.app/controllers/posts_controller%2Erb.L2'
have_finding 'RAILS_REQUEST_TIME_STATE.app/views/registrations/new%2Ehtml%2Eerb.L1C1'
# The eight ids above are the EXPECTED shape; the literal columns depend on
# the exact bytes of the fixture files. Procedure, in this order:
#   1. write the fixture, run `migrate` once, and print
#        jq -r '.findings[].id' MIGRATION.manifest.json
#   2. check by eye that every id's L/C points at the `<%` of the fragment
#      the comment in the fixture file names (open the file, count columns);
#   3. paste those ids in here verbatim;
#   4. shift one fixture line (add a blank line at the top of help.html.erb),
#      confirm this script FAILS on the moved id, then revert.
# Never widen these to code-only greps: an id is what a decision file will
# reference, and a shifted line that still matched a code-only grep would
# silently orphan every recorded decision.

# The clean page raises NO finding; the Haml page raises none either (its
# blocker already exists and it was never sent to the templates op).
about_count=$(jq '[.findings[] | select(.source.file == "app/views/pages/about.html.erb")] | length' "$MANIFEST")
[[ "$about_count" == "0" ]] || fail "about.html.erb should be clean, got $about_count findings"
haml_count=$(jq '[.findings[] | select(.source.file | endswith(".haml"))] | length' "$MANIFEST")
[[ "$haml_count" == "0" ]] || fail "haml must not reach the templates op"
jq -e '.blockers[] | select(.code == "RAILS_TEMPLATE_ENGINE_UNSUPPORTED")' "$MANIFEST" >/dev/null || fail "haml blocker missing"

# Findings are not blockers: the exit code and --strict are unchanged by them.
"$ZIGAPAGOS" migrate "$WORK/app" --from rails --target "$WORK/out2" >/dev/null || fail "second run failed"
cmp "$MANIFEST" "$WORK/out2/MIGRATION.manifest.json" || fail "manifest not deterministic"

# Every finding has the wire shape and a choices list drawn from the fixed vocabulary.
bad=$(jq -r '.findings[] | select((.id|type) != "string" or (.choices|length) == 0 or (.choices - ["island","spa","backend","retain","blocked"] | length) != 0) | .id' "$MANIFEST")
[[ -z "$bad" ]] || fail "malformed findings: $bad"

# Schema validation of the real instance.
[[ -x "$REPO/zig-out/bin/rails_manifest_validate" ]] || zig build rails-manifest-validate || fail "validator build"
"$REPO/zig-out/bin/rails_manifest_validate" "$REPO/contract/rails-presentation.v1.schema.json" "$MANIFEST" || fail "manifest fails schema"

grep -q '^## Findings' "$WORK/out/MIGRATION.md" || fail "MIGRATION.md lacks a Findings section"
echo "PASS: tests/migrate/rails-presentation.sh"
```

Also append to `tests/migrate/rails.sh`, inside its `if command -v ruby` block near the classification pins:

```bash
  # #167 Stage 1: route names and findings on the original fixture.
  [[ "$(jq -r '.routes[] | select(.verb == "POST" and .path == "/posts/:id/publish") | .name' "$MANIFEST")" == "publish_post" ]] || fail "publish_post name"
  [[ "$(jq -r '.routes[] | select(.path == "/admin/users") | .name' "$MANIFEST")" == "admin_users" ]] || fail "admin_users name"
  [[ "$(jq -r '.routes[] | select(.path == "/admin/health") | .name' "$MANIFEST")" == "null" ]] || fail "an uncertain route must stay unnamed"
  jq -e '.findings[] | select(.code == "RAILS_REQUEST_TIME_STATE" and .source.file == "app/views/posts/profile.html.erb")' "$MANIFEST" >/dev/null || fail "profile finding"
  jq -e '.findings[] | select(.code == "RAILS_PARTIAL_DYNAMIC" and .source.file == "app/views/posts/featured.html.erb")' "$MANIFEST" >/dev/null || fail "featured render @post finding"
```

- [ ] **Step 3: Run to verify it fails without the fixture/pins, then passes**

Run: `bash tests/migrate/rails-presentation.sh` — first with one fixture line deliberately shifted (add a blank line at the top of `help.html.erb`) to prove the exact-id pins discriminate: expected `FAIL: missing finding RAILS_HELPER_UNKNOWN…`. Revert, run again: `PASS`. Then `bash tests/migrate/rails.sh`: `PASS`.

- [ ] **Step 4: Run the whole shell suite**

Run: `for f in tests/migrate/*.sh; do bash "$f" || exit 1; done` (unpiped, per CLAUDE.md's exit-code note).
Expected: every PASS/SKIP.

- [ ] **Step 5: Commit**

```bash
git add tests/migrate/rails-presentation tests/migrate/rails-presentation.sh
git commit -F - -- tests/migrate/rails-presentation tests/migrate/rails-presentation.sh tests/migrate/rails.sh <<'EOF'
Fixture and e2e for Stage 1 findings (#167)

One app carrying the supported matrix's Stage 1 half plus one of each
blocker, so "cannot be silently marked complete" is an assertion. Finding
ids are pinned WHOLE -- code, path and L/C location -- because an id is
what a decision file will reference, and a shifted line that still
matched a code-only grep would silently orphan every recorded decision.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

### Task 13: Docs, skill mirror, changelog, gates

**Files:**
- Modify: `docs/migration/rails-to-zigapagos.md` (new sections: "Route names", "Layouts", "Findings", "The fragment vocabulary" — the spec's table with the Stage 1 status column; the "Reading the manifest" section gains `findings[]`)
- Copy: `skills/zigapagos-rails-migration/references/rails-to-zigapagos.md` (byte-identical)
- Modify: `skills/zigapagos-rails-migration/SKILL.md` (a step "5. Read `findings[]`: each is a question with `choices`; nothing converts yet — Stage 2 adds `MIGRATION.decisions.json`"; keep ≤ 500 lines)
- Create: `changelog.d/rails-findings.md`

- [ ] **Step 1: Write the doc sections**

Route names: the derivation rules (the Task 1 list) and that an uncertain route stays unnamed. Layouts: literal beats convention, `false` disables, dynamic → convention + `RAILS_LAYOUT_DYNAMIC`. Findings: the id format with an example, the field list, "not a blocker; does not affect exit code or `--strict`", the Stage 1 derivation table. Fragment vocabulary: the spec's table verbatim with a fourth column "Stage 1 status" — `classified` for every row, `finding` where a code is emitted, and the note that conversion is Stage 2.

- [ ] **Step 2: Mirror and gate**

```bash
cp docs/migration/rails-to-zigapagos.md skills/zigapagos-rails-migration/references/rails-to-zigapagos.md
bash tests/skills/sync.sh
bash tests/branding.sh
bash tests/confidentiality.sh
```

Expected: all PASS.

- [ ] **Step 3: Changelog**

```markdown
<!-- changelog.d/rails-findings.md -->
### Added
- `zigapagos migrate --from rails`: every route-reachable ERB template is now parsed by the Ruby sidecar; the manifest gains `findings[]` (stable ids, choices) naming each fragment a converter would refuse, routes carry their Rails helper `name`, and a controller's literal `layout` declaration is honoured (#167 Stage 1).
```

(Match the existing `changelog.d/*.md` format — open `changelog.d/rails-target.md` and copy its heading style.)

- [ ] **Step 4: Full gate run**

```bash
git ls-files -z '*.zig' | xargs -0 -r zig fmt --check
zig build check && zig build check -Dsingle-threaded
zig build rails-check && bash tests/contract/rails-drift.sh
ZIGAPAGOS_RUNTIME_DIR=$PWD/runtime zig build test-rails
for t in runtime/sidecar/rails/test/*.rb; do ruby "$t" || exit 1; done
for f in tests/migrate/rails*.sh tests/skills/sync.sh; do bash "$f" || exit 1; done
bash scripts/check-allocator-contracts.sh
```

Expected: every command exits 0 (check `$?` after each; no pipes).

- [ ] **Step 5: Commit**

```bash
git commit -F - -- docs/migration/rails-to-zigapagos.md skills/zigapagos-rails-migration/references/rails-to-zigapagos.md skills/zigapagos-rails-migration/SKILL.md changelog.d/rails-findings.md <<'EOF'
Document route names, layouts and findings (#167 Stage 1)

The doc and its skill mirror land together because tests/skills/sync.sh
byte-compares them. The fragment table is the supported-matrix the issue
asks for, with a status column that says honestly what Stage 1 does:
classify and report, convert nothing.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016ceqUz8nDB4ouT3zjGBDR4
EOF
```

---

## Self-review

**Spec coverage (Stage 1 items):** sidecar `erb.rb` (T3), `templates` op with inline i18n (T4–T6), route names (T1), controller `layout` (T2), `findings[]` in the manifest with schema regen (T11), emitted codes `RAILS_HELPER_UNKNOWN`/`RAILS_REQUEST_TIME_STATE`/`RAILS_I18N_UNRESOLVED`/`RAILS_LAYOUT_DYNAMIC` plus the template-local `RAILS_RAW_OUTPUT`/`RAILS_PARTIAL_DYNAMIC`/`RAILS_ROUTE_HELPER_DYNAMIC`/`RAILS_ROUTE_HELPER_UNKNOWN`/`RAILS_TEMPLATE_CONTROL_FLOW`/`RAILS_TEMPLATE_PARSE_ERROR` (T9), no target output (T12 asserts the two-file listing), docs + skill mirror (T13). Codes the spec reserves for later stages (`RAILS_BACKEND_ENDPOINT`, `RAILS_AUTH_JOURNEY`, `RAILS_TURBO_*`, `RAILS_STIMULUS_CONTROLLER`, `RAILS_COMPONENT_*`, `RAILS_JS_ENTRY`, `RAILS_ASSET_TRANSFORM`, `RAILS_DECISION_STALE`, `RAILS_REDIRECT_HOST_CONFIG`, `RAILS_ROUTE_DYNAMIC_SEGMENT`, `RAILS_NO_TEMPLATE`) are deliberately absent.

**Type consistency:** `fragments.Kind` (T8) is the enum `findings.derive` (T9) switches on and `templates.rb` (T5) emits as strings; `controllers.LayoutInfo` (T7) is what `resolveLayoutEntry` (T10) and `findings.DeriveInput.layouts` (T9) consume; `findings.Finding` (T9) maps onto `manifest.FindingEntry` (T11) and `report.Input.findings` (T11); `findings.lessThan` is the one sort used by both `derive` and `manifest.build`.

**Placeholders:** none remain — every test in T1–T11 is written out. The one value the plan cannot precompute is the set of finding-id column literals in T12, which depend on the exact bytes of fixture files the implementer writes; T12 gives the four-step procedure (run, verify by eye, paste, prove with a shifted line) instead of a guess.
