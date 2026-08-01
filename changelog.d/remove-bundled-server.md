### Removed

- **The bundled live server is gone**, along with its `--proxy` reverse-proxy
  mode, the `serve` and `server` subcommands, and the bare-command entry point
  that started it (issue #56). `zigapagos` is a standalone executable, and a
  standalone executable has no default action: run bare it now prints its help
  and exits 0, which is what `npx zigapagos` does too. An argument that names no
  command prints the same menu and exits non-zero.
- `zigapagos.serve()` is removed from the consumer build API, together with
  `zigapagos.Proxy` and `Options.proxies`. The `serve` steps in `site/build.zig`
  and `examples/tsx-site/build.zig` went with it.

### Changed

- **`zigapagos dev` is zero-config.** Run it in a site directory with no
  arguments and it works:
  - `--site` defaults to `public`, the same directory a bare `zigapagos release`
    writes to;
  - the rebuild command defaults to *this binary's* own `release`, resolved by
    absolute path rather than by name on `PATH`, so an npm install and a
    downloaded release tarball both work (it was `zig build`, which named a
    toolchain a standalone user never installed);
  - the island/SPA source directories to watch are derived from the entries
    `release` discovers, so a component edit rebuilds without `--watch-dir`;
  - a missing `zigbase` is fetched from the pinned release into the cache
    (SHA256-verified) instead of failing with instructions. `--no-download`
    restores the previous behaviour for offline machines and for CI that pins
    its own binary. `zigapagos e2e` is unchanged: it still fetches only on
    `--download-zigbase`, because an unannounced network fetch in CI is a
    surprise rather than a convenience.
- `zigapagos init` now points a new site at `zigapagos dev` rather than at the
  bare command, and `zigapagos init --from-astro` no longer scaffolds a `serve`
  step into the generated `build.zig`.
- **`DevOptions.download_zigbase` is now `DevOptions.no_download`** in the
  consumer build API, following the flag it passes through. `zig build dev`
  fetches the pinned zigbase implicitly, exactly like `zigapagos dev`; set
  `.no_download = true` to make a missing binary fail instead.
  `E2eOptions.download_zigbase` is unchanged and still opt-in.
