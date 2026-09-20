### Changed

- Pass a validated current-release source graph from SPA client bundling to the isolated runtime slicer instead of running a second discovery build when its complete config identity can be established. Unsupported config forms safely rediscover. Preserve standalone slicing and safe fallback behavior; add repeatable content/islands/SPA release benchmarks with output parity checks and raw samples.
