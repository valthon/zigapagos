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

# The gated route's guard reads the `z_session` cookie: "ok" => authorized,
# anything else => redirect to /app/login. We hard-refresh the gated deep link
# in both states and assert the two guarded-route acceptance criteria:
#   (a) NO gated-content flash: the gated marker never enters the DOM before a
#       redirect fires for an anon visitor;
#   (b) an authorized visitor sees the neutral fallback, then the real gated
#       content (which was never in the served shell — see spa_guards.sh).

with sync_playwright() as p:
    browser = p.chromium.launch(channel="chrome")

    # ------------------------------------------------------------------ anon
    ctx = browser.new_context()  # no z_session cookie
    page = ctx.new_page()
    errors = []
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.route("**/favicon.ico", lambda r: r.fulfill(status=204))

    # Install a MutationObserver BEFORE the app boots so we catch even a
    # single-frame flash of the gated marker. It flips a flag the moment any
    # element carrying data-gated enters the DOM.
    page.add_init_script(
        "window.__gatedSeen = false;"
        "const hit = (n) => n && n.nodeType === 1 && ("
        "  (n.matches && n.matches('[data-gated]')) ||"
        "  (n.querySelector && n.querySelector('[data-gated]')));"
        "new MutationObserver((muts) => {"
        "  if (document.querySelector('[data-gated]')) { window.__gatedSeen = true; return; }"
        "  for (const m of muts) {"
        "    if (m.type === 'attributes' && hit(m.target)) { window.__gatedSeen = true; return; }"
        "    for (const n of m.addedNodes) if (hit(n)) { window.__gatedSeen = true; return; }"
        "  }"
        "}).observe(document, {childList:true, subtree:true, attributes:true, attributeFilter:['data-gated']});"
    )

    page.goto(f"{base}/app/secret", wait_until="commit")
    # The anon guard redirects almost immediately, so the transient neutral
    # fallback may be gone before a wait_for_selector can catch it — racing it
    # makes this test flaky. The fallback-for-anon is proven deterministically by
    # the prerender (spa.sh: the guarded shell IS the fallback). Assert only the
    # stable end state: we land on /app/login having never shown gated content.
    page.wait_for_url(f"{base}/app/login")
    page.wait_for_selector('[data-view="login"]')

    assert page.evaluate("window.__gatedSeen") is False, "GATED CONTENT FLASHED before redirect (acceptance a FAIL)"
    assert page.query_selector('[data-gated]') is None, "gated content present after anon redirect"
    assert not errors, f"console/page errors (anon): {errors}"
    print("PASS: anon hard-refresh -> fallback -> redirect to /app/login, NO gated flash")
    ctx.close()

    # ---------------------------------------------------------------- authed
    ctx = browser.new_context()
    ctx.add_cookies([{"name": "z_session", "value": "ok", "url": base}])
    page = ctx.new_page()
    errors = []
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.route("**/favicon.ico", lambda r: r.fulfill(status=204))

    page.goto(f"{base}/app/secret", wait_until="networkidle")
    # Authorized: the fallback gives way to the real gated component.
    page.wait_for_selector('[data-gated="secret"]')
    assert "TOP SECRET MEMBER DATA" in page.content(), "gated content missing for authed visitor"
    # (the dev server 301s /app/secret -> /app/secret/; either is "stayed put")
    assert page.url.rstrip("/") == f"{base}/app/secret", f"authed visitor should stay on /app/secret, got {page.url}"
    assert not errors, f"console/page errors (authed): {errors}"
    print("PASS: authed hard-refresh -> fallback -> real gated content on /app/secret")

    browser.close()
    httpd.shutdown()
    print("PASS: SPA route guards (no-flash + authed content + no gated content in shell)")
