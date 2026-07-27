### Internal

- The four byte-identical private copies of `escapeRegExp` in build-time TypeScript
  (`emit-host-config.ts`, `lint-island-imports.ts`, `react-alias.ts`,
  `sidecar/bundle-island.ts`) collapse into one exported
  `runtime/scripts/escape-regexp.ts`, now with a unit test that pins both the
  metacharacters it escapes and the ones it deliberately leaves literal. That
  asymmetry is what separates it from ES2025 `RegExp.escape`, which is *not* a
  drop-in here: its output spells the same match differently
  (`\x61\x2db\.c\/d\$e` vs `a-b\.c/d\$e`) and `emit-host-config.ts` interpolates
  the result into generated nginx/Apache config that ships as a build artifact.
