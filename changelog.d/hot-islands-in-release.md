### Fixed

- `zigapagos release` now honours `ZIGAPAGOS_HOT_ISLANDS`, passing `--hot` to
  the island bundle driver when it is set. Nothing on the `release` path read
  the variable `zigapagos dev` sets, so a dev rebuild produced non-hot island
  bundles and an island hot-swap silently reset every `useState` instead of
  preserving it.
