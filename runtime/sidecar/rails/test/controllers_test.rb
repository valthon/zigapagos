require_relative "../controllers"

# Both SystemStackError checks below drive `.parse`'s rescue by RAISING the
# error, rather than by feeding Prism deeply-nested source to provoke it.
#
# The original form built 20,000 nested `[` and relied on the resulting
# native-stack exhaustion arriving as a catchable SystemStackError. It does on
# Linux. On the macOS arm64 CI runner the same input aborts the interpreter --
# `Illegal instruction: 4`, a SIGILL inside Prism's C parser -- which kills the
# process before ANY Ruby rescue runs, including the one these checks exist to
# exercise. It turned main red while passing everywhere it was developed.
#
# Producing the error is the platform-dependent part; catching it is not, and
# catching it is all these checks were ever about. See controllers.rb's rescue
# for the behavioural limit that follows.
FORCE_SYSTEM_STACK_ERROR = "__FORCE_SYSTEM_STACK_ERROR__"

def with_stack_overflow_on_parse
  Prism.singleton_class.alias_method(:__parse_before_stub, :parse)
  Prism.define_singleton_method(:parse) do |source, **kwargs|
    raise SystemStackError, "stack level too deep" if source == FORCE_SYSTEM_STACK_ERROR
    __parse_before_stub(source, **kwargs)
  end
  yield
ensure
  # `ensure`, not a trailing restore: if the rescue under test ever regresses
  # and the block raises, a leaked stub would silently corrupt every later
  # check in this file.
  Prism.singleton_class.alias_method(:parse, :__parse_before_stub)
  Prism.singleton_class.remove_method(:__parse_before_stub)
end

$failures = 0

# The per-action keys these shape checks deliberately do NOT look at.
# `:line` was never their subject; `:redirects` (#167 Stage 3 Task 2) is
# checked by `check_redirects` further down, on cases written for it --
# folding it into every expectation here would restate an empty array
# thirteen times and still not discriminate anything the dedicated checks
# do not already pin.
SHAPE_ONLY = %i[line redirects].freeze

def check(label, src, expected)
  got = RailsControllers.parse(src, path: "app/controllers/x_controller.rb")
  actual = got[:actions].transform_values { |v| v.reject { |k, _| SHAPE_ONLY.include?(k) } }
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

# --- Fix round 1: findings 1-8 from task-1-review.md -----------------------
#
# `check` above only ever inspects `got[:actions]`; `controller` and
# `unresolved` are part of the brief's declared return shape too and had
# zero coverage (finding 5). This asserts all three at once.
def check_result(label, src, expected)
  got = RailsControllers.parse(src, path: "app/controllers/x_controller.rb")
  actual = {
    controller: got[:controller],
    actions: got[:actions].transform_values { |v| v.reject { |k, _| SHAPE_ONLY.include?(k) } },
    unresolved_codes: got[:unresolved].map { |u| u[:code] },
  }
  return if actual == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  $failures += 1
end

# Finding 1 (HIGH): Prism.parse can raise SystemStackError on syntactically
# VALID but deeply-nested source. .parse must degrade to an unresolved entry
# for that one file, never raise -- a persistent sidecar walking many files
# per request cannot let one file's stack overflow take down the batch.
begin
  got = with_stack_overflow_on_parse do
    RailsControllers.parse(FORCE_SYSTEM_STACK_ERROR, path: "app/controllers/deep_controller.rb")
  end
  unless got[:unresolved].any? { |u| u[:code] == "RAILS_CONTROLLER_PARSE_ERROR" }
    warn "FAIL a stack-overflowing parse should report RAILS_CONTROLLER_PARSE_ERROR, got #{got.inspect}"
    $failures += 1
  end
rescue SystemStackError => e
  warn "FAIL a stack-overflowing parse raised #{e.class}: #{e.message} -- .parse must never raise"
  $failures += 1
end

