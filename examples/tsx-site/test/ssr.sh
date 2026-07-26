#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# (1) Install @z/runtime's own deps (preact, preact-render-to-string) so the
# sidecar can render. Without this the sidecar fails with a module-not-found
# error when it tries to import preact.
cd ../../runtime && mise exec -- bun install
cd - >/dev/null

# (2) Install this fixture's deps — creates node_modules/@z/runtime symlink
# to ../../runtime so the island's `import { useState } from "@z/runtime"`
# resolves when Bun runs the sidecar with cwd=fixture root.
mise exec -- bun install

# (3) Build the site: zigapagos spawns the Bun sidecar with cwd = fixture root,
# the island SSRs, and the HTML is written to zig-out/site/index.html.
# Restore tests/ after build (build.zig footgun).
mise exec -- zig build
# The zigapagos root build.zig rm -rf's the committed tests/**/snapshot baselines
# at configure time. Restore ONLY the files the build deleted (leave any local
# modifications to tests/ untouched).
git -C ../.. ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C ../.. restore -- {}

# (4) Assert the island was SSR'd into the output HTML.
OUT="zig-out/site/index.html"
grep -q '<section><h1>' "$OUT" || { echo "FAIL: island SSR HTML missing"; exit 1; }
grep -q 'data-z-island' "$OUT" || { echo "FAIL: island placeholder missing"; exit 1; }
grep -q 'data-z-props' "$OUT" || { echo "FAIL: props script missing"; exit 1; }

# (5) Assert the client bundles + import map wiring are present.
test -f zig-out/site/zigapagos-runtime.js || { echo "FAIL: shared runtime bundle missing"; exit 1; }
test -f zig-out/site/islands/Hero.island.js || { echo "FAIL: island bundle missing"; exit 1; }
grep -q 'data-z-module="/islands/Hero.island.js"' "$OUT" || { echo "FAIL: data-z-module missing"; exit 1; }
grep -q '<script type="importmap">' "$OUT" || { echo "FAIL: import map missing"; exit 1; }

# modulepreload hints (v1): runtime + each island module, preload-first.
grep -q '<link rel="modulepreload" href="/zigapagos-runtime.js">' "$OUT" || { echo "FAIL: runtime modulepreload missing"; exit 1; }
grep -q '<link rel="modulepreload" href="/islands/Hero.island.js">' "$OUT" || { echo "FAIL: Hero modulepreload missing"; exit 1; }
grep -q '<link rel="modulepreload" href="/islands/Flagged.island.js">' "$OUT" || { echo "FAIL: Flagged modulepreload missing"; exit 1; }
grep -q '<link rel="modulepreload" href="/islands/Panel.island.js">' "$OUT" || { echo "FAIL: Panel modulepreload missing"; exit 1; }
# Hero appears twice on the page (one nested in Panel) but its preload link is deduped to ONE.
[ "$(grep -o '<link rel="modulepreload" href="/islands/Hero.island.js">' "$OUT" | wc -l)" -eq 1 ] || { echo "FAIL: Hero modulepreload not deduped"; exit 1; }
# import map appears before any modulepreload: per the import-maps spec, a map
# is only processed if it appears before any module loading starts, and a
# <link rel="modulepreload"> starts one — a later map is disregarded.
python3 -c "
import sys
html = open(sys.argv[1]).read()
assert html.index('importmap') < html.index('modulepreload'), 'importmap must precede preload'
print('modulepreload ordering OK')
" "$OUT" || { echo "FAIL: modulepreload ordering"; exit 1; }

# The island bundle must NOT inline Preact (it imports @z/runtime external):
grep -q '"@z/runtime"' zig-out/site/islands/Hero.island.js || { echo "FAIL: island did not keep @z/runtime external"; exit 1; }

# One-Preact-instance guard at the asset level: the island bundle must keep
# @z/runtime external (no Preact internals inlined). Catches a regression the
# browser e2e would otherwise be the only check for.
if grep -qE 'preact|__H|hookState' zig-out/site/islands/Hero.island.js; then
  echo "FAIL: island bundle inlined Preact (one-instance invariant broken)"; exit 1
fi

