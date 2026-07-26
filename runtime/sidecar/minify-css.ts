#!/usr/bin/env bun
//! Minify a single CSS asset with Bun.
//!
//! This is the CSS analogue of the island/SPA JS minify pass (`bundle-island.ts`
//! with `--minify`): the release-time site-asset install phase (`src/root.zig`)
//! shells out to `bun minify-css.ts <input.css> <output.css>` for every `.css`
//! asset it stages, so a zigapagos site ships CSS at the same gzip size an
//! esbuild/Vite build would.
//!
//! It is a PURE minification pass, NOT a bundle:
//!   - `external: ["*"]` keeps every `url(...)` and `@import` target verbatim —
//!     Bun neither resolves nor rewrites them, so `url_prefix` / any path the
//!     stylesheet already encodes is preserved byte-for-byte (only redundant
//!     quotes are normalised). Without this, Bun.build tries to resolve+hash
//!     referenced assets and fails on any absolute `url("/img/…")`.
//!   - Nothing is inlined across `@import`, so the output stays a drop-in
//!     replacement for the source file at the same install path.
//!
//! Exit codes: 0 = wrote minified output; 1 = Bun reported a CSS error (surfaced
//! on stderr, which the caller inherits); 2 = bad CLI usage.

export {}; // make this a module so top-level await typechecks

const [input, output] = process.argv.slice(2);

if (!input || !output) {
  console.error("usage: minify-css.ts <input.css> <output.css>");
  process.exit(2);
}

const res = await Bun.build({
  entrypoints: [input],
  minify: true,
  // Pure minify: keep url()/@import targets external (path-preserving).
  external: ["*"],
});

if (!res.success) {
  for (const message of res.logs) console.error(String(message));
  process.exit(1);
}

const cssOut =
  res.outputs.find((o) => o.path.endsWith(".css")) ?? res.outputs[0];

if (!cssOut) {
  console.error(`minify-css: no CSS output produced for '${input}'`);
  process.exit(1);
}

// The BuildArtifact is Blob-compatible; Bun.write accepts it directly, avoiding
// a full in-memory arrayBuffer() copy.
await Bun.write(output, cssOut);
