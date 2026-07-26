# Browser hydration proof for per-deployable runtime slicing.
#
# For each of the public / admin / fallback SPAs it: loads the shell, asserts the
# view hydrated (a hooks click increments the counter -> exactly ONE Preact on its
# own runtime), and asserts NO console/page errors. It also asserts each SPA
# loaded the RIGHT runtime: the public/admin SPAs their own sliced
# /spa/<name>-runtime.js, and the fallback SPA the shared /zigapagos-runtime.js
# (and never the other).
import sys, threading, http.server, socketserver, functools, os
from playwright.sync_api import sync_playwright

root = sys.argv[1]  # zig-out/site
BASES = ["public", "admin", "fallback", "compat"]


class SPAHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        fs = self.translate_path(self.path)
        if not os.path.exists(fs):
            for b in BASES:
                if self.path.startswith(f"/{b}/"):
                    self.path = f"/{b}/index.html"
                    break
        return super().do_GET()

    def log_message(self, *a):
        pass


SPAHandler.extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".js": "text/javascript", ".mjs": "text/javascript"}
httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(SPAHandler, directory=root))
port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{port}"

# Which runtime each SPA MUST load, and which it must NOT.
EXPECT = {
    "public": ("/spa/public-runtime.js", "/zigapagos-runtime.js"),
    "admin": ("/spa/admin-runtime.js", "/zigapagos-runtime.js"),
    "fallback": ("/zigapagos-runtime.js", "/spa/fallback-runtime.js"),
    # compat imports @z/runtime/compat -> must fall back to the shared runtime and
    # still hydrate (a sliced runtime would crash: no `memo` export).
    "compat": ("/zigapagos-runtime.js", "/spa/compat-runtime.js"),
}

with sync_playwright() as p:
    browser = p.chromium.launch(channel="chrome")
    for name in BASES:
        page = browser.new_page()
        errors, loaded = [], []
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("request", lambda r: loaded.append(r.url))
        page.route("**/favicon.ico", lambda r: r.fulfill(status=204))
        page.route("**/api/**", lambda r: r.fulfill(status=200, content_type="application/json", body="{}"))
        # admin's data-load button injects an external script; stub it so no real
        # network fetch is attempted during the test.
        page.route("**/admin-tool.js", lambda r: r.fulfill(status=200, content_type="text/javascript", body=""))

        page.goto(f"{base}/{name}/", wait_until="networkidle")
        page.wait_for_selector(f'[data-view="{name}"]')

        # Interactive hydration: the counter starts at 0 and a click makes it 1.
        # If Preact didn't hydrate (or two Preacts fought), this would not update.
        assert page.text_content("[data-count]") == "0", f"{name}: initial count not 0"
        page.click("[data-inc]")
        assert page.text_content("[data-count]") == "1", f"{name}: counter did not increment (no hydration / two Preacts)"

        must, must_not = EXPECT[name]
        assert any(must in u for u in loaded), f"{name}: did not load {must} (loaded: {loaded})"
        assert not any(must_not in u for u in loaded), f"{name}: unexpectedly loaded {must_not}"
        assert not errors, f"{name}: console/page errors: {errors}"
        print(f"PASS: {name} SPA hydrated on {must} (one Preact, no errors)")
        page.close()

    browser.close()
    httpd.shutdown()
    print("PASS: per-deployable sliced-runtime hydration (public + admin + fallback)")
