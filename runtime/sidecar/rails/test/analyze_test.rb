require "json"
require "open3"
require "tmpdir"
require "fileutils"

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

  Dir.mkdir(File.join(dir, "app"))
  Dir.mkdir(File.join(dir, "app/controllers"))
  Dir.mkdir(File.join(dir, "app/controllers/admin"))
  # Fix round 1, I-1: the two-file app the whole inheritance edge exists for.
  # The filter is declared HERE and nowhere else; every check below that
  # attributes it to `posts` goes through `parents`.
  File.write(File.join(dir, "app/controllers/application_controller.rb"), <<~RB)
    class ApplicationController < ActionController::Base
      before_action :authenticate_user!
    end
  RB
  # Fix round 2, N1: the namespace-relative chain. `BaseController` here is
  # Ruby's `Admin::BaseController`, and reading the name as written keyed the
  # edge `base` -- a controller no file produces -- so the guard declared one
  # level up was invisible from `admin/users`.
  File.write(File.join(dir, "app/controllers/admin/base_controller.rb"), <<~RB)
    module Admin
      class BaseController < ApplicationController
        before_action :require_admin_login
      end
    end
  RB
  File.write(File.join(dir, "app/controllers/posts_controller.rb"), <<~RB)
    class PostsController < ApplicationController
      def index; @posts = Post.all; end
    end
  RB
  # Namespaced, to pin that the controller key comes from the FILE PATH
  # (admin/users) and NOT from the Ruby class name alone.
  File.write(File.join(dir, "app/controllers/admin/users_controller.rb"), <<~RB)
    module Admin
      class UsersController < BaseController
        def create
          redirect_to root_path
        end
      end
    end
  RB
  File.write(File.join(dir, "app/controllers/pages_controller.rb"), <<~RB)
    class PagesController < ApplicationController
      layout "marketing"
      def about; end
    end
  RB
  # Fix round 1 (#167 Stage 1 review): a controller with a `layout` but NO
  # public actions -- e.g. an all-`private` base controller meant to be
  # subclassed. This is the ONLY fixture that discriminates the
  # `controller_key`-hoisting fix through the full `handle_controllers`
  # round trip: `pages_controller.rb` above has a public action, so it
  # would still report its layout even if that hoist were reverted (the
  # `next if result[:actions].empty?` guard would never fire for it).
  # `bare_controller.rb` has none, so it only reaches `layouts` if the key
  # is computed BEFORE that guard runs.
  File.write(File.join(dir, "app/controllers/bare_controller.rb"), <<~RB)
    class BareController < ApplicationController
      layout "bare"
      before_action :require_login

      private

      def helper; end
    end
  RB

  Open3.popen3("ruby", script) do |stdin, stdout, _stderr, _thr|
    stdin.puts JSON.generate({ op: "routes", root: dir })
    stdin.flush
    res = JSON.parse(stdout.gets, symbolize_names: true)
    check("ok", res[:ok] == true)
    paths = res[:routes].map { |r| "#{r[:verb]} #{r[:path]}" }.sort
    check("routes", paths == ["GET /", "GET /posts"])

    # `ruby` rides the "routes" response -- the sidecar answering with its
    # OWN interpreter's identity, not a second `version_check.rb` spawn.
    check("ruby.available", res[:ruby][:available] == true)
    check("ruby.version matches this process's own interpreter", res[:ruby][:version] == RUBY_VERSION)

    # Each route's `:line` is ITS OWN declaration line, not a constant and
    # not the enclosing `draw` block's (line 1): `root` is on line 2,
    # `resources :posts, only: [:index]` (which expands `GET /posts`) is on
    # line 3.
    by_path = res[:routes].each_with_object({}) { |r, h| h["#{r[:verb]} #{r[:path]}"] = r[:line] }
    check("root's line is its own declaration line, not the draw block's", by_path["GET /"] == 2)
    check("resources-expanded route's line is its own declaration line", by_path["GET /posts"] == 3)
    check("two routes at different source lines report different :line values", by_path["GET /"] != by_path["GET /posts"])

    # A second request on the SAME process: the sidecar is persistent.
    stdin.puts JSON.generate({ op: "routes", root: dir })
    stdin.flush
    check("second request answered", JSON.parse(stdout.gets, symbolize_names: true)[:ok] == true)

    # A missing routes.rb is a structured answer, not a crash -- and
    # specifically a structured FAILURE (ok: false), not just any structured
    # response: `res3.key?(:ok)` alone would also pass for `ok: true`, which
    # is the wrong outcome for a root with no config/routes.rb at all and
    # would not have caught a regression that silently reported success.
    stdin.puts JSON.generate({ op: "routes", root: File.join(dir, "nope") })
    stdin.flush
    res3 = JSON.parse(stdout.gets, symbolize_names: true)
    check("missing routes.rb answered structurally with ok: false", res3[:ok] == false)

    # Malformed input must not kill the process.
    stdin.puts "{not json"
    stdin.flush
    res4 = JSON.parse(stdout.gets, symbolize_names: true)
    check("malformed request answered", res4[:ok] == false)

    # `controllers` round trip: two files, one namespaced. Pins the exact
    # shape values (not just "a key exists") -- a regression that flipped
    # `only_redirect`/`renders_json`, or that derived the controller key
    # from the Ruby class name instead of the file path, must fail this.
    stdin.puts JSON.generate({ op: "controllers", root: dir })
    stdin.flush
    res5 = JSON.parse(stdout.gets, symbolize_names: true)
    check("controllers: ok", res5[:ok] == true)
    by_key = res5[:actions].to_h { |a| ["#{a[:controller]}##{a[:action]}", a] }
    check("controllers: posts#index shape", by_key["posts#index"] == {
      controller: "posts", action: "index", only_redirect: false, renders_json: false,
      redirects: [], line: 2,
    })
    # #167 Stage 3: `redirects` rides every action entry, and this is the one
    # that has one -- the round trip pins that the helper STEM survives
    # `handle_controllers`' flattening, not just `RailsControllers.parse`'s
    # own return (which controllers_test.rb covers directly).
    check("controllers: admin/users#create shape (path-derived key, not class name)", by_key["admin/users#create"] == {
      controller: "admin/users", action: "create", only_redirect: true, renders_json: false,
      redirects: [{ name: "root", args: [] }], line: 3,
    })
    # Three now, not two: `pages_controller.rb` (added below for the layout
    # checks) contributes its own `about` action, which this count must
    # keep counting -- a layout declaration does not exempt a controller
    # from the ordinary action walk.
    check("controllers: exactly the three actions above, nothing else", res5[:actions].length == 3)
    # Fix round 1 (task-2-fixes.md item 1): `RUBY_INFO` used to ride only
    # the "routes" response -- an app with `app/controllers/` but no
    # `config/routes.rb` then reported ruby.available: false even though
    # THIS very response proves Ruby ran and answered. Now stamped here too.
    check("controllers: ruby.available", res5[:ruby][:available] == true)
    check("controllers: ruby.version matches this process's own interpreter", res5[:ruby][:version] == RUBY_VERSION)

    # Task 2 (#167 Stage 1): the controller's `layout` declaration rides
    # its own flattened array, one entry per controller that declares one --
    # a controller that never calls `layout` (posts, admin/users) gets no
    # entry at all, not an entry with a null value, so the Zig side can
    # distinguish "no declaration, fall back to convention" from "declared
    # to use the default explicitly".
    layouts = res5[:layouts]
    check("layouts present", layouts.is_a?(Array))
    pages = layouts.find { |l| l[:controller] == "pages" }
    check("pages layout literal", pages == { controller: "pages", value: "marketing", disabled: false, dynamic: false, line: 2 })
    check("undeclared controllers have no layouts entry", layouts.none? { |l| l[:controller] == "posts" })
    # The named guarantee this brief calls out explicitly: a controller
    # that declares `layout` but has no public actions of its own must
    # still report its layout (only the per-action loop has nothing to
    # iterate). See bare_controller.rb's comment above for why this
    # fixture, specifically, is what discriminates the guard-reordering
    # fix -- `pages_controller.rb`'s check above cannot regress-detect it,
    # since that controller has a public action either way.
    bare = layouts.find { |l| l[:controller] == "bare" }
    check("a layout-only controller with no public actions still reports its layout",
          bare == { controller: "bare", value: "bare", disabled: false, dynamic: false, line: 2 })
    check("a layout-only controller with no public actions contributes no actions entry",
          res5[:actions].none? { |a| a[:controller] == "bare" })

    # #167 Stage 3: `before_actions` is flattened the same way, and
    # `bare_controller.rb` discriminates the same hoisting question the
    # layout check above does -- a base controller with NO public actions
    # still guards every subclass action, so its filters must survive the
    # `actions.empty?` guard. Nothing else in this fixture declares one, so
    # the exact-length check pins that no phantom entry appears either.
    # Sorted by `Dir.glob(...).sort`, so `application` precedes `bare`.
    check("controllers: before_actions carries the filter of an action-less base controller",
          res5[:before_actions] == [
            { controller: "admin/base", name: "require_admin_login", only: [], except: [], line: 3 },
            { controller: "application", name: "authenticate_user!", only: [], except: [], line: 2 },
            { controller: "bare", name: "require_login", only: [], except: [], line: 3 },
          ])

    # Fix round 1, I-1: the inheritance edges. `application` itself
    # contributes NONE -- its superclass is a framework base class, which is
    # where the chain has to terminate.
    # Fix round 2, N1: `admin/users` inherits `BaseController` written inside
    # `module Admin`, so its edge must be `admin/base` -- the key the file
    # actually produces -- and NOT the `base` the bare name spells.
    check("controllers: parents carries one edge per controller with a readable app superclass",
          res5[:parents] == [
            { controller: "admin/base", parent: "application" },
            { controller: "admin/users", parent: "admin/base" },
            { controller: "bare", parent: "application" },
            { controller: "pages", parent: "application" },
            { controller: "posts", parent: "application" },
          ])
    # And the guard one level up is now reachable from the leaf: this is the
    # whole point of the edge, checked on the wire rather than only in Zig.
    check("controllers: the namespaced base controller's filter is on the wire under its own key",
          res5[:before_actions].include?(
            { controller: "admin/base", name: "require_admin_login", only: [], except: [], line: 3 },
          ))
    check("controllers: a framework base class terminates the chain, it is not an edge",
          res5[:parents].none? { |p| p[:controller] == "application" })
    # Nothing in this fixture skips, but the key must still be present and an
    # array -- an absent key and an empty one are different answers.
    check("controllers: skip_before_actions is present and empty", res5[:skip_before_actions] == [])

    # An absent `app/controllers/` must answer structurally, not crash --
    # and specifically with ZERO actions found, not merely `ok: true` (which
    # `res3` above already shows a missing-root response can carry
    # regardless of `ok`).
    stdin.puts JSON.generate({ op: "controllers", root: File.join(dir, "nope") })
    stdin.flush
    res6 = JSON.parse(stdout.gets, symbolize_names: true)
    check("controllers: missing app/controllers/ answers ok: true", res6[:ok] == true)
    check("controllers: missing app/controllers/ finds zero actions", res6[:actions] == [])

    stdin.close
  end
