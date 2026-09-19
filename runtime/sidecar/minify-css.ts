#!/usr/bin/env bun
// Pure CSS minification: each input uses its own Bun.build with external ["*"].
// No import bundling, URL rewriting, or cross-file output-name collisions.
// Legacy: minify-css.ts <input.css> <output.css>
// Batch: minify-css.ts --batch, stdin NDJSON {input, output} absolute path pairs.
// The caller sends all paths then closes stdin. CSS is processed sequentially,
// keeping only one stylesheet's build artifacts live at a time.
import { createInterface } from "node:readline";

async function minify(input: string, output: string): Promise<void> {
  const res = await Bun.build({
    entrypoints: [input],
    minify: true,
    // Pure minify: keep url()/@import targets external (path-preserving).
    external: ["*"],
  }).catch((error: unknown) => {
    // Bun may reject instead of returning success:false. Retain its detailed
    // diagnostics and name this input even when the exception is aggregate.
    console.error(error);
    throw new Error(`minify-css: failed to minify '${input}'`);
  });

  if (!res.success) {
    for (const message of res.logs) console.error(String(message));
    throw new Error(`minify-css: failed to minify '${input}'`);
  }

  const cssOut =
    res.outputs.find((o) => o.path.endsWith(".css")) ?? res.outputs[0];

  if (!cssOut) {
    console.error(`minify-css: no CSS output produced for '${input}'`);
    throw new Error(`minify-css: failed to minify '${input}'`);
  }

  // The BuildArtifact is Blob-compatible; Bun.write accepts it directly, avoiding
  // a full in-memory arrayBuffer() copy.
  await Bun.write(output, cssOut);
}

const args = process.argv.slice(2);
try {
  if (args.length === 1 && args[0] === "--batch") {
    for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
      const entry = JSON.parse(line);
      if (!entry || typeof entry.input !== "string" || !entry.input ||
          typeof entry.output !== "string" || !entry.output) {
        throw new Error("minify-css: expected {input, output} path pair");
      }
      await minify(entry.input, entry.output);
    }
  } else if (args.length === 2) {
    await minify(args[0]!, args[1]!);
  } else {
    console.error("usage: minify-css.ts <input.css> <output.css> | --batch");
    process.exit(2);
  }
} catch (error) {
  console.error(String(error));
  process.exit(1);
}
