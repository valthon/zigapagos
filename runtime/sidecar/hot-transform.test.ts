import { test, expect, describe } from "bun:test";
import { transformIslandForHot, hookSignaturesFor } from "./hot-transform.ts";

const KEY = "/abs/path/Counter.island.tsx";

describe("transformIslandForHot — rewrites", () => {
  test("named export default function is registered and re-exported through the proxy", () => {
    const src = `import { useState } from "@z/runtime";
export default function Counter() {
  const [n] = useState(0);
  return <div>{n}</div>;
}
`;
    const out = transformIslandForHot(src, "Counter.island.tsx", KEY);
    expect(out).not.toBe(src);
    expect(out).toContain("__zHotRegister");
    expect(out).toContain(JSON.stringify(KEY));
    expect(out).toContain(`Counter = __zigapagos_hot_register(Counter, ${JSON.stringify(KEY)}, "Counter", "useState");`);
    // The original `export default` modifiers are gone; the footer re-exports.
    expect(out).not.toMatch(/export default function/);
    expect(out.trimEnd().endsWith("export default Counter;")).toBe(true);
    // Exactly one default export remains.
    expect(out.match(/export default/g)?.length).toBe(1);
  });

  test("const arrow + trailing `export default Widget;` becomes var + footer re-export", () => {
    const src = `import { useState } from "@z/runtime";
const Widget = () => {
  const [n] = useState(1);
  return <span>{n}</span>;
};
export default Widget;
`;
    const out = transformIslandForHot(src, "Widget.island.tsx", KEY);
    expect(out).toContain("var Widget = () =>");
    expect(out).not.toContain("const Widget");
    // The ORIGINAL export assignment is removed; only the footer's remains.
    expect(out.match(/export default Widget;/g)?.length).toBe(1);
    expect(out.trimEnd().endsWith("export default Widget;")).toBe(true);
    expect(out).toContain('__zigapagos_hot_register(Widget');
  });

  test("anonymous default function export is returned byte-identical (unsupported => fallback)", () => {
    const src = `import { useState } from "@z/runtime";
export default function () {
  const [n] = useState(0);
  return <div>{n}</div>;
}
`;
    expect(transformIslandForHot(src, "Anon.island.tsx", KEY)).toBe(src);
  });

  test("anonymous default arrow export is returned byte-identical", () => {
    const src = `import { useState } from "@z/runtime";
export default () => {
  const [n] = useState(0);
  return <div>{n}</div>;
};
`;
    expect(transformIslandForHot(src, "AnonArrow.island.tsx", KEY)).toBe(src);
  });

  test("a component calling a custom hook imported from another file is NOT wrapped", () => {
    const src = `import { useThing } from "./hooks.ts";
export default function Widget() {
  const t = useThing();
  return <div>{t}</div>;
}
`;
    // Only component is unprovable => source unchanged (safe remount).
    expect(transformIslandForHot(src, "Widget.island.tsx", KEY)).toBe(src);
  });

  test("`X.useY()` property-access hook calls make the component non-preservable", () => {
    const src = `import * as R from "@z/runtime";
export default function Widget() {
  const [n] = R.useState(0);
  return <div>{n}</div>;
}
`;
    expect(transformIslandForHot(src, "Widget.island.tsx", KEY)).toBe(src);
  });

  test("class declarations and lowercase functions are untouched; inner capitalized component also wrapped", () => {
    const src = `import { useState } from "@z/runtime";
class Store { render() { return 1; } }
function helper() { return 2; }
function Inner() {
  const [x] = useState(0);
  return <b>{x}</b>;
}
export default function Outer() {
  const [n] = useState(0);
  return <div><Inner />{n}{helper()}</div>;
}
`;
    const out = transformIslandForHot(src, "Nested.island.tsx", KEY);
    expect(out).toContain('__zigapagos_hot_register(Inner');
    expect(out).toContain('__zigapagos_hot_register(Outer');
    expect(out).not.toContain('__zigapagos_hot_register(helper');
    expect(out).not.toContain('__zigapagos_hot_register(Store');
    expect(out.trimEnd().endsWith("export default Outer;")).toBe(true);
  });

  test("export function (named, no default) keeps its export and gets registered", () => {
    const src = `import { useState } from "@z/runtime";
export function Panel() {
  const [n] = useState(0);
  return <div>{n}</div>;
}
`;
    const out = transformIslandForHot(src, "Panel.island.tsx", KEY);
    expect(out).toContain("export function Panel");
    expect(out).toContain('__zigapagos_hot_register(Panel');
    expect(out).not.toContain("export default"); // no default was captured
  });

  test("a module with no wrappable component is returned unchanged", () => {
    const src = `export const answer = 42;\nfunction lower() { return 1; }\n`;
    expect(transformIslandForHot(src, "util.ts", KEY)).toBe(src);
  });
});

