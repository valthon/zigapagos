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

# Bonus real-pixel proof of scroll restoration: PUSH nav scrolls to top; BACK
# (popstate) restores the position saved for that history entry. A tall spacer
# is appended to <body> (outside #z-spa-root, so it survives soft-nav) to keep
# the document scrollable on every view — otherwise a short target page would
# read scrollY 0 for the wrong reason.

with sync_playwright() as p:
    browser = p.chromium.launch(channel="chrome")
    page = browser.new_page(viewport={"width": 800, "height": 600})
    errors = []
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.route("**/favicon.ico", lambda r: r.fulfill(status=204))

    page.goto(f"{base}/app/", wait_until="networkidle")
    page.wait_for_selector('[data-view="home"]')
    # Make the document tall on every view (persists across soft-nav).
    page.evaluate("document.body.insertAdjacentHTML('beforeend', '<div id=spacer style=\"height:3000px\"></div>')")

    # Scroll down on Home, then PUSH-navigate to Booking → should land at top.
    # NB: use an in-page element.click() (NOT page.click, which auto-scrolls the
    # off-screen link into view first and would move scrollY before navigate reads it).
    page.evaluate("window.scrollTo(0, 600)")
    page.wait_for_function("window.scrollY === 600")
    page.eval_on_selector('[data-nav="booking"]', "el => el.click()")
    page.wait_for_selector('[data-view="booking"]')
    page.wait_for_function("window.scrollY === 0")  # PUSH → scrolled to top
    print("PASS: push nav scrolls to top")

    # Scroll on Booking, then BACK (popstate) to Home → restore Home's 600.
    page.evaluate("window.scrollTo(0, 250)")
    page.wait_for_function("window.scrollY === 250")
    page.go_back()
    page.wait_for_selector('[data-view="home"]')
    page.wait_for_function("window.scrollY === 600")  # POP → restored saved position
    print("PASS: back/forward restores the saved per-entry scroll position")

    # Forward again to Booking → restore Booking's 250 (its saved position).
    page.go_forward()
    page.wait_for_selector('[data-view="booking"]')
    page.wait_for_function("window.scrollY === 250")
    print("PASS: forward restores the other entry's saved position")

    assert not errors, f"console/page errors: {errors}"
    browser.close()
    httpd.shutdown()
    print("PASS: scroll restoration — push-to-top + per-history-entry save/restore")
