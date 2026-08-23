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

# Cases where a hand-tuned "linguistically correct" table diverged from
# ActiveSupport -- the module's actual correctness criterion is agreement
# with AS, since Rails computes the real :<singular>_id param through AS,
# not through English. These were found by cross-checking against a real
# activesupport install and fixed by porting AS's rule set faithfully.
assert_eq "quiz",     Inflect.singularize("quizzes"),    "quizzes (AS: doubled consonant + es)"
assert_eq "hero",     Inflect.singularize("heroes"),     "heroes (AS: o + es)"
assert_eq "datum",    Inflect.singularize("data"),       "data (AS: ia/ta -> um)"
assert_eq "medium",   Inflect.singularize("media"),      "media (AS: ia/ta -> um)"

# These three look like bugs -- they are not. This is AS's actual, real
# output for these inputs (verified directly against activesupport
# 8.1.3.1: "campuses".singularize == "campuse", etc). AS has no rule for a
# Latin "-us" noun pluralized with a bare "-es", so its generic "-ses" ->
# "-s" rule fires instead and eats a letter that isn't a plural marker.
# Since Rails would generate the identically "wrong" param name in a real
# app, matching AS here -- not "correcting" it -- is what makes this
# module accurate. Do not "fix" these back to campus/gas/virus.
assert_eq "campuse",  Inflect.singularize("campuses"),   "campuses (AS-faithful, not English-faithful)"
assert_eq "gase",     Inflect.singularize("gases"),      "gases (AS-faithful, not English-faithful)"
assert_eq "viruse",   Inflect.singularize("viruses"),    "viruses (AS-faithful, not English-faithful)"

# Case preservation -- an explicit brief requirement, but every assertion
# above uses lowercase input. The rewrite from a hand-rolled apply_case to
# raw String#sub! backreferences means case handling is now an emergent
# property of which AS rule fires, not an explicit code path -- these pin
# that behavior so a future SINGULAR_RULES edit that breaks it goes red
# instead of silently shipping. Expected values re-derived directly from
# live activesupport 8.1.3.1, not reasoned out.

# Backreference-preserving: the whole matched suffix is reproduced via \1,
# so the captured characters' original case survives intact, and any
# untouched prefix (never part of the regex match at all) is left as
# literal, unmodified original text.
assert_eq "Person",   Inflect.singularize("PEOPLE"),     "PEOPLE case (irregular rule, backreference-preserving)"
assert_eq "BOX",      Inflect.singularize("BOXES"),      "BOXES case (suffix rule, backreference-preserving)"

# Literal-suffix quirk: AS's own replacement templates append a hardcoded
# (always-lowercase) literal after the backreference, so a captured
# leading letter keeps the input's case while the literal tail does not.
# "CATEGORy" looks like a typo -- it is not. It is AS's actual, real output
# for this input; do not "fix" it back to "CATEGORY".
assert_eq "CATEGORy", Inflect.singularize("CATEGORIES"), "CATEGORIES case (AS literal-suffix quirk, AS-faithful not tidy)"

abort "#{$failures} inflect failure(s)" if $failures > 0
puts "PASS: inflect_test.rb"
