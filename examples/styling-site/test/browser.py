"""Run against an already built directory; CI also runs the release checks."""
import functools
import http.server
import sys
import threading
from playwright.sync_api import sync_playwright, expect

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(
    ('127.0.0.1', 0), functools.partial(Quiet, directory=sys.argv[1]))
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
try:
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel='chrome')
        for width in [320, 1280]:
            for route in ['/', '/framework/', '/components/']:
                page = browser.new_page(viewport={'width': width, 'height': 900})
                errors, responses, failed = [], [], []
                page.on('pageerror', lambda error: errors.append(str(error)))
                page.on('response', lambda response: responses.append(response))
                page.on('requestfailed', lambda request: failed.append(request.url))
                page.route('**/favicon.ico', lambda route: route.fulfill(status=204))
                assert page.goto(base + route, wait_until='networkidle').status == 200
                assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
                if route == '/':
                    expect(page.locator('.plain-proof')).to_have_css('border-left-width', '4px')
                    expect(page.locator('nav a').first).to_have_css('color', 'rgb(17, 94, 89)')
                elif route == '/framework/':
                    expect(page.locator('[data-framework]')).to_have_css('padding-top', '24px')
                    expect(page.locator('[data-framework]')).to_have_css('border-top-left-radius', '12px')
                else:
                    page.wait_for_selector('[data-z-hydrated]')
                    button = page.get_by_role('button', name='Save preference')
                    expect(button).to_have_css('background-color', 'rgb(17, 94, 89)')
                    expect(page.locator('.card')).to_have_css('border-top-left-radius', '16px')
                    page.evaluate("document.fonts.load('32px DemoSymbols', '𝒜')")
                    assert page.evaluate("document.fonts.check('32px DemoSymbols', '𝒜')")
                    button.focus()
                    page.keyboard.press('Space')
                    expect(button).to_have_attribute('aria-pressed', 'true')
                    expect(page.get_by_role('status')).to_have_text('Preference saved')
                    button.click()
                    expect(page.get_by_role('status')).to_have_text('No preference saved')
                    fetched = [response.url for response in responses]
                    assert any(url.endswith('/fonts/Temml.woff2') for url in fetched), fetched
                    assert any(url.endswith('/images/grid.svg') for url in fetched), fetched
                if route != '/components/':
                    assert page.locator('script').count() == 0
                    assert not [r for r in responses if r.request.resource_type == 'script']
                assert not failed, failed
                assert not errors, errors
                assert not [r.url for r in responses if r.status >= 400]
                page.close()
                print(f'PASS: {route} at {width}px, styles/assets and interaction verified')
        browser.close()
finally:
    server.shutdown()
    server.server_close()
