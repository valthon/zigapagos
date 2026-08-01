### Fixed

- `zigapagos release` now honours `ZIGAPAGOS_HOT_ISLANDS`, passing `--hot` to
  the island bundle driver when it is set. `build/bundles.zig` was the variable's
  only reader, so the two build paths disagreed: a rebuild driven through
  `zigapagos release` produced non-hot island bundles, and an island hot-swap
  silently reset every `useState` instead of preserving it.
