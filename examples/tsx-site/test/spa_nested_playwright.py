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
    page.route("**/api/**", lambda r: r.fulfill(status=200, content_type="application/json", body="{}"))

    # 1) HARD refresh on a deep nested child: the layout chrome + the child both
    #    render (the prerendered shell already contains both; it then hydrates).
    page.goto(f"{base}/app/dash/overview", wait_until="networkidle")
    page.wait_for_selector('[data-dash-chrome]')
    page.wait_for_selector('[data-view="dash-overview"]')

    # tag the live document to detect a full reload later
    page.evaluate("window.__spa_sentinel = 7")

    # 2) Mutate LAYOUT-scoped state: bump the layout's counter to 2.
    page.click('[data-dash-inc]')
    page.click('[data-dash-inc]')
    assert page.text_content('[data-dash-count]') == "2", "layout counter did not update"

    # 3) Soft-nav to the SIBLING child via a Link inside the layout.
    page.click('[data-nav="to-settings"]')
    page.wait_for_selector('[data-view="dash-settings"]')
    assert page.url == f"{base}/app/dash/settings", f"expected soft-nav url, got {page.url}"

    # 3a) NO full reload happened.
    assert page.evaluate("window.__spa_sentinel") == 7, "full reload happened during sibling soft-nav"
    # 3b) The Outlet content swapped: overview gone, settings present.
    assert page.query_selector('[data-view="dash-overview"]') is None, "sibling overview still mounted after nav"
    # 3c) The LAYOUT stayed mounted: chrome persists AND its counter state survived (== 2).
    assert page.query_selector('[data-dash-chrome]') is not None, "layout chrome unmounted on sibling nav"
    assert page.text_content('[data-dash-count]') == "2", "layout state was RESET — the layout was remounted (should persist)"

    # 4) Soft-nav back to overview: still no reload, layout state still 2.
    page.click('[data-nav="to-overview"]')
    page.wait_for_selector('[data-view="dash-overview"]')
    assert page.evaluate("window.__spa_sentinel") == 7, "full reload during nav back"
    assert page.text_content('[data-dash-count]') == "2", "layout state lost navigating back"

    assert not errors, f"console/page errors: {errors}"
    browser.close()
    httpd.shutdown()
    print("PASS: nested hard-refresh renders layout+child; sibling soft-nav keeps the layout mounted (state persists, only Outlet swaps)")
