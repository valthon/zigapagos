#!/usr/bin/env bash
# Self-test for site/test/assert.sh.
#
# WHY. The library exists because thirty hand-rolled greps produced three
# specific wrong assertions (#59), and a library that reproduces them is worse
# than the greps -- it spreads them. So every assertion is run against a
# POSITIVE fixture that must pass and one or more NEGATIVE fixtures that must
# fail, and separately against a missing and an empty file.
#
# The negative fixtures are not arbitrary. Each one is a rendering of one of the
# three recorded mistakes:
#
#   * "prose.html" mentions the exact strings the assertions look for, in page
#     TEXT and inside a code sample -- the docs page that false-positived.
#   * "stub.html" is the placeholder that satisfied `test -f` before the real
#     page existed.
#   * "only.html" is a client:only island: wrapper present, nothing rendered --
#     "the island is on the page" passing for "the island was server-rendered".
#     "only-fallback.html" is the same island carrying a `<template
#     slot="fallback">`, which makes the wrapper NON-empty while still nothing
#     was server-rendered -- so an emptiness-only check reports it as rendered.
#
# Each case runs the assertion in a SUBSHELL, because a failing assertion exits.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/assert.sh"
failures=0

# expect <want-exit> <name> <command...>
expect() {
    local want="$1" name="$2"; shift 2
    local got=0
    ( . "$lib"; "$@" ) >/dev/null 2>&1 || got=$?
    if [[ "$got" -eq "$want" ]]; then
        echo "ok   — $name"
    else
        echo "FAIL — $name (want exit $want, got $got)"
        failures=$((failures + 1))
    fi
}

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
OUT="$t/site"
mkdir -p "$OUT/docs/islands" "$OUT/docs/stub" "$OUT/only" "$OUT/only-fallback"

# --- fixtures -----------------------------------------------------------------

# A real page: island SSR'd, one external script, one prefixed internal link.
cat >"$OUT/index.html" <<'HTML'
<!DOCTYPE html><html><head>
<link rel="icon" type="image/svg+xml" href="/myproj/logo.svg">
<script>var t = 1;</script>
<script type="module" src="/myproj/zigapagos-runtime.js"></script>
</head><body>
<a href="/myproj/docs/islands">Islands</a>
<div data-z-island id="z-island-0" data-z-src="components/Counter.island.tsx" data-z-client="load" data-z-module="/myproj/islands/Counter.island.js"><button>count: 0</button></div><script type="application/json" data-z-props="z-island-0">{"start":0}</script>
</body></html>
HTML
# The link assertion checks `src` as well as `href`, so the runtime the page
# loads has to be a real emitted file too -- which is the point: a shell that
# references a bundle the build never installed is a broken page.
touch "$OUT/logo.svg" "$OUT/zigapagos-runtime.js"

# The docs page that broke the old greps: it MENTIONS the runtime filename and
# quotes `rel="icon"` in prose, and ships no JavaScript of its own.
cat >"$OUT/docs/islands/index.html" <<'HTML'
<!DOCTYPE html><html><head><title>Islands</title></head><body>
<p>Pages with islands emit an import map pointing at zigapagos-runtime.js.</p>
<pre><code>&lt;script type="module" src="/zigapagos-runtime.js"&gt;&lt;/script&gt;
&lt;link rel="icon" href="/logo.svg"&gt;</code></pre>
<p>A page whose only island is a counter loaded all of it.</p>
</body></html>
HTML

# The placeholder that was green before the page was written.
printf '' >"$OUT/docs/stub/index.html"

# A truncated page: real content, no closing tag.
mkdir -p "$OUT/docs/truncated"
printf '<!DOCTYPE html><html><head><title>x</title></head><body><p>half' >"$OUT/docs/truncated/index.html"

# A client:only island: wrapper present, nothing server-rendered.
cat >"$OUT/only/index.html" <<'HTML'
<!DOCTYPE html><html><body>
<div data-z-island id="z-island-0" data-z-src="components/Chart.island.tsx" data-z-client="only" data-z-module="/islands/Chart.island.js"></div><script type="application/json" data-z-props="z-island-0">{}</script>
</body></html>
HTML

# The same client:only island WITH a fallback placeholder, byte-shaped the way
# src/islands/pass.zig emits one. The wrapper is non-empty, so an emptiness-only
# check calls this server-rendered; nothing was rendered on the server, and
# runtime/src/islands.ts clears the placeholder before mounting.
cat >"$OUT/only-fallback/index.html" <<'HTML'
<!DOCTYPE html><html><body>
<div data-z-island id="z-island-0" data-z-src="components/Chart.island.tsx" data-z-client="only" data-z-module="/islands/Chart.island.js"><template slot="fallback"><p>loading</p></template></div><script type="application/json" data-z-props="z-island-0">{}</script>
</body></html>
HTML

