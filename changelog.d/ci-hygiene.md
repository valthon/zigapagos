### Internal

- CI no longer resolves an npm package at workflow runtime. `browser-e2e.yml`'s site job
  served the built site with `bunx serve`, which downloads whatever the registry has at
  the moment the job runs, in a repository that pins its toolchain in `mise.toml`, passes
  `--frozen-lockfile` to every `bun install` and materializes its Zig dependencies from
  hashes. It now uses `python3 -m http.server`, already present on every runner, and
  `tests/meta/ci-package-pins.sh` fails the build on an unpinned `npx` / `bunx` /
  `bun x` / `pnpm dlx` in any workflow so the hole cannot reopen. (#50)
- The branding gate takes an inline opt-out. `<!-- branding-ok: why -->` sanctions the
  upstream project's name on that line and `<!-- branding-ok:begin why -->` /
  `<!-- branding-ok:end -->` sanctions a block, for the cases where naming it literally is
  the accurate thing to do — this repository's fork-point tag is named after the upstream
  release it marks, so the passage in `CHANGELOG.md` explaining which tags exist here can
  now say so instead of gesturing at it. A reason is required, an unbalanced block fails,
  a marker that exempts nothing fails as stale, and every sanctioned mention is printed on
  success. The gate also no longer excludes itself from its own search, and
  `tests/branding.test.sh` pins each of those rules from both sides. (#60)
