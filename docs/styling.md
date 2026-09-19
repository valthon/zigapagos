# Styling and reusable components

Zigapagos accepts ordinary CSS. A framework or design system is optional.
The [styling example](../examples/styling-site/README.md) builds plain CSS,
externally compiled Tailwind, and a reusable Preact component into one static
output directory, with separate routes showing their browser costs.

## Plain CSS

Put a stylesheet under `assets/` and reference it in a layout:

```html
<link rel="stylesheet" href="$site.asset('css/plain.css').link()">
```

That reference installs the asset and emits its deployed URL. A page without
islands or SPA routes needs no JavaScript to load or apply CSS.

## Compile a CSS framework before release

The example pins Tailwind and its CLI to 4.3.3 in its own manifest and lockfile.
It follows the [Tailwind CLI workflow](https://tailwindcss.com/docs/installation/tailwind-cli):
compile your styles first, then link the resulting stylesheet in the layout.

```sh
bun install --frozen-lockfile
bun node_modules/@tailwindcss/cli/dist/index.mjs \
  -i styles/tailwind.css -o assets/generated/tailwind.css --minify
zigapagos release --css-minify
```

Its input explicitly scans `layouts/framework.shtml`. Add your component and
template directories to the compiler's sources when you use utility classes
there. Zigapagos does not infer a framework's sources, run its compiler, or
replace its configuration. The resulting CSS is an ordinary site asset, and
using it does not add a framework runtime to the browser.

## Imports, images, and fonts

CSS `@import` and `url()` references resolve relative to the emitted stylesheet.
Zigapagos does not discover those dependencies or rewrite their URLs. Declare
them in `.static_assets`, preserving their directory structure:

```ziggy
.static_assets = [
    "css/tokens.css",
    "fonts/brand.woff2",
    "images/grid.svg",
],
```

For example, `css/components.css` can use `url('../fonts/brand.woff2')`.
A stylesheet linked only through another stylesheet also needs an explicit
static-assets entry. The example exercises an import chain, a font, and an SVG
background under these rules. Include font licenses in your deployment.

`--css-minify` shrinks each installed stylesheet independently; it does not
bundle imports. Its bundled driver needs Bun and the runtime sources. If you
enable asset fingerprinting, CSS dependencies declared as static assets retain
stable names. A linked entry stylesheet may be fingerprinted without changing
its directory. Use an external asset pipeline if you need transitive CSS URL
rewriting; do not guess hashed dependency paths.

`doctor --strict` checks the HTML's local links, but does not parse CSS imports
or `url()`. Browser checks are needed to verify these dependencies actually load.

## A reusable Preact component boundary

`design-system/Button.tsx` in the example is an ordinary local component. It
accepts typed props and an event handler. `Preference.island.tsx` imports it,
owns its state, and defines where hydration begins. Styles remain in an explicit
layout stylesheet rather than a JavaScript CSS import.

Use `@z/runtime` for Preact hooks, types, and JSX support so server rendering and
the browser share the supported runtime. Reuse components through relative
imports; they do not each need an island wrapper. Keep DOM access and browser
side effects out of module initialization and rendering, which also run on the
server.

This example verifies a local Preact component, not every React design system.
Third-party React packages require the explicit npm-compat boundary described
in [the React compatibility guide](migration/react-spa-bridge.md), and their assumptions still need browser
and server-rendering tests. CSS-in-JS extraction, arbitrary component-library
compatibility, and automatic CSS imports are not established by this example.