end

# --- B1/B2 regression (final-fixes-B.md) -----------------------------------
#
# Absolute source paths must never leak into a blocker's `path`/`detail`:
# `analyze.rb`'s `handle_controllers`/`handle_routes` used to pass the
# ABSOLUTE glob result / `File.join(root, ...)` straight into
# `RailsControllers.parse`/`RailsRoutes.parse`'s `path:` argument, so the
# SAME app, analyzed at two different checkout directories, produced two
# different report byte sequences -- a determinism violation Stage 4's
# manifest drift gate cannot tolerate. Each helper below builds its OWN tmp
# dir (a fresh, differently-named absolute path every call), so calling one
# twice with byte-identical file CONTENTS is what actually proves the
# response is directory-independent, not merely "looks relative once".
def sidecar_response(script, op, root)
  Open3.popen3("ruby", script) do |stdin, stdout, _stderr, _thr|
    stdin.puts JSON.generate({ op: op, root: root })
    stdin.flush
    res = JSON.parse(stdout.gets, symbolize_names: true)
    stdin.close
    return res
  end
end

def controllers_response_with(script, src, filename)
  Dir.mktmpdir do |dir|
    Dir.mkdir(File.join(dir, "app"))
    Dir.mkdir(File.join(dir, "app/controllers"))
    File.write(File.join(dir, "app/controllers/#{filename}"), src)
    return sidecar_response(script, "controllers", dir)
  end
