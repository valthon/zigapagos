### Added

- Generic Ziggy union values in Scripty support field access, `tag()` and `case?()` in custom fields, data and assets; date and Unix timestamp conveniences remain.
- Dev sessions accept `--url-path-prefix VALUE` and `--url-path-prefix=VALUE`, including custom rebuilds and live reload.

### Fixed

- Native Ziggy dictionary keys decode escapes consistently with `@z/site-data`, including island prop names; decoded duplicate keys remain errors.
- Static file symlinks can publish regular files outside the assets directory, directly or through globs. POSIX filenames such as `c:notes.txt` are accepted.

### Internal

- Builds check config and page type agreement with the shipped schemas. Snapshot tests detect untracked files without staging their contents.
- The Ziggy 0.3 migration guide enumerates converter limitations and their manual upgrade steps.
- Schema agreement rejects payload presence and skipped-field mismatches, reports slice/container mismatches without crashing, and checks optional builtin containers correctly. The date adapter declares its actual tagged-union shape. A permanent matrix covers structural mismatches in both directions, including production config and page schemas.
- Schema checks bind `$` to the actual document type, reject unreferenced declarations and unparsed input, and consume every expression token. The grammar matrix now covers 104 negative mutations and twelve matching baselines, with explicit Dynamic-to-`any` wrapping rules.
