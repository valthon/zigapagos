#!/usr/bin/env bash
# Regression test for issue #131 item 1: `zigapagos validate --format=json`.
#
# validate runs the same orchestrator as release in .memory mode, so its
# diagnostics already flow through src/diag.zig's emit machinery -- the fix is
# (a) validate's parser accepting --format= and (b) main.zig's pre-scan gate
# including 'validate' so the Debug banner / std.Progress don't interleave
# with the NDJSON stream on stderr.
#
# DISCRIMINATOR: on the unpatched binary, `validate --format=json` exits 1
# with "error: unexpected cli argument '--format=json'". Every phase asserts
# that string is ABSENT, so a pass here cannot be vacuous.
#
# NEEDS bun ON PATH (NDJSON parsing) -- fail loudly if missing.
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
const [mode, path, ...rest] = process.argv.slice(2);
const text = await Bun.file(path).text();
const lines = text.split("\n").filter((l) => l.length > 0);
function die(msg) {
  console.error(`check.mjs FAIL (${mode}): ${msg}`);
  console.error(`--- ${path} ---`);
  console.error(text);
  process.exit(1);
}
if (mode === "empty") {
  if (lines.length !== 0) die(`expected 0 lines, got ${lines.length}`);
  process.exit(0);
}
if (mode === "all-parse-and-one-matches") {
  const [code] = rest;
  let matches = [];
  for (const line of lines) {
    let obj;
    try { obj = JSON.parse(line); } catch (e) {
      die(`line did not parse as JSON: ${JSON.stringify(line)} (${e.message})`);
    }
    if (obj.code === code) matches.push(obj);
  }
  if (matches.length !== 1) die(`expected exactly 1 object with code ${code}, found ${matches.length}`);
  console.log(JSON.stringify(matches[0]));
  process.exit(0);
}
die(`unknown mode ${mode}`);
MJS

# Clean site fixture (same shape as tests/diagnostics/format-json.sh SITE0).
SITE0="$WORK/site0"
mkdir -p "$SITE0/content" "$SITE0/layouts"
cat > "$SITE0/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Validate format test",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF
cat > "$SITE0/layouts/index.shtml" <<'EOF'
<!DOCTYPE html>
<html>
  <head><meta charset="UTF-8"><title :text="$site.title"></title></head>
  <body>
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
  </body>
</html>
EOF
cat > "$SITE0/content/index.smd" <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---

Hello world.
EOF

echo "=== Phase 0: clean site, --format=json: exit 0, stderr fully empty ==="
set +e
( cd "$SITE0" && "$ZIGAPAGOS" validate --format=json ) >"$WORK/p0.out" 2>"$WORK/p0.err"
RC=$?
set -e
! grep -q "unexpected cli argument '--format=json'" "$WORK/p0.err" \
  || { cat "$WORK/p0.err"; fail "validate does not accept --format= (unpatched behavior)"; }
[[ "$RC" -eq 0 ]] || { cat "$WORK/p0.err"; fail "clean validate --format=json exited $RC, want 0"; }
bun run "$WORK/check.mjs" empty "$WORK/p0.err" \
  || fail "stderr was not empty on a clean validate --format=json run -- banner/progress not suppressed"
grep -q 'validate: OK' "$WORK/p0.out" || { cat "$WORK/p0.out"; fail "stdout missing the 'validate: OK' summary"; }
echo "ok"

# Broken site: a $link.sub on a non-section leaf page (ZP_LINK_NOT_A_SECTION).
SITE1="$WORK/site1"
mkdir -p "$SITE1/content" "$SITE1/layouts"
cp "$SITE0/zigapagos.ziggy" "$SITE1/zigapagos.ziggy"
cp "$SITE0/layouts/index.shtml" "$SITE1/layouts/index.shtml"
cp "$SITE0/content/index.smd" "$SITE1/content/index.smd"
cat > "$SITE1/content/other.smd" <<'EOF'
---
.title = "Other",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---

# Sub on a non-section page
[]($link.sub('index'))
EOF

echo "=== Phase 1: broken site, text mode: prose + FAILED line ==="
set +e
( cd "$SITE1" && "$ZIGAPAGOS" validate ) >"$WORK/p1.out" 2>"$WORK/p1.err"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || fail "text-mode validate of the broken fixture succeeded"
grep -q 'this page has no subpages (page is not a section)' "$WORK/p1.err" \
  || { cat "$WORK/p1.err"; fail "text-mode stderr missing the not_a_section headline"; }
grep -q 'validate: FAILED' "$WORK/p1.err" \
  || { cat "$WORK/p1.err"; fail "text-mode stderr missing the 'validate: FAILED' line"; }
echo "ok"

echo "=== Phase 2: broken site, json mode: one NDJSON object, no prose ==="
set +e
( cd "$SITE1" && "$ZIGAPAGOS" validate --format=json ) >"$WORK/p2.out" 2>"$WORK/p2.err"
RC=$?
set -e
! grep -q "unexpected cli argument '--format=json'" "$WORK/p2.err" \
  || { cat "$WORK/p2.err"; fail "validate does not accept --format= (unpatched behavior)"; }
[[ "$RC" -ne 0 ]] || fail "json-mode validate of the broken fixture succeeded"
OBJ="$(bun run "$WORK/check.mjs" all-parse-and-one-matches "$WORK/p2.err" ZP_LINK_NOT_A_SECTION)" \
  || fail "json-mode stderr did not have exactly one parseable ZP_LINK_NOT_A_SECTION object"
echo "$OBJ"
# The text printer must be suppressed, not supplemented; and the FAILED line
# is text-mode furniture, so it must be gated off the NDJSON stream too.
! grep -q '^|    ' "$WORK/p2.err" \
  || { cat "$WORK/p2.err"; fail "json-mode stderr contains caret framing -- the text printer ran too"; }
! grep -q 'validate: FAILED' "$WORK/p2.err" \
  || { cat "$WORK/p2.err"; fail "json-mode stderr contains the prose FAILED line -- it must be text-mode only"; }
echo "ok"

echo "=== Phase 3: invalid --format value is a clean usage error ==="
set +e
( cd "$SITE0" && "$ZIGAPAGOS" validate --format=xml ) >"$WORK/p3.out" 2>"$WORK/p3.err"
RC=$?
set -e
[[ "$RC" -eq 1 ]] || { cat "$WORK/p3.err"; fail "validate --format=xml exited $RC, want exactly 1"; }
grep -q 'want text|json' "$WORK/p3.err" || { cat "$WORK/p3.err"; fail "bad --format error missing 'want text|json'"; }
echo "ok"

echo "PASS: tests/validate/format-json.sh"