end

broken_controller_src = "class BrokenController\n  def index(\n  end\nend\n"
parse_res_a = controllers_response_with(script, broken_controller_src, "broken_controller.rb")
parse_res_b = controllers_response_with(script, broken_controller_src, "broken_controller.rb")

parse_a = parse_res_a[:unresolved].find { |u| u[:code] == "RAILS_CONTROLLER_PARSE_ERROR" }
parse_b = parse_res_b[:unresolved].find { |u| u[:code] == "RAILS_CONTROLLER_PARSE_ERROR" }
check("B1: broken controller reports RAILS_CONTROLLER_PARSE_ERROR (both runs)", !parse_a.nil? && !parse_b.nil?)
if parse_a && parse_b
  # Exact equality, not `include?`/basename-only -- an absolute path's
  # basename is identical to the relative one, so a substring check would
  # not have caught the original leak.
  check("B1: path is the exact app-relative literal, never the absolute checkout dir",
        parse_a[:path] == "app/controllers/broken_controller.rb")
  check("B1: two different checkout directories produce a BYTE-IDENTICAL detail",
        parse_a[:detail] == parse_b[:detail])
  check("B1: detail never starts with '/' (no absolute path leaked)",
        !parse_a[:detail].start_with?("/"))
end

# B2: a file `Dir.glob` finds but cannot READ reports RAILS_CONTROLLER_UNREADABLE,
# never RAILS_CONTROLLER_PARSE_ERROR (that code means the file WAS read and
# Prism rejected its contents -- a different finding). A dangling symlink is
# the repro: deterministic and portable across both CI OSes (unlike a
# chmod-based one, which the Zig-side tests already cover and which is
# unreliable under a root-run container). Its detail is ALSO pinned exactly:
# `e.message` is Ruby's OWN Errno formatting, generated from whatever path
# `File.read` was actually given (necessarily the absolute one, since a real
# read needs a real path) -- so this is the strongest test of B1's fix, a
# message this codebase does not construct itself and must instead sanitize.
Dir.mktmpdir do |dir2|
  Dir.mkdir(File.join(dir2, "app"))
  Dir.mkdir(File.join(dir2, "app/controllers"))
  File.symlink(File.join(dir2, "nonexistent-target-xyz"), File.join(dir2, "app/controllers/dangling_controller.rb"))
  res7 = sidecar_response(script, "controllers", dir2)
  unreadable = res7[:unresolved].find { |u| u[:code] == "RAILS_CONTROLLER_UNREADABLE" }
  check("B2: a dangling-symlink controller reports RAILS_CONTROLLER_UNREADABLE, not a parse error", !unreadable.nil?)
  if unreadable
    check("B2: path is the exact app-relative literal", unreadable[:path] == "app/controllers/dangling_controller.rb")
    check("B2: detail is the exact, sanitized Errno message (no absolute path)",
          unreadable[:detail] == "Errno::ENOENT: No such file or directory @ rb_sysopen - app/controllers/dangling_controller.rb")
  end
