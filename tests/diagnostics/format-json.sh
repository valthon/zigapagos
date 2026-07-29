#!/usr/bin/env bash
# Regression test for issue #46 / DX-27: machine-readable diagnostics.
#
# `zigapagos release --format=json` must emit exactly one NDJSON object per
# diagnostic on stderr, with a stable `code`, and text mode (the default)
# must be BYTE-FOR-BYTE unchanged by this feature (src/root.zig's conversion
# wraps every existing std.debug.print block rather than routing it through a
# new seam -- see the plan's section 5 for why).
#
# NEEDS bun ON PATH: used to parse and assert on the NDJSON lines below. Fail
# loudly if it's missing rather than silently skipping -- a skipped assertion
# here is worse than no test (see tests/meta/script-coverage.sh's own
# rationale for the same principle).
#
# The binary under test is a DEBUG build (`zig build`'s default). That
# matters for Phase 2: `fatal.msg` PANICS in a Debug build in TEXT mode
# (src/fatal.zig, `if (builtin.mode == .Debug) std.debug.panic(...)`), so
# `zigapagos release` on a real-world config error exits 134 (SIGABRT) in text
# mode today. JSON mode is the fix -- it exits a clean 1 instead -- and that
# difference IS what Phase 2 pins. If this test is ever run against a
# ReleaseFast binary, the text-mode exit code in Phase 2 will differ (no
# panic there either); the JSON-mode assertions are exit-code-independent of
# build mode and remain the meaningful half.
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
// Small NDJSON-assertion helper driven by argv. `bun run` avoids fighting
// `bun -e` quoting for a script this size.
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
    try {
      obj = JSON.parse(line);
    } catch (e) {
      die(`line did not parse as JSON: ${JSON.stringify(line)} (${e.message})`);
    }
    if (obj.code === code) matches.push(obj);
  }
  if (matches.length !== 1) die(`expected exactly 1 object with code ${code}, found ${matches.length}`);
  console.log(JSON.stringify(matches[0]));
  process.exit(0);
}

if (mode === "single-line-code") {
  const [code] = rest;
  if (lines.length !== 1) die(`expected exactly 1 line, got ${lines.length}`);
  const obj = JSON.parse(lines[0]);
  if (obj.code !== code) die(`expected code ${code}, got ${obj.code}`);
  console.log(JSON.stringify(obj));
  process.exit(0);
}

die(`unknown mode ${mode}`);
MJS

SITE0="$WORK/site0"
mkdir -p "$SITE0/content" "$SITE0/layouts"
cat > "$SITE0/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Diagnostics format test",
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

echo "=== Phase 0: --format=json is inert on a clean build ==="
# `set +e` around every capture whose exit code is then asserted: with errexit
# on, a non-zero exit aborts the script BEFORE the assertion below, so the
# `fail` message that says what went wrong would never print.
set +e
( cd "$SITE0" && "$ZIGAPAGOS" release --format=json --force -o out ) >"$WORK/p0.out" 2>"$WORK/p0.err"
RC=$?
set -e
[[ "$RC" -eq 0 ]] || { cat "$WORK/p0.err"; fail "clean build with --format=json exited $RC, want 0"; }
bun run "$WORK/check.mjs" empty "$WORK/p0.err" \
  || fail "stderr was not empty on a clean --format=json build -- the Debug banner and/or std.Progress were not suppressed"
echo "ok: exit 0, stderr fully empty"

SITE1="$WORK/site1"
mkdir -p "$SITE1/content" "$SITE1/layouts"
cp "$SITE0/zigapagos.ziggy" "$SITE1/zigapagos.ziggy"
cp "$SITE0/layouts/index.shtml" "$SITE1/layouts/index.shtml"
cp "$SITE0/content/index.smd" "$SITE1/content/index.smd"
# other.smd is NOT a section (it's a leaf page): $link.sub() asks for one of
# ITS subpages, and it has none. This is the issue #28 shape the sidebar
# heading names ("this page has no subpages (page is not a section)"); a
# leading '.' in SuperMD link syntax desugars to the same $link.sub call.
cat > "$SITE1/content/other.smd" <<'EOF'
---
.title = "Other",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---

# Sub on a non-section page (issue #28)
[]($link.sub('index')) //wrong -- other.smd is not a section
EOF

