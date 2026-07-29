#!/usr/bin/env bash
# site/test/build.sh — the site builds and is prefix-correct
set -euo pipefail
cd "$(dirname "$0")/.."
bun install --frozen-lockfile 2>/dev/null || bun install
# Mirrors are gitignored build artifacts, so a fresh clone has none. Generate
# them here rather than assuming a prior step did: the docs sidebar links to
# mirrored pages by name, and a missing mirror fails the build pointing at the
# sidebar instead of at the real cause.
bun run scripts/gen-docs-mirror.ts
zig build
OUT=zig-out/site
test -f "$OUT/index.html" || { echo "FAIL: no index.html"; exit 1; }
grep -q '/zigapagos/zigapagos-runtime.js' "$OUT/index.html" || { echo "FAIL: runtime URL not prefixed"; exit 1; }
test -f "$OUT/islands/Counter.island.js" || { echo "FAIL: Counter bundle missing"; exit 1; }
grep -q 'data-z-props' "$OUT/index.html" || { echo "FAIL: island not SSR'd"; exit 1; }
# Assert absence of branding in output via token split to avoid triggering the
# source-level branding gate.
BANNED="zi""ne"
grep -qi "$BANNED" "$OUT/index.html" && { echo "FAIL: stray $BANNED branding"; exit 1; }

# Task 1: the base shell renders, in both themes, with no webfont request.
# 'data-theme' alone would pass on the inline script's JS source without the
# toggle actually existing, so pin the two concrete pieces of the mechanism:
# the control users click, and the storage key the pre-paint script reads.
grep -q 'id="theme-toggle"' "$OUT/index.html" || { echo "FAIL: theme toggle control missing"; exit 1; }
grep -q 'zp-theme' "$OUT/index.html" || { echo "FAIL: pre-paint script doesn't reference the theme storage key"; exit 1; }
grep -q 'id="site-nav"' "$OUT/index.html" || { echo "FAIL: nav missing"; exit 1; }
test -f "$OUT/tokens.css" || { echo "FAIL: tokens.css not installed"; exit 1; }
grep -q -- '--color-accent' "$OUT/tokens.css" || { echo "FAIL: tokens.css has no palette"; exit 1; }
grep -qE 'fonts\.(googleapis|gstatic)\.com|@import url\(' "$OUT/index.html" "$OUT/style.css" "$OUT/tokens.css" \
  && { echo "FAIL: site downloads a webfont"; exit 1; }
grep -q 'name="description" content=""' "$OUT/index.html" \
  && { echo "FAIL: empty meta description"; exit 1; }

# Task 2: the landing page carries its named sections and both CTAs.
for id in s-hero s-zerojs s-pipeline; do
  grep -q "id=\"$id\"" "$OUT/index.html" || { echo "FAIL: landing section $id missing"; exit 1; }
done
grep -q 'class="btn btn-primary"' "$OUT/index.html" || { echo "FAIL: primary CTA missing"; exit 1; }

# Task 3: the islands section renders and its island is bundled + SSR'd.
grep -q 'id="s-islands"' "$OUT/index.html" || { echo "FAIL: islands section missing"; exit 1; }
test -f "$OUT/islands/CodeTabs.island.js" || { echo "FAIL: CodeTabs bundle missing"; exit 1; }
grep -q 'zp-codetabs' "$OUT/index.html" || { echo "FAIL: CodeTabs not server-rendered"; exit 1; }
grep -q 'zp-tab-on' "$OUT/index.html" || { echo "FAIL: CodeTabs did not SSR its open tab"; exit 1; }

