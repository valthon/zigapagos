### Fixed

- Invalid bare autolinks now produce diagnostics without column arithmetic panics, with carets clamped to the source line (#257).
- Markdown diagnostics use the file's line numbers regardless of blank lines after front matter (#256, part 2).
