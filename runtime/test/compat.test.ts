import { test, expect } from "bun:test";
import * as compat from "@z/runtime/compat";
import * as compatClient from "@z/runtime/compat/client";

// @z/runtime/compat must expose the full preact/compat React surface so an
// allowlisted npm React component's `react` imports (aliased here, kept external)
// resolve to the ONE shared Preact. These are the APIs npm components import.
test("@z/runtime/compat re-exports the React hook + element surface", () => {
  for (const name of [
    "useState", "useEffect", "useLayoutEffect", "useRef", "useMemo",
    "useCallback", "useReducer", "useContext", "useImperativeHandle",
    "useSyncExternalStore", "useId",
    "createElement", "cloneElement", "createContext", "createRef",
    "forwardRef", "memo", "Component", "PureComponent", "Fragment",
    "Suspense", "isValidElement", "startTransition", "version",
  ] as const) {
    expect(compat[name], `compat.${name}`).toBeDefined();
  }
});

test("@z/runtime/compat default is the React object (createElement/useState on it)", () => {
  expect(compat.default).toBeDefined();
  expect(typeof compat.default.createElement).toBe("function");
  expect(typeof compat.default.useState).toBe("function");
});

test("the existing port-mapping shims still export alongside the React surface", () => {
  for (const name of ["FlagsProvider", "useExperiment", "makeSharedResource", "ReCAPTCHA", "useRecaptcha"] as const) {
    expect(compat[name], `compat.${name}`).toBeDefined();
  }
});

test("@z/runtime/compat/client exposes createRoot + hydrateRoot (react-dom/client)", () => {
  expect(typeof compatClient.createRoot).toBe("function");
  expect(typeof compatClient.hydrateRoot).toBe("function");
});

test("compat createElement produces a Preact vnode (one shared Preact)", () => {
  const vnode = compat.createElement("div", { id: "x" }, "hi") as any;
  // Preact vnodes carry a `type` and `props`; asserting the shape proves the
  // React-shaped createElement is backed by the vendored Preact.
  expect(vnode.type).toBe("div");
  expect(vnode.props.id).toBe("x");
});
