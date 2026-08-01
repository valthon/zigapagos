#!/usr/bin/env python3
"""Rasterise site/assets/og.svg -> site/assets/og.png, and stamp the pair.

    python3 site/scripts/rasterise-og.py

WHY THIS EXISTS (#44). og.png is a DERIVED file with a hand-authored source
(og.svg) and no build step: `zig build` copies both through the asset installer
untouched, because rasterising is not something the generator does. Before this
script the rasteriser was not recorded anywhere, so editing the SVG left the PNG
-- the file every social scraper actually fetches, see base.shtml's og:image --
silently showing the previous artwork. Nothing in the repository could notice.

WHY A BROWSER, and not resvg / rsvg-convert / inkscape. og.svg's two text
stacks are `system-ui, sans-serif` and `ui-monospace, monospace`. Those are CSS
system-font KEYWORDS, not font names: resolving them is a browser feature, and
the standalone SVG rasterisers do not implement them -- they fall through to
their own default family, which is how the previously committed og.png ended up
rendering the monospace tagline in a proportional face. A browser resolves them
the same way the site's own --font-sans/--font-mono tokens do (site/assets/
tokens.css), so the card matches the site it advertises. Playwright + a
`channel="chrome"` launch is also already this repository's browser convention:
every *_playwright.py helper under site/test/ and examples/tsx-site/test/
launches exactly that way, and .github/workflows/browser-e2e.yml already
installs it.

WHAT REPRODUCIBILITY IS AND IS NOT CLAIMED. Re-running this does not promise
byte-identical output: glyph rasterisation depends on the fonts installed on the
machine and on the Chrome build. That is why the freshness gate in
site/test/build.sh stamps the hash of the SOURCE (og.svg) rather than diffing
the PNG -- a byte comparison would be red on every machine but the last one to
run this, which is a gate nobody would keep.

The stamp is written HERE, by the same command that writes the PNG, on purpose:
a two-step "regenerate, then remember to refresh the stamp" convention has an
obvious failure mode where someone does the first half and the gate goes quiet
about a genuinely stale PNG.

Requires: pip install playwright && playwright install chrome
"""

from __future__ import annotations

import hashlib
import pathlib
import struct
import sys

HERE = pathlib.Path(__file__).resolve().parent
ASSETS = HERE.parent / "assets"
SVG = ASSETS / "og.svg"
PNG = ASSETS / "og.png"
# Beside this script rather than beside the SVG, deliberately: assets/ is a
# PUBLISHED directory, and the generator warns about every file in it that no
# page references ("1 asset(s) ... were not installed"). The stamp is build
# bookkeeping, not artwork — putting it here keeps that warning honest and
# keeps an internal content hash off the public site.
STAMP = HERE / "og.svg.sha256"

# The Open Graph card size every scraper crops against (1.91:1). It is also
# declared on the <svg> element itself as width/height and as the viewBox
# extent, so a mismatch here means one of the two moved without the other.
WIDTH = 1200
HEIGHT = 630


def png_dimensions(path: pathlib.Path) -> tuple[int, int, int]:
    """Read (width, height, colour_type) straight out of the PNG's IHDR.

    Stdlib only, deliberately: adding Pillow to make one assertion about
    thirteen bytes would put a second imaging dependency in front of anyone
    regenerating this asset.
    """
    raw = path.read_bytes()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    # Length(4) Type(4), then IHDR's payload: width, height, bit depth, colour type.
    width, height = struct.unpack(">II", raw[16:24])
    colour_type = raw[25]
    return width, height, colour_type


def main() -> int:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print(
            "FAIL: playwright is not importable.\n"
            "  python3 -m venv .venv && .venv/bin/pip install playwright\n"
            "  .venv/bin/playwright install chrome",
            file=sys.stderr,
        )
        return 1

    with sync_playwright() as p:
        # channel="chrome", not the bundled Chromium: see the module docstring,
        # and browser-e2e.yml's "THE BROWSER" comment for the same choice made
        # for the same reason.
        browser = p.chromium.launch(channel="chrome")
        # device_scale_factor=1 pins the output to CSS pixels, so the viewport
        # size IS the image size. Without it a HiDPI default would silently
        # emit a 2400x1260 card.
        page = browser.new_page(
            viewport={"width": WIDTH, "height": HEIGHT},
            device_scale_factor=1,
        )
        page.goto(SVG.resolve().as_uri())
        page.screenshot(path=str(PNG), omit_background=False)
        browser.close()

    width, height, colour_type = png_dimensions(PNG)
    if (width, height) != (WIDTH, HEIGHT):
        print(
            f"FAIL: rendered {width}x{height}, expected {WIDTH}x{HEIGHT} --"
            " og.svg's width/height/viewBox and this script disagree",
            file=sys.stderr,
        )
        return 1
    # 2 = truecolour, 6 = truecolour with alpha. Either is fine, and which one
    # you get is the encoder's call: the card is drawn on an opaque <rect>, so
    # Chrome emits type 2 and drops the all-opaque alpha channel, while the
    # previously committed PNG was type 6. What is NOT fine is 0/3/4 --
    # greyscale or palette -- because that means the antialiased text against
    # #0d1013 was quantised away, i.e. the render degraded rather than merely
    # differing.
    if colour_type not in (2, 6):
        print(
            f"FAIL: rendered PNG colour type {colour_type}; expected truecolour"
            " (2 or 6), not greyscale/palette",
            file=sys.stderr,
        )
        return 1
    kind = "RGB" if colour_type == 2 else "RGBA"

    digest = hashlib.sha256(SVG.read_bytes()).hexdigest()
    STAMP.write_text(digest + "\n")

    print(f"wrote {PNG} ({width}x{height} {kind}, {PNG.stat().st_size} bytes)")
    print(f"wrote {STAMP} ({digest})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
