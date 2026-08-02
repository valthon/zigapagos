### Added

- A shell installer, `curl -fsSL https://valthon.github.io/zigapagos/install.sh | sh`, now the
  headline install method on the README and the download page. It installs a **complete**
  zigapagos — the binary, the `@z/runtime` tree it renders islands and SPAs through, and Bun and
  ZigBase when the host has neither — under `~/.local/share/zigapagos`, with a generated launcher
  in `~/.local/bin`. No `sudo`, no edits to shell startup files, and nothing written until each
  download has been verified against the release's published SHA-256 sums. It is idempotent: a
  second run installs alongside the first and repoints the launcher. `--version`, `--prefix`,
  `--bin-dir`, `--no-bun` and `--no-zigbase` cover the rest. Windows hosts are refused with the
  same wording the npm package uses, rather than being given an emulated build that looks native.
- A `runtime.tar.xz` release asset: the `@z/runtime` tree with its dependencies vendored. This is
  what makes an install outside npm able to render an island at all — the per-target archives
  carry the binary alone, and the sidecar, bundlers and slicers are scripts inside that tree. It
  is staged by the same code that stages npm's copy (`npm/stage-runtime.mjs`), so the two
  channels ship the same files by construction.

### Changed

- `docs/runtime-dependencies.md`'s distribution table gains an `install.sh` column, and its
  gate (`tests/meta/runtime-deps-doc.sh`) gains a rule that fails the build if that column
  ever describes a script or an asset that no longer exists.