end

# Controller discovery follows in-root aliases but must never read through a
# symlink into a file outside app/controllers.
Dir.mktmpdir do |dir2|
  Dir.mktmpdir do |outside|
    FileUtils.mkdir_p(File.join(dir2, "app/controllers"))
    File.write(File.join(dir2, "app/controllers/posts_controller.rb"), "class PostsController < ApplicationController\n  def index; end\nend\n")
    File.write(File.join(outside, "secret_controller.rb"), "class SecretController < ApplicationController\n  def index; end\nend\n")
    begin
      File.symlink(File.join(dir2, "app/controllers/posts_controller.rb"), File.join(dir2, "app/controllers/alias_controller.rb"))
      File.symlink(File.join(outside, "secret_controller.rb"), File.join(dir2, "app/controllers/evil_controller.rb"))
      res = sidecar_response(script, "controllers", dir2)
      check("an in-root controller symlink is analyzed", res[:actions].any? { |a| a[:controller] == "alias" && a[:action] == "index" })
      escaped = res[:unresolved].find { |u| u[:path] == "app/controllers/evil_controller.rb" }
      check("an out-of-root controller symlink is refused", escaped && escaped[:code] == "RAILS_CONTROLLER_UNREADABLE" && escaped[:detail].include?("outside root"))
      check("an out-of-root controller contributes no actions", res[:actions].none? { |a| a[:controller] == "evil" })
    rescue NotImplementedError, Errno::EPERM => e
      warn "SKIP: controller symlink tests -- #{e.class}"
    end
  end