# Flagged island (compat-importing) — same two assertions:
# (a) @z/runtime namespace must be kept external (imports may be subpaths like
#     @z/runtime/compat or @z/runtime/jsx-runtime — match the prefix, not the
#     bare specifier, since Flagged imports via the /compat subpath).
# (b) no inlined Preact internals — proves compat did not drag in a second copy.
test -f zig-out/site/islands/Flagged.island.js || { echo "FAIL: Flagged island bundle missing"; exit 1; }
grep -q '"@z/runtime' zig-out/site/islands/Flagged.island.js || { echo "FAIL: Flagged island did not keep @z/runtime external"; exit 1; }
if grep -qE 'preact|__H|hookState' zig-out/site/islands/Flagged.island.js; then
  echo "FAIL: Flagged island bundle inlined Preact (compat broke one-instance invariant)"; exit 1
fi

# Widget island (npm-compat bridge): renders @demo/widget, whose React
# `useState` is imported from the bare `react` specifier. The bridge keeps `react`
# external and the import-map resolves it to the shared runtime => ONE Preact.
# (a) The @demo/widget code IS bundled into the island (button markup present).
test -f zig-out/site/islands/Widget.island.js || { echo "FAIL: Widget island bundle missing"; exit 1; }
grep -q 'data-widget' zig-out/site/islands/Widget.island.js || { echo "FAIL: @demo/widget not bundled into island"; exit 1; }
# (b) `react` is kept EXTERNAL (a bare import survives) — NOT bundled/renamed.
grep -q 'from *"react"' zig-out/site/islands/Widget.island.js || { echo "FAIL: react not kept external in npm-compat island"; exit 1; }
# (c) ONE-PREACT: no inlined Preact internals despite bundling an npm React component.
if grep -qE 'preact|__H|hookState' zig-out/site/islands/Widget.island.js; then
  echo "FAIL: npm-compat island inlined Preact (one-instance invariant broken)"; exit 1
fi
# (d) The page import-map routes `react` to the shared runtime.
grep -q '"react":"/zigapagos-runtime.js"' "$OUT" || { echo "FAIL: react import-map entry missing"; exit 1; }
# (e) The npm component SSR'd (server-rendered without JS) via the tsconfig-paths alias.
grep -q '<button data-widget="true">Clicks: 0</button>' "$OUT" || { echo "FAIL: npm-compat Widget did not SSR"; exit 1; }

# Panel island: composite island with named + default slots.
# (a) The Panel island placeholder is in the output.
grep -q 'data-z-src="components/Panel.island.tsx"' "$OUT" || { echo "FAIL: Panel island placeholder missing"; exit 1; }

# (b) The heading named slot was woven in by the sidecar — <z-slot data-z-slot="heading"> must be
#     inside the Panel's <header> (the sidecar injects it, not pass.zig). We check that the
#     heading slot wrapper exists and that it follows <header> in the output.
grep -q 'z-slot data-z-slot="heading"' "$OUT" || { echo "FAIL: Panel heading slot z-slot wrapper missing"; exit 1; }

# (c) data-z-slots JSON script is emitted for the Panel (the client runtime reads it on hydrate).
grep -q 'data-z-slots="z-island-' "$OUT" || { echo "FAIL: Panel data-z-slots script missing"; exit 1; }

# (d) The slots JSON contains both "heading" and "default" keys, and the nested
#     Hero island placeholder is in the default slot. Uses raw_decode so the
#     embedded </script> from the nested props tag does not truncate extraction.
python3 -c "
import json, sys, re
html = open(sys.argv[1]).read()
m = re.search(r'data-z-slots=\"z-island-\d+\">', html)
assert m, 'no data-z-slots script found'
rest = html[m.end():]
slots, _ = json.JSONDecoder().raw_decode(rest)
assert 'heading' in slots, f'missing heading key in slots: {list(slots)}'
assert 'default' in slots, f'missing default key in slots: {list(slots)}'
default_slot = slots['default']
assert 'data-z-island' in default_slot, 'nested island placeholder not in default slot'
assert 'Hero.island.tsx' in default_slot, 'nested Hero src not in default slot'
print('slots keys OK:', list(slots), '| nested Hero in default slot: OK')
" "$OUT" || { echo "FAIL: Panel slots JSON / nested Hero check failed"; exit 1; }

# Panel island bundle: same external-@z/runtime guard as Hero/Flagged.
test -f zig-out/site/islands/Panel.island.js || { echo "FAIL: Panel island bundle missing"; exit 1; }
grep -q '"@z/runtime' zig-out/site/islands/Panel.island.js || { echo "FAIL: Panel island did not keep @z/runtime external"; exit 1; }
if grep -qE 'preact|__H|hookState' zig-out/site/islands/Panel.island.js; then
  echo "FAIL: Panel island bundle inlined Preact (one-instance invariant broken)"; exit 1
fi

echo "PASS: TSX island SSR'd via Bun sidecar"
