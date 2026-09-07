#!/usr/bin/env bash
# Exercise the real Bun sidecar and worker fan-out, not a serializer stub.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
BIN="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
unset ZIGAPAGOS_RUNTIME_DIR
command -v bun >/dev/null 2>&1 || { echo 'FAIL: bun not found on PATH (required for the real island sidecar)'; exit 1; }
if [[ ! -d "$REPO/runtime/node_modules" ]]; then
  echo "runtime/node_modules missing; running 'bun install --frozen-lockfile'..."
  (cd "$REPO/runtime" && bun install --frozen-lockfile) \
    || { echo 'FAIL: bun install --frozen-lockfile failed in runtime/'; exit 1; }
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/content" "$WORK/layouts" "$WORK/components"
# Resolution for imports made by the FIXTURE islands. The sidecar resolves its
# own dependencies from $REPO/runtime, so with today's dependency-free fixtures
# this link is inert -- it is here so a fixture that does import preact (or
# @z/runtime) resolves instead of failing in a way that reads as a diagnostics
# regression. `rm -rf "$WORK"` removes the link, not the target.
ln -s "$REPO/runtime/node_modules" "$WORK/node_modules"
cat > "$WORK/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Island diagnostics",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "components",
}
EOF
cat > "$WORK/layouts/index.shtml" <<'EOF'
<!DOCTYPE html>
<html><head><title>Islands</title></head><body><div :html="$page.content()"></div></body></html>
EOF
cat > "$WORK/components/Good.island.tsx" <<'EOF'
export default function Good() { return 'island-ok'; }
EOF
cat > "$WORK/components/Broken.island.tsx" <<'EOF'
export default function Broken() {
  const err = new Error('island "boom"\nsecond line');
  err.stack = 'mapped-stack\n' + 'trace'.repeat(1500) + '\nEND-OF-STACK';
  throw err;
}
EOF
page() {
  local name="$1" body="$2"
  cat > "$WORK/content/$name.smd" <<'EOF'
---
.title = "Test",
.date = @date("2020-07-06T00:00:00"),
.layout = "index.shtml",
---
EOF
  printf '\n```=html\n%s\n```\n' "$body" >> "$WORK/content/$name.smd"
}
release() {
  (cd "$WORK" && "$BIN" release --force -o out \
    --bun="$(command -v bun)" "--island-sidecar=$REPO/runtime/sidecar/render.ts" \
    --island-src-dir=. "$@")
}
page index '<z-island src="components/Good.island.tsx" client:load></z-island>'
release --format=json >"$WORK/out.log" 2>"$WORK/err.log"
grep -q island-ok "$WORK/out/index.html"
for i in $(seq 1 8); do
  page "ssr-$i" '<z-island src="components/Broken.island.tsx" client:load></z-island>'
  page "props-$i" '<z-island src="components/Good.island.tsx" client:load scripty:props prop-title="$page.not_a_field"></z-island>'
  page "markup-$i" '<z-island client:load></z-island>'
done
for attempt in 1 2 3; do
  if release --format=json >"$WORK/out.log" 2>"$WORK/err.log"; then
    echo 'FAIL: broken islands built successfully'; exit 1
  fi
  bun -e '
    const records = (await Bun.file(process.argv[1]).text()).trim().split("\n").map(line => JSON.parse(line));
    for (const [kind, code] of [["ssr", "ZP_ISLAND_SSR"], ["props", "ZP_ISLAND_PROPS"], ["markup", "ZP_ISLAND_RENDER"]]) {
      const errors = records.filter(d => d.code === code);
      if (errors.length !== 8 || new Set(errors.map(d => d.file)).size !== 8) throw Error(`bad count for ${code}`);
      for (const d of errors) {
        if (!new RegExp(`^content/${kind}-[1-8]\\.smd$`).test(d.file)) throw Error("bad page attribution");
        if (d.severity !== "error" || d.line !== null || d.col !== null) throw Error("invented source span");
        if (Object.keys(d).join(",") !== "code,severity,file,line,col,message,help") throw Error("wire schema changed");
        if (kind === "ssr" && (!d.message.includes("components/Broken.island.tsx") || !d.message.includes("(route /ssr-") || !d.message.includes("island \"boom\"\nsecond line") || !d.message.includes("mapped-stack\n") || !d.message.endsWith("END-OF-STACK"))) throw Error("lost component, route, message or long stack");
        if (kind === "props" && (!d.message.includes("components/Good.island.tsx") || !d.message.includes("$page.not_a_field"))) throw Error("lost prop context");
        if (kind === "markup" && !d.message.includes("IslandMissingSrc")) throw Error("lost pass error");
      }
    }
  ' "$WORK/err.log"
