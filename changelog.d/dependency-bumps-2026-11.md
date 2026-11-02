### Security

- Update Happy DOM and its global registrator to 21.0.4, fixing the ESM compiler injection in GHSA-834v-8h66-3h79. Refresh all four consumer lockfiles.

### Changed

- Update preact-render-to-string to 6.8.2, Bun types to 1.4.4, and Node types to 26.6.6, with compatible transitive updates.
- Pin Bun 1.4.4 and Ruby 4.0.9 across development and CI, update the installer and npm toolchain expectation, and use mise-action v5.

### Fixed

- Keep SSR runtime imports and hooks on the renderer's Preact instance when Bun materializes a separate local `file:` runtime package. Preserve site-specific resolve aliases.
