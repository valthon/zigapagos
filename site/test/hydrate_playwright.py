"""Landing-page islands actually hydrate in a real browser.

The build gate proves an island was server-rendered. Only a browser proves it
woke up — the failure mode this catches is a page whose HTML looks correct and
whose buttons do nothing.

Modelled on examples/tsx-site/test/hydrate_playwright.py: same
`data-z-island`/`data-z-hydrated` markers, same `channel="chrome"` launch (the
only browser browser-e2e.yml's install step provides — see that workflow's
"THE BROWSER" comment), same console/page-error capture.
"""
import sys
from playwright.sync_api import sync_playwright

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080/zigapagos"


def main() -> int:
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        page = browser.new_page()
        errors = []
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.route("**/favicon.ico", lambda route: route.fulfill(status=204))

        # ── Landing page: the Counter island is itself client:visible ──────
        page.goto(f"{BASE}/", wait_until="networkidle")
        counter = page.locator("button.demo-counter").first
        counter.scroll_into_view_if_needed()
        # Wait for the actual hydration marker (see runtime/src/islands.ts's
        # bootIsland, which sets this empty-string attribute right after
        # Preact's hydrate() call) rather than a fixed sleep — deterministic,
        # and it fails fast instead of racing a timeout against a slow CI box.
        page.wait_for_selector(
            '[data-z-island][data-z-client="visible"][data-z-hydrated] button.demo-counter',
            timeout=5000,
        )
        before = counter.inner_text()
        counter.click()
        # Pass `before` as an argument rather than interpolating it into the
        # JS source — the label text contains an em dash, and a future label
        # change (an apostrophe, say) would otherwise break the generated
        # expression instead of the assertion it's meant to check.
        page.wait_for_function(
            "(prev) => document.querySelector('button.demo-counter').innerText !== prev",
            arg=before,
            timeout=2000,
        )
        after = counter.inner_text()
        if before == after or "Clicked 1 time" not in after:
            print(f"FAIL: counter island did not hydrate (before={before!r} after={after!r})")
            return 1

        # ── Directive demo: five identical components, five directives ────
        page.goto(f"{BASE}/demos/directives/", wait_until="networkidle")

        page.wait_for_selector('[data-directive="client:load"].dd-on', timeout=3000)

        # THE NEGATIVE: client:visible must NOT have hydrated yet. It sits
        # below a deliberate 60vh spacer (assets/style.css's .dd-spacer) so a
        # default viewport never scrolls it into view on load — without this
        # check, a broken IntersectionObserver that hydrates everything
        # immediately (e.g. one instantiated with no element, or replaced by
        # an eager fallback) would still pass every OTHER assertion here.
        visible_card = page.locator('[data-directive="client:visible"]').first
        if "dd-on" in (visible_card.get_attribute("class") or ""):
            print("FAIL: client:visible hydrated before being scrolled into view")
            return 1

        visible_card.scroll_into_view_if_needed()
        page.wait_for_selector('[data-directive="client:visible"].dd-on', timeout=3000)

        if errors:
            print(f"FAIL: console/page errors: {errors}")
            return 1

        browser.close()
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
