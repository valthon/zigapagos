### Fixed

- A failed island-sidecar spawn now names the input that is actually missing. A `bun` that is
  not on `PATH` previously produced `failed to spawn island sidecar (bun …/render.ts):
  FileNotFound`, which reads as "render.ts is missing" about a path that resolves; the
  interpreter, the sidecar script and the island source dir are now reported separately, each
  with the fix for that specific case.
