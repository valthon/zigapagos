#!/usr/bin/env bash
# Real-runtime replay for the parity evidence emitted by the Rails presentation
# fixture. Unlike tests/dev/e2e.sh this test never places a stub named zigbase
# on PATH: a located binary is the production server under test.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 0; }

ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"
[[ -x "$ZIGAPAGOS" ]] || zig build || fail "zig build failed"
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"

# Always exercise the checked-in contract before any optional-tool skip. This
# makes a Bun/ZigBase-less CI host still catch a deleted schema, renamed fixed
# runner, or a harness edit that stopped threading the isolated data dir.
[[ -f "$REPO/tests/migrate/rails-presentation/backend/schema.json" ]] \
  || fail "the checked-in parity schema is missing"
grep -q 'pub const parity_runner_path = "test/parity.ts"' "$REPO/src/cli/rails/scaffold.zig" \
  || fail "the fixed Bun runner contract moved"
grep -q 'pub const journey_runner_path = "test/journey_playwright.py"' "$REPO/src/cli/rails/scaffold.zig" \
  || fail "the fixed Playwright runner contract moved"
grep -q -- '--data-dir="$data"' "$0" \
  || fail "the parity harness no longer threads its prepared data directory"
echo "PASS: static Rails parity harness contract"

command -v ruby >/dev/null 2>&1 || skip "ruby is not on PATH; Rails discovery cannot run"
command -v bun >/dev/null 2>&1 || skip "bun is not on PATH; the fixed parity runner cannot run"

PIN="$(sed -n 's/^[[:space:]]*pub const pinned_version[[:space:]]*=[[:space:]]*"\(v\{0,1\}[0-9.]*\)".*/\1/p' "$REPO/src/cli/zigbase.zig")"
[[ -n "$PIN" ]] || fail "could not read the owned ZigBase pin"
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME:-}/.cache}"
CACHE_ZIGBASE="$CACHE_ROOT/zigapagos/zigbase/$PIN/zigbase"

if [[ -n "${REAL_ZIGBASE:-}" ]]; then
  [[ -x "$REAL_ZIGBASE" ]] || fail "REAL_ZIGBASE is set but is not executable: $REAL_ZIGBASE"
  ZIGBASE="$REAL_ZIGBASE"
elif command -v zigbase >/dev/null 2>&1; then
  ZIGBASE="$(command -v zigbase)"
elif [[ -x "$CACHE_ZIGBASE" ]]; then
  ZIGBASE="$CACHE_ZIGBASE"
else
  if [[ "${DOWNLOAD_ZIGBASE:-0}" != 1 ]]; then
    skip "no real ZigBase found (set REAL_ZIGBASE, put zigbase on PATH, populate $CACHE_ZIGBASE, or set DOWNLOAD_ZIGBASE=1)"
  fi
  # Download through the product command that owns the pin, checksum, cache
  # layout, and explicit opt-in policy. A one-file release tree is sufficient
  # for the server/readiness handshake used only to populate the cache.
  DOWNLOAD_WORK="$(mktemp -d)"
  mkdir -p "$DOWNLOAD_WORK/site"
  printf '<!doctype html><title>download probe</title>\n' > "$DOWNLOAD_WORK/site/index.html"
  "$ZIGAPAGOS" e2e --download-zigbase --site="$DOWNLOAD_WORK/site" -- true \
    || fail "explicit pinned ZigBase download failed"
  rm -rf "$DOWNLOAD_WORK"
  [[ -x "$CACHE_ZIGBASE" ]] || fail "download succeeded but $CACHE_ZIGBASE is absent"
  ZIGBASE="$CACHE_ZIGBASE"
fi
echo "using real ZigBase: $ZIGBASE"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
cp -R "$REPO/tests/migrate/rails-presentation" "$WORK/app"
TARGET="$WORK/target"
BACKEND="$WORK/app/backend/openapi.json"
SCHEMA="$WORK/app/backend/schema.json"
DECISIONS="$WORK/app/MIGRATION.decisions.json"

echo "generating answered Rails presentation target..."
"$ZIGAPAGOS" migrate "$WORK/app" \
  --from rails --target "$TARGET" --decisions "$DECISIONS" \
  --backend "$BACKEND" --runtime-path "$REPO/runtime" \
  || fail "answered Rails presentation migration failed"

echo "building generated target..."
( cd "$TARGET" && ZIGAPAGOS_BIN="$ZIGAPAGOS" bash build.sh ) \
  || fail "generated Rails presentation target failed to build"
[[ -f "$TARGET/zig-out/site/posts/new/index.html" ]] \
  || fail "generated release tree is missing posts/new"
[[ -f "$TARGET/test/parity.ts" && -f "$TARGET/test/journey_playwright.py" ]] \
  || fail "migration did not emit both fixed parity runners"

run_bun() {
  local data="$1"
  "$ZIGAPAGOS" e2e --site="$TARGET/zig-out/site" --data-dir="$data" \
    --zigbase="$ZIGBASE" -- bash -c 'cd "$1" && exec bun test/parity.ts' _ "$TARGET"
}

run_browser() {
  local data="$1"
  "$ZIGAPAGOS" e2e --site="$TARGET/zig-out/site" --data-dir="$data" \
    --zigbase="$ZIGBASE" -- bash -c 'cd "$1" && exec python3 test/journey_playwright.py' _ "$TARGET"
}

prepare_data() {
  local data="$1"
  local apply_output
  mkdir -p "$data"
  "$ZIGBASE" migrate --data-dir "$data" \
    || fail "real ZigBase migrate failed for $data"
  apply_output="$("$ZIGBASE" schema apply "$SCHEMA" --data-dir "$data" 2>&1)" \
    || { echo "$apply_output"; fail "real ZigBase schema apply failed for $data"; }
  echo "$apply_output"
  # v0.12.0 returned success after printing UnknownCommand. Require the
  # structured success envelope, so a located but incapable binary is fatal
  # and can never turn an empty database's 404s into a misleading replay run.
  grep -q '"zigbase_schema_apply":1' <<<"$apply_output" \
    || fail "located ZigBase did not apply the schema (missing structured success envelope)"
}

# Two entirely fresh databases prove the runner did not pass through records or
# auth state leaked by an earlier invocation.
for attempt in 1 2; do
  DATA="$WORK/data-$attempt"
  prepare_data "$DATA"
  echo "running Bun parity replay (fresh data attempt $attempt)..."
  run_bun "$DATA" || fail "Bun parity replay failed on attempt $attempt"
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 is unavailable; browser journey not run"
elif ! python3 -c 'import playwright.sync_api' >/dev/null 2>&1; then
  echo "SKIP: Python Playwright is unavailable; browser journey not run"
elif ! command -v google-chrome >/dev/null 2>&1 && \
     ! command -v google-chrome-stable >/dev/null 2>&1; then
  echo "SKIP: system Chrome is unavailable; browser journey not run"
else
  DATA="$WORK/data-browser"
  prepare_data "$DATA"
  echo "running Playwright parity journey against stock ZigBase..."
  run_browser "$DATA" || fail "Playwright parity journey failed"
fi

echo "PASS: real-stock-ZigBase Rails presentation parity"
