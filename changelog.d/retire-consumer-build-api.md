### Removed

- **The consumer zig-build API is gone.** `zigapagos.website()`, `zigapagos.e2e()`
  and `zigapagos.dev()`, the option types (`Options`, `Island`, `Spa`,
  `BuildAsset`, `E2eOptions`, `DevOptions`) and the whole `build/` half that
  served them no longer exist. A site is built by RUNNING the `zigapagos`
  binary; `zig build` builds zigapagos itself and nothing else. Nothing in a
  zigapagos project needs a Zig toolchain, a `build.zig`, a `build.zig.zon` or a
  `.path` dependency on this repository any more.

  The replacements, all of which already existed:

  | was | now |
  |---|---|
  | `zigapagos.website(b, .{ .islands = …, .spas = … })` | `zigapagos release --island=SRC --spa='SRC\|BASE'` |
  | `zigapagos.e2e(b, opts, .{})` + `zig build e2e -- CMD` | `zigapagos e2e --site=DIR -- CMD` |
  | `zigapagos.dev(b, opts, .{})` + `zig build dev` | `zigapagos dev` |
  | `Options.source_maps = true` | `zigapagos release --source-maps` |
  | `Options.not_found` | `--spa-not-found=NAME` |
  | `Options.build_assets` | `--build-asset=NAME PATH [--install=P \| --install-always=P]` |

- `zigapagos release --spa-chunks=` and `--spa-slice=` are removed. They existed
  to hand `release` bundles the build graph had already produced; it now builds
  them itself.
- `zigapagos init --from-astro --zigapagos-path` is removed with the
  `build.zig.zon` it filled in. The importer scaffolds a `build.sh` instead.

### Added

- **`zigapagos release` builds the per-site islands runtime slice.** The second
  pass over the built island bundles (`/islands/_runtime.js`) used to run only
  as a build-graph step, so a toolchain-free build silently shipped the full
  shared runtime to every island page.
- **`zigapagos release` emits host config and the strict-CSP artifacts.** The
  per-namespace server config (`.spa` marker + `zigbase.static_routes.zig`,
  `nginx.nginx.conf`, `.htaccess`) and the site-wide `csp.{nginx.conf,apache.conf,zigbase.txt}`
  are written over the finished output tree. Every npm-path build until now
  shipped a tree with neither, which loses SPA deep-link fallback and serves a
  CSP that blocks the site's own inline import map.
- `zigapagos release --source-maps`, replacing `Options.source_maps`. Still
  opt-in and off by default.

### Fixed

- **Island bundles are minified.** The build graph passed `--minify` to the
  shared runtime, both runtime slicers and every SPA bundle, and to islands
  alone did not. The four islands on this project's own marketing site shrink
  from 4113 to 2094 bytes.