echo "=== Phase 1a: text mode is byte-for-byte unchanged ==="
set +e
( cd "$SITE1" && "$ZIGAPAGOS" release --force -o out ) >"$WORK/p1a.out" 2>"$WORK/p1a.err"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { cat "$WORK/p1a.out"; fail "text-mode build of the not_a_section fixture succeeded -- fixture stopped triggering the error"; }
grep -q 'this page has no subpages (page is not a section)' "$WORK/p1a.err" \
  || { cat "$WORK/p1a.err"; fail "text-mode stderr missing the not_a_section headline"; }
grep -q 'a leading '"'"'.'"'"' means "subpage of this section", not a relative path' "$WORK/p1a.err" \
  || { cat "$WORK/p1a.err"; fail "text-mode stderr missing the issue #28 note"; }
grep -q '^|    \^' "$WORK/p1a.err" \
  || { cat "$WORK/p1a.err"; fail "text-mode stderr missing the '|    ^' caret framing"; }
echo "ok: text mode carries the headline, the #28 note, and caret framing"

# Extract line:col from the text-mode headline for the cross-format agreement
# check in 1d, below.
# `|| true`: under `set -o pipefail` a non-matching grep fails the pipeline and
# would abort here, skipping the explicit "could not extract line:col" failure
# below -- which is the message that actually says what broke.
TEXT_LOC="$(grep -oE 'content/other\.smd:[0-9]+:[0-9]+' "$WORK/p1a.err" | head -1 || true)"
TEXT_LINE="$(echo "$TEXT_LOC" | cut -d: -f2)"
TEXT_COL="$(echo "$TEXT_LOC" | cut -d: -f3)"
[[ -n "$TEXT_LINE" && -n "$TEXT_COL" ]] || fail "could not extract line:col from text-mode stderr"

echo "=== Phase 1b/1c: json mode carries the diagnostic, and ONLY the diagnostic ==="
set +e
( cd "$SITE1" && "$ZIGAPAGOS" release --format=json --force -o out2 ) >"$WORK/p1b.out" 2>"$WORK/p1b.err"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { cat "$WORK/p1b.out"; fail "json-mode build of the not_a_section fixture succeeded -- fixture stopped triggering the error"; }

OBJ="$(bun run "$WORK/check.mjs" all-parse-and-one-matches "$WORK/p1b.err" ZP_LINK_NOT_A_SECTION)" \
  || fail "json-mode stderr did not have exactly one parseable ZP_LINK_NOT_A_SECTION object"
echo "$OBJ"

# 1c: the text printer must have been suppressed, not merely supplemented.
# Without this assertion, an implementation that emits JSON *in addition to*
# prose would still pass 1b -- this is what makes 1b non-vacuous.
! grep -q '^|    ' "$WORK/p1b.err" \
  || { cat "$WORK/p1b.err"; fail "json-mode stderr contains a '|    ' caret-framing line -- the text printer ran too"; }
! grep -q ': error: this page has no subpages' "$WORK/p1b.err" \
  || { cat "$WORK/p1b.err"; fail "json-mode stderr contains the text-mode headline -- the text printer ran too"; }
echo "ok: exactly one ZP_LINK_NOT_A_SECTION object, no text-mode prose alongside it"

echo "=== field assertions on the parsed object ==="
JSON_FILE="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).file))" "$OBJ")"
JSON_LINE="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).line))" "$OBJ")"
JSON_COL="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).col))" "$OBJ")"
JSON_MESSAGE="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).message))" "$OBJ")"
JSON_HELP="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).help))" "$OBJ")"
JSON_SEVERITY="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).severity))" "$OBJ")"

[[ "$JSON_SEVERITY" == "error" ]] || fail "severity: got '$JSON_SEVERITY', want 'error'"
[[ "$JSON_FILE" == *"content/other.smd" ]] || fail "file: got '$JSON_FILE', want it to end in content/other.smd"
[[ "$JSON_LINE" =~ ^[0-9]+$ && "$JSON_LINE" -gt 0 ]] || fail "line: got '$JSON_LINE', want a positive integer"
[[ "$JSON_COL" =~ ^[0-9]+$ && "$JSON_COL" -gt 0 ]] || fail "col: got '$JSON_COL', want a positive integer"
[[ "$JSON_MESSAGE" == "this page has no subpages (page is not a section)" ]] || fail "message: got '$JSON_MESSAGE'"
[[ "$JSON_HELP" == *"subpage of this section"* ]] || fail "help: got '$JSON_HELP', want it to mention 'subpage of this section'"
echo "ok: severity/file/line/col/message/help all match"

