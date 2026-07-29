### Added

- `zigapagos validate [OPTIONS]`: a fast, in-memory subset of `zigapagos release`'s checks (issue
  #45). Parses and analyzes the site — frontmatter/Ziggy schema, SuperMD parse, layout resolution,
  content-side `$link.page`/asset references, output-URL collisions, template SuperHTML/Scripty
  parse, the `:` directive lint, and template RENDER errors (a failing Scripty expression, a
  `$site.page(...)` naming no page) — WITHOUT bundling islands, spawning the Bun sidecar, or
  writing an output tree. It does not cover island SSR, the typed island props check, SPA route
  enumeration/spec checks, asset installation, or CSS minification — those stay `release`-only, so
  a green `validate` is a subset guarantee, not a green `release`. Measured (this repo's
  `examples/tsx-site`, warm caches): a content-only edit loop goes from `zig build`'s ~2s to
  `validate`'s ~0.02–0.03s — and unlike `zig build`, `validate` needs no `bun`, `node_modules`,
  `build.zig`, or consumer build graph, and never writes the output tree.
