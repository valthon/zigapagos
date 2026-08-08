### Security

- The declared `preact-render-to-string` range is raised from `^6.6.2` to `^6.7.0`, whose
  attribute serializer rejects unsafe attribute *keys* before namespace normalization
  (preactjs/preact-render-to-string#461). Under 6.6.x a key that looked namespaced but
  contained `>` or spaces was rewritten and emitted — markup injection through prop keys on
  the SSR path that renders every island. Committed lockfiles already resolved 6.7.0, so
  sites built from this repository's locked toolchain were never affected; the raised floor
  closes the window for fresh resolutions (including the published npm package, whose
  dependency ranges derive from this manifest).

### Changed

- The pinned toolchain moves from Bun 1.2.23 (the final release of the discontinued 1.2
  line) to Bun 1.3.14, and the pin is now exact — `bun = "1.3.14"` — because Bun minors
  change the bundler's minified-identifier allocation and therefore emitted chunk content
  hashes. Which is also the migration note: the first rebuild under 1.3.14 renames every
  content-hashed bundle (`app.spa-<hash>.js`, lazy chunks), so a deploy that syncs without
  deleting (rsync sans `--delete`) will retain stale chunks alongside the new ones.
  `install.sh` and the npm package's `bun` dependency follow the pin. The shipped runtime
  also picks up preact 10.29.8 (flushSync batching fix, faster memo/sCU bailouts).
- Syntax highlighting advances flow-syntax to its maintained `zig-0.16` branch: query
  directives no longer mis-evaluate, a crash in `get_cached_query` on tree-sitter-less
  builds is fixed, and Vue and GLSL grammars land alongside `*.S` assembly recognition.

### Internal

- `build.zig.zon` drops `lsp_kit` and `translate_c`, inherited from upstream's LSP build
  and consumed by nothing; `scripts/rescue-codeberg.sh` now warms the one remaining
  Codeberg-hosted pin (SuperMD's transitive translate-c) and was verified against a fresh
  cache under strace: zero Codeberg DNS queries or connections from warm through
  `zig build --fetch`, and the warmed cache resolves fully offline.
- CI workflow actions are unified on current majors (upload-artifact v7, download-artifact
  v8, setup-node v7 — clearing the fall-2026 Node 20 runner removal), and Dependabot now
  ignores jdx/mise-action minors/patches, whose tagging scheme otherwise makes it propose
  stale concrete pins against the moving `@v4` tag (PR #125's `@v4.2.3` while `v4` already
  pointed at 4.2.4).
- happy-dom moves to 20.11.2 (MutationObserver callbacks no longer silently die after a
  GC — the flaky-test kind of latent bug), and the site/ and examples/tsx-site lockfiles
  are regenerated pinned to `configVersion: 0`, keeping Bun's hoisted linker so the
  props-check gate's website-root `tsc` resolution cannot silently flip layouts.