end

# B1, the ROUTES half: `config/routes.rb`'s reported path is a fixed
# relative literal now (it is always at the same place relative to `root`),
# never the absolute `routes_path` `handle_routes` used to compute via
# `File.join(root, ...)`. A single exact-prefix check is enough here (unlike
# the controllers case, there is no per-file computation left to regress
# independently of the literal itself) -- but it is run against a THIRD,
# freshly-named tmp dir, so a reversion back to the absolute form is caught
# the same way: the checkout directory's name would appear in `detail`.
Dir.mktmpdir do |dir3|
  Dir.mkdir(File.join(dir3, "config"))
  File.write(File.join(dir3, "config/routes.rb"), "Rails.application.routes.draw do\n  get \"/x\"(\nend\n")
  res8 = sidecar_response(script, "routes", dir3)
  route_err = res8[:unresolved]&.find { |u| u[:code] == "RAILS_ROUTES_PARSE_ERROR" }
  check("B1 (routes): a routes.rb parse error is reported", !route_err.nil?)
  if route_err
    check("B1 (routes): detail is the exact relative-path-prefixed message",
          route_err[:detail] == "config/routes.rb: unexpected '(', expecting end-of-input")
    check("B1 (routes): detail never contains the absolute checkout dir", !route_err[:detail].include?(dir3))
  end
end

