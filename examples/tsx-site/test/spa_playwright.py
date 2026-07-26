import sys, threading, http.server, socketserver, functools, os
from playwright.sync_api import sync_playwright

root = sys.argv[1]  # zig-out/site


class SPAHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        fs = self.translate_path(self.path)
        if not os.path.exists(fs) and self.path.startswith("/app/"):
            # emulate the emitted try_files fallback
            self.path = "/app/club/_shell.html" if self.path.startswith("/app/club/") else "/app/index.html"
        return super().do_GET()


SPAHandler.extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".js": "text/javascript", ".mjs": "text/javascript"}
httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(SPAHandler, directory=root))
port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{port}"

with sync_playwright() as p:
    browser = p.chromium.launch(channel="chrome")
    page = browser.new_page()
    errors = []
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.route("**/favicon.ico", lambda r: r.fulfill(status=204))
    # stub ZigBase so the app boots without a backend
    page.route("**/api/**", lambda r: r.fulfill(status=200, content_type="application/json", body="{}"))

    # 1) Load the SPA index, prove it hydrates (the shell root gets Preact-managed content).
    page.goto(f"{base}/app/", wait_until="networkidle")
    page.wait_for_selector('[data-view="home"]')
    # clientInit: the browser entry called the module's clientInit
    # before the first render — its DOM marker is present (and note the raw
    # shell HTML never contains it: the SSR sidecar never calls clientInit;
    # spa_flags.sh asserts that half against the prerendered files).
    assert page.get_attribute("html", "data-client-init") == "ran", "clientInit did not run in the browser"
    # tag the live document to detect a full reload later
    page.evaluate("window.__spa_sentinel = 42")

    # 2) Soft-nav via a Link: URL changes, view swaps, NO full reload (sentinel survives).
    page.click('[data-nav="booking"]')
    # Baked flag defaults: bookAsGuest is declared default-ON in
    # spa.flags, so the flag-gated branch is on IMMEDIATELY (no /api answer —
    # the api stub returns {} — and no false-while-loading flash).
    page.wait_for_selector('[data-view="booking"][data-guest-booking="on"]')
    assert page.url == f"{base}/app/booking", f"expected soft-nav url, got {page.url}"
    assert page.evaluate("window.__spa_sentinel") == 42, "full reload happened during soft-nav"

    # 3) Soft-nav to a dynamic route renders the real component with the param.
    page.go_back()
    page.wait_for_selector('[data-view="home"]')
    page.click('[data-nav="club"]')
    page.wait_for_selector('[data-view="club"][data-id="42"]')
    assert page.evaluate("window.__spa_sentinel") == 42, "full reload during dynamic soft-nav"

    # 4) HARD refresh on a deep dynamic URL: server serves the pattern shell, client renders club 99.
    page.goto(f"{base}/app/club/99", wait_until="networkidle")
    page.wait_for_selector('[data-view="club"][data-id="99"]')

    # 5) Baked flag defaults survive a HARD load too: the booking
    # shell is prerendered with bookAsGuest ON and the client's first render
    # seeds from the data-z-flags snapshot, so the ON branch is there from the
    # first paint (the /api stub returns {} — no real flag state ever arrives).
    page.goto(f"{base}/app/booking", wait_until="networkidle")
    page.wait_for_selector('[data-view="booking"][data-guest-booking="on"]')
    assert page.query_selector("[data-guest-cta]") is not None, "flag-gated CTA missing after hard load"

    assert not errors, f"console/page errors: {errors}"
    browser.close()
    httpd.shutdown()
    print("PASS: SPA soft-nav + dynamic param + hard-refresh-on-dynamic")
