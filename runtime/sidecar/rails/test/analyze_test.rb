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

  Dir.mkdir(File.join(dir, "app"))
  Dir.mkdir(File.join(dir, "app/controllers"))
  Dir.mkdir(File.join(dir, "app/controllers/admin"))
  File.write(File.join(dir, "app/controllers/posts_controller.rb"), <<~RB)
    class PostsController < ApplicationController
      def index; @posts = Post.all; end
    end
  RB
  # Namespaced, to pin that the controller key comes from the FILE PATH
  # (admin/users) and NOT from the Ruby class name alone.
  File.write(File.join(dir, "app/controllers/admin/users_controller.rb"), <<~RB)
    class Admin::UsersController < ApplicationController
      def create
        redirect_to root_path
      end
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
      controller: "posts", action: "index", only_redirect: false, renders_json: false, line: 2,
    })
    check("controllers: admin/users#create shape (path-derived key, not class name)", by_key["admin/users#create"] == {
      controller: "admin/users", action: "create", only_redirect: true, renders_json: false, line: 2,
    })
    check("controllers: exactly the two actions above, nothing else", res5[:actions].length == 2)

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

abort "#{$failures} analyze failure(s)" if $failures > 0
puts "PASS: analyze_test.rb"
