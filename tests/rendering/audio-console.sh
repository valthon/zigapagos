#!/usr/bin/env bash
# Both render entry points, media resolution and the emitted deploy artifacts.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/content" "$WORK/layouts" "$WORK/assets"
cat > "$WORK/zigapagos.ziggy" <<'CONFIG'
.site = .simple(.{
    .title = "Media",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .asset_fingerprint = true,
    .csp_extra_sources = [.{ .directive = "media-src", .sources = ["https://media.example.com"] }],
})
CONFIG
cat > "$WORK/layouts/index.shtml" <<'LAYOUT'
<!DOCTYPE html><html><head><title>Media</title></head><body><div :html="$page.content()"></div></body></html>
LAYOUT
printf 'MP3' > "$WORK/assets/song&mix.mp3"
printf 'WAV' > "$WORK/content/local.wav"
printf '$ echo "<&>"\noutput <&>\n' > "$WORK/content/session.txt"
cat > "$WORK/content/index.smd" <<'CONTENT'
---
.title = "Media",
.date = .date("2020-07-06T00:00:00"),
.layout = "index.shtml",
---
[**Listen**](<$audio.siteAsset('song&mix.mp3').id('player').attrs('wide').title('A "song" & more').loop(true).autoplay(true).muted(true).hide_controls(false)>)

[]($audio.url('https://media.example.com/song.mp3?a=1&b=2').hide_controls(true).loop(false).autoplay(false).muted(false))

[]($audio.asset('local.wav'))

[]($audio.buildAsset('recording'))

```console
$ echo "<&>"
[root@host]# cat <in>
# echo '&'
output <&>
```

[]($code.asset('session.txt').language('console'))
CONTENT
(cd "$WORK" && "$BIN" release --build-asset=recording "$WORK/content/local.wav" --install=recording.wav --output "$WORK/out" --force) > "$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; exit 1; }
if grep -Ei 'unknown.*language|ZP_UNKNOWN_LANGUAGE' "$WORK/build.log"; then exit 1; fi
python3 - "$WORK/out" <<'PY'
from pathlib import Path
import re,sys
from html import unescape
out=Path(sys.argv[1]); html=(out/'index.html').read_text()
assert '<figure><audio id="player" class="wide " title="A &quot;song&quot; &amp; more" loop autoplay muted controls>' in html, html
assert '<figcaption><strong>Listen</strong></figcaption></figure>' in html, html
sources=re.findall(r'<source src="([^"]+)">',html)
assert re.fullmatch(r'/song&amp;mix\.[0-9a-f]{8}\.mp3',sources[0]), sources
assert (out/unescape(sources[0]).lstrip('/')).read_bytes()==b'MP3'
assert not (out/'song&mix.mp3').exists()
assert sources[1]=='https://media.example.com/song.mp3?a=1&amp;b=2',sources
assert '<audio>\n<source src="https://' in html
assert sources[2:] == ['/local.wav','/recording.wav'],sources
assert html.count('<audio controls>') == 2,html
for source in sources[2:]: assert (out/source.lstrip('/')).is_file()
assert html.count('<span class="prompt">$</span> <span class="command">echo &quot;&lt;&amp;&gt;&quot;</span>')==2,html
assert '<span class="prompt">[root@host]#</span> <span class="command">cat &lt;in&gt;</span>' in html
assert '<span class="prompt">#</span> <span class="command">echo &apos;&amp;&apos;</span>' in html
assert 'output &lt;&amp;&gt;' in html
policies=list(out.glob('csp.*'))
assert policies, 'missing CSP artifacts'
for file in policies: assert "media-src 'self' https://media.example.com" in file.read_text(),file
PY
"$BIN" doctor "$WORK/out" > "$WORK/doctor.log" 2>&1 || { cat "$WORK/doctor.log"; exit 1; }
"$BIN" inspect-output "$WORK/out" > "$WORK/inspect.log" 2>&1 || { cat "$WORK/inspect.log"; exit 1; }
echo 'PASS: audio sources, attributes, fingerprints, CSP, doctor and console entry points'
