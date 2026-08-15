#!/usr/bin/env bash
# End-to-end contract for every non-Astro migration adapter: detection,
# inventory, deterministic React/content conversion, review metadata, source
# immutability, and non-clobbering repeat runs.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"

fail() { echo "FAIL: $*"; exit 1; }
if [[ ! -x "$ZIGAPAGOS" ]]; then
  mise exec -- zig build || fail "zig build failed"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Next.js: no next.config file on purpose. Detection must use package.json,
# and a colocated App Router client module must become a scaffold candidate.
NEXT="$WORK/next"
mkdir -p "$NEXT/src/app/dashboard"
cat > "$NEXT/package.json" <<'JSON'
{"dependencies":{"next":"16.0.0","react":"19.0.0"}}
JSON
cat > "$NEXT/src/app/dashboard/Chart.tsx" <<'TSX'
"use client";
import { useState } from "react";
export default function Chart() {
  const [n] = useState(1);
  return <output>{n}</output>;
}
TSX
NEXT_BEFORE="$(sha256sum "$NEXT/src/app/dashboard/Chart.tsx" | cut -d' ' -f1)"
"$ZIGAPAGOS" migrate "$NEXT" --scaffold "$WORK/next-components" -o "$WORK/NEXT-MIGRATION.md"
grep -q 'Next.js' "$WORK/NEXT-MIGRATION.md" || fail "Next.js was not auto-detected"
grep -q 'src/app/dashboard/Chart.tsx' "$WORK/NEXT-MIGRATION.md" || fail "use client module missing from worklist"
grep -q 'from "@z/runtime"' "$WORK/next-components/Chart.island.tsx" || fail "React import was not converted"
NEXT_AFTER="$(sha256sum "$NEXT/src/app/dashboard/Chart.tsx" | cut -d' ' -f1)"
[[ "$NEXT_BEFORE" == "$NEXT_AFTER" ]] || fail "Next.js source was modified"

# Gatsby: config detection and conventional React components share the real
# scaffold path rather than receiving a placeholder-only implementation.
GATSBY="$WORK/gatsby"
mkdir -p "$GATSBY/src/pages" "$GATSBY/src/components"
: > "$GATSBY/gatsby-config.js"
cat > "$GATSBY/src/pages/index.jsx" <<'JSX'
export default function Home() { return <main>Home</main>; }
JSX
cat > "$GATSBY/src/components/Signup.js" <<'JSX'
import React, { useState } from "react";
export default function Signup() {
  const [email] = useState("");
  return <output>{email}</output>;
}
JSX
"$ZIGAPAGOS" migrate "$GATSBY" --scaffold "$WORK/gatsby-components" -o "$WORK/GATSBY-MIGRATION.md"
grep -q 'Gatsby' "$WORK/GATSBY-MIGRATION.md" || fail "Gatsby was not auto-detected"
grep -q 'src/pages/index.jsx' "$WORK/GATSBY-MIGRATION.md" || fail "Gatsby page missing from worklist"
grep -q 'from "@z/runtime"' "$WORK/gatsby-components/Signup.island.tsx" || fail "Gatsby .js React import was not converted"

# Nuxt/Vue: package fallback detection and all conventional source groups must
# be inventoried, while the report remains honest that Vue semantics need a port.
NUXT="$WORK/nuxt"
mkdir -p "$NUXT/pages" "$NUXT/components"
cat > "$NUXT/package.json" <<'JSON'
{"dependencies":{"nuxt":"4.0.0","vue":"3.5.0"}}
JSON
cat > "$NUXT/pages/index.vue" <<'VUE'
<template><main>Home</main></template>
VUE
cat > "$NUXT/components/Signup.vue" <<'VUE'
<script setup>const email = ref("")</script>
<template><output>{{ email }}</output></template>
VUE
"$ZIGAPAGOS" migrate "$NUXT" -o "$WORK/NUXT-MIGRATION.md"
grep -q 'Nuxt/Vue' "$WORK/NUXT-MIGRATION.md" || fail "Nuxt was not auto-detected"
grep -q 'pages/index.vue' "$WORK/NUXT-MIGRATION.md" || fail "Nuxt page missing from worklist"
grep -q 'components/Signup.vue' "$WORK/NUXT-MIGRATION.md" || fail "Vue component missing from worklist"
grep -q 'Vue SFCs are not mechanically rewritten' "$WORK/NUXT-MIGRATION.md" || fail "Nuxt report overclaims automatic conversion"

# Plain Vue has no Nuxt directory contract. Its complete src/**/*.vue tree,
# including a root-level App.vue, must still be visible in the worklist.
VUE="$WORK/vue"
mkdir -p "$VUE/src/features"
cat > "$VUE/package.json" <<'JSON'
{"dependencies":{"vue":"3.5.0"}}
JSON
cat > "$VUE/src/App.vue" <<'VUE'
<template><main>App</main></template>
VUE
cat > "$VUE/src/features/Room.vue" <<'VUE'
<template><section>Room</section></template>
VUE
"$ZIGAPAGOS" migrate "$VUE" -o "$WORK/VUE-MIGRATION.md"
grep -q 'src/App.vue' "$WORK/VUE-MIGRATION.md" || fail "plain Vue App.vue missing from worklist"
grep -q 'src/features/Room.vue' "$WORK/VUE-MIGRATION.md" || fail "plain Vue nested SFC missing from worklist"

