export {
  h, Fragment, useState, useEffect, useLayoutEffect, useRef, useMemo,
  useCallback, useReducer, useContext, useSyncExternalStore, createContext,
  createPortal, forwardRef, useImperativeHandle,
} from "./core.ts";
export type { VNode, ComponentChildren, ComponentType } from "./core.ts";
export { host } from "./host.ts";
export { apiFetch } from "./api.ts";
export { zbGuard } from "./zb-guard.ts";
export type { ZbGuardOptions } from "./zb-guard.ts";
export { useFlag, useVariant, FeatureFlag, Experiment, initFlags } from "./flags.ts";
export { bootIsland, initIslands, swapIsland, mountedIslands } from "./islands.ts";
export type { IslandRecord } from "./islands.ts";
export { installHmr, applyIslandUpdate } from "./hmr.ts";
export type { HmrGlobal } from "./hmr.ts";
// Dev-only fast-refresh registry — called ONLY by island bundles
// built with the dev `hot` transform (sidecar/hot-transform.ts); inert in prod.
export { __zHotRegister } from "./hot-registry.ts";
export type { Slots } from "./slots.ts";
export {
  Router, Link, Outlet, lazy, navigate, matchChain, matchRoute, useParams, useLocation,
  useNavigate, useSearchParams, useGuardData, setScrollRestoration, mountSpa,
  resolveHref, isExternalHref,
} from "./router.ts";
export type {
  RouteDef, Match, GuardResult, GuardLocation, SearchParamsInit, SetSearchParams,
} from "./router.ts";
export { isServer } from "./ssr-env.ts";
export { useRestorableState, onBeforeReload } from "./dev-reload.ts";
export type { RestorableState } from "./dev-reload.ts";
export { initErrorRelay, ErrorBoundary } from "./errors.ts";
export type { ErrorKind, ErrorRecord, InitErrorRelayOptions, ErrorBoundaryProps } from "./errors.ts";
export { initObservability, httpAdapter, parseStack } from "./observability.ts";
export type {
  InitObservabilityOptions, ObservabilityAdapter, ObservabilityEvent,
  ErrorPayload, PerfPayload, StackFrame, HttpAdapterOptions,
} from "./observability.ts";
