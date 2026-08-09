### Internal

- `ReleaseFast` is now confined to the published release matrix (`build/release.zig`); build
  and test tooling is Debug (issue #63). The snapshot suite's `camera` helper was built
  `ReleaseFast`, and `build/config.zig` still carried a commented-out
  `.preferred_optimize_mode = .ReleaseFast` left over from the consumer build API that #108
  removed. The measurement behind it, taken on this repo's own site with isolated caches: a
  cold Debug build is 29s against ReleaseFast's 96s (link alone, 3s against 58s) and produces
  **byte-identical output** — so the optimization was buying nothing a contributor can
  observe except the wait.
