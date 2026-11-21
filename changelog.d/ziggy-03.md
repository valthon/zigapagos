### Changed

- **Pre-1.0 breaking changes — Ziggy 0.3.0:** configs now use `.site = .simple(.{ ... })` or `.multilingual(.{ ... })`; run `python3 scripts/upgrade-ziggy.py /path/to/site`. The config keeps its name and existing fork settings. No version field is required.
- **Pre-1.0 breaking change:** frontmatter dates use `.date("...")` or `.unix(seconds)`, records use `.{ ... }`, pagination styles use enum literals such as `.plain_dir`, and dictionaries use `{ "key": value }`. Run the converter for config/data/frontmatter, then update inline Ziggy in templates, scripts and body examples manually.
- **Pre-1.0 breaking change:** `.author` becomes optional `.authors = ["Name"]`. Run the converter and change templates to `$page.authors.join(', ')` or an authors loop. Omitted authors default to `[]`; omitted dates still default to the epoch.
- **Pre-1.0 breaking change:** Ziggy rejects carriage returns and most control bytes. The converter changes config/data and frontmatter CRLF to LF, preserving all body bytes. Remove other invalid controls manually.
- **Pre-1.0 breaking change:** the root editor schema is replaced by the binary's shipped schemas. Run `zigapagos install-schemas` after upgrading; `init` creates them. Scripty array types are now written `[]String`; builtin signatures are unchanged except that `Array.first?()` and `Array.last?()` now correctly declare optional returns (`?any`), matching their existing runtime results.

### Added

- Site `.custom` dictionaries are available as `$site.custom`. `.supermd.auto_target_blank` controls external Markdown links and defaults to true, preserving rendered output. See `docs/migration/ziggy-0.3.md` for the complete upgrade procedure.

### Fixed

- Accept empty dynamic structs in custom values, data, i18n, asset `.ziggy()` and island props, retaining the struct/dictionary distinction. Report missing opening frontmatter delimiters by filename and exit nonzero from the converter.

- The upgrade tool wraps legacy quoted frontmatter dates in `.date(...)` and preserves body bytes on repeated runs. Unconverted string dates receive upgrade instructions. Complete documentation configs and frontmatter are parser/schema checked, and non-Ziggy examples retain their original language syntax.

- Preserve comments and their terminating newlines throughout conversion, including between legacy identifier/tag tokens. A generated boundary sweep covers 389 variants across six representative documents, plus six parser-checked baselines.
