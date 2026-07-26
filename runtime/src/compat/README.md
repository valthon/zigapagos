# `@z/runtime/compat` — port-mapping shims

Drop-in shims that collapse a React-to-`@z/runtime` marketing-island port into
mechanical import-swaps instead of hand-rewrites.  The shims codify patterns
discovered during the pilot-site marketing port.

---

## The import-swap the shims enable

```diff
-import { FlagsProvider, useFlag, useExperiment }
-        from "@legacy-app/shared/flags";
+import { FlagsProvider, useFlag, useExperiment }
+        from "@z/runtime/compat";

-import customer from "@legacy-app/shared/customer";
-const { useCustomer, CustomerProvider } = customer;
+import { useCustomer, CustomerProvider } from "@your-org/shared-lite/customer";
+// (see consumer pattern below — @your-org/shared-lite lives in the consumer project)

-import ReCAPTCHA from "react-google-recaptcha";
+import { ReCAPTCHA } from "@z/runtime/compat";
```

---

## Exported symbols

### `FlagsProvider`

```tsx
<FlagsProvider url="/api/flags/state">
  <MyIsland />
</FlagsProvider>
```

Drop-in for `@legacy-app/shared`'s `<FlagsProvider>`.  Calls `initFlags(url)`
inside `useMemo` (so it fires once on mount, is a no-op during SSR, and
`host.fetchShared` de-dupes concurrent calls).  Renders `children` directly —
no context or wrapper DOM node.

### `useExperiment(name: string): string`

Alias for `useVariant` — the name used in the pilot site's codebase for the same
server-resolved experiment-variant read.  Replacing the import line is
sufficient; no call-site changes needed.

### Flags re-exports

```ts
export { useFlag, useVariant, FeatureFlag, Experiment } from "@z/runtime";
```

These are re-exported **by name** (not `export *`) so that a single
`@z/runtime/compat` import line covers everything that was previously in
`@legacy-app/shared/flags`.  The named-re-export is load-bearing: an `export *`
would collide with the barrel's `useFlag`/`useVariant`/`FeatureFlag`/`Experiment`
inside the shared bundle and silently drop them.

### `makeSharedResource<T>(opts: { store: string; url: string }): SharedResource<T>`

Generalizes `flags.ts` for any `host.fetchShared`-backed shared store:

```ts
interface SharedResource<T> {
  prime(): void;              // trigger fetch (host de-dupes)
  use(): T | null;            // reactive read via useSyncExternalStore
  Provider(p: { children?: ComponentChildren }): VNode; // prime-on-mount wrapper
}
```

The `subscribe` function is created once per `makeSharedResource` call (not per
render), mirroring the pattern in `flags.ts:13`.

### `ReCAPTCHA`

```tsx
import { ReCAPTCHA, type RecaptchaHandle } from "@z/runtime/compat";

const ref = useRef<RecaptchaHandle>(null);
// …
<ReCAPTCHA siteKey="6Le..." onChange={(token) => setToken(token)} ref={ref} />
// ref.current.getValue()  — current token string
// ref.current.reset()     — reset the widget + clear the token
```

Drop-in for `react-google-recaptcha`.  Loads the Google reCAPTCHA v2 script via
`host.loadScript` (de-duped, SSR no-op), renders a `div.g-recaptcha-container`
placeholder during SSR, then calls `grecaptcha.render` on mount.

**Why the `grecaptcha.render` callback captures the token, not
`host.recaptchaToken()`:** The original design drafted a `host.recaptchaToken()`
accessor, but the marketing port found it unreliable for v2 — the global token
is not always available at the moment the form reads it, and the widget can be
reset or expired between the user's solve and the submit.  The shim captures
the token via the `callback` passed to `grecaptcha.render`, stores it in a ref
(`tokenRef`), and exposes it through the imperative `RecaptchaHandle`.  This is
intentional; do not revert to `host.recaptchaToken()`.

### `useRecaptcha(siteKey: string)`

```ts
const { getToken, reset, render } = useRecaptcha("6Le...");
// mount-time: render(containerEl)  — renders the widget into your own container
// submit-time: getToken()          — returns the current token string
// reset: reset()                   — resets the widget + clears the token
```

