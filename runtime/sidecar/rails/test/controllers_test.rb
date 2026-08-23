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

# --- Fix round 1: findings 1-8 from task-1-review.md -----------------------
#
# `check` above only ever inspects `got[:actions]`; `controller` and
# `unresolved` are part of the brief's declared return shape too and had
# zero coverage (finding 5). This asserts all three at once.
def check_result(label, src, expected)
  got = RailsControllers.parse(src, path: "app/controllers/x_controller.rb")
  actual = {
    controller: got[:controller],
    actions: got[:actions].transform_values { |v| v.reject { |k, _| k == :line } },
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
  deep = "class C\n def a\n  x = " + ("[" * 20_000) + ("]" * 20_000) + "\n end\nend"
  got = RailsControllers.parse(deep, path: "app/controllers/deep_controller.rb")
  unless got[:unresolved].any? { |u| u[:code] == "RAILS_CONTROLLER_PARSE_ERROR" }
    warn "FAIL deeply-nested source should report RAILS_CONTROLLER_PARSE_ERROR, got #{got.inspect}"
    $failures += 1
  end
rescue SystemStackError => e
  warn "FAIL deeply-nested source raised #{e.class}: #{e.message} -- .parse must never raise"
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

# Proves the `SystemStackError` arm of `.parse`'s rescue degrades to a
# structured entry rather than propagating.
#
# This RAISES the error directly instead of feeding Prism deeply-nested source
# to provoke it. The original version built 20,000 nested `[` and relied on
# `Prism.parse` turning the resulting native-stack exhaustion into a catchable
# `SystemStackError`. That holds on Linux, but on the macOS arm64 CI runner the
# same input aborts the interpreter outright -- `Illegal instruction: 4`, a
# native SIGILL raised inside Prism's C parser, which kills the process before
# ANY Ruby rescue runs, including the one this check exists to exercise. It
# turned main red while passing everywhere it was developed (see
# controllers.rb's rescue for the behavioural caveat that follows from it).
#
# Injecting the exception tests the rescue clause itself, deterministically and
# on every platform, which is what the check was ever actually about.
module Prism
  class << self
    alias_method :__parse_before_stub, :parse
    def parse(source, **kwargs)
      raise SystemStackError, "stack level too deep" if source == "__FORCE_SYSTEM_STACK_ERROR__"
      __parse_before_stub(source, **kwargs)
    end
  end
end

deep = RailsControllers.parse("__FORCE_SYSTEM_STACK_ERROR__", path: "app/controllers/deep_controller.rb")

module Prism
  class << self
    alias_method :parse, :__parse_before_stub
    remove_method :__parse_before_stub
  end
end

deep_entry = deep[:unresolved].first
if deep_entry.nil? || deep_entry[:path] != "app/controllers/deep_controller.rb" ||
   deep_entry[:detail].start_with?("app/controllers/")
  warn "FAIL a SystemStackError-degraded parse's unresolved entry: path should be the caller's literal path, detail should not be prefixed with it; got #{deep_entry.inspect}"
  $failures += 1
end

abort "#{$failures} controllers failure(s)" if $failures > 0
puts "PASS: controllers_test.rb"
