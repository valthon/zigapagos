### Added

- **`docs/runtime-dependencies.md`** — what the standalone binary needs at run
  time, stated once instead of inferred. A table covering every command and the
  external programs it requires; when `zigapagos release` actually needs Bun
  (the condition is the *configuration*, not whether the site has islands — with
  `ZIGAPAGOS_RUNTIME_DIR` set, a site with none still spawns the sidecar); how
  the pinned ZigBase is resolved, cached and fetched, including the `curl` and
  `tar` the fetch shells out to; and what each distribution supplies. Notably:
  a release archive carries the binary alone, so islands and SPAs built from one
  need an `@z/runtime` tree pointed at by `ZIGAPAGOS_RUNTIME_DIR` — `@z/runtime`
  is `private: true` and cannot be installed from npm on its own.
- `tests/meta/runtime-deps-doc.sh` checks that page against the sources every
  claim came from: the command table against `src/main.zig`'s `Command` enum,
  the ZigBase pin and cache path against `src/cli/zigbase.zig`, the environment
  variable against `src/cli/release.zig`, `@z/runtime`'s privacy against
  `runtime/package.json`, the binary-only release archive against
  `build/release.zig`, and every flag the page names against the file that
  parses it.

### Fixed

- **The island-sidecar spawn diagnostics no longer send you to a `build.zig`
  that does not exist.** All three ENOENT messages ended by pointing at the
  consumer build API's `.islands` table, which is gone; they now name the flag
  that actually configures each input (`--bun`, `--island-sidecar`,
  `--island-src-dir`) and `ZIGAPAGOS_RUNTIME_DIR`. The interpreter message also
  claimed bun alone cannot enable islands on a toolchain-free install "because
  the sidecar script and `@z/runtime` come from that Zig build integration" —
  false for the npm path, which ships both, and true only of a release archive.
- **The README no longer claims a release archive "gets you the same thing" as
  the npm channel.** It does not: the archive is the binary alone, so it has
  neither Bun nor the `@z/runtime` tree that islands and SPAs need. The
  quick-start's "a plain content site needs neither it nor Bun" was ambiguous
  in the same direction — setting `ZIGAPAGOS_RUNTIME_DIR` is exactly what makes
  a content-only build require Bun, and `npx zigapagos` always sets it.