Hook variant for callers that own the container element rather than using the
`<ReCAPTCHA>` component directly.  The `render(el)` call must be made after the
grecaptcha script has fully loaded; calling it before the script resolves is a
no-op (the widget will not appear).

---

## Architecture — Fork A: `@z/runtime/compat` is externalized

> This is the ACTUAL shipped architecture.  An earlier design sketch (Fork B)
> assumed compat symbols would be inlined into each island bundle.  Build
> testing disproved that: the built `Flagged.island.js` is ~444 bytes and
> imports `from "@z/runtime/compat"` — it does not contain an inlined body.

### How it works

**`--external=@z/runtime` prefix-matches all subpaths.**

`build.zig:234` invokes `bun build --external=@z/runtime --external=@z/runtime/jsx-runtime`.
Bun's `--external` flag prefix-matches specifiers, so `@z/runtime/compat` is
also externalized from every island bundle.  Island bundles import compat symbols
as bare module specifiers and rely on the page's import map to resolve them at
runtime — identical to how they import `@z/runtime` itself.

**One shared bundle.**

`runtime/src/browser-entry.ts` is bundled into `/zigapagos-runtime.js`.  It
re-exports the full `@z/runtime` barrel (`export * from "./index.ts"`) AND the
compat-unique symbols **by name**:

```ts
// browser-entry.ts (do not modify)
export { makeSharedResource, FlagsProvider, useExperiment } from "./compat/index.ts";
export { ReCAPTCHA, useRecaptcha }                          from "./compat/index.ts";
export type { RecaptchaHandle, SharedResource }             from "./compat/index.ts";
```

**One import-map entry.**

`src/islands/pass.zig` emits an import map that maps both `@z/runtime` and
`@z/runtime/compat` to the same URL:

```json
{
  "imports": {
    "@z/runtime":          "/zigapagos-runtime.js",
    "@z/runtime/compat":   "/zigapagos-runtime.js"
  }
}
```

Because both specifiers resolve to the **same module instance**, there is exactly
one Preact copy and one set of `host` stores on the page.

### The source invariant

`compat/*` files import state-bearing primitives (`host`, hooks, `initFlags`,
`useVariant`) from the bare `"@z/runtime"` specifier — never via relative paths
(`"./host.ts"`, `"../flags.ts"`, etc.).

This is load-bearing: inside the shared bundle, `"@z/runtime"` resolves to the
bundle's own re-exported instances.  A relative import would create a second
module scope in the bundle and duplicate the `host` STORES.

### The `ssr.sh` guard that enforces it

`examples/tsx-site/test/ssr.sh` checks every island bundle after build:

```bash
# For each island (Hero and Flagged):
grep -q '"@z/runtime' zig-out/site/islands/Flagged.island.js \
  || { echo "FAIL: did not keep @z/runtime external"; exit 1; }

if grep -qE 'preact|__H|hookState' zig-out/site/islands/Flagged.island.js; then
  echo "FAIL: island bundle inlined Preact (compat broke one-instance invariant)"; exit 1
fi
```

If this guard goes red after a compat change, a relative state import has slipped
in and broken the one-Preact invariant.

---

## Consumer pattern — `@your-org/shared-lite`

`@your-org/shared-lite` lives in the consumer (pilot-site) project, **not in this
repo**.  It wraps `makeSharedResource` to expose typed, project-specific hooks:

```ts
// @your-org/shared-lite/customer.ts  (consumer project — NOT zigapagos)
import { makeSharedResource } from "@z/runtime/compat";

export interface Customer { id: string; email: string; name: string }

const customer = makeSharedResource<Customer>({ store: "customer", url: "/api/club/me" });

export const useCustomer      = customer.use;       // (): Customer | null
export const primeCustomer    = customer.prime;
export const CustomerProvider = customer.Provider;
```

Islands that previously imported from `@legacy-app/shared/customer` swap their
import line to `@your-org/shared-lite/customer` — call-sites are unchanged.

The `zigapagos migrate` rewrite-table entries that point banned/legacy specifiers at
these shims are tracked separately under the `migrate-port-doctor` work.

---

## What is NOT in this package

- `@your-org/shared-lite` itself — lives in the consumer project.
- The `zigapagos migrate` rewrite-table — tracked under the same work.
- `host.recaptchaToken()` — not used by these shims (see ReCAPTCHA section above).