echo "=== Phase 1d: text and json modes agree on line:col ==="
[[ "$JSON_LINE" == "$TEXT_LINE" ]] || fail "line mismatch: text=$TEXT_LINE json=$JSON_LINE"
[[ "$JSON_COL" == "$TEXT_COL" ]] || fail "col mismatch: text=$TEXT_COL json=$JSON_COL"
echo "ok: text ($TEXT_LINE:$TEXT_COL) and json ($JSON_LINE:$JSON_COL) agree"

SITE2="$WORK/site2"
mkdir -p "$SITE2/content" "$SITE2/layouts"
cat > "$SITE2/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Diagnostics fatal test",
    .host_url = "https://example.com/blog",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF

echo "=== Phase 2: ZP_FATAL exits cleanly in json mode (no Debug-build panic) ==="
set +e
( cd "$SITE2" && "$ZIGAPAGOS" release --force -o out ) >"$WORK/p2text.out" 2>"$WORK/p2text.err"
RC_TEXT=$?
set -e
[[ "$RC_TEXT" -ne 0 ]] || { cat "$WORK/p2text.err"; fail "text-mode host_url-with-a-path build succeeded"; }
grep -q 'must not contain a path' "$WORK/p2text.err" || { cat "$WORK/p2text.err"; fail "text-mode stderr missing 'must not contain a path'"; }

set +e
( cd "$SITE2" && "$ZIGAPAGOS" release --force -o out2 --format=json ) >"$WORK/p2json.out" 2>"$WORK/p2json.err"
RC_JSON=$?
set -e
# Exactly 1, not merely non-zero: pins the no-debug-panic decision. Without
# it this path exits 134 (SIGABRT) under a Debug build, same as text mode.
[[ "$RC_JSON" -eq 1 ]] || { cat "$WORK/p2json.err"; fail "json-mode exit was $RC_JSON, want exactly 1 (134 would mean the debug panic still fires)"; }

OBJ2="$(bun run "$WORK/check.mjs" single-line-code "$WORK/p2json.err" ZP_FATAL)" \
  || fail "json-mode stderr for the config fatal was not exactly one ZP_FATAL line"
JSON2_MESSAGE="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).message))" "$OBJ2")"
JSON2_SEVERITY="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).severity))" "$OBJ2")"
[[ "$JSON2_SEVERITY" == "error" ]] || fail "ZP_FATAL severity: got '$JSON2_SEVERITY'"
[[ "$JSON2_MESSAGE" == *"must not contain a path"* ]] || fail "ZP_FATAL message: got '$JSON2_MESSAGE'"
echo "ok: exit 1 exactly, one ZP_FATAL line, message carries the config error"

echo "=== Phase 3: an invalid --format value is a clean usage error, not a panic ==="
set +e
( cd "$SITE0" && "$ZIGAPAGOS" release --force -o out3 --format=xml ) >"$WORK/p3.out" 2>"$WORK/p3.err"
RC3=$?
set -e
[[ "$RC3" -eq 1 ]] || { cat "$WORK/p3.err"; fail "bad --format value exited $RC3, want exactly 1"; }
grep -q 'want text|json' "$WORK/p3.err" || { cat "$WORK/p3.err"; fail "bad --format error message missing 'want text|json'"; }
echo "ok: --format=xml is a clean exit-1 usage error"

echo "=== Phase 4: the --format pre-scan is gated to 'release' ==="
# `--format` is documented as a `release` flag. main.zig pre-scans argv for it
# before std.Progress and the banners, and that pre-scan is gated to
# `args[1] == "release"` -- without the gate it reads argv belonging to some
# OTHER command's parser, and e.g. `zigapagos explain-code --format=json`
# answers a flag `explain-code` does not have with an NDJSON ZP_FATAL line.
# `explain-code` is the cheapest witness: it needs no site on disk, and its
# unknown-code path is a `fatal.usageError`, exactly the call this would
# reroute.
set +e
"$ZIGAPAGOS" explain-code --format=json >"$WORK/p4.out" 2>"$WORK/p4.err"
RC4=$?
set -e
[[ "$RC4" -eq 1 ]] || { cat "$WORK/p4.err"; fail "explain-code --format=json exited $RC4, want 1"; }
grep -q "unknown diagnostic code '--format=json'" "$WORK/p4.err" \
  || { cat "$WORK/p4.err"; fail "explain-code --format=json did not report the unknown code in text form"; }
! grep -q '"code":"ZP_FATAL"' "$WORK/p4.err" \
  || { cat "$WORK/p4.err"; fail "explain-code --format=json emitted NDJSON -- the pre-scan is not gated to 'release'"; }
echo "ok: a non-release command cannot flip the diagnostic stream to NDJSON"

