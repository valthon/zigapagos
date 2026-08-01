#!/usr/bin/env bash
# Assertions for a built Zigapagos site. Source this; do not run it.
#
#   . "$(dirname "$0")/assert.sh"
#   OUT=zig-out/site
#   assert_route_emitted   "$OUT" /docs/islands
#   assert_element         "$OUT/index.html" link rel=icon
#   assert_no_script_src   "$OUT/docs/islands/index.html"
#   assert_internal_links_resolve "$OUT" "$OUT/index.html" /myproj
#   assert_island_ssr      "$OUT/index.html" components/Counter.island.tsx
#
# Every function prints a diagnosis and exits non-zero on failure, so a script
# that sources this needs no `|| exit`. Its own self-test is assert.test.sh;
# docs/testing.md is the prose.
#
# WHY THIS FILE EXISTS (#59). This project hand-rolled about thirty grep-based
# assertions across four shell scripts, and got several of them wrong in ways
# that are worth naming, because every consumer will otherwise reproduce them:
#
#   1. AN ASSERTION THAT PASSED BEFORE THE CODE EXISTED. `test -f
#      $OUT/docs/overview/index.html` was green while those pages were empty
#      placeholder stubs -- the file existed the whole time. Every function here
#      therefore hard-fails on a missing or empty input rather than treating
#      absence as "nothing to check", and `assert_route_emitted` requires the
#      page to be structurally a page, not merely a file.
#
#   2. A BARE SUBSTRING MATCH THAT FALSE-POSITIVED ON PROSE. Checking a docs
#      page for `zigapagos-runtime.js` matched the islands documentation, whose
#      body legitimately SHOWS an import map with that filename in it, inside a
#      code sample. `assert_element` matches inside a tag's angle brackets and
#      nowhere else, so page text can never satisfy it.
#
#   3. AN ASSERTION FOR AN ATTRIBUTE THE FEATURE CANNOT EMIT. That one is
#      permanently red and reads in review as coverage. Nothing a library can
#      detect -- but every assertion here fails with the actual candidates it
#      found, so an impossible assertion says "found <div data-z-island ...>,
#      wanted attribute X" instead of a bare "not found", and the mistake is
#      visible on the first run.
#
# Portable bash + grep. No bun, no HTML parser: an assertion library that a
# consumer cannot read in one sitting will be replaced by greps again.
set -uo pipefail

# --- internals ----------------------------------------------------------------

_za_fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Escape a string for use as a literal inside a POSIX ERE.
_za_ere() {
    printf '%s' "$1" | sed -e 's/[][\.*^$(){}?+|/]/\\&/g'
}

# _za_readable <path> <what> -- exists, is a regular file, and is not empty.
#
# The emptiness check is failure mode 1: a zero-byte or near-zero-byte file is
# what a half-finished build leaves behind, and every content assertion below
# would otherwise report a specific missing thing rather than "this page was
# never really written".
_za_readable() {
    local f="$1" what="$2"
    [[ -e "$f" ]] || _za_fail "$what: no such file: $f"
    [[ -f "$f" ]] || _za_fail "$what: not a regular file: $f"
    [[ -s "$f" ]] || _za_fail "$what: file is empty: $f"
}

# --- assertions ---------------------------------------------------------------

# assert_route_emitted <out-dir> <route>
#
# The route was emitted AS A PAGE. `/docs/islands` accepts either
# `<out>/docs/islands/index.html` or `<out>/docs/islands.html`, matching what
# the build actually produces for a page vs an alias.
#
# Deliberately more than `test -f`: a placeholder that emits an empty file, or a
# build that wrote a truncated page, satisfies existence. This requires a
# closing `</html>` too -- the last thing written, so a build killed mid-write
# does not pass.
assert_route_emitted() {
    local out="$1" route="$2" f
    [[ -d "$out" ]] || _za_fail "assert_route_emitted: output directory does not exist: $out"
    route="/${route#/}"
    for f in "$out${route%/}/index.html" "$out${route%/}.html"; do
        [[ -f "$f" ]] || continue
        _za_readable "$f" "assert_route_emitted($route)"
        grep -qi '</html>' "$f" \
            || _za_fail "assert_route_emitted($route): $f has no closing </html> -- truncated, or not a page"
        printf '%s' "$f"
        return 0
    done
    _za_fail "assert_route_emitted($route): neither $out${route%/}/index.html nor $out${route%/}.html was emitted"
}