# Finding 5 (MEDIUM): controller is asserted concretely on a normal parse,
# and unresolved is asserted empty on success / carries the right code on a
# genuine (non-stack-overflow) parse failure.
check_result "controller is the class name, and unresolved is empty on success",
  'class PostsController < ApplicationController
     def index; end
   end',
  { controller: "PostsController", actions: { "index" => { only_redirect: false, renders_json: false } }, unresolved_codes: [] }

check_result "a genuine parse failure reports RAILS_CONTROLLER_PARSE_ERROR and a nil controller",
  'class PostsController < ApplicationController
     def index(
   end',
  { controller: nil, actions: {}, unresolved_codes: ["RAILS_CONTROLLER_PARSE_ERROR"] }

# Finding 2 (HIGH), first bullet: a non-controller prelude class must not
# steal @controller or leak its methods into @actions -- the first
# Controller-suffixed class wins, and only ITS actions are recorded.
check_result "a prelude class before the real controller does not leak actions or steal the name",
  'class ApplicationHelper
     def helper_only; end
   end
   class PostsController < ApplicationController
     def index; end
   end',
  { controller: "PostsController", actions: { "index" => { only_redirect: false, renders_json: false } }, unresolved_codes: [] }

# Finding 2 (HIGH), fallback case: when NO class is Controller-suffixed, the
# first class in the file wins and the rest are not merged in -- this is the
# review's literal repro (`class Helper; ...; class C; ...`).
check_result "with no controller-named class, the first class wins and others are not merged",
  'class Helper
     def helper_only; end
   end
   class C
     def a; end
   end',
  { controller: "Helper", actions: { "helper_only" => { only_redirect: false, renders_json: false } }, unresolved_codes: [] }

# Finding 2 (HIGH), second bullet: two sibling namespaced controllers sharing
# one file, with a SAME-NAMED action, must not merge. This reproduces the
# review's worst-case: a plain content action wrongly reported
# only_redirect: true because a same-named redirect-only action existed in a
# later sibling class and silently overwrote the hash entry.
check_result "two sibling controllers sharing a file do not merge same-named actions",
  'module Admin
     class PostsController < ApplicationController
       def index; @posts = Post.all; end
     end
   end
   module Public
     class PostsController < ApplicationController
       def index; redirect_to root_path; end
     end
   end',
  { controller: "Admin::PostsController", actions: { "index" => { only_redirect: false, renders_json: false } }, unresolved_codes: [] }

# Finding 3 (HIGH): the brief's own "redirect with other statements" case has
# redirect_to as the SECOND statement, so it already fails the
# receiver/name check on stmts.first -- the `stmts.length == 1` boundary
# itself is never exercised by it. This case puts redirect_to FIRST, so only
# `length == 1` catches it.
check "a redirect as the first of two statements is not a pure redirect",
  'class SessionsController < ApplicationController
     def create
       redirect_to root_path
       Audit.record!(current_user)
     end
   end',
  { "create" => { only_redirect: false, renders_json: false } }

# Finding 6 (LOW): renders_json must key on the literal "json" keyword, not
# any keyword argument on a render call.
check "render with a non-json keyword does not count as renders_json",
  'class PostsController < ApplicationController
     def show; render xml: some_xml; end
   end',
  { "show" => { only_redirect: false, renders_json: false } }

# Finding 7 (LOW): a receiver-qualified redirect_to call (not the bare Rails
# controller method) must not count as a pure redirect.
check "a receiver-qualified redirect_to is not a pure redirect",
  'class SessionsController < ApplicationController
     def create
       helpers.redirect_to root_path
     end
   end',
  { "create" => { only_redirect: false, renders_json: false } }

# Finding 8 (LOW): a class method (def self.foo) is never a controller
# action, regardless of visibility.
check "a class method is not an action",
  'class PostsController < ApplicationController
     def self.foo; end
     def index; end
   end',
  { "index" => { only_redirect: false, renders_json: false } }

# --- B1 (final-fixes-B.md): unresolved entries carry `path` as its OWN key,
# separate from `detail`, and `detail` is the bare message -- NOT
# `"#{path}: message"`. `analyze.rb`'s `handle_controllers` is what computes
# a path relative to the app root and passes it in here; this module's own
# job is just to echo whatever `path:` it was given back out honestly,
# split into its own field rather than folded into `detail`'s text. Pinned
# on both of `.parse`'s failure branches (a genuine Prism rejection, and the
# `rescue StandardError`/`SystemStackError` catch-all).
genuine = RailsControllers.parse('class C
   def index(
 end', path: "app/controllers/x_controller.rb")
genuine_entry = genuine[:unresolved].first
if genuine_entry.nil? || genuine_entry[:path] != "app/controllers/x_controller.rb" ||
   genuine_entry[:detail].start_with?("app/controllers/")
  warn "FAIL a genuine parse failure's unresolved entry: path should be the caller's literal path, detail should not be prefixed with it; got #{genuine_entry.inspect}"
  $failures += 1
end

# Same rescue arm, checked for the OTHER property: that the degraded entry
# carries the caller's literal path and an unprefixed detail (see B1).
deep = with_stack_overflow_on_parse do
  RailsControllers.parse(FORCE_SYSTEM_STACK_ERROR, path: "app/controllers/deep_controller.rb")
end
deep_entry = deep[:unresolved].first
if deep_entry.nil? || deep_entry[:path] != "app/controllers/deep_controller.rb" ||
   deep_entry[:detail].start_with?("app/controllers/")
  warn "FAIL a SystemStackError-degraded parse's unresolved entry: path should be the caller's literal path, detail should not be prefixed with it; got #{deep_entry.inspect}"
  $failures += 1
end

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

# Fix round 1 (#167 Stage 1 review): `self.layout "x"` is the SAME
# class-level DSL call as the bare form -- unlike `def self.foo`/`def foo`
# (where a `self.` receiver on a DEF distinguishes a class method from an
# instance method), a `self` receiver on a plain method CALL inside a class
# body just names the receiver explicitly; it carries no such distinction
# for `layout`. Any OTHER receiver (`Foo.layout "x"`) is a different
# method entirely and must stay excluded.
check_layout "self.layout \"x\" is the same static declaration as the bare form",
             "class PagesController < ApplicationController\n  self.layout \"x\"\nend\n",
             { value: "x", line: 2 }
check_layout "self.layout :sym is dynamic, same as the bare form",
             "class PostsController < ApplicationController\n  self.layout :choose\nend\n",
             { dynamic: true, line: 2 }

# --- #167 Stage 3 Task 2: per-action `redirects` ---------------------------
#
# Stage 2 recorded only WHETHER an action's whole body was a redirect
# (`only_redirect`). The backend boundary needs WHERE it went: a form island
# that replaces a Rails mutation has to send the browser to the same place
# the Rails action did, and a `redirect` route's handoff `to` has been
# hardcoded null for want of exactly this fact.
#
# `name` is the route-helper STEM (`root` for `root_path`), because that is
# what the Zig side resolves against the recovered route table. Anything the
# static walk cannot reduce to a stem plus literal arguments is `dynamic`,
# INCLUDING a bare string (`redirect_to "/about"`): a path that names no
# helper cannot be smuggled into a field documented as a stem, and a
# consumer that guessed one would resolve it against the wrong table.
def check_redirects(label, src, expected)
  got = RailsControllers.parse(src, path: "app/controllers/x_controller.rb")
  actual = got[:actions].transform_values { |v| v[:redirects] }
  return if actual == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  $failures += 1
end

check_redirects "a bare helper call is a stem with no args",
  'class SessionsController < ApplicationController
     def create
       redirect_to root_path
     end
   end',
  { "create" => [{ name: "root", args: [] }] }

check_redirects "a _url helper is the same stem as a _path one",
  'class SessionsController < ApplicationController
     def create
       redirect_to posts_url
     end
   end',
  { "create" => [{ name: "posts", args: [] }] }

check_redirects "a literal argument rides along as a string",
  'class PostsController < ApplicationController
     def create
       redirect_to post_path(1)
     end
   end',
  { "create" => [{ name: "post", args: ["1"] }] }

# Rails' flash/status options are not part of the URL, so they must not
# push an otherwise-resolvable redirect into `dynamic`.
check_redirects "trailing keyword options do not make a redirect dynamic",
  'class PostsController < ApplicationController
     def create
       redirect_to root_path, notice: "Saved", status: :see_other
     end
   end',
  { "create" => [{ name: "root", args: [] }] }

check_redirects "redirect_to @post is dynamic",
  'class PostsController < ApplicationController
     def create
       redirect_to @post
     end
   end',
  { "create" => [{ dynamic: true }] }

check_redirects "a non-literal helper argument is dynamic",
  'class PostsController < ApplicationController
     def create
       redirect_to post_path(@post)
     end
   end',
  { "create" => [{ dynamic: true }] }

# Fix round 1, I-3: a literal string is its own variant. It cannot be `name`
# (no helper to resolve) and must not be `dynamic` (a consumer can use it
# verbatim).
check_redirects "a bare string is a literal path, not a stem and not dynamic",
  'class PagesController < ApplicationController
     def old
       redirect_to "/about"
     end
   end',
  { "old" => [{ path: "/about" }] }

check_redirects "an absolute URL rides the same path variant, unnormalised",
  'class PagesController < ApplicationController
     def old
       redirect_to "https://example.com/x"
     end
   end',
  { "old" => [{ path: "https://example.com/x" }] }

# An interpolated string is a request-time value, so it stays dynamic --
# `path` must mean "usable verbatim", or a consumer would emit `/posts/#{id}`
# into a static redirect.
check_redirects "an interpolated string is dynamic, not a literal path",
  'class PagesController < ApplicationController
     def old
       redirect_to "/posts/#{params[:id]}"
     end
   end',
  { "old" => [{ dynamic: true }] }

# Fix round 1, I-2: "there is a redirect, and it is unresolvable" is a
# different answer from "there is no redirect", and only the first is true
# here. An empty list would have a consumer render a page for a route the
# app never renders one for.
check_redirects "redirect_back is dynamic, not absent",
  'class PostsController < ApplicationController
     def create
       redirect_back fallback_location: root_path
     end
   end',
  { "create" => [{ dynamic: true }] }

check_redirects "redirect_back_or_to (Rails 7) is dynamic too",
  'class PostsController < ApplicationController
     def create
       redirect_back_or_to root_path
     end
   end',
  { "create" => [{ dynamic: true }] }

check_redirects "redirect_to :back is dynamic",
  'class PostsController < ApplicationController
     def create
       redirect_to :back
     end
   end',
  { "create" => [{ dynamic: true }] }

# The receiver rule again: `helpers.redirect_back` is a different method.
check_redirects "a receiver-qualified redirect_back is not collected",
  'class PostsController < ApplicationController
     def create
       other.redirect_back fallback_location: root_path
     end
   end',
  { "create" => [] }

# `only_redirect` looks only at the top-level statement shape; `redirects`
# must NOT -- a redirect inside an `if` is still where that branch goes, and
# is precisely the shape a converted form island has to reproduce.
check_redirects "redirects nested in a conditional are collected, in source order",
  'class SessionsController < ApplicationController
     def create
       if ok?
         redirect_to root_path
       else
         redirect_to new_session_path
       end
     end
   end',
  { "create" => [{ name: "root", args: [] }, { name: "new_session", args: [] }] }

check_redirects "an action with no redirect has an empty list, not nil",
  'class PostsController < ApplicationController
     def index; @posts = Post.all; end
   end',
  { "index" => [] }

# Finding 7's receiver rule again, now for `redirects`: `helpers.redirect_to`
# is a different method and must not be collected at all (not even as
# `dynamic`, which would raise a question about a redirect that is not one).
check_redirects "a receiver-qualified redirect_to is not collected",
  'class SessionsController < ApplicationController
     def create
       helpers.redirect_to root_path
     end
   end',
  { "create" => [] }

# --- #167 Stage 3 Task 2: class-level `before_action` ----------------------
#
# A7: a static page cannot enforce a Rails auth filter, so a page route whose
# controller runs one has to raise a finding rather than ship silently
# public. That needs the filter's NAME (the heuristic reads it) and its
# only:/except: scope (which actions it actually covers).
#
# `after_action`/`around_action` are deliberately NOT collected: they run
# after or around the response, so they cannot gate whether the page is
# reachable, which is the only question this field is asked.
def check_before_actions(label, src, expected)
  got = RailsControllers.parse(src, path: "app/controllers/x_controller.rb")
  return if got[:before_actions] == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{got[:before_actions].inspect}"
  $failures += 1
end

check_before_actions "an unscoped filter has both lists empty",
  "class PostsController < ApplicationController\n  before_action :require_login\nend\n",
  [{ name: "require_login", only: [], except: [], line: 2 }]

check_before_actions "only: [...] is recorded as written",
  "class PostsController < ApplicationController\n  before_action :require_login, only: [:index, :show]\nend\n",
  [{ name: "require_login", only: %w[index show], except: [], line: 2 }]

# Rails accepts a bare symbol wherever it accepts an array; normalising here
# means the Zig side has exactly one shape to reason about.
check_before_actions "except: :destroy normalises to a one-element array",
  "class PostsController < ApplicationController\n  before_action :set_post, except: :destroy\nend\n",
  [{ name: "set_post", only: [], except: ["destroy"], line: 2 }]

check_before_actions "several symbols on one call become one entry each",
  "class PostsController < ApplicationController\n  before_action :require_login, :set_post, only: [:edit]\nend\n",
  [{ name: "require_login", only: ["edit"], except: [], line: 2 },
   { name: "set_post", only: ["edit"], except: [], line: 2 }]

check_before_actions "a block filter is dynamic -- there is no name to read",
  "class PostsController < ApplicationController\n  before_action { head :forbidden unless current_user }\nend\n",
  [{ dynamic: true, line: 2 }]

# Rails registers both halves of `before_action(:x) { ... }`. The symbol is
# kept rather than the whole call degraded to dynamic, for the same reason
# `if:` is ignored: a dynamic entry has no name for the auth heuristic to
# read, so degrading here would lose the one guard this walk CAN see.
check_before_actions "a symbol with a block keeps the symbol; the block is the unread half",
  "class PostsController < ApplicationController\n  before_action(:require_login) { head :forbidden }\nend\n",
  [{ name: "require_login", only: [], except: [], line: 2 }]

check_before_actions "a proc argument is dynamic",
  "class PostsController < ApplicationController\n  before_action ->(c) { c.head :forbidden }\nend\n",
  [{ dynamic: true, line: 2 }]

check_before_actions "a non-literal only: list is dynamic, not a silently empty scope",
  "class PostsController < ApplicationController\n  before_action :require_login, only: GUARDED\nend\n",
  [{ dynamic: true, line: 2 }]

check_before_actions "after_action and around_action are ignored",
  "class PostsController < ApplicationController\n  after_action :audit\n  around_action :wrap\n  before_action :require_login\nend\n",
  [{ name: "require_login", only: [], except: [], line: 4 }]

# `self.before_action :x` is the same class-level DSL call as the bare form,
# exactly as `self.layout` already is; any OTHER receiver is a different
# method and must stay out.
check_before_actions "self.before_action is the same declaration; a foreign receiver is not",
  "class PostsController < ApplicationController\n  self.before_action :require_login\n  Foo.before_action :nope\nend\n",
  [{ name: "require_login", only: [], except: [], line: 2 }]

# `if:`/`unless:` make a filter CONDITIONAL at request time, and are
# deliberately ignored rather than degraded to `dynamic`: a dynamic entry
# carries no name, so the auth heuristic could not see it and the guarded
# page would ship silently public -- the exact failure A7 exists to prevent.
# Over-reporting a guard raises a question the operator can answer; under-
# reporting one does not.
check_before_actions "if:/unless: are ignored, so a conditional guard is still named",
  "class PostsController < ApplicationController\n  before_action :require_login, if: :protected?\nend\n",
  [{ name: "require_login", only: [], except: [], line: 2 }]

check_before_actions "a controller with no filters reports an empty list",
  "class PostsController < ApplicationController\n  def index; end\nend\n",
  []

# Fix round 1, I-4: Rails resolves `before_action "x"` and `before_action :x`
# to the same method, so a string is a name, not an unreadable filter.
check_before_actions "a string filter name is a name, not dynamic",
  "class PostsController < ApplicationController\n  before_action \"require_login\", only: [:index]\nend\n",
  [{ name: "require_login", only: ["index"], except: [], line: 2 }]

# --- Fix round 1, I-1: the inheritance chain -------------------------------
#
# `before_action :authenticate_user!` on ApplicationController is the
# commonest Rails auth idiom there is, and it is declared in a DIFFERENT file
# from every controller it guards. Without the superclass edge the filter is
# keyed `application` while every route names `posts`/`pages`, so no consumer
# can attribute it and every guarded page reports as unguarded.
#
# This module reports the superclass as SOURCE TEXT; turning it into a
# controller key is analyze.rb's job, and walking the chain is
# controllers.zig's.
def check_superclass(label, src, expected)
  got = RailsControllers.parse(src, path: "app/controllers/x_controller.rb")
  return if got[:superclass] == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{got[:superclass].inspect}"
  $failures += 1
end

check_superclass "a plain constant superclass is its source text",
  "class PostsController < ApplicationController\nend\n", "ApplicationController"
check_superclass "a namespaced superclass keeps every segment",
  "class PostsController < Admin::BaseController\nend\n", "Admin::BaseController"
check_superclass "the framework base class is reported as written; analyze.rb decides it is not a key",
  "class ApplicationController < ActionController::Base\nend\n", "ActionController::Base"
check_superclass "no superclass is nil", "class PostsController\nend\n", nil
# A computed superclass is not a name this walk can read. nil stops the chain
# there, which under-reports inherited filters -- the same direction every
# other unreadable construct degrades in, and better than attributing filters
# to a guessed parent.
check_superclass "a computed superclass is nil, not a guess",
  "class PostsController < base_for(:posts)\nend\n", nil
check_superclass "the superclass of the CHOSEN class, not of a prelude class",
  "class Helper < Object\nend\nclass PostsController < ApplicationController\nend\n",
  "ApplicationController"

# Fix round 2, N1: the `module` nesting the class was written in, which is
# Ruby's lexical scope for resolving the superclass NAME. Deliberately not the
# class's qualified name: the compact `class Admin::UsersController` form
# opens no module, so a bare superclass in it resolves at top level, while the
# same text inside `module Admin` tries `Admin::` first. analyze.rb needs the
# difference to look the parent up the way Ruby does.
def check_namespaces(label, src, expected)
  got = RailsControllers.parse(src, path: "app/controllers/x_controller.rb")
  return if got[:lexical_namespaces] == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{got[:lexical_namespaces].inspect}"
  $failures += 1
end

check_namespaces "a top-level class has no enclosing namespace",
  "class PostsController < ApplicationController\nend\n", []
check_namespaces "a nested module is the enclosing namespace",
  "module Admin\n  class UsersController < BaseController\n  end\nend\n", ["Admin"]
check_namespaces "every level of nesting is reported, outermost first",
  "module A\n  module B\n    class C < D\n    end\n  end\nend\n", %w[A B]
# Fix round 3, NEW-1: ONE entry per `module` keyword. Ruby's `Module.nesting`
# inside `module Admin::Deep` is `[Admin::Deep]` -- `Admin` is NOT in scope,
# so a bare superclass there is the TOP-LEVEL one even when
# `Admin::BaseController` exists (verified against real Ruby). Splitting the
# accumulated path on `::` invented an `Admin` scope and, worse, made this
# spelling indistinguishable from the nested one above.
check_namespaces "a compact module path is ONE scope, not one per segment",
  "module Admin::Deep\n  class UsersController < BaseController\n  end\nend\n",
  ["Admin::Deep"]
check_namespaces "a compact module path nested inside another module keeps both entries apart",
  "module Outer\n  module Admin::Deep\n    class C < D\n    end\n  end\nend\n",
  ["Outer", "Admin::Deep"]
# The compact form opens NO module -- Ruby looks a bare superclass up at top
# level here, and reporting ["Admin"] would send analyze.rb hunting for an
# `Admin::` parent Ruby never consults.
check_namespaces "the compact class form opens no module, so the scope is empty",
  "class Admin::UsersController < BaseController\nend\n", []

# --- Fix round 1, I-1: skip_before_action ----------------------------------
#
# A subclass that skips an inherited filter is how a Rails app makes its
# login page reachable. Without these the chain walk would raise a question
# about every one of them.
def check_skips(label, src, expected)
  got = RailsControllers.parse(src, path: "app/controllers/x_controller.rb")
  return if got[:skip_before_actions] == expected
  warn "FAIL #{label}\n  expected: #{expected.inspect}\n  actual:   #{got[:skip_before_actions].inspect}"
  $failures += 1
end

check_skips "a skip is recorded with the same shape as a filter",
  "class SessionsController < ApplicationController\n  skip_before_action :require_login, only: [:new, :create]\nend\n",
  [{ name: "require_login", only: %w[new create], except: [], line: 2 }]

check_skips "an unreadable skip scope is dynamic, same rule as a filter",
  "class SessionsController < ApplicationController\n  skip_before_action :require_login, only: OPEN\nend\n",
  [{ dynamic: true, line: 2 }]

# `raise: false` is an unknown option key and is ignored, exactly as `if:` is
# on a before_action -- it changes what Rails does when the named filter is
# absent, not which actions the skip covers.
check_skips "raise: false is ignored, not read as a scope",
  "class SessionsController < ApplicationController\n  skip_before_action :require_login, raise: false\nend\n",
  [{ name: "require_login", only: [], except: [], line: 2 }]

check_skips "a controller with no skips reports an empty list",
  "class PostsController < ApplicationController\n  before_action :require_login\nend\n", []

# The two lists must not bleed into each other in either direction.
check_before_actions "a skip does not appear among the before_actions",
  "class SessionsController < ApplicationController\n  skip_before_action :require_login\nend\n", []

# The fixture `tests/migrate/rails-presentation/` already exercises the
# `redirect` classification end to end; this pins that the fact Task 4 needs
# to fill its handoff `to` is actually recoverable FROM it, so a change to
# either the fixture or the walk that broke the pairing fails here rather
# than three suites away in a shell diff.
fixture = File.expand_path(
  "../../../../tests/migrate/rails-presentation/app/controllers/pages_controller.rb", __dir__
)
fixture_parsed = RailsControllers.parse(File.read(fixture), path: "app/controllers/pages_controller.rb")
if fixture_parsed[:actions].dig("old", :redirects) != [{ name: "about", args: [] }]
  warn "FAIL the rails-presentation fixture's pages#old should redirect to the `about` helper; got #{fixture_parsed[:actions]['old'].inspect}"
  $failures += 1
end

abort "#{$failures} controllers failure(s)" if $failures > 0
puts "PASS: controllers_test.rb"