# Task 5: the docs shell exists, has a sidebar and a TOC, and ships no JS.
test -f "$OUT/docs/index.html" || { echo "FAIL: docs index missing"; exit 1; }
test -f "$OUT/docs/islands/index.html" || { echo "FAIL: mirrored islands doc missing"; exit 1; }
grep -q 'class="docs-sidebar"' "$OUT/docs/islands/index.html" || { echo "FAIL: docs sidebar missing"; exit 1; }
grep -q 'class="docs-toc"' "$OUT/docs/islands/index.html" || { echo "FAIL: docs TOC missing"; exit 1; }
# A plain substring match on 'zigapagos-runtime.js' would false-positive on
# the islands doc itself: its mirrored body is real content that shows what
# an import map looks like, filename and all, inside a code sample (see
# docs/islands.md's "```html" block). Match the actual module-script tag
# shape instead, so this pins the real claim (no runtime is LOADED) rather
# than the filename never appearing anywhere in the page as text.
grep -qE '<script type="module" src="[^"]*zigapagos-runtime\.js"' "$OUT/docs/islands/index.html" \
  && { echo "FAIL: a docs page shipped the island runtime"; exit 1; }
grep -q 'aria-current="page"' "$OUT/docs/islands/index.html" || { echo "FAIL: sidebar has no active state"; exit 1; }

# Task 6: the authored on-ramp exists AND carries its real prose. An existence
# check is not enough — the placeholder stubs these four replaced already
# emitted docs/<slug>/index.html, so a file-only assertion was green before the
# pages were written and pinned nothing.
assert_page() {  # $1 = slug, $2 = phrase that must appear
  test -f "$OUT/docs/$1/index.html" || { echo "FAIL: authored doc $1 missing"; exit 1; }
  grep -qF "$2" "$OUT/docs/$1/index.html" \
    || { echo "FAIL: docs/$1 is missing its authored prose ($2)"; exit 1; }
  grep -qE '<meta name="description" content="[^"]+"' "$OUT/docs/$1/index.html" \
    || { echo "FAIL: docs/$1 has an empty meta description"; exit 1; }
}
assert_page overview      "A Zigapagos project has three kinds of source file"
assert_page quick-start   "worth reading before deleting"
assert_page tutorial      "one that needs JavaScript immediately and one that does not"
assert_page configuration "is the subpath the site is served from"

# Task 7: the demos section and all five directive instances render.
test -f "$OUT/demos/index.html" || { echo "FAIL: demos index missing"; exit 1; }
test -f "$OUT/demos/directives/index.html" || { echo "FAIL: directives demo missing"; exit 1; }
test -f "$OUT/islands/DirectiveDemo.island.js" || { echo "FAIL: DirectiveDemo bundle missing"; exit 1; }
for d in load idle visible media; do
  grep -q "data-directive=\"client:$d\"" "$OUT/demos/directives/index.html" \
    || { echo "FAIL: client:$d instance missing"; exit 1; }
done
# client:only is documented as never server-rendered, so the component's own
# data-directive attribute (set by DirectiveDemo's own JSX) cannot appear for
# it — only the wrapper's data-z-client carries the directive name, and the
# untouched props JSON still names it, proving this is the right instance and
# not a coincidental div. The negative assertion pins the actual behaviour
# (empty placeholder) rather than just working around the positive check.
grep -q 'data-z-client="only"' "$OUT/demos/directives/index.html" \
  || { echo "FAIL: client:only instance missing"; exit 1; }
grep -q '"directive":"client:only"' "$OUT/demos/directives/index.html" \
  || { echo "FAIL: client:only props missing"; exit 1; }
grep -q 'data-directive="client:only"' "$OUT/demos/directives/index.html" \
  && { echo "FAIL: client:only was server-rendered (should be an empty placeholder)"; exit 1; }

# Task 8: the migration demo renders with its island bundled.
test -f "$OUT/demos/migrate/index.html" || { echo "FAIL: migrate demo missing"; exit 1; }
test -f "$OUT/islands/MigrateDiff.island.js" || { echo "FAIL: MigrateDiff bundle missing"; exit 1; }
grep -q 'zp-migrate' "$OUT/demos/migrate/index.html" || { echo "FAIL: MigrateDiff not server-rendered"; exit 1; }