# assert_element <file> <tag> [attr | attr=value] ...
#
# An element with this tag AND all of these attributes exists. Attribute ORDER
# is not constrained (the emitter's business, not the assertion's), but every
# attribute must appear inside the SAME opening tag -- which is the whole point.
# `attr` alone asserts presence; `attr=value` asserts an exact value.
#
# This is failure mode 2. `grep -q 'rel="icon"'` is satisfied by any page that
# quotes that string in its prose or in a code sample; this is satisfied only by
# a real `<link ... rel="icon" ...>`.
assert_element() {
    local f="$1" tag="$2"; shift 2
    _za_readable "$f" "assert_element(<$tag>)"
    [[ "$tag" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]] \
        || _za_fail "assert_element: '$tag' is not a tag name"

    # Candidate opening tags, one per line, angle brackets included. Everything
    # after this point matches against tags only, never against page text.
    local candidates
    candidates="$(grep -oE "<$(_za_ere "$tag")([[:space:]][^>]*)?/?>" "$f" || true)"
    [[ -n "$candidates" ]] \
        || _za_fail "assert_element: $f has no <$tag> element at all"

    local spec name value pattern
    for spec in "$@"; do
        if [[ "$spec" == *=* ]]; then
            name="${spec%%=*}"; value="${spec#*=}"
            pattern="[[:space:]]$(_za_ere "$name")=\"$(_za_ere "$value")\"([[:space:]]|/?>)"
        else
            name="$spec"
            pattern="[[:space:]]$(_za_ere "$name")(=|[[:space:]]|/?>)"
        fi
        candidates="$(printf '%s\n' "$candidates" | grep -E "$pattern" || true)"
        [[ -n "$candidates" ]] || _za_fail \
            "assert_element: $f has a <$tag> but none with $spec
  candidates were:
$(grep -oE "<$(_za_ere "$tag")([[:space:]][^>]*)?/?>" "$f" | sed 's/^/    /' | head -10)"
    done
}

