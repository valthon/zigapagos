#!/usr/bin/env python3
"""Strict-CSP acceptance: a strict-CSP deployment (no unsafe-inline) serves the
hydrated SPA + island pages with ZERO Content-Security-Policy violations.

This is the REQUIRED proof for the emitter: the unit test asserts the hashes are
computed correctly, but only a real browser enforcing the emitted header proves
the hash is byte-exact against the served inline script. So:

  1. CLEAN rebuild (rm -rf .zig-cache zig-out) — the stale-bundle footgun means a
     source-only rebuild can serve OLD html/bundle and hash the wrong bytes.
  2. `zig build` runs emit-host-config.ts, writing csp.nginx.conf at the site root.
  3. Parse the emitted `Content-Security-Policy` value out of csp.nginx.conf.
  4. Serve zig-out/site with the SPA try_files fallback AND that exact CSP header
     on every response.
  5. In real Chrome, register a `securitypolicyviolation` listener BEFORE any
     script runs, load a SPA route (/app/) and an island page (/), and assert
     zero violations while the SPA hydrates + soft-navigates.

Run: <venv-python> test/spa_csp_playwright.py     (from examples/tsx-site/)
"""
import os, re, subprocess, sys, threading, http.server, socketserver, functools
from playwright.sync_api import sync_playwright

EXAMPLE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(EXAMPLE))
OUT = os.path.join(EXAMPLE, "zig-out", "site")


def sh(cmd, cwd=EXAMPLE):
    print(f"+ {cmd}", flush=True)
    subprocess.run(cmd, cwd=cwd, shell=True, check=True)


def restore_snapshots():
    # Any root `zig build` can delete tests/**/snapshot — restore them.
    subprocess.run(
        "git ls-files --deleted -z -- tests/ | xargs -0 -I{} git restore -- {}",
        cwd=REPO, shell=True, check=False,
    )


def clean_rebuild():
    # STALE-BUNDLE footgun: wipe caches so the served html + runtime bundle are
    # rebuilt from source and the hashed bytes match what's served.
    sh("rm -rf .zig-cache zig-out")
    sh("(cd ../../runtime && mise exec -- bun install)")
    sh("mise exec -- bun install")
    try:
        sh("mise exec -- zig build")
    finally:
        restore_snapshots()


def read_csp_header():
    # Prefer the header emitted by the build; fall back to running the emitter.
    path = os.path.join(OUT, "csp.nginx.conf")
    if not os.path.exists(path):
        sh(f"mise exec -- bun ../../runtime/scripts/emit-host-config.ts --site {OUT}")
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    m = re.search(r'Content-Security-Policy\s+"([^"]*)"', text)
    if not m:
        sys.exit(f"FAIL: no Content-Security-Policy value in {path}\n{text}")
    return m.group(1)


class CSPHandler(http.server.SimpleHTTPRequestHandler):
    csp = ""  # set per-run

    def end_headers(self):
        self.send_header("Content-Security-Policy", self.csp)
        super().end_headers()

    def do_GET(self):
        fs = self.translate_path(self.path)
        if not os.path.exists(fs) and self.path.startswith("/app/"):
            # emulate the emitted nginx try_files fallback
            self.path = "/app/club/_shell.html" if self.path.startswith("/app/club/") else "/app/index.html"
        return super().do_GET()


CSPHandler.extensions_map = {
    **http.server.SimpleHTTPRequestHandler.extensions_map,
    ".js": "text/javascript", ".mjs": "text/javascript",
}

# Registered before ANY page script so it catches every violation from first byte.
VIOLATION_LISTENER = """
window.__csp = [];
document.addEventListener('securitypolicyviolation', e => {
  window.__csp.push({ directive: e.violatedDirective, blocked: e.blockedURI, sample: e.sample });
});
"""


def main():
    clean_rebuild()
    csp = read_csp_header()
    print(f"\nEmitted Content-Security-Policy:\n  {csp}\n", flush=True)
    if "unsafe-inline" in csp.split("style-src")[0]:  # script side must be strict
        sys.exit("FAIL: script-src carries unsafe-inline — not a strict CSP")

    CSPHandler.csp = csp
    httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(CSPHandler, directory=OUT))
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{port}"

    all_violations = []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        ctx = browser.new_context()
        ctx.add_init_script(VIOLATION_LISTENER)
        page = ctx.new_page()
        page.route("**/favicon.ico", lambda r: r.fulfill(status=204))
        page.route("**/api/**", lambda r: r.fulfill(status=200, content_type="application/json", body="{}"))

        # ── SPA route: must hydrate + soft-nav under strict CSP with zero violations.
        page.goto(f"{base}/app/", wait_until="networkidle")
        page.wait_for_selector('[data-view="home"]')  # SSR skeleton + hydration
        page.evaluate("window.__spa_sentinel = 42")
        page.click('[data-nav="booking"]')
        page.wait_for_selector('[data-view="booking"]')
        assert page.url == f"{base}/app/booking", f"expected soft-nav url, got {page.url}"
        assert page.evaluate("window.__spa_sentinel") == 42, "full reload during soft-nav (SPA not interactive)"
        spa_v = page.evaluate("window.__csp")
        all_violations += [("/app/", v) for v in spa_v]

        # ── Island page: inline importmap must load; zero violations.
        page.goto(f"{base}/", wait_until="networkidle")
        page.wait_for_selector("section h1")  # island SSR content present
        island_v = page.evaluate("window.__csp")
        all_violations += [("/", v) for v in island_v]

        browser.close()
    httpd.shutdown()

    script_violations = [(pg, v) for (pg, v) in all_violations if v["directive"].startswith("script")]
    print("CSP violations observed:")
    if all_violations:
        for pg, v in all_violations:
            print(f"  [{pg}] {v['directive']}  blocked={v['blocked']}  sample={v.get('sample','')}")
    else:
        print("  (none)")

    if script_violations:
        sys.exit(f"\nFAIL: {len(script_violations)} script-src CSP violation(s) — inline-script hash is WRONG")
    if all_violations:
        sys.exit(f"\nFAIL: {len(all_violations)} non-script CSP violation(s) under the emitted header")

    print("\nPASS: strict-CSP SPA hydrate + soft-nav + island page — ZERO CSP violations")


if __name__ == "__main__":
    main()