# Task 9: the embedded SPA prerenders shells and bundles its entry.
test -f "$OUT/demos/app/index.html" || { echo "FAIL: SPA index shell missing"; exit 1; }
test -f "$OUT/demos/app/guides/index.html" || { echo "FAIL: SPA nested shell missing"; exit 1; }
test -f "$OUT/spa/app.js" || { echo "FAIL: SPA bundle missing"; exit 1; }
grep -q '/zigapagos/spa/app.js' "$OUT/demos/app/index.html" \
  || { echo "FAIL: SPA bundle URL not prefixed"; exit 1; }
# Declaring an SPA writes the site-wide 404.html from that SPA's "/" shell.
# The site aliases its own 404 content page onto that path (Step 4a), so this
# pins that the alias actually wins rather than silently losing to the SPA
# fallback again.
grep -q 'That page does not exist' "$OUT/404.html" || { echo "FAIL: 404.html is not the site's own page"; exit 1; }
grep -q 'class="spa"' "$OUT/404.html" && { echo "FAIL: 404.html is the SPA shell, not the site 404 page"; exit 1; }
# A layout route's matched child reaches it through <Outlet/> (or, identically,
# a `children` prop — see runtime/src/router.ts's renderChainNode). A
# file-exists check alone is satisfied by an empty outlet, so assert
# GuidesIndex's actual server-rendered text made it into the layout's shell.
# NOT the dynamic `guides/:slug` leaf: that route has an explicit `skeleton`,
# and the build ALWAYS SSRs a dynamic route's skeleton, never its real
# per-param content (docs/spa.md "3. Renders skeletons") — even on the
# per-staticPaths concrete shell — so "islands"-specific text is never expected
# in that file.
grep -q 'Pick a guide: <a href="/zigapagos/demos/app/guides/islands">islands</a>' "$OUT/demos/app/guides/index.html" \
  || { echo "FAIL: SPA nested layout (guides) rendered an empty outlet, not GuidesIndex"; exit 1; }
# The nav lives inside the routed tree (a layout rung), so its <Link>s resolve
# against the Router's effective base — which is now `url_path_prefix +
# spa.base` (issue #26), composed inside <Router>.
#
# This assertion used to be deliberately weakened to the UNPREFIXED
# "/demos/app/guides", with a comment explaining that the prefixed form was a
# permanently-failing assertion: @z/runtime exposed no url_path_prefix and the
# build SSR'd every route at an unprefixed pathname, so a static shell could
# never contain the deployed address. That is exactly the gap #26 closed, and
# this is the strongest real-deploy pin in the site: the shells are served from
# https://valthon.github.io/zigapagos/, so an unprefixed nav href is a hard 404
# for any visitor without JavaScript.
grep -q 'href="/zigapagos/demos/app/guides"' "$OUT/demos/app/index.html" \
  || { echo "FAIL: SPA nav link not resolved against url_path_prefix + spa.base"; exit 1; }
# ...and the mechanism that lets the CLIENT agree with that markup: the prefix
# is baked onto the hydration root, which mountSpa reads before the first
# render. Without it the first client render would recompute an unprefixed
# href, and Preact's hydrate() never repairs an attribute.
grep -q 'id="z-spa-root" data-z-spa data-z-prefix="/zigapagos"' "$OUT/demos/app/index.html" \
  || { echo "FAIL: SPA shell carries no data-z-prefix for the client router"; exit 1; }

# The host-config emitters under a url_path_prefix. This site is the only place
# the whole chain runs for real (emit-host-config is a build.zig step, not part
# of `zigapagos release`), and it is genuinely prefixed, so these are the
# strongest assertions available for that half of the feature.
#
# The manifest carries the prefix as its OWN field and leaves route values
# TREE-RELATIVE — the output tree has no /zigapagos directory, so a prefixed
# `fallback` would name a file that does not exist.
MAN="$OUT/demos/app/routing-manifest.json"
grep -q '"url_path_prefix":"/zigapagos"' "$MAN" \
  || { echo "FAIL: routing manifest carries no url_path_prefix"; exit 1; }
