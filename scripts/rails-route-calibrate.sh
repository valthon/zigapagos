#!/usr/bin/env bash
# rails-route-calibrate.sh -- developer-only calibration for RailsRoutes.parse
# (runtime/sidecar/rails/routes.rb) against real-world config/routes.rb files.
#
# ============================================================================
# THIRD-PARTY SOURCE WARNING -- DO NOT COMMIT ANYTHING THIS SCRIPT FETCHES
#
# This script downloads config/routes.rb from real open-source Rails apps
# into a `mktemp -d` scratch directory and deletes it on exit. Several of
# those projects (canvas-lms, redmine, openproject, diaspora, mastodon,
# discourse) are GPL/AGPL. This repository is MIT. Vendoring that source --
# or a fixture file derived from it -- into the repo would redistribute
# GPL/AGPL code from an MIT project. That is why this tool exists as a
# manual, uncommitted step rather than a CI gate or an in-repo fixture: the
# in-repo fixtures under tests/migrate/rails-sample/ are synthetic, authored
# for this project, exercising the same constructs without carrying anyone
# else's copyrighted source.
#
# NEVER run this with the corpus directory pointed at anything under the
# repo, and never `cp`/`git add` anything out of $CORPUS_DIR.
#
# The oracle (oracle_one.rb, below) goes further than fetching: it EVALUATES
# the fetched third-party routes.rb files via ActionDispatch, by design --
# that is the only way to get ground truth to calibrate the static parser
# against. Weigh that the same way you would any other "run untrusted code"
# step; only invoke this where evaluating fetched third-party Ruby is
# acceptable.
# ============================================================================
#
# This is a developer tool. It is NEVER invoked by CI (nothing in
# .github/workflows/ci.yml or the tests/*/*.sh gates calls it), it requires
# network access, and its recall/precision numbers depend on `actionpack` +
# `activesupport` being installed as gems -- both of which the shipped
# sidecar (runtime/sidecar/rails/*.rb) deliberately does NOT depend on. When
# either is unavailable this script degrades: no network means no corpus, no
# actionpack means route counts with no recall/precision, never a hard
# failure that could be confused with a real regression.
#
# What it measures: RailsRoutes.parse's *confident subset* (routes with
# certain: true) against ground truth -- every route a genuine
# ActionDispatch::Routing::RouteSet produces when it evaluates the same file.
# The oracle technique (stub missing constants/gems, swallow requires, record
# rather than raise on eval errors) mirrors the throwaway spike that
# justified this design (docs/superpowers/specs/2026-08-22-rails-source-
# discovery-design.md): 91.6% recall at 98.2% precision on the confident
# subset, across canvas-lms, redmine, lobsters, openproject, diaspora,
# huginn and zammad. This script lets a future change to routes.rb be
# re-measured against the same kind of corpus without re-running the spike
# by hand.
#
# Usage:
#   bash scripts/rails-route-calibrate.sh
#
# Env overrides (mirrors src/cli/rails/routes.zig's own env vars):
#   ZIGAPAGOS_RUBY   ruby binary to use (default: `ruby` on PATH)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
RAILS_SIDECAR_DIR="$REPO/runtime/sidecar/rails"
RUBY="${ZIGAPAGOS_RUBY:-ruby}"

if ! command -v "$RUBY" >/dev/null 2>&1; then
  echo "SKIP: no ruby on PATH (set ZIGAPAGOS_RUBY, or install ruby -- see mise.toml for the pinned version)"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "SKIP: no curl on PATH -- cannot fetch the corpus"
  exit 0
fi

# name|raw-file URL. All public GitHub repos; every one of these projects'
# LICENSE is GPL, AGPL, or otherwise copyleft/non-MIT, which is exactly why
# their routes.rb cannot live in this repo -- see the warning above.
CORPUS=(
  "mastodon|https://raw.githubusercontent.com/mastodon/mastodon/main/config/routes.rb"
  "discourse|https://raw.githubusercontent.com/discourse/discourse/main/config/routes.rb"
  "canvas-lms|https://raw.githubusercontent.com/instructure/canvas-lms/master/config/routes.rb"
  "redmine|https://raw.githubusercontent.com/redmine/redmine/master/config/routes.rb"
  "openproject|https://raw.githubusercontent.com/opf/openproject/dev/config/routes.rb"
  "diaspora|https://raw.githubusercontent.com/diaspora/diaspora/master/config/routes.rb"
  "huginn|https://raw.githubusercontent.com/huginn/huginn/master/config/routes.rb"
  "zammad|https://raw.githubusercontent.com/zammad/zammad/develop/config/routes.rb"
  "lobsters|https://raw.githubusercontent.com/lobsters/lobsters/master/config/routes.rb"
)

