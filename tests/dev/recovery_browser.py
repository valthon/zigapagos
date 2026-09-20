"""Real dev builds + native Chrome EventSource recovery through a TCP fault proxy.

Run after zig build with Bun on PATH and Playwright's Chrome channel installed.
The proxy drops only the reload connection; it does not replace EventSource or
manufacture reload messages. Source edits still run the actual release command.
"""
import http.client
import json
import os
import pathlib
import select
import shlex
import signal
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.request

from playwright.sync_api import expect, sync_playwright

REPO = pathlib.Path(__file__).resolve().parents[2]
BINARY = str(pathlib.Path(os.environ.get('ZIGAPAGOS_BIN', REPO/'zig-out/bin/zigapagos')).resolve())


def wait_for(predicate, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError('Timed out: ' + description)


class ReloadProxy(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, upstream_port):
        self.upstream_port = upstream_port
        self.online = threading.Event()
        self.online.set()
        self.connections = set()
        self.mutex = threading.Lock()
        super().__init__(('127.0.0.1', 0), Forward)
        threading.Thread(target=self.serve_forever, daemon=True).start()

    def disconnect(self):
        self.online.clear()
        with self.mutex:
            for connection in self.connections:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass  # A browser reload may already have closed this socket.


class Forward(socketserver.BaseRequestHandler):
    def handle(self):
        proxy = self.server
        if not proxy.online.is_set():
            return
        try:
            upstream = socket.create_connection(('127.0.0.1', proxy.upstream_port))
        except OSError:
            return  # Expected while testing a server restart.
        pair = (self.request, upstream)
        with proxy.mutex:
            proxy.connections.update(pair)
        try:
            while proxy.online.is_set():
                readable, _, _ = select.select(pair, [], [], .1)
                for source in readable:
                    chunk = source.recv(65536)
                    if not chunk:
                        return
                    (upstream if source is self.request else self.request).sendall(chunk)
        except OSError:
            pass  # Deliberate disconnects and browser navigation tear down streams.
        finally:
            with proxy.mutex:
                proxy.connections.difference_update(pair)
            upstream.close()


with tempfile.TemporaryDirectory(prefix='zigapagos-dev-recovery-') as temporary:
    root = pathlib.Path(temporary)
    project = root/'site'
    project.mkdir()
    env = dict(os.environ, ZIGAPAGOS_DEV_BACKGROUND='0')
    env.pop('ZIGAPAGOS_RUNTIME_DIR', None)
    subprocess.run([BINARY, 'init', '--minimal'], cwd=project, env=env, check=True, capture_output=True)
    stub = root/'zigbase'
    stub.write_text('#!/bin/sh\nexec bun '+shlex.quote(str(REPO/'tests/dev/stub-zigbase.ts'))+' "$@"\n')
    stub.chmod(0o755)
    child = None
    facts = None
    proxy = None
    log_path = root/'dev.log'

    def launch():
        global child, facts
        args = [BINARY, 'dev', '--zigbase='+str(stub), '--no-download', '--port='+str(facts['port'] if facts else 0)]
        if facts:
            args += ['--reload-port='+str(facts['control_port'])]
        with log_path.open('w') as log:
            child = subprocess.Popen(args, cwd=project, env=env, stdout=log, stderr=log, start_new_session=True)
        def ready():
            assert child.poll() is None, log_path.read_text()
            if 'dev: watching:' not in log_path.read_text():
                return False
            return json.loads((project/'.zigbase/dev.json').read_text())
        facts = wait_for(ready, 'dev ready and watching')

    def stop():
        global child
        subprocess.run([BINARY, 'dev', 'stop'], cwd=project, env=env, check=True, capture_output=True)
        child.wait(timeout=10)
        for port in [facts['port'], facts['control_port']]:
            def closed():
                with socket.socket() as probe:
                    return probe.connect_ex(('127.0.0.1', port)) != 0
            wait_for(closed, f'port {port} released')
        child = None

    def status():
        with urllib.request.urlopen(f'http://127.0.0.1:{facts["control_port"]}/_zigapagos/status', timeout=2) as response:
            return json.load(response)['build']

    def first_frame(cursor):
        connection = http.client.HTTPConnection('127.0.0.1', facts['control_port'], timeout=3)
        try:
            connection.request('GET', '/', headers={'Last-Event-ID': cursor})
            response = connection.getresponse()
            assert response.status == 200
            fields = {}
            while True:
                line = response.readline().decode().rstrip('\r\n')
                if not line:
                    return fields
                if ': ' in line:
                    key, value = line.split(': ', 1)
                    fields[key] = value
        finally:
            connection.close()

    def edit(relative, contents, expected='ok'):
        previous = status()['generation']
        (project/relative).write_text(contents)
        def built():
            state = status()
            return state if state['generation'] > previous and not state['pending'] else None
        result = wait_for(built, f'{relative} rebuild')
        assert result['status'] == expected, (result, log_path.read_text())
        assert (result['error'] is None) == (expected == 'ok'), result
        return result

    try:
        launch()
        proxy = ReloadProxy(facts['control_port'])
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(channel='chrome')
            page = browser.new_page()
            errors = []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.add_init_script('''
                sessionStorage.loads = String(Number(sessionStorage.loads || 0) + 1);
                const NativeEventSource = window.EventSource;
                window.EventSource = class extends NativeEventSource {
                    constructor(url, options) {
                        super('http://127.0.0.1:PROXY/', options);
                        this.addEventListener('zigapagos-ready', event => {
                            window.devReady = true;
                            window.devCursor = event.lastEventId;
                        });
                        this.addEventListener('error', () => window.devDisconnected = true);
                    }
                };
            '''.replace('PROXY', str(proxy.server_address[1])))
            page.goto(facts['url'])

            def connected():
                page.wait_for_function('window.devReady === true')
                assert page.evaluate('window.devCursor'), 'initial connection has no cursor'

            def disconnect():
                page.evaluate('window.devReady = false; window.devDisconnected = false')
                proxy.disconnect()
                page.wait_for_function('window.devDisconnected === true')

            def reconnect():
                proxy.online.set()

            connected()
            content = (project/'content/index.smd').read_text()
            # No successful event yet: initial ready must already establish a cursor.
            old_cursor = page.evaluate('window.devCursor')
            disconnect()
            content += '\nFIRST-OFFLINE-EDIT\n'
            edit('content/index.smd', content)
            frame = first_frame(old_cursor)
            assert frame['data'] == 'reload' and 'event' not in frame, frame
            assert frame['id'] != old_cursor, frame
            # Never acknowledge a new cursor in a separate ready event before
            # its reload: disconnecting between them could lose that reload.
            reconnect()
            expect(page.get_by_text('FIRST-OFFLINE-EDIT', exact=True)).to_be_visible(timeout=15000)
            connected()

            # An invalid source must report failure without publishing a reload.
            loads = page.evaluate('sessionStorage.loads')
            invalid = content.replace('.layout = "page.shtml"', '.layout = "missing.shtml"')
            edit('content/index.smd', invalid, expected='failed')
            assert page.evaluate('sessionStorage.loads') == loads
            expect(page.get_by_text('FIRST-OFFLINE-EDIT', exact=True)).to_be_visible()
            content += '\nREPAIRED-EDIT\n'
            edit('content/index.smd', content)
            expect(page.get_by_text('REPAIRED-EDIT', exact=True)).to_be_visible(timeout=15000)
            connected()

            # Several missed builds contain independent HTML and CSS changes.
            disconnect()
            content += '\nSECOND-OFFLINE-EDIT\n'
            edit('content/index.smd', content)
            css = (project/'assets/style.css').read_text() + '\nbody { border-top: 7px solid rgb(12, 34, 56); }\n'
            edit('assets/style.css', css)
            layout = (project/'layouts/page.shtml').read_text().replace('<main>', '<main data-revision="third">')
            edit('layouts/page.shtml', layout)
            reconnect()
            expect(page.get_by_text('SECOND-OFFLINE-EDIT', exact=True)).to_be_visible(timeout=15000)
            expect(page.locator('main')).to_have_attribute('data-revision', 'third')
            expect(page.locator('body')).to_have_css('border-top-width', '7px')
            connected()

            # Reconnecting with the current cursor must not cause a reload loop.
            loads = page.evaluate('sessionStorage.loads')
            disconnect()
            reconnect()
            connected()
            page.wait_for_timeout(1500)  # Longer than the advertised retry interval.
            assert page.evaluate('sessionStorage.loads') == loads

            # Root config changes require restart. Keep the native stream alive
            # across one, proving a different session at generation zero is stale.
            disconnect()
            old_cursor = page.evaluate('window.devCursor')
            stop()
            config = project/'zigapagos.ziggy'
            config.write_text(config.read_text().replace('My site', 'Restarted site'))
            launch()
            frame = first_frame(old_cursor)
            assert frame['data'] == 'reload' and frame['id'] != old_cursor, frame
            reconnect()
            expect(page.get_by_role('link', name='Restarted site')).to_be_visible(timeout=15000)
            connected()
            assert page.evaluate('window.devCursor') != old_cursor
            loads = page.evaluate('sessionStorage.loads')
            page.wait_for_timeout(1500)
            assert page.evaluate('sessionStorage.loads') == loads
            assert not errors, errors
            browser.close()
        stop()
        print('PASS: initial cursor, failure/repair, missed HTML/CSS builds, reconnect stability, restart and teardown')
    except BaseException:
        print(log_path.read_text())
        raise
    finally:
        if proxy:
            proxy.disconnect()
            proxy.shutdown()
            proxy.server_close()
        if child and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait(timeout=10)
