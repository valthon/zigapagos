### Added

- `zigapagos migrate --copy-assets DIR` now streams conventional framework public/static trees into a separate Zigapagos assets directory while preserving URL-relative paths and source immutability. Existing targets are never overwritten: repeat runs write `.new`, `.new.2`, and later review copies.
