import { test, expect } from "bun:test";
import { resolve, join } from "node:path";
import { tmpdir } from "node:os";
import { mkdtempSync, rmSync } from "node:fs";

// The shared runtime bundle (/zigapagos-runtime.js, built from browser-entry.ts)
// is what the import-map maps `@z/runtime/compat` AND `react` to. If a
// compat-ONLY name were dropped from browser-entry's export surface — e.g. by a
// stray second `export *` colliding with the barrel (Bun SILENTLY drops the
// overlap) or by an editing slip — an npm React component's `import { memo }
// from "react"` would resolve to `undefined` at runtime. compat.test.ts only
// checks the compat/index.ts SOURCE, and the Widget e2e only exercises `useState`
// (a barrel name), so this guards the compat-only surface OF THE BUILT BUNDLE.
test("the BUILT shared runtime bundle exports the compat-only React surface", async () => {
  const entry = resolve(import.meta.dir, "../src/browser-entry.ts");
  const dir = mkdtempSync(join(tmpdir(), "z-be-"));
  try {
    const res = await Bun.build({ entrypoints: [entry], format: "esm", target: "browser" });
    expect(res.success).toBe(true);
    const outPath = join(dir, "runtime.mjs");
    await Bun.write(outPath, await res.outputs[0].text());
    const mod: Record<string, unknown> = await import(outPath);

    // compat-ONLY names (NOT in the @z/runtime barrel) — a regression here means a
    // dropped export in the shipped bundle.
    for (const name of [
      "memo", "createElement", "Component", "PureComponent", "cloneElement",
      "createRoot", "hydrateRoot",
    ]) {
      expect(typeof mod[name], `bundle export ${name}`).toBe("function");
    }
    // `version` is a string value in preact/compat — assert it is exported at all.
    expect(mod.version === undefined).toBe(false);
    // The React default object (import React from "react") must be present.
    expect(mod.default).toBeDefined();
    expect(typeof (mod.default as any).createElement).toBe("function");
    // A barrel name must STILL be present (proves no overlap-drop of shared names).
    expect(typeof mod.useState).toBe("function");
    // The router owns `lazy` in the shared bundle (React.lazy unsupported via bridge).
    expect(typeof mod.lazy).toBe("function");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