describe("hookSignaturesFor — signatures", () => {
  test("zero-hook JSX component has the empty (trivially preservable) signature", () => {
    const src = `export default function Static() { return <div>hi</div>; }\n`;
    expect(hookSignaturesFor(src, "Static.island.tsx").get("Static")).toBe("");
  });

  test("aliased runtime import normalizes to the ORIGINAL hook name", () => {
    const a = `import { useState as uS } from "@z/runtime";
export default function W() { const [n] = uS(0); return <i>{n}</i>; }
`;
    const b = `import { useState } from "@z/runtime";
export default function W() { const [n] = useState(0); return <i>{n}</i>; }
`;
    expect(hookSignaturesFor(a, "a.island.tsx").get("W")).toBe("useState");
    expect(hookSignaturesFor(a, "a.island.tsx").get("W")).toBe(
      hookSignaturesFor(b, "b.island.tsx").get("W"),
    );
  });

  test("@z/runtime subpath imports count as runtime hooks", () => {
    const src = `import { useState } from "@z/runtime/core";
export default function W() { const [n] = useState(0); return <i>{n}</i>; }
`;
    expect(hookSignaturesFor(src, "w.island.tsx").get("W")).toBe("useState");
  });

  test("hook ORDER is part of the signature", () => {
    const ab = `import { useState, useEffect } from "@z/runtime";
export default function W() { const [n] = useState(0); useEffect(() => {}, []); return <i>{n}</i>; }
`;
    const ba = `import { useState, useEffect } from "@z/runtime";
export default function W() { useEffect(() => {}, []); const [n] = useState(0); return <i>{n}</i>; }
`;
    const sa = hookSignaturesFor(ab, "w.island.tsx").get("W");
    const sb = hookSignaturesFor(ba, "w.island.tsx").get("W");
    expect(sa).toBe("useState,useEffect");
    expect(sb).toBe("useEffect,useState");
    expect(sa).not.toBe(sb);
  });

  test("initializer changes do NOT change the signature (fast-refresh semantics)", () => {
    const zero = `import { useState } from "@z/runtime";
export default function W() { const [n] = useState(0); return <i>{n}</i>; }
`;
    const str = `import { useState } from "@z/runtime";
export default function W() { const [n] = useState(""); return <i>{n}</i>; }
`;
    expect(hookSignaturesFor(zero, "w.island.tsx").get("W")).toBe(
      hookSignaturesFor(str, "w.island.tsx").get("W"),
    );
  });

  test("same-file custom hook expands recursively; editing ITS hooks changes callers' signatures", () => {
    const v1 = `import { useState } from "@z/runtime";
function useCounter() { const [n, setN] = useState(0); return [n, setN]; }
export default function W() { const [n] = useCounter(); return <i>{n}</i>; }
`;
    const v2 = `import { useState, useEffect } from "@z/runtime";
function useCounter() { const [n, setN] = useState(0); useEffect(() => {}, []); return [n, setN]; }
export default function W() { const [n] = useCounter(); return <i>{n}</i>; }
`;
    // v3 = v1 with only NON-hook code inside the local hook edited.
    const v3 = `import { useState } from "@z/runtime";
function useCounter() { const [n, setN] = useState(0); const twice = n * 2; return [twice, setN]; }
export default function W() { const [n] = useCounter(); return <i>{n}</i>; }
`;
    const s1 = hookSignaturesFor(v1, "w.island.tsx").get("W");
    const s2 = hookSignaturesFor(v2, "w.island.tsx").get("W");
    const s3 = hookSignaturesFor(v3, "w.island.tsx").get("W");
    expect(s1).toBe("useCounter{useState}");
    expect(s2).toBe("useCounter{useState,useEffect}");
    expect(s1).not.toBe(s2);
    expect(s3).toBe(s1); // non-hook edits inside the local hook are invisible
  });

  test("a local hook that itself calls an unprovable hook poisons its callers (null)", () => {
    const src = `import { useThing } from "./elsewhere.ts";
function useWrapped() { return useThing(); }
export default function W() { const t = useWrapped(); return <i>{t}</i>; }
`;
    expect(hookSignaturesFor(src, "w.island.tsx").get("W")).toBeNull();
  });

  test("mutually recursive local hooks are non-preservable (cycle guard)", () => {
    const src = `function useA(): number { return useB(); }
function useB(): number { return useA(); }
export default function W() { const n = useA(); return <i>{n}</i>; }
`;
    expect(hookSignaturesFor(src, "w.island.tsx").get("W")).toBeNull();
  });
});

