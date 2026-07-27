### Internal

- The `typescript` devDependency is held below 7.0. TypeScript 7.0 is the Go rewrite and its
  npm package no longer ships the JavaScript compiler API, which `runtime/scripts/slice-host.ts`
  and `runtime/sidecar/hot-transform.ts` both parse with — on 7.0.2 the runtime suite drops from
  617 passing to 566 passing / 51 failing. The `tsc` CLI is unaffected, so the props-check gate
  in `src/islands/props_check.zig` would have survived; only the API consumers do not. The
  ceiling is a Dependabot `ignore` on `>=7.0.0` rather than a major-block, so TypeScript 6.x —
  the last line that still ships the compiler API — is still proposed.

- Dependabot no longer groups major version bumps with routine ones. The `bun` groups for
  `runtime/` are restricted to minor and patch, and a new `runtime-majors` group collects every
  major into its own pull request, so a breaking major can no longer block unrelated updates
  from merging. `github-actions` deliberately keeps its single group: every `uses:` is pinned to
  a bare major tag, so majors are the only update it can produce and splitting would reintroduce
  per-action pull-request spam.

- `happy-dom` and `@happy-dom/global-registrator` move to 20.11.0.
