# Styling choices

A runnable compatibility example with three independently styled routes:

| Route | Authoring | Browser JavaScript |
| --- | --- | --- |
| `/` | Plain CSS, including a CSS `@import` | None |
| `/framework/` | Tailwind 4.3.3 compiled before Zigapagos release | None |
| `/components/` | A reusable local Preact button, an island, and ordinary CSS | Shared Zigapagos runtime and island |

From the repository root, with its pinned Zig and Bun versions installed:

```sh
zig build
(cd runtime && bun install --frozen-lockfile)
bash examples/styling-site/build.sh
python3 -m http.server --directory examples/styling-site/zig-out/site 8080
```

Open <http://localhost:8080/>. Deploy the contents of `zig-out/site` to a static
host. Set `host_url` to your real origin before publishing.

`build.sh` installs the example's frozen dependencies, invokes its local Tailwind
compiler, and runs `release --css-minify`. Set `ZIGAPAGOS_BIN` to use another
built binary. Tailwind is an example-only build dependency; it is not part of
Zigapagos's runtime or a requirement for the other styling approaches.

The script copies the existing repository font fixture from
`src/cli/init/assets/Temml.woff2` into ignored `assets/fonts/` and copies its
license notices there. This example runs within a Zigapagos checkout. When
copying it out, supply your own font and retain its license, or copy that fixture
and the notices. The font provides the decorative script-capital glyph on the
component page; body text uses system fonts. See `licenses/` for the MIT notices
from [Temml](https://github.com/ronkok/Temml) and
[KaTeX](https://github.com/KaTeX/KaTeX), whose Script font Temml adapts.

## Verify

```sh
bash tests/styling/compatibility.sh
python3 examples/styling-site/test/browser.py examples/styling-site/zig-out/site
```

The second command requires Python Playwright and its `chrome` channel
(`python3 -m playwright install chrome`). CI runs both checks. The browser test
checks actual computed styles, imported CSS, font/image requests, keyboard and
pointer interaction, and the absence of scripts on the two static routes.

See [Styling and reusable components](../../docs/styling.md) for the integration
boundaries and asset handling.
