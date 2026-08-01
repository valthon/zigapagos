<h1 align="center">🏝️ Zigapagos</h1>

<p align="center">
  <b>The islands-architecture static site generator with a native core.</b><br/>
  Author interactive components in TSX. Ship zero-JS-by-default pages.<br/>
  One fast Zig binary + Bun — no Node, no Vite, no framework lock-in.
</p>

<p align="center">
  <a href="https://valthon.github.io/zigapagos/">Website</a> ·
  <a href="docs/islands.md">Islands</a> ·
  <a href="docs/spa.md">SPAs</a> ·
  <a href="docs/migration/astro-to-zigapagos.md">Migrate from Astro</a>
</p>

---

## What is Zigapagos?

Zigapagos brings [Astro](https://astro.build)-style **islands architecture** to a
native static site generator. Pages are plain HTML rendered at build time by a
fast Zig core; interactivity is added per-component:

```tsx
// components/Counter.island.tsx
import { useState } from "@z/runtime";

export default function Counter({ start = 0 }: { start?: number }) {
  const [n, setN] = useState(start);
  return <button onClick={() => setN(n + 1)}>clicked {n} times</button>;
}
```

At build time each `.island.tsx` is **server-rendered** through a Bun sidecar and
embedded into the page as real HTML. In the browser it **hydrates** on your
terms — `client:load`, `client:idle`, `client:visible`, `client:media`, or
`client:only` — sharing ONE Preact instance across every island via an import
map. No island on the page? Zero JavaScript shipped.

## Features

- **TSX islands** — Preact-compatible components (`useState`, `useEffect`,
  context, portals, …) via the first-party `@z/runtime`, SSR'd at build time
  and partially hydrated.
- **Native SPAs** — a single `.spa.tsx` (exported `spa` + `routes`) becomes a
  client-routed app: prerendered route skeletons, two-phase hydration,
  soft navigation, route guards, nested layouts. Host-agnostic routing
  manifests (ZigBase / Nginx / Apache) generated for you.
- **LLM-native Astro migration** — `zigapagos migrate <astro-dir>` detects
  `client:*` component usage and writes a `MIGRATION.md` worklist; opt into
  `--scaffold` and it also emits a starter island per detected island with the
  React → `@z/runtime` import swaps already applied. It converts no page, layout
  or config itself — the docs are written as a deterministic mapping spec so an
  AI agent can complete the migration unattended.
- **Zero-config dev loop** — `zigapagos dev` rebuilds the site, serves the real
  release tree with the stock ZigBase binary (same-origin API and admin UI, not
  a proxy shim), and live-reloads the browser over SSE. Islands hot-swap with
  their `useState` intact.
- **A real templating stack, no JS required** — SuperHTML layouts and SuperMD
  content with build-time correctness checks, inherited from Zine.
- **Fast native core** — the site graph and content pipeline are Zig; the only
  JS toolchain is Bun, used surgically for TSX.

## Quickstart

### From source

`zig build` builds ZIGAPAGOS. It does not build websites — the binary does that,
and needs no Zig toolchain of its own.

```bash
# toolchain (or install zig 0.16.0 + bun 1.2 yourself)
mise install

zig build          # build the zigapagos binary
zig-out/bin/zigapagos init   # scaffold a site
zig-out/bin/zigapagos dev    # dev loop at http://127.0.0.1:1990
```

### From npm, no toolchain

```bash
npx zigapagos init                            # scaffold a content site
npx zigapagos dev                             # dev loop at http://127.0.0.1:1990
npx zigapagos release --output=public --force  # build it
```

A prebuilt binary for macOS x64 and Linux x64 — arm64 is **not** supported on
either OS until a native aarch64 build lands, and `npm install` refuses those hosts
rather than substituting the x64 binary. `zigapagos` is an alias for the canonical
[`@zigapagos/cli`](npm/README.md). This channel covers **everything**: content
sites, the CLI tooling (`init`, `migrate`, `doctor`, `validate`, `explain`),
**islands**, **native SPAs** and `zigapagos dev`, with no Zig toolchain. The
package ships the `@z/runtime` sources and the Bun sidecar, and depends on `bun`
and `@zigbase/server`, so `release` discovers your `*.island.tsx` / `*.spa.tsx`
entries and bundles them itself.

The [releases page](https://github.com/valthon/zigapagos/releases) gets you the
binary and nothing else — no Bun, and no `@z/runtime` tree, which islands and
SPAs need. [`docs/runtime-dependencies.md`](docs/runtime-dependencies.md) is the
full account: what each command needs installed, how Bun and ZigBase are
obtained, and what npm supplies that an archive does not.

To add your first island, see [docs/islands.md](docs/islands.md). A complete
worked example lives in [`examples/tsx-site/`](examples/tsx-site/) — islands,
a SPA slice, SSR + real-browser hydration tests.

## How it works

```
content/*.smd ──► Zig core (SuperMD/SuperHTML) ──► page HTML ─┐
components/*.island.tsx ──► Bun sidecar (SSR) ────────────────┤──► static site
                            └─► esbuild-style bundle ─────────┘    + import map
                                (@z/runtime external)              + one shared runtime
```

One render seam: after a page renders, islands found in it are SSR'd and the
resulting HTML + `data-z-props` are injected, along with a `modulepreload` hint,
an import map, and the shared runtime script. Everything else is plain zine-style
static generation.

## Status

Zigapagos is **v0.1.0** and pre-1.0: APIs may change between minor versions.
Zig version: **0.16.0** (we track released Zig, not nightlies). The islands
engine, SPA support, and Astro migration tooling are complete and covered by
unit + real-browser e2e tests.

## Acknowledgements

Zigapagos is a permanent fork of [**Zine**](https://zine-ssg.io) by
[Loris Cro](https://kristoff.it) — a fast, elegant, deliberately JavaScript-free
SSG. The Zig core, SuperHTML, SuperMD, and Ziggy are his work and the reason
this project could exist. Zigapagos diverges philosophically (we embrace a
minimal TSX toolchain for interactivity; Zine's whole point is not to), which
is why this is a fork rather than a contribution. The original README is
preserved at [docs/upstream/ZINE-README.md](docs/upstream/ZINE-README.md);
fork point: zine v0.11.2 (`496e42d`).

## License

MIT — see [LICENSE](LICENSE), which retains the upstream Zine copyright.
