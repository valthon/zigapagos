> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/islands/> — the site is the canonical reading experience.

# Island authoring

Islands are `.island.tsx` files authored against `@z/runtime` (a vendored
Preact build). SSR happens at build time via a Bun "render sidecar"; client
hydration uses an import-map so the page shares **one** Preact instance.

## File conventions

- Place islands under the project's `components/` directory (or any path; the
  `--island-src-dir` flag controls where Zigapagos looks).
- Name the file `<ComponentName>.island.tsx`.
- Export a default function component.

```tsx
import { useState } from "@z/runtime";

export interface Props { headline: string }

export default function Hero({ headline }: Props) {
  const [open, setOpen] = useState(false);
  return (
    <section>
      <h1>{headline}</h1>
      <button onClick={() => setOpen(!open)}>{open ? "−" : "+"}</button>
    </section>
  );
}
```

## Using an island in a layout

In a `.shtml` layout, use the `<island>` element. Props can be supplied as a
Ziggy struct literal (`:props`) or individually (`prop-NAME`):

```html
<!-- bound to a page field -->
<island src="components/Hero.island.tsx" client:load
        prop-headline="$page.title"></island>

<!-- static Ziggy struct -->
<island src="components/Flagged.island.tsx" client:load
        :props='{ .label = "hi" }'></island>

<!-- composite island with named slots -->
<island src="components/Panel.island.tsx" client:load
        :props='{ .title = "Panel" }'>
  <template slot="heading"><h2>Custom Heading</h2></template>
  <p>default body</p>
</island>
```

### `client:only` fallback content

`client:only` is the one directive that ships no server-rendered markup — the
component mounts fresh in the browser and nothing is in the HTML before it does.
A reserved `fallback` slot fills that window:

```html
<island src="components/Chart.island.tsx" client:only :props='{ .series = "a" }'>
  <template slot="fallback"><div class="chart-skeleton">Loading chart…</div></template>
  <p>this is still the default slot, delivered to the component at mount</p>
</island>
```

The fallback's markup is emitted inside the island's wrapper `<div>` at build
time, so it is in the HTML a visitor (or a crawler) sees, and it is what shows
if JavaScript never runs. Specifically:

- It is **removed at mount**, after the island's module has loaded and before
  the component renders. A module that fails to load leaves the fallback on
  screen rather than blanking the box.
- It is **not** passed to the component. `fallback` is reserved: it never
  appears in the island's `data-z-slots` payload and never arrives as a slot
  prop. Every other slot — including the default slot in the example above — is
  delivered as usual.
- It **must not contain an `<island>`**. A nested island would hydrate and then
  be torn out the moment the outer component mounts, so this is a build error.
  (A commented-out island is fine; the check skips comments and raw text.)
- There must be **at most one** of them. Two fallback templates is a build error
  rather than "the last one wins": the placeholder can only show one, so the
  other would be silently discarded — and only one of them would have been
  checked for a nested island.
- It is a **build error on any other directive**. `client:load`, `client:idle`,
  `client:visible` and `client:media` all server-render the component, so real
  content is already in the HTML; a fallback there would be permanently stacked
  on top of it rather than replaced.

Every one of those rules is **per island**, and nesting does not change that. A
`client:only` island with a fallback nested in another island's slot content is
governed by its own directive, not its parent's — so this is fine, and so is one
fallback each on two nested `client:only` islands:

```html
<island src="components/Panel.island.tsx" client:load>
  <island src="components/Chart.island.tsx" client:only>
    <template slot="fallback"><div class="chart-skeleton">Loading chart…</div></template>
  </island>
</island>
```

## Islands in content (`.smd`)

An island can also appear directly in a content page's Markdown, not just in a
layout — using SuperMD's existing raw-HTML escape hatch: a fenced code block
whose fence info is `=html`. SuperMD runs that fence's body through
superhtml's HTML validator and maps any error back to the `.smd` line, so
malformed markup in the fence still fails the build; the fence body that
passes validation is emitted into the page verbatim, and the islands pass
(which runs on the fully rendered page, after content is spliced into its
layout) rewrites any island it finds there exactly as it would in a layout —
SSR, the `data-z-props` script, the import map, the shared runtime script, the
`tsc` props gate, and the dev island-usage manifest all apply unchanged.

