#!/usr/bin/env bash
# Regression test: `sitemap.xml` emission (issue #150).
#
# `Site.sitemap = true` should make a release build emit `sitemap.xml` at the
# output root listing every canonical, indexable page URL -- and nothing
# else. The coverage rules under test, each picked because it is the one
# place the naive "list every installed .html file" approach gets it wrong:
#
#   (1) disabled by default: no `sitemap.xml` unless the config opts in.
#   (2) drafts excluded (a draft post is not in the active build at all).
#   (3) alias duplicates excluded: only the canonical page URL is listed,
#       never the `/overview.html` alias to the same page.
#   (4) pagination page-2+ windows are listed, one URL per window, suffixed
#       per `url_style` -- the fixture's blog section has 5 posts at
#       page_size=2 (3 windows: page 1 implicit, page 2, page 3).
#   (5) SPA routes: a declared static route ("/") is listed; a dynamic
#       route's pattern shell ("/club/:id", no staticPaths) is NOT listed
#       (nobody can visit "/app/club/:id" as a URL); a `staticPaths`
#       concrete entry ("/item/1", "/item/2") IS listed, as a real page.
#   (6) `host_url` + `url_path_prefix` are composed exactly once each --
#       the defect class a naive "prepend prefix twice" bug would produce.
#   (7) a SPA whose `noindex` defaults on (unset, the default) has NONE of
#       its routes listed, even a static "/" route that IS a real page --
#       its shells already carry <meta name="robots" content="noindex">, so
#       listing it in the sitemap would submit a noindex URL (Search
#       Console's "Submitted URL marked 'noindex'").
#   (8) REVERSE: the emitted set of <loc> entries is EXACTLY the expected
#       set, not a superset/subset -- mirrors tests/summary/summary.sh's
#       "the report is only trustworthy if it can't disagree either way"
#       assertion. This also re-proves (7): the noindex SPA's route is a
#       REAL file on disk (checked separately below), so if it leaked into
#       the sitemap this diff would catch it even if the targeted check in
#       (7) had a typo.
#   (9) a page whose alias resolves to the root 'sitemap.xml' is a hard
#       build error while the sitemap is enabled (never a silent overwrite).
#  (10) same as (9), through `alternatives` instead of `aliases` -- the two
#       frontmatter fields reach the site root through the identical
#       root-absolute-output path, so both must be checked.
#  (11) `sitemap = true` with an invalid/empty `host_url` still fails at
#       config validation -- `host_url` is a mandatory, always-validated
#       `Site` field, so there is no SEPARATE "sitemap needs host_url" check
#       to write; this pins that the existing validation already covers it.
#  (12) a TRAILING-SLASH `host_url` ("https://example.com/", which
#       Config.validate explicitly allows -- its URI path is exactly "/")
#       does not double the slash in any <loc>. Same no-doubled-slash scan
#       as (6), against a site built with the trailing slash, so a
#       regression here fails the same way (6) would.
#  (13) a root `assets/sitemap.xml` selected by either an exact
#       `static_assets` entry or a glob fails before install instead of being
#       silently overwritten by the generated sitemap.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

BUN="$(command -v bun || true)"
[[ -n "$BUN" ]] || { echo "FAIL: bun not found on PATH -- required to spawn the island sidecar for the SPA legs"; exit 1; }
if [[ ! -d "$REPO/runtime/node_modules" ]]; then
  echo "runtime/node_modules missing; running 'bun install --frozen-lockfile'..."
  ( cd "$REPO/runtime" && bun install --frozen-lockfile ) \
    || { echo "FAIL: bun install --frozen-lockfile failed in runtime/"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

SITE="$WORK/site"
mkdir -p "$SITE/content/docs/overview" "$SITE/content/blog" "$SITE/layouts/templates" "$SITE/assets" \
         "$SITE/app" "$SITE/hidden" "$SITE/node_modules/@z"
ln -s "$REPO/runtime" "$SITE/node_modules/@z/runtime"

cat >"$SITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Sitemap Fixture",
    .host_url = "https://example.com",
    .url_path_prefix = "myprefix",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .sitemap = true,
}
EOF

cat >"$SITE/layouts/templates/base.shtml" <<'EOF'
<!DOCTYPE html>
<html>
<head><title :text="$site.title"></title></head>
<body id="body">
  <super>