done
if release >"$WORK/text.out" 2>"$WORK/text.err"; then
  echo 'FAIL: text mode accepted broken islands'; exit 1
fi
bun -e '
  const text = await Bun.file(process.argv[1]).text();
  const records = (await Bun.file(process.argv[2]).text()).trim().split("\n").map(line => JSON.parse(line));
  for (const d of records.filter(d => d.code.startsWith("ZP_ISLAND_"))) {
    if (!text.includes(d.message)) throw Error(`changed text for ${d.file}`);
  }
' "$WORK/text.err" "$WORK/err.log"
# No-sidecar diagnostics are page-level; validate deliberately suppresses them.
if (cd "$WORK" && "$BIN" release --format=json --force -o out) >"$WORK/no.out" 2>"$WORK/no.err"; then
  echo 'FAIL: missing sidecar accepted'; exit 1
fi
bun -e '
  const records = (await Bun.file(process.argv[1]).text()).trim().split("\n").map(line => JSON.parse(line));
  const errors = records.filter(d => d.code === "ZP_ISLAND_SIDECAR_MISSING");
  if (errors.length !== 25 || new Set(errors.map(d => d.file)).size !== 25) throw Error("missing sidecar count");
  if (!errors.every(d => d.message.includes("--island="))) throw Error("missing remedy");
' "$WORK/no.err"
# A render failure the sidecar never got to describe. Writing to stdout from a
# component corrupts the NDJSON channel, so `render` returns with `err_out`
# untouched: no JavaScript message, no stack. The record must still say what
# broke -- reporting the empty message verbatim produced a diagnostic whose
# whole payload was ": \n(no stack)", which is the one thing an unattended
# consumer cannot act on. Its own site, because the desync makes the sidecar
# unusable for anything after it.
DESYNC="$WORK/desync"
mkdir -p "$DESYNC/content" "$DESYNC/layouts" "$DESYNC/components"
cp "$WORK/zigapagos.ziggy" "$DESYNC/zigapagos.ziggy"
cp "$WORK/layouts/index.shtml" "$DESYNC/layouts/index.shtml"
ln -s "$REPO/runtime/node_modules" "$DESYNC/node_modules"
# Logging a JSON OBJECT, not a bare string. `console.log(JSON.stringify(x))` is
# the standard JS debugging move, so it is the likeliest way an author corrupts
# this channel -- and it is the case a classifier that asks "is the line JSON?"
# instead of "is the line a protocol frame?" gets exactly backwards, blaming a
# wrong-typed value in the author's module for what is channel corruption.
cat > "$DESYNC/components/Noisy.island.tsx" <<'EOF'
export default function Noisy() {
  console.log(JSON.stringify({ debugging: 'a valid JSON object, but not a protocol frame' }));
  return 'never reached as a clean frame';
}
EOF
cp "$WORK/content/index.smd" "$DESYNC/content/index.smd"
python3 - "$DESYNC/content/index.smd" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
assert "Good.island.tsx" in src, "fixture page changed; update this test's substitution"
open(p, "w").write(src.replace("components/Good.island.tsx", "components/Noisy.island.tsx"))
PY
if (cd "$DESYNC" && "$BIN" release --force -o out --format=json \
      --bun="$(command -v bun)" "--island-sidecar=$REPO/runtime/sidecar/render.ts" \
      --island-src-dir=.) >"$DESYNC/out.log" 2>"$DESYNC/err.log"; then
  echo 'FAIL: a desynced sidecar built successfully'; exit 1
