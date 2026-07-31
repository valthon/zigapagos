### Added

- **npm distribution.** `npx zigapagos` now scaffolds, serves and builds a content
  site with no Zig toolchain. Three packages, released together at
  `build.zig.zon`'s version: `@zigapagos/cli-<platform>` carrying the prebuilt
  binary, `@zigapagos/cli` (canonical) resolving the right one at run time through
  `optionalDependencies`, and the unscoped `zigapagos` as a thin alias so `npx
  zigapagos` works. Prebuilt for macOS x64 and Linux x64 — the two targets
  `build/release.zig` ships. Every other host is refused with the reason rather
  than the bare fact, and arm64 (macOS or Linux) is refused rather than served the
  x64 binary: `npm install` fails with `EBADPLATFORM` because the launcher packages
  declare the `os`/`cpu` they have binaries for, so an unsupported host cannot end
  up with an install that looks clean and has no binary in it. **Everything builds
  from `npm i zigapagos` alone** — content, islands, native SPAs and `zigapagos dev`:
  `@zigapagos/cli` ships the `@z/runtime` sources and the Bun SSR sidecar, and
  declares `bun`, `typescript` and `@zigbase/server` as *optional* dependencies, so
  the tools it shells out to are installed rather than asked for. npm puts
  `node_modules/.bin` on `PATH`, and the launcher appends it to the child's, so the
  zigbase locator finds the server with no flag, no global install and nothing
  downloaded. `--omit=optional` still builds; it loses `dev`'s server and the SPA
  runtime slice. The remaining difference from a Zig build is caching, not
  capability. The published READMEs say so. See `npm/README.md`.

- The zigbase dependency is the **scoped** `@zigbase/server`, at exactly the
  `pinned_version` in `src/cli/zigbase.zig` (currently ZigBase `v0.12.0`) — the same
  release `--download-zigbase` fetches, so `zigapagos dev` runs one zigbase however
  it was installed. `npm/check-toolchain.mjs` fails the build if those two ever
  disagree.

### Internal

- The release target matrix is declared in three places — `build/release.zig`,
  `npm/cli/targets.json` and `release.yml`'s build matrix — and
  `npm/check-targets.mjs` now fails when they disagree, deriving each npm
  key/cpu/os and archive name from the zig triple rather than trusting the JSON.
  Wired into CI through `tests/npm/targets.sh` and into the release workflow before
  anything is packed. A stale `targets.json` would otherwise publish a platform
  package whose binary nobody built.
- `release.yml` gained an `npm-package` job that assembles and install-tests the
  packages from the archives the release already builds — on pull requests too, so
  a packaging defect is caught before a tag rather than by a published version that
  cannot be replaced. Publishing is a separate job gated on a `v*` tag, the
  `NPM_PUBLISH_ENABLED` repository variable and the `NPM_TOKEN` secret.
