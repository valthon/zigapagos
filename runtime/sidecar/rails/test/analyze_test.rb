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

    stdin.close
  end
end

abort "#{$failures} analyze failure(s)" if $failures > 0
puts "PASS: analyze_test.rb"