fi
bun -e '
  const records = (await Bun.file(process.argv[1]).text()).trim().split("\n").map(line => JSON.parse(line));
  const errors = records.filter(d => d.code === "ZP_ISLAND_SSR");
  if (errors.length !== 1) throw Error(`expected one ZP_ISLAND_SSR record, got ${errors.length}`);
  const [d] = errors;
  if (d.file !== "content/index.smd") throw Error("lost page attribution");
  if (!d.message.includes("components/Noisy.island.tsx")) throw Error("lost component attribution");
  const detail = d.message.split(/\(route [^)]*\): /)[1];
  if (detail === undefined) throw Error("message no longer carries a route-qualified detail");
  const head = detail.split("\n")[0].trim();
  if (head.length === 0) throw Error("empty detail: the error name was discarded");
  // Not merely non-empty: it must name the SIDECAR as the fault. Letting the
  // JSON parser errors through spelled this "SyntaxError", which reads as a
  // syntax error in the author component and sends them to debug the wrong file.
  if (head !== "SidecarBadResponse") throw Error(`detail blames the wrong thing: ${head}`);
' "$DESYNC/err.log"
# A sidecar that dies mid-build, across MORE THAN ONE page. Only the worker that
# happens to be reading when the subprocess exits observes the closed pipe; every
# other worker then writes its request into a pipe with no reader, which
# std.Io.Writer collapses to a bare `WriteFailed`. So a single-page fixture
# cannot see this: the defect is that N-1 of N records named the buffered
# writer's state instead of the failure, and it only appears with N > 1.
EXIT="$WORK/exiting"
mkdir -p "$EXIT/content" "$EXIT/layouts" "$EXIT/components"
cp "$WORK/zigapagos.ziggy" "$EXIT/zigapagos.ziggy"
cp "$WORK/layouts/index.shtml" "$EXIT/layouts/index.shtml"
ln -s "$REPO/runtime/node_modules" "$EXIT/node_modules"
cat > "$EXIT/components/Exiting.island.tsx" <<'EOF'
export default function Exiting() { process.exit(0); return 'never returns'; }
EOF
for n in index p1 p2 p3 p4 p5 p6 p7; do
  cp "$WORK/content/index.smd" "$EXIT/content/$n.smd"
  python3 - "$EXIT/content/$n.smd" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
assert "Good.island.tsx" in src, "fixture page changed; update this test's substitution"
open(p, "w").write(src.replace("components/Good.island.tsx", "components/Exiting.island.tsx"))
PY
done
if (cd "$EXIT" && "$BIN" release --force -o out --format=json \
      --bun="$(command -v bun)" "--island-sidecar=$REPO/runtime/sidecar/render.ts" \
      --island-src-dir=.) >"$EXIT/out.log" 2>"$EXIT/err.log"; then
  echo 'FAIL: a sidecar that exited mid-build built successfully'; exit 1
fi
bun -e '
  const records = (await Bun.file(process.argv[1]).text()).trim().split("\n").map(line => JSON.parse(line));
  const errors = records.filter(d => d.code === "ZP_ISLAND_SSR");
  if (errors.length !== 8) throw Error(`expected 8 ZP_ISLAND_SSR records, got ${errors.length}`);
  const names = errors.map(d => d.message.split(/\(route [^)]*\): /)[1].split("\n")[0].trim());
  const wrong = names.filter(n => n !== "SidecarExited");
  if (wrong.length) throw Error(`${wrong.length}/8 records name something other than the exited sidecar: ${[...new Set(wrong)].join(", ")}`);
' "$EXIT/err.log"
(cd "$WORK" && "$BIN" validate --format=json) >"$WORK/validate.out" 2>"$WORK/validate.err"
if grep -q ZP_ISLAND_ "$WORK/validate.err"; then echo 'FAIL: validate requires a sidecar'; exit 1; fi
for code in ZP_ISLAND_SSR ZP_ISLAND_PROPS ZP_ISLAND_RENDER ZP_ISLAND_SIDECAR_MISSING; do
  "$BIN" explain-code "$code" --format=json 2>"$WORK/explain"
  bun -e 'const d = JSON.parse(await Bun.file(process.argv[1]).text()); if (d.code !== process.argv[2] || !d.explanation) throw Error("missing explanation");' "$WORK/explain" "$code"
done
echo 'ok: island diagnostics retain page/component attribution and complete concurrent traces'
