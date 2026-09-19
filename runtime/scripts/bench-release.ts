#!/usr/bin/env bun
// Generated frontend fixtures; no network, installation, or Zig compilation.
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, chmodSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { tmpdir, cpus, platform, arch } from "node:os";
import { createHash } from "node:crypto";
import { sourceIdentity as identifySource } from "./benchmark-source.ts";

const get = (name: string) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const binary = resolve(get("binary") ?? "zig-out/bin/zigapagos");
const baseline = get("baseline") ? resolve(get("baseline")!) : undefined;
const rounds = Number(get("rounds") ?? 5);
if (!Number.isSafeInteger(rounds) || rounds < 1) throw new Error("--rounds must be a positive integer");
const runtime = resolve(import.meta.dir, "..");
const root = mkdtempSync(join(tmpdir(), "zigapagos-release-bench-"));
const versions = baseline ? [{ name: "baseline", binary: baseline }, { name: "candidate", binary }] : [{ name: "candidate", binary }];
const results: unknown[] = [];
const repo = resolve(runtime, "..");
const sourceIdentity = identifySource(repo);
function write(path: string, data: string) { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, data); }
function inventory(dir: string): { digest: string; files: number; bytes: number } {
  const hash = createHash("sha256"); let files = 0, bytes = 0;
  function walk(rel: string) {
    for (const entry of readdirSync(join(dir, rel), { withFileTypes: true }).sort((a,b) => a.name.localeCompare(b.name))) {
      const path = join(rel, entry.name);
      if (entry.isDirectory()) walk(path);
      else { const content = readFileSync(join(dir, path)); hash.update(path).update("\0").update(content); files++; bytes += content.length; }
    }
  }
  walk(""); return { digest: hash.digest("hex"), files, bytes };
}
try {
  for (const kind of ["content", "islands", "spa"]) {
    const site = join(root, kind), output = join(site, "public"), calls = join(site, "bun-calls.txt");
    write(join(site, "zigapagos.ziggy"), 'Site { .title = "Benchmark", .host_url = "https://example.com", .content_dir_path = "content", .layouts_dir_path = "layouts", .assets_dir_path = "assets", }');
    write(join(site, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx", jsxImportSource: "@z/runtime", moduleResolution: "bundler" } }));
    write(join(site, "assets/style.css"), 'body { font-family: sans-serif; color: #333333; }');
    let islands = "";
    if (kind === "islands") for (let i = 0; i < 8; i++) {
      write(join(site, `components/Counter${i}.island.tsx`), `import {useState} from '@z/runtime'; export default function Counter(){const [n,set]=useState(${i});return <button onClick={()=>set(n+1)}>{n}</button>}`);
      islands += `<island src="components/Counter${i}.island.tsx" client:visible></island>`;
    }
    write(join(site, "layouts/page.shtml"), `<!doctype html><html><head><title :text="$page.title"></title><link rel="stylesheet" href="$site.asset('style.css').link()"></head><body><main :html="$page.content()"></main>${islands}</body></html>`);
    for (let i = 0; i < 40; i++) write(join(site, `content/${i ? "page-"+i : "index"}.smd`), `---\n.title = "Page ${i}",\n.layout = "page.shtml",\n---\n# Page ${i}\n\n` + "A repeatable content fixture with **formatting**, paragraphs, and a [link](https://example.com).\n\n".repeat(20));
    if (kind === "spa") {
      for (let i = 0; i < 24; i++) write(join(site, `app/View${i}.tsx`), `import {host} from '@z/runtime'; export default function View(){return <section>View ${i}: {typeof host.now}</section>}`);
      write(join(site, "app/Bench.spa.tsx"), `import {Router,lazy} from '@z/runtime'; export const spa={base:'/app',title:'Benchmark',head:[{rel:'stylesheet',href:'/style.css'}]}; export const routes=[{path:'/',component:()=> <h1>Application</h1>},${Array.from({length:24},(_,i)=>`{path:'v${i}',component:lazy(()=>import('./View${i}')),skeleton:()=> <p>Loading</p>}`).join(",")}]; export default function App(){return <Router routes={routes} base={spa.base}/>}`);
    }
    const wrapper = join(site, "bun-wrapper");
    write(wrapper, '#!/bin/sh\nprintf "%s\\n" "$1" >> "$BENCH_BUN_CALLS"\nexec "$BENCH_BUN" "$@"\n'); chmodSync(wrapper, 0o755);
    function run(version: (typeof versions)[number]) {
      writeFileSync(calls, ""); const start = performance.now();
      const child = Bun.spawnSync([version.binary, "release", "--force", "--css-minify", `--bun=${wrapper}`], { cwd: site, env: { ...process.env, ZIGAPAGOS_RUNTIME_DIR: runtime, BENCH_BUN: process.execPath, BENCH_BUN_CALLS: calls } });
      const milliseconds = performance.now() - start;
      if (child.exitCode !== 0) throw new Error(`${kind} ${version.name}: ${child.stderr.toString()}`);
      const drivers = readFileSync(calls,"utf8").trim().split("\n").filter(Boolean).map((p)=>p.replace(runtime+"/", ""));
      return { milliseconds, drivers, output: inventory(output) };
    }
    let expected: string | undefined;
    for (const condition of ["cold-output", "warm-output"]) {
      // Warm-output primes each implementation outside the timed samples.
      if (condition === "warm-output") for (const version of versions) run(version);
      for (let round = 0; round < rounds; round++) for (const version of round % 2 ? [...versions].reverse() : versions) {
        if (condition === "cold-output") { rmSync(output, {recursive:true,force:true}); rmSync(join(site,".zigapagos-cache"),{recursive:true,force:true}); }
        const sample = run(version);
        expected ??= sample.output.digest;
        if (sample.output.digest !== expected) throw new Error(`${kind}: output byte parity failed for ${version.name}/${condition}/${round}`);
        results.push({ fixture: kind, condition, round, version: version.name, ...sample });
      }
    }
  }
  console.log(JSON.stringify({ bun: Bun.version, sourceIdentity, buildInfo: get("build-info") ?? "prebuilt binaries; compiler details not supplied", platform: platform(), architecture: arch(), cpuModel: cpus()[0]?.model, logicalCores: cpus().length, binaries: versions.map((v)=>({ ...v, version: (() => { const p = Bun.spawnSync([v.binary,"--version"]); if (p.exitCode !== 0) throw new Error(`version query failed: ${v.binary}`); return (p.stdout.toString() + p.stderr.toString()).trim(); })(), sha256: createHash("sha256").update(readFileSync(v.binary)).digest("hex") })), fixture: { pages:40, paragraphsPerPage:20, islandEntries:8, spaLazyRoutes:24 }, rounds, order: "alternate baseline/candidate per round", conditions: "cold-output deletes output and project cache; warm-output retains them; OS page cache is not flushed", byteIdentical: true, results }, null, 2));
} finally { rmSync(root, {recursive:true,force:true}); }
