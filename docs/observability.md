> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/observability/> — the site is the canonical reading experience.

# Client Observability

Zigapagos ships a first-class client-instrumentation seam for structured,
source-map-aware error and performance reporting. It is **vendor-neutral**: the
runtime produces structured payloads and dispatches them through a pluggable
**adapter**, so you point it at your own backend, at ZigBase's error pipe, or at
a provider (Sentry, Bugsnag, …) without the framework bundling any of them.

There are two tiers:

- [`initErrorRelay`](#the-basic-relay-initerrorrelay) — the basic error *relay*:
  a batched, sampled POST of flat error records to one same-origin endpoint.
  Good enough when all you need is "capture uncaught errors and POST them".
- [`initObservability`](#first-class-observability-initobservability) — the
  first-class layer: **structured payloads** with parsed (and optionally
  **source-mapped**) stack frames, **sampling + dedup**, optional **perf /
  nav-timing** capture, and a clean **adapter** interface. Reach for this when a
  team coming from React + Sentry expects symbolicated stacks and a place to
  route them.

Both are client-only (no-ops under SSR), install additive listeners, chain the
manual `window.zigapagosOnError` hook rather than clobbering it, and never throw
from the reporting path. Both also receive [`ErrorBoundary`](#errorboundary)
catches automatically.

## First-class observability (`initObservability`)

```ts
import { initObservability } from "@z/runtime";

export function clientInit(): void {
  initObservability({
    endpoint: "/api/client-errors",  // built-in HTTP adapter POSTs here
    release: "app@1.4.2",            // correlates server-side symbolication
    sampleRate: 0.25,                // report 25% of events
    perf: true,                      // capture FCP / LCP / long tasks
    context: () => ({ userId: currentUser()?.id }),
  });
}
```

Call it from your SPA's [`clientInit`](spa.md#client-only-init-clientinit)
(runs once per hard load, before hydration, and never under the SSR sidecar).
It returns a teardown function that removes every listener, restores the prior
manual hook, disconnects perf observers, and flushes + disposes the adapter.

### Structured payloads

Every uncaught `error`, `unhandledrejection`, manual `host.reportError`, and
`ErrorBoundary` catch becomes a structured `ErrorPayload`:

```jsonc
{
  "type": "error",
  "kind": "error",                 // "error" | "unhandledrejection" | "boundary" | "manual"
  "message": "Cannot read properties of undefined (reading 'id')",
  "name": "TypeError",
  "stack": "TypeError: …\n    at …",   // raw, retained as a fallback
  "frames": [                        // parsed (Chrome + Firefox/Safari formats)
    { "function": "renderClub", "filename": "https://…/spa/app.js", "lineno": 12, "colno": 4831 }
  ],
  "pathname": "/app/club/42",
  "ts": 1720000000000,
  "release": "app@1.4.2",
  "fingerprint": "error|Cannot read…|https://…/spa/app.js:12:4831",
  "context": { "userId": "u_123" }
}
```

Perf metrics arrive as `PerfPayload`s on the same channel:

```jsonc
{ "type": "perf", "metric": "LCP", "value": 1837.4, "pathname": "/app", "ts": 1720000000000, "release": "app@1.4.2" }
```

### Source-map-aware stacks

A minified production bundle produces stack frames like `app.js:12:4831` — the
`frames` array captures those verbatim, which is already useful two ways:

1. **Server-side symbolication (default, recommended).** The payload ships the
   raw frames **plus `release`**, so your backend or provider symbolicates them
   against the source maps it holds — exactly how Sentry et al. work (upload the
   maps once; the client never ships them). No client config beyond setting
   `release`. This keeps maps off every visitor's browser and out of public view.

2. **Client-side symbolication (opt-in).** Set `symbolicate: true` to have the
   runtime rewrite each frame to its **original** source/line/column/function by
   fetching the script's `.map` (served next to the bundle) and mapping it in the
   browser, before the payload is dispatched:

   ```ts
   initObservability({ endpoint: "/api/client-errors", symbolicate: true });
   ```

   Maps are fetched at most once per script (cached, including negative caches),
   and a frame whose map is missing or unmappable passes through unchanged —
   symbolication is strictly best-effort and never drops a frame or throws.

   > **Serving the maps.** Client-side symbolication only lights up once the
   > release build **emits and serves** the `.js.map` files. Set
   > Pass `--source-maps` to `zigapagos release` to emit a
   > linked `.map` next to every minified island, SPA and runtime bundle
   > (`/islands/<Name>.js.map`, `/spa/<name>.js.map`, `/zigapagos-runtime.js.map`,
   > …) and stage them into the release output. `zigapagos dev` serves that same
   > tree, so the maps are there in dev as well. It is **opt-in and off by
   > default** — maps expose your original
   > (pre-minification) sources to anyone who can reach the site, so leave it off
   > and prefer the server-side path (raw frames + `release`) if you symbolicate
   > from privately-retained maps. Turning it off keeps the release bytes
   > byte-identical to a maps-free build.

### Sampling + dedup

- **`sampleRate`** (0..1, default 1) — report only this fraction of events, so a
  high-traffic page doesn't overwhelm the endpoint.
- **Dedup** (`dedupWindowMs`, default 5000; 0 disables) — an identical error
  (same `fingerprint`: kind + message + top frame) seen again within the window
  is **suppressed**, so a component throwing in a tight render loop reports once
  rather than thousands of times. Dedup runs **before** sampling and before
  client-side symbolication, so a flood is collapsed as early as possible. Perf
  events are sampled but never deduped.

### The adapter interface

By default (when you pass `endpoint`) a built-in batching HTTP adapter buffers
events and POSTs `{ events: [...] }` to that same-origin URL via `apiFetch` —
same-origin credentials + the `zb_csrf` CSRF echo for free, flushing at a batch
cap, on an interval, and on `pagehide`/`visibilitychange→hidden` with
`keepalive`. To send anywhere else, pass your own `adapter`:

```ts
import { initObservability, type ObservabilityAdapter, type ObservabilityEvent } from "@z/runtime";

const sentryAdapter: ObservabilityAdapter = {
  handle(event: ObservabilityEvent) {
    if (event.type === "error") Sentry.captureEvent(toSentry(event));
    else Sentry.metrics.distribution(event.metric, event.value);
  },
  // optional — called on pagehide/teardown:
  flush(keepalive) { Sentry.flush(); },
  dispose() { /* release resources */ },
};

initObservability({ adapter: sentryAdapter, release: "app@1.4.2" });
```

The adapter owns transport and batching; the core owns structuring, sampling,
and dedup. `httpAdapter({ endpoint, maxBatch?, flushIntervalMs? })` is exported
if you want the built-in transport with custom batching knobs.

### Perf / nav-timing

`perf: true` installs `PerformanceObserver`s (feature-detected, wrapped so a
missing API is a no-op) for:

- **FCP** — first-contentful-paint time.
- **LCP** — largest-contentful-paint (reported per candidate; keep the last).
- **longtask** — main-thread tasks over 50ms (their duration).

Each is dispatched as a `PerfPayload` through the same adapter and respects
`sampleRate`.

### Options reference

| Option | Default | Meaning |
| --- | --- | --- |
| `endpoint` | — | Same-origin URL for the built-in HTTP adapter (`{ events }`). |
| `adapter` | — | Custom sink; overrides `endpoint`. One of the two is required. |
| `sampleRate` | `1` | Fraction of events (0..1) to report. |
| `release` | — | Build id stamped into every payload (for symbolication correlation). |
| `context` | — | `() => Record<string, unknown>` merged into each payload's `context`. |
| `perf` | `false` | Capture FCP / LCP / long tasks. |
| `symbolicate` | `false` | Rewrite frames client-side against served `.map` files. |
| `dedupWindowMs` | `5000` | Suppress an identical error within this window (0 disables). |
| `fetchSourceMap` | fetch `url+".map"` | Override the map fetcher (test seam). |
| `random`, `now` | `Math.random`, `Date.now` | Deterministic test seams. |

## ErrorBoundary

[`ErrorBoundary`](spa.md) catches a throwing subtree, renders its `fallback`,
and reports the error (`kind: "boundary"`) to whichever pipe is active —
`initObservability` or `initErrorRelay` — through a shared internal sink. If
neither is initialized the boundary still renders its fallback (the report is
dropped), so it always keeps the app alive.

## The basic relay (`initErrorRelay`)

The original, flatter seam — a batched, sampled POST of `ErrorRecord`s to one
same-origin endpoint. Unchanged and still supported:

```ts
initErrorRelay({ endpoint: "/api/client-errors", sampleRate: 0.5 });
```

Use `initObservability` instead when you want structured/source-mapped frames, a
custom adapter, dedup, or perf capture. Use one or the other, not both.