echo "=== Phase 5: ZP_FRONTMATTER_FRAMING agrees with text mode on line:col ==="
# Phase 1d proves cross-mode location agreement for a diagnostic whose column
# comes from real source data. This phase pins the other shape: a call site
# whose text printer hard-codes the column as a literal ':1'. The JSON branch
# has to say `.col = 1` to match; leaving `col` unset emits `"col":null` and
# the two modes then disagree about where the error is, which is exactly the
# ambiguity a machine-readable stream exists to remove.
SITE4="$WORK/site4"
mkdir -p "$SITE4/content" "$SITE4/layouts"
cp "$SITE0/zigapagos.ziggy" "$SITE4/zigapagos.ziggy"
cp "$SITE0/layouts/index.shtml" "$SITE4/layouts/index.shtml"
cp "$SITE0/content/index.smd" "$SITE4/content/index.smd"
# No leading '---': error.MissingFrontmatter, the ZP_FRONTMATTER_FRAMING path.
printf 'this document has no frontmatter frame\n' > "$SITE4/content/bad.smd"

set +e
( cd "$SITE4" && "$ZIGAPAGOS" release --force -o out ) >"$WORK/p5text.out" 2>"$WORK/p5text.err"
RC5T=$?
set -e
[[ "$RC5T" -ne 0 ]] || { cat "$WORK/p5text.err"; fail "text-mode build of the missing-frontmatter fixture succeeded -- fixture stopped triggering the error"; }
FM_TEXT_LOC="$(grep -oE 'content/bad\.smd:[0-9]+:[0-9]+' "$WORK/p5text.err" | head -1 || true)"
FM_TEXT_LINE="$(echo "$FM_TEXT_LOC" | cut -d: -f2)"
FM_TEXT_COL="$(echo "$FM_TEXT_LOC" | cut -d: -f3)"
[[ -n "$FM_TEXT_LINE" && -n "$FM_TEXT_COL" ]] || { cat "$WORK/p5text.err"; fail "could not extract line:col from the text-mode frontmatter framing error"; }

set +e
( cd "$SITE4" && "$ZIGAPAGOS" release --force -o out2 --format=json ) >"$WORK/p5json.out" 2>"$WORK/p5json.err"
RC5J=$?
set -e
[[ "$RC5J" -ne 0 ]] || { cat "$WORK/p5json.out"; fail "json-mode build of the missing-frontmatter fixture succeeded"; }
OBJ5="$(bun run "$WORK/check.mjs" all-parse-and-one-matches "$WORK/p5json.err" ZP_FRONTMATTER_FRAMING)" \
  || fail "json-mode stderr did not have exactly one parseable ZP_FRONTMATTER_FRAMING object"
FM_JSON_LINE="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).line))" "$OBJ5")"
FM_JSON_COL="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).col))" "$OBJ5")"
# Spelled out rather than folded into the equality check below, because
# "null" != "1" would otherwise read as a plain mismatch instead of naming
# the actual defect: the field was never set.
[[ "$FM_JSON_COL" != "null" ]] || { echo "$OBJ5"; fail "ZP_FRONTMATTER_FRAMING emitted col:null -- text mode prints a literal ':1', so the JSON branch must set .col = 1"; }
[[ "$FM_JSON_LINE" == "$FM_TEXT_LINE" ]] || fail "frontmatter line mismatch: text=$FM_TEXT_LINE json=$FM_JSON_LINE"
[[ "$FM_JSON_COL" == "$FM_TEXT_COL" ]] || fail "frontmatter col mismatch: text=$FM_TEXT_COL json=$FM_JSON_COL"
echo "ok: text ($FM_TEXT_LINE:$FM_TEXT_COL) and json ($FM_JSON_LINE:$FM_JSON_COL) agree"

echo "=== Phase 6: the inert-directive template lint emits one code per kind ==="
# `lintInertDirectives` (src/Template.zig) is the newest producer of
# `template_errors`, and `template_errors` feeds `build.any_prerendering_error`
# -- the exact set docs/diagnostics.md promises is fully converted. Its two
# kinds get two codes, not one, so a consumer can tell ':else' (never
# evaluated) from ':if'/':loop' on an element with no end tag (re-emits the
# whole template source) by switching on `code` alone.
SITE5="$WORK/site5"
mkdir -p "$SITE5/content" "$SITE5/layouts"
cp "$SITE0/zigapagos.ziggy" "$SITE5/zigapagos.ziggy"
cp "$SITE0/content/index.smd" "$SITE5/content/index.smd"
# Exactly one of each kind, so "exactly 1 object with this code" is a real
# assertion rather than a coincidence of a fixture that trips one lint twice.
cat > "$SITE5/layouts/index.shtml" <<'EOF'
<!DOCTYPE html>
<html>
<head><title :text="$page.title"></title></head>
<body>
  <ctx :if="$page.title">A</ctx>
  <ctx :else>B</ctx>
  <img src="/a.png" :if="$page.draft">
