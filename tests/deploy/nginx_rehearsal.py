#!/usr/bin/env python3
"""Build, serve and upgrade static releases on real nginx + Chromium (loopback only)."""
import argparse
from contextlib import contextmanager
import json
import os
import re
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

from playwright.sync_api import sync_playwright

REPO = Path(__file__).resolve().parents[2]


def command(args, **kwargs):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True,
                            encoding='utf-8', timeout=120, **kwargs)
    if result.returncode:
        raise AssertionError(f'{args}: exit {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result.stdout


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8', newline='\n')


def get(url, headers=None):
    try:
        response = urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


def wait_for_retired_workers(host, log, workers, timeout=10):
    """A new worker's response does not prove old workers stopped accepting."""
    if not workers:
        raise AssertionError('nginx notice log contains no original worker PIDs')
    deadline = time.monotonic() + timeout
    exited = {}
    while time.monotonic() < deadline:
        if host.poll() is not None:
            raise AssertionError('nginx master exited while retiring old workers')
        events = log.read_text(encoding='utf-8')
        exited = {int(pid): int(code) for pid, code in
                  re.findall(r'worker process (\d+) exited with code (\d+)', events)}
        failed = {pid: exited[pid] for pid in workers if pid in exited and exited[pid] != 0}
        if failed:
            raise AssertionError(f'nginx old workers exited unsuccessfully: {failed}')
        if workers.issubset(exited):
            return
        time.sleep(.02)
    raise AssertionError(f'nginx old workers did not retire: {sorted(workers - exited.keys())}')


@contextmanager
def rehearsal_session(browser, server_args, log_path):
    """Acquire resources under cleanup guards before browser setup can fail."""
    with log_path.open('w') as log:
        host = subprocess.Popen(server_args, stdout=log, stderr=log)
        try:
            context = browser.new_context()
            try:
                yield host, context
            finally:
                context.close()
        finally:
            host.terminate()
            try:
                host.wait(timeout=10)
            except subprocess.TimeoutExpired:
                host.kill()
                host.wait(timeout=5)


def rehearsal(work, args, browser, prefix):
    site = work / ('subpath' if prefix else 'root')
    site.mkdir()
    env = dict(os.environ, ZIGAPAGOS_RUNTIME_DIR=str(REPO / 'runtime'))
    command([args.binary, 'init', '--minimal'], cwd=site, env=env)
    config = site / 'zigapagos.ziggy'
    write(config, config.read_text().replace('Site {', 'Site {\n    .deploy_target = "nginx",\n'
          f'    .url_path_prefix = "{prefix.strip(chr(47))}",'))
    write(site / 'tsconfig.json', json.dumps({'compilerOptions': {'jsx': 'react-jsx', 'jsxImportSource': '@z/runtime'}}))
    write(site / 'app/app.spa.tsx', '''import {Router, Link, lazy, useState} from '@z/runtime';
import {version} from './version';
export const spa={base:'/app',title:'Host rehearsal'};
function Home(){const [count,setCount]=useState(0);return <main><h1>{version}</h1><button onClick={()=>setCount(count+1)}>Count {count}</button><Link href="/lazy">Lazy page</Link></main>}
function Item(){return <main><h1>Dynamic item</h1><Home/></main>}
export const routes=[{path:'/',component:Home},{path:'/item/:id',component:Item,skeleton:false},{path:'/lazy',component:lazy(()=>import('./Lazy')),skeleton:()=> <p>Loading lazy page</p>}];
export default function App(){return <Router base={spa.base} routes={routes}/>}
''')
    releases = []
    layout = site / 'layouts/page.shtml'
    original_layout = layout.read_text(encoding='utf-8').replace('</head>',
        '<link rel="stylesheet" href="$site.asset(\'theme.abcdef12.css\').link()"></head>').replace('</body>',
        '<a href="$site.asset(\'shell.abcdef12.html\').link()">Stable HTML asset</a></body>')
    write(site / 'assets/theme.abcdef12.css', 'body { color: #123456; }')
    write(site / 'assets/shell.abcdef12.html', '<!doctype html><html><head><title>Stable HTML</title></head><body>HTML still revalidates</body></html>')
    for version in ('release-one', 'release-two-longer'):
        write(layout, original_layout.replace('</body>', f'<script>window.rehearsalRelease={json.dumps(version)};</script></body>'))
        write(site / 'app/version.ts', f'export const version="{version}";')
        write(site / 'app/Lazy.tsx', f'export default function Lazy(){{return <h1>Lazy {version}</h1>}}')
        tree = site / version
        command([args.binary, 'release', '--force', '--spa=app/app.spa.tsx|/app', f'--output={tree}'], cwd=site, env=env)
        releases.append(tree)
    first, second = releases
    deployed = [site / 'host-release-one', site / 'host-release-two']
    for tree, target in zip(releases, deployed):
        shutil.copytree(tree, target)
    policies = [next(line.removeprefix('Content-Security-Policy: ') for line in
                     (tree / 'csp.zigbase.txt').read_text().splitlines()
                     if line.startswith('Content-Security-Policy: ')) for tree in releases]
    assert policies[0] != policies[1], 'fixture must distinguish old/new nginx header configuration'
    manifests = [json.loads((tree / 'app/routing-manifest.json').read_text()) for tree in releases]
    old_chunks = set(manifests[0]['immutableAssets'])
    assert old_chunks and old_chunks - set(manifests[1]['immutableAssets']), 'fixture must change split chunk identity'
    # Retain immutable files for documents opened before the switch. This is an
    # explicit deployment strategy, not behavior provided by the generator.
    for url in old_chunks:
        relative = url.removeprefix(prefix).lstrip('/')
        target = deployed[1] / relative
        if target.exists():
            assert target.read_bytes() == (first / relative).read_bytes()
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(first / relative, target)
    # Keep retained assets immutable in the deployment policy, while checking
    # each pristine build separately against the host.
    write(site / 'retained-paths.json', json.dumps(sorted(old_chunks | set(manifests[1]['immutableAssets']))))
    command(['bun', '-e', "import {emitCache} from " + json.dumps(str(REPO / 'runtime/scripts/emit-host-config.ts')) + "; const paths=await Bun.file(process.argv[1]).json(); await Bun.write(process.argv[2],emitCache('nginx',paths).content);",
             site / 'retained-paths.json', deployed[1] / 'cache.nginx.conf'])
    current = site / 'current'
    current.symlink_to(deployed[0], target_is_directory=True)
    docroot = site / 'www'
    if prefix:
        docroot.mkdir()
        (docroot / prefix.strip('/')).symlink_to(current, target_is_directory=True)
    else:
        docroot.symlink_to(current, target_is_directory=True)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    # No system nginx configuration or service is touched. All writable paths
    # and the PID belong to this rehearsal; only a loopback listener is opened.
    conf = site / 'nginx.conf'
    write(conf, f'''worker_processes 1;
pid "{site}/nginx.pid";
error_log "{site}/error.log" notice;
events {{ worker_connections 128; }}
http {{
  access_log "{site}/access.log";
  types {{ text/html html; text/css css; text/javascript js mjs; application/json json; }}
  default_type application/octet-stream;
  client_body_temp_path "{site}/body";
  proxy_temp_path "{site}/proxy";
  fastcgi_temp_path "{site}/fastcgi";
  uwsgi_temp_path "{site}/uwsgi";
  scgi_temp_path "{site}/scgi";
  include "{current}/cache.nginx.conf";
  server {{
    listen 127.0.0.1:{port};
    root "{docroot}";
    index index.html;
    include "{current}/csp.nginx.conf";
    add_header Cache-Control $zigapagos_cache_control always;
    include "{current}/app/nginx.nginx.conf";
    location / {{ try_files $uri $uri/ =404; }}
  }}
}}
''')
    command([args.nginx, '-t', '-p', site, '-c', conf])
    origin = f'http://127.0.0.1:{port}'
    base = origin + prefix
    server_args = [args.nginx, '-p', str(site), '-c', str(conf), '-g', 'daemon off;']
    with rehearsal_session(browser, server_args, site / 'process.log') as (host, context):
        context.add_init_script("window.__csp=[];addEventListener('securitypolicyviolation',e=>window.__csp.push(e.violatedDirective));")
        errors = []
        context.on('page', lambda page: page.on('pageerror', lambda error: errors.append(str(error))))
        for attempt in range(100):
            if host.poll() is not None:
                raise AssertionError((site / 'process.log').read_text())
            try:
                if get(base + '/')[0] == 200:
                    break
            except OSError:
                pass
            time.sleep(.05)
        else:
            raise AssertionError('nginx did not start')
        checker = ['bun', REPO / 'runtime/scripts/check-static-deploy.ts', '--site', first, '--url', base + '/', '--json']
        report = json.loads(command(checker))
        assert report['ok'], report
        status, headers, body = get(base + '/app/')
        assert status == 200 and headers['Cache-Control'] == 'no-cache'
        etag = headers['ETag']
        assert get(base + '/app/', {'If-None-Match': etag})[0] == 304
        assert get(base + '/spa/absent.js')[0] == 404, 'missing asset must not become HTML'
        # Browser deep link starts at nginx, then hydration proves CSP permits
        # generated imports/bootstrap and event handlers actually run.
        page = context.new_page()
        page.goto(base + '/app/item/arbitrary-id', wait_until='networkidle')
        page.get_by_role('heading', name='Dynamic item', exact=True).wait_for()
        page.get_by_role('button', name='Count 0').click()
        page.get_by_role('button', name='Count 1').wait_for()
        assert page.evaluate('window.__csp') == []
        page.evaluate("const script=document.createElement('script');script.textContent='window.disallowedInlineRan=true';document.body.append(script);")
        for attempt in range(100):
            if page.evaluate('window.__csp.length > 0'):
                break
            page.wait_for_timeout(20)
        else:
            raise AssertionError('CSP did not report the deliberately disallowed inline script')
        assert page.evaluate('window.disallowedInlineRan === undefined')
        assert page.evaluate('window.__csp.every(value => value.startsWith(\"script-src\"))')
        page.close()
        old = context.new_page()
        old.goto(base + '/app/', wait_until='networkidle')
        old.get_by_role('heading', name='release-one', exact=True).wait_for()
        # Atomically replace the symlink, then reload generated header config.
        next_link = site / 'next'
        next_link.symlink_to(deployed[1], target_is_directory=True)
        next_link.replace(current)
        command([args.nginx, '-t', '-p', site, '-c', conf])
        notice_log = site / 'error.log'
        old_workers = set(map(int, re.findall(r'start worker process (\d+)', notice_log.read_text(encoding='utf-8'))))
        command([args.nginx, '-s', 'reload', '-p', site, '-c', conf])
        # During graceful reload both generations can serve connections. Retire
        # every original worker before checking the new policy, including with
        # Bun's fresh connections. Do not retry a failed HTTP checker.
        wait_for_retired_workers(host, notice_log, old_workers)
        for attempt in range(100):
            status, new_headers, new_body = get(base + '/app/', {'If-None-Match': etag})
            if status == 200 and new_body != body and new_headers.get('Content-Security-Policy') == policies[1]:
                break
            time.sleep(.05)
        else:
            raise AssertionError('release switch did not converge to new HTML and generated CSP' )
        report = json.loads(command(['bun', REPO / 'runtime/scripts/check-static-deploy.ts', '--site', second, '--url', base + '/', '--json']))
        assert report['ok'], report
        requested = []
        old.on('request', lambda request: requested.append(request.url))
        old.get_by_role('link', name='Lazy page').click()
        old.get_by_role('heading', name='Lazy release-one', exact=True).wait_for()
        assert any(origin + url in requested for url in old_chunks), 'old document must fetch a retained old chunk after switching'
        for url in old_chunks:
            status, chunk_headers, _ = get(origin + url)
            assert status == 200 and chunk_headers['Cache-Control'] == 'public, max-age=31536000, immutable'
        fresh = context.new_page()
        fresh.goto(base + '/app/', wait_until='networkidle')
        fresh.get_by_role('heading', name='release-two-longer', exact=True).wait_for()
        fresh.get_by_role('link', name='Lazy page').click()
        fresh.get_by_role('heading', name='Lazy release-two-longer', exact=True).wait_for()
        assert not errors, errors
        assert old.evaluate('window.__csp') == [] and fresh.evaluate('window.__csp') == []
        print(json.dumps({'mount': prefix or '/', 'host': args.host_version,
                          'browser': browser.version, 'http_checked': report['checked'],
                          'deep_link': True, 'unexpected_csp_violations': 0, 'disallowed_inline_blocked': True, 'conditional_get_304': True,
                          'release_transition': True, 'retained_immutable_files': len(old_chunks)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default=os.environ.get('ZIGAPAGOS_BIN', str(REPO / 'zig-out/bin/zigapagos')))
    parser.add_argument('--nginx', default=os.environ.get('NGINX_BIN', 'nginx'))
    parser.add_argument('--browser-channel', default=os.environ.get('PLAYWRIGHT_CHANNEL', 'chrome'))
    args = parser.parse_args()
    args.binary = str(Path(args.binary).resolve())
    args.host_version = subprocess.run([args.nginx, '-v'], capture_output=True, text=True, check=True).stderr.strip()
    print(args.host_version, flush=True)
    with tempfile.TemporaryDirectory(prefix='zigapagos-nginx-') as temp, sync_playwright() as playwright:
        browser = playwright.chromium.launch(**({'channel': args.browser_channel} if args.browser_channel else {}))
        try:
            for prefix in ('', '/preview'):
                rehearsal(Path(temp), args, browser, prefix)
        finally:
            browser.close()


if __name__ == '__main__':
    main()
