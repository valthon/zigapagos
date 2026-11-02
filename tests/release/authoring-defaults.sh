#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
BIN="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"
SITE="${ZIGAPAGOS_AUTHORING_FIXTURE:-$(mktemp -d)}"
if [[ -z "${ZIGAPAGOS_AUTHORING_FIXTURE:-}" ]]; then trap 'rm -rf "$SITE"' EXIT; fi
mkdir -p "$SITE"
(cd "$SITE" && "$BIN" init --minimal)
mkdir -p "$SITE/components" "$SITE/app" "$SITE/node_modules/@z"
ln -s "$REPO/runtime" "$SITE/node_modules/@z/runtime"
cat > "$SITE/tsconfig.json" <<'JSON'
{"compilerOptions":{"jsx":"react-jsx","jsxImportSource":"@z/runtime","moduleResolution":"bundler","module":"ESNext","allowImportingTsExtensions":true,"noEmit":true,"target":"ES2020"}}
JSON
cat > "$SITE/components/Static.island.tsx" <<'TS'
import type {ComponentChildren} from '@z/runtime';
export type Props={children?:ComponentChildren};
export default function Static({children}:Props){return <section data-static="yes">Static HTML{children}</section>}
TS
for name in Child Visible Media Idle; do
cat > "$SITE/components/$name.island.tsx" <<'TS'
import {useState} from '@z/runtime';
export type Props={label?:string};
export default function Widget({label='ready'}:Props){const [n,set]=useState(0);return <button onClick={()=>set(n+1)}>{label} {n}</button>}
TS
done
cat > "$SITE/layouts/page.shtml" <<'HTML'
<html><head><title>Static</title></head><body><island src="components/Static.island.tsx"></island></body></html>
HTML
cat > "$SITE/layouts/mixed.shtml" <<'HTML'
<html><head><title>Mixed</title></head><body><island src="components/Static.island.tsx"><island src="components/Child.island.tsx" client:load></island></island></body></html>
HTML
cat > "$SITE/layouts/deferred.shtml" <<'HTML'
<html><head><title>Deferred</title></head><body>
<island src="components/Idle.island.tsx" client:idle></island>
<island src="components/Media.island.tsx" client:media="(min-width: 1500px)"></island>
<div style="height:4000px"></div><island src="components/Visible.island.tsx" client:visible></island>
</body></html>
HTML
for page in mixed deferred; do
printf '%s\n' '---' ".title = \"$page\"," ".layout = \"$page.shtml\"," '---' > "$SITE/content/$page.smd"
done
cat > "$SITE/app/build-only.ts" <<'TS'
import {readFileSync} from 'node:fs';
const data=readFileSync(new URL('./BUILD_ONLY_SENTINEL.json',import.meta.url),'utf8');
export function enumerate(){return JSON.parse(data)}
TS
printf '%s\n' '[{"id":"42"}]' > "$SITE/app/BUILD_ONLY_SENTINEL.json"
cat > "$SITE/app/App.spa.tsx" <<'TS'
import {Router, useParams, Link, lazy} from '@z/runtime';
import {enumerate} from './build-only';
export const spa={base:'/app',head:[]};
function Item(){const {id}=useParams();return <main data-item={id}><h1>Item {id}</h1><Link href="/item/99">Next</Link></main>}
function Group({children}){return <section data-group={useParams().group}>{children}</section>}
export const routes=[
 {path:'/',redirect:'/home'},
 {path:'/home',component:()=> <h1>Home</h1>},
 {path:'/item/:id',component:Item,staticPaths:enumerate},
 {path:'/custom/:id',component:Item,skeleton:()=> <p data-loading="custom">Loading</p>,staticPaths:[{id:'42'}]},
 {path:'/group/:group',component:Group,children:[{path:'/item/:id',component:Item,staticPaths:[{group:'A',id:'42'}]}]},
 {path:'/secure/:id',component:()=> <p>PRIVATE_SECRET</p>,guard:async(loc)=>{(window as any).__guardParams.push(loc.params.id);return {redirect:'/'}},staticPaths:[{id:'42'}]},
 {path:'/lazy/:id',component:lazy(()=>import('./Lazy')),skeleton:()=> <p data-loading="lazy">Loading lazy</p>,staticPaths:[{id:'42'}]}
];
export default function App(){return <Router base={spa.base} routes={routes} fallback={()=> <p data-guard>Checking access</p>}/>}
TS
cat > "$SITE/app/Lazy.tsx" <<'TS'
export default function Lazy(){return <h1>Loaded lazy</h1>}
TS
mkdir -p "$SITE/lazy-root"
cat > "$SITE/lazy-root/Root.spa.tsx" <<'TS'
import {Router, lazy, useParams} from '@z/runtime';
export const spa={base:'/fallback',head:[]};
export const routes=[
 {path:'/',component:lazy(()=>import('./RootView')),skeleton:()=> <p>Loading root</p>},
 {path:'/deep/:id',component:()=> <h1>Deep {useParams().id}</h1>}
];
export default function Root(){return <Router base={spa.base} routes={routes}/>}
TS
cat > "$SITE/lazy-root/RootView.tsx" <<'TS'
export default function RootView(){return <h1>Lazy namespace root</h1>}
TS
(cd "$SITE" && "$BIN" release --force --output public)
Z_AUTHORING_TSC="$REPO/runtime/node_modules/typescript" Z_AUTHORING_CONFIG="$SITE/.zigapagos-cache/props-check/tsconfig.props-check.json" bun -e '
const ts = require(process.env.Z_AUTHORING_TSC);
const config = ts.readConfigFile(process.env.Z_AUTHORING_CONFIG, ts.sys.readFile);
if (config.error) throw new Error(ts.flattenDiagnosticMessageText(config.error.messageText, "\n"));
const parsed = ts.parseJsonConfigFileContent(config.config, ts.sys, require("node:path").dirname(process.env.Z_AUTHORING_CONFIG));
if (parsed.options.jsx !== ts.JsxEmit.ReactJSX || parsed.options.target !== ts.ScriptTarget.ES2020 || parsed.options.jsxImportSource !== "@z/runtime") {
  throw new Error("props checker overrode the project JSX or target options");
}
'
python3 - "$SITE" <<'PY'
import json, sys
from pathlib import Path
site = Path(sys.argv[1])
entries = list((site/'.zigapagos-cache/client-source').glob('*.json'))
assert entries, 'CLI did not populate the persistent staticPaths transform cache'
(site/'source-cache-state.json').write_text(json.dumps({p.name: p.stat().st_mtime_ns for p in entries}))
PY
python3 - "$SITE/public" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1])
static=(out/'index.html').read_text()
assert 'Static HTML' in static and '<script' not in static and 'data-z-client=' not in static
mixed=(out/'mixed/index.html').read_text()
assert 'data-z-client="load"' in mixed and 'data-z-static-module' in mixed
assert 'data-z-props="z-island-' in mixed
deferred=(out/'deferred/index.html').read_text()
for name in ['Idle', 'Media', 'Visible']:
 assert f'modulepreload" href="/islands/{name}.island.js' not in deferred
