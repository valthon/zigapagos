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

# Prove per-route code splitting end-to-end: a hard refresh on the lazy /heavy
# route serves a skeleton shell, the browser fetches the Heavy chunk SEPARATELY,
# and the real content then appears — while the entry bundle never contains the
# heavy view's marker.

with sync_playwright() as p:
    browser = p.chromium.launch(channel="chrome")
    page = browser.new_page()
    errors, chunk_requests = [], []
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("request", lambda r: chunk_requests.append(r.url) if "/spa/Heavy-" in r.url else None)
    page.route("**/favicon.ico", lambda r: r.fulfill(status=204))

    # Hard refresh the lazy route. The prerendered shell is the skeleton; the
    # chunk loads post-hydration and the real content replaces it.
    page.goto(f"{base}/app/heavy", wait_until="networkidle")
    page.wait_for_selector('[data-heavy="loaded"]')  # the chunk loaded → real view
    assert "HEAVY-CHUNK-MARKER" in page.content(), "heavy content missing after chunk load"

    # The Heavy chunk was fetched as its OWN network request (a separate chunk).
    assert any("/spa/Heavy-" in u for u in chunk_requests), f"no separate Heavy chunk request: {chunk_requests}"

    # The ENTRY bundle does NOT contain the heavy view's marker (proves the split
    # at runtime, not just on disk).
    entry = page.evaluate("async () => (await fetch('/spa/app.js')).text()")
    assert "HEAVY-CHUNK-MARKER" not in entry, "heavy code is in the entry bundle (split failed)"

    assert not errors, f"console/page errors: {errors}"
    browser.close()
    httpd.shutdown()
    print("PASS: per-route code splitting — separate chunk fetched, real content loads, entry bundle clean")
