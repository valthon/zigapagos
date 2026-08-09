#!/usr/bin/env bash
# Regression test for issue #148: `src/render/html.zig` printed SuperMD
# directive metadata into HTML attribute values with `{s}` -- raw, unescaped --
# so an author-supplied `title`, `alt`, `id`, `attrs` (class) or code-fence
# language could terminate the attribute it sat in.
#
# Two defects, one root cause:
#
#   1. PLAIN CORRECTNESS. A title containing a double quote -- `He said "hi"`,
#      which requires no malice at all -- closes the attribute early and emits
#      malformed HTML.
#   2. ATTRIBUTE INJECTION. Having closed the attribute, the value can open new
#      ones. Reachable by whoever writes the content, so self-inflicted on a
#      single-author site -- and not self-inflicted on a migrated site whose
#      frontmatter came from elsewhere, on generated content, or on a repo where
#      content authorship is broader than code authorship.
#
# `HtmlSafe` (superhtml) escapes `&`, `<`, `>`, `'` AND `"`, so it is
# attribute-safe as-is; it was already imported by this file and already used
# for text content and for `sizes`. The fix is to use it at the attribute
# prints too.
#
# What this pins, per directive arm, is that the payload `x" onload="alert(1)`
# never becomes a real `onload` attribute, and that a bare `"` survives as
# `&quot;` rather than as a closing quote. The `onload` assertion is the
# load-bearing one: it fails loudly on the injection, not merely on a cosmetic
# escaping difference.
#
# NOT claimed: that URLs are escaped. `printUrl`/`renderLink` emit href/src
# through a different path with its own resolution rules, and issue #148 scopes
# itself to the directive-metadata attributes. That path is untouched here.
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

# One page exercising every directive arm that prints author-controlled
# metadata into an attribute. The payload is the same everywhere so a single
# grep proves the whole class: `x" onload="alert(1)` closes the attribute and
# opens an event handler if the value is not escaped.
#
# The destinations use Markdown's ANGLE-BRACKET form, `[text](<$directive…>)`,
# and not the bare one. A bare destination ends at the first double quote --
# CommonMark reads what follows as a link *title* -- so a payload containing
# `"` would not parse as a directive at all, and the page would render the
# literal source text having proved nothing. docs/images.md uses the same form
# for the same reason.
cat > "$SITE/content/attr-escaping.smd" <<'EOF'
---
.title = "Attribute escaping",
.date = @date("2020-07-06T00:00:00"),
.author = "Sample Author",
.layout = "index.shtml",
.draft = false,
---

# [Heading](<$section.id('x" onload="alert(1)').attrs('x" onload="alert(1)')>)

An [inline span](<$text.title('x" onload="alert(1)')>) inside a paragraph.

A [link](<$link.url('https://example.com/').title('x" onload="alert(1)')>) too.

[Caption](<$image.url('https://example.com/photo.png').alt('x" onload="alert(1)').title('x" onload="alert(1)')>)
EOF

set +e
( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force ) >"$WORK/build.log" 2>"$WORK/build.err"
RC=$?
set -e
if [[ "$RC" -ne 0 ]]; then
  echo "--- stdout ---"; sed -n '1,40p' "$WORK/build.log"
  echo "--- stderr ---"; sed -n '1,40p' "$WORK/build.err"
  fail "build exited $RC -- the fixture is expected to build cleanly"
fi

PAGE="$OUT/attr-escaping/index.html"
[[ -f "$PAGE" ]] || fail "expected page not emitted: $PAGE"

dump() { echo "--- $PAGE ---"; cat "$PAGE"; }

# --- (1) the injection itself --------------------------------------------
# The one assertion that distinguishes "escaped" from "broken out of". If the
# value escaped its attribute, `onload="alert(1)"` is a real attribute on a
# real element and this matches.
if grep -q 'onload="alert(1)"' "$PAGE"; then
  dump
  fail "attribute injection: the payload closed its attribute and opened onload= -- directive metadata must be HTML-escaped"
fi
echo "PASS: no directive value escaped its attribute into an onload= handler"

# --- (2) each arm escaped its own value ----------------------------------
# `"` must survive as `&quot;` in the attribute it belongs to. Asserted per
# attribute name so one arm regressing cannot hide behind another still
# passing.
ESCAPED='x&quot; onload=&quot;alert(1)'

grep -q "title=\"$ESCAPED\"" "$PAGE" \
  || { dump; fail "expected an escaped title= attribute (&quot;), from \$text/\$link/\$image .title()"; }
echo "PASS: title= carries the escaped payload"

grep -q "alt=\"$ESCAPED\"" "$PAGE" \
  || { dump; fail "expected an escaped alt= attribute (&quot;), from \$image.alt()"; }
echo "PASS: alt= carries the escaped payload"

grep -q "id=\"$ESCAPED\"" "$PAGE" \
  || { dump; fail "expected an escaped id= attribute (&quot;), from \$section.id()"; }
echo "PASS: id= carries the escaped payload"

grep -q "class=\"$ESCAPED" "$PAGE" \
  || { dump; fail "expected an escaped class= attribute (&quot;), from \$section.attrs()"; }
echo "PASS: class= carries the escaped payload"

# --- (3) the code-fence language, same shape ------------------------------
# `<pre><code class="{s}">` takes the fence's language verbatim. An unknown
# language is a warning, not a fatal (tests/rendering/unknown-language.sh), so
# a quote-carrying language builds and reaches the attribute.
#
# The payload here is deliberately NOT the `x" onload="alert(1)` used above: a
# fence's language ends at the first whitespace, so a language can never carry
# the space needed to introduce a second attribute. What IS reachable is the
# other half of the defect -- terminating the attribute early and emitting
# malformed HTML -- so that is what this asserts.
cat > "$SITE/content/attr-escaping-fence.smd" <<'EOF'
---
.title = "Attribute escaping, code fence",
.date = @date("2020-07-06T00:00:00"),
.author = "Sample Author",
.layout = "index.shtml",
.draft = false,
---

```js"x
plain text
```
EOF

set +e
( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force ) >"$WORK/build2.log" 2>"$WORK/build2.err"
RC=$?
set -e
[[ "$RC" -eq 0 ]] || { sed -n '1,40p' "$WORK/build2.err"; fail "build exited $RC on the code-fence fixture"; }

FENCE="$OUT/attr-escaping-fence/index.html"
[[ -f "$FENCE" ]] || fail "expected page not emitted: $FENCE"

grep -q 'code class="js&quot;x"' "$FENCE" \
  || { echo "--- $FENCE ---"; cat "$FENCE"; fail "expected <code class=\"js&quot;x\"> -- the fence language must be HTML-escaped"; }
echo "PASS: the code-fence language is escaped in <code class=>"

echo "ALL PROOF CHECKS PASSED (issue #148: directive metadata is HTML-escaped in every attribute it reaches)"