# Hugo: YAML frontmatter becomes Ziggy, the Markdown body survives byte content,
# _index routing is normalized, and a repeat run versions rather than overwrites.
HUGO="$WORK/hugo"
mkdir -p "$HUGO/content/blog" "$HUGO/layouts"
: > "$HUGO/hugo.toml"
cat > "$HUGO/content/blog/_index.md" <<'MD'
---
title: "Journal"
date: 2026-08-15
draft: true
---
# Preserved body
MD
HUGO_BEFORE="$(sha256sum "$HUGO/content/blog/_index.md" | cut -d' ' -f1)"
"$ZIGAPAGOS" migrate "$HUGO" --convert-content "$WORK/hugo-content" -o "$WORK/HUGO-MIGRATION.md"
OUT="$WORK/hugo-content/blog/index.smd"
grep -q '^.title = "Journal",$' "$OUT" || fail "Hugo title was not normalized"
grep -q '^.date = @date("2026-08-15T00:00:00"),$' "$OUT" || fail "Hugo date was not normalized"
grep -q '^.draft = true,$' "$OUT" || fail "Hugo draft was not normalized"
grep -q '^# Preserved body$' "$OUT" || fail "Hugo Markdown body was not preserved"
grep -q 'migration_review = true' "$OUT" || fail "review marker missing"
VALIDATE="$WORK/validate"
mkdir -p "$VALIDATE/content/blog"
cp -r tests/rendering/simple/layouts "$VALIDATE/"
cp tests/rendering/simple/zigapagos.ziggy "$VALIDATE/"
cp tests/rendering/simple/content/index.smd "$VALIDATE/content/"
cp "$OUT" "$VALIDATE/content/blog/index.smd"
( cd "$VALIDATE" && "$ZIGAPAGOS" validate ) || fail "converted Hugo content is not valid Zigapagos input"
"$ZIGAPAGOS" migrate "$HUGO" --convert-content "$WORK/hugo-content" -o "$WORK/HUGO-MIGRATION-2.md"
[[ -f "$OUT.new" ]] || fail "repeat conversion clobbered instead of writing .new"
/usr/bin/diff -q "$OUT" "$OUT.new" >/dev/null || fail "versioned conversion differs"
HUGO_AFTER="$(sha256sum "$HUGO/content/blog/_index.md" | cut -d' ' -f1)"
[[ "$HUGO_BEFORE" == "$HUGO_AFTER" ]] || fail "Hugo source was modified"

# Jekyll: dated post paths, published state, and unknown/invalid metadata are
# all carried into a valid target instead of being silently discarded.
JEKYLL="$WORK/jekyll"
mkdir -p "$JEKYLL/_posts" "$JEKYLL/_includes"
: > "$JEKYLL/_config.yml"
cat > "$JEKYLL/_posts/2026-08-15-hello.md" <<'MD'
---
title: Hello
date: 2026-02-30
published: false
permalink: /hello/
tags: [news]
---
# Jekyll body
MD
cat > "$JEKYLL/_includes/card.html" <<'HTML'
<article>{{ include.title }}</article>
HTML
JEKYLL_LOG="$WORK/jekyll.log"
"$ZIGAPAGOS" migrate "$JEKYLL" --convert-content "$WORK/jekyll-content" -o "$WORK/JEKYLL-MIGRATION.md" >"$JEKYLL_LOG" 2>&1
JEKYLL_OUT="$WORK/jekyll-content/posts/2026-08-15-hello.smd"
grep -q 'Jekyll' "$WORK/JEKYLL-MIGRATION.md" || fail "Jekyll was not auto-detected"
grep -q '_includes/card.html' "$WORK/JEKYLL-MIGRATION.md" || fail "Jekyll include missing from worklist"
grep -q '^.draft = true,$' "$JEKYLL_OUT" || fail "Jekyll published state was not converted"
grep -q 'migration_frontmatter' "$JEKYLL_OUT" || fail "unconverted Jekyll frontmatter was discarded"
grep -q 'permalink: /hello/' "$JEKYLL_OUT" || fail "Jekyll permalink was not preserved for review"
grep -q 'migration_invalid_date = "2026-02-30"' "$JEKYLL_OUT" || fail "invalid Jekyll date was not preserved"
grep -q 'REVIEW .*unconverted frontmatter' "$JEKYLL_LOG" || fail "unconverted frontmatter warning was not printed"
grep -q 'REVIEW .*invalid date' "$JEKYLL_LOG" || fail "invalid date warning was not printed"
mkdir -p "$VALIDATE/content/posts"
cp tests/rendering/simple/content/index.smd "$VALIDATE/content/posts/index.smd"
cp "$JEKYLL_OUT" "$VALIDATE/content/posts/2026-08-15-hello.smd"
( cd "$VALIDATE" && "$ZIGAPAGOS" validate ) || fail "converted Jekyll review metadata is not valid Zigapagos input"

HELP="$WORK/help.txt"
"$ZIGAPAGOS" help >"$HELP" 2>&1
grep -q 'Scan a supported framework' "$HELP" || fail "top-level help still describes migrate as Astro-only"

echo "PASS: Next.js, Gatsby, Nuxt/Vue, Hugo, and Jekyll migration adapters"
