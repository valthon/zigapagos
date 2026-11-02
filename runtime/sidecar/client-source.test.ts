import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readdirSync, statSync, utimesSync, truncateSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stripStaticPaths, clientSourcePlugin } from "./client-source.ts";
import { EMPTY_CONFIG } from "../scripts/z-runtime-config.ts";

test.each([false, true])("JavaScript JSX preserves Bun's default parsing (SPA=%s)", async (spa) => {
  const dir = mkdtempSync(join(tmpdir(), "z-jsx-loader-"));
  try {
    const file = join(dir, "entry.js");
    const source = "export const view = <div>Hello</div>;";
    writeFileSync(file, source);
    const options = {entrypoints: [file], external: ["react/jsx-runtime", "react/jsx-dev-runtime"]};
    const plain = await Bun.build(options);
    const checked = await Bun.build({...options, plugins: [clientSourcePlugin(EMPTY_CONFIG, spa, new Set())]});
    expect(checked.success).toBe(true);
    expect(await checked.outputs[0].text()).toBe(await plain.outputs[0].text());
    if (spa) {
      writeFileSync(file, source + " export const routes = [{path: '/:id', component: () => view, staticPaths: [{id: '42'}]}];");
      const stripped = await Bun.build({...options, plugins: [clientSourcePlugin(EMPTY_CONFIG, true, new Set())]});
      expect(stripped.success).toBe(true);
      expect(await stripped.outputs[0].text()).not.toContain("staticPaths");
    }
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

async function loadClient(source: string) {
  const dir = mkdtempSync(join(tmpdir(), "z-pruned-client-"));
  const file = join(dir, "client.mjs");
  try {
    writeFileSync(file, new Bun.Transpiler({loader: "ts"}).transformSync(source));
    return await import(file);
  } finally { rmSync(dir, {recursive: true, force: true}); }
}

test("staticPaths cache survives another process without loading the parser, invalidates edits and repairs corrupt entries", async () => {
  const dir = mkdtempSync(join(tmpdir(), "z-static-path-cache-"));
  const source = "export const title = 'before'; export const routes = [{path: '/:id', component: () => null, staticPaths: [{id: '42'}]}];";
  try {
    const first = await stripStaticPaths(source, "/fixture/app.tsx", dir);
    const worker = Bun.spawnSync({
      cmd: [process.execPath, "--eval", `
        import {mock} from 'bun:test';
        mock.module('typescript', () => ({createSourceFile() { throw new Error('cache miss loaded the parser'); }}));
        const {stripStaticPaths} = await import(process.env.Z_CACHE_MODULE);
        process.stdout.write(await stripStaticPaths(process.env.Z_CACHE_SOURCE, '/fixture/app.tsx', process.env.Z_CACHE_DIRECTORY));
      `],
      env: {...process.env, Z_CACHE_MODULE: join(import.meta.dir, "client-source.ts"), Z_CACHE_SOURCE: source, Z_CACHE_DIRECTORY: dir},
    });
    expect(worker.exitCode).toBe(0);
    expect(worker.stdout.toString()).toBe(first);
    const edited = await stripStaticPaths(source.replace("before", "after"), "/fixture/app.tsx", dir);
    expect(edited).toContain("after");
    expect(readdirSync(dir)).toHaveLength(2);
    for (const entry of readdirSync(dir)) writeFileSync(join(dir, entry), '{"code":"wrong","digest":"invalid"}');
    expect(await stripStaticPaths(source, "/fixture/app.tsx", dir)).toBe(first);
    expect(readdirSync(dir).every(name => name.endsWith(".json"))).toBe(true);
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

test.each(["entries", "bytes"])("staticPaths cache bounds %s on writes while keeping hits read-only", async (limit) => {
  const dir = mkdtempSync(join(tmpdir(), "z-static-path-retention-"));
  const source = "export const routes = [{path: '/:id', component: () => null, staticPaths: [{id: '42'}]}];";
  try {
    const first = await stripStaticPaths(source, "/fixture/app.tsx", dir);
    const hitPath = join(dir, readdirSync(dir)[0]);
    const hitStat = statSync(hitPath);
    writeFileSync(join(dir, "keep.json"), "unrelated file");
    for (let i = 0; i < (limit === "entries" ? 129 : 2); i++) {
      const path = join(dir, i.toString(16).padStart(64, "0") + ".json");
      writeFileSync(path, "stale");
      if (limit === "bytes") truncateSync(path, 17 * 1024 * 1024);
      utimesSync(path, new Date(0), new Date(i * 1000));
    }
    const before = readdirSync(dir);
    expect(await stripStaticPaths(source, "/fixture/app.tsx", dir)).toBe(first);
    expect(readdirSync(dir)).toEqual(before);
    expect(statSync(hitPath).mtimeMs).toBe(hitStat.mtimeMs);
    const edited = await stripStaticPaths(source.replace("42", "43"), "/fixture/app.tsx", dir);
    expect(edited).not.toContain("staticPaths");
    const entries = readdirSync(dir).filter(name => /^[a-f0-9]{64}\.json$/.test(name));
    expect(entries.length).toBeLessThanOrEqual(128);
    expect(entries.reduce((size, name) => size + statSync(join(dir, name)).size, 0)).toBeLessThanOrEqual(32 * 1024 * 1024);
    expect(readdirSync(dir)).toContain("keep.json");
    expect(entries).not.toContain("0".repeat(64) + ".json");
    expect(await stripStaticPaths(source.replace("42", "43"), "/fixture/app.tsx", dir)).toBe(edited);
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

test.each([false, true])("cache metadata resolution preserves compiler behavior (missing=%s)", (missing) => {
  const dir = mkdtempSync(join(tmpdir(), "z-static-path-dependency-"));
  try {
    // Use an isolated installation without compiler package metadata. Its
    // compiler either works or is absent, independently of the repo's install.
    for (const path of ["sidecar/client-source.ts", "scripts/lint-island-imports.ts", "scripts/z-runtime-config.ts", "scripts/react-alias.ts"]) {
      mkdirSync(join(dir, path.split("/")[0]), {recursive: true});
      copyFileSync(join(import.meta.dir, "..", path), join(dir, path));
    }
    const compiler = join(dir, "node_modules/typescript");
    mkdirSync(compiler, {recursive: true});
    if (!missing) writeFileSync(join(compiler, "index.js"), `export * from ${JSON.stringify(import.meta.resolve("typescript"))};`);
    const cache = join(dir, "cache");
    mkdirSync(cache);
    const worker = Bun.spawnSync({
      cmd: [process.execPath, "--eval", `
        const {stripStaticPaths} = await import(process.env.Z_CACHE_MODULE);
        try {
          process.stdout.write(await stripStaticPaths("export const routes = [{path: '/:id', component: () => null, staticPaths: []}];", '/fixture/app.tsx', process.env.Z_CACHE_DIRECTORY));
        } catch (error) {process.stderr.write(error.message); process.exitCode = 1;}
      `],
      env: {...process.env, Z_CACHE_MODULE: join(dir, "sidecar/client-source.ts"), Z_CACHE_DIRECTORY: cache},
    });
    if (missing) {
      expect(worker.exitCode).toBe(1);
      expect(worker.stderr.toString()).toContain("/fixture/app.tsx: separating staticPaths requires typescript");
      expect(worker.stderr.toString()).toContain("run bun install");
    } else {
      expect(worker.exitCode).toBe(0);
      expect(worker.stdout.toString()).not.toContain("staticPaths");
    }
    expect(worker.stderr.toString()).not.toContain("Cannot find module");
    expect(readdirSync(cache)).toHaveLength(0);
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

test.each(["readdirSync", "statSync", "rmSync"])("cache maintenance failures never fail a successful transform: %s", (operation) => {
  const dir = mkdtempSync(join(tmpdir(), "z-static-path-maintenance-"));
  try {
    // Force eviction so the removal fault exercises pruning, not temp cleanup.
    for (let i = 0; i < 129; i++) {
      const path = join(dir, i.toString(16).padStart(64, "0") + ".json");
      writeFileSync(path, "stale");
      utimesSync(path, new Date(0), new Date(0));
    }
    const worker = Bun.spawnSync({
      cmd: [process.execPath, "--eval", `
        import * as fs from 'node:fs';
        import {mock} from 'bun:test';
        const real = {...fs};
        const operation = process.env.Z_CACHE_OPERATION;
        const cache = process.env.Z_CACHE_DIRECTORY;
        let faulted = false;
        mock.module('node:fs', () => ({...real, [operation]: (...args) => {
          if (args[0] === cache || (String(args[0]).startsWith(cache + '/') && String(args[0]).endsWith('.json'))) {
            faulted = true;
            if (operation === 'readdirSync') {
              real.rmSync(cache, {recursive: true, force: true});
              return real.readdirSync(...args);
            }
            throw Object.assign(new Error('cache maintenance fixture'), {code: 'EACCES'});
          }
          return real[operation](...args);
        }}));
        const {stripStaticPaths} = await import(process.env.Z_CACHE_MODULE);
        const code = await stripStaticPaths("export const routes = [{path: '/:id', component: () => null, staticPaths: []}];", '/fixture/app.tsx', cache);
        process.stdout.write(JSON.stringify({code, faulted}));
      `],
      env: {...process.env, Z_CACHE_MODULE: join(import.meta.dir, "client-source.ts"), Z_CACHE_DIRECTORY: dir, Z_CACHE_OPERATION: operation},
    });
    expect(worker.exitCode).toBe(0);
    const result = JSON.parse(worker.stdout.toString());
    expect(result.faulted).toBe(true);
    expect(result.code).toContain("routes");
    expect(result.code).not.toContain("staticPaths");
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

test("cache read and write failures fall back without hiding transform errors", async () => {
  const dir = mkdtempSync(join(tmpdir(), "z-static-path-unwritable-"));
  try {
    const cache = join(dir, "not-a-directory");
    writeFileSync(cache, "blocked");
    const source = "export const routes = [{path: '/:id', component: () => null, staticPaths: []}];";
    expect(await stripStaticPaths(source, "/fixture/app.tsx", cache)).toBe(await stripStaticPaths(source, "/fixture/app.tsx"));
    await expect(stripStaticPaths("export const routes = [{...base, staticPaths: load()}]", "/fixture/app.tsx", cache)).rejects.toThrow(/cannot separate/);
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

test("staticPaths removes build-only imports, calls and helpers but preserves shared bindings", async () => {
  const out = await stripStaticPaths(`
    import { readFileSync } from 'node:fs';
    import { View } from './view';
    const secret = readFileSync('/private/BUILD_ONLY_SENTINEL', 'utf8');
    function enumerate() { return [{id: secret}]; }
    const shared = 'shared';
    export const routes = [{path: '/:id', component: View, staticPaths: () => enumerate().concat([{id: shared}])}];
    export const title = shared;
  `, "/fixture/app.tsx");
  expect(out).not.toContain("staticPaths");
  expect(out).not.toContain("node:fs");
  expect(out).not.toContain("BUILD_ONLY_SENTINEL");
  expect(out).not.toContain("enumerate");
  expect(out).toContain("shared");
  expect(out).toContain("./view");
});

test("shorthand enumeration is removed and a shadowed client name is retained", async () => {
  const out = await stripStaticPaths(`
    const staticPaths = [{ id: 'BUILD_ONLY' }];
    export const routes = [{path: '/:id', component: () => { const staticPaths = 'client'; return staticPaths; }, staticPaths}];
  `, "/fixture/app.tsx");
  expect(out).not.toContain("BUILD_ONLY");
  expect(out).toContain("'client'");
});

test.each(["enumerate", "enumerate as loadPaths"])("an exported enumeration helper remains valid: %s", async (specifier) => {
  const out = await stripStaticPaths(`
    const enumerate = () => [{id: '42'}];
    export {${specifier}};
    export const routes = [{path: '/:id', component: () => null, staticPaths: enumerate}];
  `, "/fixture/exported.ts");
  const mod = await loadClient(out);
  expect(mod[specifier.includes(" as ") ? "loadPaths" : "enumerate"]()).toEqual([{id: "42"}]);
  expect(mod.routes[0].staticPaths).toBeUndefined();
});

test("retained initializer side effects keep the bindings they reference", async () => {
  const out = await stripStaticPaths(`
    const ids = [{id: '42'}];
    const logged = globalThis.__zRetainedIds = ids;
    export const routes = [{path: '/:id', component: () => null, staticPaths: ids}];
  `, "/fixture/retained.ts");
  try {
    await loadClient(out);
    expect((globalThis as any).__zRetainedIds).toEqual([{id: "42"}]);
  } finally { delete (globalThis as any).__zRetainedIds; }
});

test("ambiguous spread route definitions fail instead of leaking enumeration", async () => {
  await expect(stripStaticPaths("export const routes = [{...base, staticPaths: load()}]", "/fixture/app.ts")).rejects.toThrow(/cannot separate/);
  await expect(stripStaticPaths("routes[0].staticPaths = load()", "/fixture/app.ts")).rejects.toThrow(/declared directly/);
  await expect(stripStaticPaths("const k = 'staticPaths'; export const routes = [{path: '/:id', [k]: load()}]", "/fixture/app.ts")).rejects.toThrow(/computed route keys/);
});

test("bundle policy checks transitive application imports and permits configured exceptions", async () => {
  const dir = mkdtempSync(join(tmpdir(), "z-client-policy-"));
  try {
    mkdirSync(join(dir, "node_modules/extra"), {recursive: true});
    writeFileSync(join(dir, "node_modules/extra/package.json"), JSON.stringify({name: "extra", main: "index.js"}));
    writeFileSync(join(dir, "node_modules/extra/index.js"), "export default 'ok'");
    writeFileSync(join(dir, "entry.ts"), "export {default} from './local'");
    writeFileSync(join(dir, "local.ts"), "import value from 'extra'; export default value");
    const build = (config = EMPTY_CONFIG) => Bun.build({entrypoints: [join(dir, "entry.ts")], plugins: [clientSourcePlugin(config, false, new Set())]});
    await expect(build()).rejects.toThrow("Bundle failed");
    expect((await build({...EMPTY_CONFIG, islandImports: {firstParty: ["extra"], npmCompat: []}})).success).toBe(true);
    // Parsing imports must not mistake documentation strings for imports.
    writeFileSync(join(dir, "local.ts"), `export default "import value from 'forbidden'"`);
    expect((await build()).success).toBe(true);
  } finally { rmSync(dir, {recursive:true, force:true}); }
});
