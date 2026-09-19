#!/usr/bin/env bun
// Run: bun runtime/scripts/bench-css-minify.ts [stylesheet-count] [rounds]
// Measures only the CSS minify phase, including process startup and file I/O.
import { mkdtempSync, rmSync, mkdirSync, readFileSync } from "node:fs";
import { tmpdir, cpus, platform, arch } from "node:os";
import { join } from "node:path";

const count = Number(process.argv[2] ?? 40);
const rounds = Number(process.argv[3] ?? 5);
if (![count, rounds].every((v) => Number.isSafeInteger(v) && v > 0)) throw new Error("positive integer count and rounds required");
const dir = mkdtempSync(join(tmpdir(), "css-bench-"));
const driver = join(import.meta.dir, "../sidecar/minify-css.ts");
try {
  const pairs: Array<{ input: string; output: string }> = [];
  for (let i = 0; i < count; i++) {
    const input = join(dir, `${i}.css`);
    await Bun.write(input, `@import "/reset.css";\n` + Array.from({ length: 100 }, (_, j) => `.rule-${i}-${j} { color: #ff0000; padding: 10px 10px; background: url("/images/bg.png"); }\n`).join(""));
    pairs.push({ input, output: join(dir, "batch", `${i}.css`) });
  }
  mkdirSync(join(dir, "single"));
  function run(batch: boolean): number {
    const start = performance.now();
    const requests = batch ? [[process.execPath, driver, "--batch"]] : pairs.map((p, i) => [process.execPath, driver, p.input, join(dir, "single", `${i}.css`)]);
    for (const cmd of requests) {
      const p = Bun.spawnSync(cmd, { stdin: batch ? Buffer.from(pairs.map((p) => JSON.stringify(p)).join("\n") + "\n") : "ignore" });
      if (p.exitCode !== 0) throw new Error(p.stderr.toString());
    }
    return performance.now() - start;
  }
  // Warm both paths, then alternate their measurement order to reduce bias.
  run(false); run(true);
  const single: number[] = [], batch: number[] = [];
  for (let i = 0; i < rounds; i++) {
    if (i % 2 === 0) { single.push(run(false)); batch.push(run(true)); }
    else { batch.push(run(true)); single.push(run(false)); }
  }
  for (let i = 0; i < count; i++) {
    if (!readFileSync(pairs[i]!.output).equals(readFileSync(join(dir, "single", `${i}.css`)))) throw new Error(`output mismatch: ${i}`);
  }
  const median = (v: number[]) => [...v].sort((a, b) => a - b)[Math.floor(v.length / 2)]!;
  console.log(JSON.stringify({ bun: Bun.version, platform: platform(), architecture: arch(), cpuModel: cpus()[0]?.model ?? "unknown", logicalCores: cpus().length, stylesheets: count, rulesPerStylesheet: 100, rounds, processes: { single: count, batch: 1 }, milliseconds: { single, batch, singleMedian: median(single), batchMedian: median(batch) }, byteIdentical: true }, null, 2));
} finally {
  rmSync(dir, { recursive: true, force: true });
}
