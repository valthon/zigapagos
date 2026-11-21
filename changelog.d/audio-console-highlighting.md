### Added

- Audio directives with captions, playback attributes, local/build/remote sources and fingerprinted site assets. CSP extra sources accept `media-src`; deployment checks and Rails parity recognize audio content types.
- `console` highlighting for fenced blocks and code directives, with escaped prompt, command and output text.

### Fixed

- `-Dhighlight=false` omits syntax/tree-sitter imports and the query cache, and accepts every language name without warnings.
