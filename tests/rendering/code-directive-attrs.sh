#!/usr/bin/env bash
# Regression test for the `$code` directive's `attrs` emission, found while
# reviewing the #148 escaping fix.
#
# Every other directive arm in `src/render/html.zig` writes the class attribute
# as a matched trio -- open ` class="`, write the attrs, close `"`. The two
# `$code` arms instead had:
#
#     if (directive.attrs) |attrs| {
#         if (code.language == null) try w.writeAll(" class=\"");
#         for (attrs) |attr| try w.print("{f} ", .{...});
#     }
#
# which is wrong in three separate ways, all reproduced before the fix:
#
#   1. `$code` WITH a language emitted `<prealpha beta ` -- no opening
#      ` class="` and no leading space, so the first attr is concatenated onto
#      the tag NAME. The result is not a malformed `<pre>`; it is an element
#      called `prealpha`, and the code block loses its styling and semantics
#      entirely.
#   2. `$code` WITHOUT a language emitted `<pre class="gamma ` -- the quote is
#      opened and never closed, so everything after it (title, the `<code>`
#      child, the snippet itself) is swallowed into the attribute value until
#      some later quote happens to end it.
#   3. The `=mathtex` arm emitted `<script type="math/tex"delta ` -- the
#      `code.language == null` guard is unreachable there (that branch is only
#      entered when the language IS `=mathtex`), so it always took the
#      no-opening-quote path and jammed the attrs onto the previous attribute.
#
# (2) is the same class of defect as issue #148 -- author-supplied directive
# metadata breaking out of the attribute it belongs to -- which is why it is
# fixed alongside it rather than filed for later.
#
# This pins the matched-trio shape for all three arms. The trailing space
# inside the value (`class="alpha beta "`) is what every sibling arm already
# produces and is insignificant in a space-separated class list, so it is
# asserted as-is rather than "corrected" into a difference from the siblings.
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
mkdir -p "$SITE/content/probe"
cp -r tests/rendering/simple/layouts "$SITE/"
cp tests/rendering/simple/zigapagos.ziggy "$SITE/"

printf 'const x = 1;\n' > "$SITE/content/probe/snippet.zig"

cat > "$SITE/content/index.smd" <<'EOF'
---
.title = "Root",
.date = @date("2020-07-06T00:00:00"),
.author = "Sample Author",
.layout = "index.shtml",
.draft = false,
---
Root.
EOF

cat > "$SITE/content/probe/index.smd" <<'EOF'
---
.title = "Code directive attrs",
.date = @date("2020-07-06T00:00:00"),
.author = "Sample Author",
.layout = "index.shtml",
.draft = false,
---

[with language](<$code.asset('snippet.zig').language('zig').attrs('alpha','beta')>)

[no language](<$code.asset('snippet.zig').attrs('gamma')>)

[mathtex](<$code.asset('snippet.zig').language('=mathtex').attrs('delta')>)
EOF

set +e
( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force ) >"$WORK/build.log" 2>"$WORK/build.err"
RC=$?
set -e
if [[ "$RC" -ne 0 ]]; then
  echo "--- stderr ---"; sed -n '1,40p' "$WORK/build.err"
  fail "build exited $RC -- the fixture is expected to build cleanly"
fi

PAGE="$OUT/probe/index.html"
[[ -f "$PAGE" ]] || fail "expected page not emitted: $PAGE"
dump() { echo "--- $PAGE ---"; cat "$PAGE"; }

# --- (1) attrs must never fuse onto the tag name -------------------------
grep -q '<prealpha' "$PAGE" \
  && { dump; fail "attrs fused onto the tag name: '<pre' + 'alpha' produced an element called <prealpha>"; }
echo "PASS: attrs did not fuse onto the <pre> tag name"

# --- (2) each arm emits a matched, closed class attribute ----------------
grep -q '<pre class="alpha beta "' "$PAGE" \
  || { dump; fail "expected <pre class=\"alpha beta \"> for a \$code with a language"; }
echo "PASS: \$code with a language emits a closed class attribute"

grep -q '<pre class="gamma "' "$PAGE" \
  || { dump; fail "expected <pre class=\"gamma \"> for a \$code without a language"; }
echo "PASS: \$code without a language emits a closed class attribute"

grep -q '<script type="math/tex" class="delta "' "$PAGE" \
  || { dump; fail "expected <script type=\"math/tex\" class=\"delta \"> for the =mathtex arm"; }
echo "PASS: the =mathtex arm emits a separated, closed class attribute"

# --- (3) no unterminated attribute value anywhere ------------------------
# A generic net beyond the three shapes above. An unterminated `class="`
# swallows the rest of the tag, so `<pre[^>]*>` stops at the FIRST `>` -- which
# is the one inside the attribute value -- and the captured tag ends up with an
# odd number of quotes. A well-formed opening tag always has an even number.
while IFS= read -r tag; do
  quotes="$(printf '%s' "$tag" | tr -cd '"' | wc -c)"
  if [[ $(( quotes % 2 )) -ne 0 ]]; then
    dump
    fail "opening tag has an odd number of quotes ($quotes) -- an attribute value was never closed: $tag"
  fi
done < <(grep -oE '<pre[^>]*>' "$PAGE")
echo "PASS: every opening <pre> tag has balanced quotes"

echo "ALL PROOF CHECKS PASSED (\$code directive attrs open and close their class attribute)"
