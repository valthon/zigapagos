#!/usr/bin/env bash
# Each failing worker must emit one complete record, including a multiline
# SuperHTML trace. A whole stderr parse detects prose and interleaving.
set -euo pipefail
cd "$(dirname "$0")/../.."
ZIGAPAGOS="${ZIGAPAGOS_BIN:-$PWD/zig-out/bin/zigapagos}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/content" "$WORK/layouts"
cat > "$WORK/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Render diagnostics",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF
cat > "$WORK/layouts/index.shtml" <<'EOF'
<!DOCTYPE html>
<html>
<head><title>Render diagnostics</title></head>
<body><p :text="$page.does_not_exist"></p></body>
</html>
EOF
for name in index $(seq 1 24); do
  cat > "$WORK/content/$name.smd" <<'EOF'
---
.title = "Test",
.date = @date("2020-07-06T00:00:00"),
.layout = "index.shtml",
---
Hello.
EOF
done
for attempt in 1 2 3; do
  if (cd "$WORK" && "$ZIGAPAGOS" release --format=json --force -o out) >"$WORK/stdout" 2>"$WORK/stderr"; then
    echo "FAIL: invalid page evaluation succeeded"; exit 1
  fi
  bun -e '
    const text = await Bun.file(process.argv[1]).text();
    const records = text.trim().split("\n").map(line => JSON.parse(line));
    const pages = records.filter(d => d.code === "ZP_PAGE_RENDER");
    if (pages.length !== 25) throw new Error(`expected 25 page failures, got ${pages.length}`);
    if (new Set(pages.map(d => d.file)).size !== 25) throw new Error("missing/duplicate page");
    for (const d of pages) {
      if (d.severity !== "error" || !/^content\/(index|[0-9]+)\.smd$/.test(d.file))
        throw new Error(`bad page attribution: ${JSON.stringify(d)}`);
      if (d.line !== null || d.col !== null) throw new Error("template span attributed to page");
      if (!d.message.includes("does_not_exist") || !d.message.includes("index.shtml") || !d.message.includes("\n"))
        throw new Error("lost multiline evaluation trace");
    }
  ' "$WORK/stderr"
done
if (cd "$WORK" && "$ZIGAPAGOS" release --force -o out) >"$WORK/text.out" 2>"$WORK/text.err"; then
  echo "FAIL: text mode accepted invalid evaluation"; exit 1
fi
bun -e '
  const text = await Bun.file(process.argv[1]).text();
  const records = (await Bun.file(process.argv[2]).text()).trim().split("\n").map(line => JSON.parse(line));
  for (const d of records.filter(d => d.code === "ZP_PAGE_RENDER")) {
    if (!text.includes(d.message)) throw new Error(`text trace changed for ${d.file}`);
  }
' "$WORK/text.err" "$WORK/stderr"
"$ZIGAPAGOS" explain-code ZP_PAGE_RENDER --format=json 2>"$WORK/explanation"
bun -e '
  const d = JSON.parse(await Bun.file(process.argv[1]).text());
  if (d.code !== "ZP_PAGE_RENDER" || !d.explanation.includes("template")) throw new Error("missing explanation");
' "$WORK/explanation"
echo "ok: concurrent page-render diagnostics retain complete traces"
