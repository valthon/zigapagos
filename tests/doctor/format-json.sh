#!/usr/bin/env bash
# Regression test for issue #131 item 1 (doctor half): `zigapagos doctor
# --format=json` emits one NDJSON finding per line on STDOUT (doctor's report
# stream -- build diagnostics live on stderr, doctor's report always lived on
# stdout) with {"check","severity","file","message"}, then exactly one
# summary object {"errors","warnings","files","skipped"}.
#
# DISCRIMINATOR: unpatched, `doctor --format=json` exits 1 with
# "error: unknown flag '--format=json'" -- asserted ABSENT below.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

command -v bun >/dev/null 2>&1 || { echo "FAIL: bun not found on PATH -- required to parse NDJSON output"; exit 1; }

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

cat > "$WORK/check.mjs" <<'MJS'
// Asserts: every line parses; exactly one finding per requested check id;
// the LAST line is the summary object with the requested counts.
const [path, errors, warnings, ...checks] = process.argv.slice(2);
const text = await Bun.file(path).text();
const lines = text.split("\n").filter((l) => l.length > 0);
function die(msg) {
  console.error(`check.mjs FAIL: ${msg}`);
  console.error(`--- ${path} ---`);
  console.error(text);
  process.exit(1);
}
const objs = lines.map((line) => {
  try { return JSON.parse(line); } catch (e) {
    die(`line did not parse as JSON: ${JSON.stringify(line)} (${e.message})`);
  }
});
const summary = objs[objs.length - 1];
if (!("errors" in summary)) die("last line is not the summary object");
if (String(summary.errors) !== errors) die(`summary.errors=${summary.errors}, want ${errors}`);
if (String(summary.warnings) !== warnings) die(`summary.warnings=${summary.warnings}, want ${warnings}`);
const findings = objs.slice(0, -1);
for (const f of findings) {
  if (!f.check || !f.severity || !f.file || !f.message) die(`finding missing a field: ${JSON.stringify(f)}`);
}
for (const c of checks) {
  const n = findings.filter((f) => f.check === c).length;
  if (n !== 1) die(`expected exactly 1 finding with check=${c}, found ${n}`);
}
if (findings.length !== checks.length) die(`expected ${checks.length} findings total, got ${findings.length}`);
console.log("ok");
MJS

# A built tree with exactly one finding of each severity: a root-relative
# og:url (abs-url-meta, error) and a dangling internal href
# (dangling-internal-link, warning).
TREE="$WORK/public"
mkdir -p "$TREE"
cat > "$TREE/index.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta property="og:url" content="/relative-og">
</head>
<body>
  <a href="/missing-page">nope</a>
</body>
</html>
EOF

echo "=== Phase 0: text mode still works (baseline) ==="
set +e
( cd "$WORK" && "$ZIGAPAGOS" doctor public ) >"$WORK/p0.out" 2>"$WORK/p0.err"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || fail "text-mode doctor of the broken tree exited 0"
grep -q '^error abs-url-meta: index.html:' "$WORK/p0.out" || { cat "$WORK/p0.out"; fail "text finding missing"; }
grep -q 'doctor: 1 error, 1 warning' "$WORK/p0.out" || { cat "$WORK/p0.out"; fail "text summary missing"; }
echo "ok"

echo "=== Phase 1: json mode: findings + summary, all parseable, no prose ==="
set +e
( cd "$WORK" && "$ZIGAPAGOS" doctor public --format=json ) >"$WORK/p1.out" 2>"$WORK/p1.err"
RC=$?
set -e
! grep -q "unknown flag '--format=json'" "$WORK/p1.err" \
  || { cat "$WORK/p1.err"; fail "doctor does not accept --format= (unpatched behavior)"; }
[[ "$RC" -ne 0 ]] || fail "json-mode doctor of the broken tree exited 0"
bun run "$WORK/check.mjs" "$WORK/p1.out" 1 1 abs-url-meta dangling-internal-link \
  || fail "json findings/summary assertions failed"
! grep -q '^error abs-url-meta:' "$WORK/p1.out" \
  || { cat "$WORK/p1.out"; fail "json-mode stdout contains a prose finding -- the text printer ran too"; }
! grep -q '^doctor: ' "$WORK/p1.out" \
  || { cat "$WORK/p1.out"; fail "json-mode stdout contains the prose summary -- it must be json"; }
echo "ok"

echo "=== Phase 2: clean tree in json mode: summary only, exit 0 ==="
CLEAN="$WORK/clean"
mkdir -p "$CLEAN/public"
printf '<!DOCTYPE html><html><head><title>x</title></head><body>ok</body></html>\n' > "$CLEAN/public/index.html"
set +e
( cd "$CLEAN" && "$ZIGAPAGOS" doctor public --format=json ) >"$WORK/p2.out" 2>"$WORK/p2.err"
RC=$?
set -e
[[ "$RC" -eq 0 ]] || { cat "$WORK/p2.err"; fail "clean json-mode doctor exited $RC, want 0"; }
bun run "$WORK/check.mjs" "$WORK/p2.out" 0 0 || fail "clean-tree summary assertions failed"
echo "ok"

echo "=== Phase 3: a fatal in json mode is one ZP_FATAL NDJSON line on stderr ==="
set +e
( cd "$WORK" && "$ZIGAPAGOS" doctor no-such-dir --format=json ) >"$WORK/p3.out" 2>"$WORK/p3.err"
RC=$?
set -e
[[ "$RC" -eq 1 ]] || { cat "$WORK/p3.err"; fail "doctor on a missing dir exited $RC, want 1"; }
grep -q '"code":"ZP_FATAL"' "$WORK/p3.err" \
  || { cat "$WORK/p3.err"; fail "missing-dir fatal did not emit ZP_FATAL NDJSON (diag.format not set before the fatal path)"; }
echo "ok"

echo "=== Phase 4: a mid-walk failure in json mode is ZP_FATAL NDJSON, not prose ==="
# An unreadable subdirectory makes walker.next fail after the walk has begun --
# the one failure path that used to print prose ("doctor: could not finish
# scanning ...") straight onto the NDJSON stderr stream. Needs a non-root user:
# root ignores mode 000 and the walk would succeed, silently voiding the phase.
[[ "$EUID" -ne 0 ]] || fail "this phase needs a non-root user (root can read a mode-000 dir, so the walk failure never happens)"
DENY="$WORK/deny"
mkdir -p "$DENY/public/locked"
printf '<!DOCTYPE html><html><head><title>x</title></head><body>ok</body></html>\n' > "$DENY/public/index.html"
chmod 000 "$DENY/public/locked"
set +e
( cd "$DENY" && "$ZIGAPAGOS" doctor public --format=json ) >"$WORK/p4.out" 2>"$WORK/p4.err"
RC=$?
set -e
chmod 755 "$DENY/public/locked"   # so the EXIT trap's rm -rf can clean up
[[ "$RC" -ne 0 ]] || { cat "$WORK/p4.err"; fail "doctor on a tree with an unreadable subdir exited 0"; }
grep -q '"code":"ZP_FATAL"' "$WORK/p4.err" \
  || { cat "$WORK/p4.err"; fail "walk failure did not emit ZP_FATAL NDJSON on stderr"; }
grep -q 'could not finish scanning' "$WORK/p4.err" \
  || { cat "$WORK/p4.err"; fail "walk-failure diagnostic lost its message"; }
! grep -q '^doctor: could not finish scanning' "$WORK/p4.err" \
  || { cat "$WORK/p4.err"; fail "walk failure printed PROSE onto the json stderr stream"; }
echo "ok"

echo "PASS: tests/doctor/format-json.sh"
