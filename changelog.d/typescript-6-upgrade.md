### Internal

- The `typescript` devDependency moves 5.9.3 → 6.0.3, the final JavaScript-based TypeScript
  line. The compiler API that `runtime/scripts/slice-host.ts` and
  `runtime/sidecar/hot-transform.ts` parse with is fully present, so neither needed
  re-platforming, and the runtime suite is unchanged at 617 passing. `site/bun.lock` and
  `examples/tsx-site/bun.lock` are regenerated in step: each embeds its own copy of
  `@z/runtime`'s resolved dependencies and bun does not refresh them for a linked package on a
  plain install, so left alone they would have kept the props-check gate running 5.9.3 while the
  runtime was tested on 6.0.3.

- TypeScript 7.x is capped out via a Dependabot `ignore` on `>=7.0.0`. 7.0 is the Go rewrite and
  its npm package no longer ships the JavaScript compiler API — `import ts from "typescript"`
  resolves to `lib/version.cjs` and yields only `{version, versionMajorMinor}`, taking the
  runtime suite to 566 passing / 51 failing. The cap is deliberately a version bound rather than
  a major-block, which is what let 6.x through. It lifts when a 7.x ships a usable programmatic
  API (7.1 at the earliest).

- The `tsconfig.json` files were audited against TypeScript 6.0's deprecation list and needed no
  changes: none uses `baseUrl`, `outFile`, `downlevelIteration`, `target: es5`,
  `moduleResolution: node|node10|classic`, `module: amd|umd|system|none`, or an explicitly false
  `esModuleInterop` / `allowSyntheticDefaultImports` / `alwaysStrict`. No source file uses the
  `module` namespace keyword or import `assert` syntax. `ignoreDeprecations` is therefore not
  needed, and the config surface is already clean for whatever 7.x removes.

- Dependabot no longer groups major version bumps with routine ones. The `bun` groups for
  `runtime/` are restricted to minor and patch, and a new `runtime-majors` group collects every
  major into its own pull request, so a breaking major can no longer block unrelated updates
  from merging. `github-actions` deliberately keeps its single group: every `uses:` is pinned to
  a bare major tag, so majors are the only update it can produce and splitting would reintroduce
  per-action pull-request spam.

- `happy-dom` and `@happy-dom/global-registrator` move to 20.11.0.