</body>
</html>
EOF

cat >"$SITE/layouts/page.shtml" <<'EOF'
<extend template="base.shtml">
<body id="body">
  <div :html="$page.content()"></div>
</body>
EOF

cat >"$SITE/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "page.shtml",
---
Home.
EOF

cat >"$SITE/content/docs/index.smd" <<'EOF'
---
.title = "Docs",
.layout = "page.shtml",
---
Docs index, linking to [overview]($link.sub('overview')).
EOF

cat >"$SITE/content/docs/overview/index.smd" <<'EOF'
---
.title = "Overview",
.layout = "page.shtml",
.aliases = ["/overview.html"],
---
Overview, reachable at its canonical URL and at the /overview.html alias.
EOF

cat >"$SITE/content/blog/index.smd" <<'EOF'
---
.title = "Blog",
.layout = "page.shtml",
.pagination = { .page_size = 2 },
---
5 active posts, page_size=2, default url_style (page_dir): 3 windows.
EOF

for i in 1 2 3 4 5; do
  cat >"$SITE/content/blog/post$i.smd" <<EOF
---
.title = "Post $i",
.date = @date("2024-06-0${i}T00:00:00"),
.layout = "page.shtml",
---
Post $i.
EOF
done

# A draft: NOT in the active build at all (no --drafts), so it must never
# reach the sitemap -- the strongest form of "excluded" there is.
cat >"$SITE/content/blog/post6.smd" <<'EOF'
---
.title = "Post 6 (draft)",
.date = @date("2024-06-06T00:00:00"),
.layout = "page.shtml",
.draft = true,
---
Unpublished.
EOF

cat >"$SITE/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "@z/runtime",
    "moduleResolution": "bundler",
    "paths": {
      "react/jsx-runtime": ["./node_modules/@z/runtime/src/jsx-runtime.ts"],
      "react/jsx-dev-runtime": ["./node_modules/@z/runtime/src/jsx-runtime.ts"]
    }
  }
}
JSON

# One static route ("/"), one dynamic route with NO staticPaths (only its
# pattern shell is ever written -- must NOT appear in the sitemap), and one
# dynamic route WITH staticPaths (its two concrete entries are real pages
# and must appear; its own pattern shell still must not). `noindex: false`
# is explicit and load-bearing: `noindex` defaults ON (see spa.zig's
# `desc.spa.noindex orelse true`), and only an EXPLICITLY-indexable SPA's
# real routes belong in the sitemap -- the `hidden` SPA below pins the
# opposite case.
cat >"$SITE/app/app.spa.tsx" <<'TSX'
import { Router } from "@z/runtime";

export const spa = { base: "/app", title: "Sitemap SPA", noindex: false };

function Home() { return <div>home</div>; }
function ClubDetail() { return <div>club</div>; }
function ClubSkeleton() { return <div>loading</div>; }
function ItemDetail() { return <div>item</div>; }
function ItemSkeleton() { return <div>loading</div>; }

export const routes = [
  { path: "/", component: Home },
  { path: "/club/:id", component: ClubDetail, skeleton: ClubSkeleton },
  {
    path: "/item/:id",
    component: ItemDetail,
    skeleton: ItemSkeleton,
    staticPaths: async () => [{ id: "1" }, { id: "2" }],
  },
];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
TSX

# A SECOND SPA that does NOT set `noindex` -- it defaults on. Its "/" route
# is a perfectly real, static, prerendered page (checked to exist on disk
# below), which is exactly what makes it a meaningful negative case: nothing
# about the route ITSELF would exclude it from the sitemap, only the owning
# SPA's noindex default.
cat >"$SITE/hidden/hidden.spa.tsx" <<'TSX'
import { Router } from "@z/runtime";

export const spa = { base: "/hidden", title: "Hidden SPA" };

function Home() { return <div>hidden home</div>; }

export const routes = [{ path: "/", component: Home }];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
TSX

OUT="$WORK/out"
build_args=(
  "--output=$OUT" --force "--bun=$BUN" "--island-sidecar=$REPO/runtime/sidecar/render.ts"
  --island-src-dir=. "--spa=app/app.spa.tsx|/app" "--spa=hidden/hidden.spa.tsx|/hidden"
)