# assert_no_script_src <file>
#
# The page loads no external JavaScript: no `<script>` carries a `src`. Inline
# scripts are allowed -- a theme-resolution snippet in the document head is not
# a framework, and banning it would make this assertion unusable on a real site.
#
# The narrow form (`grep -q 'runtime.js'`) is failure mode 2 again: it
# false-positives on any page that MENTIONS the filename. Asking the structural
# question instead is both stricter and immune to that.
assert_no_script_src() {
    local f="$1"
    _za_readable "$f" "assert_no_script_src"
    local found
    found="$(grep -oE '<script([[:space:]][^>]*)?[[:space:]]src="[^"]*"([[:space:]][^>]*)?>' "$f" || true)"
    [[ -z "$found" ]] || _za_fail \
        "assert_no_script_src: $f loads external JavaScript
$(printf '%s\n' "$found" | sed 's/^/    /')"
}

# assert_internal_links_resolve <out-dir> <file> [url-path-prefix]
#
# Every internal `href`/`src` on this page names something the build actually
# emitted. With a prefix (a project-pages subpath, e.g. `/myproj`), a
# root-absolute link that does NOT carry it is a failure too: that is the
# specific bug that works in local preview and 404s in production, and it is
# invisible anywhere except in the built tree.
#
# External, `mailto:`, in-page anchors and relative links are skipped -- the
# first three are not ours, and a relative link resolves against the emitted
# directory rather than the tree root.
assert_internal_links_resolve() {
    local out="$1" f="$2" prefix="${3:-}"
    [[ -d "$out" ]] || _za_fail "assert_internal_links_resolve: output directory does not exist: $out"
    _za_readable "$f" "assert_internal_links_resolve"
    prefix="${prefix%/}"

    local href rel target failures=0
    while IFS= read -r href; do
        case "$href" in
            http*|mailto:*|"#"*|"") continue ;;
        esac
        case "$href" in
            /*) : ;;
            *) continue ;;   # relative: resolves against the emitted directory
        esac
        if [[ -n "$prefix" ]]; then
            case "$href" in
                "$prefix"/*) rel="${href#"$prefix"/}" ;;
                *)
                    echo "  unprefixed absolute link: $href" >&2
                    failures=$((failures + 1))
                    continue
                    ;;
            esac
        else
            rel="${href#/}"
        fi
        rel="${rel%%#*}"
        rel="${rel%%\?*}"
        target="$out/$rel"
        if [[ -f "$target" || -f "${target%/}/index.html" ]]; then
            continue
        fi
        echo "  broken internal link: $href (no $target)" >&2
        failures=$((failures + 1))
    done < <(grep -oE '(href|src)="[^"]*"' "$f" | sed -E 's/^[a-z]+="//; s/"$//')

    [[ "$failures" -eq 0 ]] \
        || _za_fail "assert_internal_links_resolve: $failures unresolvable link(s) in $f"
}

# assert_island_ssr <file> <island-src>
#
# The island with this `src` is on the page AND was server-rendered: its
# wrapper element is present, it is not `client:only`, its props payload is
# present and carries the wrapper's own id, and the wrapper is NOT empty.
#
# The last two checks are failure mode 1 in its sharpest form. A wrapper is
# emitted for every island including `client:only`, which by design ships no
# server-rendered markup, so "the island is on the page" and "the island was
# server-rendered" are different claims and only the second one means hydration
# has something to adopt and a crawler has something to read.
#
# `client:only` is rejected on the DIRECTIVE and not on emptiness alone,
# because such a wrapper is not reliably empty: `client:only` is the one
# directive that may carry a `<template slot="fallback">` placeholder, which
# src/islands/pass.zig writes INTO the wrapper (a fallback under any other
# directive is a build error -- "is only meaningful on client:only"). That
# markup is authored placeholder HTML, not SSR output: runtime/src/islands.ts
# calls `rootEl.replaceChildren()` on a client:only root before mounting, so
# hydration adopts nothing and a crawler reads the placeholder. Checking
# emptiness alone reported those pages as server-rendered.
assert_island_ssr() {
    local f="$1" src="$2"
    _za_readable "$f" "assert_island_ssr($src)"

    local open id
    open="$(grep -oE "<div data-z-island id=\"[^\"]*\" data-z-src=\"$(_za_ere "$src")\"[^>]*>" "$f" | head -1)"
    [[ -n "$open" ]] || _za_fail \
        "assert_island_ssr($src): no island wrapper for that src in $f
  islands on this page:
$(grep -oE '<div data-z-island[^>]*data-z-src="[^"]*"' "$f" | sed 's/^/    /' | head -10)"

    case "$open" in
        *'data-z-client="only"'*)
            _za_fail "assert_island_ssr($src): the island is client:only -- present on the page but never server-rendered (its wrapper holds a fallback placeholder at most, and the runtime clears it on mount)"
            ;;
    esac

    id="$(printf '%s' "$open" | sed -E 's/.*id="([^"]*)".*/\1/')"
    [[ -n "$id" ]] || _za_fail "assert_island_ssr($src): island wrapper has no id: $open"

    grep -qE "<script type=\"application/json\" data-z-props=\"$(_za_ere "$id")\">" "$f" \
        || _za_fail "assert_island_ssr($src): no data-z-props payload for island id '$id' -- it would hydrate with no props"

    # The build emits `<div ...>RENDERED</div><script ... data-z-props="id">`.
    # An immediately-closed wrapper is the not-server-rendered shape. With
    # client:only already rejected above, reaching this means SSR ran and
    # produced nothing.
    if grep -qE "data-z-src=\"$(_za_ere "$src")\"[^>]*></div><script[^>]*data-z-props=\"$(_za_ere "$id")\"" "$f"; then
        _za_fail "assert_island_ssr($src): the island wrapper is EMPTY -- present on the page but not server-rendered (SSR produced nothing)"
    fi
}