CORPUS_DIR="$(mktemp -d)"
trap 'rm -rf "$CORPUS_DIR"' EXIT
echo "Corpus + scratch files live only in $CORPUS_DIR (removed on exit; never the repo)."
echo

echo "Fetching corpus..."
fetched_names=()
for entry in "${CORPUS[@]}"; do
  name="${entry%%|*}"
  url="${entry#*|}"
  dest="$CORPUS_DIR/$name.routes.rb"
  if curl -fsSL -m 20 -o "$dest" "$url" 2>"$CORPUS_DIR/$name.fetch.err"; then
    echo "  ok    $name"
    fetched_names+=("$name")
  else
    reason="$(tail -n1 "$CORPUS_DIR/$name.fetch.err" 2>/dev/null)"
    echo "  SKIP  $name (fetch failed${reason:+: $reason})"
  fi
done
echo

if [[ ${#fetched_names[@]} -eq 0 ]]; then
  echo "No corpus files could be fetched -- is the network reachable?"
  echo "Nothing to calibrate; this is expected offline, not an error."
  exit 0
fi

oracle_available=0
if "$RUBY" -e 'require "action_dispatch"; require "active_support/all"' >/dev/null 2>&1; then
  oracle_available=1
else
  echo "actionpack/activesupport gems not found -- reporting route counts only,"
  echo "  no recall/precision. Install with: gem install actionpack activesupport"
  echo
fi

# --- helper scripts, written only into the scratch dir ---------------------

cat >"$CORPUS_DIR/parse_one.rb" <<'RUBY'
# Runs the SHIPPED parser (runtime/sidecar/rails/routes.rb, loaded via -I) --
# not a reimplementation -- over one corpus file. Any exception (this parser
# rescues StandardError internally already; this is defense against anything
# that slips past that, e.g. a pathological SystemStackError) is recorded
# rather than allowed to abort the rest of the corpus.
require "json"
require "routes"

src_path, out_path = ARGV
source = File.read(src_path)

result =
  begin
    RailsRoutes.parse(source, path: File.basename(src_path))
  rescue Exception => e
    { routes: [], unresolved: [{ code: "CALIBRATE_PARSER_CRASHED", detail: "#{e.class}: #{e.message}", line: 0 }] }
  end

File.write(out_path, JSON.generate({
  routes: result[:routes].map { |r| { verb: r[:verb], path: r[:path], certain: r[:certain] } },
  unresolved_codes: result[:unresolved].map { |u| u[:code] },
}))
RUBY

cat >"$CORPUS_DIR/oracle_one.rb" <<'RUBY'
# Ground truth: expand one config/routes.rb through a genuine
# ActionDispatch::Routing::RouteSet, the way Rails itself would. Adapted from
# the throwaway spike that justified this design (see the calibration
# script's own header) -- original tool code, not derived from any of the
# GPL/AGPL projects it is run against. Missing constants and gems are
# stubbed and swallowed, so a routes.rb that references e.g. Sidekiq::Web or
# an app-specific engine still draws everything it can; a genuinely fatal
# eval error is recorded rather than raised, so one bad file cannot abort
# calibration of the rest of the corpus.
require "json"
require "action_dispatch"
require "active_support/all"

module Kernel
  alias_method :__orig_require, :require
  def require(n)
    __orig_require(n)
  rescue Exception
    false
  end
  alias_method :__orig_require_relative, :require_relative
  def require_relative(_n) = false
end

class Module
  def const_missing(name)
    stub = Class.new do
      def self.method_missing(*, **, &_) = self
      def self.respond_to_missing?(*) = true
      def self.call(_env) = [200, {}, []]
      def self.instance = self
      def self.routes = $route_set
      def self.config = self
      def self.name = "Stub"
      def self.to_s = "Stub"
    end
    const_set(name, stub) rescue nil
    stub
  end
end

module Rails
  class FakeApp
    def routes = $route_set
    def config = self
    def method_missing(*, **, &_) = self
    def respond_to_missing?(*) = true
  end
  def self.application = (@app ||= FakeApp.new)
  def self.env = "production".inquiry
  def self.root = Pathname.new(Dir.pwd)
  def self.version = "8.1.3"
  def self.logger = nil
end

module ActionDispatch::Routing
  class RouteSet
    alias_method :__orig_add_route, :add_route
    def add_route(mapping, name)
      __orig_add_route(mapping, name)
    rescue ArgumentError => e
      raise unless e.message.include?("already in use")
      __orig_add_route(mapping, nil)
    end
  end
  class Mapper
    def method_missing(name, *args, **kw, &blk)
      # Still descend into blocks: nested real routes remain discoverable
      # even under a DSL call this stub doesn't recognize.
      blk ? instance_eval(&blk) : nil
    end
    def respond_to_missing?(*) = true

    # Apps that split routes across config/routes/*.rb (e.g. `draw(:api)`)
    # -- follow it into the sibling file when present, next to the corpus
    # file itself, never elsewhere.
    def draw(name)
      extra = File.join($corpus_dir, "#{$basename}_#{name}.rb")
      instance_eval(File.read(extra), extra) if File.exist?(extra)
      nil
    end
  end
end

src_path, out_path = ARGV
$corpus_dir = File.dirname(src_path)
$basename = File.basename(src_path, ".rb")
$route_set = ActionDispatch::Routing::RouteSet.new

err = nil
begin
  eval(File.read(src_path), TOPLEVEL_BINDING, src_path)
rescue Exception => e
  err = "#{e.class}: #{e.message}"
end

routes = $route_set.routes.map do |r|
  { verb: r.verb.to_s.gsub(/[$^]/, ""),
    path: r.path.spec.to_s.sub(/\(\.:format\)\z/, "") }
end

File.write(out_path, JSON.generate({ error: err, routes: routes }))
RUBY

cat >"$CORPUS_DIR/summarize.rb" <<'RUBY'
# summarize.rb <corpus_dir> <oracle_available:0|1> <name...>
require "json"

corpus_dir = ARGV[0]
oracle_available = ARGV[1] == "1"
names = ARGV[2..]

totals = { certain: 0, uncertain: 0, overlap: 0, oracle: 0 }
code_tally = Hash.new(0)

printf("%-14s %10s %9s %9s %8s %10s\n", "project", "oracle", "certain", "uncert.", "recall", "precision")
names.each do |name|
  parser_file = File.join(corpus_dir, "#{name}.parser.json")
  next unless File.exist?(parser_file)
  parser = JSON.parse(File.read(parser_file), symbolize_names: true)
  certain = parser[:routes].select { |r| r[:certain] }.map { |r| [r[:verb], r[:path]] }.uniq
  uncertain_count = parser[:routes].count { |r| !r[:certain] }
  parser[:unresolved_codes].each { |c| code_tally[c] += 1 }

  totals[:certain] += certain.size
  totals[:uncertain] += uncertain_count

  oracle_file = File.join(corpus_dir, "#{name}.oracle.json")
  if oracle_available && File.exist?(oracle_file)
    oracle = JSON.parse(File.read(oracle_file), symbolize_names: true)
    oracle_pairs = oracle[:routes].map { |r| [r[:verb], r[:path]] }.uniq
    overlap = (certain & oracle_pairs).size
    totals[:oracle] += oracle_pairs.size
    totals[:overlap] += overlap
    recall = oracle_pairs.empty? ? 0.0 : (100.0 * overlap / oracle_pairs.size)
    precision = certain.empty? ? 0.0 : (100.0 * overlap / certain.size)
    printf("%-14s %10d %9d %9d %7.1f%% %9.1f%%\n", name, oracle_pairs.size, certain.size, uncertain_count, recall, precision)
  else
    printf("%-14s %10s %9d %9d %8s %10s\n", name, "n/a", certain.size, uncertain_count, "n/a", "n/a")
  end
end

puts
if oracle_available && totals[:oracle] > 0
  agg_recall = 100.0 * totals[:overlap] / totals[:oracle]
  agg_precision = totals[:certain] > 0 ? 100.0 * totals[:overlap] / totals[:certain] : 0.0
  printf("aggregate: %d oracle routes, %d certain (parser), recall %.1f%%, precision %.1f%%\n",
         totals[:oracle], totals[:certain], agg_recall, agg_precision)
else
  puts "aggregate: #{totals[:certain]} certain routes, #{totals[:uncertain]} uncertain -- no oracle, so no recall/precision"
end

puts
puts "unresolved codes across corpus (what the parser refused to guess at):"
if code_tally.empty?
  puts "  none"
else
  code_tally.sort_by { |_, n| -n }.each { |code, n| printf("  %-28s %d\n", code, n) }
end
RUBY

# --- run the parser (and the oracle, if available) over each fetched file --

echo "Parsing corpus with RailsRoutes.parse..."
for name in "${fetched_names[@]}"; do
  src="$CORPUS_DIR/$name.routes.rb"
  "$RUBY" -I "$RAILS_SIDECAR_DIR" "$CORPUS_DIR/parse_one.rb" "$src" "$CORPUS_DIR/$name.parser.json" || true
  if [[ "$oracle_available" -eq 1 ]]; then
    "$RUBY" "$CORPUS_DIR/oracle_one.rb" "$src" "$CORPUS_DIR/$name.oracle.json" || true
  fi
done
echo

"$RUBY" "$CORPUS_DIR/summarize.rb" "$CORPUS_DIR" "$oracle_available" "${fetched_names[@]}"