# --- (1) disabled by default --------------------------------------------------
OFFSITE="$WORK/offsite"
mkdir -p "$OFFSITE/content" "$OFFSITE/layouts/templates" "$OFFSITE/assets"
cat >"$OFFSITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "No Sitemap",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
}
EOF
cp "$SITE/layouts/templates/base.shtml" "$OFFSITE/layouts/templates/base.shtml"
cp "$SITE/layouts/page.shtml" "$OFFSITE/layouts/page.shtml"
cat >"$OFFSITE/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "page.shtml",
---
Home.
EOF
if ! ( cd "$OFFSITE" && "$ZIGAPAGOS" release "--output=$WORK/off-out" --force ) >"$WORK/off.log" 2>&1; then
  cat "$WORK/off.log"; fail "(1) the sitemap-disabled fixture failed to build"
fi
[[ ! -f "$WORK/off-out/sitemap.xml" ]] || fail "(1) sitemap.xml was emitted even though 'sitemap' is unset (default false)"
echo "PASS (1): sitemap.xml is not emitted unless 'sitemap = true'"

# --- (2)-(8): the main fixture -------------------------------------------------
if ! ( cd "$SITE" && ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime" "$ZIGAPAGOS" release "${build_args[@]}" ) >"$WORK/build.log" 2>&1; then
  cat "$WORK/build.log"; fail "the main fixture build failed"
fi
[[ -f "$OUT/sitemap.xml" ]] || { cat "$WORK/build.log"; fail "sitemap.xml was not emitted even though 'sitemap = true'"; }
SM="$OUT/sitemap.xml"

# Fixture sanity for (7)/(8): the hidden SPA's "/" route really is a real,
# installed file -- if this ever stopped being true the exclusion checks
# below would pass for the wrong reason (nothing to exclude).
[[ -f "$OUT/hidden/index.html" ]] || { cat "$WORK/build.log"; fail "fixture assumption broken: hidden/index.html (the noindex SPA's static route) was not installed"; }

head -1 "$SM" | grep -q '^<?xml version="1.0" encoding="UTF-8"?>$' || { cat "$SM"; fail "sitemap.xml has no XML declaration on its first line"; }
grep -q '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' "$SM" || { cat "$SM"; fail "sitemap.xml has no (correctly namespaced) <urlset>"; }
tail -1 "$SM" | grep -q '^</urlset>$' || { cat "$SM"; fail "sitemap.xml does not end with </urlset>"; }
echo "PASS: sitemap.xml is well-formed (XML declaration, namespaced <urlset>, closing tag)"

mapfile -t LOCS < <(grep -o '<loc>[^<]*</loc>' "$SM" | sed 's/<loc>//; s#</loc>##')
[[ "${#LOCS[@]}" -gt 0 ]] || { cat "$SM"; fail "sitemap.xml has zero <url><loc> entries"; }

want() {
  printf '%s\n' "${LOCS[@]}" | grep -qxF "$1" || { echo "--- sitemap.xml ---"; cat "$SM"; fail "expected '$1' in sitemap.xml"; }
}
missing() {
  printf '%s\n' "${LOCS[@]}" | grep -qxF "$1" && { echo "--- sitemap.xml ---"; cat "$SM"; fail "did NOT expect '$1' in sitemap.xml"; }
  return 0
}

# --- (3) alias duplicates excluded --------------------------------------------
want "https://example.com/myprefix/docs/overview/"
missing "https://example.com/myprefix/overview.html"
echo "PASS (3): the canonical URL is listed, the alias is not"

# --- (2) drafts excluded -------------------------------------------------------
missing "https://example.com/myprefix/blog/post6/"
echo "PASS (2): the draft post is not listed"

# --- (4) pagination page-2+ windows --------------------------------------------
want "https://example.com/myprefix/blog/"
want "https://example.com/myprefix/blog/page/2/"
want "https://example.com/myprefix/blog/page/3/"
missing "https://example.com/myprefix/blog/page/1/"
echo "PASS (4): pagination page-2+ windows are listed (page 1 only at the bare section URL)"

# --- (5) SPA routes: static yes, dynamic-pattern no, staticPaths concrete yes --
want "https://example.com/myprefix/app/"
want "https://example.com/myprefix/app/item/1/"
want "https://example.com/myprefix/app/item/2/"
missing "https://example.com/myprefix/app/club/"
missing "https://example.com/myprefix/app/club/_id/"
missing "https://example.com/myprefix/app/item/"
echo "PASS (5): a static SPA route and staticPaths concrete entries are listed; a dynamic pattern's own shell is not"

# --- (6) host_url + url_path_prefix composed exactly once ----------------------
for loc in "${LOCS[@]}"; do
  case "$loc" in
    https://example.com/myprefix/*) ;;
    *) fail "(6) '$loc' does not start with host_url + url_path_prefix exactly once" ;;
  esac
  case "$loc" in
    *myprefix*myprefix*) fail "(6) '$loc' repeats the url_path_prefix" ;;
  esac
  case "$loc" in
    *//myprefix*|*com//*) fail "(6) '$loc' has a doubled slash after the host" ;;
  esac
