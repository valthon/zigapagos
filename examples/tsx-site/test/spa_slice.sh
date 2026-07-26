#!/usr/bin/env bash
# Per-deployable runtime slicing e2e: proves a public SPA's per-SPA runtime
# EXCLUDES admin-only host bindings (SEPARATION), is smaller than the full shared
# runtime (SIZE), that a computed-host-access SPA falls back to the shared runtime
# (FALLBACK), and that all three hydrate interactively on the right runtime with
# one Preact (via test/spa_slice_playwright.py).
set -euo pipefail
cd "$(dirname "$0")/.."
# The root build.zig rm -rf's committed tests/**/snapshot baselines at configure
# time; restore whatever it deleted on the way out.
trap 'git -C ../.. ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C ../.. restore -- {}' EXIT

(cd ../../runtime && mise exec -- bun install)
mise exec -- bun install
# Clean rebuild so the sliced runtimes reflect current source (no stale bundles).
rm -rf .zig-cache zig-out
mise exec -- zig build

S=zig-out/site
SHARED="$S/zigapagos-runtime.js"
PUB="$S/spa/public-runtime.js"
ADM="$S/spa/admin-runtime.js"

# ── per-SPA runtimes exist for public/admin; fallback + compat have none ──────
test -f "$PUB"  || { echo "FAIL: no public-runtime.js"; exit 1; }
test -f "$ADM"  || { echo "FAIL: no admin-runtime.js"; exit 1; }
test -f "$SHARED" || { echo "FAIL: no shared runtime"; exit 1; }
! test -f "$S/spa/fallback-runtime.js" || { echo "FAIL: fallback SPA emitted its own runtime (should reuse shared)"; exit 1; }
# The compat SPA imports @z/runtime/compat: the slicer MUST fall back to the
# shared runtime (which has the compat surface) — a per-SPA compat runtime would
# be built from spa-entry.ts (no compat) and crash at load.
! test -f "$S/spa/compat-runtime.js" || { echo "FAIL: compat SPA was sliced (would crash: sliced runtime has no compat surface)"; exit 1; }

# ── SEPARATION: the admin-only host.loadScript source (its unique
#    `createElement("script")` marker) is in the admin runtime but NOT the public
#    one. recaptcha's textarea id must also be absent from both sliced runtimes. ─
grep -q 'createElement("script")' "$ADM" || { echo "FAIL: admin runtime is missing host.loadScript (createElement marker)"; exit 1; }
! grep -q 'createElement("script")' "$PUB" || { echo "FAIL: SEPARATION BROKEN — public runtime contains admin-only host.loadScript"; exit 1; }
! grep -q 'g-recaptcha-response' "$PUB" || { echo "FAIL: public runtime contains recaptcha source"; exit 1; }

# ── SIZE: each sliced runtime is smaller than the full shared runtime ─────────
sz() { wc -c < "$1"; }
shared_sz=$(sz "$SHARED"); pub_sz=$(sz "$PUB"); adm_sz=$(sz "$ADM")
[ "$pub_sz" -lt "$shared_sz" ] || { echo "FAIL: public runtime ($pub_sz) not smaller than shared ($shared_sz)"; exit 1; }
[ "$adm_sz" -lt "$shared_sz" ] || { echo "FAIL: admin runtime ($adm_sz) not smaller than shared ($shared_sz)"; exit 1; }
echo "SIZE: shared=$shared_sz public=$pub_sz admin=$adm_sz"

# ── shell wiring: public/admin shells point ONLY at their sliced runtime; the
#    fallback shell points ONLY at the shared runtime. Checks the import map, the
#    modulepreload, and the module <script> together. ────────────────────────
check_shell() {  # <base> <expected-runtime-url> <forbidden-runtime-url>
  local html="$S/$1/index.html" want="$2" bad="$3"
  grep -q "\"@z/runtime\":\"$want\"" "$html" || { echo "FAIL: $1 import-map not -> $want"; exit 1; }
  grep -q "rel=\"modulepreload\" href=\"$want\"" "$html" || { echo "FAIL: $1 missing modulepreload $want"; exit 1; }
  grep -q "<script type=\"module\" src=\"$want\">" "$html" || { echo "FAIL: $1 runtime <script> not -> $want"; exit 1; }
  ! grep -q "$bad" "$html" || { echo "FAIL: $1 shell references forbidden runtime $bad"; exit 1; }
}
check_shell public   /spa/public-runtime.js /zigapagos-runtime.js
check_shell admin    /spa/admin-runtime.js  /zigapagos-runtime.js
check_shell fallback /zigapagos-runtime.js  /spa/fallback-runtime.js
check_shell compat   /zigapagos-runtime.js  /spa/compat-runtime.js

# ── the shared runtime is unchanged for island content pages (still shipped) ──
grep -q '/zigapagos-runtime.js' "$S/index.html" || { echo "FAIL: island page lost the shared runtime"; exit 1; }

# ── interactive hydration (one Preact each) on the correct runtime ───────────
mise exec -- python3 test/spa_slice_playwright.py "$S"

echo "PASS: per-deployable runtime slicing — separation + size + fallback + one-Preact hydration"
