#!/usr/bin/env bash
# Regression test for issue #131 item 1 (explain-code half):
# `zigapagos explain-code --format=json` emits {"code","summary","explanation"}
# NDJSON on STDERR (same stream as its text output; moving CLI output to
# stdout is a CLI-wide follow-up, not a change to this one command).
#
# DISCRIMINATOR: unpatched, --format=json isn't parsed as a flag, so it fills
# the single positional CODE slot. Two-arg form (Phase 0): `explain-code
# --format=json ZP_FATAL` exits 1 with "unexpected extra argument 'ZP_FATAL'".
# One-arg form (Phase 1): `explain-code --format=json` exits 1 with "unknown
# diagnostic code '--format=json'". Each phase asserts the ABSENCE of its own
# form's message; the RC/JSON assertions carry the rest.
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
// mode "one": exactly one line, fields code/summary/explanation, code matches.
// mode "list": every line parses, every object has all three non-empty
// fields, and the requested codes each appear exactly once.
const [mode, path, ...codes] = process.argv.slice(2);
const text = await Bun.file(path).text();
const lines = text.split("\n").filter((l) => l.length > 0);
function die(msg) {
  console.error(`check.mjs FAIL (${mode}): ${msg}`);
  console.error(`--- ${path} ---`);
  console.error(text);
  process.exit(1);
}
const objs = lines.map((line) => {
  try { return JSON.parse(line); } catch (e) {
    die(`line did not parse as JSON: ${JSON.stringify(line)} (${e.message})`);
  }
});
for (const o of objs) {
  if (!o.code || !o.summary || !o.explanation) die(`entry missing a field: ${JSON.stringify(o)}`);
}
if (mode === "one") {
  if (objs.length !== 1) die(`expected exactly 1 line, got ${objs.length}`);
  if (objs[0].code !== codes[0]) die(`code: got ${objs[0].code}, want ${codes[0]}`);
} else if (mode === "list") {
  for (const c of codes) {
    const n = objs.filter((o) => o.code === c).length;
    if (n !== 1) die(`expected exactly 1 entry for ${c}, found ${n}`);
  }
  if (objs.length < 20) die(`expected the full registry (>=20 codes), got ${objs.length}`);
} else die(`unknown mode ${mode}`);
console.log("ok");
MJS

echo "=== Phase 0: one code ==="
set +e
"$ZIGAPAGOS" explain-code --format=json ZP_FATAL >"$WORK/p0.out" 2>"$WORK/p0.err"
RC=$?
set -e
! grep -q "unexpected extra argument 'ZP_FATAL'" "$WORK/p0.err" \
  || { cat "$WORK/p0.err"; fail "explain-code does not accept --format= (unpatched behavior: the flag fills the CODE slot and ZP_FATAL overflows)"; }
[[ "$RC" -eq 0 ]] || { cat "$WORK/p0.err"; fail "explain-code --format=json ZP_FATAL exited $RC, want 0"; }
bun run "$WORK/check.mjs" one "$WORK/p0.err" ZP_FATAL || fail "single-code JSON assertions failed"
echo "ok"

echo "=== Phase 1: full listing ==="
set +e
"$ZIGAPAGOS" explain-code --format=json >"$WORK/p1.out" 2>"$WORK/p1.err"
RC=$?
set -e
# Unpatched, the bare flag fills the single positional CODE slot and fails
# with this exact message -- the one-arg form's own discriminator.
! grep -q "unknown diagnostic code '--format=json'" "$WORK/p1.err" \
  || { cat "$WORK/p1.err"; fail "explain-code does not accept --format= (unpatched behavior: the flag was read as a CODE)"; }
[[ "$RC" -eq 0 ]] || { cat "$WORK/p1.err"; fail "explain-code --format=json (list) exited $RC, want 0"; }
bun run "$WORK/check.mjs" list "$WORK/p1.err" ZP_FATAL ZP_SUPERMD ZP_URL_COLLISION \
  || fail "listing JSON assertions failed"
echo "ok"

echo "=== Phase 1b: a repeated --format flag honors the LAST value, banner-free ==="
# The command parsers keep the LAST --format= value, so the pre-scan in
# main.zig must agree -- if it stopped at the FIRST flag it would resolve
# 'text' here, print the Debug banner onto stderr, and then the parser would
# switch to json: a corrupted NDJSON stream. The single-line assertion is the
# discriminator (the binary under test is a Debug build, so the banner WOULD
# appear as extra stderr lines).
set +e
"$ZIGAPAGOS" explain-code --format=text --format=json ZP_FATAL >"$WORK/p1b.out" 2>"$WORK/p1b.err"
RC=$?
set -e
[[ "$RC" -eq 0 ]] || { cat "$WORK/p1b.err"; fail "repeated --format flags exited $RC, want 0"; }
bun run "$WORK/check.mjs" one "$WORK/p1b.err" ZP_FATAL \
  || fail "repeated --format flags: stderr was not exactly one NDJSON entry (pre-scan disagreed with the parser and leaked the banner)"
echo "ok"

echo "=== Phase 2: unknown code in json mode is a ZP_FATAL NDJSON usage error ==="
set +e
"$ZIGAPAGOS" explain-code --format=json ZP_NOT_A_REAL_CODE >"$WORK/p2.out" 2>"$WORK/p2.err"
RC=$?
set -e
[[ "$RC" -eq 1 ]] || { cat "$WORK/p2.err"; fail "unknown code exited $RC, want 1"; }
grep -q '"code":"ZP_FATAL"' "$WORK/p2.err" \
  || { cat "$WORK/p2.err"; fail "unknown-code usage error did not emit ZP_FATAL NDJSON"; }
echo "ok"

echo "=== Phase 3: text mode unchanged ==="
set +e
"$ZIGAPAGOS" explain-code ZP_FATAL >"$WORK/p3.out" 2>"$WORK/p3.err"
RC=$?
set -e
[[ "$RC" -eq 0 ]] || fail "text-mode explain-code exited $RC"
grep -q '^ZP_FATAL$' "$WORK/p3.err" || { cat "$WORK/p3.err"; fail "text-mode output shape changed"; }
echo "ok"

echo "PASS: tests/diagnostics/explain-code-json.sh"
