# Production build benchmarks

Measure complete release work for three generated fixtures:

- **Content:** 40 pages, 20 paragraphs each, one stylesheet.
- **Islands:** those pages plus eight independent interactive components per page.
- **SPA:** those pages plus an application root and 24 lazy routes with skeletons,
  a stylesheet, and transitive host usage.

The runner needs an already built Zigapagos executable and the matching runtime
with its dependencies installed. It does not download dependencies, compile Zig,
or include fixture generation in timed samples:

```sh
bun runtime/scripts/bench-release.ts \
  --binary=zig-out/bin/zigapagos --rounds=10 \
  '--build-info=Zig 0.16.0 ReleaseFast native'
```

Compare two executables against the same runtime tree:

```sh
bun runtime/scripts/bench-release.ts \
  --baseline=/tmp/zigapagos-before --binary=zig-out/bin/zigapagos --rounds=10 \
  '--build-info=Zig 0.16.0 ReleaseFast native; matching build flags' > result.json
```

Use matching compiler versions, optimization modes, and CPU targets. Build each
binary with `zig build -Doptimize=ReleaseFast` before running the comparison.
The runner reports binary versions/hashes, implementation source hashes, Bun
version, OS/architecture, CPU model/core count, every timing sample in execution
order, driver invocations, and output-tree hashes/file counts/bytes.
Source identity inventories all Git-tracked and nonignored untracked runtime
files, including scripts, sidecars, source, configuration, lockfiles, tests and
fixtures, plus `src/cli/release.zig`. The report lists this scope and excluded
dependency/build-output directory names. Staged and unstaged edits, additions,
and deletions within that scope mark it modified; deleted files have null hashes.
Installed dependency contents are not hashed (the runtime lockfile is).
Ignored untracked files are excluded, so keep implementation files tracked or
nonignored. Binary hashes separately identify the compiled executables.

**Cold-output** deletes the project output and `.zigapagos-cache` before each
sample. **Warm-output** primes each implementation outside the timed samples,
then retains output/cache across repeated builds. Neither condition flushes the
OS page cache or Bun's caches; neither claims a cold machine or fresh dependency
installation. Each release runs with `--force --css-minify`. The client staging
directory is rebuilt on every release in both implementations.

Comparisons alternate baseline/candidate order each round. A small shell wrapper
records Bun driver invocations and is included equally in both timings. Every
sample's complete output tree must match byte for byte, including filenames and
host artifacts; a mismatch fails the benchmark instead of producing a speedup.

## Removing repeated SPA source discovery

The client bundler already discovers the transitive SPA source graph. Previously,
the runtime-slicer process ran another `Bun.build` just to rediscover it. The
client driver now writes a current-release capture after its successful build;
the isolated slicer validates and reuses that graph. Entry, minification setting,
configuration identity, discovered config-file list, and source/config hashes
must match. Capture identity follows the complete relative, strict-JSON config
inheritance chain and canonical file paths. JSONC, package or array `extends`,
cycles, and config symlinks whose relative resolution is ambiguous disable reuse.
An absent, invalid, changed, or unsupported capture falls back to normal discovery.

Release clears client staging before every build and never consumes the artifact
if its producing driver fails. This is a handoff between adjacent stages, **not a
persistent cache**. It is not a substitute for package-resolution invalidation
across builds. No new public release option or persistent graph reuse is added.

The slicer still reads every captured code file and performs host-usage analysis.
Unreadable sources, unsupported usage, or unavailable TypeScript retain the safe
shared-runtime fallback. Standalone `build-spa-runtime.ts` callers keep their own
source-discovery build when no capture is supplied. Custom single-file island
drivers are unchanged.

The analyzer keeps its separate process because application module overrides
must not affect its compiler dependencies. A proposed single-process pipeline
failed when an application deliberately mapped `typescript` to its own module;
the isolated handoff preserves that legitimate application configuration.

Tests exercise a resolve-mapped lazy dependency using `host.now`, React-compat
fallback, missing optional TypeScript, an application TypeScript override,
linked source maps, route/chunk manifests, changed capture inputs, and a newly
broken import. They compare client and runtime bytes and instrument `Bun.build`:
**one duplicate discovery build is removed per SPA when configuration identity
can be established**, including safe runtime-fallback cases. Unsupported config
forms still build through normal discovery.
The process count remains six for this SPA fixture.

## Recorded comparison

The [raw samples](benchmarks/release-pipeline-2026-09-19.json) were collected on
Linux x64, Intel Core i9-13900K (32 logical cores), Bun 1.4.2, with both binaries
built using Zig 0.16.0 `ReleaseFast` and the default native target. The baseline
is revision `6f8105d`; the candidate is the implementation accompanying this
report, identified by source and binary hashes. Both executables use the same
runtime tree: the baseline performs independent discovery and the candidate
reuses the validated capture in its isolated slicer.

Median of ten trials per fixture, condition, and implementation:

| Fixture | Cold-output baseline / candidate | Warm-output baseline / candidate |
| --- | ---: | ---: |
| content | 26.47 ms / 26.50 ms | 21.70 ms / 21.67 ms |
| islands | 285.18 ms / 288.05 ms | 277.59 ms / 281.30 ms |
| spa | 204.29 ms / 202.94 ms | 207.38 ms / 199.62 ms |

The binary hashes were checked against the original matching ReleaseFast builds
before refreshing these 120 samples with the reviewed runtime. This historical
report used the earlier six-file source shortlist: its hashes identify those
files only, and its modified flag covers only that shortlist. The broader
runtime inventory described above was added afterward; the raw report and
measurements are preserved without claiming the newer provenance coverage.

All output-tree hashes matched. The duplicate-build-call reduction is deterministic;
the elapsed-time differences are observations from this machine, which was shared
with other development work. Small differences can be noise. This change does
not claim a general percentage speedup, improve content/island-only builds, or
represent large application workloads. The fixtures provide a repeatable baseline
for deciding which remaining build work is worth optimizing.
