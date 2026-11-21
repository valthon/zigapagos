### Fixed

- Initialize complete page placeholders during scanning and suppress inactive section subtrees in sorting, page lists, counts and pagination; preserve a draft root as an unpublished container for active child pages.
- Reject inactive page lookups and link targets before reading content; `--allow-missing-pages` keeps its missing-page behavior. Locale and site-wide lists omit inactive pages.
- Handle translation keys on unpublished root containers even when no active counterpart supplies an index entry.
- Enforce `forbid_subsections` on active section containers, including a parsed draft root.
- Exclude empty content files from page lists, counts and pagination while preserving their warnings; initialize failed parses before section sorting.
- Bound Markdown diagnostic previews for nested containers, blank lines, truncated sources and related definitions; preserve the correct parent name in HTML nesting errors.
- Preserve readable Markdown and embedded HTML errors, duplicate-definition excerpts, asset paths and invalid-date positions across diagnostics.
- Correct the Scripty reference return types for `Array.first?()` and `Array.last?()`.

### Changed

- **Pre-1.0 breaking change:** an empty section index now suppresses its descendants. To publish those pages,
  give the section's `index.smd` valid `title` and `layout` frontmatter.
- **Pre-1.0 breaking change:** invalid dates now report `ZP_INVALID_DATE` instead of `ZP_FRONTMATTER_PARSE`.
  Update tooling that matches the diagnostic code.
