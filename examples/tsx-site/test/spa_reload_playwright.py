import sys, threading, http.server, socketserver, functools, os
from playwright.sync_api import sync_playwright

root = sys.argv[1]  # zig-out/site


class SPAHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        fs = self.translate_path(self.path)
        if not os.path.exists(fs) and self.path.startswith("/app/"):
            self.path = "/app/club/_shell.html" if self.path.startswith("/app/club/") else "/app/index.html"
        return super().do_GET()


SPAHandler.extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".js": "text/javascript", ".mjs": "text/javascript"}
httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(SPAHandler, directory=root))
port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{port}"

# State-preserving dev reload, real-pixel proof:
#   1. Type into a useRestorableState-backed field on /app/wizard.
#   2. Fire the dev client's `zigapagos:beforereload` event (persists the value to
#      sessionStorage) then reload the page — the value is RESTORED after the SPA
#      re-hydrates, and the route (URL) is unchanged.
#   3. Reload AGAIN WITHOUT firing beforereload — the field is back to its
#      initial value, proving the restore is one-shot (no stale persistence).

FIELD = '[data-restore-field]'
TYPED = "Ada Lovelace"

with sync_playwright() as p:
    browser = p.chromium.launch(channel="chrome")
    page = browser.new_page()
    errors = []
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.route("**/favicon.ico", lambda r: r.fulfill(status=204))

    page.goto(f"{base}/app/wizard", wait_until="networkidle")
    page.wait_for_selector('[data-view="wizard"]')

    # Type a value into the restorable field (fires input → onInput → setState).
    page.fill(FIELD, TYPED)
    assert page.input_value(FIELD) == TYPED, f"pre-reload field: {page.input_value(FIELD)!r}"

    # Simulate the dev client: dispatch beforereload (listener stashes the value),
    # then reload. sessionStorage + the URL both survive the reload.
    page.evaluate("window.dispatchEvent(new CustomEvent('zigapagos:beforereload'))")
    page.reload(wait_until="networkidle")
    page.wait_for_selector('[data-view="wizard"]')

    restored = page.input_value(FIELD)
    assert restored == TYPED, f"FAIL: field not restored after reload: {restored!r}"
    # Route preserved (the static server's directory redirect adds a trailing
    # slash on the initial load; normalize it out).
    path = page.evaluate("location.pathname").rstrip("/")
    assert path == "/app/wizard", f"FAIL: route changed across reload: {path!r}"
    print("PASS: field value restored across a simulated dev reload + route preserved")

    # Second reload WITHOUT a prior beforereload → the restore was one-shot, so
    # the persisted value was consumed on the first restore and nothing new was
    # written. The field falls back to its initial (empty) value.
    page.reload(wait_until="networkidle")
    page.wait_for_selector('[data-view="wizard"]')
    after = page.input_value(FIELD)
    assert after == "", f"FAIL: field not reset on second reload (stale persistence): {after!r}"
    print("PASS: one-shot restore — second reload without beforereload shows the initial value")

    assert not errors, f"console/page errors: {errors}"
    browser.close()
    httpd.shutdown()
    print("PASS: state-preserving reload — restore-on-reload + one-shot + route preserved")
