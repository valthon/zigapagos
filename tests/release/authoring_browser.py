#!/usr/bin/env python3
"""Exercise emitted hydration modes and actual module requests in Chrome."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
import json
import os
import re
import subprocess
from urllib.parse import urlsplit
from playwright.sync_api import sync_playwright

REPO = Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix='z-authoring-browser-') as temporary:
    fixture = Path(temporary)
    subprocess.run(['bash', str(REPO / 'tests/release/authoring-defaults.sh')], cwd=REPO,
                   env=dict(os.environ, ZIGAPAGOS_AUTHORING_FIXTURE=str(fixture)), check=True, timeout=180)
    output = fixture / 'public'
    manifest = json.loads((output / 'app/routing-manifest.json').read_text())

    class Host(SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            path = urlsplit(self.path).path
            if not Path(self.translate_path(path)).exists() and path.startswith('/fallback/'):
                self.path = '/fallback/index.html'
            if not Path(self.translate_path(path)).exists() and path.startswith('/app/'):
                # One URL deliberately uses the namespace fallback instead of
                # its dedicated shell, as the stock .spa marker does.
                self.path = '/app/index.html'
                if path != '/app/item/99':
                    for entry in manifest['dynamic']:
                        pattern = re.sub(r':[^/]+', '[^/]+', entry['pattern'])
                        if re.fullmatch(pattern, path.rstrip('/')):
                            self.path = entry['shell']
                            break
            super().do_GET()

    host = ThreadingHTTPServer(('127.0.0.1', 0), partial(Host, directory=str(output)))
    worker = Thread(target=host.serve_forever, daemon=True)
    worker.start()
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(channel=os.environ.get('PLAYWRIGHT_CHANNEL', 'chrome'))
            page = browser.new_page(viewport={'width': 800, 'height': 600})
            errors, requests = [], []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.on('request', lambda request: requests.append(urlsplit(request.url).path))
            page.add_init_script('window.__guardParams = [];')
            base = f'http://127.0.0.1:{host.server_port}'
            page.goto(base + '/', wait_until='networkidle')
            assert not any(path.endswith('.js') for path in requests), requests
            page.goto(base + '/mixed/', wait_until='networkidle')
            page.get_by_role('button', name='ready 0').click()
            page.get_by_role('button', name='ready 1').wait_for()
            assert not any(path.endswith('/Static.island.js') for path in requests), requests

            page.add_init_script('window.requestIdleCallback = callback => { window.fireIdle = callback; return 1; };')
            requests.clear()
            page.goto(base + '/deferred/', wait_until='networkidle')
            for name in ['Idle', 'Media', 'Visible']:
                assert not any(path.endswith(f'/{name}.island.js') for path in requests), (name, requests)
            page.evaluate('window.fireIdle({didTimeout:false,timeRemaining:()=>50})')
            page.wait_for_selector('[data-z-client="idle"][data-z-hydrated]')
            page.set_viewport_size({'width': 1600, 'height': 600})
            page.wait_for_selector('[data-z-client="media"][data-z-hydrated]')
            page.set_viewport_size({'width': 800, 'height': 600})
            assert page.locator('[data-z-client="media"][data-z-hydrated]').count() == 1
            page.locator('[data-z-client="visible"]').scroll_into_view_if_needed()
            page.wait_for_selector('[data-z-client="visible"][data-z-hydrated]')

            for path in ['/app/item/42/', '/app/custom/42/', '/app/group/A/item/42/']:
                page.goto(base + path, wait_until='networkidle')
                assert page.locator('main').get_attribute('data-item') == '42', path
                assert not page.locator('[data-loading]').count(), path
            page.goto(base + '/app/group/B/item/88', wait_until='networkidle')
            assert page.locator('section').get_attribute('data-group') == 'B'
            assert page.locator('main').get_attribute('data-item') == '88'
            page.goto(base + '/app/item/99', wait_until='networkidle')
            assert page.locator('main').get_attribute('data-item') == '99'
            page.goto(base + '/app/lazy/42/', wait_until='networkidle')
            page.get_by_role('heading', name='Loaded lazy').wait_for()
            page.goto(base + '/app/secure/42/', wait_until='networkidle')
            page.get_by_role('heading', name='Home').wait_for()
            assert 'PRIVATE_SECRET' not in page.content()
            assert page.evaluate('window.__guardParams') == ['42']
            page.goto(base + '/app/secure/99', wait_until='networkidle')
            page.get_by_role('heading', name='Home').wait_for()
            assert page.evaluate('window.__guardParams') == ['99']
            requests.clear()
            page.goto(base + '/fallback/deep/99', wait_until='networkidle')
            page.get_by_role('heading', name='Deep 99').wait_for()
            assert not any('/spa/RootView-' in path for path in requests), requests
            page.goto(base + '/fallback/', wait_until='networkidle')
            page.get_by_role('heading', name='Lazy namespace root').wait_for()
            assert not errors, errors
            browser.close()
            print('PASS: server-only nested islands, deferred requests, concrete/generic hydration, nested params, lazy views and guards')
    finally:
        host.shutdown()
        host.server_close()
        worker.join(timeout=5)
