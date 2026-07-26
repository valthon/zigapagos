import sys, http.server, socketserver, threading, functools, os
from playwright.sync_api import sync_playwright

def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
    handler.extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".js": "text/javascript", ".mjs": "text/javascript"}
    httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, f"http://127.0.0.1:{httpd.server_address[1]}/"

def main():
    target = sys.argv[1]
    httpd, base = (serve(target) if os.path.isdir(target) else (None, target))
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        page = browser.new_page()
        errors = []
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))
        # Suppress favicon 404 (browser logs it as a console error; it is not our asset).
        page.route("**/favicon.ico", lambda route: route.fulfill(status=204))
        # Stub the flags API so FlagsProvider in Flagged.island.tsx does not 404.
        page.route("**/api/flags/state", lambda route: route.fulfill(
            status=200,
            content_type="application/json",
            body=b'{"flags":{},"experiments":{}}',
        ))
        page.goto(base, wait_until="networkidle")
        # Hydration completed:
        page.wait_for_selector("[data-z-island][data-z-hydrated]", timeout=5000)
        btn = page.query_selector("[data-z-island] button")
        assert btn is not None, "island button not found"
        assert btn.inner_text().strip() == "+", f"pre-click label: {btn.inner_text()!r}"
        btn.click()
        page.wait_for_function("document.querySelector('[data-z-island] button').innerText.trim() === '−'", timeout=2000)
        assert not errors, f"console/page errors: {errors}"
        print("PASS: TSX island hydrated + interactive (+ -> minus on click)")

        # ── Panel composite island: slot DOM + nested island e2e proof ───────────────
        # Wait for the Panel island itself to be hydrated.
        page.wait_for_selector(
            "[data-z-island][data-z-hydrated][data-z-src='components/Panel.island.tsx']",
            timeout=5000,
        )
        # (a) Heading named slot: the <z-slot data-z-slot="heading"> wrapper must be present
        #     inside <header> with the expected content.
        heading_slot = page.query_selector("z-slot[data-z-slot='heading']")
        assert heading_slot is not None, "Panel heading slot (<z-slot data-z-slot='heading'>) not in DOM after hydrate"
        heading_text = heading_slot.inner_text().strip()
        assert "Custom Heading" in heading_text, f"Panel heading slot text wrong: {heading_text!r}"

        # (b) Default slot body text is present inside .panel-body.
        panel_body = page.query_selector("section.panel .panel-body")
        assert panel_body is not None, "Panel .panel-body missing from DOM"
        body_text = panel_body.inner_text()
        assert "default body" in body_text, f"Panel body text missing: {body_text!r}"

        # (c) Nested Hero island inside the Panel's slot is hydrated.
        # The nested island is inside section.panel — different from the top-level Hero.
        page.wait_for_selector(
            "section.panel [data-z-island][data-z-hydrated][data-z-src='components/Hero.island.tsx']",
            timeout=5000,
        )
        nested_btn = page.query_selector(
            "section.panel [data-z-island][data-z-src='components/Hero.island.tsx'] button"
        )
        assert nested_btn is not None, "Nested Hero button inside Panel slot not found after hydrate"
        assert nested_btn.inner_text().strip() == "+", f"Nested Hero pre-click: {nested_btn.inner_text()!r}"

        # (d) THE KEY PROOF: click the nested island's button — proves the adopt-hydration
        #     did not clobber the nested island's event handlers or Preact component state.
        nested_btn.click()
        page.wait_for_function(
            "document.querySelector(\"section.panel [data-z-island] button\").innerText.trim() === '−'",
            timeout=2000,
        )
        nested_btn_after = page.query_selector("section.panel [data-z-island] button")
        assert nested_btn_after is not None and nested_btn_after.inner_text().strip() == "−", \
            f"Nested Hero did not toggle: {nested_btn_after and nested_btn_after.inner_text()!r}"

        # (e) No console errors / hydration warnings (checked last to capture all async errors).
        assert not errors, f"console/page errors after Panel hydrate: {errors}"
        print("PASS: Panel slot DOM present + nested island interactive after adopt-hydration (no console errors)")

        # ── npm-compat bridge: THE ONE-PREACT PROOF ─────────────────────────────────
        # Widget.island renders a component from @demo/widget, whose `useState` is
        # imported from the bare `react` specifier. The client bundle kept `react`
        # external; the page import-map resolves it to the shared runtime. If a SECOND
        # Preact were loaded, this hook would throw / not update (hook dispatcher
        # mismatch) — so an interactive click that increments the counter proves ONE
        # shared Preact drives the npm component too.
        page.wait_for_selector(
            "[data-z-island][data-z-hydrated][data-z-src='components/Widget.island.tsx']",
            timeout=5000,
        )
        widget_btn = page.query_selector(
            "[data-z-src='components/Widget.island.tsx'] button[data-widget]"
        )
        assert widget_btn is not None, "npm-compat Widget button not found after hydrate"
        assert widget_btn.inner_text().strip() == "Clicks: 0", f"Widget pre-click: {widget_btn.inner_text()!r}"
        widget_btn.click()
        page.wait_for_function(
            "document.querySelector(\"[data-z-src='components/Widget.island.tsx'] button[data-widget]\").innerText.trim() === 'Clicks: 1'",
            timeout=2000,
        )
        assert not errors, f"console/page errors after npm-compat Widget hydrate: {errors}"
        print("PASS: npm-compat Widget (react->@z/runtime/compat) hydrated + interactive on ONE Preact")
        browser.close()
    if httpd: httpd.shutdown()

main()
