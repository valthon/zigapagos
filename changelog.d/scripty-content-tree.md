### Added

- `$page.leaves([limit])` lists active non-section pages across a section's subtree in descending date order. `forbid_subsections` on a section index requires child pages to use `foo.smd` instead of `foo/index.smd`; violations include a positioned diagnostic and a suggested move that preserves the URL.
- `$site.index()` returns the root index page. `$site.page()` accepts multiple string path parts.
- `Array.join(separator)` joins strings and numbers, including empty arrays.
- `$build.development` identifies renders performed by the dev loop, including rebuilds and sessions without live reload.

### Removed

- **Pre-1.0 breaking change:** removed the ineffective `skip_subdirs` frontmatter field and template property. Delete it from frontmatter; use `forbid_subsections = true` on terminal section indexes when child pages should be leaves. Remaining uses fail with a migration diagnostic.

### Fixed

- Debug builds scan content directories in deterministic path order.