# A page with a dead internal link and an unprefixed one.
mkdir -p "$OUT/docs/links"
cat >"$OUT/docs/links/index.html" <<'HTML'
<!DOCTYPE html><html><body>
<a href="/myproj/docs/islands">ok</a>
<a href="/myproj/docs/nowhere">dead</a>
</body></html>
HTML
mkdir -p "$OUT/docs/unprefixed"
cat >"$OUT/docs/unprefixed/index.html" <<'HTML'
<!DOCTYPE html><html><body><a href="/docs/islands">works locally, 404s in production</a></body></html>
HTML

# --- assert_route_emitted -----------------------------------------------------
expect 0 "route_emitted: a real page passes"                assert_route_emitted "$OUT" /docs/islands
expect 1 "route_emitted: an EMPTY placeholder fails"        assert_route_emitted "$OUT" /docs/stub
expect 1 "route_emitted: a TRUNCATED page fails"            assert_route_emitted "$OUT" /docs/truncated
expect 1 "route_emitted: a route never emitted fails"       assert_route_emitted "$OUT" /docs/nowhere
expect 1 "route_emitted: a missing output dir fails"        assert_route_emitted "$t/no-such-dir" /docs/islands

# --- assert_element -----------------------------------------------------------
expect 0 "element: <link rel=icon> present"                 assert_element "$OUT/index.html" link rel=icon
expect 0 "element: attribute presence without a value"      assert_element "$OUT/index.html" link href
expect 0 "element: two attributes on the SAME tag"          assert_element "$OUT/index.html" link rel=icon type=image/svg+xml
expect 1 "element: attributes on DIFFERENT tags do not count" \
         assert_element "$OUT/index.html" script src=/myproj/zigapagos-runtime.js rel=icon
expect 1 "element: prose quoting rel=\"icon\" does NOT match" \
         assert_element "$OUT/docs/islands/index.html" link rel=icon
expect 1 "element: wrong attribute value fails"             assert_element "$OUT/index.html" link rel=stylesheet
expect 1 "element: absent tag fails"                        assert_element "$OUT/index.html" video src=x
expect 1 "element: missing file fails"                      assert_element "$t/nope.html" link rel=icon
expect 1 "element: empty file fails"                        assert_element "$OUT/docs/stub/index.html" link rel=icon

# --- assert_no_script_src -----------------------------------------------------
expect 0 "no_script_src: a docs page that only MENTIONS a runtime passes" \
         assert_no_script_src "$OUT/docs/islands/index.html"
expect 1 "no_script_src: a page that really loads one fails" \
         assert_no_script_src "$OUT/index.html"
expect 1 "no_script_src: missing file fails"                assert_no_script_src "$t/nope.html"

# --- assert_internal_links_resolve --------------------------------------------
expect 0 "links: every prefixed link resolves"              assert_internal_links_resolve "$OUT" "$OUT/index.html" /myproj
expect 1 "links: a dead internal link fails"                assert_internal_links_resolve "$OUT" "$OUT/docs/links/index.html" /myproj
expect 1 "links: an UNPREFIXED absolute link fails under a prefix" \
         assert_internal_links_resolve "$OUT" "$OUT/docs/unprefixed/index.html" /myproj
expect 0 "links: the same page passes with no prefix declared" \
         assert_internal_links_resolve "$OUT" "$OUT/docs/unprefixed/index.html"
expect 1 "links: missing file fails"                        assert_internal_links_resolve "$OUT" "$t/nope.html" /myproj

# --- assert_island_ssr --------------------------------------------------------
expect 0 "island_ssr: a server-rendered island passes"      assert_island_ssr "$OUT/index.html" components/Counter.island.tsx
expect 1 "island_ssr: a client:only island FAILS (present, not rendered)" \
         assert_island_ssr "$OUT/only/index.html" components/Chart.island.tsx
expect 1 "island_ssr: a client:only island with a FALLBACK still FAILS (non-empty, still not rendered)" \
         assert_island_ssr "$OUT/only-fallback/index.html" components/Chart.island.tsx
expect 1 "island_ssr: an island not on the page fails"      assert_island_ssr "$OUT/index.html" components/Nope.island.tsx
expect 1 "island_ssr: a page that only DESCRIBES islands fails" \
         assert_island_ssr "$OUT/docs/islands/index.html" components/Counter.island.tsx
expect 1 "island_ssr: missing file fails"                   assert_island_ssr "$t/nope.html" components/Counter.island.tsx

if [[ "$failures" -eq 0 ]]; then
    echo "PASS: every assertion accepts its positive fixture and rejects its negative ones"
else
    echo "FAIL: $failures case(s)"
    exit 1
fi
