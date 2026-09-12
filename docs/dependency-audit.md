# Dependency audit — 2026-09-12

Checked registry versions, upstream Git revisions, toolchain releases, and
GitHub Actions release tags. PR #217 was used only to identify the minimum
registrator update (20.12.0); its patch was not applied.

## Runtime and tools

| Dependency | Selected version | Result |
| --- | --- | --- |
| `@happy-dom/global-registrator` | 20.14.5 | Updated from 20.11.6; includes #217's update |
| `happy-dom` | 20.14.5 | Updated manifest and lockfiles together |
| `@types/bun` / `bun-types` | 1.4.2 | Updated from 1.4.0 |
| `@types/node` | 26.5.1 | Explicit runtime tooling requirement; shared by all three lockfiles |
| Bun | 1.4.2 | Updated from 1.3.14 in mise, CI, installer, and documentation |
| Ruby | 4.0.6 | Updated from 3.4.10; Rails analysis uses bundled Prism |
| Preact | 10.29.8 | Current stable release; 11 is a prerelease |
| `preact-render-to-string` | 6.7.0 | Current stable release |
| TypeScript | 6.0.3 | Latest compatible 6.x release; see below |
| Zig | 0.16.0 | Latest released compiler; 0.17 is a development series |
| ZigBase | 0.13.0 | Current release; existing CLI/install pin retained |

All three Bun lockfiles were resolved using Bun 1.4.2. The site and example
lockfiles were regenerated so their `file:` runtime dependency records carry
the new tooling requirements. This also updates transitive `ws` to 8.21.3.

Newer transitive majors of `entities` and `whatwg-mimetype` (including its
types) fall outside Happy DOM's declared ranges and were not forced through
overrides. Node and Undici types are aligned across all three lockfiles:

| Lockfile | `@types/node` | `undici-types` | Node types' Undici requirement |
| --- | --- | --- | --- |
| `runtime/bun.lock` | 26.5.1 | 8.9.0 | `~8.9.0` |
| `site/bun.lock` | 26.5.1 | 8.9.0 | `~8.9.0` |
| `examples/tsx-site/bun.lock` | 26.5.1 | 8.9.0 | `~8.9.0` |

The runtime explicitly requires `@types/node@^26.5.1` as a development
dependency. Its Node APIs are used throughout the build tooling; declaring
the requirement also prevents fresh consumer lockfiles from selecting the
registry's older `latest` tag (22.20.2). Version 26.5.1 is the highest stable
published Node types version checked and is tagged for TypeScript 6.0.
It upgrades runtime's original 26.0.1 and the consumers' original 26.2.0.
Undici types 8.9.0 follows its `~8.9.0` requirement; 8.10.2 is outside that
range. Every resolved npm package was compared with its corresponding base
lockfile, with no version downgrades remaining.

TypeScript 7.0.2's package root exports only `version` and `versionMajorMinor`,
verified from its published tarball. The runtime slicer and hot transform use
the JavaScript compiler API, including `createSourceFile`. Retain the existing
6.x requirement and Dependabot exclusion until those consumers are migrated.

## Zig packages

The full revisions and content hashes are in `build.zig.zon`. Upstream
development heads are not automatically compatible with released Zig.

| Package | Selected revision | Result |
| --- | --- | --- |
| Scripty | `77f2eac9d31e` | Latest revision before the Zig 0.17 migration |
| Tracy | `67d2d89e3510` | Already at upstream HEAD |
| MIME | `a2ed0cba3b14` | Already at upstream HEAD |
| Wuffs | `6fd35cb51e90` | Retained; subsequent changes require Zig 0.17 |
| Xcode frameworks | `62f660e82e4e` | Updated to upstream HEAD |
| SuperHTML | `39dc8b3681f1` | Latest revision before the Zig 0.17 migration |
| Zeit | `1b1c95b2282c` | Current `0.16` branch; includes Windows DST fixes |
| Flow Syntax | `42d51f7f5aeb` | Current `zig-0.16` branch |
| Ziggy | `fa265838bb38` | Latest `old` revision before the Zig 0.17 migration |
| SuperMD | `4132146450f1` | Retained; newer main requires Zig 0.17 |
| libwebp | 1.6.0 | Current stable release tag |

Transitive Zig pins remain owned by their upstream package manifests and were
resolved with `zig build --fetch=all`; no vendored source was edited.

## CI and fixtures

The existing moving major tags already cover the latest releases checked:
checkout 7.0.1, cache 6.1.0, upload-artifact 7.0.1, download-artifact 8.0.1,
setup-node 7.0.0, configure-pages 6.0.0, upload-pages-artifact 5.0.0,
deploy-pages 5.0.1, and mise-action 4.3.0.

Playwright and Chrome intentionally follow their current channels in CI.
Migration fixture Gemfiles and lockfiles describe historical input projects;
they are not installed application dependencies and were left intact.

## Validation

Native build, snapshots, single-threaded check, all Zig unit steps, runtime
tests, typecheck, and allocator contracts were rerun on base `8204568`.

- Native Zig build, unchanged snapshots, and `check -Dsingle-threaded` passed.
- All 20 Zig unit-suite steps passed: 3,535 test executions (some suites overlap).
- Bun: 758 runtime tests, typecheck, dependency gate, and 28 npm packaging tests passed.
- Frozen installs succeeded in runtime, site, and example trees.
- Marketing site and TSX example builds passed, including props checks.
- Chrome passed island interaction/slot hydration and all four SPA runtime
  hydration checks (public, admin, fallback, compat).
- Rails migration, presentation, parity, legacy-assets, and code highlighting
  integration checks passed with Ruby 4.0.6 and Bun 1.4.2.
- The aarch64 macOS executable cross-compiled and linked with the new SDK.
  The broader cross-target `check` was stopped after several minutes in the
  host props-test compile; that command passed an aarch64 target to its Ziggy
  dependency while keeping the test root native. Native props tests passed.
  No macOS runtime tests were executed on this Linux host.
- Formatting, installer pins/syntax, documentation, CI package pins, branding,
  confidentiality, allocator contracts, and diff-whitespace checks passed.

After aligning Node types, frozen installs, runtime tests, typecheck, npm
packaging tests, and both site builds were rerun successfully.