# --- Task 6: the `templates` op ---------------------------------------
#
# One fixture covers all four response shapes at once: a template that
# parses AND resolves an i18n key through the SAME `RailsI18n.load` this
# handler runs once per request (not per template -- see analyze.rb);
# a template that fails to PARSE (an unterminated `if`, reported as
# `{error, line}`); a path that never existed on disk (`unreadable`,
# not a fatal request failure); and, in a second request on the SAME
# process, a path that escapes `root` after normalization.
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

    # Fix round 1 (#167 Stage 1 review, R11): `File.expand_path` normalizes
    # `.`/`..`/a leading `/` but does NOT resolve symlinks, so a symlinked
    # path could sail through that string-level check and read a file
    # OUTSIDE root -- the reviewer probed this live against the pre-fix
    # code. Three symlink shapes, one request: (evil) a symlink that
    # resolves outside `dir` entirely -- must be refused the same as a
    # literal `../` escape; (alias) a symlink that stays inside `dir` --
    # must read normally, since Rails apps legitimately use symlinks for
    # shared partials/generated code; (dangling) a symlink whose target
    # doesn't exist -- must degrade to `unreadable`, never raise, and the
    # whole op must still answer `ok: true`. Guarded so a platform without
    # `File.symlink` support (Windows; not one of this repo's two CI OSes)
    # skips loudly instead of failing opaquely.
    outside_dir = nil
    begin
      outside_dir = Dir.mktmpdir
      File.write(File.join(outside_dir, "secret.html.erb"), "<%= 'leaked' %>\n")
      File.symlink(File.join(outside_dir, "secret.html.erb"), File.join(dir, "app/views/posts/evil.html.erb"))
      File.symlink(File.join(dir, "app/views/posts/index.html.erb"), File.join(dir, "app/views/posts/alias.html.erb"))
      File.symlink(File.join(dir, "app/views/posts/does_not_exist.html.erb"), File.join(dir, "app/views/posts/dangling.html.erb"))

      stdin.puts JSON.generate({ op: "templates", root: dir, paths: ["app/views/posts/evil.html.erb", "app/views/posts/alias.html.erb", "app/views/posts/dangling.html.erb"] })
      stdin.flush
      res = JSON.parse(stdout.gets, symbolize_names: true)
      check("symlink request still answers ok:true", res[:ok] == true)
      t = res[:templates]
      check("a symlink resolving outside root is refused as outside root", t[0][:unreadable]&.include?("outside root"))
      check("a symlink resolving inside root reads as an ordinary node stream", t[1][:nodes].is_a?(Array))
      check("a dangling symlink is unreadable, not fatal", t[2][:unreadable].is_a?(String))
    rescue NotImplementedError, Errno::EPERM => e
      warn "SKIP: symlink tests -- #{e.class}: this platform does not support File.symlink"
    ensure
      FileUtils.remove_entry(outside_dir) if outside_dir && Dir.exist?(outside_dir)
    end

    stdin.puts JSON.generate({ op: "templates", root: dir, paths: "nope" })
    stdin.flush
    res = JSON.parse(stdout.gets, symbolize_names: true)
    check("non-array paths is ok:false", res[:ok] == false)
  end
end

# `handle_controllers`'s `rel_file = file.delete_prefix("#{root}/")` had the
# same trailing-slash defect as `RailsI18n.load` (i18n.rb): when `root`
# itself already ends with "/", `File.join` collapses the doubled slash in
# the glob result, so the literal `"#{root}/"` prefix (still doubled) never
# matches and `delete_prefix` is a no-op -- the ABSOLUTE path then leaks
# into `unresolved[].path`. A dangling symlink is the repro (as in the B2
# fixture above): deterministic, and it forces the `RAILS_CONTROLLER_UNREADABLE`
# branch that computes `rel_file` before this fix normalized `root`.
Dir.mktmpdir do |dir|
  Dir.mkdir(File.join(dir, "app"))
  Dir.mkdir(File.join(dir, "app/controllers"))
  File.symlink(File.join(dir, "nonexistent-target-xyz"), File.join(dir, "app/controllers/dangling_controller.rb"))
  res9 = sidecar_response(script, "controllers", "#{dir}/")
  unreadable9 = res9[:unresolved].find { |u| u[:code] == "RAILS_CONTROLLER_UNREADABLE" }
  check("trailing-slash root: unreadable-controller entry found", !unreadable9.nil?)
  check("trailing-slash root: unresolved path is still root-relative, not absolute",
        !unreadable9.nil? && unreadable9[:path] == "app/controllers/dangling_controller.rb")