describe("hookSignaturesFor — nested scopes are never flattened", () => {
  test("a nested component's hooks poison the outer signature (no cross-scope flattening)", () => {
    // v1: App's REAL hook list is [useState("hello")] — Inner's useState(0)
    // belongs to Inner's scope. v2 hoists Inner's state up: REAL hook list is
    // [useState(0), useState("hello")]. Flattening both to
    // "useState,useState" would let a preserving swap replay v1's slot-0
    // string state into v2's useState(0) — so v1 must be UNPROVABLE (null),
    // never signature-equal to v2.
    const v1 = `import { useState } from "@z/runtime";
export default function App() {
  const Inner = () => { const [a] = useState(0); return <b>{a}</b>; };
  const [b] = useState("hello");
  return <div>{b}<Inner /></div>;
}
`;
    const v2 = `import { useState } from "@z/runtime";
export default function App() {
  const [a] = useState(0);
  const [b] = useState("hello");
  const Inner = () => <b>{a}</b>;
  return <div>{b}<Inner /></div>;
}
`;
    expect(hookSignaturesFor(v1, "app.island.tsx").get("App")).toBeNull();
    expect(hookSignaturesFor(v2, "app.island.tsx").get("App")).toBe("useState,useState");
    // And the unprovable version is never wrapped at all.
    expect(transformIslandForHot(v1, "app.island.tsx", KEY)).toBe(v1);
  });

  test("nested function declarations and class methods with hook calls also poison", () => {
    const fnDecl = `import { useState } from "@z/runtime";
export default function App() {
  function Inner() { const [a] = useState(0); return <b>{a}</b>; }
  return <div><Inner /></div>;
}
`;
    expect(hookSignaturesFor(fnDecl, "app.island.tsx").get("App")).toBeNull();

    const cls = `import { useState } from "@z/runtime";
export default function App() {
  class Helper { grab() { return useState(0); } }
  return <div>{String(Helper)}</div>;
}
`;
    expect(hookSignaturesFor(cls, "app.island.tsx").get("App")).toBeNull();
  });

  test("hook-free nested callbacks (handlers, effect bodies) stay preservable", () => {
    const src = `import { useState, useEffect } from "@z/runtime";
export default function App() {
  const [n, setN] = useState(0);
  useEffect(() => { const t = setInterval(() => setN((v) => v + 1), 1000); return () => clearInterval(t); }, []);
  const onClick = () => setN(n + 1);
  return <button onClick={onClick}>{n}</button>;
}
`;
    expect(hookSignaturesFor(src, "app.island.tsx").get("App")).toBe("useState,useEffect");
  });

  test("a hook-shaped call inside a hook's own callback argument poisons", () => {
    // Illegal per the rules of hooks, but it must fail CLOSED — the callback
    // is a nested scope, not part of the component's provable sequence.
    const src = `import { useState, useMemo } from "@z/runtime";
export default function App() {
  const [n] = useState(0);
  const x = useMemo(() => { const [y] = useState(1); return y + n; }, [n]);
  return <div>{x}</div>;
}
`;
    expect(hookSignaturesFor(src, "app.island.tsx").get("App")).toBeNull();
  });
});

describe("hookSignaturesFor — lexical shadowing fails closed (AUD-022)", () => {
  test("a local const shadowing an imported hook name is NOT the runtime hook", () => {
    // v1's shadowing wrapper internally calls TWO runtime hooks; v2 calls one.
    // Both must be unprovable (null) — never a shared stable "useState" token —
    // so the registry can't swap v1's two hook slots against v2's one.
    const v1 = `import { useState } from "@z/runtime";
function makeCompat() { const [a] = useState(0); const [b] = useState(1); return () => a + b; }
export default function W() { const useState = makeCompat(); return <i>{useState()}</i>; }
`;
    const v2 = `import { useState } from "@z/runtime";
function makeCompat() { const [a] = useState(0); return () => a; }
export default function W() { const useState = makeCompat(); return <i>{useState()}</i>; }
`;
    expect(hookSignaturesFor(v1, "w.island.tsx").get("W")).toBeNull();
    expect(hookSignaturesFor(v2, "w.island.tsx").get("W")).toBeNull();
    // Unprovable => never wrapped.
    expect(transformIslandForHot(v1, "w.island.tsx", KEY)).toBe(v1);
  });

  test("a parameter shadowing an imported hook name fails closed", () => {
    const src = `import { useState } from "@z/runtime";
export default function W(useState) { return <i>{useState(0)}</i>; }
`;
    expect(hookSignaturesFor(src, "w.island.tsx").get("W")).toBeNull();
  });

  test("an unshadowed sibling call to the SAME import stays provable", () => {
    // Control: the import IS a real runtime hook when nothing shadows it.
    const src = `import { useState } from "@z/runtime";
export default function W() { const [n] = useState(0); return <i>{n}</i>; }
`;
    expect(hookSignaturesFor(src, "w.island.tsx").get("W")).toBe("useState");
  });
});