</body>
</html>
EOF

set +e
( cd "$SITE5" && "$ZIGAPAGOS" release --force -o out ) >"$WORK/p6text.out" 2>"$WORK/p6text.err"
RC6T=$?
set -e
[[ "$RC6T" -ne 0 ]] || { cat "$WORK/p6text.err"; fail "text-mode build of the inert-directive fixture succeeded -- fixture stopped triggering the lint"; }
grep -q "':else' is parsed but never evaluated" "$WORK/p6text.err" \
  || { cat "$WORK/p6text.err"; fail "text-mode stderr missing the ':else' headline"; }
grep -q "':if' on <img> can never work" "$WORK/p6text.err" \
  || { cat "$WORK/p6text.err"; fail "text-mode stderr missing the void-element branching headline"; }

set +e
( cd "$SITE5" && "$ZIGAPAGOS" release --force -o out2 --format=json ) >"$WORK/p6json.out" 2>"$WORK/p6json.err"
RC6J=$?
set -e
[[ "$RC6J" -ne 0 ]] || { cat "$WORK/p6json.out"; fail "json-mode build of the inert-directive fixture succeeded"; }

OBJ6E="$(bun run "$WORK/check.mjs" all-parse-and-one-matches "$WORK/p6json.err" ZP_TEMPLATE_ELSE_DIRECTIVE)" \
  || fail "json-mode stderr did not have exactly one parseable ZP_TEMPLATE_ELSE_DIRECTIVE object"
OBJ6B="$(bun run "$WORK/check.mjs" all-parse-and-one-matches "$WORK/p6json.err" ZP_TEMPLATE_BRANCHING_WITHOUT_END_TAG)" \
  || fail "json-mode stderr did not have exactly one parseable ZP_TEMPLATE_BRANCHING_WITHOUT_END_TAG object"
echo "$OBJ6E"
echo "$OBJ6B"

# The text printer must be suppressed, not supplemented -- same
# non-vacuousness guard as Phase 1c. This lint accumulates every message into
# one `aw` block and prints it once, so a missed `diag.format == .text` gate
# would leak the WHOLE block alongside the NDJSON.
# Matched on the `: error: ` prefix, not on the headline text alone: the
# headline text is ALSO the JSON `message`, so a bare substring grep matches
# the diagnostic it is supposed to tolerate and fails vacuously.
! grep -q ": error: ':else' is parsed but never evaluated" "$WORK/p6json.err" \
  || { cat "$WORK/p6json.err"; fail "json-mode stderr contains the ':else' text headline -- the text printer ran too"; }
! grep -q ": error: ':if' on <img> can never work" "$WORK/p6json.err" \
  || { cat "$WORK/p6json.err"; fail "json-mode stderr contains the branching text headline -- the text printer ran too"; }
# The continuation lines are unique to the text block (no JSON field carries
# them), so they pin the rest of the suppressed prose directly.
! grep -q 'SuperHTML validates' "$WORK/p6json.err" \
  || { cat "$WORK/p6json.err"; fail "json-mode stderr contains the ':else' explanation block -- the text printer ran too"; }

# Both objects must locate themselves; a lint whose whole value is "line N of
# this layout" emitting line:null would be useless to the consumer this
# stream exists for.
for OBJ6 in "$OBJ6E" "$OBJ6B"; do
  L6="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).line))" "$OBJ6")"
  C6="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).col))" "$OBJ6")"
  F6="$(bun -e "process.stdout.write(String(JSON.parse(process.argv[1]).file))" "$OBJ6")"
  [[ "$L6" != "null" && "$C6" != "null" ]] || { echo "$OBJ6"; fail "inert-directive diagnostic emitted a null line/col"; }
  [[ "$F6" == "layouts/index.shtml" ]] || { echo "$OBJ6"; fail "inert-directive diagnostic named file '$F6', want 'layouts/index.shtml'"; }
done
echo "ok: one ZP_TEMPLATE_ELSE_DIRECTIVE + one ZP_TEMPLATE_BRANCHING_WITHOUT_END_TAG, located, no prose alongside"

echo "PASS: tests/diagnostics/format-json.sh"
