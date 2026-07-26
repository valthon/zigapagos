import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validateCodegenConfig, loadCodegenConfig, DEFAULT_CONFIG } from "./codegen-config.ts";

test("absent config => openapi (default), unchanged behavior", () => {
  const missing = join(tmpdir(), "definitely-not-here-codegen.config.json");
  expect(loadCodegenConfig(missing)).toEqual(DEFAULT_CONFIG);
  expect(DEFAULT_CONFIG.mode).toBe("openapi");
});

test("explicit openapi mode ignores any zigbase block", () => {
  const cfg = validateCodegenConfig({ mode: "openapi", zigbase: { anything: true } });
  expect(cfg.mode).toBe("openapi");
  expect(cfg.zigbase).toBeUndefined();
});

test("missing mode field => openapi", () => {
  expect(validateCodegenConfig({}).mode).toBe("openapi");
});

test("zigbase mode requires a full zigbase block", () => {
  expect(() => validateCodegenConfig({ mode: "zigbase" })).toThrow(/requires a "zigbase" object/);
  expect(() =>
    validateCodegenConfig({ mode: "zigbase", zigbase: { genClientCmd: [], genClientCwd: "x", out: "y", apiPrefix: "/api" } }),
  ).toThrow(/genClientCmd must be a non-empty array/);
  expect(() =>
    validateCodegenConfig({ mode: "zigbase", zigbase: { genClientCmd: ["zig"], genClientCwd: "", out: "y", apiPrefix: "/api" } }),
  ).toThrow(/genClientCwd must be a non-empty string/);
});

test("zigbase mode parses a full block incl. optional producedPath", () => {
  const cfg = validateCodegenConfig({
    mode: "zigbase",
    zigbase: {
      genClientCmd: ["zig", "build", "gen-client"],
      genClientCwd: "../backend",
      out: "contract/generated/zbase.gen.ts",
      apiPrefix: "/api",
      producedPath: "clients/typescript/zbase.gen.ts",
    },
  });
  expect(cfg.mode).toBe("zigbase");
  expect(cfg.zigbase?.genClientCmd).toEqual(["zig", "build", "gen-client"]);
  expect(cfg.zigbase?.producedPath).toBe("clients/typescript/zbase.gen.ts");
});

test("producedPath is optional", () => {
  const cfg = validateCodegenConfig({
    mode: "zigbase",
    zigbase: { genClientCmd: ["zig"], genClientCwd: "b", out: "o", apiPrefix: "/api" },
  });
  expect(cfg.zigbase?.producedPath).toBeUndefined();
});

test("invalid mode string is rejected", () => {
  expect(() => validateCodegenConfig({ mode: "grpc" })).toThrow(/mode must be/);
});

test("loadCodegenConfig reads + validates a real file", () => {
  const dir = mkdtempSync(join(tmpdir(), "codegen-cfg-"));
  const p = join(dir, "codegen.config.json");
  writeFileSync(
    p,
    JSON.stringify({
      mode: "zigbase",
      zigbase: { genClientCmd: ["echo", "x"], genClientCwd: dir, out: "o.ts", apiPrefix: "/api" },
    }),
  );
  try {
    const cfg = loadCodegenConfig(p);
    expect(cfg.mode).toBe("zigbase");
    expect(cfg.zigbase?.genClientCwd).toBe(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
