# Gem-free English singularizer for the route sidecar's static_ast mode.
#
# Why this exists at all: static_ast has to work on a Rails app that cannot
# boot, so ActiveSupport (and its inflector) is unavailable by design. A
# route declared bare inside `resources :people do ... end` nests under the
# parent's *singular* -- `:person_id`, not `:people_id` -- so getting this
# wrong silently produces a plausible-looking path that does not exist.
#
# CORRECTNESS CRITERION: agreement with ActiveSupport, not agreement with
# English. This module's job is not "be a good English singularizer" -- it
# is to predict the exact `:<singular>_id` param name that Rails will
# actually generate for a route nested bare inside a `resources` block.
# Rails computes that name by running the resource's plural through
# ActiveSupport::Inflector#singularize, so whatever AS actually outputs is
# ground truth here, however linguistically odd it looks. For example, AS's
# default rules singularize "campuses" to "campuse" (not "campus") and
# "gases" to "gase" (not "gas"), because AS has no specific rule for a
# Latin "-us" noun pluralized with a bare "-es". If a real Rails app has
# `resources :campuses`, Rails names the nesting param `:campuse_id` -- and
# a "more correct" inflector that guessed "campus" would predict a param
# that does not exist. Do NOT "fix" entries in SINGULAR_RULES that look
# like bad English; if they were ported faithfully from AS below, they are
# correct for this module's actual purpose. (An earlier version of this
# file was hand-tuned word-by-word against English and diverged from AS on
# exactly these cases -- see the test file's "AS-faithful, not English-
# faithful" cases and the task report for how that was found.)
#
# static_ast mode has no gems at runtime, so ActiveSupport itself is
# unavailable here. This file is a faithful, order-preserving port of
# ActiveSupport::Inflector.inflections(:en)'s default English rules, as
# read from the installed activesupport gem (8.1.3.1, under this repo's
# pinned Ruby 3.4.10):
#
#   ruby -e 'require "active_support/all"; \
#     infl = ActiveSupport::Inflector.inflections(:en); \
#     infl.singulars.each { |r, x| puts "#{r.inspect} => #{x.inspect}" }'
#
# cross-checked against the gem's source declarations in
# active_support/inflections.rb (the `inflect.singular(...)` /
# `inflect.irregular(...)` / `inflect.uncountable(...)` calls) and
# active_support/inflector/inflections.rb (Inflections#irregular, which
# expands each `irregular(singular, plural)` call into two `singular`
# regex rules: a self-matching idempotent rule for the word already in
# singular form, and the plural-to-singular rule -- both PREPENDED to AS's
# internal array, so the LAST-declared irregular ends up FIRST /
# highest-priority).
#
# ORDER IS THE WHOLE MODULE, same as it was before this rewrite -- only now
# the order is AS's own, not a hand-picked one. AS's apply_inflections
# walks its rule array top-to-bottom and applies the FIRST regex that
# actually matches (via String#sub!, stopping at the first successful
# match) -- it is not "most specific wins" or "longest match wins", it is
# "first in AS's declaration-derived order wins". SINGULAR_RULES below
# preserves that exact order; reordering it changes which rule wins on any
# input multiple rules could match, which is exactly the kind of silent
# drift this port exists to close off.
module Inflect
  # Faithful port of ActiveSupport's default :en uncountables (the
  # `inflect.uncountable(%w(...))` call in active_support/inflections.rb).
  # Checked as a trailing word-boundary match, mirroring AS's own
  # Inflections::Uncountables#uncountable? -- so a compound ending in an
  # uncountable word (e.g. "some_rice") also matches, same as AS.
  UNCOUNTABLES = %w[
    equipment information rice money species series fish sheep jeans police
  ].freeze

  # Faithful port of ActiveSupport::Inflector.inflections(:en).singulars,
  # in AS's own front-to-back precedence order (see module comment above).
  # Each entry is [regex, replacement]; replacement may contain \1/\2
  # backreferences, applied exactly as Ruby's String#sub! applies them.
  # That is also why case handling needs no separate code path here: a
  # backreference reproduces the actually-matched characters' original
  # case, while a literal replacement suffix (e.g. "erson") is whatever
  # case AS hardcoded -- always lowercase. That's why AS itself
  # singularizes "PEOPLE" to "Person", not "PERSON": only the captured
  # leading letter's case survives. This module intentionally reproduces
  # that, rather than "fixing" it into a full-string case re-application,
  # because reproducing AS's actual output is the point.
  SINGULAR_RULES = [
    [/(z)ombies$/i, '\1ombie'],
    [/(z)ombie$/i, '\1ombie'],
    [/(m)oves$/i, '\1ove'],
    [/(m)ove$/i, '\1ove'],
    [/(s)exes$/i, '\1ex'],
    [/(s)ex$/i, '\1ex'],
    [/(c)hildren$/i, '\1hild'],
    [/(c)hild$/i, '\1hild'],
    [/(m)en$/i, '\1an'],
    [/(m)an$/i, '\1an'],
    [/(p)eople$/i, '\1erson'],
    [/(p)erson$/i, '\1erson'],
    [/(database)s$/i, '\1'],
    [/(quiz)zes$/i, '\1'],
    [/(matr)ices$/i, '\1ix'],
    [/(vert|ind)ices$/i, '\1ex'],
    [/^(ox)en/i, '\1'],
    [/(alias|status)(es)?$/i, '\1'],
    [/(octop|vir)(us|i)$/i, '\1us'],
    [/^(a)x[ie]s$/i, '\1xis'],
    [/(cris|test)(is|es)$/i, '\1is'],
    [/(shoe)s$/i, '\1'],
    [/(o)es$/i, '\1'],
    [/(bus)(es)?$/i, '\1'],
    [/^(m|l)ice$/i, '\1ouse'],
    [/(x|ch|ss|sh)es$/i, '\1'],
    [/(m)ovies$/i, '\1ovie'],
    [/(s)eries$/i, '\1eries'],
    [/([^aeiouy]|qu)ies$/i, '\1y'],
    [/([lr])ves$/i, '\1f'],
    [/(tive)s$/i, '\1'],
    [/(hive)s$/i, '\1'],
    [/([^f])ves$/i, '\1fe'],
    [/(^analy)(sis|ses)$/i, '\1sis'],
    [/((a)naly|(b)a|(d)iagno|(p)arenthe|(p)rogno|(s)ynop|(t)he)(sis|ses)$/i, '\1sis'],
    [/([ti])a$/i, '\1um'],
    [/(n)ews$/i, '\1ews'],
    [/(ss)$/i, '\1'],
    [/s$/i, ''],
  ].freeze

  def self.singularize(word)
    str = word.to_s
    return word if str.empty? || uncountable?(str)

    result = str.dup
    SINGULAR_RULES.each do |(rule, replacement)|
      break if result.sub!(rule, replacement)
    end
    result
  end

  # Mirrors ActiveSupport::Inflector::Inflections::Uncountables#uncountable?
  # -- a case-insensitive match of any uncountable word anchored to the end
  # of the string, with a leading word boundary (so it matches whole-word
  # suffixes, not an uncountable word as a mid-word substring).
  def self.uncountable?(word)
    UNCOUNTABLES.any? { |u| word.match?(/\b#{Regexp.escape(u)}\z/i) }
  end
  private_class_method :uncountable?
end
