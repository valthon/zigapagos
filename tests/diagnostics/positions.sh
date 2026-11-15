#!/usr/bin/env bash
# #257 / #256.2: malformed upstream columns and front-matter source offsets.
set -euo pipefail
cd "$(dirname "$0")/../.."
ZIGAPAGOS="${ZIGAPAGOS_BIN:-$PWD/zig-out/bin/zigapagos}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ulimit -c 0
mkdir -p "$WORK/content" "$WORK/layouts" "$WORK/assets"
cat > "$WORK/zigapagos.ziggy" <<'SITE'
Site {
    .title = "Positions",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
}
SITE
cat > "$WORK/layouts/index.shtml" <<'HTML'
<!DOCTYPE html><html><head><title>Positions</title></head><body><div :html="$page.content()"></div></body></html>
HTML
failures=0
check() {
  local body="$1" blanks="$2" code="$3" message="$4" row="$5"
  {
    printf '%s\n' '---' '.title = "Repro",' '.date = @date("1970-01-01T00:00:00"),' '.layout = "index.shtml",' '---'
    for ((i=0; i<blanks; i++)); do printf '\n'; done
    printf '%s\n' "$body"
  } > "$WORK/content/index.smd"
  for format in json text; do
    rc=0
    (cd "$WORK" && "$ZIGAPAGOS" release --force --format="$format" --output=out) >"$WORK/out.log" 2>"$WORK/err.log" || rc=$?
    if [[ "$rc" != 1 ]]; then
      echo "FAIL: $format $body: exit $rc, expected 1"
      failures=$((failures+1))
      continue
    fi
    if ! bun -e '
      const [path, format, code, message, row] = process.argv.slice(1);
      const text = await Bun.file(path).text();
      if (/panic|integer overflow|stack trace/i.test(text)) throw Error(text);
      if (format === "json") {
        const ds = text.trim().split("\n").map(l => JSON.parse(l));
        const d = ds.find(d => d.code === code && d.message.includes(message));
        if (!d || d.line !== Number(row) || d.col < 1) throw Error(text);
      } else {
        if (!text.includes(message) || !text.includes(`index.smd:${row}:`)) throw Error(text);
        const lines = text.split("\n");
        const i = lines.findIndex(l => l.includes(`index.smd:${row}:`));
        const source = lines[i+1]?.replace(/^\|    /, "");
        const caret = lines[i+2]?.replace(/^\|    /, "");
        if (!caret || !/^ *\^+$/.test(caret) || caret.length > Math.max(1, source.length)) throw Error(text);
      }
    ' "$WORK/err.log" "$format" "$code" "$message" "$row"; then
      failures=$((failures+1))
    fi
  done
}
for blanks in 0 1 2; do
  check '[x](/nope/)' "$blanks" ZP_UNKNOWN_PAGE '' "$((6+blanks))"
  check '[x](#missing)' "$blanks" ZP_UNKNOWN_REF '' "$((6+blanks))"
  check '<div>raw</div>' "$blanks" ZP_SUPERMD html_is_forbidden "$((6+blanks))"
done
check 'http://e:x' 1 ZP_SUPERMD '[scripty] invalid URL' 7
check '- https://example.com:port/' 1 ZP_SUPERMD '[scripty] invalid URL' 7
check $'1234567890123456789012345678901234567890\nhttps://example.com:port/' 1 ZP_SUPERMD '[scripty] invalid URL' 8
if ((failures)); then echo "FAIL: $failures position checks"; exit 1; fi
echo 'ok: invalid autolinks stay diagnostic; front-matter offsets match file lines'
