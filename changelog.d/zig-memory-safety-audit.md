### Fixed

- `zigapagos dev` no longer risks a crash or invalid free when overlapping watched
  directories refer to the same path with different spellings. Allocation failures and
  malformed input also fail cleanly instead of leaking or indexing out of bounds.
