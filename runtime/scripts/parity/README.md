# Structural Parity Gate (v1)

Compares Astro SSR output against zigapagos TSX output per route, normalizing both sides into a canonical DOM tree and island-props list before diffing. A green gate means: "every DOM node, attribute, and island prop that Astro emitted is present and identical in the zigapagos build."

## Quick start

```bash
# 1. Freeze the Astro reference as the golden corpus
bun runtime/scripts/parity.ts capture --config my-site/parity.config.json

# 2. Build the TSX site, then check it against the golden
bun runtime/scripts/parity.ts check   --config my-site/parity.config.json
```

`capture` writes `parity/golden/<slug>.nodes.json` + `<slug>.props.json` under the config directory.  
`check` reads those goldens, canonicalizes the current build, diffs, writes `parity/report/<slug>/result.json` (+ `dom.diff` on failure), and prints `parity: PASS` or `parity: FAIL — see parity/report/` before exiting 0/1.

## `parity.config.json` schema

```jsonc
{
  // The Astro (or any prior) static-dir build to use as the golden reference.
  "reference": { "kind": "static-dir", "path": "path/to/astro/dist" },
  // The zigapagos build output directory.
  "build": { "outDir": "zig-out/site" },
  // Routes to compare. "/" maps to index.html; "/foo/" maps to foo/index.html.
  "routes": [
    { "path": "/" },
    { "path": "/about/" }
  ],
  // Optional: strip scoped-style class hashes (e.g. "astro-[a-z0-9]{8}").
  // Provide as a JS RegExp source string (no slashes).
  "classHashPattern": "astro-[a-z0-9]{8}"
}
```

All paths under `reference.path` and `build.outDir` are resolved relative to the directory containing the config file.

## Normalization spec

Both the reference and the build HTML are passed through `canonicalize()` before any comparison. The steps, in order:

| Step | What happens |
|------|--------------|
| **Props extraction** | `<script type="application/json" data-z-props>` blocks are parsed into a props-by-id map and removed from the DOM. Astro props are read from `astro-island[props]` (JSON with optional `[typeCode, value]` tuple unwrapping via `decodeAstroProps`). |
| **Island-host folding** | `<div data-z-island>` (zigapagos) and `<astro-island>` (Astro) are each replaced by `<z-island data-src="ComponentName">`, retaining the host's children. The component name is extracted via `componentKey()` which strips chunk-hash suffixes (`.x1`, `.BhMxZzna`), `.island.`, and the file extension. |
| **Slot-wrapper unwrapping** | `<astro-slot>` (Astro) and `<z-slot>` (zigapagos) wrapper elements are unwrapped (children hoisted into the parent), and zigapagos's `<script type="application/json" data-z-slots>` hydration scripts are removed, so slot containers do not appear as structural differences. |
| **Comment removal** | All HTML comment nodes are removed (framework markers, Astro injection comments). |
| **`data-astro-*` stripping** | Attributes starting with `data-astro-` are removed (enabled by default). |
| **Class-hash stripping** | If `classHashPattern` is set, matching tokens are removed from each element's `class` attribute; if the class list empties, the attribute is removed entirely. |
| **Whitespace + attr canonicalization** | `serializeDom(root, { normalizeWhitespace: true })` (reused from `runtime/src/testing/parity/serialize.ts`) collapses all whitespace runs to a single space, drops whitespace-only text nodes, removes `data-z-*` attributes, and sorts remaining attributes alphabetically. The result is an `SNode[]` tree (typed `element | text` nodes). |
| **Props sort** | The extracted `IslandProps[]` list is sorted by component name so diffing is order-independent. |

The canonical form is `{ nodes: SNode[]; domString: string; props: IslandProps[] }`.

## Diff logic

**Structural diff (`diffNodes`):** Walks the two `SNode[]` trees in lock-step. Reports mismatches as `StructuralMismatch` records with `kind: "text" | "attribute" | "structure" | "missing" | "extra"` and a CSS-like `path` (e.g. `div:nth(0) > h1:nth(0) @class`).

**Props diff (`diffProps`):** Compares `IslandProps[]` by component name. For each component, JSON-serializes each prop value and reports `PropMismatch` records on any deviation.

**Line diff (`lineDiff`):** When a route fails, produces a human-readable `--- expected / +++ actual` line diff of the rendered `domString` for the report file.

## Golden-corpus / approval-test model

Goldens are the source of truth. The workflow:

1. Run `capture` once against the Astro reference to freeze the expected structure.
2. Build the zigapagos site and run `check` in CI.
3. When an intentional change is made to the TSX island output (a deliberate improvement), re-run `capture` to advance the golden and commit the updated `.nodes.json` / `.props.json` files.

For the self-consistency demo in `examples/tsx-site`, both `reference.path` and `build.outDir` point at the same `zig-out/site` directory. This proves the capture → check pipeline runs end-to-end on real output without requiring a separate Astro dist.

## v1 boundary — structural channel only

**What v1 catches:** DOM-structure regressions (missing/extra/reordered nodes), attribute changes, island-prop changes.

**What v1 does NOT cover:** CSS, scoped styles, layout, visual rendering, or pixel-level differences; **and inline / `<pre>` whitespace** — the structural channel collapses whitespace runs and drops whitespace-only text nodes, so a missing/extra space between inline elements (`<a>x</a> <a>y</a>` vs `<a>x</a><a>y</a>`) or significant `<pre>`/`<textarea>` whitespace is NOT detected. These are caught by the **v2 Playwright visual channel** — screenshot diffs via Playwright per route, which is the load-bearing safety net for styling/spacing and is tracked as the v2 deliverable of `astro-tsx-parity-gate`.

Do not treat a green v1 gate as "visually identical." It is "structurally identical."

## Known v1 limitations

| Limitation | Detail | Workaround |
|------------|--------|------------|
| **Basic Astro props type-code decoding** | `decodeAstroProps` unwraps `[typeCode, value]` tuples but does not handle every Astro type code (e.g. `BigInt`, `Set`, `Map`). Non-primitive props may not decode to an exactly matching value. | Inspect `parity/golden/<slug>.props.json` after capture and verify by hand if Astro uses non-standard types. |
| **Multi-instance-same-component props collapse** | `diffProps` keys props by component name; if the same component appears more than once on a page, only the last instance's props are compared (earlier instances are overwritten in the map). | Rename island variants if per-instance props matter, or wait for v2's per-instance tracking. |
| **Dynamic-region masks** | Pages with server-rendered dynamic regions (user-specific content) will always diff. The v2 config will add mask selectors to exclude them from the structural diff. | Canonicalize both sides to a static fixture before running `check`, or wait for v2 masks. |