````markdown
Some prose.

```=html
<z-island src="components/Counter.island.tsx" client:load
          :props='{ .start = 5 }'></z-island>
```

More prose.
````

produces (elided):

```html
<div><p>Some prose.</p>
<div data-z-island id="z-island-0" data-z-src="components/Counter.island.tsx"
     data-z-client="load" data-z-module="/islands/Counter.island.js">CONTENT-ISLAND-SSR-5</div>
<script type="application/json" data-z-props="z-island-0">{"start":5}</script>
<p>More prose.</p></div>
```

### Why the hyphen is mandatory: `<z-island>`, not `<island>`

Use `<z-island>` in content, not `<island>`. superhtml's `.html`-mode
validator — the mode used for the `=html` fence, as opposed to `.superhtml`
mode used for layouts — rejects any unhyphenated, unrecognized element name
per the HTML custom-element spec, failing the build with
`[invalid_html_tag_name]`. `.superhtml` mode is deliberately lax about unknown
elements, which is the only reason `<island>` has ever worked in a layout.
`<z-island>` is a hyphenated alias the islands pass recognizes identically to
`<island>` — same attributes, same slot handling, same everything — and it is
the one already-valid spelling superhtml's `.html` mode accepts with zero
changes to SuperMD or superhtml themselves. If a future supermd/superhtml sync
ever relaxes or renames that validation, `tests/islands/content-island.sh`
pins the current diagnostic and will fail loudly rather than silently pass.

### No self-closing