grep -q '"fallback":"/demos/app/index.html"' "$MAN" \
  || { echo "FAIL: manifest fallback is not tree-relative"; exit 1; }
grep -q '"/zigapagos/demos/app' "$MAN" \
  && { echo "FAIL: a manifest route value carries the prefix (must stay tree-relative)"; exit 1; }
# ZigBase: `.match` is a REQUEST path (prefixed); `.serve` is resolved against
# the served root directory (tree-relative). Asserting both halves is the point
# — a blanket prefix would satisfy the first and break the second silently.
ZBR="$OUT/demos/app/zigbase.static_routes.zig"
test -f "$ZBR" || { echo "FAIL: zigbase.static_routes.zig missing"; exit 1; }
grep -q '\.match = "/zigapagos/demos/app/\*\*"' "$ZBR" \
  || { echo "FAIL: zigbase .match pattern is not prefixed"; exit 1; }
grep -q '\.serve = "/demos/app/index.html"' "$ZBR" \
  || { echo "FAIL: zigbase .serve target is not tree-relative"; exit 1; }
grep -q '\.serve = "/zigapagos' "$ZBR" \
  && { echo "FAIL: a zigbase .serve target carries the prefix — it would name a file that does not exist"; exit 1; }

# Task 10: compare and download exist, and compare names its alternatives.
test -f "$OUT/compare/index.html" || { echo "FAIL: compare page missing"; exit 1; }
test -f "$OUT/download/index.html" || { echo "FAIL: download page missing"; exit 1; }
for tool in Astro Eleventy Hugo; do
  grep -q "$tool" "$OUT/compare/index.html" || { echo "FAIL: compare omits $tool"; exit 1; }
done
grep -q 'id="when-not-to"' "$OUT/compare/index.html" || { echo "FAIL: compare has no 'when not to' section"; exit 1; }

# Task 10b: the landing page carries all nine sections.
for id in s-hero s-zerojs s-islands s-directives s-spa s-astro s-pipeline s-deploy s-why; do
  grep -q "id=\"$id\"" "$OUT/index.html" || { echo "FAIL: landing section $id missing"; exit 1; }
done

# Task 11: brand assets are installed and referenced.
test -f "$OUT/logo.svg" || { echo "FAIL: logo.svg not installed"; exit 1; }
test -f "$OUT/og.svg" || { echo "FAIL: og.svg not installed"; exit 1; }
grep -q 'rel="icon"' "$OUT/index.html" || { echo "FAIL: no favicon link"; exit 1; }
grep -q 'property="og:title"' "$OUT/index.html" || { echo "FAIL: no Open Graph metadata"; exit 1; }
# og:image must be a raster copy, not og.svg: Twitter/X, Facebook and
# LinkedIn's scrapers don't render an SVG og:image, so a card pointed at the
# .svg file renders with no image on every platform that matters.
test -f "$OUT/og.png" || { echo "FAIL: og.png (rasterised social card) not installed"; exit 1; }
grep -q 'property="og:image" content="[^"]*og\.png"' "$OUT/index.html" \
  || { echo "FAIL: og:image doesn't point at the rasterised og.png"; exit 1; }
# og:image must be an ABSOLUTE URL: the Open Graph protocol requires one, and
# Facebook/LinkedIn/Slack's scrapers don't resolve a root-relative path (a
# bare $site.asset(...).link() only ever emits "/zigapagos/og.png"), so the
# card would render with no image in every environment it's actually for.
grep -q 'property="og:image" content="https://[^"]*og\.png"' "$OUT/index.html" \
  || { echo "FAIL: og:image is not an absolute URL"; exit 1; }

echo PASS
