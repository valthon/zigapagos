### Added

- Structured island-render diagnostics in `--format=json`: stable codes distinguish SSR failures, content-island Scripty prop errors, missing sidecars and other island-pass failures. Records retain content-page attribution and full component/route/error details.

### Fixed

- An island render that failed without the sidecar describing it — a protocol desync, a malformed response, a subprocess that died mid-render — reported an empty message and discarded the error name. It now carries the Zig error name in both text and JSON mode.
- The missing-sidecar message named only `<island>`, though the `<z-island>` content-page alias reaches the same check.