done
echo "PASS (6): every URL carries host_url + url_path_prefix exactly once"

# --- (7) a default-noindex SPA's routes are excluded, even a real static one --
missing "https://example.com/myprefix/hidden/"
echo "PASS (7): a default (noindex) SPA's static route is a real installed page but excluded from the sitemap"

# --- (8) REVERSE: the emitted set is EXACTLY the expected set ------------------
EXPECTED=(
  "https://example.com/myprefix/"
  "https://example.com/myprefix/docs/"
  "https://example.com/myprefix/docs/overview/"
  "https://example.com/myprefix/blog/"
  "https://example.com/myprefix/blog/page/2/"
  "https://example.com/myprefix/blog/page/3/"
  "https://example.com/myprefix/blog/post1/"
  "https://example.com/myprefix/blog/post2/"
  "https://example.com/myprefix/blog/post3/"
  "https://example.com/myprefix/blog/post4/"
  "https://example.com/myprefix/blog/post5/"
  "https://example.com/myprefix/app/"
  "https://example.com/myprefix/app/item/1/"
  "https://example.com/myprefix/app/item/2/"
)
printf '%s\n' "${LOCS[@]}" | sort -u >"$WORK/got.txt"
printf '%s\n' "${EXPECTED[@]}" | sort -u >"$WORK/want.txt"
if ! diff -u "$WORK/want.txt" "$WORK/got.txt" >"$WORK/locs.diff"; then
  echo "--- diff (left: expected, right: emitted) ---"
  cat "$WORK/locs.diff"
  fail "(8) REVERSE: sitemap.xml's <loc> set is not exactly the expected set"
fi
echo "PASS (8): REVERSE -- sitemap.xml lists exactly the expected ${#EXPECTED[@]} URLs, no more, no fewer (proves (7) again: the hidden SPA's real page is not among them)"

# --- (9) an alias to the root 'sitemap.xml' is a hard build error -------------
COLSITE="$WORK/colsite"
mkdir -p "$COLSITE/content" "$COLSITE/layouts/templates" "$COLSITE/assets"
cat >"$COLSITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Sitemap Collision",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .sitemap = true,
}
EOF
cp "$SITE/layouts/templates/base.shtml" "$COLSITE/layouts/templates/base.shtml"
cp "$SITE/layouts/page.shtml" "$COLSITE/layouts/page.shtml"
cat >"$COLSITE/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "page.shtml",
---
Home.
EOF
cat >"$COLSITE/content/rogue.smd" <<'EOF'
---
.title = "Rogue",
.layout = "page.shtml",
.aliases = ["/sitemap.xml"],
---
This page tries to alias the site root's sitemap.xml.
EOF
set +e
( cd "$COLSITE" && "$ZIGAPAGOS" release "--output=$WORK/col-out" --force ) >"$WORK/col.out" 2>"$WORK/col.err"
COL_RC=$?
set -e
[[ "$COL_RC" -ne 0 ]] || { cat "$WORK/col.out" "$WORK/col.err"; fail "(9) a page aliased to 'sitemap.xml' built successfully while the sitemap is enabled"; }
grep -qi 'sitemap' "$WORK/col.err" || { cat "$WORK/col.err"; fail "(9) the collision error does not mention 'sitemap'"; }
echo "PASS (9): a page aliased to the root 'sitemap.xml' is a hard build error"