superhtml's `.html` mode rejects a self-closing custom element
(`[html_elements_cant_self_close]`), so inside an `=html` fence a `<z-island>`
must always be a paired tag — `<z-island …></z-island>` — even with no slot
content. (Self-closing `<island … />` still works in a `.superhtml` layout;
this restriction is specific to the content fence's `.html` validation mode.)

### Props: static only — no `$page.*`

`:props` Ziggy struct literals and literal `prop-NAME="value"` attributes work
exactly as they do in a layout, and the resolved props are typechecked by the
`tsc` gate (`--island-props-check`) the same way. What does **not** work is a
`prop-NAME="$page.*"` Scripty expression: Scripty is evaluated by SuperHTML at
*layout* render time, and an `=html` fence's body is emitted verbatim rather
than run through SuperHTML's template evaluator, so a `$page.*` value in
content is never evaluated — it reaches the island as the literal string
`"$page.title"`, not the page's actual title. This is a documented limitation,
not a bug: a page-bound prop (one that has to read `$page`, `$site`, or any
other Scripty value) belongs in a layout, not content. Everything else about
authoring an island — static Ziggy props, dynamic `prop-NAME` literals, and
slots (`<template slot="…">` children inside the fence, exactly as in a
layout) — works the same in content as it does in a layout.

## Typed props contract (build-time)

Every island that accepts props should export its props type as `Props`:

```ts
export interface Props { headline: string }
// or:
export type Props = { headline: string }
```

At build time, Zigapagos typechecks each rendered `<island>`'s **resolved** props
(`:props` merged with `prop-NAME` overrides and `$page.*` values) against that
`Props` type using `tsc`. A mismatch — wrong type, missing required field, or a
misspelled prop (excess property) — fails the build:

```
error: props mismatch on /  <island src="components/Hero.island.tsx" id="z-island-0">
  resolved props: {"headline":5}
  Type 'number' is not assignable to type 'string'. (TS2322)
```

An island that takes no props simply omits `Props`. An island that accepts props
but does not `export` a `Props` type is reported once at build time:

```
warn(island_props): island components/MyIsland.island.tsx has no exported Props type; props unchecked
```

and the check is skipped for that island (it is not a build error).

### Flag: `--island-props-check=error|warn|off`

| Value   | Behaviour |
|---------|-----------|
| `error` | Mismatches fail the build (default for `zig build`). |
| `warn`  | Mismatches are logged but the build succeeds. |
| `off`   | Check disabled entirely. |

`build.zig`'s `website()` helper emits `--island-props-check=error` for all
release builds automatically. `zigapagos serve` defaults to `off` so the dev loop
stays lenient.

## Module preloading

Pages with islands emit `<link rel="modulepreload">` tags for the runtime that
page loads (see [Runtime slicing](#runtime-slicing)) and each island module,
deduped and placed **after the import map**:

```html
<script type="importmap">…</script>
<link rel="modulepreload" href="/zigapagos-runtime.js">
<link rel="modulepreload" href="/islands/Hero.island.js">
<link rel="modulepreload" href="/islands/Panel.island.js">
```

The import map must come first: per the import-maps spec, a map is only
processed if it appears before any module loading starts, and a
`<link rel="modulepreload">` starts one. A map that arrives after is silently
disregarded by the browser — a bug that was cache-state flaky (a cold cache
usually loses the race and the page still works; a warm cache wins it and
`import … from "@z/runtime"` fails).

The preload links still let the browser fetch island JS **in parallel with HTML
parse** rather than discovering each module URL serially at hydration time.
Islands using `client:only` are included. Hero appearing twice on the same page
produces a single preload link — dedup is by module URL.

**v2 follow-up (deferred):** batched-NDJSON SSR (one sidecar round-trip per page
instead of N sequential calls) is on hold pending co-design with `sidecar-slots`'
nested-slot weaving — the `BatchItem` struct must carry `slots_json` and the
deferred-splice sentinel must round-trip through slot-weaving for nested islands.

## Runtime slicing

The shared runtime (`/zigapagos-runtime.js`) is the whole `@z/runtime` barrel:
the SPA router, the feature-flag client, the API client, the observability and
error relays, and the full preact/compat React surface. A page whose only island
is a counter loaded all of it.

A release build therefore also produces a **sliced islands runtime** at
`/islands/_runtime.js`, containing only `islands.ts`'s hydration auto-init, the
JSX-transform names, and the union of the named `@z/runtime` exports the site's
islands actually import. On the dogfooded site that is 60,271 bytes -> 21,686
bytes, a 64% reduction on every island page.

Selection is per page, and conservative:

- The slicer reads each island's **built bundle** — the exact, already-resolved
  statement of what the browser will ask the runtime for. An island whose bundle
  imports `@z/runtime/compat`, a bare `react` specifier, any other
  `@z/runtime/*` subpath, a namespace or default import, a re-export, a dynamic
  `import()`, or a name the barrel does not export **bails** and keeps the shared
  runtime. (Reading island *sources* instead would miss a `react` import that
  arrives transitively through a dependency — and that page would then load a
  runtime with no React surface.)
- A page loads the slice **only if every island on it is one the slice covers**.
  A single uncovered island puts the whole page back on the shared runtime: one
  URL feeds the import map, the `modulepreload` and the module `<script>`, so a
  page can never end up with two runtimes and two Preact instances.
- If no island can be proved safe, **no slice is emitted at all** and every page
  keeps the shared runtime — the worst case is the pre-slicing behaviour.

Two consequences worth knowing:

- The shared runtime is always emitted, even on a site where every page is
  sliced, so such a site ships one unreferenced bundle in its output tree. The
  slice decision is a build-time fact and the asset is declared at configure
  time. (The SPA slicer has the same wart.)
- `zigapagos serve` and the `zigapagos dev` hot loop never slice. The live server
  serves the shared runtime from its own cache dir, and a slice entry does not
  call `installHmr()`, so slicing the dev build would silently disable island
  hot-swap. Payload size is not a dev-loop concern.

## Import guardrail

Islands may only import from:

- `@z/runtime` (and its subpaths, e.g. `@z/runtime/compat`)
- `@your-org/shared-lite`
- Relative paths (other local modules)
- Web globals (no `node:*` / bare npm packages)

Violations are caught by `runtime/scripts/lint-island-imports.ts`.

## Dev hot-swap (HMR) and fast refresh

Two dev-only layers keep island state alive across a rebuild; both are inert in
production (release bundles contain neither the transform nor the dev snippet).

**In-place hot-swap.** When only island bundles changed, the dev
server's SSE channel sends `{"kind":"island","modules":[…]}` instead of a full
reload. The injected client snippet hands it to
`window.__zigapagos_hmr.applyIsland` (`runtime/src/hmr.ts`), which re-imports
each changed module with a cache-bust query and re-renders the matching island
root(s) in place — no navigation, so the SPA route, scroll, and sibling islands
are untouched. `useRestorableState` values survive because the
`zigapagos:beforereload` event fires (and stashes them to sessionStorage) before
the swap; the fresh mount restores them.

**Fast refresh.** A bundle built with the island driver's dev-only
`--hot` flag (`runtime/sidecar/bundle-island.ts` → `hot-transform.ts`) routes
the entry module's top-level function components through a runtime registry
(`runtime/src/hot-registry.ts`), keyed by entry path + component name. On a
hot-swap, if the edited component's build-time **hook signature** (its ordered
sequence of provable hook calls) is unchanged, the re-imported module resolves
to the **same** proxy function — Preact keeps the mounted component instance,
so plain `useState`/`useReducer` state survives and the new implementation
(markup, handlers, reducer logic) takes over on the very next render.

**Deliberate fallbacks — correctness over cleverness.** Anything that can't be
proven safe falls back to the in-place remount (where only restorable state
survives), and ultimately to a full reload — never a corrupt swap:

- the component's hook sequence changed between builds (new identity → remount);
- a hook whose origin can't be proven: custom hooks imported from **other
  files**, `X.useY()` property calls, namespace-imported hooks. Only hooks
  imported from `@z/runtime`(`/…`) or declared in the **same file** (whose own
  hook sequence is folded into the signature, recursively) are provable;
- anonymous or expression default exports (`export default () => …`),
  HOC-wrapped defaults, class components, async/generator functions;
- components defined in non-entry files (the transform touches only the entry);
- an untransformed module (no `--hot`), which registers nothing.

**Dev-loop wiring.** `zigapagos dev` sets `ZIGAPAGOS_HOT_ISLANDS=1` in the
rebuild command's environment for the whole session (skipped with
`--no-live-reload`, which exists for release-fidelity testing); the consumer's
`zig build` reads it at configure time (`build.zig`'s `addIslandAssets`) and
passes `--hot` to the island bundle driver, so every dev island bundle routes
through the registry from the first page load. When the dev loop's change
classifier proves a rebuild was island-only (see the incremental re-SSR section
below), it broadcasts the `{"kind":"island",…}` hot-swap message instead of a
full reload — the swap preserves plain hook state end-to-end. Any other change
(a content page, a layout, an unclassifiable edit) still full-reloads.

Release bundles never contain the transform — `hot` is off by default and the
environment variable never reaches a plain `zig build` / `zigapagos release`,
so the release byte-parity gate is untouched. One known nit: a component
wrapped in `memo()` may show stale UI until its next state change after a
preserving swap.

## Incremental bundling

Each island and the shared runtime are bundled by `runtime/sidecar/bundle-island.ts`,
a Bun build-time driver invoked via `build.zig`'s `addIslandAssets`. The driver emits a
Make-style depfile alongside each bundle so Zig's `Run` cache knows exactly when to
re-bundle.

**What the depfile tracks** (the island's true transitive closure):

- The island entry file itself
- All relative imports and `@your-org/shared-lite` modules loaded transitively
- The `tsconfig.json` (and its `extends` chain) found above the entry
- `runtime/.version-stamp` — a short string written by `build.zig` and listed in
  every bundle's depfile; bump the string to force-rebundle all islands and the
  runtime in one stroke (use this when the `@z/runtime` external ABI or the Bun
  version changes)

`@z/runtime` is declared `--external` and is therefore never loaded by the bundler —
it is not captured in the island depfile. It is tracked separately via the runtime
bundle's own depfile plus the version stamp.

**Why this matters — the correctness fix:** previously, each island was registered as
a plain `addFileInput` pointing only at its entry file. Editing a transitive dep (a
relative import or an `@your-org/shared-lite` module) left the island's declared cache
inputs unchanged, so Zig considered it a cache hit and shipped the stale bundle.
The depfile fixes this: the Zig `Run` cache now sees the full transitive closure and
re-runs the driver whenever any file in it changes.

**Dep-capture mechanism:** a `Bun.build` `onLoad` plugin is registered as a pure
observer — it records every module path Bun loads and returns `undefined` so the
file contents pass through unmodified. This works on Bun 1.2+. On Bun 1.3+ the
`metafile.inputs` map is also populated; `bundleIsland` unions both sources so
incrementality improves automatically on newer Bun versions without any code change.

**First-build behaviour (cold cache):** on a fresh checkout the depfile does not yet
exist, so Zig always runs the driver on build #1 and the depfile is written as part of
that run. Incrementality kicks in from build #2 onward — this is standard
compiler-depfile semantics (equivalent to `cc -MD`).

**Verification:**

- `examples/tsx-site/test/parity-bundle.sh` — asserts the driver's output is
  byte-identical to a raw `bun build` invocation (for both the Hero island and the
  shared runtime), guarding against the `onLoad` observer accidentally mutating bytes.
- `examples/tsx-site/test/incremental.sh` — injects a transitive dep into Hero,
  builds twice with the dep changed between builds, and asserts the bundle hash
  changes (H1 ≠ H2); a third no-op build asserts the hash is stable (H2 = H3).

## Dev-loop incremental re-SSR (`zigapagos dev`)

Bundling being incremental (above) is only half of a fast island edit: the SSR'd
HTML of every page that *mounts* the island is stale too. The dev loop
re-renders just those pages instead of the whole site.

**The manifest.** Every disk build run under `zigapagos dev` writes a dev-only
island-usage manifest, `<data-dir>/islands-manifest.json` (default
`.zigbase/islands-manifest.json`), mapping each mounted island's `src` to the
pages that mount it. The path travels via the `ZIGAPAGOS_ISLAND_MANIFEST`
environment variable, which only the dev loop sets — a plain `zig build` or
`zigapagos release` never writes (or reads) it, so release output is unaffected.

**The classifier.** When the watcher fires and the only changed files under the
island/SPA `--watch-dir`s are known island sources, the dev loop resolves them
through the manifest to the mounting pages and drives the same
`ZIGAPAGOS_CHANGED_FILES` incremental path used for content edits:
the island is rebundled (depfile-driven, see above), the fresh bundle is
reinstalled, and ONLY the mounting pages are re-SSR'd + re-emitted.

**Fail-closed fallbacks.** Anything the manifest can't localize falls back to a
full rebuild — never wrong output, at worst the pre-incremental whole-site speed:

- the manifest is missing, unreadable, malformed, or written by a different
  zigapagos version,
- a changed file isn't a manifest key: a shared helper module, a SPA source, or
  an island added since the last build,
- a changed island entry is *referenced by another watched source file* — the
  manifest maps an entry to the pages mounting **it**, not to bundles that
  import it, so if another island or SPA imported the edited entry the
  incremental path would leave those pages' SSR'd HTML stale. The classifier
  scans the watched source dirs for any textual reference to the changed
  entry's module name (conservative: a hit in a comment or string also counts)
  and rebuilds everything on a match,
- any non-watch-dir shared input (layout, asset, i18n) changed too.

**Limitations.** The manifest keys are island *entry* files — share code
through a plain (non-`.island.tsx`) module rather than importing one island's
entry from another island or from a SPA. Doing so is still *correct* (the
reference scan above forces a full rebuild), it just forfeits the incremental
fast path for that entry. A page that starts or stops mounting an island is
corrected as soon as that page itself is re-rendered (its manifest entries are
replaced on every build that renders it) or by the next full rebuild.