for path in ['app/item/42/index.html','app/custom/42/index.html','app/group/A/item/42/index.html']:
 html=(out/path).read_text()
 assert 'data-item="42"' in html and 'data-z-prerender="concrete"' in html, path
 assert 'data-loading' not in html, path
assert 'data-item=' not in (out/'app/item/_shell.html').read_text()
assert 'data-loading="custom"' in (out/'app/custom/_shell.html').read_text()
assert 'PRIVATE_SECRET' not in (out/'app/secure/42/index.html').read_text()
assert 'data-loading="lazy"' in (out/'app/lazy/42/index.html').read_text()
assert 'RootView-' not in (out/'fallback/index.html').read_text(), 'namespace fallback preloads an unrelated lazy root chunk'
client='\n'.join(p.read_text() for p in (out/'spa').glob('*.js'))
assert 'BUILD_ONLY_SENTINEL' not in client and 'node:fs' not in client and 'staticPaths' not in client
print('PASS: server-only roots, nested hydration, deferred preloads, concrete content, lazy/guard fallbacks, build-only stripping')
PY
# Default props validation must reject a resolved mismatch even on server-only roots.
cp "$SITE/layouts/page.shtml" "$SITE/valid-layout"
cat > "$SITE/layouts/page.shtml" <<'HTML'
<html><head></head><body><island src="components/Child.island.tsx" :props='{ .label = 42 }'></island></body></html>
HTML
if (cd "$SITE" && "$BIN" release --force --output bad-output > props.log 2>&1); then
 echo 'FAIL: default props checking accepted a number for label:string'; exit 1
fi
grep -q 'TS2322' "$SITE/props.log" || {
 cat "$SITE/props.log"; echo 'FAIL: props check did not report TS2322'; exit 1;
}
rm "$SITE/tsconfig.json"
if (cd "$SITE" && "$BIN" release --force --output bad-output > props.log 2>&1); then
 echo 'FAIL: props checking without a project tsconfig accepted invalid props'; exit 1
fi
grep -q 'TS2322' "$SITE/props.log" || {
 cat "$SITE/props.log"; echo 'FAIL: props check without a project tsconfig did not report TS2322'; exit 1;
}
test ! -e "$SITE/tsconfig.json" || { echo 'FAIL: props checking created a project tsconfig'; exit 1; }
python3 - "$SITE" <<'PY'
import json, sys
from pathlib import Path
site = Path(sys.argv[1])
before = json.loads((site/'source-cache-state.json').read_text())
after = {p.name: p.stat().st_mtime_ns for p in (site/'.zigapagos-cache/client-source').glob('*.json')}
assert before == after, 'unchanged SPA transforms were rewritten on a later CLI build'
PY
mv "$SITE/valid-layout" "$SITE/layouts/page.shtml"
echo 'PASS: props checking fails by default, including server-only components'
