#!/usr/bin/env bash
# Regression test for issue #31: an unknown code-fence language used to be a
# HARD BUILD ERROR, with no list of registered languages anywhere and no
# near-match suggestion -- so the authoring loop was "guess a language, build
# for two minutes, fail, guess again". This pins the fix: an unknown language
# is now a WARNING (the build still succeeds and the fence renders as escaped,
# unhighlighted text -- exactly what `enable_treesitter=false` already
# produces for every language), the warning names a did-you-mean suggestion,
# and `zigapagos languages` exists to answer "what IS registered" directly.
#
# Fixture: tests/rendering/simple/ (clean, no pre-existing errors) plus one
# extra page with a ```jsonc fence -- "jsonc" is not a flow_syntax language
# name, but it IS distance 1 from the registered "json", so it exercises the
# did-you-mean path deterministically (see src/languages.zig's `suggest`).
#
# NOT claimed: that every unknown language gets a suggestion (src/languages.zig
# pins a genuine no-match case, "frobnicate", separately) -- only that THIS
# one, common typo-shaped case does.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

SITE="$WORK/site"; OUT="$WORK/out"
mkdir -p "$SITE"
cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$SITE/"
cp tests/rendering/simple/zigapagos.ziggy "$SITE/"

cat > "$SITE/content/jsonc-test.smd" <<'EOF'
---
.title = "Unknown language",
.date = @date("2020-07-06T00:00:00"),
.author = "Sample Author",
.layout = "index.shtml",
.draft = false,
---

```jsonc
// note: <not a tag> & ok
{ "a": 1 }
```
EOF

# --- (1) the build must SUCCEED (this is the defect: it used to be fatal) ----
set +e
( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force ) >"$WORK/build.log" 2>"$WORK/build.err"
RC=$?
set -e
if [[ "$RC" -ne 0 ]]; then
  echo "--- stdout ---"; sed -n '1,40p' "$WORK/build.log"
  echo "--- stderr ---"; sed -n '1,40p' "$WORK/build.err"
  fail "build exited $RC -- an unknown code-fence language must be a warning, not a fatal error"
fi
echo "build succeeded despite the unknown 'jsonc' language (exit 0)"

# --- (2) the page still rendered, unhighlighted but escaped -------------------
PAGE="$OUT/jsonc-test/index.html"
[[ -f "$PAGE" ]] || fail "expected page not emitted: $PAGE"
grep -q '<code class="jsonc">' "$PAGE" \
  || fail "expected an unhighlighted <code class=\"jsonc\"> block -- got:"$'\n'"$(cat "$PAGE")"
grep -q '<span' "$PAGE" \
  && fail "the jsonc block should be UNHIGHLIGHTED (no <span> markup) -- an unknown language has no treesitter grammar"
grep -q '&lt;not a tag&gt;' "$PAGE" \
  || fail "the fence content should be HTML-escaped even though it wasn't highlighted -- got:"$'\n'"$(cat "$PAGE")"
echo "PASS: jsonc-test/index.html has an escaped, unhighlighted <code class=\"jsonc\"> block"

# --- (3) the warning names a did-you-mean suggestion --------------------------
grep -q "unknown code-fence language 'jsonc'" "$WORK/build.err" \
  || { echo "--- stderr ---"; cat "$WORK/build.err"; fail "expected the unknown-language warning in stderr"; }
grep -q "did you mean 'json'" "$WORK/build.err" \
  || { echo "--- stderr ---"; cat "$WORK/build.err"; fail "expected a did-you-mean 'json' hint for 'jsonc' in stderr"; }
echo "PASS: stderr names the did-you-mean suggestion ('json') for 'jsonc'"

# --- (4) `zigapagos languages` exists and lists both languages ----------------
set +e
LANG_OUT="$("$ZIGAPAGOS" languages 2>&1)"
LANG_RC=$?
set -e
[[ "$LANG_RC" -eq 0 ]] || { echo "$LANG_OUT"; fail "'zigapagos languages' exited $LANG_RC"; }
echo "$LANG_OUT" | grep -q '^json ' || { echo "$LANG_OUT"; fail "'zigapagos languages' output missing 'json'"; }
echo "$LANG_OUT" | grep -q '^zig ' || { echo "$LANG_OUT"; fail "'zigapagos languages' output missing 'zig'"; }
echo "PASS: 'zigapagos languages' lists both 'json' and 'zig'"

echo "ALL PROOF CHECKS PASSED (unknown code-fence language is a warning, with a did-you-mean hint and a language list)"
