import {
  h, Fragment, useMemo, useSyncExternalStore, host,
  initFlags, useVariant,
  type ComponentChildren, type VNode,
} from "@z/runtime";

export interface SharedResource<T> {
  prime(): void;
  use(): T | null;
  Provider(p: { children?: ComponentChildren }): VNode;
}

// Generalizes flags.ts for any host.fetchShared-backed shared store.
export function makeSharedResource<T>(opts: { store: string; url: string }): SharedResource<T> {
  // Module-stable subscribe (one per factory call, NOT per render — mirrors flags.ts:13).
  const subscribe = (cb: () => void): (() => void) => {
    const ctrl = new AbortController();
    host.store.subscribe(opts.store, cb, ctrl.signal);
    return () => ctrl.abort();
  };
  function prime(): void { host.fetchShared(opts.url, opts.store); } // host de-dupes
  function use(): T | null {
    const raw = useSyncExternalStore(subscribe, () => host.store.getStr(opts.store));
    if (!raw) return null;
    return host.store.getJson<T>(opts.store); // loud-fail on malformed
  }
  function Provider(p: { children?: ComponentChildren }): VNode {
    useMemo(() => prime(), []);                 // prime once on mount
    return h(Fragment, null, p.children);
  }
  return { prime, use, Provider };
}

// Drop-in for the pilot site's <FlagsProvider>. No context: primes the page-global flags
// store once (initFlags = host.fetchShared, de-duped + SSR no-op) and renders children.
export function FlagsProvider(props: { children?: ComponentChildren; url?: string }): VNode {
  useMemo(() => initFlags(props.url ?? "/api/flags/state"), [props.url]);
  return h(Fragment, null, props.children);
}

// useExperiment === useVariant (the pilot site's name for the same server-resolved read).
// Direct alias — same function reference, so `useExperiment === useVariant` holds.
export const useExperiment = useVariant;

// Re-exports so one `@legacy-app/shared/flags` import line → one `@z/runtime/compat` line.
export { useFlag, useVariant, FeatureFlag, Experiment } from "@z/runtime";

export { ReCAPTCHA, useRecaptcha, type RecaptchaHandle } from "./recaptcha.ts";

// The FULL preact/compat React surface, so an allowlisted npm React component's
// `react`/`react-dom` imports (aliased to @z/runtime/compat) resolve to the ONE
// shared Preact. Enumerated as explicit named re-exports rather than `export *`:
// preact/compat's types use `export =`, which TS forbids re-exporting via `export *`
// (core.ts re-exports it by name for the same reason). None of these overlap the
// shim exports above. `lazy` here is React.lazy — but note the CLIENT bundle
// (browser-entry.ts) resolves `lazy` to the router's (one shared bundle, one name);
// React.lazy is therefore not supported through the client bridge (see docs).
export {
  Children, Component, PureComponent, StrictMode, Suspense, SuspenseList,
  cloneElement, createContext, createElement, createFactory, createPortal, createRef,
  findDOMNode, flushSync, forwardRef, hydrate, isFragment, isMemo,
  isValidElement, lazy, memo, render, startTransition, unmountComponentAtNode,
  unstable_batchedUpdates, useCallback, useContext, useDebugValue, useDeferredValue,
  useEffect, useId, useImperativeHandle, useInsertionEffect,
  useLayoutEffect, useMemo, useReducer, useRef, useState, useSyncExternalStore,
  useTransition, version, Fragment,
} from "preact/compat";
// The React default object (React.createElement, React.useState, …), for npm
// components that `import React from "react"`.
import compatDefault from "preact/compat";
export default compatDefault;

