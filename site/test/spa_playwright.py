"""The embedded demo SPA routes on the client without a page load.

THE load-bearing assertion in this file is the soft-nav check below: the URL
must change AND the document must not reload. Checking only that the
destination content appears is not enough — that passes just as well on a
full page load, which is exactly the failure mode the SPA demo shipped with
and needed two review rounds to fix. `window.__zp_marker` is the tell: a real
navigation tears down the JS heap and takes it with it, a soft one does not.
"""
import sys
from playwright.sync_api import sync_playwright

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080/zigapagos"


def main() -> int:
    with sync_playwright() as p:
        # channel="chrome": the only browser browser-e2e.yml's install step
        # provides (see that workflow's "THE BROWSER" comment) — the bundled
        # Chromium build isn't installed, so a bare chromium.launch() dies at
        # launch, after the consumer build has already been paid for.
        browser = p.chromium.launch(channel="chrome")
        page = browser.new_page()
        errors = []
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.route("**/favicon.ico", lambda route: route.fulfill(status=204))

        page.goto(f"{BASE}/demos/app/", wait_until="networkidle")
        page.wait_for_selector("nav.spa-nav")

        # Mark the document. A real navigation discards it; a soft one does not.
        page.evaluate("() => { window.__zp_marker = 'alive'; }")

        # The nav's <a href> is a KNOWN, disclosed product gap: @z/runtime's
        # Router doesn't thread url_path_prefix into Link's href, so the
        # rendered attribute is base-relative ("/demos/app/guides"), not
        # prefixed ("/zigapagos/demos/app/guides") — see demo/app.spa.tsx's
        # "KNOWN LIMITATION" comment and site/test/build.sh's matching
        # assertion. Do NOT match on the full prefixed href here; matching on
        # the suffix is what actually exists in the DOM, and it's the click
        # handler (not the attribute) that resolves the real destination.
        page.click('a[href$="/demos/app/guides"]')
        page.wait_for_function(
            "() => location.pathname.endsWith('/demos/app/guides')", timeout=3000
        )

        if "/demos/app/guides" not in page.url:
            print(f"FAIL: URL did not change on navigation (got {page.url})")
            return 1
        if page.evaluate("() => window.__zp_marker") != "alive":
            print("FAIL: navigation reloaded the document — not a soft nav")
            return 1

        # The guarded route redirects an anonymous visitor. Re-stamp the
        # marker: a fresh navigation must not carry the OLD stamp forward
        # by accident (it wouldn't — evaluate() ran against the live page,
        # but stamping again keeps this check self-contained if the guides
        # click above is ever reordered or removed).
        page.evaluate("() => { window.__zp_marker = 'still-alive'; }")
        page.click('a[href$="/demos/app/account"]')
        page.wait_for_function(
            "() => location.pathname.endsWith('/denied')", timeout=3000
        )
        if "/denied" not in page.url:
            print(f"FAIL: guard did not redirect anonymous visitor (at {page.url})")
            return 1
        if page.evaluate("() => window.__zp_marker") != "still-alive":
            print("FAIL: guard redirect reloaded the document — not a soft nav")
            return 1

        if errors:
            print(f"FAIL: console/page errors: {errors}")
            return 1

        browser.close()
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
