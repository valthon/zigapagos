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
  # A page emitted BY the embedded demo SPA (under demos/app/) is prerendered
  # from routes whose <Link> hrefs are resolved against the SPA's own,
  # unprefixed `base` — url_path_prefix isn't threaded into Router.base (see
  # site/test/build.sh's Task 9 comment and the demo page's own disclosure).
  # So a nav href like /demos/app/guides is correct AS WRITTEN, not a bug this
  # gate should chase: it is base-relative by design, and the click handler
  # resolves the real, prefixed destination at runtime (spa_playwright.py
  # proves that landing). Requiring the prefix here would pin a permanently
  # failing assertion against a known, disclosed product gap. Pages OUTSIDE
  # the SPA (the demos index, the landing page's SPA section) link INTO it
  # with an ordinary, non-Router href, so those still need the prefix and are
  # not exempted below.
  case "$html" in
    "$OUT"/demos/app/*) in_spa=1 ;;
    *) in_spa=0 ;;
  esac
  while IFS= read -r href; do
    # Skip external, anchors, mailto, and the SPA's client-side routes (the
    # router owns those; only its prerendered shells exist as files).
    case "$href" in
      http*|mailto:*|"#"*|"") continue ;;
    esac
    case "$href" in
      "$PREFIX"/*) rel="${href#"$PREFIX"/}" ;;
      /demos/app*)
        if [ "$in_spa" -eq 1 ]; then
          rel="${href#/}"
        else
          echo "FAIL: [$html] unprefixed absolute link: $href"
          FAILED=1
          continue
        fi
        ;;
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
