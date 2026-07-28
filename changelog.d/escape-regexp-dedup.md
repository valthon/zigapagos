### Internal

- Four byte-identical private copies of `escapeRegExp` in build-time TypeScript are
  gone, replaced by the right tool for each of the two contexts they were serving.
  The three JavaScript call sites (`lint-island-imports.ts`, `react-alias.ts`,
  `sidecar/bundle-island.ts`) now use the standard `RegExp.escape`, which is
  specified for exactly the ECMAScript `RegExp` position they feed. The fourth,
  `emit-host-config.ts`, emits Apache `RewriteRule` patterns — PCRE, a different
  dialect — so it gets a purpose-named `escapePcre` whose contract matches its
  output language and which keeps a deployed `.htaccess` readable
  (`^app/.*$`, not `^\x61pp/.*$`).
- Generated Apache config now has a validation net rather than only literal-string
  greps: `emit-host-config.test.ts` runs each emitted `RewriteRule` pattern through
  a real Perl-compatible regex engine and asserts it matches the URLs it should and
  rejects the near-misses an unescaped `.` would have swallowed. `buildAllow` gained
  the metacharacter-escaping test it never had.
