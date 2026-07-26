# `@z/runtime/testing/parity`

Structural SSR↔hydration parity gate for `@z/runtime` islands.

## Quick start

```ts
import { expectParity } from "@z/runtime/testing/parity";
import { resolve } from "node:path";

test("Hero island has zero SSR↔hydration mismatch", async () => {
  await expectParity(resolve(import.meta.dir, "../components/Hero.island.tsx"), {
    props: { headline: "Welcome" },
  });
});
```

`expectParity` throws a `ParityError` if any mismatch is found; `checkParity` returns a
`ParityResult` (`{ ok, ssrHtml, hydratedHtml, clientHtml, mismatches }`) without throwing.

## API

### `checkParity(absPath, opts?): Promise<ParityResult>`

Non-throwing. Returns `{ ok: boolean; ssrHtml: string; hydratedHtml: string; clientHtml: string; mismatches: Mismatch[] }`.

### `expectParity(absPath, opts?): Promise<void>`

Throws `ParityError` with a human-readable diff if `ok` is false.

### `ParityOptions`

| Option | Type | Default | Description |
|---|---|---|---|
| `props` | `Record<string, unknown>` | `{}` | Props passed to the island. Also validates JSON round-trip (data-z-props). |
| `pathname` | `string` | `"/"` | Sets `window.location.pathname` so `host.pathname()` agrees between SSR and hydration. Auto-neutralized — you rarely need to set this. |
| `zClient` | `"load" \| "idle" \| "visible" \| "media" \| "only"` | `"load"` | Value of `data-z-client` on the island root (affects which strategy `bootIsland` applies). |
| `ssr` | `"in-process" \| "sidecar"` | `"in-process"` | SSR source. `"sidecar"` throws a v2-reserved error. |
| `host` | `MockHostConfig` | — | Override host values during the check (e.g. `{ now: 0 }` to freeze `Date.now()`). |
| `ignoreAttributes` | `string[]` | — | DOM attribute names to exclude from the structural diff (case-insensitive, `data-z-*` is always excluded). |
| `ignoreSelectors` | `string[]` | — | CSS selectors for elements to exclude from comparison — escape hatch for intentionally client-only subtrees. |
| `normalizeWhitespace` | `boolean` | `false` | Collapse whitespace in text nodes before comparing. |

## Why in-process SSR (v1)?

The gate uses `ssrIsland` (in-process) rather than the Bun sidecar for SSR. This is deliberate:

- The `__setServerForTest` toggle (wired inside `ssrIsland`) puts the in-process render
  on the **server host branch**, so `host.pathname()`, `host.now()`, and `host.localDateParts()`
  behave exactly as they would on the server. This makes the comparison faithful for the class
  of divergences the gate is designed to catch.
- Running in-process keeps the suite fast and dependency-free — no sidecar process to start.
- `ssr: "sidecar"` is reserved for a future v2 that will spawn the real Bun sidecar and diff
  against its output; it currently throws an explicit error to prevent accidental use.

## `pathname` neutralization

`pathname` defaults to `"/"` and `setLocationPathname` is called before each check so
`window.location.pathname` matches the SSR pathname. This neutralizes `host.pathname()`
divergence without any option needed. Pass `pathname` explicitly only when your island renders
different content for different routes and you want to test a specific path.

## Surfacing `host.now()` / `localDateParts()` divergence

If your island renders a timestamp with `host.now()` or `host.localDateParts()`, the server
and client clocks will differ and the gate will fire with a `text` mismatch and a hint:

```
hint: host.now()/localDateParts() differ server↔client — render this client-only after an effect,
      pass host:{now:…}, or ignoreSelectors.
```

Escape hatches:

1. **`host: { now: N }`** — freeze `Date.now()` to `N` for both SSR and hydration.
   - `now: 0` freezes only `Date.now()` (Bun's `setSystemTime(new Date(0))` is a no-op in
     this runtime, so `new Date()` / `localDateParts()` remains live).
   - Any non-zero value freezes both `Date.now()` and `new Date()` / `localDateParts()`.
2. **`ignoreSelectors: [".timestamp"]`** — exclude the element entirely from the diff.
3. **Render client-only** — move the timestamp into a `useEffect`-gated state update so it
   is never emitted by SSR.

## Relationship to Playwright (`hydrate.sh`)

`examples/tsx-site/test/hydrate.sh` (and `hydrate_playwright.py`) runs the island in a real
browser with Playwright, capturing layout and paint. **That test is kept** — it exercises things
the parity util cannot: CSS rendering, font loading, scroll behavior, real network requests.

The parity util is a **structural gate**: it asserts the DOM tree (elements, text, attributes)
that Preact hydrates over matches the SSR output. It is fast and runs in CI on every push without
a browser binary.

Use both:
- `expectParity` / `checkParity` — structural correctness, runs in `bun test`.
- Playwright `hydrate.sh` — visual/layout correctness, runs in a headful browser.