end

# --- Fix round 1, I-1: superclass name -> controller key -------------------
#
# Loaded in-process rather than driven through the sidecar: this is a pure
# function over strings, and one round trip per name shape would cost a
# tmpdir and a subprocess to pin one substitution. `analyze.rb` guards its
# own `run` with `$PROGRAM_NAME == __FILE__`, so requiring it starts nothing.
require_relative "../analyze"

def check_key(name, expected)
  got = RailsAnalyze.controller_key_from_class_name(name)
  return if got == expected
  warn "FAIL controller_key_from_class_name(#{name.inspect}) => #{got.inspect}, want #{expected.inspect}"
  $failures += 1
end

check_key "ApplicationController", "application"
check_key "Admin::BaseController", "admin/base"
# A run of capitals stays one word -- `a_p_i` would key a controller nothing
# produces, silently dropping every filter declared on it.
check_key "APIController", "api"
check_key "TwoWordsController", "two_words"
# Not every parent is `...Controller`-suffixed; only the suffix is optional,
# not the conversion.
check_key "Authenticated", "authenticated"
check_key "::ApplicationController", "application"
# The chain must END at the framework, not hop to a key no file produces.
check_key "ActionController::Base", nil
check_key "ActionController::API", nil
check_key "ActionController::Metal", nil
check_key nil, nil
check_key "", nil
check_key "Controller", nil

# Fix round 2, N1: Ruby's lookup, innermost-outward, matched against the keys
# this walk actually saw.
def check_parent(name, namespaces, keys, expected)
  got = RailsAnalyze.resolve_parent_key(name, namespaces, keys)
  return if got == expected
  warn "FAIL resolve_parent_key(#{name.inspect}, #{namespaces.inspect}) => #{got.inspect}, want #{expected.inspect}"
  $failures += 1
end

seen = %w[application admin/base admin/users base]
# The lexical spelling: `BaseController` inside `module Admin` is Admin's.
check_parent "BaseController", ["Admin"], seen, "admin/base"
# The fully qualified spelling reaches the same class...
check_parent "Admin::BaseController", ["Admin"], seen, "admin/base"
# ...and so does the qualified spelling from outside the namespace.
check_parent "Admin::BaseController", [], seen, "admin/base"
# A bare name that only exists at top level is NOT captured by the namespace,
# even though a namespaced candidate is tried first: the candidate has to name
# a controller this walk saw.
check_parent "ApplicationController", ["Admin"], seen, "application"
# Deeper nesting searches innermost-outward. Discriminating that needs BOTH
# candidates to exist -- with only the outer one present, either direction
# lands on it and the search order means nothing.
check_parent "BaseController", %w[Admin Deep], seen, "admin/base"
check_parent "BaseController", %w[Admin Deep], seen + ["admin/deep/base"], "admin/deep/base"
# Fix round 3, NEW-1: `module Admin::Deep` is ONE scope entry, so the only
# namespaced candidate is `Admin::Deep::BaseController` -- `Admin` is not in
# Ruby's nesting there and must not be searched. With only `admin/base`
# around, the answer is the TOP-LEVEL `base`, not `admin/base`.
check_parent "BaseController", ["Admin::Deep"], seen, "base"
check_parent "BaseController", ["Admin::Deep"], seen + ["admin/deep/base"], "admin/deep/base"
# ... and with neither, it still falls back to the top-level reading.
check_parent "BaseController", ["Admin::Deep"], %w[application admin/base], "base"
# Nothing matched: the top-level reading is the answer, and the Zig-side walk
# simply finds no filters under it.
check_parent "SomeGemController", ["Admin"], seen, "some_gem"
# The framework still terminates the chain from inside a namespace.
check_parent "ActionController::Base", ["Admin"], seen, nil

abort "#{$failures} analyze failure(s)" if $failures > 0
puts "PASS: analyze_test.rb"