# --- (10) an alternatives output of the root 'sitemap.xml' is also a hard error --
ALTSITE="$WORK/altsite"
mkdir -p "$ALTSITE/content" "$ALTSITE/layouts/templates" "$ALTSITE/assets"
cat >"$ALTSITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Sitemap Alternative Collision",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .sitemap = true,
}
EOF
cp "$SITE/layouts/templates/base.shtml" "$ALTSITE/layouts/templates/base.shtml"
cp "$SITE/layouts/page.shtml" "$ALTSITE/layouts/page.shtml"
cat >"$ALTSITE/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "page.shtml",
---
Home.
EOF
cat >"$ALTSITE/content/rogue.smd" <<'EOF'
---
.title = "Rogue",
.layout = "page.shtml",
.alternatives = [{
    .name = "custom-sitemap",
    .output = "/sitemap.xml",
    .layout = "page.shtml",
}],
---
This page tries to write an alternative output at the site root's sitemap.xml.
EOF
set +e
( cd "$ALTSITE" && "$ZIGAPAGOS" release "--output=$WORK/alt-out" --force ) >"$WORK/alt.out" 2>"$WORK/alt.err"
ALT_RC=$?
set -e
[[ "$ALT_RC" -ne 0 ]] || { cat "$WORK/alt.out" "$WORK/alt.err"; fail "(10) a page with an alternatives output of 'sitemap.xml' built successfully while the sitemap is enabled"; }
grep -qi 'sitemap' "$WORK/alt.err" || { cat "$WORK/alt.err"; fail "(10) the collision error does not mention 'sitemap'"; }
echo "PASS (10): a page whose alternatives output resolves to the root 'sitemap.xml' is also a hard build error"

# --- (11) sitemap=true with an invalid host_url still fails at config load -----
HUSITE="$WORK/husite"
mkdir -p "$HUSITE/content" "$HUSITE/layouts/templates" "$HUSITE/assets"
cat >"$HUSITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Bad Host URL",
    .host_url = "",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .sitemap = true,
}
EOF
cp "$SITE/layouts/templates/base.shtml" "$HUSITE/layouts/templates/base.shtml"
cp "$SITE/layouts/page.shtml" "$HUSITE/layouts/page.shtml"
cat >"$HUSITE/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "page.shtml",
---
Home.
EOF
set +e
( cd "$HUSITE" && "$ZIGAPAGOS" release "--output=$WORK/hu-out" --force ) >"$WORK/hu.out" 2>"$WORK/hu.err"
HU_RC=$?
set -e
[[ "$HU_RC" -ne 0 ]] || { cat "$WORK/hu.out" "$WORK/hu.err"; fail "(11) 'sitemap = true' with an empty host_url built successfully"; }
grep -qi 'host_url\|host url' "$WORK/hu.err" || { cat "$WORK/hu.err"; fail "(11) the failure does not mention host_url"; }
echo "PASS (11): 'sitemap = true' with an invalid host_url still fails at config validation (the existing mandatory-field check already covers it)"

# --- (12) a trailing-slash host_url must not double the slash in any <loc> ----
TRAILSITE="$WORK/trailsite"
mkdir -p "$TRAILSITE/content/blog" "$TRAILSITE/layouts/templates" "$TRAILSITE/assets"
cat >"$TRAILSITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Trailing Slash Host",
    .host_url = "https://example.com/",
    .url_path_prefix = "myprefix",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .sitemap = true,
}
EOF
cp "$SITE/layouts/templates/base.shtml" "$TRAILSITE/layouts/templates/base.shtml"
cp "$SITE/layouts/page.shtml" "$TRAILSITE/layouts/page.shtml"
cat >"$TRAILSITE/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "page.shtml",
---
Home.
EOF
# A paginated section too: composePageUrl's n>1 branch appends its own tail
# after the same prefix, so it needs the same trim to not double the slash.
cat >"$TRAILSITE/content/blog/index.smd" <<'EOF'
---
.title = "Blog",
.layout = "page.shtml",
.pagination = { .page_size = 2 },
---
3 active posts, page_size=2: 2 windows.
EOF
for i in 1 2 3; do
  cat >"$TRAILSITE/content/blog/post$i.smd" <<EOF
