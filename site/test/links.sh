#!/usr/bin/env bash
# site/test/links.sh — every internal link resolves to an emitted file.
#
# The failure this catches is specific: under url_path_prefix, a hand-written
# href works in local preview and 404s in production. Checking the built tree
# is the only place that distinction is visible.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=zig-out/site
PREFIX=/zigapagos

test -d "$OUT" || { echo "FAIL: no build output — run zig build first"; exit 1; }

FAILED=0
while IFS= read -r html; do
  # No SPA exemption any more. Pages emitted BY the embedded demo SPA (under
  # demos/app/) used to be exempted from the prefix rule, because their <Link>
  # hrefs were resolved against the SPA's own unprefixed `base` and the prefix
  # only reappeared inside the click handler. Issue #26 composes
  # url_path_prefix into the Router's base, so a prerendered SPA nav href is
  # now the same fully-prefixed, file-backed address as any other internal
  # link — and holding it to the same rule is the point: an unprefixed one is
  # a 404 for a visitor without JavaScript.
  while IFS= read -r href; do
    # Skip external, anchors, mailto, and the SPA's client-side routes (the
    # router owns those; only its prerendered shells exist as files).
    case "$href" in
      http*|mailto:*|"#"*|"") continue ;;
    esac
    case "$href" in
      "$PREFIX"/*) rel="${href#"$PREFIX"/}" ;;
      /*) echo "FAIL: [$html] unprefixed absolute link: $href"; FAILED=1; continue ;;
      *) continue ;;  # relative links resolve against the emitted directory
    esac
    rel="${rel%%#*}"
    target="$OUT/$rel"
    if [ -f "$target" ] || [ -f "$target/index.html" ] || [ -f "${target%/}/index.html" ]; then
      continue
    fi
    echo "FAIL: [$html] broken internal link: $href"
    FAILED=1
  done < <(grep -oE '(href|src)="[^"]*"' "$html" | sed -E 's/^[a-z]+="//; s/"$//')
done < <(find "$OUT" -name '*.html')

[ "$FAILED" -eq 0 ] || exit 1
echo PASS
