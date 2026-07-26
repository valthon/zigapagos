// ---------------------------------------------------------------------------
// Dev-only fast-refresh registry.
//
// Island bundles built with bundle-island.ts's dev-only `hot` flag route each
// top-level function component through __zHotRegister (the transform is
// sidecar/hot-transform.ts). The registered value is a STABLE proxy function:
// when the island is re-imported after an edit (hmr.ts -> islands.ts
// swapIsland), the new module registers its components again — same module
// key, same component name. If the build-time hook signature is unchanged the
// registry swaps the implementation INSIDE the existing proxy and returns the
// same function object, so Preact keeps the mounted component instance (and
// its hook state: plain useState/useReducer) and simply re-renders it with the
// new implementation. A changed signature mints a fresh proxy — a new vnode
// type — so Preact remounts (the plain hot-swap fallback) and can never replay
// old hook state against a different hook order.
//
// PROD-SAFE the same way installHmr is: exported from the barrel but inert —
// release bundles never contain the transform, so nothing ever calls this in
// production. Even if something did, a single registration is one function
// call of indirection with identical render semantics.
// ---------------------------------------------------------------------------

type AnyFn = (this: unknown, ...args: unknown[]) => unknown;

interface HotEntry {
  impl: AnyFn;
  signature: string;
  proxy: AnyFn;
  /** Static keys last copied from an impl onto the proxy, so a re-registration
   *  can drop statics the new implementation no longer carries. */
  copied: Set<string | symbol>;
}

/** Intrinsic function own-properties that must never be copied onto the proxy. */
const SKIP_STATICS = new Set<string | symbol>(["length", "name", "prototype", "arguments", "caller"]);

/**
 * Mirror the implementation's static properties (compound components like
 * `Card.Header`, `displayName`, `defaultProps`, symbols…) onto the stable
 * proxy. Without this, `Card.Header` would be undefined on the proxy and a
 * --hot dev bundle would silently render garbage where the release bundle is
 * correct. Statics dropped by a new implementation are removed again; the
 * default displayName (the registered component name) is restored when the
 * impl carries none of its own.
 */
function syncStatics(entry: HotEntry, name: string): void {
  const impl = entry.impl;
  const proxy = entry.proxy as AnyFn & Record<PropertyKey, unknown>;
  const keys = [
    ...Object.getOwnPropertyNames(impl),
    ...Object.getOwnPropertySymbols(impl),
  ].filter((k) => !SKIP_STATICS.has(k));
  const next = new Set<string | symbol>(keys);
  for (const k of entry.copied) {
    if (!next.has(k)) {
      try {
        delete proxy[k as never];
      } catch {
        /* non-configurable: leave it in place */
      }
    }
  }
  for (const k of keys) {
    const d = Object.getOwnPropertyDescriptor(impl, k);
    if (!d) continue;
    try {
      Object.defineProperty(proxy, k, { ...d, configurable: true });
    } catch {
      /* defensive: an uncopyable static must not break the swap */
    }
  }
  entry.copied = next;
  if (!Object.getOwnPropertyNames(proxy).includes("displayName")) {
    (proxy as { displayName?: string }).displayName = name;
  }
}

// Keyed by `${moduleKey}#${componentName}` — moduleKey is the island entry's
// absolute path (stable across rebuilds within a dev session).
const registry = new Map<string, HotEntry>();

/** Test-only: forget every registration (next register mints fresh identities). */
export function __resetHotRegistryForTest(): void {
  registry.clear();
}

/**
 * Register (or re-register) a component implementation. Returns the stable
 * proxy to export in place of the implementation. Non-functions and class
 * components are returned unchanged (never proxied — a class instance's
 * lifecycle can't be safely impl-swapped).
 */
export function __zHotRegister(
  impl: unknown,
  moduleKey: string,
  name: string,
  signature: string,
): unknown {
  if (typeof impl !== "function") return impl;
  const fn = impl as AnyFn & { prototype?: { render?: unknown }; defaultProps?: unknown };
  if (fn.prototype && typeof fn.prototype.render === "function") return impl;

  const key = moduleKey + "#" + name;
  const prev = registry.get(key);
  if (prev && prev.signature === signature) {
    // Same hook sequence: swap the implementation in place. The proxy identity
    // is unchanged, so the next render diffs against the SAME vnode type and
    // Preact keeps the component instance — plain hook state survives. Statics
    // (defaultProps, compound members, …) are re-mirrored from the new impl.
    prev.impl = fn;
    syncStatics(prev, name);
    return prev.proxy;
  }

  // First sighting, or the hook signature changed: a NEW identity forces a
  // remount (correctness over cleverness — never replay mismatched hook state).
  const entry: HotEntry = {
    impl: fn,
    signature,
    proxy: undefined as unknown as AnyFn,
    copied: new Set(),
  };
  const proxy: AnyFn = function (this: unknown, ...args: unknown[]) {
    return entry.impl.apply(this, args);
  };
  entry.proxy = proxy;
  syncStatics(entry, name);
  registry.set(key, entry);
  return proxy;
}