---
.title = "Post $i",
.date = @date("2024-06-0${i}T00:00:00"),
.layout = "page.shtml",
---
Post $i.
EOF
done
if ! ( cd "$TRAILSITE" && "$ZIGAPAGOS" release "--output=$WORK/trail-out" --force ) >"$WORK/trail.log" 2>&1; then
  cat "$WORK/trail.log"; fail "(12) the trailing-slash host_url fixture failed to build"
fi
TRAIL_SM="$WORK/trail-out/sitemap.xml"
[[ -f "$TRAIL_SM" ]] || { cat "$WORK/trail.log"; fail "(12) sitemap.xml was not emitted for the trailing-slash host_url fixture"; }
mapfile -t TRAIL_LOCS < <(grep -o '<loc>[^<]*</loc>' "$TRAIL_SM" | sed 's/<loc>//; s#</loc>##')
[[ "${#TRAIL_LOCS[@]}" -gt 0 ]] || { cat "$TRAIL_SM"; fail "(12) trailing-slash fixture's sitemap.xml has zero entries"; }
for loc in "${TRAIL_LOCS[@]}"; do
  case "$loc" in
    https://example.com/myprefix/*) ;;
    *) echo "--- sitemap.xml ---"; cat "$TRAIL_SM"; fail "(12) '$loc' does not start with the trimmed host_url + url_path_prefix exactly once" ;;
  esac
  case "$loc" in
    *example.com//*) echo "--- sitemap.xml ---"; cat "$TRAIL_SM"; fail "(12) '$loc' has a doubled slash right after the (trailing-slash) host_url" ;;
  esac
done
printf '%s
' "${TRAIL_LOCS[@]}" | grep -qxF "https://example.com/myprefix/" || { cat "$TRAIL_SM"; fail "(12) the home page's URL is missing entirely"; }
printf '%s
' "${TRAIL_LOCS[@]}" | grep -qxF "https://example.com/myprefix/blog/page/2/" || { cat "$TRAIL_SM"; fail "(12) the pagination window's URL (n>1, exercises composePageUrl's tail branch) is missing or malformed"; }
echo "PASS (12): a trailing-slash host_url does not double the slash in any <loc>, including a pagination window's URL"

# --- (13) static_assets may not claim the generated sitemap path ------------
for static_entry in '"sitemap.xml"' '"**"'; do
  STATIC_SITE="$WORK/static-${static_entry//[^a-z]/}"
  mkdir -p "$STATIC_SITE/content" "$STATIC_SITE/layouts/templates" "$STATIC_SITE/assets"
  cp "$SITE/layouts/templates/base.shtml" "$STATIC_SITE/layouts/templates/base.shtml"
  cp "$SITE/layouts/page.shtml" "$STATIC_SITE/layouts/page.shtml"
  cp "$SITE/content/index.smd" "$STATIC_SITE/content/index.smd"
  printf '%s\n' 'this must never overwrite the generated sitemap' >"$STATIC_SITE/assets/sitemap.xml"
  cat >"$STATIC_SITE/zigapagos.ziggy" <<EOF
Site {
    .title = "Static Sitemap Collision",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .static_assets = [$static_entry],
    .sitemap = true,
}
EOF
  set +e
  ( cd "$STATIC_SITE" && "$ZIGAPAGOS" release "--output=$STATIC_SITE/out" --force --format=json ) \
    >"$STATIC_SITE/out.log" 2>"$STATIC_SITE/err.log"
  STATIC_RC=$?
  set -e
  [[ "$STATIC_RC" -ne 0 ]] || {
    cat "$STATIC_SITE/out.log" "$STATIC_SITE/err.log"
    fail "(13) static_assets entry $static_entry silently overwrote the generated sitemap"
  }
  grep -q '"code":"ZP_STATIC_ASSET_OUTPUT_COLLISION"' "$STATIC_SITE/err.log" || {
    cat "$STATIC_SITE/err.log"
    fail "(13) static_assets entry $static_entry did not emit the stable collision code"
  }
done
echo "PASS (13): exact and glob static_assets entries cannot overwrite the generated sitemap"

echo "PASS: tests/sitemap/sitemap.sh"
