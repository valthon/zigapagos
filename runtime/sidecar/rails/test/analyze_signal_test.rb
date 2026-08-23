require "json"
require "open3"
require "timeout"
require "tmpdir"

$failures = 0
def check(label, cond)
  return if cond
  warn "FAIL #{label}"; $failures += 1
end

script = File.expand_path("../analyze.rb", __dir__)

# Pins the review finding: `rescue Exception` at the process boundary
# (analyze.rb's `dispatch`) must not swallow SIGTERM/SIGINT delivered while
# a request is in flight. Before the fix, a signal landing mid-`dispatch`
# was caught by the broad rescue and answered as an ordinary
# `{"ok":false,"error":"SignalException: SIGTERM"}` line -- the sidecar
# survived and kept serving. That is wrong for a build-tool subprocess: a
# parent that sends SIGTERM on teardown expects the child to die, not to
# shrug the signal off and answer a request nobody wants answered anymore.
#
# The idle case (signal delivered while blocked on `$stdin.gets`, no
# request in flight) already terminated correctly even before the fix --
# that is the steady state between requests -- so this test deliberately
# targets the narrow busy-window case the reviewer identified: the signal
# must arrive while `dispatch` is actually executing.
#
# Determinism: parsing ~100,000 flat routes gives `dispatch` real CPU work
# (Prism parse + AST walk) comfortably past the 0.3s window this test needs,
# which is what creates a wide, reliable window for the signal to land
# mid-request rather than racing process startup or `$stdin.gets`. This was
# measured directly (~2.9s for 500k routes on the dev box, so ~0.6s expected
# at 100k -- still ~2x margin over the 0.3s sleep below at a tenth the
# ~440MB RSS / ~20MB temp-file cost of the original 1,000,000); it is a
# CPU-bound wall-clock budget, not a fixed sleep pinned to a guessed
# duration, so it degrades gracefully on slower hardware rather than
# flaking outright. If this ever proves flaky in CI, the fix is to RAISE the
# route count further, not to shrink the window.
Dir.mktmpdir do |dir|
  Dir.mkdir(File.join(dir, "config"))
  routes_lines = (1..100_000).map { |i| "  get \"/path_#{i}\"" }
  File.write(File.join(dir, "config/routes.rb"),
    "Rails.application.routes.draw do\n#{routes_lines.join("\n")}\nend\n")

  Open3.popen3("ruby", script) do |stdin, stdout, _stderr, wait_thr|
    stdin.puts JSON.generate({ op: "routes", root: dir })
    stdin.flush
    sleep 0.3 # let the parse/walk get well underway before the signal lands
    Process.kill("TERM", wait_thr.pid)

    # `wait_thr.value` blocks until the process actually exits -- which is
    # exactly what should happen quickly here. Bound it: if the fix ever
    # regresses, the process survives the signal and goes back to blocking
    # on stdin forever (verified by hand while developing this test), and an
    # unbounded `.value` would hang this test -- and CI -- rather than
    # failing it. Force-kill and report a clean failure instead.
    status =
      begin
        Timeout.timeout(10) { wait_thr.value }
      rescue Timeout::Error
        Process.kill("KILL", wait_thr.pid) rescue nil
        wait_thr.value
        nil
      end
    check("process terminated by SIGTERM instead of surviving it",
      !status.nil? && (status.signaled? || !status.success?))

    # Whatever (if anything) made it to stdout before the signal landed must
    # not be a normal `ok` response for the interrupted request -- the
    # request was abandoned mid-flight, not answered.
    leftover = stdout.read
    check("no ok response was written for the interrupted request",
      !leftover.include?(%("ok":true)))
  end
end

abort "#{$failures} analyze failure(s)" if $failures > 0
puts "PASS: analyze_signal_test.rb"
