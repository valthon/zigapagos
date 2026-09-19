import { test, expect } from "bun:test";
import { mkdtempSync, cpSync, mkdirSync, symlinkSync, writeFileSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const runtime = join(import.meta.dir, "..");
function snapshot(dir: string): Record<string, string> {
  return Object.fromEntries(readdirSync(dir).sort().map((file) => [file, readFileSync(join(dir, file)).toString("base64")]));
}
for (const mode of ["mapped-lazy", "compat-fallback", "no-typescript", "typescript-override", "symlink-alias", "nested-config", "jsonc-config"]) {
  test(`SPA capture handoff preserves ${mode} bytes with conservative capture reuse`, () => {
    const dir = mkdtempSync(join(tmpdir(), "spa-pipeline-"));
    try {
      let activeRuntime = runtime;
      if (mode === "no-typescript") {
        activeRuntime = join(dir, "runtime-without-typescript");
        mkdirSync(activeRuntime);
        for (const part of ["src", "sidecar", "scripts", "package.json"]) cpSync(join(runtime, part), join(activeRuntime, part), { recursive: true });
        mkdirSync(join(activeRuntime, "node_modules"));
        for (const name of ["preact", "preact-render-to-string"]) symlinkSync(join(runtime, "node_modules", name), join(activeRuntime, "node_modules", name), "dir");
      }
      writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({compilerOptions:{jsx:"react-jsx",jsxImportSource:"@z/runtime"}}));
      if (mode === "nested-config") {
        writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({extends:"./middle.json"}));
        writeFileSync(join(dir, "middle.json"), JSON.stringify({extends:"./base.json"}));
        writeFileSync(join(dir, "base.json"), JSON.stringify({compilerOptions:{jsx:"react-jsx",jsxImportSource:"@z/runtime"}}));
      }
      if (mode === "jsonc-config") writeFileSync(join(dir,"tsconfig.json"), '{/* config */ "compilerOptions":{"jsx":"react-jsx","jsxImportSource":"@z/runtime"}}');
      if (mode === "symlink-alias") symlinkSync(dir, join(dir,"alias"), "dir");
      writeFileSync(join(dir, "z-runtime.config.json"), JSON.stringify({ resolve: { "@fixture/helper": "./helper.ts" } }));
      if (mode === "typescript-override") {
        writeFileSync(join(dir, "fake-typescript.ts"), "export const version='app-local';");
        writeFileSync(join(dir, "z-runtime.config.json"), JSON.stringify({resolve:{"@fixture/helper":"./helper.ts",typescript:"./fake-typescript.ts"}}));
      }
      writeFileSync(join(dir, "helper.ts"), "import {host} from '@z/runtime'; export const label=()=>typeof host.now;");
      writeFileSync(join(dir, "Lazy.tsx"), mode !== "compat-fallback"
        ? "import {label} from '@fixture/helper'; export default function Lazy(){return <p>{label()}</p>}"
        : "import {useState} from 'react'; export default function Lazy(){const [n]=useState(1);return <p>{n}</p>}");
      const entry = join(dir, mode === "symlink-alias" ? "alias/App.spa.tsx" : "App.spa.tsx");
      writeFileSync(entry, "import {Router,lazy} from '@z/runtime'; export const spa={base:'/app'}; export const routes=[{path:'lazy',component:lazy(()=>import('./Lazy'))}]; export default function App(){return <Router routes={routes} base={spa.base}/>}");
      if (mode === "typescript-override") writeFileSync(entry, "import {version} from 'typescript'; " + readFileSync(entry,"utf8").replace('<Router routes={routes} base={spa.base}/>','<div>{version}<Router routes={routes} base={spa.base}/></div>'));
      const count = join(dir, "count.txt"), preload = join(dir,"count.ts");
      writeFileSync(preload, `import {appendFileSync} from 'node:fs'; const build=Bun.build; Bun.build=(...args)=>{appendFileSync(${JSON.stringify(count)},'build\\n');return build(...args)};`);
      const out = join(dir,"client"), sliced = join(dir,"runtime");
      const run = (driver: string, args: string[]) => {
        const child = Bun.spawnSync([process.execPath,"--preload",preload,driver,...args], {cwd:dir,env:{...process.env,NODE_ENV:"production"}});
        if(child.exitCode!==0) throw new Error(child.stderr.toString());
      };
      const bundleArgs = [`--entry=${entry}`,`--entry-name=app.js`,`--outdir=${out}`,`--chunks-json=${dir}/chunks.json`,`--depfile=${dir}/client.d`,"--external=@z/runtime","--external=@z/runtime/jsx-runtime","--minify","--sourcemap"];
      run(join(activeRuntime,"sidecar/bundle-standalone.ts"),bundleArgs);
      const runtimeArgs = [`--entry=${entry}`,`--spa-entry=${activeRuntime}/src/spa-entry.ts`,`--host-module=${activeRuntime}/src/host.ts`,`--ssr-env-module=${activeRuntime}/src/ssr-env.ts`,`--outdir=${sliced}`,"--name=app",`--manifest=${dir}/slice.json`,`--depfile=${dir}/runtime.d`,"--minify","--sourcemap"];
      run(join(activeRuntime,"scripts/build-spa-runtime.ts"),runtimeArgs);
      const expected = { client:snapshot(out), runtime:snapshot(sliced), chunks:readFileSync(join(dir,"chunks.json"),"utf8"), manifest:readFileSync(join(dir,"slice.json"),"utf8") };
      const oldCount = readFileSync(count,"utf8").trim().split("\n").length;
      rmSync(out,{recursive:true});rmSync(sliced,{recursive:true});writeFileSync(count,"");
      run(join(activeRuntime,"sidecar/bundle-standalone.ts"),[...bundleArgs,`--source-capture=${dir}/sources.json`]);
      run(join(activeRuntime,"scripts/build-spa-runtime.ts"),[...runtimeArgs,`--source-capture=${dir}/sources.json`]);
      expect({client:snapshot(out),runtime:snapshot(sliced),chunks:readFileSync(join(dir,"chunks.json"),"utf8"),manifest:readFileSync(join(dir,"slice.json"),"utf8")}).toEqual(expected);
      expect(readFileSync(count,"utf8").trim().split("\n").length).toBe(mode === "jsonc-config" ? oldCount : oldCount-1);
      if(mode!=="compat-fallback" && mode!=="no-typescript") {
        expect(JSON.parse(expected.manifest).members).toContain("now");
        expect(Object.keys(JSON.parse(expected.chunks).routeChunks)).toContain("/lazy");
        expect(readFileSync(join(dir,"runtime.d"),"utf8")).toContain("helper.ts");
      } else expect(JSON.parse(expected.manifest)).toEqual({fallback:true});
      if (mode === "nested-config") {
        // Changing only the deepest inherited config invalidates the handoff.
        writeFileSync(join(dir,"base.json"),JSON.stringify({compilerOptions:{jsx:"react-jsx",jsxImportSource:"@z/runtime",strict:true}}));
        writeFileSync(count, "");
        run(join(activeRuntime,"scripts/build-spa-runtime.ts"),[...runtimeArgs,`--source-capture=${dir}/sources.json`]);
        expect(readFileSync(count,"utf8").trim().split("\n").length).toBe(2);
      }
      // A fresh source error must fail; it cannot reuse the previous successful capture.
      writeFileSync(join(dir,"Lazy.tsx"),"import './missing-source'; export default ()=>null;");
      expect(()=>run(join(activeRuntime,"sidecar/bundle-standalone.ts"),[...bundleArgs,`--source-capture=${dir}/sources.json`])).toThrow();
      // A standalone consumer handed the old artifact must rediscover the graph.
      expect(()=>run(join(activeRuntime,"scripts/build-spa-runtime.ts"),[...runtimeArgs,`--source-capture=${dir}/sources.json`])).toThrow();
    } finally {rmSync(dir,{recursive:true,force:true});}
  },30000);
}
