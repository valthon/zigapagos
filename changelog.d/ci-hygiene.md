### Internal

- CI no longer resolves an npm package at workflow runtime. `browser-e2e.yml`'s site job
  served the built site with `bunx serve`, which downloads whatever the registry has at
  the moment the job runs, in a repository that pins its toolchain in `mise.toml`, passes
  `--frozen-lockfile` to every `bun install` and materializes its Zig dependencies from
  hashes. It now uses `python3 -m http.server`, already present on every runner, and
  `tests/meta/ci-package-pins.sh` fails the build on an unpinned `npx` / `bunx` /
  `bun x` / `pnpm dlx` in any workflow so the hole cannot reopen. (#50)
