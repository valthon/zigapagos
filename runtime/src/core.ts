// The vendored vdom+hooks core. The ONLY place Preact is imported; everything
// else in @z/runtime (and every island) imports from here, so the framework
// is swappable behind one stable surface.
export { h, Fragment, render, hydrate, createContext, cloneElement, Component } from "preact";
export type { VNode, ComponentChildren, ComponentType } from "preact";
// createPortal and useSyncExternalStore are React-compat APIs — they live in
// preact/compat, NOT preact/hooks. (Importing them from preact/hooks fails.)
export { createPortal, useSyncExternalStore, forwardRef, useImperativeHandle } from "preact/compat";
export {
  useState, useEffect, useLayoutEffect, useRef, useMemo,
  useCallback, useReducer, useContext,
} from "preact/hooks";
export { renderToString } from "preact-render-to-string";
